#!/usr/bin/env bash
set -euo pipefail

# ===== Self-bootstrap if called standalone =====
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"

NC='\033[0m'; BLUE='\033[0;34m'; YEL='\033[1;33m'; RED='\033[0;31m'; GRN='\033[0;32m'
say_info(){ printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
say_warn(){ printf "${YEL}[WARN]${NC} %s\n" "$*"; }
say_err() { printf "${RED}[ERR ]${NC} %s\n" "$*" >&2; }
say_ok()  { printf "${GRN}[OK  ]${NC} %s\n" "$*"; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { say_err "Run as root (sudo)."; exit 1; }; }

# OS check: Debian 12 / Ubuntu 22.04 / 24.04
OS_ID=""; OS_CODENAME=""; OS_NAME=""
detect_os_or_die(){
  [[ -f /etc/os-release ]] || { say_err "Missing /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}-${VERSION_CODENAME}" in
    debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
    *) say_err "Supported: Debian 12, Ubuntu 22.04/24.04. Detected: ${PRETTY_NAME}"; exit 1;;
  esac
  OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; OS_NAME="$PRETTY_NAME"
}

prompt(){ local v="$1" l="$2" d="${3:-}" a=""; if [[ -n "$d" ]]; then read -rp "$l [$d]: " a || true; a="${a:-$d}"; else
  while :; do read -rp "$l: " a || true; [[ -n "$a" ]] && break; say_warn "Cannot be empty."; done; fi; printf -v "$v" '%s' "$a"; }
choice(){ local v="$1" l="$2" d="$3" a=""; read -rp "$l [$d]: " a || true; printf -v "$v" '%s' "${a:-$d}"; }
mask(){ local s="$1"; local n=${#s}; ((n<=4)) && { printf '****'; return; }; printf '%*s' "$((n-4))" '' | tr ' ' '*'; printf '%s' "${s: -4}"; }
genpass(){ local in="${1:-}"; [[ -z "$in" ]] && openssl rand -base64 24 | tr -d '\n' || printf '%s' "$in"; }

install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get upgrade -y
  apt-get install -y curl ca-certificates lsb-release gnupg apt-transport-https jq ufw tar unzip git
}
ensure_sury(){
  echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" >/etc/apt/sources.list.d/sury-php.list
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
  apt-get update -y
}
ensure_pkgs(){ apt-get install -y --no-install-recommends "$@"; }

detect_phpfpm(){
  local v s; for v in 8.4 8.3 8.2; do s="/run/php/php${v}-fpm.sock"; [[ -S "$s" ]] && { echo "${v}|${s}"; return; }; done
  local any; any=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  [[ -n "$any" ]] && { echo "$(basename "$any" | sed -E 's/php([0-9]+\.[0-9]+)-fpm\.sock/\1/')|$any"; return; }
  echo ""
}
detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }
enable_ufw(){ ufw allow OpenSSH || true; ufw allow 80,443/tcp || true; ufw --force enable || true; }

# Safe .env setter (no sed pitfalls)
set_kv(){ f="$1"; k="$2"; v="$3"; tmp="$(mktemp)";
  awk -v K="$k" -v V="$v" 'BEGIN{found=0}
    $0 ~ "^"K"=" {print K"="V; found=1; next}
    {print}
    END{if(!found) print K"="V}
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

composer_setup(){
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi
  export COMPOSER_ALLOW_SUPERUSER=1
  export COMPOSER_ROOT_VERSION=dev-main
  export COMPOSER_CACHE_DIR="/var/cache/composer"
  mkdir -p "$COMPOSER_CACHE_DIR"
}

nginx_write_panel_config(){
  # args: domain install_dir php_sock ssl_mode(certbot/custom/none) cert_path key_path
  local domain="$1" dir="$2" sock="$3" ssl="$4" crt="${5:-}" key="${6:-}"
  local conf="/etc/nginx/sites-available/pelican.conf"
  rm -f /etc/nginx/sites-enabled/default || true

  cat >"$conf" <<NG80
server_tokens off;
server {
    listen 80;
    server_name ${domain};
    root ${dir}/public;
    index index.php;
    access_log /var/log/nginx/pelican.access.log;
    error_log  /var/log/nginx/pelican.error.log error;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_pass unix:${sock};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }
    location ~ /\.ht { deny all; }
}
NG80

  if [[ "$ssl" == "custom" ]]; then
    cat >>"$conf" <<NG443

server { listen 80; server_name ${domain}; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2;
    server_name ${domain};
    ssl_certificate     ${crt};
    ssl_certificate_key ${key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    root ${dir}/public; index index.php;
    access_log /var/log/nginx/pelican.access.log;
    error_log  /var/log/nginx/pelican.error.log error;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_pass unix:${sock};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }
}
NG443
  fi

  ln -sf "$conf" "/etc/nginx/sites-enabled/$(basename "$conf")"
  nginx -t && systemctl restart nginx
}

save_custom_cert(){
  # args: domain cert_pem key_pem -> returns paths
  local domain="$1" cert_pem="$2" key_pem="$3"
  local crt="/etc/ssl/certs/${domain}.crt"
  local key="/etc/ssl/private/${domain}.key"
  mkdir -p /etc/ssl/certs /etc/ssl/private
  echo "$cert_pem" > "$crt"
  umask 077; echo "$key_pem" > "$key"; umask 022
  chmod 644 "$crt"; chmod 600 "$key"
  echo "${crt}|${key}"
}

certbot_issue_nginx(){
  # args: domain email
  local domain="$1" email="$2"
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "${domain}" --redirect --agree-tos -m "${email}" --no-eff-email || say_warn "Certbot failed."
  systemctl reload nginx || true
}

cf_upsert_a(){
  # args: token zone_id name content proxied(true/false)
  local token="$1" zone="$2" name="$3" content="$4" proxied="$5"
  local rec_id
  rec_id="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=A&name=${name}" \
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')"
  if [[ -n "$rec_id" ]]; then
    curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rec_id}" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" >/dev/null
  else
    curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":120,\"proxied\":${proxied}}" >/dev/null
  fi
}
nginx_include_cf_realip(){
  mkdir -p /etc/nginx/includes
  local f=/etc/nginx/includes/cloudflare-real-ip.conf
  { echo "real_ip_header CF-Connecting-IP; real_ip_recursive on;"; \
    curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/' ; \
    curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/' ; } > "$f" || true
}
