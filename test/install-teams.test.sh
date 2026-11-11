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

# Members from Continuum (torii-teams ADR 0016).
check "mesh-sync.mjs parses" node --check "$T/mesh-sync.mjs"
has '"$ROOT/fips/schnorr.mjs" "$ROOT/fips/agent-file.mjs" "$PREFIX/lib/fips/"' "$I" "sync runs root's own copies, not app code"
has '"$ROOT/teams/mesh-sync.mjs" "$PREFIX/lib/teams/"' "$I" "mesh checker installed beside them"
has 'PathChanged=%s' "$I" "a path unit watches the mesh file"
has 'enable -q --now torii-teams-sync.path' "$I" "path unit enabled"
has '"$CONFIG/owner.npub"' "$I" "owner npub recorded for signature checks"
has 'TEAMS_MESH_FILE=%s' "$I" "mesh file location kept in teams.env"
has 'nft -f /opt/torii/fips/mesh.nft ||' "$T/torii-teams" "apply loads rules without bouncing FIPS"
grep -q 'restart torii-fips' "$T/torii-teams" && bad "apply never restarts FIPS units" || ok "apply never restarts FIPS units"
has 'cmp -s' "$T/torii-teams" "sync restarts git only when the lists change"
has '/var/lib/torii-teams-sync' "$T/torii-teams" "sync state kept apart from service data"
has 'Type=oneshot' "$T/torii-teams-sync.service" "sync is a oneshot"
has 'torii-teams sync --files-only ||' "$I" "installer refreshes lists without a second restart"
grep -qx '/usr/local/sbin/torii-teams apply' "$I" && ok "installer always applies (git restarts on reinstall)" || bad "installer always applies (git restarts on reinstall)"
d="$(mktemp -d)"; S="$d/torii-teams"; sed "s#^CONFIG=.*#CONFIG=$d#; s#^LIB=.*#LIB=$ROOT#; s#\[\[ \$EUID -eq 0 \]\].*##" "$T/torii-teams" > "$S"
out="$(TEAMS_MESH_FILE="$d/none.json" bash "$S" sync 2>&1)"
[[ "$out" == "no Continuum mesh file: member files unchanged" ]] && ok "no mesh file leaves member files alone" || bad "no mesh file leaves member files alone"
rm -rf -- "$d"

# Chat stays up (Suite ADR 0005): backup always restarts what it stopped, the
# one-minute watch starts stopped services, pause is respected.
has 'Restart=always' "$C" "coordinator restarts after any exit"
has 'StartLimitIntervalSec=0' "$C" "coordinator never hits a start limit"
has 'Restart=on-failure' "$G" "git keeps on-failure (its skip is not a failure)"
has 'OnUnitActiveSec=1min' "$T/torii-teams-watch.timer" "watch runs every minute"
has 'torii-teams watch' "$T/torii-teams-watch.service" "watch service runs torii-teams watch"
has '"$ROOT"/teams/torii-teams-watch.timer' "$I" "installer copies the watch timer"
has 'enable -q --now torii-teams-watch.timer' "$I" "installer arms the watch timer"
w="$(mktemp -d)"; mkdir -p "$w/bin" "$w/cfg" "$w/state" "$w/bk"
cat > "$w/bin/systemctl" <<'S'
#!/bin/bash
echo "$*" >> "$W/calls"; cmd="$1"; shift; [[ "$cmd" == -q ]] && { cmd="$1"; shift; }
[[ "${1:-}" == -q ]] && shift
u="${1%.service}"
case "$cmd" in
  is-active) s="$(cat "$W/st.$u" 2>/dev/null || echo inactive)"; [[ " $* " == *" -q "* ]] || echo "$s"; [[ "$s" == active ]] ;;
  is-enabled) [[ ! -e "$W/off.$u" ]] ;;
  stop) for x in "$@"; do echo inactive > "$W/st.${x%.service}"; done ;;
  start) for x in "$@"; do echo active > "$W/st.${x%.service}"; done ;;
