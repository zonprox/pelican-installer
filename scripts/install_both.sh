#!/usr/bin/env bash
set -euo pipefail
# This orchestrator assumes env for panel has already been exported by loader's wizard_panel,
# and after panel finishes, loader's wizard_wings will export wings env and call install_wings.sh.
echo "[INFO] Use the loader menu option 'Install Both'. It already calls Panel wizard then Wings wizard."
