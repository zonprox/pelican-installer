#!/usr/bin/env bash
set -euo pipefail

# Minimal Pelican Installer Entry
REPO_URL="https://github.com/zonprox/pelican-installer"
WORKDIR="/tmp/pelican-installer"

# --- tiny ui helpers ---
bold(){ printf "\033[1m%s\033[0m" "$*"; }
green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { red "Please run as root (sudo)."; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

fetch_repo(){
  mkdir -p /tmp
  rm -rf "$WORKDIR"
  if have git; then
    git clone --depth=1 "$REPO_URL" "$WORKDIR" >/dev/null
  else
    yellow "git not found, attempting to install (apt)."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1 || { red "Cannot install git automatically."; exit 1; }
    git clone --depth=1 "$REPO_URL" "$WORKDIR" >/dev/null
  fi
}

# Simple arrow-only menu
menu(){
  local title="$1"; shift
  local -a opts=( "$@" )
  local sel=0 key
  stty -echo -icanon time 0 min 0 || true
  trap 'stty sane' EXIT
  while :; do
    printf "\033c"; printf "%s\n\n" "$(bold "$title")"
    for i in "${!opts[@]}"; do
      if [[ $i -eq $sel ]]; then printf "  \033[7m%s\033[0m\n" "${opts[$i]}"; else printf "  %s\n" "${opts[$i]}"; fi
    done
    IFS= read -rsn1 key
    [[ -z "$key" ]] && continue
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 key
      [[ "$key" == "[A" ]] && ((sel=(sel-1+${#opts[@]})%${#opts[@]}))
      [[ "$key" == "[B" ]] && ((sel=(sel+1)%${#opts[@]}))
    elif [[ "$key" == $'\x0a' || "$key" == $'\x0d' ]]; then
      stty sane; echo "$sel"; return 0
    fi
  done
}

os_brief(){
  . /etc/os-release 2>/dev/null || true
  echo "${NAME:-unknown} ${VERSION_ID:-unknown} / $(uname -m)"
}

# Very light check: warn but allow proceed
soft_compat_check(){
  . /etc/os-release 2>/dev/null || true
  local ok="no"
  case "${ID:-unknown}" in
    ubuntu) [[ "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]] && ok="yes" ;;
    debian) [[ "${VERSION_ID:-}" == "12" ]] && ok="yes" ;;
  esac
  if [[ "$ok" != "yes" || "$(uname -m)" != "x86_64" ]]; then
    yellow "This system may not be fully supported (${NAME:-?} ${VERSION_ID:-?}, arch $(uname -m))."
    local csel
    csel=$(menu "Continue anyway?" "Yes, proceed" "No, back to menu/exit")
    [[ "$csel" -eq 0 ]] || { echo "Aborted."; exit 1; }
  fi
}

detect_leftovers(){
  local found=0
  for p in /var/www/pelican /etc/nginx/sites-available/pelican_panel /etc/pelican; do
    [[ -e "$p" ]] && found=1
  done
  systemctl list-unit-files 2>/dev/null | grep -q '^pelican-queue\.service' && found=1 || true
  systemctl list-unit-files 2>/dev/null | grep -q '^wings\.service' && found=1 || true
  if [[ $found -eq 1 ]]; then
    yellow "Previous installation remnants detected."
    local usel
    usel=$(menu "Run uninstall to clean up first?" "Yes, run uninstall" "No, keep as is")
    if [[ "$usel" -eq 0 ]]; then
      [[ -x "$WORKDIR/uninstall.sh" ]] && bash "$WORKDIR/uninstall.sh" || yellow "uninstall.sh not found yet."
    fi
  fi
}

run_panel(){ bash "$WORKDIR/panel.sh"; }
run_wings(){ [[ -x "$WORKDIR/wings.sh" ]] && bash "$WORKDIR/wings.sh" || yellow "wings.sh not found."; }
run_ssl(){   [[ -x "$WORKDIR/ssl.sh"   ]] && bash "$WORKDIR/ssl.sh"   || yellow "ssl.sh not found."; }
run_update(){[[ -x "$WORKDIR/update.sh"]] && bash "$WORKDIR/update.sh"|| yellow "update.sh not found."; }
run_uninst(){[[ -x "$WORKDIR/uninstall.sh" ]] && bash "$WORKDIR/uninstall.sh" || yellow "uninstall.sh not found."; }

main(){
  require_root
  # If we're not running from /tmp clone, fetch and re-exec from there
  local here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ "$here" != "$WORKDIR" ]]; then
    fetch_repo
    exec "$WORKDIR/install.sh"
  fi

  detect_leftovers

  while :; do
    local choice
    choice=$(menu "Pelican Installer — $(os_brief)" \
      "Install Pelican Panel" \
      "Install Wings (Node Agent)" \
      "Issue/Renew SSL" \
      "Update Panel/Wings" \
      "Uninstall (Clean all)" \
      "Re-sync installer" \
      "Exit")
    case "$choice" in
      0) soft_compat_check; run_panel ;;
      1) soft_compat_check; run_wings ;;
      2) soft_compat_check; run_ssl ;;
      3) soft_compat_check; run_update ;;
      4) run_uninst ;;
      5) fetch_repo; green "Repo refreshed in $WORKDIR" ;;
      6) exit 0 ;;
    esac
    printf "\n"; read -rsn1 -p "Press Enter to return to menu..." _ || true; echo
  done
}
main "$@"
