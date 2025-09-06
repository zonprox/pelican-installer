#!/usr/bin/env bash
set -euo pipefail

# ===== Repo coordinates =====
OWNER="zonprox"
REPO="pelican-installer"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/scripts"

# ===== Cache & exports =====
CACHE_DIR="/var/cache/pelican-installer"
mkdir -p "${CACHE_DIR}"
export PEL_CACHE_DIR="${CACHE_DIR}"
export PEL_RAW_BASE="${RAW_BASE}"

# ===== UI utils =====
blue='\033[0;34m'; yellow='\033[1;33m'; red='\033[0;31m'; green='\033[0;32m'; nc='\033[0m'
say(){   printf "${blue}[INFO]${nc} %s\n" "$*"; }
warn(){  printf "${yellow}[WARN]${nc} %s\n" "$*"; }
err(){   printf "${red}[ERR ]${nc} %s\n" "$*\n" >&2; }
ok(){    printf "${green}[OK  ]${nc} %s\n" "$*"; }
as_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

fetch_cached() {
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

ensure_common(){ fetch_cached "common.sh" >/dev/null; . "${PEL_CACHE_DIR}/common.sh"; }

# ===== Small helpers =====
detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }
b64_read_file_to_var(){ local var="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"; local val; val="$(base64 -w0 "$tmp")"; rm -f "$tmp"; export "$var"="$val"; }
mask(){ local s="$1"; local n=${#s}; ((n<=4)) && { printf '****'; return; }; printf '%s' "$(printf '%*s' "$((n-4))" '' | tr ' ' '*')${s: -4}"; }

# ===== Wizards =====

wizard_panel(){
  echo
  echo "── Panel — Configuration Wizard ─────────────────────────"
  echo "Hint: Panel domain is the host you will use to access the web UI."
  echo "      Example: panel.example.com (URL = https://panel.example.com)"
  read -rp "Panel domain: " DOMAIN
  ADMIN_EMAIL_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin email for Let's Encrypt / contact [${ADMIN_EMAIL_DEFAULT}]: " ADMIN_EMAIL
  ADMIN_EMAIL="${ADMIN_EMAIL:-$ADMIN_EMAIL_DEFAULT}"

  echo
  echo "Database engine:"
  echo "  1) MariaDB (recommended)"
  echo "  2) SQLite (single-file, simple)"
  read -rp "Choose [1-2] (default 1): " DBC; DBC="${DBC:-1}"
  if [[ "$DBC" == "2" ]]; then
    export DB_ENGINE="sqlite"
  else
    export DB_ENGINE="mariadb"
    read -rp "DB name [pelicanpanel]: " DB_NAME;  DB_NAME="${DB_NAME:-pelicanpanel}"
    read -rp "DB user [pelican]: " DB_USER;       DB_USER="${DB_USER:-pelican}"
    read -rp "DB password (blank = auto-generate): " DB_PASS; DB_PASS="${DB_PASS:-}"
  fi

  echo
  echo "Admin account (for Panel login):"
  read -rp "Admin username [admin]: " ADMIN_USERNAME; ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  ADMIN_EMAILLOGIN_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin login email [${ADMIN_EMAILLOGIN_DEFAULT}]: " ADMIN_EMAILLOGIN
  ADMIN_EMAILLOGIN="${ADMIN_EMAILLOGIN:-$ADMIN_EMAILLOGIN_DEFAULT}"
  read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

  echo
  echo "Configure SMTP now?"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "Choose [1-2] (default 2): " SMTP_OPT; SMTP_OPT="${SMTP_OPT:-2}"
  if [[ "$SMTP_OPT" == "1" ]]; then
    export SETUP_SMTP="y"
    read -rp "SMTP FROM name [Pelican Panel]: " SMTP_FROM_NAME; SMTP_FROM_NAME="${SMTP_FROM_NAME:-Pelican Panel}"
    read -rp "SMTP FROM email [noreply@${DOMAIN}]: " SMTP_FROM_EMAIL; SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-noreply@${DOMAIN}}"
    read -rp "SMTP host: " SMTP_HOST
    read -rp "SMTP port [587]: " SMTP_PORT; SMTP_PORT="${SMTP_PORT:-587}"
    read -rp "SMTP username: " SMTP_USER
    read -rp "SMTP password: " SMTP_PASS
    echo "Encryption: 1) tls  2) ssl  3) none"
    read -rp "Choose [1-3] (default 1): " SMTP_ENC_OPT; SMTP_ENC_OPT="${SMTP_ENC_OPT:-1}"
    case "$SMTP_ENC_OPT" in
      2) SMTP_ENC="ssl" ;;
      3) SMTP_ENC="none" ;;
      *) SMTP_ENC="tls" ;;
    esac
  else
    export SETUP_SMTP="n"
  fi

  echo
  echo "SSL mode for Panel:"
  echo "  1) Let's Encrypt (automatic)"
  echo "  2) Custom PEM (paste FULLCHAIN/CRT & KEY)"
  read -rp "Choose [1-2] (default 1): " SSL_OPT; SSL_OPT="${SSL_OPT:-1}"
  if [[ "$SSL_OPT" == "2" ]]; then
    SSL_MODE="custom"
    echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var KEY_PEM_B64
  else
    SSL_MODE="letsencrypt"
  fi

  echo
  echo "Use Cloudflare API (optional) to create proxied A record?"
  echo "  1) Yes"
  echo "  2) No"
  read -rp "Choose [1-2] (default 2): " CF_YN_OPT; CF_YN_OPT="${CF_YN_OPT:-2}"
  if [[ "$CF_YN_OPT" == "1" ]]; then
    export CF_ENABLE="y"
    echo "Auth method:"
    echo "  1) API Token (recommended)"
    echo "  2) Global API Key"
    read -rp "Choose [1-2] (default 1): " CF_AUTH_OPT; CF_AUTH_OPT="${CF_AUTH_OPT:-1}"
    if [[ "$CF_AUTH_OPT" == "2" ]]; then
      CF_AUTH="global"
      read -rp "Cloudflare Account Email: " CF_API_EMAIL
      read -rp "Cloudflare Global API Key: " CF_GLOBAL_API_KEY
    else
      CF_AUTH="token"
      read -rp "Cloudflare API Token (Zone DNS Edit): " CF_API_TOKEN
    fi
    read -rp "Cloudflare Zone ID: " CF_ZONE_ID
    read -rp "DNS record name [${DOMAIN}]: " CF_DNS_NAME; CF_DNS_NAME="${CF_DNS_NAME:-$DOMAIN}"
    CF_RECORD_IP="$(detect_public_ip)"
    read -rp "Server public IP for A record [${CF_RECORD_IP}]: " CF_RECORD_IP_IN; CF_RECORD_IP="${CF_RECORD_IP_IN:-$CF_RECORD_IP}"

    ensure_common
    export CF_AUTH CF_API_TOKEN CF_API_EMAIL CF_GLOBAL_API_KEY CF_ZONE_ID CF_DNS_NAME CF_RECORD_IP
    sanitize_cf_inputs
    cf_preflight_warn || true
  else
    export CF_ENABLE="n"
  fi

  read -rp "Install directory [/var/www/pelican]: " INSTALL_DIR; INSTALL_DIR="${INSTALL_DIR:-/var/www/pelican}"
  read -rp "Nginx vhost path [/etc/nginx/sites-available/pelican.conf]: " NGINX_CONF; NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"

  # Review
  echo
  echo "──────────────── Configuration Review (Panel) ───────────"
  echo "Domain:                 $DOMAIN  (URL = https://${DOMAIN}/)"
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
  echo "Cloudflare:             $( [[ "${CF_ENABLE:-n}" == "y" ]] && echo Enabled || echo Disabled )"
  [[ "${CF_ENABLE:-n}" == "y" ]] && echo "  - Auth:               ${CF_AUTH}, DNS ${CF_DNS_NAME} → ${CF_RECORD_IP}"
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed with installation? (Y/n): " ok; ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  # Export ENV for non-interactive script
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
  ensure_common
  local PANEL_URL=""
  local PANEL_HTTPS=0

  # Auto-detect Panel
  if panel_detect; then
    say "Detected Panel on this system:"
    echo " - URL:   ${PANEL_URL_DETECTED}"
    echo " - Domain:${PANEL_DOMAIN_DETECTED}"
    PANEL_URL="$PANEL_URL_DETECTED"
  fi

  echo "Hint: Panel URL is the HTTPS address of your Panel, e.g., https://panel.example.com"
  read -rp "Panel URL [${PANEL_URL:-https://panel.example.com}]: " PANEL_URL_IN
  PANEL_URL="${PANEL_URL_IN:-${PANEL_URL:-https://panel.example.com}}"
  [[ "$PANEL_URL" =~ ^https:// ]] && PANEL_HTTPS=1

  echo
  echo "Wings Endpoint Type:"
  echo "  1) Domain Name (recommended)  — e.g., node1.example.com"
  echo "  2) IP Address                 — e.g., 203.0.113.10"
  read -rp "Choose [1-2] (default 1): " ENDPT_OPT; ENDPT_OPT="${ENDPT_OPT:-1}"
  if [[ "$ENDPT_OPT" == "2" ]]; then
    WINGS_ENDPOINT="ip"
    read -rp "Wings IP address: " WINGS_IP
    # small validate
    if ! [[ "$WINGS_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      err "Invalid IP format."; exit 1
    fi
    WINGS_HOSTNAME=""   # not used
  else
    WINGS_ENDPOINT="domain"
    echo "Hint: Wings hostname is the public FQDN for this node (A record must point to this server)."
    read -rp "Wings hostname (FQDN): " WINGS_HOSTNAME
    [[ -z "$WINGS_HOSTNAME" ]] && { err "Hostname is required for Domain Name endpoint."; exit 1; }
    WINGS_IP=""
  fi

  echo
  echo "SSL for Wings:"
  echo "  1) Let's Encrypt (automatic)   — only works with a valid domain"
  echo "  2) Custom PEM (paste CRT/KEY)  — works with domain or IP (if your cert supports)"
  echo "  3) None (HTTP)                  — not recommended if Panel uses HTTPS"
  while :; do
    read -rp "Choose [1-3] (default 1): " WSSL_OPT; WSSL_OPT="${WSSL_OPT:-1}"
    case "$WSSL_OPT" in
      1)
        if [[ "$WINGS_ENDPOINT" == "ip" ]]; then
          warn "Let's Encrypt cannot issue certificates for IP addresses. Choose 2) Custom or 3) None."
          continue
        fi
        WINGS_SSL="letsencrypt"; break ;;
      2)  WINGS_SSL="custom"; break ;;
      3)
        if [[ $PANEL_HTTPS -eq 1 ]]; then
          echo "WARNING: Panel URL is HTTPS. It's strongly recommended to enable SSL for Wings."
          echo "Proceed without SSL?"
          echo "  1) Yes, continue without SSL"
          echo "  2) No, go back and choose SSL"
          read -rp "Choose [1-2] (default 2): " CFM; CFM="${CFM:-2}"
          [[ "$CFM" == "1" ]] || continue
        fi
        WINGS_SSL="none"; break ;;
      *) continue;;
    esac
  done

  WINGS_CERT_PEM_B64=""; WINGS_KEY_PEM_B64=""
  if [[ "$WINGS_SSL" == "custom" ]]; then
    local CN_HINT
    CN_HINT="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
    echo; echo "Paste FULLCHAIN/CRT for ${CN_HINT} (include BEGIN/END), then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM) for ${CN_HINT} (include BEGIN/END), then Ctrl+D:"; b64_read_file_to_var WINGS_KEY_PEM_B64
  fi

  echo
  echo "──────────────── Configuration Review (Wings) ───────────"
  echo "Panel URL:             ${PANEL_URL}"
  if [[ "$WINGS_ENDPOINT" == "domain" ]]; then
    echo "Wings endpoint:        Domain → ${WINGS_HOSTNAME}"
  else
    echo "Wings endpoint:        IP     → ${WINGS_IP}"
  fi
  echo "Wings SSL:             ${WINGS_SSL}"
  [[ "$WINGS_SSL" == "custom" ]] && echo "  - Custom PEM:        pasted"
  echo "Note: If Panel uses HTTPS, Wings should also use SSL for secure communication."
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed with installation? (Y/n): " ok; ok="${ok:-Y}"
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export PANEL_URL WINGS_SSL WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64
  export WINGS_ENDPOINT WINGS_HOSTNAME WINGS_IP
  ensure_common
  bash "$(fetch_cached install_wings.sh)"
}

