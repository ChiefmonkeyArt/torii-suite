#!/usr/bin/env bash
# shellcheck disable=SC2034  # several vars are read inside check()'s eval strings
# v0.9.25-alpha: Quest security headers + per-build CSP (lib/quest-headers.sh,
# installers/install-quest.sh step 4/5, Quest ADR-0149).
#
# 1. quest_csp_line validates the release's csp.nginx.conf (no nginx injection).
# 2. write_quest_header_snippets: enforced / missing / QUEST_CSP_ENFORCE=0.
# 3. Static: includes sit in the right nested locations; no CSP on /quest/ itself.
# 4. Live (when nginx is installed): the generated fragment passes `nginx -t` and a
#    real nginx serves the CSP on the game document only, security headers on
#    assets/worlds, and dashboard/napplet pages without the game CSP.
#    QUEST_DIST=<path to a built Quest dist/> uses a real build instead of the fixture.
#
# Run:  bash test/install-quest-csp.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
INST="${REPO_ROOT}/installers/install-quest.sh"
LIB="${REPO_ROOT}/lib/quest-headers.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

bash -n "$LIB" && ok "lib/quest-headers.sh parses" || bad "lib/quest-headers.sh bash -n"
bash -n "$INST" && ok "install-quest.sh parses" || bad "install-quest.sh bash -n"
# shellcheck source=../lib/quest-headers.sh
source "$LIB"

T="$(mktemp -d)"; trap 'kill "$(cat "$T/ngx/nginx.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$T"' EXIT
GOOD="add_header Content-Security-Policy \"script-src 'self' 'wasm-unsafe-eval' 'sha256-AbC+/0123=' ; connect-src 'self' blob: https: wss:; object-src 'none'; base-uri 'self'; frame-src 'self'\" always;"

# ── 1. validator ──────────────────────────────────────────────────────────────
v() { printf '%s\n' "$2" > "$T/c.conf"; if quest_csp_line "$T/c.conf" >/dev/null; then r=accept; else r=reject; fi; [[ "$r" == "$1" ]]; }
check "accepts the Quest line"                     "v accept \"\$GOOD\""
check "accepts with comments + blank lines"        "v accept \"# csp for build abc
\$GOOD

\""
check "rejects a missing file"                     "! quest_csp_line '$T/nope.conf' >/dev/null"
check "rejects an empty file"                      "v reject ''"
check "rejects two directives"                     "v reject \"\$GOOD
add_header X-Evil 1 always;\""
check "rejects a second directive on the same line" "v reject \"\${GOOD} return 301 https://evil.example;\""
check "rejects an embedded quote"                  "v reject 'add_header Content-Security-Policy \"script-src a\" b; object-src '\\''none'\\''\" always;'"
check "rejects \$variables"                         "v reject 'add_header Content-Security-Policy \"script-src \$host; object-src '\\''none'\\''\" always;'"
check "rejects braces"                             "v reject 'add_header Content-Security-Policy \"script-src a; object-src '\\''none'\\'' } location / {\" always;'"
check "rejects # (comment truncation)"             "v reject 'add_header Content-Security-Policy \"script-src a; object-src '\\''none'\\''#\" always;'"
check "rejects a policy without script-src"        "v reject 'add_header Content-Security-Policy \"connect-src https:; object-src '\\''none'\\''\" always;'"
check "rejects a policy without object-src none"   "v reject 'add_header Content-Security-Policy \"script-src '\\''self'\\''\" always;'"
check "rejects a non-CSP header"                   "v reject 'add_header X-Frame-Options \"script-src a; object-src '\\''none'\\''\" always;'"
check "rejects missing always"                     "v reject \"\${GOOD% always;};\""
long="add_header Content-Security-Policy \"script-src $(printf 'a%.0s' $(seq 1 4100)); object-src 'none'\" always;"
check "rejects an over-long policy"                "v reject \"\$long\""

# ── 2. snippet writer ─────────────────────────────────────────────────────────
mkdir -p "$T/rel" "$T/snip"; printf '%s\n' "$GOOD" > "$T/rel/csp.nginx.conf"
st="$(write_quest_header_snippets "$T/rel" "$T/snip")"
check "valid release → csp-enforced"               "[[ '$st' == csp-enforced ]]"
check "quest-csp.inc carries the exact line"       "grep -qxF \"\$GOOD\" '$T/snip/quest-csp.inc'"
check "quest-security.inc has the 4 headers"       "[[ \$(grep -c '^add_header ' '$T/snip/quest-security.inc') -eq 4 ]]"
check "no temp files left behind"                  "[[ -z \$(ls '$T/snip' | grep tmp) ]]"
mkdir -p "$T/old"
st="$(write_quest_header_snippets "$T/old" "$T/snip")"
check "older release (no file) → csp-missing"      "[[ '$st' == csp-missing ]]"
check "csp-missing writes no directive"            "! grep -q '^add_header' '$T/snip/quest-csp.inc'"
st="$(QUEST_CSP_ENFORCE=0 write_quest_header_snippets "$T/rel" "$T/snip")"
check "QUEST_CSP_ENFORCE=0 → csp-off"              "[[ '$st' == csp-off ]]"
check "csp-off writes no directive"                "! grep -q '^add_header' '$T/snip/quest-csp.inc'"

