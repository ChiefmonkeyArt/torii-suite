#!/usr/bin/env bash
# torii-suite/installers/install-continuum.sh
#
# Installs Torii Continuum on a host that already has torii-base running.
#
# What this does (idempotent on re-run):
#   1. Clones/updates torii-continuum into $SUITE_WORK_DIR/torii-continuum
#   2. Builds the frontend and copies dist/ into /var/www/torii/continuum/
#   3. Creates the `continuum` system user and installs the agent into
#      /home/continuum/agent/repo/ following the recipe in
#      torii-continuum/agent/README.md
#   4. Writes /etc/systemd/system/continuum-agent.service and starts it
#   5. Drops an nginx fragment at /opt/torii/nginx-fragments/continuum.conf
#      that mounts the frontend at /continuum/ and proxies the agent at
#      /agent/ (both on the shared torii-base HTTPS server block)
#   6. Registers "continuum" with the torii-base sidecar via the `torii` CLI
#
# Env (inherited from bootstrap.sh):
#   TORII_DOMAIN, SUITE_WORK_DIR, TORII_CONTINUUM_REF,
#   CONTINUUM_ADMIN_NPUB, CONTINUUM_AGENT_PORT

set -euo pipefail

# --------------------------------------------------------------------------- #
# Preflight                                                                   #
# --------------------------------------------------------------------------- #

: "${TORII_DOMAIN:?install-continuum: TORII_DOMAIN not set (run via bootstrap.sh)}"
: "${SUITE_WORK_DIR:?install-continuum: SUITE_WORK_DIR not set}"
: "${CONTINUUM_ADMIN_NPUB:?install-continuum: CONTINUUM_ADMIN_NPUB not set}"

TORII_CONTINUUM_REF="${TORII_CONTINUUM_REF:-main}"
CONTINUUM_AGENT_PORT="${CONTINUUM_AGENT_PORT:-8787}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install-continuum must run as root"
command -v node >/dev/null 2>&1 || die "node not found (torii-base bootstrap should have installed it)"
command -v npm  >/dev/null 2>&1 || die "npm not found"

# --------------------------------------------------------------------------- #
# 1. Sync source                                                              #
# --------------------------------------------------------------------------- #

SRC="${SUITE_WORK_DIR}/torii-continuum"
if [[ -d "${SRC}/.git" ]]; then
  log "updating torii-continuum to ${TORII_CONTINUUM_REF}"
  git -C "$SRC" fetch --tags --prune origin
  # Land on a local branch pointed at the ref (never a detached HEAD) and
  # hard-reset to it. Idempotent on re-run and safe for both tags and branches.
  git -C "$SRC" checkout -B torii-continuum-deploy "$TORII_CONTINUUM_REF"
  git -C "$SRC" reset --hard "$TORII_CONTINUUM_REF"
else
  log "cloning torii-continuum @ ${TORII_CONTINUUM_REF}"
  git clone --branch "$TORII_CONTINUUM_REF" \
    https://github.com/ChiefmonkeyArt/torii-continuum.git "$SRC" 2>/dev/null \
    || git clone https://github.com/ChiefmonkeyArt/torii-continuum.git "$SRC"
  git -C "$SRC" checkout "$TORII_CONTINUUM_REF"
fi

RESOLVED_REF="$(git -C "$SRC" rev-parse --short HEAD)"
log "continuum source at commit ${RESOLVED_REF}"

# --------------------------------------------------------------------------- #
# 2. Build the frontend at base /continuum/                                   #
# --------------------------------------------------------------------------- #

log "building continuum frontend (base=/continuum/)"
(
  cd "$SRC"
  # Vite honors --base at CLI, which prefixes every emitted asset URL. The
  # continuum frontend is a straightforward SPA, so this is enough — no source
  # patching required.
  npm ci --no-audit --no-fund
  npm run build -- --base=/continuum/
)

WWW_DEST="/var/www/torii/continuum"
# Only the parent must exist; $WWW_DEST itself is a symlink managed by the
# atomic flip below. Pre-creating it as a directory breaks first-install
# because `mv -Tf` refuses to replace a real directory with a symlink.
mkdir -p "$(dirname "$WWW_DEST")"

