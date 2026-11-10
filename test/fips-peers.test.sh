#!/usr/bin/env bash
# FIPS peer introductions (torii-continuum docs/adr-fips-default.md §4):
# fips/schnorr.mjs, fips/apply-peer-request.mjs, fips/torii-fips-peers, install wiring.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
has() { grep -qF -- "$1" "$2" && ok "$3" || bad "$3"; }

node --input-type=module <<'JS' && ok "verifier and request checks match nostr-tools fixtures" || bad "verifier and request checks match nostr-tools fixtures"
import { readFileSync } from 'node:fs';
import { verifyNostrEvent, npubToHex, schnorrVerify } from './fips/schnorr.mjs';
import { checkRequest } from './fips/apply-peer-request.mjs';
const F = JSON.parse(readFileSync('test/fixtures/fips-peer-requests.json', 'utf8'));
const fail = (m) => { console.error(m); process.exit(1); };
// BIP-340 official vector 1.
if (!schnorrVerify('6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a',
  '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89', 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659')) fail('bip340');
if (npubToHex(F.adminNpub) !== F.adminHex) fail('npub decode');
if (npubToHex(F.adminNpub.slice(0, -1) + (F.adminNpub.endsWith('q') ? 'p' : 'q')) !== null) fail('npub checksum');
if (!verifyNostrEvent(F.good.event) || verifyNostrEvent(F.tampered.event)) fail('event verify');
const ctx = { adminHex: F.adminHex, now: F.now };
const r = checkRequest(F.good, ctx);
if (r.peers.length !== 2 || r.createdAt !== F.good.event.created_at) fail('good');
if (Object.keys(checkRequest(F.extraFields, ctx).peers[0]).includes('evil')) fail('extra fields kept');
if (checkRequest(F.empty, ctx).peers.length !== 0) fail('empty list removes all');
for (const [name, why] of [['wrongSigner', /admin/], ['wrongKind', /kind/], ['wrongTag', /tag/], ['tampered', /signature/],
  ['nine', /at most 8/], ['old', /time/]]) {
  try { checkRequest(F[name], ctx); fail(`${name} accepted`); } catch (e) { if (!why.test(e.message)) fail(`${name}: ${e.message}`); }
}
try { checkRequest(F.good, { ...ctx, lastAt: F.good.event.created_at }); fail('replay accepted'); } catch (e) { if (!/not newer/.test(e.message)) fail('replay'); }
try { checkRequest(F.good, { ...ctx, adminHex: '' }); fail('no admin accepted'); } catch {}
JS

# End-to-end CLI with a fake fipsctl and temp files.
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
printf '#!/bin/sh\necho fd00::1\n' > "$T/fipsctl"; chmod +x "$T/fipsctl"
node -e 'const F=require("./test/fixtures/fips-peer-requests.json");const fs=require("fs");fs.writeFileSync(process.argv[1]+"/admin.npub",F.adminNpub+"\n");fs.mkdirSync(process.argv[1]+"/req");fs.writeFileSync(process.argv[1]+"/req/peer-request.json",JSON.stringify(F.good));fs.writeFileSync(process.argv[1]+"/bad.json",JSON.stringify(F.badPeer))' "$T"
# The fixtures are signed at 1800000000; run the CLI as of then.
cat > "$T/clock.mjs" <<'JS'
Date.now = () => 1800000010 * 1000;
JS
run() { node --import "$T/clock.mjs" "$ROOT/fips/apply-peer-request.mjs" "$1" "$T/admin.npub" "$T/last" "$T/peers.json" "$T/fips.yaml" "$T/fipsctl"; }
out="$(run "$T/req/peer-request.json" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "peers: 2" ]] && ok "valid request writes peers.json (2 peers)" || bad "valid request writes peers.json ($rc $out)"
[[ "$(stat -c %a "$T/peers.json")" == 644 && "$(stat -c %a "$T/fips.yaml")" == 600 ]] && ok "peers.json 0644, fips.yaml 0600" || bad "file modes"
grep -q '"connect_policy": "auto_connect"' "$T/fips.yaml" && ok "fips.yaml rendered" || bad "fips.yaml rendered"
mv "$T/last.next" "$T/last"
run "$T/req/peer-request.json" >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "same request again: nothing new (exit 3)" || bad "replay exit 3"
rm -f "$T/last"; run "$T/bad.json" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "unsafe peer refused" || bad "unsafe peer refused"
ln -s "$T/req/peer-request.json" "$T/link.json"
err="$(run "$T/link.json" 2>&1)"; [[ $? -eq 1 && "$err" == *refused* ]] && ok "symlinked request refused" || bad "symlinked request refused"
ln -s "$T/req" "$T/reqlink"
err="$(run "$T/reqlink/peer-request.json" 2>&1)"; [[ $? -eq 1 && "$err" == *link* ]] && ok "symlinked directory refused" || bad "symlinked directory refused ($err)"
printf 'root:x:0:0\n' > "$T/req/secret"; err="$(run "$T/req/secret" 2>&1)"
[[ "$err" != *root:x* ]] && ok "refusal never echoes file contents" || bad "refusal echoes contents"

# Helper and install wiring.
bash -n fips/torii-fips-peers && ok "torii-fips-peers parses" || bad "torii-fips-peers parses"
has 'die "run as root"' fips/torii-fips-peers "helper is root only"
has 'O_NOFOLLOW' fips/agent-file.mjs "request opened without following links"
has 'install -m 0755 "$ROOT/fips/torii-fips-peers" /usr/local/sbin/torii-fips-peers' installers/install-fips.sh "installer installs the helper"
has '"$ROOT/fips/schnorr.mjs" "$ROOT/fips/agent-file.mjs" "$ROOT/fips/apply-peer-request.mjs" "$PREFIX/lib/"' installers/install-fips.sh "root runs its own copies, not app code"
has 'systemctl enable -q --now torii-fips-peers.path' installers/install-fips.sh "path unit enabled"
has '"$CONFIG/admin.npub"' installers/install-fips.sh "node admin pinned from CONTINUUM_ADMIN_NPUB"
has 'Type=oneshot' fips/torii-fips-peers.service "apply runs once per change"
! grep -q 'arena-ws' fips/torii-fips-peers && ok "Quest is not restarted (it re-reads peers.json)" || bad "Quest restarted"

echo "fips-peers.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
