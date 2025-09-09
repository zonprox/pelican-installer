#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Pelican Panel Installer (Debian/Ubuntu, minimal & friendly)
# - Installs NGINX, PHP 8.2+ (via Ondřej PPA on Ubuntu), Redis, MariaDB (optional)
# - Downloads latest Pelican Panel release to /var/www/pelican
# - Creates DB/user if MariaDB selected
# - SSL modes: letsencrypt / custom (paste cert+key) / none
# - Shows a review screen, asks for confirmation, then runs unattended
# After finish: open https://YOUR_DOMAIN/installer to complete web wizard.
# References: official Pelican docs (create dir, download panel.tar.gz, composer,
# permissions, php artisan env setup / web installer). 
# ──────────────────────────────────────────────────────────────────────────────

YELLOW="\033[33m"; GREEN="\033[32m"; RED="\033[31m"; NC="\033[0m"
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Please run this script as root (sudo).${NC}"
    exit 1
  fi
}

ask() {
  local prompt="$1" default="${2:-}"
  local ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans || true
    echo "${ans:-$default}"
  else
    read -r -p "$prompt: " ans || true
    echo "${ans}"
  fi
}

# ── 1) Gather inputs ─────────────────────────────────────────────────────────
require_root

echo "== Pelican Panel Setup =="

PANEL_DOMAIN="$(ask "Panel domain (FQDN, e.g. panel.example.com)")"
[[ -z "$PANEL_DOMAIN" ]] && { error "Domain is required."; exit 1; }

ADMIN_EMAIL="$(ask "Admin email for Let's Encrypt notifications" "admin@$PANEL_DOMAIN")"

echo
echo "SSL mode:"
echo "  1) letsencrypt (automatic)"
echo "  2) custom (paste fullchain & key)"
echo "  3) none (HTTP only)"
SSL_CHOICE="$(ask "Select [1-3]" "1")"

echo
echo "Database mode:"
echo "  1) MariaDB (recommended)"
echo "  2) SQLite (simple, not for production)"
DB_CHOICE="$(ask "Select [1-2]" "1")"

DB_NAME="pelican"
DB_USER="pelican"
DB_PASS="$(openssl rand -base64 18 | tr -d '=+/')"

PHP_VER="8.2"    # can be 8.3/8.4 where available

# ── 2) Review & confirm ──────────────────────────────────────────────────────
echo
echo "===== Review your configuration ====="
echo "Domain           : $PANEL_DOMAIN"
case "$SSL_CHOICE" in
  1) echo "SSL Mode         : Let's Encrypt (auto)" ;;
  2) echo "SSL Mode         : Custom certificate" ;;
  3) echo "SSL Mode         : None (HTTP)" ;;
esac
case "$DB_CHOICE" in
  1) echo "Database         : MariaDB"
     echo "  DB Name        : $DB_NAME"
     echo "  DB User        : $DB_USER"
     echo "  DB Password    : $DB_PASS"
     ;;
  2) echo "Database         : SQLite"
     ;;
