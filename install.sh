#!/usr/bin/env bash
# Pelican Installer - Smart, Lightweight, Self-healing
set -Eeuo pipefail

LOG_FILE="/var/log/pelican-installer.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

OWNER="${OWNER:-zonprox}"
REPO="${REPO:-pelican-installer}"
BRANCH="${BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/scripts"

CACHE_DIR="/var/cache/pelican-installer"
mkdir -p "$CACHE_DIR"
export PEL_CACHE_DIR="$CACHE_DIR"
export PEL_RAW_BASE="$RAW_BASE"

blue='\033[0;34m'; yellow='\033[1;33m'; red='\033[0;31m'; green='\033[0;32m'; nc='\033[0m'
say(){   printf "${blue}[INFO]${nc} %s\n" "$*"; }
warn(){  printf "${yellow}[WARN]${nc} %s\n" "$*"; }
err(){   printf "${red}[ERR ]${nc} %s\n" "$*"; }
ok(){    printf "${green}[OK  ]${nc} %s\n" "$*"; }

as_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

fetch_cached() {
  local fname="${1:-}"; [[ -n "$fname" ]] || { err "fetch_cached: missing filename argument"; exit 1; }
  local url="${PEL_RAW_BASE}/${fname}"
  local dest="${PEL_CACHE_DIR}/${fname}"
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL -z "$dest" -o "${dest}.tmp" "$url"; then
    [[ -s "${dest}.tmp" ]] && mv -f "${dest}.tmp" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    echo "$dest"
  else
    rm -f "${dest}.tmp"
    err "Failed to fetch $url"
    exit 1
  fi
}

ensure_common(){ fetch_cached "common.sh" >/dev/null; . "${PEL_CACHE_DIR}/common.sh"; }

read_multiline_b64() {
  local _var="${1:-}" _tmp _val
  [[ -n "$_var" ]] || { err "read_multiline_b64: missing variable name"; exit 1; }
  _tmp="$(mktemp)"; cat >"$_tmp"
  _val="$(base64 -w0 "$_tmp")"
  rm -f "$_tmp"
  printf -v "$_var" '%s' "$_val"; export "$_var"
}

derive_base_domain() {
  # Simple heuristic: drop the left-most label (panel.example.com -> example.com)
  # Fallback to original if no dot.
  local d="$1"
  if [[ "$d" == *.* ]]; then
    echo "${d#*.}"
  else
    echo "$d"
  fi
}

trap 'last=$BASH_COMMAND; err "Failed at: ${last}"; echo "See $LOG_FILE"; exit 1' ERR

# ========== Wizards ==========

