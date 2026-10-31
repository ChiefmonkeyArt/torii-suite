#!/usr/bin/env bash
# TEAMS-2b: Torii Teams services. Opt-in (INSTALL_TEAMS=1).
#   chat: Cordn coordinator on the node relay; members use wss://relay.<domain>
#   git:  private ngit-grasp bound to the FIPS mesh address only (port 7334)
# Pinned, checksummed binaries; no compiler on the VPS. Keys and member lists
# are never overwritten on rerun. Never accepts a personal nsec.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "${INSTALL_TEAMS:-0}" == 1 ]] || { echo "Teams install skipped (INSTALL_TEAMS=0)"; exit 0; }
die() { echo "install-teams: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "requires root"
[[ -f /opt/torii/relay/strfry.conf ]] || die "install the node home relay first (INSTALL_NOSTR_GIT=1)"
command -v node >/dev/null || die "node is required"
FREE_KB="$(df -Pk /opt | awk 'END { print $4 }')"
(( FREE_KB >= 262144 )) || die "needs 256 MiB free headroom"

RELAY_PORT="${NOSTR_RELAY_PORT:-7777}"
[[ "$RELAY_PORT" =~ ^[0-9]+$ ]] && (( RELAY_PORT > 0 && RELAY_PORT <= 65535 )) || die "bad NOSTR_RELAY_PORT"
GIT_HOST="${TEAMS_GIT_HOST:-torii-teams}"
GIT_PORT=7334
# A FIPS shortname. Never npub-prefixed: ngit cuts URLs at the first "npub1".
[[ "$GIT_HOST" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ && "$GIT_HOST" != npub1* ]] || die "bad TEAMS_GIT_HOST"
NPUB_RE='^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$'
OWNER="${TEAMS_OWNER_NPUB:-${CONTINUUM_ADMIN_NPUB:-}}"
[[ -z "$OWNER" || "$OWNER" =~ $NPUB_RE ]] || die "TEAMS_OWNER_NPUB must be an npub"

CORDN_VERSION=v0.5.1-next.3
GRASP_VERSION=v3.0.10
case "$(dpkg --print-architecture)" in
  amd64) TRIPLE=x86_64
    CORDN_SHA=47770f83128e0379a8749969734dd10342c0965af2b6e5111911ea4f0581d49a
    GRASP_SHA=31a32fc65b0de57eaf9c713bec5d9f0378c44012f74732e24d774560a2079562 ;;
  arm64) TRIPLE=aarch64
    CORDN_SHA=834ed2227dcb139223ee1d9839ec3b0f044301150d26c5ba3a0278e93644c354
    GRASP_SHA=3d25ca4b35eae7641bb886ff2a80559d985993b8c6fbb91da009c62d150ac7e4 ;;
  *) die "unsupported architecture" ;;
esac
CORDN_URL="https://github.com/Cordn-msg/cordn-rs/releases/download/${CORDN_VERSION}/cordn-server-${TRIPLE}-unknown-linux-gnu.tar.gz"
GRASP_URL="https://github.com/ChiefmonkeyArt/torii-suite/releases/download/deps-ngit-grasp-${GRASP_VERSION}/ngit-grasp-${GRASP_VERSION}-${TRIPLE}-linux-gnu"
PREFIX=/opt/torii/teams
CONFIG=/etc/torii/teams
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

export DEBIAN_FRONTEND=noninteractive
command -v git >/dev/null && command -v nft >/dev/null || {
  apt-get update -qq
  apt-get install -y --no-install-recommends git nftables ca-certificates curl
}
get() { # url sha out
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 180 "$1" -o "$3"
  printf '%s  %s\n' "$2" "$3" | sha256sum --check --status || die "checksum mismatch: $1"
}
install -d -m 0755 "$PREFIX" "$PREFIX/bin"
if [[ "$(cat "$PREFIX/bin/.cordn.sha" 2>/dev/null)" != "$CORDN_SHA" ]]; then
  get "$CORDN_URL" "$CORDN_SHA" "$TMP/cordn.tgz"
  tar -xzf "$TMP/cordn.tgz" -C "$TMP"
  install -m 0755 "$(find "$TMP" -type f -name cordn-server | head -1)" "$PREFIX/bin/cordn-server"
  echo "$CORDN_SHA" > "$PREFIX/bin/.cordn.sha"
