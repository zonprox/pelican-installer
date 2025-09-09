#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/zonprox/pelican-installer"
WORKDIR="/tmp/pelican-installer"

# --- tiny helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
os_info() { source /etc/os-release 2>/dev/null || true; OS="${NAME:-unknown}"; VER="${VERSION_ID:-unknown}"; ID_LIKE="${ID:-unknown}"; }
press_enter() { read -rsn1 -p "Press Enter to continue..." _ || true; echo; }

fetch_repo() {
  mkdir -p /tmp
  rm -rf "$WORKDIR"
  if have git; then
    git clone --depth=1 "$REPO_URL" "$WORKDIR" >/dev/null 2>&1 || {
      echo "Git clone failed. Falling back to zip..."
      curl -fsSL "$REPO_URL/archive/refs/heads/main.zip" -o /tmp/pelican-installer.zip
      have unzip || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y unzip >/dev/null 2>&1 || true; }
      unzip -q /tmp/pelican-installer.zip -d /tmp
      mv /tmp/pelican-installer-main "$WORKDIR"
      rm -f /tmp/pelican-installer.zip
    }
  else
    curl -fsSL "$REPO_URL/archive/refs/heads/main.zip" -o /tmp/pelican-installer.zip
    have unzip || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y unzip >/dev/null 2>&1 || true; }
    unzip -q /tmp/pelican-installer.zip -d /tmp
    mv /tmp/pelican-installer-main "$WORKDIR"
    rm -f /tmp/pelican-installer.zip
  fi
}

check_leftovers() {
  LEFT=()
  [[ -d /var/www/pelican ]] && LEFT+=("/var/www/pelican")
  [[ -f /etc/nginx/sites-available/pelican_panel ]] && LEFT+=("/etc/nginx/sites-available/pelican_panel")
  systemctl list-unit-files 2>/dev/null | grep -q '^pelican-queue\.service' && LEFT+=("pelican-queue.service")
  systemctl list-unit-files 2>/dev/null | grep -q '^wings\.service' && LEFT+=("wings.service")

  if (( ${#LEFT[@]} )); then
    echo "Previous installation remnants found:"
    for i in "${LEFT[@]}"; do echo " - $i"; done
    read -rp "Run uninstall to clean first? [y/N]: " a; a="${a:-N}"
    if [[ "$a" =~ ^[Yy]$ ]]; then
      if [[ -x "$WORKDIR/uninstall.sh" ]]; then
        bash "$WORKDIR/uninstall.sh"
      else
        echo "uninstall.sh not found. Please re-sync and try again."
        exit 1
      fi
    fi
  fi
}

compat_notice() {
  os_info
  echo "Detected: ${OS} ${VER}"
  # Soft warnings only, still allow continue
  ARCH="$(uname -m)"
  WARNED=0
  case "$ARCH" in
    x86_64|amd64) : ;;
    *) echo "Note: Your architecture (${ARCH}) may not be well supported."; WARNED=1;;
  esac

  case "${ID_LIKE}" in
    ubuntu|debian) : ;;
    *) echo "Note: Your OS may not be well supported by Pelican docs."; WARNED=1;;
  esac

  [[ "$WARNED" -eq 1 ]] && read -rp "Continue anyway? [y/N]: " c && [[ "${c:-N}" =~ ^[Yy]$ ]] || [[ "$WARNED" -eq 0 ]] || { echo "Aborted."; exit 1; }
}

# --- ultra-minimal arrow menu (no numbers) ---
menu() {
  local title="$1"; shift
  local opts=("$@")
  local sel=0 key
  stty -echo -icanon time 0 min 0 || true
  trap 'stty sane; echo' EXIT
  while true; do
    printf "\033c"; echo "$title"; echo
    for i in "${!opts[@]}"; do
      if [[ $i -eq $sel ]]; then printf "  \033[7m%s\033[0m\n" "${opts[$i]}"; else printf "  %s\n" "${opts[$i]}"; fi
    done
    IFS= read -rsn1 key
    [[ -z "$key" ]] && continue
    case "$key" in
      $'\x1b') IFS= read -rsn2 key; [[ "$key" == "[A" ]] && ((sel=(sel-1+${#opts[@]})%${#opts[@]})); [[ "$key" == "[B" ]] && ((sel=(sel+1)%${#opts[@]}));;
      $'\x0a'|$'\x0d') echo $sel; stty sane; return;;
    esac
  done
}

run() {
  local file="$1"
  if [[ -x "$WORKDIR/$file" ]]; then bash "$WORKDIR/$file"; else echo "$file not found. Try re-sync."; fi
  press_enter
}

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root."; exit 1; }

  # If running from curl, ensure we work from /tmp copy
  [[ "$(dirname "$0")" != "$WORKDIR" ]] && fetch_repo

  compat_notice
  check_leftovers

  local items=(
    "Install Pelican Panel"
    "Install Wings (Node Agent)"
    "Issue/Renew SSL"
    "Update Panel/Wings"
    "Uninstall (Clean all)"
    "Re-sync installer to /tmp/pelican-installer"
    "Exit"
  )

  while true; do
    sel=$(menu "Pelican Installer" "${items[@]}")
    case "$sel" in
      0) run "panel.sh" ;;
      1) run "wings.sh" ;;
      2) run "ssl.sh" ;;
      3) run "update.sh" ;;
      4) run "uninstall.sh" ;;
      5) fetch_repo; echo "Re-synced."; press_enter ;;
      6) echo "Bye."; exit 0 ;;
    esac
  done
}

main "$@"
