#!/usr/bin/env bash
# post-revert hook for the node_info mod.
# Runs before node_info patches are reverted (module disabled via
# pve-mods-configure, or package uninstalled). Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Removes the GPU history recording service and strips any
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

finish() { [[ "$changed" == "1" ]] && exit 100; exit 0; }

bin="$(command -v intel_gpu_top 2>/dev/null || true)"
[[ -n "$bin" ]] || finish

command -v setcap &>/dev/null || finish
command -v getcap &>/dev/null || finish

if getcap "$bin" 2>/dev/null | grep -q 'cap_perfmon'; then
    setcap -r "$bin" 2>/dev/null || true
    echo "[pve-mods] Removed CAP_PERFMON from $bin"
fi

finish
