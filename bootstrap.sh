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
#   B. From a manual checkout:
#
#      git clone https://github.com/ChiefmonkeyArt/torii-suite
#      cd torii-suite
#      cp .env.example .env && nano .env
#      sudo -E ./bootstrap.sh
#
# v0.3 UX:
#   - ASCII banner, coloured stage headers with progress meter (Stage 3/7)
#   - Quiet by default — every stage's stdout goes to /var/log/torii-suite/
#     install-<ts>.log; the terminal shows a spinner + ✓ + elapsed time
#   - Live Ollama tok/s benchmark after install, shown in the final summary
#   - Set SUITE_QUIET=0 to stream everything to terminal (debug mode)
#
# Environment: see .env.example for the full contract.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Root check (comes before self-hoist, before anything)                       #
# --------------------------------------------------------------------------- #

if [[ $EUID -ne 0 ]]; then
  printf "\033[31mxx\033[0m bootstrap must run as root (try: sudo bash bootstrap.sh, or pipe: curl ... | sudo bash)\n" >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# Self-hoist: if we're being piped in (curl | sudo bash) then $0 is a bash    #
# child with no on-disk script. Clone the repo and re-exec the copy on disk.  #
# --------------------------------------------------------------------------- #

SUITE_REPO_URL="${SUITE_REPO_URL:-https://github.com/ChiefmonkeyArt/torii-suite.git}"
SUITE_CLONE_REF="${SUITE_CLONE_REF:-main}"
SUITE_INSTALL_DIR="${SUITE_INSTALL_DIR:-/opt/torii-suite/checkout}"

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
  printf "\033[36m==>\033[0m one-liner mode — cloning torii-suite into %s\n" "$SUITE_INSTALL_DIR"
  if ! command -v git >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates
  fi
  mkdir -p "$(dirname "$SUITE_INSTALL_DIR")"
  if [[ -d "${SUITE_INSTALL_DIR}/.git" ]]; then
    git -C "$SUITE_INSTALL_DIR" fetch --tags --prune origin
    git -C "$SUITE_INSTALL_DIR" checkout "$SUITE_CLONE_REF"
    git -C "$SUITE_INSTALL_DIR" pull --ff-only origin "$SUITE_CLONE_REF" 2>/dev/null || true
  else
    git clone --branch "$SUITE_CLONE_REF" "$SUITE_REPO_URL" "$SUITE_INSTALL_DIR" 2>/dev/null \
      || git clone "$SUITE_REPO_URL" "$SUITE_INSTALL_DIR"
    git -C "$SUITE_INSTALL_DIR" checkout "$SUITE_CLONE_REF"
  fi
  export SUITE_HOISTED=1
  exec "${SUITE_INSTALL_DIR}/bootstrap.sh" "$@"
fi

# --------------------------------------------------------------------------- #
# Constants + UX library                                                      #
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"

# shellcheck source=lib/ui.sh
. "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/run.sh
. "${SCRIPT_DIR}/lib/run.sh"

# --------------------------------------------------------------------------- #
# Banner                                                                      #
# --------------------------------------------------------------------------- #

ui_banner "v${SUITE_VERSION}"

# Stage counter — we compute the total number of stages after preflight so the
# progress meter shows an accurate denominator.
_STAGES_TOTAL=0
_STAGES_DONE=0
stage_header() {
  _STAGES_DONE=$(( _STAGES_DONE + 1 ))
  ui_stage "$_STAGES_DONE" "$_STAGES_TOTAL" "$*"
}

# --------------------------------------------------------------------------- #
# Preflight                                                                   #
# --------------------------------------------------------------------------- #

ui_section "Preflight"

# 1. Ubuntu version. Accept 22.04, 24.04, 26.04. Others get a warning.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    case "${VERSION_ID:-}" in
      22.04|24.04|26.04) ui_ok "Ubuntu ${VERSION_ID}" ;;
      *) ui_warn "Ubuntu ${VERSION_ID} — untested but proceeding" ;;
    esac
  else
    ui_warn "OS: ${PRETTY_NAME:-unknown} — Torii officially targets Ubuntu 22.04/24.04/26.04"
  fi
