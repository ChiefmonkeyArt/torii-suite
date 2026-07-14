#!/usr/bin/env bash
# torii-suite/installers/install-quest.sh
#
# Installs Torii Quest as a static bundle mounted at /quest/ on the shared
# torii-base HTTPS server block. No Docker, no separate Caddy — the suite
# uses torii-base's nginx directly.
#
# What this does (idempotent on re-run):
#   1. Clones/updates torii-quest into $SUITE_WORK_DIR/torii-quest
#   2. Patches vite.config.js in-place to build with base=/quest/ so all
#      absolute asset URLs (/assets/torii-entry.js etc.) resolve correctly
#      when served from a sub-path. See docs/HOSTING.md §Quest sub-path.
#   3. Builds the bundle, snapshots it into /var/www/torii/quest-releases/
#      /<stamp>/ and atomically flips /var/www/torii/quest → that dir
#   4. Drops an nginx fragment at /opt/torii/nginx-fragments/quest.conf
#   5. Registers "quest" with the torii-base sidecar
#
# Env (inherited from bootstrap.sh):
#   TORII_DOMAIN, SUITE_WORK_DIR, TORII_QUEST_REF

set -euo pipefail

: "${TORII_DOMAIN:?install-quest: TORII_DOMAIN not set (run via bootstrap.sh)}"
: "${SUITE_WORK_DIR:?install-quest: SUITE_WORK_DIR not set}"

TORII_QUEST_REF="${TORII_QUEST_REF:-main}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install-quest must run as root"
command -v node >/dev/null 2>&1 || die "node not found (torii-base bootstrap should have installed it)"
command -v npm  >/dev/null 2>&1 || die "npm not found"

# --------------------------------------------------------------------------- #
# 1. Sync source                                                              #
# --------------------------------------------------------------------------- #

SRC="${SUITE_WORK_DIR}/torii-quest"
if [[ -d "${SRC}/.git" ]]; then
  log "updating torii-quest to ${TORII_QUEST_REF}"
  git -C "$SRC" fetch --tags --prune origin
  # If we patched vite.config.js on a prior run, reset it so `checkout`
  # doesn't fight our own edit.
  git -C "$SRC" checkout -- vite.config.js 2>/dev/null || true
  git -C "$SRC" checkout "$TORII_QUEST_REF"
  git -C "$SRC" pull --ff-only origin "$TORII_QUEST_REF" 2>/dev/null || true
else
  log "cloning torii-quest @ ${TORII_QUEST_REF}"
  git clone --branch "$TORII_QUEST_REF" \
    https://github.com/ChiefmonkeyArt/torii-quest.git "$SRC" 2>/dev/null \
    || git clone https://github.com/ChiefmonkeyArt/torii-quest.git "$SRC"
  git -C "$SRC" checkout "$TORII_QUEST_REF"
fi

RESOLVED_REF="$(git -C "$SRC" rev-parse --short HEAD)"
QUEST_VERSION="$(node -p "require('${SRC}/package.json').version" 2>/dev/null || echo "unknown")"
log "quest source at commit ${RESOLVED_REF} (v${QUEST_VERSION})"

# --------------------------------------------------------------------------- #
# 2. Patch vite.config.js for /quest/ base path                               #
# --------------------------------------------------------------------------- #
#
# torii-quest ships without a `base:` in defineConfig. v0.2.370-alpha made the
# CSP entry-URL plugin base-aware (it reads config.base), so injecting
# `base: '/quest/'` is all that's needed on current refs; older refs (<v0.2.370)
# also had two hardcoded `/assets/torii-entry.js` literals that we rewrite.
#
# The patch below:
#   - injects `base: '/quest/',` into the defineConfig object
#   - rewrites any hardcoded `/assets/torii-entry.js` literals to
#     `/quest/assets/torii-entry.js` (no-op on base-aware v0.2.370+ configs)
#
# Detection keys on the ACTUAL `base: '/quest/'` injection, NOT on a
# `/quest/assets/torii-entry.js` literal — that literal now appears inside a
# comment on base-aware configs and would false-match as "already patched",
# skipping the base injection and building with base `/` (entry 404s under
# /quest/). Safe to re-run.

