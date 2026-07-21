# OpenVAS Automated Installer

Standalone, zero-dependency installer for Greenbone Vulnerability Management (GVM) on Kali Linux. One command installs the full OpenVAS scanner stack, configures PostgreSQL, creates the admin user, and produces ready-to-use management scripts.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [First Boot & Waiting for Feeds](#first-boot--waiting-for-feeds)
4. [Accessing the Web UI](#accessing-the-web-ui)
5. [User Management](#user-management)
6. [Management Scripts](#management-scripts)
7. [Systemd Services](#systemd-services)
8. [Files & Locations](#files--locations)
9. [Troubleshooting](#troubleshooting)
10. [Uninstall](#uninstall)

---

## Requirements

- Kali Linux (tested on 2024.x / 2025.x)
- ~4 GB free disk space (NVT + SCAP + CERT feeds)
- Root / sudo access
- Internet connection (feed sync pulls ~1 GB from Greenbone community servers)

---

## Installation

### Option A: Clone and Run

```bash
git clone https://github.com/XyrL02/OpenVAS-Automated-Installer.git
cd OpenVAS-Automated-Installer
sudo bash install-openvas.sh
```

### Option B: Download and Run

```bash
curl -LO https://raw.githubusercontent.com/XyrL02/OpenVAS-Automated-Installer/main/install-openvas.sh
sudo bash install-openvas.sh
```

The script will:

| Step | Action |
|------|--------|
| 1 | Install GVM packages via apt (gvm, gsad, gvm-tools, notus-scanner, etc.) |
| 2 | Create PostgreSQL user `_gvm` and database `gvmd` with required extensions |
| 3 | Initialize the GVM database schema and set Feed Owner ID |
| 4 | Create systemd overrides (HTTP-only web UI on port 9392, gvmd TCP on 9390) |
| 5 | Create the admin user (`admin` / `admin`) |
| 6 | Sync vulnerability feeds (NVT, SCAP, CERT) |
| 7 | Create management scripts in `~/openvas-gvm/scripts/` |

> **Expected duration:** The full install takes 10-30 minutes depending on internet speed. The feed sync is the longest part.

After installation completes, you will see:

```
[+] OpenVAS / GVM installation complete!
  Web UI:       http://127.0.0.1:9392
  Login:        admin / admin
  Credentials:  ~/openvas-gvm/creds.txt
  Start:        gvm-start
  Stop:         gvm-stop
  Status:       gvm-status
  Restart:      gvm-restart
  Feed sync:    gvm-update-feeds
```

---

## First Boot & Waiting for Feeds

### Step 1: Start the Services

```bash
gvm-start
```

This starts PostgreSQL, gvmd, ospd-openvas, and gsad. You will see:

```
[+] Web UI: http://127.0.0.1:9392
[+] gvmd started (PID: XXXX)
[+] ospd-openvas started
[+] gsad started — Web UI: http://127.0.0.1:9392
```

### Step 2: Wait for Feeds to Fully Download

**Do NOT use the Task Wizard or run scans until feeds are fully synced.**

The Greenbone Community Feed syncs ~1 GB of vulnerability data on first run:

| Feed | Approximate Size | Contents |
|------|-----------------|----------|
| NVT (Network Vulnerability Tests) | ~600 MB | 95,000+ vulnerability check scripts |
| SCAP | ~1 GB | CVE, CPE, DFN-CERT, OpenVAS Feeds |
| CERT | ~170 MB | CERT-Bund advisories |

To monitor feed progress:

```bash
# Check NVT count
ls /var/lib/openvas/plugins/ | wc -l
# When fully synced: ~95,000+ files

# Watch the feed sync log
tail -f /tmp/gvm_feed_sync.log

# Check gvmd log for SCAP/CERT import progress
tail -f /var/log/gvm/gvmd.log
```

**Indicators that feeds are still downloading:**
- NVT plugin count is less than ~95,000
- `gvmd.log` shows "Importing SCAP data" or "Importing CERT data"
- The web UI shows a warning banner about outdated feeds
- Vulnerability scans return zero or very few results

**Indicators that feeds are fully synced:**
- NVT count is ~95,000+
- `gvmd.log` stops showing import messages
- Web UI shows no warning banner
- Running a scan produces results

> **Tip:** You can check feed status at any time with `gvm-status` and re-sync with `gvm-update-feeds`.

### Step 3: Confirm Services Are Running

```bash
gvm-status
```

Expected output:

```
══════════════════════════════════════════════════════════
  Greenbone Vulnerability Management — Status
══════════════════════════════════════════════════════════

  RUNNING  gvmd (PID: XXXX)
  RUNNING  ospd-openvas (PID: XXXX)
  RUNNING  gsad (PID: XXXX)

  Web UI: http://127.0.0.1:9392
  POSTGRESQL: running
```

---

## Accessing the Web UI

1. Open a browser on the same machine: **http://127.0.0.1:9392**
2. Log in with:
   - **Username:** `admin`
   - **Password:** `admin`
3. You will be prompted to change the password on first login — **do this immediately**

> **Note:** The web UI runs over plain HTTP (not HTTPS) on localhost. This is intentional — it avoids certificate issues and is secure when accessed locally. Do NOT expose port 9392 to the network without adding TLS.

### First-Time Wizard

After login, GVM walks you through a setup wizard:

1. **Welcome** — click Next
2. **Administration** — change the admin password (required)
3. **Feed Sync** — the wizard checks that NVT/SCAP/CERT feeds are present. Wait here until all three show as available. If they still show as "updating", wait longer and click "Check Again"
4. **Finish** — you're ready to scan

---

## User Management

### Create a New User

#### Via Web UI

1. Go to **Administration > Users**
2. Click **New User**
3. Fill in:
   - **Name** — full name
   - **Login** — username for login
   - **Email** — email address
   - **Password** — initial password (user will be prompted to change it)
   - **Role** — select from:
     - `Admin` — full access to all features, users, and settings
     - `User` — can create and manage own scans, reports, and targets
4. Click **Save**

#### Via Command Line

```bash
# Create a new user with a password
sudo -u _gvm gvmd --create-user="username:password"

# Example:
sudo -u _gvm gvmd --create-user="analyst:SecureP@ss123"
```

### List Existing Users

```bash
sudo -u _gvm gvmd --get-users
```

### Delete a User

```bash
sudo -u _gvm gvmd --delete-user="username"

# Example:
sudo -u _gvm gvmd --delete-user="analyst"
```

### Modify a User

```bash
# Change a user's password
sudo -u _gvm gvmd --modify-user="username" --new-password="newpassword"

# Example:
sudo -u _gvm gvmd --modify-user="analyst" --new-password="N3wSecureP@ss"
```

### User Roles

| Role | Capabilities |
|------|-------------|
| **Admin** | Full access: manage users, configure settings, run any scan, view all results |
| **User** | Run scans, view own reports, manage own targets and tasks. Cannot manage users or system settings |

### Best Practices

- Change the default `admin` password immediately
- Create separate user accounts for each team member
- Use the principle of least privilege — only grant Admin role when needed
- Review user access periodically via **Administration > Users**

---

## Management Scripts

All scripts are installed to `~/openvas-gvm/scripts/` and symlinked to `~/.local/bin/`.

| Command | Description |
|---------|-------------|
| `gvm-start` | Start all GVM services (PostgreSQL, gvmd, ospd-openvas, gsad) |
| `gvm-stop` | Stop all GVM services |
| `gvm-status` | Show running status of all services |
| `gvm-restart` | Stop then start all services |
| `gvm-update-feeds` | Re-sync NVT, SCAP, and CERT feeds from Greenbone community servers |

### Start

```bash
gvm-start
```

Starts PostgreSQL if stopped, creates required runtime directories, then starts gvmd, ospd-openvas, and gsad. Self-heals systemd overrides if they are missing.

### Stop

```bash
gvm-stop
```

Stops all services. Falls back to `pkill` if systemd stop fails.

### Status

```bash
gvm-status
```

Shows whether each service is running or stopped, plus PostgreSQL status.

### Restart

```bash
gvm-restart
```

Convenience wrapper: runs `gvm-stop`, waits 2 seconds, then runs `gvm-start`.

### Update Feeds

```bash
gvm-update-feeds
```

Runs `greenbone-feed-sync` for NVT, SCAP, and CERT feeds. Use this to refresh vulnerability data after initial installation.

---

## Systemd Services

The installer creates systemd overrides to make services work correctly on Kali:

### gsad (Web UI)

```
/etc/systemd/system/gsad.service.d/override.conf
```

- `--http-only` — disables HTTPS (avoids certificate connection reset)
- `--listen 127.0.0.1 --port 9392` — binds web UI to localhost
- `--mlisten 127.0.0.1 --mport 9390` — manager connection to gvmd

### gvmd (Manager)

```
/etc/systemd/system/gvmd.service.d/override.conf
```

- `--listen=127.0.0.1 --port=9390` — TCP listener for gsad connection

### Managing via systemctl

```bash
sudo systemctl start gsad
sudo systemctl stop gsad
sudo systemctl status gsad

sudo systemctl start gvmd
sudo systemctl stop gvmd
sudo systemctl status gvmd
```

> **Note:** The management scripts handle this automatically. Use `systemctl` directly only if you need fine-grained control.

---

## Files & Locations

| Path | Description |
|------|-------------|
| `~/openvas-gvm/` | Installation directory |
| `~/openvas-gvm/scripts/` | Management scripts |
| `~/openvas-gvm/creds.txt` | Credentials file (Web UI + PostgreSQL) |
| `~/.local/bin/gvm-*` | Symlinks to management scripts |
| `/var/lib/openvas/plugins/` | NVT plugin files (~95,000) |
| `/var/lib/gvm/data-objects/` | Feed metadata (SCAP, CERT) |
| `/var/lib/gvm/` | GVM database and data |
| `/var/log/gvm/` | Log files (gvmd.log, ospd-openvas.log) |
| `/etc/systemd/system/gsad.service.d/override.conf` | gsad systemd override |
| `/etc/systemd/system/gvmd.service.d/override.conf` | gvmd systemd override |
| `/run/gvmd/gvmd.sock` | Unix socket for local gvmd connection |
| `/run/ospd/ospd-openvas.sock` | Unix socket for scanner connection |

---

## Troubleshooting

### "Connection refused" on http://127.0.0.1:9392

```bash
# Check if gsad is running
gvm-status

# If stopped, start it
gvm-start

# If still failing, check logs
journalctl -u gsad --no-pager -n 20
```

### Web UI loads but shows "Connection error" or "GMP error"

gvmd is not running or gsad cannot reach it:

```bash
# Check gvmd
sudo systemctl status gvmd
pgrep -x gvmd

# Restart everything
gvm-restart
```

### "Feed owner not set" in Task Wizard

Feeds haven't finished syncing yet. Wait for the sync to complete:

```bash
# Monitor progress
tail -f /tmp/gvm_feed_sync.log

# When NVT count reaches ~95,000, try the wizard again
ls /var/lib/openvas/plugins/ | wc -l
```

### Feed sync is slow or stuck

```bash
# Check if another sync is running (Greenbone rate-limits concurrent syncs)
ps aux | grep greenbone-feed-sync

# Kill any stuck processes and retry
sudo pkill -f greenbone-feed-sync
gvm-update-feeds
```

### PostgreSQL not starting

```bash
sudo systemctl status postgresql
sudo pg_ctlcluster 18 main start
```

### Services won't start after reboot

```bash
# The management scripts handle this
gvm-start

# Or enable services to start on boot
sudo systemctl enable postgresql gsad gvmd
```

### Reset admin password

```bash
sudo -u _gvm gvmd --modify-user="admin" --new-password="newpassword"
```

---

## Uninstall

```bash
# Stop services
gvm-stop

# Remove packages
sudo apt-get remove -y gvm gsad gvm-tools openvas-scanner ospd-openvas gvmd notus-scanner greenbone-feed-sync

# Remove data
sudo rm -rf /var/lib/openvas /var/lib/gvm
sudo rm -rf /var/log/gvm
sudo rm -rf ~/openvas-gvm

# Remove systemd overrides
sudo rm -rf /etc/systemd/system/gsad.service.d
sudo rm -rf /etc/systemd/system/gvmd.service.d
sudo systemctl daemon-reload

# Remove symlinks
rm -f ~/.local/bin/gvm-start ~/.local/bin/gvm-stop ~/.local/bin/gvm-status ~/.local/bin/gvm-restart ~/.local/bin/gvm-update-feeds

echo "OpenVAS / GVM removed."
```

---

## License

MIT

---

## Credits

- [Greenbone](https://www.greenbone.net/) for the OpenVAS / GVM stack
- Kali Linux team for packaging GVM in the default repositories
