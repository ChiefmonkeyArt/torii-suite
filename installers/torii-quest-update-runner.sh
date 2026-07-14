#!/usr/bin/env bash
# torii-suite/installers/torii-quest-update-runner.sh
#
# Root update runner for Torii Quest. Installed to /usr/local/sbin/torii-quest-update-runner
# and triggered by systemd torii-quest-update.path whenever arena-ws (running as the
# unprivileged torii-quest user) writes a request file to
# /opt/torii-quest/mp/update-requests/. arena-ws CANNOT run this itself: it runs under
# NoNewPrivileges=true + ProtectSystem=strict and cannot sudo/systemctl. This runner is
# the single privileged boundary that performs the reinstall.
#
# SECURITY MODEL — the unprivileged server can only REQUEST "install latest approved tag":
#   * This runner resolves the latest tag ITSELF (git ls-remote against GitHub). It NEVER
#     reads a requested version out of the request file, so a compromised/threatened admin
#     session cannot pin an arbitrary tag.
#   * The resolved tag is validated against an allowlist regex before any deploy.
#   * The deploy command is FIXED (cd checkout && git pull && source .env && install-quest.sh).
#     No request-file field is ever substituted into a shell command.
#   * Single-flight via flock; extra pending requests are discarded.
#   * Status is written to /opt/torii-quest/mp/update-status.json (0644, readable by
#     torii-quest so arena-ws can report progress to the admin client).
#
# Logs to journald (via systemd) + /var/log/torii-quest-update.log.

set -euo pipefail

QUEST_REPO_URL="https://github.com/ChiefmonkeyArt/torii-quest.git"
SUITE_CHECKOUT="/opt/torii-suite/checkout"
SUITE_WORK_DIR="/opt/torii-suite/work"
QUEST_SRC="${SUITE_WORK_DIR}/torii-quest"
REQ_DIR="/opt/torii-quest/mp/update-requests"
STATUS_FILE="/opt/torii-quest/mp/update-status.json"
LOG_FILE="/var/log/torii-quest-update.log"
LOCK_FILE="/var/lock/torii-quest-update.lock"
# Allowlist: vMAJOR.MINOR.PATCH with optional -prerelease (semver-ish). Rejects anything else.
ALLOW_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }

# write_status <state> <targetRef> <message>  — atomic JSON write via node (always present).
write_status() {
  local state="$1" target="${2:-}" msg="${3:-}"
  node -e '
    const fs=require("fs"),path=process.argv[1],state=process.argv[2],target=process.argv[3]||"",msg=process.argv[4]||"";
    let cur={}; try{cur=JSON.parse(fs.readFileSync(path,"utf8"))||{};}catch{}
    const now=Math.floor(Date.now()/1000);
    const startedAt = state==="running" ? (cur.startedAt||now) : cur.startedAt;
    const out={state,targetRef:target||cur.targetRef||"",startedAt:startedAt||null,
      finishedAt:(state==="succeeded"||state==="failed")?now:null,message:msg};
    fs.writeFileSync(path+".tmp",JSON.stringify(out,null,2));
    fs.renameSync(path+".tmp",path);
  ' "$STATUS_FILE" "$state" "$target" "$msg" || true
}

# --- single-flight ---------------------------------------------------------- #
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another update is already running — exiting"
  exit 0
fi

# --- pick newest pending request (discard extras) --------------------------- #
req="$(ls -1 "$REQ_DIR"/*.json 2>/dev/null | sort | tail -n1 || true)"
if [[ -z "$req" ]]; then
  log "no pending request — exiting"
  exit 0
fi
log "processing request $(basename "$req")"
find "$REQ_DIR" -maxdepth 1 -name '*.json' -delete

write_status "running" "" "resolving latest tag"

# --- resolve latest tag from GitHub (server-side, authoritative) ------------ #
# git ls-remote lists refs/tags/v*; node picks the highest by tolerant semver
# (same compare shape as the Quest client's updateCheck.compareVersions).
latest="$(git ls-remote --tags --refs "$QUEST_REPO_URL" 'refs/tags/v*' 2>/dev/null \
  | sed 's#.*refs/tags/##' \
  | node -e '
    const rl=require("readline").createInterface({input:process.stdin});
    const tags=[];
    rl.on("line",t=>{t=t.trim();if(t)tags.push(t);});
    rl.on("close",()=>{
      function cp(v){v=String(v).replace(/^v/,"");const [c="",p=""]=v.split("-");const core=c.split(".").map(n=>parseInt(n,10)||0);while(core.length<3)core.push(0);return{core:core.slice(0,3),pre:p?p.split("."):[]};}
      function cmp(a,b){const A=cp(a),B=cp(b);for(let i=0;i<3;i++){if(A.core[i]!==B.core[i])return A.core[i]<B.core[i]?-1:1;}if(!A.pre.length&&!B.pre.length)return 0;if(!A.pre.length)return 1;if(!B.pre.length)return -1;const L=Math.max(A.pre.length,B.pre.length);for(let i=0;i<L;i++){if(A.pre[i]===undefined)return -1;if(B.pre[i]===undefined)return 1;}return 0;}
      tags.sort(cmp);
      process.stdout.write(tags.length?tags[tags.length-1]:"");
    });
  ' 2>/dev/null || true)"

if [[ -z "$latest" ]]; then
  log "FAILED: could not resolve latest tag from GitHub"
  write_status "failed" "" "could not resolve latest tag from GitHub"
  exit 1
fi
if ! [[ "$latest" =~ $ALLOW_TAG_RE ]]; then
  log "FAILED: resolved tag '$latest' failed allowlist regex"
  write_status "failed" "$latest" "resolved tag failed allowlist regex"
  exit 1
fi
log "resolved latest tag: $latest"
write_status "running" "$latest" "deploying $latest"

# --- fixed deploy flow (no request-file field is substituted) --------------- #
# Mirrors the maintainer's manual deploy: pull suite checkout, source .env, set the
# resolved ref, hard-reset the quest work tree, then let install-quest.sh fetch +
# checkout + build + restart torii-arena-ws.service.
if bash -c '
    set -euo pipefail
    cd "'"$SUITE_CHECKOUT"'"
    git pull --ff-only
    set -a; . ./.env; set +a
    export SUITE_WORK_DIR="'"$SUITE_WORK_DIR"'"
    export TORII_QUEST_REF="'"$latest"'"
    git -C "'"$QUEST_SRC"'" fetch --tags --prune origin
    git -C "'"$QUEST_SRC"'" reset --hard
    git -C "'"$QUEST_SRC"'" checkout "'"$latest"'"
    bash installers/install-quest.sh
  '; then
  log "SUCCESS: deployed $latest"
  write_status "succeeded" "$latest" "deployed $latest"
else
  rc=$?
  log "FAILED: deploy of $latest exited $rc"
  write_status "failed" "$latest" "deploy exited $rc — see $LOG_FILE"
  exit "$rc"
fi
