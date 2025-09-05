#!/usr/bin/env bash
set -euo pipefail

# Bootstrap common.sh even if the script is run standalone
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"

COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
if [[ ! -f "${COMMON_LOCAL}" ]]; then
  mkdir -p "${PEL_CACHE_DIR}"
  # Use conditional fetch if already exists (first run it doesn't)
  curl -fsSL -o "${COMMON_LOCAL}.tmp" "${PEL_RAW_BASE}/common.sh"
  mv -f "${COMMON_LOCAL}.tmp" "${COMMON_LOCAL}"
fi
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base

echo "SSL helper — issue Let's Encrypt or save custom PEM."
prompt_choice TARGET "Apply to which service? (panel/wings)" "panel"

if [[ "$TARGET" == "panel" ]]; then
  prompt DOMAIN "Panel domain (e.g. panel.example.com)"
  prompt_choice MODE "SSL mode (letsencrypt/custom)" "letsencrypt"
  if [[ "$MODE" == "letsencrypt" ]]; then
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "admin@${DOMAIN}" --no-eff-email || say_warn "Certbot failed."
    systemctl reload nginx || true
  else
    CERT="/etc/ssl/certs/${DOMAIN}.crt"; KEY="/etc/ssl/private/${DOMAIN}.key"
    echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; CERT_PEM="$(cat)"
    echo "Paste PRIVATE KEY (PEM) for ${DOMAIN}, then Ctrl+D:"; umask 077; KEY_PEM="$(cat)"; umask 022
    mkdir -p /etc/ssl/certs /etc/ssl/private
    echo "$CERT_PEM" > "$CERT"; echo "$KEY_PEM" > "$KEY"
    chmod 644 "$CERT"; chmod 600 "$KEY"
    say_ok "Saved $CERT and $KEY — ensure your Nginx vhost points to them."
  fi
else
  prompt HOST "Wings hostname (e.g. wings01.example.com)"
  prompt_choice MODE "SSL mode (letsencrypt/custom)" "letsencrypt"
  mkdir -p /etc/ssl/pelican
  CERT="/etc/ssl/pelican/${HOST}.crt"; KEY="/etc/ssl/pelican/${HOST}.key"
  if [[ "$MODE" == "letsencrypt" ]]; then
    apt-get install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${HOST}" --agree-tos -m "admin@${HOST}" --non-interactive || say_warn "Certbot failed."
    ln -sf "/etc/letsencrypt/live/${HOST}/fullchain.pem" "${CERT}"
    ln -sf "/etc/letsencrypt/live/${HOST}/privkey.pem"   "${KEY}"
  else
    echo "Paste FULLCHAIN/CRT for ${HOST}, then Ctrl+D:"; CERT_PEM="$(cat)"
    echo "Paste PRIVATE KEY (PEM), then Ctrl+D:";         umask 077; KEY_PEM="$(cat)"; umask 022
    echo "$CERT_PEM" > "$CERT"; echo "$KEY_PEM" > "$KEY"
    chmod 644 "$CERT"; chmod 600 "$KEY"
  fi
  systemctl restart wings || true
  say_ok "Wings SSL ready → ${CERT} / ${KEY}"
fi
