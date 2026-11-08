#!/usr/bin/env bash
# build/test/test-gpu.sh
#
# Runs the fixture-based tests for the node_info Intel and NVIDIA GPU support:
# device discovery, stats parsing, collector loop, GPU history (RRD), API merge
# and GUI helpers. Uses temporary fixture directories; needs no GPU and does not
# touch the live configuration. Requires Perl (JSON, RRDs, PVE::INotify and the
# PVE API modules), prove and Node.js. In CI the PVE modules come from
# fetch-proxmox-files.sh.
#
# Usage: test-gpu.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILES_DIR="$REPO_DIR/src/modules/node_info/files"

info() { echo "[gpu] $*"; }
warn() { echo "[gpu] WARNING: $*" >&2; }

for cmd in perl prove node; do
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

rc=0

info "Running Intel and NVIDIA collector, history and API tests"
prove "$SCRIPT_DIR/intel.t" "$SCRIPT_DIR/nvidia.t" || rc=1

info "Running GUI tests"
node --test "$SCRIPT_DIR/gpu-gui.test.js" || rc=1

exit "$rc"
