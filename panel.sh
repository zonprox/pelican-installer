#!/usr/bin/env bash

# Pelican Panel Automated Installer
# Supports: Debian 12, Ubuntu 22.04/24.04
# Requirements per pelican.dev documentation

set -Eeuo pipefail

SCRIPT_NAME="panel.sh"
LOG_FILE="/var/log/panel-install.log"
INSTALL_DIR="/var/www/pelican"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
PHP_VERSION="8.4"

trap 'on_error $LINENO' ERR

on_error() {
  local line=$1
  echo "[ERROR] Installation failed at line ${line}. See $LOG_FILE for details." | tee -a "$LOG_FILE"
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This installer must be run as root (use sudo)." | tee -a "$LOG_FILE"
    exit 1
  fi
}

init_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "==== Pelican Panel Install Log $(date -Is) ===="
}

detect_os() {
  . /etc/os-release
  OS_ID=${ID}
  OS_VERSION_ID=${VERSION_ID}
  case "$OS_ID" in
    debian)
      if [[ "$OS_VERSION_ID" != "12"* ]]; then
        echo "Debian $OS_VERSION_ID is not supported. Use Debian 12."; exit 1
      fi
      OS_NAME="Debian 12"
      ;;
    ubuntu)
      if [[ "$OS_VERSION_ID" != "22.04" && "$OS_VERSION_ID" != "24.04" ]]; then
        echo "Ubuntu $OS_VERSION_ID is not supported. Use 22.04 or 24.04."; exit 1
      fi
      OS_NAME="Ubuntu $OS_VERSION_ID"
      ;;
    *)
      echo "Unsupported OS: $OS_ID"; exit 1
      ;;
  esac
  echo "Detected OS: $OS_NAME"
}

rand_password() {
  # 24-character base64 password excluding confusing symbols
  openssl rand -base64 24 | tr -d '\n' | sed 's/[^A-Za-z0-9._-]//g' | cut -c1-24
}

trim() { sed 's/^\s\+//; s/\s\+$//'; }

prompt_input() {
  local prompt="$1"; local default_value="${2:-}"; local var
  read -r -p "$prompt${default_value:+ [$default_value]}: " var || true
  if [[ -z "$var" && -n "$default_value" ]]; then echo "$default_value"; else echo "$var"; fi
}

validate_domain() {
  local domain="$1"
  if [[ ! "$domain" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$ ]]; then
    return 1
  fi
  return 0
}

root_domain() {
  # Get registrable root by naive split: last two labels
  local d="$1"
  awk -F. '{n=NF; if(n>=2){print $(n-1)"."$n}else{print $0}}' <<< "$d"
}

resolve_ips() {
  local host="$1"
  getent ahosts "$host" | awk '{print $1}' | sort -u
}

public_ip() {
  curl -4s https://api.ipify.org || curl -4s https://ifconfig.me || true
}

confirm() {
  local prompt="$1"; local ans
  while true; do
    read -r -p "$prompt [y/n]: " ans || true
    case "$ans" in
      y|Y) return 0;;
      n|N) return 1;;
      *) echo "Please enter y or n.";;
    esac
  done
}

print_divider() { printf '\n%s\n' "----------------------------------------"; }