else
  ui_warn "cannot detect OS (no /etc/os-release) — proceeding anyway"
fi

# 2. Ports 80 + 443.
for port in 80 443; do
  if ss -H -tln "sport = :${port}" | grep -q .; then
    if ss -H -tlnp "sport = :${port}" 2>/dev/null | grep -q '"nginx"'; then
      ui_ok "port ${port} (already bound by nginx from a previous run)"
    else
      ui_fail "port ${port} in use by something other than nginx"
      ui_step "run:  ss -tlnp 'sport = :${port}'  to see what's holding it"
      ui_die "port ${port} must be free before install"
    fi
  else
    ui_ok "port ${port} free"
  fi
done

# 3. Install missing tools quietly.
_missing=()
for tool in curl dig git; do
  command -v "$tool" >/dev/null 2>&1 || _missing+=("$tool")
done
if [[ ${#_missing[@]} -gt 0 ]]; then
  # Map tool→package.
  _pkgs=()
  for t in "${_missing[@]}"; do
    case "$t" in
      dig) _pkgs+=("dnsutils") ;;
      *)   _pkgs+=("$t") ;;
    esac
  done
  run_stage "install prerequisites (${_missing[*]})" \
    bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${_pkgs[*]}"
fi

# --------------------------------------------------------------------------- #
# Setup — env + interactive prompts                                           #
# --------------------------------------------------------------------------- #

ui_section "Setup"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  ui_ok "using existing .env at ${SCRIPT_DIR}/.env"
  # shellcheck disable=SC1091
  set -a; source "${SCRIPT_DIR}/.env"; set +a
elif [[ -e /dev/tty ]]; then
  ui_box_top
  ui_box_line "${UI_BOLD}Torii needs three things to get started${UI_RESET}"
  ui_box_rule
  ui_box_line "1. ${UI_CYAN}Domain${UI_RESET} pointing at this VPS's public IP"
  ui_box_line "   ${UI_DIM}(one A record — e.g. torii.example.com)${UI_RESET}"
  ui_box_line "2. ${UI_CYAN}Email${UI_RESET} for Let's Encrypt (HTTPS certs)"
  ui_box_line "   ${UI_DIM}used only for cert-expiry warnings${UI_RESET}"
  ui_box_line "3. Your ${UI_CYAN}Nostr npub${UI_RESET} (from a NIP-07 signer)"
  ui_box_line "   ${UI_DIM}Continuum admin login. NEVER an nsec.${UI_RESET}"
  ui_box_rule
  ui_box_line "${UI_DIM}Optional: point the LLM fallback at a remote Ollama box${UI_RESET}"
  ui_box_line "${UI_DIM}instead of installing one here.${UI_RESET}"
  ui_box_bottom
  printf "\n"

  ui_ask "Domain (e.g. torii.example.com)" TORII_DOMAIN
  [[ -n "$TORII_DOMAIN" ]] || ui_die "domain is required"

  ui_ask "Email for Let's Encrypt" LETSENCRYPT_EMAIL
  [[ "$LETSENCRYPT_EMAIL" == *@*.* ]] || ui_die "email doesn't look like an email"

  ui_ask "Your admin npub (starts with npub1)" CONTINUUM_ADMIN_NPUB
  [[ "$CONTINUUM_ADMIN_NPUB" == npub1* ]] \
    || ui_die "CONTINUUM_ADMIN_NPUB must be a bech32 npub (starts with npub1)"

  # Optional 4th question: local Ollama vs. remote endpoint.
  # Default is "local" — press Enter to keep the old behaviour.
  OLLAMA_MODE="${OLLAMA_MODE:-}"
  ui_ask "Ollama LLM fallback: [local] install here, or [remote] use existing?" OLLAMA_MODE
  OLLAMA_MODE="${OLLAMA_MODE:-local}"
  OLLAMA_MODE="${OLLAMA_MODE,,}"  # lowercase
  case "$OLLAMA_MODE" in
    local|remote) ;;
    "") OLLAMA_MODE="local" ;;
    *) ui_die "OLLAMA_MODE must be 'local' or 'remote' (got: ${OLLAMA_MODE})" ;;
  esac

  OLLAMA_URL=""
  OLLAMA_AUTH_HEADER=""
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    ui_ask "Remote Ollama URL (e.g. http://10.0.0.5:11434 or https://ollama.example.com)" OLLAMA_URL
    [[ "$OLLAMA_URL" =~ ^https?://.+ ]] \
      || ui_die "OLLAMA_URL must start with http:// or https://"
    # Optional auth header — leave blank for LAN/Tailscale endpoints.
    ui_ask "Auth header for remote endpoint (or blank if none, e.g. 'Authorization: Bearer sk-...')" OLLAMA_AUTH_HEADER
  fi

  ui_ok "writing answers to ${SCRIPT_DIR}/.env (mode 0600)"
  umask 077
  cat > "${SCRIPT_DIR}/.env" <<EOF
# Written by bootstrap.sh interactive setup on $(date -u +%Y-%m-%dT%H:%M:%SZ)
TORII_DOMAIN="${TORII_DOMAIN}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB}"
OLLAMA_MODE="${OLLAMA_MODE}"
OLLAMA_URL="${OLLAMA_URL}"
OLLAMA_AUTH_HEADER="${OLLAMA_AUTH_HEADER}"
EOF
  umask 022
else
  ui_die "no .env and no interactive terminal — set TORII_DOMAIN, LETSENCRYPT_EMAIL, CONTINUUM_ADMIN_NPUB and try again"
fi

# --- required env ---
: "${TORII_DOMAIN:?set TORII_DOMAIN=<yourdomain> (see .env.example)}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL=<you@example.com>}"

# --- opt-in flags ---
INSTALL_CONTINUUM="${INSTALL_CONTINUUM:-1}"
INSTALL_QUEST="${INSTALL_QUEST:-1}"
INSTALL_OLLAMA="${INSTALL_OLLAMA:-1}"
INSTALL_PLEBEIAN="${INSTALL_PLEBEIAN:-1}"
INSTALL_ONBOARDING_BRIDGES="${INSTALL_ONBOARDING_BRIDGES:-0}"

if [[ "$INSTALL_OLLAMA" == "1" && "$INSTALL_CONTINUUM" != "1" ]]; then
  ui_warn "INSTALL_OLLAMA=1 but INSTALL_CONTINUUM=0 — Ollama has no consumer, disabling"
  INSTALL_OLLAMA=0
fi

if [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]; then
  : "${CORS_PROXY_ORIGIN_ALLOW:?set CORS_PROXY_ORIGIN_ALLOW=... (or INSTALL_ONBOARDING_BRIDGES=0)}"
  : "${WEBSSH_ORIGIN_ALLOW:?set WEBSSH_ORIGIN_ALLOW=... (or INSTALL_ONBOARDING_BRIDGES=0)}"
fi

if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  : "${CONTINUUM_ADMIN_NPUB:?set CONTINUUM_ADMIN_NPUB=npub1... (or INSTALL_CONTINUUM=0 to skip)}"
  [[ "$CONTINUUM_ADMIN_NPUB" == npub1* ]] \
    || ui_die "CONTINUUM_ADMIN_NPUB must be a bech32 npub (starts with npub1)"
fi

# --- overrides + defaults ---
SUITE_WORK_DIR="${SUITE_WORK_DIR:-/opt/torii-suite/work}"
TORII_BASE_REF="${TORII_BASE_REF:-main}"
TORII_CONTINUUM_REF="${TORII_CONTINUUM_REF:-main}"
TORII_QUEST_REF="${TORII_QUEST_REF:-main}"
CONTINUUM_AGENT_PORT="${CONTINUUM_AGENT_PORT:-8787}"
PLEBEIAN_EXTERNAL_URL="${PLEBEIAN_EXTERNAL_URL:-https://plebeian.market}"
SKIP_CERTBOT="${SKIP_CERTBOT:-0}"
OLLAMA_MODE="${OLLAMA_MODE:-local}"
OLLAMA_MODE="${OLLAMA_MODE,,}"
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1:11434}"
OLLAMA_MODELS="${OLLAMA_MODELS:-llama3.2:3b}"
OLLAMA_URL="${OLLAMA_URL:-}"
OLLAMA_AUTH_HEADER="${OLLAMA_AUTH_HEADER:-}"

case "$OLLAMA_MODE" in
  local|remote) ;;
  *) ui_die "OLLAMA_MODE must be 'local' or 'remote' (got: ${OLLAMA_MODE})" ;;
