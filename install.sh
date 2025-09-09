#!/usr/bin/env bash
set -euo pipefail

# ====== Settings ======
: "${GITHUB_USER:=zonprox}"
: "${GITHUB_REPO:=pelican-installer}"
: "${GITHUB_BRANCH:=main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

# ====== Helpers ======
cecho(){ echo -e "\033[1;36m$*\033[0m"; }
gecho(){ echo -e "\033[1;32m$*\033[0m"; }
recho(){ echo -e "\033[1;31m$*\033[0m"; }
yecho(){ echo -e "\033[1;33m$*\033[0m"; }

require_root(){
  if [[ $EUID -ne 0 ]]; then recho "Please run as root (sudo)."; exit 1; fi
}

# Determine current script dir (may be /dev/fd/* when using bash <(curl ...))
get_self_dir(){
  local src="${BASH_SOURCE[0]}"
  if [[ -z "${src}" || "${src}" == "/dev/fd/"* || "${src}" == "pipe:"* ]]; then
    echo ""
  else
    cd "$(dirname "$src")" && pwd
  fi
}

# Download a file from GitHub raw to target path
fetch_raw(){
  local rel="$1" dst="$2"
  curl -fsSL "${RAW_BASE}/${rel}" -o "${dst}"
}

# Ensure we are running from a real directory with all scripts present.
bootstrap_if_needed(){
  local self_dir="$1"
  local need_bootstrap="no"

  # If script directory is empty or not a real path, we need bootstrap
  if [[ -z "$self_dir" ]]; then
    need_bootstrap="yes"
  else
    # If any child script is missing, bootstrap
    for f in panel.sh wings.sh ssl.sh update.sh uninstall.sh; do
      [[ -f "${self_dir}/${f}" ]] || { need_bootstrap="yes"; break; }
    done
  fi

  if [[ "${need_bootstrap}" == "yes" && "${PEL_BOOTSTRAPPED:-0}" != "1" ]]; then
    # Choose a persistent local path (prefer /opt, fallback to /var/tmp)
    local base="/opt/${GITHUB_REPO}"
    mkdir -p "$base" 2>/dev/null || base="/var/tmp/${GITHUB_REPO}"
    mkdir -p "$base"

    yecho "Bootstrapping installer into: ${base}"
    # Download the full set we need
    for f in install.sh panel.sh wings.sh ssl.sh update.sh uninstall.sh; do
      fetch_raw "$f" "${base}/${f}"
      chmod +x "${base}/${f}" || true
    done

    # Re-exec from local copy to avoid /dev/fd/* path issues
    export PEL_BOOTSTRAPPED=1
    exec bash "${base}/install.sh" "$@"
  fi
}

detect_os(){
  source /etc/os-release || { recho "Cannot read /etc/os-release"; exit 1; }
  OS="$ID"; OS_VER_ID="$VERSION_ID"; OS_VER_CODENAME="${VERSION_CODENAME:-}"
  case "$OS" in
    ubuntu) dpkg --compare-versions "$OS_VER_ID" ge "22.04" || { recho "Ubuntu $OS_VER_ID not supported. Use 22.04/24.04+."; exit 1; } ;;
    debian) dpkg --compare-versions "$OS_VER_ID" ge "11"    || { recho "Debian $OS_VER_ID not supported. Use 11/12+."; exit 1; } ;;
    *) recho "Unsupported OS: $PRETTY_NAME. Only Ubuntu/Debian are supported."; exit 1;;
  esac
}

residue_check(){
  local PELICAN_DIR="/var/www/pelican"
  local NGINX_SITE="/etc/nginx/sites-enabled/pelican.conf"
  local hits=()
  [[ -d "$PELICAN_DIR" ]] && hits+=("$PELICAN_DIR")
  [[ -f "$NGINX_SITE"  ]] && hits+=("$NGINX_SITE")
  systemctl is-active --quiet wings && hits+=("wings.service")
  getent passwd pelican >/dev/null 2>&1 && hits+=("user:pelican")
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
      1) [[ -x "${REPO_ROOT}/uninstall.sh" ]] && bash "${REPO_ROOT}/uninstall.sh" || yecho "uninstall.sh not available yet."; ;;
      2) : ;;
      0) exit 0;;
      *) recho "Invalid selection."; exit 1;;
    esac
  fi
}

ensure_repo_layout(){
  # just a hint check
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
    2) [[ -x "$REPO_ROOT/wings.sh"    ]] && bash "$REPO_ROOT/wings.sh"    || yecho "wings.sh not available yet.";;
    3) [[ -x "$REPO_ROOT/ssl.sh"      ]] && bash "$REPO_ROOT/ssl.sh"      || yecho "ssl.sh not available yet.";;
    4) [[ -x "$REPO_ROOT/update.sh"   ]] && bash "$REPO_ROOT/update.sh"   || yecho "update.sh not available yet.";;
    5) [[ -x "$REPO_ROOT/uninstall.sh"]] && bash "$REPO_ROOT/uninstall.sh"|| yecho "uninstall.sh not available yet.";;
    0) exit 0;;
    *) recho "Invalid selection."; exit 1;;
  esac
}

# ====== Entry ======
require_root
# 1) Try to get a real script dir
REPO_ROOT="$(get_self_dir || true)"
# 2) Bootstrap if needed (will re-exec when done)
bootstrap_if_needed "$REPO_ROOT" "$@"
# 3) If already bootstrapped, REPO_ROOT might still be empty; set default to /opt or /var/tmp
if [[ -z "${REPO_ROOT}" ]]; then
  if [[ -d "/opt/${GITHUB_REPO}" ]]; then
    REPO_ROOT="/opt/${GITHUB_REPO}"
  else
    REPO_ROOT="/var/tmp/${GITHUB_REPO}"
  fi
fi

detect_os
residue_check
ensure_repo_layout
main_menu
