#!/usr/bin/env bash
# Suite ADR 0001: the FIPS node on every install.
# Static ordering checks on bootstrap.sh plus functional checks of
# scripts/fips-status.sh with fakes. Run: bash test/bootstrap-fips.test.sh
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
B="$ROOT/bootstrap.sh"; Q="$ROOT/installers/install-quest.sh"; S="$ROOT/scripts/fips-status.sh"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
line_of(){ grep -nE "$1" "$2" | head -1 | cut -d: -f1; }

bash -n "$B" && ok "bootstrap parses" || bad "bootstrap parses"
bash -n "$S" && ok "status script parses" || bad "status script parses"

relay="$(line_of 'run_stage "install Nostr relay' "$B")"
fips="$(line_of 'run_stage "install FIPS node" _stage_fips' "$B")"
quest="$(line_of 'run_stage "install Quest"' "$B")"
teams="$(line_of 'run_stage "install Teams" _stage_teams' "$B")"
[[ -n "$relay" && -n "$fips" && "$fips" -gt "$relay" ]] && ok "FIPS stage runs after the relay stage" || bad "FIPS after relay ($relay/$fips)"
[[ -n "$quest" && "$fips" -lt "$quest" ]] && ok "FIPS stage runs before Quest" || bad "FIPS before Quest ($fips/$quest)"
[[ -n "$teams" && "$fips" -lt "$teams" ]] && ok "FIPS stage runs before Teams" || bad "FIPS before Teams ($fips/$teams)"
gate="$(awk -v n="$fips" 'NR<n && /if \[\[ "\$INSTALL_FIPS" == "1" \]\]; then/ {l=NR} END{print l}' "$B")"
[[ -n "$gate" && $((fips - gate)) -le 3 ]] && ok "FIPS stage is gated on INSTALL_FIPS only, not on any app" || bad "FIPS stage gate"
grep -qF 'INSTALL_FIPS="${INSTALL_FIPS:-1}"' "$B" && ok "FIPS is on by default" || bad "FIPS default"
grep -qF 'FIPS needs the node relay (INSTALL_NOSTR_GIT=1), skipping FIPS' "$B" && ok "no relay: plain warning and skip" || bad "no-relay warning"
grep -qF 'FIPS needs a TUN device' "$B" && ok "no TUN: plain warning and skip" || bad "no-TUN warning"
grep -qF 'export INSTALL_FIPS TORII_FIPS_STAGE' "$B" && ok "flags exported to installers" || bad "export"
grep -qF 'scripts/fips-status.sh' "$B" && ok "doctor stage prints the FIPS line" || bad "doctor line"
grep -qF '"${TORII_FIPS_STAGE:-0}" != 1' "$Q" && ok "Quest skips its call when bootstrap ran the stage" || bad "Quest skip"
grep -qF 'install-fips.sh' "$Q" && ok "Quest keeps its call for the updater" || bad "Quest call kept"

# Bootstrap planning logic, run in isolation with stubbed ui_warn.
plan() {
  env -i PATH="$PATH" INSTALL_NOSTR_GIT="$1" FIPS_TUN_DEV="$2" ${3:+INSTALL_FIPS=$3} bash -c '
    ui_warn(){ echo "WARN $*"; }
    eval "$(sed -n "/^# Suite ADR 0001: the FIPS node on every install/,/^fi$/p;/^if \[\[ \"\$INSTALL_FIPS\" == \"1\" && ! -c/,/^fi$/p" "'"$B"'")"
    echo "INSTALL_FIPS=$INSTALL_FIPS"'
}
out="$(plan 1 /nonexistent/tun)"; [[ "$out" == *"WARN FIPS needs a TUN"* && "$out" == *INSTALL_FIPS=0 ]] && ok "no TUN device turns FIPS off" || bad "no TUN: $out"
out="$(plan 0 /nonexistent/tun)"; [[ "$out" == *"WARN FIPS needs the node relay"* && "$out" == *INSTALL_FIPS=0 ]] && ok "no relay turns FIPS off" || bad "no relay: $out"
out="$(plan 1 /dev/zero 0)"; [[ "$out" != *WARN* && "$out" == *INSTALL_FIPS=0 ]] && ok "INSTALL_FIPS=0 skips quietly" || bad "opt-out: $out"
if [[ -c /dev/net/tun ]]; then
  out="$(plan 1 /dev/net/tun)"; [[ "$out" != *WARN* && "$out" == *INSTALL_FIPS=1 ]] && ok "relay + TUN keeps FIPS on" || bad "default on: $out"
else
  out="$(plan 1 /dev/zero)"; [[ "$out" != *WARN* && "$out" == *INSTALL_FIPS=1 ]] && ok "relay + a char device keeps FIPS on" || bad "default on: $out"
fi

# fips-status.sh with fakes.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$T/bin"; chmod +x "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/up"; printf '#!/bin/sh\nexit 3\n' > "$T/down"; chmod +x "$T/up" "$T/down"
st(){ FIPS_BIN="$1" FIPS_PEERS_FILE="$2" FIPS_SYSTEMCTL="$3" bash "$S"; }
[[ "$(st "$T/none" "$T/p" "$T/up")" == "FIPS: not installed" ]] && ok "status: not installed" || bad "status: not installed"
echo '{"version":1,"peers":[]}' > "$T/p"
[[ "$(st "$T/bin" "$T/p" "$T/up")" == "FIPS: running, 0 peers" ]] && ok "status: running, 0 peers" || bad "status running 0"
echo '{"version":1,"peers":[{"transportNpub":"npub1secretpeer","website":"https://peer.example/"}]}' > "$T/p"
out="$(st "$T/bin" "$T/p" "$T/up")"
[[ "$out" == "FIPS: running, 1 peer" ]] && ok "status: running, 1 peer" || bad "status 1 peer: $out"
[[ "$out" != *npub* && "$out" != *peer.example* && ! "$out" =~ fd[0-9a-f]{2} ]] && ok "status never prints keys, hostnames or mesh addresses" || bad "status leaks: $out"
[[ "$(st "$T/bin" "$T/p" "$T/down")" == "FIPS: not running, 1 peer" ]] && ok "status: not running" || bad "status not running"
echo 'not json' > "$T/p"
[[ "$(st "$T/bin" "$T/p" "$T/up")" == "FIPS: running, 0 peers" ]] && ok "status: bad peer file counts as 0" || bad "status bad json"
ln -sf "$T/p" "$T/link"
[[ "$(st "$T/bin" "$T/link" "$T/up")" == "FIPS: running, 0 peers" ]] && ok "status: symlinked peer file is ignored" || bad "status symlink"

printf '\n[bootstrap-fips.test] pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
