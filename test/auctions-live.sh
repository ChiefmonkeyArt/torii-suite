#!/usr/bin/env bash
# Live install of Plebeian Auctions against real nginx with a self-signed cert.
# Root only, throwaway hosts. Needs the real release tarball (bundled mint and
# validators), so it is not run in public CI:
#   sudo bash test/auctions-live.sh <plebeian-auctions-vX.Y.Z.tar.gz> [e2e.mjs]
# With systemd as PID 1 the installer starts the units; without it (containers)
# this script runs the units' commands itself, as root.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $EUID -eq 0 ]] || { echo "run as root on a throwaway host" >&2; exit 1; }
TARBALL="${1:?usage: auctions-live.sh <tarball> [e2e.mjs]}"; E2E="${2:-}"
D=example.test; H="auctions.$D"; W="$(mktemp -d)"
pass=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
fail(){ echo "  FAIL $1" >&2; exit 1; }
TAG="$(tar -xzOf "$TARBALL" ./MANIFEST.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')"
SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
SYSTEMD=0; [[ "$(ps -o comm= -p 1)" == systemd ]] && SYSTEMD=1
PIDS=()
cleanup(){ for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf -- "$W"; }
trap cleanup EXIT

rm -f /tmp/torii-register.log
if [[ ! -x /usr/local/bin/torii ]]; then
  cat > /usr/local/bin/torii <<'STUB'
#!/usr/bin/env bash
# test stub for the torii-base sidecar CLI
case "$1" in
  register) echo "$*" >> /tmp/torii-register.log ;;
  reload) nginx -t -q && { nginx -s reload 2>/dev/null || nginx; } ;;
esac
STUB
  chmod 0755 /usr/local/bin/torii
fi
pgrep -x nginx >/dev/null || nginx
if [[ "$SYSTEMD" == 0 ]]; then
  # No systemd: make systemctl reload nginx work for the installer.
  mkdir -p "$W/bin"; printf '#!/bin/sh\n[ "$1" = reload ] && exec nginx -s reload\nexit 0\n' > "$W/bin/systemctl"; chmod +x "$W/bin/systemctl"
  export PATH="$W/bin:$PATH"
fi
C=/etc/letsencrypt/live/$H
if [[ ! -f $C/fullchain.pem ]]; then
  mkdir -p "$C"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$H" \
    -keyout "$C/privkey.pem" -out "$C/fullchain.pem" >/dev/null 2>&1
fi
run(){ env INSTALL_AUCTIONS=1 TORII_DOMAIN=$D SKIP_CERTBOT=1 SKIP_SYSTEMD=$((1 - SYSTEMD)) AUCTIONS_TAG="$TAG" \
  AUCTIONS_SHA256="$1" AUCTIONS_TARBALL="$TARBALL" "${@:2}" bash "$ROOT/installers/install-auctions.sh"; }

run 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1 && fail "accepted a wrong checksum" || ok "refuses a wrong checksum"
run "$SHA" >/dev/null && ok "installs"
start_services(){
  [[ "$SYSTEMD" == 1 ]] && return 0
  local u
  for u in plebeian-auctions-mint plebeian-auctions; do
    mkdir -p "/var/lib/$u"
  done
  ( set -a; . /etc/torii/auctions/mint.env; set +a; cd /var/lib/plebeian-auctions-mint
    HOME=/var/lib/plebeian-auctions-mint exec /apps/plebeian-auctions/current/runtime/python/bin/python3 -m cashu.mint ) > "$W/mint.log" 2>&1 &
  PIDS+=($!)
  local pre start
  while IFS= read -r pre; do (cd /var/lib/plebeian-auctions && eval "${pre//\$\$/\$}") || fail "ExecStartPre: $pre"; done \
    < <(sed -n 's/^ExecStartPre=//p' /etc/systemd/system/plebeian-auctions.service)
  start="$(sed -n 's/^ExecStart=//p' /etc/systemd/system/plebeian-auctions.service)"
  (cd /var/lib/plebeian-auctions && exec $start) > "$W/gw.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 40); do curl -fsS -o /dev/null http://127.0.0.1:8795/api/network && return 0; sleep 1; done
  fail "gateway did not come up"
}
start_services
get(){ curl -sk --resolve "$H:443:127.0.0.1" -D "$W/h" -o "$W/b" -w '%{http_code}' "$@"; }

