#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel Installer - Clean Build with optional Redis
# Flow: inputs -> review -> confirm -> automated install
# Logs: /var/log/pelican-installer/panel-YYYYmmdd-HHMMSS.log

# ---------- preflight ----------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

LOG_DIR="/var/log/pelican-installer"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/panel-$(date +%Y%m%d-%H%M%S).log"

# keep interactive prompts visible while logging
exec > >(stdbuf -oL tee -a "$LOG_FILE") 2>&1
trap 'code=$?; if [[ $code -eq 0 ]]; then echo "✔ Completed. Log: $LOG_FILE"; else echo "✖ Failed (exit $code). See log: $LOG_FILE"; fi' EXIT

# ---------- helpers ----------
prompt() {
  # prompt "Question" "default" "validator|empty_ok"
  local q="$1" def="${2:-}" validator="${3:-}" ans
  while true; do
    if [[ -n "$def" ]]; then
      printf "%s [%s]: " "$q" "$def"
      IFS= read -r ans || ans=""
      ans="${ans:-$def}"
    else
      printf "%s: " "$q"
      IFS= read -r ans || ans=""
    fi
    if [[ -z "$validator" ]]; then echo "$ans"; return; fi
    if [[ "$validator" == "empty_ok" && -z "$ans" ]]; then echo "$ans"; return; fi
    if "$validator" "$ans"; then echo "$ans"; return; fi
    echo "Invalid value. Please try again."
  done
}

menu() {
  # menu "Title" default_index "opt1" "opt2" ...
  local title="$1"; shift
  local def="$1"; shift
  local options=("$@") total="${#options[@]}" choice
  echo
  echo "$title"
  for i in "${!options[@]}"; do
    local idx=$((i+1))
    if [[ $idx -eq $def ]]; then
      printf "  %d) %s [default]\n" "$idx" "${options[$i]}"
    else
      printf "  %d) %s\n" "$idx" "${options[$i]}"
    fi
  done
  while true; do
    printf "Select [%d]: " "$def"
    IFS= read -r choice || choice=""
    if [[ -z "$choice" ]]; then echo "$def"; return; fi
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$total" ]]; then
      echo "$choice"; return
    fi
    echo "Enter a number between 1 and $total (or press Enter for default)."
  done
}

nonempty() { [[ -n "${1:-}" ]]; }
is_domain() { [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; }
is_email()  { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
die()       { echo "✖ $*"; exit 1; }

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
}

php_detect() {
  for v in 8.4 8.3 8.2; do
    apt-cache policy "php$v-fpm" >/dev/null 2>&1 && { echo "$v"; return 0; }
  done
  echo ""
}

ensure_php_repo() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      apt_install software-properties-common || true
      add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
    elif [[ "${ID:-}" == "debian" ]]; then
      apt-get update -y
      apt_install ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury.gpg
      echo "deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
        >/etc/apt/sources.list.d/sury-php.list
    fi
  fi
}

mysql_exec() {
  # Try mysql or mariadb clients (root via socket)
  if have_cmd mysql; then
    mysql -u root -e "$1" || true
  elif have_cmd mariadb; then
    mariadb -u root -e "$1" || true
  fi
}

# ---------- 1) Inputs ----------
echo ">>> Pelican Panel - Input Phase"

# OS hint (allow continue)
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "Detected OS: ${ID^} ${VERSION_ID:-}"
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
    echo "Warning: non-Debian/Ubuntu system. Continue at your own risk."
    read -r -p "Continue anyway? [y/N]: " c
    [[ "${c,,}" == "y" ]] || die "Aborted."
  fi
fi

DOMAIN="$(prompt 'Panel domain (e.g. panel.example.com)' '' is_domain)"
ADMIN_EMAIL="$(prompt 'Admin email (for SSL & panel)' '' is_email)"

