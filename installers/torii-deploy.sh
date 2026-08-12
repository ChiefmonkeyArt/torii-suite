#!/usr/bin/env bash
# torii-deploy — one-shot Quest version deploy with built-in verify.
# Usage: sudo torii-deploy v0.2.427-alpha
#
# Clears old requests, writes a new deploy request, waits for the
# update-runner to finish, prints the result, and verifies the live version.
# Exits 0 on success, 1 on failure.
set -euo pipefail

VERSION="${1:?Usage: sudo torii-deploy <version>}"
REQ_DIR="/opt/torii-quest/mp/update-requests"
LOG_FILE="/var/log/torii-quest-update.log"
HEALTH_URL="https://chiefmonkey.art/quest/"
TIMEOUT_SEC=180

# --- Clear old requests ---
sudo bash -c "rm -f ${REQ_DIR}/*.json"

# --- Write deploy request ---
REQUEST_FILE="${REQ_DIR}/manual-$(echo "${VERSION}" | tr '/' '-').json"
echo "{\"target\":\"${VERSION}\",\"requestedBy\":\"manual\"}" | sudo tee "${REQUEST_FILE}" > /dev/null

echo "Deploying ${VERSION}..."

# --- Wait for update-runner to finish ---
# The log gets truncated at the start of each run, so we track from now.
START=$(date +%s)
while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if [[ ${ELAPSED} -ge ${TIMEOUT_SEC} ]]; then
    echo "TIMEOUT after ${TIMEOUT_SEC}s — check ${LOG_FILE}"
    exit 1
  fi

  # Check the last few log lines for SUCCESS or FAIL
  LAST_LINES=$(sudo tail -5 "${LOG_FILE}" 2>/dev/null || true)
  if echo "${LAST_LINES}" | grep -q "SUCCESS.*${VERSION}"; then
    echo "${LAST_LINES}"
    break
  fi
  if echo "${LAST_LINES}" | grep -q "FAIL"; then
    echo "DEPLOY FAILED:"
    echo "${LAST_LINES}"
    exit 1
  fi

  sleep 2
done

# --- Verify live version ---
sleep 2  # give nginx a moment to pick up the new symlink
if curl -s "${HEALTH_URL}" | grep -q "${VERSION}"; then
  echo "OK: ${VERSION} is live"
else
  echo "WARNING: ${VERSION} not found on live site"
  exit 1
fi
