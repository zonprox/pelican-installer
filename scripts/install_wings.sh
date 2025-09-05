#!/usr/bin/env bash
set -euo pipefail
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON="${PEL_CACHE_DIR}/common.sh"; [[ -f "$COMMON" ]] || { mkdir -p "$PEL_CACHE_DIR"; curl -fsSL -o "$COMMON" "${PEL_RAW_BASE}/common.sh"; }
. "$COMMON"

require_root
detect_os_or_die
install_base

say_info "Wings — Docker + binary + systemd + SSL"

prompt PANEL_URL "Panel URL (e.g. https://panel.example.com)"
choice WSSL "Wings SSL (letsencrypt/custom/none)" "letsencrypt"
prompt HOST "Wings hostname (node FQDN)" "$(hostname -f || echo wings.local)"
CERT_PEM=""; KEY_PEM=""
if [[ "$WSSL" == "custom" ]]; then
  echo; echo "Paste FULLCHAIN/CRT for ${HOST}, then Ctrl+D:"; CERT_PEM="$(cat)"
  echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:"; umask 077; KEY_PEM="$(cat)"; umask 022
fi

echo
echo "Panel: $PANEL_URL"
echo "Host:  $HOST"
echo "SSL:   $WSSL"
read -rp "Proceed? (Y/n): " ok || true; ok="${ok:-Y}"
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Docker CE
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# Wings binary
mkdir -p /etc/pelican /var/run/wings
arch="$(uname -m)"; arch="${arch/x86_64/amd64}"; arch="${arch/aarch64/arm64}"
curl -fsSL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${arch}"
chmod u+x /usr/local/bin/wings

# SSL
mkdir -p /etc/ssl/pelican
CERT="/etc/ssl/pelican/${HOST}.crt"
KEY="/etc/ssl/pelican/${HOST}.key"
if [[ "$WSSL" == "letsencrypt" ]]; then
  apt-get install -y certbot
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "${HOST}" --agree-tos -m "admin@${HOST}" --non-interactive || say_warn "Certbot standalone failed."
  ln -sf "/etc/letsencrypt/live/${HOST}/fullchain.pem" "${CERT}"
  ln -sf "/etc/letsencrypt/live/${HOST}/privkey.pem"   "${KEY}"
elif [[ "$WSSL" == "custom" ]]; then
  echo "$CERT_PEM" > "$CERT"; umask 077; echo "$KEY_PEM" > "$KEY"; umask 022
  chmod 644 "$CERT"; chmod 600 "$KEY"
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
systemctl enable --now wings || true

say_info "Create node in Panel → copy Configuration to /etc/pelican/config.yml, then: systemctl restart wings"
