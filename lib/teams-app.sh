#!/usr/bin/env bash
# torii-suite/lib/teams-app.sh — helpers for installers/install-teams-app.sh.
# Sourced; pure functions so test/install-teams-app.test.sh can run them as a user.
#
# Contract (torii-teams docs/torii/adr-0001-node-mount.md):
#   /torii-node.json = {"version":1,"name":..,"coordinator":<hex64>,
#                       "relays":["wss://<relay host>"],"git":..,"continuum":..,
#                       "files":"https://<teams host>/files"}   (ADR 0007)
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

# teams_node_json <pubkey> <domain> <relay host> <git url|""> <continuum 0|1> [continuum host] [files host]
# Inputs are validated here, so plain printf cannot produce broken JSON.
# The Continuum origin is https://<continuum host> (CONTINUUM_HOST, Suite
# v0.9.31) when given, else https://<domain>; /api/ is served on both.
teams_node_json() {
  local pk="$1" domain="$2" relay="$3" git="${4:-}" continuum="${5:-0}" chost="${6:-$2}" fhost="${7:-}" extra=""
  [[ "$pk" =~ ^[0-9a-f]{64}$ ]] || return 1
  teams_valid_host "$domain" && teams_valid_host "$relay" && teams_valid_host "$chost" || return 1
  if [[ -n "$git" ]]; then
    [[ "$git" =~ ^http://[a-z][a-z0-9-]{0,30}[a-z0-9]\.fips:[0-9]{1,5}$ ]] || return 1
    extra+=",\"git\":\"${git}\""
  fi
  [[ "$continuum" == 1 ]] && extra+=",\"continuum\":\"https://${chost}\""
  # The node file server (ADR 0007) needs Continuum for its upload gate.
  if [[ -n "$fhost" ]]; then
    [[ "$continuum" == 1 ]] && teams_valid_host "$fhost" || return 1
    extra+=",\"files\":\"https://${fhost}/files\""
  fi
  printf '{"version":1,"name":"%s team","coordinator":"%s","relays":["wss://%s"]%s}\n' \
    "$domain" "$pk" "$relay" "$extra"
}

# teams_csp <index.html> [--node <continuum host> <relay host>] [frame host...]
# → the Content-Security-Policy value for this build. Only the listed hosts
# (Continuum's, ADR 0002) may frame the app; with none, nobody may.
# SvelteKit's start-up code is inline, so each inline <script> gets a sha256
# hash; the policy changes every build and is rewritten on each install.
#   Default: connect-src https: wss: and https: images, because members upload
#   to public Blossom servers and may add relays.
#   --node (files on the node, ADR 0007): the browser may reach only this
#   origin, Continuum and the node relay; images and media only from here.
teams_csp() {
  local index="$1" hashes ancestors="" h connect="'self' blob: https: wss:" img="'self' data: blob: https:" media="'self' blob: https:"
  shift
  [[ -f "$index" ]] || return 1
  if [[ "${1:-}" == --node ]]; then
    teams_valid_host "${2:-}" && teams_valid_host "${3:-}" || return 1
    connect="'self' blob: https://$2 wss://$3" img="'self' data: blob:" media="'self' blob:"
    shift 3
  fi
  for h in "$@"; do
    teams_valid_host "$h" || return 1
    [[ " $ancestors " == *" https://$h "* ]] || ancestors+="${ancestors:+ }https://$h"
  done
  hashes="$(python3 - "$index" <<'PY'
import base64, hashlib, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
for body in re.findall(r"<script>(.*?)</script>", html, re.S):
    print("'sha256-%s'" % base64.b64encode(hashlib.sha256(body.encode()).digest()).decode())
PY
)" || return 1
  [[ -n "$hashes" ]] || return 1
  printf "default-src 'self'; script-src 'self' %s; style-src 'self' 'unsafe-inline'; img-src %s; media-src %s; font-src 'self' data:; connect-src %s; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors %s\n" \
    "$(printf '%s\n' "$hashes" | tr '\n' ' ' | sed 's/ $//')" "$img" "$media" "$connect" "${ancestors:-'none'}"
}

# teams_security_headers <csp> → nginx add_header block, re-declared in every
# location because a location with its own add_header drops server-level ones.
teams_security_headers() {
  local csp="$1"
  [[ "$csp" =~ ^[A-Za-z0-9\ \;:/\'+=._*-]+$ ]] || return 1
  cat <<NGINX
# written by torii-suite (lib/teams-app.sh); microphone for this origin only: voice notes (ADR 0006).
# No X-Frame-Options: CSP frame-ancestors names the Continuum hosts (ADR 0002).
add_header Content-Security-Policy "${csp}" always;
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "no-referrer" always;
add_header Permissions-Policy "geolocation=(), microphone=(self), camera=(), payment=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
NGINX
}

# teams_continuum_config <config.yaml> <app origin> — idempotent edit of the
# Continuum agent config: the app origin in server.cors_origins (member sign-in
# is cross-origin) and teams.app_url (Continuum's Team view shows
# "Open team chat" only when it is set). Prints "changed" or "unchanged".
teams_continuum_config() {
  python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
path, origin = pathlib.Path(sys.argv[1]), sys.argv[2]
assert re.fullmatch(r"https://[a-z0-9.-]+", origin), origin
text = before = path.read_text()
if "cors_origins:" in text and f'"{origin}"' not in text:
    text = re.sub(r"(cors_origins:\s*\n(?:\s*-\s+.*\n)*)",
                  lambda m: f'{m.group(1)}    - "{origin}"\n', text, count=1)
line = f'  app_url: "{origin}"'
block = re.search(r"(?m)^teams:[ \t]*(?:#.*)?\n((?:[ \t]+.*\n|[ \t]*\n)*)", text)
if block is None:
    text = text.rstrip("\n") + f"\n\n# Torii Teams app (written by torii-suite install-teams-app.sh)\nteams:\n{line}\n"
elif re.search(r"(?m)^[ \t]+app_url:.*$", block.group(1)):
    body = re.sub(r"(?m)^[ \t]+app_url:.*$", line, block.group(1), count=1)
    text = text[:block.start(1)] + body + text[block.end(1):]
else:
    text = text[:block.start(1)] + line + "\n" + text[block.start(1):]
if text != before:
    path.write_text(text)
    print("changed")
else:
    print("unchanged")
PY
}

# teams_continuum_port <config.yaml> → the Continuum agent's loopback port
# (server.port, default 8787), for the file server's upload gate.
teams_continuum_port() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"(?m)^server:[ \t]*(?:#.*)?\n((?:[ \t]+.*\n|[ \t]*\n)*)", text)
port = re.search(r"(?m)^[ \t]+port:[ \t]*([0-9]{1,5})[ \t]*(?:#.*)?$", m.group(1)) if m else None
print(port.group(1) if port and 0 < int(port.group(1)) < 65536 else 8787)
PY
}

# teams_files_unit <node binary> → systemd unit for the node file server
# (ADR 0007): loopback only, DynamicUser, state in /var/lib/torii-teams-files.
teams_files_unit() {
  local node="$1"
  [[ "$node" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
  cat <<UNIT
# written by torii-suite (lib/teams-app.sh); torii-teams ADR 0007
[Unit]
Description=Torii Teams file server (encrypted team media)
After=network.target continuum-agent.service

[Service]
ExecStart=${node} /opt/torii/teams-files/server.mjs
EnvironmentFile=/etc/torii/teams/files.env
DynamicUser=yes
StateDirectory=torii-teams-files
StateDirectoryMode=0700
UMask=0077
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
CapabilityBoundingSet=
SystemCallArchitectures=native
IPAddressDeny=any
IPAddressAllow=localhost
MemoryMax=256M

[Install]
WantedBy=multi-user.target
UNIT
}
