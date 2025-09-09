#!/usr/bin/env bash
set -euo pipefail

PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

# ====== Targets & Defaults ======
PELICAN_DIR="/var/www/pelican"
NGINX_AVAIL="/etc/nginx/sites-available/pelican.conf"
NGINX_SITE="/etc/nginx/sites-enabled/pelican.conf"
QUEUE_UNIT="/etc/systemd/system/pelican-queue.service"
WINGS_UNIT="/etc/systemd/system/wings.service"   # if present later
PEL_USER="pelican"
PEL_GROUP="pelican"

# ====== Helpers ======
cecho(){ echo -e "\033[1;36m$*\033[0m"; }
gecho(){ echo -e "\033[1;32m$*\033[0m"; }
recho(){ echo -e "\033[1;31m$*\033[0m"; }
yecho(){ echo -e "\033[1;33m$*\033[0m"; }

require_root(){ [[ $EUID -eq 0 ]] || { recho "Please run as root (sudo)."; exit 1; }; }

detect_os(){
  source /etc/os-release || { recho "Cannot read /etc/os-release"; exit 1; }
  OS="$ID"; OS_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
  case "$OS" in
    ubuntu) dpkg --compare-versions "$OS_VER" ge "22.04" || { recho "Ubuntu $OS_VER not supported (need 22.04+)."; exit 1; } ;;
    debian) dpkg --compare-versions "$OS_VER" ge "11"    || { recho "Debian $OS_VER not supported (need 11+)."; exit 1; } ;;
    *) recho "Unsupported OS: $PRETTY_NAME"; exit 1 ;;
  esac
}

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

# Read server_name from nginx site if available
read_panel_domain(){
  PANEL_FQDN=""
  if [[ -f "$NGINX_AVAIL" ]]; then
    PANEL_FQDN="$(awk '/server_name[ \t]+/ {gsub(/;|server_name/,""); print $0; exit}' "$NGINX_AVAIL" | xargs || true)"
  fi
}

# Try to stop & disable a unit if exists
stop_disable_unit(){
  local unit="$1"
  if systemctl list-unit-files | grep -q "^$(basename "$unit")"; then
    systemctl stop "$(basename "$unit")" || true
    systemctl disable "$(basename "$unit")" || true
  fi
  # If it's a loose file under /etc/systemd/system, remove & daemon-reload
  if [[ -f "$unit" ]]; then
    rm -f "$unit"
    systemctl daemon-reload || true
  fi
}

# Remove www-data cron line for Laravel scheduler
remove_wwwdata_cron(){
  if crontab -l -u www-data 2>/dev/null | grep -q 'artisan schedule:run'; then
    crontab -l -u www-data 2>/dev/null | grep -v 'artisan schedule:run' | crontab -u www-data - || true
  fi
}

# Database clean (MariaDB/MySQL)
drop_mysql_assets(){
  local DB_NAME="pelican"
  local DB_USER="pelican"
  if cmd_exists mysql; then
    yecho "Dropping MySQL/MariaDB database & user if exist..."
    mysql -NBe "DROP DATABASE IF EXISTS \`$DB_NAME\`;" || true
    mysql -NBe "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';" || true
    mysql -NBe "FLUSH PRIVILEGES;" || true
  fi
}

# Remove nginx site
remove_nginx_site(){
  if [[ -f "$NGINX_SITE" ]]; then rm -f "$NGINX_SITE"; fi
  if [[ -f "$NGINX_AVAIL" ]]; then rm -f "$NGINX_AVAIL"; fi
  if cmd_exists nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  fi
}

# Remove cert via certbot if domain known
remove_cert_if_any(){
  [[ -z "${PANEL_FQDN:-}" ]] && return 0
  if cmd_exists certbot; then
    # Non-interactive delete; ignore errors if no such cert
    certbot delete --cert-name "$PANEL_FQDN" -n || true
    # Some installs name the cert by domain, handle -d as fallback (best-effort)
    certbot delete -d "$PANEL_FQDN" -n || true
    systemctl reload nginx || true
  fi
}

# Remove app files & user
remove_files_and_user(){
  # Kill processes under pelican user (best-effort)
  if id -u "$PEL_USER" >/dev/null 2>&1; then
    pkill -u "$PEL_USER" || true
  fi

  # Remove app dir
  rm -rf "$PELICAN_DIR" || true
  # Remove residual logs or caches commonly used
  rm -rf /var/log/pelican* /var/tmp/pelican* /tmp/pelican* 2>/dev/null || true

  # Remove user/group if exist
  if id -u "$PEL_USER" >/dev/null 2>&1; then
    userdel -r "$PEL_USER" 2>/dev/null || userdel "$PEL_USER" || true
  fi
  if getent group "$PEL_GROUP" >/dev/null 2>&1; then
    groupdel "$PEL_GROUP" || true
  fi
}

