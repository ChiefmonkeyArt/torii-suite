#!/usr/bin/env bash
# torii-suite/installers/install-teams-app.sh — Torii Teams web app (TEAMS-2c a).
# Opt-in (INSTALL_TEAMS_APP=1); needs the Teams services (install-teams.sh).
#
#   https://teams.<domain>/        the app, on its own origin (chat keys stay
#                                  apart from Quest and Continuum)
#   https://teams.<domain>/torii-node.json
#                                  node settings: coordinator from coord.pub,
#                                  wss://relay.<domain>, optional Continuum
#   /teams/ on the main host       launcher tile, redirects to the app
#
# Prebuilt, checksum-pinned release from ChiefmonkeyArt/torii-teams; no build on
# the box. Design: torii-teams docs/torii/adr-0001-node-mount.md, docs/TEAMS.md.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/teams-app.sh
source "$ROOT/lib/teams-app.sh"
[[ "${INSTALL_TEAMS_APP:-0}" == 1 ]] || { echo "Teams app install skipped (INSTALL_TEAMS_APP=0)"; exit 0; }
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m--  %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx  install-teams-app: %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "requires root"
: "${TORII_DOMAIN:?install-teams-app: TORII_DOMAIN not set (run via bootstrap.sh)}"

# Pinned release. Bumped together with the Suite version; an operator may pin
# another release by setting BOTH (the checksum is never fetched from the release).
# 0.6.1-torii.1 = torii-teams d2a2f22; SHA-256 checked against the GitHub release
# and its build-provenance attestation.
TEAMS_APP_TAG="${TEAMS_APP_TAG:-0.6.1-torii.1}"
TEAMS_APP_SHA256="${TEAMS_APP_SHA256:-8f7ae476417845111703c96fe94412de595d5e6816d364bfd53a66a442d760ea}"
[[ -n "$TEAMS_APP_TAG" && -n "$TEAMS_APP_SHA256" ]] \
  || die "no Torii Teams release pinned yet (set TEAMS_APP_TAG and TEAMS_APP_SHA256)"
