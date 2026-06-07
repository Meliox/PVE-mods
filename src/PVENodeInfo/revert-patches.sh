#!/usr/bin/env bash
# /usr/lib/pve-mod/revert-patches.sh
#
# Reverts all patches applied by apply-patches.sh.
# Restores PVE system files from backups in /var/lib/pve-mod/backup/.
# Called by prerm before package files are removed.

BACKUP_DIR="/var/lib/pve-mod/backup"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PVE_MOD_JS="/usr/share/pve-manager/js/PveMod_PveNodeStatusView.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

restore_latest() {
    local name="$1" target="$2"
    local latest
    latest=$(find "$BACKUP_DIR" -name "${name}.*" -type f -printf '%T+ %p\n' 2>/dev/null \
        | sort -r | head -n1 | awk '{print $2}')
    if [[ -n "$latest" ]]; then
        cp "$latest" "$target"
        info "Restored $(basename "$target") from backup"
    else
        warn "No backup found for ${name}; $target not restored"
    fi
}

CHANGED=false

# ── node-info: Nodes.pm ───────────────────────────────────────────────────────
if grep -qF "use PVE::API2::PVEMod_SensorInfo" "$NODES_PM" 2>/dev/null; then
    restore_latest "Nodes.pm" "$NODES_PM"
    CHANGED=true
fi

# ── node-info: pvemanagerlib.js ───────────────────────────────────────────────
if grep -qF "PveMod_PveNodeStatusView.js" "$PVE_MANAGER_JS" 2>/dev/null; then
    restore_latest "pvemanagerlib.js" "$PVE_MANAGER_JS"
    CHANGED=true
fi

# ── node-info: JS module file ─────────────────────────────────────────────────
if [[ -f "$PVE_MOD_JS" ]]; then
    rm -f "$PVE_MOD_JS"
    info "Removed PveMod_PveNodeStatusView.js"
    CHANGED=true
fi

# ── nag-screen: proxmoxlib.min.js symlink ────────────────────────────────────
if [[ -L "$PROXMOXLIB_MIN_JS" ]]; then
    rm -f "$PROXMOXLIB_MIN_JS"
    restore_latest "proxmoxlib.min.js" "$PROXMOXLIB_MIN_JS"
    CHANGED=true
fi

# ── nag-screen: proxmoxlib.js ────────────────────────────────────────────────
if grep -qF "// disable subscription nag screen" "$PROXMOXLIB_JS" 2>/dev/null; then
    restore_latest "proxmoxlib.js" "$PROXMOXLIB_JS"
    CHANGED=true
fi

# ── restart pveproxy if anything changed ─────────────────────────────────────
if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi
