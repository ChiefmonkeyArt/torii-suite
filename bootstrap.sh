#!/usr/bin/env bash
# torii-suite/bootstrap.sh — one-command Torii Suite installer.
#
# Orchestrates the full deployment of the Torii Suite on a fresh Ubuntu VPS:
#
#   1. torii-base   — nginx + launcher + sidecar (the host layer)
#   2. Continuum    — frontend at /continuum/ + Fastify agent proxied at /agent/
#   2b. Ollama      — loopback LLM daemon so Continuum has a local fallback
#   3. Torii Quest  — static bundle at /quest/
#   4. Plebeian     — external tile at /plebeian/ (registered, not installed)
#
# Two ways to run:
#
#   A. One-liner (recommended for non-coders):
#
#      curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/main/bootstrap.sh | sudo bash
#
#      The script clones itself, asks three questions (domain, LE email, admin
#      npub), then installs everything. No pre-editing required.
#
#   B. From a manual checkout (for operators who prefer a .env file):
#
#      git clone https://github.com/ChiefmonkeyArt/torii-suite
#      cd torii-suite
#      cp .env.example .env && nano .env
#      sudo -E ./bootstrap.sh
#
# Environment (see .env.example for the full contract):
#
#   Required:  TORII_DOMAIN, LETSENCRYPT_EMAIL, CONTINUUM_ADMIN_NPUB
#   Opt-in:    INSTALL_CONTINUUM, INSTALL_QUEST, INSTALL_PLEBEIAN, INSTALL_OLLAMA
#   Overrides: SUITE_WORK_DIR, TORII_*_REF, CONTINUUM_AGENT_PORT, SKIP_CERTBOT,
#              OLLAMA_MODELS, OLLAMA_BIND
#
# Idempotent: re-running the script pulls the latest ref for each repo,
# rebuilds only if the resolved commit changed, and re-registers apps if the
# launcher registry is missing them.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Logging                                                                     #
# --------------------------------------------------------------------------- #

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }
step() { printf "\n\033[35m### %s ###\033[0m\n\n" "$*"; }
ask()  { # ask <prompt> <var> [<default>]
  local prompt="$1" var="$2" default="${3:-}" reply
  if [[ -n "$default" ]]; then
    printf "\033[36m?\033[0m %s [%s]: " "$prompt" "$default" > /dev/tty
  else
    printf "\033[36m?\033[0m %s: " "$prompt" > /dev/tty
  fi
  read -r reply < /dev/tty
  reply="${reply:-$default}"
  printf -v "$var" '%s' "$reply"
}

# --------------------------------------------------------------------------- #
# Root check (comes before everything else)                                   #
# --------------------------------------------------------------------------- #

[[ $EUID -eq 0 ]] || die "bootstrap must run as root (try: sudo bash bootstrap.sh, or pipe: curl ... | sudo bash)"

# --------------------------------------------------------------------------- #
# Self-hoist: if we're being piped in (curl | sudo bash) then $0 is a bash    #
# child with no on-disk script. Clone the repo and re-exec the copy on disk   #
# so paths, installers, and .env behave normally.                             #
# --------------------------------------------------------------------------- #

SUITE_REPO_URL="${SUITE_REPO_URL:-https://github.com/ChiefmonkeyArt/torii-suite.git}"
SUITE_CLONE_REF="${SUITE_CLONE_REF:-main}"
SUITE_INSTALL_DIR="${SUITE_INSTALL_DIR:-/opt/torii-suite/checkout}"

# Detect the "piped in" case: BASH_SOURCE[0] points at something that isn't a
# real, readable file (usually /dev/fd/... or empty), OR the file exists but
# its containing directory has no VERSION file (i.e. not a real checkout).
NEEDS_HOIST=0
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  NEEDS_HOIST=1
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! -f "${SCRIPT_DIR}/VERSION" ]]; then
    NEEDS_HOIST=1
  fi
fi