[[ ! -s /tmp/torii-register.log ]] && ok "no launcher card (never registered with the sidecar)" || fail "registered a launcher tile"
[[ -z "$(find /opt/torii/nginx-fragments -iname '*auction*' 2>/dev/null)" ]] && ok "no main-domain fragment" || fail "wrote a main-domain fragment"
[[ "$(get "https://$H/")" == 200 ]] && grep -q 'Plebeian Auctions' "$W/b" && ok "app served on its own host" || fail "index"
grep -qi "^content-security-policy: default-src 'self'; script-src 'self' 'sha256-" "$W/h" && grep -qi "connect-src 'self';" "$W/h" \
  && ok "CSP: inline script hashed, own origin only" || fail "CSP"
grep -qi '^x-robots-tag: noindex' "$W/h" && grep -qi '^strict-transport-security:' "$W/h" && grep -qi '^x-frame-options: DENY' "$W/h" \
  && ok "noindex, HSTS, no framing" || fail "headers"
[[ "$(get "https://$H/robots.txt")" == 200 ]] && grep -q 'Disallow: /' "$W/b" && ok "robots.txt disallows all" || fail "robots"
js="$(grep -o 'assets/index-[A-Za-z0-9_-]*\.js' "$ROOT/../plebeian-arena-auctions/web/dist/index.html" 2>/dev/null || true)"
[[ -n "$js" ]] || js="$(get "https://$H/" >/dev/null; grep -o 'assets/index-[A-Za-z0-9_-]*\.js' "$W/b" | head -1)"
[[ "$(get -H 'Accept-Encoding: gzip' "https://$H/$js")" == 200 ]] && grep -qi '^content-encoding: gzip' "$W/h" \
  && grep -qi '^cache-control: public, max-age=31536000, immutable' "$W/h" && ok "bundle gzipped and immutable" || fail "assets"
[[ "$(get "https://$H/api/network")" == 200 ]] && python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert len(v)==4' "$W/b" \
  && ok "four validators answer through nginx" || fail "api"
[[ "$(get "https://$H/mint/v1/info")" == 200 ]] && grep -q 'Nutshell' "$W/b" && ok "fake-sats mint answers through nginx" || fail "mint"
[[ "$(get -X PUT "https://$H/api/network")" == 405 ]] && [[ "$(get -X POST "https://$H/")" == 405 ]] && ok "only GET/HEAD, and POST to the API" || fail "methods"
for p in 8795 13338 26656 26657 7101; do
  ss -Htln | awk '{print $4}' | grep -qE "^(127\.0\.0\.1|\[::1\]):$p$" || fail "port $p not loopback-only"
done; ok "gateway, mint and validators bind loopback only"
K1="$(sed -n 's/^MINT_PRIVATE_KEY=//p' /etc/torii/auctions/mint.env)"
[[ "$(stat -c %a /etc/torii/auctions/mint.env)" == 600 ]] && ok "mint settings 0600" || fail "mint.env mode"

if [[ -n "$E2E" ]]; then
  grep -q "$H" /etc/hosts || echo "127.0.0.1 $H" >> /etc/hosts
  NODE_TLS_REJECT_UNAUTHORIZED=0 node "$E2E" "https://$H" > "$W/e2e.log" 2>&1 || { tail -20 "$W/e2e.log"; fail "acceptance suite"; }
  ok "acceptance suite through nginx: $(grep -o 'RESULT: .*' "$W/e2e.log")"
fi

for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; PIDS=(); sleep 3
run "$SHA" >/dev/null && [[ "$(sed -n 's/^MINT_PRIVATE_KEY=//p' /etc/torii/auctions/mint.env)" == "$K1" ]] \
  && ok "re-install keeps the mint key" || fail "re-install"
[[ "$(find /apps/plebeian-auctions/releases -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 2 ]] && ok "keeps at most 2 releases" || fail "release pruning"
env AUCTIONS_REMOVE=1 TORII_DOMAIN=$D SKIP_SYSTEMD=$((1 - SYSTEMD)) bash "$ROOT/installers/install-auctions.sh" >/dev/null \
  && [[ ! -e /etc/nginx/sites-enabled/$H.conf ]] && [[ -f /etc/torii/auctions/mint.env ]] && ok "remove: vhost gone, settings kept" || fail "remove"
echo "auctions-live: ${pass} passed"
