#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel installer — minimal flow:
# Input -> Review -> Confirm -> Auto install -> Summary

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }
err()  { printf "\033[31m%s\033[0m\n" "$*"; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Please run as root."; exit 1; }; }
have()      { command -v "$1" >/dev/null 2>&1; }

os_info() { source /etc/os-release || true; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; }
supported_os() { case "$OS_ID" in ubuntu) [[ "$OS_VER" == "22.04" || "$OS_VER" == "24.04" ]];; debian) [[ "$OS_VER" == "12" ]];; *) false;; esac; }

rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }
php_sock() { ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2"); echo "/run/php/php${ver}-fpm.sock"; }

collect() {
  echo; bold "Pelican Panel — Input"
  read -rp "Panel domain (FQDN): " PANEL_DOMAIN
  read -rp "Admin email: " ADMIN_EMAIL
  read -rp "Timezone [Asia/Ho_Chi_Minh]: " APP_TZ; APP_TZ="${APP_TZ:-Asia/Ho_Chi_Minh}"
  read -rp "DB name [pelican]: " DB_NAME; DB_NAME="${DB_NAME:-pelican}"
  read -rp "DB user [pelican]: " DB_USER; DB_USER="${DB_USER:-pelican}"
  read -rp "DB password (blank = auto): " DB_PASS || true
  [[ -z "${DB_PASS:-}" ]] && { DB_PASS="$(rand)"; AUTO_DB=1; } || AUTO_DB=0
  read -rp "Issue Let's Encrypt now? [Y/n]: " LE; LE="${LE:-Y}"

  echo; bold "Review"
  cat <<EOF
Domain      : ${PANEL_DOMAIN}
Admin Email : ${ADMIN_EMAIL}
Timezone    : ${APP_TZ}
DB Name     : ${DB_NAME}
DB User     : ${DB_USER}
DB Pass     : ${DB_PASS} $( [[ $AUTO_DB -eq 1 ]] && printf "(auto)" )
Let'sEncrypt: ${LE}
EOF
  read -rp "Type YES to confirm and install: " C; [[ "$C" == "YES" ]] || { err "Aborted."; exit 1; }
}

deps() {
  ok "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release jq git unzip \
    nginx mariadb-server redis-server \
    php php-fpm php-cli php-mysql php-redis php-curl php-zip php-gd php-mbstring php-xml php-bcmath \
    certbot python3-certbot-nginx
  if ! have composer; then
    curl -sS https://getcomposer.org/installer -o /tmp/c.php
    php /tmp/c.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/c.php
  fi
}

db() {
  ok "Configuring database..."
  systemctl enable --now mariadb
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

fetch() {
  ok "Fetching Pelican Panel..."
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

configure() {
  ok "Setting up .env and app..."
  pushd /var/www/pelican >/dev/null
  [[ -f .env ]] || cp .env.example .env || true
  php -r '
$env=file_get_contents(".env");
function setv(&$e,$k,$v){$e=preg_replace("/^".$k."=.*/m",$k."=".$v,$e,-1,$c);if(!$c){$e.="\n".$k."=".$v;}}
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
  popd >/dev/null
}

queue_unit() {
  ok "Queue worker service..."
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
  ok "Nginx site..."
  local sock; sock="$(php_sock)"
  cat >/etc/nginx/sites-available/pelican_panel <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    root /var/www/pelican/public;
    index index.php;
    client_max_body_size 100m;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock};
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri /index.php?\$query_string;
        expires max; log_not_found off;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/pelican_panel /etc/nginx/sites-enabled/pelican_panel
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

ssl() {
  [[ "${LE^^}" == "Y" ]] || { warn "Skipping Let's Encrypt."; return 0; }
  ok "Issuing Let's Encrypt (nginx plugin)..."
  certbot --nginx -d "${PANEL_DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos -n --redirect || warn "Certbot failed."
  systemctl reload nginx || true
}

summary() {
  local URL="https://${PANEL_DOMAIN}"
  [[ "${LE^^}" == "Y" ]] || URL="http://${PANEL_DOMAIN}"
  echo; bold "Done."
  cat <<EOF
URL         : ${URL}
Admin Email : ${ADMIN_EMAIL}
Timezone    : ${APP_TZ}

DB
  Host      : 127.0.0.1
  Name      : ${DB_NAME}
  User      : ${DB_USER}
  Pass      : ${DB_PASS}

Services
  Nginx     : $(systemctl is-active nginx || echo inactive)
  MariaDB   : $(systemctl is-active mariadb || echo inactive)
  Redis     : $(systemctl is-active redis-server || echo inactive)
  Queue     : $(systemctl is-active pelican-queue || echo inactive)

Next: Open the URL and create the first admin user. Then install Wings from the main menu.
EOF
}

main() {
  need_root
  os_info
  if ! supported_os; then
    warn "Your OS (${OS_ID} ${OS_VER}) may not be fully supported. Proceeding as requested."
  fi
  collect
  deps
  db
  fetch
  configure
  queue_unit
  nginx_site
  ssl
  summary
}

main "$@"
