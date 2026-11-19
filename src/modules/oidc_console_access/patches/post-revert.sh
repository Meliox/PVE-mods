#!/usr/bin/env bash
# post-revert hook for the oidc_console_access mod.
# Runs before oidc_console_access patches are reverted. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Schedules a deferred pvedaemon reload (after the
# revert has finished) and requests a pveproxy reload.
# Exit codes: 0 = no change, 100 = changed (reload pveproxy), other = error.

set -u

if ! systemd-run --quiet --on-active=5s --unit=pve-mods-reload-pvedaemon \
    systemctl reload-or-try-restart pvedaemon; then
    echo "[pve-mods] WARNING: Could not schedule pvedaemon reload. Run 'systemctl reload-or-try-restart pvedaemon' after the package operation finishes." >&2
fi

exit 100