# If a previous install (< v0.6.2-alpha) left $WWW_DEST as a real directory,
# migrate it aside so the symlink flip can succeed. Symlinks pass through.
if [[ -d "$WWW_DEST" && ! -L "$WWW_DEST" ]]; then
  log "migrating legacy $WWW_DEST directory aside (pre-v0.6.2 layout)"
  mv "$WWW_DEST" "${WWW_DEST}.legacy-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# Snapshot into a release dir + symlink flip. Keeps last install for rollback.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-${RESOLVED_REF}"
RELEASE_DIR="/var/www/torii/continuum-releases/${STAMP}"
mkdir -p "$(dirname "$RELEASE_DIR")"
cp -a "${SRC}/dist/." "${RELEASE_DIR}/"

# Atomic symlink flip: /var/www/torii/continuum → releases/<stamp>
ln -sfn "$RELEASE_DIR" "$WWW_DEST.new"
mv -Tf "$WWW_DEST.new" "$WWW_DEST"

# Retain last 3 releases.
find "$(dirname "$RELEASE_DIR")" -maxdepth 1 -mindepth 1 -type d \
  | sort | head -n -3 | xargs -r rm -rf

chown -R root:www-data "$RELEASE_DIR"
find "$RELEASE_DIR" -type d -exec chmod 755 {} +
find "$RELEASE_DIR" -type f -exec chmod 644 {} +

# --------------------------------------------------------------------------- #
# 3. Continuum agent — user, install, config                                  #
# --------------------------------------------------------------------------- #

if ! id continuum >/dev/null 2>&1; then
  log "creating 'continuum' system user"
  adduser --system --group --home /home/continuum --disabled-password \
          --gecos "Torii Continuum agent" continuum
fi

AGENT_HOME="/home/continuum/agent"
AGENT_REPO="${AGENT_HOME}/repo"

sudo -u continuum -H mkdir -p "$AGENT_HOME"
sudo -u continuum -H chmod 700 /home/continuum

if [[ -d "${AGENT_REPO}/.git" ]]; then
  log "updating continuum agent repo"
  sudo -u continuum -H git -C "$AGENT_REPO" fetch --tags --prune origin
  # Same detached-HEAD hardening as the frontend sync above: land on a local
  # branch and hard-reset, rather than pulling a tag into a detached HEAD.
  sudo -u continuum -H git -C "$AGENT_REPO" checkout -B torii-continuum-deploy "$TORII_CONTINUUM_REF"
  sudo -u continuum -H git -C "$AGENT_REPO" reset --hard "$TORII_CONTINUUM_REF"
else
  log "cloning continuum agent repo"
  sudo -u continuum -H git clone --branch "$TORII_CONTINUUM_REF" \
    https://github.com/ChiefmonkeyArt/torii-continuum.git "$AGENT_REPO" 2>/dev/null \
    || sudo -u continuum -H git clone \
       https://github.com/ChiefmonkeyArt/torii-continuum.git "$AGENT_REPO"
  sudo -u continuum -H git -C "$AGENT_REPO" checkout "$TORII_CONTINUUM_REF"
fi

log "installing agent npm deps (production)"
sudo -u continuum -H bash -c "cd '${AGENT_REPO}/agent' && npm ci --omit=dev --no-audit --no-fund"

# --------------------------------------------------------------------------- #
# 4. Agent config.yaml                                                        #
# --------------------------------------------------------------------------- #

