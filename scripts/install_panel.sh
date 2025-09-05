#!/usr/bin/env bash
set -euo pipefail

# ── Bootstrap common.sh even if run standalone ────────────────────────────────
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
if [[ ! -f "${COMMON_LOCAL}" ]]; then
  mkdir -p "${PEL_CACHE_DIR}"
  curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"
fi
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base
ensure_sury

# ── Read ENV from loader (NO prompts here) ────────────────────────────────────
: "${DOMAIN:?missing DOMAIN}"; : "${ADMIN_EMAIL:?missing ADMIN_EMAIL}"
: "${INSTALL_DIR:=/var/www/pelican}"
: "${NGINX_CONF:=/etc/nginx/sites-available/pelican.conf}"
: "${DB_ENGINE:=mariadb}"                # mariadb|sqlite
: "${SETUP_SMTP:=n}"                     # y|n
: "${SSL_MODE:=letsencrypt}"             # letsencrypt|custom
: "${CF_ENABLE:=n}"                      # y|n
: "${CF_AUTH:=token}"                    # token|global

# Optional ENV
: "${DB_NAME:=pelicanpanel}"; : "${DB_USER:=pelican}"; : "${DB_PASS:=}"
: "${ADMIN_USERNAME:=admin}"; : "${ADMIN_EMAILLOGIN:=admin@${DOMAIN}}"; : "${ADMIN_PASSWORD:=}"
: "${CERT_PEM_B64:=}"; : "${KEY_PEM_B64:=}"
: "${CF_API_TOKEN:=}"; : "${CF_API_EMAIL:=}"; : "${CF_GLOBAL_API_KEY:=}"
: "${CF_ZONE_ID:=}"; : "${CF_DNS_NAME:=${DOMAIN}}"; : "${CF_RECORD_IP:=}"
: "${SMTP_FROM_NAME:=Pelican Panel}"; : "${SMTP_FROM_EMAIL:=noreply@${DOMAIN}}"
: "${SMTP_HOST:=}"; : "${SMTP_PORT:=587}"; : "${SMTP_USER:=}"; : "${SMTP_PASS:=}"; : "${SMTP_ENC:=tls}"

