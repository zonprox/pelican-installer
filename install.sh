#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/zonprox/pelican-installer"
WORKDIR="/tmp/pelican-installer"

have() { command -v "$1" >/dev/null 2>&1; }

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

compat_notice() {
  . /etc/os-release 2>/dev/null || true
  local os="${NAME:-unknown}" ver="${VERSION_ID:-unknown}" arch
  arch="$(uname -m)"
  echo "Detected: ${os} ${ver}"
  local warn=0

  case "$arch" in x86_64|amd64) : ;; *) echo "Note: Your architecture (${arch}) may not be well supported."; warn=1;; esac
  case "${ID:-}" in ubuntu|debian) : ;; *) echo "Note: Your OS may not be well supported by Pelican docs."; warn=1;; esac

  if [[ $warn -eq 1 ]]; then
    read -rp "Continue anyway? [y/N]: " c
    [[ "${c:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi
}

check_leftovers() {
  # No systemctl calls (avoids hangs on non-systemd envs)
  LEFT=()
  [[ -d /var/www/pelican ]] && LEFT+=("/var/www/pelican")
  [[ -f /etc/nginx/sites-available/pelican_panel ]] && LEFT+=("/etc/nginx/sites-available/pelican_panel")
  [[ -f /etc/systemd/system/pelican-queue.service ]] && LEFT+=("/etc/systemd/system/pelican-queue.service")
  [[ -f /etc/systemd/system/wings.service ]] && LEFT+=("/etc/systemd/system/wings.service")
  [[ -d /etc/pelican ]] && LEFT+=("/etc/pelican")

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

menu() {
  # Arrow-only minimal TUI (no numbers)
  local title="$1"; shift
  local opts=("$@")
  local sel=0 key

  stty -echo -icanon time 0 min 0 2>/dev/null || true
  trap 'stty sane >/dev/null 2>&1 || true' EXIT

  while true; do
    printf "\033c"; echo "$title"; echo
    for i in "${!opts[@]}"; do
      if [[ $i -eq $sel ]]; then printf "  \033[7m%s\033[0m\n" "${opts[$i]}"; else printf "  %s\n" "${opts[$i]}"; fi
    done
    IFS= read -rsn1 key
    [[ -z "$key" ]] && continue
    case "$key" in
      $'\x1b') IFS= read -rsn2 key; [[ "$key" == "[A" ]] && ((sel=(sel-1+${#opts[@]})%${#opts[@]}));
                               [[ "$key" == "[B" ]] && ((sel=(sel+1)%${#opts[@]}));;
      $'\x0a'|$'\x0d') echo $sel; stty sane >/dev/null 2>&1 || true; return;;
    esac
  done
}

run() {
  local f="$1"
  if [[ -x "$WORKDIR/$f" ]]; then
    bash "$WORKDIR/$f"
  else
    echo "$f not found. Re-sync first."
  fi
  read -rp "Press Enter to return to menu..." _ || true
}

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root."; exit 1; }

  # Ensure we are running from /tmp copy when invoked via curl
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
      5) fetch_repo; echo "Re-synced."; read -rp "Press Enter..." _ ;;
      6) echo "Bye."; exit 0 ;;
    esac
  done
}

main "$@"
