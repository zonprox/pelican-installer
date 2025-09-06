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

# ===== Inputs from wizard =====
: "${PANEL_URL:?missing PANEL_URL}"
: "${WINGS_ENDPOINT:?missing WINGS_ENDPOINT}"   # "domain" | "ip"
: "${WINGS_HOSTNAME:=}"                          # required if endpoint=domain
: "${WINGS_IP:=}"                                # required if endpoint=ip
: "${WINGS_SSL:=letsencrypt}"                    # "letsencrypt" | "custom" | "none"
: "${WINGS_CERT_PEM_B64:=}"
: "${WINGS_KEY_PEM_B64:=}"

# ===== Validate endpoint/SSL =====
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

# Common Name (for file naming)
CN_RAW="$([[ "$WINGS_ENDPOINT" == "domain" ]] && echo "$WINGS_HOSTNAME" || echo "$WINGS_IP")"
CN_SAFE="$(echo "$CN_RAW" | tr ':./' '___')"

# ===== Docker & wings binary =====
say_info "Installing Docker CE…"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

say_info "Installing wings binary…"
mkdir -p /etc/pelican /var/run/wings
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
curl -fL -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# ===== SSL material provisioning =====
mkdir -p /etc/ssl/pelican
WINGS_CERT="/etc/ssl/pelican/${CN_SAFE}.crt"
WINGS_KEY="/etc/ssl/pelican/${CN_SAFE}.key"

case "$WINGS_SSL" in
  letsencrypt)
    # only for domain
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
    # no files
    ;;
  *)
    say_err "Invalid WINGS_SSL"; exit 1 ;;
esac

# ===== Persist SSL prefs for auto-apply =====
cat >/etc/pelican/.ssl_prefs <<PREFS
MODE=${WINGS_SSL}
ENDPOINT=${WINGS_ENDPOINT}
CN_RAW=${CN_RAW}
HOSTNAME=${WINGS_HOSTNAME}
IP=${WINGS_IP}
CERT=${WINGS_CERT}
KEY=${WINGS_KEY}
PANEL_URL=${PANEL_URL}
PREFS
chmod 600 /etc/pelican/.ssl_prefs

# ===== Helper to force config.yml -> correct SSL block =====
cat >/usr/local/bin/pelican-wings-ssl <<'FIXER'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/pelican/config.yml"
PREF="/etc/pelican/.ssl_prefs"

usage(){ echo "Usage: pelican-wings-ssl apply"; exit 1; }
[[ "${1:-}" == "apply" ]] || usage
[[ -f "$PREF" ]] || { echo "[WARN] $PREF missing; nothing to apply."; exit 0; }
[[ -f "$CONF" ]] || { echo "[WARN] $CONF not found yet (paste or autodeploy config first)."; exit 0; }

# shellcheck disable=SC1090
. "$PREF"

# Decide target ssl block
case "${MODE}" in
  custom)
    SSL_ENABLED="true"
    SSL_CERT="${CERT}"
    SSL_KEY="${KEY}"
    ;;
  letsencrypt)
    if [[ "${ENDPOINT}" != "domain" || -z "${HOSTNAME}" ]]; then
      echo "[WARN] LE mode but no domain hostname; skipping."; exit 0
    fi
    SSL_ENABLED="true"
    SSL_CERT="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
    ;;
  none)
    SSL_ENABLED="false"
    SSL_CERT=""
    SSL_KEY=""
    ;;
  *)
    echo "[ERR ] Unknown MODE=${MODE}"; exit 1
    ;;
esac

# Build replacement block
TMP="$(mktemp)"
cat >"$TMP" <<BLOCK
  ssl:
    enabled: ${SSL_ENABLED}
BLOCK
if [[ "${SSL_ENABLED}" == "true" ]]; then
  cat >>"$TMP" <<BLOCK
    cert: ${SSL_CERT}
    key: ${SSL_KEY}
BLOCK
fi

# Rewrite api.ssl block in YAML (idempotent)
OUT="$(mktemp)"
awk -v repl="$(sed 's/[&/\]/\\&/g' "$TMP")" '
  BEGIN{in_api=0; in_ssl=0; injected=0}
  function print_repl(){ print repl; injected=1; }
  /^api:[[:space:]]*$/ { in_api=1; print; next }
  in_api && /^  ssl:[[:space:]]*$/ { print_repl(); in_ssl=1; next }
  in_ssl {
    # skip lines under old ssl block (indent >= 4 spaces)
    if ($0 ~ /^[[:space:]]{4}/) { next }
    # first line not indented at 4 spaces → ssl block ended
    in_ssl=0
  }
  in_api && !injected && /^  port:[[:space:]]*/ { print; print_repl(); next }
  # End api block detection: next top-level key
  in_api && /^[^[:space:]]/ { in_api=0 }
  { print }
' "$CONF" > "$OUT"

mv "$OUT" "$CONF"
rm -f "$TMP"
echo "[OK  ] Applied SSL (${MODE}) to $CONF"
FIXER
chmod +x /usr/local/bin/pelican-wings-ssl

# ===== systemd with ExecStartPre (auto-fix before start) =====
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
# Auto-fix config.yml SSL block based on /etc/pelican/.ssl_prefs
ExecStartPre=/usr/local/bin/pelican-wings-ssl apply
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

# ===== Post-install hint =====
echo "──────────────── Wings next steps ────────────────"
echo "1) In Panel: ${PANEL_URL} → Admin → Nodes → Create Node."
echo "   - Set the node endpoint to: ${CN_RAW}"
if [[ "$WINGS_SSL" == "none" ]]; then
  echo "   - Wings SSL = none → hãy đảm bảo có reverse proxy HTTPS ở phía trước."
elif [[ "$WINGS_SSL" == "letsencrypt" ]]; then
  echo "   - Wings SSL = Let's Encrypt → cert/key sẽ ở /etc/letsencrypt/live/${WINGS_HOSTNAME}/"
else
  echo "   - Wings SSL = Custom → cert=${WINGS_CERT} | key=${WINGS_KEY}"
fi
echo "2) Copy the generated Configuration vào /etc/pelican/config.yml"
echo "3) Chạy: sudo systemctl restart wings"
echo "   (ExecStartPre sẽ tự điều chỉnh lại api.ssl trong config.yml theo tuỳ chọn của bạn.)"
echo "──────────────────────────────────────────────────"

say_ok "Wings installed. Endpoint=${WINGS_ENDPOINT} (${CN_RAW}), SSL=${WINGS_SSL}"
