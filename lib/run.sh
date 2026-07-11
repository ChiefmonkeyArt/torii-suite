#!/usr/bin/env bash
# torii-suite/lib/run.sh — quiet-by-default stage runner.
#
# `run_stage <label> <cmd> [<args>...]` runs a command with:
#   - stdout+stderr streamed to a per-install log file at $SUITE_LOG_FILE
#   - a spinner on the terminal while it runs
#   - a green ✓ + elapsed time on success
#   - a red ✗ + last 10 log lines + full log path on failure (then exit 1)
#
# Requires lib/ui.sh to be sourced first.
#
# Environment:
#   SUITE_QUIET       (default 1)   — set to 0 to stream everything to terminal
#   SUITE_LOG_FILE    (auto-derived) — override to pin log location
#
# Design notes:
#   - Uses tee to fork stdout so the file always gets the full output even when
#     the terminal is quiet.
#   - Uses a background spinner PID we kill on completion.
#   - Timing uses SECONDS (bash builtin) — no external `date` calls per stage.
#   - When SUITE_QUIET=0 (debug mode) we skip the spinner entirely and let the
#     child process's stdout stream through so operators can watch nginx/apt/npm.
#   - Ctrl-C: we set an EXIT trap that stops the spinner cleanly so a killed
#     install doesn't leave a dangling cursor-off state.

# --------------------------------------------------------------------------- #
# Log file setup                                                              #
# --------------------------------------------------------------------------- #

SUITE_QUIET="${SUITE_QUIET:-1}"

if [[ -z "${SUITE_LOG_FILE:-}" ]]; then
  SUITE_LOG_DIR="/var/log/torii-suite"
  mkdir -p "$SUITE_LOG_DIR"
  chmod 750 "$SUITE_LOG_DIR"
  SUITE_LOG_FILE="${SUITE_LOG_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  : > "$SUITE_LOG_FILE"
  chmod 640 "$SUITE_LOG_FILE"
fi
export SUITE_LOG_FILE

# --------------------------------------------------------------------------- #
# Spinner                                                                     #
# --------------------------------------------------------------------------- #

# Braille dot cascade - one continuous "orbit" that reads as motion rather
# than a spinning cursor. Ten frames give the eye enough resolution at 12fps.
_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
# If the terminal isn't UTF-8, degrade to a rotating ASCII spinner so we don't
# print mojibake.
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" != *[Uu][Tt][Ff]* ]]; then
  _SPINNER_FRAMES=("|" "/" "-" "\\")
fi

# 256-colour ramp for the spinner glyph - matches the pink/cyan wordmark
# so the whole install feels visually coherent. Cycles slower than the
# frames (one colour step per 3 glyph steps) so it reads as a subtle glow.
_SPINNER_COLORS=($'\e[38;5;201m' $'\e[38;5;207m' $'\e[38;5;213m' $'\e[38;5;219m' $'\e[38;5;159m' $'\e[38;5;123m' $'\e[38;5;87m' $'\e[38;5;51m')

_SPINNER_PID=""

_spinner_start() {
  local label="$1"
  # Hide cursor so the spinner column doesn't jitter.
  printf "\e[?25l" > /dev/tty 2>/dev/null || true
  (
    local i=0
    local fn=${#_SPINNER_FRAMES[@]}
    local cn=${#_SPINNER_COLORS[@]}
    while :; do
      local frame="${_SPINNER_FRAMES[$((i % fn))]}"
      local color="${_SPINNER_COLORS[$(( (i / 3) % cn ))]}"
      # \r rewrites the current terminal line in place. Two trailing spaces
      # prevent leftover chars if the next label is shorter.
      printf "\r  %s%s%s %s  " "$color" "$frame" "$UI_RESET" "$label" > /dev/tty 2>/dev/null || true
      sleep 0.08
      i=$((i + 1))
    done
  ) &
  _SPINNER_PID=$!
  # Silence job control chatter about the background process.
  disown "$_SPINNER_PID" 2>/dev/null || true
}

_spinner_stop() {
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
  fi
  # Clear the spinner line and show the cursor again.
  printf "\r\e[K" > /dev/tty 2>/dev/null || true
  printf "\e[?25h" > /dev/tty 2>/dev/null || true
}

# Belt-and-braces cleanup on exit or SIGINT so a killed install doesn't leave
# the terminal with cursor-off.
_ui_cleanup() { _spinner_stop; }
trap _ui_cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# run_stage                                                                   #
# --------------------------------------------------------------------------- #

# run_stage <label> <cmd> [<args>...]
#
# In quiet mode: shows a spinner, tees the child output to the log file, prints
# ✓ label (Ns) on success, ✗ label + last log lines + log path on failure.
#
# In loud mode (SUITE_QUIET=0): prints a plain header, streams everything
# through tee to both terminal and log file, no spinner.
run_stage() {
  local label="$1"; shift
  local start=$SECONDS

  # Announce to the log even in quiet mode so `tail -f $SUITE_LOG_FILE` from
  # a second SSH session shows meaningful landmarks.
  {
    printf "\n============================================================\n"
    printf "STAGE: %s\n" "$label"
    printf "CMD:   %s\n" "$*"
    printf "TIME:  %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf "============================================================\n"
  } >> "$SUITE_LOG_FILE"

  local rc=0
  if [[ "$SUITE_QUIET" == "1" ]]; then
    _spinner_start "$label"
    # Run in a subshell so `set -e` propagates cleanly. `|| rc=$?` captures the
    # failure exit code without tripping the parent's set -e.
    ( "$@" ) >> "$SUITE_LOG_FILE" 2>&1 || rc=$?
    _spinner_stop
  else
    # Loud mode: stream and log simultaneously.
    printf "\n  %s%s%s %s%s%s\n" "$UI_CYAN" "$UI_ARROW" "$UI_RESET" "$UI_BOLD" "$label" "$UI_RESET"
    ( "$@" ) 2>&1 | tee -a "$SUITE_LOG_FILE"
    rc=${PIPESTATUS[0]}
  fi

  local elapsed=$(( SECONDS - start ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  local timing
  if [[ $mins -gt 0 ]]; then
    timing="${mins}m${secs}s"
  else
    timing="${secs}s"
  fi

  if [[ $rc -eq 0 ]]; then
    printf "  %s%s%s %s %s(%s)%s\n" \
      "$UI_GREEN" "$UI_CHECK" "$UI_RESET" \
      "$label" "$UI_DIM" "$timing" "$UI_RESET"
    return 0
  fi

  # Failure path — show the last 10 log lines and the full log path so the
  # operator can debug without a second SSH session.
  printf "  %s%s%s %s %s(exit %d, %s)%s\n" \
    "$UI_RED" "$UI_CROSS" "$UI_RESET" \
    "$label" "$UI_DIM" "$rc" "$timing" "$UI_RESET" >&2
  printf "\n  %sLast 10 log lines:%s\n" "$UI_DIM" "$UI_RESET" >&2
  tail -n 10 "$SUITE_LOG_FILE" | sed 's/^/    /' >&2
  printf "\n  %sFull log: %s%s%s\n\n" "$UI_DIM" "$UI_RESET" "$SUITE_LOG_FILE" "" >&2
  exit "$rc"
}

# run_quiet — run a single command quietly, log its output, no spinner or
# stage header. Useful for preflight checks and small side-work inside stages.
# Returns the child's exit code; does NOT auto-exit.
run_quiet() {
  {
    printf "\n--- quiet: %s ---\n" "$*"
  } >> "$SUITE_LOG_FILE"
  ( "$@" ) >> "$SUITE_LOG_FILE" 2>&1
}
