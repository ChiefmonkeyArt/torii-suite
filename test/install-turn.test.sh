#!/usr/bin/env bash
# Suite ADR 0008: the TURN stage is opt-in, private-peer safe and self-testing.
# Static checks always; with root and coturn installed (CI installs it) it
# writes a real config, starts turnserver directly and relays test traffic.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { pass=$((pass+1)); }
S=installers/install-turn.sh

if command -v shellcheck >/dev/null; then shellcheck -S warning "$S" || fail shellcheck; ok; fi
grep -qx 'INSTALL_TURN=0' .env.example || fail ".env.example default"; ok
grep -qF 'INSTALL_TURN="${INSTALL_TURN:-0}"' bootstrap.sh || fail "bootstrap default"; ok
grep -qx 'export INSTALL_TURN' bootstrap.sh || fail "bootstrap export"; ok
grep -qF '_stage_turn()           { "${SCRIPT_DIR}/installers/install-turn.sh"; }' bootstrap.sh || fail "stage fn"; ok
grep -qF '[[ "$INSTALL_TURN"             == "1" ]] && _STAGES_TOTAL' bootstrap.sh || fail "stage count"; ok
out="$(INSTALL_TURN=0 bash "$S")" || fail "skip exits non-zero"
[[ "$out" == *"skipped (INSTALL_TURN=0)"* ]] || fail "skip message"; ok

# Safety rules that must never be dropped.
for want in lt-cred-mech no-tcp-relay no-multicast-peers no-cli fingerprint no-software-attribute; do
  grep -q "echo \"$want\"" "$S" || fail "missing $want"; ok
done
for r in 10.0.0.0-10.255.255.255 127.0.0.0-127.255.255.255 169.254.0.0-169.254.255.255 \
         172.16.0.0-172.31.255.255 192.168.0.0-192.168.255.255 100.64.0.0-100.127.255.255 \
         fc00::-fdff fe80::-febf ' ::1 '; do
  grep -qF -- "$r" "$S" || fail "private range $r not denied"; ok
done
! grep -qE "^  ::-|[[:space:]]::-" "$S" || fail "an IPv6 deny range starts at :: (blocks all IPv4 in coturn)"; ok
grep -q 'policy-rc.d' "$S" || fail "coturn must not start before its config"; ok
grep -q 'force-confold' "$S" || fail "package must keep our config"; ok
grep -q 'APT::Sandbox::User=root' "$S" || fail "apt fallback"; ok
grep -q 'Storage=volatile' "$S" || fail "volatile logs"; ok
grep -q 'chmod 0600 "$CRED"' "$S" || fail "credentials root-only"; ok
! grep -qiE 'google|stun\.l\.|twilio|cloudflare' "$S" || fail "no third-party servers"; ok

