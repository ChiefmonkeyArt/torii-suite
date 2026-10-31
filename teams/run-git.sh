#!/bin/bash
# torii-teams-git: private ngit-grasp, bound to the node's FIPS mesh address
# only. "--check" is the unit's ExecCondition: skip (not fail) until FIPS and
# at least one member exist.
set -euo pipefail
MEMBERS_FILE="${TEAMS_MEMBERS_FILE:-/etc/torii/teams/git-members}"
members="$(grep -E '^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$' "$MEMBERS_FILE" 2>/dev/null | sort -u | paste -sd, || true)"
if [[ "${1:-}" == --check ]]; then
  [[ "${MESH_IP:-}" =~ ^fd[0-9a-f:]+$ && -n "$members" ]]; exit
fi
[[ "${MESH_IP:-}" =~ ^fd[0-9a-f:]+$ ]] || { echo "no FIPS mesh address" >&2; exit 1; }
[[ -n "$members" ]] || { echo "no git members in $MEMBERS_FILE" >&2; exit 1; }
origin="${GIT_HOST:?}.fips:${GIT_PORT:?}"
# Not <npub>.fips: ngit truncates any URL at its first "npub1".
export NGIT_DOMAIN="$origin" NGIT_BIND_ADDRESS="[${MESH_IP}]:${GIT_PORT}"
export NGIT_PRIVATE_MODE=true NGIT_PRIVATE_MEMBERS="$members"
# The mesh is already encrypted end to end; declare the plain-http origin.
export NGIT_PRIVATE_PUBLIC_ORIGIN="http://${origin}"
export NGIT_USER_INDEX_RELAYS="ws://127.0.0.1:${RELAY_PORT:?}"
export NGIT_RELAY_DATA_PATH="${STATE_DIRECTORY:?}/relay" NGIT_GIT_DATA_PATH="${STATE_DIRECTORY}/git"
export NGIT_RELAY_NAME="Torii Teams" NGIT_LOG_LEVEL=info
exec /opt/torii/teams/bin/ngit-grasp
