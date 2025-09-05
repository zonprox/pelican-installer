#!/usr/bin/env bash
set -euo pipefail

# ===== Repo coordinates (edit nếu đổi nhánh) =====
OWNER="zonprox"
REPO="pelican-installer"
BRANCH="main"

# ===== Resolve scripts dir (works for normal file or /dev/fd/*) =====
SELF="${BASH_SOURCE[0]}"
# If run via process substitution, $SELF looks like /dev/fd/63 → dirname=/dev/fd (no scripts there)
REPO_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null || echo "")"
SCRIPTS_DIR=""
if [[ -n "$REPO_DIR" && -d "${REPO_DIR}/scripts" && -f "${REPO_DIR}/scripts/common.sh" ]]; then
  SCRIPTS_DIR="${REPO_DIR}/scripts"
else
  # Bootstrap: fetch tarball to /tmp and re-exec from there
  TMPBASE="$(mktemp -d /tmp/${REPO}.XXXXXX)"
  TARBALL_URL="https://codeload.github.com/${OWNER}/${REPO}/tar.gz/refs/heads/${BRANCH}"
  echo "[INFO] Bootstrapping ${OWNER}/${REPO}@${BRANCH} → ${TMPBASE}"
  curl -fsSL "$TARBALL_URL" -o "${TMPBASE}/repo.tgz"
  mkdir -p "${TMPBASE}/src"
  tar -xzf "${TMPBASE}/repo.tgz" -C "${TMPBASE}/src" --strip-components=1
  chmod +x "${TMPBASE}/src"/install.sh "${TMPBASE}/src"/scripts/*.sh
  exec "${TMPBASE}/src/install.sh"  # re-exec from real tree
fi

# ===== From here on we have a real tree =====
# shellcheck source=scripts/common.sh
. "${SCRIPTS_DIR}/common.sh"

require_root
detect_os_or_die
say_info "Detected OS: ${OS_NAME}"

while :; do
  cat <<'MENU'

────────────────────────────────────────────
 Pelican Installer — Main Menu
────────────────────────────────────────────
 1) Install Panel
 2) Install Wings (with SSL options)
 3) Install Both (Panel then Wings)
 4) SSL Only (issue Let's Encrypt or use custom PEM)
 5) Update (Panel and/or Wings)
 6) Uninstall (Panel and/or Wings)
 7) Quit
MENU
  read -rp "Choose an option [1-7]: " choice || true

  case "${choice:-}" in
    1) bash "${SCRIPTS_DIR}/install_panel.sh" ;;
    2) bash "${SCRIPTS_DIR}/install_wings.sh" ;;
    3) bash "${SCRIPTS_DIR}/install_both.sh" ;;
    4) bash "${SCRIPTS_DIR}/install_ssl.sh" ;;
    5) bash "${SCRIPTS_DIR}/update.sh" ;;
    6) bash "${SCRIPTS_DIR}/uninstall.sh" ;;
    7) exit 0 ;;
    *) say_warn "Invalid choice." ;;
  esac
done
