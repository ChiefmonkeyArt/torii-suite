#!/usr/bin/env bash
# torii-suite/lib/ui.sh — presentation helpers for a polished install UX.
#
# Pure bash + ANSI. No dependencies. Works over SSH on any modern terminal.
# All output goes to stdout unless a helper explicitly targets /dev/tty for
# interactive prompts.
#
# Contract:
#   Callers should treat this file as a library (source it, don't exec it).
#   Every visible symbol is guarded so a caller running under `set -u` or
#   sourcing this twice does not blow up.
#
# Colour policy: honour NO_COLOR (https://no-color.org) and non-tty stdout.
# When colour is off, all colour vars expand to empty strings — the layout
# still renders correctly, just monochrome.

# --------------------------------------------------------------------------- #
# Colour + terminal detection                                                 #
# --------------------------------------------------------------------------- #

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  UI_COLOR=1
else
  UI_COLOR=0
fi

if [[ "$UI_COLOR" == "1" ]]; then
  UI_RESET=$'\e[0m'
  UI_BOLD=$'\e[1m'
  UI_DIM=$'\e[2m'
  UI_RED=$'\e[31m'
  UI_GREEN=$'\e[32m'
  UI_YELLOW=$'\e[33m'
  UI_CYAN=$'\e[36m'
  UI_GREY=$'\e[90m'
  UI_PINK=$'\e[38;5;213m'   # 256-colour hot pink (magenta accent)
  UI_CYAN2=$'\e[38;5;51m'   # bright cyan
else
  UI_RESET="" UI_BOLD="" UI_DIM=""
  UI_RED="" UI_GREEN="" UI_YELLOW=""
  UI_CYAN="" UI_GREY="" UI_PINK="" UI_CYAN2=""
fi

# Symbols — degrade to ASCII when locale isn't UTF-8, so we don't render
# mojibake on operators who ssh in with a barebones POSIX locale.
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *UTF-8* ]] || [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *utf8* ]]; then
  UI_CHECK="✓"
  UI_CROSS="✗"
  UI_WARN="⚠"
  UI_ARROW="→"
  UI_DOT="•"
  UI_TL="╭" UI_TR="╮" UI_BL="╰" UI_BR="╯" UI_H="─" UI_V="│"
  UI_TEE_L="├" UI_TEE_R="┤"
else
  UI_CHECK="OK"
  UI_CROSS="XX"
  UI_WARN="!!"
  UI_ARROW="->"
  UI_DOT="*"
  UI_TL="+" UI_TR="+" UI_BL="+" UI_BR="+" UI_H="-" UI_V="|"
  UI_TEE_L="+" UI_TEE_R="+"
fi

# Width defaults. 60 columns is narrow enough to survive a resized SSH window
# but wide enough for the summary card.
UI_WIDTH="${UI_WIDTH:-60}"

# --------------------------------------------------------------------------- #
# Logging primitives (structured, quiet by default in v0.3)                   #
# --------------------------------------------------------------------------- #

# ui_ok    <msg>  — green check
# ui_warn  <msg>  — yellow bang, still stdout (not stderr — we want in-flow)
# ui_fail  <msg>  — red cross, stderr, does NOT exit (caller decides)
# ui_step  <msg>  — dim arrow, sub-step under a stage
# ui_info  <msg>  — cyan dot
ui_ok()   { printf "  %s%s%s %s\n"  "$UI_GREEN"  "$UI_CHECK" "$UI_RESET" "$*"; }
ui_warn() { printf "  %s%s%s %s\n"  "$UI_YELLOW" "$UI_WARN"  "$UI_RESET" "$*"; }
ui_fail() { printf "  %s%s%s %s\n"  "$UI_RED"    "$UI_CROSS" "$UI_RESET" "$*" >&2; }
ui_step() { printf "  %s%s%s %s\n"  "$UI_GREY"   "$UI_ARROW" "$UI_RESET" "$*"; }
ui_info() { printf "  %s%s%s %s\n"  "$UI_CYAN"   "$UI_DOT"   "$UI_RESET" "$*"; }

