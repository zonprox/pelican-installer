#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/lib/common.sh"

require_root; detect_os
echo -e "${CYAN}Install BOTH Panel + Wings${NC}"
read -rp "Proceed? (Y/n): " OK || true; OK="${OK:-Y}"
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

bash "${ROOT_DIR}/scripts/panel.sh"
bash "${ROOT_DIR}/scripts/wings.sh"
