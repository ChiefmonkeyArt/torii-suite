#!/usr/bin/env bash
# torii-suite/bootstrap.sh — one-command Torii Suite installer.
#
# Orchestrates the full deployment of the Torii Suite on a fresh Ubuntu VPS:
#
#   1. torii-base   — nginx + launcher + sidecar (the host layer)
#   2. Continuum    — frontend at /continuum/ + Fastify agent proxied at /agent/
#   3. Torii Quest  — static bundle at /quest/
#   4. Plebeian     — external tile at /plebeian/ (registered, not installed)
#
# Usage (as root, from a checkout of torii-suite):
#
#   sudo -E ./bootstrap.sh
#
# Environment (see .env.example for the full contract):
#
#   Required:  TORII_DOMAIN, LETSENCRYPT_EMAIL, CONTINUUM_ADMIN_NPUB
#   Opt-in:    INSTALL_CONTINUUM, INSTALL_QUEST, INSTALL_PLEBEIAN
#   Overrides: SUITE_WORK_DIR, TORII_*_REF, CONTINUUM_AGENT_PORT, SKIP_CERTBOT
#
# Idempotent: re-running the script pulls the latest ref for each repo,
# rebuilds only if the resolved commit changed, and re-registers apps if the
# launcher registry is missing them.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Constants + logging                                                         #
# --------------------------------------------------------------------------- #

SUITE_VERSION="$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION" 2>/dev/null || echo "unknown")"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }
step() { printf "\n\033[35m### %s ###\033[0m\n\n" "$*"; }

# --------------------------------------------------------------------------- #
# Preflight                                                                   #
# --------------------------------------------------------------------------- #

[[ $EUID -eq 0 ]] || die "bootstrap must run as root (try: sudo -E ./bootstrap.sh)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if the operator dropped one alongside the script.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# --- required env ---
: "${TORII_DOMAIN:?set TORII_DOMAIN=<yourdomain> (see .env.example)}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL=<you@example.com>}"

# --- opt-in flags (default: install everything) ---
INSTALL_CONTINUUM="${INSTALL_CONTINUUM:-1}"
INSTALL_QUEST="${INSTALL_QUEST:-1}"
INSTALL_PLEBEIAN="${INSTALL_PLEBEIAN:-1}"

# --- continuum requires an admin npub if opted in ---
if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  : "${CONTINUUM_ADMIN_NPUB:?set CONTINUUM_ADMIN_NPUB=npub1... (or INSTALL_CONTINUUM=0 to skip)}"
  [[ "$CONTINUUM_ADMIN_NPUB" == npub1* ]] \
    || die "CONTINUUM_ADMIN_NPUB must be a bech32 npub (starts with npub1)"
fi

# --- overrides + defaults ---
SUITE_WORK_DIR="${SUITE_WORK_DIR:-/opt/torii-suite/work}"
TORII_BASE_REF="${TORII_BASE_REF:-main}"
TORII_CONTINUUM_REF="${TORII_CONTINUUM_REF:-main}"
TORII_QUEST_REF="${TORII_QUEST_REF:-main}"
CONTINUUM_AGENT_PORT="${CONTINUUM_AGENT_PORT:-8787}"
PLEBEIAN_EXTERNAL_URL="${PLEBEIAN_EXTERNAL_URL:-https://plebeian.market}"
SKIP_CERTBOT="${SKIP_CERTBOT:-0}"

export TORII_DOMAIN LETSENCRYPT_EMAIL SKIP_CERTBOT
export CONTINUUM_ADMIN_NPUB CONTINUUM_AGENT_PORT
export SUITE_WORK_DIR

# --------------------------------------------------------------------------- #
# Banner                                                                      #
# --------------------------------------------------------------------------- #

cat <<BANNER
=============================================================
  torii-suite bootstrap  v${SUITE_VERSION}
  Domain:            ${TORII_DOMAIN}
  Work dir:          ${SUITE_WORK_DIR}
  Continuum:         $( [[ "$INSTALL_CONTINUUM" == "1" ]] && echo "install (agent :${CONTINUUM_AGENT_PORT})" || echo "SKIP" )
  Quest:             $( [[ "$INSTALL_QUEST" == "1" ]] && echo "install" || echo "SKIP" )
  Plebeian tile:     $( [[ "$INSTALL_PLEBEIAN" == "1" ]] && echo "register (${PLEBEIAN_EXTERNAL_URL})" || echo "SKIP" )
  Let's Encrypt:     $( [[ "$SKIP_CERTBOT" == "1" ]] && echo "SKIP" || echo "enabled (${LETSENCRYPT_EMAIL})" )
=============================================================
BANNER

