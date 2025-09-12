#!/bin/bash
# Pelican Panel Installation Script
# Supports Debian 12, Ubuntu 22.04, and Ubuntu 24.04
# Requires PHP 8.4 and MariaDB

# Text formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="/var/log/pelican_install.log"
CONFIG_FILE="/etc/pelican_install.conf"

# Default values
DEFAULT_DB_NAME="pelican"
DEFAULT_DB_USER="pelican_user"
DEFAULT_DB_HOST="localhost"
DEFAULT_REDIS_HOST="localhost"
DEFAULT_REDIS_PORT="6379"
DEFAULT_APP_URL="https://"
DEFAULT_APP_TIMEZONE="UTC"
DEFAULT_ADMIN_USERNAME="admin"

# Configuration variables
DOMAIN=""
SSL_TYPE="" # letsencrypt, custom, none
SSL_CERT_PATH=""
SSL_KEY_PATH=""
SSL_CERT_CONTENT=""
SSL_KEY_CONTENT=""
DB_PASSWORD=""
REDIS_PASSWORD=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
APP_KEY=""
USE_CLOUDFLARE=false

# Installation flags
HAS_ERROR=0
VALID_DOMAIN=0
VALID_EMAIL=0
VALID_DB=0
VALID_REDIS=0

# Detect OS
OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: $1" >> "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS: $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >> "$LOG_FILE"
    HAS_ERROR=1
}

# Function to check exit code
check_exit() {
    if [ $? -ne 0 ]; then
        print_error "$1"
        rollback_installation
        exit 1
    fi
}

# Function to validate domain
validate_domain() {
    local domain_pattern='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    if [[ $1 =~ $domain_pattern ]] || [[ $1 == "localhost" ]]; then
        # Check DNS resolution
        if host "$1" &> /dev/null || [[ $1 == "localhost" ]]; then
            VALID_DOMAIN=1
            return 0
        else
            print_warning "Domain $1 does not resolve to an IP address"
            read -rp "Continue anyway? (y/n): " continue_choice
            if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
                VALID_DOMAIN=1
                return 0
            fi
        fi
    fi
    return 1
}

# Function to validate email
validate_email() {
    local email_pattern='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    if [[ $1 =~ $email_pattern ]]; then
        VALID_EMAIL=1
        return 0
    fi
    return 1
}

# Function to check MySQL connection
check_mysql_connection() {
    if mysql -u"$DEFAULT_DB_USER" -p"$DB_PASSWORD" -h"$DEFAULT_DB_HOST" -e "SELECT 1;" &> /dev/null; then
        VALID_DB=1
        return 0
    fi
    return 1
}

# Function to check Redis connection
check_redis_connection() {
    if command -v redis-cli &> /dev/null; then
        if [ -z "$REDIS_PASSWORD" ]; then
            if redis-cli -h "$DEFAULT_REDIS_HOST" -p "$DEFAULT_REDIS_PORT" ping &> /dev/null; then
                VALID_REDIS=1
                return 0
            fi
        else
            if redis-cli -h "$DEFAULT_REDIS_HOST" -p "$DEFAULT_REDIS_PORT" -a "$REDIS_PASSWORD" ping &> /dev/null; then
                VALID_REDIS=1
                return 0
            fi
        fi
    fi
    return 1
}

# Function to generate random password
generate_password() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+{}|:<>?=' < /dev/urandom | head -c "$length" | xargs
}

# Function to generate secure app key
generate_app_key() {
    echo "base64:$(openssl rand -base64 32)"
}