fi
if [[ "$(cat "$PREFIX/bin/.grasp.sha" 2>/dev/null)" != "$GRASP_SHA" ]]; then
  get "$GRASP_URL" "$GRASP_SHA" "$TMP/ngit-grasp"
  install -m 0755 "$TMP/ngit-grasp" "$PREFIX/bin/ngit-grasp"
  echo "$GRASP_SHA" > "$PREFIX/bin/.grasp.sha"
fi
install -m 0755 "$ROOT/teams/run-coord.sh" "$ROOT/teams/run-git.sh" "$PREFIX/bin/"
install -m 0750 "$ROOT/teams/torii-teams" /usr/local/sbin/torii-teams

for u in torii-teams-coord torii-teams-git; do
  id -u "$u" >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --home-dir /nonexistent --no-create-home "$u"
done

install -d -m 0755 -o root -g root "$CONFIG"
for f in coord.key git-members member-nodes; do
  [[ ! -L "$CONFIG/$f" ]] || die "refusing symlinked $CONFIG/$f"
done
if [[ ! -s "$CONFIG/coord.key" ]]; then
  read -r SK PK < <(node "$ROOT/teams/keygen.mjs")
  ( umask 077; printf '%s\n' "$SK" > "$CONFIG/coord.key" )
  printf '%s\n' "$PK" > "$CONFIG/coord.pub"
  unset SK
fi
chown root:root "$CONFIG/coord.key"; chmod 0600 "$CONFIG/coord.key"
if [[ ! -e "$CONFIG/git-members" ]]; then
  { echo "# One npub per line. Private git admits only these. Then: torii-teams apply"
    [[ -n "$OWNER" ]] && echo "$OWNER"; } > "$CONFIG/git-members"
fi
if [[ ! -e "$CONFIG/member-nodes" ]]; then
  echo "# One FIPS device npub per line (fipsctl show). Mesh git port opens only to these." > "$CONFIG/member-nodes"
fi
chmod 0644 "$CONFIG/git-members" "$CONFIG/member-nodes"

MESH_IP=""
if [[ -x /opt/torii/fips/bin/fipsctl && -f /etc/torii/fips/fips.key ]]; then
  MESH_IP="$(/opt/torii/fips/bin/fipsctl address --key /etc/torii/fips/fips.key)"
  [[ "$MESH_IP" =~ ^fd[0-9a-f:]+$ ]] || die "invalid mesh address"
  grep -q 'chain members' /opt/torii/fips/mesh.nft \
    || die "Suite FIPS firewall predates Teams; rerun installers/install-fips.sh first"
  # The FIPS trial (ops/fips-trial in torii-continuum) also binds :7334.
  if ss -Hltn "sport = :$GIT_PORT" | grep -q . && ! systemctl is-active -q torii-teams-git.service; then
    die "port $GIT_PORT already in use (tear down the FIPS trial first)"
  fi
fi
printf 'RELAY_PORT=%s\nGIT_HOST=%s\nGIT_PORT=%s\nMESH_IP=%s\n' \
  "$RELAY_PORT" "$GIT_HOST" "$GIT_PORT" "$MESH_IP" > "$CONFIG/teams.env"
chmod 0644 "$CONFIG/teams.env"

install -m 0644 "$ROOT"/teams/torii-teams-*.service "$ROOT"/teams/torii-teams-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q torii-teams-coord.service torii-teams-git.service torii-teams-backup.timer
systemctl restart torii-teams-coord.service
systemctl start torii-teams-backup.timer
/usr/local/sbin/torii-teams apply
sleep 2
systemctl is-active -q torii-teams-coord.service || die "torii-teams-coord failed to start"
echo "Teams chat coordinator: $(cat "$CONFIG/coord.pub") via wss://relay.${TORII_DOMAIN:-<domain>}"
[[ -n "$MESH_IP" ]] && echo "Teams git (mesh only): http://${GIT_HOST}.fips:${GIT_PORT}; members map '${GIT_HOST}' to this node's FIPS npub"
echo "Members: $CONFIG/git-members, devices: $CONFIG/member-nodes, then: torii-teams apply"