wizard_both(){
  say "You will configure Panel first, then Wings (auto-prefill from Panel)."
  wizard_panel
  echo
  say "Panel done. Proceed to Wings configuration..."
  wizard_wings
}

wizard_ssl(){
  echo
  echo "── SSL Utility — Apply for panel or wings ───────────────"
  echo "Target:"
  echo "  1) Panel"
  echo "  2) Wings"
  read -rp "Choose [1-2] (default 1): " T; T="${T:-1}"
  if [[ "$T" == "2" ]]; then
    echo "Hint: Wings hostname is the node's FQDN (e.g., node1.example.com)"
    read -rp "Wings hostname: " WINGS_HOSTNAME
    echo "SSL mode:"
    echo "  1) Let's Encrypt"
    echo "  2) Custom PEM"
    read -rp "Choose [1-2] (default 1): " M; M="${M:-1}"
    if [[ "$M" == "2" ]]; then
      echo; echo "Paste FULLCHAIN/CRT for ${WINGS_HOSTNAME}, then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
      echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:"; b64_read_file_to_var WINGS_KEY_PEM_B64
      export SSL_TARGET="wings" SSL_MODE="custom" WINGS_HOSTNAME WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64
    else
      export SSL_TARGET="wings" SSL_MODE="letsencrypt" WINGS_HOSTNAME
    fi
  else
    echo "Hint: Panel domain is what you used during Panel setup (e.g., panel.example.com)"
    read -rp "Panel domain: " DOMAIN
    echo "SSL mode:"
    echo "  1) Let's Encrypt"
    echo "  2) Custom PEM"
    read -rp "Choose [1-2] (default 1): " M; M="${M:-1}"
    if [[ "$M" == "2" ]]; then
      echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var CERT_PEM_B64
      echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var KEY_PEM_B64
      export SSL_TARGET="panel" SSL_MODE="custom" DOMAIN CERT_PEM_B64 KEY_PEM_B64
    else
      export SSL_TARGET="panel" SSL_MODE="letsencrypt" DOMAIN
    fi
  fi
  ensure_common
  bash "$(fetch_cached install_ssl.sh)"
}

wizard_update(){ ensure_common; bash "$(fetch_cached update.sh)"; }
wizard_uninstall(){ ensure_common; bash "$(fetch_cached uninstall.sh)"; }

# ===== Main menu =====
as_root
say "Pelican Installer — quick loader (numeric choices, hints, auto-detect)."
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
