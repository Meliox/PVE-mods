#!/usr/bin/env bash
# build/test/test-lm-sensors.sh
#
# Runs the fixture-based tests for the node_info lm-sensors support: output
# sanitizing, DIMM/drive/CPU enrichment, the payload pipeline and collector loop
# (Perl), and the GUI helpers and renderers that consume the payload (Node.js).
# The GUI tests consume the payload the Perl collector produces for the shared
# fixture, so both sides are checked against the same contract. Needs no
# sensors hardware and does not touch the live configuration. Requires Perl
# with the JSON module, prove and Node.js.
#
# fixtures/lm_sensors hold `sensors -J` output, the only layout supported. They are
# numbered NN-<hardware>.json; add the next number and every data-driven test picks it up.
# All are formatted like the live collector's input (`python3 -m json.tool`, 4-space indent).
#
#   01 synthetic            hand-built to mirror prog/sensors/chips.c in lm-sensors
#   02 intel it8620         captured with `sensors -J` on the maintainer's machine
#
# The rest are hardware captured with the old `sensors -j` in Meliox/PVE-mods issues and
# converted to the -J layout (features keyed by sensor name, the old label in "label",
# units per libsensors). The values are real; the layout is derived:
#
#   03 dell t7910           issue 73   dual Xeon, repeated labels (4x SODIMM, 2x fan)
#   04 dell smm sodimm      issue 113  dell_smm with a SODIMM temperature
#   05 qnap soc dts         issue 87   QNAP, soc_dts + coretemp
#   06 it8786 4 drives      issue 88   it8786, NVMe and four drivetemp drives
#   07 hp pch 1 drive       issue 108  HP, pch_cannonlake and one drive
#   08 amd amdgpu 2 nvme    issue 112  AMD, amdgpu, two NVMe, Wi-Fi and NIC PHYs
#   09 amd ddr5 nvme        issue 331  AMD with a DDR5 spd5118 DIMM
#   10 raspberry pi 5       issue 102  cpu_thermal, RP1, two NVMe and a PWM fan
#   11 nct6779 14 drives    issue 153  nct6779 and fourteen drivetemp drives
#
# Usage: test-lm-sensors.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILES_DIR="$REPO_DIR/src/modules/node_info/files"

info() { echo "[lm-sensors] $*"; }
warn() { echo "[lm-sensors] WARNING: $*" >&2; }

for cmd in perl prove node; do
    command -v "$cmd" >/dev/null 2>&1 || { warn "'$cmd' command not found."; exit 1; }
done
perl -MJSON -e1 2>/dev/null || { warn "Perl module JSON not found; install libjson-perl."; exit 1; }

# Lay the module out the way the package installs it, per files.list
export NODE_INFO_TEST_ROOT
NODE_INFO_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$NODE_INFO_TEST_ROOT"' EXIT

while read -r src dest _; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    mkdir -p "$NODE_INFO_TEST_ROOT/$(dirname "$dest")"
    cp "$FILES_DIR/$src" "$NODE_INFO_TEST_ROOT/$dest"
done < "$FILES_DIR/files.list"

export LM_SENSORS_FIXTURES="$SCRIPT_DIR/fixtures/lm_sensors"
export LM_SENSORS_PAYLOADS="$NODE_INFO_TEST_ROOT/payloads"
mkdir -p "$LM_SENSORS_PAYLOADS"

rc=0

info "Running collector tests"
prove "$SCRIPT_DIR/lm-sensors.t" || rc=1

info "Generating the collector payloads for the GUI tests"
for fixture in "$LM_SENSORS_FIXTURES"/*.json; do
    name="$(basename "$fixture")"
    perl "$SCRIPT_DIR/lm-sensors-payload.pl" "$name" "$LM_SENSORS_PAYLOADS/$name" || rc=1
done

info "Running GUI tests"
node --test "$SCRIPT_DIR/lm-sensors.test.js" || rc=1

exit "$rc"