# Function to check for existing installation
check_existing_installation() {
    if [ -d "/var/www/pelican" ]; then
        print_warning "Existing Pelican installation detected."
        read -rp "Backup existing installation? (y/n): " backup_choice
        if [[ "$backup_choice" =~ ^[Yy]$ ]]; then
            backup_dir="/var/www/pelican_backup_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir"
            cp -r /var/www/pelican/* "$backup_dir/"
            print_status "Existing installation backed up to $backup_dir"
        fi
    fi
}

# Function to add PHP repository
add_php_repository() {
    print_status "Adding PHP repository..."
    
    # Install prerequisites
    apt install -y software-properties-common apt-transport-https lsb-release ca-certificates curl gnupg >> "$LOG_FILE" 2>&1
    
    # Different methods for different distributions
    if [[ "$OS_ID" == "ubuntu" ]]; then
        # Ubuntu - use PPA
        LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y >> "$LOG_FILE" 2>&1
    elif [[ "$OS_ID" == "debian" ]]; then
        # Debian - use Sury repository
        curl -sSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php.gpg
        echo "deb [signed-by=/usr/share/keyrings/php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    else
        print_error "Unsupported operating system: $OS_ID"
        exit 1
    fi
    
    apt update >> "$LOG_FILE" 2>&1
    check_exit "Failed to add PHP repository"
    print_success "PHP repository added"
}

# Function to install PHP 8.4
install_php() {
    print_status "Installing PHP 8.4 and extensions..."
    
    # Add PHP repository
    add_php_repository
    
    # Install PHP 8.4 and required extensions
    apt install -y php8.4 php8.4-cli php8.4-fpm php8.4-common php8.4-mysql \
    php8.4-mbstring php8.4-xml php8.4-bcmath php8.4-curl php8.4-zip \
    php8.4-gd php8.4-intl php8.4-sqlite3 >> "$LOG_FILE" 2>&1
    
    # Check if PHP 8.4 packages are available, fall back to available version if not
    if [ $? -ne 0 ]; then
        print_warning "PHP 8.4 not available, trying to install available PHP version"
        
        # Determine available PHP version
        PHP_VERSION=$(apt-cache search '^php[0-9]' | grep -o 'php[0-9]\.[0-9]' | sort -V | tail -n1)
        
        if [ -z "$PHP_VERSION" ]; then
            print_error "No PHP version found"
            exit 1
        fi
        
        print_status "Installing $PHP_VERSION instead of PHP 8.4"
        
        # Install available PHP version
        apt install -y $PHP_VERSION $PHP_VERSION-cli $PHP_VERSION-fpm $PHP_VERSION-common $PHP_VERSION-mysql \
        $PHP_VERSION-mbstring $PHP_VERSION-xml $PHP_VERSION-bcmath $PHP_VERSION-curl $PHP_VERSION-zip \
        $PHP_VERSION-gd $PHP_VERSION-intl $PHP_VERSION-sqlite3 >> "$LOG_FILE" 2>&1
        check_exit "Failed to install PHP $PHP_VERSION and extensions"
    else
        print_success "PHP 8.4 and extensions installed"
    fi
    
    # Enable and start PHP-FPM
    systemctl enable php8.4-fpm >> "$LOG_FILE" 2>&1
    systemctl start php8.4-fpm >> "$LOG_FILE" 2>&1
    
    # Adjust PHP-FPM configuration to prevent timeout
    PHP_FPM_POOL_FILE="/etc/php/8.4/fpm/pool.d/www.conf"
    if [ -f "$PHP_FPM_POOL_FILE" ]; then
        sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 600/' $PHP_FPM_POOL_FILE
        sed -i 's/^request_terminate_timeout = .*/request_terminate_timeout = 600/' $PHP_FPM_POOL_FILE
        # If the line doesn't exist, add it
        if ! grep -q "request_terminate_timeout" $PHP_FPM_POOL_FILE; then
            echo "request_terminate_timeout = 600" >> $PHP_FPM_POOL_FILE
        fi
        systemctl restart php8.4-fpm
        print_status "Adjusted PHP-FPM timeout to 600 seconds"
    else
        print_warning "PHP 8.4 FPM pool file not found, skipping timeout adjustment"
    fi
    
    print_success "PHP installed and configured"
}

