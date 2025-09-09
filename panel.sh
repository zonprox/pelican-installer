#!/usr/bin/env bash
set -Eeuo pipefail

# Pelican Panel Installer (engine)
# Performs: Python venv + Pelican, project scaffold, Nginx, SSL, optional MariaDB placeholder
# Docs reference:
# - Install Pelican / Markdown extra: python -m pip install "pelican[markdown]"
# - Quickstart flow: pelican-quickstart
# https://docs.getpelican.com/en/latest/install.html
# https://docs.getpelican.com/en/latest/quickstart.html
# Publish helpers: https://docs.getpelican.com/en/latest/publish.html

CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    *) shift;;
  esac
done

if [[ -z "${CONFIG_FILE:-}" || ! -f "$CONFIG_FILE" ]]; then
  echo "Config file missing. Run via install.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

log() { echo -e "\033[1;36m➤\033[0m $*"; }
ok()  { echo -e "\033[1;32m✔\033[0m $*"; }
warn(){ echo -e "\033[1;33m⚠\033[0m $*"; }
err() { echo -e "\033[1;31m✖\033[0m $*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  echo unknown
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_base_packages() {
  local mgr; mgr="$(detect_pkg_mgr)"
  case "$mgr" in
    apt)
      apt_install curl git python3 python3-venv python3-pip nginx
      if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        apt_install certbot python3-certbot-nginx
      fi
      if [[ "$DB_MODE" == "mariadb" ]]; then
        apt_install mariadb-server mariadb-client
      fi
    ;;
    *)
      warn "Non-Debian/Ubuntu OS detected. Please ensure equivalent packages are installed: curl, git, python3, python3-venv, python3-pip, nginx, certbot(optional), mariadb(optional)."
    ;;
  esac
}

create_user_and_dirs() {
  id -u "$PELICAN_USER" >/dev/null 2>&1 || useradd -r -m -d "$PELICAN_DIR" -s /usr/sbin/nologin "$PELICAN_USER"
  mkdir -p "$PELICAN_DIR"
  chown -R "$PELICAN_USER":"$PELICAN_USER" "$PELICAN_DIR"
}

setup_python_and_pelican() {
  log "Setting up Python virtual environment & Pelican…"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip
  # Install Pelican w/ Markdown extra per docs
  python -m pip install "pelican[markdown]"
  ok "Pelican installed in venv: $VENV_DIR"
}

scaffold_project() {
  log "Scaffolding Pelican project…"
  local tmpans
  tmpans="$(mktemp)"

  # Feed answers to pelican-quickstart non-interactively (best-effort).
  # The prompt order may evolve; we provide sensible defaults.
  cat > "$tmpans" <<ANS
$PELICAN_DIR
$SITE_TITLE
$SITE_AUTHOR
$ADMIN_EMAIL
$SITE_URL
Y
UTC
en
Y
Y
Y
Y
N
N
ANS

  # Run as pelican user to own files
  sudo -u "$PELICAN_USER" bash -lc "
    set -e
    source '$VENV_DIR/bin/activate'
    cd /
    yes '' >/dev/null 2>&1 || true
    pelican-quickstart < '$tmpans'
  "

  # Ensure basic skeleton if quickstart changed prompts:
  sudo -u "$PELICAN_USER" bash -lc "
    mkdir -p '$PELICAN_DIR/content' '$PELICAN_DIR/output'
    [ -f '$PELICAN_DIR/pelicanconf.py' ] || cat > '$PELICAN_DIR/pelicanconf.py' <<PY
AUTHOR = '$SITE_AUTHOR'
SITENAME = '$SITE_TITLE'
SITEURL = '$SITE_URL'
PATH = 'content'
TIMEZONE = 'UTC'
DEFAULT_LANG = 'en'
PY
  "

  rm -f "$tmpans"
  ok "Project scaffolded at $PELICAN_DIR"
}

