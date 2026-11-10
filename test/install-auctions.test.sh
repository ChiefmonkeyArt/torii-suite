#!/usr/bin/env bash
# Plebeian Auctions installer contract: static checks + lib/auctions.sh unit tests.
# Runs as any user. The live install is test/auctions-live.sh (root, real tarball).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
I="$ROOT/installers/install-auctions.sh"; L="$ROOT/lib/auctions.sh"; B="$ROOT/bootstrap.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
has(){ grep -qF -- "$1" "$2" && ok "$3" || bad "$3"; }
hasnt(){ grep -qF -- "$1" "$2" && bad "$3" || ok "$3"; }
check(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && ok "$d" || bad "$d"; }
refuse(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && bad "$d" || ok "$d"; }

check "install-auctions.sh parses" bash -n "$I"
check "lib/auctions.sh parses" bash -n "$L"
has 'INSTALL_AUCTIONS:-0' "$I" "opt-in"
has 'INSTALL_AUCTIONS="${INSTALL_AUCTIONS:-0}"' "$B" "bootstrap defaults it off"
grep -Eq '^AUCTIONS_TAG="\$\{AUCTIONS_TAG:-v[0-9]+\.[0-9]+\.[0-9]+\}"$' "$I" && ok "a release tag is pinned" || bad "a release tag is pinned"
grep -Eq '^AUCTIONS_SHA256="\$\{AUCTIONS_SHA256:-[0-9a-f]{64}\}"$' "$I" && ok "its SHA-256 is pinned" || bad "its SHA-256 is pinned"
has 'sha256sum --check --status' "$I" "artifact checked against the pinned checksum"
hasnt '.sha256"' "$I" "checksum never taken from the release"
# Team-only (Suite ADR 0002): no launcher card, no main-domain mount.
hasnt 'torii register' "$I" "never registers a launcher tile"
hasnt 'nginx-fragments' "$I" "writes no main-domain fragment"
hasnt 'torii register' "$L" "helpers never register a tile"
has 'X-Robots-Tag "noindex, nofollow"' "$L" "noindex header"
has "frame-ancestors 'none'" "$L" "never framed"
has "connect-src 'self'" "$L" "app reaches only its own origin"
has 'location = /mint/v1/ws {' "$I" "only the mint WebSocket path may upgrade"
has 'limit_conn torii_auctions_ws 16;' "$I" "open WebSockets capped per address"
[[ "$(grep -c 'proxy_set_header Upgrade' "$I")" == 1 ]] && ok "upgrade headers on that one location only" || bad "upgrade headers on that one location only"
has 'never served over plain HTTP' "$I" "no app over plain HTTP"
has 'auctions_safe_tree' "$I" "refuses symlinks that leave the release"
has 'ports already in use' "$I" "fails closed on a port clash"
has 'IPAddressAllow=localhost' "$L" "services reach loopback only"
has 'DynamicUser=yes' "$L" "services run as dynamic users"
has 'install -m 0600 -o root -g root "$TMP/mint.env"' "$I" "mint settings 0600 root"
has 'MINT_BACKEND_BOLT11_SAT=FakeWallet' "$L" "fake sats only"
has 'gzip_static on;' "$I" "serves pre-compressed assets"

