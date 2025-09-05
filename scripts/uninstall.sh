#!/usr/bin/env bash
set -euo pipefail

# ── Self-bootstrap common.sh (works standalone or via loader) ────────────────
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
if [[ ! -f "${COMMON_LOCAL}" ]]; then
  mkdir -p "${PEL_CACHE_DIR}"
  curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"
fi
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die

# ── Defaults & flags ─────────────────────────────────────────────────────────
TARGET="${UNINSTALL_TARGET:-}"     # panel|wings|both
YES=0                              # --yes      : no confirmation
DROP_DB=1                          # --keep-db  : set to 0 to keep DB/user/sqlite file
REMOVE_LE=0                        # --remove-le: delete Let's Encrypt cert(s)
CLOUDFLARE_CLEAN=0                 # --cloudflare-clean: delete DNS record if CF_* provided
PURGE_PACKAGES=0                   # --purge-packages: apt purge nginx/php/redis/mariadb/docker/certbot (danger)

# Optional hints (overrides auto-detect when present)
DOMAIN_HINT="${DOMAIN:-}"          # panel domain
WINGS_HOSTNAME_HINT="${WINGS_HOSTNAME:-}"  # wings hostname
NGINX_CONF_HINT="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"
INSTALL_DIR_HINT="${INSTALL_DIR:-/var/www/pelican}"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_DNS_NAME="${CF_DNS_NAME:-}"

# ── Arg parsing ──────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Usage: uninstall.sh [--target panel|wings|both] [--yes]
                    [--keep-db] [--remove-le]
                    [--cloudflare-clean] [--purge-packages]
Optional hints: DOMAIN=..., WINGS_HOSTNAME=..., NGINX_CONF=..., INSTALL_DIR=...
Cloudflare (optional): CF_API_TOKEN=..., CF_ZONE_ID=..., CF_DNS_NAME=...
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --keep-db) DROP_DB=0; shift ;;
    --remove-le) REMOVE_LE=1; shift ;;
    --cloudflare-clean) CLOUDFLARE_CLEAN=1; shift ;;
    --purge-packages) PURGE_PACKAGES=1; shift ;;
    -h|--help) usage ;;
    *) say_warn "Unknown arg: $1"; usage ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
confirm_once() {
  [[ $YES -eq 1 ]] && return 0
  echo "This will uninstall: ${1}. It will remove files/services"
  [[ $DROP_DB -eq 1 ]] && echo " - and DROP related databases/users (if detected)"
  [[ $REMOVE_LE -eq 1 ]] && echo " - and DELETE Let's Encrypt certificate(s)"
  [[ $CLOUDFLARE_CLEAN -eq 1 ]] && echo " - and DELETE Cloudflare DNS record"
  [[ $PURGE_PACKAGES -eq 1 ]] && echo " - and APT PURGE core packages (nginx/php/redis/mariadb/docker/certbot)"
  read -rp "Proceed? (y/N): " ok; ok="${ok:-N}"
  [[ "$ok" =~ ^[Yy]$ ]]
}

first_token() { # pick first token from nginx server_name line
  awk '{for(i=2;i<=NF;i++){gsub(/;$/,"",$i); print $i; exit}}'
}

extract_domain_from_appurl() {
  local appurl="$1" d="${appurl#*://}"; echo "${d%%/*}"
}

dotenv_get() { # read KEY from .env without eval
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | sed -E "s/^${key}=//" || true
}

mysql_exec() { mysql -u root -Nse "$1" 2>/dev/null || true; }

cf_delete_record() {
  local token="$1" zone="$2" name="$3"
  local rec_id
  rec_id="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=A&name=${name}" \
     -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')"
  [[ -n "$rec_id" ]] || { say_warn "Cloudflare: record ${name} not found"; return; }
  curl -fsS -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rec_id}" \
     -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" >/dev/null \
     && say_ok "Cloudflare: deleted ${name}"
}

