#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os

log "Pelican Panel – configuration"

prompt_input DOMAIN "Panel domain (e.g. panel.example.com)"
prompt_input ADMIN_EMAIL "Admin email (Let's Encrypt/contact)" "admin@${DOMAIN}"

read -rp "Database engine: MariaDB or SQLite? (M/s) [M]: " DB_CHOICE || true; DB_CHOICE="${DB_CHOICE:-M}"
if [[ "$DB_CHOICE" =~ ^[Ss]$ ]]; then
  DB_ENGINE="sqlite"
else
  DB_ENGINE="mariadb"
  prompt_input DB_NAME "DB name" "pelicanpanel"
  prompt_input DB_USER "DB user" "pelican"
  read -rp "DB password (blank = auto-generate): " DB_PASS_IN || true
  DB_PASS="$(gen_password "$DB_PASS_IN")"
fi

prompt_input ADMIN_USERNAME   "Admin username" "admin"
prompt_input ADMIN_EMAILLOGIN "Admin login email" "admin@${DOMAIN}"
read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD_IN || true
ADMIN_PASSWORD="$(gen_password "$ADMIN_PASSWORD_IN")"

read -rp "Configure SMTP now? (y/N): " _smtp || true; _smtp="${_smtp:-N}"
if [[ "$_smtp" =~ ^[Yy]$ ]]; then
  SETUP_SMTP="y"
  prompt_input SMTP_FROM_NAME  "From name"  "Pelican Panel"
  prompt_input SMTP_FROM_EMAIL "From email" "noreply@${DOMAIN}"
  prompt_input SMTP_HOST       "SMTP host"
  prompt_input SMTP_PORT       "SMTP port" "587"
  prompt_input SMTP_USER       "SMTP username"
  prompt_input SMTP_PASS       "SMTP password"
  prompt_input SMTP_ENC        "Encryption (tls/ssl/none)" "tls"
else SETUP_SMTP="n"; fi

prompt_choice SSL_MODE "SSL mode (letsencrypt/custom)" "letsencrypt"
CERT_PEM=""; KEY_PEM=""
if [[ "$SSL_MODE" == "custom" ]]; then
  echo; echo "Paste FULLCHAIN/CRT (include BEGIN/END), then Ctrl+D:"
  CERT_TMP="$(mktemp)"; cat > "$CERT_TMP"; CERT_PEM="$(cat "$CERT_TMP")"; rm -f "$CERT_TMP"
  echo; echo "Paste PRIVATE KEY (PEM) (include BEGIN/END), then Ctrl+D:"
  KEY_TMP="$(mktemp)"; umask 077; cat > "$KEY_TMP"; umask 022; KEY_PEM="$(cat "$KEY_TMP")"; rm -f "$KEY_TMP"
fi

read -rp "Enable Cloudflare Proxy & DNS via API? (y/N): " _cf || true; _cf="${_cf:-N}"
if [[ "$_cf" =~ ^[Yy]$ ]]; then
  CF_ENABLE="y"
  prompt_input CF_API_TOKEN "Cloudflare API Token (Zone DNS Edit)"
  prompt_input CF_ZONE_ID   "Cloudflare Zone ID"
  prompt_input CF_DNS_NAME  "DNS record name" "${DOMAIN}"
  DEFAULT_IP="$(get_public_ip)"; prompt_input CF_RECORD_IP "Public IP" "${DEFAULT_IP}"
else CF_ENABLE="n"; fi

prompt_input INSTALL_DIR "Install directory" "/var/www/pelican"
prompt_input NGINX_CONF  "Nginx vhost path"  "/etc/nginx/sites-available/pelican.conf"

# Review
echo; echo "================== REVIEW =================="
echo "Domain:            $DOMAIN"
echo "Admin contact:     $ADMIN_EMAIL"
echo "Install dir:       $INSTALL_DIR"
echo "Nginx vhost:       $NGINX_CONF"
echo "DB engine:         $DB_ENGINE"
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  echo "  - DB name:       $DB_NAME"
  echo "  - DB user:       $DB_USER"
  echo "  - DB pass:       $(mask "$DB_PASS")"
else
  echo "  - SQLite file:   $INSTALL_DIR/database/database.sqlite"
fi
echo "Admin user:        $ADMIN_USERNAME / $ADMIN_EMAILLOGIN / $(mask "$ADMIN_PASSWORD")"
echo "SMTP config:       $([[ "$SETUP_SMTP" == "y" ]] && echo "Yes" || echo "No")"
echo "SSL mode:          $SSL_MODE"
[[ "$SSL_MODE" == "custom" ]] && echo "  - CERT/KEY pasted"
echo "Cloudflare:        $([[ "$CF_ENABLE" == "y" ]] && echo "Enabled" || echo "Disabled")"
[[ "$CF_ENABLE" == "y" ]] && { echo "  - DNS: $CF_DNS_NAME"; echo "  - IP:  $CF_RECORD_IP"; }
echo "============================================"
read -rp "Proceed? (Y/n): " CONFIRM || true; CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ==== Install ====
install_prereqs
log "Installing Nginx, PHP 8.4, Redis, Certbot…"
apt-get install -y nginx \
  php8.4 php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql php8.4-mbstring php8.4-bcmath \
  php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-sqlite3 \
  redis-server certbot python3-certbot-nginx