CONFIG_FILE="${SRC}/vite.config.js"
[[ -f "$CONFIG_FILE" ]] || die "expected ${CONFIG_FILE} to exist"

if grep -qE "base:[[:space:]]*['\"]/?quest/?['\"]" "$CONFIG_FILE"; then
  log "quest vite.config.js already has base: '/quest/'"
else
  log "patching quest vite.config.js for /quest/ base"

  # Insert `base: '/quest/',` immediately after `defineConfig({`.
  # Only rewrites the first match; defineConfig should appear once.
  sed -i "0,/defineConfig({/s||defineConfig({\n  base: '/quest/',|" "$CONFIG_FILE"

  # Rewrite the two absolute asset paths used by the inline bootstrap and
  # by the chunk-import-rewrite plugin.
  sed -i "s|/assets/torii-entry\.js|/quest/assets/torii-entry.js|g" "$CONFIG_FILE"
fi

# --------------------------------------------------------------------------- #
# 3. Build                                                                    #
# --------------------------------------------------------------------------- #

log "building torii-quest bundle"
(
  cd "$SRC"
  npm ci --no-audit --no-fund
  npm run build
)

[[ -d "${SRC}/dist" ]] || die "quest build produced no dist/ directory"

# --------------------------------------------------------------------------- #
# 4. Snapshot + atomic symlink flip                                           #
# --------------------------------------------------------------------------- #

WWW_LINK="/var/www/torii/quest"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-${RESOLVED_REF}"
RELEASE_DIR="/var/www/torii/quest-releases/${STAMP}"
mkdir -p "$(dirname "$RELEASE_DIR")"
cp -a "${SRC}/dist/." "${RELEASE_DIR}/"

ln -sfn "$RELEASE_DIR" "${WWW_LINK}.new"
mv -Tf "${WWW_LINK}.new" "$WWW_LINK"

# Retain last 3 releases.
find "$(dirname "$RELEASE_DIR")" -maxdepth 1 -mindepth 1 -type d \
  | sort | head -n -3 | xargs -r rm -rf

chown -R root:www-data "$RELEASE_DIR"
find "$RELEASE_DIR" -type d -exec chmod 755 {} +
find "$RELEASE_DIR" -type f -exec chmod 644 {} +

# --------------------------------------------------------------------------- #
# 5. nginx fragment                                                           #
# --------------------------------------------------------------------------- #

FRAGMENT_DIR="/opt/torii/nginx-fragments"
FRAGMENT_FILE="${FRAGMENT_DIR}/quest.conf"
mkdir -p "$FRAGMENT_DIR"

FRAGMENT_CONTENT="$(cat <<NGINX
# /opt/torii/nginx-fragments/quest.conf — written by torii-suite

# See install-continuum.sh for the full explanation of why regex + alias is
# broken. Same fix here: prefix location for /quest/assets/ and let nginx do
# the prefix rewrite correctly instead of falling through to the SPA shell.
location /quest/ {
    alias /var/www/torii/quest/;
    try_files \$uri \$uri/ /quest/index.html;

    location /quest/assets/ {
        alias /var/www/torii/quest/assets/;
        try_files \$uri =404;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable" always;
    }
    location = /quest/index.html {
        alias /var/www/torii/quest/index.html;
        add_header Cache-Control "no-store" always;
    }
}
NGINX
)"

if [[ ! -f "$FRAGMENT_FILE" ]] || ! diff -q <(echo "$FRAGMENT_CONTENT") "$FRAGMENT_FILE" >/dev/null; then
  log "writing nginx fragment ${FRAGMENT_FILE}"
  echo "$FRAGMENT_CONTENT" > "$FRAGMENT_FILE"
fi

# --------------------------------------------------------------------------- #
# 6. Register with the torii-base sidecar and reload nginx                    #
# --------------------------------------------------------------------------- #

log "registering 'quest' with torii sidecar (v${QUEST_VERSION})"
/usr/local/bin/torii register quest \
  --display "Torii Quest" \
  --desc    "3D open-world quest game on nostr" \
  --version "${QUEST_VERSION}"

