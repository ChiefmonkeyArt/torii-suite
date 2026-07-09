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
# torii-quest currently ships without a `base:` in defineConfig and bakes
# absolute paths (`/assets/torii-entry.js?v=…`) into the inline bootstrap.
# Rebuilding with `--base=/quest/` alone doesn't rewrite that literal string.
#
# The patch below:
#   - injects `base: '/quest/',` into the defineConfig object
#   - rewrites the two hardcoded `/assets/torii-entry.js` literals to
#     `/quest/assets/torii-entry.js`
#
# We apply it only if the file still has the un-patched literals — safe to
# re-run.

CONFIG_FILE="${SRC}/vite.config.js"
[[ -f "$CONFIG_FILE" ]] || die "expected ${CONFIG_FILE} to exist"

if grep -q "'/quest/assets/torii-entry\.js'" "$CONFIG_FILE" \
   || grep -q "\"/quest/assets/torii-entry\.js\"" "$CONFIG_FILE"; then
  log "quest vite.config.js already patched for /quest/ base"
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

location /quest/ {
    alias /var/www/torii/quest/;
    try_files \$uri \$uri/ /quest/index.html;

    # Long-cache hashed assets; never cache the shell.
    location ~* ^/quest/assets/.*\.(js|css|woff2?|svg|png|jpg|jpeg|webp|glb|gltf|bin|ktx2|hdr)\$ {
        alias /var/www/torii/quest/;
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

/usr/local/bin/torii reload

log "quest install complete — https://${TORII_DOMAIN}/quest/"