configure_nginx() {
  log "Configuring Nginx for ${SITE_DOMAIN} (${SSL_MODE})…"
  local server_root="$PELICAN_DIR/output"
  local site_file="/etc/nginx/sites-available/pelican"
  local site_link="/etc/nginx/sites-enabled/pelican"

  mkdir -p "$server_root"
  # minimal strong defaults; add HSTS only when SSL enabled
  cat > "$site_file" <<NGX
server {
    listen 80;
    server_name ${SITE_DOMAIN};
    root ${server_root};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX

  if [[ "$SSL_MODE" != "none" ]]; then
    # Upgrade to 443; keep 80 for ACME
    sed -i "1i \
server {\
    listen 80; \
    server_name ${SITE_DOMAIN}; \
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; } \
    location / { return 301 https://\$host\$request_uri; } \
}\n" "$site_file"
  fi

  ln -sf "$site_file" "$site_link"
  nginx -t
  systemctl restart nginx

  case "$SSL_MODE" in
    letsencrypt)
      mkdir -p /var/www/letsencrypt
      nginx -t && systemctl reload nginx
      certbot --nginx -d "$SITE_DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --non-interactive --redirect || {
        warn "Let's Encrypt failed; keeping HTTP only."
      }
    ;;
    custom)
      mkdir -p /etc/ssl/pelican
      echo
      echo "Paste your FULL CHAIN certificate (PEM), end with EOF on its own line:"
      cat > /etc/ssl/pelican/custom.crt
EOF
      echo "Paste your PRIVATE KEY (PEM), end with EOF on its own line:"
      cat > /etc/ssl/pelican/custom.key
EOF
      chmod 600 /etc/ssl/pelican/custom.*
      # inject ssl server block
      cat >> "$site_file" <<NGX
server {
    listen 443 ssl;
    server_name ${SITE_DOMAIN};
    root ${server_root};
    index index.html;

    ssl_certificate     /etc/ssl/pelican/custom.crt;
    ssl_certificate_key /etc/ssl/pelican/custom.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX
      nginx -t && systemctl reload nginx
    ;;
    none)
      : # nothing more
    ;;
  esac
  ok "Nginx configured."
}

prepare_database_placeholder() {
  if [[ "$DB_MODE" == "mariadb" ]]; then
    log "Preparing MariaDB placeholder (Pelican itself does not require DB)…"
    systemctl enable --now mariadb || true
    mysql -u root <<SQL || true
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "MariaDB ready (db: $DB_NAME, user: $DB_USER)."
  else
    log "SQLite placeholder selected (no action; not required by Pelican)."
  fi
}

first_build() {
  log "Performing first site build…"
  sudo -u "$PELICAN_USER" bash -lc "
    source '$VENV_DIR/bin/activate'
    cd '$PELICAN_DIR'
    # Create sample content if empty
    if [ ! -e content/hello.md ]; then
      mkdir -p content
      cat > content/hello.md <<MD
Title: Hello Pelican
Date: $(date +%Y-%m-%d)
Category: General

This is your first post generated by Pelican.
MD
    fi
    pelican content -o output -s pelicanconf.py
  "
  ok "Build complete → $PELICAN_DIR/output"
}

summary() {
  cat <<EOF

────────────────────────────────────────────────────────
Pelican Panel • Installation Summary
────────────────────────────────────────────────────────
Site:
  Title     : $SITE_TITLE
  Author    : $SITE_AUTHOR
  URL       : $SITE_URL
  Domain    : $SITE_DOMAIN

Paths:
  Project   : $PELICAN_DIR
  Content   : $PELICAN_DIR/content
  Output    : $PELICAN_DIR/output
  Virtualenv: $VENV_DIR

Web:
  Nginx     : enabled for ${SITE_DOMAIN}
  SSL Mode  : ${SSL_MODE}

Database (placeholder for future extensions):
  Mode      : ${DB_MODE}
  Name/User : ${DB_NAME}/${DB_USER}
  Password  : stored in $CONFIG_FILE

Next steps:
  # Build again when you add content
  sudo -u $PELICAN_USER bash -lc 'source $VENV_DIR/bin/activate && cd $PELICAN_DIR && pelican content -o output -s pelicanconf.py'

  # Preview locally (optional)
  sudo -u $PELICAN_USER bash -lc 'cd $PELICAN_DIR/output && python -m http.server 8000'
  → http://localhost:8000

EOF
}

main() {
  require curl
  ensure_base_packages
  create_user_and_dirs
  setup_python_and_pelican
  scaffold_project
  first_build
  configure_nginx
  prepare_database_placeholder
  summary
}

main