CONFIG_FILE="${AGENT_REPO}/agent/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "writing agent config.yaml (first run)"
  sudo -u continuum -H cp "${AGENT_REPO}/agent/config.example.yaml" "$CONFIG_FILE"

  # Generate a session secret ourselves so the operator doesn't have to.
  SESSION_SECRET="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
  # Sanity: 32 bytes hex = exactly 64 chars, [0-9a-f] only. Anything else and
  # we abort before writing config — a bad secret means anyone can forge tokens.
  if [[ ! "$SESSION_SECRET" =~ ^[0-9a-f]{64}$ ]]; then
    die "session_secret generation failed: expected 64 hex chars, got ${#SESSION_SECRET}"
  fi

  # In-place edit via sed. Keys are unique in config.example.yaml so this is safe.
  sudo -u continuum -H sed -i \
    -e "s|^\(\s*admin_npub:\).*|\1 \"${CONTINUUM_ADMIN_NPUB}\"|" \
    -e "s|^\(\s*session_secret:\).*|\1 \"${SESSION_SECRET}\"|" \
    "$CONFIG_FILE"

  # Post-substitution sanity: the file must now contain our secret, not the
  # placeholder from config.example.yaml. Defence against a silent sed miss.
  if ! grep -qE "^\s*session_secret:[[:space:]]*\"${SESSION_SECRET}\"\s*$" "$CONFIG_FILE"; then
    die "session_secret substitution failed — config.yaml still shows the placeholder"
  fi
  if grep -qE 'session_secret:.*REPLACE_WITH' "$CONFIG_FILE"; then
    die "session_secret still contains REPLACE_WITH placeholder in $CONFIG_FILE"
  fi

  # Session TTL: only rewrite if the operator passed a non-default value.
  # Whole-number seconds, 60 (1 min) to 604800 (7 days). Anything outside
  # that range is a footgun and we refuse it.
  if [[ -n "${CONTINUUM_SESSION_TTL_SEC:-}" && "${CONTINUUM_SESSION_TTL_SEC}" != "86400" ]]; then
    if [[ ! "${CONTINUUM_SESSION_TTL_SEC}" =~ ^[0-9]+$ ]] \
       || (( CONTINUUM_SESSION_TTL_SEC < 60 )) \
       || (( CONTINUUM_SESSION_TTL_SEC > 604800 )); then
      die "CONTINUUM_SESSION_TTL_SEC must be an integer between 60 (1 min) and 604800 (7 days); got '${CONTINUUM_SESSION_TTL_SEC}'"
    fi
    sudo -u continuum -H sed -i \
      -e "s|^\(\s*session_ttl_sec:\).*|\1 ${CONTINUUM_SESSION_TTL_SEC}|" \
      "$CONFIG_FILE"
    log "session_ttl_sec set to ${CONTINUUM_SESSION_TTL_SEC}s"
  fi

  # Make sure the agent listens on the port the nginx fragment will proxy to.
  # (Idempotent: only rewrites if a port: line exists at the top level.)
  sudo -u continuum -H sed -i \
    -e "s|^\(\s*port:\)\s*[0-9]\+|\1 ${CONTINUUM_AGENT_PORT}|" \
    "$CONFIG_FILE"

  # Add the domain to cors_origins if the key exists.
  if grep -q "cors_origins:" "$CONFIG_FILE"; then
    sudo -u continuum -H python3 - "$CONFIG_FILE" "https://${TORII_DOMAIN}" <<'PY'
import sys, re, pathlib
path, origin = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
# Idempotent: only append if the origin isn't already listed.
if origin in text:
    sys.exit(0)
# Match the cors_origins list opener (block or flow) and append a bullet.
text = re.sub(
    r"(cors_origins:\s*\n(?:\s*-\s+.*\n)*)",
    lambda m: f"{m.group(1)}    - \"{origin}\"\n",
    text,
    count=1,
)
path.write_text(text)
PY
  fi

  chmod 600 "$CONFIG_FILE"
  chown continuum:continuum "$CONFIG_FILE"
else
  log "agent config.yaml already exists — leaving in place"
fi

