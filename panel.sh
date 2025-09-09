#!/usr/bin/env bash
set -Eeuo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

collect_inputs() {
  echo "Pelican Panel - Inputs"
  read -rp "Panel domain (e.g. panel.example.com): " PANEL_DOMAIN
  read -rp "Admin email: " ADMIN_EMAIL
  read -rp "Timezone [Asia/Ho_Chi_Minh]: " APP_TZ; APP_TZ="${APP_TZ:-Asia/Ho_Chi_Minh}"
  read -rp "DB name [pelican]: " DB_NAME; DB_NAME="${DB_NAME:-pelican}"
  read -rp "DB user [pelican]: " DB_USER; DB_USER="${DB_USER:-pelican}"
  read -rp "DB password (blank = auto): " DB_PASS || true
  if [[ -z "${DB_PASS:-}" ]]; then DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"; AUTO_DB=1; else AUTO_DB=0; fi

  echo
  echo "Review:"
  echo "  Domain      : $PANEL_DOMAIN"
  echo "  Admin Email : $ADMIN_EMAIL"
  echo "  Timezone    : $APP_TZ"
  echo "  DB          : $DB_NAME / $DB_USER / $DB_PASS $( [[ $AUTO_DB -eq 1 ]] && printf '(auto)' )"
  read -rp "Issue Let's Encrypt SSL now? [Y/n]: " LE; LE="${LE:-Y}"
  echo
  read -rp "Type YES to install: " OK; [[ "$OK" == "YES" ]] || { echo "Aborted."; exit 1; }
}

deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release git unzip jq \
    nginx mariadb-server redis-server \
    php php-fpm php-cli php-mysql php-redis php-curl php-zip php-gd php-mbstring php-xml php-bcmath \
    certbot python3-certbot-nginx

  if ! have composer; then
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

db_setup() {
  systemctl enable --now mariadb
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

get_php_sock() {
  local v; v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
  PHP_SOCK="/run/php/php${v}-fpm.sock"
}

panel_fetch_and_env() {
  mkdir -p /var/www
  if [[ -d /var/www/pelican/.git ]]; then
    git -C /var/www/pelican fetch --depth 1 origin main || true
    git -C /var/www/pelican reset --hard origin/main || true
  else
    rm -rf /var/www/pelican
    git clone --depth=1 https://github.com/pelican-dev/panel.git /var/www/pelican
  fi

  cd /var/www/pelican
  [[ -f .env ]] || cp .env.example .env || true

  php -r '
$env = file_get_contents(".env");
function setv(&$e,$k,$v){ $e=preg_replace("/^".$k."=.*/m",$k."=".$v,$e,-1,$c); if(!$c){$e.="\n".$k."=".$v;} }
setv($env,"APP_ENV","production");
setv($env,"APP_DEBUG","false");
setv($env,"APP_URL", getenv("PANEL_DOMAIN"));
setv($env,"APP_TIMEZONE", getenv("APP_TZ"));
setv($env,"SESSION_DRIVER","redis");
setv($env,"CACHE_DRIVER","redis");
setv($env,"QUEUE_CONNECTION","redis");
setv($env,"DB_HOST","127.0.0.1");
setv($env,"DB_PORT","3306");
setv($env,"DB_DATABASE", getenv("DB_NAME"));
setv($env,"DB_USERNAME", getenv("DB_USER"));
setv($env,"DB_PASSWORD", getenv("DB_PASS"));
echo $env;' > .env.tmp && mv .env.tmp .env

  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q
  php artisan key:generate --force
  php artisan migrate --seed --force
  php artisan storage:link || true
  chown -R www-data:www-data /var/www/pelican
}

queue_service() {
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

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now pelican-queue
}

nginx_site() {
  get_php_sock
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
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri /index.php?\$query_string;
        expires max;
        log_not_found off;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/pelican_panel /etc/nginx/sites-enabled/pelican_panel
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

ssl_issue() {
  if [[ "${LE^^}" == "Y" ]]; then
    certbot --nginx -d "$PANEL_DOMAIN" -m "$ADMIN_EMAIL" --agree-tos -n --redirect || echo "Certbot failed (you can re-run later)."
    systemctl reload nginx || true
  fi
}

summary() {
  local URL="http://${PANEL_DOMAIN}"
  [[ "${LE^^}" == "Y" ]] && URL="https://${PANEL_DOMAIN}"
  echo
  echo "Pelican Panel installed."
  echo "URL           : $URL"
  echo "Admin Email   : $ADMIN_EMAIL"
  echo "Timezone      : $APP_TZ"
  echo "DB Host       : 127.0.0.1"
  echo "DB Name/User  : $DB_NAME / $DB_USER"
  echo "DB Password   : $DB_PASS"
  echo
  echo "Next:"
  echo "  - Open the URL to create the first admin user."
  echo "  - Then install Wings from the main menu."
}

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root."; exit 1; }
  collect_inputs
  deps
  db_setup
  panel_fetch_and_env
  queue_service
  nginx_site
  ssl_issue
  summary
}

main "$@"
