#!/usr/bin/env bash
# Static SB-10 assertions for installers/install-quest.sh: the flag-gated
# release-artifact fast path. When TORII_QUEST_ARTIFACT=1 the installer must
# download the CI-built tarball for a v<semver> tag, verify its checksum, and
# promote it WITHOUT cloning or building on the box — while the default (flag
# unset/0) source-build path stays byte-for-byte unchanged for today's
# git-driven updater.
#
# Run:  bash test/install-quest-sb10-artifact.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
INST="${REPO_ROOT}/installers/install-quest.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

[[ -f "$INST" ]] || { bad "missing $INST"; exit 1; }
bash -n "$INST" && ok "install-quest.sh parses cleanly" || bad "install-quest.sh failed bash -n"

# ── SB-10: flag is opt-in and defaults OFF (source-build preserved) ──────────
grep -qF 'TORII_QUEST_ARTIFACT="${TORII_QUEST_ARTIFACT:-0}"' "$INST" \
  && ok "TORII_QUEST_ARTIFACT defaults to 0 (source-build is still the default)" \
  || bad "TORII_QUEST_ARTIFACT default is not 0"

# The source-build path is still present and intact (git clone + checkout).
grep -qF 'git clone --branch "$TORII_QUEST_REF"' "$INST" \
  && ok "source-build git clone path still present" \
  || bad "source-build git clone path removed"
grep -qF 'git -C "$SRC" reset --hard "$RESOLVED_REF"' "$INST" \
  && ok "source-build checkout/reset path intact" \
  || bad "source-build checkout/reset path altered"

# ── SB-10: artifact branch gates the build behind the flag ──────────────────
# The clone/update and the patch+build must be mutually exclusive branches on
# the flag: artifact ≠ clone, artifact ≠ patch/build.
grep -qF 'if [[ "${TORII_QUEST_ARTIFACT}" == "1" ]]; then' "$INST" \
  && ok "artifact branch exists (download + verify + extract)" \
  || bad "missing artifact branch"

# The artifact download must target the GitHub release download URL for the tag.
grep -qF 'releases/download/${TAG}' "$INST" \
  && ok "artifact downloads from the GitHub release for \${TAG}" \
  || bad "artifact download URL missing"
grep -qF 'torii-quest-${TAG}.tar.gz.sha256' "$INST" \
  && ok "artifact fetches the co-published .sha256 sidecar" \
  || bad "artifact does not fetch the .sha256 sidecar"

# Fail-closed: tag must be a v<semver> release tag (branches/SHAs have no artifact).
grep -qE 'TORII_QUEST_ARTIFACT=1 needs a v<semver> release tag' "$INST" \
  && ok "artifact path refuses non-tag refs (v<semver> gate)" \
  || bad "artifact path missing the v<semver> tag gate"

# Fail-closed: checksum verification before anything live is touched.
grep -qF 'sha256sum -c' "$INST" \
  && ok "artifact path verifies the checksum (sha256sum -c)" \
  || bad "artifact path missing checksum verification"
grep -qE 'checksum verification failed for quest artifact' "$INST" \
  && ok "checksum failure removes the cached tarball and dies" \
  || bad "checksum failure is not handled fail-closed"

# The patch (base=/quest/) + npm build must be skipped in artifact mode.
grep -qF 'if [[ "${TORII_QUEST_ARTIFACT}" != "1" ]]; then' "$INST" \
  && ok "patch/base + npm build are gated behind 'artifact != 1'" \
  || bad "patch+build are not gated behind the flag"

# ── SB-10 scope discipline: never delete the active git working tree ───────
# The artifact path must extract into a SEPARATE staging root, never remove
# .git, never `git clean` the checkout, so today's git-driven updater survives.
grep -qF 'EXTRACT_ROOT="${SUITE_WORK_DIR}/torii-quest-artifact"' "$INST" \
  && ok "artifact extracts into a separate staging root (git checkout untouched)" \
  || bad "artifact extract root is not separate from the git checkout"
if grep -qF 'rm -rf "$EXTRACT_ROOT"' "$INST" && ! grep -qF 'rm -rf "$SRC"' "$INST"; then
  ok "artifact path never removes the git working tree (.git survives)"
else
  bad "artifact path may delete the git working tree"
fi

# ── SB-10: version + provenance come from the artifact, not a live clone ────
grep -qE 'QUEST_VERSION="\$\{QUEST_VERSION#v\}"' "$INST" \
  && ok "artifact reads version from the VERSION file (strips leading v)" \
  || bad "artifact does not derive version from VERSION"
grep -qF '"commit"' "$INST" \
  && ok "artifact derives the deploy stamp from MANIFEST commit" \
  || bad "artifact does not read MANIFEST commit"

echo
echo "install-quest-sb10-artifact.test.sh: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]