esac

if [[ "$OLLAMA_MODE" == "remote" && "$INSTALL_OLLAMA" == "1" ]]; then
  [[ -n "$OLLAMA_URL" ]] || ui_die "OLLAMA_MODE=remote requires OLLAMA_URL to be set"
  [[ "$OLLAMA_URL" =~ ^https?://.+ ]] \
    || ui_die "OLLAMA_URL must start with http:// or https://"
fi

# Resolve the endpoint the benchmark + Continuum will actually hit. In local
# mode this is http://<bind>; in remote mode it's OLLAMA_URL as-is (no trailing
# slash to keep string concatenation clean).
if [[ "$OLLAMA_MODE" == "remote" ]]; then
  OLLAMA_ENDPOINT="${OLLAMA_URL%/}"
else
  OLLAMA_ENDPOINT="http://${OLLAMA_BIND}"
fi
CORS_PROXY_UPSTREAM_ALLOW="${CORS_PROXY_UPSTREAM_ALLOW:-blesta.sovereignhybridcompute.com}"
CORS_PROXY_PORT="${CORS_PROXY_PORT:-8801}"
WEBSSH_PORT="${WEBSSH_PORT:-8802}"
WEBSSH_MAX_PER_IP="${WEBSSH_MAX_PER_IP:-3}"
WEBSSH_MAX_SESSION_MS="${WEBSSH_MAX_SESSION_MS:-900000}"

export TORII_DOMAIN LETSENCRYPT_EMAIL SKIP_CERTBOT
export CONTINUUM_ADMIN_NPUB CONTINUUM_AGENT_PORT
export INSTALL_OLLAMA OLLAMA_MODE OLLAMA_BIND OLLAMA_MODELS OLLAMA_URL OLLAMA_AUTH_HEADER OLLAMA_ENDPOINT
export SUITE_WORK_DIR
export CORS_PROXY_ORIGIN_ALLOW CORS_PROXY_UPSTREAM_ALLOW CORS_PROXY_PORT
export WEBSSH_ORIGIN_ALLOW WEBSSH_PORT WEBSSH_MAX_PER_IP WEBSSH_MAX_SESSION_MS

# --------------------------------------------------------------------------- #
# DNS preflight (has to come after we know TORII_DOMAIN)                      #
# --------------------------------------------------------------------------- #

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
fi

if [[ -n "$PUBLIC_IP" ]]; then
  DOMAIN_IPS="$(dig +short A "$TORII_DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ')"
  if [[ -z "$DOMAIN_IPS" ]]; then
    ui_warn "DNS: no A record found for ${TORII_DOMAIN} — Let's Encrypt will fail"
    [[ "$SKIP_CERTBOT" == "1" ]] || ui_die "DNS not configured (set SKIP_CERTBOT=1 to install without HTTPS)"
  elif ! echo " $DOMAIN_IPS " | grep -q " $PUBLIC_IP "; then
    ui_warn "DNS: ${TORII_DOMAIN} → [${DOMAIN_IPS% }], but this VPS is ${PUBLIC_IP}"
    [[ "$SKIP_CERTBOT" == "1" ]] || ui_die "DNS points elsewhere — fix the A record or set SKIP_CERTBOT=1"
  else
    ui_ok "DNS: ${TORII_DOMAIN} → ${PUBLIC_IP}"
  fi
else
  ui_warn "could not determine this VPS's public IP — skipping DNS preflight"
fi

# --------------------------------------------------------------------------- #
# Remote Ollama preflight (only when OLLAMA_MODE=remote)                      #
# --------------------------------------------------------------------------- #
#
# Probe /api/tags on the remote endpoint before running any stages. Better to
# fail here in 5 seconds than after installing torii-base + Continuum.
#
if [[ "$INSTALL_OLLAMA" == "1" && "$OLLAMA_MODE" == "remote" ]]; then
  # Warn on plaintext http:// to a non-loopback / non-RFC1918 host.
  # Extract the host portion between :// and (: or / or end).
  _ollama_host="${OLLAMA_URL#*://}"
  _ollama_host="${_ollama_host%%[/?#]*}"
  _ollama_host="${_ollama_host%%:*}"
  if [[ "$OLLAMA_URL" == http://* ]]; then
    case "$_ollama_host" in
      127.*|localhost|::1)                                 ;;  # loopback
      10.*|192.168.*)                                      ;;  # RFC1918
      172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)              ;;  # RFC1918 172.16/12
      100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) ;;  # CGNAT / Tailscale 100.64/10
      *.ts.net|*.tail*.net)                                ;;  # Tailscale MagicDNS
      *.internal|*.lan|*.local|*.home)                     ;;  # common LAN suffixes
      *)
        ui_warn "OLLAMA_URL uses plain http:// to a public-looking host (${_ollama_host}) — inference traffic will be in the clear. Prefer https:// or a private-network address."
        ;;
    esac
  fi

  ui_step "probing remote Ollama at ${OLLAMA_URL} ..."
  _probe_args=(-fsS -m 5 "${OLLAMA_ENDPOINT}/api/tags")
  [[ -n "$OLLAMA_AUTH_HEADER" ]] && _probe_args+=(-H "$OLLAMA_AUTH_HEADER")
  if _probe_out="$(curl "${_probe_args[@]}" 2>>"$SUITE_LOG_FILE")"; then
    if printf "%s" "$_probe_out" | grep -qE '"models"[[:space:]]*:'; then
      _model_count="$(printf "%s" "$_probe_out" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | wc -l | tr -d ' ')"
      ui_ok "remote Ollama reachable — ${_model_count} model(s) available"
    else
      ui_warn "remote Ollama responded but /api/tags didn't return a models array (see log)"
    fi
  else
    ui_die "remote Ollama at ${OLLAMA_URL} did not respond — fix OLLAMA_URL / OLLAMA_AUTH_HEADER or switch to OLLAMA_MODE=local"
  fi
  unset _probe_args _probe_out _model_count _ollama_host
