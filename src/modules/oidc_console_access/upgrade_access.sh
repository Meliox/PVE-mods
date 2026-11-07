#!/usr/bin/env bash
# upgrade_access.configure.sh - Configure module for pve-mods upgrade_access
#
# Sourced by pve-mods-configure. Requires CONFD_DIR and the helper functions
# (info, warn, ask) to be defined in the calling script before this file is
# sourced.
#
# Provides the standard four-function module API:
#   upgrade_access_defaults    — set variables to safe defaults
#   upgrade_access_load_conf   — parse /etc/pve-mods/conf.d/upgrade_access.conf
#   upgrade_access_configure   — ask which groups may upgrade / use the root shell
#   upgrade_access_write_conf  — write /etc/pve-mods/conf.d/upgrade_access.conf
#
# A feature's patch is enabled (upgrade=1 / shell=1) exactly when its group
# list is not empty.

UPGRADE_ACCESS_CONF="${CONFD_DIR}/upgrade_access.conf"

upgrade_access_defaults() {
    UPGRADE_ACCESS_UPGRADE_GROUPS=""
    UPGRADE_ACCESS_SHELL_GROUPS=""
}

_upgrade_access_read() {
    local line
    line=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$UPGRADE_ACCESS_CONF" 2>/dev/null | head -n1)
    echo "${line#*=}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

upgrade_access_load_conf() {
    [[ -f "$UPGRADE_ACCESS_CONF" ]] || return 0
    UPGRADE_ACCESS_UPGRADE_GROUPS="$(_upgrade_access_read upgrade_groups)"
    UPGRADE_ACCESS_SHELL_GROUPS="$(_upgrade_access_read shell_groups)"
    return 0
}

upgrade_access_configure() {
    echo "Members of these Proxmox groups skip the root@pam restriction. They also need"
    echo "Sys.Console on /nodes/<node>. Enter '-' to disable a feature, empty to keep it."
    local input
    input=$(ask "Groups allowed to use the node 'Upgrade' console [${UPGRADE_ACCESS_UPGRADE_GROUPS:-none}]")
    if [[ "$input" == "-" ]]; then UPGRADE_ACCESS_UPGRADE_GROUPS=""
    elif [[ -n "$input" ]]; then UPGRADE_ACCESS_UPGRADE_GROUPS="$(echo "$input" | tr -d '[:space:]')"; fi
    warn "Shell groups get a passwordless ROOT shell in the node 'Shell' tab."
    input=$(ask "Groups allowed to use the node 'Shell' tab without login [${UPGRADE_ACCESS_SHELL_GROUPS:-none}]")
    if [[ "$input" == "-" ]]; then UPGRADE_ACCESS_SHELL_GROUPS=""
    elif [[ -n "$input" ]]; then UPGRADE_ACCESS_SHELL_GROUPS="$(echo "$input" | tr -d '[:space:]')"; fi
    return 0
}

upgrade_access_write_conf() {
    local up=0 sh=0
    [[ -n "$UPGRADE_ACCESS_UPGRADE_GROUPS" ]] && up=1
    [[ -n "$UPGRADE_ACCESS_SHELL_GROUPS" ]] && sh=1
    mkdir -p "$CONFD_DIR"
    cat > "$UPGRADE_ACCESS_CONF" <<EOF
# pve-mods :: upgrade_access mod configuration
# Each feature is an independent patch; enable it with the flag and list the
# Proxmox groups (comma separated) that may use it. Members additionally need
# Sys.Console on /nodes/<node>.
[access]
# Upgrade console (Updates -> Upgrade, runs 'pveupgrade --shell' as root).
upgrade=${up}
upgrade_groups=${UPGRADE_ACCESS_UPGRADE_GROUPS}
# Node "Shell" tab without login prompt (passwordless ROOT shell).
shell=${sh}
shell_groups=${UPGRADE_ACCESS_SHELL_GROUPS}
EOF
}
