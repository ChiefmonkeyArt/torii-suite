#!/usr/bin/env bash
# Continuum host (Suite v0.9.31) contract: static checks + lib/continuum-host.sh
# unit tests. Runs as any user. The live nginx run is test/continuum-host-live.sh.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
I="$ROOT/installers/install-continuum-host.sh"; L="$ROOT/lib/continuum-host.sh"
C="$ROOT/installers/install-continuum.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
has(){ grep -qF -- "$1" "$2" && ok "$3" || bad "$3"; }
check(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && ok "$d" || bad "$d"; }
refuse(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && bad "$d" || ok "$d"; }

check "install-continuum-host.sh parses" bash -n "$I"
check "lib/continuum-host.sh parses" bash -n "$L"
has 'INSTALL_CONTINUUM_HOST:-0' "$I" "Continuum host is opt-in"
has 'never strand the app' "$I" "redirect only once the vhost has a certificate"
has 'rolled back' "$I" "a rejected nginx config is rolled back"
has 'CONTINUUM_HOST_REMOVE' "$I" "has a rollback switch"
has 'predates Suite v0.9.31-alpha' "$I" "refuses a fragment without the headers include"
n="$(grep -cF 'include /opt/torii/nginx-snippets/continuum-headers*.inc;' "$C")"
[[ "$n" == 4 ]] && ok "every Continuum location includes the headers (4)" || bad "headers include count is $n, want 4"
has 'INSTALL_CONTINUUM_HOST="${INSTALL_CONTINUUM_HOST:-0}"' "$ROOT/bootstrap.sh" "bootstrap defaults the host off"
has '_stage_continuum_host' "$ROOT/bootstrap.sh" "bootstrap has a Continuum host stage"
has 'export INSTALL_CONTINUUM_HOST CONTINUUM_HOST' "$ROOT/bootstrap.sh" "bootstrap exports CONTINUUM_HOST for the Teams app"
has 'INSTALL_CONTINUUM_HOST=0' "$ROOT/.env.example" ".env.example documents INSTALL_CONTINUUM_HOST"

# shellcheck source=../lib/continuum-host.sh
source "$L"
check "valid host" continuum_valid_host continuum.example.org
refuse "rejects a host with a path" continuum_valid_host 'continuum.example.org/x'
refuse "rejects a host with a space" continuum_valid_host 'a b.org'
refuse "rejects an uppercase host" continuum_valid_host 'Continuum.example.org'

h="$(continuum_host_headers teams.example.org)"
[[ "$h" == *'microphone=("https://teams.example.org")'* && "$h" != *"microphone=(self"* ]] && ok "microphone delegated to the Teams origin only (ADR 0006)" || bad "microphone policy"
[[ "$h" == *"frame-ancestors 'none'"* && "$h" == *'X-Frame-Options "DENY"'* ]] && ok "nothing may frame Continuum" || bad "frame policy"
[[ "$h" == *"Strict-Transport-Security"* && "$h" == *"nosniff"* ]] && ok "HSTS + nosniff" || bad "HSTS/nosniff"
[[ "$(continuum_host_headers '')" == *"microphone=()"* ]] && ok "no Teams app: no microphone" || bad "no-teams microphone"
refuse "rejects a bad Teams host" continuum_host_headers 'teams.example.org" always; add_header X "y'

v="$(continuum_host_vhost continuum.example.org /c /f.conf /a.conf /h.inc)"
[[ "$v" == *"server_name continuum.example.org;"* && "$v" == *"include /f.conf;"* && "$v" == *"include /a.conf;"* ]] && ok "vhost reuses the fragment and /api/ snippet" || bad "vhost includes"
[[ "$v" == *"location = / { include /h.inc; return 302 /continuum/; }"* ]] && ok "host root goes to /continuum/" || bad "host root"
[[ "$v" == *"location / { include /h.inc; return 404; }"* ]] && ok "other paths are 404" || bad "other paths"
refuse "vhost rejects a bad host" continuum_host_vhost 'x;y' /c /f /a /h

r="$(continuum_host_redirect continuum.example.org)"
[[ "$r" == *'rewrite ^/continuum(/.*)?$ https://continuum.example.org/continuum$1 permanent;'* ]] && ok "apex /continuum/ is a 301 to the host" || bad "redirect"
refuse "redirect rejects a bad host" continuum_host_redirect 'evil.org/x'

echo "continuum-host: ${pass} passed, ${fail} failed"
(( fail == 0 ))