esac
echo "PHP Version      : $PHP_VER"
echo "Install dir      : /var/www/pelican"
echo "====================================="
read -r -p "Proceed with installation? [y/N]: " yn
[[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

# ── 3) Package repositories & dependencies ───────────────────────────────────
info "Updating system packages…"
apt-get update -y

# PHP repo for Ubuntu; on Debian bookworm PHP 8.2 is available natively.
if grep -qi ubuntu /etc/os-release; then
  info "Adding PHP PPA (Ondřej)…"
  apt-get install -y software-properties-common ca-certificates lsb-release apt-transport-https curl
  add-apt-repository -y ppa:ondrej/php || true
  apt-get update -y
fi

info "Installing base packages (NGINX, Redis, PHP $PHP_VER + extensions, tools)…"
apt-get install -y \
  nginx redis-server unzip tar curl git \
  php$PHP_VER php$PHP_VER-fpm php$PHP_VER-cli php$PHP_VER-gd php$PHP_VER-mysql php$PHP_VER-mbstring \
  php$PHP_VER-bcmath php$PHP_VER-xml php$PHP_VER-curl php$PHP_VER-zip php$PHP_VER-intl php$PHP_VER-sqlite3

# MariaDB (if chosen)
if [[ "$DB_CHOICE" == "1" ]]; then
  info "Installing MariaDB server & client…"
  apt-get install -y mariadb-server mariadb-client
  systemctl enable --now mariadb
fi

# Composer
if ! command -v composer >/dev/null 2>&1; then
  info "Installing Composer…"
  curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# ── 4) Panel files ───────────────────────────────────────────────────────────
info "Creating /var/www/pelican and downloading latest Panel…"
mkdir -p /var/www/pelican
cd /var/www/pelican

# Download latest release tarball and extract (official docs)
# https://pelican.dev/docs/panel/getting-started/
curl -fsSL "https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz" | tar -xzv

# Install PHP dependencies (no-dev, optimize autoloader)
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# ── 5) Database setup ────────────────────────────────────────────────────────
if [[ "$DB_CHOICE" == "1" ]]; then
  info "Creating MariaDB database & user…"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';"
  mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1'; FLUSH PRIVILEGES;"
fi

# ── 6) Basic .env priming (use web installer to finalize) ────────────────────
# We'll let the built-in web wizard finalize at https://DOMAIN/installer
# https://pelican.dev/docs/panel/panel-setup/ ; https://blog.aflorzy.com/... (/installer)
cp -n .env.example .env || true
php artisan key:generate --force

# Minimal environment defaults
sed -i "s|^APP_URL=.*|APP_URL=https://$PANEL_DOMAIN|g" .env
sed -i "s|^APP_ENV=.*|APP_ENV=production|g" .env
sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env

if [[ "$DB_CHOICE" == "1" ]]; then
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
  sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
  sed -i "s|^DB_PORT=.*|DB_PORT=3306|g" .env
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB_NAME|g" .env
  sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$DB_USER|g" .env
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|g" .env
else
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=sqlite|g" .env
  touch /var/www/pelican/database/database.sqlite
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=/var/www/pelican/database/database.sqlite|g" .env
fi

# ── 7) NGINX vhost ───────────────────────────────────────────────────────────
# Minimal NGINX config for PHP-FPM (fastcgi_pass defaults may vary per distro)
PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
NGINX_SITE="/etc/nginx/sites-available/pelican"

cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    root /var/www/pelican/public;

    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~* \.(jpg|jpeg|png|gif|css|js|ico|svg)\$ {
        expires 30d;
        access_log off;
    }
}
NGINX

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/pelican
[[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx
systemctl restart "php${PHP_VER}-fpm"

# ── 8) SSL handling ──────────────────────────────────────────────────────────
case "$SSL_CHOICE" in
  1)
    info "Issuing Let's Encrypt certificate…"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$PANEL_DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --redirect --no-eff-email || {
      warn "Certbot failed; keeping HTTP for now. You can retry later with: certbot --nginx -d $PANEL_DOMAIN"
    }
    ;;
  2)
    info "Using custom certificate (PEM). You will be prompted to paste contents."
    SSL_DIR="/etc/ssl/pelican"
    mkdir -p "$SSL_DIR"
    echo "Paste your FULLCHAIN (END with a line containing only a single dot '.'), then ENTER:"
    FULLCHAIN="$(awk 'BEGIN{first=1} {if($0=="."){exit} if(!first) printf "\n"; printf "%s",$0; first=0}')"
    echo "Paste your PRIVATE KEY (END with a line containing only a single dot '.'), then ENTER:"
    PRIVKEY="$(awk 'BEGIN{first=1} {if($0=="."){exit} if(!first) printf "\n"; printf "%s",$0; first=0}')"

    echo "$FULLCHAIN" > "$SSL_DIR/fullchain.pem"
    echo "$PRIVKEY"  > "$SSL_DIR/privkey.pem"
    chmod 600 "$SSL_DIR/"*.pem

    # Replace nginx server block with SSL
    cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};
    root /var/www/pelican/public;

    ssl_certificate     ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;

    index index.php;
    client_max_body_size 100m;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }
    location ~* \.(jpg|jpeg|png|gif|css|js|ico|svg)\$ {
        expires 30d;
        access_log off;
    }
}
NGINX
    nginx -t && systemctl reload nginx
    ;;
  3)
    warn "SSL disabled. You can enable later via Let's Encrypt or custom cert."
    ;;
esac

# ── 9) Permissions & services ────────────────────────────────────────────────
chown -R www-data:www-data /var/www/pelican
chmod -R 755 /var/www/pelican/storage /var/www/pelican/bootstrap/cache || true

systemctl restart nginx "php${PHP_VER}-fpm" redis-server || true

# ── 10) Final messages ───────────────────────────────────────────────────────
echo
echo -e "${GREEN}Pelican Panel base install completed!${NC}"
echo "Next step: open the web installer to finish configuration:"
echo -e "  -> ${YELLOW}https://${PANEL_DOMAIN}/installer${NC}"
echo
echo "Tips:"
echo " - If you see a 500 error later, check logs and permissions."
echo " - To retry Let's Encrypt: certbot --nginx -d ${PANEL_DOMAIN}"
echo " - To update Wings later, see official docs."