[[ "$TEAMS_APP_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+-torii\.[0-9]+$ ]] || die "bad TEAMS_APP_TAG"
[[ "$TEAMS_APP_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "bad TEAMS_APP_SHA256"

CONFIG=/etc/torii/teams
PK="$(teams_coord_pub "$CONFIG/coord.pub")" \
  || die "no valid $CONFIG/coord.pub: install the Teams services first (INSTALL_TEAMS=1)"
APP_HOST="${TORII_TEAMS_HOST-teams.${TORII_DOMAIN}}"
RELAY_HOST="${TORII_RELAY_HOST-relay.${TORII_DOMAIN}}"
teams_valid_host "$TORII_DOMAIN" || die "bad TORII_DOMAIN"
teams_valid_host "$APP_HOST" || die "bad TORII_TEAMS_HOST (the app needs its own host name)"
teams_valid_host "$RELAY_HOST" || die "the app needs the relay subdomain (TORII_RELAY_HOST)"
GIT_URL=""
if [[ -f "$CONFIG/teams.env" ]]; then
  GIT_HOST="$(sed -n 's/^GIT_HOST=//p' "$CONFIG/teams.env")"
  GIT_PORT="$(sed -n 's/^GIT_PORT=//p' "$CONFIG/teams.env")"
  MESH_IP="$(sed -n 's/^MESH_IP=//p' "$CONFIG/teams.env")"
  [[ -n "$MESH_IP" && -n "$GIT_HOST" ]] && GIT_URL="http://${GIT_HOST}.fips:${GIT_PORT}"
fi
for c in curl tar sha256sum python3 nginx; do command -v "$c" >/dev/null || die "$c not found"; done

APPS_ROOT="${APPS_ROOT:-/apps}"
APP_DIR="${APPS_ROOT}/teams-app"
CACHE="${SUITE_WORK_DIR:-/opt/torii-suite/work}/artifacts"
NAME="torii-teams-${TEAMS_APP_TAG}"
TARBALL="${TEAMS_APP_TARBALL:-${CACHE}/${NAME}.tar.gz}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# 1. Fetch and verify against the pinned checksum (fail closed).
if [[ -z "${TEAMS_APP_TARBALL:-}" && ! -s "$TARBALL" ]]; then
  mkdir -p "$CACHE"
  log "downloading ${NAME}"
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 -o "${TARBALL}.part" \
    "https://github.com/ChiefmonkeyArt/torii-teams/releases/download/${TEAMS_APP_TAG}/${NAME}.tar.gz" \
    || { rm -f -- "${TARBALL}.part"; die "download failed for ${TEAMS_APP_TAG}"; }
  mv -- "${TARBALL}.part" "$TARBALL"
fi
printf '%s  %s\n' "$TEAMS_APP_SHA256" "$TARBALL" | sha256sum --check --status \
  || { [[ -n "${TEAMS_APP_TARBALL:-}" ]] || rm -f -- "$TARBALL"; die "checksum mismatch for ${NAME}"; }

# 2. Unpack and sanity-check before anything live changes.
mkdir "$TMP/x"
tar -xzf "$TARBALL" -C "$TMP/x" --no-same-owner --no-same-permissions
[[ -f "$TMP/x/index.html" && -f "$TMP/x/MANIFEST.json" ]] || die "artifact is missing index.html or MANIFEST.json"
[[ ! -e "$TMP/x/torii-node.json" ]] || die "artifact ships torii-node.json (node settings belong to the installer)"
[[ -z "$(find "$TMP/x" -type l -print -quit)" ]] || die "artifact contains symlinks"
# Upstream Cordn identity files (NIP-05 names, Android app links) are not ours.
rm -rf -- "$TMP/x/.well-known" "$TMP/x/_headers" "$TMP/x/_redirects"
MANIFEST_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$TMP/x/MANIFEST.json")"
[[ "$MANIFEST_TAG" == "$TEAMS_APP_TAG" ]] || die "artifact is ${MANIFEST_TAG}, expected ${TEAMS_APP_TAG}"
CSP="$(teams_csp "$TMP/x/index.html")" || die "could not derive the Content-Security-Policy"

# 3. Release snapshot + atomic flip, keep the last 3.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-${TEAMS_APP_TAG}"
RELEASE="${APP_DIR}/releases/${STAMP}"
mkdir -p "${APP_DIR}/releases"
cp -a "$TMP/x/." "$RELEASE/"
chown -R root:root "$RELEASE"
find "$RELEASE" -type d -exec chmod 755 {} +
find "$RELEASE" -type f -exec chmod 644 {} +
ln -sfn "$RELEASE" "${APP_DIR}/current.new"
mv -Tf "${APP_DIR}/current.new" "${APP_DIR}/current"
find "${APP_DIR}/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf

# 4. Node settings, outside the release tree, 0644 root.
CONTINUUM=0
CONTINUUM_CONFIG="${SUITE_WORK_DIR:-/opt/torii-suite/work}/torii-continuum/agent/config.yaml"
[[ -f "$CONTINUUM_CONFIG" && -f /etc/systemd/system/continuum-agent.service ]] && CONTINUUM=1
NODE_JSON="$CONFIG/torii-node.json"
[[ ! -L "$NODE_JSON" ]] || die "refusing symlinked $NODE_JSON"
teams_node_json "$PK" "$TORII_DOMAIN" "$RELAY_HOST" "$GIT_URL" "$CONTINUUM" > "$TMP/node.json" \
  || die "could not write node settings"
install -m 0644 -o root -g root "$TMP/node.json" "$NODE_JSON"

# 5. Continuum: allow the app origin for member sign-in (cross-origin) and set
#    teams.app_url so the Team view shows "Open team chat".
if (( CONTINUUM == 1 )); then
  [[ ! -L "$CONTINUUM_CONFIG" ]] || die "refusing symlinked $CONTINUUM_CONFIG"
  # Rewritten in place, so owner (continuum) and mode (0600) are kept.
  CHANGED="$(teams_continuum_config "$CONTINUUM_CONFIG" "https://${APP_HOST}")" \
    || die "could not update the Continuum config"
  if [[ "$CHANGED" == changed ]]; then
    log "Continuum config: cors_origins + teams.app_url = https://${APP_HOST}"
    systemctl restart continuum-agent.service
  fi
fi

# 6. Headers snippet (stable path) + vhost on its own certificate.
SNIPPETS="${TEAMS_APP_SNIPPET_DIR:-/opt/torii/nginx-snippets}"
mkdir -p "$SNIPPETS"
teams_security_headers "$CSP" > "$SNIPPETS/teams-app-headers.inc" || die "invalid CSP"
chmod 0644 "$SNIPPETS/teams-app-headers.inc"

SKIP_CERTBOT="${SKIP_CERTBOT:-0}"
CERT_DIR="/etc/letsencrypt/live/${APP_HOST}"
VHOST="/etc/nginx/sites-available/${APP_HOST}.conf"
VHOST_LINK="/etc/nginx/sites-enabled/${APP_HOST}.conf"
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
H="include ${SNIPPETS}/teams-app-headers.inc;"
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  { echo "# ${VHOST} - written by torii-suite install-teams-app.sh (${TEAMS_APP_TAG})"
    acme_block
    cat <<NGINX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${APP_HOST};
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    root ${APP_DIR}/current;
    index index.html;
    server_tokens off;
    client_max_body_size 1k;
    if (\$request_method !~ ^(GET|HEAD)\$) { return 405; }

    location /.well-known/ { return 404; }
    location = /torii-node.json {
        alias ${NODE_JSON};
        default_type application/json;
        types { }
        add_header Cache-Control "no-store" always;
        ${H}
    }
    location /_app/immutable/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        ${H}
        try_files \$uri =404;
    }
    location = /service-worker.js {
        add_header Cache-Control "no-cache" always;
        ${H}
    }
    location / {
        add_header Cache-Control "no-cache" always;
        ${H}
        try_files \$uri /index.html;
    }
}
NGINX
  } > "$TMP/vhost"
else
  { echo "# ${VHOST} - written by torii-suite install-teams-app.sh; no certificate yet."
    echo "# Re-run after DNS for ${APP_HOST} points here; the app is never served over plain HTTP."
    cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${APP_HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { default_type text/plain; return 200 "torii-teams: no TLS certificate yet\n"; }
}
NGINX
  } > "$TMP/vhost"
fi
install -m 0644 "$TMP/vhost" "$VHOST"
ln -sf "$VHOST" "$VHOST_LINK"

# 7. Launcher tile: /teams/ on the main host redirects to the app.
FRAGMENT_DIR=/opt/torii/nginx-fragments
mkdir -p "$FRAGMENT_DIR"
cat > "$FRAGMENT_DIR/teams.conf" <<NGINX
# /opt/torii/nginx-fragments/teams.conf - written by torii-suite install-teams-app.sh
# Torii Teams runs on its own origin; the launcher tile redirects there.
location = /teams  { return 302 https://${APP_HOST}/chat; }
location = /teams/ { return 302 https://${APP_HOST}/chat; }
NGINX
chmod 0644 "$FRAGMENT_DIR/teams.conf"
/usr/local/bin/torii register teams --display "Torii Teams" \
  --desc "Private team chat that turns into work" --version "${TEAMS_APP_TAG}"
/usr/local/bin/torii reload

log "Torii Teams ${TEAMS_APP_TAG}: https://${APP_HOST}/chat (coordinator ${PK:0:12}..., relay wss://${RELAY_HOST})"
