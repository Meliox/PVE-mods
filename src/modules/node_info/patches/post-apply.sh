#!/usr/bin/env bash
# post-apply hook for the node_info mod.
# Runs after node_info patches are applied. Provided env: MOD_CONF, STASH_DIR,
# CONFD_DIR. When GPU history is enabled, creates the GPU RRD storage directory
# and installs/starts the service that records history around the clock; when
# disabled, removes that service again.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

GPU_RRD_DIR="/var/lib/rrdcached/db/pve-mods-gpu"

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

gpu_history="$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" gpu gpu_history 0)"

SERVICE_NAME="pve-mods-gpu-history.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
changed=0

# Only touch systemd when operating on the real root (not a test root).
manage_service=0
[[ "${PVE_MODs_ROOT:-/}" == "/" ]] && command -v systemctl &>/dev/null && manage_service=1

# Keeps the GPU collectors running without the web UI open, so history has no
# gaps. Runs as www-data like the collectors started from pveproxy.
service_unit() {
    cat <<'UNIT'
[Unit]
Description=pve-mods GPU history recorder
After=pveproxy.service rrdcached.service

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/perl -I/usr/share/perl5 -MPVE::PVEMods::ProcessManager=pve_mods_run_service -e 'pve_mods_run_service()'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
}

if [[ "$gpu_history" == "1" ]]; then
    if [[ ! -d "$GPU_RRD_DIR" ]]; then
        mkdir -p "$GPU_RRD_DIR"
        chown www-data:www-data "$GPU_RRD_DIR" 2>/dev/null || true
        echo "[pve-mods] Created GPU RRD directory: $GPU_RRD_DIR"
        changed=1
    fi

    if [[ "$manage_service" == "1" ]]; then
        if [[ "$(service_unit)" != "$(cat "$SERVICE_FILE" 2>/dev/null)" ]]; then
            service_unit > "$SERVICE_FILE"
            systemctl daemon-reload
            echo "[pve-mods] Installed $SERVICE_NAME"
            changed=1
        fi
        systemctl enable "$SERVICE_NAME" &>/dev/null || true
        # Restart so the service always runs with the current configuration
        if systemctl restart "$SERVICE_NAME"; then
            echo "[pve-mods] GPU history recording service (re)started"
        else
            echo "[pve-mods] WARNING: could not start $SERVICE_NAME" >&2
        fi
    fi
elif [[ "$manage_service" == "1" && -f "$SERVICE_FILE" ]]; then
    systemctl disable --now "$SERVICE_NAME" &>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "[pve-mods] Removed $SERVICE_NAME (GPU history disabled)"
    changed=1
fi

[[ "$changed" == "1" ]] && exit 100
exit 0
