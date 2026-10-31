#!/usr/bin/env bash
# torii-suite/lib/teams-app.sh — helpers for installers/install-teams-app.sh.
# Sourced; pure functions so test/install-teams-app.test.sh can run them as a user.
#
# Contract (torii-teams docs/torii/adr-0001-node-mount.md):
#   /torii-node.json = {"version":1,"name":..,"coordinator":<hex64>,
#                       "relays":["wss://<relay host>"],"git":..,"continuum":..}
#   The app on https uses only wss:// relays; .fips endpoints are for native
#   clients and the CLI on the mesh.

TEAMS_HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

teams_valid_host() { [[ "${1:-}" =~ $TEAMS_HOST_RE ]]; }

# teams_coord_pub <coord.pub> → prints the 64-hex pubkey, or returns 1.
teams_coord_pub() {
  local f="$1" pk
  [[ -f "$f" && ! -L "$f" ]] || return 1
  pk="$(tr -d '[:space:]' < "$f" | tr 'A-F' 'a-f')"
  [[ "$pk" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$pk"
}

# teams_node_json <pubkey> <domain> <relay host> <git url|""> <continuum 0|1>
# Inputs are validated here, so plain printf cannot produce broken JSON.
teams_node_json() {
  local pk="$1" domain="$2" relay="$3" git="${4:-}" continuum="${5:-0}" extra=""
  [[ "$pk" =~ ^[0-9a-f]{64}$ ]] || return 1
  teams_valid_host "$domain" && teams_valid_host "$relay" || return 1
  if [[ -n "$git" ]]; then
    [[ "$git" =~ ^http://[a-z][a-z0-9-]{0,30}[a-z0-9]\.fips:[0-9]{1,5}$ ]] || return 1
    extra+=",\"git\":\"${git}\""
  fi
  [[ "$continuum" == 1 ]] && extra+=",\"continuum\":\"https://${domain}\""
  printf '{"version":1,"name":"%s team","coordinator":"%s","relays":["wss://%s"]%s}\n' \
    "$domain" "$pk" "$relay" "$extra"
}

# teams_csp <index.html> → the Content-Security-Policy value for this build.
# SvelteKit's start-up code is inline, so each inline <script> gets a sha256
# hash; the policy changes every build and is rewritten on each install.
#   connect-src https: — members upload images to Blossom servers and may
#   reach Continuum sign-in; wss: — members may add relays and coordinators.
teams_csp() {
  local index="$1" hashes
  [[ -f "$index" ]] || return 1
  hashes="$(python3 - "$index" <<'PY'
import base64, hashlib, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
for body in re.findall(r"<script>(.*?)</script>", html, re.S):
    print("'sha256-%s'" % base64.b64encode(hashlib.sha256(body.encode()).digest()).decode())
PY
)" || return 1
  [[ -n "$hashes" ]] || return 1
  printf "default-src 'self'; script-src 'self' %s; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; media-src 'self' blob: https:; font-src 'self' data:; connect-src 'self' https: wss:; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\n" \
    "$(printf '%s\n' "$hashes" | tr '\n' ' ' | sed 's/ $//')"
}

# teams_security_headers <csp> → nginx add_header block, re-declared in every
# location because a location with its own add_header drops server-level ones.
teams_security_headers() {
  local csp="$1"
  [[ "$csp" =~ ^[A-Za-z0-9\ \;:/\'+=._*-]+$ ]] || return 1
  cat <<NGINX
# written by torii-suite (lib/teams-app.sh); microphone=(self) for voice notes
add_header Content-Security-Policy "${csp}" always;
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "no-referrer" always;
add_header Permissions-Policy "geolocation=(), microphone=(self), camera=(), payment=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
NGINX
}
