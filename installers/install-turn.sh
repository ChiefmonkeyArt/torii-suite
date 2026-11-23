#!/usr/bin/env bash
# torii-suite/installers/install-turn.sh — your own TURN server (coturn) for
# voice calls (Suite ADR 0008). Opt-in (INSTALL_TURN=1).
#
# Torii Companion (Tab5) and 0xchat calls connect directly when they can. When
# a router or mobile network blocks that, the audio is relayed through this
# server, and with the Tab5's "Hide my IP" the other side only ever sees this
# server's address. Calls stay end-to-end encrypted (DTLS-SRTP): the relay
# passes sealed packets and cannot hear them.
#
#   1. coturn from Ubuntu/Debian (apt). If apt's sandbox user cannot resolve
#      the mirrors (seen on chiefmonkey.art), apt is retried as root.
#   2. /etc/turnserver.conf written before the package, so it never starts
#      with the open default config. One login (user "torii") with a random
#      password, kept root-only in /etc/torii/turn/credentials.
#   3. Relays only to public addresses: loopback, private, link-local and
#      CGNAT are refused (no way in to the VPS LAN or local-only services).
#      This server's own public address stays allowed, so two callers who
#      both relay here can still reach each other.
#   4. Small limits for a personal server: 20 relay ports, 64 kB/s per call
#      leg, 10 allocations in total, UDP relays only.
#   5. Logs to a volatile journal namespace (1 day, 8 MB), no log files.
#   6. ufw, when active, gets 3478 udp/tcp and the relay ports; nothing else.
#   7. Self-test: a STUN request to the server must come back.
#
# Listens on the main IPv4 address only (not FIPS, Docker or loopback).
# Ports: 3478 udp+tcp (TURN/STUN), 49160-49179 udp (relays).
# Env: TORII_TURN_EXTERNAL_IP (when the VPS sits behind 1:1 NAT),
#      TORII_TURN_REALM (default TORII_DOMAIN), TORII_TURN_ROTATE=1 (new password),
#      TORII_TURN_TEST_PASSWORD (adds a temporary "torii-test" login for an
#      end-to-end call test; never stored in the credentials file or printed.
#      Re-running the stage without it removes the login).
# Show the login on the VPS: sudo cat /etc/torii/turn/credentials
# Re-runs keep the password unless TORII_TURN_ROTATE=1.
set -euo pipefail
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mxx  install-turn: %s\033[0m\n' "$*" >&2; exit 1; }
[[ "${INSTALL_TURN:-0}" == 1 ]] || { echo "TURN install skipped (INSTALL_TURN=0)"; exit 0; }
[[ $EUID -eq 0 ]] || die "requires root"

PORT=3478
RELAY_MIN=49160
RELAY_MAX=49179
CONF=/etc/turnserver.conf
DIR=/etc/torii/turn
CRED="$DIR/credentials"
REALM="${TORII_TURN_REALM:-${TORII_DOMAIN:-}}"
[[ "$REALM" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || die "set TORII_DOMAIN or TORII_TURN_REALM"

# The address callers are told to send to. Must be public.
is_private4() {
  local ip="$1" a b
  IFS=. read -r a b _ _ <<< "$ip"
  [[ $a == 10 || $a == 127 || $a == 0 ]] && return 0
  [[ $a == 169 && $b == 254 ]] && return 0
  [[ $a == 172 && $b -ge 16 && $b -le 31 ]] && return 0
  [[ $a == 192 && $b == 168 ]] && return 0
  [[ $a == 100 && $b -ge 64 && $b -le 127 ]] && return 0
  return 1
}
EXT="${TORII_TURN_EXTERNAL_IP:-}"
LOCAL4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
[[ "$LOCAL4" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "no IPv4 route; TURN needs one"
if [[ -z "$EXT" ]]; then
  is_private4 "$LOCAL4" && die "this server's address is private ($LOCAL4); set TORII_TURN_EXTERNAL_IP to its public IPv4"
  EXTERNAL_LINE=""
else
  [[ "$EXT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "TORII_TURN_EXTERNAL_IP must be an IPv4 address"
  is_private4 "$EXT" && die "TORII_TURN_EXTERNAL_IP must be public"
  EXTERNAL_LINE="external-ip=$EXT/$LOCAL4"
fi

# Ports must be free (or already ours).
if ss -Hlnu "sport = :$PORT" 2>/dev/null | grep -q . && ! systemctl is-active --quiet coturn; then
  die "port $PORT/udp is already in use by something else"
fi

install -d -m 0700 "$DIR"
[[ ! -L "$CRED" ]] || die "refusing a symlinked credentials file"
PASS=""
if [[ -f "$CRED" && "${TORII_TURN_ROTATE:-0}" != 1 ]]; then
  PASS="$(sed -n 's/^password=//p' "$CRED" | head -n1)"
fi
if [[ ! "$PASS" =~ ^[A-Za-z0-9]{24,64}$ ]]; then
  PASS="$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)"
  [[ ${#PASS} == 32 ]] || die "could not make a password"
fi

TEST_PASS="${TORII_TURN_TEST_PASSWORD:-}"
if [[ -n "$TEST_PASS" && ! "$TEST_PASS" =~ ^[A-Za-z0-9]{24,64}$ ]]; then
  die "TORII_TURN_TEST_PASSWORD must be 24-64 letters and digits"
fi

# Every address a relay may NOT send to (RFC 6890 special-purpose ranges).
# Never start an IPv6 range at "::": coturn then matches every IPv4 peer too
# and refuses to relay anything (fixed in v0.9.83-alpha).
DENY=(
  0.0.0.0-0.255.255.255 10.0.0.0-10.255.255.255 100.64.0.0-100.127.255.255
  127.0.0.0-127.255.255.255 169.254.0.0-169.254.255.255 172.16.0.0-172.31.255.255
  192.0.0.0-192.0.0.255 192.0.2.0-192.0.2.255 192.88.99.0-192.88.99.255
  192.168.0.0-192.168.255.255 198.18.0.0-198.19.255.255 198.51.100.0-198.51.100.255
  203.0.113.0-203.0.113.255 224.0.0.0-255.255.255.255
  ::1 64:ff9b::-64:ff9b::ffff:ffff 100::-100::ffff:ffff:ffff:ffff
  2001::-2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff 2001:db8::-2001:db8:ffff:ffff:ffff:ffff:ffff:ffff
  fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
  ff00::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
)
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
{
  echo "# Written by Torii Suite installers/install-turn.sh (ADR 0008). Re-run to change."
  echo "listening-port=$PORT"
  echo "listening-ip=$LOCAL4"
  echo "relay-ip=$LOCAL4"
  echo "min-port=$RELAY_MIN"
  echo "max-port=$RELAY_MAX"
  if [[ -n "$EXTERNAL_LINE" ]]; then echo "$EXTERNAL_LINE"; fi
  echo "realm=$REALM"
  echo "fingerprint"
  echo "lt-cred-mech"
  echo "user=torii:$PASS"
  if [[ -n "$TEST_PASS" ]]; then echo "user=torii-test:$TEST_PASS"; fi
  echo "no-tls"
  echo "no-dtls"
  echo "no-tcp-relay"
  echo "no-multicast-peers"
  echo "no-cli"
  echo "no-software-attribute"
  echo "stale-nonce=600"
  echo "total-quota=10"
  echo "user-quota=10"
  echo "max-bps=64000"
  echo "max-allocate-lifetime=3600"
  echo "log-file=stdout"
  echo "simple-log"
  for r in "${DENY[@]}"; do echo "denied-peer-ip=$r"; done
} > "$TMP/turnserver.conf"
install -m 0640 -o root -g root "$TMP/turnserver.conf" "$CONF.torii"

# Install the package with our config already in place and the service held.
if ! dpkg -s coturn >/dev/null 2>&1; then
  log "installing coturn"
  install -m 0640 "$CONF.torii" "$CONF"
  export DEBIAN_FRONTEND=noninteractive
  APT=(apt-get -qq)
  if ! "${APT[@]}" update; then
    log "apt could not update as its sandbox user; retrying as root"
    APT=(apt-get -qq -o APT::Sandbox::User=root)
    "${APT[@]}" update || die "apt-get update failed; nothing was changed"
  fi
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
  trap 'rm -f /usr/sbin/policy-rc.d; rm -rf -- "$TMP"' EXIT
  "${APT[@]}" install -y --no-install-recommends -o Dpkg::Options::=--force-confold coturn \
    || die "apt-get install coturn failed"
  rm -f /usr/sbin/policy-rc.d
fi
command -v turnserver >/dev/null || die "coturn did not install"
install -m 0640 "$CONF.torii" "$CONF"
rm -f "$CONF.torii"
# The Debian service reads its user from here; it must be able to read the config.
if getent group turnserver >/dev/null; then chgrp turnserver "$CONF"; fi
if [[ -f /etc/default/coturn ]]; then sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn; fi

umask 077
printf 'server=turn:%s:%s\nuser=torii\npassword=%s\n' "${EXT:-$LOCAL4}" "$PORT" "$PASS" > "$CRED.new"
mv -f "$CRED.new" "$CRED"
chmod 0600 "$CRED"
umask 022

# Volatile, bounded logs; no files on disk. Plus a little systemd hardening.
install -d /etc/systemd/journald@torii-turn.conf.d /etc/systemd/system/coturn.service.d \
  /etc/systemd/system/systemd-journald@torii-turn.service.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=8M\nRuntimeMaxFileSize=1M\nMaxRetentionSec=1day\n' \
  > /etc/systemd/journald@torii-turn.conf.d/limits.conf
printf '[Service]\nLogsDirectory=\n' \
  > /etc/systemd/system/systemd-journald@torii-turn.service.d/volatile.conf
printf '[Service]\nLogNamespace=torii-turn\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectHome=yes\nProtectSystem=full\nRestart=on-failure\n' \
  > /etc/systemd/system/coturn.service.d/torii.conf

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "opening TURN ports in ufw"
  ufw allow "$PORT/udp" comment 'Torii TURN' >/dev/null
  ufw allow "$PORT/tcp" comment 'Torii TURN' >/dev/null
  ufw allow "$RELAY_MIN:$RELAY_MAX/udp" comment 'Torii TURN relays' >/dev/null
fi

systemctl daemon-reload
systemctl enable -q coturn
systemctl restart coturn
ok=0
for _ in {1..20}; do
  if ss -Hlnu "sport = :$PORT" | grep -q .; then ok=1; break; fi
  sleep 0.5
done
[[ $ok == 1 ]] || { journalctl -u coturn -n 20 --no-pager >&2 || true; die "coturn is not listening on $PORT/udp"; }
if command -v turnutils_stunclient >/dev/null; then
  timeout 10 turnutils_stunclient -p "$PORT" "$LOCAL4" >/dev/null 2>&1 || die "STUN self-test failed"
  log "STUN self-test passed"
fi
echo "TURN server running on port $PORT (relays $RELAY_MIN-$RELAY_MAX/udp)."
if [[ -n "$TEST_PASS" ]]; then
  echo "Temporary test login torii-test is on. Run the stage again without it to remove it."
else
  echo "No test login."
fi
echo "Show the login for the Tab5 (Settings > Calls): sudo cat $CRED"
echo "If your provider has its own firewall, open the same ports there."