ssl_choice="$(menu 'SSL mode:' 1 \
  'letsencrypt (automatic)' \
  'custom (paste cert/key)' \
  'none')"
case "$ssl_choice" in
  1) SSL_MODE="letsencrypt" ;;
  2) SSL_MODE="custom" ;;
  3) SSL_MODE="none" ;;
esac

redir_choice="$(menu 'Redirect HTTP to HTTPS?' 1 'yes (recommended)' 'no')"
REDIRECT_HTTPS=$([[ "$redir_choice" == "1" ]] && echo "yes" || echo "no")

db_choice="$(menu 'Database backend:' 1 \
  'MariaDB (recommended)' \
  'MySQL 8+' \
  'SQLite (single-host/testing)')"
case "$db_choice" in
  1) DB_DRIVER="mariadb" ;;
  2) DB_DRIVER="mysql" ;;
  3) DB_DRIVER="sqlite" ;;
esac

if [[ "$DB_DRIVER" != "sqlite" ]]; then
  DB_NAME="$(prompt 'DB name' 'pelican' nonempty)"
  DB_USER="$(prompt 'DB user' 'pelican' nonempty)"
  DB_PASS="$(prompt 'DB password (empty = auto-generate)' '' empty_ok)"
  [[ -z "$DB_PASS" ]] && DB_PASS="$(tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c 24)"
  DB_HOST="$(prompt 'DB host' '127.0.0.1' nonempty)"
  DB_PORT="$(prompt 'DB port' '3306' nonempty)"
else
  DB_NAME=":memory:"; DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""
fi

TIMEZONE="$(prompt 'Server timezone (PHP)' 'Asia/Ho_Chi_Minh' nonempty)"
PANEL_BRANCH="$(prompt 'Panel branch/tag' 'main' nonempty)"
ADMIN_USER="$(prompt 'Admin username' 'admin' nonempty)"

set_pw="$(prompt 'Set admin password manually? (y/n)' 'n' nonempty)"
if [[ "${set_pw,,}" =~ ^y ]]; then
  ADMIN_PASS="$(prompt 'Admin password' '' nonempty)"
else
  ADMIN_PASS="$(tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c 16)"
fi)

# NEW: Redis optional
redis_choice="$(menu 'Install Redis for cache/session?' 1 'yes' 'no')"
INSTALL_REDIS=$([[ "$redis_choice" == "1" ]] && echo "yes" || echo "no")

