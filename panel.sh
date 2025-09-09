#!/usr/bin/env bash
set -euo pipefail

# Pelican Panel installer (Ubuntu/Debian focus). Minimal but production-minded.
# Docs referenced:
# - Supported OS/PHP/DB + panel tarball & composer: pelican.dev/docs/panel/getting-started/
# - Panel setup & artisan: pelican.dev/docs/panel/panel-setup/ and pelican.dev/docs/panel/advanced/artisan/
# - Wings virtualization & Docker note (for info messages): pelican.dev/docs/wings/install

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Please run as root (or via sudo)."
    exit 1
  fi
}

ask_inputs() {
  echo "== Pelican Panel – Input =="
  read -rp "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
  [[ -z "${PANEL_DOMAIN}" ]] && { echo "[!] Domain is required."; exit 1; }

  echo "SSL mode:"
  echo "  1) Let's Encrypt (auto)"
  echo "  2) Custom (paste PEM content)"
  echo "  3) None (HTTP only)"
  read -rp "Select [1-3]: " SSL_MODE

  if [[ "${SSL_MODE}" == "1" ]]; then
    read -rp "Email for Let's Encrypt (required): " LE_EMAIL
    [[ -z "${LE_EMAIL}" ]] && { echo "[!] Email is required for Let's Encrypt."; exit 1; }
  elif [[ "${SSL_MODE}" == "2" ]]; then
    echo "[i] Paste fullchain certificate (END with Ctrl-D):"
    CUSTOM_CERT="$(cat)"
    echo "[i] Paste private key (END with Ctrl-D):"
    CUSTOM_KEY="$(cat)"
  fi

  echo "Database mode:"
  echo "  1) MariaDB (recommended)"
  echo "  2) SQLite (single-file)"
  read -rp "Select [1-2]: " DB_MODE

  if [[ "${DB_MODE}" == "1" ]]; then
    DB_NAME="pelican"
    DB_USER="pelican"
    DB_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"
    echo "[i] MariaDB will be installed/configured. A database & user will be created."
  else
    echo "[i] SQLite will be used; suitable for small installs. MariaDB is recommended for production."
  fi
}

review_and_confirm() {
  echo
  echo "== Review =="
  echo " Domain     : ${PANEL_DOMAIN}"
  case "${SSL_MODE}" in
    1) echo " SSL        : Let's Encrypt (auto)";;
    2) echo " SSL        : Custom (PEM provided)";;
    3) echo " SSL        : None";;
  esac
  case "${DB_MODE}" in
    1) echo " Database   : MariaDB (db=${DB_NAME}, user=${DB_USER}, auto-generated password)";;
    2) echo " Database   : SQLite";;
  esac
  echo " Proceed? [y/N]"
  read -rp "> " ok
  [[ "${ok,,}" == "y" ]] || { echo "Canceled."; exit 0; }
}

gentle_compat_checks() {
  echo "[i] Checking minimal dependencies..."
  OS_OK=true
  . /etc/os-release || true
  case "${ID:-unknown}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:11|debian:12) : ;;
    *) OS_OK=false ;;
  esac
  if ! ${OS_OK}; then
    echo "[!] Warning: Your OS is not one of the commonly documented combinations for Pelican Panel."
    echo "    You can continue, but PHP/webserver package names may differ."
  fi

  PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "none")"
  if [[ "${PHPV}" == "none" ]]; then
    echo "[!] PHP not found yet. The installer will attempt to install it."
  elif [[ "$(printf '%s\n' "8.2" "$PHPV" | sort -V | head -n1)" != "8.2" ]]; then
    echo "[!] Warning: PHP ${PHPV} detected; Pelican recommends PHP 8.2/8.3/8.4."
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq software-properties-common curl tar unzip gnupg2 ca-certificates lsb-release

  # Webserver & PHP (use distro defaults; warn above if <8.2)
  apt-get install -y -qq nginx php php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # MariaDB if selected
  if [[ "${DB_MODE}" == "1" ]]; then
    apt-get install -y -qq mariadb-server mariadb-client
    systemctl enable --now mariadb
  fi

  # Certbot if LE
  if [[ "${SSL_MODE}" == "1" ]]; then
    apt-get install -y -qq certbot python3-certbot-nginx
  fi
}

