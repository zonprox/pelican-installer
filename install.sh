#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/zonprox/pelican-installer"
WORKDIR="/tmp/pelican-installer"

# --- tiny helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
os_info() { . /etc/os-release 2>/dev/null || true; OS="${NAME:-unknown}"; VER="${VERSION_ID:-unknown}"; ID_SYS="${ID:-unknown}"; }
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
      if [[ -x "$WORKDIR/uninstall.sh" ]]; then bash "$WORKDIR/uninstall.sh"; else echo "uninstall.sh not found."; exit 1; fi
    fi
  fi
}

compat_notice() {
  os_info
  echo "Detected: ${OS} ${VER}"
  local ARCH; ARCH="$(uname -m)"
  local WARNED=0
  # Soft warnings only — still allow continue
  case "$ARCH" in x86_64|amd64) : ;; *) echo "Note: Your architecture (${ARCH}) may not be well supported."; WARNED=1;; esac
  case "$ID_SYS" in ubuntu|debian) : ;; *) echo "Note: Your OS may not be well supported by Pelican docs."; WARNED=1;; esac
  if (( WARNED )); then
    read -rp "Continue anyway? [y/N]: " c; c="${c:-N}"
    [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi
}

# --- minimal arrow-only menu (blocking read; no numbers) ---
menu() {
  local title="$1"; shift
  local opts=("$@")
  local sel=0 key
  # block until at least 1 byte (fixes the “busy loop” bug)
  stty -echo -icanon min 1 time 0 2>/dev/null || true
  trap 'stty sane 2>/dev/null || true' EXIT
  while true; do
    printf "\033[H\033[2J"  # clear screen
    printf "%s\n\n" "$title"
    for i in "${!opts[@]}"; do
      if [[ $i -eq $sel ]]; then printf "  \033[7m%s\033[0m\n" "${opts[$i]}"; else printf "  %s\n" "${opts[$i]}"; fi
    done
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        # read the rest of the escape sequence quickly
        IFS= read -rsn2 -t 0.05 key
        case "$key" in
          "[A") ((sel=(sel-1+${#opts[@]})%${#opts[@]}));;
          "[B") ((sel=(sel+1)%${#opts[@]}));;
        esac
        ;;
      $'\x0a'|$'\x0d') printf "%s" "$sel"; stty sane 2>/dev/null || true; return;;
      *) : ;;  # ignore any other key
    esac
  done
}

run() {
  local file="$1"
  if [[ -x "$WORKDIR/$file" ]]; then bash "$WORKDIR/$file"; else echo "$file not found. Try re-sync."; fi
  read -rsn1 -p "Press Enter to return to menu..." _ || true; echo
}

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root."; exit 1; }
  # ensure we run from a synced copy in /tmp (repo runs directly, no release)
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
    sel="$(menu "Pelican Installer" "${items[@]}")"
    case "$sel" in
      0) run "panel.sh" ;;
      1) run "wings.sh" ;;
      2) run "ssl.sh" ;;
      3) run "update.sh" ;;
      4) run "uninstall.sh" ;;
      5) fetch_repo; echo "Re-synced."; read -rsn1 -p "Press Enter..." _ || true; echo ;;
      6) echo "Bye."; exit 0 ;;
    esac
  done
}

main "$@"
