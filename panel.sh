#!/usr/bin/env bash
# Pelican Panel installer (Ubuntu/Debian focused, gentle checks, fully automated path)
# Flow: gather inputs -> review -> confirm -> install -> print summary.

set -Eeuo pipefail

WORKDIR="/tmp/pelican-installer"
LOG_FILE="${WORKDIR}/panel-install.log"
PANEL_DIR="/var/www/pelican"
NGINX_SITE="/etc/nginx/sites-available/pelican.conf"
NGINX_LINK="/etc/nginx/sites-enabled/pelican.conf"

ESC="$(printf '\033')"
cursor_blink_on(){ printf "${ESC}[?25h"; }
cursor_blink_off(){ printf "${ESC}[?25l"; }
print_active(){ printf "${ESC}[7m> %s ${ESC}[27m\n" "$1"; }
print_inactive(){ printf "  %s  \n" "$1"; }
get_key(){
  read -rsn1 key 2>/dev/null || true
  case "$key" in
    "") echo enter ;;
    $'\x1b') read -rsn2 key || true; [[ "$key" == "[A" ]] && echo up && return; [[ "$key" == "[B" ]] && echo down && return; echo ignore ;;
    *) echo ignore ;;
  esac
}
choose(){
  local title="$1"; shift
  local items=("$@")
  local sel=0
  trap 'cursor_blink_on' EXIT
  cursor_blink_off
  echo; echo "$title"; echo
  while true; do
    for i in "${!items[@]}"; do
      if [[ $i -eq $sel ]]; then print_active "${items[$i]}"; else print_inactive "${items[$i]}"; fi
    done
    case "$(get_key)" in
      up)   ((sel= (sel-1+${#items[@]})%${#items[@]})) ;;
      down) ((sel= (sel+1)%${#items[@]})) ;;
      enter) echo "$sel"; return ;;
      *) :;;
    esac
    printf "${ESC}[${#items[@]}A"
  done
}

log(){ printf -- "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG_FILE" >&2; }

require_root(){
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then echo "Please run as root or install sudo."; exit 1; fi
  fi
}
sudo_run(){ if [[ $EUID -ne 0 ]]; then sudo bash -c "$*"; else bash -c "$*"; fi; }

detect_os(){
  local os="unknown" ver=""
  if [[ -f /etc/os-release ]]; then . /etc/os-release; os="${ID:-unknown}"; ver="${VERSION_ID:-}"; fi
  echo "$os|$ver"
}

detect_php_fpm_sock(){
  # Return best-guess php-fpm sock path
  local sock=""
  for d in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do [[ -S "$d" ]] && sock="$d" && break; done
  if [[ -z "$sock" ]]; then
    # try discover installed PHP versions
    local v=""
    if command -v php >/dev/null 2>&1; then v="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" || true; fi
    [[ -n "$v" ]] && sock="/run/php/php${v}-fpm.sock"
  fi
  echo "$sock"
}

ensure_packages(){
  local os ver; IFS='|' read -r os ver <<<"$(detect_os)"
  log "Detected OS: ${os^} ${ver}"

  # Common tools
  sudo_run "apt-get update -y"
  sudo_run "apt-get install -y ca-certificates lsb-release curl tar unzip git software-properties-common"

  # NGINX
  sudo_run "apt-get install -y nginx"

  # PHP (prefer 8.3+ as per Pelican docs)
  local php_pkgs="php php-cli php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-sqlite3"
  # On Ubuntu 22.04 we may need PPA for newer PHP
  if [[ "$os" == "ubuntu" && "${ver%%.*}" -eq 22 ]]; then
    sudo_run "add-apt-repository -y ppa:ondrej/php || true"
    sudo_run "apt-get update -y"
  fi
  sudo_run "apt-get install -y ${php_pkgs}"

  # Composer (Pelican docs)
  # https://pelican.dev/docs/panel/getting-started/
  if ! command -v composer >/dev/null 2>&1; then
    sudo_run "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
  fi
}

install_mariadb(){
  # https://pelican.dev/docs/panel/advanced/mysql
  sudo_run "curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash"
  sudo_run "apt-get install -y mariadb-server"
}

create_db(){
  local dbuser="$1" dbpass="$2" dbname="$3"
  sudo_run "mysql -u root -e \"CREATE USER IF NOT EXISTS '${dbuser}'@'127.0.0.1' IDENTIFIED BY '${dbpass}';\""
  sudo_run "mysql -u root -e \"CREATE DATABASE IF NOT EXISTS \\\`${dbname}\\\\\\\`;\""
  sudo_run "mysql -u root -e \"GRANT ALL PRIVILEGES ON \\\`${dbname}\\\\\\\`.* TO '${dbuser}'@'127.0.0.1'; FLUSH PRIVILEGES;\""
}

download_panel(){
  # https://pelican.dev/docs/panel/getting-started/
  sudo_run "mkdir -p ${PANEL_DIR}"
  pushd "$PANEL_DIR" >/dev/null
  sudo_run "curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv"
  # Install PHP deps
  sudo_run "COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader"
  popd >/dev/null
}

configure_env(){
  pushd "$PANEL_DIR" >/dev/null
  # Generate .env + APP_KEY
  sudo_run "php artisan p:environment:setup -n"
  # Configure DB if MySQL/MariaDB chosen
  local driver="$1" dbname="$2" dbuser="$3" dbpass="$4" host="${5:-127.0.0.1}" port="${6:-3306}"
  if [[ "$driver" == "mysql" ]]; then
    sudo_run "php artisan p:environment:database --driver=mysql --database='${dbname}' --host='${host}' --port='${port}' --username='${dbuser}' --password='${dbpass}' -n"
  fi
  # Permissions (Pelican docs)
  # https://pelican.dev/docs/panel/panel-setup/
  sudo_run "chmod -R 755 storage/* bootstrap/cache/"
  sudo_run "chown -R www-data:www-data ${PANEL_DIR}"
  popd >/dev/null
}

configure_nginx(){
  local server_name="$1"
  local php_sock; php_sock="$(detect_php_fpm_sock)"
  if [[ -z "$php_sock" ]]; then
    echo "Warning: Could not determine php-fpm sock. Using default /run/php/php-fpm.sock"
    php_sock="/run/php/php-fpm.sock"
  fi
  sudo_run "bash -c 'cat > ${NGINX_SITE} <<NGINX
server {
    listen 80;
    server_name ${server_name};
    root ${PANEL_DIR}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${php_sock};
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|woff2?)$ {
        expires 7d;
        access_log off;
    }
}
NGINX'"
  sudo_run "ln -sf ${NGINX_SITE} ${NGINX_LINK} || true"
  sudo_run "rm -f /etc/nginx/sites-enabled/default || true"
  sudo_run "nginx -t"
  sudo_run "systemctl enable --now nginx"
  sudo_run "systemctl reload nginx"
}

configure_cron_and_queue(){
  # Cron (every minute) — verify guidance: https://pelican.dev/docs/troubleshooting/
  sudo_run "crontab -u www-data -l 2>/dev/null | { cat; echo '* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1'; } | crontab -u www-data -"
  # Queue service via Pelican artisan helper (documented): https://pelican.dev/docs/panel/advanced/artisan/
  pushd "$PANEL_DIR" >/dev/null
  sudo_run "php artisan p:environment:queue-service --service-name=pelican-queue --user=www-data --group=www-data --overwrite -n"
  sudo_run "systemctl daemon-reload"
  sudo_run "systemctl enable --now pelican-queue.service || true"
  popd >/dev/null
}

print_summary(){
  local domain="$1" dbtype="$2" dbname="$3" dbuser="$4"
  echo
  echo "================== Pelican Panel — Installation Summary =================="
  echo " Panel path : ${PANEL_DIR}"
  echo " Domain/IP  : ${domain}"
  echo " Web Setup  : http://${domain}/installer  (run the web installer to complete)"
  echo " NGINX conf : ${NGINX_SITE}"
  echo " Queue svc  : pelican-queue.service (systemd)"
  echo " Cron       : www-data -> * * * * * php ${PANEL_DIR}/artisan schedule:run"
  echo " DB Type    : ${dbtype}"
  if [[ "$dbtype" == "MariaDB" ]]; then
    echo " DB Name    : ${dbname}"
    echo " DB User    : ${dbuser}"
    echo " DB Host    : 127.0.0.1"
    echo " Note       : APP_KEY stored in ${PANEL_DIR}/.env (back it up!)"
  else
    echo " Note       : Using SQLite by default (configure in web installer if needed)."
  fi
  echo " Next steps :"
  echo "   1) Visit the web installer: http://${domain}/installer"
  echo "   2) (Optional) Run SSL module later to enable HTTPS for your domain."
  echo "   3) Install Wings on your node(s) from the main menu."
  echo "=========================================================================="
}

gather_inputs(){
  echo "Pelican Panel — Quick Setup"
  read -rp "Your domain or server IP (e.g., panel.example.com or 1.2.3.4): " DOMAIN
  [[ -z "${DOMAIN:-}" ]] && echo "Domain/IP is required." && exit 1

  local choice
  echo
  echo "Choose database backend:"
  choice=$(choose "Database" "MariaDB (recommended)" "SQLite")
  case "$choice" in
    0) DB_KIND="mariadb" ;;
    1) DB_KIND="sqlite" ;;
    *) DB_KIND="mariadb" ;;
  esac

  if [[ "$DB_KIND" == "mariadb" ]]; then
    read -rp "DB name     [panel]: " DB_NAME; DB_NAME="${DB_NAME:-panel}"
    read -rp "DB user     [pelican]: " DB_USER; DB_USER="${DB_USER:-pelican}"
    # Generate a safe default password if empty
    read -rp "DB password [auto-generate if blank]: " DB_PASS || true
    if [[ -z "${DB_PASS:-}" ]]; then
      DB_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20 || true)"
      [[ -z "$DB_PASS" ]] && DB_PASS="Pelican_${RANDOM}_$(date +%s)"
    fi
  else
    DB_NAME="(sqlite)"; DB_USER="-"; DB_PASS="-"
  fi

  echo
  echo "------- Review -------"
  printf " Domain/IP : %s\n" "$DOMAIN"
  printf " Database  : %s\n" "${DB_KIND^^}"
  if [[ "$DB_KIND" == "mariadb" ]]; then
    printf " DB Name   : %s\n" "$DB_NAME"
    printf " DB User   : %s\n" "$DB_USER"
  fi
  echo "----------------------"
  read -rp "Proceed with installation? [Y/n]: " CONFIRM || true
  [[ "${CONFIRM:-Y}" =~ ^[Yy]$|^$ ]] || { echo "Cancelled."; exit 1; }
}

main(){
  mkdir -p "$WORKDIR"
  : > "$LOG_FILE"
  require_root
  log "Starting Pelican Panel installation"

  gather_inputs
  ensure_packages

  download_panel

  if [[ "$DB_KIND" == "mariadb" ]]; then
    install_mariadb
    create_db "$DB_USER" "$DB_PASS" "$DB_NAME"
    configure_env "mysql" "$DB_NAME" "$DB_USER" "$DB_PASS"
    DB_TYPE_HUMAN="MariaDB"
  else
    configure_env "sqlite" "" "" ""
    DB_TYPE_HUMAN="SQLite"
  fi

  configure_nginx "$DOMAIN"
  configure_cron_and_queue

  print_summary "$DOMAIN" "$DB_TYPE_HUMAN" "$DB_NAME" "$DB_USER" | tee -a "$LOG_FILE"
  log "Done."
}

main "$@"