setup_database() {
  if [[ "${DB_MODE}" == "1" ]]; then
    # Create DB & user (works with unix_socket root on Debian/Ubuntu)
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  fi
}

deploy_panel() {
  mkdir -p /var/www/pelican
  cd /var/www/pelican

  # Download latest panel release tarball (official docs)
  # Ref: curl ... | tar -xzv
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz

  # Install dependencies
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  # Prepare environment (.env) without interactive prompts
  cp -n .env.example .env || true

  # App URL + key
  sed -i "s#^APP_URL=.*#APP_URL=https://${PANEL_DOMAIN}#g" .env || true
  php artisan key:generate --force

  # DB config
  if [[ "${DB_MODE}" == "1" ]]; then
    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/g" .env
    sed -i "s/^DB_HOST=.*/DB_HOST=127.0.0.1/g" .env
    sed -i "s/^DB_PORT=.*/DB_PORT=3306/g" .env
    sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/g" .env
    sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/g" .env
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/g" .env
  else
    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/g" .env
    touch database/database.sqlite
    sed -i "s#^DB_DATABASE=.*#DB_DATABASE=$(pwd)/database/database.sqlite#g" .env
  fi

  # Migrate + seed
  php artisan migrate --seed --force

  # Permissions
  chown -R www-data:www-data /var/www/pelican
  find /var/www/pelican -type f -exec chmod 0644 {} \;
  find /var/www/pelican -type d -exec chmod 0755 {} \;
}

nginx_config() {
  local conf="/etc/nginx/sites-available/pelican"
  cat > "${conf}" <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    root /var/www/pelican/public;
    index index.php;

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~* \.(?:css|js|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri =404;
        expires 1h;
        add_header Cache-Control "public";
    }
}
EOF

  ln -sf "${conf}" /etc/nginx/sites-enabled/pelican
  # disable default site if present
  [[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx

  if [[ "${SSL_MODE}" == "1" ]]; then
    echo "[i] Requesting Let's Encrypt certificate via certbot..."
    certbot --nginx -d "${PANEL_DOMAIN}" -m "${LE_EMAIL}" --agree-tos --redirect --non-interactive
  elif [[ "${SSL_MODE}" == "2" ]]; then
    echo "[i] Installing custom certificate..."
    install -d -m 0755 /etc/ssl/pelican
    echo "${CUSTOM_CERT}" > /etc/ssl/pelican/fullchain.pem
    echo "${CUSTOM_KEY}"  > /etc/ssl/pelican/privkey.pem
    chmod 600 /etc/ssl/pelican/privkey.pem

    # Replace server block to use SSL (simple)
    cat > "${conf}" <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};

    ssl_certificate     /etc/ssl/pelican/fullchain.pem;
    ssl_certificate_key /etc/ssl/pelican/privkey.pem;

    root /var/www/pelican/public;
    index index.php;

    access_log /var/log/nginx/pelican_access.log;
    error_log  /var/log/nginx/pelican_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
}
EOF
    nginx -t && systemctl reload nginx
  else
    echo "[i] SSL disabled (HTTP only). You can enable HTTPS later."
  fi
}

final_info() {
  echo
  echo "== Installation Complete =="
  echo " URL       : https://${PANEL_DOMAIN}"
  if [[ "${DB_MODE}" == "1" ]]; then
    echo " DB        : MariaDB"
    echo "   name    : ${DB_NAME}"
    echo "   user    : ${DB_USER}"
    echo "   pass    : ${DB_PASS}"
  else
    echo " DB        : SQLite at /var/www/pelican/database/database.sqlite"
  fi
  echo " Panel dir : /var/www/pelican"
  echo " Nginx     : /etc/nginx/sites-available/pelican"
  echo
  echo "[Next] Create the first admin user:"
  echo "  cd /var/www/pelican && php artisan p:user:make"
  echo
  echo "[Note] Pelican supports PHP 8.2/8.3/8.4 and MySQL 8+/MariaDB 10.6+;"
  echo "      for details see docs."
}

# ---- run flow ----
ensure_root
ask_inputs
review_and_confirm
gentle_compat_checks
install_packages
setup_database
deploy_panel
nginx_config
final_info
