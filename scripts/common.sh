#!/usr/bin/env bash
# Common helpers for Pelican Installer
# - Safe: strict mode, error traps
# - Lightweight: only what we actually need
# - Reusable: sourced by other scripts

set -Eeuo pipefail

# ---------- Logging ----------
NC='\033[0m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREEN='\033[0;32m'
say_info(){  echo -e "${BLUE}[INFO]${NC} $*"; }
say_warn(){  echo -e "${YELLOW}[WARN]${NC} $*"; }
say_err(){   echo -e "${RED}[ERR ]${NC} $*"; }
say_ok(){    echo -e "${GREEN}[OK  ]${NC} $*"; }

# Trap errors in callers as well (when sourced)
trap 'say_err "Failed at: ${BASH_COMMAND} (exit $?)"; exit 1' ERR

# ---------- Safety ----------
require_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { say_err "Run as root (sudo)."; exit 1; }
}

# ---------- OS / base ----------
detect_os_or_die(){
  [[ -f /etc/os-release ]] || { say_err "Missing /etc/os-release"; exit 1; }
  . /etc/os-release
  case "${ID}-${VERSION_CODENAME}" in
    debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
    *) say_err "Supported: Debian 12 / Ubuntu 22.04 / 24.04. Detected: ${PRETTY_NAME}"; exit 1;;
  esac
  OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; export OS_ID OS_CODENAME
}

install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl tar unzip git ca-certificates lsb-release gnupg apt-transport-https ufw jq acl
}

ensure_pkg(){ dpkg -s "$1" >/dev/null 2>&1 || apt-get install -y "$1"; }

# ---------- PHP / web stack ----------
ensure_sury(){
  # Sury repo for PHP 8.x
  if [[ ! -f /etc/apt/sources.list.d/sury-php.list ]]; then
    echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
    apt-get update -y
  fi
}

ensure_php_84(){
  ensure_sury
  apt-get install -y \
    php8.4 php8.4-fpm php8.4-cli php8.4-mbstring php8.4-xml php8.4-curl \
    php8.4-zip php8.4-gd php8.4-bcmath php8.4-mysql php8.4-redis
  systemctl enable --now php8.4-fpm
}

ensure_nginx(){ ensure_pkg nginx; systemctl enable --now nginx; }

detect_phpfpm(){
  # returns "version|/run/php/phpX.Y-fpm.sock" or empty
  local v s
  for v in 8.4 8.3 8.2; do
    s="/run/php/php${v}-fpm.sock"
    [[ -S "$s" ]] && { echo "${v}|${s}"; return; }
  done
  local any
  any=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  [[ -n "$any" ]] && echo "$(basename "$any" | sed -E 's/php([0-9]+\.[0-9]+)-fpm\.sock/\1/')|$any" || echo ""
}

# ---------- Databases / cache ----------
ensure_redis(){ ensure_pkg redis-server; systemctl enable --now redis-server; }

ensure_mariadb(){
  if ! command -v mysql >/dev/null 2>&1; then
    apt-get install -y mariadb-server mariadb-client
    systemctl enable --now mariadb
  fi
}

# ---------- Composer ----------
composer_setup(){
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  export COMPOSER_ALLOW_SUPERUSER=1
  export COMPOSER_ROOT_VERSION=dev-main
  export COMPOSER_CACHE_DIR="/var/cache/composer"
  mkdir -p "$COMPOSER_CACHE_DIR"
}

# ---------- Firewall ----------
enable_ufw(){
  ufw allow OpenSSH || true
  ufw allow 80,443/tcp || true
  ufw --force enable || true
}
open_port_ufw(){ command -v ufw >/dev/null 2>&1 && ufw allow "$1"/tcp || true; }

# ---------- Docker ----------
ensure_docker(){
  if command -v docker >/dev/null 2>&1; then
    say_info "Docker present: $(docker --version 2>/dev/null | head -n1)"
    systemctl enable --now docker 2>/dev/null || true
    return 0
  fi
  say_info "Installing Docker CE (official repository)…"
  install_base
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  say_ok "Docker installed."
}

# ---------- Network / ports ----------
port_busy(){
  # return 0 if port is busy
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep -qE "LISTEN\s+.*:$1(\s|$)"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i :"$1" -sTCP:LISTEN -P -n >/dev/null 2>&1
  else
    # fallback: try nc
    nc -z localhost "$1" >/dev/null 2>&1
  fi
}

detect_public_ip(){
  curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"
}

# ---------- Nginx + Cloudflare real IP ----------
nginx_add_cloudflare_realip(){
  mkdir -p /etc/nginx/includes
  local f=/etc/nginx/includes/cloudflare-real-ip.conf
  {
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
    curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/' || true
    curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/' || true
  } > "$f" || true
}

# ---------- Cloudflare helpers ----------
sanitize_cf_inputs(){
  CF_ZONE_ID="${CF_ZONE_ID//[$'\r\n\t ']}"; export CF_ZONE_ID
  CF_DNS_NAME="${CF_DNS_NAME//[$'\r\n\t ']}"; export CF_DNS_NAME
  if [[ "${CF_AUTH:-token}" == "global" ]]; then
    CF_API_EMAIL="${CF_API_EMAIL//[$'\r\n\t ']}"; export CF_API_EMAIL
    CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY//[$'\r\n\t ']}"; export CF_GLOBAL_API_KEY
  else
    CF_API_TOKEN="${CF_API_TOKEN#Bearer }"
    CF_API_TOKEN="${CF_API_TOKEN//[$'\r\n\t ']}"
    export CF_API_TOKEN
  fi
}

