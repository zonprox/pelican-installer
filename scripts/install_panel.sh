#!/usr/bin/env bash
set -euo pipefail

# Bootstrap common helpers (works standalone too)
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON="${PEL_CACHE_DIR}/common.sh"
[[ -f "$COMMON" ]] || { mkdir -p "$PEL_CACHE_DIR"; curl -fsSL -o "${COMMON}" "${PEL_RAW_BASE}/common.sh"; }
# shellcheck source=/dev/null
. "${COMMON}"

require_root
detect_os_or_die
install_base
ensure_sury

say_info "Pelican Panel — guided install"

# ── Inputs
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
  DB_PASS="$(genpass "${DB_PASS_IN:-}")"
fi

prompt ADMIN_USERNAME   "Admin username" "admin"
prompt ADMIN_EMAILLOGIN "Admin login email" "admin@${DOMAIN}"
read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD_IN || true
ADMIN_PASSWORD="$(genpass "${ADMIN_PASSWORD_IN:-}")"

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

choice SSL_MODE "SSL mode (letsencrypt/custom/none)" "letsencrypt"
CERT_PEM=""; KEY_PEM=""
if [[ "$SSL_MODE" == "custom" ]]; then
  echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"; CERT_PEM="$(cat)"
  echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"; umask 077; KEY_PEM="$(cat)"; umask 022
fi

read -rp "Use Cloudflare API for proxied A record & Real-IP? (y/N): " _cf || true; _cf="${_cf:-N}"
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

# ── Review
echo
echo "──── Configuration Review ────"
echo "Domain:            $DOMAIN"
echo "Admin contact:     $ADMIN_EMAIL"
echo "Install dir:       $INSTALL_DIR"
echo "Nginx vhost:       $NGINX_CONF"
echo "DB engine:         $DB_ENGINE"
[[ "$DB_ENGINE" == "mariadb" ]] && echo "  - ${DB_NAME}/${DB_USER}  pass: $(mask "$DB_PASS")" || echo "  - SQLite @ ${INSTALL_DIR}/database/database.sqlite"
echo "Admin:             $ADMIN_USERNAME / $ADMIN_EMAILLOGIN / $(mask "$ADMIN_PASSWORD")"
echo "SMTP:              $( [[ "$SETUP_SMTP" == "y" ]] && echo Yes || echo No )"
echo "SSL mode:          $SSL_MODE"
[[ "$SSL_MODE" == "custom" ]] && echo "  - PEM headers: $(echo "$CERT_PEM" | head -n1) | $(echo "$KEY_PEM" | head -n1)"
echo "Cloudflare:        $( [[ "$CF_ENABLE" == "y" ]] && echo Enabled || echo Disabled )"
[[ "$CF_ENABLE" == "y" ]] && echo "  - DNS/IP: ${CF_DNS_NAME} → ${CF_RECORD_IP}"
echo "───────────────────────────────"
read -rp "Proceed? (Y/n): " ok || true; ok="${ok:-Y}"
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Packages
ensure_pkgs nginx php8.4 php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql php8.4-mbstring php8.4-bcmath php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-sqlite3 redis-server
systemctl enable --now redis-server
enable_ufw
[[ "$SSL_MODE" == "letsencrypt" ]] && ensure_pkgs certbot python3-certbot-nginx
[[ "$DB_ENGINE" == "mariadb"   ]] && ensure_pkgs mariadb-server mariadb-client
composer_setup

# ── Download & install Panel (tarball + composer)
mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
if [[ ! -f artisan ]]; then
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
fi
composer install --no-dev --optimize-autoloader --prefer-dist

# ── Database bootstrap
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

# ── Nginx vhost & SSL
PHP_DET="$(detect_phpfpm || true)"; PHP_VERSION="${PHP_DET%%|*}"; PHP_SOCK="${PHP_DET##*|}"
[[ -z "$PHP_SOCK" ]] && { PHP_VERSION="8.4"; PHP_SOCK="/run/php/php8.4-fpm.sock"; }

if [[ "$SSL_MODE" == "custom" ]]; then
  paths="$(save_custom_cert "$DOMAIN" "$CERT_PEM" "$KEY_PEM")"
  CRT="${paths%%|*}"; KEY="${paths##*|}"
  nginx_write_panel_config "$DOMAIN" "$INSTALL_DIR" "$PHP_SOCK" "custom" "$CRT" "$KEY"
else
  nginx_write_panel_config "$DOMAIN" "$INSTALL_DIR" "$PHP_SOCK" "none"
  [[ "$SSL_MODE" == "letsencrypt" ]] && certbot_issue_nginx "$DOMAIN" "$ADMIN_EMAIL"
fi

# ── .env & Pelican CLI (skip web installer)
cp -n .env.example .env || true
set_kv .env APP_URL "https://${DOMAIN}"
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
set_kv .env REDIS_HOST 127.0.0.1
set_kv .env CACHE_DRIVER redis
set_kv .env SESSION_DRIVER redis
set_kv .env QUEUE_CONNECTION redis

grep -q '^APP_KEY=base64:' .env || sudo -u www-data php artisan key:generate --force

php artisan p:environment:setup -n || true
if [[ "$DB_ENGINE" == "mariadb" ]]; then
  php artisan p:environment:database --driver=mysql --database="${DB_NAME}" --host=127.0.0.1 --port=3306 --username="${DB_USER}" --password="${DB_PASS}" -n || true
else
  php artisan p:environment:database --driver=sqlite --database="${INSTALL_DIR}/database/database.sqlite" -n || true
fi
php artisan p:redis:setup --redis-host=127.0.0.1 --redis-port=6379 -n || true
php artisan p:environment:{queue,session,cache} --driver=redis --redis-host=127.0.0.1 --redis-port=6379 -n || true || true

php artisan migrate --force
php artisan p:user:make --email="${ADMIN_EMAILLOGIN}" --username="${ADMIN_USERNAME}" --password="${ADMIN_PASSWORD}" --admin=1 -n || true

# Queue worker
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

# Cloudflare (optional)
if [[ "${CF_ENABLE:-n}" == "y" ]]; then
  cf_upsert_a "$CF_API_TOKEN" "$CF_ZONE_ID" "$CF_DNS_NAME" "$CF_RECORD_IP" true
  nginx_include_cf_realip
  if ! grep -q 'cloudflare-real-ip.conf' "$NGINX_CONF"; then
    sed -i '1a include /etc/nginx/includes/cloudflare-real-ip.conf;' "$NGINX_CONF"
    nginx -t && systemctl reload nginx || true
  fi
fi

# Summary
SUMMARY="${INSTALL_DIR}/pelican-install-summary.txt"
cat >"$SUMMARY" <<EOF
Pelican Panel — Installation Summary
Domain: https://${DOMAIN}/
Install: ${INSTALL_DIR}
Nginx:   ${NGINX_CONF}
PHP-FPM: ${PHP_SOCK} (PHP ${PHP_VERSION})
DB:      ${DB_ENGINE} $( [[ "$DB_ENGINE" == "mariadb" ]] && echo "(${DB_NAME}/${DB_USER})" )
Admin:   ${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN}
SSL:     ${SSL_MODE}
Cloudflare: $( [[ "${CF_ENABLE:-n}" == "y" ]] && echo "ON ($CF_DNS_NAME → $CF_RECORD_IP proxied)" || echo OFF )
EOF

say_ok "Panel installed. Summary → $SUMMARY"
