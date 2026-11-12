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
grep -Eq '^TEAMS_APP_TAG="\$\{TEAMS_APP_TAG:-[0-9]+\.[0-9]+\.[0-9]+-torii\.[0-9]+\}"$' "$I" && ok "a release tag is pinned" || bad "a release tag is pinned"
grep -Eq '^TEAMS_APP_SHA256="\$\{TEAMS_APP_SHA256:-[0-9a-f]{64}\}"$' "$I" && ok "its SHA-256 is pinned" || bad "its SHA-256 is pinned"
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
has 'teams_continuum_config' "$I" "sets Continuum cors_origins and teams.app_url"
has 'torii register teams' "$I" "registers a launcher tile"
has 'gzip_static on;' "$I" "serves pre-compressed assets"
has "-exec gzip -9 -k -n -f {} +" "$I" "compresses the release once at install"
grep -qF 'AGENT_HOME="${APPS_ROOT}/continuum/agent"' "$ROOT/installers/install-continuum.sh" \
  && grep -qF 'CONFIG_FILE="${AGENT_REPO}/agent/config.yaml"' "$ROOT/installers/install-continuum.sh" \
  && grep -qF 'CONTINUUM_CONFIG="${APPS_ROOT}/continuum/agent/repo/agent/config.yaml"' "$I" \
  && ok "Continuum config path matches install-continuum.sh" || bad "Continuum config path matches install-continuum.sh"
n="$(grep -n '^APPS_ROOT=' "$I" | head -1 | cut -d: -f1)"; m="$(grep -n '^CONTINUUM_CONFIG=' "$I" | cut -d: -f1)"
[[ -n "$n" && -n "$m" && "$n" -lt "$m" ]] && ok "APPS_ROOT is set before the Continuum path" || bad "APPS_ROOT is set before the Continuum path"
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
J="$(teams_node_json "$PK" example.com relay.example.com "" 1 continuum.example.com)"
[[ "$J" == *'"continuum":"https://continuum.example.com"'* ]] && ok "CONTINUUM_HOST becomes the Continuum origin" || bad "CONTINUUM_HOST becomes the Continuum origin ($J)"
refuse "a bad Continuum host is refused" teams_node_json "$PK" example.com relay.example.com "" 1 'evil.com/x'

printf '<html><script>a()</script><body><script>\nb()\n</script></body></html>' > "$T/index.html"
CSP="$(teams_csp "$T/index.html")"
want1="'sha256-$(printf 'a()' | openssl dgst -sha256 -binary | base64)'"
want2="'sha256-$(printf '\nb()\n' | openssl dgst -sha256 -binary | base64)'"
[[ "$CSP" == *"script-src 'self' $want1 $want2;"* ]] && ok "CSP hashes every inline script" || bad "CSP hashes every inline script ($CSP)"
[[ "$CSP" == *"object-src 'none'"* && "$CSP" == *"frame-ancestors 'none'"* && "$CSP" != *unsafe-eval* ]] \
  && ok "CSP locks down objects, framing and eval" || bad "CSP locks down objects, framing and eval"
check "headers snippet accepts the CSP" teams_security_headers "$CSP"
FCSP="$(teams_csp "$T/index.html" continuum.example.com example.com example.com)"
[[ "$FCSP" == *"frame-ancestors https://continuum.example.com https://example.com" ]] \
  && ok "CSP lets only the Continuum hosts frame the app" || bad "CSP frame hosts ($FCSP)"
refuse "a bad frame host is refused" teams_csp "$T/index.html" "evil.com; script-src *"
check "headers snippet accepts the framed CSP" teams_security_headers "$FCSP"
[[ "$(teams_security_headers "$FCSP")" != *"add_header X-Frame-Options"* ]] && ok "no X-Frame-Options (frame-ancestors rules)" || bad "X-Frame-Options still set"
[[ "$(teams_security_headers "$FCSP")" == *"microphone=(self), camera=()"* ]] && ok "microphone for this origin only, no camera (voice notes, ADR 0006)" || bad "Permissions-Policy microphone"
refuse "headers snippet refuses an injected CSP" teams_security_headers "default-src 'self'\"; return 200"
printf '<html></html>' > "$T/empty.html"; refuse "CSP needs the start-up script" teams_csp "$T/empty.html"