fi

# --------------------------------------------------------------------------- #
# Plan summary                                                                #
# --------------------------------------------------------------------------- #

# Compute stage count for the progress meter. Remote mode skips the install
# stage entirely (there's nothing to install), so it doesn't count.
_STAGES_TOTAL=1  # base
[[ "$INSTALL_CONTINUUM"          == "1" ]] && _STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))
[[ "$INSTALL_OLLAMA"             == "1" && "$OLLAMA_MODE" == "local" ]] && _STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))
[[ "$INSTALL_QUEST"              == "1" ]] && _STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))
[[ "$INSTALL_PLEBEIAN"           == "1" ]] && _STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))
[[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]] && _STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))
_STAGES_TOTAL=$(( _STAGES_TOTAL + 1 ))  # doctor

# Build plan rows via string concatenation — avoids putting user-supplied
# values (email, port, model list) into printf format strings.
_plan_row() {
  local flag="$1" active_text="$2" skip_text="${3:-skip}"
  if [[ "$flag" == "1" ]]; then
    echo "${UI_GREEN}${active_text}${UI_RESET}"
  else
    echo "${UI_DIM}${skip_text}${UI_RESET}"
  fi
}

ui_box_top
ui_box_line "${UI_BOLD}Install plan${UI_RESET}  ${UI_DIM}v${SUITE_VERSION}${UI_RESET}"
ui_box_rule
ui_box_line "Domain      ${UI_CYAN}${TORII_DOMAIN}${UI_RESET}"
ui_box_line "Continuum   $(_plan_row "$INSTALL_CONTINUUM" "install ${UI_DIM}(agent :${CONTINUUM_AGENT_PORT})${UI_RESET}")"
if [[ "$INSTALL_OLLAMA" == "1" && "$OLLAMA_MODE" == "remote" ]]; then
  ui_box_line "Ollama      ${UI_GREEN}remote${UI_RESET} ${UI_DIM}(${OLLAMA_URL})${UI_RESET}"
