#!/usr/bin/env bash
set -euo pipefail

# Logs
NC='\033[0m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREEN='\033[0;32m'
say_info(){  echo -e "${BLUE}[INFO]${NC} $*"; }
say_warn(){  echo -e "${YELLOW}[WARN]${NC} $*"; }
say_err(){   echo -e "${RED}[ERR ]${NC} $*"; }
say_ok(){    echo -e "${GREEN}[OK  ]${NC} $*"; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { say_err "Run as root (sudo)."; exit 1; }; }

# OS detection
OS_ID=""; OS_CODENAME=""; OS_NAME=""
detect_os_or_die(){
  [[ -f /etc/os-release ]] || { say_err "Missing /etc/os-release"; exit 1; }
  . /etc/os-release
  case "${ID}-${VERSION_CODENAME}" in
    debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
    *) say_err "Supported: Debian 12 / Ubuntu 22.04 / 24.04. Detected: ${PRETTY_NAME}"; exit 1;;
  esac
  OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; OS_NAME="$PRETTY_NAME"
}

# Base packages (no full upgrade for speed)
install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl tar unzip git ca-certificates lsb-release gnupg apt-transport-https ufw jq
}

# Sury PHP repo (8.4)
ensure_sury(){
  echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
  apt-get update -y
}

# UFW baseline
enable_ufw(){ ufw allow OpenSSH || true; ufw allow 80,443/tcp || true; ufw --force enable || true; }

# PHP-FPM socket
detect_phpfpm(){
  local v s
  for v in 8.4 8.3 8.2; do s="/run/php/php${v}-fpm.sock"; [[ -S "$s" ]] && { echo "${v}|${s}"; return; }; done
  local any; any=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  [[ -n "$any" ]] && { echo "$(basename "$any" | sed -E 's/php([0-9]+\.[0-9]+)-fpm\.sock/\1/')|$any"; return; }
  echo ""
}

# Public IP
detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }

# Cloudflare: include real IPs into nginx
nginx_add_cloudflare_realip(){
  mkdir -p /etc/nginx/includes
  local f=/etc/nginx/includes/cloudflare-real-ip.conf
  { echo "real_ip_header CF-Connecting-IP; real_ip_recursive on;"; \
    curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/' ; \
    curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/' ; } > "$f" || true
}

# Cloudflare sanitize + preflight
sanitize_cf_inputs(){
  CF_ZONE_ID="${CF_ZONE_ID//[$'\r\n\t ']}"
  CF_DNS_NAME="${CF_DNS_NAME//[$'\r\n\t ']}"
  if [[ "${CF_AUTH:-token}" == "global" ]]; then
    CF_API_EMAIL="${CF_API_EMAIL//[$'\r\n\t ']}"
    CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY//[$'\r\n\t ']}"
    CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY%\"}"; CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY#\"}"
    CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY%\'}"; CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY#\'}"
  else
    CF_API_TOKEN="${CF_API_TOKEN#Bearer }"
    CF_API_TOKEN="${CF_API_TOKEN//[$'\r\n\t ']}"
    CF_API_TOKEN="${CF_API_TOKEN%\"}"; CF_API_TOKEN="${CF_API_TOKEN#\"}"
    CF_API_TOKEN="${CF_API_TOKEN%\'}"; CF_API_TOKEN="${CF_API_TOKEN#\'}"
  fi
}

cf_preflight_warn(){
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
    say_warn "Cloudflare preflight failed (HTTP $http). Check credentials & Zone ID (auth=${CF_AUTH:-token})."; return 1
  fi
  return 0
}

# Cloudflare upsert
cf_upsert_a_record(){
  local token="${CF_API_TOKEN:-}" email="${CF_API_EMAIL:-}" gkey="${CF_GLOBAL_API_KEY:-}"
  local auth="${CF_AUTH:-token}" zone="$2" name="$3" content="$4" proxied="$5"
  local base="https://api.cloudflare.com/client/v4/zones/${zone}/dns_records"

  local -a hdr
  if [[ "$auth" == "global" ]]; then
    hdr=(-H "X-Auth-Email: ${email}" -H "X-Auth-Key: ${gkey}" -H "Content-Type: application/json")
  else
    hdr=(-H "Authorization: Bearer ${token}" -H "Content-Type: application/json")
  fi

  local res http rec_id
  res="$(mktemp)"
  http="$(curl -sS -o "$res" -w '%{http_code}' "${hdr[@]}" "${base}?type=A&name=${name}")" || http=000
  if [[ "$http" == "200" ]]; then
    rec_id="$(jq -r '.result[0].id // empty' "$res")"
  else
    say_warn "Cloudflare list failed (HTTP $http): $(cat "$res")"
  fi
  rm -f "$res"

  res="$(mktemp)"
  if [[ -n "$rec_id" ]]; then
    http="$(curl -sS -o "$res" -w '%{http_code}' -X PUT "${hdr[@]}" \
            --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" \
            "${base}/${rec_id}")" || http=000
  else
    http="$(curl -sS -o "$res" -w '%{http_code}' -X POST "${hdr[@]}" \
            --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" \
            "${base}")" || http=000
  fi

  if [[ "$http" != "200" && "$http" != "201" ]]; then
    say_warn "Cloudflare upsert failed (HTTP $http): $(cat "$res")"; rm -f "$res"; return 1
  fi
  rm -f "$res"; say_ok "Cloudflare DNS set: ${name} → ${content} (proxied=${proxied}, auth=${auth})"
}

