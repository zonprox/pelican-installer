#!/usr/bin/env bash
set -Eeuo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Pelican Panel Installer (minimal, opinionated)
# - Installs Pelican Panel (PHP/Laravel app) under /var/www/pelican
# - NGINX + PHP-FPM, Composer; MariaDB (local) or remote MySQL/MariaDB
# - SSL modes: Let's Encrypt (auto), Custom (paste cert/key), None
# - Review → Confirm → Auto-install
# Notes:
# * Pelican requires PHP 8.2+ with specific extensions; we try to install via apt.
# * We'll warn (not block) on non-Ubuntu/Debian.
# * You can refine/extend later (queue tuning, Redis, Cloudflare, etc.).
# ────────────────────────────────────────────────────────────────────────────────

# --- Helpers ---
log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

is_root() { [[ "${EUID:-0}" -eq 0 ]]; }
ensure_root() { is_root || die "Please run as root (sudo)."; }

ensure_root
need_cmd curl
need_cmd git
need_cmd sed
need_cmd awk

# --- Soft OS check ---
OS_ID="unknown"
if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; fi
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  log "Notice: Detected OS: ${OS_ID}. Pelican docs primarily cover Ubuntu/Debian."
  read -rp "Continue anyway? [y/N]: " cont
  [[ "${cont,,}" == "y" ]] || exit 0
fi

# --- Defaults & Paths ---
PANEL_DIR="/var/www/pelican"
NGINX_AV="/etc/nginx/sites-available"
NGINX_EN="/etc/nginx/sites-enabled"
NGINX_FILE="${NGINX_AV}/pelican.conf"
SSL_DIR="/etc/ssl/pelican"
PHP_SOCKET=""
APP_URL=""
DB_MODE=""
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="pelican"
DB_USER="pelican"
DB_PASS=""
SSL_MODE=""
LE_EMAIL=""
CERT_PATH="${SSL_DIR}/panel.crt"
KEY_PATH="${SSL_DIR}/panel.key"

# --- Prompt inputs (number-based menus) ---
echo "Pelican Panel Setup"
echo "===================="

# Domain & URL
read -rp "Panel Domain (e.g. panel.example.com): " DOMAIN
[[ -n "${DOMAIN:-}" ]] || die "Domain is required."
APP_URL="https://${DOMAIN}"

# SSL Mode
echo
echo "SSL Mode:"
echo "1) Let's Encrypt (automatic via certbot + nginx)"
echo "2) Custom (paste PEM certificate and private key)"
echo "3) None (HTTP only)"
read -rp "Choose [1-3]: " ssl_choice
case "$ssl_choice" in
  1) SSL_MODE="letsencrypt";;
  2) SSL_MODE="custom";;
  3) SSL_MODE="none"; APP_URL="http://${DOMAIN}";;
  *) die "Invalid SSL choice";;
esac
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  read -rp "Admin email for Let's Encrypt: " LE_EMAIL
  [[ -n "${LE_EMAIL:-}" ]] || die "Email is required for Let's Encrypt."
fi

# Database mode
echo
echo "Database Mode:"
echo "1) Local MariaDB (auto install & create DB/user)"
echo "2) Remote MySQL/MariaDB (you will provide credentials)"
read -rp "Choose [1-2]: " db_choice
case "$db_choice" in
  1) DB_MODE="local";;
  2) DB_MODE="remote";;
  *) die "Invalid DB choice";;
esac

if [[ "$DB_MODE" == "remote" ]]; then
  read -rp "DB Host [127.0.0.1]: " DB_HOST_INP; DB_HOST="${DB_HOST_INP:-127.0.0.1}"
  read -rp "DB Port [3306]: " DB_PORT_INP; DB_PORT="${DB_PORT_INP:-3306}"
  read -rp "DB Name [pelican]: " DB_NAME_INP; DB_NAME="${DB_NAME_INP:-pelican}"
  read -rp "DB User [pelican]: " DB_USER_INP; DB_USER="${DB_USER_INP:-pelican}"
  read -rp "DB Password: " DB_PASS; [[ -n "$DB_PASS" ]] || die "DB password required."
else
  # local: generate strong password
  DB_PASS="$(openssl rand -base64 24 | tr -d '\n' | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-32)"
fi

# --- Review summary ---
echo
echo "Review your configuration:"
echo "--------------------------------------------"
echo "Domain        : $DOMAIN"
echo "App URL       : $APP_URL"
echo "SSL Mode      : $SSL_MODE"
[[ "$SSL_MODE" == "letsencrypt" ]] && echo "LE Email      : $LE_EMAIL"
echo "DB Mode       : $DB_MODE"
echo "DB Host       : $DB_HOST"
echo "DB Port       : $DB_PORT"
echo "DB Name       : $DB_NAME"
echo "DB User       : $DB_USER"
[[ "$DB_MODE" == "local" ]] && echo "DB Password   : (auto-generated)"
[[ "$DB_MODE" == "remote" ]] && echo "DB Password   : (provided)"
echo "Install Path  : $PANEL_DIR"
echo "--------------------------------------------"
read -rp "Proceed with installation? [y/N]: " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Cancelled."; exit 0; }

# --- System packages (minimal) ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# Web + PHP + tools
apt-get install -y nginx curl git unzip zip software-properties-common \
  php php-fpm php-cli php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3 \
  composer