cf_preflight_warn(){
  # returns 0 on 200 OK, 1 otherwise (with warning)
  local http
  if [[ "${CF_AUTH:-token}" == "global" ]]; then
    http="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "X-Auth-Email: ${CF_API_EMAIL}" -H "X-Auth-Key: ${CF_GLOBAL_API_KEY}" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}")"
  else
    http="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}")"
  fi
  if [[ "$http" != "200" ]]; then
    say_warn "Cloudflare preflight failed (HTTP $http). Verify credentials & Zone ID (auth=${CF_AUTH:-token})."
    return 1
  fi
  return 0
}

cf_upsert_a_record(){
  # Usage: cf_upsert_a_record <auth-mode> <zone_id> <rec_name> <content_ip> <proxied:true|false>
  # Note: <auth-mode> is unused; we rely on global env (CF_AUTH etc.) but keep the signature for compatibility.
  local _auth="${CF_AUTH:-token}" zone="$2" rec_name="$3" content="$4" proxied="$5"
  local base="https://api.cloudflare.com/client/v4/zones/${zone}/dns_records"

  local -a hdr
  if [[ "$_auth" == "global" ]]; then
    hdr=(-H "X-Auth-Email: ${CF_API_EMAIL}" -H "X-Auth-Key: ${CF_GLOBAL_API_KEY}" -H "Content-Type: application/json")
  else
    hdr=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  fi

  local res http rec_id
  res="$(mktemp)"
  http="$(curl -sS -o "$res" -w '%{http_code}' "${hdr[@]}" "${base}?type=A&name=${rec_name}")" || http=000
  if [[ "$http" == "200" ]]; then
    rec_id="$(jq -r '.result[0].id // empty' "$res")"
  else
    say_warn "Cloudflare list failed (HTTP $http): $(cat "$res")"
  fi
  rm -f "$res"

  res="$(mktemp)"
  if [[ -n "${rec_id:-}" ]]; then
    http="$(curl -sS -o "$res" -w '%{http_code}' -X PUT "${hdr[@]}" \
            --data "{\"type\":\"A\",\"name\":\"${rec_name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" \
            "${base}/${rec_id}")" || http=000
  else
    http="$(curl -sS -o "$res" -w '%{http_code}' -X POST "${hdr[@]}" \
            --data "{\"type\":\"A\",\"name\":\"${rec_name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" \
            "${base}")" || http=000
  fi

  if [[ "$http" != "200" && "$http" != "201" ]]; then
    say_warn "Cloudflare upsert failed (HTTP $http): $(cat "$res")"
    rm -f "$res"; return 1
  fi
  rm -f "$res"; say_ok "Cloudflare DNS set: ${rec_name} → ${content} (proxied=${proxied}, auth=${_auth})"
}

# ---------- Panel auto-detect ----------
panel_detect(){
  # Tries: .env(APP_URL) → nginx vhost server_name
  local env="/var/www/pelican/.env" url=""
  if [[ -f "$env" ]]; then
    url="$(grep -E '^APP_URL=' "$env" | sed -E 's/^APP_URL=//')"
  fi
  if [[ -z "$url" ]]; then
    local conf
    conf="$(readlink -f /etc/nginx/sites-enabled/pelican.conf 2>/dev/null || true)"
    [[ -z "$conf" ]] && conf="$(ls -1 /etc/nginx/sites-enabled/*.conf 2>/dev/null | head -n1 || true)"
    if [[ -n "$conf" ]]; then
      PANEL_DOMAIN_DETECTED="$(grep -m1 -E '^\s*server_name\s+' "$conf" | awk '{for(i=2;i<=NF;i++){gsub(/;$/,"",$i); print $i; exit}}')"
      [[ -n "${PANEL_DOMAIN_DETECTED:-}" ]] && url="https://${PANEL_DOMAIN_DETECTED}"
    fi
  else
    PANEL_DOMAIN_DETECTED="${url#*://}"; PANEL_DOMAIN_DETECTED="${PANEL_DOMAIN_DETECTED%%/*}"
  fi
  if [[ -n "$url" ]]; then
    PANEL_URL_DETECTED="$url"
    export PANEL_URL_DETECTED PANEL_DOMAIN_DETECTED
    return 0
  fi
  return 1
}

# ---------- Wings SSL patch (YAML heuristic) ----------
# patch_wings_ssl_file <config.yml> <enable:true|false> <cert_path> <key_path>
patch_wings_ssl_file(){
  local file="$1" enable="$2" cert="$3" key="$4"
  [[ -f "$file" ]] || { say_err "Config not found: $file"; return 1; }
  local en="false"; [[ "$enable" == "true" ]] && en="true"

  # We patch the first occurrences within the api.ssl block.
  # This is a simple heuristic that works with the default Wings template.
  sed -Ei "0,/^[[:space:]]*enabled:/s//  enabled: ${en}/" "$file" || true
  sed -Ei "0,/^[[:space:]]*cert:/s//  cert: ${cert//\//\\/}/" "$file" || true
  sed -Ei "0,/^[[:space:]]*key:/s//  key: ${key//\//\\/}/" "$file" || true
}
