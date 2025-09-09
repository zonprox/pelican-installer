#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel installer (minimal but complete)
# - PHP 8.4 (fallback to 8.3 if repository not available)
# - NGINX
# - MariaDB (preferred); optional SQLite
# - SSL modes: Let's Encrypt / Custom PEM / None
#
# Docs referenced:
#   - Panel Getting Started (OS & PHP deps, download latest release, composer) :contentReference[oaicite:0]{index=0}
#   - Panel Setup (artisan env setup) :contentReference[oaicite:1]{index=1}
#   - Webserver Configuration (Nginx/Apache/Caddy) :contentReference[oaicite:2]{index=2}
#   - MariaDB preferred (Pelican MySQL page) :contentReference[oaicite:3]{index=3}
#   - SSL creation/LE overview (Pelican SSL & Let’s Encrypt) :contentReference[oaicite:4]{index=4}

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[OK]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[ERR]\033[0m %s\n" "$*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

prompt_inputs() {
  echo "=== Panel Configuration ==="
  read -rp "Panel domain (e.g., panel.example.com) [required]: " PANEL_DOMAIN
  if [[ -z "${PANEL_DOMAIN}" ]]; then err "Domain is required."; exit 1; fi

  read -rp "Contact email for Let's Encrypt / panel notices [you@example.com]: " PANEL_EMAIL
  PANEL_EMAIL=${PANEL_EMAIL:-you@example.com}

  echo "SSL mode:"
  echo "  1) Let's Encrypt (automatic)"
  echo "  2) Custom (paste PEM & KEY)"
  echo "  3) None (HTTP only)"
  read -rp "Choose [1-3]: " SSL_MODE
  if [[ "${SSL_MODE}" != "1" && "${SSL_MODE}" != "2" && "${SSL_MODE}" != "3" ]]; then
    err "Invalid SSL mode"; exit 1
  fi

  echo "Database:"
  echo "  1) MariaDB (preferred)"
  echo "  2) SQLite (quick test / not recommended for prod)"
  read -rp "Choose [1-2]: " DB_MODE
  if [[ "${DB_MODE}" != "1" && "${DB_MODE}" != "2" ]]; then
    err "Invalid DB mode"; exit 1
  fi

  # For MariaDB, ask for db/user names (generate password)
  if [[ "${DB_MODE}" == "1" ]]; then
    read -rp "DB name [pelican]: " DB_NAME
    DB_NAME=${DB_NAME:-pelican}
    read -rp "DB user [pelican]: " DB_USER
    DB_USER=${DB_USER:-pelican}
    DB_PASS="$(openssl rand -base64 24 | tr -d '\n' | sed 's/[\/\"]/A/g')"
  fi

  echo
  echo "=== Review ==="
  echo "Domain   : ${PANEL_DOMAIN}"
  echo "Email    : ${PANEL_EMAIL}"
  echo "SSL      : $( [[ "${SSL_MODE}" == "1" ]] && echo "Let's Encrypt" || ([[ "${SSL_MODE}" == "2" ]] && echo "Custom" || echo "None"))"
  echo "Database : $( [[ "${DB_MODE}" == "1" ]] && echo "MariaDB" || echo "SQLite")"
  [[ "${DB_MODE}" == "1" ]] && echo "DB creds : ${DB_USER}@${DB_NAME}  (password will be generated)"
  read -rp "Proceed with installation? [y/N]: " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Aborted."; exit 0
  fi
}

apt_noninteractive() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
}

ensure_tools() {
  apt-get install -y curl tar unzip ca-certificates lsb-release gnupg git
}

install_nginx() {
  apt-get install -y nginx
  systemctl enable --now nginx
}

install_php_stack() {
  # Try PHP 8.4 first (recommended by Pelican docs); fallback to 8.3 if 8.4 repo unavailable
  local phpver=""
  if [[ -n "$(command -v apt-get)" ]]; then
    # Add PHP repos for Ubuntu/Debian if needed
    . /etc/os-release || true
    case "${ID:-}" in
      ubuntu)
        add-apt-repository -y ppa:ondrej/php || true
        ;;
      debian)
        # Sury repo for Debian
        apt-get install -y apt-transport-https software-properties-common || true
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury.gpg || true
        echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" \
          > /etc/apt/sources.list.d/sury-php.list || true
        ;;
    esac
    apt-get update -y || true
  fi

  if apt-get install -y php8.4 php8.4-{fpm,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,sqlite3}; then
    phpver="8.4"
  else
    warn "PHP 8.4 not available, falling back to 8.3"
    apt-get install -y php8.3 php8.3-{fpm,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,sqlite3}
    phpver="8.3"
  fi

  systemctl enable --now "php${phpver}-fpm"
  PHP_SOCK="/run/php/php${phpver}-fpm.sock"
  echo "${PHP_SOCK}" > /tmp/pelican_php_sock
  ok "PHP ${phpver} installed."
}

install_mariadb() {
  # Prefer MariaDB per docs
  curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash || true
  apt-get update -y
  apt-get install -y mariadb-server
  systemctl enable --now mariadb
  ok "MariaDB installed."

  # Create DB + user
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  ok "Database ${DB_NAME} and user ${DB_USER} created."
}

install_composer() {
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
}

