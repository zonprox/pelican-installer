#!/usr/bin/env bash
set -Eeuo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Pelican Installer Bootstrap & Menu
# - Minimal UI, number-based menu
# - Downloads all scripts to /tmp/pelican-installer/ (overwrites if exists)
# - Smart leftover checks; suggest running uninstall if remnants found
# - Soft OS compatibility check (Ubuntu/Debian recommended, but not enforced)
# - Runs directly from GitHub raw (no releases required)
# ────────────────────────────────────────────────────────────────────────────────

# --- Config (edit for your repo) ---
REPO_USER="${REPO_USER:-zonprox}"
REPO_NAME="${REPO_NAME:-pelican-installer}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${REPO_BRANCH}"

# --- Paths ---
WORK_DIR="/tmp/pelican-installer"
LOG_FILE="${WORK_DIR}/installer.log"

# --- Utilities ---
log() { printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# --- Safety / prerequisites ---
need_cmd curl
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd tee

mkdir -p "$WORK_DIR"
# Overwrite: clean folder (but keep log if exists)
if [[ -e "$WORK_DIR" ]]; then
  : > "$LOG_FILE" || true
fi

# --- OS check (soft) ---
OS_ID="unknown"
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
fi
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  log "Notice: Detected OS: ${OS_ID}. Pelican officially targets Ubuntu/Debian stacks."
  log "We'll continue if you confirm, but some steps may need manual adjustment."
fi

# --- Fetch helper ---
fetch() {
  # $1: filename
  local fn="$1"
  local url="${RAW_BASE}/${fn}"
  log "Downloading ${fn} ..."
  if ! curl -fsSL "$url" -o "${WORK_DIR}/${fn}"; then
    log "Could not fetch ${fn} from ${url}."
    return 1
  fi
  chmod +x "${WORK_DIR}/${fn}" || true
  return 0
}

# --- Download core scripts (install.sh + panel.sh) ---
fetch "install.sh" || true   # re-download to workspace for offline reuse
fetch "panel.sh" || die "panel.sh is required at this stage."

# Optional modules (placeholders if not present yet)
for optional in "wings.sh" "ssl.sh" "update.sh" "uninstall.sh"; do
  if ! fetch "$optional"; then
    log "Creating placeholder for ${optional} (you can implement it later)."
    cat > "${WORK_DIR}/${optional}" <<'EOF'
#!/usr/bin/env bash
echo "This module is not implemented yet. Please update the repository with a real script."
exit 0
EOF
    chmod +x "${WORK_DIR}/${optional}"
  fi
done

# --- Smart leftover detection ---
detect_leftovers() {
  local leftovers=()

  [[ -d "/var/www/pelican" ]] && leftovers+=("/var/www/pelican")
  [[ -f "/etc/nginx/sites-enabled/pelican.conf" ]] && leftovers+=("/etc/nginx/sites-enabled/pelican.conf")
  [[ -f "/etc/systemd/system/pelican-queue.service" ]] && leftovers+=("systemd pelican-queue.service")
  [[ -f "/etc/pelican/config.yml" ]] && leftovers+=("/etc/pelican/config.yml")
  systemctl list-units --type=service 2>/dev/null | grep -q '^wings\.service' && leftovers+=("wings.service")
  command -v wings >/dev/null 2>&1 && leftovers+=("wings binary")

  if ((${#leftovers[@]})); then
    log "Detected possible previous installation remnants:"
    for item in "${leftovers[@]}"; do
      log " - ${item}"
    done
    echo
    echo "It is strongly recommended to run a cleanup before proceeding."
    echo "1) Run uninstall now (if implemented)"
    echo "2) Proceed anyway"
    echo "0) Exit"
    read -rp "Your choice [1/2/0]: " ans
    case "$ans" in
      1) bash "${WORK_DIR}/uninstall.sh";;
      2) log "Proceeding despite detected remnants...";;
      0) log "Exiting."; exit 0;;
      *) log "Invalid choice, proceeding by default."; ;;
    esac
  fi
}

detect_leftovers

# --- Menu ---
while true; do
  echo
  echo "Pelican Installer — Main Menu"
  echo "================================="
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
