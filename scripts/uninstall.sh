#!/usr/bin/env bash
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
. "${COMMON_LOCAL}"

require_root

say_info "Stopping services…"
systemctl disable --now pelican-queue 2>/dev/null || true
systemctl disable --now wings 2>/dev/null || true

say_info "Removing systemd units…"
rm -f /etc/systemd/system/pelican-queue.service
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload || true

say_info "Removing Nginx vhost (if any)…"
rm -f /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
nginx -t && systemctl reload nginx || true

say_info "Removing application files…"
rm -rf /var/www/pelican /etc/pelican /var/lib/pelican 2>/dev/null || true

say_info "Keeping shared components (MariaDB/Redis/PHP/Nginx/Docker) to avoid breaking other apps."
say_ok "Uninstall completed."
