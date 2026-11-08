#!/usr/bin/env bash
# build/test/test-amd.sh
#
# Runs the fixture-based tests for the node_info AMD GPU support: sysfs/hwmon
# collector, GPU history (RRD), API merge, GUI helpers and wizard configuration.
# Uses temporary fixture directories; needs no AMD GPU and does not touch the
# live configuration. Requires Perl (JSON, RRDs, PVE::INotify and the PVE API
# modules), prove and Node.js. In CI the PVE modules come from
# fetch-proxmox-files.sh.
#
# Usage: test-amd.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOD_DIR="$REPO_DIR/src/modules/node_info"
FILES_DIR="$MOD_DIR/files"

info() { echo "[amd] $*"; }
warn() { echo "[amd] WARNING: $*" >&2; }

for cmd in perl prove node bash; do
    command -v "$cmd" >/dev/null 2>&1 || { warn "'$cmd' command not found."; exit 1; }
done
perl -MJSON -MRRDs -e1 2>/dev/null || { warn "Perl modules JSON and RRDs not found; install libjson-perl and librrds-perl."; exit 1; }

# Lay the module out the way the package installs it, per files.list
export AMD_TEST_ROOT
AMD_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$AMD_TEST_ROOT"' EXIT

while read -r src dest _; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    mkdir -p "$AMD_TEST_ROOT/$(dirname "$dest")"
    cp "$FILES_DIR/$src" "$AMD_TEST_ROOT/$dest"
done < "$FILES_DIR/files.list"
mkdir -p "$AMD_TEST_ROOT/usr/lib/pve-mods/configure.d"
cp "$MOD_DIR/node_info.configure.sh" "$AMD_TEST_ROOT/usr/lib/pve-mods/configure.d/node_info.sh"

rc=0

info "Running collector and history tests"
prove "$SCRIPT_DIR/gpu-amd.t" "$SCRIPT_DIR/amd-history.t" || rc=1

info "Running GUI tests"
node --test "$SCRIPT_DIR/amd-gui.test.js" || rc=1

info "Running wizard configuration test"
bash "$SCRIPT_DIR/amd-config.sh" || rc=1

exit "$rc"
