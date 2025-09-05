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

bash "${THIS_DIR}/install_panel.sh"
echo
echo "Now proceeding to Wings installation..."
bash "${THIS_DIR}/install_wings.sh"
