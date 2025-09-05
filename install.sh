#!/usr/bin/env bash
set -euo pipefail

# ===== Repo coordinates =====
OWNER="zonprox"
REPO="pelican-installer"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/scripts"

# ===== Cache & exports (for child scripts) =====
CACHE_DIR="/var/cache/pelican-installer"
mkdir -p "${CACHE_DIR}"
export PEL_CACHE_DIR="${CACHE_DIR}"
export PEL_RAW_BASE="${RAW_BASE}"

# ===== Tiny utils =====
blue='\033[0;34m'; yellow='\033[1;33m'; red='\033[0;31m'; green='\033[0;32m'; nc='\033[0m'
say(){   printf "${blue}[INFO]${nc} %s\n" "$*"; }
warn(){  printf "${yellow}[WARN]${nc} %s\n" "$*"; }
err(){   printf "${red}[ERR ]${nc} %s\n" "$*\n" >&2; }
ok(){    printf "${green}[OK  ]${nc} %s\n" "$*"; }
as_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

fetch_cached() {
  # $1 = remote file under scripts/, put to cache and chmod +x
  local name="$1"
  local url="${PEL_RAW_BASE}/${name}"
  local dest="${PEL_CACHE_DIR}/${name}"
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL -z "${dest}" -o "${dest}.tmp" "${url}"; then
    [[ -s "${dest}.tmp" ]] && mv -f "${dest}.tmp" "${dest}"
    chmod +x "${dest}" 2>/dev/null || true
    echo "${dest}"
  else
    rm -f "${dest}.tmp"
    err "Failed to fetch ${url}"
    exit 1
  fi
}

ensure_common(){ fetch_cached "common.sh" >/dev/null; }

detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }

# Base64 helpers (for multi-line PEM)
b64_read_file_to_var(){
  # read stdin to temp, base64 it, export to VAR name
  # usage: b64_read_file_to_var VAR_NAME
  local var="$1" tmp; tmp="$(mktemp)"
  cat > "$tmp"
  local val; val="$(base64 -w0 "$tmp")"
  rm -f "$tmp"
  export "$var"="$val"
}
mask(){ local s="$1"; local n=${#s}; ((n<=4)) && { printf '****'; return; }; printf '%s' "$(printf '%*s' "$((n-4))" '' | tr ' ' '*')${s: -4}"; }

# ===== Wizards (config-first) =====

wizard_panel(){
  echo
  echo "── Panel — Configuration Wizard ─────────────────────────"
  read -rp "Panel domain (e.g. panel.example.com): " DOMAIN
  ADMIN_EMAIL_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin email for Let's Encrypt / contact [${ADMIN_EMAIL_DEFAULT}]: " ADMIN_EMAIL
  ADMIN_EMAIL="${ADMIN_EMAIL:-$ADMIN_EMAIL_DEFAULT}"

  read -rp "Database engine: MariaDB or SQLite? (M/s) [M]: " DBC; DBC="${DBC:-M}"
  if [[ "$DBC" =~ ^[Ss]$ ]]; then
    export DB_ENGINE="sqlite"
  else
    export DB_ENGINE="mariadb"
    read -rp "DB name [pelicanpanel]: " DB_NAME;  DB_NAME="${DB_NAME:-pelicanpanel}"
    read -rp "DB user [pelican]: " DB_USER;       DB_USER="${DB_USER:-pelican}"
    read -rp "DB password (blank = auto-generate): " DB_PASS; DB_PASS="${DB_PASS:-}"
  fi

  read -rp "Admin username [admin]: " ADMIN_USERNAME; ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  ADMIN_EMAILLOGIN_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin login email [${ADMIN_EMAILLOGIN_DEFAULT}]: " ADMIN_EMAILLOGIN
  ADMIN_EMAILLOGIN="${ADMIN_EMAILLOGIN:-$ADMIN_EMAILLOGIN_DEFAULT}"
  read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

  read -rp "Configure SMTP now? (y/N): " SMTP_YN; SMTP_YN="${SMTP_YN:-N}"
  if [[ "$SMTP_YN" =~ ^[Yy]$ ]]; then
    export SETUP_SMTP="y"
    read -rp "SMTP FROM name [Pelican Panel]: " SMTP_FROM_NAME; SMTP_FROM_NAME="${SMTP_FROM_NAME:-Pelican Panel}"
    read -rp "SMTP FROM email [noreply@${DOMAIN}]: " SMTP_FROM_EMAIL; SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-noreply@${DOMAIN}}"
    read -rp "SMTP host: " SMTP_HOST
    read -rp "SMTP port [587]: " SMTP_PORT; SMTP_PORT="${SMTP_PORT:-587}"
    read -rp "SMTP username: " SMTP_USER
    read -rp "SMTP password: " SMTP_PASS
    read -rp "SMTP encryption (tls/ssl/none) [tls]: " SMTP_ENC; SMTP_ENC="${SMTP_ENC:-tls}"
  else
    export SETUP_SMTP="n"
  fi

  read -rp "SSL mode (letsencrypt/custom) [letsencrypt]: " SSL_MODE; SSL_MODE="${SSL_MODE:-letsencrypt}"
  CERT_PEM_B64=""; KEY_PEM_B64=""
  if [[ "$SSL_MODE" == "custom" ]]; then
    echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"
    b64_read_file_to_var CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN} (include BEGIN/END), then Ctrl+D:"
    b64_read_file_to_var KEY_PEM_B64
  fi

  read -rp "Use Cloudflare API (proxied A record + Real-IP include)? (y/N): " CF_YN; CF_YN="${CF_YN:-N}"
  if [[ "$CF_YN" =~ ^[Yy]$ ]]; then
    export CF_ENABLE="y"
    read -rp "Cloudflare auth method (token/global) [token]: " CF_AUTH
    CF_AUTH="${CF_AUTH:-token}"

    if [[ "$CF_AUTH" == "global" ]]; then
      read -rp "Cloudflare Account Email: " CF_API_EMAIL
      read -rp "Cloudflare Global API Key: " CF_GLOBAL_API_KEY
      CF_API_EMAIL="${CF_API_EMAIL//[$'\r\n\t ']}"
      CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY//[$'\r\n\t ']}"
      CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY%\"}"; CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY#\"}"
      CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY%\'}"; CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY#\'}"
    else
      read -rp "Cloudflare API Token (Zone DNS Edit): " CF_API_TOKEN
      CF_API_TOKEN="${CF_API_TOKEN#Bearer }"
      CF_API_TOKEN="${CF_API_TOKEN//[$'\r\n\t ']}"
      CF_API_TOKEN="${CF_API_TOKEN%\"}"; CF_API_TOKEN="${CF_API_TOKEN#\"}"
      CF_API_TOKEN="${CF_API_TOKEN%\'}"; CF_API_TOKEN="${CF_API_TOKEN#\'}"
    fi

    read -rp "Cloudflare Zone ID: " CF_ZONE_ID
    read -rp "DNS record name [${DOMAIN}]: " CF_DNS_NAME; CF_DNS_NAME="${CF_DNS_NAME:-$DOMAIN}"
    CF_RECORD_IP="$(detect_public_ip)"
    read -rp "Server public IP for A record [${CF_RECORD_IP}]: " CF_RECORD_IP_IN; CF_RECORD_IP="${CF_RECORD_IP_IN:-$CF_RECORD_IP}"

    CF_ZONE_ID="${CF_ZONE_ID//[$'\r\n\t ']}"
    CF_DNS_NAME="${CF_DNS_NAME//[$'\r\n\t ']}"

    # Preflight (warn-only)
    if [[ "$CF_AUTH" == "global" ]]; then
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "X-Auth-Email: ${CF_API_EMAIL}" -H "X-Auth-Key: ${CF_GLOBAL_API_KEY}" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}")"
    else
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}")"
    fi
    if [[ "$http_code" != "200" ]]; then
      warn "Cloudflare preflight failed (HTTP $http_code). Re-check credentials & Zone ID (auth=${CF_AUTH})."
    fi
  else
    export CF_ENABLE="n"
  fi

  read -rp "Install directory [/var/www/pelican]: " INSTALL_DIR; INSTALL_DIR="${INSTALL_DIR:-/var/www/pelican}"
  read -rp "Nginx vhost path [/etc/nginx/sites-available/pelican.conf]: " NGINX_CONF; NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"

  # Review
  echo
  echo "──────────────── Configuration Review (Panel) ───────────"
  echo "Domain:                 $DOMAIN"
  echo "Admin contact:          ${ADMIN_EMAIL}"
  echo "Install dir:            ${INSTALL_DIR}"
  echo "Nginx vhost:            ${NGINX_CONF}"
  echo "DB engine:              ${DB_ENGINE}"
  if [[ "${DB_ENGINE}" == "mariadb" ]]; then
    echo "  - DB name/user:       ${DB_NAME} / ${DB_USER}"
    echo "  - DB password:        $( [[ -n "${DB_PASS:-}" ]] && echo "$(mask "$DB_PASS")" || echo '(auto-generate)' )"
  else
    echo "  - SQLite file:        ${INSTALL_DIR}/database/database.sqlite"
  fi
  echo "Admin account:          ${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN} / $( [[ -n "${ADMIN_PASSWORD}" ]] && echo "$(mask "$ADMIN_PASSWORD")" || echo "(auto-generate)" )"
  echo "SMTP configure:         $( [[ "$SETUP_SMTP" == "y" ]] && echo Yes || echo No )"
  echo "SSL mode:               ${SSL_MODE}"
  [[ "$SSL_MODE" == "custom" ]] && echo "  - Custom PEM:         (pasted; stored as base64 in-memory)"
  echo "Cloudflare:             $( [[ "$CF_ENABLE" == "y" ]] && echo Enabled || echo Disabled )"
  [[ "$CF_ENABLE" == "y" ]] && echo "  - Auth:               ${CF_AUTH}"
  [[ "$CF_ENABLE" == "y" ]] && echo "  - DNS name/ip:        ${CF_DNS_NAME} / ${CF_RECORD_IP}"
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed with installation? (Y/n): " ok; ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  # Export ENV for the non-interactive script
  export DOMAIN ADMIN_EMAIL INSTALL_DIR NGINX_CONF SSL_MODE
  export ADMIN_USERNAME ADMIN_EMAILLOGIN
  export DB_ENGINE DB_NAME DB_USER DB_PASS
  export ADMIN_PASSWORD
  export CERT_PEM_B64 KEY_PEM_B64
  export CF_ENABLE CF_AUTH CF_API_TOKEN CF_API_EMAIL CF_GLOBAL_API_KEY CF_ZONE_ID CF_DNS_NAME CF_RECORD_IP
  export SETUP_SMTP SMTP_FROM_NAME SMTP_FROM_EMAIL SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_ENC

  ensure_common
  bash "$(fetch_cached install_panel.sh)"
}

