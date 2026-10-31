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
grep -qi '^strict-transport-security:' "$W/h" && grep -qi '^x-frame-options: DENY' "$W/h" && ok "HSTS and framing headers" || fail "headers"
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
echo "teams-app-live.sh: $pass passed"