gather_inputs() {
  echo "Interactive setup. Leave blank for defaults where shown."

  while true; do
    DOMAIN=$(prompt_input "Enter primary domain for Panel (e.g., panel.example.com)")
    DOMAIN=$(echo "$DOMAIN" | trim)
    if [[ -z "$DOMAIN" ]]; then echo "Domain cannot be empty."; continue; fi
    if ! validate_domain "$DOMAIN"; then echo "Invalid domain format."; continue; fi
    break
  done

  DEFAULT_ADMIN_USER="admin"
  ADMIN_USER=$(prompt_input "Admin username" "$DEFAULT_ADMIN_USER")
  ADMIN_USER=$(echo "$ADMIN_USER" | trim)
  if [[ -z "$ADMIN_USER" ]]; then ADMIN_USER="$DEFAULT_ADMIN_USER"; fi

  ROOT_DOM=$(root_domain "$DOMAIN")
  DEFAULT_ADMIN_EMAIL="admin@${ROOT_DOM}"
  ADMIN_EMAIL=$(prompt_input "Admin email" "$DEFAULT_ADMIN_EMAIL")
  ADMIN_EMAIL=$(echo "$ADMIN_EMAIL" | trim)
  if [[ -z "$ADMIN_EMAIL" ]]; then ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"; fi

  ADMIN_PASSWORD=$(prompt_input "Admin password (leave blank to auto-generate)")
  if [[ -z "$ADMIN_PASSWORD" ]]; then ADMIN_PASSWORD=$(rand_password); AUTO_PW=1; else AUTO_PW=0; fi

  echo "SSL options: 1) none  2) letsencrypt  3) custom"
  while true; do
    SSL_OPTION=$(prompt_input "Choose SSL option (1/2/3)" "2")
    case "$SSL_OPTION" in
      1) SSL_MODE="none"; break;;
      2) SSL_MODE="letsencrypt"; break;;
      3) SSL_MODE="custom"; break;;
      *) echo "Invalid choice.";;
    esac
  done

  if [[ "$SSL_MODE" == "custom" ]]; then
    echo "Custom SSL: 1) use file paths  2) paste certificate contents"
    while true; do
      CUSTOM_SSL_INPUT=$(prompt_input "Choose input method (1/2)" "1")
      case "$CUSTOM_SSL_INPUT" in
        1)
          CERT_PATH=$(prompt_input "Path to full chain certificate (PEM)" "/etc/ssl/certs/${DOMAIN}.crt")
          KEY_PATH=$(prompt_input "Path to private key (PEM)" "/etc/ssl/private/${DOMAIN}.key")
          CHAIN_PATH=$(prompt_input "Path to CA chain (optional)")
          ;;
        2)
          echo "Paste full chain certificate (end with EOF on its own line):"; CERT_CONTENT=$(</dev/stdin)
          echo "Paste private key (end with EOF on its own line):"; KEY_CONTENT=$(</dev/stdin)
          echo "Paste CA chain if separate (optional, end with EOF):"; CHAIN_CONTENT=$(</dev/stdin || true)
          ;;
        *) echo "Invalid choice"; continue;;
      esac
      break
    done
  fi

  DB_NAME=$(prompt_input "MariaDB database name" "pelican")
  DB_USER=$(prompt_input "MariaDB username" "pelican")
  DB_PASS=$(prompt_input "MariaDB user password (leave blank to auto-generate)")
  if [[ -z "$DB_PASS" ]]; then DB_PASS=$(rand_password); fi

  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_PASS=""

  print_review
  if confirm "Proceed with installation?"; then
    return 0
  else
    echo "Let's re-enter the details."
    gather_inputs
  fi
}

print_review() {
  print_divider
  echo "Review Configuration:"
  echo "- Domain: $DOMAIN"
  echo "- Admin username: $ADMIN_USER"
  echo "- Admin email: $ADMIN_EMAIL"
  echo "- Admin password: ${AUTO_PW:+(auto-generated)}${AUTO_PW:+'*hidden*'}${AUTO_PW:+ }"
  echo "- SSL mode: $SSL_MODE"
  if [[ "$SSL_MODE" == "custom" ]]; then
    if [[ "${CUSTOM_SSL_INPUT:-1}" == "1" ]]; then
      echo "  - Cert path: ${CERT_PATH:-}"
      echo "  - Key path: ${KEY_PATH:-}"
      echo "  - Chain path: ${CHAIN_PATH:-(none)}"
    else
      echo "  - Cert: pasted"
      echo "  - Key: pasted"
      echo "  - Chain: ${CHAIN_CONTENT:+pasted}${CHAIN_CONTENT:-(none)}"
    fi
  fi
  echo "- DB: name=$DB_NAME user=$DB_USER pass=*hidden*"
  echo "- Redis: $REDIS_HOST:$REDIS_PORT"
  print_divider
}

