#!/usr/bin/env bash
# One status line for the FIPS node (Suite ADR 0001). Never prints mesh
# addresses, keys or hostnames: deploy logs end up on GitHub. Never fatal.
set -uo pipefail
PEERS="${FIPS_PEERS_FILE:-/etc/torii/fips/peers.json}"
BIN="${FIPS_BIN:-/opt/torii/fips/bin/fips}"
SYSTEMCTL="${FIPS_SYSTEMCTL:-systemctl}"
if [[ ! -x "$BIN" ]]; then
  echo "FIPS: not installed"
  exit 0
fi
count=0
if [[ -f "$PEERS" && ! -L "$PEERS" ]]; then
  count="$(node -e 'try{const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).peers;console.log(Array.isArray(p)?p.length:0)}catch{console.log(0)}' "$PEERS" 2>/dev/null || echo 0)"
fi
[[ "$count" =~ ^[0-9]+$ ]] || count=0
peers="$count peers"; [[ "$count" == 1 ]] && peers="1 peer"
if "$SYSTEMCTL" is-active --quiet torii-fips.service; then
  echo "FIPS: running, $peers"
else
  echo "FIPS: not running, $peers"
fi
