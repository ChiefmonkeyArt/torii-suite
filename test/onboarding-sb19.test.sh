#!/usr/bin/env bash
# Static SB-19 assertions for onboarding/prototype.html: the SHC account
# password must never be derived from the public npub, and the resume path must
# persist only the short-lived operate-scoped apiKey (never the durable
# password). Run:  bash test/onboarding-sb19.test.sh   (from repo root)

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
HTML="${REPO_ROOT}/onboarding/prototype.html"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

[[ -f "$HTML" ]] || { bad "missing $HTML"; exit 1; }

# The inline module script must still parse (node --check when node is present).
if command -v node >/dev/null 2>&1; then
  if node -e '
    const fs=require("fs");
    const h=fs.readFileSync(process.argv[1],"utf8");
    const m=h.match(/<script type="module">([\s\S]*?)<\/script>/);
    if(!m){console.error("no module script");process.exit(1)}
    fs.writeFileSync("/tmp/sb19-check.mjs", m[1]);
  ' "$HTML" && node --check /tmp/sb19-check.mjs 2>/dev/null; then
    ok "prototype.html module script parses"
  else
    bad "prototype.html module script fails to parse"
  fi
else
  ok "node absent — skipping parse check"
fi

# ── SB-19: password is RANDOM, never npub-derived ───────────────────────────
# The old public→secret derivation (npub hex + fixed suffix) must be gone.
if grep -qE 'npubHex\.slice\(0, ?32\)' "$HTML"; then
  bad "password still derived from npubHex.slice(0, 32)"
else
  ok "no npub-derived password (npubHex.slice(0,32) absent)"
fi
grep -qF 'function randomPassword()' "$HTML" \
  && ok "randomPassword() helper present" \
  || bad "randomPassword() helper missing"
grep -qF 'crypto.getRandomValues(new Uint8Array(32))' "$HTML" \
  && ok "randomPassword uses crypto.getRandomValues (32 bytes)" \
  || bad "randomPassword does not use crypto.getRandomValues"

# ── SB-19: resume persists the apiKey, NOT the password ────────────────────
grep -qF 'SHC_LS_PREFIX = "torii-shc-"' "$HTML" \
  && ok "localStorage key is namespaced (torii-shc- prefix)" \
  || bad "localStorage key missing namespace"
grep -qF 'localStorage.setItem(SHC_LS_PREFIX' "$HTML" \
  && ok "saveShc writes to localStorage" \
  || bad "saveShc does not write to localStorage"
grep -qF 'JSON.stringify({ email, apiKey, expiresAt })' "$HTML" \
  && ok "persisted payload is email + apiKey + expiresAt only" \
  || bad "persisted payload includes unexpected fields (or is missing)"
if grep -qF 'saveShc(' "$HTML" && ! grep -qE 'saveShc\([^)]*password' "$HTML"; then
  ok "saveShc call site never passes the password"
else
  bad "saveShc call site may pass the password"
fi

# ── SB-19: expired tokens are refused (fail back to register) ──────────────
grep -qF 'Date.parse(saved.expiresAt) <= Date.now()' "$HTML" \
  && ok "loadSavedShc rejects an expired apiKey" \
  || bad "loadSavedShc does not check token expiry"

# ── SB-19: resume restores the session and skips register ──────────────────
grep -qF 'shc.setCredentials({ email: saved.email, apiKey: saved.apiKey })' "$HTML" \
  && ok "resume restores the session via setCredentials" \
  || bad "resume does not call setCredentials"
grep -qF 'const saved = !shc.getSession() ? loadSavedShc(state.npubHex) : null;' "$HTML" \
  && ok "resume only when there is no live session" \
  || bad "resume lookup is not gated on getSession()"
grep -qF 'state.shcPassword = state.shcPassword || randomPassword();' "$HTML" \
  && ok "random password minted only inside the register branch" \
  || bad "random password not gated inside the register branch"

echo
echo "onboarding-sb19.test.sh: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]