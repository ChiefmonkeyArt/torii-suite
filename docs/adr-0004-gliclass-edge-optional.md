# ADR 0004 (Suite): GLiClass Edge, an optional choice model on the CPU

Date: 2026-11-11. Status: **Accepted** (owner, 2026-11-11: "Add GLiClass Edge
as an optional install and benchmark it on the server CPU"). Target: Suite
`v0.9.65-alpha`, with Continuum `v0.2.210-alpha` (stages `gliclass`,
`gliclass_bench`, `gliclass_remove`).

## Context

- Many agent steps are choices, not writing: which tool, approve or deny,
  yes or no. TypeSafe's Jev 1.13 answers these in one pass but is a hosted
  service. A local model keeps the question and its context on the server.
- `knowledgator/gliclass-v4-edge` (Apache-2.0, 0.4B parameters, a
  DeBERTa-v3-large-based encoder) ships ONNX files and a model card that shows
  a Jev-style decision server. It was the smallest open option we found with
  published Jev-style results.
- Trials on a 2-core x86_64 sandbox (Python 3.14):
  - the full-precision `onnx/model.onnx` (1.76 GB) matches the upstream
    PyTorch reference exactly;
  - the upstream 8-bit file `onnx/model_q8.onnx` (647 MB) and ordinary
    dynamic 8-bit quantisation (every variant tried) give wrong answers,
    because activations are rounded too;
  - **4-bit weight-only** (MatMulNBits, block 32, symmetric, 8-bit compute;
    the word table as GatherBlockQuantized; opset kept at 17) is 466 MB and
    gives the same pick on every test case, with probabilities within 0.01;
  - conversion needs about 3.5 GB of memory for about 10 seconds; answering
    needs about 1.5 GB resident.
- Benchmark (OpenSystem1-classifier sets, pinned commit 842dcfc; Jev 1.13's
  recorded answers from the same repo), 4-bit and full precision identical:
  - 12 obvious questions: 11/12 (Jev 12/12), median about 0.25 s;
  - 30 tool-routing cases: 28/30 (Jev 29/30; ModernBERT-large zero-shot
    23/30), every tool pick right (20/20), 8/10 "no tool fits"; median about
    0.9 s for about 210 tokens on 2 cores.
- **ONNX Runtime 1.29 and later send telemetry to Microsoft by default on
  Linux** (a persistent device ID, OS, CPU, memory and model details to
  `mobile.events.data.microsoft.com`), unless `ORT_DISABLE_TELEMETRY=1` is set
  before the library loads. 1.28.0 contains no telemetry code. This conflicts
  with the rule of no Google, Microsoft or Cloudflare in infrastructure paths.

## Decision

1. **Opt-in.** `INSTALL_GLICLASS=0` by default (`.env.example`,
   `bootstrap.sh`). `installers/install-gliclass.sh` installs into
   `/opt/gliclass-edge`; nothing listens and no service runs.
2. **Convert on the server from a pinned source.** The full-precision ONNX
   file and tokenizer come from Hugging Face revision `885af1a…`, each checked
   against a pinned SHA-256. `lib/gliclass/convert.py` makes the 4-bit copy;
   the full-precision file and conversion libraries are deleted afterwards
   (about 630 MB stays). The converted file's hash is logged but not pinned,
   because different CPUs and runtime versions may round differently (seen:
   ONNX Runtime 1.28.0 and 1.31.1 produce different bytes with identical
   answers).
3. **Self-test is the gate.** Three cases with known full-precision answers;
   a wrong pick or a probability more than 0.05 away removes the install and
   fails the stage.
4. **Hash-pinned wheels, no build step, no PyTorch.** Runtime: onnxruntime,
   tokenizers, numpy and their dependencies (`requirements-runtime.txt`).
   Conversion only: onnx and friends (`requirements-convert.txt`). Both use
   `pip --no-deps --require-hashes --only-binary=:all:` for CPython 3.13/3.14
   on x86_64.
5. **No Microsoft telemetry.** onnxruntime is pinned at **1.28.0**. As second
   guards, `ORT_DISABLE_TELEMETRY=1` is set by the installer, the bench
   script, the bench sandbox, `convert.py` and `gliclass_edge.py`; and the
   installer refuses any onnxruntime build that contains the collector
   address. Raising the pin needs a new decision.
6. **Measure before wiring.** `installers/bench-gliclass.sh` (stage
   `gliclass_bench`) runs the self-test and the benchmark under a throwaway
   user with no network, a read-only system and a memory cap, and keeps the
   JSON under `/var/lib/gliclass-edge/`. Benchmark data is downloaded at a
   pinned commit with SHA-256 checks, not copied into this repo (that repo
   has no licence).
7. **Removal is a stage.** `installers/remove-gliclass.sh` (stage
   `gliclass_remove`) deletes `/opt/gliclass-edge`, reports the space freed,
   and the stage writes `INSTALL_GLICLASS=0`.

## Consequences

- A later Continuum decision can wire choice questions to this model behind a
  loopback service, using the server's own benchmark numbers.
- ONNX Runtime and DeBERTa-v3 (the model's base) are Microsoft-authored, MIT
  licensed open source. They run offline here, with telemetry absent from the
  pinned build; no Microsoft service is contacted. The model files come from
  Hugging Face at install time only.
- On 2 cores a long routing prompt takes about a second; this suits
  background decisions, not every keystroke.
- x86_64 and Python 3.13/3.14 only, for now (the hashes cover those wheels).