# --------------------------------------------------------------------------- #
# 7. arena-ws multiplayer backend (v0.6.0-alpha, SUITE-VPS-READY-1)           #
# --------------------------------------------------------------------------- #
#
# Quest ships its authoritative multiplayer server as a Node process built to
# ${SRC}/dist/server/arena-ws.cjs (with a matching dist/package.json declaring
# the ws runtime dep). This stage:
#
#   - creates the torii-quest system user if absent (idempotent)
#   - copies the built server + its package.json into /opt/torii-quest/mp
#   - runs `npm install --omit=dev` inside that dir
#   - writes /etc/systemd/system/torii-arena-ws.service
#   - writes /opt/torii/nginx-fragments/quest-mp.conf (nginx /mp WSS proxy)
#   - enables + starts the service, waits for it to answer on 127.0.0.1
#
# Set INSTALL_ARENA_WS=0 in .env to skip this entire stage (Quest still
# publishes as a static bundle at /quest/, MP will just be unreachable).

if [[ "${INSTALL_ARENA_WS:-1}" != "1" ]]; then
  log "INSTALL_ARENA_WS=0 - skipping arena-ws install (MP will be unreachable)"
  ARENA_WS_INSTALLED=0
else
  ARENA_WS_PORT="${ARENA_WS_PORT:-8788}"
  ARENA_WS_MODE="${ARENA_WS_MODE:-authoritative}"
  # Quest admin npub gates the in-game "Update Now" button (v0.7.16-alpha). Defaults
  # to the Continuum admin npub (same operator) so an existing .env without
  # QUEST_ADMIN_NPUB keeps working. arena-ws normalises npub->hex at startup.
  QUEST_ADMIN_NPUB="${QUEST_ADMIN_NPUB:-${CONTINUUM_ADMIN_NPUB:-}}"
  MP_DIR="/opt/torii-quest/mp"
  MP_SRC_SERVER="${SRC}/dist/server/arena-ws.cjs"
  MP_SRC_PKG="${SRC}/dist/package.json"

  # 7a. Preflight - the built server bundle must exist.
  #
  # `npm run build` in torii-quest is defined as `build-dashboard && vite build
  # && npm run build:server`, and `build:server` uses esbuild to emit
  # dist/server/arena-ws.cjs. If that file is missing, either (a) the pinned
  # Quest ref pre-dates arena-ws or (b) build:server failed and only the
  # frontend produced. Either way we cannot install /mp.
  if [[ ! -f "$MP_SRC_SERVER" ]]; then
    warn "expected ${MP_SRC_SERVER} but the Quest build did not produce one - the pinned ref may not carry arena-ws yet"
    warn "install-quest will proceed with the static bundle only; set INSTALL_ARENA_WS=0 to suppress this warning"
    ARENA_WS_INSTALLED=0
  else
    # 7a.1. dist/package.json is NOT emitted by esbuild - it must declare the
    # `ws` runtime dep for `npm install --omit=dev` to pull it in. Write one
    # if the Quest build didn't. `ws` version matches what Quest handoff
    # documents as the tested runtime.
    if [[ ! -f "$MP_SRC_PKG" ]]; then
      log "writing ${MP_SRC_PKG} (arena-ws runtime deps manifest)"
      cat > "$MP_SRC_PKG" <<PKG
{
  "name": "torii-quest-arena-ws",
  "private": true,
  "description": "Torii Quest arena-ws runtime dependency manifest (written by torii-suite install-quest.sh)",
  "version": "${QUEST_VERSION}",
  "main": "server/arena-ws.cjs",
  "dependencies": {
    "ws": "^8.21.0"
  }
}
PKG
    fi

    if ! node -e "const p=require('${MP_SRC_PKG}'); if(!(p.dependencies&&p.dependencies.ws)) process.exit(1)" 2>/dev/null; then
      die "${MP_SRC_PKG} does not declare a 'ws' dependency - the pinned Quest ref shipped a broken manifest"
    fi
    ARENA_WS_INSTALLED=1
  fi
fi

