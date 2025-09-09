#!/usr/bin/env bash
# One-shot Pelican Panel installer (Ubuntu/Debian) — minimal, opinionated, non-blocking warnings
set -Eeuo pipefail

msg()  { printf "[*] %s\n" "$*"; }
ok()   { printf "[+] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*"; }
err()  { printf "[x] %s\n" "$*" >&2; }

require_rootish() {
  if [[ $EUID -ne 0 ]]; then
    warn "Not running as root. We'll use sudo where needed."
    SUDO="sudo"
  else
    SUDO=""
  fi
}

detect_os() {
  OS_ID="unknown"; OS_VER="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
  fi
  msg "OS: $OS_ID $OS_VER"
  case "$OS_ID" in
    ubuntu|debian) ok "Ubuntu/Debian detected."; ;;
    *) warn "Officially documented on Ubuntu/Debian. Continuing anyway." ;;
  esac
}

detect_php_version() {
  # Prefer 8.4 → 8.3 → 8.2 per docs; fall back to distro default if none
  local CANDIDATES=("8.4" "8.3" "8.2")
  PHPV=""
  for v in "${CANDIDATES[@]}"; do
    if apt-cache policy "php$v-fpm" 2>/dev/null | grep -q Candidate; then
      if apt-cache policy "php$v-fpm" | grep -q "Candidate: (none)"; then
        continue
      fi
      PHPV="$v"
      break
    fi
  done
  if [[ -z "$PHPV" ]]; then
    # Try generic 'php-fpm' to detect distro default
    if apt-cache policy php-fpm 2>/dev/null | grep -q Candidate; then
      PHPV=$(dpkg -l | awk '/php[0-9]+\.[0-9]+-fpm/ {print $2}' | sed -n 's/^php\([0-9]\+\.[0-9]\+\)-fpm.*/\1/p' | head -n1 || true)
      PHPV="${PHPV:-8.2}"
    else
      PHPV="8.2"
    fi
    warn "Could not find explicit PHP 8.4/8.3/8.2 packages in cache; trying $PHPV."
  fi
  ok "Using PHP $PHPV"
  PHPFPM_SOCK="/var/run/php/php${PHPV}-fpm.sock"
  PHP_BIN="/usr/bin/php"
}

rand() {
  # base64, strip non-url chars, length ~ 24
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#%+=' | head -c 24
}

collect_inputs() {
  echo
  read -rp "Panel domain (FQDN), e.g., panel.example.com: " PANEL_FQDN
  PANEL_FQDN=${PANEL_FQDN:-panel.example.com}

  read -rp "Admin email: " ADMIN_EMAIL
  ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}

  read -rp "Admin username [admin]: " ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}

  DB_NAME="pelican"
  DB_USER="pelican"
  DB_PASS=$(rand)
  ADMIN_PASS=$(rand)

  echo
  echo "Review:"
  echo "  Domain        : $PANEL_FQDN"
  echo "  Admin email   : $ADMIN_EMAIL"
  echo "  Admin user    : $ADMIN_USER"
  echo "  DB name/user  : $DB_NAME / $DB_USER"
  echo "  DB password   : (generated)"
  echo "  Admin password: (generated)"
  echo
  read -rp "Proceed with installation? [y/N]: " CONFIRM
  [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || { warn "Cancelled."; exit 0; }
}

apt_install() {
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl tar unzip git gnupg \
    nginx mariadb-server redis-server
  # PHP & extensions per docs
  $SUDO apt-get install -y "php${PHPV}" "php${PHPV}-fpm" \
    "php${PHPV}-cli" "php${PHPV}-gd" "php${PHPV}-mysql" "php${PHPV}-mbstring" \
    "php${PHPV}-bcmath" "php${PHPV}-xml" "php${PHPV}-curl" "php${PHPV}-zip" \
    "php${PHPV}-intl" "php${PHPV}-sqlite3"
  ok "Base packages installed."
}

install_composer() {
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | $SUDO php -- --install-dir=/usr/local/bin --filename=composer
    ok "Composer installed."
  else
    ok "Composer already present."
  fi
}

