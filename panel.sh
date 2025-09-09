#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Pelican Panel Automated Installer (Ubuntu 22.04/24.04, Debian 12)
# Steps:
#  1) Collect inputs -> Review -> Confirm
#  2) Install dependencies (Nginx, MariaDB, Redis, PHP, Composer, Certbot)
#  3) Create DB + user
#  4) Fetch Pelican Panel (git) & configure (.env)
#  5) Composer install, key generate, migrate/seed
#  6) Systemd queue worker
#  7) Nginx vhost + optional Let's Encrypt
#  8) Final info print
#
# Docs:
#  - Panel getting started: https://pelican.dev/docs/panel/getting-started/  (ref)
#  - Wings: https://pelican.dev/docs/wings/install/                          (ref)
#  - Pelican is a fork of Pterodactyl: https://pelican.dev/docs/comparison/  (ref)
# ──────────────────────────────────────────────────────────────────────────────

bold() { printf "\033[1m%s\033[0m" "$*"; }
ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
err()  { printf "\033[31m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

os_info() {
  source /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
}

supported_os() {
  case "$OS_ID" in
    ubuntu) [[ "$OS_VER" == "22.04" || "$OS_VER" == "24.04" ]] ;;
    debian) [[ "$OS_VER" == "12"    ]] ;;
    *) false;;
  esac
}

random_str() {
  # 32 chars URL-safe
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

php_sock_path() {
  local ver
  ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
  echo "/run/php/php${ver}-fpm.sock"
}

collect_inputs() {
  echo
  printf "%s\n" "$(bold "Pelican Panel — Input collection")"

  read -rp "Panel domain (FQDN, e.g. panel.example.com): " PANEL_DOMAIN
  read -rp "Admin email (for SSL & panel): " ADMIN_EMAIL
  read -rp "App timezone [default: Asia/Ho_Chi_Minh]: " APP_TZ
  APP_TZ="${APP_TZ:-Asia/Ho_Chi_Minh}"

  read -rp "Database name [pelican]: " DB_NAME; DB_NAME="${DB_NAME:-pelican}"
  read -rp "Database user [pelican]: " DB_USER; DB_USER="${DB_USER:-pelican}"
  read -rp "Database password (leave blank to auto-generate): " DB_PASS || true
  if [[ -z "${DB_PASS:-}" ]]; then DB_PASS="$(random_str)"; AUTO_DB_PASS=1; else AUTO_DB_PASS=0; fi

  read -rp "Generate Let's Encrypt SSL now? [Y/n]: " LETSENCRYPT
  LETSENCRYPT="${LETSENCRYPT:-Y}"

  echo
  printf "%s\n" "$(bold "Review configuration:")"
  cat <<EOF
  Domain        : ${PANEL_DOMAIN}
  Admin Email   : ${ADMIN_EMAIL}
  Timezone      : ${APP_TZ}
  DB Name       : ${DB_NAME}
  DB User       : ${DB_USER}
  DB Password   : ${DB_PASS} $( [[ $AUTO_DB_PASS -eq 1 ]] && printf "(auto)" )
  SSL (LE)      : ${LETSENCRYPT}
EOF
  echo
  read -rp "Proceed with installation? Type YES to continue: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || { err "Aborted."; exit 1; }
}

install_dependencies() {
  ok "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release jq git unzip \
    nginx mariadb-server redis-server \
    php php-fpm php-cli php-mysql php-redis php-curl php-zip php-gd php-mbstring php-xml php-bcmath \
    certbot python3-certbot-nginx

  if ! have_cmd composer; then
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

secure_mysql() {
  ok "Configuring MariaDB..."
  systemctl enable --now mariadb
  # Create DB & user (idempotent)
  mysql -uroot <<MYSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL
}

fetch_panel() {
  ok "Fetching Pelican Panel..."
  mkdir -p /var/www
  if [[ -d /var/www/pelican/.git ]]; then
    pushd /var/www/pelican >/dev/null
    git fetch --depth 1 origin main || true
    git reset --hard origin/main || true
    popd >/dev/null
  else
    rm -rf /var/www/pelican
    git clone --depth=1 https://github.com/pelican-dev/panel.git /var/www/pelican
  fi
  chown -R www-data:www-data /var/www/pelican
}

configure_env() {
  ok "Configuring environment (.env)..."
  pushd /var/www/pelican >/dev/null
  [[ -f .env ]] || cp .env.example .env || true

  # Update .env values
  php -r '
$env = file_get_contents(".env");
function setv(&$env,$k,$v){ $env=preg_replace("/^".$k."=.*/m",$k."=".$v,$env,-1,$c); if(!$c){$env.="\n".$k."=".$v;} }
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
echo $env;' > .env.tmp
  mv .env.tmp .env

  # Install PHP deps & optimize
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q
  php artisan key:generate --force
  php artisan migrate --seed --force
  php artisan storage:link || true

  chown -R www-data:www-data /var/www/pelican
  popd >/dev/null
}

setup_queue_worker() {
  ok "Setting up queue worker (systemd)..."
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

configure_nginx() {
  ok "Configuring Nginx vhost..."
  local sock; sock="$(php_sock_path)"

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

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;
}
EOF

  ln -sf /etc/nginx/sites-available/pelican_panel /etc/nginx/sites-enabled/pelican_panel
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_ssl() {
  if [[ "${LETSENCRYPT^^}" == "Y" ]]; then
    ok "Requesting Let's Encrypt certificate with HTTP-01 via nginx..."
    # This will edit the vhost to SSL automatically
    certbot --nginx -d "${PANEL_DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos -n --redirect || warn "Certbot failed. You can re-run SSL later."
    systemctl reload nginx || true
  else
    warn "Skipping SSL issuance as requested."
  fi
}

print_summary() {
  local url="https://${PANEL_DOMAIN}"
  [[ "${LETSENCRYPT^^}" != "Y" ]] && url="http://${PANEL_DOMAIN}"

  echo
  printf "%s\n" "$(bold "Pelican Panel installed successfully!")"
  cat <<EOF
URL            : ${url}
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

Next steps
  1) Open the URL above to create the first admin user.
  2) Then install Wings on your node(s) from the main menu.
EOF
}

main() {
  require_root
  os_info
  supported_os || { err "Supported: Ubuntu 22.04/24.04, Debian 12. Detected: ${OS_ID} ${OS_VER}"; exit 1; }

  collect_inputs
  install_dependencies
  secure_mysql
  fetch_panel
  configure_env
  setup_queue_worker
  configure_nginx
  issue_ssl
  print_summary
}

main "$@"
