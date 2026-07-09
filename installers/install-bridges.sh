#!/usr/bin/env bash
# torii-suite/installers/install-bridges.sh
#
# Installs the onboarding bridges (CORS proxy + WebSSH) on a host that
# already has torii-base running. Both bridges are optional — this script
# only runs when INSTALL_ONBOARDING_BRIDGES=1.
#
# What this does (idempotent on re-run):
#   1. Creates the 'torii-bridges' system user
#   2. Copies bridges/cors-proxy/ and bridges/webssh/ to /opt/torii/bridges/
#   3. Runs `npm ci --omit=dev` for each
#   4. Writes /etc/systemd/system/torii-cors-proxy.service
#   5. Writes /etc/systemd/system/torii-webssh.service
#   6. Drops an nginx fragment at /opt/torii/nginx-fragments/bridges.conf
#      that exposes both bridges under /cors-proxy/ and /webssh
#   7. Reloads systemd + nginx via `torii reload`
#
# Env (inherited from bootstrap.sh):
#   TORII_DOMAIN, SUITE_WORK_DIR,
#   CORS_PROXY_UPSTREAM_ALLOW, CORS_PROXY_ORIGIN_ALLOW, CORS_PROXY_PORT,
#   WEBSSH_ORIGIN_ALLOW, WEBSSH_PORT, WEBSSH_MAX_PER_IP,
#   WEBSSH_MAX_SESSION_MS

set -euo pipefail

: "${TORII_DOMAIN:?install-bridges: TORII_DOMAIN not set (run via bootstrap.sh)}"
: "${SUITE_WORK_DIR:?install-bridges: SUITE_WORK_DIR not set}"

# Origin allowlists MUST be set — the bridges refuse to start without them.
: "${CORS_PROXY_ORIGIN_ALLOW:?install-bridges: CORS_PROXY_ORIGIN_ALLOW required (comma-separated origins)}"
: "${WEBSSH_ORIGIN_ALLOW:?install-bridges: WEBSSH_ORIGIN_ALLOW required (comma-separated origins)}"

CORS_PROXY_UPSTREAM_ALLOW="${CORS_PROXY_UPSTREAM_ALLOW:-blesta.sovereignhybridcompute.com}"
CORS_PROXY_PORT="${CORS_PROXY_PORT:-8801}"
WEBSSH_PORT="${WEBSSH_PORT:-8802}"
WEBSSH_MAX_PER_IP="${WEBSSH_MAX_PER_IP:-3}"
WEBSSH_MAX_SESSION_MS="${WEBSSH_MAX_SESSION_MS:-900000}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install-bridges must run as root"
command -v node >/dev/null 2>&1 || die "node not found"
command -v npm  >/dev/null 2>&1 || die "npm not found"

# --------------------------------------------------------------------------- #
# 1. torii-bridges system user                                                #
# --------------------------------------------------------------------------- #

if ! id torii-bridges >/dev/null 2>&1; then
  log "creating 'torii-bridges' system user"
  adduser --system --group --home /opt/torii/bridges --no-create-home \
          --disabled-password --gecos "Torii onboarding bridges" torii-bridges
fi

# --------------------------------------------------------------------------- #
# 2. Copy bridge sources into /opt                                            #
# --------------------------------------------------------------------------- #

# Resolve the suite repo root — this script lives in installers/, so the repo
# root is one level up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BRIDGES_ROOT="/opt/torii/bridges"
mkdir -p "$BRIDGES_ROOT"

for bridge in cors-proxy webssh; do
  SRC="${REPO_ROOT}/bridges/${bridge}"
  DST="${BRIDGES_ROOT}/${bridge}"
  [[ -d "$SRC" ]] || die "missing bridge source: ${SRC}"

  log "installing ${bridge} into ${DST}"
  mkdir -p "$DST"
  # Copy source but not node_modules — we'll `npm ci` fresh.
  # rsync-esque via tar to preserve permissions and skip node_modules.
  (
    cd "$SRC"
    tar --exclude='./node_modules' --exclude='./.git' -cf - . \
      | tar -xf - -C "$DST"
  )
done

# --------------------------------------------------------------------------- #
# 3. Install production dependencies                                          #
# --------------------------------------------------------------------------- #

# cors-proxy has zero deps but still has a package.json — a `npm ci --omit=dev`
# is a no-op there and keeps the flow uniform.
for bridge in cors-proxy webssh; do
  log "installing ${bridge} production deps"
  (
    cd "${BRIDGES_ROOT}/${bridge}"
    if [[ -f package-lock.json ]]; then
      npm ci --omit=dev --no-audit --no-fund
    elif [[ -f package.json ]]; then
      # cors-proxy has no lockfile since it has no deps.
      npm install --omit=dev --no-audit --no-fund
    fi
  )
done

chown -R torii-bridges:torii-bridges "$BRIDGES_ROOT"

# --------------------------------------------------------------------------- #
# 4. torii-cors-proxy.service                                                 #
# --------------------------------------------------------------------------- #

CORS_UNIT_FILE="/etc/systemd/system/torii-cors-proxy.service"
CORS_UNIT_CONTENT="$(cat <<UNIT
[Unit]
Description=Torii CORS proxy (onboarding bridge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=torii-bridges
Group=torii-bridges
WorkingDirectory=${BRIDGES_ROOT}/cors-proxy
Environment=NODE_ENV=production
Environment=CORS_PROXY_PORT=${CORS_PROXY_PORT}
Environment=CORS_PROXY_UPSTREAM_ALLOW=${CORS_PROXY_UPSTREAM_ALLOW}
Environment=CORS_PROXY_ORIGIN_ALLOW=${CORS_PROXY_ORIGIN_ALLOW}
Environment=CORS_PROXY_LOG_LEVEL=silent
ExecStart=/usr/bin/env node index.mjs
Restart=on-failure
RestartSec=3

# Sandboxing
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
)"

