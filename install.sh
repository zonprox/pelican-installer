#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
: "${GITHUB_USER:=zonprox}"
: "${GITHUB_REPO:=pelican-installer}"
: "${GITHUB_BRANCH:=main}"

REPO_NAME="${GITHUB_REPO}"
INSTALL_BASE_PRIMARY="/opt/${REPO_NAME}"
INSTALL_BASE_FALLBACK="/var/tmp/${REPO_NAME}"

PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

# =========================
# UI helpers
# =========================
cecho(){ echo -e "\033[1;36m$*\033[0m"; }
gecho(){ echo -e "\033[1;32m$*\033[0m"; }
recho(){ echo -e "\033[1;31m$*\033[0m"; }
yecho(){ echo -e "\033[1;33m$*\033[0m"; }

require_root(){
  if [[ $EUID -ne 0 ]]; then
    recho "Please run as root (sudo)."
    exit 1
  fi
}

# =========================
# OS detection
# =========================
detect_os(){
  if [[ ! -r /etc/os-release ]]; then
    recho "Cannot read /etc/os-release"; exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS="${ID:-}"; OS_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
  case "${OS}" in
    ubuntu)
      if ! dpkg --compare-versions "${OS_VER}" ge "22.04"; then
        recho "Ubuntu ${OS_VER} not supported. Use 22.04/24.04+."
        exit 1
      fi
      ;;
    debian)
      if ! dpkg --compare-versions "${OS_VER}" ge "11"; then
        recho "Debian ${OS_VER} not supported. Use 11/12+."
        exit 1
      fi
      ;;
    *)
      recho "Unsupported OS: ${PRETTY_NAME:-${OS}}"
      exit 1
      ;;
  esac
}

# =========================
# Locate self dir (may be empty when run via bash <(curl ...))
# =========================
get_self_dir(){
  local src
  src="${BASH_SOURCE[0]:-}"
  # When run via process substitution, BASH_SOURCE may be empty or like /dev/fd/*
  if [[ -z "${src}" || "${src}" == "/dev/fd/"* || "${src}" == "pipe:"* ]]; then
    echo ""
    return 0
  fi
  local d
  d="$(cd "$(dirname "${src}")" && pwd)"
  echo "${d}"
}

