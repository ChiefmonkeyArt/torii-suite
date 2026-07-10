#!/usr/bin/env bash
# torii-suite/installers/install-ollama.sh
#
# Installs Ollama as a local, loopback-bound LLM daemon so the Continuum
# agent can fall back to a self-hosted model when Routstr is unavailable.
#
# Design notes:
#   - Loopback-only (127.0.0.1:11434). Not exposed on the public interface.
#   - OLLAMA_ORIGINS restricted to localhost so a same-host process can't be
#     tricked into calling the daemon on someone else's behalf.
#   - CPU-only by default. On a small VPS the shipped model (llama3.2:3b) will
#     produce roughly 1–5 tok/s — usable as a fallback, not a daily driver.
#     The Continuum model router defaults to `routstr_first`, so this only
#     kicks in when Routstr returns 402 or is otherwise unavailable.
#   - Ported by hand from torii-continuum ops/ansible/roles/ollama so a suite
#     bootstrap can install the exact same shape without pulling in ansible.
#
# Env contract:
#   OLLAMA_BIND               (default 127.0.0.1:11434)
#   OLLAMA_MODELS             (default "llama3.2:3b" — space-separated list)
#   OLLAMA_HEALTHCHECK_TRIES  (default 20)
#   OLLAMA_HEALTHCHECK_DELAY  (default 3s)

set -euo pipefail

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33m--  %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install-ollama must run as root"

# Defence in depth: bootstrap.sh already skips this stage in remote mode, but
# a hand-run of this installer while OLLAMA_MODE=remote is set in the env
# would otherwise install a local daemon the operator didn't want. Refuse.
if [[ "${OLLAMA_MODE:-local}" == "remote" ]]; then
  die "OLLAMA_MODE=remote is set — not installing a local Ollama daemon. Unset OLLAMA_MODE or set it to 'local' if you want the local install."
fi

OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1:11434}"
OLLAMA_MODELS="${OLLAMA_MODELS:-llama3.2:3b}"
OLLAMA_HEALTHCHECK_TRIES="${OLLAMA_HEALTHCHECK_TRIES:-20}"
OLLAMA_HEALTHCHECK_DELAY="${OLLAMA_HEALTHCHECK_DELAY:-3}"

# --------------------------------------------------------------------------- #
# 1. Install the binary                                                       #
# --------------------------------------------------------------------------- #

if [[ ! -x /usr/local/bin/ollama ]]; then
  log "installing ollama (official installer)"
  # The official installer is a curl|sh — we run it as-is because the alternative
  # is redistributing a binary we don't control. Its content is public and
  # reviewable. If the operator objects, they can disable INSTALL_OLLAMA and run
  # ollama out-of-band.
  curl -fsSL https://ollama.com/install.sh | sh
else
  log "ollama already installed at /usr/local/bin/ollama — skipping install"
fi

# --------------------------------------------------------------------------- #
# 2. systemd override — loopback bind + restricted origins                    #
# --------------------------------------------------------------------------- #

log "writing systemd override (bind=${OLLAMA_BIND}, origins=localhost only)"

mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}"
Environment="OLLAMA_ORIGINS=http://127.0.0.1,http://localhost"
EOF
chmod 644 /etc/systemd/system/ollama.service.d/override.conf

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# --------------------------------------------------------------------------- #
# 3. Health check                                                             #
# --------------------------------------------------------------------------- #

log "waiting for ollama to answer on http://${OLLAMA_BIND}/api/tags"

tries=0
until curl -fsS "http://${OLLAMA_BIND}/api/tags" >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [[ $tries -ge $OLLAMA_HEALTHCHECK_TRIES ]]; then
    die "ollama did not respond on ${OLLAMA_BIND} after $((tries * OLLAMA_HEALTHCHECK_DELAY))s — check: journalctl -u ollama -n 100"
  fi
  sleep "$OLLAMA_HEALTHCHECK_DELAY"
done

log "ollama healthy after ${tries} attempts"

# --------------------------------------------------------------------------- #
# 4. Pull configured models                                                   #
# --------------------------------------------------------------------------- #

for model in $OLLAMA_MODELS; do
  log "pulling model: ${model} (this can take a while on first run)"
  # `ollama pull` is idempotent: it verifies the manifest and no-ops if the
  # model is already up to date.
  /usr/local/bin/ollama pull "$model" \
    || warn "failed to pull ${model} — Continuum will still start, but this model won't be available"
done

log "ollama install complete — daemon on ${OLLAMA_BIND}, ${OLLAMA_MODELS//  / } ready"