# Composer
composer_setup(){
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  export COMPOSER_ALLOW_SUPERUSER=1
  export COMPOSER_ROOT_VERSION=dev-main
  export COMPOSER_CACHE_DIR="/var/cache/composer"
  mkdir -p "$COMPOSER_CACHE_DIR"
}

mysql_escape_squote(){ printf "%s" "$1" | sed "s/'/''/g"; }
run_as_www(){ if command -v runuser >/dev/null 2>&1; then runuser -u www-data -- "$@"; else sudo -u www-data "$@"; fi }

# Panel auto-detect
panel_detect(){
  local env="/var/www/pelican/.env"; local url=""
  if [[ -f "$env" ]]; then url="$(grep -E '^APP_URL=' "$env" | sed -E 's/^APP_URL=//')"; fi
  if [[ -z "$url" ]]; then
    local conf; conf="$(readlink -f /etc/nginx/sites-enabled/pelican.conf 2>/dev/null || true)"
    [[ -z "$conf" ]] && conf="$(ls -1 /etc/nginx/sites-enabled/*.conf 2>/dev/null | head -n1 || true)"
    [[ -n "$conf" ]] && PANEL_DOMAIN_DETECTED="$(grep -m1 -E '^\s*server_name\s+' "$conf" | awk '{for(i=2;i<=NF;i++){gsub(/;$/,"",$i); print $i; exit}}')"
    [[ -n "${PANEL_DOMAIN_DETECTED:-}" ]] && url="https://${PANEL_DOMAIN_DETECTED}"
  else
    PANEL_DOMAIN_DETECTED="${url#*://}"; PANEL_DOMAIN_DETECTED="${PANEL_DOMAIN_DETECTED%%/*}"
  fi
  if [[ -n "$url" ]]; then PANEL_URL_DETECTED="$url"; export PANEL_URL_DETECTED PANEL_DOMAIN_DETECTED; return 0; fi
  return 1
}

# ===== NEW: Docker ensure (skip installer if present) =====
ensure_docker(){
  if command -v docker >/dev/null 2>&1; then
    say_info "Docker already present: $(docker --version 2>/dev/null | head -n1)"
    systemctl enable --now docker 2>/dev/null || true
    return 0
  fi
  say_info "Installing Docker CE from official APT repo…"
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

# ===== Wings SSL config patcher =====
# patch_wings_ssl_file <file> <enable:true|false> <cert_path> <key_path>
patch_wings_ssl_file(){
  local file="$1" enable="$2" cert="$3" key="$4"
  [[ -f "$file" ]] || { say_err "config file not found: $file"; return 1; }
  local en="false"; [[ "$enable" == "true" ]] && en="true"

  # patch the first occurrences inside api.ssl block (simple heuristic)
  sed -Ei "0,/^[[:space:]]*enabled:/s//  enabled: ${en}/" "$file" || true
  sed -Ei "0,/^[[:space:]]*cert:/s//  cert: ${cert//\//\\/}/" "$file" || true
  sed -Ei "0,/^[[:space:]]*key:/s//  key: ${key//\//\\/}/" "$file" || true
}

# Try guess custom cert/key under /etc/ssl/pelican
guess_default_wings_certpair(){
  local c k; c="$(ls -1 /etc/ssl/pelican/*.crt 2>/dev/null | head -n1 || true)"
  if [[ -n "$c" ]]; then k="${c%.crt}.key"; [[ -f "$k" ]] || k=""
    if [[ -n "$k" ]]; then GUESSED_CERT="$c"; GUESSED_KEY="$k"; export GUESSED_CERT GUESSED_KEY; return 0; fi
  fi
  return 1
}