prepare_repos() {
  echo "Preparing repositories for PHP ${PHP_VERSION}..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common apt-transport-https

  if [[ "$OS_ID" == "debian" ]]; then
    # Sury repo for PHP on Debian
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg
    echo "deb https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/sury-php.list
  elif [[ "$OS_ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:ondrej/php
  fi

  apt-get update -y
}

install_dependencies() {
  echo "Installing dependencies..."
  # Web, DB, Cache
  apt-get install -y nginx mariadb-server redis-server

  # PHP 8.4 + extensions
  apt-get install -y \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-curl \
    php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-gd \
    php${PHP_VERSION}-intl php${PHP_VERSION}-bcmath php${PHP_VERSION}-redis

  # Certbot
  apt-get install -y certbot python3-certbot-nginx

  # Git, unzip
  apt-get install -y git unzip

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_CHECKSUM="$(curl -s https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
      echo 'ERROR: Invalid composer installer checksum' >&2
      rm -f composer-setup.php; exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  systemctl enable --now nginx
  systemctl enable --now mariadb
  systemctl enable --now redis-server
}

secure_mariadb_and_create_db() {
  echo "Configuring MariaDB..."
  # Set root passwordless via unix_socket; create DB and user
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

deploy_pelican() {
  echo "Deploying Pelican Panel..."
  mkdir -p "$INSTALL_DIR"
  if [[ -z "${SUDO_USER:-}" ]]; then OWNER_USER="root"; else OWNER_USER="$SUDO_USER"; fi
  chown -R "$OWNER_USER":"$OWNER_USER" "$INSTALL_DIR"

  if [[ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
    sudo -u "$OWNER_USER" composer create-project pelican/panel "$INSTALL_DIR" --no-interaction || true
  fi

  cd "$INSTALL_DIR"

  # Environment
  if [[ ! -f .env ]]; then cp .env.example .env || true; fi
  sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|" .env || true
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|" .env || true
  sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env || true
  sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env || true
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" .env || true
  sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$DB_USER|" .env || true
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env || true
  sed -i "s|^REDIS_HOST=.*|REDIS_HOST=$REDIS_HOST|" .env || true
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$REDIS_PASS|" .env || true
  sed -i "s|^REDIS_PORT=.*|REDIS_PORT=$REDIS_PORT|" .env || true

  sudo -u "$OWNER_USER" php artisan key:generate --force || true
  sudo -u "$OWNER_USER" php artisan storage:link || true
  sudo -u "$OWNER_USER" php artisan migrate --force || true

  # Attempt Pelican-specific installers if available
  sudo -u "$OWNER_USER" php artisan pelican:install --force || true
  sudo -u "$OWNER_USER" php artisan pelican:setup --force || true

  chown -R www-data:www-data "$INSTALL_DIR"
  find "$INSTALL_DIR" -type f -exec chmod 0644 {} +
  find "$INSTALL_DIR" -type d -exec chmod 0755 {} +
}

configure_nginx() {
  echo "Configuring Nginx..."
  local server_name="$DOMAIN"
  local site_file="$NGINX_AVAILABLE/$server_name.conf"

  cat > "$site_file" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};
    root ${INSTALL_DIR}/public;

    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files $uri /index.php?$query_string;
        expires max;
        log_not_found off;
    }

    client_max_body_size 100m;
}
NGINX

  ln -sf "$site_file" "$NGINX_ENABLED/$server_name.conf"
  nginx -t | cat
  systemctl reload nginx
}

obtain_letsencrypt() {
  echo "Validating DNS before requesting Let's Encrypt..."
  local pubip; pubip=$(public_ip)
  if [[ -z "$pubip" ]]; then echo "Could not determine public IP. Aborting LE."; return 1; fi
  local resolved; resolved=$(resolve_ips "$DOMAIN" | tr '\n' ' ')
  if ! grep -qw "$pubip" <<< "$resolved"; then
    echo "Domain $DOMAIN does not resolve to this server IP $pubip (got: $resolved).";
    echo "Please fix DNS A/AAAA records and re-run."
    exit 1
  fi

  systemctl stop nginx || true
  # Use webroot to avoid Nginx module variations
  certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --preferred-challenges http || {
    systemctl start nginx; return 1;
  }
  systemctl start nginx

  # Configure SSL server block
  local site_file="$NGINX_AVAILABLE/$DOMAIN.conf"
  cat > "$site_file" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root ${INSTALL_DIR}/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files $uri /index.php?$query_string;
        expires max;
        log_not_found off;
    }
    client_max_body_size 100m;
}
NGINX

  ln -sf "$site_file" "$NGINX_ENABLED/$DOMAIN.conf"
  nginx -t | cat
  systemctl reload nginx
}

