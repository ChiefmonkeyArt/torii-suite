#!/usr/bin/env bash
# torii-suite/installers/install-continuum-host.sh — Continuum on its own origin.
# Opt-in (INSTALL_CONTINUUM_HOST=1); runs after install-continuum.sh.
#
#   https://continuum.<domain>/continuum/   the app (same files, same agent)
#   https://<domain>/continuum/*            301 to the Continuum host
#   /api/ and /agent/                       served on both hosts
#
# Why: on the shared apex origin, any script from Quest or another app can read
# Continuum's owner token from localStorage. Its own origin closes that.
# Rollback: CONTINUUM_HOST_REMOVE=1 removes the redirect and the vhost.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/continuum-host.sh
source "$ROOT/lib/continuum-host.sh"
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m--  %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx  install-continuum-host: %s\033[0m\n' "$*" >&2; exit 1; }

REMOVE="${CONTINUUM_HOST_REMOVE:-0}"
[[ "${INSTALL_CONTINUUM_HOST:-0}" == 1 || "$REMOVE" == 1 ]] \
  || { echo "Continuum host skipped (INSTALL_CONTINUUM_HOST=0)"; exit 0; }
[[ $EUID -eq 0 ]] || die "requires root"
: "${TORII_DOMAIN:?install-continuum-host: TORII_DOMAIN not set (run via bootstrap.sh)}"
HOST="${CONTINUUM_HOST:-continuum.${TORII_DOMAIN}}"
continuum_valid_host "$TORII_DOMAIN" || die "bad TORII_DOMAIN"
continuum_valid_host "$HOST" && [[ "$HOST" != "$TORII_DOMAIN" ]] \
  || die "bad CONTINUUM_HOST (Continuum needs its own host name)"

FRAGMENT_DIR=/opt/torii/nginx-fragments
REDIRECT="$FRAGMENT_DIR/continuum-host.conf"
FRAGMENT="$FRAGMENT_DIR/continuum.conf"
API_SNIPPET=/etc/nginx/snippets/torii-api.conf
SNIPPETS=/opt/torii/nginx-snippets
HEADERS="$SNIPPETS/continuum-headers.inc"
VHOST="/etc/nginx/sites-available/${HOST}.conf"
VHOST_LINK="/etc/nginx/sites-enabled/${HOST}.conf"
CERT_DIR="/etc/letsencrypt/live/${HOST}"

if [[ "$REMOVE" == 1 ]]; then
  rm -f -- "$REDIRECT" "$VHOST_LINK" "$HEADERS"
  /usr/local/bin/torii reload
  log "Continuum is back on https://${TORII_DOMAIN}/continuum/ (certificate for ${HOST} kept)"
  exit 0
fi

[[ -f "$FRAGMENT" ]] || die "no $FRAGMENT: install Continuum first (INSTALL_CONTINUUM=1)"
grep -qF 'continuum-headers*.inc' "$FRAGMENT" \
  || die "$FRAGMENT predates Suite v0.9.31-alpha: re-run install-continuum.sh first"
[[ -f "$API_SNIPPET" ]] || die "no $API_SNIPPET (torii-base must run first)"
command -v nginx >/dev/null || die "nginx not found"

# 1. Headers for every Continuum location. The Teams host is validated when
#    Teams is (being) installed; no origin gets the microphone (v0.9.36-alpha).
TEAMS_HOST="${TORII_TEAMS_HOST-teams.${TORII_DOMAIN}}"
[[ "${INSTALL_TEAMS_APP:-0}" == 1 || -e "/etc/nginx/sites-enabled/${TEAMS_HOST}.conf" ]] || TEAMS_HOST=""
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
continuum_host_headers "$TEAMS_HOST" > "$TMP/headers" || die "bad TORII_TEAMS_HOST"
mkdir -p "$SNIPPETS"
install -m 0644 -o root -g root "$TMP/headers" "$HEADERS"

# 2. Certificate (webroot, same as the Teams app).
install -d -m 0755 /var/www/certbot /etc/nginx/sites-available /etc/nginx/sites-enabled
acme_block() {
  cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX
}
if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  A_RECORDS="$(dig +short A "$HOST" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
  if [[ "${SKIP_CERTBOT:-0}" == 1 ]]; then
    warn "SKIP_CERTBOT=1 - no certificate for ${HOST}; Continuum stays on https://${TORII_DOMAIN}/continuum/"
  elif [[ -z "$A_RECORDS" ]] || [[ -n "$PUBLIC_IP" && " $A_RECORDS " != *" $PUBLIC_IP "* ]]; then
    die "DNS: point ${HOST} at this VPS (A record), or set SKIP_CERTBOT=1"
  else
    command -v certbot >/dev/null || die "certbot not found (torii-base must run first)"
    acme_block > "$VHOST"; ln -sf "$VHOST" "$VHOST_LINK"
    nginx -t && systemctl reload nginx
    EMAIL_ARG=(--register-unsafely-without-email)
    [[ -n "${LETSENCRYPT_EMAIL:-}" ]] && EMAIL_ARG=(--email "$LETSENCRYPT_EMAIL")
    certbot certonly --webroot -w /var/www/certbot -d "$HOST" --non-interactive --agree-tos "${EMAIL_ARG[@]}" \
      || die "certbot failed for ${HOST}"
  fi
fi

# 3. Vhost + apex redirect, only with a certificate: never strand the app.
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  { echo "# ${VHOST} - written by torii-suite install-continuum-host.sh"
    continuum_host_vhost "$HOST" "$CERT_DIR" "$FRAGMENT" "$API_SNIPPET" "$HEADERS"
  } > "$TMP/vhost" || die "could not write the vhost"
  continuum_host_redirect "$HOST" > "$TMP/redirect"
  install -m 0644 "$TMP/vhost" "$VHOST"
  ln -sf "$VHOST" "$VHOST_LINK"
  install -m 0644 "$TMP/redirect" "$REDIRECT"
  if ! nginx -t 2>"$TMP/nginx-t"; then
    rm -f -- "$REDIRECT" "$VHOST_LINK"
    cat "$TMP/nginx-t" >&2
    die "nginx rejected the Continuum host config; rolled back"
  fi
  /usr/local/bin/torii reload
  log "Continuum: https://${HOST}/continuum/ (https://${TORII_DOMAIN}/continuum/ redirects there)"
else
  rm -f -- "$REDIRECT"
  cat > "$TMP/vhost" <<NGINX
# ${VHOST} - written by torii-suite install-continuum-host.sh; no certificate yet.
# Re-run after DNS for ${HOST} points here.
server {
    listen 80;
    listen [::]:80;
    server_name ${HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { default_type text/plain; return 200 "continuum: no TLS certificate yet\n"; }
}
NGINX
  install -m 0644 "$TMP/vhost" "$VHOST"; ln -sf "$VHOST" "$VHOST_LINK"
  /usr/local/bin/torii reload
fi
