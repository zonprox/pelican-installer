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

: "${SSL_TARGET:?missing target}"  # panel|wings

if [[ "$SSL_TARGET" == "panel" ]]; then
  : "${SSL_MODE:=letsencrypt}"; : "${DOMAIN:?missing domain}"
  if [[ "$SSL_MODE" == "letsencrypt" ]]; then
    ensure_pkg certbot; ensure_pkg python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "admin@${DOMAIN}" --no-eff-email || say_warn "Certbot failed."
    systemctl reload nginx || true
  else
    : "${CERT_PEM_B64:?}"; : "${KEY_PEM_B64:?}"
    CERT="/etc/ssl/certs/${DOMAIN}.crt"; KEY="/etc/ssl/private/${DOMAIN}.key"
    base64 -d <<<"$CERT_PEM_B64" > "$CERT"
    umask 077; base64 -d <<<"$KEY_PEM_B64" > "$KEY"; umask 022
    chmod 644 "$CERT"; chmod 600 "$KEY"
    say_ok "Installed custom Panel SSL → $CERT / $KEY"
  fi
  exit 0
fi

# Wings
: "${SSL_ACTION:=issue}"  # issue|install|fix
case "$SSL_ACTION" in
  issue)
    : "${WINGS_HOSTNAME:?missing hostname}"
    ensure_pkg certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot failed."
    say_ok "LE issued for ${WINGS_HOSTNAME}."
    ;;
  install)
    : "${WINGS_CN:?missing CN}"; : "${WINGS_CERT_PEM_B64:?}"; : "${WINGS_KEY_PEM_B64:?}"
    mkdir -p /etc/ssl/pelican
    CERT="/etc/ssl/pelican/$(echo "${WINGS_CN}" | tr ':./' '___').crt"
    KEY="/etc/ssl/pelican/$(echo "${WINGS_CN}" | tr ':./' '___').key"
    base64 -d <<<"$WINGS_CERT_PEM_B64" > "$CERT"
    umask 077; base64 -d <<<"$WINGS_KEY_PEM_B64" > "$KEY"; umask 022
    chmod 644 "$CERT"; chmod 600 "$KEY"
    say_ok "Installed custom Wings cert → $CERT / $KEY"
    ;;
  fix)
    CFG="/etc/pelican/config.yml"
    : "${WINGS_CERT_PATH:?missing cert path}"; : "${WINGS_KEY_PATH:?missing key path}"
    [[ -f "$CFG" ]] || { say_err "Wings config not found: $CFG"; exit 1; }
    patch_wings_ssl_file "$CFG" "true" "$WINGS_CERT_PATH" "$WINGS_KEY_PATH"
    systemctl restart wings || (journalctl -u wings --no-pager -n 100; exit 1)
    say_ok "Patched Wings config to custom cert."
    ;;
  *) say_err "Invalid SSL_ACTION"; exit 1 ;;
esac
