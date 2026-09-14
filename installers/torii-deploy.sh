#!/usr/bin/env bash
# torii-deploy — request a Quest deploy and wait for the privileged update runner.
# Usage: sudo torii-deploy [version-reference]
#
# The unprivileged Quest server can only REQUEST "install latest approved tag";
# the root update-runner (torii-quest-update-runner) resolves the latest tag
# itself from GitHub and NEVER trusts a version out of the request file. That
# is a deliberate security boundary: a threatened session cannot pin an
# arbitrary tag.
#
# The optional [version-reference] is therefore advisory only — logged and used
# for a post-deploy mismatch warning — not a value the runner will honor. This
# script reports the version the runner ACTUALLY deployed (read from its status
# file), so it never claims a different version went live and never curls a
# hardcoded operator's site to verify.
#
# Exits 0 on success, 1 on failure.
set -euo pipefail

REFERENCE="${1:-}"
REQ_DIR="/apps/quest/mp/update-requests"
STATUS_FILE="/apps/quest/mp/update-status.json"
LOG_FILE="/var/log/torii-quest-update.log"
TIMEOUT_SEC=180

status_field() { # <file> <field> — best-effort JSON field read via node
  sudo node -e '
    const fs=require("fs");const f=process.argv[1],k=process.argv[2];
    try{const o=JSON.parse(fs.readFileSync(f,"utf8"));process.stdout.write(String(o[k]||""));}
    catch(e){process.stdout.write("");}
  ' "$1" "$2" 2>/dev/null || true
}

# --- Clear old requests ---
sudo bash -c "rm -f ${REQ_DIR}/*.json"

# --- Write deploy request (request "latest approved tag", never a pinned ref) ---
printf '{"requestedBy":"manual"}\n' | sudo tee "${REQ_DIR}/manual.json" > /dev/null

if [[ -n "$REFERENCE" ]]; then
  echo "Requesting latest approved tag (reference: ${REFERENCE} — advisory only)..."
else
  echo "Requesting latest approved tag..."
fi

# --- Wait for update-runner to finish ---
# The runner writes /apps/quest/mp/update-status.json (state + targetRef). The
# helper previously grepped the runner's log for "SUCCESS <version>" and then
# curled a hardcoded URL to confirm — both racy and domain-bound. Read the
# authoritative status file instead.
START=$(date +%s)
while true; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))
  if [[ ${ELAPSED} -ge ${TIMEOUT_SEC} ]]; then
    echo "TIMEOUT after ${TIMEOUT_SEC}s — check ${LOG_FILE}"
    exit 1
  fi

  STATE=$(status_field "$STATUS_FILE" state)
  if [[ "$STATE" == "succeeded" ]]; then
    break
  fi
  if [[ "$STATE" == "failed" ]]; then
    echo "DEPLOY FAILED — check ${LOG_FILE}"
    exit 1
  fi
  sleep 2
done

# --- Report the version the runner actually deployed ---
DEPLOYED=$(status_field "$STATUS_FILE" targetRef)
echo "OK: deployed ${DEPLOYED:-unknown}"
if [[ -n "$REFERENCE" && -n "$DEPLOYED" && "$REFERENCE" != "$DEPLOYED" ]]; then
  echo "NOTE: requested reference '${REFERENCE}' differs from deployed '${DEPLOYED}'" \
       "(the runner deploys the latest approved tag, not an exact version)."
fi