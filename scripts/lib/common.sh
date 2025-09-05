#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then error "Run as root (sudo)."; exit 1; fi; }

detect_os() {
  if [[ -f /etc/os-release ]]; then . /etc/os-release
    case "${ID}-${VERSION_CODENAME}" in
      debian-bookworm|ubuntu-jammy|ubuntu-noble) ;;
      *) error "Supported: Debian 12 (bookworm) or Ubuntu 22.04 (jammy)/24.04 (noble). Detected: ${PRETTY_NAME}"; exit 1;;
    esac
    export OS_ID="$ID" OS_CODENAME="$VERSION_CODENAME" OS_NAME="$PRETTY_NAME"
  else error "Missing /etc/os-release"; exit 1; fi
}

prompt_input() {
  local var="$1" msg="$2" def="${3:-}" val=""
  if [[ -n "$def" ]]; then read -rp "$msg [${def}]: " val || true; val="${val:-$def}";
  else while true; do read -rp "$msg: " val || true; [[ -n "$val" ]] && break; warn "Cannot be empty."; done; fi
  printf -v "$var" '%s' "$val"
}
prompt_choice() { local var="$1" msg="$2" def="$3" ans=""; read -rp "$msg [${def}]: " ans || true; printf -v "$var" '%s' "${ans:-$def}"; }

gen_password() { local input="${1:-}"; [[ -z "$input" ]] && openssl rand -base64 24 | tr -d '\n' || echo -n "$input"; }
mask() { local s="$1"; local n=${#s}; (( n<=4 )) && { printf '****'; return; }; printf '%s' "$(printf '%*s' "$((n-4))" '' | tr ' ' '*')${s: -4}"; }

detect_php_fpm_socket() {
  for ver in 8.4 8.3 8.2; do [[ -S "/run/php/php${ver}-fpm.sock" ]] && { echo "${ver}|/run/php/php${ver}-fpm.sock"; return; }; done
  local any; any=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  [[ -n "$any" ]] && { echo "$(basename "$any" | sed -E 's/php([0-9]+\.[0-9]+)-fpm\.sock/\1/')|$any"; return; }
  echo ""
}

get_public_ip() { curl -fsSL https://api.ipify.org || curl -fsSL ifconfig.me || echo "0.0.0.0"; }

install_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get upgrade -y
  apt-get install -y curl tar unzip git ca-certificates lsb-release gnupg apt-transport-https ufw jq
  echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
  apt-get update -y
}

ensure_composer() { command -v composer >/dev/null 2>&1 || curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; }

enable_ufw_web() { ufw allow OpenSSH || true; ufw allow 80,443/tcp || true; ufw --force enable || true; }

write_cloudflare_realip() {
  mkdir -p /etc/nginx/includes
  local cf_cfg="/etc/nginx/includes/cloudflare-real-ip.conf"
  { echo "real_ip_header CF-Connecting-IP; real_ip_recursive on;"; \
    curl -fsS https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/' ; \
    curl -fsS https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/' ; } > "$cf_cfg" || true
  echo "$cf_cfg"
}
