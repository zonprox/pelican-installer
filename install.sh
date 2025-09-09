#!/bin/bash

# Pelican Panel Installer Script
# Simplified version for initial setup
# Supported systems: Ubuntu 20.04+, Debian 10+

set -e  # Exit on error

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
    esac
    
    return 0
}

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