if [[ ! -f "$CORS_UNIT_FILE" ]] || ! diff -q <(echo "$CORS_UNIT_CONTENT") "$CORS_UNIT_FILE" >/dev/null; then
  log "writing ${CORS_UNIT_FILE}"
  echo "$CORS_UNIT_CONTENT" > "$CORS_UNIT_FILE"
  systemctl daemon-reload
fi

systemctl enable torii-cors-proxy.service >/dev/null
systemctl restart torii-cors-proxy.service
sleep 1
if ! systemctl is-active --quiet torii-cors-proxy.service; then
  systemctl status torii-cors-proxy.service --no-pager || true
  die "torii-cors-proxy failed to start"
fi
log "torii-cors-proxy active on 127.0.0.1:${CORS_PROXY_PORT}"

# --------------------------------------------------------------------------- #
# 5. torii-webssh.service                                                     #
# --------------------------------------------------------------------------- #

WEBSSH_UNIT_FILE="/etc/systemd/system/torii-webssh.service"
WEBSSH_UNIT_CONTENT="$(cat <<UNIT
[Unit]
Description=Torii WebSSH bridge (onboarding bridge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=torii-bridges
Group=torii-bridges
WorkingDirectory=${BRIDGES_ROOT}/webssh
Environment=NODE_ENV=production
Environment=WEBSSH_PORT=${WEBSSH_PORT}
Environment=WEBSSH_ORIGIN_ALLOW=${WEBSSH_ORIGIN_ALLOW}
Environment=WEBSSH_MAX_PER_IP=${WEBSSH_MAX_PER_IP}
Environment=WEBSSH_MAX_SESSION_MS=${WEBSSH_MAX_SESSION_MS}
Environment=WEBSSH_LOG_LEVEL=silent
ExecStart=/usr/bin/env node index.mjs
Restart=on-failure
RestartSec=3

# Sandboxing
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
# WebSSH cannot enable MemoryDenyWriteExecute because ssh2 JITs some crypto.
RestrictSUIDSGID=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
)"

if [[ ! -f "$WEBSSH_UNIT_FILE" ]] || ! diff -q <(echo "$WEBSSH_UNIT_CONTENT") "$WEBSSH_UNIT_FILE" >/dev/null; then
  log "writing ${WEBSSH_UNIT_FILE}"
  echo "$WEBSSH_UNIT_CONTENT" > "$WEBSSH_UNIT_FILE"
  systemctl daemon-reload
fi

systemctl enable torii-webssh.service >/dev/null
systemctl restart torii-webssh.service
sleep 1
if ! systemctl is-active --quiet torii-webssh.service; then
  systemctl status torii-webssh.service --no-pager || true
  die "torii-webssh failed to start"
fi
log "torii-webssh active on 127.0.0.1:${WEBSSH_PORT}"

# --------------------------------------------------------------------------- #
# 6. nginx fragment                                                           #
# --------------------------------------------------------------------------- #

FRAGMENT_DIR="/opt/torii/nginx-fragments"
FRAGMENT_FILE="${FRAGMENT_DIR}/bridges.conf"
mkdir -p "$FRAGMENT_DIR"

FRAGMENT_CONTENT="$(cat <<NGINX
# /opt/torii/nginx-fragments/bridges.conf — written by torii-suite
#
# CORS proxy at /cors-proxy/
# WebSSH   at /webssh (WebSocket upgrade)

location /cors-proxy/ {
    proxy_pass         http://127.0.0.1:${CORS_PROXY_PORT};
    proxy_http_version 1.1;
    proxy_set_header   Host              \$host;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   Origin            \$http_origin;
    proxy_read_timeout 60s;
    client_max_body_size 10m;
}

location = /webssh {
    proxy_pass         http://127.0.0.1:${WEBSSH_PORT};
    proxy_http_version 1.1;
    proxy_set_header   Host              \$host;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   Origin            \$http_origin;
    proxy_set_header   Upgrade           \$http_upgrade;
    proxy_set_header   Connection        "upgrade";
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;
}
NGINX
)"

if [[ ! -f "$FRAGMENT_FILE" ]] || ! diff -q <(echo "$FRAGMENT_CONTENT") "$FRAGMENT_FILE" >/dev/null; then
  log "writing nginx fragment ${FRAGMENT_FILE}"
  echo "$FRAGMENT_CONTENT" > "$FRAGMENT_FILE"
fi

# --------------------------------------------------------------------------- #
# 7. Register with torii-base and reload nginx                                #
# --------------------------------------------------------------------------- #

log "registering 'bridges' with torii sidecar"
/usr/local/bin/torii register bridges \
  --display "Onboarding Bridges" \
  --desc    "CORS proxy + WebSSH for the non-coder onboarding flow" \
  --version "0.1.2-alpha"

/usr/local/bin/torii reload

log "bridges install complete"
log "  cors-proxy: https://${TORII_DOMAIN}/cors-proxy/<upstream-host>/<path>"
log "  webssh:     wss://${TORII_DOMAIN}/webssh"