configure_custom_ssl() {
  echo "Configuring custom SSL..."
  mkdir -p /etc/ssl/custom
  local cert_file key_file chain_file
  if [[ "${CUSTOM_SSL_INPUT:-1}" == "1" ]]; then
    cert_file="$CERT_PATH"; key_file="$KEY_PATH"; chain_file="${CHAIN_PATH:-}"
  else
    cert_file="/etc/ssl/custom/${DOMAIN}.crt"
    key_file="/etc/ssl/custom/${DOMAIN}.key"
    chain_file="/etc/ssl/custom/${DOMAIN}-chain.crt"
    echo "$CERT_CONTENT" > "$cert_file"
    echo "$KEY_CONTENT" > "$key_file"
    if [[ -n "${CHAIN_CONTENT:-}" ]]; then echo "$CHAIN_CONTENT" > "$chain_file"; fi
    chmod 600 "$key_file"
  fi

  if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
    echo "Certificate or key file missing."; exit 1
  fi

  local site_file="$NGINX_AVAILABLE/$DOMAIN.conf"
  if [[ -n "$chain_file" && -f "$chain_file" ]]; then
    FULLCHAIN_DIRECTIVE="ssl_trusted_certificate ${chain_file};"
  else
    FULLCHAIN_DIRECTIVE="# ssl_trusted_certificate not provided"
  fi

  cat > "$site_file" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ${FULLCHAIN_DIRECTIVE}

    root ${INSTALL_DIR}/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files $uri /index.php?$query_string;
        expires max;
        log_not_found off;
    }
    client_max_body_size 100m;
}
NGINX

  ln -sf "$site_file" "$NGINX_ENABLED/$DOMAIN.conf"
  nginx -t | cat
  systemctl reload nginx
}

configure_supervisor_and_cron() {
  echo "Configuring Supervisor and cron..."
  apt-get install -y supervisor
  systemctl enable --now supervisor

  local program_file="/etc/supervisor/conf.d/pelican-queue.conf"
  cat > "$program_file" <<SUP
[program:pelican-queue]
command=/usr/bin/php ${INSTALL_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=90
directory=${INSTALL_DIR}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/log/pelican-queue.log
stopwaitsecs=3600
SUP

  supervisorctl reread || true
  supervisorctl update || true

  # Cron for Laravel scheduler
  if ! crontab -u www-data -l >/dev/null 2>&1; then echo "" | crontab -u www-data -; fi
  (crontab -u www-data -l 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php ${INSTALL_DIR}/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -
}

create_admin_user() {
  echo "Creating admin user if supported..."
  cd "$INSTALL_DIR"
  sudo -u www-data php artisan pelican:admin --name "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD" || true
}

final_summary() {
  print_divider
  echo "Pelican Panel installation completed."
  echo "URL: https://${DOMAIN}"
  echo "Admin username: ${ADMIN_USER}"
  echo "Admin email: ${ADMIN_EMAIL}"
  if [[ "$AUTO_PW" -eq 1 ]]; then echo "Admin password (auto): ${ADMIN_PASSWORD}"; fi
  echo "Database: name=${DB_NAME} user=${DB_USER} pass=${DB_PASS}"
  echo "Install dir: ${INSTALL_DIR}"
  echo "Logs: ${LOG_FILE}"
  print_divider
}

main() {
  require_root
  init_logging
  detect_os
  gather_inputs

  echo "Starting installation on $OS_NAME for domain $DOMAIN..."

  prepare_repos
  install_dependencies
  secure_mariadb_and_create_db
  deploy_pelican
  configure_nginx

  case "$SSL_MODE" in
    none)
      echo "Skipping SSL configuration (HTTP only)." ;;
    letsencrypt)
      obtain_letsencrypt ;;
    custom)
      configure_custom_ssl ;;
  esac

  configure_supervisor_and_cron
  create_admin_user
  final_summary
}

