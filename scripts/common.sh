#!/usr/bin/env bash
set -euo pipefail

# ── Pretty logging ──────────────────────────────────────────────────────────────
NC='\033[0m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREEN='\033[0;32m'
say_info(){  echo -e "${BLUE}[INFO]${NC} $*"; }
say_warn(){  echo -e "${YELLOW}[WARN]${NC} $*"; }
say_err(){   echo -e "${RED}[ERR ]${NC} $*" >&2; }
say_ok(){    echo -e "${GREEN}[OK  ]${NC} $*"; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { say_err "Run as root (sudo)."; exit 1; }; }

# ── OS detection (Debian 12 / Ubuntu 22.04 / 24.04) ────────────────────────────
OS_ID=""; OS_CODENAME=""; OS_NAME=""
detect_os_or_die(){
  [[ -f /etc/os-release ]] || { say_err "Missing /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}-${VERSION_CODENAME}" in
    debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
    *) say_err "Supported: Debian 12 (bookworm), Ubuntu 22.04 (jammy), 24.04 (noble). Detected: ${PRETTY_NAME}"; exit 1;;
  esac
  OS_ID="$ID"; OS_CODENAME="$VERSION_CODENAME"; OS_NAME="$PRETTY_NAME"
}

# ── Prompt helpers ─────────────────────────────────────────────────────────────
prompt(){
  # $1=varname $2=label $3=default(optional)
  local __var="$1" __label="$2" __def="${3:-}" ans=""
  if [[ -n "$__def" ]]; then read -rp "$__label [$__def]: " ans || true; ans="${ans:-$__def}"
  else
    while :; do read -rp "$__label: " ans || true; [[ -n "$ans" ]] && break; say_warn "Cannot be empty."; done
  fi
  printf -v "$__var" '%s' "$ans"
}
prompt_choice(){ # $1=var $2=label $3=default
  local __var="$1" __label="$2" __def="$3" ans=""
  read -rp "$__label [$__def]: " ans || true; printf -v "$__var" '%s' "${ans:-$__def}"
}
mask(){ local s="$1"; local n=${#s}; ((n<=4)) && { printf '****'; return; }; printf '%s' "$(printf '%*s' "$((n-4))" '' | tr ' ' '*')${s: -4}"; }
gen_pass(){ local in="${1:-}"; [[ -z "$in" ]] && openssl rand -base64 24 | tr -d '\n' || printf '%s' "$in"; }

# ── Sury repo for PHP 8.4 ──────────────────────────────────────────────────────
ensure_sury(){
  echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
  apt-get update -y
}

# ── Common packages ────────────────────────────────────────────────────────────
install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get upgrade -y
  apt-get install -y curl tar unzip git ca-certificates lsb-release gnupg apt-transport-https ufw jq
}

# ── PHP-FPM socket detection ───────────────────────────────────────────────────
detect_phpfpm(){
  local v s
  for v in 8.4 8.3 8.2; do
    s="/run/php/php${v}-fpm.sock"
    [[ -S "$s" ]] && { echo "${v}|${s}"; return; }
  done
  local any; any=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  [[ -n "$any" ]] && { echo "$(basename "$any" | sed -E 's/php([0-9]+\.[0-9]+)-fpm\.sock/\1/')|$any"; return; }
  echo ""
}

# ── Public IP helper ───────────────────────────────────────────────────────────
detect_public_ip(){ curl -s https://api.ipify.org || curl -s ifconfig.me || echo "0.0.0.0"; }

# ── UFW baseline ───────────────────────────────────────────────────────────────
enable_ufw(){ ufw allow OpenSSH || true; ufw allow 80,443/tcp || true; ufw --force enable || true; }

# ── Cloudflare API helpers ─────────────────────────────────────────────────────
cf_upsert_a_record(){
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

nginx_add_cloudflare_realip(){
  mkdir -p /etc/nginx/includes
  local f=/etc/nginx/includes/cloudflare-real-ip.conf
  { echo "real_ip_header CF-Connecting-IP; real_ip_recursive on;"; \
    curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/' ; \
    curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/' ; } > "$f" || true
  say_ok "Wrote $f"
}

# ── Citations: official docs used by installers ────────────────────────────────
# Panel prerequisites & steps: https://pelican.dev/docs/panel/getting-started/
# Panel update steps:      https://pelican.dev/docs/panel/update/
# Wings install & systemd: https://pelican.dev/docs/wings/install/
# Wings update:            https://pelican.dev/docs/wings/update/
# Creating SSL:            https://pelican.dev/docs/guides/ssl/
