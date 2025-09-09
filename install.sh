#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
: "${GITHUB_USER:=zonprox}"
: "${GITHUB_REPO:=pelican-installer}"
: "${GITHUB_BRANCH:=main}"

REPO_NAME="${GITHUB_REPO}"
PRIMARY_DIR="/opt/${REPO_NAME}"
FALLBACK_DIR="/var/tmp/${REPO_NAME}"
LOCK_FILE="/var/run/${REPO_NAME}.lock"

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
    recho "Please run as root (sudo)."; exit 1
  fi
}

# =========================
# Lock to prevent concurrent runs
# =========================
acquire_lock(){
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    yecho "Another run is in progress. Waiting for the lock..."
    flock 9
  fi
}

# =========================
# OS detection
# =========================
detect_os(){
  [[ -r /etc/os-release ]] || { recho "Cannot read /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  OS="${ID:-}"; OS_VER="${VERSION_ID:-}"; CODENAME="${VERSION_CODENAME:-}"
  case "${OS}" in
    ubuntu) dpkg --compare-versions "${OS_VER}" ge "22.04" || { recho "Ubuntu ${OS_VER} not supported. Use 22.04/24.04+."; exit 1; } ;;
    debian) dpkg --compare-versions "${OS_VER}" ge "11"    || { recho "Debian ${OS_VER} not supported. Use 11/12+."; exit 1; } ;;
    *) recho "Unsupported OS: ${PRETTY_NAME:-${OS}}"; exit 1 ;;
  esac
}

# =========================
# Utility: get current script dir (may be empty for bash <(curl ...))
# =========================
get_self_dir(){
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "${src}" || "${src}" == "/dev/fd/"* || "${src}" == "pipe:"* ]]; then
    echo ""; return 0
  fi
  local d; d="$(cd "$(dirname "${src}")" && pwd)"
  echo "${d}"
}

# =========================
# Safety: only remove whitelisted dirs (/opt|/var/tmp)/pelican-installer
# =========================
safe_rm_rf(){
  local target="$1"
  [[ -z "${target}" ]] && { recho "Refuse to remove empty path"; return 1; }
  case "${target}" in
    "/opt/${REPO_NAME}"|"/var/tmp/${REPO_NAME}")
      rm -rf --one-file-system -- "${target}"
      ;;
    *)
      recho "Refusing to remove non-whitelisted path: ${target}"
      return 1
      ;;
  esac
}

# =========================
# Validate a repo directory
# =========================
is_valid_repo_dir(){
  local d="$1"
  [[ -d "${d}" ]] || return 1
  [[ -f "${d}/install.sh" && -f "${d}/panel.sh" ]] || return 1
  return 0
}

# =========================
# Download via git into a temp dir, return path
# =========================
git_fetch_tmp(){
  local tmp; tmp="$(mktemp -d)"
  git clone --depth=1 --branch "${GITHUB_BRANCH}" "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${tmp}/${REPO_NAME}" >/dev/null
  echo "${tmp}/${REPO_NAME}"
}

# =========================
# Download tarball into a temp dir, return path
# =========================
tgz_fetch_tmp(){
  local tmp tgz
  tmp="$(mktemp -d)"
  tgz="${tmp}/${REPO_NAME}.tar.gz"
  curl -fsSL "https://codeload.github.com/${GITHUB_USER}/${GITHUB_REPO}/tar.gz/refs/heads/${GITHUB_BRANCH}" -o "${tgz}"
  mkdir -p "${tmp}/out"
  tar -xzf "${tgz}" -C "${tmp}/out" --strip-components=1
  echo "${tmp}/out"
}

