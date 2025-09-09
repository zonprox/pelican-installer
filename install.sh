#!/bin/bash

# Pelican Panel Installer Script
# Simplified version for initial setup
# Supported systems: Ubuntu 20.04+, Debian 10+

set -e  # Exit on error

<<<<<<< HEAD
<<<<<<< HEAD
<<<<<<< HEAD
# Configuration
INSTALL_DIR="/tmp/pelican-installer"
REPO_URL="https://raw.githubusercontent.com/zonprox/pelican-installer/main"
LOG_FILE="/var/log/pelican-installer.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   exit 1
fi

# Create temporary directory
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Function to display error messages
error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE
}

# Function to display success messages
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a $LOG_FILE
}

# Function to display warnings
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a $LOG_FILE
}

# Function to display info
info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a $LOG_FILE
}

# Check system compatibility
check_system() {
    info "Checking system compatibility..."
    
    # Check OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        error "Cannot determine OS version"
        return 1
    fi
    
    # Check compatibility
    case $OS in
        "Ubuntu")
            if [[ "$VER" != "20.04" && "$VER" != "22.04" && "$VER" != "24.04" ]]; then
                warning "Ubuntu $VER is not officially supported. Continue at your own risk."
            fi
            ;;
        "Debian GNU/Linux")
            if [[ "$VER" != "10" && "$VER" != "11" && "$VER" != "12" ]]; then
                warning "Debian $VER is not officially supported. Continue at your own risk."
            fi
            ;;
        *)
            warning "$OS is not officially supported. Continue at your own risk."
            ;;
=======
=======
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
=======
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
# --------- utils ----------
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

press_any() { read -rsn1 -p "Press any key to continue..."; echo; }

# Minimal arrow menu (no numbers)
choose_option() {
  # Args: title, options...
  local title="$1"; shift
  local options=("$@")
  local selected=0 key
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true; stty echo 2>/dev/null || true; echo' EXIT

  while true; do
    echo -e "\n\033[1m${title}\033[0m"
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf "  \033[7m%s\033[0m\n" "${options[$i]}"
      else
        printf "  %s\n" "${options[$i]}"
      fi
    done
    IFS= read -rsn1 key
    # handle arrows
    if [[ $key == $'\x1b' ]]; then
      read -rsn2 key
      case "$key" in
        "[A") ((selected=(selected-1+${#options[@]})%${#options[@]}));; # up
        "[B") ((selected=(selected+1)%${#options[@]}));;               # down
      esac
    elif [[ $key == "" ]]; then
      echo "$selected"
      return 0
    fi
    # clear menu (move up lines)
    local lines=$(( ${#options[@]} + 1 ))
    for _ in $(seq 1 $lines); do tput cuu1; tput el; done
  done
}

# --------- fetch repo into /tmp ----------
fetch_repo() {
  log "Preparing workspace at $WORKDIR"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"

  if has_cmd git; then
    log "Fetching sources via git clone..."
    git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$WORKDIR" >/dev/null 2>&1 || {
      warn "git clone failed, trying codeload (tar.gz)"
      curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" \
        | tar -xz -C /tmp
      mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
    }
  else
    log "git not found, using codeload (tar.gz)..."
    curl -fsSL "https://codeload.github.com/zonprox/pelican-installer/tar.gz/refs/heads/$BRANCH" \
      | tar -xz -C /tmp
    mv "/tmp/pelican-installer-$BRANCH" "$WORKDIR"
  fi
  log "Sources ready in $WORKDIR"
}

# --------- compatibility check (soft warning) ----------
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
    warn "Your OS is not officially listed as Debian/Ubuntu.
We will proceed if you choose to continue, but things may not work as expected."
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

# --------- panel input/review/confirm ----------
collect_panel_inputs() {
  echo
  read -rp "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
  read -rp "Admin email (for SSL/notifications): " PANEL_EMAIL
  read -rp "Timezone (e.g., Asia/Ho_Chi_Minh): " PANEL_TZ
  read -rp "DB root password (will be used/created): " DB_ROOT_PASS
  read -rp "Panel DB name [pelican]: " PANEL_DB_NAME; PANEL_DB_NAME=${PANEL_DB_NAME:-pelican}
  read -rp "Panel DB user [pelican]: " PANEL_DB_USER; PANEL_DB_USER=${PANEL_DB_USER:-pelican}
  read -rp "Panel DB user password: " PANEL_DB_PASS

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
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
    esac
    
    return 0
}

<<<<<<< HEAD
<<<<<<< HEAD
<<<<<<< HEAD
# Check for existing installation
check_existing() {
    info "Checking for existing installation..."
    
    if [[ -d "/var/www/pelican" ]]; then
        warning "Found existing Pelican installation in /var/www/pelican"
        read -p "Do you want to run uninstall first? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            run_uninstall
        fi
    fi
}

# Download necessary scripts
download_scripts() {
    info "Downloading installation scripts..."
    
    scripts=("panel.sh" "wings.sh" "ssl.sh" "update.sh" "uninstall.sh")
    
    for script in "${scripts[@]}"; do
        if curl -sSf "$REPO_URL/$script" -o "$INSTALL_DIR/$script"; then
            chmod +x "$INSTALL_DIR/$script"
            success "Downloaded $script"
        else
            error "Failed to download $script"
            return 1
        fi
    done
    
    return 0
}

# Run panel installation
run_panel() {
    info "Starting panel installation..."
    bash "$INSTALL_DIR/panel.sh"
}

# Run uninstall
run_uninstall() {
    info "Starting uninstallation..."
    bash "$INSTALL_DIR/uninstall.sh"
}

# Display main menu
show_menu() {
    echo -e "\n${GREEN}Pelican Panel Installer${NC}"
    echo "========================"
    echo "1) Install Panel"
    echo "2) Install Wings"
    echo "3) Configure SSL"
    echo "4) Update"
    echo "5) Uninstall"
    echo "6) Exit"
    echo
}

# Process user input
process_menu() {
    while true; do
        show_menu
        read -p "Please select an option (1-6): " choice
        
        case $choice in
            1)
                run_panel
                ;;
            2)
                info "Wings installation will be available soon"
                ;;
            3)
                info "SSL configuration will be available soon"
                ;;
            4)
                info "Update functionality will be available soon"
                ;;
            5)
                run_uninstall
                ;;
            6)
                info "Goodbye!"
                exit 0
                ;;
            *)
                error "Invalid option. Please try again."
                ;;
        esac
        
        echo
        read -p "Press any key to continue..." -n 1 -r
        echo
    done
}

# Main execution
main() {
    echo -e "${GREEN}Pelican Panel Installer${NC}"
    echo "==============================="
    
    # Check system compatibility
    if ! check_system; then
        error "System compatibility check failed"
        exit 1
    fi
    
    # Check for existing installation
    check_existing
    
    # Download scripts
    if ! download_scripts; then
        error "Failed to download necessary scripts"
        exit 1
    fi
    
    # Show menu
    process_menu
}

# Run main function
main "$@"
=======
=======
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
=======
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
# --------- entry ----------
need_root
compat_check
fetch_repo
scan_residue
main_menu
>>>>>>> parent of 80219d2 (vá đọc phím từ /dev/tty)
