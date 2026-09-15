#!/usr/bin/env bash
# torii-suite/installers/install-nostr-git.sh
#
# Installs sovereign Nostr git-mirror infrastructure on the VPS:
#   - strfry Nostr relay (built from pinned source, loopback-only, systemd)
#   - git smart-HTTP host via fcgiwrap + git-http-backend (read-only)
#   - nginx routes: /relay (WSS proxy) + /git (read-only smart-HTTP)
#
# Keyless by design: no nsec, no project names, no announcement logic. This
# stage provisions empty infra (/opt/torii/git + a running relay); Continuum
# (slice CONT-NIP34-MIRROR-1) populates it with browser-signed kind:30617
# repos. Same seam as Suite<->Quest: the suite installs, it does not know the
# consumers' internals.
#
# Why build strfry from source: strfry publishes no prebuilt release binaries
# (tag-only source on github.com/hoytech/strfry). Compiling our own binary from
# a pinned tag is the sovereign path -- no opaque blob to trust. The build is
# skipped on re-run when the binary already exists at the pinned tag.
#
# What this does (idempotent on re-run):
#   1. Installs build deps + builds strfry from the pinned source tag
#   2. Writes /opt/torii/relay/strfry.conf (loopback bind, configured port/db)
#   3. Writes torii-relay.service (hardened, torii-relay system user)
#   4. Installs fcgiwrap + enables its socket
#   5. Creates empty /opt/torii/git (GIT_HOST_ROOT) for Continuum to populate
#   6. Writes nginx fragments: relay.conf + git.conf
#   7. Reloads nginx via the torii sidecar
#
# Env (inherited from bootstrap.sh):
#   TORII_DOMAIN, SUITE_WORK_DIR, NOSTR_RELAY_PORT, NOSTR_RELAY_DB,
#   GIT_HOST_ROOT, NOSTR_PUBLIC_RELAYS, STRFRY_REF,
#   TORII_RELAY_HOST (default: relay.<TORII_DOMAIN>), LETSENCRYPT_EMAIL,
#   SKIP_CERTBOT (default: 0)
#
# Subdomain mode (v0.9.8-alpha, SUITE-RELAY-SUBDOMAIN-1):
# The default relay endpoint is now wss://relay.<TORII_DOMAIN> served from a
# dedicated sites-available vhost with its own Let's Encrypt cert. This is
# the recommended path -- it matches what NIP-17 clients (and the Continuum
# nap-bridge) look for by default (`relay.<domain>`), and it keeps the main
# domain's app fragments unaffected by relay traffic. The path-based
# wss://<TORII_DOMAIN>/relay fragment is still written (backward compat with
# any existing clients pointed at it), but the subdomain is preferred. Set
# TORII_RELAY_HOST="" to skip subdomain provisioning (path-only mode).

set -euo pipefail

INSTALL_NOSTR_GIT="${INSTALL_NOSTR_GIT:-1}"
if [[ "$INSTALL_NOSTR_GIT" != "1" ]]; then
  printf "\033[36m==>\033[0m INSTALL_NOSTR_GIT=0 - skipping Nostr relay + git host install\n"
  exit 0
fi

: "${TORII_DOMAIN:?install-nostr-git: TORII_DOMAIN not set (run via bootstrap.sh)}"
: "${SUITE_WORK_DIR:?install-nostr-git: SUITE_WORK_DIR not set (run via bootstrap.sh)}"

NOSTR_RELAY_PORT="${NOSTR_RELAY_PORT:-7777}"
NOSTR_RELAY_DB="${NOSTR_RELAY_DB:-/opt/torii/relay/db}"
GIT_HOST_ROOT="${GIT_HOST_ROOT:-/opt/torii/git}"
# v0.9.7-alpha (BEKKA-READY-6): dropped damus (503-degraded). See bootstrap.sh.
NOSTR_PUBLIC_RELAYS="${NOSTR_PUBLIC_RELAYS:-wss://nos.lol,wss://relay.nostr.band,wss://relay.primal.net}"
STRFRY_REF="${STRFRY_REF:-1.1.0}"