esac
S
printf '#!/bin/bash\necho "$*" >> "$W/log"\n' > "$w/bin/logger"
cat > "$w/bin/df" <<'S'
#!/bin/bash
echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "x 1 1 ${DF_FREE:-9999999} 1% /"
S
cat > "$w/bin/tar" <<'S'
#!/bin/bash
while (($#)); do [[ "$1" == -czf ]] && { echo x > "$2"; break; }; shift; done
[[ ! -e "$W/tarfail" ]]
S
printf '#!/bin/bash\n[[ -e "$W/gitok" ]]\n' > "$w/bin/run-git"
# Not root here: same install, minus the owner flags.
printf '#!/bin/bash\na=(); while (($#)); do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done\nexec /usr/bin/install "${a[@]}"\n' > "$w/bin/install"
chmod +x "$w/bin/"*
S2="$w/torii-teams"
sed "s#^CONFIG=.*#CONFIG=$w/cfg#; s#^STATE=.*#STATE=$w/state#; s#^BACKUPS=.*#BACKUPS=$w/bk#; s#^RUN_GIT=.*#RUN_GIT=$w/bin/run-git#; s#^LOCK=.*#LOCK=$w/lock#; s#\[\[ \$EUID -eq 0 \]\].*##" "$T/torii-teams" > "$S2"
tt(){ W="$w" PATH="$w/bin:$PATH" bash "$S2" "$@" >/dev/null 2>&1; }
up(){ echo active > "$w/st.torii-teams-coord"; echo active > "$w/st.torii-teams-git"; : > "$w/calls"; : > "$w/log"; }
up; touch "$w/tarfail"; tt backup && bad "failed backup reports failure" || ok "failed backup reports failure"
[[ "$(cat "$w/st.torii-teams-coord")" == active && "$(cat "$w/st.torii-teams-git")" == active ]] \
  && ok "failed backup restarts chat and git" || bad "failed backup restarts chat and git"
compgen -G "$w/bk/*.part" >/dev/null && bad "failed backup leaves no .part" || ok "failed backup leaves no .part"
rm -f "$w/tarfail"; up; DF_FREE=10 tt backup && bad "full disk: backup refused" || ok "full disk: backup refused"
grep -q stop "$w/calls" && bad "full disk: nothing stopped" || ok "full disk: nothing stopped"
grep -q 'backup skipped' "$w/log" && ok "full disk: reason logged" || bad "full disk: reason logged"
up; tt backup && compgen -G "$w/bk/torii-teams-*.tar.gz" >/dev/null && ok "backup writes a tarball" || bad "backup writes a tarball"
[[ "$(cat "$w/st.torii-teams-coord")" == active ]] && ok "backup restarts chat after a good copy" || bad "backup restarts chat after a good copy"
up; echo inactive > "$w/st.torii-teams-coord"; echo inactive > "$w/st.torii-teams-git"; tt watch
[[ "$(cat "$w/st.torii-teams-coord")" == active ]] && ok "watch starts a stopped coordinator" || bad "watch starts a stopped coordinator"
grep -q 'torii-teams-coord.service was inactive' "$w/log" && ok "watch logs the start" || bad "watch logs the start"
[[ "$(cat "$w/st.torii-teams-git")" == inactive ]] && ok "watch leaves unconfigured git alone" || bad "watch leaves unconfigured git alone"
touch "$w/gitok"; tt watch; [[ "$(cat "$w/st.torii-teams-git")" == active ]] && ok "watch starts configured git" || bad "watch starts configured git"
up; echo activating > "$w/st.torii-teams-coord"; tt watch; grep -q '^start' "$w/calls" && bad "watch leaves a restarting unit alone" || ok "watch leaves a restarting unit alone"
up; echo inactive > "$w/st.torii-teams-coord"; touch "$w/off.torii-teams-coord"; tt watch
grep -q '^start' "$w/calls" && bad "watch ignores a disabled unit" || ok "watch ignores a disabled unit"; rm -f "$w/off.torii-teams-coord"
up; tt pause; [[ -e "$w/cfg/paused" && "$(cat "$w/st.torii-teams-coord")" == inactive ]] && ok "pause stops chat" || bad "pause stops chat"
tt watch; [[ "$(cat "$w/st.torii-teams-coord")" == inactive ]] && ok "watch respects pause" || bad "watch respects pause"
tt resume; [[ ! -e "$w/cfg/paused" && "$(cat "$w/st.torii-teams-coord")" == active ]] && ok "resume starts chat" || bad "resume starts chat"
up; echo inactive > "$w/st.torii-teams-coord"; ( exec 8>"$w/lock"; flock 8; W="$w" PATH="$w/bin:$PATH" bash "$S2" watch; true )
[[ "$(cat "$w/st.torii-teams-coord")" == inactive ]] && ok "watch waits while a backup holds the lock" || bad "watch waits while a backup holds the lock"
up; DF_FREE=1000 tt watch; grep -q 'low disk' "$w/log" && ok "watch warns on low disk" || bad "watch warns on low disk"
rm -rf -- "$w"

# After a real install (CI).
if [[ -x /opt/torii/teams/bin/run-git.sh ]]; then
  for u in "$T"/*.service "$T"/*.timer; do
    check "$(basename "$u") verifies" systemd-analyze verify "/etc/systemd/system/$(basename "$u")"
  done
  check "coordinator is running" systemctl is-active -q torii-teams-coord
  check "backup timer is armed" systemctl is-active -q torii-teams-backup.timer
  check "watch timer is armed" systemctl is-active -q torii-teams-watch.timer
  [[ "$(stat -c %a /etc/torii/teams/coord.key)" == 600 ]] && ok "installed key is 0600" || bad "installed key is 0600"
fi

echo "install-teams.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
