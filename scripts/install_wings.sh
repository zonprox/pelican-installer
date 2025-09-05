#!/usr/bin/env bash
set -euo pipefail

# Bootstrap common.sh even if the script is run standalone
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"

COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
if [[ ! -f "${COMMON_LOCAL}" ]]; then
  mkdir -p "${PEL_CACHE_DIR}"
  # Use conditional fetch if already exists (first run it doesn't)
  curl -fsSL -o "${COMMON_LOCAL}.tmp" "${PEL_RAW_BASE}/common.sh"
  mv -f "${COMMON_LOCAL}.tmp" "${COMMON_LOCAL}"
fi
# shellcheck source=/dev/null
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base

say_info "Wings installer — Docker + wings binary + systemd + SSL."

# Basic prompts
prompt PANEL_URL "Panel URL (e.g. https://panel.example.com)"
prompt_choice WINGS_SSL "Wings SSL: letsencrypt/custom/none" "letsencrypt"
prompt WINGS_HOSTNAME "Wings hostname (node FQDN, e.g. wings01.example.com)" "$(hostname -f || echo wings.local)"

# If using Let's Encrypt on a headless wings box (no webserver), we’ll use certbot standalone
if [[ "$WINGS_SSL" == "custom" ]]; then
  echo; echo "Paste FULLCHAIN/CRT for ${WINGS_HOSTNAME}, then Ctrl+D:";  CERT_PEM="$(cat)"
  echo; echo "Paste PRIVATE KEY (PEM), then Ctrl+D:";                 umask 077; KEY_PEM="$(cat)"; umask 022
fi

# Quick review
echo
echo "── Review ─────────────────────────────────"
echo "Panel URL:       $PANEL_URL"
echo "Wings hostname:  $WINGS_HOSTNAME"
echo "Wings SSL mode:  $WINGS_SSL"
[[ "${WINGS_SSL}" == "custom" ]] && echo "Custom PEM headers: $(echo "$CERT_PEM" | head -n1) / $(echo "$KEY_PEM" | head -n1)"
echo "──────────────────────────────────────────"
read -rp "Proceed? (Y/n): " ok || true; ok="${ok:-Y}"
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Install Docker CE (official one-liner from docs) :contentReference[oaicite:9]{index=9}
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# Install wings (official path + arch switch) :contentReference[oaicite:10]{index=10}
mkdir -p /etc/pelican /var/run/wings
curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

# SSL layout for wings
WINGS_CERT="/etc/ssl/pelican/${WINGS_HOSTNAME}.crt"
WINGS_KEY="/etc/ssl/pelican/${WINGS_HOSTNAME}.key"
mkdir -p /etc/ssl/pelican

if [[ "$WINGS_SSL" == "letsencrypt" ]]; then
  # Use certbot standalone — docs: Creating SSL Certificates (standalone method suitable for wings-only). :contentReference[oaicite:11]{index=11}
  apt-get install -y certbot
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot standalone failed."
  ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "${WINGS_CERT}"
  ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"   "${WINGS_KEY}"
elif [[ "$WINGS_SSL" == "custom" ]]; then
  echo "$CERT_PEM" > "$WINGS_CERT"
  umask 077; echo "$KEY_PEM" > "$WINGS_KEY"; umask 022
  chmod 644 "$WINGS_CERT"; chmod 600 "$WINGS_KEY"
fi

# Systemd service (from docs) :contentReference[oaicite:12]{index=12}
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

say_info "Next step: create node in the Panel → Nodes → Create New → Configuration tab, copy config to /etc/pelican/config.yml, then start wings."
say_info "Docs: Wings ‘Configure’ step & ‘Starting/Daemonizing’."   # :contentReference[oaicite:13]{index=13}

# Try to start wings (will error until config.yml exists; that’s ok)
systemctl enable --now wings || true

echo
say_ok "Wings is set up. Ensure /etc/pelican/config.yml exists (from Panel → Node → Configuration) and restart: systemctl restart wings"