# ── 3. static installer wiring ────────────────────────────────────────────────
check "installer sources the lib"                  "grep -qF 'source \"\$(dirname -- \"\${BASH_SOURCE[0]}\")/../lib/quest-headers.sh\"' '$INST'"
check "snippets written after the symlink flip"    "[[ \$(grep -n 'write_quest_header_snippets \"\$RELEASE_DIR\"' '$INST' | cut -d: -f1) -gt \$(grep -n 'mv -Tf \"\${WWW_LINK}.new\"' '$INST' | cut -d: -f1) ]]"
check "installer still ends with torii reload"     "[[ \$(grep -c '^/usr/local/bin/torii reload' '$INST') -ge 1 ]]"
check "exactly one CSP include"                    "[[ \$(grep -c 'quest-csp.inc;' '$INST') -eq 1 ]]"
check "three security includes (worlds/assets/index)" "[[ \$(grep -c 'quest-security.inc;' '$INST') -eq 3 ]]"

# ── 4. real nginx ─────────────────────────────────────────────────────────────
if ! command -v nginx >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  printf '  skip live nginx checks (nginx/curl not installed)\n'
else
  A="$T/apps"; R="$A/quest/releases/r1"; mkdir -p "$R/assets" "$R/napplets/gateway" "$A/quest/data/worlds" "$T/ngx/logs"
  if [[ -n "${QUEST_DIST:-}" && -d "${QUEST_DIST}" ]]; then cp -a "${QUEST_DIST}/." "$R/"; else
    printf '<!doctype html><title>q</title>\n' > "$R/index.html"
    printf '<!doctype html><title>d</title>\n' > "$R/dashboard.html"
    printf '<!doctype html><title>n</title>\n' > "$R/napplets/gateway/index.html"
    printf '%s\n' "$GOOD" > "$R/csp.nginx.conf"
  fi
  printf 'x\n' > "$R/assets/zz-test.js"; printf '{}\n' > "$A/quest/data/worlds/w.json"
  ln -sfn "$R" "$A/quest/current"
  write_quest_header_snippets "$R" "$T/snip" >/dev/null
  # Render the installer's real fragment heredoc with test paths.
  body="$(sed -n '/^FRAGMENT_CONTENT="\$(cat <<NGINX$/,/^NGINX$/p' "$INST" | sed '1d;$d')"
  APPS_ROOT="$A" QUEST_SNIPPET_DIR="$T/snip" eval "cat <<NGINX
$body
NGINX" > "$T/quest.conf"
  # The torii-base server-level headers, as on a real node.
  cat > "$T/ngx/nginx.conf" <<EOF
pid $T/ngx/nginx.pid; error_log $T/ngx/logs/error.log; daemon on;
events {}
http {
  types { text/html html; application/javascript js; application/json json; }
  access_log off; client_body_temp_path $T/ngx; proxy_temp_path $T/ngx; fastcgi_temp_path $T/ngx; uwsgi_temp_path $T/ngx; scgi_temp_path $T/ngx;
  server {
    listen 127.0.0.1:18089;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    include $T/quest.conf;
  }
}
EOF
  if nginx -t -q -p "$T/ngx" -c "$T/ngx/nginx.conf" 2>"$T/ngx/t.err"; then ok "generated fragment passes nginx -t"; else bad "nginx -t: $(cat "$T/ngx/t.err")"; fi
  if nginx -p "$T/ngx" -c "$T/ngx/nginx.conf" 2>/dev/null; then
    sleep 0.3
    h() { curl -s -o /dev/null -D - "http://127.0.0.1:18089$1" | tr -d '\r'; }
    csp="$(grep -v '^#' "$R/csp.nginx.conf" | sed -n 's/^add_header Content-Security-Policy "\(.*\)" always;$/\1/p')"
    for u in /quest/ /quest/index.html /quest/w/npub1abc/world; do
      out="$(h "$u")"
      check "$u: 200"                               "grep -q '^HTTP/1.1 200' <<<\"\$out\""
      check "$u: sends the release's CSP"           "grep -qxF \"Content-Security-Policy: \$csp\" <<<\"\$out\""
      check "$u: keeps Cache-Control no-store"      "grep -qx 'Cache-Control: no-store' <<<\"\$out\""
      check "$u: has the 4 security headers"        "[[ \$(grep -cE '^(X-Frame-Options|X-Content-Type-Options|Referrer-Policy|Permissions-Policy):' <<<\"\$out\") -eq 4 ]]"
    done
    for u in /quest/assets/zz-test.js /quest/worlds/w.json; do
      out="$(h "$u")"
      check "$u: has nosniff + 4 security headers"  "[[ \$(grep -cE '^(X-Frame-Options|X-Content-Type-Options|Referrer-Policy|Permissions-Policy):' <<<\"\$out\") -eq 4 ]]"
      check "$u: no CSP (not a document)"           "! grep -qi '^Content-Security-Policy:' <<<\"\$out\""
    done
    for u in /quest/dashboard.html /quest/napplets/gateway/index.html; do
      out="$(h "$u")"
      check "$u: 200, own meta CSP only (no game CSP header)" "grep -q '^HTTP/1.1 200' <<<\"\$out\" && ! grep -qi '^Content-Security-Policy:' <<<\"\$out\""
    done
    kill "$(cat "$T/ngx/nginx.pid")" 2>/dev/null
  else bad "nginx failed to start"; fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