# Subdomain relay host. Empty string opts out (path-only mode). Anything else
# is provisioned as a dedicated vhost with its own Let's Encrypt cert.
TORII_RELAY_HOST="${TORII_RELAY_HOST:-relay.${TORII_DOMAIN}}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SKIP_CERTBOT="${SKIP_CERTBOT:-0}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install-nostr-git must run as root"

# nginx + the torii sidecar are provided by torii-base. The fragments below
# are include'd into the base server block via the sidecar, so fail early if
# base hasn't run yet.
command -v nginx >/dev/null 2>&1 || die "nginx not found (torii-base must run first)"
[[ -x /usr/local/bin/torii ]] || die "torii sidecar not found (torii-base must run first)"
command -v git  >/dev/null 2>&1 || die "git not found (torii-base bootstrap should have installed it)"

RELAY_PREFIX="/opt/torii/relay"
RELAY_BIN="${RELAY_PREFIX}/strfry"
RELAY_CONF="${RELAY_PREFIX}/strfry.conf"
RELAY_SRC="${SUITE_WORK_DIR}/torii-strfry"
GIT_HTTP_BACKEND="$(git --exec-path)/git-http-backend"

# --------------------------------------------------------------------------- #
# 1. Build strfry from the pinned source tag                                   #
# --------------------------------------------------------------------------- #

# Decide whether a (re)build is needed. A build is required when the binary is
# missing or the checkout is not at the pinned tag; otherwise re-runs skip the
# multi-minute compile.
need_build=0
if [[ ! -x "$RELAY_BIN" ]]; then
  need_build=1
elif [[ -d "${RELAY_SRC}/.git" ]]; then
  cur_tag="$(git -C "$RELAY_SRC" describe --tags --exact-match 2>/dev/null || echo "")"
  [[ "$cur_tag" == "$STRFRY_REF" ]] || need_build=1
else
  need_build=1
fi

if (( need_build == 1 )); then
  log "installing strfry build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    git g++ make libssl-dev zlib1g-dev liblmdb-dev libflatbuffers-dev \
    libsecp256k1-dev libzstd-dev

  if [[ -d "${RELAY_SRC}/.git" ]]; then
    log "updating strfry source to ${STRFRY_REF}"
    git -C "$RELAY_SRC" fetch --tags --prune origin
    git -C "$RELAY_SRC" reset --hard HEAD 2>/dev/null || true
    git -C "$RELAY_SRC" checkout "$STRFRY_REF"
  else
    # Stale/partial checkout (a dir without .git — an aborted clone) makes
    # `git clone` abort with "destination path already exists". Move it aside
    # first; it is re-cloneable source, so nothing is lost.
    if [[ -e "${RELAY_SRC}" ]]; then
      log "moving stale non-git checkout aside: ${RELAY_SRC}"
      mv "${RELAY_SRC}" "${RELAY_SRC}.stale-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    log "cloning strfry @ ${STRFRY_REF}"
    git clone https://github.com/hoytech/strfry.git "$RELAY_SRC" 2>/dev/null
    git -C "$RELAY_SRC" checkout "$STRFRY_REF"
  fi

  log "initialising strfry submodules (golpe)"
  git -C "$RELAY_SRC" submodule update --init

  log "building strfry (this takes a few minutes)"
  (
    cd "$RELAY_SRC"
    make setup-golpe
    make -j"$(nproc)"
  )

  [[ -x "${RELAY_SRC}/strfry" ]] \
    || die "strfry build did not produce a binary at ${RELAY_SRC}/strfry"

  install -d -m 0755 -o root -g root "$RELAY_PREFIX"
  install -m 0755 "${RELAY_SRC}/strfry" "$RELAY_BIN"
else
  log "strfry already built at ${STRFRY_REF} - skipping build"
fi

