#!/usr/bin/env bash
#
# نصب HestiaCP روی سرور ایران با عبور از فیلترینگ از طریق تانل SSH
# ------------------------------------------------------------------
# نحوه کار:
#   1) یک تانل SSH با پورت‌فورواردینگ داینامیک (SOCKS5) از این سرور
#      به یک سرور خارج از ایران (relay) برقرار می‌شود.
#   2) با privoxy، آن SOCKS5 به یک پروکسی HTTP محلی تبدیل می‌شود
#      (چون apt-get از SOCKS5 پشتیبانی نمی‌کند).
#   3) apt / curl / wget / git با استفاده از همین پروکسی محلی اجرا
#      می‌شوند تا نصب HestiaCP از گیت‌هاب و مخازن آن انجام شود.
#
# نحوه اجرا:
#   1) این فایل را روی سرور ایران کپی کنید و با روت اجرا کنید:
#        chmod +x install-hestia-via-tunnel.sh
#        ./install-hestia-via-tunnel.sh
#   2) اسکریپت مقادیر لازم (اطلاعات سرور خارج و ...) را در ترمینال می‌پرسد.
#   3) بعد از اطمینان از سالم بودن نصب، اسکریپت remove-tunnel.sh را
#      اجرا کنید تا تانل و تنظیمات موقت پاک شوند.
#
set -euo pipefail

SOCKS_PORT="1080"                     # پورت لوکال SOCKS5
PROXY_PORT="8118"                     # پورت لوکال HTTP (privoxy)

PID_FILE="/var/run/hestia-ssh-tunnel.pid"
APT_PROXY_FILE="/etc/apt/apt.conf.d/95-hestia-tunnel-proxy"
PRIVOXY_CONFIG="/etc/privoxy/config"
MARK_START="# >>> hestia-tunnel-proxy >>>"
MARK_END="# <<< hestia-tunnel-proxy <<<"

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$1"; }
err() { printf '\n\033[1;31m[!] %s\033[0m\n' "$1" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "این اسکریپت باید با روت اجرا شود (sudo)."
  exit 1
fi

# ---------- 0) دریافت اطلاعات از کاربر ----------
echo "اطلاعات سرور خارج (relay) که تانل SSH از طریق آن برقرار می‌شود:"

RELAY_HOST=""
until [[ -n "$RELAY_HOST" ]]; do
  read -rp "آدرس IP یا دامنه سرور خارج: " RELAY_HOST
done

read -rp "پورت SSH سرور خارج [22]: " RELAY_PORT
RELAY_PORT="${RELAY_PORT:-22}"

read -rp "یوزر SSH سرور خارج [root]: " RELAY_USER
RELAY_USER="${RELAY_USER:-root}"

read -rp "مسیر کلید خصوصی SSH [/root/.ssh/id_rsa]: " RELAY_SSH_KEY
RELAY_SSH_KEY="${RELAY_SSH_KEY:-/root/.ssh/id_rsa}"

echo ""
echo "پارامترهای نصب HestiaCP (اختیاری، Enter بزنید تا نصب تعاملی بپرسد):"
read -rp "هاست‌نیم پنل (مثلا panel.example.com): " HESTIA_HOSTNAME
read -rp "ایمیل ادمین پنل: " HESTIA_EMAIL

if [[ ! -f "$RELAY_SSH_KEY" ]]; then
  err "کلید SSH پیدا نشد: $RELAY_SSH_KEY"
  exit 1
fi

# ---------- 1) برقراری تانل SOCKS5 به سرور خارج ----------
log "برقراری تانل SSH به $RELAY_USER@$RELAY_HOST:$RELAY_PORT ..."

ssh -N -D "127.0.0.1:${SOCKS_PORT}" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -i "$RELAY_SSH_KEY" \
    -p "$RELAY_PORT" \
    "${RELAY_USER}@${RELAY_HOST}" &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$PID_FILE"

# صبر برای بالا آمدن پورت SOCKS
for i in $(seq 1 15); do
  if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/${SOCKS_PORT}" 2>/dev/null; then
    break
  fi
  if [[ "$i" -eq 15 ]]; then
    err "تانل SSH برقرار نشد. اتصال به سرور خارج را بررسی کنید."
    kill "$TUNNEL_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 1
  fi
  sleep 1
done
log "تانل برقرار شد (PID: $TUNNEL_PID)، پورت SOCKS5: 127.0.0.1:${SOCKS_PORT}"

# ---------- 2) نصب و تنظیم privoxy برای تبدیل SOCKS5 به HTTP ----------
log "نصب privoxy ..."
apt-get update -qq
apt-get install -y privoxy >/dev/null

if ! grep -q "$MARK_START" "$PRIVOXY_CONFIG" 2>/dev/null; then
  {
    echo ""
    echo "$MARK_START"
    echo "listen-address 127.0.0.1:${PROXY_PORT}"
    # forward-socks5t: رزولوشن DNS هم از طریق تانل انجام می‌شود تا فیلترینگ DNS دور زده شود
    echo "forward-socks5t / 127.0.0.1:${SOCKS_PORT} ."
    echo "$MARK_END"
  } >> "$PRIVOXY_CONFIG"
fi

systemctl restart privoxy
sleep 1
if ! systemctl is-active --quiet privoxy; then
  err "privoxy بالا نیامد. لاگ آن را با journalctl -u privoxy بررسی کنید."
  exit 1
fi
log "privoxy روی 127.0.0.1:${PROXY_PORT} فعال شد."

# ---------- 3) تست اتصال از طریق پروکسی ----------
log "تست دسترسی به GitHub از طریق تانل ..."
if ! curl -x "http://127.0.0.1:${PROXY_PORT}" -sSf --max-time 15 -o /dev/null \
     https://raw.githubusercontent.com; then
  err "دسترسی از طریق تانل موفق نبود. تنظیمات سرور خارج را بررسی کنید."
  exit 1
fi
log "اتصال از طریق تانل سالم است."

# ---------- 4) تنظیم پروکسی برای apt و متغیرهای محیطی ----------
cat > "$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy "http://127.0.0.1:${PROXY_PORT}/";
Acquire::https::Proxy "http://127.0.0.1:${PROXY_PORT}/";
EOF

export http_proxy="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

# ---------- 5) دانلود و اجرای نصب‌کننده HestiaCP ----------
log "دانلود نصب‌کننده HestiaCP ..."
cd /root
curl -x "http://127.0.0.1:${PROXY_PORT}" -fsSL \
  -o hst-install.sh \
  https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh
chmod +x hst-install.sh

log "اجرای نصب HestiaCP (این مرحله چند دقیقه طول می‌کشد) ..."
HESTIA_ARGS=()
[[ -n "$HESTIA_HOSTNAME" ]] && HESTIA_ARGS+=(--hostname "$HESTIA_HOSTNAME")
[[ -n "$HESTIA_EMAIL" ]] && HESTIA_ARGS+=(--email "$HESTIA_EMAIL")

./hst-install.sh "${HESTIA_ARGS[@]}"

log "نصب HestiaCP تمام شد."
echo ""
echo "توجه: تانل SSH و تنظیمات پروکسی هنوز فعال هستند (برای پایداری نصب)."
echo "بعد از اطمینان از سالم بودن پنل، اسکریپت remove-tunnel.sh را اجرا کنید"
echo "تا تانل و پروکسی موقت به طور کامل پاک شوند."
