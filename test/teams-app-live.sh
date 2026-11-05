#!/usr/bin/env bash
# Live install of the Teams app against real nginx with a self-signed cert.
# Root only, throwaway hosts (CI: .github/workflows/teams-app.yml).
#   sudo bash test/teams-app-live.sh [artifact.tar.gz]   (default: a small fake build)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $EUID -eq 0 ]] || { echo "run as root on a throwaway host" >&2; exit 1; }
D=example.test; H="teams.$D"; W="$(mktemp -d)"; trap 'rm -rf -- "$W"' EXIT
pass=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
fail(){ echo "  FAIL $1" >&2; exit 1; }

TAG=0.6.1-torii.0
if [[ -n "${1:-}" ]]; then
  TARBALL="$1"
  TAG="$(tar -xzOf "$TARBALL" ./MANIFEST.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')"
else
  mkdir -p "$W/a/_app/immutable" "$W/a/.well-known"
  printf '<!doctype html><html><head><script>window.__boot=1</script></head><body>app</body></html>' > "$W/a/index.html"
  echo 'console.log(1)' > "$W/a/_app/immutable/app.js"
  echo '{"names":{"cordn":"x"}}' > "$W/a/.well-known/nostr.json"
  printf '{"app":"torii-teams","tag":"%s","version":"0.6.1","commit":"0000000"}\n' "$TAG" > "$W/a/MANIFEST.json"
  tar -C "$W/a" -czf "$W/app.tgz" .
  TARBALL="$W/app.tgz"
fi
SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"

install -d -m 0755 /etc/torii/teams
[[ -s /etc/torii/teams/coord.pub ]] || printf '%064x\n' 1 > /etc/torii/teams/coord.pub
PK="$(tr -d '[:space:]' < /etc/torii/teams/coord.pub)"
if [[ ! -x /usr/local/bin/torii ]]; then
  cat > /usr/local/bin/torii <<'STUB'
#!/usr/bin/env bash
# test stub for the torii-base sidecar CLI
case "$1" in
  register) [[ -f "/opt/torii/nginx-fragments/$2.conf" ]] || { echo missing_fragment >&2; exit 1; }; echo "$*" >> /tmp/torii-register.log ;;
  reload) nginx -t -q && { nginx -s reload 2>/dev/null || nginx; } ;;
esac
STUB
  chmod 0755 /usr/local/bin/torii
fi
C=/etc/letsencrypt/live/$H
if [[ ! -f $C/fullchain.pem ]]; then
  mkdir -p "$C"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$H" \
    -keyout "$C/privkey.pem" -out "$C/fullchain.pem" >/dev/null 2>&1
fi

run(){ env INSTALL_TEAMS_APP=1 TORII_DOMAIN=$D SKIP_CERTBOT=1 TEAMS_APP_TAG="$TAG" \
  TEAMS_APP_SHA256="$1" TEAMS_APP_TARBALL="$TARBALL" bash "$ROOT/installers/install-teams-app.sh"; }
run "$SHA" >/dev/null && ok "installs"
get(){ curl -sk --resolve "$H:443:127.0.0.1" -D "$W/h" -o "$W/b" -w '%{http_code}' "$@"; }

