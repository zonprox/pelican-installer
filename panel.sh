#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel Installer (fixed)
# - Collect all inputs first -> Review -> Confirm -> Fully automatic install
# - Fix DB auth (always set DB_PASSWORD + host = 127.0.0.1, create users for '%' and 'localhost')
# - Run composer & artisan as www-data (no root warning)
# - Clear config cache before migrations

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
need_cmd runuser
need_cmd openssl

# Soft OS check
OS_ID="unknown"; [[ -f /etc/os-release ]] && { . /etc/os-release; OS_ID="${ID:-unknown}"; }
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  log "Notice: Detected OS '${OS_ID}'. Ubuntu/Debian is recommended, but continuing is allowed."
  read -rp "Continue anyway? [y/N]: " cont
  [[ "${cont,,}" == "y" ]] || exit 0
fi

# Defaults/paths
PANEL_DIR="/var/www/pelican"
NGINX_AV="/etc/nginx/sites-available"
NGINX_EN="/etc/nginx/sites-enabled"
NGINX_FILE="${NGINX_AV}/pelican.conf"
SSL_DIR="/etc/ssl/pelican"
PHP_SOCKET=""
APP_URL=""
DOMAIN=""
SSL_MODE=""
LE_EMAIL=""

DB_MODE=""
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="pelican"
DB_USER="pelican"
DB_PASS=""

# Helper to set key in .env robustly
write_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s#^${key}=.*#${key}=${val}#g" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

# ── 1) Collect inputs
echo "Pelican Panel Setup — Input"
echo "==========================="

# Domain & URL scheme depend on SSL mode, but ask domain first
read -rp "Panel Domain (e.g. panel.example.com): " DOMAIN
[[ -n "${DOMAIN:-}" ]] || die "Domain is required."

echo
echo "SSL Mode:"
echo "1) Let's Encrypt (auto via certbot + nginx)"
echo "2) Custom (paste PEM certificate and private key)"
echo "3) None (HTTP only)"
read -rp "Choose [1-3]: " ssl_choice
case "$ssl_choice" in
  1) SSL_MODE="letsencrypt"; APP_URL="https://${DOMAIN}";;
  2) SSL_MODE="custom";      APP_URL="https://${DOMAIN}";;
  3) SSL_MODE="none";        APP_URL="http://${DOMAIN}";;
  *) die "Invalid SSL choice";;
esac
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  read -rp "Admin email for Let's Encrypt: " LE_EMAIL
  [[ -n "${LE_EMAIL:-}" ]] || die "Email is required for Let's Encrypt."
fi

echo
echo "Database Mode:"
echo "1) Local MariaDB (auto install & create DB/user)"
echo "2) Remote MySQL/MariaDB (provide credentials)"
read -rp "Choose [1-2]: " db_choice
case "$db_choice" in
  1) DB_MODE="local"; DB_HOST="127.0.0.1";;
  2) DB_MODE="remote";;
  *) die "Invalid DB choice";;
esac

if [[ "$DB_MODE" == "remote" ]]; then
  read -rp "DB Host [127.0.0.1]: " DB_HOST_INP; DB_HOST="${DB_HOST_INP:-127.0.0.1}"
  read -rp "DB Port [3306]: " DB_PORT_INP; DB_PORT="${DB_PORT_INP:-3306}"
  read -rp "DB Name [pelican]: " DB_NAME_INP; DB_NAME="${DB_NAME_INP:-pelican}"
  read -rp "DB User [pelican]: " DB_USER_INP; DB_USER="${DB_USER_INP:-pelican}"
  read -rp "DB Password: " DB_PASS
  [[ -n "$DB_PASS" ]] || die "DB password required."
else
  # Local: generate strong password (alnum)
  DB_PASS="$(openssl rand -base64 24 | tr -cd '[:alnum:]' | cut -c1-24)"
fi

# ── 2) Review
echo
echo "Review Configuration"
echo "--------------------"
echo "Domain        : $DOMAIN"
echo "App URL       : $APP_URL"
echo "SSL Mode      : $SSL_MODE"
[[ "$SSL_MODE" == "letsencrypt" ]] && echo "LE Email      : $LE_EMAIL"
echo "DB Mode       : $DB_MODE"
echo "DB Host       : $DB_HOST"
echo "DB Port       : $DB_PORT"
echo "DB Name       : $DB_NAME"
echo "DB User       : $DB_USER"
echo "DB Password   : $([[ "$DB_MODE" == "local" ]] && echo '(auto-generated)' || echo '(provided)')"
echo "Install Path  : $PANEL_DIR"
echo "--------------------"
read -rp "Proceed with installation? [y/N]: " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Cancelled."; exit 0; }

# ── 3) Install base packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx curl git unzip zip software-properties-common \
  php php-fpm php-cli php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3 \
  composer redis-server

