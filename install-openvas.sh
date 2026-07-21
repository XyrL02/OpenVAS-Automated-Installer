#!/usr/bin/env bash
# =====================================================================
#  Standalone OpenVAS / GVM Installer for Kali Linux
#  No dependencies — copy this file to any Kali machine and run it.
#  Usage: sudo bash install-openvas.sh
# =====================================================================
set -euo pipefail

INSTALL_DIR="$HOME/openvas-gvm"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; CYAN='\e[36m'; RESET='\e[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[-]${RESET} $*"; }
info() { echo -e "${CYAN}[i]${RESET} $*"; }

echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}  OpenVAS / GVM — Standalone Installer for Kali Linux${RESET}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo ""

mkdir -p "$INSTALL_DIR" "$SCRIPTS_DIR"

# =====================================================================
# SECTION 1: Install GVM packages via apt
# =====================================================================
log "Installing OpenVAS / GVM packages..."

GVM_PACKAGES=(
    gvm gsad gvm-tools openvas-scanner ospd-openvas gvmd gvmd-common
    notus-scanner greenbone-feed-sync postgresql-18-pg-gvm python3-gvm
    python3-pontos libgvm22t64 xsltproc psmisc rsync
)

TO_INSTALL=()
for pkg in "${GVM_PACKAGES[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        info "$pkg already installed (skipping)"
    else
        TO_INSTALL+=("$pkg")
    fi
done