# ── Node file server (torii-teams ADR 0007) ──
J="$(teams_node_json "$PK" example.com relay.example.com "" 1 continuum.example.com teams.example.com)"
[[ "$J" == *'"files":"https://teams.example.com/files"'* ]] && ok "node file names the node file server" || bad "node file files ($J)"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$J" && ok "node file with files is valid JSON" || bad "node file JSON"
refuse "file server needs Continuum" teams_node_json "$PK" example.com relay.example.com "" 0 example.com teams.example.com
refuse "a bad files host is refused" teams_node_json "$PK" example.com relay.example.com "" 1 example.com 'evil.com/x'
[[ "$(teams_node_json "$PK" example.com relay.example.com "" 1)" != *'"files"'* ]] && ok "no files entry unless asked" || bad "files entry by default"
NCSP="$(teams_csp "$T/index.html" --node continuum.example.com relay.example.com continuum.example.com)"
[[ "$NCSP" == *"connect-src 'self' blob: https://continuum.example.com wss://relay.example.com;"* ]] && ok "node CSP: connect only to self, Continuum and the relay" || bad "node CSP connect ($NCSP)"
[[ "$NCSP" == *"img-src 'self' data: blob:;"* && "$NCSP" == *"media-src 'self' blob:;"* && "$NCSP" != *"https:;"* ]] && ok "node CSP: no remote images or media" || bad "node CSP images ($NCSP)"
[[ "$NCSP" == *"frame-ancestors https://continuum.example.com" ]] && ok "node CSP keeps the frame hosts" || bad "node CSP frames ($NCSP)"
check "headers snippet accepts the node CSP" teams_security_headers "$NCSP"
[[ "$CSP" == *"connect-src 'self' blob: https: wss:;"* ]] && ok "default CSP: local blob: reads, any https/wss host" || bad "default CSP ($CSP)"
refuse "node CSP refuses a bad relay host" teams_csp "$T/index.html" --node continuum.example.com 'x; script-src *'
printf 'server:\n  host: 127.0.0.1\n  port: 9911 # agent\nteams:\n  port: 1\n' > "$T/p.yaml"
[[ "$(teams_continuum_port "$T/p.yaml")" == 9911 ]] && ok "reads the Continuum server.port" || bad "Continuum port"
printf 'teams:\n  port: 1\n' > "$T/p2.yaml"
[[ "$(teams_continuum_port "$T/p2.yaml")" == 8787 ]] && ok "Continuum port defaults to 8787" || bad "Continuum port default"
U="$(teams_files_unit /usr/bin/node)"
for w in 'DynamicUser=yes' 'StateDirectory=torii-teams-files' 'ProtectSystem=strict' 'IPAddressAllow=localhost' 'NoNewPrivileges=yes' 'ExecStart=/usr/bin/node /opt/torii/teams-files/server.mjs'; do
  [[ "$U" == *"$w"* ]] || bad "unit has $w"
done && ok "file server unit is sandboxed and loopback-only"
refuse "unit refuses a strange node path" teams_files_unit '/usr/bin/node; rm -rf /'
has 'TEAMS_FILES="${TEAMS_FILES:-1}"' "$I" "file server on by default with Continuum"
has '(( CONTINUUM == 1 )) || TEAMS_FILES=0' "$I" "file server only with Continuum"
has 'PUT/files/upload|DELETE/files/[0-9a-f]{64}' "$I" "only uploads and deletes may PUT/DELETE"
has 'proxy_pass http://127.0.0.1:${TEAMS_FILES_PORT};' "$I" "file server is reached over loopback"
has 'TEAMS_FILES=1' "$ROOT/.env.example" ".env.example documents TEAMS_FILES"
if command -v node >/dev/null; then
  node --test "$ROOT/test/teams-files.test.mjs" >/dev/null 2>&1 && ok "file server unit tests (node --test)" || bad "file server unit tests"
fi

# Continuum config edit: cors_origins + teams.app_url, idempotent.
cat > "$T/c.yaml" <<'Y'
server:
  host: "127.0.0.1"
  cors_origins:
    # comment
    - "http://localhost:5180"

cashu:
  enabled: false
Y
[[ "$(teams_continuum_config "$T/c.yaml" https://teams.example.com)" == changed ]] && ok "Continuum config is edited" || bad "Continuum config is edited"
[[ "$(teams_continuum_config "$T/c.yaml" https://teams.example.com)" == unchanged ]] && ok "Continuum config edit is idempotent" || bad "Continuum config edit is idempotent"
printf 'server:\n  port: 8787\nteams:\n  app_url: "https://old.example.com"\n  other: 1\nlogging:\n  level: info\n' > "$T/d.yaml"
teams_continuum_config "$T/d.yaml" https://teams.example.com >/dev/null
python3 - "$T/c.yaml" "$T/d.yaml" <<'PY' && ok "Continuum YAML stays valid, app_url added or replaced" || bad "Continuum YAML stays valid, app_url added or replaced"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert "https://teams.example.com" in c["server"]["cors_origins"], c
assert c["teams"] == {"app_url": "https://teams.example.com"} and c["cashu"] == {"enabled": False}, c
d = yaml.safe_load(open(sys.argv[2]))
assert d["teams"] == {"app_url": "https://teams.example.com", "other": 1} and d["logging"]["level"] == "info", d
assert open(sys.argv[2]).read().count("app_url") == 1
PY
refuse "Continuum edit refuses a non-https origin" teams_continuum_config "$T/c.yaml" 'http://x"'

echo "install-teams-app.test.sh: $pass passed, $fail failed"
(( fail == 0 ))
