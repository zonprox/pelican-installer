#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Pelican Installer Bootstrap
# - One-line installer entrypoint
# - Downloads helper modules into /tmp/pelican-installer/
# - Presents a simple numeric menu
# - Light compatibility checks (warn, don't block)
# - Detects previous installs and suggests uninstall
# Author: ZonProx (minimal, user-first style)
# ──────────────────────────────────────────────────────────────────────────────

REPO_BASE="https://raw.githubusercontent.com/zonprox/pelican-installer/main"
WORKDIR="/tmp/pelican-installer"
SUBDIRS=(install panel wings ssl update uninstall)

# Colors (minimal)
YELLOW="\033[33m"; GREEN="\033[32m"; RED="\033[31m"; NC="\033[0m"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Please run this script as root (sudo).${NC}"
    exit 1
  fi
}

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

prepare_layout() {
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  for d in "${SUBDIRS[@]}"; do
    mkdir -p "$WORKDIR/$d"
  done
  info "Workspace prepared at $WORKDIR"
}

fetch_file() {
  local relpath="$1"
  local out="$WORKDIR/$relpath"
  local url="$REPO_BASE/$relpath"
  curl -fsSL "$url" -o "$out"
  chmod +x "$out" || true
}

download_modules() {
  # Only fetch what's needed now; you can add more modules later.
  fetch_file "panel/panel.sh"

  # Create empty placeholders for future modules so the structure exists.
  : > "$WORKDIR/install/README"
  : > "$WORKDIR/wings/README"
  : > "$WORKDIR/ssl/README"
  : > "$WORKDIR/update/README"
  : > "$WORKDIR/uninstall/README"
  info "Modules downloaded into $WORKDIR"
}

check_system() {
  local os_like="unknown" arch="$(uname -m)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_like="${ID_LIKE:-$ID}"
  fi

  if [[ "$os_like" != *debian* && "$os_like" != *ubuntu* ]]; then
    warn "This system is not officially listed as Debian/Ubuntu-like."
    warn "We'll continue if you want, but there could be rough edges."
  fi

  if [[ "$arch" != "x86_64" && "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
    warn "Architecture '$arch' is less tested. Proceed at your own risk."
  fi

  # Minimal connectivity check
  if ! curl -fsSL https://github.com/ >/dev/null; then
    warn "Cannot reach GitHub right now; downloads may fail."
  fi
}

detect_previous_install() {
  local hints=()
  [[ -d /var/www/pelican ]] && hints+=("/var/www/pelican")
  systemctl is-active --quiet wings && hints+=("wings service active")
  [[ -f /etc/nginx/sites-available/pelican ]] && hints+=("nginx site: pelican")
  mysql -NBe "SHOW DATABASES LIKE 'pelican';" >/dev/null 2>&1 && hints+=("MariaDB DB: pelican")

  if ((${#hints[@]})); then
    warn "It looks like a previous Pelican install may exist:"
    for h in "${hints[@]}"; do echo " - $h"; done
    echo
    echo "You can proceed, but it's safer to clean up first."
    echo "If you already have an 'uninstall.sh' later, run it to remove leftovers (DB/files/PHP/libs)."
    read -r -p "Proceed anyway? [y/N]: " yn
    [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
  fi
}

main_menu() {
  clear
  cat <<'MENU'
Pelican Installer - Minimal Menu
(1) Install Panel (recommended)
(2) Install Wings (coming soon)
(3) Update (coming soon)
(4) Uninstall (coming soon)
(0) Exit
MENU
  echo -n "Choose an option [0-4]: "
  read -r choice
  case "$choice" in
    1) bash "$WORKDIR/panel/panel.sh" ;;
    2) warn "Wings module not ready yet. Please check back later."; sleep 1 ;;
    3) warn "Update module not ready yet. Please check back later."; sleep 1 ;;
    4) warn "Uninstall module not ready yet. Please check back later."; sleep 1 ;;
    0) info "Goodbye!"; exit 0 ;;
    *) warn "Invalid selection."; sleep 1 ;;
  esac
}

# ── Flow ──────────────────────────────────────────────────────────────────────
require_root
prepare_layout
download_modules
check_system
detect_previous_install
while true; do main_menu; done
