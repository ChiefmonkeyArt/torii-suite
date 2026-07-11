#!/usr/bin/env bash
# torii-suite/installers/set-admin-npub.sh
#
# Rotate the Continuum agent's admin_npub. The npub is the whole identity:
# after this runs, only the new npub can sign in. The old one is dead to us.
#
# When to run this:
#   - Migrating to a new hardware Nostr signer.
#   - Losing access to the old signer for any reason (device wipe, key
#     compromise, revoked bunker delegation).
#   - Transferring the server to a new operator.
#
# What it does NOT do:
#   - Rotate session_secret. Any tokens the OLD npub already holds remain
#     valid until they expire. Run rotate-session-secret.sh right after
#     this if you want to kill those too. (Recommended for compromise.)
#   - Delete stored NIP-44 data. Data was encrypted TO the old npub; the
#     new npub can't decrypt it. It remains readable only if you can still
#     produce old-npub signatures. Restore-from-backup is your problem.
#   - Break the install. Atomic write, verified restart, rollback on failure.
#
# Usage (on the VPS):
#   sudo bash /opt/torii-suite/installers/set-admin-npub.sh npub1abc...
#   NEW_ADMIN_NPUB=npub1abc... sudo -E bash /opt/torii-suite/installers/set-admin-npub.sh
#
# Exit codes:
#   0 - rotated, agent restarted, health check green
#   1 - preflight failed (bad npub, missing tools, missing config)
#   2 - config write failed, no change made
#   3 - config written but agent failed to come back up; ORIGINAL RESTORED

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/home/continuum/agent/config.yaml}"
AGENT_UNIT="${AGENT_UNIT:-continuum-agent.service}"
AGENT_PORT="${CONTINUUM_AGENT_PORT:-8787}"

log()  { printf "\033[36m--\033[0m  %s\n" "$*"; }
warn() { printf "\033[33m--\033[0m  %s\n" "$*" >&2; }
die()  { printf "\033[31mxx\033[0m  %s\n" "$*" >&2; exit "${2:-1}"; }

[[ $EUID -eq 0 ]] || die "set-admin-npub must run as root (try: sudo bash $0 npub1...)"

# ── Argument / env resolution ───────────────────────────────────────────────
NEW_NPUB="${1:-${NEW_ADMIN_NPUB:-}}"
NEW_NPUB="${NEW_NPUB## }"; NEW_NPUB="${NEW_NPUB%% }"   # strip stray whitespace
if [[ -z "$NEW_NPUB" ]]; then
  die "usage: sudo bash $0 npub1abc...  (or set NEW_ADMIN_NPUB and pass -E)" 1
fi

# bech32 npub: literal 'npub1' prefix, then exactly 58 chars from the bech32 alphabet.
# We check the shape here; the agent will do the full NIP-19 decode on next boot.
if [[ ! "$NEW_NPUB" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]]; then
  die "argument does not look like a bech32 npub (expected 'npub1' + 58 lowercase chars)" 1
fi

# ── Preflight ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "config not found at $CONFIG_FILE  (is Continuum installed?)"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found - can't restart the agent"
grep -qE '^\s*admin_npub:' "$CONFIG_FILE" \
  || die "admin_npub key missing from $CONFIG_FILE - refusing to run" 1

CURRENT="$(grep -E '^\s*admin_npub:' "$CONFIG_FILE" | head -1 | sed -E 's|^\s*admin_npub:\s*"?([^"]*)"?\s*$|\1|')"
if [[ "$CURRENT" == "$NEW_NPUB" ]]; then
  log "admin_npub already set to ${NEW_NPUB} - nothing to do"
  exit 0
fi
log "rotating admin_npub"
log "  from  ${CURRENT}"
log "  to    ${NEW_NPUB}"

# ── Atomic write ────────────────────────────────────────────────────────────
STAT_OWNER="$(stat -c '%U:%G' "$CONFIG_FILE" 2>/dev/null || echo 'continuum:continuum')"
STAT_MODE="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '600')"

BACKUP="${CONFIG_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$CONFIG_FILE" "$BACKUP" || die "backup to $BACKUP failed" 2
log "backup saved to $BACKUP"

TMP="${CONFIG_FILE}.setnpub.$$"
sed -e "s|^\(\s*admin_npub:\).*|\1 \"${NEW_NPUB}\"|" "$CONFIG_FILE" > "$TMP" || {
  rm -f "$TMP"
  die "sed rewrite failed - config unchanged" 2
}
if ! grep -qE "^\s*admin_npub:[[:space:]]*\"${NEW_NPUB}\"\s*$" "$TMP"; then
  rm -f "$TMP"
  die "admin_npub substitution missed the target line - config unchanged" 2
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
log "done. only ${NEW_NPUB} can sign in from now on."
log "any tokens the old npub already holds remain valid until expiry."
log "run rotate-session-secret.sh right now if you want to kill those too."
log "backup kept at $BACKUP"
