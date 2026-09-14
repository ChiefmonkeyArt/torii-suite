#!/usr/bin/env bash
# Static SB-16 assertions for installers/install-continuum.sh and
# installers/install-ollama.sh: the Ollama model-pull stanza must respect the
# local/remote install-mode gate, so a remote-mode redeploy never drags a local
# model into the box (the daemon-install path already refuses on
# OLLAMA_MODE=remote, but the re-pull stanza did not).
#
# Run:  bash test/install-continuum-sb16.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
INST="${REPO_ROOT}/installers/install-continuum.sh"
OLLAMA_INST="${REPO_ROOT}/installers/install-ollama.sh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

for f in "$INST" "$OLLAMA_INST"; do
  [[ -f "$f" ]] || { bad "missing $f"; exit 1; }
  bash -n "$f" && ok "$(basename "$f") parses cleanly" || bad "$(basename "$f") failed bash -n"
done

# ── SB-16: model pull must be gated on OLLAMA_MODE != remote ────────────────
# The remote-mode guard must appear before the model-pull precondition that
# would otherwise pull a model whenever the ollama CLI + endpoint are reachable.
remote_guard="$(grep -nF 'if [[ "${OLLAMA_MODE:-local}" == "remote" ]]; then' "$INST" | head -1 | cut -d: -f1)"
pull_gate="$(grep -nF '_effective_ollama_models="${OLLAMA_MODELS:-' "$INST" | head -1 | cut -d: -f1)"
ollama_cli_gate="$(grep -nF 'command -v /usr/local/bin/ollama' "$INST" | head -1 | cut -d: -f1)"

[[ -n "$remote_guard" ]] \
  && ok "install-continuum.sh has an explicit OLLAMA_MODE=remote guard" \
  || bad "missing OLLAMA_MODE=remote guard in install-continuum.sh"
[[ -n "$remote_guard" && -n "$ollama_cli_gate" && "$remote_guard" -lt "$ollama_cli_gate" ]] \
  && ok "remote-mode guard precedes the ollama-CLI pull gate (guard=$remote_guard cli=$ollama_cli_gate)" \
  || bad "remote-mode guard does not precede the pull gate (guard=$remote_guard cli=$ollama_cli_gate)"
# In remote mode _effective_ollama_models is cleared, so the pull never runs.
grep -qF '_effective_ollama_models=""' "$INST" \
  && ok "remote mode clears _effective_ollama_models (pull is skipped)" \
  || bad "remote mode does not clear _effective_ollama_models"

# install-ollama.sh must still refuse a local daemon install under remote mode.
grep -qF 'OLLAMA_MODE=remote is set — not installing a local Ollama daemon' "$OLLAMA_INST" \
  && ok "install-ollama.sh still refuses a local daemon under OLLAMA_MODE=remote" \
  || bad "install-ollama.sh lost its remote-mode daemon refusal"

# The owner vs NPC model divergence must be documented as intentional, not drift.
grep -qF 'two-voice boundary' "$OLLAMA_INST" \
  && ok "owner(qwen3)/NPC(llama3.2) divergence documented as intentional two-voice boundary" \
  || bad "owner/NPC model divergence no longer documented as intentional"

echo
echo "install-continuum-sb16.test.sh: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]