setup_db() {
  ok "Configuring MariaDB/MySQL..."
  $SUDO systemctl enable --now mariadb
  # Use socket auth as root (Debian/Ubuntu default); fallback to password prompt if needed
  if ! mysql -e "SELECT 1;" >/dev/null 2>&1; then
    warn "Cannot connect to MySQL as root via socket. You'll be prompted for root password."
    mysql -uroot -p -e "SELECT 1;" || { err "MySQL connection failed."; exit 1; }
  fi
  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';"
  mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
  mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';"
  mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  ok "Database prepared."
}

deploy_panel() {
  ok "Deploying Pelican Panel..."
  $SUDO systemctl enable --now "php${PHPV}-fpm" nginx redis-server

  $SUDO mkdir -p /var/www/pelican
  if [[ ! -d /var/www/pelican/.git ]]; then
    $SUDO git clone --depth=1 https://github.com/pelican-dev/panel.git /var/www/pelican
  else
    (cd /var/www/pelican && $SUDO git pull --ff-only)
  fi

  cd /var/www/pelican
  # Composer (allow root for simplicity)
  $SUDO env COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  # Generate .env & APP_KEY (non-interactive)
  if ! $SUDO "$PHP_BIN" artisan -q p:environment:setup; then
    warn "p:environment:setup failed/noninteractive; falling back to copying .env.example and key:generate."
    $SUDO cp -n .env.example .env || true
    $SUDO "$PHP_BIN" artisan key:generate --force
  fi

  # Configure database via CLI
  $SUDO "$PHP_BIN" artisan p:environment:database \
      --driver=mysql --database="$DB_NAME" --host=127.0.0.1 --port=3306 \
      --username="$DB_USER" --password="$DB_PASS" -n || warn "Database env update command returned non-zero; continuing."

  # Storage link & caches
  $SUDO "$PHP_BIN" artisan storage:link || true
  $SUDO "$PHP_BIN" artisan optimize:clear || true
  $SUDO "$PHP_BIN" artisan optimize || true

  # Migrate & seed schema
  $SUDO "$PHP_BIN" artisan migrate --seed --force

  # Permissions per docs
  $SUDO chmod -R 755 storage/* bootstrap/cache/ || true
  $SUDO chown -R www-data:www-data /var/www/pelican

  ok "Panel code & DB ready."
}

configure_nginx() {
  ok "Configuring NGINX vhost..."
  local VHOST="/etc/nginx/sites-available/pelican.conf"
  local ROOT="/var/www/pelican/public"

  $SUDO tee "$VHOST" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_FQDN};
    root ${ROOT};

    index index.php;
    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHPFPM_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  $SUDO rm -f /etc/nginx/sites-enabled/default
  $SUDO ln -sf "$VHOST" /etc/nginx/sites-enabled/pelican.conf
  $SUDO nginx -t
  $SUDO systemctl reload nginx
  ok "NGINX configured (HTTP). Add SSL later via SSL module."
}

create_admin_user() {
  ok "Creating admin user via artisan..."
  cd /var/www/pelican
  $SUDO "$PHP_BIN" artisan p:user:make \
      --email="$ADMIN_EMAIL" \
      --username="$ADMIN_USER" \
      --password="$ADMIN_PASS" \
      --admin=1 -n || warn "User creation returned non-zero; verify manually in the panel."
}

summary() {
  echo
  echo "Installation complete."
  echo "--------------------------------------------------"
  echo "URL            : http://$PANEL_FQDN"
  echo "Admin username : $ADMIN_USER"
  echo "Admin password : $ADMIN_PASS"
  echo "Admin email    : $ADMIN_EMAIL"
  echo
  echo "Database       : $DB_NAME"
  echo "DB user        : $DB_USER"
  echo "DB password    : $DB_PASS"
  echo
  echo "PHP-FPM sock   : $PHPFPM_SOCK"
  echo "Panel path     : /var/www/pelican"
  echo
  echo "Next steps:"
  echo "  - (Optional) Enable HTTPS via the SSL module later."
  echo "  - (Optional) Tune Redis/queue/mail in .env."
  echo "--------------------------------------------------"
}

trap 'err "An error occurred. Check the logs above."' ERR
require_rootish
detect_os
detect_php_version
collect_inputs
apt_install
install_composer
setup_db
deploy_panel
configure_nginx
create_admin_user
summary
