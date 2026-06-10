#!/usr/bin/env bash
# post-revert hook for the nag_screen mod.
# Runs before nag_screen patches are reverted. Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Requests a pveproxy restart so the original UI is served.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

exit 100
