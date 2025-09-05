#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${THIS_DIR}/common.sh"

require_root

echo "Uninstall options:"
echo " 1) Panel only"
echo " 2) Wings only"
echo " 3) Both"
read -rp "Choose [1-3]: " opt || true

confirm_rm(){
  read -rp "Delete directory $1 ? (y/N): " ok || true
  [[ "$ok" =~ ^[Yy]$ ]] && rm -rf "$1" && say_ok "Removed $1"
}

if [[ "$opt" == "1" || "$opt" == "3" ]]; then
  systemctl disable --now pelican-queue.service 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-queue.service
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/pelican.conf /etc/nginx/sites-available/pelican.conf
  systemctl reload nginx || true
  confirm_rm "/var/www/pelican"
fi

if [[ "$opt" == "2" || "$opt" == "3" ]]; then
  systemctl disable --now wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload
  rm -f /usr/local/bin/wings
  confirm_rm "/etc/pelican"
  # Optional: keep Docker and images; uncomment next line to purge
  # apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && apt-get autoremove -y
fi

say_ok "Uninstall finished."
