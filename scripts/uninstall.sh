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

TARGET="${UNINSTALL_TARGET:-}"     # panel|wings|both
YES=0                              # --yes
DROP_DB=1                          # --keep-db -> 0
REMOVE_LE=0                        # --remove-le
CLOUDFLARE_CLEAN=0                 # --cloudflare-clean
PURGE_PACKAGES=0                   # --purge-packages

DOMAIN_HINT="${DOMAIN:-}"
WINGS_HOSTNAME_HINT="${WINGS_HOSTNAME:-}"
NGINX_CONF_HINT="${NGINX_CONF:-/etc/nginx/sites-available/pelican.conf}"
INSTALL_DIR_HINT="${INSTALL_DIR:-/var/www/pelican}"

CF_AUTH="${CF_AUTH:-token}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_API_EMAIL="${CF_API_EMAIL:-}"
CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_DNS_NAME="${CF_DNS_NAME:-}"

usage() {
  cat <<USAGE
Usage: uninstall.sh [--target panel|wings|both] [--yes]
                    [--keep-db] [--remove-le]
                    [--cloudflare-clean] [--purge-packages]
Cloudflare (optional): CF_AUTH=token|global and CF_API_TOKEN=... or CF_API_EMAIL=... CF_GLOBAL_API_KEY=...
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

first_token() { awk '{for(i=2;i<=NF;i++){gsub(/;$/,"",$i); print $i; exit}}'; }
extract_domain_from_appurl() { local d="${1#*://}"; echo "${d%%/*}"; }
dotenv_get() { local file="$1" key="$2"; grep -E "^${key}=" "$file" 2>/dev/null | sed -E "s/^${key}=//" || true; }
mysql_exec() { mysql -u root -Nse "$1" 2>/dev/null || true; }

cf_delete_record() {
  local name="$1"
  local base="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
  local -a hdr
  if [[ "$CF_AUTH" == "global" ]]; then
    hdr=(-H "X-Auth-Email: ${CF_API_EMAIL}" -H "X-Auth-Key: ${CF_GLOBAL_API_KEY}" -H "Content-Type: application/json")
  else
    hdr=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  fi
  local res http rec_id
  res="$(mktemp)"
  http="$(curl -sS -o "$res" -w '%{http_code}' "${hdr[@]}" "${base}?type=A&name=${name}")" || http=000
  if [[ "$http" != "200" ]]; then
    say_warn "Cloudflare list failed (HTTP $http): $(cat "$res")"; rm -f "$res"; return
  fi
  rec_id="$(jq -r '.result[0].id // empty' "$res")"
  rm -f "$res"
  [[ -n "$rec_id" ]] || { say_warn "Cloudflare: record ${name} not found"; return; }
  res="$(mktemp)"
  http="$(curl -sS -o "$res" -w '%{http_code}' -X DELETE "${hdr[@]}" "${base}/${rec_id}")" || http=000
  if [[ "$http" != "200" ]]; then
    say_warn "Cloudflare delete failed (HTTP $http): $(cat "$res")"
  else
    say_ok "Cloudflare: deleted ${name}"
  fi
  rm -f "$res"
}

uninstall_panel() {
  say_info "Uninstalling Pelican Panel…"

  local install_dir="$INSTALL_DIR_HINT"
  local nginx_conf="$NGINX_CONF_HINT"
  local domain="${DOMAIN_HINT}"

  if [[ -z "$domain" && -f "$nginx_conf" ]]; then
    domain="$(grep -m1 -E '^\s*server_name\s+' "$nginx_conf" | first_token || true)"
  fi
  if [[ -z "$domain" && -f "${install_dir}/.env" ]]; then
    local app_url; app_url="$(dotenv_get "${install_dir}/.env" "APP_URL")"
    [[ -n "$app_url" ]] && domain="$(extract_domain_from_appurl "$app_url")"
  fi

  systemctl disable --now pelican-queue.service 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-queue.service
  systemctl daemon-reload

  rm -f "/etc/nginx/sites-enabled/$(basename "$nginx_conf")" "$nginx_conf" 2>/dev/null || true
  rm -f /var/log/nginx/pelican.access.log /var/log/nginx/pelican.error.log 2>/dev/null || true
  rm -f /etc/nginx/includes/cloudflare-real-ip.conf 2>/dev/null || true
  nginx -t && systemctl reload nginx || true

  if [[ $DROP_DB -eq 1 && -f "${install_dir}/.env" ]]; then
    local conn db user sqlite_path
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

  rm -rf "$install_dir"

  if [[ -n "$domain" ]]; then
    rm -f "/etc/ssl/certs/${domain}.crt" "/etc/ssl/private/${domain}.key" 2>/dev/null || true
    if [[ $REMOVE_LE -eq 1 && -d "/etc/letsencrypt/live/${domain}" && $(command -v certbot) ]]; then
      certbot delete --cert-name "$domain" -n || say_warn "Certbot delete failed or not found for ${domain}"
    fi
  fi

  if [[ $CLOUDFLARE_CLEAN -eq 1 && -n "$CF_ZONE_ID" ]]; then
    local cf_name="${CF_DNS_NAME:-$domain}"
    [[ -n "$cf_name" ]] && cf_delete_record "$cf_name"
  fi

  say_ok "Panel uninstalled."
}

uninstall_wings() {
  say_info "Uninstalling Wings…"
  systemctl disable --now wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload

  rm -f /usr/local/bin/wings
  rm -rf /etc/pelican /var/run/wings

  local host="${WINGS_HOSTNAME_HINT}"
  if [[ -z "$host" ]]; then
    host="$(basename "$(ls -1 /etc/ssl/pelican/*.crt 2>/dev/null | head -n1 || echo "")" .crt)"
  fi
  if [[ -n "$host" ]]; then
    rm -f "/etc/ssl/pelican/${host}.crt" "/etc/ssl/pelican/${host}.key" 2>/dev/null || true
    if [[ $REMOVE_LE -eq 1 && -d "/etc/letsencrypt/live/${host}" && $(command -v certbot) ]]; then
      certbot delete --cert-name "$host" -n || say_warn "Certbot delete failed or not found for ${host}"
    fi
  fi

  if [[ $PURGE_PACKAGES -eq 1 ]]; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    apt-get autoremove -y || true
  fi

  say_ok "Wings uninstalled."
}

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

case "$TARGET" in
  panel) uninstall_panel ;;
  wings) uninstall_wings ;;
  both)  uninstall_panel; uninstall_wings ;;
  *) say_err "Unknown target: $TARGET"; exit 1 ;;
esac

[[ $PURGE_PACKAGES -eq 1 ]] && purge_core_packages

say_ok "Uninstall finished."
