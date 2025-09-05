#!/usr/bin/env bash
set -euo pipefail
: "${PEL_CACHE_DIR:=/var/cache/pelican-installer}"
: "${PEL_RAW_BASE:=https://raw.githubusercontent.com/zonprox/pelican-installer/main/scripts}"

fetch() { mkdir -p "${PEL_CACHE_DIR}"; curl -fsSL -z "${PEL_CACHE_DIR}/$1" -o "${PEL_CACHE_DIR}/$1.tmp" "${PEL_RAW_BASE}/$1" && { [[ -s "${PEL_CACHE_DIR}/$1.tmp" ]] && mv -f "${PEL_CACHE_DIR}/$1.tmp" "${PEL_CACHE_DIR}/$1"; }; chmod +x "${PEL_CACHE_DIR}/$1" 2>/dev/null || true; }
fetch "install_panel.sh"; bash "${PEL_CACHE_DIR}/install_panel.sh"
echo; echo "Proceeding to Wings installation…"
fetch "install_wings.sh"; bash "${PEL_CACHE_DIR}/install_wings.sh"
