#!/usr/bin/env bash
# post-apply hook for the oidc_console_access mod.
# Runs after oidc_console_access patches are applied. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. The shell API calls are 'protected' and served by
# pvedaemon, so it must reload Nodes.pm in addition to the pveproxy restart.
# The restart is deferred so the revert path (hook runs before `patch -R`) also
# picks up the final file content.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

systemd-run --quiet --on-active=5s --unit=pve-mods-restart-pvedaemon \
    systemctl restart pvedaemon 2>/dev/null || true

exit 100
