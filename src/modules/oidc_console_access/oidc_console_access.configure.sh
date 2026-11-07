#!/usr/bin/env bash
# oidc_console_access.configure.sh - Configure the oidc_console_access module
#
# Sourced by pve-mods-configure. Requires CONFD_DIR and the helper functions
# (info, warn, ask) to be defined in the calling script before this file is
# sourced.
#
# Provides the standard four-function module API:
#   oidc_console_access_defaults    — set variables to safe defaults
#   oidc_console_access_load_conf   — parse the module configuration
#   oidc_console_access_configure   — ask which groups may upgrade / use the root shell
#   oidc_console_access_write_conf  — write the module configuration
#
# A feature's patch is enabled (upgrade=1 / shell=1) exactly when its group
# list is not empty.

OIDC_CONSOLE_ACCESS_CONF="${CONFD_DIR}/oidc_console_access.conf"

oidc_console_access_defaults() {
    OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS=""
    OIDC_CONSOLE_ACCESS_SHELL_GROUPS=""
}

_oidc_console_access_read() {
    local line
    line=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$OIDC_CONSOLE_ACCESS_CONF" 2>/dev/null | head -n1)
    echo "${line#*=}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

oidc_console_access_load_conf() {
    [[ -f "$OIDC_CONSOLE_ACCESS_CONF" ]] || return 0
    OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS="$(_oidc_console_access_read upgrade_groups)"
    OIDC_CONSOLE_ACCESS_SHELL_GROUPS="$(_oidc_console_access_read shell_groups)"
    return 0
}

oidc_console_access_configure() {
    echo "Members of these Proxmox groups skip the root@pam restriction. They also need"
    echo "Sys.Console on /nodes/<node>. Enter '-' to disable a feature, empty to keep it."
    local input
    input=$(ask "Groups allowed to use the node 'Upgrade' console [${OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS:-none}]")
    if [[ "$input" == "-" ]]; then OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS=""
    elif [[ -n "$input" ]]; then OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS="$(echo "$input" | tr -d '[:space:]')"; fi
    warn "Shell groups get a passwordless ROOT shell in the node 'Shell' tab."
    input=$(ask "Groups allowed to use the node 'Shell' tab without login [${OIDC_CONSOLE_ACCESS_SHELL_GROUPS:-none}]")
    if [[ "$input" == "-" ]]; then OIDC_CONSOLE_ACCESS_SHELL_GROUPS=""
    elif [[ -n "$input" ]]; then OIDC_CONSOLE_ACCESS_SHELL_GROUPS="$(echo "$input" | tr -d '[:space:]')"; fi
    return 0
}

oidc_console_access_write_conf() {
    local up=0 sh=0
    [[ -n "$OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS" ]] && up=1
    [[ -n "$OIDC_CONSOLE_ACCESS_SHELL_GROUPS" ]] && sh=1
    mkdir -p "$CONFD_DIR"
    cat > "$OIDC_CONSOLE_ACCESS_CONF" <<EOF
# pve-mods :: oidc_console_access mod configuration
# Each feature is an independent patch; enable it with the flag and list the
# Proxmox groups (comma separated) that may use it. Members additionally need
# Sys.Console on /nodes/<node>.
[access]
# Upgrade console (Updates -> Upgrade, runs 'pveupgrade --shell' as root).
upgrade=${up}
upgrade_groups=${OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS}
# Node "Shell" tab without login prompt (passwordless ROOT shell).
shell=${sh}
shell_groups=${OIDC_CONSOLE_ACCESS_SHELL_GROUPS}
EOF
}
