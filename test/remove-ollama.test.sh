#!/usr/bin/env bash
# Suite ADR 0003: Ollama is optional. Checks the config flip, the default-off
# switches, and remove-ollama.sh against a fake filesystem root.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { pass=$((pass+1)); }
# shellcheck source=../lib/ollama-config.sh
source lib/ollama-config.sh
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

cat > "$t/c.yaml" <<'Y'
routstr:
  fallback:
    enabled: true
ollama:
  # Master switch.

  enabled: true
  endpoint: "http://127.0.0.1:11434"
model_router:
  enabled: true
Y
chmod 640 "$t/c.yaml"
ollama_config_set_enabled "$t/c.yaml" false || fail "flip returned $?"
grep -qx '  enabled: false' "$t/c.yaml" || fail "ollama.enabled not false"
[[ "$(grep -c 'enabled: true' "$t/c.yaml")" == 2 ]] || fail "touched another block"
[[ "$(stat -c %a "$t/c.yaml")" == 640 ]] || fail "mode changed"; ok
cp "$t/c.yaml" "$t/before"; ollama_config_set_enabled "$t/c.yaml" false
cmp -s "$t/c.yaml" "$t/before" || fail "not idempotent"; ok
ollama_config_set_enabled "$t/c.yaml" true; grep -qx '  enabled: true' <(sed -n '/^ollama:/,/^[a-z]/p' "$t/c.yaml") || fail "flip back"; ok
printf 'routstr: {}\n' > "$t/none.yaml"
set +e; ollama_config_set_enabled "$t/none.yaml" false; rc=$?; set -e
[[ $rc == 2 ]] || fail "no block should return 2, got $rc"; ok
set +e; ollama_config_set_enabled "$t/c.yaml" maybe; rc=$?; set -e
[[ $rc == 1 ]] || fail "bad value should return 1"; ok
ln -s "$t/c.yaml" "$t/link.yaml"
set +e; ollama_config_set_enabled "$t/link.yaml" false; rc=$?; set -e
[[ $rc == 2 ]] || fail "symlink must be refused"; ok

# Defaults are off.
grep -qx 'INSTALL_OLLAMA=0' .env.example || fail ".env.example default"; ok
grep -qF 'INSTALL_OLLAMA="${INSTALL_OLLAMA:-0}"' bootstrap.sh || fail "bootstrap default"; ok
grep -q 'ollama_config_set_enabled "$CONFIG_FILE" false' installers/install-continuum.sh || fail "install-continuum flip off"; ok

# remove-ollama.sh on a fake root (needs root for the EUID guard).
if [[ $EUID -eq 0 ]]; then
  r="$t/root"; mkdir -p "$r/usr/local/bin" "$r/usr/local/lib/ollama" "$r/usr/share/ollama/.ollama/models" \
    "$r/etc/systemd/system/ollama.service.d" "$t/apps/continuum/agent/repo/agent"
  : > "$r/usr/local/bin/ollama"; : > "$r/etc/systemd/system/ollama.service"
  cp "$t/before" "$t/apps/continuum/agent/repo/agent/config.yaml"
  sed -i 's/^  enabled: false/  enabled: true/' "$t/apps/continuum/agent/repo/agent/config.yaml"
  out="$(REMOVE_OLLAMA_ROOT="$r" APPS_ROOT="$t/apps" bash installers/remove-ollama.sh 2>&1)" || fail "remove: $out"
  for p in usr/local/bin/ollama usr/local/lib/ollama usr/share/ollama etc/systemd/system/ollama.service etc/systemd/system/ollama.service.d; do
    [[ ! -e "$r/$p" ]] || fail "$p left behind"
  done
  sed -n '/^ollama:/,/^[a-z]/p' "$t/apps/continuum/agent/repo/agent/config.yaml" | grep -qx '  enabled: false' || fail "config not flipped"; ok
  REMOVE_OLLAMA_ROOT="$r" APPS_ROOT="$t/apps" bash installers/remove-ollama.sh >/dev/null 2>&1 || fail "second run"; ok
else
  echo "skip: remove-ollama.sh fake-root run needs root"
fi
echo "remove-ollama: ${pass} passed"