# --------------------------------------------------------------------------- #
# 4b. Ollama enablement (idempotent, safe to re-run)                          #
# --------------------------------------------------------------------------- #
#
# When the suite is asked to install Ollama, the agent config's `ollama.enabled`
# flag must flip to true so the model router will actually consider the local
# daemon as a fallback. We do this on every run (not just first-run) so that a
# later `INSTALL_OLLAMA=1 bootstrap.sh` on an existing install picks up the
# change without the operator hand-editing config.yaml.
#
if [[ "${INSTALL_OLLAMA:-0}" == "1" ]]; then
  _ollama_mode="${OLLAMA_MODE:-local}"
  # Resolve the endpoint we want the agent to hit.
  if [[ "$_ollama_mode" == "remote" ]]; then
    _ollama_target="${OLLAMA_URL%/}"
    log "flipping ollama.enabled -> true and pointing ollama.host at ${_ollama_target} in agent/config.yaml"
  else
    _ollama_target="http://${OLLAMA_BIND:-127.0.0.1:11434}"
    log "flipping ollama.enabled -> true in agent/config.yaml (local mode, host stays at ${_ollama_target})"
  fi
  # Python is more reliable than sed for YAML-adjacent edits; the file already
  # requires python3 above for cors_origins, so no new dependency.
  # `set -e` would kill us on the python heredoc's non-zero exit; guard it.
  set +e
  sudo -u continuum -H \
    OLLAMA_TARGET="$_ollama_target" \
    OLLAMA_MODE="$_ollama_mode" \
    OLLAMA_AUTH_HEADER="${OLLAMA_AUTH_HEADER:-}" \
    python3 - "$CONFIG_FILE" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
target = os.environ.get("OLLAMA_TARGET", "")
mode = os.environ.get("OLLAMA_MODE", "local")
auth = os.environ.get("OLLAMA_AUTH_HEADER", "")

# 1. Flip enabled: true inside the top-level ollama: block.
new_text, n = re.subn(
    r"(^ollama:\s*\n(?:[ \t]+.*\n)*?[ \t]+enabled:\s*)(?:true|false)",
    r"\1true",
    text,
    count=1,
    flags=re.MULTILINE,
)
if n == 0:
    # No ollama block — caller will warn.
    sys.exit(2)

# 2. Rewrite host: <url> inside the same block. Only touches the ollama block.
#    Handles both quoted and unquoted values, preserves indentation.
def _replace_field(src, field, value):
    pat = re.compile(
        rf'(^ollama:\s*\n(?:[ \t]+.*\n)*?[ \t]+{field}:\s*)(?:"[^"]*"|\'[^\']*\'|[^\n]*)',
        re.MULTILINE,
    )
    # Always emit the value double-quoted so URLs and header strings with
    # colons don't confuse the YAML parser.
    safe = value.replace('"', '\\"')
    return pat.subn(rf'\g<1>"{safe}"', src, count=1)

new_text, n_host = _replace_field(new_text, "host", target)
# `host:` might not exist yet in older configs — that's OK, agent will use its
# own default. We only care that it was set correctly if it was present.
if mode == "remote" and n_host == 0:
    # For remote mode we NEED the host to be set. Inject it right after
    # the enabled: line so the agent actually points at the endpoint.
    def _inject(src, field, value):
        pat = re.compile(
            r"(^ollama:\s*\n(?:[ \t]+.*\n)*?)([ \t]+)(enabled:\s*(?:true|false)\n)",
            re.MULTILINE,
        )
        safe = value.replace('"', '\\"')
        return pat.subn(rf'\g<1>\g<2>\g<3>\g<2>{field}: "{safe}"\n', src, count=1)
    new_text, _ = _inject(new_text, "host", target)

# 3. Auth header for remote endpoints behind a reverse proxy.
if mode == "remote" and auth:
    new_text, n_auth = _replace_field(new_text, "auth_header", auth)
    if n_auth == 0:
        # Same injection trick as above for the auth field.
        pat = re.compile(
            r"(^ollama:\s*\n(?:[ \t]+.*\n)*?)([ \t]+)(enabled:\s*(?:true|false)\n)",
            re.MULTILINE,
        )
        safe = auth.replace('"', '\\"')
        new_text = pat.sub(
            rf'\g<1>\g<2>\g<3>\g<2>auth_header: "{safe}"\n', new_text, count=1
        )

path.write_text(new_text)
PY
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    warn "agent/config.yaml has no 'ollama:' block — leaving Ollama alone (agent will run Routstr-only)"
  elif [[ $rc -ne 0 ]]; then
    die "failed to update ollama config in ${CONFIG_FILE}"
  fi
  unset _ollama_mode _ollama_target