# ui_die <msg> — fail + exit 1. Callers use this instead of the old die().
ui_die()  { ui_fail "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Boxes                                                                       #
# --------------------------------------------------------------------------- #

# ui_repeat <char> <count>  — echo char count times, no newline.
ui_repeat() {
  local ch="$1" n="$2" out=""
  local i
  for ((i=0; i<n; i++)); do out+="$ch"; done
  printf "%s" "$out"
}

# ui_box_top    — draw top edge of a box UI_WIDTH cols wide
# ui_box_bottom — draw bottom edge
# ui_box_line   — draw a padded line inside the box (word won't wrap, keep it short)
# ui_box_rule   — draw a horizontal rule inside the box
ui_box_top()    { printf "%s%s%s%s%s\n" "$UI_PINK" "$UI_TL" "$(ui_repeat "$UI_H" $((UI_WIDTH-2)))" "$UI_TR" "$UI_RESET"; }
ui_box_bottom() { printf "%s%s%s%s%s\n" "$UI_PINK" "$UI_BL" "$(ui_repeat "$UI_H" $((UI_WIDTH-2)))" "$UI_BR" "$UI_RESET"; }
ui_box_rule()   { printf "%s%s%s%s%s\n" "$UI_PINK" "$UI_TEE_L" "$(ui_repeat "$UI_H" $((UI_WIDTH-2)))" "$UI_TEE_R" "$UI_RESET"; }

# ui_box_line <text> — draw a text line inside a box, left-aligned with 2-col
# padding on each side. Text may contain ANSI escapes; we compute visible width
# by stripping them.
ui_box_line() {
  local text="$*"
  # Strip ANSI escapes to measure visible width.
  local visible
  visible="$(printf "%s" "$text" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
  local pad=$(( UI_WIDTH - 4 - ${#visible} ))
  [[ $pad -lt 0 ]] && pad=0
  printf "%s%s%s %s%s %s%s%s\n" \
    "$UI_PINK" "$UI_V" "$UI_RESET" \
    "$text" "$(ui_repeat " " $pad)" \
    "$UI_PINK" "$UI_V" "$UI_RESET"
}

# --------------------------------------------------------------------------- #
# Banner + stage headers                                                      #
# --------------------------------------------------------------------------- #

# ui_banner <version> — the very first thing the operator sees.
# ASCII wordmark so it works in any terminal that survives SSH. Lines are
# revealed with a subtle stagger (~35ms) unless UI_ANIM=0 or NO_COLOR is set.
ui_banner() {
  local version="${1:-}"
  local delay=0.035
  [[ "${UI_ANIM:-1}" == "0" || "$UI_COLOR" == "0" ]] && delay=0
  printf "\n"
  printf "%s  ______           _ _%s\n"    "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
  printf "%s /_  __/___  _____(_|_)%s\n"   "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
  printf "%s  / / / __ \\/ ___/ / /%s\n"    "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
  printf "%s / / / /_/ / /  / / /%s\n"     "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
  printf "%s/_/  \\____/_/  /_/_/%s\n"      "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
  printf "%s   s u i t e   %s%s%s\n"       "$UI_DIM"  "$UI_CYAN2" "${version}" "$UI_RESET"
  printf "\n"
  printf "%s one vps  ·  one clanker  ·  a gateway to a\n" "$UI_DIM"
  printf " decentralised open world of infinite possibilities%s\n" "$UI_RESET"
  printf "\n"
}

# ui_stage_banner <name> - small ASCII wordmark shown at the top of the
# named stage. Currently supports: continuum, quest. Silently no-ops for
# unknown names so callers can decorate optionally.
ui_stage_banner() {
  local name="${1:-}"
  local delay=0.025
  [[ "${UI_ANIM:-1}" == "0" || "$UI_COLOR" == "0" ]] && delay=0
  case "$name" in
    continuum)
      printf "%s  ___         _   _%s\n"                    "$UI_CYAN2" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s / __|___ _ _| |_(_)_ _ _  _ _  _ _ __%s\n"  "$UI_CYAN2" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s| (__/ _ \\ ' \\  _| | ' \\ || | || | '  \\%s\n" "$UI_CYAN2" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s \\___\\___/_||_\\__|_|_||_\\_,_|\\_,_|_|_|_|%s\n" "$UI_CYAN2" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s      an AI-powered app builder%s\n\n"       "$UI_DIM"   "$UI_RESET"
      ;;
    quest)
      printf "%s   ____                  __%s\n"             "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s  / __ \\__  _____  _____/ /_%s\n"           "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s / / / / / / / _ \\/ ___/ __/%s\n"            "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s/ /_/ / /_/ /  __(__  ) /_%s\n"               "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s\\___\\_\\__,_/\\___/____/\\__/%s\n"             "$UI_PINK" "$UI_RESET"; [[ "$delay" != "0" ]] && sleep "$delay"
      printf "%s     the federated metaverse%s\n\n"          "$UI_DIM"  "$UI_RESET"
      ;;
  esac
}

# ui_stage <n> <total> <label> — coloured stage header with progress meter.
# Draws a full-width rule above the stage, a "[3/7] ▓▓▓░░░░  Continuum" line,
# and a blank line under. Callers then emit ui_step/ui_ok inside the stage.
ui_stage() {
  local n="$1" total="$2" label="$3"
  local filled=$(( n * 20 / total ))
  local empty=$(( 20 - filled ))
  printf "\n"
  printf "%s%s%s\n" "$UI_GREY" "$(ui_repeat "$UI_H" "$UI_WIDTH")" "$UI_RESET"
  printf "  %s[%d/%d]%s  %s%s%s%s%s  %s%s%s\n" \
    "$UI_DIM" "$n" "$total" "$UI_RESET" \
    "$UI_PINK" "$(ui_repeat '█' "$filled")" "$UI_GREY" "$(ui_repeat '░' "$empty")" "$UI_RESET" \
    "$UI_BOLD" "$label" "$UI_RESET"
  printf "\n"
}

# ui_section <label> — dim rule between top-level phases (preflight / setup /
# stages / done). Lighter weight than ui_stage; no progress meter.
ui_section() {
  printf "\n%s%s  %s%s%s\n" "$UI_GREY" "$UI_H$UI_H" "$UI_BOLD" "$*" "$UI_RESET"
}

# --------------------------------------------------------------------------- #
# Animations                                                                  #
# --------------------------------------------------------------------------- #

# The stage spinner lives in lib/run.sh (see _spinner_start / _spinner_stop).
# The helpers below are for standalone flourishes: the rainbow finale line
# and the box-border pulse used by ui_pulse_box_line.

# ui_rainbow <text>  - print $text with each character mapped through a
# hot 256-colour ramp (magenta → pink → cyan → blue). Used for the finale
# line. Falls back to bold when colour is off.
ui_rainbow() {
  local text="$*"
  if [[ "$UI_COLOR" != "1" ]]; then
    printf "%s%s%s\n" "$UI_BOLD" "$text" "$UI_RESET"
    return
  fi
  local colors=(201 207 213 219 225 195 159 123 87 51 45 39)
  local n=${#colors[@]}
  local i ch
  for ((i=0; i<${#text}; i++)); do
    ch="${text:$i:1}"
    printf "\e[38;5;%sm%s" "${colors[$((i % n))]}" "$ch"
  done
  printf "%s\n" "$UI_RESET"
}


# --------------------------------------------------------------------------- #
# Prompts (interactive only — read from /dev/tty, print to /dev/tty)         #
# --------------------------------------------------------------------------- #

# ui_ask <prompt> <var> [<default>] — pretty prompt with pink caret.
ui_ask() {
  local prompt="$1" var="$2" default="${3:-}" reply
  if [[ -n "$default" ]]; then
    printf "  %s%s%s %s %s[%s]%s: " \
      "$UI_PINK" "$UI_ARROW" "$UI_RESET" "$prompt" "$UI_DIM" "$default" "$UI_RESET" > /dev/tty
  else
    printf "  %s%s%s %s: " "$UI_PINK" "$UI_ARROW" "$UI_RESET" "$prompt" > /dev/tty
  fi
  read -r reply < /dev/tty
  reply="${reply:-$default}"
  printf -v "$var" '%s' "$reply"
}

# ui_confirm <prompt>  — returns 0 on y/Y, non-zero otherwise.
ui_confirm() {
  local reply
  printf "\n  %s%s%s %s %s[y/N]%s " \
    "$UI_PINK" "$UI_ARROW" "$UI_RESET" "$*" "$UI_DIM" "$UI_RESET" > /dev/tty
  read -r reply < /dev/tty
  [[ "$reply" =~ ^[Yy]$ ]]
}
