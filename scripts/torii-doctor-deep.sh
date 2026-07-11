#!/usr/bin/env bash
# torii-doctor-deep.sh - one-shot diagnostic dump for a live Torii Suite install.
#
# Run as root on the VPS:
#   curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/main/torii-doctor-deep.sh | sudo bash
# or:
#   sudo bash torii-doctor-deep.sh
#
# Writes everything to /tmp/torii-doctor-<timestamp>.txt and prints the path
# at the end. Read-only - never mutates anything.

set -u  # not -e; keep going even if a probe fails

OUT="/tmp/torii-doctor-$(date -u +%Y%m%dT%H%M%SZ).txt"
: > "$OUT"

hr() { printf '\n==================== %s ====================\n' "$*" >> "$OUT"; }
run() {
  local label="$1"; shift
  printf '\n-- %s --\n' "$label" >> "$OUT"
  printf '$ %s\n' "$*" >> "$OUT"
  "$@" >> "$OUT" 2>&1 || printf '(exit %d)\n' "$?" >> "$OUT"
}

hr "META"
run "date"              date -u
run "hostname"          hostname
run "uname"             uname -a
run "os-release"        cat /etc/os-release
run "ip addr"           ip -4 addr show scope global

hr "TORII BASE (host layer)"
run "torii-base version"        cat /opt/torii/VERSION 2>/dev/null
run "sidecar status"            systemctl status torii-sidecar.service --no-pager -l
run "sidecar last 40 log lines" journalctl -u torii-sidecar.service -n 40 --no-pager
run "sidecar port"              ss -tlnp | grep -E ':(3100|3101|9090)' 2>/dev/null
run "torii CLI"                 which torii
run "torii status"              /usr/local/bin/torii status 2>&1
run "torii apps"                /usr/local/bin/torii list 2>&1
run "nginx fragments dir"       ls -la /opt/torii/nginx-fragments/
run "nginx apps.json"           cat /opt/torii/apps.json 2>/dev/null

hr "NGINX"
run "nginx version"     nginx -v
run "nginx test"        nginx -t
run "nginx sites-enabled" ls -la /etc/nginx/sites-enabled/
run "torii.conf"        cat /etc/nginx/sites-enabled/torii.conf 2>/dev/null || cat /etc/nginx/sites-available/torii.conf 2>/dev/null
run "nginx access log (last 30)" tail -n 30 /var/log/nginx/access.log
run "nginx error log (last 30)" tail -n 30 /var/log/nginx/error.log

hr "CONTINUUM"
run "continuum agent status"       systemctl status torii-continuum-agent.service --no-pager -l
run "continuum agent last 50"      journalctl -u torii-continuum-agent.service -n 50 --no-pager
run "continuum VERSION"            cat /opt/torii-continuum/VERSION 2>/dev/null
run "continuum root ls"            ls -la /opt/torii-continuum/
run "continuum dist ls"            ls -la /opt/torii-continuum/dist/ 2>&1
run "continuum dist index.html"    head -20 /opt/torii-continuum/dist/index.html 2>&1
run "continuum dist assets"        ls -la /opt/torii-continuum/dist/assets/ 2>&1 | head -15
run "continuum agent port"         ss -tlnp | grep -E ':(3000|8080)'
run "GET /api/health (loopback)"   curl -sv http://127.0.0.1:3000/api/health 2>&1 | head -25
run "GET /continuum/ (loopback)"   curl -sv http://127.0.0.1/continuum/ 2>&1 | head -30
run "GET /continuum/ (public)"     curl -sv https://$(hostname -f 2>/dev/null || hostname)/continuum/ 2>&1 | head -30
run "GET /continuum/ body head"    curl -sSL https://$(hostname -f 2>/dev/null || hostname)/continuum/ 2>&1 | head -60
run "GET /agent/health (public)"   curl -sv https://$(hostname -f 2>/dev/null || hostname)/agent/api/health 2>&1 | head -25

hr "QUEST"
run "quest static ls"          ls -la /opt/torii-quest/
run "quest VERSION"            cat /opt/torii-quest/VERSION 2>/dev/null
run "quest dist ls"            ls -la /opt/torii-quest/dist/ 2>&1
run "quest arena-ws status"    systemctl status torii-arena-ws.service --no-pager -l
run "quest arena-ws last 60"   journalctl -u torii-arena-ws.service -n 60 --no-pager
run "quest arena-ws port"      ss -tlnp | grep -E ':(8788|8789)'
run "GET /mp (loopback ws)"    curl -sv --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:8788/mp 2>&1 | head -20
run "GET /mp (public wss)"     curl -sv --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' https://$(hostname -f 2>/dev/null || hostname)/mp 2>&1 | head -20
run "quest version endpoint"   curl -sv https://$(hostname -f 2>/dev/null || hostname)/quest/version.json 2>&1 | head -20

hr "OLLAMA"
run "ollama service"    systemctl status ollama.service --no-pager -l | head -20
run "ollama port"       ss -tlnp | grep -E ':11434'
run "ollama tags"       curl -sf http://127.0.0.1:11434/api/tags 2>&1 | head -20

hr "SYSTEMD-WIDE"
run "all torii units"           systemctl list-units --type=service 'torii*' --no-pager --all
run "failed units (any)"        systemctl --failed --no-pager

hr "RECENT INSTALL LOG"
LATEST_LOG=$(ls -1t /var/log/torii-suite/install-*.log 2>/dev/null | head -1)
if [[ -n "$LATEST_LOG" ]]; then
  printf '\n-- last install log: %s --\n' "$LATEST_LOG" >> "$OUT"
  tail -n 200 "$LATEST_LOG" >> "$OUT"
fi

hr "DONE"
echo "" >> "$OUT"
echo "Report written to: $OUT" | tee -a "$OUT"
echo "Copy the file back with:  scp ubuntu@YOUR_VPS:$OUT ./"  | tee -a "$OUT"
echo ""
echo "==============================================="
echo "  Report saved to: $OUT"
echo "  Size: $(wc -c < "$OUT") bytes"
echo "==============================================="
