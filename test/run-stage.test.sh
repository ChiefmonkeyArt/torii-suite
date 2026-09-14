#!/usr/bin/env bash
# Hermetic tests for lib/run.sh run_stage (audit SB-07).
#
# SB-07 root cause: run_stage ran the stage on the LEFT side of `||` in a
# subshell, which (a) suppressed errexit inside the stage — an early `false`
# followed by a success reported success — and (b) ran in a subprocess so
# variable assignments did not reach the caller (AUTH_SMOKE_RESULT etc. were
# always left "skipped"). This suite asserts both are fixed without a real
# install, network, or root.
#
# Run:  bash test/run-stage.test.sh   (from repo root)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

# Pin the log to a temp file so sourcing run.sh does not touch /var/log.
TEST_LOG="$(mktemp)"
export SUITE_LOG_FILE="$TEST_LOG"
export NO_COLOR=1

# shellcheck disable=SC1090,SC1091
source "${REPO_ROOT}/lib/ui.sh"
# shellcheck disable=SC1090,SC1091
source "${REPO_ROOT}/lib/run.sh"

# run_stage's failure path calls `exit`; wrap failing runs so we capture the
# exit code without killing this test. `run_stage` returns 0 on success so a
# succeeding stage can be called directly (result import must land here).
run_capture_rc() {
  ( run_stage "$@" ) >/dev/null 2>&1
  echo $?
}

# ── 1. errexit: an early `false` must fail the stage (not report success) ────
SUITE_QUIET=1
_early() { false; echo "EARLY-AFTER-FALSE-SHOULD-NOT-RUN"; }
rc=$(run_capture_rc "early failure" _early)
[[ "$rc" -ne 0 ]] && ok "quiet: early failure exits non-zero ($rc)" || bad "quiet: early failure reported success ($rc)"
grep -qF "EARLY-AFTER-FALSE-SHOULD-NOT-RUN" "$TEST_LOG" \
  && bad "quiet: errexit suppressed — code after false ran" \
  || ok "quiet: errexit honours the first failing command"

# ── 2. intermediate + final failure also fail closed ────────────────────────
_mid() { true; false; echo "MID-AFTER-FALSE"; }
rc=$(run_capture_rc "mid failure" _mid)
[[ "$rc" -ne 0 ]] && ok "quiet: intermediate failure exits non-zero ($rc)" || bad "quiet: intermediate failure masked"

_final() { echo "ran-ok"; false; }
rc=$(run_capture_rc "final failure" _final)
[[ "$rc" -ne 0 ]] && ok "quiet: final-command failure exits non-zero ($rc)" || bad "quiet: final-command failure masked"

# ── 3. assignment/result propagation (the lost AUTH_SMOKE_RESULT bug) ──────
MY_RESULT="unset"
_ok_stage() { stage_result "MY_RESULT=ok"; }
run_stage "result-propagating stage" _ok_stage 2>/dev/null
[[ "$MY_RESULT" == "ok" ]] && ok "quiet: stage result reaches the caller ($MY_RESULT)" || bad "quiet: result lost (got '$MY_RESULT')"

# Multiple keys in one stage.
R1="unset"; R2="unset"
_multi() { stage_result "R1=alpha" "R2=beta=with=equals"; }
run_stage "multi-result stage" _multi 2>/dev/null
[[ "$R1" == "alpha" && "$R2" == "beta=with=equals" ]] \
  && ok "quiet: multiple results (incl. '=' in value) propagate" \
  || bad "quiet: multi-result import wrong (R1='$R1' R2='$R2')"

# ── 4. loud mode (SUITE_QUIET=0) reaches parity ────────────────────────────
SUITE_QUIET=0
_early_loud() { false; echo "LOUD-AFTER-FALSE"; }
rc=$(run_capture_rc "loud early failure" _early_loud)
[[ "$rc" -ne 0 ]] && ok "loud: early failure exits non-zero ($rc)" || bad "loud: early failure masked ($rc)"

LOUD_RESULT="unset"
_loud_ok() { stage_result "LOUD_RESULT=loud-ok"; }
run_stage "loud ok stage" _loud_ok 2>/dev/null
[[ "$LOUD_RESULT" == "loud-ok" ]] && ok "loud: stage result reaches the caller" || bad "loud: result lost (got '$LOUD_RESULT')"

# ── 5. stage_result is a no-op when no channel is open (safety) ────────────
unset SUITE_STAGE_RESULT_FILE
before_pid="$$"
stage_result "NOPE=1" 2>/dev/null
[[ -z "${NOPE:-}" ]] && ok "stage_result without a channel is a safe no-op" || bad "stage_result wrote with no channel"

rm -f "$TEST_LOG"

printf '\n[run-stage.test] pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1