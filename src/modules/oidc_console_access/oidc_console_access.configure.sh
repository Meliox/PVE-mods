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
    local input
    echo "Enabled features grant root access. Members also need Sys.Console on /nodes/<node>."

    if _oidc_console_access_ask_yes_no "Enable the node 'Upgrade' console? (Y/N)"; then
        input=$(ask "Groups allowed to use the node 'Upgrade' console (comma-separated; empty disables)")
        OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS="$(echo "$input" | tr -d '[:space:]')"
    else
        OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS=""
    fi

    warn "Shell access provides a passwordless ROOT shell on the node."
    if _oidc_console_access_ask_yes_no "Enable passwordless access to the node 'Shell' tab? (Y/N)"; then
        input=$(ask "Groups allowed to use the node 'Shell' tab (comma-separated; empty disables)")
        OIDC_CONSOLE_ACCESS_SHELL_GROUPS="$(echo "$input" | tr -d '[:space:]')"
    else
        OIDC_CONSOLE_ACCESS_SHELL_GROUPS=""
    fi
    return 0
}

_oidc_console_access_ask_yes_no() {
    local prompt="$1" input
    while true; do
        input=$(ask "$prompt")
        case "$input" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) warn "Please enter Y or N." ;;
        esac
    done
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
