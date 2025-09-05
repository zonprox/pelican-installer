#!/usr/bin/env bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${THIS_DIR}/install_panel.sh"
echo
echo "Now proceeding to Wings installation..."
bash "${THIS_DIR}/install_wings.sh"
