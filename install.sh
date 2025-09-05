#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

# shellcheck source=scripts/lib/common.sh
. "${SCRIPTS_DIR}/lib/common.sh"

main_menu() {
  clear
  echo -e "${CYAN}Pelican Installer – Main Menu${NC}"
  echo "1) Install Pelican Panel"
  echo "2) Install Pelican Wings"
  echo "3) Install BOTH (Panel + Wings)"
  echo "4) SSL: Issue/Configure (Let's Encrypt or Custom PEM)"
  echo "5) Update Panel"
  echo "6) Uninstall (Panel/Wings)"
  echo "0) Exit"
  echo
  read -rp "Select an option: " opt || true

  case "${opt:-}" in
    1) bash "${SCRIPTS_DIR}/panel.sh" ;;
    2) bash "${SCRIPTS_DIR}/wings.sh" ;;
    3) bash "${SCRIPTS_DIR}/both.sh" ;;
    4) bash "${SCRIPTS_DIR}/ssl.sh" ;;
    5) bash "${SCRIPTS_DIR}/update.sh" ;;
    6) bash "${SCRIPTS_DIR}/uninstall.sh" ;;
    0) echo "Bye!"; exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
}

require_root
detect_os
while true; do main_menu; done
