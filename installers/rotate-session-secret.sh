#!/usr/bin/env bash
# torii-suite/installers/rotate-session-secret.sh
#
# Rotate the Continuum agent's session_secret. Every session token issued
# under the old secret becomes invalid the instant the agent restarts.
#
# When to run this:
#   - Laptop lost or stolen. Revoke every open session, everywhere, now.
#   - Suspicion the agent host was reached by anyone but you.
#   - Routine hygiene, quarterly or after any admin_npub change.
#
# What it does NOT do:
#   - Touch admin_npub. Login identity stays the same.
#   - Delete stored NIP-44 encrypted data. The RAM cache resets on restart
#     but the ciphertext on disk is unchanged; next login re-unlocks it.
#   - Break the install. Config write is atomic (tmp + mv), agent restart
#     is verified, we roll back on failure.
#
# Usage (on the VPS):
#   sudo bash /opt/torii-suite/installers/rotate-session-secret.sh
#
# Exit codes:
#   0 - rotated, agent restarted, health check green
#   1 - preflight failed
#   2 - config write failed, no change made
#   3 - config written but agent failed to come back up; ORIGINAL RESTORED

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/home/continuum/agent/config.yaml}"
AGENT_UNIT="${AGENT_UNIT:-continuum-agent.service}"
AGENT_PORT="${CONTINUUM_AGENT_PORT:-8787}"

log()  { printf "\033[36m--\033[0m  %s\n" "$*"; }
warn() { printf "\033[33m--\033[0m  %s\n" "$*" >&2; }
die()  { printf "\033[31mxx\033[0m  %s\n" "$*" >&2; exit "${2:-1}"; }

[[ $EUID -eq 0 ]] || die "rotate-session-secret must run as root (try: sudo bash $0)"

# ── Preflight ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "config not found at $CONFIG_FILE  (is Continuum installed?)"
command -v node >/dev/null 2>&1 || die "node not found - session_secret generation needs it"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found - can't restart the agent"
grep -qE '^\s*session_secret:' "$CONFIG_FILE" \
  || die "session_secret key missing from $CONFIG_FILE - refusing to run" 1

# ── Generate new secret ─────────────────────────────────────────────────────
NEW_SECRET="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
if [[ ! "$NEW_SECRET" =~ ^[0-9a-f]{64}$ ]]; then
  die "session_secret generation failed: expected 64 hex chars, got ${#NEW_SECRET}" 1
fi
log "generated new 32-byte session_secret"

# ── Atomic write ────────────────────────────────────────────────────────────
# Preserve ownership and mode of the current file.
STAT_OWNER="$(stat -c '%U:%G' "$CONFIG_FILE" 2>/dev/null || echo 'continuum:continuum')"
STAT_MODE="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '600')"

BACKUP="${CONFIG_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$CONFIG_FILE" "$BACKUP" || die "backup to $BACKUP failed" 2
log "backup saved to $BACKUP"

TMP="${CONFIG_FILE}.rotate.$$"
sed -e "s|^\(\s*session_secret:\).*|\1 \"${NEW_SECRET}\"|" "$CONFIG_FILE" > "$TMP" || {
  rm -f "$TMP"
  die "sed rewrite failed - config unchanged" 2
}

# Confirm the substitution landed.
if ! grep -qE "^\s*session_secret:[[:space:]]*\"${NEW_SECRET}\"\s*$" "$TMP"; then
  rm -f "$TMP"
  die "session_secret substitution missed the target line - config unchanged" 2
fi

chown "$STAT_OWNER" "$TMP" || warn "chown $STAT_OWNER on tmp file failed"
chmod "$STAT_MODE" "$TMP"  || warn "chmod $STAT_MODE on tmp file failed"
mv -f "$TMP" "$CONFIG_FILE" || {
  rm -f "$TMP"
  die "atomic mv failed - config unchanged" 2
}
log "config updated at $CONFIG_FILE"

# ── Restart + verify ────────────────────────────────────────────────────────
log "restarting $AGENT_UNIT ..."
if ! systemctl restart "$AGENT_UNIT"; then
  warn "systemctl restart failed - rolling back"
  cp -a "$BACKUP" "$CONFIG_FILE"
  systemctl restart "$AGENT_UNIT" || warn "rollback restart also failed - fix by hand"
  die "agent restart failed. ORIGINAL CONFIG RESTORED from $BACKUP" 3
fi

# Wait for the agent to accept traffic again.
tries=0
until curl -fsS -m 3 "http://127.0.0.1:${AGENT_PORT}/api/health" >/dev/null 2>&1; do
  tries=$(( tries + 1 ))
  if (( tries >= 10 )); then
    warn "agent did not come back on /api/health after 10 tries - rolling back"
    cp -a "$BACKUP" "$CONFIG_FILE"
    systemctl restart "$AGENT_UNIT" || true
    die "agent health check failed after restart. ORIGINAL CONFIG RESTORED from $BACKUP" 3
  fi
  sleep 1
done

log "agent healthy on port ${AGENT_PORT}"
log "done. every prior session token is now invalid."
log "backup kept at $BACKUP  (safe to delete once you have re-logged in)"
