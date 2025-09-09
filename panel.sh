#!/usr/bin/env bash
set -euo pipefail

bold(){ printf "\033[1m%s\033[0m" "$*"; }
green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { red "Please run as root (sudo)."; exit 1; }; }

sock_guess(){
  local s
  s=$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | head -n1 || true)
  [[ -n "${s:-}" ]] && { echo "$s"; return; }
  echo "/run/php/php8.2-fpm.sock"
}

collect_inputs(){
  echo
  printf "%s\n" "$(bold "Pelican Panel — Input")"
  read -rp "Panel domain (FQDN): " PANEL_DOMAIN
  read -rp "Admin email (for SSL & panel): " ADMIN_EMAIL
  read -rp "App timezone [Asia/Ho_Chi_Minh]: " APP_TZ; APP_TZ="${APP_TZ:-Asia/Ho_Chi_Minh}"
  read -rp "DB name [pelican]: " DB_NAME; DB_NAME="${DB_NAME:-pelican}"
  read -rp "DB user [pelican]: " DB_USER; DB_USER="${DB_USER:-pelican}"
  read -rp "DB password (blank = auto): " DB_PASS || true
  if [[ -z "${DB_PASS:-}" ]]; then DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"; fi

  echo
  printf "%s\n" "$(bold "SSL via Let's Encrypt?"))"
  read -rp "[Y/n]: " LETSENCRYPT; LETSENCRYPT="${LETSENCRYPT:-Y}"

  echo
  printf "%s\n" "$(bold "Review"))"
  cat <<EOF
Domain        : ${PANEL_DOMAIN}
Admin Email   : ${ADMIN_EMAIL}
Timezone      : ${APP_TZ}
DB Name/User  : ${DB_NAME} / ${DB_USER}
DB Password   : ${DB_PASS}
SSL (LE)      : ${LETSENCRYPT}
EOF
  echo
  read -rp "Type YES to install: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || { red "Aborted."; exit 1; }
}

deps(){
  green "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx mariadb-server redis-server git curl unzip \
    php php-fpm php-cli php-mysql php-redis php-curl php-zip php-gd php-mbstring php-xml php-bcmath
  if [[ "${LETSENCRYPT^^}" == "Y" ]]; then
    apt-get install -y certbot python3-certbot-nginx
  fi
  if ! have composer; then
    curl -sS https://getcomposer.org/installer -o /tmp/c.php
    php /tmp/c.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/c.php
  fi
}

db(){
  green "Configuring MariaDB..."
  systemctl enable --now mariadb
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

panel_fetch(){
  green "Fetching Pelican Panel..."
  mkdir -p /var/www
  if [[ -d /var/www/pelican/.git ]]; then
    git -C /var/www/pelican fetch --depth 1 origin main || true
    git -C /var/www/pelican reset --hard origin/main || true
  else
    rm -rf /var/www/pelican
    git clone --depth=1 https://github.com/pelican-dev/panel.git /var/www/pelican
  fi
  chown -R www-data:www-data /var/www/pelican
}

panel_env(){
  green "Setting .env & installing PHP deps..."
  pushd /var/www/pelican >/dev/null
  [[ -f .env ]] || cp .env.example .env
  sed -i "s|^APP_ENV=.*|APP_ENV=production|; s|^APP_DEBUG=.*|APP_DEBUG=false|" .env || true
  sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_DOMAIN}|" .env || echo "APP_URL=https://${PANEL_DOMAIN}" >> .env
  sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=${APP_TZ}|" .env || echo "APP_TIMEZONE=${APP_TZ}" >> .env
  sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env || echo "SESSION_DRIVER=redis" >> .env
  sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env || echo "CACHE_DRIVER=redis" >> .env
  sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env || echo "QUEUE_CONNECTION=redis" >> .env
  sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env || echo "DB_HOST=127.0.0.1" >> .env
  sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env || echo "DB_PORT=3306" >> .env
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env || echo "DB_DATABASE=${DB_NAME}" >> .env
  sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env || echo "DB_USERNAME=${DB_USER}" >> .env
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env || echo "DB_PASSWORD=${DB_PASS}" >> .env

  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q
  php artisan key:generate --force
  php artisan migrate --seed --force
  php artisan storage:link || true
  chown -R www-data:www-data /var/www/pelican
  popd >/dev/null
}

queue_unit(){
  green "Queue worker service..."
  cat >/etc/systemd/system/pelican-queue.service <<EOF
[Unit]
Description=Pelican Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=3
ExecStart=/usr/bin/php /var/www/pelican/artisan queue:work --sleep=3 --tries=3 --timeout=90
WorkingDirectory=/var/www/pelican
StandardOutput=append:/var/log/pelican-queue.log
StandardError=append:/var/log/pelican-queue.log
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now pelican-queue
}

nginx_site(){
  green "Nginx vhost..."
  local sock; sock="$(sock_guess)"
  cat >/etc/nginx/sites-available/pelican_panel <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    root /var/www/pelican/public;
    index index.php;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri /index.php?\$query_string;
        expires max;
        log_not_found off;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/pelican_panel /etc/nginx/sites-enabled/pelican_panel
  [[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

ssl_issue(){
  if [[ "${LETSENCRYPT^^}" == "Y" ]]; then
    green "Issuing Let's Encrypt SSL..."
    apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1 || true
    certbot --nginx -d "${PANEL_DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos -n --redirect || yellow "Certbot failed; you can retry later."
    systemctl reload nginx || true
  else
    yellow "Skipping SSL issuance."
  fi
}

summary(){
  local URL="https://${PANEL_DOMAIN}"
  [[ "${LETSENCRYPT^^}" == "Y" ]] || URL="http://${PANEL_DOMAIN}"
  echo
  printf "%s\n" "$(bold "Done.")"
  cat <<EOF
URL            : ${URL}
Admin Email    : ${ADMIN_EMAIL}
Timezone       : ${APP_TZ}

Database
  Host         : 127.0.0.1
  Name         : ${DB_NAME}
  User         : ${DB_USER}
  Password     : ${DB_PASS}

Services
  Nginx        : $(systemctl is-active nginx || echo inactive)
  MariaDB      : $(systemctl is-active mariadb || echo inactive)
  Redis        : $(systemctl is-active redis-server || echo inactive)
  Queue        : $(systemctl is-active pelican-queue || echo inactive)

Next
  - Open the URL to create the first admin user.
  - Install Wings from main menu if needed.
EOF
}

main(){
  require_root
  collect_inputs
  deps
  db
  panel_fetch
  panel_env
  queue_unit
  nginx_site
  ssl_issue
  summary
}
main "$@"