# --------------------------------------------------------------------------- #
# 2. strfry.conf (loopback bind, configured port/db, NIP-11 identity)          #
# --------------------------------------------------------------------------- #
#
# Minimal sovereign config. strfry.conf is libconfig syntax (nested braces),
# NOT dotted keys. Only db is required; everything else falls back to strfry
# defaults (see upstream strfry.conf). We pin: loopback bind (nginx fronts
# TLS), the configured port, real-IP passthrough from nginx, and a NIP-11
# identity. pubkey/contact stay empty -- the VPS is keyless and holds no nsec.

CONF_CONTENT="$(cat <<CONF
# ${RELAY_CONF} - written by torii-suite install-nostr-git.sh
# Minimal sovereign config. strfry defaults apply for everything not listed
# here (see upstream strfry.conf). Loopback bind only - nginx fronts TLS.

db = "${NOSTR_RELAY_DB}/"

relay {
    bind = "127.0.0.1"
    port = ${NOSTR_RELAY_PORT}
    realIpHeader = "x-real-ip"

    info {
        name = "Torii"
        description = "Sovereign Torii Nostr relay - git mirror infra (keyless VPS)"
        pubkey = ""
        contact = ""
        icon = ""
    }
}
CONF
)"

if [[ ! -f "$RELAY_CONF" ]] || ! diff -q <(printf '%s\n' "$CONF_CONTENT") "$RELAY_CONF" >/dev/null 2>&1; then
  log "writing strfry config ${RELAY_CONF}"
  install -d -m 0755 -o root -g root "$(dirname "$RELAY_CONF")"
  printf '%s\n' "$CONF_CONTENT" > "$RELAY_CONF"
  chmod 0644 "$RELAY_CONF"
fi

# --------------------------------------------------------------------------- #
# 3. torii-relay system user + db dir                                          #
# --------------------------------------------------------------------------- #

if ! id -u torii-relay >/dev/null 2>&1; then
  log "creating torii-relay system user"
  useradd --system --shell /usr/sbin/nologin \
    --home-dir "$RELAY_PREFIX" --no-create-home torii-relay
fi
# RELAY_PREFIX stays root-owned (0755): torii-relay reads the binary + conf
# but cannot modify them. Only the db dir is writable by the service.
install -d -m 0755 -o root -g root "$RELAY_PREFIX"
install -d -m 0755 -o torii-relay -g torii-relay "$NOSTR_RELAY_DB"

# --------------------------------------------------------------------------- #
# 4. systemd unit (hardened)                                                   #
# --------------------------------------------------------------------------- #
#
# strfry is a compiled C++ binary (no JIT), so unlike arena-ws we can keep
# MemoryDenyWriteExecute=true. Writable surface is limited to the db dir.

UNIT_FILE="/etc/systemd/system/torii-relay.service"
UNIT_CONTENT="$(cat <<UNIT
# ${UNIT_FILE} - written by torii-suite install-nostr-git.sh
[Unit]
Description=Torii Nostr relay (strfry)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=torii-relay
Group=torii-relay
WorkingDirectory=${RELAY_PREFIX}
ExecStart=${RELAY_BIN} --config ${RELAY_CONF} relay
Restart=on-failure
RestartSec=5

# strfry's default relay.nofiles is 1000000; it calls setrlimit at startup.
# Raise the unit's limit so that succeeds (it cannot as a non-root user
# without this).
LimitNOFILE=1000000

# Hardening. strfry is a compiled C++ binary (no JIT), so
# MemoryDenyWriteExecute=true is safe here (unlike the Node arena-ws unit).
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${NOSTR_RELAY_DB}
MemoryDenyWriteExecute=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
UNIT
)"

if [[ ! -f "$UNIT_FILE" ]] || ! diff -q <(printf '%s\n' "$UNIT_CONTENT") "$UNIT_FILE" >/dev/null 2>&1; then
  log "writing systemd unit ${UNIT_FILE}"
  printf '%s\n' "$UNIT_CONTENT" > "$UNIT_FILE"
  chmod 0644 "$UNIT_FILE"
  systemctl daemon-reload