# The rest of the arena-ws install runs only when the preflight left it
# marked installable. If we set ARENA_WS_INSTALLED=0 above (either because
# arena-ws was skipped by env or because the Quest build didn't emit the
# server bundle), skip the rest.
if [[ "${ARENA_WS_INSTALLED:-0}" == "1" ]]; then

  # 7b. torii-quest system user (idempotent).
  if ! id -u torii-quest >/dev/null 2>&1; then
    log "creating torii-quest system user"
    useradd --system --shell /usr/sbin/nologin --home-dir /opt/torii-quest --create-home torii-quest
  else
    log "torii-quest user already present"
  fi

  # 7b.1. Ensure the home dir exists and is torii-quest-owned. If the user was
  # created on a previous install and /opt/torii-quest was later removed (e.g.
  # a partial cleanup), `useradd` skips this run and the home dir is missing.
  # `install -d $MP_DIR` below would then create /opt/torii-quest as root, and
  # the subsequent `sudo -u torii-quest -H npm install` would EACCES trying to
  # write /opt/torii-quest/.npm. Belt-and-braces: chown even if it existed.
  install -d -m 0755 -o torii-quest -g torii-quest /opt/torii-quest
  chown torii-quest:torii-quest /opt/torii-quest

  # 7c. Install path + copy artifacts.
  install -d -m 0755 -o torii-quest -g torii-quest "$MP_DIR"
  cp -f "$MP_SRC_SERVER" "$MP_DIR/arena-ws.cjs"
  cp -f "$MP_SRC_PKG"    "$MP_DIR/package.json"
  chown torii-quest:torii-quest "$MP_DIR/arena-ws.cjs" "$MP_DIR/package.json"
  chmod 0644 "$MP_DIR/arena-ws.cjs" "$MP_DIR/package.json"

  # 7d. npm install --omit=dev inside the MP dir, as the torii-quest user.
  log "installing arena-ws production dependencies"
  ( cd "$MP_DIR" && sudo -u torii-quest -H npm install --omit=dev --no-audit --no-fund )

  # 7e. systemd unit (Item M).
  UNIT_FILE="/etc/systemd/system/torii-arena-ws.service"
  UNIT_CONTENT="$(cat <<UNIT
