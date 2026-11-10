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

node --input-type=module <<'JS' && ok "renderer takes 8 distinct peers, refuses a ninth and duplicates" || bad "renderer takes 8 distinct peers, refuses a ninth and duplicates"
import { renderConfig, MAX_PEERS } from './fips/render-config.mjs';
const B = '023456789acdefghjklmnpqrstuvwxyz';
const peer = i => ({
  transportNpub: 'npub1' + B[i].repeat(58),
  beaconPubkey: String(i).repeat(64).slice(0, 64), ownerPubkey: '2'.repeat(64),
  zoneId: 'world-' + i, website: `https://peer${i}.example/quest/`,
});
const list = n => ({ version: 1, peers: Array.from({ length: n }, (_, i) => peer(i)) });
if (MAX_PEERS !== 8) process.exit(1);
const out = renderConfig(list(8), () => 'fd00::1');
if (out.peers.length !== 8 || out.peers[7].addresses[0].addr !== 'peer7.example:2121') process.exit(2);
if (Buffer.byteLength(JSON.stringify(list(8))) > 8192) process.exit(3);
const throws = f => { try { f(); return false; } catch { return true; } };
if (!throws(() => renderConfig(list(9), () => 'fd00::1'))) process.exit(4);
const dup = list(2); dup.peers[1].transportNpub = dup.peers[0].transportNpub;
if (!throws(() => renderConfig(dup, () => 'fd00::1'))) process.exit(5);
JS

echo "install-fips.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