systemctl enable --now redis-server
[[ "$DB_ENGINE" == "mariadb" ]] && apt-get install -y mariadb-server mariadb-client
ensure_composer
enable_ufw_web

# Fetch panel
mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
if [[ ! -f artisan ]]; then
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
fi
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# DB bootstrap
if [[ "$DB_ENGINE" == "mariadb" ]]; then
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
else
  mkdir -p "${INSTALL_DIR}/database"; touch "${INSTALL_DIR}/database/database.sqlite"
fi

chown -R www-data:www-data "$INSTALL_DIR"; chmod -R 755 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" || true

# Nginx
rm -f /etc/nginx/sites-enabled/default || true
PHP_DET="$(detect_php_fpm_socket || true)"; PHP_VERSION="${PHP_DET%%|*}"; PHP_SOCK="${PHP_DET##*|}"
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
    client_max_body_size 100m; client_body_timeout 120s; sendfile off;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php; include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY ""; fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k; fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300; fastcgi_send_timeout 300; fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
    location ~ /\.ht { deny all; }
}
NG80

CUSTOM_CERT_PATH="/etc/ssl/certs/${DOMAIN}.crt"
CUSTOM_KEY_PATH="/etc/ssl/private/${DOMAIN}.key"
if [[ "$SSL_MODE" == "custom" ]]; then
  mkdir -p /etc/ssl/certs /etc/ssl/private
  echo "$CERT_PEM" > "$CUSTOM_CERT_PATH"
  umask 077; echo "$KEY_PEM" > "$CUSTOM_KEY_PATH"; umask 022
  chown root:root "$CUSTOM_CERT_PATH" "$CUSTOM_KEY_PATH"
  chmod 644 "$CUSTOM_CERT_PATH"; chmod 600 "$CUSTOM_KEY_PATH"
  cat >> "$NGINX_CONF" <<NG443

