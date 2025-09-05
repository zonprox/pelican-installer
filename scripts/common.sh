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
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}-${VERSION_CODENAME}" in
    debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
    *) say_err "Supported: Debian 12 / Ubuntu 22.04 / 24.04. Detected: ${PRETTY_NAME}"; exit 1;;
  esac
  OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; OS_NAME="$PRETTY_NAME"
}

# Base packages
install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get upgrade -y
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

# Cloudflare API (hardened upsert with explicit error logs)
cf_upsert_a_record(){
  local token="$1" zone="$2" name="$3" content="$4" proxied="$5"
  local base="https://api.cloudflare.com/client/v4/zones/${zone}/dns_records"
  local hdr=(-H "Authorization: Bearer ${token}" -H "Content-Type: application/json")

  # find existing
  local res http rec_id
  res="$(mktemp)"
  http="$(curl -sS -o "$res" -w '%{http_code}' "${hdr[@]}" \
          "${base}?type=A&name=${name}")" || http=000
  if [[ "$http" == "200" ]]; then
    rec_id="$(jq -r '.result[0].id // empty' "$res")"
  else
    say_warn "Cloudflare list failed (HTTP $http): $(cat "$res")"
  fi
  rm -f "$res"

  # upsert
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
    say_warn "Cloudflare upsert failed (HTTP $http): $(cat "$res")"
    rm -f "$res"
    return 1
  fi
  rm -f "$res"
  say_ok "Cloudflare DNS set: ${name} → ${content} (proxied=${proxied})"
}

# KV writer for .env (safe with special chars)
set_kv(){ f="$1"; k="$2"; v="$3"; tmp="$(mktemp)";
  awk -v K="$k" -v V="$v" 'BEGIN{found=0}
    $0 ~ "^"K"=" {print K"="V; found=1; next}
    {print}
    END{if(!found) print K"="V}
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Composer setup
composer_setup(){
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  export COMPOSER_ALLOW_SUPERUSER=1
  export COMPOSER_ROOT_VERSION=dev-main
  export COMPOSER_CACHE_DIR="/var/cache/composer"
  mkdir -p "$COMPOSER_CACHE_DIR"
}
