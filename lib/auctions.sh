#!/usr/bin/env bash
# torii-suite/lib/auctions.sh — helpers for installers/install-auctions.sh.
# Sourced; pure functions so test/install-auctions.test.sh can run them as a user.
# Design: docs/AUCTIONS.md, Suite ADR 0002 (team-only app, no launcher card).

AUCTIONS_HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
auctions_valid_host() { [[ "${1:-}" =~ $AUCTIONS_HOST_RE ]]; }
auctions_valid_port() { [[ "${1:-}" =~ ^[0-9]{2,5}$ ]] && (( 1024 < $1 && $1 < 65536 )); }

# The arena's fixed loopback ports: per validator i=0..3, CometBFT p2p
# 26656+10i and rpc 26657+10i, and the co-signer 7101+i.
auctions_validator_ports() {
  local i
  for i in 0 1 2 3; do printf '%s %s %s\n' $((26656 + 10 * i)) $((26657 + 10 * i)) $((7101 + i)); done | tr ' ' '\n'
}

# auctions_busy_ports <port...> → prints each port that something is listening on.
auctions_busy_ports() {
  local listening p
  listening="$(ss -Htln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u)"
  for p in "$@"; do grep -qx -- "$p" <<<"$listening" && printf '%s\n' "$p"; done
  return 0
}

