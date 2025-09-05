#!/usr/bin/env bash
set -euo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die

echo "Update options:"
echo " 1) Panel"
echo " 2) Wings"
echo " 3) Both"
read -rp "Choose [1-3]: " opt || true

if [[ "$opt" == "1" || "$opt" == "3" ]]; then
  say_info "Updating Panel (official updater, fallback manual)…"
  bash -c "$(curl -fsSL https://pelican.dev/updatePanel.sh)" || {
    say_warn "Fallback to manual update."
    cd /var/www/pelican || { say_err "/var/www/pelican missing"; exit 1; }
    php artisan down || true
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz
    chmod -R 755 storage/* bootstrap/cache
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_ROOT_VERSION=dev-main composer install --no-dev --optimize-autoloader --prefer-dist
    php artisan storage:link || true
    php artisan optimize:clear && php artisan optimize
    php artisan migrate --seed --force
    chown -R www-data:www-data /var/www/pelican
    php artisan queue:restart || true
    php artisan up
  }
fi

if [[ "$opt" == "2" || "$opt" == "3" ]]; then
  say_info "Updating Wings…"
  systemctl stop wings || true
  ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
  chmod u+x /usr/local/bin/wings
  systemctl enable --now wings
fi

say_ok "Update complete."
