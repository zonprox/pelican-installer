#!/bin/bash
# panel.sh
# Handles the complete, automated installation of the Pelican Panel.

# Exit immediately if a command exits with a non-zero status.
set -e

# Source the common script for helper functions (e.g., print_info)
# Ensure common.sh is in the same directory.
if [ -f ./common.sh ]; then
    # shellcheck source=common.sh
    . ./common.sh
else
    echo "Error: common.sh not found. Please ensure it is in the same directory."
    exit 1
fi

# --- GLOBAL VARIABLES ---
# These will be populated by user input.
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
FQDN=""
ADMIN_EMAIL=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""

# --- USER INPUT COLLECTION ---
# Gathers all necessary information from the user before installation.
collect_user_info() {
    print_info "--- 1. Gathering Required Information ---"
    echo "This script will collect all necessary information upfront."
    echo "Default values are shown in parentheses, press Enter to use them."
    echo

    # Database Credentials
    print_info "Please set up the database credentials."
    read -p " Database Name (panel): " DB_NAME
    DB_NAME=${DB_NAME:-panel}

    read -p " Database User (pelican): " DB_USER
    DB_USER=${DB_USER:-pelican}

    read -sp " Database Password (a random password will be generated if left blank): " DB_PASSWORD
    echo
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        print_warning "A random password has been generated for the database user."
    fi

    # Fully Qualified Domain Name (FQDN)
    print_info "\nEnter the domain name for the Panel (e.g., panel.yourdomain.com)."
    while [ -z "$FQDN" ]; do
        read -p " Domain Name: " FQDN
        if [ -z "$FQDN" ]; then
            print_error "Domain Name cannot be empty."
        fi
    done

    # Admin User Account
    print_info "\nCreate an initial administrator account for the Panel."
    while [ -z "$ADMIN_EMAIL" ]; do
        read -p " Admin Email: " ADMIN_EMAIL
    done
    while [ -z "$ADMIN_USERNAME" ]; do
        read -p " Admin Username: " ADMIN_USERNAME
    done
    while [ -z "$ADMIN_PASSWORD" ]; do
        read -sp " Admin Password: " ADMIN_PASSWORD
        echo
        if [ -z "$ADMIN_PASSWORD" ]; then
            print_error "Admin password cannot be empty."
        fi
    done
}

