#!/usr/bin/env bash
# torii-suite/installers/bench-gliclass.sh — measure GLiClass Edge on this
# server's CPU (Suite ADR 0004). Needs installers/install-gliclass.sh first.
#
# Runs the self-test, then the OpenSystem1-classifier sets (12 obvious
# questions, 30 tool-routing cases) and compares each pick with Jev 1.13's
# recorded answers. Sandboxed: a throwaway user, no network, read-only system,
# capped memory. Prints the summary; keeps the full JSON in
# /var/lib/gliclass-edge/bench-<UTC time>.json.
#
# Env: GLICLASS_ROOT (default /opt/gliclass-edge), GLICLASS_THREADS (default:
# every core), GLICLASS_MEMORY_MAX (default 3G).
set -euo pipefail
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mxx  bench-gliclass: %s\033[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "requires root"
export ORT_DISABLE_TELEMETRY=1  # guard; the pinned onnxruntime has no telemetry
GL_ROOT="${GLICLASS_ROOT:-/opt/gliclass-edge}"
[[ -x "${GL_ROOT}/venv/bin/python" && -f "${GL_ROOT}/model/model.onnx" && -d "${GL_ROOT}/bench" ]] \
  || die "GLiClass Edge is not installed in ${GL_ROOT} (run the gliclass stage first)"
threads="${GLICLASS_THREADS:-}"
[[ -z "$threads" || "$threads" =~ ^[1-9][0-9]?$ ]] || die "GLICLASS_THREADS must be a small number"
mem="${GLICLASS_MEMORY_MAX:-3G}"
[[ "$mem" =~ ^[1-9][0-9]*[MG]$ ]] || die "GLICLASS_MEMORY_MAX looks wrong (e.g. 3G)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="/var/lib/gliclass-edge/bench-${stamp}.json"

log "CPU: $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo), $(nproc) cores; memory free $(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo) MB"
log "model on disk: $(du -sm "${GL_ROOT}" | cut -f1) MB in ${GL_ROOT}"
py=("${GL_ROOT}/venv/bin/python" "${GL_ROOT}/gliclass_edge.py")
args=(bench "${GL_ROOT}/model" "${GL_ROOT}/bench")
[[ -n "$threads" ]] && args+=(--threads "$threads")
if systemd-run --quiet --wait --collect -p DynamicUser=yes true 2>/dev/null; then
  # Throwaway user, no network, read-only system, capped memory.
  sandbox=(systemd-run --quiet --wait --pipe --collect --service-type=exec
    -p DynamicUser=yes -p PrivateNetwork=yes -p ProtectSystem=strict -p ProtectHome=yes
    -p PrivateTmp=yes -p NoNewPrivileges=yes -p ProtectKernelTunables=yes -p ProtectControlGroups=yes
    -p RestrictAddressFamilies=AF_UNIX -p StateDirectory=gliclass-edge -p MemoryMax="$mem"
    -p "ReadOnlyPaths=${GL_ROOT}" -p Nice=10 -E ORT_DISABLE_TELEMETRY=1)
  "${sandbox[@]}" "${py[@]}" selftest "${GL_ROOT}/model" || die "self-test failed"
  "${sandbox[@]}" "${py[@]}" "${args[@]}" --json "$out" || die "benchmark failed"
else
  # No usable systemd (containers): user nobody, no network namespace access.
  log "systemd-run unavailable; using unshare + setpriv (no network, user nobody)"
  tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
  chown 65534:65534 "$tmp"
  sandbox=(unshare --net -- setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs --)
  "${sandbox[@]}" "${py[@]}" selftest "${GL_ROOT}/model" || die "self-test failed"
  "${sandbox[@]}" "${py[@]}" "${args[@]}" --json "$tmp/r.json" || die "benchmark failed"
  install -d -m 0755 /var/lib/gliclass-edge
  install -m 0644 "$tmp/r.json" "$out"
fi
log "full results: ${out}"
