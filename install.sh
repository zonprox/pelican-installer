#!/usr/bin/env bash
# Minimal Pelican installer launcher
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/zonprox/pelican-installer/main"
WORKDIR="/tmp/pelican-installer"

msg()  { printf "[*] %s\n" "$*"; }
ok()   { printf "[+] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*"; }
err()  { printf "[x] %s\n" "$*" >&2; }

prepare_workdir() {
  if [[ -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
  mkdir -p "$WORKDIR"/{install,panel,wings,ssl,update,uninstall}
  ok "Workspace ready at $WORKDIR"
}

fetch_files() {
  # Always fetch fresh copies from repo
  curl -fsSL "$REPO_RAW/install.sh" -o "$WORKDIR/install/install.sh"
  curl -fsSL "$REPO_RAW/panel.sh"   -o "$WORKDIR/panel/panel.sh"

  # Lightweight placeholders for yet-to-be-implemented modules
  for f in wings ssl update uninstall; do
    cat > "$WORKDIR/$f/$f.sh" <<'EOF'
#!/usr/bin/env bash
echo "[!] This module is not implemented yet. Please check back later."
exit 0
EOF
    chmod +x "$WORKDIR/$f/$f.sh"
  done

  chmod +x "$WORKDIR/install/install.sh" "$WORKDIR/panel/panel.sh"
  ok "Fetched installer scripts."
}

detect_leftovers() {
  local found=0
  echo
  msg "Quick scan for previous Pelican/Pterodactyl leftovers..."
  if [[ -d /var/www/pelican ]]; then
    warn "Found directory: /var/www/pelican"
    found=1
  fi
  if command -v mysql >/dev/null 2>&1; then
    if mysql -Nse "SHOW DATABASES LIKE 'pelican';" >/dev/null 2>&1; then
      warn "Found MySQL/MariaDB database named 'pelican'"
      found=1
    fi
    if mysql -Nse "SELECT user FROM mysql.user WHERE user='pelican' LIMIT 1;" >/dev/null 2>&1; then
      warn "Found MySQL/MariaDB user 'pelican'"
      found=1
    fi
  fi
  if systemctl list-unit-files 2>/dev/null | grep -qE 'wings\.service|pterodactyl|pelican'; then
    warn "Found related systemd units (wings/pterodactyl/pelican)"
    found=1
  fi
  if [[ $found -eq 1 ]]; then
    echo
    warn "Residual files/services were detected."
    echo "    → Recommendation: run the Uninstall module to clean up fully (DB, files, PHP libs)."
    echo "    → In this minimal starter, Uninstall is a placeholder for now."
  else
    ok "No obvious leftovers detected."
  fi
}

check_os() {
  local id="unknown" ver="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
    ver="${VERSION_ID:-unknown}"
  fi
  msg "Detected OS: $id $ver"
  case "$id" in
    ubuntu|debian)
      ok "Ubuntu/Debian family detected. Proceeding."
      ;;
    *)
      echo
      warn "This script targets Ubuntu/Debian as per Pelican docs."
      warn "We'll still let you continue at your own risk."
      ;;
  esac
}

main_menu() {
  echo
  echo "Pelican Installer — minimal menu"
  echo "--------------------------------"
  echo "1) Install Pelican Panel"
  echo "2) Install Wings (placeholder)"
  echo "3) SSL (placeholder)"
  echo "4) Update Panel (placeholder)"
  echo "5) Uninstall (placeholder)"
  echo "0) Exit"
  echo -n "Select an option [0-5]: "
  read -r choice || true
  case "${choice:-}" in
    1) bash "$WORKDIR/panel/panel.sh" ;;
    2) bash "$WORKDIR/wings/wings.sh" ;;
    3) bash "$WORKDIR/ssl/ssl.sh" ;;
    4) bash "$WORKDIR/update/update.sh" ;;
    5) bash "$WORKDIR/uninstall/uninstall.sh" ;;
    0|"") ok "Bye."; exit 0 ;;
    *) warn "Invalid choice."; main_menu ;;
  esac
}

trap 'err "An error occurred. Exiting."' ERR
clear
msg "Preparing Pelican installer..."
prepare_workdir
fetch_files
check_os
detect_leftovers
main_menu