# ---------- 2) Review ----------
clear
cat <<REVIEW
================ Review ================
Domain:            $DOMAIN
Admin email:       $ADMIN_EMAIL
SSL mode:          $SSL_MODE
Redirect HTTPS:    $REDIRECT_HTTPS
Database:          $DB_DRIVER
$( [[ "$DB_DRIVER" != "sqlite" ]] && echo "  DB host/port:    $DB_HOST:$DB_PORT
  DB name:         $DB_NAME
  DB user/pass:    $DB_USER / $DB_PASS" )
Timezone (PHP):    $TIMEZONE
Panel branch:      $PANEL_BRANCH
Admin account:     $ADMIN_USER / (hidden)
Redis install:     $INSTALL_REDIS
Log file:          $LOG_FILE
========================================
REVIEW
read -r -p "Proceed with installation? [y/N]: " go
[[ "${go,,}" == "y" ]] || die "Cancelled."

# ---------- 3) Install ----------
echo ">>> Installing base packages..."
have_cmd apt-get || die "apt-get not found. Unsupported OS for auto-install."
apt-get update -y
apt_install curl ca-certificates lsb-release apt-transport-https gnupg unzip tar git

echo ">>> Ensuring PHP repositories..."
ensure_php_repo
apt-get update -y

PHPV="$(php_detect)"
[[ -z "$PHPV" ]] && die "No PHP 8.2/8.3/8.4 packages found."
echo ">>> Installing PHP $PHPV + extensions..."
apt_install "php$PHPV" "php$PHPV-fpm" "php$PHPV-cli" \
            "php$PHPV-gd" "php$PHPV-mysql" "php$PHPV-mbstring" \
            "php$PHPV-bcmath" "php$PHPV-xml" "php$PHPV-curl" \
            "php$PHPV-zip" "php$PHPV-intl" "php$PHPV-sqlite3"

# If Redis selected, install php-redis extension too
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  apt_install "php$PHPV-redis"
fi

PHP_INI="/etc/php/${PHPV}/fpm/php.ini"
sed -i "s~^;*date.timezone =.*~date.timezone = ${TIMEZONE}~" "$PHP_INI" || true
systemctl enable --now "php${PHPV}-fpm"

echo ">>> Installing NGINX..."
apt_install nginx
systemctl enable --now nginx

echo ">>> Installing Composer (if absent)..."
if ! have_cmd composer; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Databases
if [[ "$DB_DRIVER" == "mariadb" ]]; then
  echo ">>> Installing MariaDB..."
  apt_install mariadb-server mariadb-client
  systemctl enable --now mariadb
elif [[ "$DB_DRIVER" == "mysql" ]]; then
  echo ">>> Installing MySQL..."
  apt_install mysql-server mysql-client
  systemctl enable --now mysql
fi

# Create DB & user
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo ">>> Creating database and user (if not exists)..."
  mysql_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_exec "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';"
  mysql_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
fi

# Panel deploy
PANEL_DIR="/var/www/pelican"
REPO_URL="https://github.com/pelican-dev/panel.git"

echo ">>> Fetching Pelican Panel ($PANEL_BRANCH) into $PANEL_DIR..."
if [[ -d "$PANEL_DIR/.git" ]]; then
  (cd "$PANEL_DIR" && git fetch --all -q && git checkout -q "$PANEL_BRANCH" && git reset --hard -q "origin/$PANEL_BRANCH")
else
  rm -rf "$PANEL_DIR"
  git clone -q --branch "$PANEL_BRANCH" "$REPO_URL" "$PANEL_DIR"
fi

echo ">>> Installing PHP dependencies (composer install --no-dev)..."
cd "$PANEL_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q

# .env setup
[[ -f .env ]] || cp .env.example .env 2>/dev/null || touch .env
APP_URL_PROTOCOL=$([[ "$SSL_MODE" == "none" ]] && echo "http" || echo "https")
APP_URL="${APP_URL_PROTOCOL}://${DOMAIN}"

sed -i -E "
s|^APP_ENV=.*|APP_ENV=production|;
s|^APP_DEBUG=.*|APP_DEBUG=false|;
s|^APP_URL=.*|APP_URL=${APP_URL}|;
" .env

if [[ "$DB_DRIVER" != "sqlite" ]]; then
  sed -i -E "
s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|;
s|^DB_HOST=.*|DB_HOST=${DB_HOST}|;
s|^DB_PORT=.*|DB_PORT=${DB_PORT}|;
s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|;
s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|;
s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|;
" .env
else
  sed -i -E "s|^DB_CONNECTION=.*|DB_CONNECTION=sqlite|;" .env
fi

# Redis env (only when chosen)
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  # ensure defaults
  grep -q '^REDIS_HOST=' .env || echo "REDIS_HOST=127.0.0.1" >> .env
  grep -q '^REDIS_PORT=' .env || echo "REDIS_PORT=6379" >> .env
  sed -i -E "
s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|;
s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|;
" .env
fi

echo ">>> Generating app key..."
php artisan key:generate --force || true

echo ">>> Running migrations (and seed if available)..."
php artisan migrate --force || true
php artisan db:seed --force || true

# Pelican-specific helpers (best effort)
if php artisan list --no-ansi 2>/dev/null | grep -qE '^p:environment:setup'; then
  php artisan p:environment:setup --no-interaction || true
fi
if php artisan list --no-ansi 2>/dev/null | grep -qE '^p:user:make'; then
  php artisan p:user:make \
    --email="${ADMIN_EMAIL}" \
    --username="${ADMIN_USER}" \
    --password="${ADMIN_PASS}" \
    --admin=1 --no-interaction || true
else
  echo "Note: Could not find 'p:user:make'. Please create the admin in UI if needed."
fi

# Redis server install & enable (after app prepared)
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  echo ">>> Installing Redis server..."
  apt_install redis-server
  systemctl enable --now redis-server
fi

# NGINX vhost
NGINX_CONF="/etc/nginx/sites-available/pelican.conf"
SSL_DIR="/etc/ssl/pelican"
mkdir -p "$SSL_DIR"

gen_http_block() {
  cat <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;

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
}

gen_https_block_custom() {
  local crt="$1" key="$2"
  cat <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;

    ssl_certificate     ${crt};
    ssl_certificate_key ${key};

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
}

echo ">>> Writing NGINX config..."
case "$SSL_MODE" in
  none)
    gen_http_block > "$NGINX_CONF"
    ;;
  letsencrypt)
    gen_http_block > "$NGINX_CONF"
    ;;
  custom)
    CERT_PATH="${SSL_DIR}/${DOMAIN}.crt"
    KEY_PATH="${SSL_DIR}/${DOMAIN}.key"
    umask 077
    echo "Paste FULL CHAIN certificate (end with Ctrl-D on an empty line):"
    cat > "$CERT_PATH"
    echo "Paste PRIVATE KEY (end with Ctrl-D on an empty line):"
    cat > "$KEY_PATH"
    chmod 600 "$CERT_PATH" "$KEY_PATH"
    gen_https_block_custom "$CERT_PATH" "$KEY_PATH" > "$NGINX_CONF"
    ;;
