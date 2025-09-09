#!/usr/bin/env bash
set -euo pipefail

# Pelican Installer (bootstrap + menu)
# Minimal UI, numeric input, gentle warnings – not blockers.
# It downloads all scripts to /tmp/pelican-installer/ and runs from there.

REPO_USER="${REPO_USER:-zonprox}"
REPO_NAME="${REPO_NAME:-pelican-installer}"
REPO_REF="${REPO_REF:-main}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${REPO_REF}}"

WORKDIR="/tmp/pelican-installer"
SCRIPTS=("install.sh" "panel.sh" "wings.sh" "ssl.sh" "update.sh" "uninstall.sh")

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[i] This script prefers root privileges; attempting via sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

fetch_all() {
  echo "[i] Preparing workspace: ${WORKDIR}"
  rm -rf "${WORKDIR}" && mkdir -p "${WORKDIR}"
  for f in "${SCRIPTS[@]}"; do
    echo "[i] Fetching ${f}"
    if curl -fsSL "${BASE_URL}/${f}" -o "${WORKDIR}/${f}"; then
      chmod +x "${WORKDIR}/${f}"
    else
      # Create tiny placeholder for modules you’ll implement later
      echo -e "#!/usr/bin/env bash\n echo \"${f} is not yet implemented.\"" > "${WORKDIR}/${f}"
      chmod +x "${WORKDIR}/${f}"
    fi
  done
  echo "[✓] All scripts placed in ${WORKDIR}"
}

detect_os() {
  . /etc/os-release || true
  OS_NAME="${NAME:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  echo "[i] Detected OS: ${OS_NAME} ${OS_VER}"

  # Gentle compatibility advice based on Pelican docs (Ubuntu 22.04/24.04, Debian 11/12 supported)
  case "${ID:-unknown}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:11|debian:12)
      echo "[✓] OS is commonly used with Pelican Panel."
      ;;
    *)
      echo "[!]\n[Warning] Your OS is not listed as ‘commonly documented’ for Pelican Panel."
      echo "         You can still proceed; packages may differ and require manual adjustments."
      ;;
  esac
}

check_leftovers() {
  echo "[i] Checking for previous installs or leftovers..."
  local hints=()

  [[ -d /var/www/pelican ]] && hints+=("/var/www/pelican")
  systemctl list-units --type=service --no-pager 2>/dev/null | grep -qE 'wings\.service' && hints+=("wings.service")
  docker info >/dev/null 2>&1 && docker images --format '{{.Repository}}' | grep -qi pelican && hints+=("docker:pelican-images")
  [[ -f /etc/nginx/sites-enabled/pelican ]] && hints+=("nginx:pelican-site")
  [[ -d /etc/pelican ]] && hints+=("/etc/pelican")
  mysql -NBe "SHOW DATABASES LIKE 'pelican';" >/dev/null 2>&1 && hints+=("mysql:db pelican")

  if ((${#hints[@]})); then
    echo "[!]\n[Notice] Possible leftovers detected:"
    for h in "${hints[@]}"; do echo "  - ${h}"; done
    echo "You may want to run uninstall first for a clean state."
    echo "Run uninstall now? [1] Yes  [2] No"
    read -rp "> " ans
    if [[ "${ans}" == "1" ]]; then
      bash "${WORKDIR}/uninstall.sh" || true
    fi
  else
    echo "[✓] No obvious leftovers found."
  fi
}

main_menu() {
  echo
  echo "Pelican Installer — Main Menu"
  echo "1) Install Pelican Panel"
  echo "2) Install Wings (node)            [coming soon]"
  echo "3) SSL helper                      [coming soon]"
  echo "4) Update panel/wings              [coming soon]"
  echo "5) Uninstall / cleanup             [basic placeholder]"
  echo "6) Re-download installer files"
  echo "0) Exit"
  read -rp "Select: " choice
  case "${choice}" in
    1) bash "${WORKDIR}/panel.sh" ;;
    2) bash "${WORKDIR}/wings.sh" ;;
    3) bash "${WORKDIR}/ssl.sh" ;;
    4) bash "${WORKDIR}/update.sh" ;;
    5) bash "${WORKDIR}/uninstall.sh" ;;
    6) fetch_all; main_menu ;;
    0) exit 0 ;;
    *) echo "Invalid choice"; main_menu ;;
  esac
}

# --- flow ---
need_root "$@"
detect_os
fetch_all
check_leftovers
main_menu
