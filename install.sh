#!/usr/bin/env bash
# Pelican Installer - Bootstrap & Menu (arrow-key navigation)
# Minimal deps; downloads all scripts to /tmp/pelican-installer and runs selected module.
# Repo is read directly via raw.githubusercontent.com (no releases required).

set -Eeuo pipefail

# ---- Config (override via env if needed) ----
GITHUB_USER_REPO="${GITHUB_USER_REPO:-zonprox/pelican-installer}"
BRANCH="${BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER_REPO}/${BRANCH}"
WORKDIR="/tmp/pelican-installer"
MODULES=(panel wings ssl update uninstall)
# Only panel.sh is fully implemented now; others can be added later.
LOG_FILE="${WORKDIR}/installer.log"

# ---- UI helpers (no external deps) ----
ESC="$(printf '\033')"
cursor_blink_on(){ printf "${ESC}[?25h"; }
cursor_blink_off(){ printf "${ESC}[?25l"; }
cursor_to(){ printf "${ESC}[$1;${2:-1}H"; }
print_inactive(){ printf "  %s  \n" "$1"; }
print_active(){ printf "${ESC}[7m> %s ${ESC}[27m\n" "$1"; }
get_key(){
  read -rsn1 key 2>/dev/null || true
  case "$key" in
    "") echo enter ;;
    $'\x1b')
      read -rsn2 key || true
      [[ "$key" == "[A" ]] && echo up && return
      [[ "$key" == "[B" ]] && echo down && return
      echo ignore
      ;;
    q) echo quit ;;
    *) echo ignore ;;
  esac
}
menu() {
  # $1 title  $2 array_name  -> echoes selected index (0-based) or -1 to exit
  local title="$1"; local -n _items="$2"
  local selected=0
  printf "\n%s\n\n" "$title"
  trap 'cursor_blink_on' EXIT
  cursor_blink_off
  while true; do
    local idx=0
    for item in "${_items[@]}"; do
      if [[ $idx -eq $selected ]]; then print_active "$item"; else print_inactive "$item"; fi
      idx=$((idx+1))
    done
    case "$(get_key)" in
      up)   ((selected= (selected-1+${#_items[@]})%${#_items[@]})) ;;
      down) ((selected= (selected+1)%${#_items[@]})) ;;
      enter) echo "$selected"; return ;;
      quit)  echo "-1"; return ;;
      *) :;;
    esac
    cursor_to $(( $(tput lines) )) 0
    # redraw
    printf "${ESC}[${#_items[@]}A"
  done
}

log(){ printf -- "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG_FILE" >&2; }

# ---- Bootstrap ----
prepare_workdir() {
  mkdir -p "$WORKDIR"
  : > "$LOG_FILE"
  log "Using workdir: $WORKDIR"
}

download_modules() {
  log "Downloading modules from ${RAW_BASE}"
  for name in "${MODULES[@]}"; do
    url="${RAW_BASE}/${name}.sh"
    dst="${WORKDIR}/${name}.sh"
    if curl -fsSL "$url" -o "$dst"; then
      chmod +x "$dst"
      log "Fetched $name.sh"
    else
      # Create a friendly placeholder if not present yet
      cat >"$dst"<<'EOF'
#!/usr/bin/env bash
echo "[Info] This module is not implemented yet. Please update the repository with this script."
exit 0
EOF
      chmod +x "$dst"
      log "Placeholder created for $name.sh (not found in repo)."
    fi
  done
}

detect_leftovers() {
  local found=0
  local hints=()
  [[ -d /var/www/pelican ]] && found=1 && hints+=("/var/www/pelican")
  [[ -d /etc/pelican ]] && found=1 && hints+=("/etc/pelican")
  [[ -x /usr/local/bin/wings ]] && found=1 && hints+=("/usr/local/bin/wings")
  systemctl list-units --type=service --all 2>/dev/null | grep -qE '(^|\s)(wings\.service|pelican-queue\.service)\s' && found=1 && hints+=("(systemd) wings/pelican-queue")
  if (( found )); then
    echo "Detected previous Pelican-related files/services:"
    printf " - %s\n" "${hints[@]}"
    echo
    read -rp "Run 'uninstall' module to fully clean up now? [y/N]: " ans || true
    if [[ "${ans,,}" == "y" ]]; then
      bash "${WORKDIR}/uninstall.sh" || true
    else
      echo "You can run Uninstall later from the menu."
    fi
    echo
  fi
}

check_os_gently() {
  # Gentle warning: prefer Ubuntu/Debian (per Pelican docs), but allow continue on others.
  local os="unknown" ver=""; 
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os="${ID:-unknown}"; ver="${VERSION_ID:-}"
  fi
  echo "Detected OS: ${os^} ${ver}"
  case "$os" in
    ubuntu|debian)
      echo "Good: Ubuntu/Debian are documented & commonly used for Pelican.";;
    *)
      echo "Note: Your OS is not Ubuntu/Debian. Pelican supports several OS (Ubuntu 22.04/24.04, Debian 12, etc.),"
      echo "but setup steps may differ. Proceeding is allowed, yet expect to adjust manually if needed."
      ;;
  esac
  echo
}

main_menu() {
  local options=("Install Panel" "Install Wings" "Configure SSL" "Update Panel" "Uninstall Everything" "Exit")
  while true; do
    clear
    echo "Pelican Installer — ${GITHUB_USER_REPO}@${BRANCH}"
    echo "Workdir: $WORKDIR"
    echo
    check_os_gently
    detect_leftovers
    echo "Use Arrow keys to move, Enter to select (q to quit):"
    local sel; sel=$(menu "Main Menu" options) || sel=-1
    case "$sel" in
      0) bash "${WORKDIR}/panel.sh"; read -rp "Press Enter to return to menu..." _ ;;
      1) bash "${WORKDIR}/wings.sh"; read -rp "Press Enter..." _ ;;
      2) bash "${WORKDIR}/ssl.sh"; read -rp "Press Enter..." _ ;;
      3) bash "${WORKDIR}/update.sh"; read -rp "Press Enter..." _ ;;
      4) bash "${WORKDIR}/uninstall.sh"; read -rp "Press Enter..." _ ;;
      5|-1) echo "Bye."; return ;;
      *) :;;
    esac
  done
}

# ---- Run ----
prepare_workdir
download_modules
main_menu
