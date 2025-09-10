#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Installer - Clean Menu Loader
# Code: English; UI: minimal numeric menu
# License: MIT

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zonprox/pelican-installer/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
RUN_LOCAL="false"
[[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/install.sh" ]] && RUN_LOCAL="true"

trap 'code=$?; [[ $code -ne 0 ]] && echo "Error: Installer aborted (exit $code)"; exit $code' EXIT

cls() { command -v tput >/dev/null 2>&1 && tput clear || clear; }

check_os() {
  local id=id_like=ver
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}" ; id_like="${ID_LIKE:-}" ; ver="${VERSION_ID:-}"
  else
    id="unknown"; id_like=""; ver="unknown"
  fi
  echo "Detected OS: ${id^} ${ver}"
  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *debian* ]]; then
    echo "Warning: Pelican recommends Ubuntu/Debian. Continue at your own risk."
    read -r -p "Continue anyway? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { echo "Aborted."; exit 1; }
  fi
}

run_module() {
  local name="$1"
  local tmp
  if [[ "$RUN_LOCAL" == "true" && -f "${SCRIPT_DIR}/${name}.sh" ]]; then
    bash "${SCRIPT_DIR}/${name}.sh"
    return
  fi
  tmp="$(mktemp "/tmp/pelican-${name}.XXXXXX.sh")"
  if ! curl -fsSL "${RAW_BASE}/${name}.sh" -o "$tmp"; then
    echo "Failed to fetch ${name}.sh from ${RAW_BASE}"
    exit 1
  fi
  chmod +x "$tmp"
  bash "$tmp"
  rm -f "$tmp"
}

main_menu() {
  while true; do
    cls
    cat <<'MENU'
Pelican Installer
=====================================
1) Install / Configure Panel
2) Install / Configure Wings      (placeholder)
3) SSL Utilities                  (placeholder)
4) Update Panel/Wings             (placeholder)
5) Uninstall Panel/Wings          (placeholder)
0) Exit
=====================================
MENU
    read -r -p "Select an option: " opt
    case "$opt" in
      1) run_module "panel" ;;
      2) echo "Wings module not available yet."; read -r -p "Press Enter..." _ ;;
      3) echo "SSL utilities not available yet."; read -r -p "Press Enter..." _ ;;
      4) echo "Update module not available yet."; read -r -p "Press Enter..." _ ;;
      5) echo "Uninstall module not available yet."; read -r -p "Press Enter..." _ ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

check_os
main_menu