systemctl enable --now nginx
systemctl enable --now redis-server || true

# ── 4) DB setup
if [[ "$DB_MODE" == "local" ]]; then
  apt-get install -y mariadb-server
  systemctl enable --now mariadb

  # Create DB & users; create both 'localhost' and '%' to avoid host-match surprises
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%'        IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';"
  mysql -e "FLUSH PRIVILEGES;"
else
  # Quick connectivity check (TCP). If fails, stop early.
  if ! mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "-p${DB_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
    die "Cannot connect to remote DB with provided credentials. Please verify and retry."
  fi
fi

# ── 5) Clone panel
if [[ -d "$PANEL_DIR" ]]; then
  echo "Existing $PANEL_DIR found. Using it as-is."
else
  git clone https://github.com/pelican-dev/panel.git "$PANEL_DIR"
fi
cd "$PANEL_DIR"

# Ensure ownership for web user before composer
chown -R www-data:www-data "$PANEL_DIR"

# ── 6) Composer install as www-data (no root warning)
# Use runuser to execute as www-data
if [[ ! -f composer.json ]]; then
  die "composer.json not found in $PANEL_DIR (repo layout may have changed)."
fi
runuser -u www-data -- composer install --no-dev --optimize-autoloader

# ── 7) Configure environment
[[ -f .env ]] || cp -n .env.example .env || true

write_env "APP_ENV" "production"
write_env "APP_DEBUG" "false"
write_env "APP_URL" "${APP_URL}"

write_env "DB_CONNECTION" "mysql"
write_env "DB_HOST" "${DB_HOST}"
write_env "DB_PORT" "${DB_PORT}"
write_env "DB_DATABASE" "${DB_NAME}"
write_env "DB_USERNAME" "${DB_USER}"
write_env "DB_PASSWORD" "${DB_PASS}"

# ── 8) Laravel app init as www-data
runuser -u www-data -- php artisan config:clear
runuser -u www-data -- php artisan key:generate --force
runuser -u www-data -- php artisan migrate --force --no-interaction
# Seed tùy nhu cầu: runuser -u www-data -- php artisan db:seed --force

# Permissions (again, after artisan may create dirs/files)
chown -R www-data:www-data "$PANEL_DIR"
find "$PANEL_DIR/storage" -type d -exec chmod 775 {} \; || true
find "$PANEL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; || true

# ── 9) PHP-FPM socket detection
PHP_SOCKET="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
FASTCGI_PASS="${PHP_SOCKET:+unix:${PHP_SOCKET}}"
[[ -z "$FASTCGI_PASS" ]] && FASTCGI_PASS="127.0.0.1:9000"

# ── 10) Nginx vhost
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
nginx -t && systemctl reload nginx

# ── 11) SSL
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" -m "$LE_EMAIL" --agree-tos --redirect -n || {
    echo "Let's Encrypt automatic configuration failed. You can retry later:"
    echo "  certbot --nginx -d $DOMAIN -m $LE_EMAIL --agree-tos --redirect"
  }
elif [[ "$SSL_MODE" == "custom" ]]; then
  mkdir -p "$SSL_DIR"
  echo
  echo "Paste your FULL CHAIN certificate (PEM) below. End with EOF (Ctrl+D):"
  cat > "${SSL_DIR}/panel.crt"
  echo
  echo "Paste your PRIVATE KEY (PEM) below. End with EOF (Ctrl+D):"
  cat > "${SSL_DIR}/panel.key"
  chmod 600 "${SSL_DIR}/panel.crt" "${SSL_DIR}/panel.key"

  cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_DIR}/panel.crt;
    ssl_certificate_key ${SSL_DIR}/panel.key;

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

# ── 12) Queue worker (systemd) + Scheduler
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

# cron (per-minute scheduler) for www-data
( crontab -u www-data -l 2>/dev/null | grep -v "artisan schedule:run" ; echo "* * * * * cd ${PANEL_DIR} && /usr/bin/php artisan schedule:run >/dev/null 2>&1" ) | crontab -u www-data -

# ── 13) Final info
echo
echo "Pelican Panel installation completed."
echo "--------------------------------------------"
echo "URL            : ${APP_URL}"
echo "Document root  : ${PANEL_DIR}/public"
echo "Nginx vhost    : ${NGINX_FILE}"
echo "Queue service  : pelican-queue.service"
echo "DB connection  : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
if [[ "$DB_MODE" == "local" ]]; then
  echo "DB password    : ${DB_PASS}"
fi
echo
echo "Notes:"
echo "- Composer & Artisan ran as www-data (no root warning)."
echo "- .env was written with non-empty DB_PASSWORD and APP_URL."
echo "- Config cache cleared before migrations to avoid stale env."
