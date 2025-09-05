# Pelican Installer

A unified installer for **Pelican Panel** and **Wings** on Debian/Ubuntu. Includes Redis, PHP 8.4, UFW, SSL, Cloudflare integration, and a TUI with a pre-provisioning review screen.

**Repository**: [github.com/zonprox/pelican-installer](https://github.com/zonprox/pelican-installer)

## Features

- **Menu-driven `install.sh`**:
  - Install Panel, Wings, or both
  - SSL: Let’s Encrypt or Custom PEM
  - Update Panel
  - Uninstall
- **Auto-config**:
  - PHP 8.4 (Sury)
  - Redis (cache/session/queue)
  - MariaDB or SQLite
  - UFW (ports 22/80/443)
  - Public IP auto-detection
- **Cloudflare** (optional):
  - Proxied A record ("orange cloud")
  - Nginx Real Client IP
- **CLI provisioning**:
  - Database migrations
  - Admin user creation
  - Skip web installer
- Post-install summary saved

## Supported OS

- Debian 12 (Bookworm)
- Ubuntu 22.04 LTS (Jammy)
- Ubuntu 24.04 LTS (Noble)

> **Note**: Run commands as `root` or with `sudo`.

## Quick Start

1. **Download and run the installer**:
   ```bash
   bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)
   ```

### Input Prompts
- Domain, contact email
- Database (MariaDB/SQLite)
- Admin username/email/password (empty for auto-generated)
- SMTP (optional)
- **SSL**:
  - Let’s Encrypt (via Certbot)
  - Custom PEM (`-----BEGIN CERTIFICATE-----` and `-----BEGIN PRIVATE KEY-----`)
- **Cloudflare** (optional):
  - API Token, Zone ID, DNS name
  - Public IP (auto-detected, overridable)

Review screen confirms inputs before provisioning.

## Menu Options

1. Install Panel
2. Install Wings
3. Install Both
4. SSL: Issue/Configure
5. Update Panel
6. Uninstall
0. Exit

## Installation Paths

- Panel: `/var/www/pelican`
- Nginx vhost: `/etc/nginx/sites-available/pelican.conf`
- Queue unit: `/etc/systemd/system/pelican-queue.service`
- Summary: `<install_dir>/pelican-install-summary.txt`

## SSL Options

### Let’s Encrypt
- Certbot configures Nginx for HTTP → HTTPS.
- Ensure DNS points to server’s public IP.
- Cloudflare: Disable proxy during HTTP-01 validation if needed.

### Custom PEM
- Paste **FULLCHAIN/CRT** and **PRIVATE KEY**:
  ```plaintext
  -----BEGIN CERTIFICATE-----
  ...
  -----END CERTIFICATE-----
  -----BEGIN PRIVATE KEY-----
  ...
  -----END PRIVATE KEY-----
  ```
- Saved to:
  - Cert: `/etc/ssl/certs/<domain>.crt` (chmod 644)
  - Key: `/etc/ssl/private/<domain>.key` (chmod 600)

> **Cloudflare Origin Certs**: Use with proxy ON and SSL Mode **Full (Strict)**. Not trusted by browsers directly.

## Cloudflare Setup

1. **API Token**:
   - Cloudflare → My Profile → API Tokens → Create Token.
   - Permissions: `Zone.DNS: Edit`, `Zone.Zone: Read`.
   - Include your domain.
   - Copy API Token and Zone ID.
   - Provide in installer: Token, Zone ID, DNS name (e.g., `panel.example.com`), Public IP (auto-detected).
   - Script creates proxied A record and configures Nginx for client IPs.

2. **Origin Certificate** (optional):
   - Cloudflare → SSL/TLS → Origin Server → Create Certificate.
   - Select RSA, add hostnames, copy Cert and Key.
   - Use in installer’s Custom SSL mode.
   - Set Cloudflare SSL to **Full (Strict)**, proxy ON.

## Post-Installation

- Visit: `https://<your-domain>/`
- Log in with admin credentials (auto-generated if blank).
- Check services:
  ```bash
  systemctl status nginx php8.4-fpm mariadb redis-server pelican-queue pelican-wings
  ```

## Updating Panel

- Menu: Select **Update Panel**, or:
  ```bash
  bash <(curl -s https://raw.githubusercontent.com/zonprox/pelican-installer/main/install.sh)
  ```
  Choose **Update Panel** to fetch latest release, run migrations, and reload services.

## Uninstalling

- Menu: Select **Uninstall**, choose Panel, Wings, or both.
- Removes services, binaries, configs, and (optionally) database.

## Security

- UFW enables ports 22/80/443.
- Keys stored in `/etc/ssl/private` (chmod 600).
- Rotate API tokens, restrict SSH.

## Troubleshooting

- **Let’s Encrypt fails**: Check DNS and port 80. Toggle Cloudflare proxy OFF if needed.
- **Cloudflare IPs**: Verify `cloudflare-real-ip.conf` in Nginx, reload.
- **Queue issues**: Check `journalctl -u pelican-queue -f`.
- **Wings**: Replace `/etc/pelican/wings.yml` with Panel-generated config.

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

PRs welcome for:
- More OS support
- Non-interactive mode
- Security hardening
- CI workflow

## License

MIT © zonprox