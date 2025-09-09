#!/bin/bash
# initializer.sh
# Performs pre-installation checks.

# Source the common script
# shellcheck source=common.sh
. ./common.sh

# Main function for the initializer
main() {
    print_info "--- Running Pre-Installation Checks ---"

    # 1. Check if the script is run as root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root. Please use 'sudo' or log in as root."
        exit 1
    fi
    print_success "Running as root."

    # 2. Check OS compatibility
    check_os

    # 3. Check for previous installations
    check_for_previous_install

    print_success "All pre-installation checks passed."
    print_info "Proceeding to Panel installation setup..."
    sleep 2

    # If all checks pass, execute the panel installer script
    ./panel.sh
}

# --- SCRIPT EXECUTION START ---
if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi