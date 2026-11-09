#!/usr/bin/env bash

NODE_SEARCH_CONF="${CONFD_DIR}/node_search.conf"

node_search_defaults() { :; }
node_search_load_conf() { :; }
node_search_configure() { :; }
node_search_write_conf() {
    if [[ ! -f "$NODE_SEARCH_CONF" ]]; then
        cat > "$NODE_SEARCH_CONF" <<EOF
# pve-mods :: node_search
# No tunable settings. Enable or disable this module in the main configuration.
EOF
    fi
}
