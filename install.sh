#!/usr/bin/env bash
set -euo pipefail

# Pelican Installer - Main Menu Loader
# Author: zonprox (starter scaffold by ChatGPT)
# License: MIT

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zonprox/pelican-installer/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
RUN_LOCAL="false"
[[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/install.sh" ]] && RUN_LOCAL="true"

# --- UI helpers ---
cecho() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info()  { cecho "1;34" "➜ $*"; }
warn()  { cecho "1;33" "⚠ $*"; }
err()   { cecho "1;31" "✖ $*"; }
ok()    { cecho "1;32" "✔ $*"; }

press_enter() { read -r -p "Press [Enter] to continue..." _; }

# --- System compatibility check (Ubuntu/Debian recommended) ---
check_os() {
  local id_like id ver
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"; id_like="${ID_LIKE:-}"
    ver="${VERSION_ID:-}"
  else
    id="unknown"; id_like=""
    ver="unknown"
  fi

  info "Detected OS: ${id^} ${ver}"
  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *debian* ]]; then
    warn "Pelican Panel officially documents Ubuntu/Debian (PHP 8.2–8.4, NGINX/Apache/Caddy)."
    warn "You can continue at your own risk."
    read -r -p "Continue anyway? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { err "Aborted by user."; exit 1; }
  fi
}

# --- Downloader to run a module (local or remote raw) ---
run_module() {
  local name="$1"
  local target="/tmp/pelican-${name}-$$.sh"
  if [[ "$RUN_LOCAL" == "true" && -f "${SCRIPT_DIR}/${name}.sh" ]]; then
    info "Running local ${name}.sh ..."
    bash "${SCRIPT_DIR}/${name}.sh"
    return
  fi
  info "Fetching ${name}.sh from GitHub raw..."
  if ! curl -fsSL "${RAW_BASE}/${name}.sh" -o "${target}"; then
    err "Failed to download ${name}.sh from ${RAW_BASE}"
    exit 1
  fi
  chmod +x "${target}"
  bash "${target}"
  rm -f "${target}"
}

# --- Menu ---
main_menu() {
  clear
  cecho "1;36" "Pelican Installer"
  echo "====================================="
  echo "1) Install/Configure Panel"
  echo "2) Install/Configure Wings      (coming from your repo)"
  echo "3) SSL Utilities                (Let's Encrypt / custom) "
  echo "4) Update Panel/Wings           "
  echo "5) Uninstall Panel/Wings        "
  echo "0) Exit"
  echo "====================================="
  read -r -p "Select an option: " opt
  case "$opt" in
    1) run_module "panel" ;;
    2) warn "Module wings.sh not provided yet. Add ${RAW_BASE}/wings.sh later."; press_enter ;;
    3) warn "Module ssl.sh not provided yet. Add ${RAW_BASE}/ssl.sh later."; press_enter ;;
    4) warn "Module update.sh not provided yet. Add ${RAW_BASE}/update.sh later."; press_enter ;;
    5) warn "Module uninstall.sh not provided yet. Add ${RAW_BASE}/uninstall.sh later."; press_enter ;;
    0) ok "Bye!"; exit 0 ;;
    *) warn "Invalid option."; press_enter ;;
  esac
}

check_os
while true; do main_menu; done
