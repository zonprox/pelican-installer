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
install_base

: "${SSL_TARGET:?missing}"; : "${SSL_MODE:=letsencrypt}"

if [[ "$SSL_TARGET" == "panel" ]]; then
  : "${DOMAIN:?missing}"
  if [[ "$SSL_MODE" == "letsencrypt" ]]; then
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "admin@${DOMAIN}" --no-eff-email || say_warn "Certbot failed."
    systemctl reload nginx || true
  else
    : "${CERT_PEM_B64:?missing}"; : "${KEY_PEM_B64:?missing}"
    CERT="/etc/ssl/certs/${DOMAIN}.crt"; KEY="/etc/ssl/private/${DOMAIN}.key"
    base64 -d <<<"$CERT_PEM_B64" > "$CERT"
    umask 077; base64 -d <<<"$KEY_PEM_B64" > "$KEY"; umask 022
    chmod 644 "$CERT"; chmod 600 "$KEY"
    say_ok "Saved custom SSL for Panel → $CERT / $KEY"
  fi
else
  : "${WINGS_HOSTNAME:?missing}"
  CERT="/etc/ssl/pelican/${WINGS_HOSTNAME}.crt"; KEY="/etc/ssl/pelican/${WINGS_HOSTNAME}.key"
  mkdir -p /etc/ssl/pelican
  if [[ "$SSL_MODE" == "letsencrypt" ]]; then
    apt-get install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot failed."
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "${CERT}"
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"   "${KEY}"
  else
    : "${WINGS_CERT_PEM_B64:?missing}"; : "${WINGS_KEY_PEM_B64:?missing}"
    base64 -d <<<"$WINGS_CERT_PEM_B64" > "$CERT"
    umask 077; base64 -d <<<"$WINGS_KEY_PEM_B64" > "$KEY"; umask 022
    chmod 644 "$CERT"; chmod 600 "$KEY"
  fi
  systemctl restart wings || true
  say_ok "Wings SSL ready → ${CERT} / ${KEY}"
fi