# ── Uninstall: Panel ─────────────────────────────────────────────────────────
uninstall_panel() {
  say_info "Uninstalling Pelican Panel…"

  local install_dir="$INSTALL_DIR_HINT"
  local nginx_conf="$NGINX_CONF_HINT"
  local domain="$DOMAIN_HINT"

  # Derive domain (prefer nginx, then .env)
  if [[ -z "$domain" && -f "$nginx_conf" ]]; then
    domain="$(grep -m1 -E '^\s*server_name\s+' "$nginx_conf" | first_token || true)"
  fi
  if [[ -z "$domain" && -f "${install_dir}/.env" ]]; then
    local app_url; app_url="$(dotenv_get "${install_dir}/.env" "APP_URL")"
    [[ -n "$app_url" ]] && domain="$(extract_domain_from_appurl "$app_url")"
  fi

  # Stop services & remove units/vhosts
  systemctl disable --now pelican-queue.service 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-queue.service
  systemctl daemon-reload

  rm -f "/etc/nginx/sites-enabled/$(basename "$nginx_conf")" "$nginx_conf" 2>/dev/null || true
  # Attempt to clean dedicated logs & include
  rm -f /var/log/nginx/pelican.access.log /var/log/nginx/pelican.error.log 2>/dev/null || true
  rm -f /etc/nginx/includes/cloudflare-real-ip.conf 2>/dev/null || true
  nginx -t && systemctl reload nginx || true

  # DB cleanup (safe; only drops app DB/user)
  if [[ $DROP_DB -eq 1 && -f "${install_dir}/.env" ]]; then
    local conn db user pass sqlite_path
    conn="$(dotenv_get "${install_dir}/.env" DB_CONNECTION)"
    if [[ "$conn" == "mysql" || "$conn" == "mariadb" || "$conn" == "mysql_native" ]]; then
      db="$(dotenv_get "${install_dir}/.env" DB_DATABASE)"
      user="$(dotenv_get "${install_dir}/.env" DB_USERNAME)"
      [[ -n "$db" ]] && mysql_exec "DROP DATABASE IF EXISTS \`$db\`;" && say_ok "Dropped DB: $db"
      [[ -n "$user" ]] && mysql_exec "DROP USER IF EXISTS '${user}'@'127.0.0.1'; FLUSH PRIVILEGES;" && say_ok "Dropped DB user: $user@127.0.0.1"
    elif [[ "$conn" == "sqlite" ]]; then
      sqlite_path="$(dotenv_get "${install_dir}/.env" DB_DATABASE)"
      [[ -n "$sqlite_path" ]] && rm -f "$sqlite_path" && say_ok "Removed SQLite file: $sqlite_path"
    fi
  fi

  # Remove app dir
  rm -rf "$install_dir"

  # SSL removal
  if [[ -n "$domain" ]]; then
    # Custom files (safe to remove)
    rm -f "/etc/ssl/certs/${domain}.crt" "/etc/ssl/private/${domain}.key" 2>/dev/null || true
    if [[ $REMOVE_LE -eq 1 ]]; then
      if command -v certbot >/dev/null 2>&1; then
        certbot delete --cert-name "$domain" -n || say_warn "Certbot delete failed or not found for ${domain}"
      fi
    fi
  fi

  # Cloudflare cleanup (opt-in)
  if [[ $CLOUDFLARE_CLEAN -eq 1 && -n "$CF_API_TOKEN" && -n "$CF_ZONE_ID" ]]; then
    local cf_name="${CF_DNS_NAME:-$domain}"
    [[ -n "$cf_name" ]] && cf_delete_record "$CF_API_TOKEN" "$CF_ZONE_ID" "$cf_name"
  fi

  say_ok "Panel uninstalled."
}

# ── Uninstall: Wings ──────────────────────────────────────────────────────────
uninstall_wings() {
  say_info "Uninstalling Wings…"
  systemctl disable --now wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload

  # Remove binary & config
  rm -f /usr/local/bin/wings
  rm -rf /etc/pelican /var/run/wings

  # SSL (custom files)
  local host="${WINGS_HOSTNAME_HINT}"
  if [[ -z "$host" ]]; then
    # best-effort: take first crt under /etc/ssl/pelican
    host="$(basename "$(ls -1 /etc/ssl/pelican/*.crt 2>/dev/null | head -n1 || echo "")" .crt)"
  fi
  if [[ -n "$host" ]]; then
    local cert="/etc/ssl/pelican/${host}.crt" key="/etc/ssl/pelican/${host}.key"
    rm -f "$cert" "$key" 2>/dev/null || true
    if [[ $REMOVE_LE -eq 1 && -d "/etc/letsencrypt/live/${host}" && $(command -v certbot) ]]; then
      certbot delete --cert-name "$host" -n || say_warn "Certbot delete failed or not found for ${host}"
    fi
  fi

  # Docker purge (optional)
  if [[ $PURGE_PACKAGES -eq 1 ]]; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    apt-get autoremove -y || true
  fi

  say_ok "Wings uninstalled."
}

# ── Package purge (very aggressive; optional) ─────────────────────────────────
purge_core_packages() {
  say_warn "Purging core packages (nginx/php/redis/mariadb/certbot)…"
  apt-get purge -y nginx nginx-common nginx-core || true
  apt-get purge -y "php8.4*" php8.4 php-common || true
  apt-get purge -y redis-server || true
  apt-get purge -y mariadb-server mariadb-client || true
  apt-get purge -y certbot python3-certbot-nginx || true
  apt-get autoremove -y || true
  say_ok "Core packages purged."
}

# ── Target selection (single confirmation only) ───────────────────────────────
if [[ -z "$TARGET" ]]; then
  echo "Uninstall options:"
  echo " 1) Panel only"
  echo " 2) Wings only"
  echo " 3) Both"
  read -rp "Choose [1-3]: " opt || true
  case "${opt:-}" in
    1) TARGET="panel" ;;
    2) TARGET="wings" ;;
    3) TARGET="both" ;;
    *) say_err "Invalid choice"; exit 1 ;;
  esac
fi

confirm_once "$TARGET" || { echo "Aborted."; exit 0; }

# ── Execute ───────────────────────────────────────────────────────────────────
case "$TARGET" in
  panel) uninstall_panel ;;
  wings) uninstall_wings ;;
  both)  uninstall_panel; uninstall_wings ;;
  *) say_err "Unknown target: $TARGET"; exit 1 ;;
esac

# Optional: purge core packages after target removal
[[ $PURGE_PACKAGES -eq 1 ]] && purge_core_packages

say_ok "Uninstall finished."