if [[ "$NEEDS_HOIST" == "1" ]]; then
  log "one-liner mode detected — cloning torii-suite into ${SUITE_INSTALL_DIR}"

  # Need git + curl + ca-certificates before anything else.
  if ! command -v git >/dev/null 2>&1; then
    log "installing git + curl + ca-certificates"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates
  fi

  mkdir -p "$(dirname "$SUITE_INSTALL_DIR")"
  if [[ -d "${SUITE_INSTALL_DIR}/.git" ]]; then
    log "existing checkout found — updating to ${SUITE_CLONE_REF}"
    git -C "$SUITE_INSTALL_DIR" fetch --tags --prune origin
    git -C "$SUITE_INSTALL_DIR" checkout "$SUITE_CLONE_REF"
    git -C "$SUITE_INSTALL_DIR" pull --ff-only origin "$SUITE_CLONE_REF" 2>/dev/null || true
  else
    git clone --branch "$SUITE_CLONE_REF" "$SUITE_REPO_URL" "$SUITE_INSTALL_DIR" 2>/dev/null \
      || git clone "$SUITE_REPO_URL" "$SUITE_INSTALL_DIR"
    git -C "$SUITE_INSTALL_DIR" checkout "$SUITE_CLONE_REF"
  fi

  log "re-executing on-disk bootstrap: ${SUITE_INSTALL_DIR}/bootstrap.sh"
  # Preserve env so anything the operator set on the curl command line survives
  # the re-exec. Do NOT re-hoist (guard flag).
  export SUITE_HOISTED=1
  exec "${SUITE_INSTALL_DIR}/bootstrap.sh" "$@"
fi

# --------------------------------------------------------------------------- #
# Constants                                                                   #
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"

# --------------------------------------------------------------------------- #
# Preflight                                                                   #
# --------------------------------------------------------------------------- #

step "preflight — checking host is ready for install"

# 1. Ubuntu version. Accept 22.04, 24.04, 26.04. Others get a warning, not an
#    abort, because a friend running Debian testing may still succeed and we
#    don't want to be paternalistic.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    case "${VERSION_ID:-}" in
      22.04|24.04|26.04) log "OS: Ubuntu ${VERSION_ID} (supported)" ;;
      *) warn "OS: Ubuntu ${VERSION_ID} — untested but proceeding" ;;
    esac
  else
    warn "OS: ${PRETTY_NAME:-unknown} — torii-suite officially targets Ubuntu 22.04/24.04/26.04"
  fi
else
  warn "cannot detect OS (no /etc/os-release) — proceeding anyway"
fi

# 2. Ports 80 + 443 must be free (or already owned by nginx from a previous run).
for port in 80 443; do
  # ss is in iproute2 on all supported Ubuntu versions.
  if ss -H -tln "sport = :${port}" | grep -q .; then
    # If nginx already owns it, that's fine — a re-run of the bootstrap.
    if ss -H -tlnp "sport = :${port}" 2>/dev/null | grep -q '"nginx"'; then
      log "port ${port}: already bound by nginx (previous install detected)"
    else
      warn "port ${port} is in use by something other than nginx"
      warn "  run:  ss -tlnp 'sport = :${port}'  to see what's holding it"
      die  "port ${port} must be free before install (or hand it off to nginx)"
    fi
  else
    log "port ${port}: free"
  fi
done

# 3. Basic tool availability. torii-base's own bootstrap installs the rest, but
#    we need enough to run our preflight (dig for DNS, curl for downloads).
for tool in curl dig git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log "installing missing tool: ${tool}"
    apt-get update -qq
    case "$tool" in
      dig) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils ;;
      *)   DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$tool" ;;
    esac
  fi
done

# --------------------------------------------------------------------------- #
# Interactive setup (only when .env doesn't already exist)                    #
# --------------------------------------------------------------------------- #

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  log "found existing .env at ${SCRIPT_DIR}/.env — using it"
  # shellcheck disable=SC1091
  set -a; source "${SCRIPT_DIR}/.env"; set +a
elif [[ -e /dev/tty ]]; then
  step "setup — three questions"
  cat <<'INTRO' > /dev/tty

