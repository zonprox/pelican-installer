#!/usr/bin/env bash
set -Eeuo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
. "${COMMON_LOCAL}"

require_root
detect_os_or_die
install_base
ensure_docker

: "${PANEL_URL:?missing PANEL_URL}"
: "${WINGS_ENDPOINT:?missing WINGS_ENDPOINT}"     # domain|ip
: "${WINGS_HOSTNAME:=}"                            # if domain
: "${WINGS_IP:=}"                                  # if ip
: "${WINGS_SSL:=letsencrypt}"                      # letsencrypt|custom|none
: "${WINGS_CERT_PEM_B64:=}"                        # if custom
: "${WINGS_KEY_PEM_B64:=}"                         # if custom

if [[ "$WINGS_ENDPOINT" == "domain" ]]; then
  [[ -n "$WINGS_HOSTNAME" ]] || { say_err "WINGS_HOSTNAME required"; exit 1; }
elif [[ "$WINGS_ENDPOINT" == "ip" ]]; then
  [[ -n "$WINGS_IP" ]] || { say_err "WINGS_IP required"; exit 1; }
  [[ "$WINGS_SSL" != "letsencrypt" ]] || { say_err "LE cannot issue for IP"; exit 1; }
else
  say_err "Invalid WINGS_ENDPOINT"; exit 1
fi

CN_RAW="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
CN_SAFE="$(echo "$CN_RAW" | tr ':./' '___')"

# Preflight panel reachability (warn only)
say_info "Probing Panel → $PANEL_URL"
curl -Ik --max-time 8 "$PANEL_URL" >/tmp/panel_head.txt 2>&1 || say_warn "Panel not reachable now; ensure DNS & TLS ok."

# Wings binary
say_info "Installing wings binary…"
mkdir -p /etc/pelican /var/run/wings
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# SSL material
mkdir -p /etc/ssl/pelican
WINGS_CERT="/etc/ssl/pelican/${CN_SAFE}.crt"
WINGS_KEY="/etc/ssl/pelican/${CN_SAFE}.key"

case "$WINGS_SSL" in
  letsencrypt)
    ensure_pkg certbot
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "${WINGS_HOSTNAME}" --agree-tos -m "admin@${WINGS_HOSTNAME}" --non-interactive || say_warn "Certbot failed."
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "${WINGS_CERT}"
    ln -sf "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem"   "${WINGS_KEY}"
    ;;
  custom)
    base64 -d <<<"${WINGS_CERT_PEM_B64:?}" > "$WINGS_CERT"
    umask 077; base64 -d <<<"${WINGS_KEY_PEM_B64:?}" > "$WINGS_KEY"; umask 022
    chmod 644 "$WINGS_CERT"; chmod 600 "$WINGS_KEY"
    ;;
  none) ;;
  *) say_err "Invalid WINGS_SSL"; exit 1 ;;
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
systemctl enable wings

# Paste config.yml
CFG="/etc/pelican/config.yml"
echo
echo "────────────────────────────────────────────────────────"
echo " Paste your Wings config.yml (from Panel) and press Ctrl+D"
echo "────────────────────────────────────────────────────────"
tmp="$(mktemp)"; cat > "$tmp"
[[ -f "$CFG" ]] && cp -f "$CFG" "${CFG}.bak.$(date +%s)" || true
mv -f "$tmp" "$CFG"; chmod 640 "$CFG"; chown root:root "$CFG"

# Force remote to PANEL_URL (if provided)
if [[ -n "${PANEL_URL:-}" ]]; then
  esc="${PANEL_URL//\//\\/}"
  if grep -qE '^remote:' "$CFG"; then
    sed -Ei "s|^remote:.*$|remote: '${esc}'|" "$CFG" || true
  else
    echo "remote: '${PANEL_URL}'" >> "$CFG"
  fi
fi

# Patch SSL
case "$WINGS_SSL" in
  custom)      patch_wings_ssl_file "$CFG" "true" "$WINGS_CERT" "$WINGS_KEY" ;;
  letsencrypt) patch_wings_ssl_file "$CFG" "true" "/etc/letsencrypt/live/${WINGS_HOSTNAME}/fullchain.pem" "/etc/letsencrypt/live/${WINGS_HOSTNAME}/privkey.pem" ;;
  none)        patch_wings_ssl_file "$CFG" "false" "/dev/null" "/dev/null" ;;
esac

# Port sanity — auto move if busy (8080→8090)
extract_port(){ awk 'BEGIN{f=0} /^api:/{f=1;next} f && /port:[[:space:]]*/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$1"; }
set_port(){ local cfg="$1" newp="$2"; sed -Ei "0,/^[[:space:]]*port:/s//  port: ${newp}/" "$cfg"; }

PORT="$(extract_port "$CFG")"; [[ -z "$PORT" ]] && PORT=8080
if port_busy "$PORT"; then
  for p in $(seq 8080 8090); do
    if ! port_busy "$p"; then
      set_port "$CFG" "$p"; PORT="$p"; say_warn "Port busy → switched Wings HTTP to $PORT"; break
    fi
  done
fi
open_port_ufw "$PORT"; open_port_ufw 2022

# Cloudflare hint for SFTP
if [[ "$WINGS_ENDPOINT" == "domain" ]]; then
  say_info "If ${WINGS_HOSTNAME} is behind Cloudflare, set DNS to 'DNS only' (grey) for SFTP (2022)."
fi

# Start/restart
if systemctl is-active --quiet wings; then
  systemctl restart wings || { journalctl -u wings --no-pager -n 100; exit 1; }
else
  systemctl start wings  || { journalctl -u wings --no-pager -n 100; exit 1; }
fi

say_ok "Wings deployed."
echo " - API Port : ${PORT}"
echo " - Config   : ${CFG}"
[[ "$WINGS_SSL" != "none" ]] && { echo " - CERT     : ${WINGS_CERT}"; echo " - KEY      : ${WINGS_KEY}"; }
