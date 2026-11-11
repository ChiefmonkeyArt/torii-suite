#!/usr/bin/env python3
"""GLiClass v4 Edge on the CPU: typed decisions, a self-test and a benchmark.

Suite ADR 0004. Optional (INSTALL_GLICLASS=1). Runs the 4-bit weight-only ONNX
file that installers/install-gliclass.sh makes from the pinned upstream file.
Needs only onnxruntime, tokenizers and numpy: no PyTorch, no network, no
generated text. A decision is one forward pass that scores every option.

Request shape follows the model card's Jev-style server (knowledgator/
gliclass-v4-edge README, "Serving a Jev-style decision API"): the state is the
text, the question is the instruction, every option is a label.

  python3 gliclass_edge.py selftest MODEL_DIR
  python3 gliclass_edge.py bench MODEL_DIR BENCH_DIR [--json OUT]
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time

# Second guard (the pinned onnxruntime 1.28.0 has no telemetry code): 1.29+
# reads this once at import and then sends nothing to Microsoft.
os.environ["ORT_DISABLE_TELEMETRY"] = "1"

LABEL, SEP = "<<LABEL>>", "<<SEP>>"
MAX_TOKENS = 4096  # refuse, never truncate (a cut-off state gives a wrong answer)
MAX_OPTIONS = 25   # model config max_num_classes

# Golden answers from the full-precision upstream ONNX file (which matches the
# PyTorch reference exactly). A converted file must agree on every pick and
# stay close on probability, or the install is refused.
SELFTEST = [
    {"state": "Our refund window is 30 days. The customer bought the item 45 days ago.",
     "question": "Apply the refund policy to the customer's request.",
     "options": {"approve": "refund approved", "deny": "refund denied", "human": "escalate to a human"},
     "expected": "deny", "p_full": 0.950},
    {"state": ("Alice -member_of-> Finance team\nFinance team -can_read-> Reports folder\n"
               "Alice -explicit_deny-> Salaries.xlsx\nRule: explicit restrictions override team permissions."),
     "question": "Can Alice open Salaries.xlsx?",
     "options": {"yes": "yes", "no": "no"}, "expected": "no", "p_full": 0.999},
    {"state": "What's the weather in Paris tomorrow?",
     "question": "Which tool should handle this request?",
     "options": {"weather": "get_weather", "email": "send_email", "none": "no tool fits"},
     "expected": "weather", "p_full": 0.998},
]
SELFTEST_TOLERANCE = 0.05


def as_text(value) -> str:
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def render_state(state) -> str:
    """Same rendering as the model card server: key: value lines, string lists as - items."""
    if state in (None, "", {}, []):
        return ""
    if isinstance(state, str):
        return state
    if isinstance(state, list):
        return "\n".join(f"- {as_text(item)}" for item in state)
    lines = []
    for key, value in state.items():
        if isinstance(value, list) and all(isinstance(item, str) for item in value):
            lines += [f"{key}:"] + [f"- {item}" for item in value]
        else:
            lines.append(f"{key}: {as_text(value)}")
    return "\n".join(lines)


def build_input(text: str, labels: list[str], prompt: str) -> str:
    """Uni-encoder layout with prompt_first (gliclass pipeline.prepare_input):
    labels, separator, instruction, then the state."""
    return "".join(LABEL + label for label in labels) + SEP + (prompt or "") + text


class Engine:
    def __init__(self, model_dir: str, threads: int | None = None):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.np = np
        self.tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads or (os.cpu_count() or 1)
        opts.inter_op_num_threads = 1
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.enable_mem_pattern = False  # inputs vary in length; keeps resident memory down
        t0 = time.perf_counter()
        self.session = ort.InferenceSession(
            os.path.join(model_dir, "model.onnx"), sess_options=opts, providers=["CPUExecutionProvider"])
        self.load_ms = (time.perf_counter() - t0) * 1000
        self.threads = opts.intra_op_num_threads

    def choice(self, state, question: str, options: dict[str, str]) -> dict:
        """One choice question. Returns pick, probabilities, tokens and milliseconds."""
        if not isinstance(options, dict) or not 2 <= len(options) <= MAX_OPTIONS:
            raise ValueError(f"need 2 to {MAX_OPTIONS} options")
        np = self.np
        keys = list(options)
        labels = [as_text(v) if v is not None else k for k, v in options.items()]
        enc = self.tok.encode(build_input(render_state(state), labels, as_text(question or "")))
        if len(enc.ids) > MAX_TOKENS:
            raise ValueError(f"input of {len(enc.ids)} tokens exceeds the {MAX_TOKENS}-token limit")
        ids = np.asarray([enc.ids], dtype=np.int64)
        mask = np.asarray([enc.attention_mask], dtype=np.int64)
        t0 = time.perf_counter()
        logits = self.session.run(None, {"input_ids": ids, "attention_mask": mask})[0][0][: len(keys)]
        ms = (time.perf_counter() - t0) * 1000
        z = np.exp(logits - logits.max())
        p = z / z.sum()
        probs = {k: float(v) for k, v in zip(keys, p)}
        ranked = sorted(probs.values(), reverse=True)
        pick = max(keys, key=probs.get)
        return {"choice": pick, "confidence": probs[pick], "margin": ranked[0] - ranked[1],
                "probabilities": probs, "tokens": len(enc.ids), "ms": ms}


def selftest(engine: Engine) -> list[str]:
    """Empty list when the model agrees with the full-precision answers."""
    problems = []
    for case in SELFTEST:
        r = engine.choice(case["state"], case["question"], case["options"])
        if r["choice"] != case["expected"]:
            problems.append(f"picked {r['choice']} instead of {case['expected']}")
        elif abs(r["confidence"] - case["p_full"]) > SELFTEST_TOLERANCE:
            problems.append(f"{case['expected']}: {r['confidence']:.3f} vs full precision {case['p_full']:.3f}")
    return problems


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _score(engine, cases, reference, min_p, min_margin):
    rows, lat = [], []
    for case in cases:
        r = engine.choice(case["state"], case["question"], case["options"])
        lat.append(r["ms"])
        ref = reference.get(case["id"], {})
        rows.append({"id": case["id"], "category": case.get("category", case.get("reasoning", "")),
                     "expected": case["expected"], "picked": r["choice"],
                     "correct": r["choice"] == case["expected"],
                     "confidence": round(r["confidence"], 4), "margin": round(r["margin"], 4),
                     "gate_clear": r["confidence"] >= min_p and r["margin"] >= min_margin,
                     "tokens": r["tokens"], "ms": round(r["ms"], 1),
                     "jev_picked": ref.get("picked"), "jev_correct": ref.get("correct")})
    n = len(rows)
    correct = sum(r["correct"] for r in rows)
    summary = {"cases": n, "correct": correct, "accuracy": round(correct / n, 4),
               "gate_clear": sum(r["gate_clear"] for r in rows),
               "mean_margin": round(statistics.fmean(r["margin"] for r in rows), 4),
               "median_ms": round(statistics.median(lat), 1),
               "p95_ms": round(sorted(lat)[max(0, int(round(0.95 * n)) - 1)], 1),
               "mean_tokens": round(statistics.fmean(r["tokens"] for r in rows), 1),
               "jev_correct": sum(1 for r in rows if r["jev_correct"]),
               "agrees_with_jev": sum(1 for r in rows if r["jev_picked"] == r["picked"])}
    no_tool = [r for r in rows if r["expected"] == "no_tool"]
    if no_tool:
        summary["no_tool_recall"] = f"{sum(r['correct'] for r in no_tool)}/{len(no_tool)}"
        sel = [r for r in rows if r["expected"] != "no_tool"]
        summary["selection"] = f"{sum(r['correct'] for r in sel)}/{len(sel)}"
    return summary, rows


def bench(engine: Engine, bench_dir: str) -> dict:
    """The OpenSystem1-classifier sets: 12 obvious questions and 30 BFCL-derived
    routing cases, with Jev 1.13's recorded per-case picks for comparison."""
    routing = _load(os.path.join(bench_dir, "bfcl-routing-subset.json"))
    obvious = _load(os.path.join(bench_dir, "typesafe-benchmark-results.json"))["cases"]
    jev_routing = {c["id"]: c for c in _load(os.path.join(bench_dir, "bfcl-routing-typesafe-results.json"))["cases"]}
    jev_obvious = {c["id"]: c for c in obvious}
    min_p, min_margin = routing["minimum_probability"], routing["minimum_margin"]
    for case in routing["cases"][:2] + obvious[:2]:  # warm-up, not timed
        engine.choice(case["state"], case["question"], case["options"])
    s_obv, r_obv = _score(engine, obvious, jev_obvious, min_p, min_margin)
    s_rt, r_rt = _score(engine, routing["cases"], jev_routing, min_p, min_margin)
    return {"model": "knowledgator/gliclass-v4-edge (4-bit weight-only ONNX)", "threads": engine.threads,
            "cpu": _cpu_name(), "load_ms": round(engine.load_ms), "peak_rss_mb": _peak_rss_mb(),
            "gate": {"minimum_probability": min_p, "minimum_margin": min_margin},
            "obvious": s_obv, "routing": s_rt, "cases": {"obvious": r_obv, "routing": r_rt}}


