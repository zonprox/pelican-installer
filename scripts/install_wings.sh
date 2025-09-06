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

# ===== Inputs from wizard (install.sh) =====
: "${PANEL_URL:?missing PANEL_URL}"               # e.g. https://panel.example.com
: "${WINGS_ENDPOINT:?missing WINGS_ENDPOINT}"     # "domain" | "ip"
: "${WINGS_HOSTNAME:=}"                           # required if endpoint=domain
: "${WINGS_IP:=}"                                 # required if endpoint=ip
: "${WINGS_SSL:=letsencrypt}"                     # "letsencrypt" | "custom" | "none"
: "${WINGS_CERT_PEM_B64:=}"                       # required if custom
: "${WINGS_KEY_PEM_B64:=}"                        # required if custom

# ===== Validate endpoint and SSL =====
if [[ "$WINGS_ENDPOINT" == "domain" ]]; then
  [[ -n "$WINGS_HOSTNAME" ]] || { say_err "WINGS_HOSTNAME required for domain endpoint"; exit 1; }
elif [[ "$WINGS_ENDPOINT" == "ip" ]]; then
  [[ -n "$WINGS_IP" ]] || { say_err "WINGS_IP required for ip endpoint"; exit 1; }
  [[ "$WINGS_SSL" != "letsencrypt" ]] || { say_err "Let's Encrypt cannot issue certificates for IP addresses."; exit 1; }
else
  say_err "Invalid WINGS_ENDPOINT (must be 'domain' or 'ip')"; exit 1
fi

CN_RAW="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
CN_SAFE="$(echo "$CN_RAW" | tr ':./' '___')"

# ===== Ensure Docker (skip install if already present) =====
ensure_docker

# ===== Install wings binary =====
say_info "Installing wings binary…"
mkdir -p /etc/pelican /var/run/wings
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# ===== Provision SSL files (if any) =====
mkdir -p /etc/ssl/pelican
WINGS_CERT="/etc/ssl/pelican/${CN_SAFE}.crt"
WINGS_KEY="/etc/ssl/pelican/${CN_SAFE}.key"

case "$WINGS_SSL" in
  letsencrypt)
    apt-get install -y certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot standalone failed."
    # keep config.yml pointing to LE; we create convenience symlinks (optional)
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
    # no certs; config.yml will be patched to ssl.enabled: false
    ;;
  *) say_err "Invalid WINGS_SSL"; exit 1 ;;
esac

# ===== Create systemd unit (enable only; start after config is in place) =====
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
systemctl enable wings

# ===== Mandatory: paste config.yml → write → patch SSL → start =====
CFG="/etc/pelican/config.yml"
echo
echo "────────────────────────────────────────────────────────"
echo " Paste your Wings config.yml from Panel below"
echo " (End input with Ctrl+D)"
echo "────────────────────────────────────────────────────────"
tmp="$(mktemp)"
cat > "$tmp"

# Save config atomically
install -d -m 0755 /etc/pelican
[[ -f "$CFG" ]] && cp -f "$CFG" "${CFG}.bak.$(date +%s)" || true
mv -f "$tmp" "$CFG"
chmod 640 "$CFG"; chown root:root "$CFG"

# Optional: enforce 'remote:' to PANEL_URL if provided
if [[ -n "${PANEL_URL:-}" ]]; then
  remote_escaped="${PANEL_URL//\//\\/}"
  # If line exists -> replace; else append at end
  if grep -qE '^remote:' "$CFG"; then
    sed -Ei "s|^remote:.*$|remote: '${remote_escaped}'|" "$CFG" || true
  else
    echo "remote: '${PANEL_URL}'" >> "$CFG"
  fi
fi

# Patch SSL block according to selected mode
case "$WINGS_SSL" in
  custom)
    patch_wings_ssl_file "$CFG" "true" "$WINGS_CERT" "$WINGS_KEY"
    ;;
  letsencrypt)
    # force LE paths for selected hostname
    patch_wings_ssl_file "$CFG" "true" "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"
    ;;
  none)
    patch_wings_ssl_file "$CFG" "false" "/dev/null" "/dev/null"
    ;;
esac

# Start/restart wings now
if systemctl is-active --quiet wings; then
  systemctl restart wings || { journalctl -u wings --no-pager -n 150; exit 1; }
else
  systemctl start wings || { journalctl -u wings --no-pager -n 150; exit 1; }
fi

say_ok "Wings deployed successfully."
echo " - Endpoint : ${WINGS_ENDPOINT} (${CN_RAW})"
echo " - SSL mode : ${WINGS_SSL}"
echo " - Config   : ${CFG}"
[[ "$WINGS_SSL" != "none" ]] && { echo " - CERT     : ${WINGS_CERT}"; echo " - KEY      : ${WINGS_KEY}"; }
