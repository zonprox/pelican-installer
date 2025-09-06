# Pelican Installer

A streamlined installer for **Pelican Panel** and **Wings** on Debian/Ubuntu, with Redis, PHP 8.4, UFW, SSL, Cloudflare support, and a TUI with pre-provisioning review.

**Repository**: [github.com/zonprox/pelican-installer](https://github.com/zonprox/pelican-installer)

## Features

- **Menu-driven `install.sh`**:
  - Install Panel, Wings, or both
  - SSL: Let’s Encrypt or Custom PEM
  - Update/Uninstall
- **Auto-config**:
  - PHP 8.4, Redis, MariaDB/SQLite
  - UFW (ports 22/80/443)
  - Public IP detection
- **Cloudflare** (optional):
  - Proxied A record
  - Nginx Real Client IP
- CLI provisioning, DB migrations, admin user creation
- Post-install summary

## Supported OS

- Debian 12
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

> **Note**: Run as `root` or with `sudo`.

## Quick Start

```bash
bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)
```

**Prompts**:
- Domain, email
- Database (MariaDB/SQLite)
- Admin credentials (auto-generated if blank)
- SSL: Let’s Encrypt or Custom PEM
- Cloudflare: API Token, Zone ID, DNS name

## Menu

1. Install Panel
2. Install Wings
3. Install Both
4. SSL Setup
5. Update Panel
6. Uninstall
0. Exit

## Paths

- Panel: `/var/www/pelican`
- Nginx: `/etc/nginx/sites-available/pelican.conf`
- Queue: `/etc/systemd/system/pelican-queue.service`
- Summary: `<install_dir>/pelican-install-summary.txt`

## SSL

- **Let’s Encrypt**: Auto-configures Nginx (HTTP → HTTPS).
- **Custom PEM**: Paste `FULLCHAIN` and `PRIVATE KEY`.
- **Cloudflare Origin Cert**: Use with proxy ON, SSL **Full (Strict)**.

## Cloudflare

- **API Token**: Permissions for `Zone.DNS: Edit`, `Zone.Zone: Read`.
- Provide Token, Zone ID, DNS name in installer.
- Creates proxied A record, configures Nginx for client IPs.

## Post-Install

- Visit: `https://<your-domain>/`
- Check services:
  ```bash
  systemctl status nginx php8.4-fpm mariadb redis-server pelican-queue pelican-wings
  ```

## Update

```bash
bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)
```
Select **Update Panel**.

## Uninstall

Menu → **Uninstall**: Removes Panel, Wings, or both.

## Security

- UFW: Ports 22/80/443.
- Keys: `/etc/ssl/private` (chmod 600).
- Rotate tokens, restrict SSH.

## Troubleshooting

- **Let’s Encrypt**: Check DNS/port 80.
- **Cloudflare IPs**: Verify `cloudflare-real-ip.conf`.
- **Queue**: `journalctl -u pelican-queue -f`.
- **Wings**: Update `/etc/pelican/wings.yml`.

## Project Layout

```plaintext
pelican-installer/
├── install.sh
├── scripts/
│   ├── lib/common.sh
│   ├── panel.sh
│   ├── wings.sh
│   ├── both.sh
│   ├── ssl.sh
│   ├── update.sh
│   └── uninstall.sh
└── README.md
```

## Contributing

PRs for OS support, non-interactive mode, security, or CI welcome.

## License

MIT © zonprox