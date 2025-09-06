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

# Inputs
: "${PANEL_URL:?missing PANEL_URL}"
: "${WINGS_ENDPOINT:?missing WINGS_ENDPOINT}"   # "domain" | "ip"
: "${WINGS_HOSTNAME:=}"                          # required if endpoint=domain
: "${WINGS_IP:=}"                                # required if endpoint=ip
: "${WINGS_SSL:=letsencrypt}"                    # "letsencrypt" | "custom" | "none"
: "${WINGS_CERT_PEM_B64:=}"
: "${WINGS_KEY_PEM_B64:=}"

# Validate endpoint
if [[ "$WINGS_ENDPOINT" == "domain" ]]; then
  [[ -n "$WINGS_HOSTNAME" ]] || { say_err "WINGS_HOSTNAME required for domain endpoint"; exit 1; }
elif [[ "$WINGS_ENDPOINT" == "ip" ]]; then
  [[ -n "$WINGS_IP" ]] || { say_err "WINGS_IP required for ip endpoint"; exit 1; }
  if [[ "$WINGS_SSL" == "letsencrypt" ]]; then
    say_err "Let's Encrypt cannot issue certificates for IP addresses. Choose custom or none."; exit 1
  fi
else
  say_err "Invalid WINGS_ENDPOINT (must be 'domain' or 'ip')"; exit 1
fi

# Normalize common name (for file naming)
CN_RAW="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
CN_SAFE="$(echo "$CN_RAW" | tr ':./' '___')"

say_info "Installing Docker CE…"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

say_info "Installing wings binary…"
mkdir -p /etc/pelican /var/run/wings
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# SSL files (optional)
mkdir -p /etc/ssl/pelican
WINGS_CERT="/etc/ssl/pelican/${CN_SAFE}.crt"
WINGS_KEY="/etc/ssl/pelican/${CN_SAFE}.key"

case "$WINGS_SSL" in
  letsencrypt)
    # only allowed for domain endpoint
    apt-get install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot standalone failed."
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "${WINGS_CERT}"
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"   "${WINGS_KEY}"
    ;;
  custom)
    [[ -n "$WINGS_CERT_PEM_B64" && -n "$WINGS_KEY_PEM_B64" ]] || { say_err "Custom SSL selected but no PEM provided"; exit 1; }
    base64 -d <<<"$WINGS_CERT_PEM_B64" > "$WINGS_CERT"
    umask 077; base64 -d <<<"$WINGS_KEY_PEM_B64" > "$WINGS_KEY"; umask 022
    chmod 644 "$WINGS_CERT"; chmod 600 "$WINGS_KEY"
    ;;
  none)
    # no cert provisioning
    ;;
  *)
    say_err "Invalid WINGS_SSL"; exit 1 ;;
esac

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

# Short guide (auto-filled)
echo "──────────────── Wings next steps ────────────────"
echo "1) In Panel: ${PANEL_URL} → Admin → Nodes → Create Node."
echo "   - Set the node's FQDN/IP to: ${CN_RAW}"
if [[ "$WINGS_SSL" == "none" ]]; then
  echo "   - Since Wings SSL = none, ensure your reverse proxy handles TLS or use HTTP."
else
  echo "   - Use the certificate you provisioned here when Panel generates config."
  echo "     CERT: ${WINGS_CERT}"
  echo "     KEY : ${WINGS_KEY}"
fi
echo "2) Copy the generated Configuration into /etc/pelican/config.yml"
echo "3) Then: sudo systemctl restart wings"
echo "──────────────────────────────────────────────────"

say_ok "Wings installed. Endpoint=${WINGS_ENDPOINT} (${CN_RAW}), SSL=${WINGS_SSL}"
