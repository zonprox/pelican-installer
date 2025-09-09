#!/bin/bash
# common.sh
# Contains shared functions and variables for the installer scripts.

# --- COLORS ---
# Define color codes for script output.
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# --- HELPER FUNCTIONS FOR OUTPUT ---
# These functions make the output more readable.
print_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

print_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

print_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

# --- OS DETECTION & VALIDATION ---
# Checks if the current OS is supported by Pelican.
# Based on Pelican docs, supported OS are Ubuntu & Debian.
check_os() {
    print_info "Checking operating system compatibility..."

    # Read OS information from /etc/os-release
    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect operating system. /etc/os-release not found."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    # Get the major version number (e.g., '22' from '22.04')
    VERSION_ID_MAJOR=$(echo "$VERSION_ID" | cut -d'.' -f1)

    # List of supported OS and versions
    SUPPORTED=false
    if [ "$ID" == "ubuntu" ]; then
        case "$VERSION_ID_MAJOR" in
            "20"|"22"|"24") SUPPORTED=true ;;
        esac
    elif [ "$ID" == "debian" ]; then
        case "$VERSION_ID_MAJOR" in
            "10"|"11"|"12") SUPPORTED=true ;;
        esac
    fi

    if [ "$SUPPORTED" == "true" ]; then
        print_success "System is compatible: $PRETTY_NAME"
    else
        print_error "Unsupported operating system: $PRETTY_NAME"
        print_error "Supported OS: Ubuntu (20.04, 22.04, 24.04) or Debian (10, 11, 12)."
        exit 1
    fi
}

# --- PRE-INSTALLATION CHECK ---
# Checks for remnants of a previous Pelican installation.
check_for_previous_install() {
    print_info "Checking for previous Pelican installations..."
    if [ -d "/var/www/pelican" ]; then
        print_warning "A directory at /var/www/pelican already exists."
        print_warning "This suggests a previous installation is present."
        read -p "Would you like to continue anyway? This may overwrite existing data. (y/N): " response
        if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            print_error "Installation aborted by user."
            exit 1
        fi
    else
        print_success "No previous installation found."
    fi
}