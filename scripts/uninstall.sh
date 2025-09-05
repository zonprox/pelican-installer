#!/usr/bin/env bash
set -euo pipefail
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON="${PEL_CACHE_DIR}/common.sh"; [[ -f "$COMMON" ]] || { mkdir -p "$PEL_CACHE_DIR"; curl -fsSL -o "$COMMON" "${PEL_RAW_BASE}/common.sh"; }
. "$COMMON"

require_root

echo "Uninstall options:"
echo " 1) Panel only"
echo " 2) Wings only"
echo " 3) Both"
read -rp "Choose [1-3]: " opt || true

ask_rm(){ read -rp "Delete $1 ? (y/N): " ok || true; [[ "$ok" =~ ^[Yy]$ ]] && rm -rf "$1" && say_ok "Removed $1"; }

if [[ "$opt" == "1" || "$opt" == "3" ]]; then
  systemctl disable --now pelican-queue 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-queue.service
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/pelican.conf /etc/nginx/sites-available/pelican.conf
  systemctl reload nginx || true
  ask_rm "/var/www/pelican"
fi

if [[ "$opt" == "2" || "$opt" == "3" ]]; then
  systemctl disable --now wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload
  rm -f /usr/local/bin/wings
  ask_rm "/etc/pelican"
  # Uncomment to purge Docker as well:
  # apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && apt-get autoremove -y
fi

say_ok "Uninstall finished."
