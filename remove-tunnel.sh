#!/usr/bin/env bash
#
# Fully removes the SSH tunnel and temporary proxy settings created by
# install-hestia-via-tunnel.sh. Run this on the Iran server as root once
# you've confirmed the HestiaCP install is working:
#   bash <(curl -fsSL https://raw.githubusercontent.com/persiato/HestiaCP-via-SSH/main/remove-tunnel.sh)
#
set -euo pipefail

PID_FILE="/var/run/hestia-ssh-tunnel.pid"
APT_PROXY_FILE="/etc/apt/apt.conf.d/95-hestia-tunnel-proxy"
PRIVOXY_CONFIG="/etc/privoxy/config"
MARK_START="# >>> hestia-tunnel-proxy >>>"
MARK_END="# <<< hestia-tunnel-proxy <<<"

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$1"; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

# ---------- 1) Stop the SSH tunnel ----------
if [[ -f "$PID_FILE" ]]; then
  TUNNEL_PID="$(cat "$PID_FILE")"
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID"
    log "SSH tunnel (PID $TUNNEL_PID) stopped."
  fi
  rm -f "$PID_FILE"
else
  # no PID file: find and stop any leftover tunnel process
  pkill -f "ssh -N -D 127.0.0.1:" 2>/dev/null && log "Leftover SSH tunnel(s) stopped." || true
fi

# ---------- 2) Remove the apt proxy config ----------
if [[ -f "$APT_PROXY_FILE" ]]; then
  rm -f "$APT_PROXY_FILE"
  log "apt proxy config removed."
fi

# ---------- 3) Remove privoxy config changes and the package itself ----------
if [[ -f "$PRIVOXY_CONFIG" ]] && grep -q "$MARK_START" "$PRIVOXY_CONFIG"; then
  sed -i "/${MARK_START}/,/${MARK_END}/d" "$PRIVOXY_CONFIG"
  log "Removed the block added to privoxy's config."
fi

if dpkg -l privoxy >/dev/null 2>&1; then
  systemctl stop privoxy 2>/dev/null || true
  apt-get purge -y privoxy >/dev/null 2>&1 || true
  log "privoxy package removed."
fi

log "Cleanup complete. The server no longer uses the tunnel or the temporary proxy."
