#!/usr/bin/env bash
# TEAMS-2c(a) installer contract: static checks + lib/teams-app.sh unit tests.
# Runs as any user. The live install is test/teams-app-live.sh (CI: teams-app.yml).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
I="$ROOT/installers/install-teams-app.sh"; L="$ROOT/lib/teams-app.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
has(){ grep -qF -- "$1" "$2" && ok "$3" || bad "$3"; }
hasnt(){ grep -qF -- "$1" "$2" && bad "$3" || ok "$3"; }
check(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && ok "$d" || bad "$d"; }
refuse(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && bad "$d" || ok "$d"; }

check "install-teams-app.sh parses" bash -n "$I"
check "lib/teams-app.sh parses" bash -n "$L"
has 'INSTALL_TEAMS_APP:-0' "$I" "Teams app is opt-in"
has 'sha256sum --check --status' "$I" "artifact is checked against a pinned checksum"
hasnt '.sha256"' "$I" "checksum is never taken from the release itself"
has 'install the Teams services first' "$I" "fails closed without coord.pub"
has 'install -m 0644 -o root -g root "$TMP/node.json" "$NODE_JSON"' "$I" "node file is 0644 root"
has 'NODE_JSON="$CONFIG/torii-node.json"' "$I" "node file lives outside the release tree"
has 'artifact ships torii-node.json' "$I" "refuses an artifact that ships node settings"
has 'artifact contains symlinks' "$I" "refuses symlinks in the artifact"
has 'rm -rf -- "$TMP/x/.well-known"' "$I" "drops upstream Cordn identity files"
has 'location /.well-known/ { return 404; }' "$I" "no .well-known on the app host"
has 'never served over plain HTTP' "$I" "no app over plain HTTP"
has 'cors_origins' "$I" "allows the app origin for Continuum sign-in"
has 'torii register teams' "$I" "registers a launcher tile"
has 'INSTALL_TEAMS_APP="${INSTALL_TEAMS_APP:-0}"' "$ROOT/bootstrap.sh" "bootstrap defaults the app off"
has '_stage_teams_app' "$ROOT/bootstrap.sh" "bootstrap has a Teams app stage"
has 'INSTALL_TEAMS_APP=0' "$ROOT/.env.example" ".env.example documents INSTALL_TEAMS_APP"

# shellcheck source=../lib/teams-app.sh
source "$L"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PK="$(printf 'ab%.0s' $(seq 32))"
printf '%s\n' "${PK^^}" > "$T/coord.pub"
[[ "$(teams_coord_pub "$T/coord.pub")" == "$PK" ]] && ok "coord.pub is read and lower-cased" || bad "coord.pub is read and lower-cased"
echo nothex > "$T/bad.pub"; refuse "a bad coord.pub is refused" teams_coord_pub "$T/bad.pub"
refuse "a missing coord.pub is refused" teams_coord_pub "$T/none.pub"
ln -s "$T/coord.pub" "$T/link.pub"; refuse "a symlinked coord.pub is refused" teams_coord_pub "$T/link.pub"

J="$(teams_node_json "$PK" example.com relay.example.com http://torii-teams.fips:7334 1)"
python3 - "$J" "$PK" <<'PY' && ok "node file matches the app contract" || bad "node file matches the app contract"
import json, sys
d = json.loads(sys.argv[1])
assert d == {"version": 1, "name": "example.com team", "coordinator": sys.argv[2],
             "relays": ["wss://relay.example.com"], "git": "http://torii-teams.fips:7334",
             "continuum": "https://example.com"}, d
PY
J="$(teams_node_json "$PK" example.com relay.example.com "" 0)"
[[ "$J" != *continuum* && "$J" != *git* ]] && ok "git and continuum are omitted when absent" || bad "git and continuum are omitted when absent"
refuse "a quote in the domain is refused" teams_node_json "$PK" 'exa"mple.com' relay.example.com "" 0
refuse "a non-mesh git URL is refused" teams_node_json "$PK" example.com relay.example.com http://evil.com:7334 0
refuse "a short pubkey is refused" teams_node_json abc example.com relay.example.com "" 0

printf '<html><script>a()</script><body><script>\nb()\n</script></body></html>' > "$T/index.html"
CSP="$(teams_csp "$T/index.html")"
want1="'sha256-$(printf 'a()' | openssl dgst -sha256 -binary | base64)'"
want2="'sha256-$(printf '\nb()\n' | openssl dgst -sha256 -binary | base64)'"
[[ "$CSP" == *"script-src 'self' $want1 $want2;"* ]] && ok "CSP hashes every inline script" || bad "CSP hashes every inline script ($CSP)"
[[ "$CSP" == *"object-src 'none'"* && "$CSP" == *"frame-ancestors 'none'"* && "$CSP" != *unsafe-eval* ]] \
  && ok "CSP locks down objects, framing and eval" || bad "CSP locks down objects, framing and eval"
check "headers snippet accepts the CSP" teams_security_headers "$CSP"
refuse "headers snippet refuses an injected CSP" teams_security_headers "default-src 'self'\"; return 200"
printf '<html></html>' > "$T/empty.html"; refuse "CSP needs the start-up script" teams_csp "$T/empty.html"

echo "install-teams-app.test.sh: $pass passed, $fail failed"
(( fail == 0 ))
