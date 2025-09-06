#!/usr/bin/env bash
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base

say_info "Update Panel (composer install + cache clear)…"
if [[ -d /var/www/pelican ]]; then
  cd /var/www/pelican
  composer install --no-interaction --prefer-dist --optimize-autoloader
  php artisan optimize:clear || true
  systemctl restart php8.4-fpm || true
  systemctl restart pelican-queue || true
  systemctl reload nginx || true
  say_ok "Panel updated."
else
  say_warn "/var/www/pelican not found; skip panel."
fi

say_info "Update Wings (binary latest)…"
if command -v wings >/dev/null 2>&1; then
  ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
  chmod u+x /usr/local/bin/wings
  systemctl restart wings || true
  say_ok "Wings updated."
else
  say_warn "Wings not found; skip."
fi