wizard_wings(){
  echo
  echo "── Wings — Configuration Wizard ─────────────────────────"
  read -rp "Panel URL (e.g. https://panel.example.com): " PANEL_URL
  HN_DEFAULT="$(hostname -f 2>/dev/null || echo wings.local)"
  read -rp "Wings hostname [${HN_DEFAULT}]: " WINGS_HOSTNAME; WINGS_HOSTNAME="${WINGS_HOSTNAME:-$HN_DEFAULT}"
  read -rp "Wings SSL (letsencrypt/custom/none) [letsencrypt]: " WINGS_SSL; WINGS_SSL="${WINGS_SSL:-letsencrypt}"

  WINGS_CERT_PEM_B64=""; WINGS_KEY_PEM_B64=""
  if [[ "$WINGS_SSL" == "custom" ]]; then
    echo; echo "Paste FULLCHAIN/CRT for ${WINGS_HOSTNAME}, then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:";                 b64_read_file_to_var WINGS_KEY_PEM_B64
  fi

  echo
  echo "──────────────── Configuration Review (Wings) ───────────"
  echo "Panel URL:             ${PANEL_URL}"
  echo "Wings hostname:        ${WINGS_HOSTNAME}"
  echo "Wings SSL:             ${WINGS_SSL}"
  [[ "$WINGS_SSL" == "custom" ]] && echo "  - Custom PEM:        (pasted; stored as base64 in-memory)"
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed with installation? (Y/n): " ok; ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export PANEL_URL WINGS_HOSTNAME WINGS_SSL WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64
  ensure_common
  bash "$(fetch_cached install_wings.sh)"
}

wizard_both(){
  say "You will configure Panel first, then Wings."
  wizard_panel
  echo
  say "Panel done. Proceed to Wings configuration..."
  wizard_wings
}

wizard_ssl(){
  echo
  echo "── SSL Utility — Apply for panel or wings ───────────────"
  read -rp "Target (panel/wings) [panel]: " TARGET; TARGET="${TARGET:-panel}"
  if [[ "$TARGET" == "panel" ]]; then
    read -rp "Panel domain (e.g. panel.example.com): " DOMAIN
    read -rp "SSL mode (letsencrypt/custom) [letsencrypt]: " MODE; MODE="${MODE:-letsencrypt}"
    if [[ "$MODE" == "custom" ]]; then
      echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var CERT_PEM_B64
      echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var KEY_PEM_B64
    fi
    export SSL_TARGET="panel" SSL_MODE="$MODE" DOMAIN CERT_PEM_B64 KEY_PEM_B64
  else
    read -rp "Wings hostname: " WINGS_HOSTNAME
    read -rp "SSL mode (letsencrypt/custom) [letsencrypt]: " MODE; MODE="${MODE:-letsencrypt}"
    if [[ "$MODE" == "custom" ]]; then
      echo; echo "Paste FULLCHAIN/CRT for ${WINGS_HOSTNAME}, then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
      echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:"; b64_read_file_to_var WINGS_KEY_PEM_B64
    fi
    export SSL_TARGET="wings" SSL_MODE="$MODE" WINGS_HOSTNAME WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64
  fi
  ensure_common
  bash "$(fetch_cached install_ssl.sh)"
}

wizard_update(){ ensure_common; bash "$(fetch_cached update.sh)"; }
wizard_uninstall(){ ensure_common; bash "$(fetch_cached uninstall.sh)"; }

# ===== Main menu =====
as_root
say "Pelican Installer — quick loader (config-first)."
while :; do
cat <<'MENU'

────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings (with SSL options)
 3) Install Both (Panel then Wings)
 4) SSL Only (issue Let's Encrypt or use custom PEM)
 5) Update (Panel and/or Wings)
 6) Uninstall (Panel and/or Wings)
 7) Quit
MENU
  read -rp "Choose an option [1-7]: " choice || true
  case "${choice:-}" in
    1) wizard_panel ;;
    2) wizard_wings ;;
    3) wizard_both ;;
    4) wizard_ssl ;;
    5) wizard_update ;;
    6) wizard_uninstall ;;
    7) exit 0 ;;
    *) warn "Invalid choice." ;;
  esac
done