# Note: Pelican recommends PHP 8.2+ with listed extensions. We install distro defaults.
# If your distro ships older PHP, consider enabling a PHP repo for 8.2+ later.

# DB (local) if chosen
if [[ "$DB_MODE" == "local" ]]; then
  apt-get install -y mariadb-server
  systemctl enable --now mariadb
  # Create DB & user (works with unix_socket auth on Ubuntu/Debian)
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
fi

# Redis (optional but useful for queue/session). Keeping minimal; install then you can enable later.
apt-get install -y redis-server || true
systemctl enable --now redis-server || true

# ── Clone Pelican Panel
if [[ -d "$PANEL_DIR" ]]; then
  echo "Existing $PANEL_DIR found. Using it as-is."
else
  git clone https://github.com/pelican-dev/panel.git "$PANEL_DIR"
fi
cd "$PANEL_DIR"

# Composer install
# Prefer production flags
composer install --no-dev --optimize-autoloader

# Environment
if [[ ! -f .env ]]; then
  cp -n .env.example .env || true
fi

# Configure .env (DB + URL + basic queue/session)
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|g" .env

# DB settings
if grep -q "^DB_CONNECTION=" .env; then
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
else
  echo "DB_CONNECTION=mysql" >> .env
fi
sed -i "s|^DB_HOST=.*|DB_HOST=${DB_HOST}|g" .env || echo "DB_HOST=${DB_HOST}" >> .env
sed -i "s|^DB_PORT=.*|DB_PORT=${DB_PORT}|g" .env || echo "DB_PORT=${DB_PORT}" >> .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env || echo "DB_DATABASE=${DB_NAME}" >> .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env || echo "DB_USERNAME=${DB_USER}" >> .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env || echo "DB_PASSWORD=${DB_PASS}" >> .env

# App key
php artisan key:generate --force

# Database migrations & seed
php artisan migrate --force --seed

# Storage permissions
chown -R www-data:www-data "$PANEL_DIR"
find "$PANEL_DIR/storage" -type d -exec chmod 775 {} \; || true
find "$PANEL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; || true

# ── PHP-FPM socket detection (best-effort)
PHP_SOCKET="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
if [[ -z "$PHP_SOCKET" ]]; then
  # fallback
  PHP_SOCKET="127.0.0.1:9000"
  FASTCGI_PASS="$PHP_SOCKET"
else
  FASTCGI_PASS="unix:${PHP_SOCKET}"
fi

# ── NGINX vhost
mkdir -p "$NGINX_AV" "$NGINX_EN"
cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;

    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass ${FASTCGI_PASS};
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|webp|ico)\$ {
        try_files \$uri =404;
        access_log off;
        expires 30d;
    }

    client_max_body_size 256m;
}
EOF

ln -sf "$NGINX_FILE" "${NGINX_EN}/pelican.conf"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ── SSL handling
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  apt-get install -y certbot python3-certbot-nginx
  # Try to obtain & auto-configure SSL
  certbot --nginx -d "$DOMAIN" -m "$LE_EMAIL" --agree-tos --redirect -n || {
    echo "Let's Encrypt automatic configuration failed. You can retry later with:"
    echo "  certbot --nginx -d $DOMAIN -m $LE_EMAIL --agree-tos --redirect"
  }
elif [[ "$SSL_MODE" == "custom" ]]; then
  mkdir -p "$SSL_DIR"
  echo
  echo "Paste your FULL CHAIN certificate (PEM) below. End with EOF (Ctrl+D):"
  cat > "$CERT_PATH"
  echo
  echo "Paste your PRIVATE KEY (PEM) below. End with EOF (Ctrl+D):"
  cat > "$KEY_PATH"
  chmod 600 "$CERT_PATH" "$KEY_PATH"

  # Replace NGINX server block with SSL-enabled one
  cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    root ${PANEL_DIR}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass ${FASTCGI_PASS};
    }
    client_max_body_size 256m;
}
EOF
  nginx -t && systemctl reload nginx
fi

# ── Queue worker (systemd)
cat > /etc/systemd/system/pelican-queue.service <<'EOF'
[Unit]
Description=Pelican Panel Queue Worker
After=network.target

[Service]
User=www-data
WorkingDirectory=/var/www/pelican
ExecStart=/usr/bin/php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pelican-queue.service

# ── Scheduler (cron)
( crontab -l 2>/dev/null | grep -v "artisan schedule:run" ; echo "* * * * * cd ${PANEL_DIR} && /usr/bin/php artisan schedule:run >> /dev/null 2>&1" ) | crontab -u www-data -

# ── Final info
echo
echo "Pelican Panel installation completed."
echo "--------------------------------------------"
echo "URL            : ${APP_URL}"
echo "Document root  : ${PANEL_DIR}/public"
echo "Nginx vhost    : ${NGINX_FILE}"
echo "Queue service  : pelican-queue.service (systemd)"
if [[ "$SSL_MODE" == "custom" ]]; then
  echo "Custom cert    : ${CERT_PATH}"
  echo "Custom key     : ${KEY_PATH}"
fi
echo "DB connection  : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
if [[ "$DB_MODE" == "local" ]]; then
  echo "DB password    : ${DB_PASS}"
fi
echo
echo "Next steps:"
echo "- Visit the URL above to finish any web-based setup if prompted."
echo "- Add Nodes then configure Wings on your servers (separate module)."
echo "- For updates & advanced config, see Pelican docs."
