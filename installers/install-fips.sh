#!/usr/bin/env bash
# Automatic Suite node-build component, not a browser/plugin installation.
# Fresh installations get stable node identity + no peers until enrolled.
# Operator-owned peer pins survive upgrades. Never accepts a personal nsec.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "${INSTALL_FIPS:-1}" == 1 ]] || { echo "FIPS install skipped by operator"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "FIPS provisioning requires root" >&2; exit 1; }
[[ -c /dev/net/tun ]] || { echo "FIPS requires a host TUN device" >&2; exit 1; }
# Do not take over an independently managed daemon/interface.
if [[ -e /etc/fips/fips.yaml ]] || systemctl is-active --quiet fips.service; then
  echo "Existing independently managed FIPS found; refusing to replace it" >&2
  exit 1
fi
[[ -f /opt/torii/relay/strfry.conf ]] || { echo "Install the node home relay before FIPS" >&2; exit 1; }
command -v node >/dev/null
command -v nginx >/dev/null
FREE_KB="$(df -Pk /opt | awk 'END { print $4 }')"
(( FREE_KB >= 262144 )) || { echo "FIPS provisioning needs 256 MiB free headroom" >&2; exit 1; }

VERSION=0.5.3
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) SHA=6edd18e67c4f4c47d9d8c7366aacc6505d11df79c1c4b1b1d63246fa66e3e8a3 ;;
  arm64) SHA=8b1dc54163cd99f92f13845296f6511f5683e9d5635da51400b27f0dd5f07b48 ;;
  *) echo "Unsupported FIPS architecture: $ARCH" >&2; exit 1 ;;
esac
PREFIX=/opt/torii/fips
CONFIG=/etc/torii/fips
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends nftables libdbus-1-3 ca-certificates curl
if [[ ! -x "$PREFIX/bin/fips" ]] || [[ "$("$PREFIX/bin/fips" -V)" != "fips $VERSION"* ]]; then
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 120 \
    "https://github.com/jmcorgan/fips/releases/download/v${VERSION}/fips_${VERSION}_${ARCH}.deb" \
    -o "$TMP/fips.deb"
  printf '%s  %s\n' "$SHA" "$TMP/fips.deb" | sha256sum --check --status
  # Extract binaries only. Do NOT execute upstream postinst or change host DNS.
  dpkg-deb -x "$TMP/fips.deb" "$TMP/package"
  install -d -m 0755 "$PREFIX/bin"
  install -m 0755 "$TMP/package/usr/bin/fips" "$TMP/package/usr/bin/fipsctl" "$PREFIX/bin/"
  install -m 0644 "$TMP/package/usr/share/doc/fips/copyright" "$PREFIX/COPYRIGHT"
fi
install -d -m 0755 "$CONFIG" "$CONFIG/fips.d"
if [[ ! -e "$CONFIG/peers.json" ]]; then
  printf '{"version":1,"peers":[]}\n' > "$CONFIG/peers.json"
fi
[[ ! -L "$CONFIG/peers.json" ]] || { echo "Refusing symlinked peer config" >&2; exit 1; }
chown root:root "$CONFIG/peers.json"
chmod 0644 "$CONFIG/peers.json"
node "$ROOT/fips/render-config.mjs" "$CONFIG/peers.json" "$TMP/fips.yaml" "$PREFIX/bin/fipsctl"
install -m 0600 "$TMP/fips.yaml" "$CONFIG/fips.yaml"
if [[ ! -e "$CONFIG/fips.key" ]]; then
  "$PREFIX/bin/fipsctl" keygen --dir "$CONFIG"
fi
chmod 0600 "$CONFIG/fips.key"
MESH_IP="$("$PREFIX/bin/fipsctl" address --key "$CONFIG/fips.key")"
[[ "$MESH_IP" =~ ^fd[0-9a-f:]+$ ]] || { echo "Invalid mesh address" >&2; exit 1; }
RELAY_PORT="${NOSTR_RELAY_PORT:-7777}"
[[ "$RELAY_PORT" =~ ^[0-9]+$ ]] && (( RELAY_PORT > 0 && RELAY_PORT <= 65535 ))

