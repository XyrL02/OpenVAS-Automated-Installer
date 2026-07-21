#!/usr/bin/env bash
# =====================================================================
#  OpenVAS / GVM Uninstaller for Kali Linux
#  Usage: bash uninstall-openvas.sh
# =====================================================================
set -uo pipefail

GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; CYAN='\e[36m'; RESET='\e[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
info() { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }

echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}  OpenVAS / GVM — Uninstaller for Kali Linux${RESET}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo ""

# Pre-flight: not root
if [ "$(id -u)" -eq 0 ]; then
    warn "Do NOT run as root. Run as: bash uninstall-openvas.sh"
    exit 1
fi

# 1. Stop all services
log "Stopping GVM services..."
for svc in gsad ospd-openvas gvmd; do
    if pgrep -x "$svc" >/dev/null 2>&1 || pgrep -f "$svc" >/dev/null 2>&1; then
        sudo pkill -x "$svc" 2>/dev/null || sudo pkill -f "$svc" 2>/dev/null
        sleep 1
        sudo pkill -9 -x "$svc" 2>/dev/null || sudo pkill -9 -f "$svc" 2>/dev/null
        log "  $svc stopped"
    fi
done

# 2. Remove management scripts
log "Removing management scripts..."
sudo rm -f /usr/local/bin/gvm-start /usr/local/bin/gvm-stop /usr/local/bin/gvm-status \
           /usr/local/bin/gvm-restart /usr/local/bin/gvm-update-feeds
# Also clean up any broken symlinks from previous installs
sudo find /usr/local/bin -maxdepth 1 -name 'gvm-*' -type l -delete 2>/dev/null
# Restore system originals if backed up
sudo mv /usr/bin/gvm-start.bak /usr/bin/gvm-start 2>/dev/null || true
info "Management scripts removed"

# 3. Remove systemd overrides
log "Removing systemd overrides..."
sudo rm -rf /etc/systemd/system/gsad.service.d /etc/systemd/system/gvmd.service.d
sudo systemctl daemon-reload 2>/dev/null || true
info "Systemd overrides removed"

# 4. Remove local install directory
INSTALL_DIR="$HOME/openvas-gvm"
if [ -d "$INSTALL_DIR" ]; then
    log "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    info "Removed $INSTALL_DIR"
fi

# 5. Remove PostgreSQL database and user
log "Removing PostgreSQL database and user..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS gvmd;" 2>/dev/null || true
sudo -u postgres psql -c "DROP OWNED BY _gvm CASCADE;" 2>/dev/null || true
sudo -u postgres psql -c "DROP ROLE IF EXISTS _gvm;" 2>/dev/null || true
info "PostgreSQL database and user removed"

# 6. Remove runtime directories
log "Cleaning runtime directories..."
sudo rm -rf /run/gvmd /run/ospd /var/log/gvm /var/lib/openvas/feed-update.lock 2>/dev/null || true
info "Runtime directories cleaned"

# 7. Optionally remove packages (ask user)
echo ""
echo -e "${YELLOW}Remove GVM packages? This will remove: gvm, gsad, gvmd, openvas-scanner, etc.${RESET}"
read -p "Remove packages? [y/N]: " REMOVE_PKGS
if [[ "$REMOVE_PKGS" =~ ^[Yy]$ ]]; then
    log "Removing GVM packages..."
    sudo apt-get remove --purge -y gvm gsad gvm-tools openvas-scanner ospd-openvas \
        gvmd gvmd-common notus-scanner greenbone-feed-sync 2>&1 | tail -5
    sudo apt-get autoremove -y 2>/dev/null || true
    info "Packages removed"
else
    info "Packages kept (run: sudo apt-get remove --purge gvm gsad gvmd to remove later)"
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}[+]${RESET} OpenVAS / GVM uninstalled!"
echo -e "${CYAN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  To reinstall: bash install-openvas.sh"
echo ""
