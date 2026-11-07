#!/usr/bin/env bash

GUEST_INFO_CONF="${CONFD_DIR}/guest_info.conf"

guest_info_defaults() { :; }
guest_info_load_conf() { :; }
guest_info_configure() { :; }
guest_info_write_conf() {
    if [[ ! -f "$GUEST_INFO_CONF" ]]; then
        cat > "$GUEST_INFO_CONF" <<EOF
# pve-mods :: guest_info
# No tunable settings. Enable or disable this module in the main configuration.
EOF
    fi
}