[[ "$(get "https://$H/chat")" == 200 ]] && grep -q '<html' "$W/b" && ok "SPA route serves index.html" || fail "SPA route"
grep -qi "^content-security-policy: default-src 'self'; script-src 'self' 'sha256-" "$W/h" && ok "CSP with script hash" || fail "CSP"
grep -qi '^strict-transport-security:' "$W/h" && ! grep -qi '^x-frame-options:' "$W/h" && grep -qi "frame-ancestors 'none'" "$W/h" && ok "HSTS; framing only via frame-ancestors (none without Continuum)" || fail "headers"
[[ "$(get "https://$H/torii-node.json")" == 200 ]] || fail "node file status"
grep -qi '^content-type: application/json' "$W/h" && grep -qi '^cache-control: no-store' "$W/h" && ok "node file is JSON, no-store" || fail "node file headers"
python3 - "$W/b" "$PK" <<'PY' && ok "node file carries the coordinator and wss relay" || fail "node file body"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == 1 and d["coordinator"] == sys.argv[2] and d["relays"] == ["wss://relay.example.test"], d
PY
grep -qi '^content-security-policy:' "$W/h" && ok "headers kept in nested locations" || fail "node file lost headers"
[[ "$(get "https://$H/.well-known/nostr.json")" == 404 ]] && ok "no upstream NIP-05 file" || fail ".well-known served"
[[ "$(get -X POST "https://$H/chat")" == 405 ]] && ok "only GET and HEAD" || fail "POST allowed"
[[ "$(get "https://$H/_app/immutable/missing.js")" == 404 ]] && ok "missing assets are 404, not the shell" || fail "asset fallback"
[[ "$(stat -c '%a %U' /etc/torii/teams/torii-node.json)" == "644 root" ]] && ok "node file 0644 root" || fail "node file mode"
[[ ! -e /apps/teams-app/current/torii-node.json ]] && ok "node file is outside the release" || fail "node file in release"
grep -q 'return 302 https://teams.example.test/chat' /opt/torii/nginx-fragments/teams.conf && ok "launcher tile redirects" || fail "fragment"

sleep 1; run "$SHA" >/dev/null && ok "rerun is idempotent"
live="$(readlink /apps/teams-app/current)"
if run "$(printf '%064d' 0)" >/dev/null 2>&1; then fail "accepted a wrong checksum"; fi
[[ "$(readlink /apps/teams-app/current)" == "$live" ]] && ok "wrong checksum refused, live app untouched" || fail "current changed"
mv /etc/torii/teams/coord.pub "$W/coord.pub"
if run "$SHA" >/dev/null 2>&1; then mv "$W/coord.pub" /etc/torii/teams/coord.pub; fail "installed without coord.pub"; fi
mv "$W/coord.pub" /etc/torii/teams/coord.pub
ok "fails closed without coord.pub"

# ── With Continuum: the node file server (torii-teams ADR 0007) ──
command -v node >/dev/null || fail "node is needed for the file server phase"
CC=/apps/continuum/agent/repo/agent/config.yaml CU=/etc/systemd/system/continuum-agent.service
FAKE_UNIT=0; [[ -e "$CU" ]] || { : > "$CU"; FAKE_UNIT=1; }
mkdir -p "$(dirname "$CC")"; FAKE_CC=0; [[ -e "$CC" ]] || { printf 'server:\n  port: 18787\n  cors_origins:\n    - "https://x.example"\n' > "$CC"; FAKE_CC=1; }
cat > "$W/continuum.mjs" <<'JS'
import { createServer } from 'node:http';
createServer((req, res) => {
  const ok = req.url === '/api/team/files-ok' && req.headers.authorization === 'Bearer member-token-1';
  res.writeHead(ok ? 200 : 401, { 'content-type': 'application/json' });
  res.end(ok ? JSON.stringify({ ok: true, pubkey: 'ab'.repeat(32), owner: false }) : '{}');
}).listen(18787, '127.0.0.1');
JS
node "$W/continuum.mjs" & FAKE_PID=$!
SYSD=0; systemctl is-system-running >/dev/null 2>&1 || [[ "$(systemctl is-system-running 2>/dev/null)" == degraded ]] && SYSD=1
cleanup_files(){
  kill "$FAKE_PID" 2>/dev/null || true; [[ -n "${FS_PID:-}" ]] && kill "$FS_PID" 2>/dev/null || true
  (( SYSD == 1 )) && systemctl disable --now torii-teams-files.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/torii-teams-files.service
  (( FAKE_UNIT == 1 )) && rm -f "$CU"; (( FAKE_CC == 1 )) && rm -f "$CC"; rm -rf -- "$W"
}
trap cleanup_files EXIT
env INSTALL_TEAMS_APP=1 TORII_DOMAIN=$D SKIP_CERTBOT=1 SKIP_SYSTEMD=1 TEAMS_APP_TAG="$TAG" TEAMS_APP_SHA256="$SHA" \
  TEAMS_APP_TARBALL="$TARBALL" TEAMS_FILES_MAX_MB=1 bash "$ROOT/installers/install-teams-app.sh" >/dev/null && ok "installs with Continuum and the file server"
grep -q '^TEAMS_FILES_CONTINUUM=http://127.0.0.1:18787$' /etc/torii/teams/files.env && ok "file server asks Continuum on its own port" || fail "files.env"
if (( SYSD == 1 )); then
  systemctl daemon-reload && systemctl restart torii-teams-files.service && ok "file server runs under systemd (DynamicUser)"
else
  mkdir -p "$W/files"; (set -a; . /etc/torii/teams/files.env; TEAMS_FILES_DIR="$W/files" exec node /opt/torii/teams-files/server.mjs) & FS_PID=$!
  ok "file server started directly (no systemd here)"
fi
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:8805/x" && break; sleep 0.1; done
[[ "$(get "https://$H/torii-node.json")" == 200 ]] && grep -q '"files":"https://teams.example.test/files"' "$W/b" && ok "node file names the file server" || fail "node file files"
get "https://$H/chat" >/dev/null
grep -qi "connect-src 'self' blob: https://$D wss://relay.$D;" "$W/h" && grep -qi "img-src 'self' data: blob:;" "$W/h" && ok "CSP: only this node's hosts" || fail "node CSP"
printf 'sealed-bytes' > "$W/blob"; BS="$(sha256sum "$W/blob" | cut -d' ' -f1)"
[[ "$(get -X PUT --data-binary @"$W/blob" "https://$H/files/upload")" == 401 ]] && ok "upload without a session is refused" || fail "anonymous upload"
[[ "$(get -X PUT -H 'Authorization: Bearer member-token-1' -H "X-SHA-256: $BS" --data-binary @"$W/blob" "https://$H/files/upload")" == 201 ]] \
  && grep -q "\"url\":\"https://teams.example.test/files/$BS\"" "$W/b" && ok "member upload returns the node URL" || fail "member upload ($(cat "$W/b"))"
[[ "$(get "https://$H/files/$BS")" == 200 ]] && cmp -s "$W/b" "$W/blob" && grep -qi '^content-type: application/octet-stream' "$W/h" \
  && grep -qi "^content-security-policy: default-src 'none'; sandbox" "$W/h" && ok "blob served as inert bytes" || fail "blob read"
head -c 1100000 /dev/zero > "$W/big"
[[ "$(get -X PUT -H 'Authorization: Bearer member-token-1' --data-binary @"$W/big" "https://$H/files/upload")" == 413 ]] && ok "size cap enforced" || fail "size cap"
[[ "$(get -X POST "https://$H/files/upload")" == 405 && "$(get -X PUT "https://$H/chat")" == 405 ]] && ok "no other write methods" || fail "methods"
[[ "$(get -X DELETE -H 'Authorization: Bearer member-token-1' "https://$H/files/$BS")" == 200 ]] && [[ "$(get "https://$H/files/$BS")" == 404 ]] && ok "uploader can delete" || fail "delete"
echo "teams-app-live.sh: $pass passed"
