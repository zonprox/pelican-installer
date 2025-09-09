#!/usr/bin/env bash
# install.sh - Pelican smart installer (minimal, arrow-key menu)
# Run via: bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/zonprox/pelican-installer}"
BRANCH="${BRANCH:-main}"
WORKDIR="/tmp/pelican-installer"
SELF_NAME="$(basename "$0")"

# ---------- console / tty ----------
TTY_FD=""
open_tty() {
  # Open /dev/tty for interactive reads, even when stdin is not a TTY (curl|bash)
  if exec {TTY_FD}<>/dev/tty 2>/dev/null; then
    :
  else
    printf "\033[1;31m[✗] Cannot open /dev/tty (interactive terminal required).\033[0m\n"
    printf "Please run this command from a real terminal.\n"
    exit 1
  fi
}

hide_cursor() { printf "\033[?25l"; }
show_cursor() { printf "\033[?25h"; }
clear_lines() { # clear N lines above
  local n=${1:-1}
  for _ in $(seq 1 "$n"); do printf "\033[1A\033[2K"; done
}

# ---------- utils ----------
log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*"; }
hr() { printf "\033[2m%s\033[0m\n" "----------------------------------------"; }

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

press_any() {
  printf "Press any key to continue..." >&1
  # read a single key from /dev/tty
  IFS= read -rsn1 -u "$TTY_FD"
  printf "\n"
}

# Robust arrow-key menu (no numbers). Works even under curl|bash due to /dev/tty
choose_option() {
  local title="$1"; shift
  local options=("$@")
  local selected=0 key

  hide_cursor
  trap 'show_cursor' EXIT

  # initial render
  while true; do
    echo
    printf "\033[1m%s\033[0m\n" "$title"
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf "  \033[7m%s\033[0m\n" "${options[$i]}"
      else
        printf "  %s\n" "${options[$i]}"
      fi
    done

    # wait key from /dev/tty
    IFS= read -rsn1 -u "$TTY_FD" key || key=""
    if [[ $key == $'\x1b' ]]; then
      # read rest of escape sequence
      IFS= read -rsn2 -u "$TTY_FD" key || key=""
      case "$key" in
        "[A") ((selected=(selected-1+${#options[@]})%${#options[@]}));; # up
        "[B") ((selected=(selected+1)%${#options[@]}));;               # down
      esac
    elif [[ $key == "" ]]; then
      # Enter
      echo "$selected"
      return 0
    else
      # Optional vim-like shortcuts
      case "$key" in
        k) ((selected=(selected-1+${#options[@]})%${#options[@]}));;
        j) ((selected=(selected+1)%${#options[@]}));;
      esac
    fi

    # clear previously drawn block: title + options count
    clear_lines $(( ${#options[@]} + 1 ))
  done
}

# ---------- fetch repo into /tmp ----------
fetch_repo() {
  log "Preparing workspace at $WORKDIR"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"

  if has_cmd git; then
    log "Fetching sources via git clone..."
    if ! git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$WORKDIR" >/dev/null 2>&1; then
      warn "git clone failed, trying codeload (tar.gz)"
      curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" \
        | tar -xz -C /tmp
      mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
    fi
  else
    log "git not found, using codeload (tar.gz)..."
    curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" \
      | tar -xz -C /tmp
    mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
  fi
  log "Sources ready in $WORKDIR"
}

# ---------- compatibility check (soft warning) ----------
compat_check() {
  local os_id="" os_like=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi
  if [[ "$os_id" =~ (ubuntu|debian) || "$os_like" =~ (debian|ubuntu) ]]; then
    log "OS check: Debian/Ubuntu family detected."
  else
    warn "Your OS may not be fully supported. You can continue, but things might not work as expected."
  fi
}

# ---------- residue scan ----------
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

# ---------- panel input / review / confirm ----------
prompt_tty() { # usage: prompt_tty "Question: " varname
  local msg="$1"; shift
  local __var="$1"
  printf "%s" "$msg" >&1
  IFS= read -r -u "$TTY_FD" "$__var"
}

collect_panel_inputs() {
  echo
  prompt_tty "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
  prompt_tty "Admin email (for SSL/notifications): " PANEL_EMAIL
  prompt_tty "Timezone (e.g., Asia/Ho_Chi_Minh): " PANEL_TZ
  prompt_tty "DB root password (will be used/created): " DB_ROOT_PASS
  prompt_tty "Panel DB name [pelican]: " PANEL_DB_NAME; PANEL_DB_NAME=${PANEL_DB_NAME:-pelican}
  prompt_tty "Panel DB user [pelican]: " PANEL_DB_USER; PANEL_DB_USER=${PANEL_DB_USER:-pelican}
  prompt_tty "Panel DB user password: " PANEL_DB_PASS

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

# ---------- main menu actions ----------
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

# ---------- menu loop ----------
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

# ---------- entry ----------
need_root
open_tty
compat_check
fetch_repo
scan_residue
main_menu
