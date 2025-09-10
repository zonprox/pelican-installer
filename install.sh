#!/usr/bin/env bash
set -Eeuo pipefail

# Minimal Pelican Installer Menu (only calls panel.sh)
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zonprox/pelican-installer/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
RUN_LOCAL="false"; [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/install.sh" ]] && RUN_LOCAL="true"

fetch_and_run() {
  local name="$1" tmp
  if [[ "$RUN_LOCAL" == "true" && -f "${SCRIPT_DIR}/${name}.sh" ]]; then
    bash "${SCRIPT_DIR}/${name}.sh"; return
  fi
  tmp="$(mktemp "/tmp/pelican-${name}.XXXXXX.sh")"
  curl -fsSL "${RAW_BASE}/${name}.sh" -o "$tmp" || { echo "Failed to fetch ${name}.sh"; exit 1; }
  chmod +x "$tmp"; bash "$tmp"; rm -f "$tmp"
}

check_os_hint() {
  local id="unknown" like="" ver=""
  [[ -r /etc/os-release ]] && { . /etc/os-release; id="${ID:-unknown}"; like="${ID_LIKE:-}"; ver="${VERSION_ID:-}"; }
  echo "Detected OS: ${id^} ${ver}"
  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$like" != *debian* ]]; then
    echo "Warning: Pelican recommends Ubuntu/Debian. Continue at your own risk."
    read -r -p "Continue anyway? [y/N]: " c; [[ "${c,,}" == "y" ]] || { echo "Aborted."; exit 1; }
  fi
}

main_menu() {
  while true; do
    clear
    cat <<'MENU'
Pelican Installer
=====================================
1) Install / Configure Panel
0) Exit
=====================================
MENU
    read -r -p "Select an option: " opt
    case "$opt" in
      1) fetch_and_run "panel" ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

check_os_hint
main_menu
