#!/usr/bin/env bash
# post-apply hook for the node_info mod.
# Runs after node_info patches are applied. Provided env: MOD_CONF, STASH_DIR,
# CONFD_DIR. Creates the GPU RRD storage directory when GPU history is enabled.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

GPU_RRD_DIR="/var/lib/rrdcached/db/pve-mod-gpu"

read_conf() {
    local file="$1" section="$2" key="$3" default="${4:-0}"
    [[ -f "$file" ]] || { echo "$default"; return; }
    local val
    val=$(awk -F= -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == k) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }
        }
    ' "$file")
    echo "${val:-$default}"
}

gpu_history="$(read_conf "${MOD_CONF:-/etc/pve-mod/conf.d/node_info.conf}" gpu gpu_history 0)"

if [[ "$gpu_history" == "1" && ! -d "$GPU_RRD_DIR" ]]; then
    mkdir -p "$GPU_RRD_DIR"
    chown www-data:www-data "$GPU_RRD_DIR" 2>/dev/null || true
    echo "[pve-mod] Created GPU RRD directory: $GPU_RRD_DIR"
    exit 100
fi

exit 0