install -m 0644 "$ROOT/fips/mesh.nft" "$PREFIX/mesh.nft"
install -m 0644 "$ROOT/fips/"*.service /etc/systemd/system/
# The additional mesh route binds ONLY the npub-derived IPv6, never [::].
# It is an isolated nginx process; a FIPS failure cannot stop the HTTPS proxy.
cat > "$PREFIX/relay-nginx.conf" <<NGINX
pid /run/torii-fips-relay/nginx.pid;
error_log stderr warn;
worker_processes 1;
events { worker_connections 64; }
http {
  access_log off;
  client_body_temp_path /run/torii-fips-relay/body;
  proxy_temp_path /run/torii-fips-relay/proxy;
  limit_conn_zone \$binary_remote_addr zone=mesh:64k;
  server {
    listen [$MESH_IP]:7778;
    client_max_body_size 16k;
    limit_conn mesh 2;
    location = / {
      limit_except GET { deny all; }
      proxy_pass http://127.0.0.1:$RELAY_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host localhost;
      proxy_buffering off;
      proxy_read_timeout 45s;
      proxy_send_timeout 5s;
    }
    location / { return 404; }
  }
}
NGINX
chmod 0644 "$PREFIX/relay-nginx.conf"

# Bounded, volatile namespace; no global journal policy changes or profiler files.
install -d /etc/systemd/journald@torii-fips.conf.d \
  /etc/systemd/system/systemd-journald@torii-fips.service.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=8M\nRuntimeMaxFileSize=1M\nMaxRetentionSec=1day\n' \
  > /etc/systemd/journald@torii-fips.conf.d/limits.conf
printf '[Service]\nLogsDirectory=\n' \
  > /etc/systemd/system/systemd-journald@torii-fips.service.d/volatile.conf
# Peer introductions from Continuum (torii-continuum docs/adr-fips-default.md
# §4): the agent drops an admin-signed list; this root path unit checks the
# signature against the node admin and rewrites peers.json. The helper and its
# libraries are copied here so root never runs app-owned code.
install -d -m 0755 "$PREFIX/lib"
install -m 0644 "$ROOT/fips/render-config.mjs" "$ROOT/fips/schnorr.mjs" "$ROOT/fips/agent-file.mjs" "$ROOT/fips/apply-peer-request.mjs" "$PREFIX/lib/"
install -m 0755 "$ROOT/fips/torii-fips-peers" /usr/local/sbin/torii-fips-peers
if [[ -z "${CONTINUUM_ADMIN_NPUB:-}" && -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  CONTINUUM_ADMIN_NPUB="$(set -a; . "$ROOT/.env" >/dev/null 2>&1; printf '%s' "${CONTINUUM_ADMIN_NPUB:-}")"
fi
if [[ "${CONTINUUM_ADMIN_NPUB:-}" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]]; then
  printf '%s\n' "$CONTINUUM_ADMIN_NPUB" > "$CONFIG/admin.npub"
  chmod 0644 "$CONFIG/admin.npub"
fi
PEER_REQUEST="${TORII_FIPS_PEER_REQUEST:-${APPS_ROOT:-/apps}/continuum/agent/repo/agent/memory/fips/peer-request.json}"
[[ "$PEER_REQUEST" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "Invalid TORII_FIPS_PEER_REQUEST" >&2; exit 1; }
printf 'TORII_FIPS_PEER_REQUEST=%s\n' "$PEER_REQUEST" > "$CONFIG/peers.env"
printf '[Unit]\nDescription=Torii FIPS: watch for an operator-signed peer list\n\n[Path]\nPathChanged=%s\nUnit=torii-fips-peers.service\n\n[Install]\nWantedBy=paths.target\n' \
  "$PEER_REQUEST" > /etc/systemd/system/torii-fips-peers.path
systemctl daemon-reload
systemctl enable --now torii-fips-firewall.service
systemctl enable -q --now torii-fips-peers.path
systemctl enable torii-fips.service torii-fips-relay.service
systemctl restart torii-fips.service
# Upstream can remain active in DEGRADED state without TUN. Require the actual
# interface before starting the proxy; never confuse "process alive" with ready.
READY=0
for _ in {1..30}; do
  if ip -6 addr show dev fips0 2>/dev/null | grep -q 'inet6 fd'; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == 1 ]] || { echo "FIPS TUN did not become ready" >&2; exit 1; }
systemctl restart torii-fips-relay.service
sleep 1
systemctl is-active --quiet torii-fips.service torii-fips-relay.service
echo "FIPS background transport installed. Peer pins: $CONFIG/peers.json"
echo "Other operators must approve their own install; no remote VPS was changed."
