#!/usr/bin/env bash
# Live nginx run of the Continuum host (Suite v0.9.31): the real fragment from
# install-continuum.sh + lib/continuum-host.sh output, on high ports, no root.
# Needs nginx, openssl, curl, python3. CI: .github/workflows/continuum-host.yml.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/continuum-host.sh
source "$ROOT/lib/continuum-host.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
T="$(mktemp -d)"; PIDS=()
cleanup(){ [[ -f "$T/nginx.pid" ]] && kill "$(cat "$T/nginx.pid")" 2>/dev/null; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf -- "$T"; }
trap cleanup EXIT
APEX=example.org HOST=continuum.example.org TEAMS=teams.example.org PORT=18443

# Real fragment, expanded exactly as the installer does.
mkdir -p "$T"/{apps/continuum/current/assets,frag,snip,cert,logs,api,agent}
body="$(sed -n '/^FRAGMENT_CONTENT="\$(cat <<NGINX$/,/^NGINX$/p' "$ROOT/installers/install-continuum.sh" | sed '1d;$d')"
[[ -n "$body" ]] || { echo "could not extract the fragment" >&2; exit 1; }
APPS_ROOT="$T/apps" CONTINUUM_AGENT_PORT=18788
eval "cat <<NGINX
${body}
NGINX" | sed "s#/opt/torii/nginx-snippets/#$T/snip/#" > "$T/frag/continuum.conf"
cat > "$T/api.conf" <<NGINX
location /api/ { proxy_pass http://127.0.0.1:18787; limit_req zone=torii_api_limit burst=60 nodelay; client_max_body_size 1m; }
NGINX
echo '<!doctype html><title>continuum</title>' > "$T/apps/continuum/current/index.html"
echo 'console.log(1)' > "$T/apps/continuum/current/assets/app-abc.js"
echo api-ok > "$T/api/health"; mkdir -p "$T/api/api" && cp "$T/api/health" "$T/api/api/health"
echo agent-ok > "$T/agent/health"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$HOST" \
  -keyout "$T/cert/privkey.pem" -out "$T/cert/fullchain.pem" >/dev/null 2>&1
(cd "$T/api" && exec python3 -m http.server 18787 --bind 127.0.0.1 >/dev/null 2>&1) & PIDS+=($!)
(cd "$T/agent" && exec python3 -m http.server 18788 --bind 127.0.0.1 >/dev/null 2>&1) & PIDS+=($!)

conf() {
  { cat <<NGINX
worker_processes 1;
pid $T/nginx.pid;
error_log $T/logs/error.log;
events {}
http {
  access_log off;
  client_body_temp_path $T/logs; proxy_temp_path $T/logs; fastcgi_temp_path $T/logs; uwsgi_temp_path $T/logs; scgi_temp_path $T/logs;
  default_type application/octet-stream;
  types { text/html html; application/javascript js; }
  limit_req_zone \$binary_remote_addr zone=torii_api_limit:1m rate=30r/s;
  server {
    listen $PORT ssl; server_name $APEX;
    ssl_certificate $T/cert/fullchain.pem; ssl_certificate_key $T/cert/privkey.pem;
    add_header X-Frame-Options "SAMEORIGIN" always;
    include $T/frag/*.conf;
    include $T/api.conf;
  }
NGINX
    [[ "${1:-}" == host ]] && continuum_host_vhost "$HOST" "$T/cert" "$T/frag/continuum.conf" "$T/api.conf" "$T/snip/continuum-headers.inc" \
      | sed "s/listen 443 ssl http2;/listen $PORT ssl;/; s/listen \[::\]:443 ssl http2;//; s/listen 80;/listen 18080;/; s/listen \[::\]:80;//"
    echo "}"
  } > "$T/nginx.conf"
}

# Before the host install: the empty glob must not break nginx.
conf
nginx -t -p "$T" -c "$T/nginx.conf" >/dev/null 2>&1 && ok "fragment is valid with no headers snippet" || bad "fragment without snippet"

continuum_host_headers "$TEAMS" > "$T/snip/continuum-headers.inc"
continuum_host_redirect "$HOST" > "$T/frag/continuum-host.conf"
conf host
if nginx -t -p "$T" -c "$T/nginx.conf" 2>"$T/t.err"; then ok "host config passes nginx -t"; else cat "$T/t.err" >&2; bad "nginx -t"; fi
nginx -p "$T" -c "$T/nginx.conf" 2>/dev/null || { cat "$T/logs/error.log" >&2; exit 1; }
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:18787/health" && curl -s -o /dev/null "http://127.0.0.1:18788/health" && break; sleep 0.1; done

c(){ local h="$1"; shift; curl -sk --resolve "$h:$PORT:127.0.0.1" -D "$T/h" -o "$T/b" -w '%{http_code}' "https://$h:$PORT$1"; }
hdr(){ grep -i "^$1:" "$T/h" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
expect(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

expect "apex /continuum/x?y=1 is a 301" "$(c $APEX '/continuum/x?y=1')" 301
expect "redirect keeps path and query" "$(hdr location)" "https://$HOST/continuum/x?y=1"
expect "apex /continuum is a 301" "$(c $APEX /continuum)" 301
expect "apex /api/ is not redirected" "$(c $APEX /api/health)" 200
expect "host /continuum/ serves the app" "$(c $HOST /continuum/)" 200
grep -q '<title>continuum</title>' "$T/b" && ok "it is the Continuum index" || bad "index body"
expect "index: no-store" "$(hdr cache-control)" "no-store"
expect "index: frame-ancestors none" "$(hdr content-security-policy)" "frame-ancestors 'none'"
expect "index: X-Frame-Options DENY" "$(hdr x-frame-options)" "DENY"
expect "index: microphone only for Teams" "$(hdr permissions-policy)" "geolocation=(), camera=(), payment=(), microphone=(self \"https://$TEAMS\")"
expect "deep link falls back to the app" "$(c $HOST /continuum/projects/x)" 200
expect "deep link: frame-ancestors none" "$(hdr content-security-policy)" "frame-ancestors 'none'"
expect "asset is served" "$(c $HOST /continuum/assets/app-abc.js)" 200
expect "asset: immutable" "$(hdr cache-control)" "public, max-age=2592000, immutable"
expect "asset: nosniff" "$(hdr x-content-type-options)" "nosniff"
expect "missing asset is 404" "$(c $HOST /continuum/assets/nope.js)" 404
expect "host /api/ proxies to the agent" "$(c $HOST /api/health)" 200
grep -q api-ok "$T/b" && ok "it is the /api/ backend" || bad "/api/ body"
expect "/api/: HSTS" "$(hdr strict-transport-security)" "max-age=31536000"
expect "host /agent/ proxies" "$(c $HOST /agent/health)" 200
expect "/agent/: frame-ancestors none" "$(hdr content-security-policy)" "frame-ancestors 'none'"
expect "host / goes to /continuum/" "$(c $HOST /)" 302
expect "host root location" "$(hdr location)" "https://$HOST:$PORT/continuum/"
expect "other apex apps are 404 on the host" "$(c $HOST /quest/)" 404

echo "continuum-host-live: ${pass} passed, ${fail} failed"
(( fail == 0 ))
