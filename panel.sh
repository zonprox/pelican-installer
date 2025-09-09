#!/usr/bin/env bash
# panel.sh - Minimal non-blocking Pelican Panel setup
set -euo pipefail

log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*"; }
hr() { printf "\033[2m%s\033[0m\n" "----------------------------------------"; }

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Please run as root (use sudo)."
    exit 1
  fi
}

require_env() {
  local missing=0
  for v in PANEL_DOMAIN PANEL_EMAIL PANEL_TZ DB_ROOT_PASS PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS; do
    if [[ -z "${!v:-}" ]]; then
      err "Missing env: $v (exported by install.sh)."
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then exit 1; fi
}

detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
  else
    err "This minimal script currently supports apt-based systems."
    exit 1
  fi
}

install_packages() {
  log "Updating package index..."
  apt-get update -y >/dev/null

  log "Installing dependencies (nginx, mariadb, redis, php)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    nginx mariadb-server redis-server \
    php php-fpm php-mysql php-cli php-curl php-mbstring php-xml php-zip php-gd >/dev/null

  # ensure services
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl enable --now mariadb >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true
  systemctl enable --now redis-server >/dev/null 2>&1 || true

  # timezone
  if [[ -n "${PANEL_TZ:-}" ]]; then
    timedatectl set-timezone "$PANEL_TZ" >/dev/null 2>&1 || warn "Failed to set timezone to $PANEL_TZ"
  fi
}

secure_mariadb() {
  log "Configuring MariaDB users & DB..."
  local mysql_cmd="mysql -uroot"
  if mysql -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    :
  else
    warn "Root auth with unix_socket only; trying without password still."
  fi

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

prepare_webroot() {
  PANEL_ROOT="/var/www/pelican"
  mkdir -p "$PANEL_ROOT"
  chown -R www-data:www-data "$PANEL_ROOT"
  find "$PANEL_ROOT" -type d -exec chmod 755 {} \;
  find "$PANEL_ROOT" -type f -exec chmod 644 {} \;
}

deploy_panel_placeholder() {
  hr
  warn "PLACEHOLDER: FETCH & DEPLOY PELICAN PANEL"
  cat <<'NOTE'
This is the single place you need to fill in with the official Pelican Panel deployment command.
For example (pseudo):
  curl -L https://example.com/pelican/panel.tar.gz | tar -xz -C /var/www/pelican --strip-components=1
  cd /var/www/pelican
  cp .env.example .env
  php artisan key:generate
  php artisan migrate --seed --force
  php artisan queue:restart

Until you put the real commands here, the rest of the stack (Nginx, PHP-FPM, MariaDB, Redis) is prepared.
NOTE
  hr
}

configure_phpfpm() {
  log "Tuning PHP-FPM (basic)"
  PHPFPM_POOL="/etc/php/*/fpm/pool.d/www.conf"
  for f in $PHPFPM_POOL; do
    [[ -f "$f" ]] || continue
    sed -i 's/^;*pm.max_children = .*/pm.max_children = 8/' "$f" || true
    sed -i 's/^;*pm.start_servers = .*/pm.start_servers = 2/' "$f" || true
    sed -i 's/^;*pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "$f" || true
    sed -i 's/^;*pm.max_spare_servers = .*/pm.max_spare_servers = 4/' "$f" || true
  done
  systemctl restart php*-fpm >/dev/null 2>&1 || true
}

configure_nginx() {
  log "Configuring Nginx vhost for ${PANEL_DOMAIN}"
  local site="/etc/nginx/sites-available/pelican-panel.conf"
  cat > "$site" <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    root /var/www/pelican/public;

    index index.php index.html;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg)\$ {
        expires max;
        log_not_found off;
    }

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;
}
NGINX

  ln -sf "$site" /etc/nginx/sites-enabled/pelican-panel.conf
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
}

post_info() {
  echo
  hr
  log "Pelican Panel base stack is ready."
  cat <<EOF
Domain     : https://${PANEL_DOMAIN}
Email      : ${PANEL_EMAIL}
DB Name    : ${PANEL_DB_NAME}
DB User    : ${PANEL_DB_USER}
DB Host    : 127.0.0.1
Redis      : localhost (default)
Timezone   : ${PANEL_TZ}

Next step:
- Replace the placeholder block in panel.sh with the official Pelican Panel deployment commands.
- (Optional) Run SSL module later to issue Let's Encrypt (not included in this minimal panel.sh).
EOF
  hr
}

main() {
  need_root
  require_env
  detect_pkg
  install_packages
  secure_mariadb
  prepare_webroot
  deploy_panel_placeholder
  configure_phpfpm
  configure_nginx
  post_info
}

main "$@"