torii-suite needs three things to get started:

  1. A domain name that already points at this VPS's public IP
     (one A record — e.g. torii.example.com → 203.0.113.10)
  2. An email address for Let's Encrypt (free HTTPS certificates).
     Used only for cert-expiry warnings — any working inbox is fine.
  3. Your Nostr npub (from Plebeian Signer, nos2x, or another NIP-07 signer)
     — this is the account that will be the Continuum admin. NEVER an nsec.

INTRO

  ask "Domain (e.g. torii.example.com)"          TORII_DOMAIN
  [[ -n "$TORII_DOMAIN" ]] || die "domain is required"

  ask "Email for Let's Encrypt (HTTPS cert expiry warnings)" LETSENCRYPT_EMAIL
  [[ "$LETSENCRYPT_EMAIL" == *@*.* ]] || die "email doesn't look like an email"

  ask "Your admin npub (starts with npub1)"       CONTINUUM_ADMIN_NPUB
  [[ "$CONTINUUM_ADMIN_NPUB" == npub1* ]] \
    || die "CONTINUUM_ADMIN_NPUB must be a bech32 npub (starts with npub1)"

  # Write the answers so re-runs don't ask again.
  log "writing answers to ${SCRIPT_DIR}/.env (mode 0600)"
  umask 077
  cat > "${SCRIPT_DIR}/.env" <<EOF
# Written by bootstrap.sh interactive setup on $(date -u +%Y-%m-%dT%H:%M:%SZ)
TORII_DOMAIN="${TORII_DOMAIN}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB}"
EOF
  umask 022
else
  die "no .env and no interactive terminal — set TORII_DOMAIN, LETSENCRYPT_EMAIL, CONTINUUM_ADMIN_NPUB and try again"
fi

# --- required env (belt and braces after prompts/env loading) ---
: "${TORII_DOMAIN:?set TORII_DOMAIN=<yourdomain> (see .env.example)}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL=<you@example.com>}"

# --- opt-in flags (defaults geared to "100% Continuum + 100% Quest") ---
INSTALL_CONTINUUM="${INSTALL_CONTINUUM:-1}"
INSTALL_QUEST="${INSTALL_QUEST:-1}"
INSTALL_OLLAMA="${INSTALL_OLLAMA:-1}"       # v0.2.0: on by default when Continuum is on
INSTALL_PLEBEIAN="${INSTALL_PLEBEIAN:-1}"   # tile only — see register-plebeian.sh
# Onboarding bridges (CORS proxy + WebSSH) stay OFF unless the operator asks for them.
INSTALL_ONBOARDING_BRIDGES="${INSTALL_ONBOARDING_BRIDGES:-0}"

# Ollama only makes sense when Continuum is installed. Coerce and warn.
if [[ "$INSTALL_OLLAMA" == "1" && "$INSTALL_CONTINUUM" != "1" ]]; then
  warn "INSTALL_OLLAMA=1 but INSTALL_CONTINUUM=0 — Ollama has no consumer, disabling"
  INSTALL_OLLAMA=0
fi

# --- bridges require explicit allowlists if opted in ---
if [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]; then
  : "${CORS_PROXY_ORIGIN_ALLOW:?set CORS_PROXY_ORIGIN_ALLOW=... (or INSTALL_ONBOARDING_BRIDGES=0)}"
  : "${WEBSSH_ORIGIN_ALLOW:?set WEBSSH_ORIGIN_ALLOW=... (or INSTALL_ONBOARDING_BRIDGES=0)}"
fi

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

# Ollama defaults (CPU-only, small model).
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1:11434}"
OLLAMA_MODELS="${OLLAMA_MODELS:-llama3.2:3b}"

# Bridge defaults (only consulted when INSTALL_ONBOARDING_BRIDGES=1)
CORS_PROXY_UPSTREAM_ALLOW="${CORS_PROXY_UPSTREAM_ALLOW:-blesta.sovereignhybridcompute.com}"
CORS_PROXY_PORT="${CORS_PROXY_PORT:-8801}"
WEBSSH_PORT="${WEBSSH_PORT:-8802}"
WEBSSH_MAX_PER_IP="${WEBSSH_MAX_PER_IP:-3}"
WEBSSH_MAX_SESSION_MS="${WEBSSH_MAX_SESSION_MS:-900000}"

