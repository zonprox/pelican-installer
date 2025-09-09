#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Pelican Installer Bootstrap (Entry)
# Author: Zon (zonprox)
# Repo  : https://github.com/zonprox/pelican-installer
# Goal  : Single-line curl entry, fetch repo to /temp/pelican-installer, show menu
# UX    : Arrow-key navigation, numbers as fallback, minimal/no fluff
# Lang  : All prompts in English (per user request)
# ──────────────────────────────────────────────────────────────────────────────

REPO_URL="https://github.com/zonprox/pelican-installer"
RAW_FALLBACK="https://raw.githubusercontent.com/zonprox/pelican-installer/main"
WORKDIR="/temp/pelican-installer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

# Colors (minimal)
bold() { printf "\033[1m%s\033[0m" "$*"; }
dim()  { printf "\033[2m%s\033[0m" "$*"; }
ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
err()  { printf "\033[31m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

fetch_repo() {
  printf "%s\n" "$(bold "Downloading pelican-installer to ${WORKDIR} ...")"
  mkdir -p /temp
  rm -rf "${WORKDIR}"
  if have_cmd git; then
    git clone --depth=1 "${REPO_URL}" "${WORKDIR}" >/dev/null 2>&1 || {
      warn "git clone failed, trying curl+unzip..."
      curl -fsSL "${REPO_URL}/archive/refs/heads/main.zip" -o /tmp/pelican-installer.zip
      have_cmd unzip || apt-get update -y >/dev/null 2>&1 || true
      have_cmd unzip || apt-get install -y unzip >/dev/null 2>&1
      unzip -q /tmp/pelican-installer.zip -d /temp
      mv /temp/pelican-installer-main "${WORKDIR}"
      rm -f /tmp/pelican-installer.zip
    }
  else
    curl -fsSL "${REPO_URL}/archive/refs/heads/main.zip" -o /tmp/pelican-installer.zip
    have_cmd unzip || apt-get update -y >/dev/null 2>&1 || true
    have_cmd unzip || apt-get install -y unzip >/dev/null 2>&1
    unzip -q /tmp/pelican-installer.zip -d /temp
    mv /temp/pelican-installer-main "${WORKDIR}"
    rm -f /tmp/pelican-installer.zip
  fi
  ok "Repository synced to ${WORKDIR}"
}

# ── Preflight: detect remnants and OS compatibility ───────────────────────────
os_info() {
  source /etc/os-release || true
  OS_NAME="${NAME:-unknown}"
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
}

check_systemd() { have_cmd systemctl; }
check_net()     { curl -fsSL https://1.1.1.1 >/dev/null 2>&1; }
arch_ok()       { [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]; }

supported_os() {
  # Keep this tight & explicit to avoid edge conflicts
  case "$OS_ID" in
    ubuntu)
      [[ "$OS_VER" == "22.04" || "$OS_VER" == "24.04" ]] && return 0 || return 1
      ;;
    debian)
      [[ "$OS_VER" == "12" ]] && return 0 || return 1
      ;;
    *) return 1 ;;
  esac
}

detect_leftovers() {
  LEFTOVERS=()
  [[ -d /var/www/pelican ]] && LEFTOVERS+=("/var/www/pelican")
  [[ -f /etc/nginx/sites-available/pelican_panel ]] && LEFTOVERS+=("/etc/nginx/sites-available/pelican_panel")
  systemctl list-unit-files 2>/dev/null | grep -q '^pelican-panel\.service' && LEFTOVERS+=("pelican-panel.service")
  systemctl list-unit-files 2>/dev/null | grep -q '^pelican-queue\.service' && LEFTOVERS+=("pelican-queue.service")
  systemctl list-unit-files 2>/dev/null | grep -q '^wings\.service' && LEFTOVERS+=("wings.service")
  [[ -d /etc/pelican ]] && LEFTOVERS+=("/etc/pelican")
}

