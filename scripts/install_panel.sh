#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${THIS_DIR}/common.sh"

require_root
detect_os_or_die
install_base
ensure_sury

say_info "Pelican Panel installer — guided setup (Debian/Ubuntu)."

# ── Inputs ─────────────────────────────────────────────────────────────────────
prompt DOMAIN      "Panel domain (e.g. panel.example.com)"
prompt ADMIN_EMAIL "Admin email (Let's Encrypt contact)" "admin@${DOMAIN}"

read -rp "Database engine: MariaDB or SQLite? (M/s) [M]: " _dbc || true; _dbc="${_dbc:-M}"
if [[ "$_dbc" =~ ^[Ss]$ ]]; then
  DB_ENGINE="sqlite"
else
  DB_ENGINE="mariadb"
  prompt DB_NAME "DB name" "pelicanpanel"
  prompt DB_USER "DB user" "pelican"
  read -rp "DB password (blank = auto-generate): " DB_PASS_IN || true
  DB_PASS="$(gen_pass "${DB_PASS_IN:-}")"
fi

prompt ADMIN_USERNAME   "Admin username" "admin"
prompt ADMIN_EMAILLOGIN "Admin login email" "admin@${DOMAIN}"
read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD_IN || true
ADMIN_PASSWORD="$(gen_pass "${ADMIN_PASSWORD_IN:-}")"

read -rp "Configure SMTP now? (y/N): " _smtp || true; _smtp="${_smtp:-N}"
if [[ "$_smtp" =~ ^[Yy]$ ]]; then
  SETUP_SMTP="y"
  prompt SMTP_FROM_NAME  "SMTP From name"  "Pelican Panel"
  prompt SMTP_FROM_EMAIL "SMTP From email" "noreply@${DOMAIN}"
  prompt SMTP_HOST       "SMTP host"
  prompt SMTP_PORT       "SMTP port" "587"
  prompt SMTP_USER       "SMTP username"
  prompt SMTP_PASS       "SMTP password"
  prompt SMTP_ENC        "SMTP encryption (tls/ssl/none)" "tls"
else
  SETUP_SMTP="n"
fi

prompt_choice SSL_MODE "SSL mode (letsencrypt/custom)" "letsencrypt"

CERT_PEM=""; KEY_PEM=""
if [[ "$SSL_MODE" == "custom" ]]; then
  echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"
  CERT_PEM="$(cat)"
  echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"
  umask 077; KEY_PEM="$(cat)"; umask 022
  if ! grep -q "BEGIN CERTIFICATE" <<<"$CERT_PEM"; then say_warn "Certificate PEM header missing."; fi
  if ! grep -q "BEGIN " <<<"$KEY_PEM"; then say_warn "Key PEM header missing."; fi
fi

read -rp "Use Cloudflare API to create proxied A record & Real-IP include? (y/N): " _cf || true; _cf="${_cf:-N}"
if [[ "$_cf" =~ ^[Yy]$ ]]; then
  CF_ENABLE="y"
  prompt CF_API_TOKEN "Cloudflare API Token (Zone DNS Edit)"
  prompt CF_ZONE_ID   "Cloudflare Zone ID"
  prompt CF_DNS_NAME  "DNS record name" "${DOMAIN}"
  CF_RECORD_IP="$(detect_public_ip)"
  prompt CF_RECORD_IP "Server public IP for A record" "${CF_RECORD_IP}"
else
  CF_ENABLE="n"
fi

prompt INSTALL_DIR "Install directory" "/var/www/pelican"
prompt NGINX_CONF  "Nginx vhost path"  "/etc/nginx/sites-available/pelican.conf"

# ── Review ─────────────────────────────────────────────────────────────────────
echo
echo "──────────────── Configuration Review ────────────────"
echo "Domain:                 $DOMAIN"
echo "Admin contact:          $ADMIN_EMAIL"
echo "Install dir:            $INSTALL_DIR"
echo "Nginx vhost:            $NGINX_CONF"
echo "Database engine:        $DB_ENGINE"
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  echo "  - DB name/user:       $DB_NAME / $DB_USER"
  echo "  - DB password:        $(mask "$DB_PASS")"
else
  echo "  - SQLite file:        $INSTALL_DIR/database/database.sqlite"
