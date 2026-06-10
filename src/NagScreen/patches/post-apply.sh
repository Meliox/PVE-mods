#!/usr/bin/env bash
# post-apply hook for the nag_screen mod.
# Runs after nag_screen patches are applied. Provided env: MOD_CONF, STASH_DIR,
# CONFD_DIR. Requests a pveproxy restart so the patched UI is served.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

exit 100