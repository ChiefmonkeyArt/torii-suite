#!/usr/bin/env bash
# torii-suite/installers/register-plebeian.sh
#
# Registers a Plebeian Market tile on the torii-base launcher. Plebeian is
# an external service; we do NOT self-host it. Instead, we write an nginx
# fragment that 302-redirects /plebeian/ -> $PLEBEIAN_EXTERNAL_URL, so the
# launcher tile's "Open" button lands the user on plebeian.market.
#
# We must write a fragment even for external tiles because the torii-base
# sidecar's POST /torii/apps rejects registrations that lack a fragment
# ({"error":"missing_fragment"}). A redirect fragment satisfies that
# contract and gives the launcher tile working navigation.
#
# Env (inherited from bootstrap.sh):
#   PLEBEIAN_EXTERNAL_URL  (default: https://plebeian.market)

set -euo pipefail

PLEBEIAN_EXTERNAL_URL="${PLEBEIAN_EXTERNAL_URL:-https://plebeian.market}"

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
die()  { printf "\033[31mxx  %s\033[0m\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "register-plebeian must run as root"

# Sanity check the URL - bail early on obvious typos rather than register a
# broken tile.
case "$PLEBEIAN_EXTERNAL_URL" in
  https://*|http://*) ;;
  *) die "PLEBEIAN_EXTERNAL_URL must start with http:// or https:// (got: ${PLEBEIAN_EXTERNAL_URL})" ;;
esac

# --------------------------------------------------------------------------- #
# 1. nginx fragment: 302 redirect /plebeian/ -> external URL                  #
# --------------------------------------------------------------------------- #

FRAGMENT_DIR="/opt/torii/nginx-fragments"
FRAGMENT_FILE="${FRAGMENT_DIR}/plebeian.conf"
mkdir -p "$FRAGMENT_DIR"

FRAGMENT_CONTENT="$(cat <<NGINX
# /opt/torii/nginx-fragments/plebeian.conf - written by torii-suite
#
# Plebeian is an external service; we redirect the launcher tile's local
# mount to plebeian.market. 302 (not 301) so we can swap this for a
# self-hosted variant later without cache poisoning.
location = /plebeian/ {
    return 302 ${PLEBEIAN_EXTERNAL_URL};
}
location = /plebeian {
    return 302 ${PLEBEIAN_EXTERNAL_URL};
}
NGINX
)"

if [[ ! -f "$FRAGMENT_FILE" ]] || ! diff -q <(echo "$FRAGMENT_CONTENT") "$FRAGMENT_FILE" >/dev/null; then
  log "writing nginx fragment ${FRAGMENT_FILE}"
  echo "$FRAGMENT_CONTENT" > "$FRAGMENT_FILE"
fi

# --------------------------------------------------------------------------- #
# 2. Register the tile with torii-base sidecar                                #
# --------------------------------------------------------------------------- #

log "registering 'plebeian' launcher tile (external: ${PLEBEIAN_EXTERNAL_URL})"
/usr/local/bin/torii register plebeian \
  --display "Plebeian Market" \
  --desc    "Bitcoin-native marketplace (external site)" \
  --version "external"

# TODO(torii-base): once torii-base v0.2+ supports external-URL tiles in the
# registry schema, pipe PLEBEIAN_EXTERNAL_URL through the register call and
# drop the redirect fragment. Until then, /plebeian/ redirects out and the
# launcher tile's Open button lands on plebeian.market.

log "plebeian tile registered"
