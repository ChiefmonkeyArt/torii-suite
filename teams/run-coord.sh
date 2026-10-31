#!/bin/bash
# torii-teams-coord: Cordn coordinator. Talks only to the node's loopback
# relay; members reach the same relay publicly at wss://relay.<domain>.
set -euo pipefail
key="$(cat "${CREDENTIALS_DIRECTORY:?}/coord.key")"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid coordinator key" >&2; exit 1; }
export CORDN_SERVER_PRIVATE_KEY="$key"
# IPv4 loopback on purpose: cordn-server cannot dial bracketed IPv6 literals.
export CORDN_RELAY_URLS="ws://127.0.0.1:${RELAY_PORT:?}"
export CORDN_STORAGE_BACKEND=sqlite CORDN_SQLITE_PATH="${STATE_DIRECTORY:?}/cordn.sqlite"
export CORDN_SERVER_NAME=torii-teams
unset key
exec /opt/torii/teams/bin/cordn-server