wizard_panel(){
  clear; echo "── Panel — Configuration Wizard"; echo
  read -rp "Panel domain (e.g. panel.example.com): " DOMAIN

  # Admin login first (email suggestion uses base-domain)
  local BASE_D; BASE_D="$(derive_base_domain "$DOMAIN")"
  local ADMIN_EMAIL_SUGGEST="admin@${BASE_D}"
  read -rp "Admin username [admin]: " ADMIN_USERNAME; ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  read -rp "Admin email [${ADMIN_EMAIL_SUGGEST}]: " ADMIN_EMAILLOGIN; ADMIN_EMAILLOGIN="${ADMIN_EMAILLOGIN:-$ADMIN_EMAIL_SUGGEST}"
  read -rp "Admin password (blank=auto): " ADMIN_PASSWORD; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

  echo; echo "Database engine:"
  echo "  1) MariaDB (recommended)"
  echo "  2) SQLite"
  read -rp "Choose [1-2] (default 1): " DBC; DBC="${DBC:-1}"
  if [[ "$DBC" == "2" ]]; then
    DB_ENGINE="sqlite"
  else
    DB_ENGINE="mariadb"
    read -rp "DB name [pelicanpanel]: " DB_NAME;  DB_NAME="${DB_NAME:-pelicanpanel}"
    read -rp "DB user [pelican]: " DB_USER;       DB_USER="${DB_USER:-pelican}"
    read -rp "DB password (blank=auto): " DB_PASS; DB_PASS="${DB_PASS:-}"
  fi

  echo; echo "SSL for Panel:"
  echo "  1) Let's Encrypt (auto)"
  echo "  2) Custom PEM (paste FULLCHAIN/CRT & KEY)"
  read -rp "Choose [1-2] (default 1): " SSL_OPT; SSL_OPT="${SSL_OPT:-1}"
  if [[ "$SSL_OPT" == "2" ]]; then
    SSL_MODE="custom"
    echo; echo "Paste FULLCHAIN/CRT (end with Ctrl+D):"; read_multiline_b64 CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (end with Ctrl+D):";  read_multiline_b64 KEY_PEM_B64
    ADMIN_EMAIL=""  # not needed for custom SSL
  else
    SSL_MODE="letsencrypt"
    # Only ask for LE email now, with base-domain hint (no 'panel.')
    local LE_MAIL_SUGGEST="admin@${BASE_D}"
    read -rp "Email for Let's Encrypt [${LE_MAIL_SUGGEST}]: " ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-$LE_MAIL_SUGGEST}"
  fi

  echo; echo "Optional: Configure Cloudflare DNS?"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "Choose [1-2] (default 2): " CF_OPT; CF_OPT="${CF_OPT:-2}"
  if [[ "$CF_OPT" == "1" ]]; then
    CF_ENABLE="y"
    echo "Auth method:"; echo "  1) API Token"; echo "  2) Global API Key"
    read -rp "Choose [1-2] (default 1): " A; A="${A:-1}"
    if [[ "$A" == "2" ]]; then
      CF_AUTH="global"; read -rp "Cloudflare Account Email: " CF_API_EMAIL; read -rp "Global API Key: " CF_GLOBAL_API_KEY
    else
      CF_AUTH="token"; read -rp "API Token (Zone.DNS): " CF_API_TOKEN
    fi
    read -rp "Zone ID: " CF_ZONE_ID
    read -rp "DNS name [${DOMAIN}]: " CF_DNS_NAME; CF_DNS_NAME="${CF_DNS_NAME:-$DOMAIN}"
    CF_RECORD_IP="$(curl -s https://api.ipify.org || echo 0.0.0.0)"
    read -rp "Server public IP [${CF_RECORD_IP}]: " x; CF_RECORD_IP="${x:-$CF_RECORD_IP}"
  else
    CF_ENABLE="n"
  fi

  read -rp "Install directory [/var/www/pelican]: " INSTALL_DIR; INSTALL_DIR="${INSTALL_DIR:-/var/www/pelican}"
  read -rp "Nginx vhost path [/etc/nginx/sites-available/pelican.conf]: " NGINX_CONF; NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"

  echo; echo "── Review (Panel) ──────────────────────────────────────"
  echo "Domain:   $DOMAIN (https://$DOMAIN/)"
  echo "Admin:    $ADMIN_USERNAME / $ADMIN_EMAILLOGIN"
  echo "DB:       $DB_ENGINE"
  echo "SSL:      $SSL_MODE"
  [[ "$SSL_MODE" == "letsencrypt" ]] && echo "LE Mail:  ${ADMIN_EMAIL}"
  echo "Install:  $INSTALL_DIR"
  echo "VHost:    $NGINX_CONF"
  echo "CF DNS:   $([[ $CF_ENABLE == y ]] && echo enabled || echo disabled)"
  read -rp "Proceed? (Y/n): " okc; okc="${okc:-Y}"; [[ "$okc" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export DOMAIN ADMIN_EMAIL INSTALL_DIR NGINX_CONF SSL_MODE CERT_PEM_B64 KEY_PEM_B64
  export DB_ENGINE DB_NAME DB_USER DB_PASS ADMIN_USERNAME ADMIN_EMAILLOGIN ADMIN_PASSWORD
  export CF_ENABLE CF_AUTH CF_API_TOKEN CF_API_EMAIL CF_GLOBAL_API_KEY CF_ZONE_ID CF_DNS_NAME CF_RECORD_IP

  ensure_common; bash "$(fetch_cached install_panel.sh)"
}

wizard_wings(){
  clear; echo "── Wings — Configuration Wizard"; echo
  ensure_common
  local PANEL_URL=""
  if panel_detect; then
    echo "Detected Panel: ${PANEL_URL_DETECTED}"
    PANEL_URL="$PANEL_URL_DETECTED"
  fi
  read -rp "Panel URL [${PANEL_URL:-https://panel.example.com}]: " z; PANEL_URL="${z:-${PANEL_URL:-https://panel.example.com}}"

  echo; echo "Endpoint type:"; echo "  1) Domain name (recommended)"; echo "  2) IP address"
  read -rp "Choose [1-2] (default 1): " E; E="${E:-1}"
  if [[ "$E" == "2" ]]; then
    WINGS_ENDPOINT="ip"; read -rp "Wings IP: " WINGS_IP; WINGS_HOSTNAME=""
  else
    WINGS_ENDPOINT="domain"; read -rp "Wings hostname (FQDN): " WINGS_HOSTNAME; WINGS_IP=""
  fi

  echo; echo "SSL for Wings:"; echo "  1) Let's Encrypt (domain only)"; echo "  2) Custom PEM"; echo "  3) None"
  while :; do
    read -rp "Choose [1-3] (default 1): " S; S="${S:-1}"
    case "$S" in
      1) [[ "$WINGS_ENDPOINT" == "ip" ]] && { warn "Let's Encrypt cannot issue for IP."; continue; }; WINGS_SSL="letsencrypt"; break ;;
      2) WINGS_SSL="custom"; break ;;
      3) WINGS_SSL="none"; break ;;
      *) continue ;;
    esac
  done
  if [[ "$WINGS_SSL" == "custom" ]]; then
    local CN; CN="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
    echo; echo "Paste FULLCHAIN/CRT for ${CN} (end Ctrl+D):"; read_multiline_b64 WINGS_CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (end Ctrl+D):";          read_multiline_b64 WINGS_KEY_PEM_B64
  fi

  echo; echo "── Review (Wings) ─────────────────────────────────────"
  echo "Panel:    $PANEL_URL"
  echo "Endpoint: $([[ "$WINGS_ENDPOINT" == domain ]] && echo "$WINGS_HOSTNAME (domain)" || echo "$WINGS_IP (ip)")"
  echo "SSL:      $WINGS_SSL"
  read -rp "Proceed? (Y/n): " okc; okc="${okc:-Y}"; [[ "$okc" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export PANEL_URL WINGS_ENDPOINT WINGS_HOSTNAME WINGS_IP WINGS_SSL WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64
  ensure_common; bash "$(fetch_cached install_wings.sh)"
}

wizard_both(){ wizard_panel; echo; wizard_wings; }

wizard_ssl(){
  clear; echo "── SSL Utility"; echo "Target:"; echo "  1) Panel"; echo "  2) Wings"
  read -rp "Choose [1-2] (default 1): " T; T="${T:-1}"
  if [[ "$T" == "2" ]]; then
    echo "Action:"; echo "  1) Issue Let's Encrypt for Wings (domain)"; echo "  2) Install custom PEM for Wings"; echo "  3) Fix Wings config.yml to use custom cert"
    read -rp "Choose [1-3] (default 1): " A; A="${A:-1}"
    case "$A" in
      1) read -rp "Wings hostname: " WINGS_HOSTNAME; export SSL_TARGET="wings" SSL_ACTION="issue" WINGS_HOSTNAME ;;
      2) read -rp "CN for file naming (host/IP): " CN; echo "Paste FULLCHAIN/CRT (Ctrl+D):"; read_multiline_b64 WINGS_CERT_PEM_B64; echo "Paste KEY (Ctrl+D):"; read_multiline_b64 WINGS_KEY_PEM_B64; export SSL_TARGET="wings" SSL_ACTION="install" WINGS_CN="$CN" WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64 ;;
      3) read -rp "Custom CERT path: " WINGS_CERT_PATH; read -rp "Custom KEY path: " WINGS_KEY_PATH; export SSL_TARGET="wings" SSL_ACTION="fix" WINGS_CERT_PATH WINGS_KEY_PATH ;;
      *) err "Invalid"; exit 1 ;;
    esac
  else
    echo "Panel SSL:"; echo "  1) Let's Encrypt"; echo "  2) Custom PEM"
    read -rp "Choose [1-2] (default 1): " M; M="${M:-1}"
    read -rp "Panel domain: " DOMAIN
    if [[ "$M" == "2" ]]; then
      echo "Paste FULLCHAIN/CRT (Ctrl+D):"; read_multiline_b64 CERT_PEM_B64
      echo "Paste KEY (Ctrl+D):";          read_multiline_b64 KEY_PEM_B64
      export SSL_TARGET="panel" SSL_MODE="custom" DOMAIN CERT_PEM_B64 KEY_PEM_B64
    else
      export SSL_TARGET="panel" SSL_MODE="letsencrypt" DOMAIN
    fi
  fi
  ensure_common; bash "$(fetch_cached install_ssl.sh)"
}

as_root
say "Pelican Installer — Smart mode (see $LOG_FILE)"
while :; do
cat <<'MENU'
────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings (paste config.yml; auto SSL/port)
 3) Install Both (Panel then Wings)
 4) SSL Only (issue / install / fix)
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
    5) ensure_common; bash "$(fetch_cached update.sh)";;
    6) ensure_common; bash "$(fetch_cached uninstall.sh)";;
    7) exit 0 ;;
    *) warn "Invalid choice" ;;
  esac
done
