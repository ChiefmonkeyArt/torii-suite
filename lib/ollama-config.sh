# shellcheck shell=bash
# Set `ollama.enabled` in a Continuum agent config.yaml (Suite ADR 0003).
# Touches only the top-level `ollama:` block. Returns 0 when set (or already
# set), 2 when the file has no ollama block, 1 on error.
ollama_config_set_enabled() {
  local file="$1" value="$2"
  [[ "$value" == true || "$value" == false ]] || return 1
  [[ -f "$file" && ! -L "$file" ]] || return 2
  local owner
  owner="$(stat -c %U "$file")"
  local -a as=()
  [[ "$owner" == "$(id -un)" ]] || as=(sudo -u "$owner" -H)
  "${as[@]}" env OLLAMA_ENABLED="$value" python3 - "$file" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
value = os.environ["OLLAMA_ENABLED"]
new, n = re.subn(r"(^ollama:\s*\n(?:[ \t]+.*\n|[ \t]*\n)*?[ \t]+enabled:\s*)(?:true|false)\b",
                 lambda m: m.group(1) + value, text, count=1, flags=re.M)
if n == 0:
    sys.exit(2)
if new != text:
    path.write_text(new)
PY
}
