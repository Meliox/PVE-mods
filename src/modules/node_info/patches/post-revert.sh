#!/usr/bin/env bash
# post-revert hook for the node_info mod.
# Runs before node_info patches are reverted (module disabled via
# pve-mod-configure, or package uninstalled). Provided env: MOD_CONF,
# STASH_DIR, CONFD_DIR. Strips any capability granted to intel_gpu_top by the
# configure wizard, so www-data loses CAP_PERFMON again on disable/removal.
# Exit codes: 0 = no change, 100 = changed (restart pveproxy), other = error.

set -u

bin="$(command -v intel_gpu_top 2>/dev/null || true)"
[[ -n "$bin" ]] || exit 0

command -v setcap &>/dev/null || exit 0
command -v getcap &>/dev/null || exit 0

if getcap "$bin" 2>/dev/null | grep -q 'cap_perfmon'; then
    setcap -r "$bin" 2>/dev/null || true
    echo "[pve-mod] Removed CAP_PERFMON from $bin"
fi

exit 0
