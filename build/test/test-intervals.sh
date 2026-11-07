#!/usr/bin/env bash
# build/test/test-intervals.sh
#
# Tests the node_info [intervals] settings (data_pull, collector_timeout):
#   - the configure wizard loads, writes and preserves them (configure -> save -> reload)
#   - the wizard and Config.pm accept and reject the same values
#   - Config.pm loads the wizard-written file; the worker keep-alive loop honours the timeout
# Needs only bash and core Perl; no Proxmox system or sensor hardware.
#
# Usage: test-intervals.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WIZARD="$REPO_DIR/src/modules/node_info/node_info.configure.sh"
VALUES="$SCRIPT_DIR/fixtures/interval-values.txt"

info() { echo "[intervals] $*"; }
warn() { echo "[intervals] WARNING: $*" >&2; }

command -v perl >/dev/null 2>&1 || { warn "'perl' command not found; install perl."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Helpers the wizard expects from pve-mods-configure; warnings are captured to a file
CONFD_DIR="$TMP"
LOAD_WARNINGS="$TMP/warnings"
: > "$LOAD_WARNINGS"
warn() { echo "$*" >> "$LOAD_WARNINGS"; }
info() { :; }
# shellcheck source=/dev/null
source "$WIZARD"

fail=0 count=0
check() { # description expected actual
    count=$((count + 1))
    if [[ "$2" == "$3" ]]; then
        echo "ok $count - $1"
    else
        echo "not ok $count - $1 (expected '$2', got '$3')"
        fail=1
    fi
}

load_fresh() {
    node_info_defaults
    node_info_load_conf
}

# Defaults
node_info_defaults
check "default data_pull" 1 "$DATA_PULL_INTERVAL"
check "default collector_timeout" 10 "$COLLECTOR_TIMEOUT"

# Fresh install: nothing saved yet, so the defaults are written
node_info_write_conf
load_fresh
check "defaults survive save and reload (data_pull)" 1 "$DATA_PULL_INTERVAL"
check "defaults survive save and reload (collector_timeout)" 10 "$COLLECTOR_TIMEOUT"

# Same accept/reject rules as Config.pm, from the shared value list
while IFS='|' read -r kind raw norm; do
    [[ -z "$kind" || "$kind" == \#* ]] && continue
    printf '[intervals]\ndata_pull=%s\ncollector_timeout=%s\n' "$raw" "$raw" > "$NODE_INFO_CONF"
    : > "$LOAD_WARNINGS"
    load_fresh
    if [[ "$kind" == accept ]]; then
        check "accept '$raw' (data_pull)" "$norm" "$DATA_PULL_INTERVAL"
        check "accept '$raw' (collector_timeout)" "$norm" "$COLLECTOR_TIMEOUT"
        check "accept '$raw' without warning" 0 "$(wc -l < "$LOAD_WARNINGS")"
    else
        check "reject '$raw' (data_pull keeps default)" 1 "$DATA_PULL_INTERVAL"
        check "reject '$raw' (collector_timeout keeps default)" 10 "$COLLECTOR_TIMEOUT"
        check "reject '$raw' warns once per option" 2 "$(wc -l < "$LOAD_WARNINGS")"
    fi
done < "$VALUES"

# Configure -> save -> reload keeps manually edited values
node_info_defaults
node_info_write_conf
sed -i -e 's/^data_pull=.*/data_pull=7/' -e 's/^collector_timeout=.*/collector_timeout=300/' "$NODE_INFO_CONF"
load_fresh
check "custom data_pull loaded" 7 "$DATA_PULL_INTERVAL"
check "custom collector_timeout loaded" 300 "$COLLECTOR_TIMEOUT"

# Configuring an unrelated feature must not reset them
ENABLE_UPS=1; UPS_DEVICE_NAME="ups@example"
node_info_write_conf
load_fresh
check "unrelated change saved" 1 "$ENABLE_UPS"
check "data_pull preserved after unrelated change" 7 "$DATA_PULL_INTERVAL"
check "collector_timeout preserved after unrelated change" 300 "$COLLECTOR_TIMEOUT"

# A second round trip is stable
node_info_write_conf
cp "$NODE_INFO_CONF" "$TMP/wizard.conf"
load_fresh
node_info_write_conf
check "repeated save is stable" "$(cat "$TMP/wizard.conf")" "$(cat "$NODE_INFO_CONF")"

# A rejected value in a saved file falls back to the default
sed -i 's/^collector_timeout=.*/collector_timeout=0/' "$NODE_INFO_CONF"
load_fresh
check "invalid saved value falls back to default" 10 "$COLLECTOR_TIMEOUT"
check "valid sibling value kept" 7 "$DATA_PULL_INTERVAL"

echo "1..$count"
if (( fail )); then
    echo "[intervals] WARNING: wizard interval tests failed" >&2
    exit 1
fi

echo "[intervals] Running Config.pm and worker lifecycle tests"
INTERVALS_WIZARD_CONF="$TMP/wizard.conf" perl "$SCRIPT_DIR/test-intervals.t"
