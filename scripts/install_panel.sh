#!/usr/bin/env bash
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base
enable_ufw
ensure_nginx
ensure_php_84
ensure_redis
composer_setup

: "${DOMAIN:?missing}"; : "${ADMIN_EMAIL:?missing}"
: "${INSTALL_DIR:=/var/www/pelican}"
: "${NGINX_CONF:=/etc/nginx/sites-available/pelican.conf}"
: "${SSL_MODE:=letsencrypt}"

# DB
: "${DB_ENGINE:=mariadb}"
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  ensure_mariadb
  : "${DB_NAME:=pelicanpanel}"; : "${DB_USER:=pelican}"; : "${DB_PASS:=}"
  if [[ -z "$DB_PASS" ]]; then DB_PASS="$(openssl rand -base64 18)"; fi
fi

# Admin
: "${ADMIN_USERNAME:=admin}"; : "${ADMIN_EMAILLOGIN:=admin@${DOMAIN}}"; : "${ADMIN_PASSWORD:=}"

APP_URL="https://${DOMAIN}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Fetch Panel source (prefer tarball to keep fast/light)
if [[ ! -f "composer.json" ]]; then
  say_info "Downloading Pelican Panel source…"
  # You can swap to an official archive when available
  git clone --depth=1 https://github.com/pelican-dev/panel.git . || {
    say_warn "git clone failed; fallback to composer create-project"
    composer create-project pelican-dev/panel . --no-interaction || true
  }
fi

# Permissions
chown -R www-data:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR" -type f -exec chmod 644 {} \;

# .env
if [[ ! -f ".env" ]]; then
  cp .env.example .env
fi

# Update .env
php_ver_sock="$(detect_phpfpm)"
PHP_SOCK="${php_ver_sock#*|}"
[[ -S "$PHP_SOCK" ]] || say_warn "PHP-FPM sock not detected; Nginx config will guess php8.4-fpm"

sed -i "s|^APP_URL=.*$|APP_URL=${APP_URL}|g" .env
sed -i "s|^APP_ENV=.*$|APP_ENV=production|g" .env
sed -i "s|^APP_DEBUG=.*$|APP_DEBUG=false|g" .env

if [[ "$DB_ENGINE" == "mariadb" ]]; then
  sed -i "s|^DB_CONNECTION=.*$|DB_CONNECTION=mysql|g" .env
  sed -i "s|^DB_HOST=.*$|DB_HOST=127.0.0.1|g" .env
  sed -i "s|^DB_PORT=.*$|DB_PORT=3306|g" .env
  sed -i "s|^DB_DATABASE=.*$|DB_DATABASE=${DB_NAME}|g" .env
  sed -i "s|^DB_USERNAME=.*$|DB_USERNAME=${DB_USER}|g" .env
  sed -i "s|^DB_PASSWORD=.*$|DB_PASSWORD=${DB_PASS}|g" .env

  # Create DB/user if not exists
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
else
  sed -i "s|^DB_CONNECTION=.*$|DB_CONNECTION=sqlite|g" .env
  mkdir -p database && touch database/database.sqlite
  chown -R www-data:www-data database
fi

# Redis
sed -i "s|^CACHE_DRIVER=.*$|CACHE_DRIVER=redis|g" .env
sed -i "s|^SESSION_DRIVER=.*$|SESSION_DRIVER=redis|g" .env
sed -i "s|^QUEUE_CONNECTION=.*$|QUEUE_CONNECTION=redis|g" .env
sed -i "s|^REDIS_HOST=.*$|REDIS_HOST=127.0.0.1|g" .env
sed -i "s|^REDIS_PORT=.*$|REDIS_PORT=6379|g" .env

# Composer install
composer install --no-interaction --prefer-dist --optimize-autoloader

# Key & migrate
php artisan key:generate --force
php artisan migrate --force
php artisan storage:link || true

# Create admin user
if [[ -z "$ADMIN_PASSWORD" ]]; then ADMIN_PASSWORD="$(openssl rand -base64 18)"; fi
php artisan p:user:make \
  --email="${ADMIN_EMAILLOGIN}" \
  --username="${ADMIN_USERNAME}" \
  --name-first="Admin" --name-last="User" \
  --password="${ADMIN_PASSWORD}"

# Queue worker (systemd) — ensure root writes
cat >/etc/systemd/system/pelican-queue.service <<'UNIT'
[Unit]
Description=Pelican Queue Worker
After=network.target

[Service]
User=www-data
WorkingDirectory=/var/www/pelican
ExecStart=/usr/bin/php artisan queue:work --queue=high,default,low --tries=3 --timeout=120
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now pelican-queue

# Nginx vhost
cat >"$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};

    root ${INSTALL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;

    include /etc/nginx/includes/cloudflare-real-ip.conf;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 30d;
        access_log off;
    }
}
NGX

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pelican.conf
nginx_add_cloudflare_realip
nginx -t && systemctl reload nginx

# SSL
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  ensure_pkg certbot; ensure_pkg python3-certbot-nginx
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL}" --no-eff-email || say_warn "Certbot failed."
  systemctl reload nginx || true
else
  CERT="/etc/ssl/certs/${DOMAIN}.crt"; KEY="/etc/ssl/private/${DOMAIN}.key"
  base64 -d <<<"${CERT_PEM_B64:?}" > "$CERT"
  umask 077; base64 -d <<<"${KEY_PEM_B64:?}" > "$KEY"; umask 022
  chmod 644 "$CERT"; chmod 600 "$KEY"
  say_ok "Saved custom SSL (Panel) → $CERT / $KEY"
  # Optional: you can add an SSL server block here if needed; LE already handled redirect above.
fi

# Cloudflare DNS (optional)
if [[ "${CF_ENABLE:-n}" == "y" ]]; then
  sanitize_cf_inputs
  if cf_preflight_warn; then
    cf_upsert_a_record "${CF_AUTH}" "${CF_ZONE_ID}" "${CF_DNS_NAME}" "${CF_RECORD_IP}" true || true
  fi
fi

# Summary
summary="${INSTALL_DIR}/pelican-install-summary.txt"
{
  echo "Panel URL: https://${DOMAIN}/"
  echo "Admin: ${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN} / ${ADMIN_PASSWORD}"
  if [[ "$DB_ENGINE" == "mariadb" ]]; then
    echo "DB: ${DB_NAME} / ${DB_USER} / ${DB_PASS}"
  else
    echo "DB: sqlite → ${INSTALL_DIR}/database/database.sqlite"
  fi
  echo "SSL mode: ${SSL_MODE}"
  echo "VHost: ${NGINX_CONF}"
} >"$summary"

say_ok "Panel installed."
echo "Summary → $summary"
