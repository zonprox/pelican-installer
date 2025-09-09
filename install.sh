#!/usr/bin/env bash
set -Eeuo pipefail

# Minimal Pelican Installer Bootstrap
REPO_USER="${REPO_USER:-zonprox}"
REPO_NAME="${REPO_NAME:-pelican-installer}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${REPO_BRANCH}"

WORK_DIR="/tmp/pelican-installer"
LOG_FILE="${WORK_DIR}/installer.log"

log() { printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd curl
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd tee
need_cmd runuser

mkdir -p "$WORK_DIR"
: > "$LOG_FILE" || true

OS_ID="unknown"
if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; fi
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  log "Notice: Detected OS '${OS_ID}'. Ubuntu/Debian is recommended, but continuing is allowed."
fi

fetch() {
  local fn="$1" url="${RAW_BASE}/${fn}"
  log "Downloading ${fn} ..."
  if ! curl -fsSL "$url" -o "${WORK_DIR}/${fn}"; then
    log "Could not fetch ${fn} from ${url}."
    return 1
  fi
  chmod +x "${WORK_DIR}/${fn}" || true
}

fetch "install.sh" || true
fetch "panel.sh" || die "panel.sh is required."

for optional in "wings.sh" "ssl.sh" "update.sh" "uninstall.sh"; do
  if ! fetch "$optional"; then
    log "Creating placeholder for ${optional}."
    cat > "${WORK_DIR}/${optional}" <<'EOF'
#!/usr/bin/env bash
echo "This module is not implemented yet. Please update the repository with a real script."
exit 0
EOF
    chmod +x "${WORK_DIR}/${optional}"
  fi
done

detect_leftovers() {
  local leftovers=()
  [[ -d "/var/www/pelican" ]] && leftovers+=("/var/www/pelican")
  [[ -f "/etc/nginx/sites-enabled/pelican.conf" ]] && leftovers+=("nginx vhost")
  [[ -f "/etc/systemd/system/pelican-queue.service" ]] && leftovers+=("pelican-queue.service")
  systemctl list-units --type=service 2>/dev/null | grep -q '^wings\.service' && leftovers+=("wings.service")
  command -v wings >/dev/null 2>&1 && leftovers+=("wings binary")

  if ((${#leftovers[@]})); then
    log "Detected possible previous installation remnants:"
    for i in "${leftovers[@]}"; do log " - $i"; done
    echo "1) Run uninstall now"
    echo "2) Proceed anyway"
    echo "0) Exit"
    read -rp "Your choice [1/2/0]: " ans
    case "$ans" in
      1) bash "${WORK_DIR}/uninstall.sh";;
      2) log "Proceeding despite remnants...";;
      0) log "Exiting."; exit 0;;
      *) log "Invalid choice, proceeding by default."; ;;
    esac
  fi
}
detect_leftovers

while true; do
  echo
  echo "Pelican Installer — Main Menu"
  echo "============================="
  echo "1) Install Panel"
  echo "2) Install Wings (coming soon)"
  echo "3) SSL Tools (coming soon)"
  echo "4) Update (coming soon)"
  echo "5) Uninstall"
  echo "0) Exit"
  read -rp "Enter a number: " choice
  case "$choice" in
    1) bash "${WORK_DIR}/panel.sh";;
    2) bash "${WORK_DIR}/wings.sh";;
    3) bash "${WORK_DIR}/ssl.sh";;
    4) bash "${WORK_DIR}/update.sh";;
    5) bash "${WORK_DIR}/uninstall.sh";;
    0) log "Bye."; exit 0;;
    *) echo "Invalid choice."; ;;
  esac
done