main "$@"

#!/bin/bash

# Simple installation script for Pelican Panel on Debian/Ubuntu
# Based on official documentation from pelican.dev
# This script installs prerequisites, sets up the panel, configures NGINX, handles SSL, database, Redis, and creates admin user.

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (use sudo)."
  exit 1
fi

# Detect OS
if [ -f /etc/debian_version ]; then
  OS="debian"
elif [ -f /etc/lsb-release ]; then
  OS="ubuntu"
else
  echo "This script supports only Debian or Ubuntu."
  exit 1
fi

# Function to generate random password
generate_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

# Prompt for inputs
echo "Welcome to Pelican Panel Installer."
echo "Please provide the following information:"

read -p "Enter domain (e.g., panel.example.com): " domain

read -p "Enter admin username: " admin_username
read -p "Enter admin email: " admin_email
read -s -p "Enter admin password (leave blank to generate): " admin_password
echo
if [ -z "$admin_password" ]; then
  admin_password=$(generate_password)
  echo "Generated admin password: $admin_password"
fi

echo "Choose SSL option:"
echo "1) Let's Encrypt (automatic)"
echo "2) Custom (paste cert and key)"
echo "3) None (HTTP only)"
read -p "Enter choice (1/2/3): " ssl_choice

if [ "$ssl_choice" = "2" ]; then
  echo "Paste fullchain.pem content (end with Ctrl+D on new line):"
  fullchain=$(cat)
  echo "Paste privkey.pem content (end with Ctrl+D on new line):"
  privkey=$(cat)
fi

read -p "Install and use Redis? (y/n): " redis_choice
redis_choice=${redis_choice,,}  # lowercase

echo "Database setup (MySQL/MariaDB):"
read -p "Enter database name (default: panel): " db_name
db_name=${db_name:-panel}
read -p "Enter database user (default: pelican): " db_user
db_user=${db_user:-pelican}
read -s -p "Enter database password (leave blank to generate): " db_password
echo
if [ -z "$db_password" ]; then
  db_password=$(generate_password)
  echo "Generated DB password: $db_password"
fi

# Review and confirm
echo -e "\nReview your inputs:"
echo "Domain: $domain"
echo "Admin Username: $admin_username"
echo "Admin Email: $admin_email"
echo "Admin Password: ****"
echo "SSL: $(case $ssl_choice in 1) echo "Let's Encrypt";; 2) echo "Custom";; 3) echo "None";; esac)"
echo "Redis: ${redis_choice^}"  # capitalize first letter
echo "DB Name: $db_name"
echo "DB User: $db_user"
echo "DB Password: ****"

read -p "Confirm and proceed? (y/n): " confirm
confirm=${confirm,,}
if [ "$confirm" != "y" ]; then
  echo "Installation cancelled."
  exit 0
fi

# Installation starts
echo "Starting installation..."

# Update system
apt update -y && apt upgrade -y

# Install basic tools
apt install -y curl tar unzip software-properties-common lsb-release gpg

# Install PHP 8.4
add-apt-repository ppa:ondrej/php -y
apt update -y
apt install -y php8.4 php8.4-cli php8.4-fpm php8.4-gd php8.4-mysql php8.4-mbstring php8.4-bcmath php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-sqlite3

# Install NGINX
apt install -y nginx

# Install Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Install MariaDB
curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
apt install -y mariadb-server

