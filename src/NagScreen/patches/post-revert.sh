#!/usr/bin/env bash
# post-revert hook for the nag_screen mod.
# Runs before nag_screen patches are reverted. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Removes the min.js symlink and restores the original
# minified file from the stash. Exit codes: 0 = no change, 100 = changed.

set -u

PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"
STASH_DIR="${STASH_DIR:-/var/lib/pve-mod/backup}"

if [[ -L "$PROXMOXLIB_MIN_JS" ]]; then
    rm -f "$PROXMOXLIB_MIN_JS"
    latest=$(find "$STASH_DIR" -name "proxmoxlib.min.js.*" -type f -printf '%T+ %p\n' 2>/dev/null \
        | sort -r | head -n1 | awk '{print $2}')
    if [[ -n "$latest" ]]; then
        cp "$latest" "$PROXMOXLIB_MIN_JS"
        echo "[pve-mod] Restored proxmoxlib.min.js from stash"
    fi
    exit 100
fi

exit 0