fi

systemctl enable torii-relay.service >/dev/null 2>&1 || true
systemctl restart torii-relay.service

# Wait up to 10s for strfry to bind the loopback port.
relay_ready=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if (echo > "/dev/tcp/127.0.0.1/${NOSTR_RELAY_PORT}") 2>/dev/null; then
    relay_ready=1
    break
  fi
  sleep 1
done
if (( relay_ready == 1 )); then
  log "torii-relay.service is up on 127.0.0.1:${NOSTR_RELAY_PORT}"
else
  die "torii-relay.service did not become ready on 127.0.0.1:${NOSTR_RELAY_PORT} within 10s (check: journalctl -u torii-relay.service)"
fi

# --------------------------------------------------------------------------- #
# 5. fcgiwrap (nginx -> git-http-backend adapter)                              #
# --------------------------------------------------------------------------- #
#
# nginx has no native CGI. fcgiwrap is the standard FastCGI adapter that runs
# git-http-backend (a CGI) behind nginx's fastcgi_pass. Read-only fetch/clone
# is exposed at /git/; push is blocked at nginx (see git.conf below).

log "installing fcgiwrap (git smart-HTTP adapter)"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends fcgiwrap >/dev/null
systemctl enable --now fcgiwrap.socket >/dev/null 2>&1 || true
# nginx points at /run/fcgiwrap.socket (created by fcgiwrap.socket via socket
# activation). Require it: the plain fcgiwrap.service listens on a different
# transport and would not satisfy the fastcgi_pass below.
if [[ ! -S /run/fcgiwrap.socket ]]; then
  die "expected fcgiwrap socket at /run/fcgiwrap.socket but it is absent - check: systemctl status fcgiwrap.socket"
fi

# --------------------------------------------------------------------------- #
# 6. Empty git host root (Continuum populates this)                            #
# --------------------------------------------------------------------------- #
#
# GIT_HOST_ROOT is the bare-repo store git-http-backend serves from. This stage
# provisions it empty + world-traversable so www-data (fcgiwrap) can read repos
# the Continuum mirror job creates later. The mirror job owns repo creation +
# per-repo http.receivepack=false; the nginx route below enforces read-only at
# the edge independently of per-repo config.

install -d -m 0755 -o root -g www-data "$GIT_HOST_ROOT"

# --------------------------------------------------------------------------- #
# 7. nginx fragments                                                          #
# --------------------------------------------------------------------------- #

FRAGMENT_DIR="/opt/torii/nginx-fragments"
mkdir -p "$FRAGMENT_DIR"

# 7a. Relay WSS proxy: wss://$host/relay -> loopback strfry.
#
# strfry serves BOTH the Nostr WebSocket protocol AND NIP-11 relay-info (plain
# HTTP GET with Accept: application/nostr+json) on the same socket. Forcing
# Connection "upgrade" unconditionally broke arena-ws's plain-HTTP endpoints
# (see quest-mp.conf), so here we pass the client's own Connection header
# through instead: a WS handshake sends Connection: Upgrade (upgraded), a
# NIP-11 GET sends no Upgrade (served as plain HTTP). Either way strfry wins.
RELAY_FRAGMENT_FILE="${FRAGMENT_DIR}/relay.conf"
RELAY_FRAGMENT_CONTENT="$(cat <<NGINX
# ${RELAY_FRAGMENT_FILE} - written by torii-suite
#
# Torii Nostr relay (strfry) proxy. Clients dial wss://\$host/relay; nginx
# upgrades + proxies to the loopback-bound strfry process on port
# ${NOSTR_RELAY_PORT}. NIP-11 relay-info is served by strfry on the same path
# via the Accept header - the passthrough Connection header keeps plain-HTTP
# NIP-11 GETs working without forcing an upgrade on them.

location /relay {
    proxy_pass http://127.0.0.1:${NOSTR_RELAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
NGINX
)"