export TORII_DOMAIN LETSENCRYPT_EMAIL SKIP_CERTBOT
export CONTINUUM_ADMIN_NPUB CONTINUUM_AGENT_PORT
export INSTALL_OLLAMA OLLAMA_BIND OLLAMA_MODELS
export SUITE_WORK_DIR
export CORS_PROXY_ORIGIN_ALLOW CORS_PROXY_UPSTREAM_ALLOW CORS_PROXY_PORT
export WEBSSH_ORIGIN_ALLOW WEBSSH_PORT WEBSSH_MAX_PER_IP WEBSSH_MAX_SESSION_MS

# --------------------------------------------------------------------------- #
# Preflight — DNS resolves to this host                                       #
# --------------------------------------------------------------------------- #

# Look up the host's public IP and the domain's A record. If they disagree,
# Let's Encrypt will fail later — much better to bail here with a plain-English
# message than to leave a half-installed system.
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
if [[ -z "$PUBLIC_IP" ]]; then
  # Fall back to a second provider so we don't hard-fail on ipify being down.
  PUBLIC_IP="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
fi

if [[ -n "$PUBLIC_IP" ]]; then
  DOMAIN_IPS="$(dig +short A "$TORII_DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ')"
  if [[ -z "$DOMAIN_IPS" ]]; then
    warn "DNS: no A record found for ${TORII_DOMAIN} — Let's Encrypt will fail"
    warn "  create an A record pointing ${TORII_DOMAIN} at ${PUBLIC_IP} and re-run"
    if [[ "$SKIP_CERTBOT" != "1" ]]; then
      die "DNS not configured (set SKIP_CERTBOT=1 to install without HTTPS)"
    fi
  elif ! echo " $DOMAIN_IPS " | grep -q " $PUBLIC_IP "; then
    warn "DNS: ${TORII_DOMAIN} resolves to [${DOMAIN_IPS% }] but this VPS is ${PUBLIC_IP}"
    if [[ "$SKIP_CERTBOT" != "1" ]]; then
      die "DNS points elsewhere — fix the A record or set SKIP_CERTBOT=1"
    fi
  else
    log "DNS: ${TORII_DOMAIN} → ${PUBLIC_IP} ✓"
  fi
else
  warn "could not determine this VPS's public IP — skipping DNS preflight"
fi

# --------------------------------------------------------------------------- #
# Banner                                                                      #
# --------------------------------------------------------------------------- #

cat <<BANNER
=============================================================
  torii-suite bootstrap  v${SUITE_VERSION}
  Domain:            ${TORII_DOMAIN}
  Work dir:          ${SUITE_WORK_DIR}
  Continuum:         $( [[ "$INSTALL_CONTINUUM" == "1" ]] && echo "install (agent :${CONTINUUM_AGENT_PORT})" || echo "SKIP" )
  Ollama:            $( [[ "$INSTALL_OLLAMA"    == "1" ]] && echo "install (${OLLAMA_MODELS} on ${OLLAMA_BIND})" || echo "SKIP" )
  Quest:             $( [[ "$INSTALL_QUEST"     == "1" ]] && echo "install" || echo "SKIP" )
  Plebeian tile:     $( [[ "$INSTALL_PLEBEIAN"  == "1" ]] && echo "register (${PLEBEIAN_EXTERNAL_URL})" || echo "SKIP" )
  Onboarding brdgs:  $( [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]] && echo "install (cors :${CORS_PROXY_PORT}, webssh :${WEBSSH_PORT})" || echo "SKIP" )
  Let's Encrypt:     $( [[ "$SKIP_CERTBOT" == "1" ]] && echo "SKIP" || echo "enabled (${LETSENCRYPT_EMAIL})" )
=============================================================
BANNER

