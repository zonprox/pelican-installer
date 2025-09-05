#!/usr/bin/env bash
set -euo pipefail
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON="${PEL_CACHE_DIR}/common.sh"; [[ -f "$COMMON" ]] || { mkdir -p "$PEL_CACHE_DIR"; curl -fsSL -o "$COMMON" "${PEL_RAW_BASE}/common.sh"; }
. "$COMMON"

require_root
detect_os_or_die
install_base

choice TARGET "Apply to which service? (panel/wings)" "panel"
if [[ "$TARGET" == "panel" ]]; then
  prompt DOMAIN "Panel domain"
  choice MODE "SSL mode (letsencrypt/custom)" "letsencrypt"
  if [[ "$MODE" == "letsencrypt" ]]; then
    certbot_issue_nginx "$DOMAIN" "admin@${DOMAIN}"
  else
    echo "Paste FULLCHAIN/CRT, then Ctrl+D:"; CERT="$(cat)"
    echo "Paste PRIVATE KEY, then Ctrl+D:";  umask 077; KEY="$(cat)"; umask 022
    save_custom_cert "$DOMAIN" "$CERT" "$KEY" >/dev/null
    say_ok "Saved custom cert to /etc/ssl/certs/${DOMAIN}.crt and key to /etc/ssl/private/${DOMAIN}.key"
  fi
else
  prompt HOST "Wings hostname"
  choice MODE "SSL mode (letsencrypt/custom)" "letsencrypt"
  mkdir -p /etc/ssl/pelican
  CERT="/etc/ssl/pelican/${HOST}.crt"; KEY="/etc/ssl/pelican/${HOST}.key"
  if [[ "$MODE" == "letsencrypt" ]]; then
    apt-get install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${HOST}" --agree-tos -m "admin@${HOST}" --non-interactive || say_warn "Certbot failed."
    ln -sf "/etc/letsencrypt/live/${HOST}/fullchain.pem" "${CERT}"
    ln -sf "/etc/letsencrypt/live/${HOST}/privkey.pem"   "${KEY}"
  else
    echo "Paste FULLCHAIN/CRT, then Ctrl+D:"; CERT_PEM="$(cat)"
    echo "Paste PRIVATE KEY, then Ctrl+D:";  umask 077; KEY_PEM="$(cat)"; umask 022
    echo "$CERT_PEM" > "$CERT"; echo "$KEY_PEM" > "$KEY"; chmod 644 "$CERT"; chmod 600 "$KEY"
  fi
  systemctl restart wings || true
  say_ok "Wings SSL ready → ${CERT} / ${KEY}"
fi
