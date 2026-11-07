#!/usr/bin/env bash
# post-revert hook for the oidc_console_access mod.
# Runs before oidc_console_access patches are reverted. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Schedules a deferred pvedaemon restart (after the
# revert has finished) and requests a pveproxy restart.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

systemd-run --quiet --on-active=5s --unit=pve-mods-restart-pvedaemon \
    systemctl restart pvedaemon 2>/dev/null || true

exit 100
