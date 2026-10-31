#!/usr/bin/env bash
# TEAMS-2b installer contract. Static checks everywhere; unit verification and
# live service checks only after a real install (CI: teams-build.yml).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
I="$ROOT/installers/install-teams.sh"; T="$ROOT/teams"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
has(){ grep -qF -- "$1" "$2" && ok "$3" || bad "$3"; }
hasnt(){ grep -qF -- "$1" "$2" && bad "$3" || ok "$3"; }
check(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && ok "$d" || bad "$d"; }
refuse(){ local d="$1"; shift; "$@" >/dev/null 2>&1 && bad "$d" || ok "$d"; }

for f in "$I" "$T/torii-teams" "$T/run-coord.sh" "$T/run-git.sh"; do
  check "$(basename "$f") parses" bash -n "$f"
done
has 'INSTALL_TEAMS:-0' "$I" "Teams is opt-in"
has 'sha256sum --check --status' "$I" "downloads are checksum-pinned"
hasnt '@GRASP_SHA' "$I" "ngit-grasp checksums are filled in"
hasnt 'cargo' "$I" "no compiler runs on the VPS"
has 'install the node home relay first' "$I" "requires the node relay"
has 'chain members' "$I" "requires the Teams-aware FIPS firewall"
has 'tear down the FIPS trial first' "$I" "refuses to collide with the FIPS trial on :7334"
has 'npub1*' "$I" "git host may not be npub-prefixed (ngit truncation bug)"
has '[[ ! -s "$CONFIG/coord.key" ]]' "$I" "coordinator key is generated once"
has 'chmod 0600 "$CONFIG/coord.key"' "$I" "coordinator key is root-only"
has '[[ ! -e "$CONFIG/git-members" ]]' "$I" "member list is never overwritten"
has 'refusing symlinked' "$I" "symlinked config is refused"
has 'INSTALL_TEAMS="${INSTALL_TEAMS:-0}"' "$ROOT/bootstrap.sh" "bootstrap defaults Teams off"
has '_stage_teams' "$ROOT/bootstrap.sh" "bootstrap has a Teams stage"
has 'INSTALL_TEAMS=0' "$ROOT/.env.example" ".env.example documents INSTALL_TEAMS"

# Service boundaries.
C="$T/torii-teams-coord.service"; G="$T/torii-teams-git.service"
has 'LoadCredential=coord.key:' "$C" "key reaches the coordinator as a credential"
has 'IPAddressDeny=any' "$C" "coordinator has no network beyond loopback"
has 'IPAddressAllow=localhost' "$C" "coordinator may reach the loopback relay"
has 'ws://127.0.0.1:${RELAY_PORT' "$T/run-coord.sh" "coordinator dials the IPv4 loopback relay"
has 'ExecCondition=' "$G" "git is skipped, not failed, until configured"
has 'NGIT_BIND_ADDRESS="[${MESH_IP}]' "$T/run-git.sh" "git binds the mesh address only"
has 'NGIT_PRIVATE_MODE=true' "$T/run-git.sh" "git runs in private mode"
has 'NGIT_USER_INDEX_RELAYS="ws://127.0.0.1' "$T/run-git.sh" "git looks users up on the node relay only"
for u in "$C" "$G"; do
  for k in NoNewPrivileges=true ProtectSystem=strict CapabilityBoundingSet= MemoryDenyWriteExecute=true; do
    has "$k" "$u" "$(basename "$u") $k"
  done
done
has 'Persistent=true' "$T/torii-teams-backup.timer" "missed backups run at next boot"

# Firewall: per-service chain, drop-in glob, ordering before the final drop.
M="$ROOT/fips/mesh.nft"
has 'include "/etc/torii/fips/fips.d/*.nft"' "$M" "mesh firewall includes fips.d drop-ins"
awk '/jump members/{j=NR} /counter drop/{d=NR} END{exit !(j && d && j<d)}' "$M" \
  && ok "member allow list is consulted before the final drop" || bad "member allow list is consulted before the final drop"
has 'VERSION=0.5.3' "$ROOT/installers/install-fips.sh" "FIPS pinned to 0.5.3"
has '"$CONFIG/fips.d"' "$ROOT/installers/install-fips.sh" "FIPS installer creates fips.d"

# Behaviour.
K="$(node "$T/keygen.mjs")"
[[ "$K" =~ ^[0-9a-f]{64}\ [0-9a-f]{64}$ ]] && ok "keygen prints hex secret + x-only pubkey" || bad "keygen prints hex secret + x-only pubkey"
[[ "$(node "$T/keygen.mjs")" != "$K" ]] && ok "keygen is random" || bad "keygen is random"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
N=npub1dl3hkz3zwwmkzxj30eh5a8k7lyml6n8axa2g9jcqm7usk0j5vfks599qa4
printf '# comment\nnot-an-npub\n' > "$tmp/none"; printf '# c\n%s\n%s\n' "$N" "$N" > "$tmp/one"
refuse "git skipped with no members" env TEAMS_MEMBERS_FILE="$tmp/none" MESH_IP=fd00::1 bash "$T/run-git.sh" --check
refuse "git skipped without a mesh address" env TEAMS_MEMBERS_FILE="$tmp/one" MESH_IP= bash "$T/run-git.sh" --check
refuse "git rejects a non-mesh address" env TEAMS_MEMBERS_FILE="$tmp/one" MESH_IP=0.0.0.0 bash "$T/run-git.sh" --check
check "git starts with a member and a mesh address" env TEAMS_MEMBERS_FILE="$tmp/one" MESH_IP=fd00::1 bash "$T/run-git.sh" --check
mkdir -p "$tmp/cred"; echo nsec1bad > "$tmp/cred/coord.key"
refuse "coordinator refuses a malformed key" env CREDENTIALS_DIRECTORY="$tmp/cred" RELAY_PORT=7777 STATE_DIRECTORY="$tmp" bash "$T/run-coord.sh"

# After a real install (CI).
if [[ -x /opt/torii/teams/bin/run-git.sh ]]; then
  for u in "$T"/*.service "$T"/*.timer; do
    check "$(basename "$u") verifies" systemd-analyze verify "/etc/systemd/system/$(basename "$u")"
  done
  check "coordinator is running" systemctl is-active -q torii-teams-coord
  check "backup timer is armed" systemctl is-active -q torii-teams-backup.timer
  [[ "$(stat -c %a /etc/torii/teams/coord.key)" == 600 ]] && ok "installed key is 0600" || bad "installed key is 0600"
fi

echo "install-teams.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