# Create DB and user (assume root password blank or handle manually if set)
mysql -u root -e "CREATE USER '$db_user'@'127.0.0.1' IDENTIFIED BY '$db_password';"
mysql -u root -e "CREATE DATABASE $db_name;"
mysql -u root -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'127.0.0.1';"
mysql -u root -e "FLUSH PRIVILEGES;"

# Install Redis if chosen
if [ "$redis_choice" = "y" ]; then
  apt install -y redis-server
  systemctl enable --now redis-server
fi

# Create panel directory
mkdir -p /var/www/pelican
cd /var/www/pelican

# Download and extract panel
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv

# Install dependencies
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# Set up .env
cp .env.example .env
php artisan key:generate --force

# Edit .env for DB
sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" .env
sed -i "s/DB_HOST=.*/DB_HOST=127.0.0.1/" .env
sed -i "s/DB_PORT=.*/DB_PORT=3306/" .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=$db_name/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=$db_user/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$db_password/" .env

# Edit .env for APP_URL
if [ "$ssl_choice" = "3" ]; then
  sed -i "s|APP_URL=.*|APP_URL=http://$domain|" .env
else
  sed -i "s|APP_URL=.*|APP_URL=https://$domain|" .env
fi

# Edit .env for Redis if chosen
if [ "$redis_choice" = "y" ]; then
  sed -i "s/CACHE_DRIVER=.*/CACHE_DRIVER=redis/" .env
  sed -i "s/SESSION_DRIVER=.*/SESSION_DRIVER=redis/" .env
  sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=redis/" .env
  sed -i "s/REDIS_HOST=.*/REDIS_HOST=127.0.0.1/" .env
  sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=null/" .env
  sed -i "s/REDIS_PORT=.*/REDIS_PORT=6379/" .env
fi

# Run migrations and seed
php artisan migrate --seed --force

# Create admin user
php artisan p:user:make --admin --username="$admin_username" --email="$admin_email" --password="$admin_password" --name-first="Admin" --name-last="User"

# Set permissions
chown -R www-data:www-data /var/www/pelican
chmod -R 755 storage/* bootstrap/cache/

# Configure NGINX
rm /etc/nginx/sites-enabled/default

if [ "$ssl_choice" = "3" ]; then
  # HTTP only config
  cat << EOF > /etc/nginx/sites-available/pelican.conf
server {
    listen 80;
    server_name $domain;
    root /var/www/pelican/public;
    index index.php;
    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
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
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
else
  # HTTPS config
  cat << EOF > /etc/nginx/sites-available/pelican.conf
server_tokens off;
server {
    listen 80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain;
    root /var/www/pelican/public;
    index index.php;
    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;
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
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
fi

ln -s /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf

# Handle SSL
if [ "$ssl_choice" != "3" ]; then
  if [ "$ssl_choice" = "1" ]; then
    apt install -y certbot python3-certbot-nginx
    certbot --nginx -d $domain --non-interactive --agree-tos --email $admin_email --redirect
  elif [ "$ssl_choice" = "2" ]; then
    mkdir -p /etc/letsencrypt/live/$domain
    echo "$fullchain" > /etc/letsencrypt/live/$domain/fullchain.pem
    echo "$privkey" > /etc/letsencrypt/live/$domain/privkey.pem
    chmod 600 /etc/letsencrypt/live/$domain/privkey.pem
  fi
fi

# Restart services
systemctl restart nginx
systemctl restart php8.4-fpm

# Results
echo -e "\nInstallation completed!"
echo "Pelican Panel is installed at /var/www/pelican"
if [ "$ssl_choice" = "3" ]; then
  echo "Access the panel at http://$domain"
else
  echo "Access the panel at https://$domain"
fi
echo "Admin credentials:"
echo "Username: $admin_username"
echo "Email: $admin_email"
echo "Password: $admin_password"
echo "Note: You may need to configure Wings separately for daemon."
echo "For security, run mysql_secure_installation to secure MariaDB."