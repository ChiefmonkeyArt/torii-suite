#!/usr/bin/env bash
# Static + functional tests for SB-14 (installers/torii-deploy.sh and
# installers/torii-quest-update-runner.sh): the latest-only boundary is kept,
# the semver comparator correctly orders prerelease identifiers, and the deploy
# helper no longer claims an exact version or curls a hardcoded operator site.
#
# Run:  bash test/torii-deploy-sb14.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
DEPLOY="${REPO_ROOT}/installers/torii-deploy.sh"
RUNNER="${REPO_ROOT}/installers/torii-quest-update-runner.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

for f in "$DEPLOY" "$RUNNER"; do
  [[ -f "$f" ]] || { bad "missing $f"; exit 1; }
  bash -n "$f" && ok "$(basename "$f") parses cleanly" || bad "$(basename "$f") failed bash -n"
done

# ── latest-only boundary preserved (never weakened) ─────────────────────────
grep -qF 'git ls-remote --tags --refs' "$RUNNER" \
  && ok "runner still resolves the latest tag itself (latest-only preserved)" \
  || bad "runner lost its authoritative latest-tag resolution"
grep -qE '^ALLOW_TAG_RE=' "$RUNNER" \
  && ok "runner still validates the resolved tag against an allowlist regex" \
  || bad "runner lost its allowlist tag validation"

# ── semver comparator: functional ordering of prerelease identifiers ────────
# Extract the exact cp/cmp functions from the runner so the test exercises the
# SHIPPED comparator, not a re-implementation.
CP_FN="$(sed -n 's/^      \(function cp(v).*\)$/\1/p' "$RUNNER" | head -1)"
CMP_FN="$(sed -n 's/^      \(function cmp(a,b).*\)$/\1/p' "$RUNNER" | head -1)"
[[ -n "$CP_FN" && -n "$CMP_FN" ]] || { bad "could not extract cp/cmp from runner"; exit 1; }

pick_latest() {
  printf '%s\n' "$1" | node -e "
    $CP_FN
    $CMP_FN
    const rl=require('readline').createInterface({input:process.stdin});
    const tags=[];
    rl.on('line',t=>{t=t.trim();if(t)tags.push(t);});
    rl.on('close',()=>{tags.sort(cmp);process.stdout.write(tags.length?tags[tags.length-1]:'');});
  "
}

[[ "$(pick_latest $'v0.2.4-alpha.2\nv0.2.4-alpha.10')" == "v0.2.4-alpha.10" ]] \
  && ok "alpha.10 sorts above alpha.2 (numeric prerelease components)" \
  || bad "alpha.2 vs alpha.10 ordering wrong (got '$(pick_latest $'v0.2.4-alpha.2\nv0.2.4-alpha.10')')"
[[ "$(pick_latest $'v0.2.4-alpha.2\nv0.2.4-beta.1')" == "v0.2.4-beta.1" ]] \
  && ok "beta sorts above alpha (alphanumeric prerelease ordering)" \
  || bad "alpha vs beta ordering wrong (got '$(pick_latest $'v0.2.4-alpha.2\nv0.2.4-beta.1')')"
[[ "$(pick_latest $'v0.2.4-alpha.10\nv0.2.4-beta.1')" == "v0.2.4-beta.1" ]] \
  && ok "beta.1 sorts above alpha.10 despite shorter numeric tail" \
  || bad "alpha.10 vs beta.1 ordering wrong (got '$(pick_latest $'v0.2.4-alpha.10\nv0.2.4-beta.1')')"
[[ "$(pick_latest $'v0.2.4-alpha\nv0.2.4')" == "v0.2.4" ]] \
  && ok "release sorts above any prerelease of the same core" \
  || bad "release-vs-prerelease ordering wrong (got '$(pick_latest $'v0.2.4-alpha\nv0.2.4')')"
[[ "$(pick_latest $'v0.2.3\nv0.2.4-alpha.2')" == "v0.2.4-alpha.2" ]] \
  && ok "higher core with prerelease still beats a lower pure release" \
  || bad "core ordering across prerelease wrong (got '$(pick_latest $'v0.2.3\nv0.2.4-alpha.2')')"

# ── torii-deploy.sh: honest contract + no hardcoded operator site ───────────
if grep -qF 'chiefmonkey.art' "$DEPLOY"; then
  bad "torii-deploy.sh still hardcodes a specific operator's origin"
else
  ok "torii-deploy.sh no longer curls a hardcoded operator site"
fi
grep -qF 'targetRef' "$DEPLOY" \
  && ok "deploy helper reports the version the runner actually deployed (targetRef)" \
  || bad "deploy helper no longer reads the authoritative targetRef"
grep -qF 'status_field' "$DEPLOY" \
  && ok "deploy helper reads the runner status file instead of grepping the log/URL" \
  || bad "deploy helper lost status-file verification"
# The helper must not present an exact-version field the runner refuses to honor.
if grep -qF '"target"' "$DEPLOY"; then
  bad "deploy helper still writes a misleading \"target\" request field"
else
  ok "deploy helper no longer writes a misleading exact-version request field"
fi
grep -qF 'advisory only' "$DEPLOY" \
  && ok "deploy helper documents the version reference as advisory" \
  || bad "deploy helper no longer marks the version reference as advisory"

echo
echo "torii-deploy-sb14.test.sh: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]