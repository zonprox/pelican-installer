#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os

echo "What do you want to uninstall?"
echo "1) Panel only"
echo "2) Wings only"
echo "3) BOTH Panel + Wings"
read -rp "Select: " CH || true

case "${CH:-}" in
  1)
    prompt_input INSTALL_DIR "Panel install directory" "/var/www/pelican"
    read -rp "Remove database too? (y/N): " RDB || true; RDB="${RDB:-N}"
    systemctl disable --now pelican-queue 2>/dev/null || true
    rm -f /etc/systemd/system/pelican-queue.service
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    [[ "$RDB" =~ ^[Yy]$ ]] && { mysql -u root -e "DROP DATABASE IF EXISTS pelicanpanel;" || true; }
    echo -e "${GREEN}Panel removed.${NC}"
    ;;
  2)
    systemctl disable --now pelican-wings 2>/dev/null || true
    rm -f /etc/systemd/system/pelican-wings.service
    systemctl daemon-reload
    rm -f /usr/local/bin/wings
    rm -rf /etc/pelican /var/lib/pelican /var/log/pelican
    echo -e "${GREEN}Wings removed.${NC}"
    ;;
  3)
    bash "${ROOT_DIR}/scripts/uninstall.sh" <<< $'1\n'
    bash "${ROOT_DIR}/scripts/uninstall.sh" <<< $'2\n'
    ;;
  *) echo "Aborted."; exit 0 ;;
esac
