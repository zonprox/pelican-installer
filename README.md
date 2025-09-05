# Pelican Installer

A unified, batteries-included installer for Pelican Panel and Wings on Debian/Ubuntu. Features Redis-first architecture, PHP 8.4, UFW, SSL, Cloudflare integration, and a user-friendly TUI with a final "review" screen before provisioning.

🔗 **Repository**: [github.com/zonprox/pelican-installer](https://github.com/zonprox/pelican-installer)

## ✨ Features

- **Menu-driven `install.sh`**:
  - Install Pelican Panel
  - Install Pelican Wings
  - Install both Panel and Wings
  - SSL: Let’s Encrypt or Custom PEM (fullchain & private key)
  - Update Panel
  - Uninstall (Panel/Wings)
- **Auto-detections & sane defaults**:
  - PHP 8.4 (Sury)
  - Redis enabled (cache/session/queue)
  - MariaDB or SQLite
  - UFW auto-enabled (ports 22/80/443)
  - Public IP fetched automatically for Cloudflare DNS
- **Cloudflare integration (optional)**:
  - Create/update proxied A record (“orange cloud”)
  - Nginx Real Client IP configuration
- **CLI provisioning**:
  - Database migrations
  - Admin user creation
  - Skip web installer
- **Post-install summary** saved in the install directory

## ✅ Supported Operating Systems

- Debian 12 (Bookworm)
- Ubuntu 22.04 LTS (Jammy)
- Ubuntu 24.04 LTS (Noble)

> **Note**: Run all commands as `root` or with `sudo`.

## 🚀 Quick Start

1. **Get the installer**:
   ```bash
   git clone https://github.com/zonprox/pelican-installer.git
   cd pelican-installer
   ```

2. **Make scripts executable**:
   ```bash
   sudo chmod +x install.sh scripts/*.sh scripts/lib/common.sh
   ```

3. **Launch the menu**:
   ```bash
   sudo ./install.sh
   ```

### Input Prompts
You’ll be prompted for:
- Domain and contact email
- Database engine (MariaDB or SQLite)
- Admin username/email/password (leave empty for auto-generated credentials)
- SMTP settings (optional)
- **SSL mode**:
  - Let’s Encrypt (automatic via Certbot)
  - Custom PEM (paste full `-----BEGIN CERTIFICATE-----` and `-----BEGIN PRIVATE KEY-----`)
- **Cloudflare (optional)**:
  - API Token, Zone ID, DNS name
  - Public IP auto-detected (can override)

A **review screen** will display all inputs for confirmation before provisioning.

## 🧭 Menu Overview

1. Install Pelican Panel
2. Install Pelican Wings
3. Install BOTH (Panel + Wings)
4. SSL: Issue/Configure (Let's Encrypt or Custom PEM)
5. Update Panel
6. Uninstall (Panel/Wings)
0. Exit

## 📍 Default Installation Paths

- **Panel install directory**: `/var/www/pelican`
- **Nginx vhost**: `/etc/nginx/sites-available/pelican.conf`
- **Queue unit**: `/etc/systemd/system/pelican-queue.service`
- **Summary file**: `<install_dir>/pelican-install-summary.txt`

## 🔐 SSL Options

### Option A: Let’s Encrypt (Recommended for Direct Traffic)
- The installer uses Certbot to obtain a certificate and configures Nginx for HTTP → HTTPS redirects.
- Ensure your domain’s DNS points to the server’s public IP.
- If using Cloudflare, temporarily disable the proxy (orange cloud) during HTTP-01 validation if needed.

### Option B: Custom PEM
- Paste the full contents of your **FULLCHAIN/CRT** and **PRIVATE KEY** (PEM format), including:
  ```
  -----BEGIN CERTIFICATE-----
  ...
  -----END CERTIFICATE-----
  ```
  and
  ```
  -----BEGIN PRIVATE KEY-----
  ...
  -----END PRIVATE KEY-----
  ```
- Files are saved to:
  - Certificate: `/etc/ssl/certs/<domain>.crt` (chmod 644)
  - Key: `/etc/ssl/private/<domain>.key` (chmod 600)
- Nginx is configured for HTTP → HTTPS redirects.

> **Note**: Cloudflare Origin Certificates are trusted by Cloudflare but not by browsers. Use them with the orange cloud (proxy) ON and SSL Mode set to **Full (Strict)**.

## ☁️ Cloudflare Integration

### 1. Create a Cloudflare API Token
- Log in to Cloudflare → My Profile → API Tokens → Create Token.
- Use the **Edit zone DNS** template or a custom token with:
  - **Permissions**:
    - `Zone.DNS: Edit`
    - `Zone.Zone: Read` (recommended)
  - **Zone Resources**: Include your specific domain.
- Copy the **API Token** and **Zone ID** (found on your domain’s Overview page).
- In the installer, provide:
  - API Token
  - Zone ID
  - DNS record name (e.g., `panel.example.com`)
  - Public IP (auto-detected, but can be overridden)
- The script will:
  - Upsert a proxied A record (orange cloud)
  - Configure Nginx with a `cloudflare-real-ip.conf` include for proper client IP detection.

### 2. Create a Cloudflare Origin Certificate (Optional)
- Use for TLS from Cloudflare to the origin server:
  - Cloudflare Dashboard → Your domain → SSL/TLS → Origin Server → Create Certificate.
  - Select RSA private key type and desired validity period.
  - Add hostnames (e.g., `panel.example.com`).
  - Copy the **Origin Certificate** (CERT/FULLCHAIN) and **Private Key** (KEY/PEM).
- In the installer, select SSL mode = Custom and paste both.
- In Cloudflare SSL/TLS → Overview, set SSL mode to **Full (Strict)** and ensure the DNS record has the orange cloud ON.

> **Reminder**: Origin Certificates are not trusted by browsers when accessing the origin directly.

## 🧪 Post-Installation

- Visit: `https://<your-domain>/`
- Log in with the admin credentials (auto-generated if left blank).
- Check systemd services:
  ```bash
  systemctl status nginx
  systemctl status php8.4-fpm
  systemctl status mariadb           # if chosen
  systemctl status redis-server
  systemctl status pelican-queue
  systemctl status pelican-wings     # if installed
  ```

## 🔁 Updating the Panel

- From the main menu, select **Update Panel**, or run:
  ```bash
  cd pelican-installer
  sudo ./install.sh
  # Choose: Update Panel
  ```
- This fetches the latest release, runs `composer install` and `php artisan migrate`, then reloads services.

## 🗑 Uninstalling

- From the menu, select **Uninstall**, then choose:
  - Panel only
  - Wings only
  - Both
- The script stops services, removes units/binaries/configs, and optionally drops the database.

## 🧱 Security Notes

- UFW is enabled with ports 22/80/443 allowed.
- Custom key files are stored in `/etc/ssl/private` with `0600` permissions.
- Rotate API tokens, use per-zone scopes, and restrict SSH access for enhanced security.

## 🐛 Troubleshooting

- **Let’s Encrypt fails (HTTP-01)**:
  - Ensure DNS resolves to the server and port 80 is reachable.
  - If using Cloudflare, toggle the proxy OFF during issuance, then re-enable.
- **Client IPs appear as Cloudflare IPs**:
  - Verify the `cloudflare-real-ip.conf` include exists in your Nginx server block and reload Nginx.
- **Queue not processing**:
  - Check logs: `journalctl -u pelican-queue -f`
- **Wings configuration**:
  - Replace the placeholder `/etc/pelican/wings.yml` with the real config generated by the Panel.

## 🧩 Project Layout

```
pelican-installer/
├── install.sh                # Main menu
├── scripts/
│   ├── lib/common.sh         # Shared helpers (logging, OS detection, etc.)
│   ├── panel.sh              # Install Panel
│   ├── wings.sh              # Install Wings (Docker required)
│   ├── both.sh               # Install both
│   ├── ssl.sh                # Issue/configure SSL
│   ├── update.sh             # Update Panel
│   └── uninstall.sh          # Uninstall safely
└── README.md
```

## 💬 Contributing

Pull requests are welcome! Suggested improvements:
- Expand OS coverage
- Add non-interactive/ENV mode
- Harden security defaults
- Implement CI workflow (linting, release artifacts)

## ⚖️ License

MIT © zonprox