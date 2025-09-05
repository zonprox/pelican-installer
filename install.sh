#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"

# shellcheck source=scripts/common.sh
. "${SCRIPTS_DIR}/common.sh"

require_root
detect_os_or_die    # Debian 12 / Ubuntu 22.04 / 24.04
say_info "Detected OS: ${OS_NAME}"

while :; do
  cat <<'MENU'

────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings
 3) Install Both
 4) SSL Only
 5) Update
 6) Uninstall
 7) Quit
MENU
  read -rp "Choose an option [1-7]: " choice || true

  case "${choice:-}" in
    1) bash "${SCRIPTS_DIR}/install_panel.sh" ;;
    2) bash "${SCRIPTS_DIR}/install_wings.sh" ;;
    3) bash "${SCRIPTS_DIR}/install_both.sh" ;;
    4) bash "${SCRIPTS_DIR}/install_ssl.sh" ;;
    5) bash "${SCRIPTS_DIR}/update.sh" ;;
    6) bash "${SCRIPTS_DIR}/uninstall.sh" ;;
    7) exit 0 ;;
    *) say_warn "Invalid choice." ;;
  esac
done