# Function to install MariaDB
install_mariadb() {
    print_status "Installing MariaDB..."
    # Install MariaDB
    apt install -y mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
    check_exit "Failed to install MariaDB"
    # Start and enable MariaDB
    systemctl start mariadb >> "$LOG_FILE" 2>&1
    systemctl enable mariadb >> "$LOG_FILE" 2>&1
    # Secure MariaDB installation
    print_status "Securing MariaDB installation..."
    
    # Check if MySQL root password is already set
    if mysql -u root -e "SELECT 1;" &> /dev/null; then
        # Set root password if not set
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" >> "$LOG_FILE" 2>&1
    fi
    
    mysql -u root -p"$DB_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS test;" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1
    # Create database and user
    mysql -u root -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $DEFAULT_DB_NAME;" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "CREATE USER IF NOT EXISTS '$DEFAULT_DB_USER'@'$DEFAULT_DB_HOST' IDENTIFIED BY '$DB_PASSWORD';" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DEFAULT_DB_NAME.* TO '$DEFAULT_DB_USER'@'$DEFAULT_DB_HOST';" >> "$LOG_FILE" 2>&1
    mysql -u root -p"$DB_PASSWORD" -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1
    print_success "MariaDB installed and secured"
}

# Function to install Redis
install_redis() {
    print_status "Installing Redis..."
    apt install -y redis-server >> "$LOG_FILE" 2>&1
    check_exit "Failed to install Redis"
    # Configure Redis
    sed -i 's/bind 127.0.0.1 ::1/bind 0.0.0.0/' /etc/redis/redis.conf
    if [ -n "$REDIS_PASSWORD" ]; then
        sed -i "s/# requirepass foobared/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
    fi
    # Additional Redis security
    sed -i 's/supervised no/supervised systemd/' /etc/redis/redis.conf
    sed -i 's/# rename-command CONFIG ""/rename-command CONFIG ""/' /etc/redis/redis.conf
    echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf
    systemctl restart redis >> "$LOG_FILE" 2>&1
    systemctl enable redis >> "$LOG_FILE" 2>&1
    print_success "Redis installed and configured"
}

# Function to install Nginx
install_nginx() {
    print_status "Installing Nginx..."
    apt install -y nginx >> "$LOG_FILE" 2>&1
    check_exit "Failed to install Nginx"
    print_success "Nginx installed"
}

# Function to generate SSL with Let's Encrypt
generate_ssl() {
    print_status "Generating SSL certificate with Let's Encrypt..."
    apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
    check_exit "Failed to install Certbot"
    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email >> "$LOG_FILE" 2>&1
    check_exit "Failed to generate SSL certificate"
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    print_success "SSL certificate generated"
}

# Function to setup custom SSL
setup_custom_ssl() {
    print_status "Setting up custom SSL certificate..."
    # Create directory for SSL certificates
    mkdir -p /etc/ssl/private/ >> "$LOG_FILE" 2>&1
    mkdir -p /etc/ssl/certs/ >> "$LOG_FILE" 2>&1
    # Write certificate content to files
    echo "$SSL_CERT_CONTENT" > "/etc/ssl/certs/$DOMAIN.crt"
    echo "$SSL_KEY_CONTENT" > "/etc/ssl/private/$DOMAIN.key"
    SSL_CERT_PATH="/etc/ssl/certs/$DOMAIN.crt"
    SSL_KEY_PATH="/etc/ssl/private/$DOMAIN.key"
    print_success "Custom SSL certificate set up"
}

# Function to configure Cloudflare real IP
configure_cloudflare() {
    print_status "Configuring Cloudflare real IP..."
    # Download Cloudflare IP ranges
    CLOUDFLARE_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
    CLOUDFLARE_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)
    
    # Create Nginx configuration for Cloudflare
    cat > /etc/nginx/conf.d/cloudflare.conf << EOF
# Cloudflare real IP configuration
real_ip_header X-Forwarded-For;
real_ip_recursive on;
EOF
    
    # Add IPv4 addresses
    for ip in $CLOUDFLARE_IPV4; do
        echo "set_real_ip_from $ip;" >> /etc/nginx/conf.d/cloudflare.conf
    done
    
    # Add IPv6 addresses
    for ip in $CLOUDFLARE_IPV6; do
        echo "set_real_ip_from $ip;" >> /etc/nginx/conf.d/cloudflare.conf
    done
    
    print_success "Cloudflare real IP configured"
}

