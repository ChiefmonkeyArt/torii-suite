#!/usr/bin/env bash
# Static SB-13 assertions for bootstrap.sh: the two "opt-out" bugs the audit
# found — TORII_RELAY_HOST restoring its default when explicitly set empty, and
# the Ollama RAM guard reading OLLAMA_MODE before its fallback. The fixes are
# `${var-default}` (empty honoured as the documented opt-out) and
# `${OLLAMA_MODE:-local}` self-contained inside the RAM guard.
#
# Run:  bash test/bootstrap-sb13.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
BOOT="${REPO_ROOT}/bootstrap.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

[[ -f "$BOOT" ]] || { bad "missing $BOOT"; exit 1; }
bash -n "$BOOT" && ok "bootstrap.sh parses cleanly" || bad "bootstrap.sh failed bash -n"

# ── SB-13 opt-out: TORII_RELAY_HOST empty must be honoured, not defaulted ────
# No-colon `${var-default}` = only unset triggers the default; empty stays empty.
if grep -qF 'TORII_RELAY_HOST="${TORII_RELAY_HOST:-relay.${TORII_DOMAIN}}"' "$BOOT"; then
  bad "TORII_RELAY_HOST still restores its default when set empty (uses :-)"
else
  ok "TORII_RELAY_HOST no longer restores its default when set empty"
fi
grep -qF 'TORII_RELAY_HOST="${TORII_RELAY_HOST-relay.${TORII_DOMAIN}}"' "$BOOT" \
  && ok "TORII_RELAY_HOST honours an explicit empty value (no-colon default)" \
  || bad "TORII_RELAY_HOST is not using the no-colon default form"

# ── SB-13 opt-out: RAM guard self-contains its OLLAMA_MODE default ───────────
grep -qF '[[ "$INSTALL_OLLAMA" == "1" && "${OLLAMA_MODE:-local}" == "local" ]]' "$BOOT" \
  && ok "Ollama RAM guard defaults OLLAMA_MODE to local itself (not read-before-fallback)" \
  || bad "Ollama RAM guard still reads bare \$OLLAMA_MODE before its fallback"

# ── functional: confirm the chosen forms actually behave as intended ─────────
want_empty() { TORII_RELAY_HOST= TORII_DOMAIN=example.com bash -c 'printf "%s" "${TORII_RELAY_HOST-relay.${TORII_DOMAIN}}"'; }
want_default() { TORII_DOMAIN=example.com bash -c 'printf "%s" "${TORII_RELAY_HOST-relay.${TORII_DOMAIN}}"'; }
[[ "$(want_empty)" == "" ]] \
  && ok "empty TORII_RELAY_HOST stays empty (subdomain skipped)" \
  || bad "empty TORII_RELAY_HOST did not stay empty (got '$(want_empty)')"
[[ "$(want_default)" == "relay.example.com" ]] \
  && ok "unset TORII_RELAY_HOST falls back to relay.<domain>" \
  || bad "unset TORII_RELAY_HOST fallback wrong (got '$(want_default)')"

echo
echo "bootstrap-sb13.test.sh: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]