else
  ui_box_line "Ollama      $(_plan_row "$INSTALL_OLLAMA" "install ${UI_DIM}(${OLLAMA_MODELS})${UI_RESET}")"
fi
ui_box_line "Quest       $(_plan_row "$INSTALL_QUEST" "install")"
ui_box_line "Plebeian    $(_plan_row "$INSTALL_PLEBEIAN" "tile")"
ui_box_line "Bridges     $(_plan_row "$INSTALL_ONBOARDING_BRIDGES" "install")"
if [[ "$SKIP_CERTBOT" == "1" ]]; then
  ui_box_line "HTTPS       ${UI_YELLOW}skip${UI_RESET}"
else
  ui_box_line "HTTPS       ${UI_GREEN}Let's Encrypt${UI_RESET} ${UI_DIM}(${LETSENCRYPT_EMAIL})${UI_RESET}"
fi
ui_box_rule
ui_box_line "Logs        ${UI_DIM}${SUITE_LOG_FILE}${UI_RESET}"
ui_box_bottom

# Confirm — skip if piped (no /dev/tty) or SUITE_ASSUME_YES=1.
if [[ -e /dev/tty && "${SUITE_ASSUME_YES:-0}" != "1" ]]; then
  ui_confirm "Continue?" || ui_die "aborted by operator"
