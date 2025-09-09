#!/usr/bin/env bash
set -euo pipefail

# Pelican Panel installer (standardized flow)
# Flow: gather inputs -> review -> confirm -> fully automated install
# Exports a log at /var/log/pelican-installer/panel-*.log
# Works best on Ubuntu/Debian; will try to proceed elsewhere if user insists.

# -------- Logging & Helpers --------
LOG_DIR="/var/log/pelican-installer"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/panel-$(date +%Y%m%d-%H%M%S).log"

# Redirect all output to tee (stdout + log)
# shellcheck disable=SC2094
exec > >(tee -a "$LOG_FILE") 2>&1

cecho() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info()  { cecho "1;34" "➜ $*"; }
warn()  { cecho "1;33" "⚠ $*"; }
err()   { cecho "1;31" "✖ $*"; }
ok()    { cecho "1;32" "✔ $*"; }

require_root() { [[ $EUID -eq 0 ]] || { err "Please run as root (sudo)."; exit 1; }; }
randpw() { tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c "${1:-20}"; echo; }

trap 'status=$?; [[ $status -eq 0 ]] && ok "Done. Log saved: $LOG_FILE" || err "Failed with status $status. See log: $LOG_FILE"' EXIT

# -------- Validators --------
nonempty() { [[ -n "${1:-}" ]]; }
is_domain() { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }
is_email()  { [[ "$1" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; }
yn_to_bool() { case "${1,,}" in y|yes) echo "yes";; n|no) echo "no";; *) echo "";; esac; }

ask() {
  # ask "Prompt" "default" "validator_function|empty_ok"
  local prompt="$1" def="${2:-}" validator="${3:-}"
  local v input
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "$prompt [$def]: " input
      input="${input:-$def}"
    else
      read -r -p "$prompt: " input
    fi
    [[ -z "$validator" ]] && { echo "$input"; return; }
    if [[ "$validator" == "empty_ok" && -z "$input" ]]; then
      echo "$input"; return
    fi
    if $validator "$input"; then
      echo "$input"; return
    else
      warn "Invalid value. Please try again."
    fi
  done
}

select_menu() {
  # select_menu "Title" "1) foo" "2) bar" ; echoes chosen number
  local title="$1"; shift
  echo "$title"
  local opt
  for opt in "$@"; do echo "  $opt"; done
  local choice
  while true; do
    read -r -p "Select: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && { echo "$choice"; return; }
    warn "Please enter a number."
  done
}

# -------- OS Hint (allow continue) --------
os_hint() {
  local id id_like ver
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"; id_like="${ID_LIKE:-}"; ver="${VERSION_ID:-}"
  else
    id="unknown"; id_like=""; ver="unknown"
  fi
  info "Detected OS: ${id^} ${ver}"
  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *debian* ]]; then
    warn "Pelican recommends Ubuntu/Debian. Continue at your own risk."
    read -r -p "Continue anyway? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { err "Aborted."; exit 1; }
  fi
}

# -------- Repo & PHP detection --------
detect_php_ver() {
  for v in 8.4 8.3 8.2; do
    if apt-cache policy "php$v-fpm" >/dev/null 2>&1; then echo "$v"; return 0; fi
  done
  echo ""
}
ensure_php_repo() {
  . /etc/os-release
  local id="${ID:-}" codename="${VERSION_CODENAME:-}"
  if [[ "$id" == "ubuntu" ]]; then
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
  elif [[ "$id" == "debian" ]]; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ ${codename} main" >/etc/apt/sources.list.d/sury-php.list
  fi
}

# -------- 1) Gather Inputs --------
require_root
os_hint

DOMAIN="$(ask 'Panel domain (e.g. panel.example.com)' '' is_domain)"
ADMIN_EMAIL="$(ask 'Admin email (for LE & panel user)' '' is_email)"