if [[ ! -f "$RELAY_FRAGMENT_FILE" ]] || ! diff -q <(printf '%s\n' "$RELAY_FRAGMENT_CONTENT") "$RELAY_FRAGMENT_FILE" >/dev/null 2>&1; then
  log "writing nginx fragment ${RELAY_FRAGMENT_FILE}"
  printf '%s\n' "$RELAY_FRAGMENT_CONTENT" > "$RELAY_FRAGMENT_FILE"
fi

# 7b. Read-only git smart-HTTP via fcgiwrap + git-http-backend.
GIT_FRAGMENT_FILE="${FRAGMENT_DIR}/git.conf"
GIT_FRAGMENT_CONTENT="$(cat <<NGINX
# ${GIT_FRAGMENT_FILE} - written by torii-suite
#
# Torii git smart-HTTP host (read-only mirror). nginx routes /git/ to
# git-http-backend via fcgiwrap. Continuum's mirror job (CONT-NIP34-MIRROR-1)
# populates ${GIT_HOST_ROOT} with bare repos; this route serves them.
#
# Read-only by design:
#   - fetch/clone (service=git-upload-pack) is allowed
#   - push is blocked at the edge two ways: the advertise
#     (info/refs?service=git-receive-pack -> 403) AND the actual push POST
#     (POST /git/<repo>.git/git-receive-pack -> 403). Blocking only the query
#     string would leave the push endpoint itself open.
#   - per-repo http.receivepack defaults to false (belt-and-braces, set by the
#     mirror job)
#
# GIT_HTTP_EXPORT_ALL makes every repo under the root exportable without a
# per-repo git-daemon-export-ok marker.

# Block the push endpoint itself (POST .../git-receive-pack, no query string).
# Regex locations match in order of appearance, so this specific block must
# come before the generic ^/git/(.*)$ below.
location ~ ^/git/.*/git-receive-pack\$ {
    return 403;
}

location ~ ^/git/(.*)\$ {
    # Block the push advertise (GET info/refs?service=git-receive-pack).
    # nginx "if" is narrow here: a single return.
    if (\$query_string ~* "(^|&)service=git-receive-pack(&|$)") { return 403; }

    include /etc/nginx/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME ${GIT_HTTP_BACKEND};
    fastcgi_param GIT_HTTP_EXPORT_ALL 1;
    fastcgi_param GIT_PROJECT_ROOT ${GIT_HOST_ROOT};
    fastcgi_param PATH_INFO /\$1;
    fastcgi_param REMOTE_USER \$remote_user;
    fastcgi_pass unix:/run/fcgiwrap.socket;
    fastcgi_read_timeout 300s;
}
NGINX
)"

if [[ ! -f "$GIT_FRAGMENT_FILE" ]] || ! diff -q <(printf '%s\n' "$GIT_FRAGMENT_CONTENT") "$GIT_FRAGMENT_FILE" >/dev/null 2>&1; then
  log "writing nginx fragment ${GIT_FRAGMENT_FILE}"
  printf '%s\n' "$GIT_FRAGMENT_CONTENT" > "$GIT_FRAGMENT_FILE"
fi

# --------------------------------------------------------------------------- #
# 7c. Subdomain relay vhost + Let's Encrypt cert                               #
# --------------------------------------------------------------------------- #
#
# Recommended endpoint: wss://${TORII_RELAY_HOST} (default relay.<domain>).
# Provisions a dedicated sites-available vhost with its own cert. The
# path-based /relay fragment above stays in place for backward compat --
# both endpoints reverse-proxy to the same loopback strfry process.
#
# Skipped cleanly when TORII_RELAY_HOST is empty (path-only mode).
#
# DNS check: we resolve TORII_RELAY_HOST and refuse to touch certbot when the
# subdomain does not resolve to a public IP that includes THIS host's IP. The
# check is only fatal when SKIP_CERTBOT!=1; a warned-through install (no cert)
# still writes the plain-HTTP vhost so `certbot certonly` can be run later.

