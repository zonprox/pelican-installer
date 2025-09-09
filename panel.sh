#!/usr/bin/env bash
set -euo pipefail

PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

PELICAN_DIR="/var/www/pelican"
NGINX_AVAIL="/etc/nginx/sites-available/pelican.conf"
NGINX_SITE="/etc/nginx/sites-enabled/pelican.conf"

randpw(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; echo; }
cecho(){ echo -e "\033[1;36m$*\033[0m"; }
gecho(){ echo -e "\033[1;32m$*\033[0m"; }
recho(){ echo -e "\033[1;31m$*\033[0m"; }
yecho(){ echo -e "\033[1;33m$*\033[0m"; }

require_root(){ [[ $EUID -eq 0 ]] || { recho "Please run as root (sudo)."; exit 1; }; }

detect_os(){
  source /etc/os-release || { recho "Cannot read /etc/os-release"; exit 1; }
  OS="$ID"; OS_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
  case "$OS" in
    ubuntu) dpkg --compare-versions "$OS_VER" ge "22.04" || { recho "Ubuntu $OS_VER not supported. Use 22.04/24.04+"; exit 1; } ;;
    debian) dpkg --compare-versions "$OS_VER" ge "11"    || { recho "Debian $OS_VER not supported. Use 11/12+"; exit 1; } ;;
    *) recho "Unsupported OS: $PRETTY_NAME"; exit 1;;
  esac
}

apt_prepare(){
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
}

install_php_stack(){
  if [[ "$ID" == "ubuntu" ]]; then
    add-apt-repository -y ppa:ondrej/php
  else
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
  fi
  apt-get update -y
  apt-get install -y nginx redis-server mariadb-server \
    php8.2 php8.2-cli php8.2-common php8.2-fpm php8.2-mysql php8.2-sqlite3 \
    php8.2-mbstring php8.2-xml php8.2-bcmath php8.2-curl php8.2-zip php8.2-gd php8.2-intl \
    git unzip
  systemctl enable --now redis-server || true

  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi
}

gather_inputs(){
  cecho "== Pelican Panel — Input =="
  read -rp "FQDN for panel (e.g. panel.example.com): " PANEL_FQDN
  read -rp "Admin email (for Panel account): " ADMIN_EMAIL
  read -rp "Admin username: " ADMIN_USER
  ADMIN_PASS="$(randpw 16)"
  echo "Generated admin password: $ADMIN_PASS"

  echo
  echo "Database engine?"
  echo "  1) MariaDB/MySQL (default)"
  echo "  2) SQLite (no external DB)"
  read -rp "Select [1-2]: " DBSEL || true; DBSEL="${DBSEL:-1}"

  DB_NAME="pelican"; DB_USER="pelican"; DB_PASS="$(randpw 22)"

  echo
  echo "Cache driver?"
  echo "  1) Redis (recommended)  2) file"
  read -rp "Select [1-2]: " CACHESEL || true; CACHESEL="${CACHESEL:-1}"

  echo
  echo "Enable HTTPS via Let's Encrypt automatically?"
  echo "  1) Yes  2) No (you can run ssl.sh later)"
  read -rp "Select [1-2]: " SSLSEL || true; SSLSEL="${SSLSEL:-1}"

  read -rp "Email for Let's Encrypt (only if enabling HTTPS): " LE_EMAIL || true
}

review_and_confirm(){
  clear
  cecho "== Review =="
  echo "Domain:        $PANEL_FQDN"
  echo "Admin email:   $ADMIN_EMAIL"
  echo "Admin user:    $ADMIN_USER"
  echo "Admin pass:    $ADMIN_PASS"
  echo "DB engine:     $([[ "$DBSEL" == "2" ]] && echo "SQLite" || echo "MariaDB/MySQL")"
  if [[ "$DBSEL" != "2" ]]; then
    echo "DB name:       $DB_NAME"
    echo "DB user:       $DB_USER"
    echo "DB pass:       $DB_PASS"
  fi
  echo "Cache driver:  $([[ "$CACHESEL" == "1" ]] && echo "Redis" || echo "file")"
  echo "HTTPS:         $([[ "$SSLSEL" == "1" ]] && echo "Let's Encrypt (auto)" || echo "Disabled")"
  [[ "$SSLSEL" == "1" ]] && echo "LE email:      $LE_EMAIL"
  echo
  echo "1) Confirm & Install (fully automatic)"
  echo "2) Cancel"
  read -rp "Select: " OK
  [[ "$OK" == "1" ]] || { recho "Cancelled."; exit 1; }
}

