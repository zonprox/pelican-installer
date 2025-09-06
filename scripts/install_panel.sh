#!/usr/bin/env bash
# Pelican - Install Panel (smart, lightweight, self-healing)
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

# ---------- Helpers (local) ----------
run_as_www() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u www-data -- "$@"
  else
    sudo -u www-data "$@"
  fi
}

replace_env_kv() {
  # replace_env_kv <file> <KEY> <value>
  local file="$1" key="$2" val="$3" esc
  [[ -f "$file" ]] || touch "$file"
  esc="${val//\//\\/}"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*$|${key}=${esc}|" "$file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$file"
  fi
}

# ---------- Preconditions ----------
require_root
detect_os_or_die
install_base
enable_ufw
ensure_nginx
ensure_php_84
ensure_redis
composer_setup
ensure_php_exts intl pdo_sqlite mbstring xml curl zip gd bcmath mysql redis

# ---------- Inputs ----------
: "${DOMAIN:?missing DOMAIN}"
: "${ADMIN_EMAIL:?missing ADMIN_EMAIL}"
: "${INSTALL_DIR:=/var/www/pelican}"
: "${NGINX_CONF:=/etc/nginx/sites-available/pelican.conf}"
: "${SSL_MODE:=letsencrypt}"   # letsencrypt|custom

: "${DB_ENGINE:=mariadb}"      # mariadb|sqlite
: "${DB_NAME:=pelicanpanel}"
: "${DB_USER:=pelican}"
: "${DB_PASS:=}"

: "${ADMIN_USERNAME:=admin}"
: "${ADMIN_EMAILLOGIN:=admin@${DOMAIN}}"
: "${ADMIN_PASSWORD:=}"

APP_URL="https://${DOMAIN}"

say_info "Target Panel URL → ${APP_URL}"
say_info "Install directory → ${INSTALL_DIR}"

# ---------- Create directory & permissions ----------
mkdir -p "$INSTALL_DIR"
chown -R www-data:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \; || true
find "$INSTALL_DIR" -type f -exec chmod 644 {} \; || true

cd "$INSTALL_DIR"

# ---------- Fetch panel source ----------
if [[ ! -f "composer.json" ]]; then
  say_info "Fetching Pelican Panel source…"
  if command -v git >/dev/null 2>&1; then
    # Prefer shallow clone (fast)
    run_as_www git clone --depth=1 https://github.com/pelican-dev/panel.git "$INSTALL_DIR" || true
  fi
fi

# Fallback if git failed
if [[ ! -f "composer.json" ]]; then
  say_warn "composer.json not found; fallback to Composer create-project…"
  run_as_www /usr/local/bin/composer create-project pelican-dev/panel . --no-interaction || true
fi

[[ -f "composer.json" ]] || { say_err "Panel source missing (composer.json not found)."; exit 1; }

# ---------- .env ----------
if [[ ! -f ".env" ]]; then
  cp -f .env.example .env || touch .env
fi
chown www-data:www-data .env
chmod 640 .env

replace_env_kv .env "APP_URL" "${APP_URL}"
replace_env_kv .env "APP_ENV" "production"
replace_env_kv .env "APP_DEBUG" "false"
replace_env_kv .env "CACHE_DRIVER" "redis"
replace_env_kv .env "SESSION_DRIVER" "redis"
replace_env_kv .env "QUEUE_CONNECTION" "redis"
replace_env_kv .env "REDIS_HOST" "127.0.0.1"
replace_env_kv .env "REDIS_PORT" "6379"

# Database engine
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  ensure_mariadb
  if [[ -z "$DB_PASS" ]]; then DB_PASS="$(openssl rand -base64 18)"; fi
  replace_env_kv .env "DB_CONNECTION" "mysql"
  replace_env_kv .env "DB_HOST" "127.0.0.1"
  replace_env_kv .env "DB_PORT" "3306"
  replace_env_kv .env "DB_DATABASE" "${DB_NAME}"
  replace_env_kv .env "DB_USERNAME" "${DB_USER}"
  replace_env_kv .env "DB_PASSWORD" "${DB_PASS}"

  say_info "Ensuring MariaDB database & user…"
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
else
  replace_env_kv .env "DB_CONNECTION" "sqlite"
  mkdir -p database
  touch database/database.sqlite
  chown -R www-data:www-data database
  chmod 660 database/database.sqlite || true
