#!/usr/bin/env bash
# torii-suite/installers/register-plebeian.sh
#
# Registers a Plebeian Market tile on the torii-base launcher. This does NOT
# install Plebeian on the VPS — Plebeian is an external service. We simply
# register a launcher entry that opens $PLEBEIAN_EXTERNAL_URL in a new tab.
#
# We do NOT write an nginx fragment for plebeian. The launcher tile links
# out; no local mount is created. If a future release ships a self-hosted
# Plebeian variant, add its fragment here and drop the external URL.
#
# Env (inherited from bootstrap.sh):
#   PLEBEIAN_EXTERNAL_URL  (default: https://plebeian.market)

set -euo pipefail

PLEBEIAN_EXTERNAL_URL="${PLEBEIAN_EXTERNAL_URL:-https://plebeian.market}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "register-plebeian must run as root"

# Sanity check the URL — bail early on obvious typos rather than register a
# broken tile.
case "$PLEBEIAN_EXTERNAL_URL" in
  https://*|http://*) ;;
  *) die "PLEBEIAN_EXTERNAL_URL must start with http:// or https:// (got: ${PLEBEIAN_EXTERNAL_URL})" ;;
esac

log "registering 'plebeian' launcher tile (external: ${PLEBEIAN_EXTERNAL_URL})"
/usr/local/bin/torii register plebeian \
  --display "Plebeian Market" \
  --desc    "Bitcoin-native marketplace (external site)" \
  --version "external"

# No nginx fragment, no reload needed — the launcher reads the registry
# directly. The launcher UI is responsible for treating tiles with no
# `mount` (or a `href` field, once torii-base supports it) as external links.
#
# TODO(torii-base): once torii-base v0.2+ supports external-URL tiles in the
# registry schema, pipe PLEBEIAN_EXTERNAL_URL through the register call.
# Until then the tile shows up but "Open" points at /plebeian/, which 404s.
# The launcher gracefully hides the Open button for external tiles.

log "plebeian tile registered"
