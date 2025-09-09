#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Installer — minimal, arrow-only menu
# Repo: https://github.com/zonprox/pelican-installer
# Flow: curl | bash -> clone to /temp/pelican-installer -> menu -> call sub-scripts

REPO_URL="https://github.com/zonprox/pelican-installer"
WORKDIR="/temp/pelican-installer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }
err()  { printf "\033[31m%s\033[0m\n" "$*"; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Please run as root."; exit 1; }; }
have()      { command -v "$1" >/dev/null 2>&1; }

clone_repo() {
  mkdir -p /temp
  rm -rf "${WORKDIR}"
  if have git; then
    git clone --depth=1 "${REPO_URL}" "${WORKDIR}" >/dev/null
  else
    err "git is required to fetch the installer. Try: apt-get update && apt-get install -y git"
    exit 1
  fi
  ok "Repository synced to ${WORKDIR}"
}

os_info() { source /etc/os-release || true; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; }
arch_info() { ARCH="$(uname -m)"; }

supported_os() {
  case "$OS_ID" in
    ubuntu) [[ "$OS_VER" == "22.04" || "$OS_VER" == "24.04" ]] ;;
    debian) [[ "$OS_VER" == "12" ]] ;;
    *) return 1 ;;
  esac
}

detect_leftovers() {
  LEFT=()
  [[ -d /var/www/pelican ]] && LEFT+=("/var/www/pelican")
  [[ -f /etc/nginx/sites-available/pelican_panel ]] && LEFT+=("/etc/nginx/sites-available/pelican_panel")
  systemctl list-unit-files 2>/dev/null | grep -q '^pelican-queue\.service' && LEFT+=("pelican-queue.service")
  systemctl list-unit-files 2>/dev/null | grep -q '^wings\.service'        && LEFT+=("wings.service")
}

ask_uninstall_if_leftovers() {
  (( ${#LEFT[@]} )) || return 0
  warn "Detected remnants from a previous install:"
  printf ' - %s\n' "${LEFT[@]}"
  read -rp "Run uninstall to clean everything? [Y/n]: " a; a="${a:-Y}"
  [[ "$a" =~ ^[Yy]$ ]] || return 0
  if [[ -x "${WORKDIR}/uninstall.sh" ]]; then
    bash "${WORKDIR}/uninstall.sh"
  else
    err "uninstall.sh not found."
    exit 1
  fi
}

# Minimal arrow-only menu (↑/↓ + Enter)
menu() {
  local title="$1"; shift
  local items=("$@")
  local sel=0 key
  stty -echo -icanon time 0 min 0 || true
  trap 'stty sane; echo' EXIT
  while true; do
    printf "\033c"; bold "$title"; echo
    for i in "${!items[@]}"; do
      if [[ $i -eq $sel ]]; then printf "  \033[7m%s\033[0m\n" "${items[$i]}"; else printf "  %s\n" "${items[$i]}"; fi
    done
    IFS= read -rsn1 key || true
    [[ -z "$key" ]] && continue
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 key || true
      [[ "$key" == "[A" ]] && ((sel=(sel-1+${#items[@]})%${#items[@]}))
      [[ "$key" == "[B" ]] && ((sel=(sel+1)%${#items[@]}))
    elif [[ "$key" == $'\x0a' || "$key" == $'\x0d' ]]; then
      stty sane; echo; return $sel
    fi
  done
}

run_script() { [[ -x "$1" ]] && bash "$1" || warn "$(basename "$1") not found."; }

main() {
  need_root
  # If invoked via raw curl, ensure we run from WORKDIR
  if [[ "$SCRIPT_DIR" != "$WORKDIR" ]]; then
    clone_repo
  fi

  os_info; arch_info
  if ! supported_os; then
    warn "Your OS (${OS_ID} ${OS_VER}) may not be fully supported. Proceed at your own risk."
  fi
  if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
    warn "This system architecture (${ARCH}) may not be well supported. You can still proceed if you wish."
  fi

  detect_leftovers
  ask_uninstall_if_leftovers

  local options=(
    "Install Pelican Panel"
    "Install Wings (Node Agent)"
    "Issue/Renew SSL (Let's Encrypt)"
    "Update Panel/Wings"
    "Uninstall (Clean up)"
    "Re-sync installer"
    "Exit"
  )

  while true; do
    menu "Pelican Installer — ${OS_ID} ${OS_VER}" "${options[@]}"
    case $? in
      0) run_script "${WORKDIR}/panel.sh" ;;
      1) run_script "${WORKDIR}/wings.sh" ;;
      2) run_script "${WORKDIR}/ssl.sh" ;;
      3) run_script "${WORKDIR}/update.sh" ;;
      4) run_script "${WORKDIR}/uninstall.sh" ;;
      5) clone_repo ;;
      6) ok "Bye."; exit 0 ;;
    esac
    read -rp "Press Enter to return to menu..." _ || true
  done
}

main "$@"