# Function to configure Nginx
configure_nginx() {
    print_status "Configuring Nginx..."
    # Remove default configuration
    rm -f /etc/nginx/sites-enabled/default >> "$LOG_FILE" 2>&1
    
    # Configure Cloudflare if enabled
    if [ "$USE_CLOUDFLARE" = true ]; then
        configure_cloudflare
    fi
    
    # Create Nginx configuration based on SSL type
    if [ "$SSL_TYPE" = "none" ]; then
        cat > /etc/nginx/sites-available/pelican.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/pelican/public;
    index index.php;
    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    
    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
        include /etc/nginx/fastcgi_params;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
EOF
    else
        cat > /etc/nginx/sites-available/pelican.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root /var/www/pelican/public;
    index index.php;
    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    
    # SSL configuration
    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;
    
    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 600;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
        include /etc/nginx/fastcgi_params;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
EOF
    fi
    
    # Enable site
    ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/ >> "$LOG_FILE" 2>&1
    
    # Test Nginx configuration
    nginx -t >> "$LOG_FILE" 2>&1
    check_exit "Nginx configuration test failed"
    
    # Restart Nginx
    systemctl restart nginx >> "$LOG_FILE" 2>&1
    check_exit "Failed to restart Nginx"
    
    print_success "Nginx configured"
}

