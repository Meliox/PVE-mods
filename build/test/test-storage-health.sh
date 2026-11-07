#!/usr/bin/env bash
# build/test/test-storage-health.sh
#
# Runs the fixture-based tests for the node_info storage health collector
# (zpool status / smartctl parsers and the health evaluation). Needs no Proxmox
# system, ZFS pools or drives; requires Perl with the JSON module.
#
# Usage: test-storage-health.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILES_DIR="$REPO_DIR/src/modules/node_info/files"

info() { echo "[storage-health] $*"; }
warn() { echo "[storage-health] WARNING: $*" >&2; }

command -v perl >/dev/null 2>&1 || { warn "'perl' command not found; install perl."; exit 1; }
perl -MJSON -e1 2>/dev/null || { warn "Perl module JSON not found; install libjson-perl."; exit 1; }

# Lay the module sources out the way the package installs them, per files.list
LIB_DIR="$(mktemp -d)"
trap 'rm -rf "$LIB_DIR"' EXIT

while read -r src dest _; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    [[ "$dest" == usr/share/perl5/* ]] || continue
    rel="${dest#usr/share/perl5/}"
    mkdir -p "$LIB_DIR/$(dirname "$rel")"
    cp "$FILES_DIR/$src" "$LIB_DIR/$rel"
done < "$FILES_DIR/files.list"

info "Running storage health tests"
STORAGE_HEALTH_FIXTURES="$SCRIPT_DIR/fixtures/storage_health" \
    perl -I"$LIB_DIR" "$SCRIPT_DIR/storage-health.t"
