#!/bin/bash

# Pelican Panel Installation Script

set -e

# Configuration
INSTALL_DIR="/tmp/pelican-installer"
LOG_FILE="/var/log/pelican-installer.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Error handling
error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a $LOG_FILE
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a $LOG_FILE
}

# Install dependencies
install_dependencies() {
    info "Installing dependencies..."
    
    apt update
    apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg
    
    # Add PHP repository
    add-apt-repository -y ppa:ondrej/php
    apt update
    
    # Install PHP and extensions
    apt install -y php8.3 php8.3-{common,cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,curl,zip,fpm}
    
    # Install other dependencies
    apt install -y nginx mariadb-server mariadb-client
}

# Configure database
setup_database() {
    info "Setting up database..."
    
    # Start MySQL if not running
    systemctl start mariadb
    
    # Create database and user
    mysql -e "CREATE DATABASE pelican;"
    mysql -e "CREATE USER 'pelican'@'127.0.0.1' IDENTIFIED BY 'temp_password';"
    mysql -e "GRANT ALL PRIVILEGES ON pelican.* TO 'pelican'@'127.0.0.1';"
    mysql -e "FLUSH PRIVILEGES;"
}

# Install Pelican Panel
install_panel() {
    info "Installing Pelican Panel..."
    
    # Create installation directory
    mkdir -p /var/www/pelican
    cd /var/www/pelican
    
    # Download and install panel
    curl -Lo panel.tar.gz https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    
    # Install Composer dependencies
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    composer install --no-dev --optimize-autoloader
    
    # Set permissions
    chown -R www-data:www-data /var/www/pelican
}

# Configure environment
setup_environment() {
    info "Configuring environment..."
    
    cd /var/www/pelican
    
    # Copy environment file
    cp .env.example .env
    
    # Generate application key
    php artisan key:generate --force
}

# Display installation summary
show_summary() {
    echo -e "${GREEN}Installation Complete!${NC}"
    echo "======================="
    echo "Panel URL: http://$(hostname -I | awk '{print $1}')"
    echo "Database: pelican"
    echo "Database User: pelican"
    echo "Please remember to:"
    echo "1. Update your .env file with correct database credentials"
    echo "2. Set up your webserver (Nginx configuration)"
    echo "3. Complete the setup through the web interface"
}

# Main execution
main() {
    install_dependencies
    setup_database
    install_panel
    setup_environment
    show_summary
}

main "$@"