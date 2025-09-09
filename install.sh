#!/usr/bin/env bash
# install.sh - Pelican Smart Minimal Installer
# Author: Zon (scaffold by ChatGPT)
# Language: English (as requested)

set -Eeuo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/zonprox/pelican-installer/main"
WORKDIR="/tmp/pelican-installer"
SUBDIRS=("install" "panel" "wings" "ssl" "update" "uninstall")

# ------------- UI Helpers (arrow-key menu, minimal & no deps) -------------
cursor_blink_on()  { tput cnorm || true; }
cursor_blink_off() { tput civis || true; }
cursor_to()        { tput cup "$1" "$2"; }
print_option()     { local idx="$1" text="$2"; printf "  %s\n" "$text"; }
print_selected()   { local idx="$1" text="$2"; tput rev; printf "> %s\n" "$text"; tput sgr0; }
get_key() {
  # Read arrow keys: up/down/enter
  local key
  IFS= read -rsn1 key 2>/dev/null || true
  if [[ $key == $'\x1b' ]]; then
    IFS= read -rsn2 key 2>/dev/null || true
    case "$key" in
      "[A") echo "up";;    # Up
      "[B") echo "down";;  # Down
      *)    echo "other";;
    esac
  elif [[ $key == $'\x0a' ]]; then
    echo "enter"
  else
    echo "other"
  fi
}
menu() {
  # Usage: menu "Title" "${options[@]}" -> echo index (0-based)
  local title="$1"; shift
  local options=("$@")
  local selected=0
  local lastrow lastcol startrow i key

  tput smcup || true
  cursor_blink_off
  trap 'cursor_blink_on; tput rmcup || true' EXIT

  clear
  echo "$title"
  echo
  startrow=3

  while true; do
    for i in "${!options[@]}"; do
      cursor_to $((startrow + i)) 0
      if [[ $i -eq $selected ]]; then
        print_selected "$i" "${options[$i]}"
      else
        print_option "$i" "${options[$i]}"
      fi
    done

    key=$(get_key)
    case "$key" in
      up)   ((selected=(selected-1+${#options[@]})%${#options[@]}));;
      down) ((selected=(selected+1)%${#options[@]}));;
      enter) break;;
      *) :;;
    esac
  done

  # Restore screen
  cursor_blink_on
  tput rmcup || true
  echo "$selected"
}

# ------------- Download & Layout -------------
bootstrap_layout() {
  echo "[*] Preparing workspace at $WORKDIR ..."
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  for d in "${SUBDIRS[@]}"; do
    mkdir -p "$WORKDIR/$d"
  done

  echo "[*] Fetching required scripts from repo (main branch) ..."
  curl -fsSL "$REPO_RAW_BASE/panel.sh" -o "$WORKDIR/panel/panel.sh"
  # Optionally pre-create empty placeholders for future modules
  touch "$WORKDIR/wings/wings.sh" "$WORKDIR/ssl/ssl.sh" "$WORKDIR/update/update.sh" "$WORKDIR/uninstall/uninstall.sh"
  chmod +x "$WORKDIR"/**/*.sh 2>/dev/null || true
  chmod +x "$WORKDIR"/panel/panel.sh
}

# ------------- Soft Checks (OS/arch/prior install) -------------
soft_system_checks() {
  echo "[*] Running soft system checks ..."
  local os_id="unknown" os_ver="unknown" arch
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    os_id="${ID:-unknown}"
    os_ver="${VERSION_ID:-unknown}"
  fi
  arch="$(uname -m || echo unknown)"

  echo "    - Detected OS: $os_id $os_ver"
  echo "    - Detected Arch: $arch"
  # Pelican targets Debian/Ubuntu typically; warn but do not block
  case "$os_id" in
    ubuntu|debian)
      echo "    ✓ This OS is commonly used with Pelican."
      ;;
    *)
      echo "    ⚠ This OS is not officially recommended by Pelican docs, but you may proceed at your own risk."
      ;;
  esac
  # Minimal arch guidance
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" && "$arch" != "aarch64" && "$arch" != arm64 ]]; then
    echo "    ⚠ Non-standard architecture detected. You can still continue, but Wings binary/Node/PHP packages may be unavailable."
  fi
}

detect_leftovers() {
  echo "[*] Checking for leftovers from previous installs ..."
  local findings=()
  [[ -d /var/www/pelican ]] && findings+=("/var/www/pelican (panel dir)")
  [[ -f /etc/nginx/sites-enabled/pelican.conf ]] && findings+=("nginx pelican.conf")
  systemctl list-units --type=service --all 2>/dev/null | grep -qE '^wings\.service' && findings+=("wings.service")
  mysql -Nse "SHOW DATABASES LIKE 'pelican';" 2>/dev/null | grep -q '^pelican$' && findings+=("MySQL DB 'pelican'")
  id pelican  &>/dev/null && findings+=("user 'pelican'")

  if ((${#findings[@]})); then
    echo "    ⚠ Found possible leftovers:"
    for f in "${findings[@]}"; do echo "      - $f"; done
    echo "    You may want to fully clean up before proceeding."
    echo "    Tip: Choose 'Run Uninstall/Cleanup' in menu to remove databases/files/services (destructive)."
  else
    echo "    ✓ No obvious leftovers found."
  fi
}

# ------------- Actions -------------
action_install_panel() {
  bash "$WORKDIR/panel/panel.sh"
}

action_install_wings() {
  # Simple inline installer (optional stub; full script would live in wings/wings.sh)
  echo "[*] Installing Wings (simple path) ..."
  sudo mkdir -p /etc/pelican /var/run/wings
  # Fetch latest wings binary per Pelican docs (auto-arch)
  sudo curl -fsSL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$([[ \"$(uname -m)\" == \"x86_64\" ]] && echo amd64 || echo arm64)"
  sudo chmod u+x /usr/local/bin/wings
  # Create systemd unit minimally
  sudo tee /etc/systemd/system/wings.service >/dev/null <<'EOF'
[Unit]
Description=Pelican Wings
After=docker.service
Requires=docker.service

[Service]
User=root
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  echo "    ✓ Wings binary installed. Next:"
  echo "      1) Create a Node in Panel → Nodes → Create New"
  echo "      2) Copy the generated config to /etc/pelican/config.yml"
  echo "      3) systemctl enable --now wings"
  echo "    (Follow Pelican docs for details.)"
}

action_uninstall_cleanup() {
  echo "This will attempt to remove Pelican Panel, Wings, Nginx site, and DB 'pelican'."
  read -r -p "Type 'YES' to proceed: " ans
  if [[ "$ans" != "YES" ]]; then
    echo "Aborted."
    return 0
  fi

  set +e
  sudo systemctl stop wings 2>/dev/null
  sudo systemctl disable wings 2>/dev/null
  sudo rm -f /etc/systemd/system/wings.service
  sudo systemctl daemon-reload

  sudo rm -rf /var/www/pelican
  sudo rm -f /etc/nginx/sites-enabled/pelican.conf /etc/nginx/sites-available/pelican.conf
  sudo nginx -t && sudo systemctl reload nginx 2>/dev/null

  mysql -e "DROP DATABASE IF EXISTS pelican;" 2>/dev/null
  mysql -e "DROP USER IF EXISTS 'pelican'@'localhost';" 2>/dev/null

  sudo rm -rf /etc/pelican /var/run/wings
  echo "Cleanup attempted. Some artifacts may remain depending on your customizations."
  set -e
}

action_about() {
  cat <<'TXT'
Pelican Installer (minimal, keyboard-driven)
- Arrow-key navigation, no numeric input
- Soft compatibility checks (Ubuntu/Debian preferred but not enforced)
- Clean temp-only workspace in /tmp/pelican-installer
- Modular subdirs: install/, panel/, wings/, ssl/, update/, uninstall/

References:
- Pelican docs (Panel & Wings) and quick install guidance.
TXT
}

# ------------- Main -------------
main_menu() {
  local options=(
    "Install Pelican Panel"
    "Install Wings (node agent)"
    "Run Uninstall/Cleanup (destructive)"
    "Re-check System & Leftovers"
    "About / Help"
    "Exit"
  )
  while true; do
    sel=$(menu "Pelican Installer — use ↑/↓ and Enter" "${options[@]}")
    case "$sel" in
      0) action_install_panel;;
      1) action_install_wings;;
      2) action_uninstall_cleanup;;
      3) soft_system_checks; detect_leftovers; read -rp "Press Enter to continue ...";;
      4) action_about; read -rp "Press Enter to continue ...";;
      5) echo "Bye!"; break;;
      *) :;;
    esac
  done
}

# Run
bootstrap_layout
soft_system_checks
detect_leftovers
main_menu
