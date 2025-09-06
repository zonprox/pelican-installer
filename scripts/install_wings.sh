#!/usr/bin/env bash
set -euo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base

# Inputs (PANEL_URL may be empty here; we try to detect)
: "${PANEL_URL:=}"; : "${WINGS_HOSTNAME:?missing WINGS_HOSTNAME}"; : "${WINGS_SSL:=letsencrypt}"
: "${WINGS_CERT_PEM_B64:=}"; : "${WINGS_KEY_PEM_B64:=}"

# Auto-detect Panel URL on this system if not provided
if [[ -z "$PANEL_URL" ]] && panel_detect; then
  PANEL_URL="$PANEL_URL_DETECTED"
  say_info "Auto-detected Panel URL: ${PANEL_URL}"
fi

say_info "Installing Docker CE…"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

say_info "Installing wings binary…"
mkdir -p /etc/pelican /var/run/wings
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# SSL
mkdir -p /etc/ssl/pelican
WINGS_CERT="/etc/ssl/pelican/${WINGS_HOSTNAME}.crt"
WINGS_KEY="/etc/ssl/pelican/${WINGS_HOSTNAME}.key"
if [[ "$WINGS_SSL" == "letsencrypt" ]]; then
  apt-get install -y certbot
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot standalone failed."
  ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "${WINGS_CERT}"
  ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"   "${WINGS_KEY}"
elif [[ "$WINGS_SSL" == "custom" ]]; then
  [[ -n "$WINGS_CERT_PEM_B64" ]] && base64 -d <<<"$WINGS_CERT_PEM_B64" > "$WINGS_CERT"
  if [[ -n "$WINGS_KEY_PEM_B64" ]]; then umask 077; base64 -d <<<"$WINGS_KEY_PEM_B64" > "$WINGS_KEY"; umask 022; fi
  chmod 644 "$WINGS_CERT"; chmod 600 "$WINGS_KEY"
fi

# systemd
cat >/etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service
[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now wings || true  # may fail until config.yml exists

# Short guide (auto-filled if Panel URL available)
echo "──────────────── Wings next steps ────────────────"
if [[ -n "$PANEL_URL" ]]; then
  echo "1) In Panel: ${PANEL_URL} → Admin → Nodes → Create Node."
else
  echo "1) In Panel: <YOUR_PANEL_URL> → Admin → Nodes → Create Node."
fi
echo "2) Copy the generated Configuration into /etc/pelican/config.yml"
echo "3) Then: sudo systemctl restart wings"
echo "──────────────────────────────────────────────────"

say_ok "Wings installed. SSL: ${WINGS_SSL} (cert=${WINGS_CERT}, key=${WINGS_KEY})"
