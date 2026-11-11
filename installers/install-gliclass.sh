#!/usr/bin/env bash
# torii-suite/installers/install-gliclass.sh — GLiClass v4 Edge, a small
# choice model that runs on the CPU (Suite ADR 0004). Opt-in (INSTALL_GLICLASS=1).
#
# It answers "which of these options?" questions (which tool, approve or deny,
# yes or no) in one pass, with no generated text and no network. Nothing uses
# it yet: this installs the model, checks it and fetches the benchmark so the
# operator can measure it on their own CPU (installers/bench-gliclass.sh)
# before Continuum is wired to it.
#
#   1. checks: root, x86_64, CPython 3.13 or 3.14, about 3.5 GB of free disk
#      and 4 GB of free memory (the conversion needs it, once)
#   2. downloads the full-precision ONNX file and tokenizer from a pinned
#      Hugging Face revision, each checked against a pinned SHA-256
#   3. makes a 4-bit weight-only copy (lib/gliclass/convert.py; about 490 MB)
#      and deletes the full-precision file and the conversion libraries
#   4. runtime: /opt/gliclass-edge/venv (onnxruntime, tokenizers, numpy;
#      hash-pinned wheels, no build step, no PyTorch)
#   5. self-test: the 4-bit file must give the full-precision answers, or the
#      install is removed and refused
#   6. benchmark data from OpenSystem1-classifier at a pinned commit, checked
#      by SHA-256 (fetched, not copied into this repo: that repo has no licence)
#
# Disk after install: about 660 MB. No service, no port, no user.
# Re-runs skip everything when the installed pin and self-test still match.
# Remove with installers/remove-gliclass.sh (stage gliclass_remove).
#
# Env: GLICLASS_ROOT (default /opt/gliclass-edge), GLICLASS_THREADS.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC="$ROOT/lib/gliclass"
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m--  %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx  install-gliclass: %s\033[0m\n' "$*" >&2; exit 1; }
[[ "${INSTALL_GLICLASS:-0}" == 1 ]] || { echo "GLiClass Edge install skipped (INSTALL_GLICLASS=0)"; exit 0; }
[[ $EUID -eq 0 ]] || die "requires root"

# onnxruntime 1.29+ sends telemetry to Microsoft unless this is set before it
# loads. The pinned 1.28.0 has none; this and the check below are guards.
export ORT_DISABLE_TELEMETRY=1
GL_ROOT="${GLICLASS_ROOT:-/opt/gliclass-edge}"
case "$GL_ROOT" in /*) ;; *) die "GLICLASS_ROOT must be an absolute path" ;; esac

# Pins. Model: knowledgator/gliclass-v4-edge (Apache-2.0). Bench data:
# maustin10/OpenSystem1-classifier. Changing a revision means changing its hashes.
GL_REV=885af1af8a07edf4ed34df83ca0d995ed8201283
GL_BASE="https://huggingface.co/knowledgator/gliclass-v4-edge/resolve/${GL_REV}/onnx"
GL_MODEL_SHA=0943dc2b2ab697915af029e04c2233be2d5c4c16224c7fe833551fdc22b78f69
GL_TOK_SHA=fac3bf8dbdea44df6c0dd296ca81ca058710c69abdb8d69905d5c26d4dccf66a
OS1_REV=842dcfc4209083f16d7e379cbf071dfa0233fc80
OS1_BASE="https://raw.githubusercontent.com/maustin10/OpenSystem1-classifier/${OS1_REV}"
BENCH_FILES=(
  "data/bfcl-routing-subset.json 15ed1ea4fee5a64402302cb2ed2315badf99954a3539c12a669c3cff1a5696fd"
  "results/typesafe-benchmark-results.json 1ef2fcaacb351f9d22754d79d02b8715fd0cb93d29117901ef36b8858680cd6d"
  "results/bfcl-routing-typesafe-results.json a8d82cdb9f083572c0cc0feaf3713d34231364e3bebf646b417bf5f1c4732970"
)
NEED_DISK_MB=3500
NEED_MEM_MB=4000
STAMP="${GL_ROOT}/INSTALLED"
STAMP_WANT="rev=${GL_REV} model=${GL_MODEL_SHA} tok=${GL_TOK_SHA} os1=${OS1_REV} code=$(cat "$SRC/gliclass_edge.py" "$SRC/convert.py" "$SRC"/requirements-*.txt | sha256sum | cut -c1-16)"

[[ "$(uname -m)" == x86_64 ]] || die "x86_64 only (the pinned wheels are x86_64)"
command -v python3 >/dev/null || die "python3 not found"
PYV="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
case "$PYV" in 3.13|3.14) ;; *) die "needs CPython 3.13 or 3.14 (found ${PYV}); the wheels are pinned for those" ;; esac

selftest() { "${GL_ROOT}/venv/bin/python" "${GL_ROOT}/gliclass_edge.py" selftest "${GL_ROOT}/model"; }

if [[ -f "$STAMP" && "$(head -1 "$STAMP")" == "$STAMP_WANT" ]] && selftest >/dev/null 2>&1; then
  log "GLiClass Edge already installed at ${GL_ROOT} and passes its self-test"
  exit 0
fi

# 1. Room to work. The conversion holds the full-precision model in memory.
mkdir -p "$GL_ROOT"
free_mb="$(df --output=avail -m "$GL_ROOT" | tail -1 | tr -d ' ')"
(( free_mb >= NEED_DISK_MB )) || die "needs about ${NEED_DISK_MB} MB free on $(df --output=target "$GL_ROOT" | tail -1) during install, has ${free_mb} MB (about 660 MB stays after)"
mem_mb="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
(( mem_mb >= NEED_MEM_MB )) || die "needs about ${NEED_MEM_MB} MB of free memory to convert the model once, has ${mem_mb} MB"
log "disk ${free_mb} MB free, memory ${mem_mb} MB free, Python ${PYV}"

if ! python3 -c 'import ensurepip, venv' 2>/dev/null; then
  log "installing python3-venv"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null
fi

work="$(mktemp -d /var/tmp/gliclass-install.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT

fetch() { # url sha256 dest
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 5 -o "$3.part" "$1" || die "download failed: $1"
  local got; got="$(sha256sum "$3.part" | cut -d' ' -f1)"
  [[ "$got" == "$2" ]] || { rm -f -- "$3.part"; die "checksum mismatch for $(basename "$3") (got ${got:0:16}…)"; }
  mv -f -- "$3.part" "$3"
}
pipi() { "${GL_ROOT}/venv/bin/python" -m pip -q --disable-pip-version-check --no-cache-dir install \
  --no-deps --require-hashes --only-binary=:all: "$@"; }

# 2. Runtime libraries (kept) and conversion libraries (temporary, same Python).
log "runtime libraries -> ${GL_ROOT}/venv"
rm -rf -- "${GL_ROOT}/venv"
python3 -m venv "${GL_ROOT}/venv"
pipi -r "$SRC/requirements-runtime.txt" || die "runtime libraries failed to install"
if grep -rlaqF -e events.data.microsoft.com -e OneCollector "${GL_ROOT}/venv/lib"; then
  rm -rf -- "${GL_ROOT}/venv"
  die "this onnxruntime build carries Microsoft telemetry; refusing it (pin 1.28.0 or a --no_telemetry build)"
fi
log "conversion libraries (temporary)"
pipi --target "$work/convlib" -r "$SRC/requirements-convert.txt" \
  || die "conversion libraries failed to install"

# 3. Model files from the pinned revision.
log "downloading GLiClass Edge (1.8 GB, revision ${GL_REV:0:12})"
fetch "${GL_BASE}/model.onnx" "$GL_MODEL_SHA" "$work/model-full.onnx"
fetch "${GL_BASE}/tokenizer.json" "$GL_TOK_SHA" "$work/tokenizer.json"

# 4. 4-bit weight-only copy. Different CPUs may round differently, so the file
#    hash is logged, not pinned; the self-test is the gate.
log "making the 4-bit copy"
mkdir -p "$work/model"
PYTHONPATH="$work/convlib" "${GL_ROOT}/venv/bin/python" "$SRC/convert.py" "$work/model-full.onnx" "$work/model/model.onnx" \
  || die "conversion failed"
rm -f -- "$work/model-full.onnx"
rm -rf -- "$work/convlib"
mv "$work/tokenizer.json" "$work/model/tokenizer.json"
log "4-bit file sha256 $(sha256sum "$work/model/model.onnx" | cut -c1-16)…, $(du -m "$work/model/model.onnx" | cut -f1) MB"

rm -rf -- "${GL_ROOT}/model" "${GL_ROOT}/model.new"
mv "$work/model" "${GL_ROOT}/model.new"
mv "${GL_ROOT}/model.new" "${GL_ROOT}/model"
install -m 0644 "$SRC/gliclass_edge.py" "${GL_ROOT}/gliclass_edge.py"

# 5. Self-test or refuse.
if ! out="$(selftest 2>&1)"; then
  printf '%s\n' "$out" >&2
  rm -rf -- "$GL_ROOT"
  die "the 4-bit model did not give the full-precision answers on this CPU; removed"
fi
log "$out"

# 6. Benchmark data.
mkdir -p "${GL_ROOT}/bench"
for entry in "${BENCH_FILES[@]}"; do
  path="${entry%% *}"; sha="${entry##* }"
  fetch "${OS1_BASE}/${path}" "$sha" "${GL_ROOT}/bench/$(basename "$path")"
done
log "benchmark data (OpenSystem1-classifier ${OS1_REV:0:12}) -> ${GL_ROOT}/bench"

chmod -R go-w,a+rX "$GL_ROOT"
printf '%s\ninstalled=%s\n' "$STAMP_WANT" "$(date -u +%FT%TZ)" > "$STAMP"
log "GLiClass Edge installed: $(du -sm "$GL_ROOT" | cut -f1) MB in ${GL_ROOT}. Measure it with installers/bench-gliclass.sh"