if [[ $EUID -eq 0 ]] && command -v turnserver >/dev/null && command -v turnutils_uclient >/dev/null; then
  t="$(mktemp -d)"; fake="$t/bin"; mkdir -p "$fake"
  cat > "$fake/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  restart) pkill -x turnserver; sleep 0.3; (setsid turnserver -c /etc/turnserver.conf >/tmp/torii-turn-test.log 2>&1 &) ;;
  is-active) pgrep -x turnserver >/dev/null ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake/systemctl"
  printf '#!/bin/sh\nexit 1\n' > "$fake/ufw"; chmod +x "$fake/ufw"
  systemctl stop coturn 2>/dev/null || true; pkill -x turnserver || true
  ip4="$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  ext=(); if [[ "$ip4" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|100\.) ]]; then ext=(TORII_TURN_EXTERNAL_IP=203.0.114.7); fi
  env PATH="$fake:$PATH" INSTALL_TURN=1 TORII_DOMAIN=turn.test "${ext[@]}" bash "$S" >/dev/null || { cat /tmp/torii-turn-test.log >&2; fail "install"; }; ok
  [[ "$(stat -c %a /etc/torii/turn/credentials)" == 600 ]] || fail "credentials mode"; ok
  pw="$(sed -n 's/^password=//p' /etc/torii/turn/credentials)"
  [[ ${#pw} == 32 ]] || fail "password length"; ok
  env PATH="$fake:$PATH" INSTALL_TURN=1 TORII_DOMAIN=turn.test "${ext[@]}" bash "$S" >/dev/null || fail "re-run"
  [[ "$(sed -n 's/^password=//p' /etc/torii/turn/credentials)" == "$pw" ]] || fail "re-run changed the password"; ok
  r="$(timeout 30 turnutils_uclient -y -u torii -w "$pw" -r turn.test -n 10 -m 1 -l 170 "$ip4" 2>&1 || true)"
  grep -q 'Total lost packets 0 ' <<< "$r" || { echo "$r" | tail -5 >&2; fail "relay between two clients"; }; ok
  r="$(timeout 15 turnutils_uclient -y -u torii -w wrong -n 2 -m 1 "$ip4" 2>&1 || true)"
  grep -q 'Cannot complete Allocation' <<< "$r" || fail "wrong password accepted"; ok
  r="$(timeout 15 turnutils_uclient -u torii -w "$pw" -e 127.0.0.1 -r 3480 -n 2 -m 1 "$ip4" 2>&1 || true)"
  grep -q '403 (Forbidden IP)' <<< "$r" || fail "relay to loopback allowed"; ok
  # Temporary test login: added with TORII_TURN_TEST_PASSWORD, gone on re-run.
  tp=TestOnly0123456789abcdefABCDEF
  if env PATH="$fake:$PATH" INSTALL_TURN=1 TORII_DOMAIN=turn.test TORII_TURN_TEST_PASSWORD='bad pw' "${ext[@]}" bash "$S" >/dev/null 2>&1; then fail "bad test password accepted"; fi; ok
  out="$(env PATH="$fake:$PATH" INSTALL_TURN=1 TORII_DOMAIN=turn.test TORII_TURN_TEST_PASSWORD=$tp "${ext[@]}" bash "$S")" || fail "install with test login"
  [[ "$out" != *"$tp"* ]] || fail "test password printed"; ok
  ! grep -q "$tp" /etc/torii/turn/credentials || fail "test password stored in credentials"; ok
  r="$(timeout 30 turnutils_uclient -y -u torii-test -w "$tp" -r turn.test -n 5 -m 1 -l 170 "$ip4" 2>&1 || true)"
  grep -q 'Total lost packets 0 ' <<< "$r" || fail "test login relay"; ok
  env PATH="$fake:$PATH" INSTALL_TURN=1 TORII_DOMAIN=turn.test "${ext[@]}" bash "$S" >/dev/null || fail "re-run without test login"
  ! grep -q torii-test /etc/turnserver.conf || fail "test login not removed"; ok
  # A public relay address must be able to relay to public IPv4 peers
  # (v0.9.81/82 denied every IPv4 peer). Uses a test address on lo.
  if ip addr add 45.10.10.10/32 dev lo 2>/dev/null; then
    sed -e 's/^listening-ip=.*/listening-ip=45.10.10.10/' -e 's/^relay-ip=.*/relay-ip=45.10.10.10/' \
      -e '/^external-ip=/d' -e 's/^listening-port=.*/listening-port=3491/' -e 's/^log-file=.*/log-file=\/tmp\/torii-turn-pub.log/' \
      /etc/turnserver.conf > "$t/pub.conf"
    (setsid turnserver -c "$t/pub.conf" >/dev/null 2>&1 &); sleep 1.5
    r="$(timeout 30 turnutils_uclient -y -u torii -w "$pw" -p 3491 -n 5 -m 1 -l 170 45.10.10.10 2>&1 || true)"
    pkill -f "$t/pub.conf" || true; ip addr del 45.10.10.10/32 dev lo || true
    grep -q 'Total lost packets 0 ' <<< "$r" || { tail -3 /tmp/torii-turn-pub.log >&2; fail "relay to a public IPv4 peer refused"; }; ok
  fi
  pkill -x turnserver || true; rm -rf "$t"
fi
echo "install-turn: $pass checks passed"
