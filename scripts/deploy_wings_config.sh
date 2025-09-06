#!/usr/bin/env bash
set -euo pipefail

: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"
COMMON_LOCAL="${PEL_CACHE_DIR}/common.sh"
[[ -f "${COMMON_LOCAL}" ]] || { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -o "${COMMON_LOCAL}" "${PEL_RAW_BASE}/common.sh"; }
. "${COMMON_LOCAL}"

require_root

# Defaults/args
PANEL_URL_ARG=""; SSL_MODE_ARG="none"; CERT_PATH_ARG=""; KEY_PATH_ARG=""
ENDPOINT_ARG="domain"; CN_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-url) PANEL_URL_ARG="$2"; shift 2 ;;
    --ssl-mode)  SSL_MODE_ARG="$2"; shift 2 ;;
    --cert)      CERT_PATH_ARG="$2"; shift 2 ;;
    --key)       KEY_PATH_ARG="$2"; shift 2 ;;
    --endpoint)  ENDPOINT_ARG="$2"; shift 2 ;;
    --cn)        CN_ARG="$2"; shift 2 ;;
    *) say_warn "Unknown arg: $1"; shift ;;
  esac
done

CFG="/etc/pelican/config.yml"
mkdir -p /etc/pelican

say_info "Paste your Wings config.yml from Panel below, then press Ctrl+D:"
tmp="$(mktemp)"; cat > "$tmp"

# Save/backup
[[ -f "$CFG" ]] && cp -f "$CFG" "${CFG}.bak.$(date +%s)" || true
mv -f "$tmp" "$CFG"
chmod 640 "$CFG"; chown root:root "$CFG"

# Optional: enforce remote to Panel URL if provided
if [[ -n "$PANEL_URL_ARG" ]]; then
  sed -Ei "s|^remote:.*$|remote: '${PANEL_URL_ARG//'/'/\/}'|g" "$CFG" || true
fi

# Patch SSL depending on mode
case "$SSL_MODE_ARG" in
  custom)
    if [[ -z "$CERT_PATH_ARG" || -z "$KEY_PATH_ARG" ]]; then
      if guess_default_wings_certpair; then
        CERT_PATH_ARG="$GUESSED_CERT"; KEY_PATH_ARG="$GUESSED_KEY"
      else
        say_err "Custom SSL selected but no cert/key path provided and none detected."; exit 1
      fi
    fi
    patch_wings_ssl_file "$CFG" "true" "$CERT_PATH_ARG" "$KEY_PATH_ARG"
    ;;
  letsencrypt)
    # keep as the Panel generated (LE paths)
    patch_wings_ssl_file "$CFG" "true" "/etc/letsencrypt/live/${CN_ARG}/fullchain.pem" "/etc/letsencrypt/live/${CN_ARG}/privkey.pem"
    ;;
  none)
    patch_wings_ssl_file "$CFG" "false" "/dev/null" "/dev/null"
    ;;
esac

systemctl restart wings || (journalctl -u wings --no-pager -n 100; exit 1)
say_ok "Wings config deployed → $CFG (SSL=${SSL_MODE_ARG})."