suggest_uninstall_if_leftovers() {
  if (( ${#LEFTOVERS[@]} )); then
    warn "Detected remnants from a previous install:"
    for item in "${LEFTOVERS[@]}"; do printf " - %s\n" "$item"; done
    printf "\n"
    read -rp "Run uninstall to clean database/files/services first? [Y/n]: " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if [[ -x "${WORKDIR}/uninstall.sh" ]]; then
        bash "${WORKDIR}/uninstall.sh"
      else
        err "uninstall.sh not found yet. Please sync the repo (option 7) or add uninstall.sh."
        exit 1
      fi
    fi
  fi
}

# ── Arrow-key menu (minimal TUI) ──────────────────────────────────────────────
# Use ↑/↓ to move, Enter to select; numbers 1..n also work.
menu() {
  local title="$1"; shift
  local options=("$@")
  local selected=0 key

  stty -echo -icanon time 0 min 0 || true
  trap 'stty sane; echo' EXIT

  while true; do
    printf "\033c"  # clear screen
    printf "%s\n\n" "$(bold "$title")"
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf "  \033[7m%2d) %s\033[0m\n" "$((i+1))" "${options[$i]}"
      else
        printf "   %2d) %s\n" "$((i+1))" "${options[$i]}"
      fi
    done
    printf "\n%s\n" "$(dim "Use ↑/↓ and Enter. Or press number to choose.")"

    # Read a single key (including arrows)
    IFS= read -rsn1 key
    [[ -z "$key" ]] && continue
    case "$key" in
      [1-9])
        local idx=$((10#$key - 1))
        (( idx >= 0 && idx < ${#options[@]} )) && { selected=$idx; break; }
        ;;
      "") : ;; # ignore
      $'\x1b')
        # possible arrow seq
        IFS= read -rsn2 key
        case "$key" in
          "[A") ((selected = (selected - 1 + ${#options[@]}) % ${#options[@]}));;
          "[B") ((selected = (selected + 1) % ${#options[@]}));;
        esac
        ;;
      "") : ;;
      $'\x0a'|$'\x0d') break ;; # Enter
      *) : ;;
    esac
  done
  stty sane
  echo $selected
}

# ── Main actions ──────────────────────────────────────────────────────────────
run_panel()     { bash "${WORKDIR}/panel.sh"; }
run_wings()     { [[ -x "${WORKDIR}/wings.sh"     ]] && bash "${WORKDIR}/wings.sh"     || warn "wings.sh not found."; }
run_ssl()       { [[ -x "${WORKDIR}/ssl.sh"       ]] && bash "${WORKDIR}/ssl.sh"       || warn "ssl.sh not found."; }
run_update()    { [[ -x "${WORKDIR}/update.sh"    ]] && bash "${WORKDIR}/update.sh"    || warn "update.sh not found."; }
run_uninstall() { [[ -x "${WORKDIR}/uninstall.sh" ]] && bash "${WORKDIR}/uninstall.sh" || warn "uninstall.sh not found."; }

main() {
  require_root
  os_info

  # If we are running from raw curl, ensure repo is fetched first
  if [[ "$SCRIPT_DIR" != "$WORKDIR" ]]; then
    fetch_repo
  fi

  os_info
  check_systemd || { err "systemd is required."; exit 1; }
  arch_ok      || { err "Only x86_64/amd64 is supported."; exit 1; }
  check_net    || { err "No network connectivity."; exit 1; }
  if ! supported_os; then
    err "Supported OS: Ubuntu 22.04/24.04, Debian 12. Detected: ${OS_NAME} ${OS_VER}"
    exit 1
  fi

  detect_leftovers
  suggest_uninstall_if_leftovers

  local choices=(
    "Install Pelican Panel"
    "Install Wings (Node Agent)"
    "Issue/Renew SSL (Let's Encrypt)"
    "Update Panel/Wings"
    "Uninstall (Clean everything)"
    "Re-sync installer to /temp/pelican-installer"
    "Exit"
  )

  while true; do
    sel=$(menu "Pelican Installer — ${OS_NAME} ${OS_VER}" "${choices[@]}")
    case "$sel" in
      0) run_panel ;;
      1) run_wings ;;
      2) run_ssl ;;
      3) run_update ;;
      4) run_uninstall ;;
      5) fetch_repo ;;
      6) ok "Bye!"; exit 0 ;;
      *) : ;;
    esac
    printf "\n%s\n" "$(dim "Press Enter to return to menu...")"; read -r _
  done
}

main "$@"
