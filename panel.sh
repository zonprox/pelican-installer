#!/usr/bin/env bash
# panel.sh - Auto-provision Pelican Panel (per pelican.dev docs), non-interactive
# Requires env exports from install.sh:
#   PANEL_DOMAIN PANEL_EMAIL PANEL_TZ DB_ROOT_PASS PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS
set -euo pipefail

log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*"; }
hr()  { printf "\033[2m%s\033[0m\n" "----------------------------------------"; }

need_root() {
  if [[ ${EUID} -ne 0 ]]; then err "Please run as root (use sudo)."; exit 1; fi
}

require_env() {
  local missing=0
  for v in PANEL_DOMAIN PANEL_EMAIL PANEL_TZ DB_ROOT_PASS PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS; do
    if [[ -z "${!v:-}" ]]; then err "Missing env: $v (exported by install.sh)."; missing=1; fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

has() { command -v "$1" >/dev/null 2>&1; }

detect_pkgmgr() {
  if has apt-get; then PKG=apt-get; OS_FAMILY=debian;
  else err "This minimal script currently supports apt-based systems."; exit 1; fi
}

install_base_packages() {
  log "Updating package index..."
  $PKG update -y >/dev/null

  # PHP: use distro default (8.4/8.3/8.2 on modern Ubuntu/Debian). Keep minimal & non-blocking.
  # Docs recommend PHP 8.4/8.3/8.2 with extensions: gd, mysql, mbstring, bcmath, xml, curl, zip, intl, sqlite3, fpm
  # https://pelican.dev/docs/panel/getting-started/
  log "Installing Nginx, MariaDB, Redis, PHP & extensions..."
  DEBIAN_FRONTEND=noninteractive $PKG install -y \
    ca-certificates curl gnupg lsb-release \
    nginx mariadb-server redis-server \
    php php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3 >/dev/null

  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl enable --now mariadb >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true
  systemctl enable --now redis-server >/dev/null 2>&1 || true

  # Timezone (best-effort)
  timedatectl set-timezone "$PANEL_TZ" >/dev/null 2>&1 || warn "Failed to set timezone: $PANEL_TZ"
}

secure_mariadb_and_db() {
  log "Configuring MariaDB and creating Panel DB/user..."
  local mysql_cmd="mysql -uroot"
  # Try to set root password (both auth modes handled best-effort)
  $mysql_cmd <<SQL || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

  $mysql_cmd -p"${DB_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${PANEL_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PANEL_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PANEL_DB_NAME}\`.* TO '${PANEL_DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

detect_php_fpm_socket() {
  # Prefer versioned sockets, fallback to generic sock.
  PHP_FPM_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
  if [[ -z "${PHP_FPM_SOCK}" && -S /run/php/php-fpm.sock ]]; then PHP_FPM_SOCK="/run/php/php-fpm.sock"; fi
  if [[ -z "${PHP_FPM_SOCK}" ]]; then
    warn "Cannot find php-fpm.sock; attempting to start any php*-fpm services."
    systemctl restart 'php*-fpm' >/dev/null 2>&1 || true
    PHP_FPM_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "${PHP_FPM_SOCK}" ]]; then err "Unable to detect PHP-FPM socket."; exit 1; fi
  log "Detected PHP-FPM socket: ${PHP_FPM_SOCK}"
}

prepare_webroot_and_download() {
  PANEL_ROOT="/var/www/pelican"
  log "Preparing panel root at ${PANEL_ROOT}"
  mkdir -p "$PANEL_ROOT"
  cd "$PANEL_ROOT"

  # Per docs: download latest release tarball to current dir and extract
  # https://pelican.dev/docs/panel/getting-started/   https://pelican.dev/docs/panel/update/
  log "Downloading latest Pelican Panel release..."
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv

  # Composer (per docs)
  if ! has composer; then
    log "Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  log "Installing PHP dependencies (composer install)..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
}

permissions_and_nginx() {
  # Panel Setup docs — set permissions then continue via installer
  # https://pelican.dev/docs/panel/panel-setup/
  log "Setting file permissions..."
  chmod -R 755 storage/* bootstrap/cache/ || true
  chown -R www-data:www-data "$PANEL_ROOT"

  # Nginx vhost per docs (HTTP variant). SSL handled by separate module later.
  # https://pelican.dev/docs/panel/webserver-config
  log "Writing Nginx vhost for ${PANEL_DOMAIN}"
  local site="/etc/nginx/sites-available/pelican.conf"
  cat > "$site" <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    root /var/www/pelican/public;
    index index.php index.html;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

  ln -sf "$site" /etc/nginx/sites-enabled/pelican.conf
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl restart nginx
}

artisan_bootstrap() {
  cd "$PANEL_ROOT"

  # Create .env & APP_KEY (non-interactive allowed with -n). Docs: p:environment:setup
  # https://pelican.dev/docs/panel/panel-setup/
  log "Initializing environment (.env & APP_KEY)..."
  php artisan p:environment:setup -n || true

  # Configure database to use MariaDB credentials we created.
  # Docs: p:environment:database options
  # https://pelican.dev/docs/panel/advanced/artisan/
  log "Configuring database connection..."
  php artisan p:environment:database \
    --driver=mysql \
    --database="${PANEL_DB_NAME}" \
    --host=127.0.0.1 \
    --port=3306 \
    --username="${PANEL_DB_USER}" \
    --password="${PANEL_DB_PASS}" \
    -n

  # Optional: set cache/session/queue to Redis quickly (best-effort, skip on failure)
  log "Configuring Redis (cache/session/queue)..."
  php artisan p:redis:setup --redis-host=127.0.0.1 -n || true

  # Migrate & seed (force in production)
  log "Running database migrations..."
  php artisan migrate --seed --force

  # Create a systemd queue worker service (non-interactive). Use www-data.
  log "Creating queue worker service..."
  php artisan p:environment:queue-service --service-name=pelican-queue --user=www-data --group=www-data --overwrite -n || true
  systemctl daemon-reload || true
  systemctl enable --now pelican-queue || true

  # Final perms (tighten env a bit)
  chmod 640 "${PANEL_ROOT}/.env" || true
  chown -R www-data:www-data "$PANEL_ROOT"
}

post_info() {
  echo
  hr
  log "Pelican Panel is deployed."
  cat <<EOF
Open the web installer to finalize setup (admin user, etc.):
  http://${PANEL_DOMAIN}/installer

References:
- Getting Started: https://pelican.dev/docs/panel/getting-started/
- Webserver Config (NGINX): https://pelican.dev/docs/panel/webserver-config
- Panel Setup (env, perms): https://pelican.dev/docs/panel/panel-setup
- Artisan commands (non-interactive flags): https://pelican.dev/docs/panel/advanced/artisan/

If you plan to enable HTTPS, run your SSL module later to provision Let's Encrypt and switch Nginx to TLS.
EOF
  hr
}

main() {
  need_root
  require_env
  detect_pkgmgr
  install_base_packages
  secure_mariadb_and_db
  detect_php_fpm_socket
  prepare_webroot_and_download
  permissions_and_nginx
  artisan_bootstrap
  post_info
}

main "$@"
