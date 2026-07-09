#!/usr/bin/env bash
#
# Install HestiaCP on an Iran-based server by tunneling all install
# traffic through an SSH SOCKS5 tunnel to a foreign relay server.
# ------------------------------------------------------------------
# How it works:
#   1) An SSH dynamic port forward (SOCKS5) is opened from this server
#      to a foreign (non-Iran) relay server.
#   2) privoxy converts that SOCKS5 tunnel into a local HTTP proxy
#      (apt-get does not support SOCKS5 proxies directly).
#   3) apt / curl / wget use that local HTTP proxy to install HestiaCP
#      from GitHub and its own repositories.
#
# Usage:
#   Run this directly on the Iran server as root:
#     bash <(curl -fsSL https://raw.githubusercontent.com/persiato/HestiaCP-via-SSH/main/install-hestia-via-tunnel.sh)
#   It will prompt for the relay server's address, port, user and
#   password. After the install is confirmed working, run
#   remove-tunnel.sh to tear down the tunnel and temporary proxy.
#
set -euo pipefail

SOCKS_PORT="1080"   # local SOCKS5 port
PROXY_PORT="8118"   # local HTTP proxy port (privoxy)

PID_FILE="/var/run/hestia-ssh-tunnel.pid"
APT_PROXY_FILE="/etc/apt/apt.conf.d/95-hestia-tunnel-proxy"
PRIVOXY_CONFIG="/etc/privoxy/config"
MARK_START="# >>> hestia-tunnel-proxy >>>"
MARK_END="# <<< hestia-tunnel-proxy <<<"

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$1"; }
err() { printf '\n\033[1;31m[!] %s\033[0m\n' "$1" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (sudo)."
  exit 1
fi

# ---------- 0) Collect input ----------
echo "Details of the foreign (non-Iran) relay server the SSH tunnel connects to:"

RELAY_HOST=""
until [[ -n "$RELAY_HOST" ]]; do
  read -rp "Relay server IP or domain: " RELAY_HOST
done

read -rp "Relay SSH port [22]: " RELAY_PORT
RELAY_PORT="${RELAY_PORT:-22}"

read -rp "Relay SSH user [root]: " RELAY_USER
RELAY_USER="${RELAY_USER:-root}"

read -rsp "Relay SSH password: " RELAY_SSH_PASSWORD
echo ""

echo ""
echo "HestiaCP install parameters (optional, press Enter to let the installer ask interactively):"
read -rp "Panel hostname (e.g. panel.example.com): " HESTIA_HOSTNAME
read -rp "Panel admin email: " HESTIA_EMAIL

if ! command -v sshpass >/dev/null 2>&1; then
  log "Installing sshpass for password-based SSH ..."
  apt-get update -qq
  apt-get install -y sshpass >/dev/null
fi

# ---------- 1) Open the SOCKS5 tunnel to the relay server ----------
log "Opening SSH tunnel to $RELAY_USER@$RELAY_HOST:$RELAY_PORT ..."

export SSHPASS="$RELAY_SSH_PASSWORD"
sshpass -e ssh -N -D "127.0.0.1:${SOCKS_PORT}" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -p "$RELAY_PORT" \
    "${RELAY_USER}@${RELAY_HOST}" &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$PID_FILE"
unset SSHPASS RELAY_SSH_PASSWORD

# wait for the SOCKS port to come up
for i in $(seq 1 15); do
  if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/${SOCKS_PORT}" 2>/dev/null; then
    break
  fi
  if [[ "$i" -eq 15 ]]; then
    err "SSH tunnel did not come up. Check connectivity to the relay server."
    kill "$TUNNEL_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 1
  fi
  sleep 1
done
log "Tunnel is up (PID: $TUNNEL_PID), SOCKS5 on 127.0.0.1:${SOCKS_PORT}"

# ---------- 2) Install and configure privoxy (SOCKS5 -> HTTP) ----------
log "Installing privoxy ..."
apt-get update -qq
apt-get install -y privoxy >/dev/null

if ! grep -q "$MARK_START" "$PRIVOXY_CONFIG" 2>/dev/null; then
  # Remove any pre-existing listen-address line first: privoxy's default
  # config already binds 127.0.0.1:8118, and a duplicate directive makes
  # the service fail to start (address already in use).
  sed -i '/^[[:space:]]*listen-address/d' "$PRIVOXY_CONFIG"
  {
    echo ""
    echo "$MARK_START"
    echo "listen-address 127.0.0.1:${PROXY_PORT}"
    # forward-socks5t also resolves DNS through the tunnel, to avoid DNS-based filtering
    echo "forward-socks5t / 127.0.0.1:${SOCKS_PORT} ."
    echo "$MARK_END"
  } >> "$PRIVOXY_CONFIG"
fi

systemctl restart privoxy
sleep 1
if ! systemctl is-active --quiet privoxy; then
  err "privoxy failed to start. Check: journalctl -u privoxy"
  exit 1
fi
log "privoxy is active on 127.0.0.1:${PROXY_PORT}"

# ---------- 3) Test connectivity through the proxy ----------
log "Testing access to GitHub through the tunnel ..."
if ! curl -x "http://127.0.0.1:${PROXY_PORT}" -sSf --max-time 15 -o /dev/null \
     https://raw.githubusercontent.com; then
  err "Could not reach the internet through the tunnel. Check the relay server."
  exit 1
fi
log "Tunnel connectivity looks good."

# ---------- 4) Configure the apt proxy and environment variables ----------
cat > "$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy "http://127.0.0.1:${PROXY_PORT}/";
Acquire::https::Proxy "http://127.0.0.1:${PROXY_PORT}/";
EOF

export http_proxy="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

# ---------- 5) Download and run the HestiaCP installer ----------
log "Downloading the HestiaCP installer ..."
cd /root
curl -x "http://127.0.0.1:${PROXY_PORT}" -fsSL \
  -o hst-install.sh \
  https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh
chmod +x hst-install.sh

log "Running the HestiaCP installer (this takes several minutes) ..."
HESTIA_ARGS=()
[[ -n "$HESTIA_HOSTNAME" ]] && HESTIA_ARGS+=(--hostname "$HESTIA_HOSTNAME")
[[ -n "$HESTIA_EMAIL" ]] && HESTIA_ARGS+=(--email "$HESTIA_EMAIL")

./hst-install.sh "${HESTIA_ARGS[@]}"

log "HestiaCP install finished."
echo ""
echo "Note: the SSH tunnel and proxy settings are still active (kept for install stability)."
echo "Once you've confirmed the panel works, run remove-tunnel.sh to fully clean them up."