RELAY_SUBDOMAIN_OK=0
if [[ -n "$TORII_RELAY_HOST" ]]; then
  log "provisioning subdomain relay vhost for ${TORII_RELAY_HOST}"

  # DNS preflight (soft when SKIP_CERTBOT=1, hard otherwise).
  RELAY_DNS_OK=0
  PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
  fi
  RELAY_A_RECORDS="$(dig +short A "$TORII_RELAY_HOST" @1.1.1.1 2>/dev/null | tr '\n' ' ')"
  if [[ -z "$RELAY_A_RECORDS" ]]; then
    warn "DNS: no A record for ${TORII_RELAY_HOST} - Let's Encrypt will fail"
    [[ "$SKIP_CERTBOT" == "1" ]] || die "DNS: point ${TORII_RELAY_HOST} at this VPS (or set SKIP_CERTBOT=1 to install without HTTPS)"
  elif [[ -n "$PUBLIC_IP" ]] && ! echo " $RELAY_A_RECORDS " | grep -q " $PUBLIC_IP "; then
    warn "DNS: ${TORII_RELAY_HOST} -> [${RELAY_A_RECORDS% }], but this VPS is ${PUBLIC_IP}"
    [[ "$SKIP_CERTBOT" == "1" ]] || die "DNS: ${TORII_RELAY_HOST} points elsewhere - fix the A record or set SKIP_CERTBOT=1"
  else
    log "DNS: ${TORII_RELAY_HOST} -> ${PUBLIC_IP:-<unknown host IP>}"
    RELAY_DNS_OK=1
  fi

  # certbot's webroot; torii-base bootstrap installs /var/www/certbot but
  # the sidecar user cannot recreate it if missing. Be idempotent.
  install -d -m 0755 /var/www/certbot

  RELAY_VHOST="/etc/nginx/sites-available/${TORII_RELAY_HOST}.conf"
  RELAY_VHOST_LINK="/etc/nginx/sites-enabled/${TORII_RELAY_HOST}.conf"
  RELAY_CERT_DIR="/etc/letsencrypt/live/${TORII_RELAY_HOST}"

  # Stage 1: plain-HTTP vhost so certbot --webroot can validate. We serve the
  # ACME challenge here and 301 everything else -- keeps the vhost useful
  # even before HTTPS is obtained.
  install -d -m 0755 /etc/nginx/sites-available
  install -d -m 0755 /etc/nginx/sites-enabled
  cat > "${RELAY_VHOST}.acme" <<ACME_VHOST
