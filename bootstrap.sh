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
      22.04|24.04) ui_ok "Ubuntu ${VERSION_ID}" ;;
      26.04)
        ui_ok "Ubuntu ${VERSION_ID}"
        # Ollama's official installer has documented support for 22/24 only.
        # 26.04 has worked in testing but is untested at scale. Flag it here
        # so the operator has an audit trail if something Ollama-shaped fails
        # later. The escape hatch is INSTALL_OLLAMA=0 (or OLLAMA_MODE=remote).
        if [[ "${INSTALL_OLLAMA:-1}" == "1" && "${OLLAMA_MODE:-local}" == "local" ]]; then
          ui_info "Ubuntu 26.04 detected - local Ollama install is unofficial-but-should-work. If it fails, re-run with INSTALL_OLLAMA=0 or OLLAMA_MODE=remote."
        fi
        ;;
      *) ui_warn "Ubuntu ${VERSION_ID} - untested but proceeding" ;;
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
  ui_box_line "${UI_DIM}Ollama installs locally by default (sovereign LLM${UI_RESET}"
  ui_box_line "${UI_DIM}fallback). Set OLLAMA_MODE=remote in the env to${UI_RESET}"
  ui_box_line "${UI_DIM}point at an existing endpoint instead.${UI_RESET}"
  ui_box_bottom
  printf "\n"

  ui_ask "Domain (e.g. torii.example.com)" TORII_DOMAIN
  [[ -n "$TORII_DOMAIN" ]] || ui_die "domain is required"

  ui_ask "Email for Let's Encrypt" LETSENCRYPT_EMAIL
  [[ "$LETSENCRYPT_EMAIL" == *@*.* ]] || ui_die "email doesn't look like an email"

  # First-timer hint. If they don't have a signer yet, they can't produce
  # a valid npub — tell them where to get one before we ask for it.
  printf '\n  %b%b No NIP-07 signer yet? Any of these work:%b\n' "${UI_DIM}" "${UI_ARROW}" "${UI_RESET}"
  printf '  %b  • Plebeian Signer (Chrome/Firefox, recommended — built by us)%b\n' "${UI_DIM}" "${UI_RESET}"
  printf '  %b  • nos2x, Alby, Amber (Android)%b\n' "${UI_DIM}" "${UI_RESET}"
  printf '  %b    Chrome:  chromewebstore.google.com → search "Plebeian Signer"%b\n' "${UI_DIM}" "${UI_RESET}"
  printf '  %b    Firefox: addons.mozilla.org → search "Plebeian Signer"%b\n\n' "${UI_DIM}" "${UI_RESET}"

  ui_ask "Your admin npub (starts with npub1)" CONTINUUM_ADMIN_NPUB
  # Trim stray whitespace from paste artefacts.
  CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB## }"
  CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB%% }"
  [[ "$CONTINUUM_ADMIN_NPUB" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]] \
    || ui_die "CONTINUUM_ADMIN_NPUB must be a bech32 npub: 'npub1' + 58 lowercase chars from the bech32 alphabet"

  # Ollama LLM fallback: default to local install. It's the sovereign
  # choice - Continuum's LLM stays on this box, no third-party endpoint,
  # no key rotation, no upstream outage taking us down. Advanced operators
  # can flip to a remote endpoint by setting OLLAMA_MODE=remote (with
  # OLLAMA_URL + optional OLLAMA_AUTH_HEADER) in the environment before
  # running bootstrap, or by editing .env after this run and restarting.
  OLLAMA_MODE="${OLLAMA_MODE:-local}"
  OLLAMA_MODE="${OLLAMA_MODE,,}"
  case "$OLLAMA_MODE" in
    local|remote) ;;
    *) ui_die "OLLAMA_MODE must be 'local' or 'remote' (got: ${OLLAMA_MODE})" ;;
  esac

  OLLAMA_URL="${OLLAMA_URL:-}"
  OLLAMA_AUTH_HEADER="${OLLAMA_AUTH_HEADER:-}"
  if [[ "$OLLAMA_MODE" == "remote" ]]; then
    [[ "$OLLAMA_URL" =~ ^https?://.+ ]] \
      || ui_die "OLLAMA_MODE=remote requires OLLAMA_URL to be set in the environment (http:// or https:// endpoint)"
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
  # Trim paste-whitespace and validate the full bech32 shape (not just the
  # 'npub1' prefix). Matches the shape check enforced by set-admin-npub.sh.
  CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB## }"
  CONTINUUM_ADMIN_NPUB="${CONTINUUM_ADMIN_NPUB%% }"
  [[ "$CONTINUUM_ADMIN_NPUB" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]] \
    || ui_die "CONTINUUM_ADMIN_NPUB must be a bech32 npub: 'npub1' + 58 lowercase chars from the bech32 alphabet"
fi

# --- overrides + defaults ---
SUITE_WORK_DIR="${SUITE_WORK_DIR:-/opt/torii-suite/work}"
# torii-base v0.1.1 adds /etc/sudoers.d/torii-nginx so the sidecar (which
# runs as the unprivileged torii user) can `sudo -n nginx -t` and
# `sudo -n nginx -s reload`. Without this the [2/6] Continuum stage fails
# with 500 {"error":"nginx_reload_failed"} on the torii register call.
# Pinned by suite v0.6.3-alpha.
TORII_BASE_REF="${TORII_BASE_REF:-v0.1.1}"
# Continuum ships tagged releases; suite v0.6.0-alpha pins v0.2.14-alpha (auth
# rate-limit slice). Quest v0.2.367-alpha is the first tag carrying arena-ws,
# pinned by suite v0.6.1-alpha. v0.2.374-alpha restores the `/quest/` base on
# the pinned entry URL (Quest froze after ENTER ARENA without it), pinned by
# suite v0.7.1-alpha.
TORII_CONTINUUM_REF="${TORII_CONTINUUM_REF:-v0.2.14-alpha}"
TORII_QUEST_REF="${TORII_QUEST_REF:-v0.2.386-alpha}"
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
export CONTINUUM_ADMIN_NPUB CONTINUUM_AGENT_PORT CONTINUUM_SESSION_TTL_SEC
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

# Post-install auth smoke test. NEVER hard-fails the install — the agent may
# still be booting or nginx may still be reloading. Records the result into
# AUTH_SMOKE_RESULT for the summary card.
#
# Verifies (against http://127.0.0.1:${CONTINUUM_AGENT_PORT} — the loopback
# endpoint bypasses TLS entirely, so this works whether certbot ran or not):
#   1. GET /api/health returns 200
#   2. POST /api/auth/challenge returns { challenge: <48-char hex>, expires_in }
#   3. POST /api/auth/verify with a bogus event is rejected (ok=false)
AUTH_SMOKE_RESULT="skipped"
_stage_auth_smoke() {
  local base="http://127.0.0.1:${CONTINUUM_AGENT_PORT}"
  local tries=0 max_tries=6 backoff=2

  # 1. Health check, with backoff (systemd may still be warming up).
  while (( tries < max_tries )); do
    if curl -fsS -m 5 "${base}/api/health" >/dev/null 2>&1; then break; fi
    tries=$(( tries + 1 ))
    if (( tries >= max_tries )); then
      ui_warn "agent /api/health did not respond after ${max_tries} tries — skipping auth smoke"
      AUTH_SMOKE_RESULT="health-timeout"
      return 0
    fi
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
  done
  ui_ok "agent /api/health OK"

  # 2. Challenge endpoint.
  local ch_body
  ch_body="$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d '{}' "${base}/api/auth/challenge" 2>>"$SUITE_LOG_FILE" || echo '')"
  if [[ -z "$ch_body" ]]; then
    ui_warn "/api/auth/challenge did not respond"
    AUTH_SMOKE_RESULT="challenge-failed"
    return 0
  fi
  local challenge
  challenge="$(printf '%s' "$ch_body" | grep -oE '"challenge"[[:space:]]*:[[:space:]]*"[a-f0-9]+"' | head -1 | sed -E 's/.*"([a-f0-9]+)"$/\1/')"
  if [[ -z "$challenge" ]]; then
    ui_warn "/api/auth/challenge returned malformed body (see log)"
    printf '%s\n' "$ch_body" >> "$SUITE_LOG_FILE"
    AUTH_SMOKE_RESULT="challenge-malformed"
    return 0
  fi
  local ch_len=${#challenge}
  if (( ch_len < 32 )); then
    ui_warn "/api/auth/challenge returned suspiciously short challenge (${ch_len} chars)"
    AUTH_SMOKE_RESULT="challenge-short"
    return 0
  fi
  ui_ok "/api/auth/challenge issued ${ch_len}-char challenge"

  # 3. Verify with a bogus event — must be rejected. We build a well-formed
  # kind 22242 shape with an all-zero pubkey/id/sig; if the agent accepts
  # this, something is very wrong.
  local bogus
  bogus=$(printf '{"kind":22242,"pubkey":"%s","content":"%s","tags":[["challenge","%s"]],"created_at":%d,"id":"%s","sig":"%s"}' \
    "$(printf '0%.0s' {1..64})" "$challenge" "$challenge" "$(date +%s)" \
    "$(printf '0%.0s' {1..64})" "$(printf '0%.0s' {1..128})")
  local vf_body vf_http
  vf_http="$(curl -sS -m 5 -o /tmp/torii-suite-auth-vf.json -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"event\":${bogus}}" "${base}/api/auth/verify" 2>>"$SUITE_LOG_FILE" || echo '000')"
  vf_body="$(cat /tmp/torii-suite-auth-vf.json 2>/dev/null || echo '')"
  rm -f /tmp/torii-suite-auth-vf.json

  # We expect a 4xx OR a 200 with ok:false. What we do NOT want is 200 + ok:true.
  if [[ "$vf_http" == "200" ]] && printf '%s' "$vf_body" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
    ui_warn "SECURITY: /api/auth/verify accepted a bogus event — investigate immediately"
    printf '%s\n' "$vf_body" >> "$SUITE_LOG_FILE"
    AUTH_SMOKE_RESULT="SECURITY-FAIL"
    return 0
  fi
  ui_ok "/api/auth/verify correctly rejected a bogus event (HTTP ${vf_http})"

  AUTH_SMOKE_RESULT="ok"
  return 0
}

# --------------------------------------------------------------------------- #
# Stages                                                                      #
# --------------------------------------------------------------------------- #

stage_header "torii-base (host layer)"
run_stage "install torii-base" _stage_base

if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  stage_header "Continuum (frontend + agent)"
  ui_stage_banner continuum
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
  stage_header "Torii Quest (the federated metaverse)"
  ui_stage_banner quest
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

AUTH_SMOKE_RATE_RESULT="skipped"
_stage_auth_smoke_rate() {
  # Only run when the operator has rate-limiting turned on. If they've
  # disabled it explicitly, we mark 'skipped' on the summary card rather
  # than probing a limiter that isn't there.
  if [[ "${CONTINUUM_RATE_LIMIT_ENABLED:-1}" != "1" ]]; then
    AUTH_SMOKE_RATE_RESULT="skipped"
    ui_info "CONTINUUM_RATE_LIMIT_ENABLED=0 - not probing /api/auth/challenge limiter"
    return 0
  fi

  local base="http://127.0.0.1:${CONTINUUM_AGENT_PORT}"
  local max="${CONTINUUM_RATE_LIMIT_CHALLENGE_PER_MIN:-10}"
  local n=$(( max + 1 ))
  local last="000"
  local http

  # Fire N+1 challenges as fast as curl will go. Loopback bypasses TLS so
  # this is only bounded by process turnaround. Legitimate users get 10
  # sign-ins/min per IP - well above real usage - and we prove the (N+1)th
  # returns 429.
  for _ in $(seq 1 "$n"); do
    http="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' -d '{}' \
      "${base}/api/auth/challenge" 2>>"$SUITE_LOG_FILE" || echo '000')"
    last="$http"
  done

  if [[ "$last" == "429" ]]; then
    ui_ok "/api/auth/challenge returned 429 on request #${n} (limit=${max}/min)"
    AUTH_SMOKE_RATE_RESULT="ok"
  else
    ui_warn "expected 429 on request #${n}, got ${last} - limiter may not be enforced"
    AUTH_SMOKE_RATE_RESULT="not-enforced"
  fi
  return 0
}

# MP smoke test (v0.6.0-alpha, SUITE-VPS-READY-1). Opens a WebSocket to
# 127.0.0.1:${ARENA_WS_PORT} through the same loopback path the nginx /mp
# fragment proxies, and verifies the arena-ws process is speaking WebSocket
# rather than crashing on connect. Uses Node inline - already installed for
# the Continuum agent so no new dependency.
MP_SMOKE_RESULT="skipped"
_stage_mp_smoke() {
  if [[ "${INSTALL_QUEST:-1}" != "1" ]]; then
    MP_SMOKE_RESULT="skipped"
    return 0
  fi
  if [[ "${INSTALL_ARENA_WS:-1}" != "1" ]]; then
    MP_SMOKE_RESULT="skipped"
    ui_info "INSTALL_ARENA_WS=0 - not probing /mp WebSocket"
    return 0
  fi

  local port="${ARENA_WS_PORT:-8788}"
  local result
  # Node one-liner: try to open a WS to loopback and log the outcome.
  # Timeout is 5s. Success = any of: open event fires, or the server sends
  # a HELLO frame. Failure = timeout or connection refused.
  set +e
  result="$(sudo -u torii-quest -H NODE_PATH=/opt/torii-quest/mp/node_modules \
    node -e "
      const WebSocket = require('ws');
      const ws = new WebSocket('ws://127.0.0.1:${port}/mp');
      let done = false;
      const finish = (label) => { if (done) return; done = true; try { ws.terminate(); } catch(e){} console.log(label); process.exit(0); };
      ws.on('open', () => finish('ok'));
      ws.on('message', () => finish('ok'));
      ws.on('error', (e) => finish('error:' + (e && e.code || 'unknown')));
      setTimeout(() => finish('timeout'), 5000);
    " 2>>"$SUITE_LOG_FILE")"
  local rc=$?
  set -e

  case "$result" in
    ok)
      ui_ok "wss loopback probe to /mp connected (arena-ws is alive)"
      MP_SMOKE_RESULT="ok"
      ;;
    timeout)
      ui_warn "/mp WebSocket did not complete handshake within 5s"
      MP_SMOKE_RESULT="timeout"
      ;;
    error:*)
      ui_warn "/mp WebSocket probe failed (${result})"
      MP_SMOKE_RESULT="error"
      ;;
    *)
      ui_warn "/mp WebSocket probe returned unexpected result (rc=${rc}, result=${result})"
      MP_SMOKE_RESULT="error"
      ;;
  esac
  return 0
}