# =========================
# Ensure we have a fresh local copy in PRIMARY_DIR or FALLBACK_DIR
# Strategy:
#   1) Prefer PRIMARY_DIR (/opt)
#   2) If exists but broken → overwrite atomically
#   3) If git available → use git; else tar.gz
#   4) Always replace target atomically (download to tmp, then swap)
# =========================
ensure_local_copy(){
  local target="${PRIMARY_DIR}"
  mkdir -p "${target}" 2>/dev/null || { target="${FALLBACK_DIR}"; mkdir -p "${target}"; }

  local src=""
  if command -v git >/dev/null 2>&1; then
    yecho "Bootstrapping local copy of ${GITHUB_USER}/${GITHUB_REPO} (${GITHUB_BRANCH}) via git..."
    # If target is a git repo, try fast-path update; else do clean clone to tmp then replace
    if [[ -d "${target}/.git" ]]; then
      # attempt update; if fails → full replace
      if (cd "${target}" && git fetch --depth=1 origin "${GITHUB_BRANCH}" >/dev/null 2>&1 && git checkout -f "${GITHUB_BRANCH}" >/dev/null 2>&1 && git reset --hard "origin/${GITHUB_BRANCH}" >/dev/null 2>&1); then
        :
      else
        yecho "Git update failed. Replacing repository..."
        src="$(git_fetch_tmp)"
        safe_rm_rf "${target}"
        mkdir -p "$(dirname "${target}")"
        mv "${src}" "${target}"
      fi
    else
      # Non-git or dirty dir → replace atomically
      src="$(git_fetch_tmp)"
      safe_rm_rf "${target}"
      mkdir -p "$(dirname "${target}")"
      mv "${src}" "${target}"
    fi
  else
    yecho "git not found. Bootstrapping via tarball..."
    src="$(tgz_fetch_tmp)"
    safe_rm_rf "${target}"
    mkdir -p "$(dirname "${target}")"
    mv "${src}" "${target}"
  fi

  chmod +x "${target}/"*.sh 2>/dev/null || true

  # Validate existence of key scripts
  if ! is_valid_repo_dir "${target}"; then
    recho "Local copy at ${target} looks invalid. Falling back to tarball..."
    src="$(tgz_fetch_tmp)"
    safe_rm_rf "${target}"
    mv "${src}" "${target}"
    chmod +x "${target}/"*.sh 2>/dev/null || true
    is_valid_repo_dir "${target}" || { recho "Failed to prepare a valid local copy at ${target}."; exit 1; }
  fi

  echo "${target}"
}

# =========================
# Bootstrap if running from /dev/fd or missing child scripts
# =========================
bootstrap_if_needed(){
  local self_dir="$1"
  local need="no"
  if [[ -z "${self_dir}" ]]; then
    need="yes"
  else
    for f in panel.sh wings.sh ssl.sh update.sh uninstall.sh; do
      [[ -f "${self_dir}/${f}" ]] || { need="yes"; break; }
    done
  fi

  if [[ "${need}" == "yes" && "${PEL_BOOTSTRAPPED:-0}" != "1" ]]; then
    local local_dir
    local_dir="$(ensure_local_copy)"
    export PEL_BOOTSTRAPPED=1
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

  [[ -d "${PELICAN_DIR}" ]] && hits+=("${PELICAN_DIR}")
  [[ -f "${NGINX_SITE}"  ]] && hits+=("${NGINX_SITE}")
  systemctl is-active --quiet wings 2>/dev/null && hits+=("wings.service")
  getent passwd pelican >/dev/null 2>&1 && hits+=("user:pelican")
  if command -v mysql >/dev/null 2>&1; then
    mysql -NBe "SHOW DATABASES LIKE 'pelican';" 2>/dev/null | grep -q '^pelican$' && hits+=("mysql:pelican database")
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
      1) [[ -x "${REPO_ROOT}/uninstall.sh" ]] && bash "${REPO_ROOT}/uninstall.sh" || yecho "uninstall.sh not available yet." ;;
      2) : ;;
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
    2) [[ -x "${REPO_ROOT}/wings.sh"    ]] && bash "${REPO_ROOT}/wings.sh"    || yecho "wings.sh not available yet." ;;
    3) [[ -x "${REPO_ROOT}/ssl.sh"      ]] && bash "${REPO_ROOT}/ssl.sh"      || yecho "ssl.sh not available yet." ;;
    4) [[ -x "${REPO_ROOT}/update.sh"   ]] && bash "${REPO_ROOT}/update.sh"   || yecho "update.sh not available yet." ;;
    5) [[ -x "${REPO_ROOT}/uninstall.sh"]] && bash "${REPO_ROOT}/uninstall.sh"|| yecho "uninstall.sh not available yet." ;;
    0) exit 0 ;;
    *) recho "Invalid selection."; exit 1 ;;
  esac
}

# =========================
# Entry
# =========================
require_root
acquire_lock

# If running from process substitution, self_dir will be empty
REPO_ROOT="$(get_self_dir || true)"
bootstrap_if_needed "${REPO_ROOT}" "$@"

# If still empty (shouldn't happen), force-prepare local copy and continue
if [[ -z "${REPO_ROOT}" ]]; then
  REPO_ROOT="$(ensure_local_copy)"
fi

detect_os
residue_check
main_menu