fi
echo "Admin account:          $ADMIN_USERNAME / $ADMIN_EMAILLOGIN / $(mask "$ADMIN_PASSWORD")"
echo "SMTP configure:         $( [[ "$SETUP_SMTP" == "y" ]] && echo Yes || echo No )"
echo "SSL mode:               $SSL_MODE"
[[ "$SSL_MODE" == "custom" ]] && echo "  - Custom PEM headers: $(echo "$CERT_PEM" | head -n1) / $(echo "$KEY_PEM" | head -n1)"
echo "Cloudflare:             $( [[ "$CF_ENABLE" == "y" ]] && echo Enabled || echo Disabled )"
[[ "$CF_ENABLE" == "y" ]] && echo "  - DNS name/ip:        $CF_DNS_NAME / $CF_RECORD_IP"
echo "──────────────────────────────────────────────────────"
read -rp "Proceed? (Y/n): " ok || true; ok="${ok:-Y}"
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Packages ───────────────────────────────────────────────────────────────────
apt-get install -y nginx \
  php8.4 php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql php8.4-mbstring php8.4-bcmath \
  php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-sqlite3 \
  redis-server certbot python3-certbot-nginx
systemctl enable --now redis-server
enable_ufw

# DB
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  apt-get install -y mariadb-server mariadb-client
fi

# Composer
if ! command -v composer >/dev/null 2>&1; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# ── Download & install Panel (docs recommend tar+composer) ─────────────────────
# Ref: Getting Started → download + composer. :contentReference[oaicite:6]{index=6}
mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
if [[ ! -f artisan ]]; then
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
fi
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# Database bootstrap
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
else
  mkdir -p "${INSTALL_DIR}/database"
  : > "${INSTALL_DIR}/database/database.sqlite"
fi

chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" || true

# ── Nginx vhost & SSL ──────────────────────────────────────────────────────────
rm -f /etc/nginx/sites-enabled/default || true
PHP_DET="$(detect_phpfpm || true)"; PHP_VERSION="${PHP_DET%%|*}"; PHP_SOCK="${PHP_DET##*|}"
[[ -z "$PHP_SOCK" ]] && { PHP_VERSION="8.4"; PHP_SOCK="/run/php/php8.4-fpm.sock"; }

cat > "$NGINX_CONF" <<NG80
server_tokens off;
server {
    listen 80;
    server_name ${DOMAIN};
    root ${INSTALL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pelican.access.log;
    error_log  /var/log/nginx/pelican.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }

    location ~ /\.ht { deny all; }
}
NG80

CUSTOM_CERT="/etc/ssl/certs/${DOMAIN}.crt"
CUSTOM_KEY="/etc/ssl/private/${DOMAIN}.key"

if [[ "$SSL_MODE" == "custom" ]]; then
  mkdir -p /etc/ssl/certs /etc/ssl/private
  echo "$CERT_PEM" > "$CUSTOM_CERT"
  umask 077; echo "$KEY_PEM"  > "$CUSTOM_KEY"; umask 022
  chown root:root "$CUSTOM_CERT" "$CUSTOM_KEY"
  chmod 644 "$CUSTOM_CERT"; chmod 600 "$CUSTOM_KEY"

  cat >> "$NGINX_CONF" <<NG443

server { listen 80; server_name ${DOMAIN}; return 301 https://\$host\$request_uri; }

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate     ${CUSTOM_CERT};
    ssl_certificate_key ${CUSTOM_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    root ${INSTALL_DIR}/public; index index.php;

    access_log /var/log/nginx/pelican.access.log;
    error_log  /var/log/nginx/pelican.error.log error;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }
    location ~ /\.ht { deny all; }
}
NG443
fi

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$(basename "$NGINX_CONF")"
nginx -t && systemctl restart nginx

if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  # Official docs: use certbot for SSL creation. :contentReference[oaicite:7]{index=7}
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL}" --no-eff-email || say_warn "Certbot failed — check DNS/Cloudflare."
  systemctl reload nginx || true
fi

# ── .env + Pelican CLI (skips web installer) ───────────────────────────────────
cp -n .env.example .env || true
grep -q '^APP_URL=' .env && sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env || echo "APP_URL=https://${DOMAIN}" >> .env
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/" .env
  sed -i "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" .env
  sed -i "s/^DB_PORT=.*/DB_PORT=3306/" .env
  sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
  sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env
else
  sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/" .env
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${I_*_