fi

# --------------------------------------------------------------------------- #
# 4c. Rate limit config (v0.6.0-alpha, SUITE-VPS-READY-1)                     #
# --------------------------------------------------------------------------- #
#
# Continuum v0.2.14-alpha ships with a defaults-populated `rate_limit:` block
# in agent/config.example.yaml. The agent also defaults sensibly if the block
# is entirely absent (loader fills it in on boot), so the very worst case here
# is a no-op. But we still write the block from the four CONTINUUM_RATE_LIMIT_*
# env vars so operators can tune on install by editing /opt/torii-suite/.env
# and re-running bootstrap.sh - same UX as the ollama block above.
#
# Idempotent: on first install the block is injected below the closing brace
# of the audit_log logging entry; on re-run the existing keys are rewritten
# in-place.
_rl_enabled="${CONTINUUM_RATE_LIMIT_ENABLED:-1}"
_rl_challenge="${CONTINUUM_RATE_LIMIT_CHALLENGE_PER_MIN:-10}"
_rl_verify="${CONTINUUM_RATE_LIMIT_VERIFY_PER_MIN:-20}"
_rl_max="${CONTINUUM_RATE_LIMIT_MAX_CHALLENGES:-1000}"

# Bool-ify: env vars are always strings.
if [[ "$_rl_enabled" == "0" || "$_rl_enabled" == "false" ]]; then
  _rl_enabled_yaml="false"
else
  _rl_enabled_yaml="true"
fi

log "writing rate_limit block to agent/config.yaml (enabled=${_rl_enabled_yaml}, challenge=${_rl_challenge}/min, verify=${_rl_verify}/min, max_challenges=${_rl_max})"
set +e
sudo -u continuum -H \
  RL_ENABLED="$_rl_enabled_yaml" \
  RL_CHALLENGE="$_rl_challenge" \
  RL_VERIFY="$_rl_verify" \
  RL_MAX="$_rl_max" \
  python3 - "$CONFIG_FILE" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
enabled = os.environ.get("RL_ENABLED", "true")
challenge = os.environ.get("RL_CHALLENGE", "10")
verify = os.environ.get("RL_VERIFY", "20")
max_ch = os.environ.get("RL_MAX", "1000")

# Match the top-level `rate_limit:` block.
#
# Note vs. the ollama patcher: rate_limit's rendered form in
# config.example.yaml includes blank lines between keys and inline `  #`
# comments. `[ \t]+.*\n` alone stops at the first blank line and leaves
# `auth_challenge_per_min: ...` orphaned under a stripped-and-rewritten
# block, which then produces duplicate keys on re-run. The pattern below
# also matches blank lines (`[ \t]*\n`) and stops only at a line that
# starts flush-left with a non-whitespace character (the next top-level
# YAML key), which is the real block boundary.
block_re = re.compile(
    r"(^rate_limit:\s*\n(?:(?:[ \t]+.*|[ \t]*)\n)*)",
    re.MULTILINE,
)

desired = (
    "rate_limit:\n"
    f"  enabled: {enabled}\n"
    f"  auth_challenge_per_min: {challenge}\n"
    f"  auth_verify_per_min: {verify}\n"
    f"  max_challenges: {max_ch}\n"
)

if block_re.search(text):
    new_text = block_re.sub(desired, text, count=1)
else:
    # No block present (older config.example.yaml or manually stripped).
    # Append with a preceding blank line so YAML stays clean.
    if not text.endswith("\n"):
        text = text + "\n"
    new_text = text + "\n" + desired

path.write_text(new_text)
PY
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  die "failed to update rate_limit config in ${CONFIG_FILE}"
fi
unset _rl_enabled _rl_challenge _rl_verify _rl_max _rl_enabled_yaml

# --------------------------------------------------------------------------- #
# 5. systemd unit                                                             #
# --------------------------------------------------------------------------- #

