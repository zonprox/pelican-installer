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
  local name="$1"; local url="${PEL_RAW_BASE}/${name}"; local dest="${PEL_CACHE_DIR}/${name}"
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL -z "${dest}" -o "${dest}.tmp" "${url}"; then
    [[ -s "${dest}.tmp" ]] && mv -f "${dest}.tmp" "${dest}"
    chmod +x "${dest}" 2>/dev/null || true; echo "${dest}"
  else
    rm -f "${dest}.tmp"; err "Failed to fetch ${url}"; exit 1
  fi
}

ensure_common(){ fetch_cached "common.sh" >/dev/null; . "${PEL_CACHE_DIR}/common.sh"; }

# ===== Small helpers =====
detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }
b64_read_file_to_var(){ local var="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"; local val; val="$(base64 -w0 "$tmp")"; rm -f "$tmp"; export "$var"="$val"; }
mask(){ local s="$1"; local n=${#s}; ((n<=4)) && { printf '****'; return; }; printf '%s' "$(printf '%*s' "$((n-4))" '' | tr ' ' '*')${s: -4}"; }

# ===== Wizards =====

wizard_panel(){
  echo; echo "── Panel — Configuration Wizard ─────────────────────────"
  echo "Hint: Panel domain is the host you will use to access the web UI."
  echo "      Example: panel.example.com (URL = https://panel.example.com)"
  read -rp "Panel domain: " DOMAIN
  ADMIN_EMAIL_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin email for Let's Encrypt / contact [${ADMIN_EMAIL_DEFAULT}]: " ADMIN_EMAIL
  ADMIN_EMAIL="${ADMIN_EMAIL:-$ADMIN_EMAIL_DEFAULT}"

  echo; echo "Database engine:"
  echo "  1) MariaDB (recommended)"; echo "  2) SQLite (single-file, simple)"
  read -rp "Choose [1-2] (default 1): " DBC; DBC="${DBC:-1}"
  if [[ "$DBC" == "2" ]]; then
    export DB_ENGINE="sqlite"
  else
    export DB_ENGINE="mariadb"
    read -rp "DB name [pelicanpanel]: " DB_NAME;  DB_NAME="${DB_NAME:-pelicanpanel}"
    read -rp "DB user [pelican]: " DB_USER;       DB_USER="${DB_USER:-pelican}"
    read -rp "DB password (blank = auto-generate): " DB_PASS; DB_PASS="${DB_PASS:-}"
  fi

  echo; echo "Admin account (for Panel login):"
  read -rp "Admin username [admin]: " ADMIN_USERNAME; ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  ADMIN_EMAILLOGIN_DEFAULT="admin@${DOMAIN}"
  read -rp "Admin login email [${ADMIN_EMAILLOGIN_DEFAULT}]: " ADMIN_EMAILLOGIN
  ADMIN_EMAILLOGIN="${ADMIN_EMAILLOGIN:-$ADMIN_EMAILLOGIN_DEFAULT}"
  read -rp "Admin password (blank = auto-generate): " ADMIN_PASSWORD; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

  echo; echo "Configure SMTP now?"
  echo "  1) Yes"; echo "  2) No"
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
    case "$SMTP_ENC_OPT" in 2) SMTP_ENC="ssl";; 3) SMTP_ENC="none";; *) SMTP_ENC="tls";; esac
  else
    export SETUP_SMTP="n"
  fi

  echo; echo "SSL mode for Panel:"
  echo "  1) Let's Encrypt (automatic)"; echo "  2) Custom PEM (paste FULLCHAIN/CRT & KEY)"
  read -rp "Choose [1-2] (default 1): " SSL_OPT; SSL_OPT="${SSL_OPT:-1}"
  if [[ "$SSL_OPT" == "2" ]]; then
    SSL_MODE="custom"
    echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM) for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var KEY_PEM_B64
  else
    SSL_MODE="letsencrypt"
  fi

  echo; echo "Use Cloudflare API (optional) to create proxied A record?"
  echo "  1) Yes"; echo "  2) No"
  read -rp "Choose [1-2] (default 2): " CF_YN_OPT; CF_YN_OPT="${CF_YN_OPT:-2}"
  if [[ "$CF_YN_OPT" == "1" ]]; then
    export CF_ENABLE="y"
    echo "Auth method:"; echo "  1) API Token (recommended)"; echo "  2) Global API Key"
    read -rp "Choose [1-2] (default 1): " CF_AUTH_OPT; CF_AUTH_OPT="${CF_AUTH_OPT:-1}"
    if [[ "$CF_AUTH_OPT" == "2" ]]; then
      CF_AUTH="global"; read -rp "Cloudflare Account Email: " CF_API_EMAIL; read -rp "Cloudflare Global API Key: " CF_GLOBAL_API_KEY
    else
      CF_AUTH="token"; read -rp "Cloudflare API Token (Zone DNS Edit): " CF_API_TOKEN
    fi
    read -rp "Cloudflare Zone ID: " CF_ZONE_ID
    read -rp "DNS record name [${DOMAIN}]: " CF_DNS_NAME; CF_DNS_NAME="${CF_DNS_NAME:-$DOMAIN}"
    CF_RECORD_IP="$(detect_public_ip)"; read -rp "Server public IP for A record [${CF_RECORD_IP}]: " x; CF_RECORD_IP="${x:-$CF_RECORD_IP}"
    ensure_common; export CF_AUTH CF_API_TOKEN CF_API_EMAIL CF_GLOBAL_API_KEY CF_ZONE_ID CF_DNS_NAME CF_RECORD_IP
    sanitize_cf_inputs; cf_preflight_warn || true
  else
    export CF_ENABLE="n"
  fi

  read -rp "Install directory [/var/www/pelican]: " INSTALL_DIR; INSTALL_DIR="${INSTALL_DIR:-/var/www/pelican}"
  read -rp "Nginx vhost path [/etc/nginx/sites-available/pelican.conf]: " NGINX_CONF; NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"

  echo; echo "──────────────── Configuration Review (Panel) ───────────"
  echo "Domain:   $DOMAIN  (URL = https://${DOMAIN}/)"; echo "Admin:    ${ADMIN_USERNAME} / ${ADMIN_EMAILLOGIN} / $( [[ -n "${ADMIN_PASSWORD}" ]] && echo "$(mask "$ADMIN_PASSWORD")" || echo "(auto)" )"
  echo "DB:       ${DB_ENGINE}"; [[ "${DB_ENGINE}" == "mariadb" ]] && echo "  - ${DB_NAME} / ${DB_USER} / $( [[ -n "${DB_PASS:-}" ]] && echo "$(mask "$DB_PASS")" || echo "(auto)" )"
  echo "SMTP:     $( [[ "$SETUP_SMTP" == "y" ]] && echo Yes || echo No )"; echo "SSL:      ${SSL_MODE}"
  echo "CF:       $( [[ "${CF_ENABLE:-n}" == "y" ]] && echo Enabled || echo Disabled )"; [[ "${CF_ENABLE:-n}" == "y" ]] && echo "  - ${CF_AUTH}, ${CF_DNS_NAME} → ${CF_RECORD_IP}"
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed? (Y/n): " ok; ok="${ok:-Y}"; [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export DOMAIN ADMIN_EMAIL INSTALL_DIR NGINX_CONF SSL_MODE
  export ADMIN_USERNAME ADMIN_EMAILLOGIN DB_ENGINE DB_NAME DB_USER DB_PASS ADMIN_PASSWORD
  export CERT_PEM_B64 KEY_PEM_B64
  export CF_ENABLE CF_AUTH CF_API_TOKEN CF_API_EMAIL CF_GLOBAL_API_KEY CF_ZONE_ID CF_DNS_NAME CF_RECORD_IP
  export SETUP_SMTP SMTP_FROM_NAME SMTP_FROM_EMAIL SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_ENC

  ensure_common; bash "$(fetch_cached install_panel.sh)"
}

