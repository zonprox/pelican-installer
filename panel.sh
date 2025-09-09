#!/usr/bin/env bash
# panel.sh - Install Pelican Panel (minimal but production-capable)
# Language: English

set -Eeuo pipefail

# ------------ Defaults ------------
PANEL_DIR="/var/www/pelican"
NGINX_SITE="/etc/nginx/sites-available/pelican.conf"
TIMEZONE_DEFAULT="UTC"
DB_NAME="pelican"
DB_USER="pelican"
DB_PASS="${DB_PASS:-}"          # can be preseeded via env
APP_URL="${APP_URL:-}"          # can be preseeded via env
LE_EMAIL="${LE_EMAIL:-}"        # optional for Let's Encrypt

# ------------ Prompt helpers ------------
prompt() {
  local var="$1" msg="$2" def="${3:-}"
  local val
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " val || true
    val="${val:-$def}"
  else
    read -r -p "$msg: " val || true
  fi
  printf -v "$var" "%s" "$val"
}

yesno() {
  local msg="$1"
  local ans
  read -r -p "$msg [y/N]: " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ------------ Gather inputs ------------
gather_inputs() {
  echo "[*] Collecting installation inputs ..."
  prompt APP_URL "Panel URL (e.g., https://panel.example.com)"
  prompt LE_EMAIL "Let's Encrypt email (optional, empty to skip)" ""
  prompt DB_PASS "Database password for user '$DB_USER' (leave empty to auto-generate)" ""
  prompt TIMEZONE "PHP timezone" "$TIMEZONE_DEFAULT"

  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  fi
}

review_inputs() {
  cat <<EOF

Configuration Review:
  Panel directory : $PANEL_DIR
  App URL         : $APP_URL
  LE Email        : ${LE_EMAIL:-<skip SSL auto>}
  DB name/user    : $DB_NAME / $DB_USER
  DB password     : $DB_PASS
  Timezone        : ${TIMEZONE:-$TIMEZONE_DEFAULT}

EOF
  yesno "Proceed with installation?" || { echo "Aborted by user."; exit 1; }
}

# ------------ Soft checks ------------
soft_checks() {
  echo "[*] Soft system check (non-blocking) ..."
  local os_id="unknown"
  [[ -f /etc/os-release ]] && . /etc/os-release || true
  os_id="${ID:-unknown}"
  case "$os_id" in
    ubuntu|debian) echo "    ✓ Debian/Ubuntu detected";;
    *) echo "    ⚠ Non-debian OS detected. Proceeding anyway (you may need to adapt packages).";;
  esac
}

# ------------ Install dependencies ------------
install_deps() {
  echo "[*] Installing dependencies (Nginx, MariaDB, Redis, PHP, Node 20+, Yarn, Composer) ..."
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y

  # Basic stack
  sudo apt-get install -y gnupg2 ca-certificates lsb-release curl software-properties-common

  # MariaDB + Redis + Nginx
  sudo apt-get install -y mariadb-server redis-server nginx

  # PHP (use distro packages; adjust to 8.2+ if available)
  sudo apt-get install -y php php-fpm php-cli php-curl php-gd php-mbstring php-mysql php-xml php-zip php-bcmath php-intl

  # Node.js 20+ (per Pelican dev notes)
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  sudo npm i -g yarn

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
      >&2 echo 'ERROR: Invalid composer installer checksum'
      rm composer-setup.php
      exit 1
    fi
    sudo php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php
  fi

  # Set timezone for PHP
  sudo timedatectl set-timezone "${TIMEZONE:-$TIMEZONE_DEFAULT}" || true
  sudo sed -i "s~^;date.timezone =.*~date.timezone = ${TIMEZONE:-$TIMEZONE_DEFAULT}~" /etc/php/*/fpm/php.ini || true
  sudo systemctl restart php*-fpm.service || true
}

# ------------ Database setup ------------
setup_database() {
  echo "[*] Configuring MariaDB database and user ..."
  sudo systemctl enable --now mariadb
  # Create DB and user (idempotent)
  sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
}

# ------------ Panel install ------------
install_panel_code() {
  echo "[*] Deploying Pelican Panel into $PANEL_DIR ..."
  sudo mkdir -p "$PANEL_DIR"
  if [[ ! -d "$PANEL_DIR/.git" ]]; then
    sudo git clone https://github.com/pelican-dev/panel.git "$PANEL_DIR"
  else
    (cd "$PANEL_DIR" && sudo git pull --ff-only)
  fi
  sudo chown -R "$USER":"$USER" "$PANEL_DIR"

  cd "$PANEL_DIR"
  # Backend deps
  composer install --no-dev --optimize-autoloader
  # Env
  cp -n .env.example .env || true
  php artisan key:generate --force
  php artisan p:environment:setup --url="$APP_URL" --timezone="${TIMEZONE:-$TIMEZONE_DEFAULT}" || true
  php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="$DB_NAME" --username="$DB_USER" --password="$DB_PASS" || true

  # Migrate
  php artisan migrate --force

  # Frontend build
  yarn install --frozen-lockfile || yarn install
  yarn build

  # Permissions
  sudo chown -R www-data:www-data storage bootstrap/cache
  sudo find storage -type d -exec chmod 775 {} \;
  sudo find bootstrap/cache -type d -exec chmod 775 {} \;
}

# ------------ Nginx & SSL ------------
configure_nginx() {
  local server_name
  server_name="$(echo "$APP_URL" | sed -E 's#https?://##' | sed 's#/$##')"

  echo "[*] Writing Nginx site to $NGINX_SITE ..."
  sudo tee "$NGINX_SITE" >/dev/null <<EOF
server {
    listen 80;
    server_name $server_name;

    root $PANEL_DIR/public;
    index index.php;

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
    }

    location ~* \.(?:jpg|jpeg|gif|png|css|js|ico|svg|webp)$ {
        expires 7d;
        access_log off;
    }
}
EOF

  sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/pelican.conf
  sudo nginx -t
  sudo systemctl reload nginx

  # Optional: Let's Encrypt
  if [[ -n "${LE_EMAIL:-}" && "$APP_URL" =~ ^https?:// ]]; then
    if yesno "Issue Let's Encrypt certificate now for $server_name? (requires DNS pointing)"; then
      sudo apt-get install -y certbot python3-certbot-nginx
      sudo certbot --nginx -d "$server_name" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect || {
        echo "    ⚠ Certbot failed; keeping HTTP. You can retry later."
      }
    fi
  fi
}

# ------------ Finish / Output ------------
finish_output() {
  local server_name
  server_name="$(echo "$APP_URL" | sed -E 's#https?://##' | sed 's#/$##')"

  cat <<EOF

✅ Pelican Panel installed!

URL        : $APP_URL
Nginx site : $NGINX_SITE
App path   : $PANEL_DIR
DB         : $DB_NAME (user: $DB_USER)
Timezone   : ${TIMEZONE:-$TIMEZONE_DEFAULT}

Next steps:
1) Visit $APP_URL to finish any web-based setup (create admin, etc).
2) (Optional) Issue SSL via Let's Encrypt if you skipped earlier.
3) Create a Node, then install Wings per docs and paste config to /etc/pelican/config.yml.
4) After node config is in place: systemctl enable --now wings

Useful references:
- Pelican Panel getting started docs
- Wings install & configuration docs

EOF
}

# ------------ Main flow ------------
main() {
  soft_checks
  gather_inputs
  review_inputs
  install_deps
  setup_database
  install_panel_code
  configure_nginx
  finish_output
}

main "$@"
