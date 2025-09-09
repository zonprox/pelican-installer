#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican one-line installer launcher
# Usage example for users:
#   bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)

SCRIPT_NAME="pelican-installer"
WORKDIR="/tmp/${SCRIPT_NAME}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zonprox/pelican-installer/main}"

# Files expected in the root
FILES=(install.sh panel.sh wings.sh ssl.sh update.sh uninstall.sh)

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[OK]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[ERR]\033[0m %s\n" "$*" >&2; }

ensure_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Please run as root (e.g., sudo -i)."
    exit 1
  fi
}

recreate_workdir() {
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"
}

fetch_files() {
  log "Downloading scripts to ${WORKDIR} ..."
  local f
  for f in "${FILES[@]}"; do
    # If a file doesn't exist in repo yet, create a stub so menu still works.
    if curl -fsSL "${RAW_BASE}/${f}" -o "${WORKDIR}/${f}"; then
      :
    else
      cat > "${WORKDIR}/${f}" <<'STUB'
#!/usr/bin/env bash
echo "This module is not implemented yet. Please check back later."
STUB
    fi
    chmod +x "${WORKDIR}/${f}"
  done
  ok "Scripts ready in ${WORKDIR}"
}

os_info() {
  . /etc/os-release || true
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  echo "${OS_ID}, ${OS_VER}"
}

compat_check() {
  local os; os=$(os_info)
  log "Detected OS: ${os}"
  # Supported per docs: Ubuntu 22.04/24.04, Debian 12 (Debian 11 lacks sqlite pkg), plus others may work.
  # Show gentle warning, do not hard-block.
  case "${OS_ID:-}" in
    ubuntu)
      if [[ "${OS_VER:-}" =~ ^(22\.04|24\.04)$ ]]; then
        ok "Ubuntu ${OS_VER} is supported by Pelican docs."
      else
        warn "Ubuntu ${OS_VER} is not explicitly covered in docs. It may still work — proceed with caution."
      fi
      ;;
    debian)
      if [[ "${OS_VER:-}" =~ ^(12|11)$ ]]; then
        warn "Debian ${OS_VER}: SQLite may be unavailable on 11; MariaDB is preferred. Proceeding is allowed."
      else
        warn "Debian ${OS_VER} is not explicitly covered. Proceeding is allowed."
      fi
      ;;
    *)
      warn "This OS is not officially documented. Installation may still work; continue at your own risk."
      ;;
  esac
  echo
  echo "Reference: Pelican Getting Started lists supported OS and PHP dependencies." 
  echo "→ https://pelican.dev/docs/panel/getting-started/ (for your notes)"
}

leftover_check() {
  echo
  log "Scanning for previous installations or leftovers ..."
  local found=0
  if [[ -d /var/www/pelican ]]; then
    warn "Found /var/www/pelican (panel files)"
    found=1
  fi
  if systemctl list-units --type=service | grep -qE 'wings\.service'; then
    warn "Found wings.service (Pelican daemon) — might be an old install"
    found=1
  fi
  if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
    warn "MariaDB/MySQL present — there may be existing databases/users"
    found=1
  fi
  if [[ $found -eq 1 ]]; then
    echo
    warn "It looks like you may have a previous or partial installation."
    echo "Tip: run the cleanup module to remove databases, files, PHP & libraries if needed:"
    echo "  bash ${WORKDIR}/uninstall.sh"
    echo "(uninstall.sh is pluggable; implement full cleanup later if desired.)"
  else
    ok "No obvious leftovers detected."
  fi
}

menu() {
  echo
  echo "====== Pelican Installer ======"
  echo "1) Install Panel"
  echo "2) Install Wings (placeholder)"
  echo "3) SSL Toolkit (placeholder)"
  echo "4) Update (placeholder)"
  echo "5) Uninstall (placeholder)"
  echo "0) Exit"
  echo "================================"
  read -rp "Choose an option [0-5]: " choice
  case "${choice}" in
    1) bash "${WORKDIR}/panel.sh" ;;
    2) bash "${WORKDIR}/wings.sh" ;;
    3) bash "${WORKDIR}/ssl.sh" ;;
    4) bash "${WORKDIR}/update.sh" ;;
    5) bash "${WORKDIR}/uninstall.sh" ;;
    0) exit 0 ;;
    *) echo "Invalid option"; sleep 1; menu ;;
  esac
}

main() {
  ensure_root
  recreate_workdir
  fetch_files
  compat_check
  leftover_check
  menu
}
main "$@"
