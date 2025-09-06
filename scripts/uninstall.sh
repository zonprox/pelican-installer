#!/usr/bin/env bash
# Pelican - Uninstall (clean & explicit)
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
mkdir -p "${PEL_CACHE_DIR}"
[[ -f "${COMMON_LOCAL}" ]] || curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base

# ---------- Defaults & Detectors ----------
PANEL_DIR_DEFAULT="/var/www/pelican"
PANEL_ENV="${PANEL_DIR_DEFAULT}/.env"
NGINX_AVAIL="/etc/nginx/sites-available/pelican.conf"
NGINX_ENABL="/etc/nginx/sites-enabled/pelican.conf"
QUEUE_UNIT="/etc/systemd/system/pelican-queue.service"
WINGS_CFG="/etc/pelican/config.yml"
WINGS_DATA="/var/lib/pelican"
WINGS_SVC_NAME="wings"          # standard service name for Pelican Wings

# read .env helper
get_env() { local k="$1"; grep -E "^${k}=" "$PANEL_ENV" 2>/dev/null | sed -E "s/^${k}=//"; }

# try detect panel
PANEL_FOUND="n"
if [[ -d "$PANEL_DIR_DEFAULT" ]] || [[ -f "$PANEL_ENV" ]]; then PANEL_FOUND="y"; fi

# derive domain & db info if panel exists
DOMAIN_DETECT=""
DB_CONN=""; DB_NAME=""; DB_USER=""; DB_HOST=""; DB_PASS_MASKED=""
if [[ "$PANEL_FOUND" == "y" ]]; then
  APP_URL="$(get_env APP_URL || true)"
  if [[ -n "${APP_URL:-}" ]]; then
    DOMAIN_DETECT="${APP_URL#*://}"; DOMAIN_DETECT="${DOMAIN_DETECT%%/*}"
  else
    # fallback from nginx
    if [[ -f "$NGINX_AVAIL" ]]; then
      DOMAIN_DETECT="$(grep -m1 -E '^\s*server_name\s+' "$NGINX_AVAIL" | awk '{for(i=2;i<=NF;i++){gsub(/;$/,"",$i); print $i; exit}}')"
    fi
  fi
  DB_CONN="$(get_env DB_CONNECTION || true)"
  DB_NAME="$(get_env DB_DATABASE || true)"
  DB_USER="$(get_env DB_USERNAME || true)"
  DB_HOST="$(get_env DB_HOST || true)"
  # mask pass length
  if grep -q '^DB_PASSWORD=' "$PANEL_ENV" 2>/dev/null; then
    local_pass="$(get_env DB_PASSWORD)"
    [[ -n "$local_pass" ]] && DB_PASS_MASKED="$(printf '%*s' "${#local_pass}" '' | tr ' ' '*')"
  fi
fi

# detect SSL files
LE_CERT_DIR=""; CUSTOM_CERT=""; CUSTOM_KEY=""
if [[ -n "$DOMAIN_DETECT" ]]; then
  [[ -d "/etc/letsencrypt/live/${DOMAIN_DETECT}" ]] && LE_CERT_DIR="/etc/letsencrypt/live/${DOMAIN_DETECT}"
  [[ -f "/etc/ssl/certs/${DOMAIN_DETECT}.crt" ]] && CUSTOM_CERT="/etc/ssl/certs/${DOMAIN_DETECT}.crt"
  [[ -f "/etc/ssl/private/${DOMAIN_DETECT}.key" ]] && CUSTOM_KEY="/etc/ssl/private/${DOMAIN_DETECT}.key"
fi

# detect wings
WINGS_FOUND="n"
if systemctl list-unit-files | grep -q "^${WINGS_SVC_NAME}.service"; then WINGS_FOUND="y"; fi
[[ -f "$WINGS_CFG" ]] && WINGS_FOUND="y"
[[ -d "$WINGS_DATA" ]] && WINGS_FOUND="y"

# ---------- Ask Targets ----------
echo "──────── Pelican Uninstall — Targets ────────"
echo "  1) Panel only"
echo "  2) Wings only"
echo "  3) Both (Panel + Wings)"
read -rp "Choose [1-3]: " T; T="${T:-3}"

UN_PANEL="n"; UN_WINGS="n"
case "$T" in
  1) UN_PANEL="y" ;;
  2) UN_WINGS="y" ;;
  3) UN_PANEL="y"; UN_WINGS="y" ;;
  *) say_err "Invalid choice"; exit 1;;
esac

# ---------- Dangerous options (toggles) ----------
DROP_DB="n"
if [[ "$UN_PANEL" == "y" && "$DB_CONN" == "mysql" || "$DB_CONN" == "mariadb" ]]; then
  echo; echo "Drop MySQL/MariaDB database & user?"
  echo "  DB: ${DB_NAME:-<unknown>}  USER: ${DB_USER:-<unknown>}  HOST: ${DB_HOST:-<unknown>}"
  read -rp "Type 'yes' to drop DB & user [yes/N]: " x; [[ "${x:-}" == "yes" ]] && DROP_DB="y"
fi

REMOVE_SSL="n"
if [[ "$UN_PANEL" == "y" && ( -n "$LE_CERT_DIR" || -n "$CUSTOM_CERT" || -n "$CUSTOM_KEY" ) ]]; then
  echo; echo "Remove SSL certificates for domain: ${DOMAIN_DETECT:-<unknown>}?"
  [[ -n "$LE_CERT_DIR" ]] && echo "  - Let's Encrypt dir: $LE_CERT_DIR"
  [[ -n "$CUSTOM_CERT" ]] && echo "  - Custom CERT: $CUSTOM_CERT"
  [[ -n "$CUSTOM_KEY" ]] && echo "  - Custom KEY : $CUSTOM_KEY"
  read -rp "Type 'yes' to remove SSL assets [yes/N]: " x; [[ "${x:-}" == "yes" ]] && REMOVE_SSL="y"
fi

PURGE_WINGS_DATA="n"
if [[ "$UN_WINGS" == "y" && -d "$WINGS_DATA" ]]; then
  echo; echo "Remove Wings data directory? ($WINGS_DATA)"
  read -rp "Type 'yes' to remove Wings data [yes/N]: " x; [[ "${x:-}" == "yes" ]] && PURGE_WINGS_DATA="y"
fi

PRUNE_DOCKER="n"
if [[ "$UN_WINGS" == "y" ]]; then
  echo; echo "Prune Docker containers/images related to Pelican?"
  echo "  (This may remove game server containers/images created by Wings.)"
  read -rp "Type 'yes' to prune Docker [yes/N]: " x; [[ "${x:-}" == "yes" ]] && PRUNE_DOCKER="y"
fi

# ---------- Summary ----------
echo
echo "──────── Review — Will Remove ────────"
if [[ "$UN_PANEL" == "y" ]]; then
  echo "• Panel application dir:      $PANEL_DIR_DEFAULT"
  echo "• Nginx vhost (file/symlink): $NGINX_AVAIL / $NGINX_ENABL"
  echo "• Systemd queue service:      pelican-queue.service"
  echo "• Nginx logs (if exist):      /var/log/nginx/pelican_*.log"
  if [[ "$DROP_DB" == "y" ]]; then
    echo "• DROP DB & user:             ${DB_NAME:-?} / ${DB_USER:-?} (hosts: 127.0.0.1, localhost)"
  fi
  if [[ "$REMOVE_SSL" == "y" ]]; then
    [[ -n "$LE_CERT_DIR" ]] && echo "• Remove LE cert dir:         $LE_CERT_DIR"
    [[ -n "$CUSTOM_CERT" ]] && echo "• Remove custom cert:         $CUSTOM_CERT"
    [[ -n "$CUSTOM_KEY"  ]] && echo "• Remove custom key:          $CUSTOM_KEY"
  fi
fi

if [[ "$UN_WINGS" == "y" ]]; then
  echo "• Wings systemd service:      ${WINGS_SVC_NAME}.service"
  echo "• Wings config:               $WINGS_CFG"
  if [[ "$PURGE_WINGS_DATA" == "y" ]]; then
    echo "• Remove Wings data dir:      $WINGS_DATA"
  fi
  if [[ "$PRUNE_DOCKER" == "y" ]]; then
    echo "• Docker prune:               containers/images/networks (dangereous)"
  fi
fi

echo "──────────────────────────────────────"
read -rp "Type UPPERCASE 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { say_warn "Aborted by user."; exit 0; }

# ---------- Execute Uninstall ----------
nginx_reload_needed=0
systemd_reload_needed=0

if [[ "$UN_PANEL" == "y" ]]; then
  say_info "Stopping queue worker…"
  systemctl disable --now pelican-queue 2>/dev/null || true
  rm -f "$QUEUE_UNIT"
  systemd_reload_needed=1

  say_info "Removing Nginx vhost…"
  rm -f "$NGINX_ENABL" || true
  rm -f "$NGINX_AVAIL" || true
  nginx_reload_needed=1

  say_info "Removing panel application directory…"
  rm -rf "$PANEL_DIR_DEFAULT" 2>/dev/null || true

  say_info "Removing Nginx logs (if present)…"
  rm -f /var/log/nginx/pelican_access.log /var/log/nginx/pelican_error.log 2>/dev/null || true

  if [[ "$DROP_DB" == "y" && ( "$DB_CONN" == "mysql" || "$DB_CONN" == "mariadb" ) ]]; then
    say_info "Dropping MariaDB database & user…"
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi

  if [[ "$REMOVE_SSL" == "y" ]]; then
    if [[ -n "$LE_CERT_DIR" ]]; then
      if command -v certbot >/dev/null 2>&1; then
        say_info "Removing Let's Encrypt certificate via certbot…"
        certbot delete --cert-name "${DOMAIN_DETECT}" -n || true
      fi
      rm -rf "$LE_CERT_DIR" 2>/dev/null || true
      rm -rf "/etc/letsencrypt/archive/${DOMAIN_DETECT}" "/etc/letsencrypt/renewal/${DOMAIN_DETECT}.conf" 2>/dev/null || true
    fi
    [[ -n "$CUSTOM_CERT" ]] && rm -f "$CUSTOM_CERT"
    [[ -n "$CUSTOM_KEY"  ]] && rm -f "$CUSTOM_KEY"
  fi
fi

if [[ "$UN_WINGS" == "y" ]]; then
  say_info "Stopping Wings service…"
  systemctl disable --now "${WINGS_SVC_NAME}" 2>/dev/null || true
  systemd_reload_needed=1

  say_info "Removing Wings config…"
  rm -f "$WINGS_CFG" 2>/dev/null || true
  rm -rf /etc/pelican 2>/dev/null || true

  if [[ "$PURGE_WINGS_DATA" == "y" ]]; then
    say_info "Removing Wings data dir…"
    rm -rf "$WINGS_DATA" 2>/dev/null || true
  fi

  if [[ "$PRUNE_DOCKER" == "y" ]]; then
    say_warn "Pruning Docker resources (this can remove running/stopped containers/images)…"
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' | grep -i 'pelican\|wings' || true
      docker stop $(docker ps -aq) 2>/dev/null || true
      docker rm $(docker ps -aq) 2>/dev/null || true
      docker image prune -af || true
      docker container prune -f || true
      docker network prune -f || true
      docker volume prune -f || true
    fi
  fi
fi

if (( systemd_reload_needed )); then
  systemctl daemon-reload || true
fi

if (( nginx_reload_needed )); then
  if command -v nginx >/dev/null 2>&1; then
    nginx -t && systemctl reload nginx || true
  fi
fi

say_ok "Uninstall finished."

# Small summary
echo "──────── Summary ────────"
[[ "$UN_PANEL" == "y" ]] && echo "• Panel removed."
[[ "$UN_WINGS" == "y" ]] && echo "• Wings removed."
[[ "$DROP_DB" == "y"   ]] && echo "• Database & user dropped."
[[ "$REMOVE_SSL" == "y" ]] && echo "• SSL assets removed."
[[ "$PRUNE_DOCKER" == "y" ]] && echo "• Docker resources pruned."
echo "────────────────────────"