# ${UNIT_FILE} - written by torii-suite install-quest.sh
[Unit]
Description=Torii Quest arena-ws (authoritative multiplayer backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=torii-quest
Group=torii-quest
WorkingDirectory=${MP_DIR}
ExecStart=/usr/bin/node ${MP_DIR}/arena-ws.cjs
Environment=NODE_ENV=production
Environment=PORT=${ARENA_WS_PORT}
Environment=MP_MODE=${ARENA_WS_MODE}
Environment=QUEST_ADMIN_NPUB=${QUEST_ADMIN_NPUB}
Restart=on-failure
RestartSec=5

# Hardening. MemoryDenyWriteExecute=true is intentionally omitted:
# V8's baseline JIT calls mprotect(PROT_WRITE|PROT_EXEC) on code pages,
# which MDWE blocks. Node crashes on startup with SIGTRAP + errno 12.
# Verified live: torii-arena-ws was core-dumping every 5s on Ubuntu 26.04.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${MP_DIR}
LockPersonality=true

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

  # 7f. Enable + (re)start the service so a new build actually gets loaded.
  systemctl enable torii-arena-ws.service >/dev/null 2>&1 || true
  systemctl restart torii-arena-ws.service

  # Wait up to 10s for the process to bind and answer.
  arena_ws_ready=0
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -m 2 "http://127.0.0.1:${ARENA_WS_PORT}/health" >/dev/null 2>&1 \
       || (echo > "/dev/tcp/127.0.0.1/${ARENA_WS_PORT}") 2>/dev/null; then
      arena_ws_ready=1
      break
    fi
    sleep 1
  done
  if (( arena_ws_ready == 1 )); then
    log "torii-arena-ws.service is up on 127.0.0.1:${ARENA_WS_PORT}"
  else
    die "torii-arena-ws.service did not become ready on 127.0.0.1:${ARENA_WS_PORT} within 10s (check: journalctl -u torii-arena-ws.service)"
  fi

  # 7g. nginx /mp fragment (Item N). Arena-ws proxy.
  #
  # /mp now carries BOTH transports:
  #   * wss://\$host/mp             — the WebSocket arena session (Upgrade)
  #   * GET  https://\$host/mp/auth-challenge — plain HTTP (session-token login)
  #   * POST https://\$host/mp/session       — plain HTTP (session-token login)
  #
  # A single `location /mp { Connection "upgrade" }` broke the two HTTP auth
  # endpoints: it forced `Connection: upgrade` on plain requests that carry no
  # Upgrade header, which the arena-ws Node HTTP server rejects. The idiomatic
  # fix is a `map $http_upgrade $connection_upgrade` in the http{} scope, but
  # these fragments are included inside a server{} block (torii-base's sidecar
  # requires one location fragment per app), where `map` is illegal. So we split
  # by path instead: the auth endpoints get a clean HTTP proxy, and the arena
  # session keeps the Upgrade proxy. Same loopback upstream either way.
  MP_FRAGMENT_FILE="${FRAGMENT_DIR}/quest-mp.conf"
  MP_FRAGMENT_CONTENT="$(cat <<NGINX
# ${MP_FRAGMENT_FILE} - written by torii-suite
#
# Torii Quest arena-ws proxy. Session-token login uses two plain-HTTP
# endpoints under /mp; the arena itself is a WebSocket upgrade. All three
# proxy to the loopback-bound arena-ws process on port ${ARENA_WS_PORT}.

# Session-token login (NIP-98): plain HTTP, no Upgrade/Connection rewrite.
location = /mp/auth-challenge {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 30s;
}
location = /mp/session {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 30s;
    client_max_body_size 16k;
}

# Admin auto-update surface (v0.7.16-alpha). NIP-98 session + admin-npub gated
# on the arena-ws side. Plain HTTP, no Upgrade/Connection rewrite.
location = /mp/admin/update {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 30s;
    client_max_body_size 16k;
}
location = /mp/admin/update-status {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 30s;
}
location = /mp/admin/update-capability {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 10s;
}

# Arena WebSocket session. Client dials wss://\$host/mp.
location /mp {
    proxy_pass http://127.0.0.1:${ARENA_WS_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}
NGINX
)"
  if [[ ! -f "$MP_FRAGMENT_FILE" ]] || ! diff -q <(printf '%s\n' "$MP_FRAGMENT_CONTENT") "$MP_FRAGMENT_FILE" >/dev/null 2>&1; then
    log "writing nginx fragment ${MP_FRAGMENT_FILE}"
    printf '%s\n' "$MP_FRAGMENT_CONTENT" > "$MP_FRAGMENT_FILE"
  fi

  # 7h. Auto-update infrastructure (v0.7.16-alpha). arena-ws (torii-quest user,
  # hardened, no sudo) cannot run install-quest.sh itself. It writes a request
  # file to update-requests/; a root systemd path/service picks it up + runs the
  # bounded torii-quest-update-runner, which resolves the latest tag ITSELF and
  # redeploys. See installers/torii-quest-update-runner.sh for the security model.
  RUNNER_SRC="$(dirname "${BASH_SOURCE[0]}")/torii-quest-update-runner.sh"
  install -d -m 0770 -o torii-quest -g torii-quest /opt/torii-quest/mp/update-requests
  install -m 0755 "$RUNNER_SRC" /usr/local/sbin/torii-quest-update-runner
  : > /var/log/torii-quest-update.log; chmod 0644 /var/log/torii-quest-update.log
  cat > /etc/systemd/system/torii-quest-update.path <<'UNIT'
[Unit]
Description=Torii Quest auto-update trigger watcher

[Path]
PathChanged=/opt/torii-quest/mp/update-requests
Unit=torii-quest-update.service

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/torii-quest-update.service <<'UNIT'
[Unit]
Description=Torii Quest auto-update runner (root reinstall of latest tag)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/torii-quest-update-runner
UNIT
  chmod 0644 /etc/systemd/system/torii-quest-update.path /etc/systemd/system/torii-quest-update.service
  systemctl daemon-reload
  systemctl enable --now torii-quest-update.path >/dev/null 2>&1 || true

fi
export ARENA_WS_INSTALLED

/usr/local/bin/torii reload

if [[ "${ARENA_WS_INSTALLED:-0}" == "1" ]]; then
  log "quest install complete - https://${TORII_DOMAIN}/quest/ + wss://${TORII_DOMAIN}/mp"
else
  log "quest install complete - https://${TORII_DOMAIN}/quest/ (MP skipped)"
fi