# =========================
# Ensure we have a local copy of the repo with all scripts
# Prefer git; fallback to tar.gz download
# =========================
ensure_local_copy(){
  local target
  target="${INSTALL_BASE_PRIMARY}"
  mkdir -p "${target}" 2>/dev/null || {
    target="${INSTALL_BASE_FALLBACK}"
    mkdir -p "${target}"
  }

  if command -v git >/dev/null 2>&1; then
    if [[ -d "${target}/.git" ]]; then
      # Existing clone: pull
      (cd "${target}" && git fetch --depth=1 origin "${GITHUB_BRANCH}" && git checkout -f "${GITHUB_BRANCH}" && git reset --hard "origin/${GITHUB_BRANCH}") >/dev/null
    else
      rm -rf "${target:?}"/*
      git clone --depth=1 --branch "${GITHUB_BRANCH}" "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${target}" >/dev/null
    fi
  else
    # Fallback: download tarball and extract
    local tgz="${target}.tar.gz"
    rm -rf "${target}" && mkdir -p "${target}"
    curl -fsSL "https://codeload.github.com/${GITHUB_USER}/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}" -o "${tgz}"
    # Extract into target (strip 1 leading component)
    tar -xzf "${tgz}" -C "${target}" --strip-components=1
    rm -f "${tgz}"
  fi

  # Ensure scripts are executable
  chmod +x "${target}/"*.sh 2>/dev/null || true

  echo "${target}"
}

# =========================
# Bootstrap if running from /dev/fd or missing child scripts
# =========================
bootstrap_if_needed(){
  local self_dir="$1"
  local need_bootstrap="no"

  if [[ -z "${self_dir}" ]]; then
    need_bootstrap="yes"
  else
    for f in panel.sh wings.sh ssl.sh update.sh uninstall.sh; do
      if [[ ! -f "${self_dir}/${f}" ]]; then
        need_bootstrap="yes"
        break
      fi
    done
  fi

  if [[ "${need_bootstrap}" == "yes" && "${PEL_BOOTSTRAPPED:-0}" != "1" ]]; then
    yecho "Bootstrapping local copy of ${GITHUB_USER}/${GITHUB_REPO} (${GITHUB_BRANCH})..."
    local local_dir
    local_dir="$(ensure_local_copy)"
    export PEL_BOOTSTRAPPED="1"
    exec bash "${local_dir}/install.sh" "$@"
  fi
}

# =========================
# Residue check (previous installation footprints)
# =========================
residue_check(){
  local PELICAN_DIR="/var/www/pelican"
  local NGINX_SITE="/etc/nginx/sites-enabled/pelican.conf"
  local hits=()

  if [[ -d "${PELICAN_DIR}" ]]; then hits+=("${PELICAN_DIR}"); fi
  if [[ -f "${NGINX_SITE}" ]]; then hits+=("${NGINX_SITE}"); fi
  if systemctl is-active --quiet wings 2>/dev/null; then hits+=("wings.service"); fi
  if getent passwd pelican >/dev/null 2>&1; then hits+=("user:pelican"); fi
  if command -v mysql >/dev/null 2>&1; then
    if mysql -NBe "SHOW DATABASES LIKE 'pelican';" 2>/dev/null | grep -q '^pelican$'; then
      hits+=("mysql:pelican database")
    fi
  fi

  if (( ${#hits[@]} > 0 )); then
    yecho "Found possible previous installation leftovers:"
    for h in "${hits[@]}"; do echo " - ${h}"; done
    echo
    echo "1) Run uninstall (clean up database/files/services)  [recommended]"
    echo "2) Ignore and continue"
    echo "0) Exit"
    read -r -p "Select: " opt
    case "${opt}" in
      1)
        if [[ -x "${REPO_ROOT}/uninstall.sh" ]]; then
          bash "${REPO_ROOT}/uninstall.sh"
        else
          yecho "uninstall.sh not found. Skipping."
        fi
        ;;
      2) ;;
      0) exit 0 ;;
      *) recho "Invalid selection."; exit 1 ;;
    esac
  fi
}

# =========================
# Menu
# =========================
main_menu(){
  clear
  cecho "Pelican Installer — Main Menu"
  echo "1) Install/Configure Panel"
  echo "2) Install/Configure Wings (agent)"
  echo "3) SSL (Let's Encrypt/Certbot)"
  echo "4) Update Panel/Wings"
  echo "5) Uninstall (clean)"
  echo "0) Exit"
  read -r -p "Select: " choice
  case "${choice}" in
    1) bash "${REPO_ROOT}/panel.sh" ;;
    2)
      if [[ -x "${REPO_ROOT}/wings.sh" ]]; then
        bash "${REPO_ROOT}/wings.sh"
      else
        yecho "wings.sh not available yet."
      fi
      ;;
    3)
      if [[ -x "${REPO_ROOT}/ssl.sh" ]]; then
        bash "${REPO_ROOT}/ssl.sh"
      else
        yecho "ssl.sh not available yet."
      fi
      ;;
    4)
      if [[ -x "${REPO_ROOT}/update.sh" ]]; then
        bash "${REPO_ROOT}/update.sh"
      else
        yecho "update.sh not available yet."
      fi
      ;;
    5)
      if [[ -x "${REPO_ROOT}/uninstall.sh" ]]; then
        bash "${REPO_ROOT}/uninstall.sh"
      else
        yecho "uninstall.sh not available yet."
      fi
      ;;
    0) exit 0 ;;
    *) recho "Invalid selection."; exit 1 ;;
  esac
}

# =========================
# Entry
# =========================
require_root

# Determine current script dir (may be empty under bash <(curl ...))
REPO_ROOT="$(get_self_dir || true)"

# Bootstrap if needed; re-exec from local copy to avoid /dev/fd quirks
bootstrap_if_needed "${REPO_ROOT}" "$@"

# If we are here, we are running from a real dir containing sibling scripts
if [[ -z "${REPO_ROOT}" ]]; then
  # Should not happen, but keep a safe default
  if [[ -d "${INSTALL_BASE_PRIMARY}" ]]; then
    REPO_ROOT="${INSTALL_BASE_PRIMARY}"
  elif [[ -d "${INSTALL_BASE_FALLBACK}" ]]; then
    REPO_ROOT="${INSTALL_BASE_FALLBACK}"
  else
    # Last-resort bootstrap
    local_dir="$(ensure_local_copy)"
    REPO_ROOT="${local_dir}"
  fi
fi

detect_os
residue_check
main_menu
