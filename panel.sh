#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel Installer - Basic, clean, test-friendly
# Flow: input -> review -> confirm -> install core stack
# Minimal dependencies; no firewall, no extras. Clear logs.

# ---------- preflight ----------
[[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }

LOG_DIR="/var/log/pelican-installer"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/panel-$(date +%Y%m%d-%H%M%S).log"
exec > >(stdbuf -oL tee -a "$LOG_FILE") 2>&1
trap 'code=$?; [[ $code -eq 0 ]] && echo "✔ Done. Log: $LOG_FILE" || echo "✖ Failed (exit $code). See: $LOG_FILE"' EXIT

# ---------- helpers ----------
q() { printf "%s" "$1"; }
ask() {  # ask "Prompt" "default" "validator(empty_ok|nonempty|domain|email|port|int)"
  local p="$1" def="${2:-}" val="${3:-}" ans
  while true; do
    if [[ -n "$def" ]]; then printf "%s [%s]: " "$p" "$def"; else printf "%s: " "$p"; fi
    IFS= read -r ans || ans=""
    ans="${ans:-$def}"
    case "$val" in
      "" ) echo "$ans"; return ;;
      nonempty ) [[ -n "$ans" ]] && { echo "$ans"; return; } ;;
      empty_ok ) echo "$ans"; return ;;
      domain ) [[ "$ans" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] && { echo "$ans"; return; } ;;
      email )  [[ "$ans" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && { echo "$ans"; return; } ;;
      port )   [[ "$ans" =~ ^[0-9]{2,5}$ ]] && { echo "$ans"; return; } ;;
      int )    [[ "$ans" =~ ^[0-9]+$ ]] && { echo "$ans"; return; } ;;
    esac
    echo "Invalid value. Please try again."
  done
}

menu() {  # menu "Title" default "opt1" "opt2" ...
  local title="$1" def="$2"; shift 2; local opts=("$@") n="${#opts[@]}" c
  echo; echo "$title"
  for i in "${!opts[@]}"; do local i1=$((i+1)); [[ $i1 -eq $def ]] && printf "  %d) %s [default]\n" "$i1" "${opts[$i]}" || printf "  %d) %s\n" "$i1" "${opts[$i]}"; done
  while true; do printf "Select [%d]: " "$def"; IFS= read -r c || c=""; [[ -z "$c" ]] && { echo "$def"; return; }
    [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le "$n" ]] && { echo "$c"; return; }
    echo "Enter a number 1..$n (or Enter for default)."
  done
}

have()     { command -v "$1" >/dev/null 2>&1; }
die()      { echo "✖ $*"; exit 1; }
apt_i()    { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null; }
php_pick() { for v in 8.4 8.3 8.2; do apt-cache policy "php$v-fpm" >/dev/null 2>&1 && { echo "$v"; return; }; done; echo ""; }

ensure_php_repo() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    apt_i software-properties-common || true
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
  elif [[ "${ID:-}" == "debian" ]]; then
    apt-get update -y
    apt_i ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" >/etc/apt/sources.list.d/sury-php.list
  fi
}

sql_exec() { if have mysql; then mysql   -u root -e "$1" || true; elif have mariadb; then mariadb -u root -e "$1" || true; fi; }
genpw()    { tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c "${1:-16}"; echo; }

# ---------- 1) Input ----------
echo ">>> Input"
[[ -r /etc/os-release ]] && { . /etc/os-release; echo "Detected OS: ${ID^} ${VERSION_ID:-}"; [[ "$ID" != "ubuntu" && "$ID" != "debian" && "${ID_LIKE:-}" != *debian* ]] && { echo "Warning: non-Debian/Ubuntu. Continue at your own risk."; read -r -p "Continue? [y/N]: " c; [[ "${c,,}" == "y" ]] || die "Aborted."; }; }

DOMAIN="$(ask 'Panel domain (e.g. panel.example.com)' '' domain)"
ADMIN_EMAIL="$(ask 'Admin email (for SSL & panel)' '' email)"

ssl_sel="$(menu 'SSL mode:' 1 'letsencrypt (auto)' 'custom (paste cert/key)' 'none')"
case "$ssl_sel" in 1) SSL_MODE="letsencrypt";; 2) SSL_MODE="custom";; 3) SSL_MODE="none";; esac

redir_sel="$(menu 'Redirect HTTP to HTTPS?' 1 'yes (recommended)' 'no')"
REDIR=$([[ "$redir_sel" == "1" ]] && echo "yes" || echo "no")

