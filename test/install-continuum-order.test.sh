#!/usr/bin/env bash
# Static ordering tests for installers/install-continuum.sh (audit SB-05/SB-06).
#
# The installer is the live deploy path; a full functional test would need
# npm ci + git clone + systemd + root. These assertions pin the load-bearing
# ORDERING the two findings fix, so a future edit can't silently reorder the
# promote back in front of the backend restart.
#
# Run:  bash test/install-continuum-order.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
INST="${REPO_ROOT}/installers/install-continuum.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

[[ -f "$INST" ]] || { bad "missing $INST"; exit 1; }
bash -n "$INST" && ok "installer parses cleanly" || bad "installer failed bash -n"

line_of() { grep -nE "$1" "$INST" | head -1 | cut -d: -f1; }

# ── SB-06: frontend promote must come AFTER the agent restart ────────────────
agent_restart="$(line_of 'systemctl restart continuum-agent\.service')"
promote="$(line_of 'Promote the frontend \(deferred from above')"
flip="$(grep -nF 'mv -Tf "$WWW_DEST' "$INST" | head -1 | cut -d: -f1)"
[[ -n "$agent_restart" && -n "$promote" && "$promote" -gt "$agent_restart" ]] \
  && ok "frontend promote happens after continuum-agent restart (agent=$agent_restart promote=$promote)" \
  || bad "promote not after agent restart (agent=$agent_restart promote=$promote)"
[[ -n "$flip" && "$flip" -gt "$agent_restart" ]] \
  && ok "current symlink flip happens after agent restart (flip=$flip)" \
  || bad "current flip not after agent restart (flip=$flip)"

# The build must still produce dist before the (deferred) promote copies it.
build="$(line_of 'npm run build')"
[[ -n "$build" && "$build" -lt "$promote" ]] \
  && ok "frontend build happens before the deferred promote" \
  || bad "build/promote order wrong (build=$build promote=$promote)"

# ── SB-05: nap-bridge restarted alongside the agent, conditionally ────────────
npbridge="$(line_of 'systemctl restart torii-nap-bridge\.service')"
[[ -n "$npbridge" && "$npbridge" -gt "$agent_restart" && "$npbridge" -lt "$promote" ]] \
  && ok "nap-bridge restart sits after agent restart, before promote" \
  || bad "nap-bridge restart misplaced (agent=$agent_restart np=$npbridge promote=$promote)"
grep -qF 'systemctl is-active --quiet torii-nap-bridge.service' "$INST" \
  && ok "nap-bridge restart is conditional (only when the voice is active)" \
  || bad "nap-bridge restart not conditional on is-active"

# nap-bridge failure must warn, not die (public voice is optional).
if awk '/SB-05:/,/torii-nap-bridge not active/' "$INST" | grep -qF 'warn "torii-nap-bridge'; then
  ok "nap-bridge post-restart failure is a warn, not a die"
else
  bad "nap-bridge failure path missing its warn"
fi

printf '\n[install-continuum-order.test] pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1