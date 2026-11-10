#!/usr/bin/env bash
# torii-suite/installers/install-auctions.sh — Plebeian Auctions (fake sats).
# Opt-in (INSTALL_AUCTIONS=1). Team-only: no launcher card, never registered
# with the torii sidecar, not linked from the homepage, noindex (Suite ADR 0002).
#
#   https://auctions.<domain>/   the arena, on its own origin (browser keys
#                                and wallets stay apart from the other apps)
#
# Services (loopback only, systemd-sandboxed, DynamicUser):
#   plebeian-auctions-mint   Nutshell FakeWallet mint      127.0.0.1:AUCTIONS_MINT_PORT
#   plebeian-auctions        gateway + four CometBFT validators
#                            gateway 127.0.0.1:AUCTIONS_PORT; validators
#                            26656-26687 and 7101-7104 on loopback
# State: /var/lib/plebeian-auctions{,-mint}. Config: /etc/torii/auctions.
#
# Prebuilt, checksum-pinned release from ChiefmonkeyArt/plebeian-arena-auctions
# (bundled CPython + Nutshell, static Go binary); nothing is built on the box.
#   AUCTIONS_RESET=1   wipe the chain and the mint (all fake sats) on this run
#   AUCTIONS_REMOVE=1  stop and remove the app (state is kept)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/auctions.sh
source "$ROOT/lib/auctions.sh"
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m--  %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx  install-auctions: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '  ..  install-auctions: %s\n' "$*"; }
[[ "${INSTALL_AUCTIONS:-0}" == 1 || "${AUCTIONS_REMOVE:-0}" == 1 ]] \
  || { echo "Plebeian Auctions install skipped (INSTALL_AUCTIONS=0)"; exit 0; }
[[ $EUID -eq 0 ]] || die "requires root"
: "${TORII_DOMAIN:?install-auctions: TORII_DOMAIN not set (run via bootstrap.sh)}"

APP_HOST="${AUCTIONS_HOST:-auctions.${TORII_DOMAIN}}"
auctions_valid_host "$TORII_DOMAIN" || die "bad TORII_DOMAIN"
auctions_valid_host "$APP_HOST" || die "bad AUCTIONS_HOST (the app needs its own host name)"
APPS_ROOT="${APPS_ROOT:-/apps}"
APP_DIR="${APPS_ROOT}/plebeian-auctions"
CONFIG=/etc/torii/auctions
UNITS=(plebeian-auctions.service plebeian-auctions-mint.service)
VHOST="/etc/nginx/sites-available/${APP_HOST}.conf"
VHOST_LINK="/etc/nginx/sites-enabled/${APP_HOST}.conf"
SNIPPETS="${AUCTIONS_SNIPPET_DIR:-/opt/torii/nginx-snippets}"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"

if [[ "${AUCTIONS_REMOVE:-0}" == 1 ]]; then
  log "removing Plebeian Auctions (state in /var/lib/plebeian-auctions* is kept)"
  [[ "$SKIP_SYSTEMD" == 1 ]] || systemctl disable --now "${UNITS[@]}" >/dev/null 2>&1 || true
  rm -f -- "$VHOST_LINK" "$VHOST" "$SNIPPETS/auctions-headers.inc" /etc/systemd/system/plebeian-auctions.service \
    /etc/systemd/system/plebeian-auctions-mint.service
  [[ "$SKIP_SYSTEMD" == 1 ]] || systemctl daemon-reload
  nginx -t && systemctl reload nginx
  exit 0
fi

