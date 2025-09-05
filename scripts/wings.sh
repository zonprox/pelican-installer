#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os

log "Pelican Wings – configuration"
prompt_input NODE_NAME "Wings node name" "pelican-node"
prompt_input NODE_DIR  "Wings data dir" "/var/lib/pelican"
prompt_input CONFIG_DIR "Wings config dir" "/etc/pelican"
prompt_input LOG_DIR "Wings log dir" "/var/log/pelican"

# Download source
echo
echo "You can provide a direct download URL for the Wings binary, or leave blank to try GitHub latest."
read -rp "Wings download URL (blank = auto): " WINGS_URL || true
prompt_input GITHUB_REPO "GitHub repo (owner/repo) for auto-detect" "pelican-dev/wings"

# Confirm
echo; echo "=========== REVIEW ==========="
echo "Node name:    $NODE_NAME"
echo "Data dir:     $NODE_DIR"
echo "Config dir:   $CONFIG_DIR"
echo "Log dir:      $LOG_DIR"
echo "URL:          ${WINGS_URL:-'(auto)'}"
echo "GitHub repo:  $GITHUB_REPO"
echo "=============================="
read -rp "Proceed? (Y/n): " OK || true; OK="${OK:-Y}"
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

install_prereqs
enable_ufw_web

# Docker (required by wings)
log "Installing Docker (engine + CLI)…"
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Create dirs
mkdir -p "$NODE_DIR" "$CONFIG_DIR" "$LOG_DIR"
useradd -r -s /bin/false pelican 2>/dev/null || true
chown -R pelican:pelican "$NODE_DIR" "$LOG_DIR"
chown -R root:root "$CONFIG_DIR"

# Download wings
BIN_PATH="/usr/local/bin/wings"
if [[ -n "${WINGS_URL:-}" ]]; then
  curl -fsSL "$WINGS_URL" -o "$BIN_PATH"
else
  # try GitHub latest asset named like wings_linux_amd64 or similar
  ASSET_URL="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.assets[]?.browser_download_url | select(test("linux.*amd64|x86_64"; "i"))' | head -n1)"
  [[ -z "$ASSET_URL" ]] && { error "Cannot auto-detect Wings asset from ${GITHUB_REPO}. Provide WINGS URL."; exit 1; }
  curl -fsSL "$ASSET_URL" -o "$BIN_PATH"
fi
chmod +x "$BIN_PATH"

# Basic config (you may replace with your real config from panel)
CONFIG_FILE="${CONFIG_DIR}/wings.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
cat > "$CONFIG_FILE" <<EOF
# Minimal example – replace with real panel-issued config later.
uuid: "$(uuidgen)"
token_id: "CHANGE_ME"
token: "CHANGE_ME"
api:
  host: 0.0.0.0
  port: 8080
system:
  root_directory: ${NODE_DIR}
  log_directory: ${LOG_DIR}
docker:
  network:
    name: pelican0
EOF
fi

# Systemd
cat >/etc/systemd/system/pelican-wings.service <<UNIT
[Unit]
Description=Pelican Wings
After=network-online.target docker.service
Requires=docker.service

[Service]
User=pelican
Group=pelican
ExecStart=${BIN_PATH} --config ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pelican-wings.service

echo -e "${GREEN}Wings installed.${NC} Edit config at ${CONFIG_FILE} or replace with the config from Panel. Logs: journalctl -u pelican-wings -f"
