#!/usr/bin/env bash
# post-apply hook for the node_info mod.
# Runs after node_info patches are applied. Provided env: MOD_CONF, STASH_DIR,
# CONFD_DIR. When GPU history is enabled, creates the GPU RRD storage directory
# and installs/starts the service that records history around the clock; when
# disabled, removes that service again. Likewise installs/removes the root
# service that collects SMART data when storage health is enabled.
# Restores Intel GPU performance-counter permission when monitoring is enabled.
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

if [[ "${PVE_MODs_ROOT:-/}" == "/" ]]; then
    source "${PVE_MODs_INTEL_GPU_HELPER:-/usr/lib/pve-mods/intel-gpu-permissions.sh}" || exit 1
    action=intel_gpu_revoke_permission
    if [[ "$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" gpu intel_enabled)" == "1" \
            && "$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" debug intel_mode)" != "1" ]]; then
        action=intel_gpu_restore_permission
    fi
    rc=0
    "$action" || rc=$?
    case "$rc" in
        0) ;;
        100) changed=1 ;;
        *) echo "[pve-mods] WARNING: Intel GPU permission could not be updated; keeping Node Info installed." >&2 ;;
    esac
fi

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

# SMART queries need root, which pveproxy (www-data) does not have, so storage
# health runs them from a small root service that publishes its results to
# /run/pve-mods-smart for the collector to read. Installed only when storage
# health with SMART is enabled and smartctl is present (or debug mode is on,
# where the collector reads sample files instead).
storage_health="$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" storage_health enabled 0)"
storage_smart="$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" storage_health smart_enabled 1)"
storage_debug="$(read_conf "${MOD_CONF:-/etc/pve-mods/conf.d/node_info.conf}" debug storage_health_mode 0)"

SMART_SERVICE_NAME="pve-mods-storage-smart.service"
SMART_SERVICE_FILE="/etc/systemd/system/$SMART_SERVICE_NAME"

smart_service_unit() {
    cat <<'UNIT'
[Unit]
Description=pve-mods storage SMART collector
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/perl -I/usr/share/perl5 -MPVE::PVEMods::Collector::StorageHealth=smart_service_main -e 'smart_service_main()'
RuntimeDirectory=pve-mods-smart
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
Nice=10
IOSchedulingClass=idle
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
}

if [[ "$manage_service" == "1" ]]; then
    if [[ "$storage_health" == "1" && "$storage_smart" == "1" && "$storage_debug" != "1" ]] \
            && command -v smartctl &>/dev/null; then
        if [[ "$(smart_service_unit)" != "$(cat "$SMART_SERVICE_FILE" 2>/dev/null)" ]]; then
            smart_service_unit > "$SMART_SERVICE_FILE"
            systemctl daemon-reload
            echo "[pve-mods] Installed $SMART_SERVICE_NAME"
            changed=1
        fi
        systemctl enable "$SMART_SERVICE_NAME" &>/dev/null || true
        # Restart so the service always runs with the current configuration
        if systemctl restart "$SMART_SERVICE_NAME"; then
            echo "[pve-mods] Storage SMART service (re)started"
        else
            echo "[pve-mods] WARNING: could not start $SMART_SERVICE_NAME" >&2
        fi
    elif [[ -f "$SMART_SERVICE_FILE" ]]; then
        systemctl disable --now "$SMART_SERVICE_NAME" &>/dev/null || true
        rm -f "$SMART_SERVICE_FILE"
        systemctl daemon-reload
        echo "[pve-mods] Removed $SMART_SERVICE_NAME (storage SMART checks disabled)"
        changed=1
    fi
fi

[[ "$changed" == "1" ]] && exit 100
exit 0
