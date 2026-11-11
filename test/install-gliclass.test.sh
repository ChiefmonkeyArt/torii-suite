#!/usr/bin/env bash
# Suite ADR 0004: GLiClass Edge is opt-in, pinned, telemetry-free and removable.
# Static checks always; the root-only checks run under sudo (CI does).
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { pass=$((pass+1)); }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

if command -v shellcheck >/dev/null; then
  shellcheck -S warning installers/install-gliclass.sh installers/bench-gliclass.sh installers/remove-gliclass.sh || fail shellcheck; ok
fi
python3 test/gliclass_edge_test.py >/dev/null 2>&1 || { python3 test/gliclass_edge_test.py; fail "python unit tests"; }; ok

# Off by default, wired through bootstrap.
grep -qx 'INSTALL_GLICLASS=0' .env.example || fail ".env.example default"; ok
grep -qF 'INSTALL_GLICLASS="${INSTALL_GLICLASS:-0}"' bootstrap.sh || fail "bootstrap default"; ok
grep -qx 'export INSTALL_GLICLASS' bootstrap.sh || fail "bootstrap export"; ok
grep -qF '_stage_gliclass()       { "${SCRIPT_DIR}/installers/install-gliclass.sh"; }' bootstrap.sh || fail "stage fn"; ok
grep -qF '[[ "$INSTALL_GLICLASS"         == "1" ]] && _STAGES_TOTAL' bootstrap.sh || fail "stage count"; ok
out="$(INSTALL_GLICLASS=0 bash installers/install-gliclass.sh)" || fail "skip exits non-zero"
[[ "$out" == *"skipped (INSTALL_GLICLASS=0)"* ]] || fail "skip message"; ok

# Pins: upstream revision + hashes, bench data commit, no network fetch without a hash.
grep -qx 'GL_REV=885af1af8a07edf4ed34df83ca0d995ed8201283' installers/install-gliclass.sh || fail "model revision pin"; ok
grep -qx 'GL_MODEL_SHA=0943dc2b2ab697915af029e04c2233be2d5c4c16224c7fe833551fdc22b78f69' installers/install-gliclass.sh || fail "model hash"; ok
grep -qx 'OS1_REV=842dcfc4209083f16d7e379cbf071dfa0233fc80' installers/install-gliclass.sh || fail "bench pin"; ok
[[ "$(grep -c '^  "[a-z]*/[a-z-]*\.json [0-9a-f]\{64\}"$' installers/install-gliclass.sh)" == 3 ]] || fail "bench file hashes"; ok
[[ "$(grep -c '^ *fetch "' installers/install-gliclass.sh)" == 4 ]] || fail "every download goes through fetch()"; ok
grep -q -- '--require-hashes --only-binary=:all:' installers/install-gliclass.sh || fail "pip hash mode"; ok

# Telemetry: pinned runtime has none; the switch is set everywhere ORT loads.
grep -q '^onnxruntime==1.28.0 ' lib/gliclass/requirements-runtime.txt || fail "onnxruntime pin"; ok
grep -qx 'export ORT_DISABLE_TELEMETRY=1' installers/install-gliclass.sh || fail "install telemetry switch"; ok
grep -q 'events.data.microsoft.com' installers/install-gliclass.sh || fail "telemetry refusal"; ok
grep -q -- '-E ORT_DISABLE_TELEMETRY=1' installers/bench-gliclass.sh || fail "bench sandbox telemetry switch"; ok
grep -q 'os.environ\["ORT_DISABLE_TELEMETRY"\] = "1"' lib/gliclass/convert.py || fail "convert telemetry switch"; ok
grep -q 'PrivateNetwork=yes' installers/bench-gliclass.sh || fail "bench offline"; ok
# v0.9.67: no apt (it could not reach the Ubuntu mirrors on chiefmonkey.art);
# pip comes from a hash-pinned wheel. Name lookups are checked first.
! grep -q 'apt-get' installers/install-gliclass.sh || fail "installer must not need apt"; ok
grep -q 'venv --without-pip' installers/install-gliclass.sh || fail "venv without pip"; ok
grep -qx 'PIP_SHA=[0-9a-f]\{64\}' installers/install-gliclass.sh || fail "pip wheel hash"; ok
grep -q 'getent ahosts' installers/install-gliclass.sh || fail "DNS precheck"; ok

if [[ $EUID -eq 0 ]]; then
  # Refuses a relative root before touching anything.
  if INSTALL_GLICLASS=1 GLICLASS_ROOT=rel bash installers/install-gliclass.sh >/dev/null 2>&1; then fail "relative root accepted"; fi; ok
  # Remove: refuses a directory that is not an install, removes one that is, re-runs.
  mkdir -p "$t/other"; : > "$t/other/keep"
  if GLICLASS_ROOT="$t/other" bash installers/remove-gliclass.sh >/dev/null 2>&1; then fail "removed a non-install"; fi
  [[ -f "$t/other/keep" ]] || fail "non-install touched"; ok
  mkdir -p "$t/gl/model" "$t/gl/venv"; : > "$t/gl/INSTALLED"; head -c 2097152 /dev/zero > "$t/gl/model/model.onnx"
  out="$(GLICLASS_ROOT="$t/gl" bash installers/remove-gliclass.sh)" || fail "remove: $out"
  [[ ! -e "$t/gl" ]] || fail "install left behind"; [[ "$out" == *"freed about"* ]] || fail "no freed report"; ok
  GLICLASS_ROOT="$t/gl" bash installers/remove-gliclass.sh >/dev/null || fail "second remove"; ok
  if GLICLASS_ROOT=/ bash installers/remove-gliclass.sh >/dev/null 2>&1; then fail "accepted /"; fi; ok
  # Bench refuses when nothing is installed.
  if GLICLASS_ROOT="$t/none" bash installers/bench-gliclass.sh >/dev/null 2>&1; then fail "bench without install"; fi; ok
else
  echo "skip: root-only checks"
fi
echo "install-gliclass: ${pass} passed"