UNIT_FILE="/etc/systemd/system/continuum-agent.service"
UNIT_CONTENT="$(cat <<UNIT
[Unit]
Description=Continuum Agent (Fastify)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=continuum
Group=continuum
WorkingDirectory=${AGENT_REPO}/agent
Environment=NODE_ENV=production
ExecStart=/usr/bin/env node index.mjs
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=${AGENT_REPO}/agent
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
)"

# Only touch the unit if content changed — avoids needless restarts on re-run.
if [[ ! -f "$UNIT_FILE" ]] || ! diff -q <(echo "$UNIT_CONTENT") "$UNIT_FILE" >/dev/null; then
  log "writing continuum-agent.service"
  echo "$UNIT_CONTENT" > "$UNIT_FILE"
  systemctl daemon-reload
fi

systemctl enable continuum-agent.service >/dev/null
systemctl restart continuum-agent.service
sleep 1
if ! systemctl is-active --quiet continuum-agent.service; then
  systemctl status continuum-agent.service --no-pager || true
  die "continuum-agent failed to start (see status above)"
fi
log "continuum-agent active on 127.0.0.1:${CONTINUUM_AGENT_PORT}"

# --------------------------------------------------------------------------- #
# 6. nginx fragment                                                           #
# --------------------------------------------------------------------------- #

FRAGMENT_DIR="/opt/torii/nginx-fragments"
FRAGMENT_FILE="${FRAGMENT_DIR}/continuum.conf"
mkdir -p "$FRAGMENT_DIR"

FRAGMENT_CONTENT="$(cat <<NGINX
# /opt/torii/nginx-fragments/continuum.conf — written by torii-suite

# Frontend static bundle.
#
# NOTE (v0.7.0-alpha): the previous fragment used a nested
# `location ~* ^/continuum/assets/...` with `alias /var/www/torii/continuum/;`
# to attach cache headers. That pattern is broken: nginx does not strip the
# location prefix when `alias` is used inside a regex location, so the file
# lookup fails, the outer `try_files` fallback catches it, and every asset
# request 301s to `<path>/` and is served the SPA shell as text/html. This
# breaks every hashed JS/CSS bundle -> blank page.
#
# Fix: use prefix `location /continuum/assets/` (nginx handles prefix + alias
# correctly), cache the whole /assets/ tree since Vite hashes every file in
# it, and return 404 on miss instead of falling through to the SPA shell.
location /continuum/ {
    alias /var/www/torii/continuum/;
    try_files \$uri \$uri/ /continuum/index.html;

    location /continuum/assets/ {
        alias /var/www/torii/continuum/assets/;
        try_files \$uri =404;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable" always;
    }
    location = /continuum/index.html {
        alias /var/www/torii/continuum/index.html;
        add_header Cache-Control "no-store" always;
    }
}

# Agent — reverse proxy to the Fastify daemon on 127.0.0.1
location /agent/ {
    proxy_pass         http://127.0.0.1:${CONTINUUM_AGENT_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Host              \$host;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   Upgrade           \$http_upgrade;
    proxy_set_header   Connection        "upgrade";
    proxy_read_timeout 60s;
    client_max_body_size 1m;
}
NGINX
)"

if [[ ! -f "$FRAGMENT_FILE" ]] || ! diff -q <(echo "$FRAGMENT_CONTENT") "$FRAGMENT_FILE" >/dev/null; then
  log "writing nginx fragment ${FRAGMENT_FILE}"
  echo "$FRAGMENT_CONTENT" > "$FRAGMENT_FILE"
fi

# --------------------------------------------------------------------------- #
# 7. Register with the torii-base sidecar and reload nginx                    #
# --------------------------------------------------------------------------- #

# Version string for the registry — read from the agent's package.json.
CONTINUUM_VERSION="$(node -p "require('${AGENT_REPO}/agent/package.json').version" 2>/dev/null || echo "unknown")"

log "registering 'continuum' with torii sidecar (v${CONTINUUM_VERSION})"
/usr/local/bin/torii register continuum \
  --display "Continuum" \
  --desc    "AI-powered app builder + Nostr agent" \
  --version "${CONTINUUM_VERSION}"

/usr/local/bin/torii reload

log "continuum install complete — https://${TORII_DOMAIN}/continuum/"