# --- REVIEW AND CONFIRM ---
# Displays the collected information and asks for confirmation.
review_and_confirm() {
    clear
    print_info "=========================================="
    print_info "        Review Installation Details"
    print_info "=========================================="
    echo
    print_info "Database:"
    echo "  - Name:      $DB_NAME"
    echo "  - User:      $DB_USER"
    echo "  - Password:  [hidden]"
    echo
    print_info "Panel Settings:"
    echo "  - Domain:    $FQDN"
    echo
    print_info "Admin Account:"
    echo "  - Email:     $ADMIN_EMAIL"
    echo "  - Username:  $ADMIN_USERNAME"
    echo "  - Password:  [hidden]"
    echo
    print_warning "The installation will begin automatically after confirmation."
    read -p "Is everything correct? [y/N]: " confirmation

    if [[ ! "$confirmation" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        print_error "Installation aborted by user."
        exit 1
    fi
}

# --- INSTALLATION FUNCTIONS ---

# Install essential packages, PHP, Nginx, MariaDB, etc.
install_dependencies() {
    print_info "[INSTALL] Updating package lists..."
    apt-get update -y

    print_info "[INSTALL] Installing essential packages..."
    apt-get install -y software-properties-common curl apt-transport-https ca-certificates gnupg

    print_info "[INSTALL] Adding PPA for PHP 8.3..."
    add-apt-repository -y ppa:ondrej/php

    print_info "[INSTALL] Installing Nginx, MariaDB, Redis, and PHP extensions..."
    apt-get update -y
    apt-get install -y nginx mariadb-server redis-server \
                       php8.3 php8.3-fpm php8.3-common php8.3-mysql php8.3-gd \
                       php8.3-cli php8.3-bcmath php8.3-mbstring php8.3-xml php8.3-curl php8.3-zip \
                       unzip tar git composer

    print_success "All dependencies have been installed."
}

# Secure MariaDB and create the database/user for Pelican.
configure_database() {
    print_info "[SETUP] Configuring MariaDB database..."
    
    # Start and enable MariaDB
    systemctl start mariadb
    systemctl enable mariadb
    
    # Create database and user
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '\`$DB_USER\`'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '\`$DB_USER\`'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    print_success "Database and user created successfully."
}

# Download and set up Pelican panel files.
download_pelican() {
    print_info "[SETUP] Downloading and configuring Pelican Panel..."
    mkdir -p /var/www/pelican
    cd /var/www/pelican || exit 1

    print_info "Downloading Pelican Panel files..."
    curl -L -o pelican.tar.gz https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz
    tar -xzvf pelican.tar.gz
    rm -f pelican.tar.gz
    
    print_info "Installing Composer dependencies..."
    # Run composer as www-data to avoid permission issues
    composer install --no-dev --optimize-autoloader

    print_info "Setting up file permissions..."
    chown -R www-data:www-data /var/www/pelican/*
    
    print_success "Pelican Panel files downloaded and configured."
}

# Configure the .env file with user settings.
configure_pelican_env() {
    print_info "[SETUP] Configuring environment file (.env)..."
    cd /var/www/pelican || exit 1
    
    # Copy example env file
    cp .env.example .env
    
    # Generate app key
    php artisan key:generate --force
    
    # Update .env file
    sed -i "s|APP_URL=http://localhost|APP_URL=https://$FQDN|" .env
    sed -i "s/DB_DATABASE=laravel/DB_DATABASE=$DB_NAME/" .env
    sed -i "s/DB_USERNAME=laravel/DB_USERNAME=$DB_USER/" .env
    sed -i "s/DB_PASSWORD=/DB_PASSWORD=$DB_PASSWORD/" .env

    print_success ".env file configured."
}

# Run database migrations and create the admin user.
run_migrations_and_setup() {
    print_info "[SETUP] Running database migrations and creating admin user..."
    cd /var/www/pelican || exit 1
    
    # Run migrations and seeders
    php artisan migrate --seed --force
    
    # Create the admin user
    php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USERNAME" --password="$ADMIN_PASSWORD" --admin=1 --no-interaction
    
    print_success "Database migrated and admin user created."
}

# Set up the systemd service for the queue worker.
setup_queue_worker() {
    print_info "[SETUP] Setting up queue worker (systemd)..."
    
    cat > /etc/systemd/system/pteroq.service <<-EOF
[Unit]
Description=Pelican Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pelican/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pteroq.service
    
    print_success "Queue worker service created and started."
}

# Configure Nginx to serve the panel.
configure_nginx() {
    print_info "[SETUP] Configuring Nginx web server..."
    
    # Disable default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Create Nginx config file for Pelican
    cat > /etc/nginx/sites-available/pelican.conf <<-EOF
server {
    listen 80;
    server_name $FQDN;

    root /var/www/pelican/public;
    index index.php;

    # security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "origin-when-cross-origin";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    # Block access to sensitive files
    location ~ /\.ht {
        deny all;
    }
}
EOF

    # Enable the site
    ln -s /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
    
    # Test and restart Nginx
    nginx -t
    systemctl restart nginx
    
    print_success "Nginx configured for $FQDN."
}

# --- MAIN INSTALLATION LOGIC ---
# This function orchestrates the entire installation process.
run_installation() {
    print_info "--- 2. Starting Automated Installation ---"
    
    install_dependencies
    configure_database
    download_pelican
    configure_pelican_env
    run_migrations_and_setup
    setup_queue_worker
    configure_nginx

    echo
    print_success "======================================================"
    print_success "       Pelican Panel Installation Completed!"
    print_success "======================================================"
    echo
    print_info "You can now access your panel at: http://$FQDN"
    print_warning "It is highly recommended to configure SSL (HTTPS) for your panel."
    echo
}

# --- SCRIPT ENTRY POINT ---
main() {
    collect_user_info
    review_and_confirm
    run_installation
}

# Execute the main function when the script is run.
if [ "$0" = "$BASH_SOURCE" ]; then
    main
fi