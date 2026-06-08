#!/usr/bin/env bash
# post-apply hook for the nag_screen mod.
# Runs after nag_screen patches are applied. Provided env: MOD_CONF, STASH_DIR,
# CONFD_DIR. Replaces the minified proxmoxlib with a symlink to the patched
# unminified copy so the browser serves the patched code. The original minified
# file is stashed (it is a non-patch binary replacement, so `patch -R` cannot
# restore it). Exit codes: 0 = no change, 100 = changed, other = error.

set -u

PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PROXMOXLIB_MIN_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"
STASH_DIR="${STASH_DIR:-/var/lib/pve-mod/backup}"

if [[ ! -L "$PROXMOXLIB_MIN_JS" ]]; then
    mkdir -p "$STASH_DIR"
    if [[ -f "$PROXMOXLIB_MIN_JS" ]]; then
        mv "$PROXMOXLIB_MIN_JS" \
            "$STASH_DIR/proxmoxlib.min.js.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    ln -sf "$PROXMOXLIB_JS" "$PROXMOXLIB_MIN_JS"
    echo "[pve-mod] Symlinked proxmoxlib.min.js -> proxmoxlib.js"
    exit 100
fi

exit 0