setup_database_if_mysql(){
  if [[ "$DBSEL" == "2" ]]; then return 0; fi
  systemctl enable --now mariadb
  mysql -NBe "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
  mysql -NBe "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';"
  mysql -NBe "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1'; FLUSH PRIVILEGES;"
}

deploy_panel_sources(){
  mkdir -p "$PELICAN_DIR"
  cd "$PELICAN_DIR"
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
  composer install --no-dev --optimize-autoloader

  php artisan p:environment:setup

  if [[ "$DBSEL" == "2" ]]; then
    mkdir -p "${PELICAN_DIR}/database"
    touch "${PELICAN_DIR}/database/database.sqlite"
    php artisan p:environment:database --driver=sqlite --database="${PELICAN_DIR}/database/database.sqlite"
  else
    php artisan p:environment:database --driver=mysql --database="$DB_NAME" --host=127.0.0.1 --port=3306 --username="$DB_USER" --password="$DB_PASS"
  fi

  if [[ "$CACHESEL" == "1" ]]; then
    php artisan p:environment:cache --driver=redis --redis-host=127.0.0.1 --redis-port=6379
  else
    php artisan p:environment:cache --driver=file
  fi

  php artisan migrate --seed --force || php artisan migrate --force
  php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --password="$ADMIN_PASS" --admin=1 -n

  chown -R www-data:www-data "$PELICAN_DIR"
  chmod -R 755 "$PELICAN_DIR/storage" "$PELICAN_DIR/bootstrap/cache"
}

configure_nginx_php(){
  local phpv; phpv="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80;
    server_name ${PANEL_FQDN};
    root ${PELICAN_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${phpv}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
  ln -sf "$NGINX_AVAIL" "$NGINX_SITE"
  nginx -t
  systemctl reload nginx
}

enable_https_if_requested(){
  [[ "$SSLSEL" != "1" ]] && return 0
  apt-get install -y snapd || true
  snap install core || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot || true
  certbot --nginx --non-interactive --agree-tos -m "$LE_EMAIL" -d "$PANEL_FQDN" || {
    yecho "Certbot failed — continuing without HTTPS. You can re-run later."
  }
  systemctl reload nginx || true
}

install_cron_and_services(){
  if ! crontab -l -u www-data 2>/dev/null | grep -q 'artisan schedule:run'; then
    (crontab -l -u www-data 2>/dev/null; echo "* * * * * php ${PELICAN_DIR}/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -
  fi
  cat >/etc/systemd/system/pelican-queue.service <<EOF
[Unit]
Description=Pelican Panel Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=3
WorkingDirectory=${PELICAN_DIR}
ExecStart=/usr/bin/php ${PELICAN_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now pelican-queue.service
}

final_output(){
  gecho "Pelican Panel installed successfully!"
  local proto="http"; [[ "$SSLSEL" == "1" ]] && proto="https"
  echo "URL:           ${proto}://${PANEL_FQDN}"
  echo "Admin email:   $ADMIN_EMAIL"
  echo "Admin user:    $ADMIN_USER"
  echo "Admin pass:    $ADMIN_PASS"
}

# ====== Run ======
require_root
detect_os
apt_prepare
install_php_stack
gather_inputs
review_and_confirm
setup_database_if_mysql
deploy_panel_sources
configure_nginx_php
enable_https_if_requested
install_cron_and_services
final_output