# Auto-generate passwords if blank
[[ -z "$DB_PASS" ]] && DB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
[[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

say_info "Installing Nginx, PHP 8.4, Redis…"
apt-get install -y nginx \
  php8.4 php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql php8.4-mbstring php8.4-bcmath \
  php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-sqlite3 \
  redis-server
systemctl enable --now redis-server
enable_ufw

if [[ "$DB_ENGINE" == "mariadb" ]]; then
  apt-get install -y mariadb-server mariadb-client
fi

# ── Composer + download Panel ─────────────────────────────────────────────────
composer_setup
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [[ ! -f artisan ]]; then
  curl -fL https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
fi
COMPOSER_ROOT_VERSION=dev-main COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --prefer-dist

# ── Database bootstrap ────────────────────────────────────────────────────────
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  DB_PASS_SQL="$(mysql_escape_squote "$DB_PASS")"
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
else
  mkdir -p "${INSTALL_DIR}/database"
  : > "${INSTALL_DIR}/database/database.sqlite"
fi

# ── Permissions (baseline) ────────────────────────────────────────────────────
chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" || true

# ── Nginx vhost (single :80; add :443 if custom SSL) ─────────────────────────
rm -f /etc/nginx/sites-enabled/default || true
mkdir -p "$(dirname "$NGINX_CONF")"

# Remove other vhosts that claim the same domain on :80 to avoid conflicts
for f in /etc/nginx/sites-enabled/*; do
  [[ -L "$f" ]] || continue
  if grep -qE "^\s*server_name\s+.*\b${DOMAIN}\b" "$f" 2>/dev/null; then
    [[ "$(readlink -f "$f")" != "$NGINX_CONF" ]] && rm -f "$f"
  fi
done

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
  [[ -n "$CERT_PEM_B64" ]] && base64 -d <<<"$CERT_PEM_B64" > "$CUSTOM_CERT" && chmod 644 "$CUSTOM_CERT"
  if [[ -n "$KEY_PEM_B64" ]]; then umask 077; base64 -d <<<"$KEY_PEM_B64" > "$CUSTOM_KEY"; umask 022; chmod 600 "$CUSTOM_KEY"; fi

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
systemctl restart "php${PHP_VERSION}-fpm" || true

# ── Let's Encrypt if chosen ───────────────────────────────────────────────────
if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL}" --no-eff-email || say_warn "Certbot failed — check DNS/Cloudflare."
  systemctl reload nginx || true
fi

# ── .env (safe writes), APP_KEY — run as www-data ─────────────────────────────
cp -n .env.example .env || true

# Core app config
set_kv .env APP_ENV production
set_kv .env APP_DEBUG false
set_kv .env APP_URL "https://${DOMAIN}"

# DB config
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  set_kv .env DB_CONNECTION mysql
  set_kv .env DB_HOST 127.0.0.1
  set_kv .env DB_PORT 3306
  set_kv .env DB_DATABASE "${DB_NAME}"
  set_kv .env DB_USERNAME "${DB_USER}"
  set_kv .env DB_PASSWORD "${DB_PASS}"
else
  set_kv .env DB_CONNECTION sqlite
  set_kv .env DB_DATABASE "${INSTALL_DIR}/database/database.sqlite"
fi

# Redis-first (fill all keys to avoid any wizard)
set_kv .env REDIS_HOST 127.0.0.1
set_kv .env REDIS_PORT 6379
set_kv .env REDIS_PASSWORD null
set_kv .env REDIS_USERNAME null
set_kv .env CACHE_DRIVER redis
set_kv .env SESSION_DRIVER redis
set_kv .env QUEUE_CONNECTION redis

# Mail (optional)
if [[ "${SETUP_SMTP}" == "y" ]]; then
  set_kv .env MAIL_MAILER smtp
  set_kv .env MAIL_HOST "${SMTP_HOST}"
  set_kv .env MAIL_PORT "${SMTP_PORT}"
  set_kv .env MAIL_USERNAME "${SMTP_USER}"
  set_kv .env MAIL_PASSWORD "${SMTP_PASS}"
  set_kv .env MAIL_ENCRYPTION "${SMTP_ENC}"
  set_kv .env MAIL_FROM_ADDRESS "${SMTP_FROM_EMAIL}"
  set_kv .env MAIL_FROM_NAME "${SMTP_FROM_NAME}"
fi

# ensure ownership BEFORE artisan touches .env
chown www-data:www-data .env
chmod 640 .env

# generate APP_KEY if missing
if ! grep -q '^APP_KEY=base64:' .env; then
  run_as_www php artisan key:generate --force
fi

# ── Migrate & seed admin (no interactive env commands) ────────────────────────
run_as_www php artisan migrate --force
run_as_www php artisan p:user:make \
  --email="${ADMIN_EMAILLOGIN}" --username="${ADMIN_USERNAME}" \
  --password="${ADMIN_PASSWORD}" --admin=1 -n || true

# storage link & optimize
run_as_www php artisan storage:link || true
run_as_www php artisan optimize:clear && run_as_www php artisan optimize || true

# Final permission sweep
chown -R www-data:www-data "${INSTALL_DIR}"
chmod -R 755 "${INSTALL_DIR}/storage" "${INSTALL_DIR}/bootstrap/cache" || true

# ── Queue worker (root writes unit; no permission issues) ─────────────────────
cat >/etc/systemd/system/pelican-queue.service <<UNIT
[Unit]
Description=Pelican Panel Queue Worker
After=network.target
[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/php artisan queue:work --queue=default --sleep=3 --tries=3 --max-time=3600
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now pelican-queue.service

# ── Cloudflare (optional) ─────────────────────────────────────────────────────
if [[ "${CF_ENABLE}" == "y" && -n "${CF_ZONE_ID}" && -n "${CF_DNS_NAME}" ]]; then
  IP_TO_SET="${CF_RECORD_IP:-$(detect_public_ip)}"
  cf_upsert_a_record "$CF_API_TOKEN" "$CF_ZONE_ID" "$CF_DNS_NAME" "$IP_TO_SET" true || say_warn "Cloudflare: DNS change skipped."
  nginx_add_cloudflare_realip
  if ! grep -q 'cloudflare-real-ip.conf' "$NGINX_CONF"; then
    sed -i '1a include /etc/nginx/includes/cloudflare-real-ip.conf;' "$NGINX_CONF"
    nginx -t && systemctl reload nginx || true
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY="${INSTALL_DIR}/pelican-install-summary.txt"
cat >"$SUMMARY" <<EOF
Pelican Panel — Installation Summary
Timestamp (UTC): ${TS}

Domain & URLs
- Domain:     ${DOMAIN}
- URL:        https://${DOMAIN}/

Paths
- Install:    ${INSTALL_DIR}
- Nginx vhost:${NGINX_CONF}
- .env:       ${INSTALL_DIR}/.env
- PHP-FPM:    ${PHP_SOCK}
- Queue unit: /etc/systemd/system/pelican-queue.service
- Summary:    ${SUMMARY}

Services
- UFW:        enabled (22,80,443)
- Redis:      $(systemctl is-active redis-server || true)
- Nginx:      $(systemctl is-active nginx || true)
- PHP-FPM:    $(systemctl is-active php${PHP_VERSION}-fpm || true)

Database
- Engine:     ${DB_ENGINE}
$( if [[ "$DB_ENGINE" == "mariadb" ]]; then
     echo "- Name/User:  ${DB_NAME} / ${DB_USER}"
     echo "- Password:   ${DB_PASS}"
   else
     echo "- SQLite:     ${INSTALL_DIR}/database/database.sqlite"
   fi )

Admin
- Username:   ${ADMIN_USERNAME}
- Email:      ${ADMIN_EMAILLOGIN}
- Password:   ${ADMIN_PASSWORD}

SSL
- Mode:       ${SSL_MODE}
$( if [[ "$SSL_MODE" == "custom" ]]; then
     echo "- Cert:       ${CUSTOM_CERT}"
     echo "- Key:        ${CUSTOM_KEY}"
   else
     echo "- Provider:   Let's Encrypt (certbot)"
   fi )

Cloudflare
- Enabled:    ${CF_ENABLE}
$( [[ "$CF_ENABLE" == "y" ]] && echo "- DNS:       ${CF_DNS_NAME} → ${IP_TO_SET:-<auto>}" )

EOF

say_ok "Panel installed. Summary → $SUMMARY"