if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  stage_header "Auth smoke test"
  run_stage "verify Nostr login endpoints" _stage_auth_smoke
  # Only run the rate-limit probe if the base auth smoke actually got a
  # working agent. Firing N+1 requests at a health-timeout agent is useless.
  if [[ "$AUTH_SMOKE_RESULT" == "ok" ]]; then
    run_stage "verify /api/auth rate limit" _stage_auth_smoke_rate
  fi
fi

if [[ "$INSTALL_QUEST" == "1" && "${INSTALL_ARENA_WS:-1}" == "1" ]]; then
  stage_header "MP smoke test"
  run_stage "verify arena-ws /mp WebSocket" _stage_mp_smoke
fi

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
if [[ "$INSTALL_CONTINUUM" == "1" ]]; then
  case "$AUTH_SMOKE_RESULT" in
    ok)              ui_box_line "Nostr login  ${UI_GREEN}verified${UI_RESET}${UI_DIM}  (challenge issued, bogus event rejected)${UI_RESET}" ;;
    SECURITY-FAIL)   ui_box_line "Nostr login  ${UI_RED}SECURITY FAIL${UI_RESET}${UI_DIM}  agent accepted a bogus event - check ${SUITE_LOG_FILE}${UI_RESET}" ;;
    health-timeout)  ui_box_line "Nostr login  ${UI_YELLOW}unverified${UI_RESET}${UI_DIM}  agent /api/health not up yet - test manually${UI_RESET}" ;;
    challenge-*)     ui_box_line "Nostr login  ${UI_YELLOW}degraded${UI_RESET}${UI_DIM}  /api/auth/challenge issue (${AUTH_SMOKE_RESULT}) - see ${SUITE_LOG_FILE}${UI_RESET}" ;;
    *)               ui_box_line "Nostr login  ${UI_DIM}not tested${UI_RESET}" ;;
  esac
  case "$AUTH_SMOKE_RATE_RESULT" in
    ok)              ui_box_line "Rate limit   ${UI_GREEN}enforced${UI_RESET}${UI_DIM}  (429 on request N+1)${UI_RESET}" ;;
    not-enforced)    ui_box_line "Rate limit   ${UI_YELLOW}not enforced${UI_RESET}${UI_DIM}  - check ${SUITE_LOG_FILE}${UI_RESET}" ;;
    skipped)         ui_box_line "Rate limit   ${UI_DIM}skipped${UI_RESET}" ;;
    *)               : ;;
  esac
fi
if [[ "$INSTALL_QUEST" == "1" && "${INSTALL_ARENA_WS:-1}" == "1" ]]; then
  ui_box_line "Quest MP     ${UI_CYAN}wss://${TORII_DOMAIN}/mp${UI_RESET}"
  case "$MP_SMOKE_RESULT" in
    ok)              ui_box_line "  ${UI_ARROW} arena-ws   ${UI_GREEN}loopback probe ok${UI_RESET}" ;;
    timeout)         ui_box_line "  ${UI_ARROW} arena-ws   ${UI_YELLOW}handshake timeout${UI_RESET}${UI_DIM}  - see ${SUITE_LOG_FILE}${UI_RESET}" ;;
    error)           ui_box_line "  ${UI_ARROW} arena-ws   ${UI_YELLOW}probe failed${UI_RESET}${UI_DIM}  - see ${SUITE_LOG_FILE}${UI_RESET}" ;;
    skipped)         ui_box_line "  ${UI_ARROW} arena-ws   ${UI_DIM}skipped${UI_RESET}" ;;
    *)               : ;;
  esac
fi
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
ui_rainbow "  a gateway to a decentralised open world of infinite possibilities"
printf "\n"
