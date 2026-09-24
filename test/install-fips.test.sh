#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
I="$ROOT/installers/install-fips.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
has(){ grep -qF "$1" "$2" && ok "$3" || bad "$3"; }

bash -n "$I" && ok "installer parses" || bad "installer parses"
has 'INSTALL_FIPS:-1' "$I" "FIPS is a default build component with operator opt-out"
has 'sha256sum --check --status' "$I" "release package is pinned by checksum"
has 'dpkg-deb -x' "$I" "package scripts and global DNS changes are not executed"
has 'FREE_KB >= 262144' "$I" "installer requires bounded disk headroom"
has 'peers":[]' "$I" "fresh node starts without an automatic peer"
has 'systemctl restart torii-fips.service' "$I" "daemon is supervised"
has 'QUEST_FIPS_PEERS_PATH=/etc/torii/fips/peers.json' "$ROOT/installers/install-quest.sh" \
  "Quest reads the same root-owned pin set"
has 'location = /mp/node-presence' "$ROOT/installers/install-quest.sh" \
  "presence snapshot has a same-origin route"

for u in "$ROOT"/fips/*.service; do
  systemd-analyze verify "$u" >/dev/null 2>&1 && ok "$(basename "$u") verifies" || bad "$(basename "$u") verifies"
done
has 'iifname != "fips0" return' "$ROOT/fips/mesh.nft" "firewall leaves non-FIPS traffic unchanged"
has 'tcp dport 7778 accept' "$ROOT/fips/mesh.nft" "only relay port is admitted inbound"
has 'counter drop' "$ROOT/fips/mesh.nft" "all other inbound mesh traffic is dropped"
has 'iifname "fips0" drop' "$ROOT/fips/mesh.nft" "mesh forwarding is blocked"

node --input-type=module <<'JS' && ok "renderer rejects unsafe introductions" || bad "renderer rejects unsafe introductions"
import { renderConfig } from './fips/render-config.mjs';
const base = { version: 1, peers: [{
  transportNpub: 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
  beaconPubkey: '1'.repeat(64), ownerPubkey: '2'.repeat(64),
  zoneId: 'torii-quest', website: 'https://localhost/',
}] };
let rejected = false;
try { renderConfig(base, () => 'fd00::1'); } catch { rejected = true; }
if (!rejected) process.exit(1);
JS

echo "install-fips.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
