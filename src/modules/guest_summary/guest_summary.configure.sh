#!/usr/bin/env bash

GUEST_SUMMARY_CONF="${CONFD_DIR}/guest_summary.conf"

guest_summary_defaults() { :; }
guest_summary_load_conf() { :; }
guest_summary_configure() { :; }
guest_summary_write_conf() {
    if [[ ! -f "$GUEST_SUMMARY_CONF" ]]; then
        cat > "$GUEST_SUMMARY_CONF" <<EOF
# pve-mods :: guest_summary
# No tunable settings. Enable or disable this module in the main configuration.
EOF
    fi
}