db_sel="$(menu 'Database backend:' 1 'MariaDB (recommended)' 'MySQL 8+' 'SQLite (testing)')"
case "$db_sel" in
  1) DB_DRIVER="mariadb";;
  2) DB_DRIVER="mysql";;
  3) DB_DRIVER="sqlite";;
esac
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  DB_NAME="$(ask 'DB name' 'pelican' nonempty)"
  DB_USER="$(ask 'DB user' 'pelican' nonempty)"
  DB_PASS="$(ask 'DB password (empty = auto-generate)' '' empty_ok)"; [[ -z "$DB_PASS" ]] && DB_PASS="$(genpw 24)"
  DB_HOST="$(ask 'DB host' '127.0.0.1' nonempty)"
  DB_PORT="$(ask 'DB port' '3306' port)"
else
  DB_NAME=":memory:"; DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT=""
fi

redis_sel="$(menu 'Install Redis for cache/session?' 1 'yes' 'no')"
INSTALL_REDIS=$([[ "$redis_sel" == "1" ]] && echo "yes" || echo "no")

TIMEZONE="$(ask 'Server timezone (PHP)' 'Asia/Ho_Chi_Minh' nonempty)"
BRANCH="$(ask 'Panel branch/tag' 'main' nonempty)"
ADMIN_USER="$(ask 'Admin username' 'admin' nonempty)"
set_pw="$(ask 'Set admin password manually? (y/n)' 'n' nonempty)"
if [[ "${set_pw,,}" =~ ^y ]]; then ADMIN_PASS="$(ask 'Admin password' '' nonempty)"; else ADMIN_PASS="$(genpw 16)"; fi

# ---------- 2) Review ----------
clear
cat <<REVIEW
================ Review ================
Domain:            $DOMAIN
Admin email:       $ADMIN_EMAIL
SSL mode:          $SSL_MODE
Redirect HTTPS:    $REDIR
Database:          $DB_DRIVER
$( [[ "$DB_DRIVER" != "sqlite" ]] && echo "  DB host/port:    $DB_HOST:$DB_PORT
  DB name:         $DB_NAME
  DB user/pass:    $DB_USER / $DB_PASS" )
Redis install:     $INSTALL_REDIS
Timezone (PHP):    $TIMEZONE
Panel branch:      $BRANCH
Admin account:     $ADMIN_USER / (hidden)
Log file:          $LOG_FILE
========================================
REVIEW
read -r -p "Proceed with installation? [y/N]: " go
[[ "${go,,}" == "y" ]] || die "Cancelled."

# ---------- 3) Install (basic) ----------
echo ">>> apt base"
have apt-get || die "apt-get not found"
apt-get update -y
apt_i curl ca-certificates lsb-release apt-transport-https gnupg unzip tar git

echo ">>> PHP repo & packages"
ensure_php_repo; apt-get update -y
PHPV="$(php_pick)"; [[ -z "$PHPV" ]] && die "No PHP 8.2/8.3/8.4 packages found."
apt_i "php$PHPV" "php$PHPV-fpm" "php$PHPV-cli" "php$PHPV-gd" "php$PHPV-mysql" "php$PHPV-mbstring" "php$PHPV-bcmath" "php$PHPV-xml" "php$PHPV-curl" "php$PHPV-zip" "php$PHPV-intl" "php$PHPV-sqlite3"
[[ "$INSTALL_REDIS" == "yes" ]] && apt_i "php$PHPV-redis"
sed -i "s~^;*date.timezone =.*~date.timezone = ${TIMEZONE}~" "/etc/php/${PHPV}/fpm/php.ini" || true
systemctl enable --now "php${PHPV}-fpm"

echo ">>> NGINX"
apt_i nginx; systemctl enable --now nginx

echo ">>> Composer"
if ! have composer; then curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; fi

if [[ "$DB_DRIVER" == "mariadb" ]]; then
  echo ">>> MariaDB"
  apt_i mariadb-server mariadb-client; systemctl enable --now mariadb
elif [[ "$DB_DRIVER" == "mysql" ]]; then
  echo ">>> MySQL"
  apt_i mysql-server mysql-client; systemctl enable --now mysql
fi

if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo ">>> Create DB/user"
  sql_exec "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  sql_exec "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';"
  sql_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
fi

echo ">>> Fetch Panel"
PANEL_DIR="/var/www/pelican"
REPO_URL="https://github.com/pelican-dev/panel.git"
rm -rf "$PANEL_DIR"
git clone -q --branch "$BRANCH" "$REPO_URL" "$PANEL_DIR"

echo ">>> Composer install"
cd "$PANEL_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -q

echo ">>> .env"
[[ -f .env ]] || cp .env.example .env 2>/dev/null || touch .env
APP_PROTO=$([[ "$SSL_MODE" == "none" ]] && echo "http" || echo "https")
APP_URL="${APP_PROTO}://${DOMAIN}"
sed -i -E "s|^APP_ENV=.*|APP_ENV=production|; s|^APP_DEBUG=.*|APP_DEBUG=false|; s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  sed -i -E "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|; s|^DB_HOST=.*|DB_HOST=${DB_HOST}|; s|^DB_PORT=.*|DB_PORT=${DB_PORT}|; s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|; s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|; s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
else
  sed -i -E "s|^DB_CONNECTION=.*|DB_CONNECTION=sqlite|" .env
fi
if [[ "$INSTALL_REDIS" == "yes" ]]; then
  grep -q '^REDIS_HOST=' .env || echo "REDIS_HOST=127.0.0.1" >> .env
  grep -q '^REDIS_PORT=' .env || echo "REDIS_PORT=6379" >> .env
  sed -i -E "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|; s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
fi

echo ">>> key & migrate"
php artisan key:generate --force || true
php artisan migrate --force || true
php artisan db:seed --force || true

if php artisan list --no-ansi 2>/dev/null | grep -q '^p:user:make'; then
  php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --password="$ADMIN_PASS" --admin=1 --no-interaction || true
fi

if [[ "$INSTALL_REDIS" == "yes" ]]; then
  echo ">>> Redis server"
  apt_i redis-server; systemctl enable --now redis-server
fi

echo ">>> NGINX vhost"
NGINX_CONF="/etc/nginx/sites-available/pelican.conf"
SSL_DIR="/etc/ssl/pelican"; mkdir -p "$SSL_DIR"
cat > "$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;
    index index.php;
    client_max_body_size 100m;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock; }
    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?)\$ { expires 7d; access_log off; }
}
NGX
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
rm -f /etc/nginx/sites-enabled/default || true