fi

mkdir -p "$SUITE_WORK_DIR"

# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #

clone_or_pull() {
  local url="$1" ref="$2" dest="$3"
  if [[ -d "${dest}/.git" ]]; then
    git -C "$dest" fetch --tags --prune origin
    git -C "$dest" checkout "$ref"
    git -C "$dest" pull --ff-only origin "$ref" 2>/dev/null || true
  else
    git clone --branch "$ref" "$url" "$dest" 2>/dev/null || git clone "$url" "$dest"
    git -C "$dest" checkout "$ref"
  fi
}

torii_cli() {
  local torii_bin="/usr/local/bin/torii"
  [[ -x "$torii_bin" ]] || ui_die "torii CLI not found at ${torii_bin} (base bootstrap failed?)"
  "$torii_bin" "$@"
}

# Wrapper functions so each stage can be one shell command that run_stage runs.
_stage_base() {
  local src="${SUITE_WORK_DIR}/torii-base"
  clone_or_pull "https://github.com/ChiefmonkeyArt/torii-base.git" "$TORII_BASE_REF" "$src"
  (
    cd "$src"
    TORII_DOMAIN="$TORII_DOMAIN" \
    LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" \
    SKIP_CERTBOT="$SKIP_CERTBOT" \
      ./bootstrap.sh
  )
}
_stage_continuum()      { "${SCRIPT_DIR}/installers/install-continuum.sh"; }
_stage_ollama()         { "${SCRIPT_DIR}/installers/install-ollama.sh"; }
_stage_quest()          { "${SCRIPT_DIR}/installers/install-quest.sh"; }
_stage_plebeian()       { "${SCRIPT_DIR}/installers/register-plebeian.sh"; }
_stage_bridges()        { "${SCRIPT_DIR}/installers/install-bridges.sh"; }

