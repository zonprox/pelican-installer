#!/usr/bin/env bash
# Pelican - Install Panel (doc-aligned, smart, self-healing)
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

# ---------- Helpers ----------
run_as_www(){ command -v runuser >/dev/null 2>&1 && runuser -u www-data -- "$@" || sudo -u www-data "$@"; }

# ---------- Preconditions & cleanup ----------
require_root
detect_os_or_die
install_base
enable_ufw
ensure_nginx
ensure_php_84
ensure_redis
composer_setup
ensure_php_exts intl pdo_sqlite mbstring xml curl zip gd bcmath mysql redis

# Remove previous queue unit to avoid leftovers
if systemctl list-unit-files | grep -q '^pelican-queue.service'; then
  systemctl disable --now pelican-queue 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-queue.service
  systemctl daemon-reload || true
fi

# ---------- Inputs (exported by installer wizard) ----------
: "${DOMAIN:?missing DOMAIN}"
: "${INSTALL_DIR:=/var/www/pelican}"
: "${NGINX_CONF:=/etc/nginx/sites-available/pelican.conf}"

# SSL
: "${SSL_MODE:=letsencrypt}"            # letsencrypt|custom
: "${ADMIN_EMAIL:=}"                    # asked only if letsencrypt in wizard
: "${CERT_PEM_B64:=}"; : "${KEY_PEM_B64:=}"

# DB
: "${DB_ENGINE:=mariadb}"               # mariadb|sqlite
: "${DB_NAME:=pelicanpanel}"
: "${DB_USER:=pelican}"
: "${DB_PASS:=}"

# Admin user
: "${ADMIN_USERNAME:=admin}"
: "${ADMIN_EMAILLOGIN:=admin@${DOMAIN}}"
: "${ADMIN_PASSWORD:=}"

APP_URL="https://${DOMAIN}"
say_info "Panel URL  : ${APP_URL}"
say_info "Install dir: ${INSTALL_DIR}"

# ---------- Create dir & sanitize any previous attempt ----------
mkdir -p "$INSTALL_DIR"
# remove stale laravel caches from previous runs
rm -f "$INSTALL_DIR"/bootstrap/cache/config.php "$INSTALL_DIR"/bootstrap/cache/routes*.php 2>/dev/null || true
chown -R www-data:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \; || true
find "$INSTALL_DIR" -type f -exec chmod 644 {} \; || true

cd "$INSTALL_DIR"

# ---------- Fetch panel source ----------
if [[ ! -f composer.json ]]; then
  say_info "Cloning Pelican Panel repository…"
  if command -v git >/dev/null 2>&1; then
    run_as_www git clone --depth=1 https://github.com/pelican-dev/panel.git "$INSTALL_DIR" || true
  fi
fi
if [[ ! -f composer.json ]]; then
  say_warn "composer.json not found; falling back to Composer create-project…"
  run_as_www /usr/local/bin/composer create-project pelican-dev/panel . --no-interaction || true
fi
[[ -f composer.json ]] || { say_err "Panel source missing (composer.json not found)."; exit 1; }

# ---------- Composer install ----------
say_info "Installing PHP dependencies (Composer)…"
set +e
run_as_www /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader
rc=$?; set -e
if (( rc != 0 )); then
  say_warn "Composer failed (exit $rc). Ensuring extensions & retrying…"
  ensure_php_exts intl pdo_sqlite mbstring xml curl zip gd bcmath mysql redis
  run_as_www /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader
fi

# ---------- Environment setup (use Artisan editors per docs) ----------
# Create .env & APP_KEY if missing
if [[ ! -f .env ]]; then
  say_info "Running p:environment:setup (create .env + APP_KEY)…"
  run_as_www /usr/bin/php artisan p:environment:setup --no-interaction  # creates .env & key if absent
else
  # ensure we have an app key
  run_as_www /usr/bin/php artisan key:generate --force
fi

# Force APP_URL to domain (keeps .env tidy)
if grep -q '^APP_URL=' .env; then
  sed -i "s|^APP_URL=.*$|APP_URL=${APP_URL}|" .env
else
  echo "APP_URL=${APP_URL}" >> .env
fi

# Database config
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  ensure_mariadb
  [[ -n "$DB_PASS" ]] || DB_PASS="$(openssl rand -base64 18)"
  say_info "Configuring DB via p:environment:database…"
  run_as_www /usr/bin/php artisan p:environment:database \
    --driver=mysql --database="${DB_NAME}" --host=127.0.0.1 --port=3306 \
    --username="${DB_USER}" --password="${DB_PASS}" --no-interaction

  say_info "Ensuring MariaDB database & users (127.0.0.1 + localhost)…"
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'   IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost'   IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
else
  # SQLite: set connection and create file
  sed -i '/^DB_CONNECTION=/d;/^DB_HOST=/d;/^DB_PORT=/d;/^DB_DATABASE=/d;/^DB_USERNAME=/d;/^DB_PASSWORD=/d' .env
  echo "DB_CONNECTION=sqlite" >> .env
  mkdir -p database
  touch database/database.sqlite
  chown -R www-data:www-data database
  chmod 660 database/database.sqlite || true
fi

# Redis-first for cache/session/queue
say_info "Configuring Redis (cache/session/queue) via p:redis:setup…"
run_as_www /usr/bin/php artisan p:redis:setup \
  --redis-host=127.0.0.1 --redis-port=6379 --no-interaction

