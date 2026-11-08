#!/usr/bin/env bash
# post-revert hook for the node_info mod.
# Runs before node_info patches are reverted (module disabled via
# pve-mods-configure, or package uninstalled). Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Removes the GPU history recording service and the storage
# SMART collector service, and strips any
# capability granted to intel_gpu_top by the configure wizard, so www-data loses
# CAP_PERFMON again on disable/removal.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

# Stop and remove the GPU history recording service (see post-apply.sh).
SERVICE_NAME="pve-mods-gpu-history.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
changed=0
if [[ "${PVE_MODs_ROOT:-/}" == "/" && -f "$SERVICE_FILE" ]] && command -v systemctl &>/dev/null; then
    systemctl disable --now "$SERVICE_NAME" &>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "[pve-mods] Removed $SERVICE_NAME"
    changed=1
fi

# Likewise the storage SMART collector service (see post-apply.sh).
SMART_SERVICE_NAME="pve-mods-storage-smart.service"
SMART_SERVICE_FILE="/etc/systemd/system/$SMART_SERVICE_NAME"
if [[ "${PVE_MODs_ROOT:-/}" == "/" && -f "$SMART_SERVICE_FILE" ]] && command -v systemctl &>/dev/null; then
    systemctl disable --now "$SMART_SERVICE_NAME" &>/dev/null || true
    rm -f "$SMART_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf /run/pve-mods-smart
    echo "[pve-mods] Removed $SMART_SERVICE_NAME"
    changed=1
fi

finish() { [[ "$changed" == "1" ]] && exit 100; exit 0; }

[[ "${PVE_MODs_ROOT:-/}" == "/" ]] || finish
source "${PVE_MODs_INTEL_GPU_HELPER:-/usr/lib/pve-mods/intel-gpu-permissions.sh}" || exit 1
rc=0
intel_gpu_revoke_permission || rc=$?
case "$rc" in
    0) ;;
    100) changed=1 ;;
    *) exit "$rc" ;;
esac

finish