# Doctor is a status readout — never fatal.
_stage_doctor() {
  torii_cli status || true
  echo
  torii_cli doctor || true
}

# --------------------------------------------------------------------------- #
# Stages                                                                      #
# --------------------------------------------------------------------------- #

stage_header "torii-base (host layer)"
run_stage "install torii-base" _stage_base

if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  stage_header "Continuum (frontend + agent)"
  run_stage "install Continuum" _stage_continuum
fi

OLLAMA_BENCH=""
if [[ "$INSTALL_OLLAMA" == "1" ]]; then
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    ui_section "Ollama (remote endpoint)"
    ui_ok "using existing endpoint at ${OLLAMA_URL} — nothing to install"
  else
    stage_header "Ollama (local LLM fallback)"
    run_stage "install Ollama + pull ${OLLAMA_MODELS}" _stage_ollama
  fi

  # Live benchmark — measure actual tok/s for whichever endpoint we're going
  # to use. Costs ~15s, gives the operator a real number instead of guessing.
  # For local mode we use the first shipped model; for remote we ask the
  # endpoint for its first available model.
  ui_step "measuring Ollama throughput..."
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    _tags_args=(-fsS -m 5 "${OLLAMA_ENDPOINT}/api/tags")
    [[ -n "$OLLAMA_AUTH_HEADER" ]] && _tags_args+=(-H "$OLLAMA_AUTH_HEADER")
    _tags_json="$(curl "${_tags_args[@]}" 2>>"$SUITE_LOG_FILE" || echo "")"
    _bench_model="$(printf "%s" "$_tags_json" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/^"name"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/')"
    if [[ -z "$_bench_model" ]]; then
      ui_warn "Ollama benchmark: remote endpoint has no models pulled yet — skipping"
      _bench_model=""
    fi
    unset _tags_args _tags_json
  else
    _bench_model="${OLLAMA_MODELS%% *}"
  fi

  if [[ -n "$_bench_model" ]]; then
    # Ask for exactly 32 tokens of output; measure eval_count / eval_duration.
    # eval_duration is in nanoseconds.
    _bench_args=(-fsS -m 120 "${OLLAMA_ENDPOINT}/api/generate" -H 'Content-Type: application/json')
    [[ -n "$OLLAMA_AUTH_HEADER" ]] && _bench_args+=(-H "$OLLAMA_AUTH_HEADER")
    _bench_args+=(-d "$(printf '{"model":"%s","prompt":"Say the word hello.","stream":false,"options":{"num_predict":32}}' "$_bench_model")")
    _bench_json="$(curl "${_bench_args[@]}" 2>>"$SUITE_LOG_FILE" || echo "")"
    if [[ -n "$_bench_json" ]]; then
      _eval_count=$(printf "%s" "$_bench_json" | grep -oE '"eval_count":[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
      _eval_dur=$(printf "%s"   "$_bench_json" | grep -oE '"eval_duration":[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
      if [[ -n "$_eval_count" && -n "$_eval_dur" && "$_eval_dur" -gt 0 ]]; then
        # tok/s = eval_count / (eval_duration / 1e9); use integer math × 100 for one decimal.
        _tps_x100=$(( _eval_count * 100000000000 / _eval_dur ))
        _tps_int=$(( _tps_x100 / 100 ))
        _tps_frac=$(( _tps_x100 % 100 ))
        OLLAMA_BENCH="$(printf "%d.%02d tok/s (%s)" "$_tps_int" "$_tps_frac" "$_bench_model")"
        ui_ok "Ollama benchmark: ${OLLAMA_BENCH}"
      else
        ui_warn "Ollama benchmark: could not parse response (see log)"
      fi
    else
      ui_warn "Ollama benchmark: request failed (see log)"
    fi
    unset _bench_args _bench_json _eval_count _eval_dur _tps_x100 _tps_int _tps_frac
  fi
fi

if [[ "$INSTALL_QUEST" == "1" ]]; then
  stage_header "Torii Quest (3D world)"
  run_stage "install Quest" _stage_quest
fi

if [[ "$INSTALL_PLEBEIAN" == "1" ]]; then
  stage_header "Plebeian tile"
  run_stage "register Plebeian" _stage_plebeian
fi

if [[ "$INSTALL_ONBOARDING_BRIDGES" == "1" ]]; then
  stage_header "Onboarding bridges"
  run_stage "install bridges (cors-proxy + webssh)" _stage_bridges
fi

stage_header "Doctor"
run_stage "torii status + doctor" _stage_doctor

# --------------------------------------------------------------------------- #
# Summary card                                                                #
# --------------------------------------------------------------------------- #

ui_section "Done"

ui_box_top
ui_box_line "${UI_BOLD}${UI_GREEN}${UI_CHECK} Torii Suite is live${UI_RESET}  ${UI_DIM}v${SUITE_VERSION}${UI_RESET}"
ui_box_rule
ui_box_line "Launcher     ${UI_CYAN}https://${TORII_DOMAIN}/${UI_RESET}"
[[ "$INSTALL_CONTINUUM" == "1" ]] && ui_box_line "Continuum    ${UI_CYAN}https://${TORII_DOMAIN}/continuum/${UI_RESET}"
[[ "$INSTALL_QUEST" == "1" ]]     && ui_box_line "Quest        ${UI_CYAN}https://${TORII_DOMAIN}/quest/${UI_RESET}"
[[ "$INSTALL_PLEBEIAN" == "1" ]]  && ui_box_line "Plebeian     ${UI_DIM}${PLEBEIAN_EXTERNAL_URL}${UI_RESET}"
if [[ "$INSTALL_OLLAMA" == "1" ]]; then
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    ui_box_line "Ollama       ${UI_DIM}remote: ${OLLAMA_URL}${UI_RESET}"
  else
    ui_box_line "Ollama       ${UI_DIM}${OLLAMA_BIND} (loopback)${UI_RESET}"
  fi
  [[ -n "$OLLAMA_BENCH" ]] && ui_box_line "  ${UI_ARROW} measured  ${UI_PINK}${OLLAMA_BENCH}${UI_RESET}"
fi
ui_box_rule
ui_box_line "Admin npub   ${UI_DIM}${CONTINUUM_ADMIN_NPUB:-<not set>}${UI_RESET}"
ui_box_rule
ui_box_line "${UI_BOLD}Next steps${UI_RESET}"
ui_box_line "1. Open ${UI_CYAN}https://${TORII_DOMAIN}/continuum/${UI_RESET}"
ui_box_line "   sign in with your NIP-07 signer"
ui_box_line "2. Top up your Cashu wallet from the signer"
ui_box_line "   so Continuum can pay Routstr per request"
if [[ "$INSTALL_OLLAMA" == "1" ]]; then
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    ui_box_line "3. Continuum will fall back to your remote Ollama"
    ui_box_line "   when Routstr is unreachable or the wallet is empty"
  else
    ui_box_line "3. Local Ollama is running as a fallback when"
    ui_box_line "   Routstr is unreachable or the wallet is empty"
  fi
fi
ui_box_rule
ui_box_line "Logs         ${UI_DIM}${SUITE_LOG_FILE}${UI_RESET}"
ui_box_line "Repo         ${UI_DIM}github.com/ChiefmonkeyArt/torii-suite${UI_RESET}"
ui_box_bottom

printf "\n"
