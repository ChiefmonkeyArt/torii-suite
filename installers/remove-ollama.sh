#!/usr/bin/env bash
# torii-suite/installers/remove-ollama.sh — take the local Ollama model off
# this server (Suite ADR 0003). Continuum answers through Routstr, which now
# falls back across providers and models on its own (Continuum v0.2.209-alpha).
#
# Run as root by the `ollama_remove` Suite stage, which also writes
# INSTALL_OLLAMA=0 to the operator .env so no later deploy reinstalls it.
# Safe to re-run: every step skips what is already gone.
#
#   1. Continuum: ollama.enabled -> false, restart the agent if it runs
#   2. stop and disable ollama.service, remove its unit and drop-in
#   3. remove /usr/local/bin/ollama, /usr/local/lib/ollama and the model store
#      /usr/share/ollama, then the ollama system user and group
#
# Env: APPS_ROOT (default /apps). OLLAMA_MODE=remote leaves this host alone
# apart from step 1 (nothing local to remove).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/ollama-config.sh
source "$ROOT/lib/ollama-config.sh"
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m--  %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx  remove-ollama: %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "requires root"

APPS_ROOT="${APPS_ROOT:-/apps}"
CONFIG_FILE="${APPS_ROOT}/continuum/agent/repo/agent/config.yaml"
# Test seam: a fake filesystem root for the paths below. Never set in production.
R="${REMOVE_OLLAMA_ROOT:-}"

used_before="$(df --output=used -k "${R:-/}" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"

# 1. Continuum stops considering the local model first, so no turn hangs on a
#    daemon that is about to disappear.
if [[ -f "$CONFIG_FILE" ]]; then
  set +e; ollama_config_set_enabled "$CONFIG_FILE" false; rc=$?; set -e
  case $rc in
    0) log "Continuum: ollama.enabled -> false" ;;
    2) log "Continuum config has no ollama block — nothing to change" ;;
    *) die "could not update ${CONFIG_FILE}" ;;
  esac
  if [[ -z "$R" ]] && systemctl is-active --quiet continuum-agent.service; then
    systemctl restart continuum-agent.service
    log "restarted continuum-agent"
  fi
else
  log "no Continuum config at ${CONFIG_FILE} — skipping"
fi

if [[ "${OLLAMA_MODE:-local}" == remote ]]; then
  log "OLLAMA_MODE=remote: no local Ollama on this host to remove"
  exit 0
fi

# The in-world greeter (hermes-npc) used the same local model.
if id hermes-npc >/dev/null 2>&1; then
  warn "hermes-npc is installed and used this model; the in-world greeter will not answer until it has another model"
fi

# 2. Service.
if [[ -z "$R" ]]; then
  if systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    systemctl disable --now ollama.service >/dev/null 2>&1 || true
    log "stopped and disabled ollama.service"
  fi
fi
rm -f "${R}/etc/systemd/system/ollama.service"
rm -rf "${R}/etc/systemd/system/ollama.service.d"
[[ -z "$R" ]] && systemctl daemon-reload

# 3. Files, models, user.
for p in /usr/local/bin/ollama /usr/local/lib/ollama /usr/share/ollama; do
  if [[ -e "${R}${p}" || -L "${R}${p}" ]]; then
    rm -rf --one-file-system -- "${R}${p}"
    log "removed ${p}"
  fi
done
if [[ -z "$R" ]]; then
  if id ollama >/dev/null 2>&1; then userdel ollama 2>/dev/null && log "removed user ollama" || warn "could not remove user ollama"; fi
  if getent group ollama >/dev/null 2>&1; then groupdel ollama 2>/dev/null && log "removed group ollama" || warn "could not remove group ollama"; fi
fi

used_after="$(df --output=used -k "${R:-/}" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
freed=$(( (used_before - used_after) / 1024 ))
(( freed > 0 )) && log "freed about ${freed} MB" || true
log "Ollama removed. Set INSTALL_OLLAMA=1 and re-run bootstrap to bring it back."