# ---------- Permissions (as docs) ----------
# Make sure storage & cache are writable by webserver.
chown -R www-data:www-data storage bootstrap/cache
chmod -R 755 storage/* bootstrap/cache/ || true  # per docs
# Clear any stale caches prior to migrate
run_as_www /usr/bin/php artisan config:clear || true
run_as_www /usr/bin/php artisan cache:clear || true
run_as_www /usr/bin/php artisan optimize:clear || true

# ---------- Migrate & storage link ----------
say_info "Migrating database…"
run_as_www /usr/bin/php artisan migrate --force
say_info "Linking storage…"
run_as_www /usr/bin/php artisan storage:link || true

# ---------- Admin user ----------
[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(openssl rand -base64 18)"
say_info "Creating admin user (${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN})…"
run_as_www /usr/bin/php artisan p:user:make \
  --email="${ADMIN_EMAILLOGIN}" \
  --username="${ADMIN_USERNAME}" \
  --password="${ADMIN_PASSWORD}" \
  --admin=1 \
  --no-interaction

# ---------- Queue worker (use official artisan service generator) ----------
say_info "Installing queue worker service via p:environment:queue-service…"
run_as_www /usr/bin/php artisan p:environment:queue-service \
  --service-name=pelican-queue --user=www-data --group=www-data --overwrite --no-interaction
systemctl daemon-reload
systemctl enable --now pelican-queue

# ---------- Nginx (align with docs) ----------
say_info "Writing Nginx vhost (doc-aligned)…"
phpfpm_pair="$(detect_phpfpm)"; php_sock="/run/php/php8.4-fpm.sock"
[[ -n "$phpfpm_pair" ]] && php_sock="${phpfpm_pair#*|}"

mkdir -p "$(dirname "$NGINX_CONF")"
# remove default site (avoids conflicts)
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Plain HTTP first; SSL section will be appended/replaced below
cat >"$NGINX_CONF" <<NGX
server_tokens off;

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root ${INSTALL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    # allow larger uploads & longer runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    # SSL certs – will be updated below depending on mode
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${php_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;

        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGX

# Apply SSL mode
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  say_info "Issuing Let's Encrypt certificate via certbot…"
  ensure_pkg certbot; ensure_pkg python3-certbot-nginx
  # certbot will edit the nginx conf automatically; but our conf is already https-ready
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL:-admin@${DOMAIN#*.}}" --no-eff-email || say_warn "Certbot failed."
else
  say_info "Installing custom SSL material…"
  CERT="/etc/ssl/certs/${DOMAIN}.crt"
  KEY="/etc/ssl/private/${DOMAIN}.key"
  base64 -d <<<"${CERT_PEM_B64}" > "$CERT"
  umask 077; base64 -d <<<"${KEY_PEM_B64}" > "$KEY"; umask 022
  chmod 644 "$CERT"; chmod 600 "$KEY"
  # replace the ssl_certificate lines for custom certs
  sed -i "s|ssl_certificate[[:space:]].*|ssl_certificate ${CERT};|" "$NGINX_CONF"
  sed -i "s|ssl_certificate_key[[:space:]].*|ssl_certificate_key ${KEY};|" "$NGINX_CONF"
fi

nginx -t && systemctl reload nginx

# ---------- Optional Cloudflare DNS (handled by installer wrapper) ----------
if [[ "${CF_ENABLE:-n}" == "y" ]]; then
  say_info "Cloudflare DNS: upsert A record…"
  sanitize_cf_inputs
  if cf_preflight_warn; then
    cf_upsert_a_record "${CF_AUTH}" "${CF_ZONE_ID}" "${CF_DNS_NAME:-$DOMAIN}" "${CF_RECORD_IP:-$(detect_public_ip)}" true || true
  else
    say_warn "Skip Cloudflare DNS (preflight failed)."
  fi
fi

# ---------- Postflight quick-check ----------
LOG_TODAY="${INSTALL_DIR}/storage/logs/laravel-$(date +%F).log"
if [[ -s "$LOG_TODAY" ]]; then
  if grep -qiE 'exception|stack|error' "$LOG_TODAY" ; then
    say_warn "Laravel log shows errors today. Inspect the last lines:"
    tail -n 50 "$LOG_TODAY" || true
    say_warn "See docs Troubleshooting for guidance."
  fi
fi

# ---------- Summary ----------
summary="${INSTALL_DIR}/pelican-install-summary.txt"
{
  echo "Panel URL: https://${DOMAIN}/"
  echo "Admin Username : ${ADMIN_USERNAME}"
  echo "Admin Email    : ${ADMIN_EMAILLOGIN}"
  echo "Admin Password : ${ADMIN_PASSWORD}"
  if [[ "$DB_ENGINE" == "mariadb" ]]; then
    echo "DB Engine: MariaDB"
    echo "DB Name  : ${DB_NAME}"
    echo "DB User  : ${DB_USER}"
    echo "DB Pass  : ${DB_PASS}"
  else
    echo "DB Engine: SQLite (${INSTALL_DIR}/database/database.sqlite)"
  fi
  echo "SSL Mode : ${SSL_MODE}"
  echo "Nginx    : ${NGINX_CONF}"
  echo "Queue    : systemd unit → pelican-queue.service"
} >"$summary"
chmod 640 "$summary" || true

say_ok "Panel installed successfully."
echo "Summary → ${summary}"
echo
echo "If you still see '500', check logs:"
echo "  tail -n 1000 ${INSTALL_DIR}/storage/logs/laravel-\$(date +%F).log | grep \"[\$(date +%Y)]\""