# shellcheck source=../lib/auctions.sh
source "$L"
check "valid host" auctions_valid_host auctions.example.com
refuse "rejects a bad host" auctions_valid_host 'bad host;'
check "valid port" auctions_valid_port 8795
refuse "rejects a privileged port" auctions_valid_port 80
f="$(mktemp)"; printf 'AUCTIONS_PORT=9123\nAUCTIONS_MINT_PORT=x\n' > "$f"
[[ "$(auctions_saved_port "$f" AUCTIONS_PORT)" == 9123 ]] && ok "reads a saved port" || bad "reads a saved port"
refuse "ignores a bad saved port" auctions_saved_port "$f" AUCTIONS_MINT_PORT
refuse "no saved file, no port" auctions_saved_port /nonexistent AUCTIONS_PORT; rm -f "$f"
[[ "$(auctions_free_port 40100 40100 40101)" == 40102 ]] && ok "free port skips taken ones" || bad "free port skips taken ones"
has 'is taken; the gateway uses' "$I" "picks a free gateway port on a clash"
has '$CONFIG/ports' "$I" "remembers the chosen ports"
[[ "$(auctions_validator_ports | wc -l)" == 12 ]] && ok "twelve validator ports" || bad "twelve validator ports"
W="$(mktemp -d)"; trap 'rm -rf -- "$W"' EXIT
mkdir -p "$W/t/bin" && touch "$W/t/bin/python3.12" && ln -s python3.12 "$W/t/bin/python3"
check "relative in-tree symlink accepted" auctions_safe_tree "$W/t"
ln -s /etc/passwd "$W/t/bin/evil"; refuse "absolute symlink refused" auctions_safe_tree "$W/t"; rm "$W/t/bin/evil"
ln -s ../../../x "$W/t/bin/up"; refuse "escaping symlink refused" auctions_safe_tree "$W/t"; rm "$W/t/bin/up"
printf '<html><script>window.a=1</script><script type="module" src="x.js"></script></html>' > "$W/i.html"
csp="$(auctions_csp "$W/i.html")"
want="'sha256-$(printf 'window.a=1' | openssl dgst -sha256 -binary | base64)'"
[[ "$csp" == *"script-src 'self' $want;"* ]] && ok "CSP hashes the inline script" || bad "CSP hashes the inline script"
check "headers accept the CSP" auctions_security_headers "$csp"
refuse "headers refuse a quote" auctions_security_headers 'default-src "x"'
env="$(auctions_mint_env 13338 /var/lib/plebeian-auctions-mint)"
[[ "$env" == *"MINT_LISTEN_HOST=127.0.0.1"* && "$env" != *MINT_PRIVATE_KEY* ]] && ok "mint env: loopback, key added separately" || bad "mint env"
refuse "mint env refuses a bad port" auctions_mint_env 80 /x
u="$(auctions_chain_unit /apps/plebeian-auctions 8795 13338)"
[[ "$u" == *"-addr 127.0.0.1:8795"* && "$u" == *'$$(seq 60)'* ]] && ok "gateway unit: loopback, systemd-escaped loop" || bad "gateway unit"
[[ "$u" == *"arena init -if-needed -root /var/lib/plebeian-auctions/chain"* && "$u" == *"-lock-margin 86400"* ]] && ok "gateway unit: re-inits a chain of another format, 24 h lock margin" || bad "gateway unit: init -if-needed / margin"
[[ "$u" != *"-demo-controls"* ]] && ok "gateway unit: demo controls off by default" || bad "gateway unit: demo controls default"
u2="$(auctions_chain_unit /apps/plebeian-auctions 8795 13338 600 1)"
[[ "$u2" == *"-lock-margin 600"* && "$u2" == *"-mint http://127.0.0.1:13338 -demo-controls"* ]] && ok "gateway unit: margin and demo controls on request" || bad "gateway unit: margin/demo flags"
refuse "gateway unit refuses a bad margin" auctions_chain_unit /apps/plebeian-auctions 8795 13338 '1;x' 0
refuse "gateway unit refuses a bad demo flag" auctions_chain_unit /apps/plebeian-auctions 8795 13338 600 yes
has 'AUCTIONS_DEMO_CONTROLS:-1' "$I" "installer keeps the team demo controls on unless set to 0"
has 'bin/arena bin/arena-frost' "$I" "artifact must carry the FROST helper"
refuse "gateway unit refuses a bad path" auctions_chain_unit 'x;y' 8795 13338
echo "install-auctions: ${pass} passed, ${fail} failed"
(( fail == 0 ))