if [ ${#TO_INSTALL[@]} -gt 0 ]; then
    log "Installing ${#TO_INSTALL[@]} packages..."
    sudo apt-get update -qq 2>/dev/null || true
    sudo apt-get install -y "${TO_INSTALL[@]}" 2>&1 | tail -5
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        warn "Some packages failed — trying metapackage: gvm"
        sudo apt-get install -y gvm 2>&1 | tail -3
    fi
else
    info "All GVM packages already installed"
fi

# Verify key binaries
MISSING_BINS=()
for bin in gsad gvmd openvas gvm-cli; do
    command -v "$bin" &>/dev/null || MISSING_BINS+=("$bin")
done
if [ ${#MISSING_BINS[@]} -gt 0 ]; then
    warn "Missing binaries: ${MISSING_BINS[*]}"
    warn "Trying: sudo apt-get install -y gvm"
    sudo apt-get install -y gvm 2>&1 | tail -3
fi

# =====================================================================
# SECTION 2: PostgreSQL setup for GVM
# =====================================================================
log "Configuring PostgreSQL for GVM..."

if ! systemctl is-active --quiet postgresql 2>/dev/null; then
    log "Starting PostgreSQL..."
    sudo systemctl enable --now postgresql 2>/dev/null || {
        sudo pg_ctlcluster 18 main start 2>/dev/null || true
    }
fi

GVM_DB_USER="_gvm"
GVM_DB_NAME="gvmd"

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$GVM_DB_USER'" 2>/dev/null | grep -q 1; then
    log "Creating PostgreSQL user: $GVM_DB_USER"
    sudo -u postgres createuser -DRS "$GVM_DB_USER" 2>/dev/null || warn "User $GVM_DB_USER may already exist"
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$GVM_DB_NAME'" 2>/dev/null | grep -q 1; then
    log "Creating PostgreSQL database: $GVM_DB_NAME"
    sudo -u postgres createdb -O "$GVM_DB_USER" "$GVM_DB_NAME" 2>/dev/null || warn "Database $GVM_DB_NAME may already exist"
fi

sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $GVM_DB_NAME TO $GVM_DB_USER;" 2>/dev/null || true
sudo -u postgres psql -c "ALTER DATABASE $GVM_DB_NAME OWNER TO $GVM_DB_USER;" 2>/dev/null || true

# Enable required PostgreSQL extensions
log "Creating PostgreSQL extensions (pgcrypto, uuid-ossp, pg-gvm)..."
sudo runuser -u postgres -- /usr/share/gvm/create-postgresql-database 2>/dev/null || {
    sudo -u postgres psql -d "$GVM_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";" 2>/dev/null || true
    sudo -u postgres psql -d "$GVM_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" 2>/dev/null || true
    sudo -u postgres psql -d "$GVM_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_gvm;" 2>/dev/null || true
}

# Set password for _gvm user
GVM_DB_PASS=$(openssl rand -base64 16 2>/dev/null || head -c 16 /dev/urandom | base64)
GVM_DB_PASS="${GVM_DB_PASS//[^a-zA-Z0-9]/A}"
sudo -u postgres psql -c "ALTER USER $GVM_DB_USER WITH PASSWORD '$GVM_DB_PASS';" 2>/dev/null || true

# Save credentials
cat > "$INSTALL_DIR/creds.txt" << CREDS
═══════════════════════════════════════════════════════
 OpenVAS / GVM Credentials
═══════════════════════════════════════════════════════

--- Web UI ---
URL:      http://127.0.0.1:9392
Username: admin
Password: admin
(Change after first login)

--- PostgreSQL Database ---
Host:     localhost:5432
Database: $GVM_DB_NAME
Username: $GVM_DB_USER
Password: $GVM_DB_PASS
═══════════════════════════════════════════════════════
CREDS
chmod 600 "$INSTALL_DIR/creds.txt"
info "Credentials saved to: $INSTALL_DIR/creds.txt"

# =====================================================================
# SECTION 3: Initialize GVM database schema
# =====================================================================
log "Initializing GVM database..."

sudo mkdir -p /run/gvmd 2>/dev/null
sudo chown _gvm:_gvm /run/gvmd 2>/dev/null || true

sudo -u _gvm gvmd --migrate 2>/dev/null || {
    log "First-time DB init — starting gvmd briefly..."
    sudo -u _gvm gvmd 2>/dev/null &
    GVM_PID=$!
    sleep 5
    sudo kill $GVM_PID 2>/dev/null || true
}

# =====================================================================
# SECTION 4: Create systemd overrides for gsad and gvmd
# =====================================================================
log "Configuring systemd overrides..."

sudo mkdir -p /etc/systemd/system/gsad.service.d
sudo tee /etc/systemd/system/gsad.service.d/override.conf >/dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/gsad --http-only --listen 127.0.0.1 --port 9392 --mlisten 127.0.0.1 --mport 9390 --gnutls-options=
EOF

sudo mkdir -p /etc/systemd/system/gvmd.service.d
sudo tee /etc/systemd/system/gvmd.service.d/override.conf >/dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/gvmd --listen=127.0.0.1 --port=9390
EOF

sudo systemctl daemon-reload 2>/dev/null
log "Systemd overrides configured (gsad HTTP-only :9392, gvmd TCP :9390)"

# =====================================================================
# SECTION 5: Create GVM admin user
# =====================================================================
log "Setting up GVM admin user..."

sudo -u _gvm gvmd --create-user="admin:admin" 2>/dev \
    && info "Admin user created" \
    || info "Admin user may already exist (ok)"

# Set Feed Owner ID so the Task Wizard works out of the box
log "Setting Feed Owner ID in database..."
if sudo -u postgres psql -d gvmd -tAc "SELECT 1 FROM settings WHERE name='Feed Owner ID'" 2>/dev/null | grep -q 1; then
    info "Feed Owner ID already set"
else
    sudo -u postgres psql -d gvmd -c \
        "INSERT INTO settings (uuid, name, owner, value, comment) VALUES ('7865fcf0-aa31-4073-a2f4-a4aaae81cc9d', 'Feed Owner ID', 1, '1', 'Feed owner set to admin user');" 2>/dev/null \
        && info "Feed Owner ID set to admin" \
        || warn "Could not set Feed Owner ID (may need manual fix)"
fi

# =====================================================================
# SECTION 6: Feed synchronization
# =====================================================================
log "Syncing Greenbone vulnerability feeds (this may take a while on first run)..."

if command -v greenbone-feed-sync &>/dev/null; then
    greenbone-feed-sync 2>&1 | tail -5 || warn "Feed sync may need manual run later"
elif [ -f /usr/lib/gvm/scripts/greenbone-nvt-sync ]; then
    sudo -u _gvm /usr/lib/gvm/scripts/greenbone-nvt-sync 2>&1 | tail -3 || true
else
    warn "Feed sync tool not found — feeds will sync on first gsad start"
fi

# =====================================================================
# SECTION 7: Create management scripts
# =====================================================================
log "Creating management scripts..."

# --- gvm-start ---
cat > "$SCRIPTS_DIR/gvm-start" << 'STARTEOF'
#!/usr/bin/env bash
set -uo pipefail
GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; CYAN='\e[36m'; RESET='\e[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
err()  { echo -e "${RED}[-]${RESET} $*"; }

echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}  Starting Greenbone Vulnerability Management (GVM)${RESET}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"

# Ensure systemd overrides exist (self-healing)
if [ ! -f /etc/systemd/system/gsad.service.d/override.conf ]; then
    sudo mkdir -p /etc/systemd/system/gsad.service.d
    sudo tee /etc/systemd/system/gsad.service.d/override.conf >/dev/null << 'OVR'
[Service]
ExecStart=
ExecStart=/usr/bin/gsad --http-only --listen 127.0.0.1 --port 9392 --mlisten 127.0.0.1 --mport 9390 --gnutls-options=
OVR
    sudo systemctl daemon-reload 2>/dev/null
fi
if [ ! -f /etc/systemd/system/gvmd.service.d/override.conf ]; then
    sudo mkdir -p /etc/systemd/system/gvmd.service.d
    sudo tee /etc/systemd/system/gvmd.service.d/override.conf >/dev/null << 'OVR'
[Service]
ExecStart=
ExecStart=/usr/sbin/gvmd --listen=127.0.0.1 --port=9390
OVR
    sudo systemctl daemon-reload 2>/dev/null
fi

# 1. Start PostgreSQL
if ! systemctl is-active --quiet postgresql 2>/dev/null; then
    log "Starting PostgreSQL..."
    sudo systemctl start postgresql 2>/dev/null || sudo pg_ctlcluster 18 main start 2>/dev/null
fi

# 2. Create /run/gvmd with proper ownership
sudo mkdir -p /run/gvmd 2>/dev/null
sudo chown _gvm:_gvm /run/gvmd 2>/dev/null

# 3. Start gvmd
if ! pgrep -x gvmd >/dev/null 2>&1; then
    log "Starting gvmd..."
    sudo -u _gvm gvmd --listen=127.0.0.1 --port=9390 --database=gvmd --unix-socket=/run/gvmd/gvmd.sock 2>/dev/null &
    sleep 2
    pgrep -x gvmd >/dev/null 2>&1 && log "gvmd started (PID: $(pgrep -x gvmd))" || err "gvmd failed to start"
else
    log "gvmd already running (PID: $(pgrep -x gvmd))"
fi

# 4. Start ospd-openvas
if ! pgrep -f "ospd-openvas" >/dev/null 2>&1; then
    log "Starting ospd-openvas..."
    sudo -u _gvm ospd-openvas --unix-socket=/run/ospd/ospd-openvas.sock --pid-file=/run/ospd/ospd-openvas.pid --log-file=/var/log/gvm/ospd-openvas.log --lock-file-dir=/run/ospd 2>/dev/null &
    sleep 2
    pgrep -f "ospd-openvas" >/dev/null 2>&1 && log "ospd-openvas started" || err "ospd-openvas failed"
else
    log "ospd-openvas already running"
fi

# 5. Start gsad
if ! pgrep -x gsad >/dev/null 2>&1; then
    log "Starting gsad (web UI)..."
    sudo gsad --listen=127.0.0.1 --port=9392 --mlisten=127.0.0.1 --mport=9390 --gnutls-options="" 2>/dev/null &
    sleep 2
    pgrep -x gsad >/dev/null 2>&1 && log "gsad started — Web UI: http://127.0.0.1:9392" || err "gsad failed"
else
    log "gsad already running — Web UI: http://127.0.0.1:9392"
fi

echo ""
log "GVM Services:"
echo "  Web UI:       http://127.0.0.1:9392"
echo "  gvmd:         $(pgrep -x gvmd >/dev/null 2>&1 && echo 'RUNNING' || echo 'STOPPED')"
echo "  ospd-openvas: $(pgrep -f ospd-openvas >/dev/null 2>&1 && echo 'RUNNING' || echo 'STOPPED')"
echo "  gsad:         $(pgrep -x gsad >/dev/null 2>&1 && echo 'RUNNING' || echo 'STOPPED')"
echo ""
STARTEOF
chmod +x "$SCRIPTS_DIR/gvm-start"

# --- gvm-stop ---
cat > "$SCRIPTS_DIR/gvm-stop" << 'STOPEOF'
#!/usr/bin/env bash
set -uo pipefail
GREEN='\e[32m'; RESET='\e[0m'
log() { echo -e "${GREEN}[+]${RESET} $*"; }

echo "Stopping GVM services..."
for svc in gsad ospd-openvas gvmd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        sudo systemctl stop "$svc" 2>/dev/null
    fi
    if pgrep -x "$svc" >/dev/null 2>&1 || pgrep -f "$svc" >/dev/null 2>&1; then
        sudo pkill -x "$svc" 2>/dev/null || sudo pkill -f "$svc" 2>/dev/null
        sleep 1
        (pgrep -x "$svc" >/dev/null 2>&1 || pgrep -f "$svc" >/dev/null 2>&1) && sudo pkill -9 -x "$svc" 2>/dev/null || sudo pkill -9 -f "$svc" 2>/dev/null
        log "$svc stopped"
    else
        log "$svc not running (skipped)"
    fi
done
log "All GVM services stopped."
STOPEOF
chmod +x "$SCRIPTS_DIR/gvm-stop"

# --- gvm-status ---
cat > "$SCRIPTS_DIR/gvm-status" << 'STATUSEOF'
#!/usr/bin/env bash
set -uo pipefail
GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; CYAN='\e[36m'; RESET='\e[0m'

echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}  Greenbone Vulnerability Management — Status${RESET}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo ""

check_svc() {
    local name="$1" pid_check="$2"
    if eval "$pid_check" >/dev/null 2>&1; then
        PID=$(eval "$pid_check" | head -1)
        echo -e "  ${GREEN}RUNNING${RESET}  $name (PID: $PID)"
    else
        echo -e "  ${RED}STOPPED${RESET}  $name"
    fi
}

check_svc "gvmd"         "pgrep -x gvmd"
check_svc "ospd-openvas" "pgrep -f ospd-openvas"
check_svc "gsad"         "pgrep -x gsad"

echo ""
echo -e "  ${YELLOW}Web UI:${RESET} http://127.0.0.1:9392"

if systemctl is-active --quiet postgresql 2>/dev/null; then
    echo -e "  ${GREEN}POSTGRESQL:${RESET} running"
else
    echo -e "  ${RED}POSTGRESQL:${RESET} stopped"
fi
echo ""
STATUSEOF
chmod +x "$SCRIPTS_DIR/gvm-status"

# --- gvm-restart ---
cat > "$SCRIPTS_DIR/gvm-restart" << 'RESTARTEOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/gvm-stop"
sleep 2
"$SCRIPT_DIR/gvm-start"
RESTARTEOF
chmod +x "$SCRIPTS_DIR/gvm-restart"

# --- gvm-update-feeds ---
cat > "$SCRIPTS_DIR/gvm-update-feeds" << 'FEEDSEOF'
#!/usr/bin/env bash
set -uo pipefail
GREEN='\e[32m'; RESET='\e[0m'
log() { echo -e "${GREEN}[+]${RESET} $*"; }

log "Syncing Greenbone vulnerability feeds..."
if command -v greenbone-feed-sync &>/dev/null; then
    greenbone-feed-sync --type nvt 2>&1 | tail -5
    greenbone-feed-sync --type scap 2>&1 | tail -5
    greenbone-feed-sync --type cert 2>&1 | tail -5
elif [ -f /usr/lib/gvm/scripts/greenbone-nvt-sync ]; then
    sudo -u _gvm /usr/lib/gvm/scripts/greenbone-nvt-sync 2>&1 | tail -3
    sudo -u _gvm /usr/lib/gvm/scripts/greenbone-scapdata-sync 2>&1 | tail -3
    sudo -u _gvm /usr/lib/gvm/scripts/greenbone-certdata-sync 2>&1 | tail -3
else
    echo "Feed sync tools not found"
fi

log "Feed sync complete."
FEEDSEOF
chmod +x "$SCRIPTS_DIR/gvm-update-feeds"

# Symlink scripts to ~/.local/bin
mkdir -p "$HOME/.local/bin"
for script in gvm-start gvm-stop gvm-status gvm-restart gvm-update-feeds; do
    ln -sf "$SCRIPTS_DIR/$script" "$HOME/.local/bin/$script" 2>/dev/null || true
done

# =====================================================================
# SECTION 8: Log directories and permissions
# =====================================================================
sudo mkdir -p /var/log/gvm 2>/dev/null
sudo chown _gvm:_gvm /var/log/gvm 2>/dev/null || true
sudo mkdir -p /run/ospd 2>/dev/null
sudo chown _gvm:_gvm /run/ospd 2>/dev/null || true

# =====================================================================
# Done
# =====================================================================
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}[+]${RESET} OpenVAS / GVM installation complete!"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  Web UI:       http://127.0.0.1:9392"
echo "  Login:        admin / admin"
echo "  Credentials:  $INSTALL_DIR/creds.txt"
echo ""
echo "  Start:        gvm-start"
echo "  Stop:         gvm-stop"
echo "  Status:       gvm-status"
echo "  Restart:      gvm-restart"
echo "  Feed sync:    gvm-update-feeds"
echo ""
echo "  Scripts dir:  $SCRIPTS_DIR"
echo ""
