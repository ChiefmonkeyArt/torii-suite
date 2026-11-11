#!/usr/bin/env bash
# torii-suite/installers/remove-gliclass.sh — take GLiClass Edge off this
# server (Suite ADR 0004). Run by the `gliclass_remove` stage, which also writes
# INSTALL_GLICLASS=0 to the operator .env. Safe to re-run.
# Benchmark results in /var/lib/gliclass-edge are kept (a few KB each);
# GLICLASS_REMOVE_RESULTS=1 removes them too.
set -euo pipefail
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mxx  remove-gliclass: %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "requires root"
GL_ROOT="${GLICLASS_ROOT:-/opt/gliclass-edge}"
case "$GL_ROOT" in /?*) ;; *) die "GLICLASS_ROOT must be an absolute path" ;; esac
[[ "$GL_ROOT" != / ]] || die "refusing to remove /"
if [[ -e "$GL_ROOT" ]]; then
  [[ -f "$GL_ROOT/INSTALLED" || -d "$GL_ROOT/model" || -d "$GL_ROOT/venv" ]] \
    || die "${GL_ROOT} does not look like a GLiClass Edge install; not touching it"
  mb="$(du -sm "$GL_ROOT" | cut -f1)"
  rm -rf --one-file-system -- "$GL_ROOT"
  log "removed ${GL_ROOT}, freed about ${mb} MB"
else
  log "GLiClass Edge is not installed (${GL_ROOT} absent)"
fi
if [[ "${GLICLASS_REMOVE_RESULTS:-0}" == 1 ]]; then
  rm -rf -- /var/lib/gliclass-edge /var/lib/private/gliclass-edge
  log "removed benchmark results"
fi
log "Set INSTALL_GLICLASS=1 and re-run the gliclass stage to bring it back."
