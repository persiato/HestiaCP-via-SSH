#!/usr/bin/env bash
#
# حذف کامل تانل SSH و تنظیمات موقت پروکسی که برای نصب پنل ساخته شده بودند.
# بعد از اینکه از سالم بودن نصب HestiaCP مطمئن شدید، این اسکریپت را
# روی سرور ایران با روت اجرا کنید:
#   chmod +x remove-tunnel.sh
#   ./remove-tunnel.sh
#
set -euo pipefail

PID_FILE="/var/run/hestia-ssh-tunnel.pid"
APT_PROXY_FILE="/etc/apt/apt.conf.d/95-hestia-tunnel-proxy"
PRIVOXY_CONFIG="/etc/privoxy/config"
MARK_START="# >>> hestia-tunnel-proxy >>>"
MARK_END="# <<< hestia-tunnel-proxy <<<"

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$1"; }

if [[ $EUID -ne 0 ]]; then
  echo "این اسکریپت باید با روت اجرا شود (sudo)." >&2
  exit 1
fi

# ---------- 1) قطع تانل SSH ----------
if [[ -f "$PID_FILE" ]]; then
  TUNNEL_PID="$(cat "$PID_FILE")"
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID"
    log "تانل SSH (PID $TUNNEL_PID) متوقف شد."
  fi
  rm -f "$PID_FILE"
else
  # اگر فایل PID نبود، هر ssh -D باقی‌مانده مرتبط با این تانل را پیدا و متوقف کن
  pkill -f "ssh -N -D 127.0.0.1:" 2>/dev/null && log "تانل(های) SSH باقی‌مانده متوقف شدند." || true
fi

# ---------- 2) حذف تنظیمات پروکسی apt ----------
if [[ -f "$APT_PROXY_FILE" ]]; then
  rm -f "$APT_PROXY_FILE"
  log "فایل پروکسی apt حذف شد."
fi

# ---------- 3) حذف تنظیمات privoxy و خود privoxy ----------
if [[ -f "$PRIVOXY_CONFIG" ]] && grep -q "$MARK_START" "$PRIVOXY_CONFIG"; then
  sed -i "/${MARK_START}/,/${MARK_END}/d" "$PRIVOXY_CONFIG"
  log "تنظیمات اضافه‌شده به privoxy حذف شد."
fi

if dpkg -l privoxy >/dev/null 2>&1; then
  systemctl stop privoxy 2>/dev/null || true
  apt-get purge -y privoxy >/dev/null 2>&1 || true
  log "بسته privoxy حذف شد."
fi

log "همه چیز پاک شد. سرور دیگر از تانل یا پروکسی موقت استفاده نمی‌کند."
