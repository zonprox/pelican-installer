#!/usr/bin/env bash
set -euo pipefail

# ===== Repo coordinates (edit if you rename) =====
OWNER="zonprox"
REPO="pelican-installer"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/scripts"

CACHE_DIR="/var/cache/pelican-installer"
mkdir -p "${CACHE_DIR}"

# Export for child scripts so they can bootstrap too
export PEL_CACHE_DIR="${CACHE_DIR}"
export PEL_RAW_BASE="${RAW_BASE}"

say()  { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[ERR ]\033[0m %s\n' "$*" >&2; }
rootp(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

fetch_cached() {
  # $1 = filename in scripts/
  local name="$1"
  local url="${RAW_BASE}/${name}"
  local dst="${CACHE_DIR}/${name}"
  mkdir -p "$(dirname "$dst")"
  if curl -fsSL -z "${dst}" -o "${dst}.tmp" "${url}"; then
    [[ -s "${dst}.tmp" ]] && mv -f "${dst}.tmp" "${dst}"
    chmod +x "${dst}" 2>/dev/null || true
    echo "${dst}"
  else
    rm -f "${dst}.tmp"
    err "Failed to fetch ${url}"
    exit 1
  fi
}

ensure_common() { fetch_cached "common.sh" >/dev/null; }

run_step() {
  local script="$1"
  ensure_common
  local path; path="$(fetch_cached "${script}")"
  bash "${path}"
}

# ===== Start =====
rootp
say "Pelican Installer — quick loader (fetch on demand)."

while :; do
cat <<'MENU'

────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings (with SSL options)
 3) Install Both (Panel then Wings)
 4) SSL Only (issue Let's Encrypt or use custom PEM)
 5) Update (Panel and/or Wings)
 6) Uninstall (Panel and/or Wings)
 7) Quit
MENU
  read -rp "Choose an option [1-7]: " choice || true
  case "${choice:-}" in
    1) run_step "install_panel.sh" ;;
    2) run_step "install_wings.sh" ;;
    3) run_step "install_both.sh" ;;
    4) run_step "install_ssl.sh" ;;
    5) run_step "update.sh" ;;
    6) run_step "uninstall.sh" ;;
    7) exit 0 ;;
    *) warn "Invalid choice." ;;
  esac
done