def _cpu_name() -> str:
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def _peak_rss_mb() -> int:
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024


def _print_report(rep: dict) -> None:
    print(f"CPU: {rep['cpu']} ({rep['threads']} threads); load {rep['load_ms']} ms; peak memory {rep['peak_rss_mb']} MB")
    for name, title in (("obvious", "12 obvious questions"), ("routing", "30 tool-routing cases")):
        s = rep[name]
        extra = f"; pick a tool {s['selection']}, no tool {s['no_tool_recall']}" if "selection" in s else ""
        print(f"{title}: {s['correct']}/{s['cases']} right (Jev 1.13: {s['jev_correct']}/{s['cases']}){extra}; "
              f"same pick as Jev {s['agrees_with_jev']}/{s['cases']}; confident {s['gate_clear']}/{s['cases']}; "
              f"median {s['median_ms']} ms, p95 {s['p95_ms']} ms, {s['mean_tokens']} tokens")
    for name in ("obvious", "routing"):
        for r in rep["cases"][name]:
            if not r["correct"]:
                print(f"  wrong: {r['id']} picked {r['picked']} (expected {r['expected']}, p={r['confidence']}, Jev {r['jev_picked']})")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("selftest")
    st.add_argument("model_dir")
    b = sub.add_parser("bench")
    b.add_argument("model_dir")
    b.add_argument("bench_dir")
    b.add_argument("--json")
    b.add_argument("--threads", type=int)
    args = ap.parse_args(argv)
    engine = Engine(args.model_dir, getattr(args, "threads", None))
    if args.cmd == "selftest":
        problems = selftest(engine)
        for p in problems:
            print(f"selftest: {p}", file=sys.stderr)
        print("selftest: ok" if not problems else "selftest: FAILED")
        return 1 if problems else 0
    rep = bench(engine, args.bench_dir)
    _print_report(rep)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