# Give the operator a chance to abort without --yes clutter.
if [[ -t 0 && "${SUITE_ASSUME_YES:-0}" != "1" ]]; then
  read -rp "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by operator"
fi

mkdir -p "$SUITE_WORK_DIR"

# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #

# clone_or_pull <repo_url> <ref> <dest>
# Idempotent: clones on first run, `git fetch` + `git checkout` on subsequent runs.
clone_or_pull() {
  local url="$1" ref="$2" dest="$3"
  if [[ -d "${dest}/.git" ]]; then
    log "updating $(basename "$dest") to ${ref}"
    git -C "$dest" fetch --tags --prune origin
    git -C "$dest" checkout "$ref"
    # Fast-forward if ref is a branch; ignore failure if it's a tag/detached.
    git -C "$dest" pull --ff-only origin "$ref" 2>/dev/null || true
  else
    log "cloning $(basename "$dest") @ ${ref}"
    git clone --branch "$ref" "$url" "$dest" 2>/dev/null \
      || git clone "$url" "$dest"
    git -C "$dest" checkout "$ref"
  fi
}

# torii_cli <args...> — thin wrapper so we don't have to remember to load env.
torii_cli() {
  local torii_bin="/usr/local/bin/torii"
  [[ -x "$torii_bin" ]] || die "torii CLI not found at ${torii_bin} (base bootstrap failed?)"
  "$torii_bin" "$@"
}

# --------------------------------------------------------------------------- #
# STAGE 1 — torii-base                                                        #
# --------------------------------------------------------------------------- #

step "STAGE 1 — install torii-base (host layer)"

BASE_SRC="${SUITE_WORK_DIR}/torii-base"
clone_or_pull "https://github.com/ChiefmonkeyArt/torii-base.git" "$TORII_BASE_REF" "$BASE_SRC"

log "running torii-base bootstrap"
(
  cd "$BASE_SRC"
  TORII_DOMAIN="$TORII_DOMAIN" \
  LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" \
  SKIP_CERTBOT="$SKIP_CERTBOT" \
    ./bootstrap.sh
)

# --------------------------------------------------------------------------- #
# STAGE 2 — Continuum                                                         #
# --------------------------------------------------------------------------- #

if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  step "STAGE 2 — install Continuum (frontend + agent)"
  "${SCRIPT_DIR}/installers/install-continuum.sh"
else
  log "STAGE 2 skipped (INSTALL_CONTINUUM=0)"
fi

# --------------------------------------------------------------------------- #
# STAGE 3 — Torii Quest                                                       #
# --------------------------------------------------------------------------- #

if [[ "$INSTALL_QUEST" == "1" ]]; then
  step "STAGE 3 — install Torii Quest (static bundle)"
  "${SCRIPT_DIR}/installers/install-quest.sh"
else
  log "STAGE 3 skipped (INSTALL_QUEST=0)"
fi

# --------------------------------------------------------------------------- #
# STAGE 4 — Plebeian tile registration                                        #
# --------------------------------------------------------------------------- #

if [[ "$INSTALL_PLEBEIAN" == "1" ]]; then
  step "STAGE 4 — register Plebeian Market tile"
  "${SCRIPT_DIR}/installers/register-plebeian.sh"
else
  log "STAGE 4 skipped (INSTALL_PLEBEIAN=0)"
fi

# --------------------------------------------------------------------------- #
# STAGE 5 — doctor                                                            #
# --------------------------------------------------------------------------- #

step "STAGE 5 — doctor"

torii_cli status || warn "torii status returned non-zero"
echo
torii_cli doctor || warn "torii doctor reported issues — review above"

# --------------------------------------------------------------------------- #
# Done                                                                        #
# --------------------------------------------------------------------------- #

cat <<DONE

=============================================================
  Torii Suite install complete.

  Launcher:    https://${TORII_DOMAIN}/
$( [[ "$INSTALL_CONTINUUM" == "1" ]] && echo "  Continuum:   https://${TORII_DOMAIN}/continuum/" )
$( [[ "$INSTALL_QUEST" == "1" ]]     && echo "  Quest:       https://${TORII_DOMAIN}/quest/" )
$( [[ "$INSTALL_PLEBEIAN" == "1" ]]  && echo "  Plebeian:    ${PLEBEIAN_EXTERNAL_URL}" )

  Next steps:
    - Visit the launcher and pick your homepage app: sudo torii set-root <name>
    - Top up your Cashu wallet in Continuum → Routstr (see docs/CONTINUUM.md)
    - Bump versions and re-run this script to update.

  Ops guide:   docs/OPS.md
  Repo:        https://github.com/ChiefmonkeyArt/torii-suite
=============================================================
DONE
