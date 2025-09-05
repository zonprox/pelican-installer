#!/usr/bin/env bash
set -euo pipefail

# ===== Repo coordinates =====
OWNER="zonprox"
REPO="pelican-installer"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/scripts"

CACHE_DIR="/var/cache/pelican-installer"
mkdir -p "${CACHE_DIR}"

# ===== Tiny utils =====
say() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[ERR ]\033[0m %s\n' "$*" >&2; }
as_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }; }

fetch_cached() {
  # $1 = remote name (e.g., install_panel.sh)
  local name="$1"
  local url="${RAW_BASE}/${name}"
  local dest="${CACHE_DIR}/${name}"
  # -z <file>: send If-Modified-Since using mtime of <file>
  if curl -fsSL -z "${dest}" -o "${dest}.tmp" "${url}"; then
    # If not modified, curl leaves .tmp as 0 bytes; keep old file.
    if [[ -s "${dest}.tmp" ]]; then mv -f "${dest}.tmp" "${dest}"; fi
    chmod +x "${dest}"
    echo "${dest}"
  else
    rm -f "${dest}.tmp"
    err "Failed to fetch ${url}"
    exit 1
  fi
}

run_step() {
  local script_name="$1"
  local local_path
  local_path="$(fetch_cached "${script_name}")"
  bash "${local_path}"
}

# ===== Start =====
as_root
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
