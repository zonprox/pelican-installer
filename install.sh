#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Minimalist Installer (Main Menu)
# Author: zonprox
# Requirements: bash>=4, curl, sudo
# Docs reference: Pelican install & quickstart
# - Installing Pelican: python -m pip install "pelican[markdown]"
# - Quickstart flow: pelican-quickstart (Q&A) to scaffold project
# https://docs.getpelican.com/en/latest/install.html
# https://docs.getpelican.com/en/latest/quickstart.html

###############################################################################
# Global styling (dark minimalist)
###############################################################################
readonly C_RESET="\033[0m"
readonly C_DIM="\033[2m"
readonly C_OK="\033[1;32m"
readonly C_WARN="\033[1;33m"
readonly C_ERR="\033[1;31m"
readonly C_TITLE="\033[1;36m"
readonly C_SEL="\033[7m"

title() {
  echo -e "${C_TITLE}$*${C_RESET}"
}
info() {
  echo -e "${C_DIM}$*${C_RESET}"
}
ok() {
  echo -e "${C_OK}✔${C_RESET} $*"
}
warn() {
  echo -e "${C_WARN}⚠${C_RESET} $*"
}
err() {
  echo -e "${C_ERR}✖${C_RESET} $*" >&2
}

###############################################################################
# Config
###############################################################################
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zonprox/pelican-installer/main}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/pelican-installer}"
STATE_DIR="${STATE_DIR:-/var/lib/pelican-installer}"
CONFIG_FILE="$STATE_DIR/config.env"

REQUIRED_CMDS=(curl bash)
trap 'err "Unexpected error. Exiting." ; exit 1' ERR

###############################################################################
# Utilities
###############################################################################
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

need_cmds() {
  local missing=()
  for c in "${REQUIRED_CMDS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "Missing commands: ${missing[*]}"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$INSTALL_ROOT" "$STATE_DIR"
}

download_if_missing() {
  local name="$1" url="$2" dest="$3"
  if [[ ! -s "$dest" ]]; then
    info "Fetching $name from: $url"
    curl -fsSL "$url" -o "$dest"
    chmod +x "$dest"
    ok "Saved $name → $dest"
  fi
}

detect_os() {
  local os="other" pretty="Unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-$NAME}"
    case "${ID_LIKE:-$ID}" in
      *debian*|*ubuntu*) os="debian";;
    esac
  fi
  echo "$os|$pretty"
}

press_any_key() {
  read -rsp $'Press any key to continue...\n' -n1
}

###############################################################################
# Arrow-key menu (pure bash)
###############################################################################
# Usage: select_menu "Title" "Option A" "Option B" ...  -> echoes index (0..N-1)
select_menu() {
  local header="$1"; shift
  local -a opts=("$@")
  local idx=0 key
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' EXIT

  while true; do
    clear
    title "$header"
    echo
    for i in "${!opts[@]}"; do
      if [[ $i -eq $idx ]]; then
        echo -e "  ${C_SEL}${opts[$i]}${C_RESET}"
      else
        echo -e "  ${opts[$i]}"
      fi
    done
    echo
    info "[↑/↓ to move, Enter to select, q to quit]"

    IFS= read -rsn1 key
    case "$key" in
      q) tput cnorm 2>/dev/null || true; exit 130;;
      "") echo "$idx"; tput cnorm 2>/dev/null || true; return 0;;
      $'\x1b')
        read -rsn2 key || true
        case "$key" in
          "[A") ((idx = (idx-1+${#opts[@]})%${#opts[@]}));;
          "[B") ((idx = (idx+1)%${#opts[@]}));;
        esac
      ;;
    esac
  done
}

###############################################################################
# System compatibility check
###############################################################################
check_compatibility() {
  local result pretty
  result="$(detect_os)"
  local os="${result%%|*}"
  pretty="${result##*|}"

  title "System Compatibility"
  echo
  echo -e "Detected: ${C_DIM}${pretty}${C_RESET}"
  if [[ "$os" != "debian" ]]; then
    warn "Pelican is Python-based and portable; however this installer is optimized for Ubuntu/Debian.\nYou may continue at your own risk."
    echo
    local sel
    sel=$(select_menu "Proceed anyway?" "Yes, continue" "No, abort")
    if [[ "$sel" -ne 0 ]]; then
      err "Aborted by user."
      exit 2
    fi
  else
    ok "Debian/Ubuntu family detected."
  fi
}

###############################################################################
# Collect user input → Review → Confirm
###############################################################################
random_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

collect_inputs() {
  clear
  title "Pelican Panel • Guided Setup"
  echo
  echo -e "${C_DIM}Tip: Pelican is a static site generator; a database is not required.\nMariaDB option is provided for future extensions/integrations.${C_RESET}"
  echo

  read -rp "Site Title (e.g., My Pelican Site): " SITE_TITLE
  read -rp "Author Name (e.g., Zon): " SITE_AUTHOR
  read -rp "Admin Email (for Let's Encrypt or contact): " ADMIN_EMAIL
  read -rp "Primary Domain (e.g., blog.example.com): " SITE_DOMAIN
  read -rp "Base URL (e.g., https://$SITE_DOMAIN): " SITE_URL

  # SSL mode: letsencrypt / custom / none
  local ssl_idx
  ssl_idx=$(select_menu "Select SSL Mode" \
    "letsencrypt (automatic)" \
    "custom (paste PEM cert/key)" \
    "none (http)")
  case "$ssl_idx" in
    0) SSL_MODE="letsencrypt";;
    1) SSL_MODE="custom";;
    2) SSL_MODE="none";;
  esac

  # DB mode: mariadb / sqlite
  local db_idx
  db_idx=$(select_menu "Select Database Mode (Pelican doesn't need DB; MariaDB prepared for future use)" \
    "mariadb (recommended placeholder)" \
    "sqlite (lightweight placeholder)")
  case "$db_idx" in
    0) DB_MODE="mariadb";;
    1) DB_MODE="sqlite";;
  esac

  # Defaults/derived
  PELICAN_USER="pelican"
  PELICAN_DIR="/var/www/pelican"
  VENV_DIR="/opt/pelican-venv"
  DB_NAME="pelican"
  DB_USER="pelican"
  DB_PASS="$(random_password)"

  # Export to env + save
  mkdir -p "$STATE_DIR"
  cat > "$CONFIG_FILE.tmp" <<EOF
SITE_TITLE="$SITE_TITLE"
SITE_AUTHOR="$SITE_AUTHOR"
ADMIN_EMAIL="$ADMIN_EMAIL"
SITE_DOMAIN="$SITE_DOMAIN"
SITE_URL="$SITE_URL"
SSL_MODE="$SSL_MODE"
DB_MODE="$DB_MODE"
PELICAN_USER="$PELICAN_USER"
PELICAN_DIR="$PELICAN_DIR"
VENV_DIR="$VENV_DIR"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
EOF

  # If custom SSL, we will ask in panel.sh to paste cert/key securely.
}

