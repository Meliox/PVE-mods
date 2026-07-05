#!/usr/bin/env bash
# nag_screen.configure.sh - Configure module for pve-mod nag_screen
#
# Sourced by pve-mod-configure. Requires CONFD_DIR to be defined in the
# calling script before this file is sourced.
#
# Provides the standard four-function module API:
#   nag_screen_defaults    — no-op (nag_screen has no tunable variables)
#   nag_screen_load_conf   — no-op (no tunable settings to load)
#   nag_screen_configure   — no-op (no interactive configuration needed)
#   nag_screen_write_conf  — write placeholder /etc/pve-mod/conf.d/nag_screen.conf

NAG_SCREEN_CONF="${CONFD_DIR}/nag_screen.conf"

nag_screen_defaults()  { :; }
nag_screen_load_conf() { :; }
nag_screen_configure() { :; }

nag_screen_write_conf() {
    # Only write the placeholder if it does not already exist; it has no
    # machine-managed values so there is nothing to update on re-runs.
    if [[ ! -f "$NAG_SCREEN_CONF" ]]; then
        cat > "$NAG_SCREEN_CONF" <<EOF
# pve-mod :: nag_screen mod configuration
# The nag-screen mod has no tunable settings; this file is a placeholder
# kept for consistency with the per-mod conf.d layout.
EOF
    fi
}
