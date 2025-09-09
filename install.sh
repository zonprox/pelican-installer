#!/bin/bash
# install.sh
# Main entry point for the Pelican Installer script.

# --- GITHUB REPOSITORY ---
# This is where the installer will download the other scripts from.
# Remember to change 'main' to your default branch if it's different.
GITHUB_REPO="https://raw.githubusercontent.com/zonprox/pelican-installer/main/"

# --- SCRIPT NAMES ---
# Names of the script files to be downloaded from the repo.
INITIALIZER_SCRIPT="initializer.sh"
COMMON_SCRIPT="common.sh"
PANEL_SCRIPT="panel.sh"

# --- DOWNLOAD AND EXECUTE ---
# Creates a temporary directory to store the scripts.
# Downloads the necessary scripts from the GitHub repo.
# Sources the common script for shared functions.
setup() {
    # Create a temporary directory for the installer
    INSTALLER_DIR="/tmp/pelican_installer_$$"
    mkdir -p "$INSTALLER_DIR"
    cd "$INSTALLER_DIR" || exit 1

    # Download required scripts
    echo "Downloading installer scripts..."
    for script in "$COMMON_SCRIPT" "$INITIALIZER_SCRIPT" "$PANEL_SCRIPT"; do
        if ! curl -sL "${GITHUB_REPO}${script}" -o "$script"; then
            echo "Error: Failed to download ${script}. Please check your internet connection and the repository URL."
            exit 1
        fi
        chmod +x "$script"
    done

    # Source the common script to use its functions
    # shellcheck source=common.sh
    . ./"$COMMON_SCRIPT"
}

# --- MAIN MENU ---
# Displays the main menu and prompts the user for a choice.
show_menu() {
    clear
    print_info "=========================================="
    print_info "      Pelican Installer Script"
    print_info "=========================================="
    echo
    echo " [1] Install Pelican Panel"
    echo " [2] Install Wings (Not implemented yet)"
    echo " [3] Uninstall Pelican (Not implemented yet)"
    echo " [4] Update Configuration (Not implemented yet)"
    echo " [5] Exit"
    echo
    print_info "------------------------------------------"
}

# --- MAIN LOGIC ---
# Handles the user's choice and calls the appropriate functions.
main() {
    setup

    while true; do
        show_menu
        read -p " Enter your choice [1-5]: " choice
        case $choice in
            1)
                print_info "Starting Pelican Panel installation..."
                ./"$INITIALIZER_SCRIPT"
                # The initializer will call the panel script if checks pass
                ;;
            2|3|4)
                print_warning "This feature is not yet implemented."
                sleep 2
                ;;
            5)
                print_info "Exiting installer. Goodbye!"
                break
                ;;
            *)
                print_error "Invalid option. Please try again."
                sleep 2
                ;;
        esac
    done

    # Cleanup temporary directory
    rm -rf "$INSTALLER_DIR"
}

# --- SCRIPT EXECUTION START ---
# Ensure the script is not run as a subprocess.
if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi