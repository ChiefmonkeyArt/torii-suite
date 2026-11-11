"""Suite ADR 0004: GLiClass Edge logic that needs no model (python3 -m unittest)."""
import importlib.util
import os
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
os.environ.pop("ORT_DISABLE_TELEMETRY", None)
spec = importlib.util.spec_from_file_location("gliclass_edge", ROOT / "lib/gliclass/gliclass_edge.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class FakeEngine:
    """Picks from a table; stands in for the ONNX session."""
    threads = 1

    def __init__(self, picks):
        self.picks = picks

    def choice(self, state, question, options):
        pick = self.picks[state]
        others = [k for k in options if k != pick]
        probs = {pick: 0.9, **{k: 0.1 / len(others) for k in others}}
        return {"choice": pick, "confidence": 0.9, "margin": 0.9 - max(probs[k] for k in others),
                "probabilities": probs, "tokens": 10, "ms": 5.0}


class Logic(unittest.TestCase):
    def test_telemetry_switch_set_on_import(self):
        self.assertEqual(os.environ.get("ORT_DISABLE_TELEMETRY"), "1")

    def test_render_state(self):
        self.assertEqual(g.render_state(None), "")
        self.assertEqual(g.render_state("plain"), "plain")
        self.assertEqual(g.render_state(["a", {"b": 1}]), '- a\n- {"b": 1}')
        self.assertEqual(g.render_state({"user": "alice", "tags": ["x", "y"], "n": 3}),
                         "user: alice\ntags:\n- x\n- y\nn: 3")

    def test_build_input(self):
        self.assertEqual(g.build_input("STATE", ["yes", "no"], "Q? "), "<<LABEL>>yes<<LABEL>>no<<SEP>>Q? STATE")
        self.assertEqual(g.build_input("S", ["a", "b"], None), "<<LABEL>>a<<LABEL>>b<<SEP>>S")

    def test_score(self):
        cases = [{"id": "c1", "state": "s1", "question": "q", "options": {"a": "A", "b": "B"}, "expected": "a"},
                 {"id": "c2", "state": "s2", "question": "q", "options": {"a": "A", "no_tool": "none"}, "expected": "no_tool"},
                 {"id": "c3", "state": "s3", "question": "q", "options": {"a": "A", "no_tool": "none"}, "expected": "no_tool"}]
        ref = {"c1": {"picked": "a", "correct": True}, "c2": {"picked": "no_tool", "correct": True},
               "c3": {"picked": "a", "correct": False}}
        s, rows = g._score(FakeEngine({"s1": "a", "s2": "a", "s3": "no_tool"}), cases, ref, 0.65, 0.15)
        self.assertEqual((s["cases"], s["correct"], s["jev_correct"], s["agrees_with_jev"]), (3, 2, 2, 1))
        self.assertEqual((s["selection"], s["no_tool_recall"]), ("1/1", "1/2"))
        self.assertEqual(s["gate_clear"], 3)
        self.assertFalse(rows[1]["correct"])

    def test_selftest_reports_wrong_pick_and_drift(self):
        class E:
            def __init__(self, conf, flip=False):
                self.conf, self.flip = conf, flip

            def choice(self, state, question, options):
                case = next(c for c in g.SELFTEST if c["state"] == state)
                pick = next(k for k in options if k != case["expected"]) if self.flip else case["expected"]
                return {"choice": pick, "confidence": case["p_full"] - self.conf}
        self.assertEqual(g.selftest(E(0.01)), [])
        self.assertEqual(len(g.selftest(E(0.2))), 3)
        self.assertTrue(all("instead of" in p for p in g.selftest(E(0, flip=True))))

    def test_option_limits(self):
        e = g.Engine.__new__(g.Engine)
        with self.assertRaises(ValueError):
            e.choice("s", "q", {"only": "one"})
        with self.assertRaises(ValueError):
            e.choice("s", "q", {str(i): str(i) for i in range(g.MAX_OPTIONS + 1)})

    def test_requirements_are_hash_pinned(self):
        for name in ("requirements-runtime.txt", "requirements-convert.txt"):
            text = (ROOT / "lib/gliclass" / name).read_text()
            reqs = re.findall(r"^([A-Za-z0-9_.-]+)==(\S+) \\$", text, re.M)
            self.assertTrue(reqs, name)
            for block in re.split(r"\n(?=[A-Za-z])", text.split("\n", 1)[1]):
                if block.strip() and not block.startswith("#"):
                    self.assertIn("--hash=sha256:", block, block)
        self.assertIn("numpy==2.3.5 ", (ROOT / "lib/gliclass/requirements-runtime.txt").read_text(),
                      "numpy 2.4+ needs x86-64-v2; see ADR 0004 before changing the pin")
        self.assertIn("onnxruntime==1.28.0 ", (ROOT / "lib/gliclass/requirements-runtime.txt").read_text(),
                      "onnxruntime 1.29+ sends telemetry to Microsoft; see ADR 0004 before changing the pin")


if __name__ == "__main__":
    sys.exit(unittest.main())
