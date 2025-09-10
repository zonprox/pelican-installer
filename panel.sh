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