if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  echo ">>> Let’s Encrypt"
  apt_i certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --no-eff-email --non-interactive || echo "LE failed; keep HTTP."
elif [[ "$SSL_MODE" == "custom" ]]; then
  CERT_PATH="${SSL_DIR}/${DOMAIN}.crt"; KEY_PATH="${SSL_DIR}/${DOMAIN}.key"; umask 077
  echo "Paste FULL CHAIN certificate (end with Ctrl-D):"; cat > "$CERT_PATH"
  echo "Paste PRIVATE KEY (end with Ctrl-D):";          cat > "$KEY_PATH"; chmod 600 "$CERT_PATH" "$KEY_PATH"
  cat > "$NGINX_CONF" <<NGX
server { listen 80; server_name ${DOMAIN}; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name ${DOMAIN}; root ${PANEL_DIR}/public;
    ssl_certificate ${CERT_PATH}; ssl_certificate_key ${KEY_PATH};
    index index.php; client_max_body_size 100m;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock; }
    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?)\$ { expires 7d; access_log off; }
}
NGX
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
fi

if [[ "$REDIR" == "yes" && "$SSL_MODE" != "none" ]]; then
  # ensure an HTTP->HTTPS redirect block exists (LE often does this automatically)
  grep -q "return 301 https" "$NGINX_CONF" || sed -i "1iserver { listen 80; server_name ${DOMAIN}; return 301 https://\$host\$request_uri; }" "$NGINX_CONF"
fi

nginx -t && systemctl reload nginx
chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
chmod 640 "$PANEL_DIR/.env" 2>/dev/null || true

# ---------- 4) Final ----------
PROTO=$([[ "$SSL_MODE" == "none" ]] && echo "http" || echo "https")
clear
echo "========================================"
echo " Pelican Panel installed"
echo "----------------------------------------"
echo "URL:              ${PROTO}://${DOMAIN}"
echo "Admin username:   ${ADMIN_USER}"
echo "Admin password:   ${ADMIN_PASS}"
if [[ "$DB_DRIVER" != "sqlite" ]]; then
  echo "DB:               ${DB_DRIVER} ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
  echo "DB user/pass:     ${DB_USER} / ${DB_PASS}"
fi
echo "PHP-FPM:          ${PHPV} (timezone: ${TIMEZONE})"
echo "Redis installed:  ${INSTALL_REDIS}"
echo "Panel path:       ${PANEL_DIR}"
echo "NGINX conf:       ${NGINX_CONF}"
echo "SSL mode:         ${SSL_MODE} (Redirect HTTPS: ${REDIR})"
echo "Log file:         ${LOG_FILE}"
echo "========================================"