# ${RELAY_VHOST}.acme - written by torii-suite install-nostr-git.sh
# Temporary HTTP-only vhost served during Let's Encrypt HTTP-01 validation.
server {
    listen 80;
    listen [::]:80;
    server_name ${TORII_RELAY_HOST};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
ACME_VHOST
  chmod 0644 "${RELAY_VHOST}.acme"

  # Obtain a cert if we don't already have one and DNS + certbot are green.
  if [[ ! -f "${RELAY_CERT_DIR}/fullchain.pem" ]]; then
    if [[ "$SKIP_CERTBOT" == "1" ]]; then
      warn "SKIP_CERTBOT=1 - not issuing cert for ${TORII_RELAY_HOST} (vhost will be HTTP-only)"
    elif (( RELAY_DNS_OK == 0 )); then
      warn "DNS check failed - skipping cert issuance for ${TORII_RELAY_HOST}"
    else
      command -v certbot >/dev/null 2>&1 \
        || die "certbot not found (torii-base must run first)"
      log "issuing Let's Encrypt cert for ${TORII_RELAY_HOST} (HTTP-only vhost active)"
      # Swap the temp vhost into place so certbot HTTP-01 can validate.
      install -m 0644 "${RELAY_VHOST}.acme" "$RELAY_VHOST"
      ln -sf "$RELAY_VHOST" "$RELAY_VHOST_LINK"
      nginx -t && systemctl reload nginx
      CERTBOT_EMAIL_ARG=()
      if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
        CERTBOT_EMAIL_ARG=(--email "$LETSENCRYPT_EMAIL")
      else
        CERTBOT_EMAIL_ARG=(--register-unsafely-without-email)
      fi
      certbot certonly --webroot -w /var/www/certbot -d "$TORII_RELAY_HOST" \
        --non-interactive --agree-tos "${CERTBOT_EMAIL_ARG[@]}" \
        || die "certbot failed for ${TORII_RELAY_HOST} - see /var/log/letsencrypt/letsencrypt.log"
    fi
  else
    log "cert already present for ${TORII_RELAY_HOST} - skipping issuance"
  fi

  # Stage 2: write the real vhost. If the cert exists, serve TLS + WSS. If it
  # doesn't (SKIP_CERTBOT or DNS failure), fall back to the acme vhost so
  # nginx still validates on reload.
  rm -f "${RELAY_VHOST}.acme"

  if [[ -f "${RELAY_CERT_DIR}/fullchain.pem" ]]; then
    RELAY_VHOST_CONTENT="$(cat <<VHOST
# ${RELAY_VHOST} - written by torii-suite install-nostr-git.sh
# Torii sovereign Nostr relay (strfry) - subdomain vhost + Let's Encrypt.
#
# strfry serves BOTH the Nostr WebSocket protocol AND NIP-11 relay-info (plain
# HTTP GET with Accept: application/nostr+json) on the same socket. We pass
# the client's own Connection header through so plain-HTTP NIP-11 GETs work
# without forcing an upgrade on them.

server {
    listen 80;
    listen [::]:80;
    server_name ${TORII_RELAY_HOST};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${TORII_RELAY_HOST};

    ssl_certificate     ${RELAY_CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${RELAY_CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass         http://127.0.0.1:${NOSTR_RELAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$http_connection;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
VHOST
)"
    RELAY_SUBDOMAIN_OK=1
  else
    RELAY_VHOST_CONTENT="$(cat <<VHOST
# ${RELAY_VHOST} - written by torii-suite install-nostr-git.sh
# HTTP-only vhost - no cert on disk (SKIP_CERTBOT or DNS failed).
# Re-run install-nostr-git.sh after DNS/cert are ready to upgrade to TLS.

server {
    listen 80;
    listen [::]:80;
    server_name ${TORII_RELAY_HOST};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 200 "torii-relay: no TLS cert on disk yet\n";
        add_header Content-Type text/plain;
    }
}
VHOST
)"
  fi

  if [[ ! -f "$RELAY_VHOST" ]] || ! diff -q <(printf '%s\n' "$RELAY_VHOST_CONTENT") "$RELAY_VHOST" >/dev/null 2>&1; then
    log "writing nginx vhost ${RELAY_VHOST}"
    printf '%s\n' "$RELAY_VHOST_CONTENT" > "$RELAY_VHOST"
    chmod 0644 "$RELAY_VHOST"
  fi
  ln -sf "$RELAY_VHOST" "$RELAY_VHOST_LINK"
else
  log "TORII_RELAY_HOST empty - skipping subdomain vhost (path-only mode)"
fi

# --------------------------------------------------------------------------- #
# 8. Reload nginx via the torii sidecar                                        #
# --------------------------------------------------------------------------- #

/usr/local/bin/torii reload

if (( RELAY_SUBDOMAIN_OK == 1 )); then
  RELAY_WS_URL="wss://${TORII_RELAY_HOST}"
  RELAY_WS_ALT="wss://${TORII_DOMAIN}/relay"
  log "nostr-git infra complete - relay ${RELAY_WS_URL} (subdomain, TLS) + fallback ${RELAY_WS_ALT}"
else
  RELAY_WS_URL="wss://${TORII_DOMAIN}/relay"
  log "nostr-git infra complete - relay ${RELAY_WS_URL} (path mode)"
fi
GIT_HTTP_URL="https://${TORII_DOMAIN}/git"
log "                            + git host ${GIT_HTTP_URL}/"
log "git host root is empty; Continuum populates ${GIT_HOST_ROOT} with mirrored repos"