# auctions_free_port <start> <taken...> → the first port from <start> (up to
# +50) that nothing listens on and is not in <taken>. Non-zero if none.
auctions_free_port() {
  local start="$1" p; shift
  local taken
  # shellcheck disable=SC2046
  taken=" $* $(auctions_busy_ports $(seq "$start" $((start + 50))) | tr '\n' ' ') "
  for ((p = start; p <= start + 50; p++)); do
    [[ "$taken" == *" $p "* ]] || { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# auctions_saved_port <file> <KEY> → the port saved by an earlier install, if valid.
auctions_saved_port() {
  local v
  [[ -f "$1" && ! -L "$1" ]] || return 1
  v="$(sed -n "s/^$2=\([0-9]\{2,5\}\)$/\1/p" "$1" | head -n1)"
  auctions_valid_port "$v" && printf '%s\n' "$v"
}

# auctions_safe_tree <dir> → 0 when every symlink is relative and stays inside
# <dir> (the bundled CPython has a few, e.g. bin/python3 -> python3.12).
auctions_safe_tree() {
  local root link target
  root="$(cd -- "$1" && pwd -P)" || return 1
  while IFS= read -r -d '' link; do
    target="$(readlink -- "$link")"
    [[ "$target" != /* ]] || return 1
    case "$(realpath -m -- "$(dirname -- "$link")/$target")" in "$root"/*) ;; *) return 1 ;; esac
  done < <(find "$root" -type l -print0)
}

# auctions_csp <index.html> → the Content-Security-Policy for this build: every
# inline <script> gets a sha256 hash; the app may reach only its own origin.
auctions_csp() {
  local index="$1" hashes
  [[ -f "$index" ]] || return 1
  hashes="$(python3 - "$index" <<'PY'
import base64, hashlib, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
for body in re.findall(r"<script>(.*?)</script>", html, re.S):
    print("'sha256-%s'" % base64.b64encode(hashlib.sha256(body.encode()).digest()).decode())
PY
)" || return 1
  printf "default-src 'self'; script-src 'self'%s; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self'; connect-src 'self'; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\n" \
    "$(printf '%s\n' "$hashes" | sed '/^$/d; s/^/ /' | tr -d '\n')"
}

# auctions_security_headers <csp> → nginx add_header block (re-declared in each
# location: one with its own add_header drops the server-level ones).
auctions_security_headers() {
  local csp="$1"
  [[ "$csp" =~ ^[A-Za-z0-9\ \;:/\'+=._*-]+$ ]] || return 1
  cat <<NGINX
# written by torii-suite (lib/auctions.sh). Team-only: never indexed.
add_header Content-Security-Policy "${csp}" always;
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "no-referrer" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header X-Robots-Tag "noindex, nofollow" always;
NGINX
}

# auctions_mint_env <port> <state dir> → the fake-sats mint settings (Nutshell
# FakeWallet: invoices pay themselves). MINT_PRIVATE_KEY is appended once by
# the installer and never rewritten, so the keyset survives upgrades.
auctions_mint_env() {
  local port="$1" state="$2"
  auctions_valid_port "$port" && [[ "$state" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
  cat <<ENV
# written by torii-suite install-auctions.sh. FAKE SATS ONLY: no real Lightning.
MINT_BACKEND_BOLT11_SAT=FakeWallet
MINT_LISTEN_HOST=127.0.0.1
MINT_LISTEN_PORT=${port}
MINT_DATABASE=${state}/db
MINT_INPUT_FEE_PPK=0
MINT_RATE_LIMIT=FALSE
MINT_INFO_NAME="Plebeian Auctions fake-sats mint"
FAKEWALLET_BRR=TRUE
FAKEWALLET_DELAY_INCOMING_PAYMENT=1
FAKEWALLET_DELAY_OUTGOING_PAYMENT=1
ENV
}

# Shared systemd sandbox: loopback only, no writes outside the state directory.
_auctions_sandbox() {
  cat <<UNIT
DynamicUser=yes
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
CapabilityBoundingSet=
SystemCallArchitectures=native
IPAddressDeny=any
IPAddressAllow=localhost
UNIT
}

# auctions_mint_unit <app dir> → the fake-sats mint unit.
auctions_mint_unit() {
  local app="$1"
  [[ "$app" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
  cat <<UNIT
# written by torii-suite (lib/auctions.sh); Suite ADR 0002
[Unit]
Description=Plebeian Auctions fake-sats Cashu mint (Nutshell FakeWallet)
After=network.target

[Service]
ExecStart=${app}/current/runtime/python/bin/python3 -m cashu.mint
EnvironmentFile=/etc/torii/auctions/mint.env
Environment=HOME=/var/lib/plebeian-auctions-mint PYTHONDONTWRITEBYTECODE=1
WorkingDirectory=/var/lib/plebeian-auctions-mint
StateDirectory=plebeian-auctions-mint
StateDirectoryMode=0700
MemoryMax=384M
$(_auctions_sandbox)

[Install]
WantedBy=multi-user.target
UNIT
}

# auctions_chain_unit <app dir> <gateway port> <mint port> [lock margin s] [demo 0|1]
# → the gateway unit. The gateway supervises the four validator processes
# (CometBFT + co-signer); the chain is created on first start, once the mint
# answers. "arena init -if-needed" keeps a chain only when its FORMAT marker
# matches the release (v0.3.0-v0.3.3: format 3), otherwise it replaces the whole root.
# Demo controls (unauthenticated validator stop/start) are off unless demo=1.
auctions_chain_unit() {
  local app="$1" port="$2" mport="$3" margin="${4:-86400}" demo="${5:-0}" s=/var/lib/plebeian-auctions dflag=""
  [[ "$app" =~ ^/[A-Za-z0-9/._-]+$ ]] && auctions_valid_port "$port" && auctions_valid_port "$mport" || return 1
  [[ "$margin" =~ ^[0-9]{2,7}$ ]] && [[ "$demo" =~ ^[01]$ ]] || return 1
  [[ "$demo" == 1 ]] && dflag=" -demo-controls"
  cat <<UNIT
# written by torii-suite (lib/auctions.sh); Suite ADR 0002
[Unit]
Description=Plebeian Auctions gateway and four validators (fake sats)
After=network.target plebeian-auctions-mint.service
Requires=plebeian-auctions-mint.service

[Service]
ExecStartPre=/bin/sh -c 'for i in \$\$(seq 60); do /usr/bin/curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:${mport}/v1/info && exit 0; sleep 1; done; exit 1'
ExecStartPre=${app}/current/bin/arena init -if-needed -root ${s}/chain -mint http://127.0.0.1:${mport} -lock-margin ${margin}
ExecStart=${app}/current/bin/arena gateway -root ${s}/chain -static ${app}/current/web -addr 127.0.0.1:${port} -mint http://127.0.0.1:${mport}${dflag}
WorkingDirectory=${s}
StateDirectory=plebeian-auctions
StateDirectoryMode=0700
KillMode=mixed
TimeoutStopSec=20
MemoryMax=768M
$(_auctions_sandbox)

[Install]
WantedBy=multi-user.target
UNIT
}
