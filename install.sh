#!/usr/bin/env bash
# install.sh - Pelican smart installer (minimal, arrow-key menu) [TTY-safe]
# Run via: bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/zonprox/pelican-installer}"
BRANCH="${BRANCH:-main}"
WORKDIR="/tmp/pelican-installer"
SELF_NAME="$(basename "$0")"

# --------- utils ----------
log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*"; }
hr() { printf "\033[2m%s\033[0m\n" "----------------------------------------"; }

# TTY-safe input: read from keyboard even if script comes from process substitution
TTY_FD=0
open_tty() {
  if [[ -t 0 ]]; then
    TTY_FD=0                 # stdin is a TTY (run from local file)
  elif [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    TTY_FD=3                 # use real terminal
  else
    err "No interactive TTY found. Please run from a terminal."
    exit 1
  fi
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

press_any() {
  printf "Press any key to continue..."
  IFS= read -rsn1 -u "$TTY_FD" _
  echo
}

# Minimal arrow menu (no numbers), TTY-safe
choose_option() {
  # Args: title, options...
  local title="$1"; shift
  local options=("$@")
  local selected=0 key key2
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true; stty echo 2>/dev/null || true; [[ $TTY_FD -eq 3 ]] && exec 3<&-; echo' EXIT

  while true; do
    echo -e "\n\033[1m${title}\033[0m"
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf "  \033[7m%s\033[0m\n" "${options[$i]}"
      else
        printf "  %s\n" "${options[$i]}"
      fi
    done

    IFS= read -rsn1 -u "$TTY_FD" key || key=""
    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn2 -u "$TTY_FD" key2 || key2=""
      case "$key2" in
        "[A") ((selected=(selected-1+${#options[@]})%${#options[@]}));; # up
        "[B") ((selected=(selected+1)%${#options[@]}));;               # down
      esac
    elif [[ -z "$key" ]]; then
      # Enter pressed (or EOF fallback)
      echo "$selected"
      return 0
    fi

    # redraw menu (best effort if tput available)
    if tput cols >/dev/null 2>&1; then
      local lines=$(( ${#options[@]} + 1 ))
      for _ in $(seq 1 $lines); do tput cuu1 2>/dev/null || true; tput el 2>/dev/null || true; done
    else
      clear
    fi
  done
}

# --------- fetch repo into /tmp ----------
fetch_repo() {
  log "Preparing workspace at $WORKDIR"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"

  if has_cmd git; then
    log "Fetching sources via git clone..."
    if ! git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$WORKDIR" >/dev/null 2>&1; then
      warn "git clone failed, trying codeload (tar.gz)"
      curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" | tar -xz -C /tmp
      mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
    fi
  else
    log "git not found, using codeload (tar.gz)..."
    curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" | tar -xz -C /tmp
    mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
  fi
  log "Sources ready in $WORKDIR"
}

# --------- compatibility check (soft warning) ----------
compat_check() {
  local os_id="" os_like=""
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi
  if [[ "$os_id" =~ (ubuntu|debian) || "$os_like" =~ (debian|ubuntu) ]]; then
    log "OS check: Debian/Ubuntu family detected."
  else
    warn "Your OS may not be officially supported. We can continue, but things may not work as expected."
  fi
}

# --------- residue scan ----------
scan_residue() {
  local hits=()
  [[ -d /var/www/pelican ]] && hits+=("/var/www/pelican")
  [[ -d /var/www/pterodactyl ]] && hits+=("/var/www/pterodactyl")
  systemctl list-units --type=service 2>/dev/null | grep -qE 'nginx\.service' && hits+=("nginx")
  systemctl list-units --type=service 2>/dev/null | grep -qE 'mariadb\.service|mysql\.service' && hits+=("mariadb/mysql")
  systemctl list-units --type=service 2>/dev/null | grep -qE 'redis\.service' && hits+=("redis")
  if ((${#hits[@]})); then
    warn "Possible previous installation traces: ${hits[*]}"
    local ans
    ans=$(choose_option "Would you like to run a full cleanup (uninstall) first?" "Yes, run uninstall" "No, continue")
    if [[ $ans -eq 0 ]]; then
      if [[ -x "$WORKDIR/uninstall/uninstall.sh" ]]; then
        bash "$WORKDIR/uninstall/uninstall.sh"
      else
        warn "Uninstall module not found yet. Please add it to $WORKDIR/uninstall/uninstall.sh"
        press_any
      fi
    fi
  fi
}

# --------- panel input/review/confirm (TTY-safe reads) ----------
collect_panel_inputs() {
  echo
  read -u "$TTY_FD" -rp "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
  read -u "$TTY_FD" -rp "Admin email (for SSL/notifications): " PANEL_EMAIL
  read -u "$TTY_FD" -rp "Timezone (e.g., Asia/Ho_Chi_Minh): " PANEL_TZ
  read -u "$TTY_FD" -rp "DB root password (will be used/created): " DB_ROOT_PASS
  read -u "$TTY_FD" -rp "Panel DB name [pelican]: " PANEL_DB_NAME; PANEL_DB_NAME=${PANEL_DB_NAME:-pelican}
  read -u "$TTY_FD" -rp "Panel DB user [pelican]: " PANEL_DB_USER; PANEL_DB_USER=${PANEL_DB_USER:-pelican}
  read -u "$TTY_FD" -rp "Panel DB user password: " PANEL_DB_PASS

  hr
  echo -e "\033[1mReview your settings:\033[0m"
  cat <<EOF
Domain     : $PANEL_DOMAIN
Email      : $PANEL_EMAIL
Timezone   : $PANEL_TZ
DB root    : (hidden)
DB name    : $PANEL_DB_NAME
DB user    : $PANEL_DB_USER
DB pass    : (hidden)
EOF
  hr
  local go
  go=$(choose_option "Proceed with installation?" "Yes, install Panel" "No, go back")
  if [[ $go -ne 0 ]]; then
    warn "Cancelled by user."
    return 1
  fi
  export PANEL_DOMAIN PANEL_EMAIL PANEL_TZ DB_ROOT_PASS PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS
  return 0
}

run_panel_install() {
  if [[ -x "$WORKDIR/panel/panel.sh" ]]; then
    bash "$WORKDIR/panel/panel.sh"
  else
    err "panel.sh not found at $WORKDIR/panel/panel.sh"
    exit 1
  fi
}

# --------- main menu actions ----------
action_panel() {
  if collect_panel_inputs; then
    run_panel_install
    echo
    log "Panel installation completed (script finished)."
    echo "URL     : https://${PANEL_DOMAIN}"
    echo "Docs    : https://pelican.dev/docs"
    hr
    press_any
  fi
}

coming_soon() {
  warn "This module will be added next. For now, it's a placeholder."
  press_any
}

# --------- menu loop ----------
main_menu() {
  while true; do
    clear
    echo -e "\033[1mPelican Installer\033[0m"
    hr
    echo "Use ↑/↓ to navigate, Enter to select."
    local idx
    idx=$(choose_option "Select an action:" \
      "Install Panel" \
      "Install Wings (coming soon)" \
      "Setup SSL (coming soon)" \
      "Update (coming soon)" \
      "Uninstall (coming soon)" \
      "Exit")
    case "$idx" in
      0) action_panel ;;
      1) coming_soon ;;
      2) coming_soon ;;
      3) coming_soon ;;
      4) coming_soon ;;
      5) clear; exit 0;;
    esac
  done
}

# --------- entry ----------
need_root
open_tty
compat_check
fetch_repo
scan_residue
main_menu