# Pinned release (v0.3.0 = plebeian-arena-auctions 088957c; SHA-256 of the CI-built
# release asset). Bumped together with the Suite version; an operator may pin
# another release by setting BOTH (the checksum is never fetched from the release).
AUCTIONS_TAG="${AUCTIONS_TAG:-v0.3.0}"
AUCTIONS_SHA256="${AUCTIONS_SHA256:-b2e8691f658614fe776ffb9698a0dbaab5794ed6ec0b5a316b37abb1e8428d2b}"
[[ "$AUCTIONS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad AUCTIONS_TAG"
[[ "$AUCTIONS_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "bad AUCTIONS_SHA256"
# Lock margin: seconds after an auction's hard end before a bidder can reclaim
# escrow alone; the seller must collect within it. Demo controls expose the
# unauthenticated validator stop/start route; on for the team demo only, and
# must be 0 before real sats.
AUCTIONS_LOCK_MARGIN="${AUCTIONS_LOCK_MARGIN:-86400}"
AUCTIONS_DEMO_CONTROLS="${AUCTIONS_DEMO_CONTROLS:-1}"
[[ "$AUCTIONS_LOCK_MARGIN" =~ ^[0-9]{2,7}$ ]] || die "bad AUCTIONS_LOCK_MARGIN (10-9999999 seconds)"
[[ "$AUCTIONS_DEMO_CONTROLS" =~ ^[01]$ ]] || die "bad AUCTIONS_DEMO_CONTROLS (0 or 1)"
# Ports: an explicit setting wins; then what an earlier install chose
# ($CONFIG/ports); then the default, or on a first install the next free port.
port_given="${AUCTIONS_PORT:+1}" mint_given="${AUCTIONS_MINT_PORT:+1}"
AUCTIONS_PORT="${AUCTIONS_PORT:-$(auctions_saved_port "$CONFIG/ports" AUCTIONS_PORT || echo 8795)}"
AUCTIONS_MINT_PORT="${AUCTIONS_MINT_PORT:-$(auctions_saved_port "$CONFIG/ports" AUCTIONS_MINT_PORT || echo 13338)}"
auctions_valid_port "$AUCTIONS_PORT" && auctions_valid_port "$AUCTIONS_MINT_PORT" \
  && [[ "$AUCTIONS_PORT" != "$AUCTIONS_MINT_PORT" ]] || die "bad AUCTIONS_PORT / AUCTIONS_MINT_PORT"
[[ "$(uname -m)" == x86_64 ]] || die "the release is built for x86_64 only"
for c in curl tar sha256sum python3 nginx ss openssl; do command -v "$c" >/dev/null || die "$c not found"; done

CACHE="${SUITE_WORK_DIR:-/opt/torii-suite/work}/artifacts"
NAME="plebeian-auctions-${AUCTIONS_TAG}"
TARBALL="${AUCTIONS_TARBALL:-${CACHE}/${NAME}.tar.gz}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# 1. Ports: on a first install, nothing else may hold the arena's loopback ports.
running=0
[[ "$SKIP_SYSTEMD" != 1 ]] && systemctl is-active --quiet plebeian-auctions.service && running=1
if (( running == 0 )); then
  if [[ -z "$port_given" ]] && [[ -n "$(auctions_busy_ports "$AUCTIONS_PORT")" ]]; then
    p="$(auctions_free_port "$AUCTIONS_PORT" "$AUCTIONS_MINT_PORT")" || die "no free gateway port near $AUCTIONS_PORT"
    info "port $AUCTIONS_PORT is taken; the gateway uses $p"; AUCTIONS_PORT="$p"
  fi
  if [[ -z "$mint_given" ]] && [[ -n "$(auctions_busy_ports "$AUCTIONS_MINT_PORT")" ]]; then
    p="$(auctions_free_port "$AUCTIONS_MINT_PORT" "$AUCTIONS_PORT")" || die "no free mint port near $AUCTIONS_MINT_PORT"
    info "port $AUCTIONS_MINT_PORT is taken; the mint uses $p"; AUCTIONS_MINT_PORT="$p"
  fi
  # shellcheck disable=SC2046
  busy="$(auctions_busy_ports "$AUCTIONS_PORT" "$AUCTIONS_MINT_PORT" $(auctions_validator_ports) | tr '\n' ' ')"
  [[ -z "${busy// }" ]] || die "ports already in use: ${busy}(set AUCTIONS_PORT / AUCTIONS_MINT_PORT, or free them)"
fi

# 2. Fetch and verify against the pinned checksum (fail closed).
if [[ -z "${AUCTIONS_TARBALL:-}" && ! -s "$TARBALL" ]]; then
  mkdir -p "$CACHE"
  log "downloading ${NAME}"
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 600 -o "${TARBALL}.part" \
    "https://github.com/ChiefmonkeyArt/plebeian-arena-auctions/releases/download/${AUCTIONS_TAG}/${NAME}.tar.gz" \
    || { rm -f -- "${TARBALL}.part"; die "download failed for ${AUCTIONS_TAG}"; }
  mv -- "${TARBALL}.part" "$TARBALL"
fi
printf '%s  %s\n' "$AUCTIONS_SHA256" "$TARBALL" | sha256sum --check --status \
  || { [[ -n "${AUCTIONS_TARBALL:-}" ]] || rm -f -- "$TARBALL"; die "checksum mismatch for ${NAME}"; }

# 3. Unpack and sanity-check before anything live changes.
mkdir "$TMP/x"
tar -xzf "$TARBALL" -C "$TMP/x" --no-same-owner --no-same-permissions
for f in MANIFEST.json bin/arena bin/arena-frost web/index.html runtime/python/bin/python3; do
  [[ -e "$TMP/x/$f" ]] || die "artifact is missing $f"
done
auctions_safe_tree "$TMP/x" || die "artifact has a symlink that leaves the release"
MANIFEST_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$TMP/x/MANIFEST.json")"
[[ "$MANIFEST_TAG" == "$AUCTIONS_TAG" ]] || die "artifact is ${MANIFEST_TAG}, expected ${AUCTIONS_TAG}"
"$TMP/x/runtime/python/bin/python3" -c 'import cashu.mint.main' || die "bundled mint runtime does not load"
CSP="$(auctions_csp "$TMP/x/web/index.html")" || die "could not derive the Content-Security-Policy"

# 4. Release snapshot (bytecode compiled once, gzip copies for gzip_static).
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-${AUCTIONS_TAG}"
RELEASE="${APP_DIR}/releases/${STAMP}"
mkdir -p "${APP_DIR}/releases"
cp -a "$TMP/x/." "$RELEASE/"
"$RELEASE/runtime/python/bin/python3" -m compileall -q -j 0 "$RELEASE/runtime/python/lib" >/dev/null 2>&1 || true
find "$RELEASE/web" -type f -size +1k \( -name '*.js' -o -name '*.css' -o -name '*.html' -o -name '*.svg' \
  -o -name '*.json' -o -name '*.txt' \) -exec gzip -9 -k -n -f {} +
chown -R root:root "$RELEASE"
find "$RELEASE" -type d -exec chmod 755 {} +
find "$RELEASE" -type f ! -perm -u+x -exec chmod 644 {} +
find "$RELEASE" -type f -perm -u+x -exec chmod 755 {} +

# 5. Config: the mint key is made once and kept, so the keyset (and every
#    escrow already on the chain) survives upgrades.
install -d -m 0700 -o root -g root "$CONFIG"
[[ ! -L "$CONFIG/mint.env" ]] || die "refusing symlinked $CONFIG/mint.env"
KEY=""
[[ -f "$CONFIG/mint.env" ]] && KEY="$(sed -n 's/^MINT_PRIVATE_KEY=\([0-9a-f]\{64\}\)$/\1/p' "$CONFIG/mint.env")"
[[ -n "$KEY" ]] || KEY="$(openssl rand -hex 32)"
{ auctions_mint_env "$AUCTIONS_MINT_PORT" /var/lib/plebeian-auctions-mint || die "could not write the mint settings"
  printf 'MINT_PRIVATE_KEY=%s\n' "$KEY"; } > "$TMP/mint.env"
install -m 0600 -o root -g root "$TMP/mint.env" "$CONFIG/mint.env"
[[ ! -L "$CONFIG/ports" ]] || die "refusing symlinked $CONFIG/ports"
printf 'AUCTIONS_PORT=%s\nAUCTIONS_MINT_PORT=%s\n' "$AUCTIONS_PORT" "$AUCTIONS_MINT_PORT" > "$TMP/ports"
install -m 0600 -o root -g root "$TMP/ports" "$CONFIG/ports"

# 6. Units, stop, flip, start. Keep the last 2 releases (each carries a Python).
auctions_mint_unit "$APP_DIR" > "$TMP/mint.unit" || die "could not write the mint unit"
auctions_chain_unit "$APP_DIR" "$AUCTIONS_PORT" "$AUCTIONS_MINT_PORT" "$AUCTIONS_LOCK_MARGIN" "$AUCTIONS_DEMO_CONTROLS" > "$TMP/chain.unit" || die "could not write the gateway unit"
if [[ "$SKIP_SYSTEMD" != 1 ]]; then systemctl stop "${UNITS[@]}" >/dev/null 2>&1 || true; fi
install -m 0644 "$TMP/mint.unit" /etc/systemd/system/plebeian-auctions-mint.service
install -m 0644 "$TMP/chain.unit" /etc/systemd/system/plebeian-auctions.service
ln -sfn "$RELEASE" "${APP_DIR}/current.new"
mv -Tf "${APP_DIR}/current.new" "${APP_DIR}/current"
find "${APP_DIR}/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -2 | xargs -r rm -rf
if [[ "${AUCTIONS_RESET:-0}" == 1 ]]; then
  warn "AUCTIONS_RESET=1: wiping the chain and the mint (every fake sat)"
  rm -rf /var/lib/plebeian-auctions /var/lib/private/plebeian-auctions \
    /var/lib/plebeian-auctions-mint /var/lib/private/plebeian-auctions-mint
fi
if [[ "$SKIP_SYSTEMD" != 1 ]]; then
  systemctl daemon-reload
  systemctl enable "${UNITS[@]}" >/dev/null 2>&1
  systemctl start plebeian-auctions-mint.service plebeian-auctions.service \
    || die "services did not start: journalctl -u plebeian-auctions -u plebeian-auctions-mint"
  for _ in $(seq 1 60); do
    curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${AUCTIONS_PORT}/api/network" && break; sleep 1
  done
  curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${AUCTIONS_PORT}/api/network" \
    || die "gateway not answering on 127.0.0.1:${AUCTIONS_PORT}: journalctl -u plebeian-auctions"
fi

# 7. Headers snippet + vhost on its own certificate. No launcher tile, no
#    main-domain fragment: the address is shared with the team directly.
mkdir -p "$SNIPPETS"
auctions_security_headers "$CSP" > "$SNIPPETS/auctions-headers.inc" || die "invalid CSP"
chmod 0644 "$SNIPPETS/auctions-headers.inc"
SKIP_CERTBOT="${SKIP_CERTBOT:-0}"
CERT_DIR="/etc/letsencrypt/live/${APP_HOST}"
install -d -m 0755 /var/www/certbot /etc/nginx/sites-available /etc/nginx/sites-enabled
acme_block() {
  cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${APP_HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX
}
if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  A_RECORDS="$(dig +short A "$APP_HOST" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
  if [[ "$SKIP_CERTBOT" == 1 ]]; then
    warn "SKIP_CERTBOT=1 - no certificate for ${APP_HOST}; the app is not served until there is one"
  elif [[ -z "$A_RECORDS" ]] || [[ -n "$PUBLIC_IP" && " $A_RECORDS " != *" $PUBLIC_IP "* ]]; then
    die "DNS: point ${APP_HOST} at this VPS (A record), or set SKIP_CERTBOT=1"
  else
    command -v certbot >/dev/null || die "certbot not found (torii-base must run first)"
    acme_block > "$VHOST"; ln -sf "$VHOST" "$VHOST_LINK"
    nginx -t && systemctl reload nginx
    EMAIL_ARG=(--register-unsafely-without-email)
    [[ -n "${LETSENCRYPT_EMAIL:-}" ]] && EMAIL_ARG=(--email "$LETSENCRYPT_EMAIL")
    certbot certonly --webroot -w /var/www/certbot -d "$APP_HOST" --non-interactive --agree-tos "${EMAIL_ARG[@]}" \
      || die "certbot failed for ${APP_HOST}"
  fi
fi
H="include ${SNIPPETS}/auctions-headers.inc;"
P="proxy_pass http://127.0.0.1:${AUCTIONS_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_read_timeout 30s;"
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  { echo "# ${VHOST} - written by torii-suite install-auctions.sh (${AUCTIONS_TAG})"
    echo "# Team-only (Suite ADR 0002): no launcher card; never indexed."
    echo "limit_req_zone \$binary_remote_addr zone=torii_auctions:10m rate=30r/s;"
    acme_block
    cat <<NGINX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${APP_HOST};
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    root ${APP_DIR}/current/web;
    index index.html;
    server_tokens off;
    client_max_body_size 64k;
    gzip_static on;
    gzip_vary on;
    if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }

    location /.well-known/ { return 404; }
    location /api/ {
        limit_req zone=torii_auctions burst=60 nodelay;
        add_header Cache-Control "no-store" always;
        ${H}
        ${P}
    }
    location /mint/ {
        limit_req zone=torii_auctions burst=60 nodelay;
        add_header Cache-Control "no-store" always;
        ${H}
        ${P}
    }
    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        ${H}
        try_files \$uri =404;
    }
    location / {
        if (\$request_method = POST) { return 405; }
        add_header Cache-Control "no-cache" always;
        ${H}
        try_files \$uri /index.html;
    }
}
NGINX
  } > "$TMP/vhost"
else
  { echo "# ${VHOST} - written by torii-suite install-auctions.sh; no certificate yet."
    echo "# Re-run after DNS for ${APP_HOST} points here; the app is never served over plain HTTP."
    cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${APP_HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { default_type text/plain; return 200 "plebeian-auctions: no TLS certificate yet\n"; }
}
NGINX
  } > "$TMP/vhost"
fi
install -m 0644 "$TMP/vhost" "$VHOST"
ln -sf "$VHOST" "$VHOST_LINK"
nginx -t || die "nginx config test failed"
systemctl reload nginx

log "Plebeian Auctions ${AUCTIONS_TAG}: https://${APP_HOST}/ (team-only, no launcher card; fake sats)"