# SSL mode
ssl_choice="$(select_menu 'SSL mode:' '1) letsencrypt (auto)' '2) custom (paste fullchain/key)' '3) none')"
case "$ssl_choice" in
  1) SSL_MODE="letsencrypt" ;;
  2) SSL_MODE="custom" ;;
  3) SSL_MODE="none" ;;
  *) err "Invalid SSL choice"; exit 1 ;;
esac

# Redirect HTTP->HTTPS
redir_choice="$(select_menu 'Redirect HTTP to HTTPS:' '1) yes (recommended)' '2) no')"
REDIRECT_HTTPS=$([[ "$redir_choice" == "1" ]] && echo "yes" || echo "no")

# Database
db_choice="$(select_menu 'Database backend:' '1) MariaDB (recommended)' '2) MySQL 8+' '3) SQLite (single-host test)')"
case "$db_choice" in
  1) DB_DRIVER="mariadb" ;;
  2) DB_DRIVER="mysql" ;;
  3) DB_DRIVER="sqlite" ;;
  *) err "Invalid DB choice"; exit 1 ;;
esac

if [[ "$DB_DRIVER" != "sqlite" ]]; then
  DB_NAME="$(ask 'DB name' 'pelican' nonempty)"
  DB_USER="$(ask 'DB user' 'pelican' nonempty)"
  DB_PASS="$(ask 'DB password (leave blank to auto-generate)' '' empty_ok)"
  [[ -z "$DB_PASS" ]] && DB_PASS="$(randpw 24)"
  DB_HOST="$(ask 'DB host' '127.0.0.1' nonempty)"
  DB_PORT="$(ask 'DB port' '3306' nonempty)"
else
  DB_NAME=":memory:"; DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""
fi

# Timezone / PHP
TIMEZONE="$(ask 'Server timezone (PHP INI & app)' 'Asia/Ho_Chi_Minh' nonempty)"

# Panel branch/version
PANEL_BRANCH="$(ask 'Panel branch/tag to deploy' 'main' nonempty)"

# Admin user
ADMIN_USER="$(ask 'Initial admin username' 'admin' nonempty)"
set_admin_pw="$(ask 'Set admin password manually? (y/n)' 'n' nonempty)"
if [[ "$(yn_to_bool "$set_admin_pw")" == "yes" ]]; then
  ADMIN_PASS="$(ask 'Admin password' '' nonempty)"
else
  ADMIN_PASS="$(randpw 16)"
fi

# Optional components
redis_choice="$(select_menu 'Install Redis for cache/session?' '1) yes' '2) no')"
INSTALL_REDIS=$([[ "$redis_choice" == "1" ]] && echo "yes" || echo "no")

ufw_choice="$(select_menu 'Configure UFW firewall to allow HTTP/HTTPS?' '1) yes' '2) no')"
ENABLE_UFW=$([[ "$ufw_choice" == "1" ]] && echo "yes" || echo "no")

# -------- 2) Review --------
clear
echo "================= Review ================="
echo "Domain:            $DOMAIN"
echo "Admin email:       $ADMIN_EMAIL"
echo "SSL mode:          $SSL_MODE"
echo "Redirect HTTPS:    $REDIRECT_HTTPS"
echo "Database:          $DB_DRIVER"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "  DB host/port:    $DB_HOST:$DB_PORT"
  echo "  DB name:         $DB_NAME"
  echo "  DB user/pass:    $DB_USER / $DB_PASS"
fi
echo "Timezone:          $TIMEZONE"
echo "Panel branch:      $PANEL_BRANCH"
echo "Admin account:     $ADMIN_USER / (hidden)"
echo "Install Redis:     $INSTALL_REDIS"
echo "Enable UFW:        $ENABLE_UFW"
echo "Log file:          $LOG_FILE"
echo "=========================================="
read -r -p "Proceed with installation? [y/N]: " c
[[ "${c,,}" == "y" ]] || { err "Cancelled."; exit 1; }