# Full purge of related packages (dangerous if shared)
purge_related_packages(){
  yecho "Purging related packages (nginx, php8.2*, mariadb, redis, certbot/snapd, composer)..."
  # Stop common services first
  systemctl stop nginx 2>/dev/null || true
  systemctl stop mariadb 2>/dev/null || true
  systemctl stop redis-server 2>/dev/null || true

  # Composer binary installed by us (common path)
  [[ -f /usr/local/bin/composer ]] && rm -f /usr/local/bin/composer || true

  # Purge packages (names are broad; ignore missing)
  apt-get purge -y \
    nginx nginx-core nginx-common \
    "php8.2*" php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-sqlite3 php8.2-xml php8.2-mbstring php8.2-bcmath php8.2-curl php8.2-zip php8.2-gd php8.2-intl \
    mariadb-server mariadb-client \
    redis-server \
    certbot || true

  # Remove snapd/certbot if installed via snap
  if cmd_exists snap; then
    snap remove certbot || true
    # Optional: remove snapd entirely (comment out if you prefer to keep snapd)
    apt-get purge -y snapd || true
    rm -rf /snap /var/snap /var/lib/snapd || true
  fi

  # Remove 3rd-party PHP repos (ondrej or sury)
  [[ -f /etc/apt/sources.list.d/ondrej-ubuntu-php*.list ]] && rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php*.list || true
  [[ -f /etc/apt/sources.list.d/sury-php.list          ]] && rm -f /etc/apt/sources.list.d/sury-php.list          || true
  [[ -f /usr/share/keyrings/sury.gpg                   ]] && rm -f /usr/share/keyrings/sury.gpg                   || true

  apt-get autoremove -y || true
  apt-get autoclean -y || true
  apt-get update -y || true
}

snapshot_plan(){
  cecho "== Detected resources to remove =="
  [[ -d "$PELICAN_DIR" ]]  && echo " - Files: $PELICAN_DIR"
  [[ -f "$NGINX_AVAIL" ]]  && echo " - Nginx site-available: $NGINX_AVAIL"
  [[ -f "$NGINX_SITE"  ]]  && echo " - Nginx site-enabled:   $NGINX_SITE"
  [[ -f "$QUEUE_UNIT"  ]]  && echo " - Systemd unit:         $(basename "$QUEUE_UNIT")"
  systemctl list-unit-files 2>/dev/null | grep -q '^wings.service' && echo " - Systemd unit:         wings.service"
  id -u "$PEL_USER" >/dev/null 2>&1 && echo " - User:                 $PEL_USER"
  getent group "$PEL_GROUP" >/dev/null 2>&1 && echo " - Group:                $PEL_GROUP"
  cmd_exists mysql && echo " - Database:             pelican (MySQL/MariaDB if exists)"
  [[ -n "${PANEL_FQDN:-}" ]] && echo " - TLS Certificate:      $PANEL_FQDN (certbot if exists)"
  echo
}

# ====== Flow ======
require_root
detect_os
read_panel_domain

# Menu: minimal vs full purge
clear
cecho "Pelican Uninstaller"
echo "What do you want to remove?"
echo "1) Safe Clean  (remove Pelican app, DB, users, Nginx site, units, cert; keep system packages)"
echo "2) Full Purge  (also purge nginx/php/mariadb/redis/certbot/snapd/composer & repos)"
echo "0) Exit"
read -rp "Select: " CHOICE
[[ "$CHOICE" =~ ^[012]$ ]] || { recho "Invalid selection."; exit 1; }
[[ "$CHOICE" == "0" ]] && exit 0

# Show plan & confirm
snapshot_plan
echo "Proceed?"
echo "1) Confirm & Uninstall"
echo "2) Cancel"
read -rp "Select: " OK
[[ "$OK" == "1" ]] || { recho "Cancelled."; exit 1; }

# Stop related units first
stop_disable_unit "$QUEUE_UNIT"
stop_disable_unit "$WINGS_UNIT"
# Some providers install wings as just "wings" in /usr/local/bin + service
systemctl stop wings 2>/dev/null || true
systemctl disable wings 2>/dev/null || true

# Remove cron
remove_wwwdata_cron

# DB clean
drop_mysql_assets

# Nginx & TLS clean
remove_cert_if_any
remove_nginx_site

# Files & user
remove_files_and_user

# Full purge if chosen
if [[ "$CHOICE" == "2" ]]; then
  purge_related_packages
fi

gecho "Uninstall completed."
exit 0
