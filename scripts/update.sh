#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os

prompt_input INSTALL_DIR "Panel install directory" "/var/www/pelican"
cd "$INSTALL_DIR"

log "Fetching latest release and updating vendor…"
TMPDIR="$(mktemp -d)"
curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xz -C "$TMPDIR"
rsync -a --delete --exclude='.env' --exclude='storage/' --exclude='vendor/' "$TMPDIR"/. "$INSTALL_DIR"/
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan migrate --force
php artisan view:clear && php artisan cache:clear

systemctl reload nginx || true
systemctl restart pelican-queue || true

echo -e "${GREEN}Panel updated successfully.${NC}"