server { listen 80; server_name ${DOMAIN}; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name ${DOMAIN};
    ssl_certificate ${CUSTOM_CERT_PATH}; ssl_certificate_key ${CUSTOM_KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m;
    root ${INSTALL_DIR}/public; index index.php;
    access_log /var/log/nginx/pelican.access.log; error_log /var/log/nginx/pelican.error.log error;
    client_max_body_size 100m; client_body_timeout 120s; sendfile off;
    add_header X-Content-Type-Options nosniff; add_header X-Frame-Options DENY; add_header Referrer-Policy same-origin;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ { fastcgi_split_path_info ^(.+\.php)(/.+)\$; fastcgi_pass unix:${PHP_SOCK};
      fastcgi_index index.php; include fastcgi_params;
      fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
      fastcgi_param HTTP_PROXY ""; fastcgi_intercept_errors off;
      fastcgi_buffer_size 16k; fastcgi_buffers 4 16k;
      fastcgi_connect_timeout 300; fastcgi_send_timeout 300; fastcgi_read_timeout 300;
      include /etc/nginx/fastcgi_params; }
    location ~ /\.ht { deny all; }
}
NG443
fi

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$(basename "$NGINX_CONF")"
nginx -t && systemctl restart nginx

if [[ "$SSL_MODE" == "letsencrypt" ]]; then
  if ! certbot certificates | grep -q "Domains: ${DOMAIN}"; then
    certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${ADMIN_EMAIL}" --no-eff-email || warn "Certbot failed; check DNS/Cloudflare."
  fi
  systemctl reload nginx || true
fi

# .env + Redis-first
cd "$INSTALL_DIR"
[[ -f .env ]] || cp .env.example .env || true
grep -q '^APP_NAME=' .env || echo "APP_NAME=PelicanPanel" >> .env
grep -q '^APP_URL='  .env && sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env || echo "APP_URL=https://${DOMAIN}" >> .env

if [[ "$DB_ENGINE" == "mariadb" ]]; then
  sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/g" .env
  sed -i "s/^DB_HOST=.*/DB_HOST=127.0.0.1/g" .env
  sed -i "s/^DB_PORT=.*/DB_PORT=3306/g" .env
  sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/g" .env
  sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/g" .env
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/g" .env
else
  sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/g" .env
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${INSTALL_DIR}/database/database.sqlite|g" .env || true
fi

if grep -q '^REDIS_HOST=' .env; then sed -i "s/^REDIS_HOST=.*/REDIS_HOST=127.0.0.1/g" .env
else cat >> .env <<EOF
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=null
EOF
fi
for k in CACHE_DRIVER SESSION_DRIVER QUEUE_CONNECTION; do
  grep -q "^${k}=" .env || echo "${k}=redis" >> .env
  sed -i "s/^${k}=.*/${k}=redis/g" .env
done

grep -q '^APP_KEY=base64:' .env || sudo -u www-data php artisan key:generate --force

php artisan p:environment:setup -n || true
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  php artisan p:environment:database --driver=mysql --database="${DB_NAME}" --host=127.0.0.1 --port=3306 --username="${DB_USER}" --password="${DB_PASS}" -n || true
else
  php artisan p:environment:database --driver=sqlite --database="${INSTALL_DIR}/database/database.sqlite" -n || true
fi
php artisan p:redis:setup --redis-host=127.0.0.1 --redis-port=6379 -n || true
php artisan p:environment:{queue,session,cache} --driver=redis --redis-host=127.0.0.1 --redis-port=6379 -n || true

if [[ "$SETUP_SMTP" == "y" ]]; then
  php artisan p:environment:mail --driver=smtp --email="${SMTP_FROM_EMAIL}" --from="${SMTP_FROM_NAME}" \
    --encryption="${SMTP_ENC}" --host="${SMTP_HOST}" --port="${SMTP_PORT}" --username="${SMTP_USER}" --password="${SMTP_PASS}" -n || true
fi

php artisan migrate --force
php artisan p:user:make --email="${ADMIN_EMAILLOGIN}" --username="${ADMIN_USERNAME}" --password="${ADMIN_PASSWORD}" --admin=1 -n || true

chown -R www-data:www-data "$INSTALL_DIR"; chmod -R 755 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" || true

# Queue worker
cat >/etc/systemd/system/pelican-queue.service <<'UNIT'
[Unit] Description=Pelican Panel Queue Worker After=network.target
[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
WorkingDirectory=/var/www/pelican
ExecStart=/usr/bin/php artisan queue:work --queue=default --sleep=3 --tries=3 --max-time=3600
[Install] WantedBy=multi-user.target
UNIT
sed -i "s|WorkingDirectory=/var/www/pelican|WorkingDirectory=${INSTALL_DIR}|g" /etc/systemd/system/pelican-queue.service
systemctl daemon-reload; systemctl enable --now pelican-queue.service

# Cloudflare DNS + Real IP
if [[ "${CF_ENABLE:-n}" == "y" ]]; then
  log "Cloudflare: upserting proxied A record…"
  CF_NAME="${CF_DNS_NAME}"; CF_TYPE="A"; CF_TTL=120; CF_PROXIED=true
  REC_ID=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=${CF_TYPE}&name=${CF_NAME}" \
           -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty' || true)
  if [[ -n "${REC_ID}" ]]; then
    curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "{\"type\":\"${CF_TYPE}\",\"name\":\"${CF_NAME}\",\"content\":\"${CF_RECORD_IP}\",\"ttl\":${CF_TTL},\"proxied\":${CF_PROXIED}}" >/dev/null
  else
    curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "{\"type\":\"${CF_TYPE}\",\"name\":\"${CF_NAME}\",\"content\":\"${CF_RECORD_IP}\",\"ttl\":${CF_TTL},\"proxied\":${CF_PROXIED}}" >/dev/null
  fi
  CF_INC="$(write_cloudflare_realip)"
  if ! grep -q 'cloudflare-real-ip.conf' "$NGINX_CONF"; then sed -i "1a include ${CF_INC};" "$NGINX_CONF"; fi
  nginx -t && systemctl reload nginx || true
fi

# Summary
NGINX_STATUS="$(systemctl is-active nginx || true)"
PHPFPM_STATUS="$(systemctl is-active php${PHP_VERSION}-fpm || true)"
DB_STATUS=$( [[ "$DB_ENGINE" == "mariadb" ]] && systemctl is-active mariadb || echo "sqlite" )
REDIS_STATUS="$(systemctl is-active redis-server || true)"
QUEUE_STATUS="$(systemctl is-active pelican-queue || true)"
SUMMARY_FILE="${INSTALL_DIR%/}/pelican-install-summary.txt"
cat > "$SUMMARY_FILE" <<EOF
Pelican Panel – Installation Summary
Domain: ${DOMAIN}
URL:    https://${DOMAIN}/
Admin:  ${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN} / ${ADMIN_PASSWORD}
DB:     ${DB_ENGINE} $( [[ "$DB_ENGINE" == "mariadb" ]] && echo "(${DB_NAME} @ 127.0.0.1:3306 user=${DB_USER})" )
SSL:    ${SSL_MODE}
Services: nginx=${NGINX_STATUS}, php-fpm=${PHPFPM_STATUS}, db=${DB_STATUS}, redis=${REDIS_STATUS}, queue=${QUEUE_STATUS}
EOF

echo -e "${GREEN}Done. Summary saved:${NC} ${SUMMARY_FILE}"
echo -e "Open: ${CYAN}https://${DOMAIN}/${NC}"