wizard_wings(){
  echo; echo "── Wings — Configuration Wizard ─────────────────────────"
  ensure_common
  local PANEL_URL="" PANEL_HTTPS=0

  if panel_detect; then
    say "Detected Panel on this system:"; echo " - URL:   ${PANEL_URL_DETECTED}"; echo " - Domain:${PANEL_DOMAIN_DETECTED}"
    PANEL_URL="$PANEL_URL_DETECTED"
  fi

  echo "Hint: Panel URL is the HTTPS address of your Panel, e.g., https://panel.example.com"
  read -rp "Panel URL [${PANEL_URL:-https://panel.example.com}]: " z; PANEL_URL="${z:-${PANEL_URL:-https://panel.example.com}}"
  [[ "$PANEL_URL" =~ ^https:// ]] && PANEL_HTTPS=1

  echo; echo "Wings Endpoint Type:"; echo "  1) Domain Name (recommended) — e.g., node1.example.com"; echo "  2) IP Address — e.g., 203.0.113.10"
  read -rp "Choose [1-2] (default 1): " ENDPT_OPT; ENDPT_OPT="${ENDPT_OPT:-1}"
  if [[ "$ENDPT_OPT" == "2" ]]; then
    WINGS_ENDPOINT="ip"; read -rp "Wings IP address: " WINGS_IP
    [[ "$WINGS_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { err "Invalid IP format."; exit 1; }
    WINGS_HOSTNAME=""
  else
    WINGS_ENDPOINT="domain"; echo "Hint: Wings hostname is a public FQDN A-record pointing to this server."
    read -rp "Wings hostname (FQDN): " WINGS_HOSTNAME; [[ -n "$WINGS_HOSTNAME" ]] || { err "Hostname required."; exit 1; }
    WINGS_IP=""
  fi

  echo; echo "SSL for Wings:"; echo "  1) Let's Encrypt (automatic; domain only)"
  echo "  2) Custom PEM (paste CRT/KEY)"; echo "  3) None (HTTP)"
  while :; do
    read -rp "Choose [1-3] (default 1): " WSSL_OPT; WSSL_OPT="${WSSL_OPT:-1}"
    case "$WSSL_OPT" in
      1) [[ "$WINGS_ENDPOINT" == "ip" ]] && { warn "LE cannot issue for IP; choose 2 or 3."; continue; }; WINGS_SSL="letsencrypt"; break ;;
      2) WINGS_SSL="custom"; break ;;
      3) [[ $PANEL_HTTPS -eq 1 ]] && { echo "WARNING: Panel is HTTPS; Wings without SSL is discouraged."; read -rp "Proceed anyway? (y/N): " c; [[ "${c:-N}" =~ ^[Yy]$ ]] || continue; }; WINGS_SSL="none"; break ;;
      *) continue;;
    esac
  done

  WINGS_CERT_PEM_B64=""; WINGS_KEY_PEM_B64=""
  if [[ "$WINGS_SSL" == "custom" ]]; then
    local CN_HINT; CN_HINT="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
    echo; echo "Paste FULLCHAIN/CRT for ${CN_HINT}, then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
    echo; echo "Paste PRIVATE KEY (PEM) for ${CN_HINT}, then Ctrl+D:"; b64_read_file_to_var WINGS_KEY_PEM_B64
  fi

  echo; echo "──────────────── Configuration Review (Wings) ───────────"
  echo "Panel URL: ${PANEL_URL}"
  [[ "$WINGS_ENDPOINT" == "domain" ]] && echo "Endpoint : Domain → ${WINGS_HOSTNAME}" || echo "Endpoint : IP     → ${WINGS_IP}"
  echo "SSL     : ${WINGS_SSL}"; [[ "$WINGS_SSL" == "custom" ]] && echo "  - Custom PEM pasted"
  echo "Note: If Panel uses HTTPS, Wings should also use SSL for secure communication."
  echo "─────────────────────────────────────────────────────────"
  read -rp "Proceed with installation? (Y/n): " ok; ok="${ok:-Y}"; [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  export PANEL_URL WINGS_SSL WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64 WINGS_ENDPOINT WINGS_HOSTNAME WINGS_IP
  ensure_common; bash "$(fetch_cached install_wings.sh)"
}

wizard_both(){ say "You will configure Panel first, then Wings (auto-prefill from Panel)."; wizard_panel; echo; say "Panel done. Proceed to Wings…"; wizard_wings; }

wizard_ssl(){
  echo; echo "── SSL Utility ──────────────────────────────────────────"
  echo "Target:"; echo "  1) Panel"; echo "  2) Wings"
  read -rp "Choose [1-2] (default 1): " T; T="${T:-1}"
  if [[ "$T" == "2" ]]; then
    echo "Action:"; echo "  1) Issue Let's Encrypt for Wings (domain)"
    echo "  2) Install custom PEM for Wings (CRT/KEY)"
    echo "  3) Fix Wings config.yml to use custom cert (no provisioning)"
    read -rp "Choose [1-3] (default 1): " A; A="${A:-1}"
    case "$A" in
      1)
        read -rp "Wings hostname (domain): " WINGS_HOSTNAME
        export SSL_TARGET="wings" SSL_ACTION="issue" WINGS_HOSTNAME; ;;
      2)
        read -rp "Wings hostname (for file naming; can be IP or FQDN): " CN
        echo; echo "Paste FULLCHAIN/CRT for ${CN}, then Ctrl+D:"; b64_read_file_to_var WINGS_CERT_PEM_B64
        echo; echo "Paste PRIVATE KEY (PEM) for ${CN}, then Ctrl+D:"; b64_read_file_to_var WINGS_KEY_PEM_B64
        export SSL_TARGET="wings" SSL_ACTION="install" WINGS_CN="${CN}" WINGS_CERT_PEM_B64 WINGS_KEY_PEM_B64 ;;
      3)
        # Try best guess cert/key; else ask path
        ensure_common
        if guess_default_wings_certpair; then
          say "Using detected cert: ${GUESSED_CERT}"; say "Using detected key : ${GUESSED_KEY}"
          export SSL_TARGET="wings" SSL_ACTION="fix" WINGS_CERT_PATH="${GUESSED_CERT}" WINGS_KEY_PATH="${GUESSED_KEY}"
        else
          read -rp "Path to custom CERT file (fullchain): " WINGS_CERT_PATH
          read -rp "Path to custom KEY file: " WINGS_KEY_PATH
          export SSL_TARGET="wings" SSL_ACTION="fix" WINGS_CERT_PATH WINGS_KEY_PATH
        fi ;;
      *) err "Invalid choice"; exit 1;;
    esac
  else
    echo "Panel SSL:"
    echo "  1) Issue Let's Encrypt"; echo "  2) Install custom PEM"
    read -rp "Choose [1-2] (default 1): " M; M="${M:-1}"
    read -rp "Panel domain: " DOMAIN
    if [[ "$M" == "2" ]]; then
      echo; echo "Paste FULLCHAIN/CRT for ${DOMAIN}, then Ctrl+D:"; b64_read_file_to_var CERT_PEM_B64
      echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:"; b64_read_file_to_var KEY_PEM_B64
      export SSL_TARGET="panel" SSL_MODE="custom" DOMAIN CERT_PEM_B64 KEY_PEM_B64
    else
      export SSL_TARGET="panel" SSL_MODE="letsencrypt" DOMAIN
    fi
  fi
  ensure_common; bash "$(fetch_cached install_ssl.sh)"
}

wizard_update(){ ensure_common; bash "$(fetch_cached update.sh)"; }
wizard_uninstall(){ ensure_common; bash "$(fetch_cached uninstall.sh)"; }

# ===== Main menu =====
as_root
say "Pelican Installer — numeric choices, hints, auto-detect, deploy wings config."
while :; do
cat <<'MENU'

────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings (with SSL options)
 3) Install Both (Panel then Wings)
 4) SSL Only (issue/install/fix)
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
