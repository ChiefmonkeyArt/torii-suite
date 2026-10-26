#!/usr/bin/env bash
# torii-suite/lib/quest-headers.sh — security headers for Torii Quest on nginx.
#
# Why (Quest ADR-0149, Suite v0.9.25-alpha):
#   * Quest ships a per-build Content-Security-Policy as dist/csp.nginx.conf (one
#     `add_header Content-Security-Policy "…" always;` line). Its inline-bootstrap hash
#     changes EVERY build, so nginx must take the policy from the installed release
#     and reload on each deploy (install-quest.sh already ends with `torii reload`).
#   * nginx drops server-level add_header directives in any location that declares
#     its own. Quest's nested locations (index.html, assets, worlds) set Cache-Control,
#     so they silently lost torii-base's four security headers. We re-declare them.
#
# Two snippets, written to a STABLE path outside the release tree (so nginx -t never
# depends on what a release ships, and an older Quest without the file still loads):
#   quest-security.inc — the four torii-base headers (every nested Quest location)
#   quest-csp.inc      — the validated CSP line (the game document only); a comment
#                        when the release has no policy or QUEST_CSP_ENFORCE=0
#
# The CSP line is validated, never trusted: exactly one
#   add_header Content-Security-Policy "<value>" always;
# where <value> uses only CSP-safe characters (no quote, $, backslash, braces, `#`,
# newline), contains script-src and object-src 'none', and is ≤ 4096 chars. Anything
# else → no CSP (logged) rather than an nginx-injection or a broken config.

QUEST_HEADERS_DIR_DEFAULT="/opt/torii/nginx-snippets"

quest_security_headers() {
  cat <<'NGINX'
# written by torii-suite (lib/quest-headers.sh) — torii-base's server-level headers,
# re-declared because a location with its own add_header drops them.
add_header X-Frame-Options        "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy        "strict-origin-when-cross-origin" always;
add_header Permissions-Policy     "geolocation=(), microphone=(), camera=()" always;
NGINX
}

# quest_csp_line <csp.nginx.conf> → prints the validated add_header line, or nothing
# (return 1) when the file is missing/invalid.
quest_csp_line() {
  local f="$1" lines line value
  [[ -f "$f" ]] || return 1
  # Every non-comment, non-blank line must be THE add_header line (exactly one).
  lines="$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)"
  [[ -n "$lines" ]] || return 1
  [[ "$(printf '%s\n' "$lines" | wc -l)" -eq 1 ]] || return 1
  line="$lines"
  [[ "$line" =~ ^add_header\ Content-Security-Policy\ \"([A-Za-z0-9\ \;:/\'+=._*-]+)\"\ always\;$ ]] || return 1
  value="${BASH_REMATCH[1]}"
  (( ${#value} <= 4096 )) || return 1
  [[ "$value" == *"script-src "* && "$value" == *"object-src 'none'"* ]] || return 1
  printf '%s\n' "$line"
}

# write_quest_header_snippets <release_dir> [<dir>] — idempotent; prints a status word:
#   csp-enforced | csp-off | csp-missing
write_quest_header_snippets() {
  local release="$1" dir="${2:-$QUEST_HEADERS_DIR_DEFAULT}" csp status
  mkdir -p "$dir"
  quest_security_headers > "${dir}/quest-security.inc.tmp"
  mv -f "${dir}/quest-security.inc.tmp" "${dir}/quest-security.inc"
  if [[ "${QUEST_CSP_ENFORCE:-1}" == "0" ]]; then
    printf '# QUEST_CSP_ENFORCE=0 — Content-Security-Policy not sent (operator choice)\n' > "${dir}/quest-csp.inc.tmp"
    status="csp-off"
  elif csp="$(quest_csp_line "${release}/csp.nginx.conf")"; then
    { printf '# written by torii-suite from %s/csp.nginx.conf (validated)\n' "$release"; printf '%s\n' "$csp"; } > "${dir}/quest-csp.inc.tmp"
    status="csp-enforced"
  else
    printf '# no valid csp.nginx.conf in the installed Quest release — CSP not sent\n' > "${dir}/quest-csp.inc.tmp"
    status="csp-missing"
  fi
  mv -f "${dir}/quest-csp.inc.tmp" "${dir}/quest-csp.inc"
  chmod 644 "${dir}/quest-security.inc" "${dir}/quest-csp.inc"
  printf '%s\n' "$status"
}
