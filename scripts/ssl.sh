#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os

prompt_input DOMAIN "Domain to configure SSL for"
prompt_choice SSL_MODE "SSL mode (letsencrypt/custom)" "letsencrypt"

if [[ "$SSL_MODE" == "custom" ]]; then
  CERT_PEM=""; KEY_PEM=""
  echo; echo "Paste FULLCHAIN/CRT (include BEGIN/END), then Ctrl+D:"
  CERT_TMP="$(mktemp)"; cat > "$CERT_TMP"; CERT_PEM="$(cat "$CERT_TMP")"; rm -f "$CERT_TMP"
  echo; echo "Paste PRIVATE KEY (PEM) (include BEGIN/END), then Ctrl+D:"
  KEY_TMP="$(mktemp)"; umask 077; cat > "$KEY_TMP"; umask 022; KEY_PEM="$(cat "$KEY_TMP")"; rm -f "$KEY_TMP"

  CERT_PATH="/etc/ssl/certs/${DOMAIN}.crt"
  KEY_PATH="/etc/ssl/private/${DOMAIN}.key"
  mkdir -p /etc/ssl/certs /etc/ssl/private
  echo "$CERT_PEM" > "$CERT_PATH"
  umask 077; echo "$KEY_PEM" > "$KEY_PATH"; umask 022
  chown root:root "$CERT_PATH" "$KEY_PATH"
  chmod 644 "$CERT_PATH"; chmod 600 "$KEY_PATH"
  echo -e "${GREEN}Saved custom cert to:${NC} $CERT_PATH"
  echo -e "${GREEN}Saved custom key  to:${NC} $KEY_PATH"
  echo "Remember to point your Nginx server block to these files and reload nginx."
else
  apt-get update -y && apt-get install -y certbot python3-certbot-nginx
  read -rp "Admin email for Let's Encrypt: " EMAIL || true
  certbot --nginx -d "${DOMAIN}" --redirect --agree-tos -m "${EMAIL}" --no-eff-email
  systemctl reload nginx || true
fi
