#!/usr/bin/env bash
# post-apply hook for the oidc_console_access mod.
# Runs after oidc_console_access patches are applied. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. The shell API calls are 'protected' and served by
# pvedaemon, so it must reload Nodes.pm in addition to the pveproxy reload.
# The reload is deferred so the revert path (hook runs before `patch -R`) also
# picks up the final file content.
# Exit codes: 0 = no change, 100 = changed (reload pveproxy), other = error.

set -u

if ! systemd-run --quiet --on-active=5s --unit=pve-mods-reload-pvedaemon \
    systemctl reload-or-try-restart pvedaemon; then
    echo "[pve-mods] WARNING: Could not schedule pvedaemon reload. Run 'systemctl reload-or-try-restart pvedaemon' after the package operation finishes." >&2
fi

exit 100