fi

# ---------- Composer install ----------
say_info "Running composer install (as www-data)…"
set +e
run_as_www /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader
rc=$?
set -e
if (( rc != 0 )); then
  say_warn "Composer failed (exit $rc). Ensuring more PHP extensions & retrying…"
  ensure_php_exts intl pdo_sqlite mbstring xml curl zip gd bcmath mysql redis
  run_as_www /usr/local/bin/composer install --no-interaction --prefer-dist --optimize-autoloader
fi

# ---------- Laravel setup ----------
say_info "Generating app key…"
run_as_www /usr/bin/php artisan key:generate --force

say_info "Migrating database…"
if [[ "$DB_ENGINE" == "sqlite" ]]; then
  chmod 660 database/database.sqlite || true
  chown www-data:www-data database/database.sqlite
fi
run_as_www /usr/bin/php artisan migrate --force

say_info "Linking storage…"
run_as_www /usr/bin/php artisan storage:link || true

# ---------- Admin user ----------
if [[ -z "$ADMIN_PASSWORD" ]]; then ADMIN_PASSWORD="$(openssl rand -base64 18)"; fi
say_info "Creating admin user (${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN})…"
run_as_www /usr/bin/php artisan p:user:make \
  --email="${ADMIN_EMAILLOGIN}" \
  --username="${ADMIN_USERNAME}" \
  --name-first="Admin" --name-last="User" \
  --password="${ADMIN_PASSWORD}"

# ---------- Queue worker (systemd) ----------
say_info "Installing queue worker service…"
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

# ---------- Nginx vhost ----------
say_info "Writing Nginx vhost…"
phpfpm_pair="$(detect_phpfpm)"
php_sock="/run/php/php8.4-fpm.sock"
if [[ -n "$phpfpm_pair" ]]; then
  php_sock="${phpfpm_pair#*|}"
fi

mkdir -p "$(dirname "$NGINX_CONF")"

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
        fastcgi_pass unix:${php_sock};
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

# ---------- SSL ----------
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  say_info "Issuing Let's Encrypt certificate via certbot (nginx)…"
  ensure_pkg certbot; ensure_pkg python3-certbot-nginx
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL}" --no-eff-email || say_warn "Certbot failed."
  systemctl reload nginx || true
else
  say_info "Installing custom SSL certificate…"
  CERT="/etc/ssl/certs/${DOMAIN}.crt"
  KEY="/etc/ssl/private/${DOMAIN}.key"
  base64 -d <<<"${CERT_PEM_B64:?missing CERT_PEM_B64}" > "$CERT"
  umask 077; base64 -d <<<"${KEY_PEM_B64:?missing KEY_PEM_B64}" > "$KEY"; umask 022
  chmod 644 "$CERT"; chmod 600 "$KEY"

  # Add SSL server block (443) + redirect 80→443
  cat >"$NGINX_CONF" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};

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
        fastcgi_pass unix:${php_sock};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 30d;
        access_log off;
    }
}
NGX

  nginx -t && systemctl reload nginx
  say_ok "Custom SSL installed at $CERT / $KEY"
fi

# ---------- Cloudflare DNS (optional) ----------
if [[ "${CF_ENABLE:-n}" == "y" ]]; then
  say_info "Cloudflare DNS: preparing to upsert A record…"
  sanitize_cf_inputs
  if cf_preflight_warn; then
    cf_upsert_a_record "${CF_AUTH}" "${CF_ZONE_ID}" "${CF_DNS_NAME:-$DOMAIN}" "${CF_RECORD_IP:-$(detect_public_ip)}" true || true
  else
    say_warn "Skip Cloudflare DNS changes (preflight failed)."
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