# -------- 3) Install --------
info "Updating apt and installing base packages..."
apt-get update -y
apt-get install -y sudo lsb-release apt-transport-https ca-certificates curl gnupg unzip tar git software-properties-common >/dev/null

info "Ensuring PHP repositories..."
ensure_php_repo
apt-get update -y

# Install PHP
PHPV="$(detect_php_ver)"
[[ -z "$PHPV" ]] && { err "No PHP 8.2/8.3/8.4 found in repos."; exit 1; }
info "Installing PHP $PHPV + required extensions..."
apt-get install -y \
  "php$PHPV" "php$PHPV-fpm" "php$PHPV-cli" "php$PHPV-gd" "php$PHPV-mysql" \
  "php$PHPV-mbstring" "php$PHPV-bcmath" "php$PHPV-xml" "php$PHPV-curl" \
  "php$PHPV-zip" "php$PHPV-intl" "php$PHPV-sqlite3" >/dev/null

# Configure PHP timezone
PHP_INI="/etc/php/${PHPV}/fpm/php.ini"
sed -i "s~^;*date.timezone =.*~date.timezone = ${TIMEZONE}~" "$PHP_INI" || true
systemctl enable --now "php${PHPV}-fpm" >/dev/null

# Web server
info "Installing NGINX..."
apt-get install -y nginx >/dev/null
systemctl enable --now nginx >/dev/null

# Redis (optional)
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  info "Installing Redis..."
  apt-get install -y redis-server >/dev/null
  systemctl enable --now redis-server >/dev/null
fi

# Composer
if ! command -v composer >/dev/null 2>&1; then
  info "Installing Composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Databases
if [[ "$DB_DRIVER" == "mariadb" ]]; then
  info "Installing MariaDB server..."
  apt-get install -y mariadb-server mariadb-client >/dev/null
  systemctl enable --now mariadb >/dev/null
elif [[ "$DB_DRIVER" == "mysql" ]]; then
  info "Installing MySQL server..."
  apt-get install -y mysql-server mysql-client >/dev/null
  systemctl enable --now mysql >/dev/null
fi

# Create DB objects
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  info "Creating database & user (if not exists)..."
  SQL_CREATE="
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
    FLUSH PRIVILEGES;
  "
  if command -v mysql >/dev/null 2>&1; then
    echo "$SQL_CREATE" | mysql -u root || echo "$SQL_CREATE" | mariadb -u root || true
  elif command -v mariadb >/dev/null 2>&1; then
    echo "$SQL_CREATE" | mariadb -u root || true
  fi
fi

# Panel fetch/deploy
PANEL_DIR="/var/www/pelican"
info "Fetching Pelican Panel ($PANEL_BRANCH) into $PANEL_DIR ..."
if [[ -d "$PANEL_DIR/.git" ]]; then
  (cd "$PANEL_DIR" && git fetch --all -q && git checkout -q "$PANEL_BRANCH" && git reset --hard -q "origin/$PANEL_BRANCH")
else
  rm -rf "$PANEL_DIR"
  git clone -q --branch "$PANEL_BRANCH" https://github.com/pelican-dev/panel.git "$PANEL_DIR"
fi

info "Installing composer dependencies (no-dev)..."
cd "$PANEL_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q

info "Generating .env and APP_KEY..."
sudo -u www-data php artisan p:environment:setup --no-interaction || php artisan p:environment:setup --no-interaction

# DB config in .env
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  sed -i \
    -e "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/" \
    -e "s/^DB_HOST=.*/DB_HOST=${DB_HOST}/" \
    -e "s/^DB_PORT=.*/DB_PORT=${DB_PORT}/" \
    -e "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" \
    -e "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" \
    -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" \
    .env
else
  sed -i -e "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/" .env
fi

# Cache/session driver (prefer redis if installed)
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  sed -i -e "s/^CACHE_DRIVER=.*/CACHE_DRIVER=redis/" -e "s/^SESSION_DRIVER=.*/SESSION_DRIVER=redis/" .env
fi