# Confirm — but only if we have a tty AND the operator didn't already answer
# our interactive prompts (i.e. .env was there and no prompt phase happened).
if [[ -e /dev/tty && "${SUITE_ASSUME_YES:-0}" != "1" ]]; then
  printf "Continue? [y/N] " > /dev/tty
  read -r reply < /dev/tty
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by operator"
fi

mkdir -p "$SUITE_WORK_DIR"

# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #

clone_or_pull() {
  local url="$1" ref="$2" dest="$3"
  if [[ -d "${dest}/.git" ]]; then
    log "updating $(basename "$dest") to ${ref}"
    git -C "$dest" fetch --tags --prune origin
    git -C "$dest" checkout "$ref"
    git -C "$dest" pull --ff-only origin "$ref" 2>/dev/null || true
  else
    log "cloning $(basename "$dest") @ ${ref}"
    git clone --branch "$ref" "$url" "$dest" 2>/dev/null \
      || git clone "$url" "$dest"
    git -C "$dest" checkout "$ref"
  fi
}

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
# STAGE 2b — Ollama (local LLM fallback for Continuum)                        #
# --------------------------------------------------------------------------- #

if [[ "$INSTALL_OLLAMA" == "1" ]]; then
  step "STAGE 2b — install Ollama (local LLM fallback)"
  "${SCRIPT_DIR}/installers/install-ollama.sh"
else
  log "STAGE 2b skipped (INSTALL_OLLAMA=0)"
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
# STAGE 5 — Onboarding bridges (CORS proxy + WebSSH)                          #
# --------------------------------------------------------------------------- #

if [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]; then
  step "STAGE 5 — install onboarding bridges (cors-proxy + webssh)"
  "${SCRIPT_DIR}/installers/install-bridges.sh"
else
  log "STAGE 5 skipped (INSTALL_ONBOARDING_BRIDGES=0)"
fi

# --------------------------------------------------------------------------- #
# STAGE 6 — doctor                                                            #
# --------------------------------------------------------------------------- #

step "STAGE 6 — doctor"

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
$( [[ "$INSTALL_CONTINUUM" == "1" ]]           && echo "  Continuum:   https://${TORII_DOMAIN}/continuum/" )
$( [[ "$INSTALL_QUEST" == "1" ]]               && echo "  Quest:       https://${TORII_DOMAIN}/quest/" )
$( [[ "$INSTALL_PLEBEIAN" == "1" ]]            && echo "  Plebeian:    ${PLEBEIAN_EXTERNAL_URL}" )
$( [[ "$INSTALL_OLLAMA" == "1" ]]              && echo "  Ollama:      http://${OLLAMA_BIND} (loopback only)" )
$( [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]  && echo "  CORS proxy:  https://${TORII_DOMAIN}/cors-proxy/<upstream-host>/<path>" )
$( [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]  && echo "  WebSSH:      wss://${TORII_DOMAIN}/webssh" )

  Admin npub:  ${CONTINUUM_ADMIN_NPUB:-<not set>}

  Next steps:
    1. Open https://${TORII_DOMAIN}/continuum/ in a browser with a NIP-07
       signer (Plebeian Signer, nos2x). Sign in — the agent will only accept
       the admin npub above.
    2. Top up your Cashu wallet from the signer so Continuum's Routstr calls
       can pay per-request. See docs/CONTINUUM.md for the walkthrough.
$( [[ "$INSTALL_OLLAMA" == "1" ]] && cat <<OLLAMA_NEXT
    3. Local Ollama is running on ${OLLAMA_BIND} as a fallback for when
       Routstr is unreachable. On a CPU-only VPS expect 1–5 tok/s from
       ${OLLAMA_MODELS} — usable, but not a daily driver. See
       docs/CONTINUUM.md for how to switch to a remote GPU host later.
OLLAMA_NEXT
)

  To update: re-run this script (or on the VPS: cd ${SCRIPT_DIR} && git pull && sudo ./bootstrap.sh).

  Ops guide:   docs/OPS.md
  Repo:        https://github.com/ChiefmonkeyArt/torii-suite
=============================================================
DONE