esac

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
rm -f /etc/nginx/sites-enabled/default || true

# Let's Encrypt obtain
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  echo ">>> Obtaining Let's Encrypt certificate..."
  apt_install certbot python3-certbot-nginx
  if certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive; then
    echo "LE OK."
  else
    echo "LE failed; keeping HTTP only."
  fi
fi

# Optional redirect to HTTPS
if [[ "$REDIRECT_HTTPS" == "yes" && "$SSL_MODE" != "none" ]]; then
  if ! grep -q "return 301 https" "$NGINX_CONF"; then
    TMP="$(mktemp)"
    cat > "$TMP" <<RED
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
RED
    cat "$NGINX_CONF" >> "$TMP"
    mv "$TMP" "$NGINX_CONF"
  fi
fi

nginx -t
systemctl reload nginx

# Permissions
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
chmod 640 "$PANEL_DIR/.env" 2>/dev/null || true

# ---------- 4) Final Info ----------
PROTOCOL=$([[ "$SSL_MODE" == "none" ]] && echo "http" || echo "https")

clear
echo "========================================"
echo " Pelican Panel installed successfully"
echo "----------------------------------------"
echo "URL:              ${PROTOCOL}://${DOMAIN}"
echo "Admin username:   ${ADMIN_USER}"
echo "Admin password:   ${ADMIN_PASS}"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "DB:               ${DB_DRIVER} ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
  echo "DB user/pass:     ${DB_USER} / ${DB_PASS}"
fi
echo "PHP-FPM:          php-fpm ${PHPV} (timezone: ${TIMEZONE})"
echo "Redis installed:  ${INSTALL_REDIS}"
echo "Panel path:       ${PANEL_DIR}"
echo "NGINX conf:       ${NGINX_CONF}"
echo "SSL mode:         ${SSL_MODE} (Redirect HTTPS: ${REDIRECT_HTTPS})"
echo "Log file:         ${LOG_FILE}"
echo "========================================"
echo "Notes:"
echo " - Keep your .env APP_KEY safe (generated)."
echo " - If 'p:user:make' did not exist, create admin in the UI."