# Run migrations/seed
info "Migrating database..."
php artisan migrate --seed --force

# Create admin
info "Creating initial admin user..."
php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --password="${ADMIN_PASS}" --admin=1 --no-interaction || true

# NGINX vhost
NGINX_CONF="/etc/nginx/sites-available/pelican.conf"
SSL_DIR="/etc/ssl/pelican"
mkdir -p "$SSL_DIR"

# base server block (80)
cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;

    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
    }

    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?)\$ {
        expires 7d;
        access_log off;
    }
}
NGX

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
rm -f /etc/nginx/sites-enabled/default || true

# SSL handling
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  info "Installing certbot and issuing Let's Encrypt certificate..."
  apt-get install -y certbot python3-certbot-nginx >/dev/null
  certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive || warn "Certbot failed; continuing with HTTP."
elif [[ "$SSL_MODE" == "custom" ]]; then
  info "Paste your FULL CHAIN certificate (finish with Ctrl-D on empty line):"
  CERT_PATH="${SSL_DIR}/${DOMAIN}.crt"
  KEY_PATH="${SSL_DIR}/${DOMAIN}.key"
  umask 077
  cat > "$CERT_PATH"
  info "Paste your PRIVATE KEY (finish with Ctrl-D on empty line):"
  cat > "$KEY_PATH"
  chmod 600 "$CERT_PATH" "$KEY_PATH"

  cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    index index.php;
    client_max_body_size 100m;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
    }
    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?)\$ { expires 7d; access_log off; }
}
NGX
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
fi

# Optional redirect if HTTPS in use
if [[ "$REDIRECT_HTTPS" == "yes" && "$SSL_MODE" != "none" ]]; then
  # ensure port 80 block is a redirect
  sed -i '0,/root .*public;/{s/server {\n    listen 80;.*server_name .*;\n    root .*public;\n\n    index index.php;.*\n}\n/server {\n    listen 80;\n    server_name '"$DOMAIN"';\n    return 301 https:\/\/$host$request_uri;\n}\n/}' "$NGINX_CONF" || true
fi

nginx -t
systemctl reload nginx

# Permissions
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || true
chmod 640 "$PANEL_DIR/.env" || true

# Firewall (optional)
if [[ "$ENABLE_UFW" == "yes" ]]; then
  info "Configuring UFW for HTTP/HTTPS..."
  apt-get install -y ufw >/dev/null
  ufw allow OpenSSH >/dev/null || true
  ufw allow http >/dev/null || true
  ufw allow https >/dev/null || true
  yes | ufw enable >/dev/null || true
fi

# -------- 4) Final Output --------
PROTOCOL="http"
[[ "$SSL_MODE" != "none" ]] && PROTOCOL="https"

clear
ok "Pelican Panel has been installed."
echo "----------------------------------------------"
echo "URL:              ${PROTOCOL}://${DOMAIN}"
echo "Admin username:   ${ADMIN_USER}"
echo "Admin password:   ${ADMIN_PASS}"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "DB:               ${DB_DRIVER} ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
  echo "DB user/pass:     ${DB_USER} / ${DB_PASS}"
fi
echo "PHP-FPM:          ${PHPV} (timezone: ${TIMEZONE})"
echo "Panel path:       ${PANEL_DIR}"
echo "Nginx conf:       ${NGINX_CONF}"
echo "SSL mode:         ${SSL_MODE}  (Redirect HTTPS: ${REDIRECT_HTTPS})"
echo "Redis installed:  ${INSTALL_REDIS}"
echo "UFW enabled:      ${ENABLE_UFW}"
echo "Log file:         ${LOG_FILE}"
echo "----------------------------------------------"
echo "Tips:"
echo " - Keep your .env APP_KEY safe."
echo " - Restart queues if needed: php artisan queue:restart"
echo " - To re-run, simply execute the installer again."
