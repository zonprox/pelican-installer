#!/usr/bin/env bash
set -euo pipefail

# Pelican Panel installer (non-interactive after confirmation)
# Covers: deps (PHP 8.2+/NGINX/Composer), MariaDB/MySQL, Panel app, SSL (LE/custom/none)
# Tested on: Ubuntu/Debian family (requires internet access & sudo)
# Refs: pelican.dev docs

# ---------- Helpers ----------
cecho() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info()  { cecho "1;34" "➜ $*"; }
warn()  { cecho "1;33" "⚠ $*"; }
err()   { cecho "1;31" "✖ $*"; }
ok()    { cecho "1;32" "✔ $*"; }

require_root() { [[ $EUID -eq 0 ]] || { err "Please run as root (sudo)."; exit 1; }; }

randpw() { tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c "${1:-20}"; echo; }

detect_php_ver() {
  # Prefer 8.4, fallback 8.3 then 8.2
  for v in 8.4 8.3 8.2; do
    if apt-cache policy "php$v-fpm" >/dev/null 2>&1; then echo "$v"; return 0; fi
  done
  echo ""
}

ensure_repos() {
  . /etc/os-release
  local id="${ID:-}" ver="${VERSION_ID:-}"
  if [[ "$id" == "ubuntu" ]]; then
    # Ondrej PPA for latest PHP
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
  elif [[ "$id" == "debian" ]]; then
    # Sury repo for PHP
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" >/etc/apt/sources.list.d/sury-php.list
  fi
}

confirm() {
  read -r -p "Proceed with installation? [y/N]: " c
  [[ "${c,,}" == "y" ]]
}

# ---------- Collect Inputs ----------
require_root

read -r -p "Panel domain (e.g. panel.example.com): " PANEL_DOMAIN
read -r -p "Admin email (for LE & panel user): " ADMIN_EMAIL

echo "SSL mode:"
echo "  1) letsencrypt (auto)"
echo "  2) custom (paste cert/key)"
echo "  3) none"
read -r -p "Select [1-3]: " SSL_CHOICE
case "$SSL_CHOICE" in
  1) SSL_MODE="letsencrypt" ;;
  2) SSL_MODE="custom" ;;
  3) SSL_MODE="none" ;;
  *) err "Invalid SSL choice"; exit 1 ;;
esac

echo "Database backend:"
echo "  1) MariaDB (recommended)"
echo "  2) MySQL 8+"
echo "  3) SQLite (single-host test)"
read -r -p "Select [1-3]: " DB_CHOICE
case "$DB_CHOICE" in
  1) DB_DRIVER="mariadb"; DB_NAME="pelican"; DB_USER="pelican"; DB_PASS="$(randpw 24)";;
  2) DB_DRIVER="mysql";   DB_NAME="pelican"; DB_USER="pelican"; DB_PASS="$(randpw 24)";;
  3) DB_DRIVER="sqlite";  DB_NAME=":memory:"; DB_USER=""; DB_PASS="";;
  *) err "Invalid DB choice"; exit 1 ;;
esac

read -r -p "Create initial admin username (e.g. admin): " ADMIN_USER
ADMIN_PASS="$(randpw 16)"

# ---------- Review ----------
clear
echo "================= Review ================="
echo "Domain:          $PANEL_DOMAIN"
echo "Admin email:     $ADMIN_EMAIL"
echo "SSL mode:        $SSL_MODE"
echo "Database:        $DB_DRIVER"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "DB name:         $DB_NAME"
  echo "DB user/pass:    $DB_USER / $DB_PASS"
fi
echo "Admin account:   $ADMIN_USER / (generated)"
echo "=========================================="

confirm || { err "Cancelled."; exit 1; }

# ---------- Install Dependencies ----------
info "Updating apt indexes..."
apt-get update -y

info "Installing base packages..."
apt-get install -y sudo lsb-release apt-transport-https ca-certificates curl gnupg unzip tar git software-properties-common >/dev/null

info "Ensuring PHP repositories..."
ensure_repos
apt-get update -y

PHPV="$(detect_php_ver)"
[[ -z "$PHPV" ]] && { err "No PHP 8.2/8.3/8.4 found in repos."; exit 1; }
info "Installing PHP $PHPV + extensions..."
apt-get install -y \
  "php$PHPV" "php$PHPV-fpm" "php$PHPV-cli" "php$PHPV-gd" "php$PHPV-mysql" \
  "php$PHPV-mbstring" "php$PHPV-bcmath" "php$PHPV-xml" "php$PHPV-curl" \
  "php$PHPV-zip" "php$PHPV-intl" "php$PHPV-sqlite3" >/dev/null

