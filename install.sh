#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

PELICAN_DIR="/var/www/pelican"
NGINX_SITE="/etc/nginx/sites-enabled/pelican.conf"
PANEL_SERVICE_HINT="$PELICAN_DIR/artisan"
OS=""
OS_VER_ID=""
OS_VER_CODENAME=""

# --------- UI helpers ----------
cecho(){ echo -e "\033[1;36m$*\033[0m"; }
gecho(){ echo -e "\033[1;32m$*\033[0m"; }
recho(){ echo -e "\033[1;31m$*\033[0m"; }
yecho(){ echo -e "\033[1;33m$*\033[0m"; }
pause(){ read -rp "Press ENTER to continue..."; }

require_root(){
  if [[ $EUID -ne 0 ]]; then
    recho "Please run as root (sudo)."; exit 1
  fi
}

detect_os(){
  source /etc/os-release || { recho "Cannot read /etc/os-release"; exit 1; }
  OS="$ID"; OS_VER_ID="$VERSION_ID"; OS_VER_CODENAME="${VERSION_CODENAME:-}"
  case "$OS" in
    ubuntu)
      # Pelican Panel supports PHP 8.2+ (8.2/8.3/8.4) — ensure modern Ubuntu (22.04+). :contentReference[oaicite:0]{index=0}
      dpkg --compare-versions "$OS_VER_ID" ge "22.04" || { recho "Ubuntu $OS_VER_ID not supported. Use 22.04/24.04+. Exiting."; exit 1; }
      ;;
    debian)
      # Prefer Debian 11/12 (modern PHP via Sury). :contentReference[oaicite:1]{index=1}
      dpkg --compare-versions "$OS_VER_ID" ge "11" || { recho "Debian $OS_VER_ID not supported. Use 11/12+. Exiting."; exit 1; }
      ;;
    *)
      recho "Unsupported OS: $PRETTY_NAME. Only Ubuntu/Debian are supported."; exit 1;;
  esac
}

residue_check(){
  local hits=()
  [[ -d "$PELICAN_DIR" ]] && hits+=("$PELICAN_DIR")
  [[ -f "$NGINX_SITE" ]] && hits+=("$NGINX_SITE")
  systemctl is-active --quiet wings && hits+=("wings.service")
  getent passwd pelican >/dev/null 2>&1 && hits+=("user:pelican")
  # simple DB footprint check (best-effort)
  if command -v mysql >/dev/null 2>&1; then
    if mysql -NBe "SHOW DATABASES LIKE 'pelican';" 2>/dev/null | grep -q pelican; then
      hits+=("mysql:pelican database")
    fi
  fi
  if ((${#hits[@]})); then
    yecho "Found possible previous installation leftovers:"
    for h in "${hits[@]}"; do echo " - $h"; done
    echo
    echo "1) Run uninstall (clean up database/files/services)  [recommended]"
    echo "2) Ignore and continue"
    echo "0) Exit"
    read -rp "Select: " opt
    case "$opt" in
      1)
        if [[ -x "$REPO_ROOT/uninstall.sh" ]]; then
          "$REPO_ROOT/uninstall.sh"
        else
          yecho "uninstall.sh not present yet. Performing minimal cleanup (files/nginx only)."
          rm -rf "$PELICAN_DIR" || true
          rm -f  "$NGINX_SITE"  || true
          nginx -t && systemctl reload nginx || true
        fi
        ;;
      2) : ;;
      0) exit 0;;
      *) recho "Invalid selection."; exit 1;;
    esac
  fi
}

ensure_repo_layout(){
  # Informative only — not enforcing, just guiding structure the user requested.
  for f in panel.sh wings.sh ssl.sh update.sh uninstall.sh; do
    [[ -f "$REPO_ROOT/$f" ]] || true
  done
}

main_menu(){
  clear
  cecho "Pelican Installer — Main Menu"
  echo "1) Install/Configure Panel"
  echo "2) Install/Configure Wings (agent)"
  echo "3) SSL (Let's Encrypt/Certbot)"
  echo "4) Update Panel/Wings"
  echo "5) Uninstall (clean)"
  echo "0) Exit"
  read -rp "Select: " choice
  case "$choice" in
    1) bash "$REPO_ROOT/panel.sh";;
    2) [[ -x "$REPO_ROOT/wings.sh" ]] && bash "$REPO_ROOT/wings.sh" || yecho "wings.sh not available yet.";;
    3) [[ -x "$REPO_ROOT/ssl.sh" ]]   && bash "$REPO_ROOT/ssl.sh"   || yecho "ssl.sh not available yet.";;
    4) [[ -x "$REPO_ROOT/update.sh" ]]&& bash "$REPO_ROOT/update.sh"|| yecho "update.sh not available yet.";;
    5) [[ -x "$REPO_ROOT/uninstall.sh" ]] && bash "$REPO_ROOT/uninstall.sh" || yecho "uninstall.sh not available yet.";;
    0) exit 0;;
    *) recho "Invalid selection."; exit 1;;
  esac
}

# --------- Flow ----------
require_root
detect_os
residue_check
ensure_repo_layout
main_menu