review_and_confirm() {
  clear
  title "Review Configuration"
  echo
  sed 's/^/  /' "$CONFIG_FILE.tmp"
  echo
  local sel
  sel=$(select_menu "Confirm and continue with installation?" "Yes, proceed" "No, edit" "Cancel")
  case "$sel" in
    0) mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"; ok "Configuration saved to $CONFIG_FILE"; return 0;;
    1) rm -f "$CONFIG_FILE.tmp"; collect_inputs; review_and_confirm;;
    2) err "Cancelled by user."; exit 2;;
  esac
}

###############################################################################
# Main actions (call submodules via GitHub raw)
###############################################################################
run_panel_install() {
  download_if_missing "panel.sh" "$RAW_BASE/panel.sh" "$INSTALL_ROOT/panel.sh"
  # shellcheck disable=SC1090
  "$INSTALL_ROOT/panel.sh" --config "$CONFIG_FILE"
}

show_post_install() {
  clear
  title "Pelican Installed Successfully"
  echo
  cat <<EOF
Path summary:
  - Project root: /var/www/pelican
  - Content dir : /var/www/pelican/content
  - Output dir  : /var/www/pelican/output
  - Virtualenv  : /opt/pelican-venv

Basic usage:
  sudo -u pelican bash -lc '
    source /opt/pelican-venv/bin/activate
    cd /var/www/pelican
    pelican content -o output -s pelicanconf.py    # build
  '

Preview locally:
  sudo -u pelican bash -lc '
    source /opt/pelican-venv/bin/activate
    cd /var/www/pelican/output && python -m http.server 8000
  '  → http://localhost:8000

Nginx:
  - Serving domain: ${SITE_DOMAIN}
  - SSL mode      : ${SSL_MODE}

Database (placeholder for future extensions):
  - Mode          : ${DB_MODE}
  - DB Name/User  : pelican
  - Password      : (stored in $CONFIG_FILE)

EOF
  ok "All done."
}

###############################################################################
# Main Menu
###############################################################################
main_menu() {
  while true; do
    local choice
    choice=$(select_menu "Pelican Installer — Main Menu" \
      "Install / Reconfigure Pelican Panel" \
      "Show Saved Configuration" \
      "Update panel.sh from GitHub" \
      "Uninstall (remove site & configs)" \
      "Exit")

    case "$choice" in
      0)
        collect_inputs
        review_and_confirm
        run_panel_install
        show_post_install
        press_any_key
      ;;
      1)
        clear
        title "Current Configuration"
        if [[ -s "$CONFIG_FILE" ]]; then sed 's/^/  /' "$CONFIG_FILE"; else warn "No config saved yet."; fi
        echo ; press_any_key
      ;;
      2)
        download_if_missing "panel.sh" "$RAW_BASE/panel.sh" "$INSTALL_ROOT/panel.sh"
        ok "panel.sh refreshed."
        press_any_key
      ;;
      3)
        download_if_missing "uninstall.sh" "$RAW_BASE/uninstall.sh" "$INSTALL_ROOT/uninstall.sh"
        if [[ -x "$INSTALL_ROOT/uninstall.sh" ]]; then
          "$INSTALL_ROOT/uninstall.sh" || true
        else
          warn "uninstall.sh not available yet. You can remove Nginx site, dirs, and venv manually."
        fi
        press_any_key
      ;;
      4) clear; exit 0;;
    esac
  done
}

###############################################################################
# Entry
###############################################################################
require_root
need_cmds
ensure_dirs
check_compatibility
# Preload panel.sh so menu actions work offline
download_if_missing "panel.sh" "$RAW_BASE/panel.sh" "$INSTALL_ROOT/panel.sh"
main_menu