# Web server (NGINX)
info "Installing NGINX..."
apt-get install -y nginx >/dev/null
systemctl enable --now nginx >/dev/null

# Composer
if ! command -v composer >/dev/null 2>&1; then
  info "Installing Composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Databases
if [[ "$DB_DRIVER" == "mariadb" ]]; then
  info "Installing MariaDB server (>=10.6)..."
  apt-get install -y mariadb-server mariadb-client >/dev/null
  systemctl enable --now mariadb >/dev/null
elif [[ "$DB_DRIVER" == "mysql" ]]; then
  info "Installing MySQL server 8+..."
  apt-get install -y mysql-server mysql-client >/dev/null
  systemctl enable --now mysql >/dev/null
fi

# ---------- Database Setup ----------
DB_HOST="127.0.0.1"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  info "Creating database & user..."
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

# ---------- Panel Deploy ----------
PANEL_DIR="/var/www/pelican"
info "Fetching Pelican Panel into $PANEL_DIR ..."
if [[ -d "$PANEL_DIR/.git" ]]; then
  (cd "$PANEL_DIR" && git fetch --all -q && git reset --hard origin/main -q)
else
  rm -rf "$PANEL_DIR"
  git clone -q https://github.com/pelican-dev/panel.git "$PANEL_DIR"
fi

info "Installing PHP dependencies (Composer, no-dev)..."
cd "$PANEL_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q

# Environment setup
info "Generating .env & APP_KEY..."
sudo -u www-data php artisan p:environment:setup --no-interaction || php artisan p:environment:setup --no-interaction

# Configure database via artisan if not sqlite
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  info "Configuring database via artisan..."
  # Try dedicated command if present, else patch .env
  if php artisan list --raw 2>/dev/null | grep -q "^p:environment:database$"; then
    php artisan p:environment:database --no-interaction || true
    # Overwrite with our values to ensure correctness
  fi
  sed -i \
    -e "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/" \
    -e "s/^DB_HOST=.*/DB_HOST=${DB_HOST}/" \
    -e "s/^DB_PORT=.*/DB_PORT=3306/" \
    -e "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" \
    -e "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" \
    -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" \
    .env
else
  sed -i -e "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/" .env
fi

# Migrate & seed
info "Migrating database..."
php artisan migrate --seed --force

# Create admin user
info "Creating initial admin user..."
php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --password="${ADMIN_PASS}" --admin=1 --no-interaction || true

# ---------- NGINX vhost ----------
NGINX_CONF="/etc/nginx/sites-available/pelican.conf"
SSL_DIR="/etc/ssl/pelican"
mkdir -p "$SSL_DIR"

cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
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

if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  info "Issuing Let's Encrypt certificate via certbot..."
  apt-get install -y certbot python3-certbot-nginx >/dev/null
  certbot --nginx -d "${PANEL_DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --non-interactive || warn "Certbot failed; continuing with HTTP."
elif [[ "$SSL_MODE" == "custom" ]]; then
  info "Paste your FULL CHAIN certificate (END with an empty line + Ctrl-D):"
  CERT_PATH="${SSL_DIR}/${PANEL_DOMAIN}.crt"
  KEY_PATH="${SSL_DIR}/${PANEL_DOMAIN}.key"
  umask 077
  cat > "$CERT_PATH"
  info "Paste your PRIVATE KEY (END with an empty line + Ctrl-D):"
  cat > "$KEY_PATH"
  chmod 600 "$CERT_PATH" "$KEY_PATH"
  # Patch nginx for SSL
  cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};
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
    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?)\$ {
        expires 7d; access_log off;
    }
}
NGX
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
fi

nginx -t
systemctl reload nginx
systemctl enable --now "php${PHPV}-fpm" >/dev/null

# Permissions
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || true
chmod 640 "$PANEL_DIR/.env" || true

# ---------- Output ----------
clear
ok  "Pelican Panel has been installed."
echo "----------------------------------------------"
echo "URL:              http${SSL_MODE!="none" && echo "s" || echo ""}://${PANEL_DOMAIN}"
echo "Admin (initial):  ${ADMIN_USER} / ${ADMIN_PASS}"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "DB:               ${DB_DRIVER} ${DB_NAME} @ ${DB_HOST}"
  echo "DB user/pass:     ${DB_USER} / ${DB_PASS}"
fi
echo "PHP-FPM:          ${PHPV}"
echo "Panel path:       ${PANEL_DIR}"
echo "Nginx conf:       ${NGINX_CONF}"
echo "SSL mode:         ${SSL_MODE}"
echo "----------------------------------------------"
echo "Next:"
echo " - Keep your .env APP_KEY safe."
echo " - If needed, restart queue workers: php artisan queue:restart"
echo " - For Wings install, return to main menu later."