download_panel() {
  mkdir -p /var/www/pelican
  cd /var/www/pelican
  # Download latest packaged release
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  chown -R www-data:www-data /var/www/pelican
  ok "Pelican Panel downloaded & dependencies installed."
}

write_env() {
  cd /var/www/pelican
  cp -n .env.example .env || true
  # Base config
  cat >/var/www/pelican/.env <<EOF
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${PANEL_DOMAIN}
APP_TIMEZONE=UTC

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379

# Database
DB_CONNECTION=${DB_MODE==1 && echo mariadb || echo sqlite}
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_MODE==1 && echo "${DB_NAME}" || echo "database.sqlite"}
DB_USERNAME=${DB_MODE==1 && echo "${DB_USER}" || echo ""}
DB_PASSWORD=${DB_MODE==1 && echo "${DB_PASS}" || echo ""}

# Mail placeholder (you can change later in Panel)
MAIL_MAILER=log
MAIL_FROM_ADDRESS=noreply@${PANEL_DOMAIN}
MAIL_FROM_NAME="Pelican Panel"
EOF

  if [[ "${DB_MODE}" == "2" ]]; then
    mkdir -p /var/www/pelican/database
    touch /var/www/pelican/database/database.sqlite
    chown -R www-data:www-data /var/www/pelican/database
  fi

  # Generate APP_KEY & run basic setup (non-interactive fallback if artisan prompts)
  sudo -u www-data php artisan key:generate --force || true
  ok ".env configured."
}

configure_nginx_http_only() {
  local PHP_SOCK; PHP_SOCK="$(cat /tmp/pelican_php_sock)"
  cat >/etc/nginx/sites-available/pelican.conf <<NGX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    root /var/www/pelican/public;

    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp)$ {
        expires 7d;
        access_log off;
    }
}
NGX
  ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

enable_https_with_cert_paths() {
  local CERT="$1" KEY="$2"
  local PHP_SOCK; PHP_SOCK="$(cat /tmp/pelican_php_sock)"
  cat >/etc/nginx/sites-available/pelican.conf <<NGX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};
    root /var/www/pelican/public;

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};

    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp)$ {
        expires 7d;
        access_log off;
    }
}
NGX
  ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

configure_ssl() {
  case "${SSL_MODE}" in
    1)
      # Let's Encrypt via certbot (nginx plugin)
      apt-get install -y certbot python3-certbot-nginx
      # Ensure HTTP vhost exists so LE can pass HTTP-01
      configure_nginx_http_only
      # Obtain certificate & auto-configure nginx
      certbot --nginx -d "${PANEL_DOMAIN}" -m "${PANEL_EMAIL}" --agree-tos --redirect --no-eff-email -n
      ok "Let's Encrypt certificate installed and nginx configured."
      ;;
    2)
      # Custom PEM/KEY
      echo "Paste FULLCHAIN (END WITH CTRL-D on new line):"
      CUSTOM_CERT_DIR="/etc/ssl/pelican"
      mkdir -p "${CUSTOM_CERT_DIR}"
      CERT_PATH="${CUSTOM_CERT_DIR}/fullchain.pem"
      KEY_PATH="${CUSTOM_CERT_DIR}/privkey.pem"
      cat > "${CERT_PATH}"
      echo "Paste PRIVATE KEY (END WITH CTRL-D on new line):"
      cat > "${KEY_PATH}"
      chmod 600 "${KEY_PATH}"
      enable_https_with_cert_paths "${CERT_PATH}" "${KEY_PATH}"
      ok "Custom certificate installed and nginx configured."
      ;;
    3)
      configure_nginx_http_only
      warn "SSL disabled: serving HTTP only."
      ;;
  esac
}

redis_install() {
  # Recommended cache/session backend in docs
  apt-get install -y redis-server
  systemctl enable --now redis-server
}

finalize_panel() {
  cd /var/www/pelican
  sudo -u www-data php artisan migrate --force || true
  sudo -u www-data php artisan cache:clear || true
  sudo -u www-data php artisan config:clear || true
  ok "Panel initialized."
}

show_summary() {
  echo
  echo "================ Installation Complete ================"
  echo "Pelican Panel URL : https://${PANEL_DOMAIN}"
  if [[ "${DB_MODE}" == "1" ]]; then
    echo "Database          : MariaDB"
    echo "  Name           : ${DB_NAME}"
    echo "  User           : ${DB_USER}"
    echo "  Pass           : ${DB_PASS}"
  else
    echo "Database          : SQLite (/var/www/pelican/database/database.sqlite)"
  fi
  echo
  echo "Next steps:"
  echo "  1) Open the URL above and finish the web installer / create the admin user."
  echo "  2) (Optional) If behind a reverse proxy (Cloudflare/NGINX/Caddy), see Optional Config docs."
  echo "  3) To change domain later, update Nginx & panel config (see docs)."
  echo "======================================================="
}

main() {
  require_root
  prompt_inputs
  apt_noninteractive
  ensure_tools
  install_nginx
  install_php_stack
  redis_install
  if [[ "${DB_MODE}" == "1" ]]; then install_mariadb; fi
  install_composer
  download_panel
  write_env
  configure_ssl
  finalize_panel
  show_summary
}

main "$@"