# Function to install Pelican Panel
install_pelican() {
    print_status "Installing Pelican Panel..."
    # Create directory
    mkdir -p /var/www/pelican >> "$LOG_FILE" 2>&1
    cd /var/www/pelican >> "$LOG_FILE" 2>&1
    
    # Download latest release
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv >> "$LOG_FILE" 2>&1
    check_exit "Failed to download Pelican Panel"
    
    # Install Composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >> "$LOG_FILE" 2>&1
    check_exit "Failed to install Composer"
    
    # Install PHP dependencies
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader >> "$LOG_FILE" 2>&1
    check_exit "Failed to install PHP dependencies"
    
    # Set permissions
    chown -R www-data:www-data /var/www/pelican >> "$LOG_FILE" 2>&1
    chmod -R 755 storage/* bootstrap/cache/ >> "$LOG_FILE" 2>&1
    
    # Create environment file
    cat > .env << EOF
APP_ENV=production
APP_KEY=$APP_KEY
APP_URL=$DEFAULT_APP_URL$DOMAIN
APP_TIMEZONE=$DEFAULT_APP_TIMEZONE
DB_HOST=$DEFAULT_DB_HOST
DB_DATABASE=$DEFAULT_DB_NAME
DB_USERNAME=$DEFAULT_DB_USER
DB_PASSWORD=$DB_PASSWORD
REDIS_HOST=$DEFAULT_REDIS_HOST
REDIS_PORT=$DEFAULT_REDIS_PORT
REDIS_PASSWORD=$REDIS_PASSWORD
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
EOF
    
    # Generate application key only if not already set
    if ! grep -q '^APP_KEY=base64:' .env; then
        print_status "Generating application key..."
        php artisan key:generate --force >> "$LOG_FILE" 2>&1
        check_exit "Failed to generate application key"
    else
        print_status "Application key already set, skipping generation..."
    fi
    
    # Setup environment by directly modifying the .env file
    print_status "Setting up environment..."
    
    # Update the .env file with all configuration values
    sed -i "s|APP_URL=.*|APP_URL=$DEFAULT_APP_URL$DOMAIN|" .env
    sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$DEFAULT_APP_TIMEZONE|" .env
    sed -i "s|DB_HOST=.*|DB_HOST=$DEFAULT_DB_HOST|" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DEFAULT_DB_NAME|" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DEFAULT_DB_USER|" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" .env
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=$DEFAULT_REDIS_HOST|" .env
    sed -i "s|REDIS_PORT=.*|REDIS_PORT=$DEFAULT_REDIS_PORT|" .env
    
    if [ -n "$REDIS_PASSWORD" ]; then
        sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=$REDIS_PASSWORD|" .env
    else
        sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=|" .env
    fi
    
    sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
    sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
    sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
    
    # Cache configuration
    php artisan config:cache >> "$LOG_FILE" 2>&1
    
    print_success "Environment setup completed"
    
    # Database migration
    print_status "Running database migrations..."
    php artisan migrate --force --seed >> "$LOG_FILE" 2>&1
    check_exit "Failed to migrate database"
    
    # Create admin user
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(generate_password)
    fi
    print_status "Creating admin user..."
    php artisan p:user:make --username="$DEFAULT_ADMIN_USERNAME" --email="$ADMIN_EMAIL" \
    --password="$ADMIN_PASSWORD" --admin=1 >> "$LOG_FILE" 2>&1
    check_exit "Failed to create admin user"
    
    print_success "Pelican Panel installed"
}

# Function to configure firewall
configure_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        print_status "Configuring firewall..."
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 22/tcp
        ufw --force enable
        print_success "Firewall configured"
    fi
}

# Function to setup log rotation
setup_logrotate() {
    print_status "Setting up log rotation..."
    cat > /etc/logrotate.d/pelican << EOF
/var/log/nginx/pelican*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1
    endscript
}
EOF
    print_success "Log rotation configured"
}

# Function to harden security
harden_security() {
    print_status "Applying security hardening..."
    # Restrict database user privileges
    mysql -u root -p"$DB_PASSWORD" -e "REVOKE ALL PRIVILEGES ON *.* FROM '$DEFAULT_DB_USER'@'$DEFAULT_DB_HOST';" 2>/dev/null
    mysql -u root -p"$DB_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DEFAULT_DB_NAME.* TO '$DEFAULT_DB_USER'@'$DEFAULT_DB_HOST';" 2>/dev/null
    
    # Set strict permissions
    chmod 600 /etc/ssl/private/* 2>/dev/null
    chmod 644 /etc/ssl/certs/* 2>/dev/null
    
    # Create .htaccess protection for sensitive directories
    cat > /var/www/pelican/public/.htaccess << EOF
Order deny,allow
Deny from all
EOF
    
    print_success "Security hardening completed"
}

# Function to check service status
check_service_status() {
    local service_name=$1
    if systemctl is-active --quiet $service_name; then
        print_success "$service_name is running"
    else
        print_error "$service_name is not running"
        systemctl status $service_name >> "$LOG_FILE" 2>&1
        return 1
    fi
}

# Function to rollback installation
rollback_installation() {
    print_error "Installation failed. Performing rollback..."
    # Remove created files and databases
    mysql -u root -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS $DEFAULT_DB_NAME;" 2>/dev/null
    mysql -u root -p"$DB_PASSWORD" -e "DROP USER IF EXISTS '$DEFAULT_DB_USER'@'$DEFAULT_DB_HOST';" 2>/dev/null
    rm -rf /var/www/pelican
    rm -f /etc/nginx/sites-available/pelican.conf
    rm -f /etc/nginx/sites-enabled/pelican.conf
    rm -f /etc/nginx/conf.d/cloudflare.conf
    systemctl reload nginx
    print_status "Rollback completed"
}

# Function to display installation summary
display_summary() {
    echo -e "${BOLD}Installation Summary:${NC}"
    echo -e "Domain: ${GREEN}$DOMAIN${NC}"
    echo -e "SSL Type: ${GREEN}$SSL_TYPE${NC}"
    if [ "$SSL_TYPE" = "custom" ]; then
        echo -e "SSL Certificate: ${GREEN}Custom${NC}"
        echo -e "SSL Key: ${GREEN}Custom${NC}"
    fi
    echo -e "Database: ${GREEN}MariaDB${NC}"
    echo -e "Database Name: ${GREEN}$DEFAULT_DB_NAME${NC}"
    echo -e "Database User: ${GREEN}$DEFAULT_DB_USER${NC}"
    echo -e "Redis Host: ${GREEN}$DEFAULT_REDIS_HOST${NC}"
    echo -e "Redis Port: ${GREEN}$DEFAULT_REDIS_PORT${NC}"
    echo -e "Admin Username: ${GREEN}$DEFAULT_ADMIN_USERNAME${NC}"
    echo -e "Admin Email: ${GREEN}$ADMIN_EMAIL${NC}"
    echo -e "Admin Password: ${GREEN}$ADMIN_PASSWORD${NC}"
    echo -e "App URL: ${GREEN}$DEFAULT_APP_URL$DOMAIN${NC}"
    echo -e "App Timezone: ${GREEN}$DEFAULT_APP_TIMEZONE${NC}"
    echo -e "Log File: ${GREEN}$LOG_FILE${NC}"
    echo -e "Cloudflare Proxy: ${GREEN}$USE_CLOUDFLARE${NC}"
}

# Function to save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
DOMAIN="$DOMAIN"
SSL_TYPE="$SSL_TYPE"
SSL_CERT_PATH="$SSL_CERT_PATH"
SSL_KEY_PATH="$SSL_KEY_PATH"
DB_PASSWORD="$DB_PASSWORD"
REDIS_PASSWORD="$REDIS_PASSWORD"
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
APP_KEY="$APP_KEY"
USE_CLOUDFLARE="$USE_CLOUDFLARE"
EOF
    chmod 600 "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE"
}

# Main execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root"
        exit 1
    fi
    
    # Check OS compatibility
    if ! grep -q -E "Debian GNU/Linux 12|Ubuntu 22.04|Ubuntu 24.04" /etc/os-release; then
        print_error "Unsupported OS. This script only supports Debian 12, Ubuntu 22.04, and Ubuntu 24.04"
        exit 1
    fi
    
    # Create log file
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    print_status "Starting Pelican Panel installation. Log file: $LOG_FILE"
    
    # Check for existing installation
    check_existing_installation
    
    # Gather user input
    echo -e "${BOLD}Pelican Panel Installation${NC}"
    echo -e "This script will install Pelican Panel on your server."
    echo
    
    # Domain input
    while true; do
        read -rp "Enter your domain (e.g., panel.example.com): " DOMAIN
        if validate_domain "$DOMAIN"; then
            break
        else
            print_error "Invalid domain. Please try again."
        fi
    done
    
    # Cloudflare proxy
    read -rp "Is your domain behind Cloudflare proxy? (y/n): " cloudflare_choice
    if [[ "$cloudflare_choice" =~ ^[Yy]$ ]]; then
        USE_CLOUDFLARE=true
    fi
    
    # SSL type selection
    echo -e "Select SSL option:"
    echo -e "1) Let's Encrypt (automated SSL)"
    echo -e "2) Custom SSL (provide your own certificate)"
    echo -e "3) No SSL (not recommended)"
    while true; do
        read -rp "Enter choice [1-3]: " ssl_choice
        case $ssl_choice in
            1) SSL_TYPE="letsencrypt"; break ;;
            2) SSL_TYPE="custom"; break ;;
            3) SSL_TYPE="none"; break ;;
            *) print_error "Invalid choice. Please try again." ;;
        esac
    done
    
    # Custom SSL handling
    if [ "$SSL_TYPE" = "custom" ]; then
        echo -e "Select certificate input method:"
        echo -e "1) File paths"
        echo -e "2) Paste content"
        while true; do
            read -rp "Enter choice [1-2]: " cert_choice
            case $cert_choice in
                1)
                    read -rp "Enter SSL certificate file path: " SSL_CERT_PATH
                    read -rp "Enter SSL key file path: " SSL_KEY_PATH
                    if [ ! -f "$SSL_CERT_PATH" ] || [ ! -f "$SSL_KEY_PATH" ]; then
                        print_error "Certificate or key file not found"
                        exit 1
                    fi
                    break
                    ;;
                2)
                    echo "Paste your SSL certificate content (Ctrl+D when done):"
                    SSL_CERT_CONTENT=$(cat)
                    echo "Paste your SSL key content (Ctrl+D when done):"
                    SSL_KEY_CONTENT=$(cat)
                    break
                    ;;
                *) print_error "Invalid choice. Please try again." ;;
            esac
        done
    fi
    
    # Database password
    while true; do
        read -srp "Enter database password: " DB_PASSWORD_TEMP
        echo
        if [ -z "$DB_PASSWORD_TEMP" ]; then
            DB_PASSWORD=$(generate_password)
            print_status "Generated random database password"
            break
        else
            read -srp "Confirm database password: " DB_PASSWORD_CONFIRM
            echo
            if [ "$DB_PASSWORD_TEMP" = "$DB_PASSWORD_CONFIRM" ]; then
                DB_PASSWORD="$DB_PASSWORD_TEMP"
                break
            else
                print_error "Passwords do not match. Please try again."
            fi
        fi
    done
    
    # Redis password
    read -srp "Enter Redis password (leave empty for no password): " REDIS_PASSWORD_TEMP
    echo
    if [ -n "$REDIS_PASSWORD_TEMP" ]; then
        read -srp "Confirm Redis password: " REDIS_PASSWORD_CONFIRM
        echo
        if [ "$REDIS_PASSWORD_TEMP" = "$REDIS_PASSWORD_CONFIRM" ]; then
            REDIS_PASSWORD="$REDIS_PASSWORD_TEMP"
        else
            print_error "Passwords do not match. Using no Redis password."
            REDIS_PASSWORD=""
        fi
    fi
    
    # Admin email
    while true; do
        read -rp "Enter admin email: " ADMIN_EMAIL
        if validate_email "$ADMIN_EMAIL"; then
            break
        else
            print_error "Invalid email. Please try again."
        fi
    done
    
    # Admin password
    read -srp "Enter admin password (leave empty to generate): " ADMIN_PASSWORD_TEMP
    echo
    if [ -z "$ADMIN_PASSWORD_TEMP" ]; then
        ADMIN_PASSWORD=$(generate_password)
        print_status "Generated random admin password"
    else
        read -srp "Confirm admin password: " ADMIN_PASSWORD_CONFIRM
        echo
        if [ "$ADMIN_PASSWORD_TEMP" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            ADMIN_PASSWORD="$ADMIN_PASSWORD_TEMP"
        else
            print_error "Passwords do not match. Generating random password."
            ADMIN_PASSWORD=$(generate_password)
        fi
    fi
    
    # Generate App Key
    APP_KEY=$(generate_app_key)
    
    # Display summary
    echo
    display_summary
    echo
    
    # Confirmation
    read -rp "Proceed with installation? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_error "Installation cancelled"
        exit 1
    fi
    
    # Save configuration
    save_config
    
    # Update system
    print_status "Updating system packages..."
    apt update >> "$LOG_FILE" 2>&1
    apt upgrade -y >> "$LOG_FILE" 2>&1
    print_success "System updated"
    
    # Install dependencies
    install_php
    install_mariadb
    install_redis
    install_nginx
    
    # SSL configuration
    case $SSL_TYPE in
        "letsencrypt")
            generate_ssl
            ;;
        "custom")
            setup_custom_ssl
            ;;
        "none")
            print_warning "Skipping SSL configuration. Not recommended for production."
            ;;
    esac
    
    # Configure Nginx
    configure_nginx
    
    # Install Pelican Panel
    install_pelican
    
    # Configure firewall
    configure_firewall
    
    # Setup log rotation
    setup_logrotate
    
    # Harden security
    harden_security
    
    # Check service status
    check_service_status nginx
    check_service_status php8.4-fpm
    check_service_status mariadb
    check_service_status redis
    
    # Final summary
    echo
    echo -e "${BOLD}Installation Complete!${NC}"
    echo -e "Pelican Panel has been successfully installed."
    echo -e "Access your panel at: ${GREEN}$DEFAULT_APP_URL$DOMAIN${NC}"
    echo -e "Admin username: ${GREEN}$DEFAULT_ADMIN_USERNAME${NC}"
    echo -e "Admin password: ${GREEN}$ADMIN_PASSWORD${NC}"
    echo -e "Log file: ${GREEN}$LOG_FILE${NC}"
    echo
    echo -e "${BOLD}Next Steps:${NC}"
    echo -e "1. Login to your panel and configure your settings"
    echo -e "2. Install Wings on your game servers"
    echo -e "3. Add your node to the panel"
    echo -e "4. Start creating game servers!"
    echo
    echo -e "${YELLOW}Important:${NC} Save the above information in a secure location."
}

# Execute main function
main "$@"