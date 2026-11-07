#!/bin/bash
set -euo pipefail

ROOT="${AMD_TEST_ROOT:?AMD_TEST_ROOT must point to the staged package layout (see test-amd.sh)}"
CONFD_DIR="$(mktemp -d)"
trap 'rm -f "$CONFD_DIR/node_info.conf"; rmdir "$CONFD_DIR"' EXIT
info() { :; }
source "$ROOT/usr/lib/pve-mods/configure.d/node_info.sh"
node_info_defaults
ENABLE_AMD_GPU_INFO=1
ENABLE_GPU_HISTORY=1
DATA_PULL_INTERVAL=5
COLLECTOR_TIMEOUT=120
DEBUG_AMD=1
DEBUG_AMD_FILE="/tmp/amd-devices.json"
node_info_write_conf
node_info_defaults
node_info_load_conf
[[ "$ENABLE_AMD_GPU_INFO" == 1 && "$ENABLE_GPU_HISTORY" == 1 ]]
[[ "$DATA_PULL_INTERVAL" == 5 && "$COLLECTOR_TIMEOUT" == 120 ]]
[[ "$DEBUG_AMD" == 1 && "$DEBUG_AMD_FILE" == /tmp/amd-devices.json ]]
node_info_write_conf
grep -q '^amd_enabled=1$' "$NODE_INFO_CONF"
echo "AMD configuration round-trip passed"
