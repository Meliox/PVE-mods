#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
TARGET="$WORK/usr/share/pve-manager/js/pvemanagerlib.js"
PATCH="$ROOT/src/modules/node_search/patches/01-guest-network-overview.patch"
mkdir -p "$(dirname "$TARGET")"
cp "${PVE_MANAGER_JS:-/usr/share/pve-manager/js/pvemanagerlib.js}" "$TARGET"
if grep -qF "Ext.define('PVE.mod.GuestNetworkInfo'," "$TARGET"; then
    patch -d "$WORK" -p1 -F0 --batch --reverse < "$PATCH"
fi
cp "$TARGET" "$WORK/before.js"
patch -d "$WORK" -p1 -F0 --batch --forward < "$PATCH"
"${NODE:-node}" --check "$TARGET"
PVE_MANAGER_JS="$TARGET" "${NODE:-node}" --test "$ROOT/build/test/node-search.test.js"
if patch -d "$WORK" -p1 -F0 --batch --forward --dry-run < "$PATCH"; then
    echo "ERROR: patch must not apply twice" >&2
    exit 1
fi
patch -d "$WORK" -p1 -F0 --batch --reverse < "$PATCH"
cmp "$WORK/before.js" "$TARGET"
GRAPH_PATCH="$ROOT/src/modules/guest_summary/patches/01-guest-summary-graphs.patch"
if grep -qF "Ext.define('PVE.mod.GuestSummaryChart'," "$TARGET"; then
    patch -d "$WORK" -p1 -F0 --batch --reverse < "$GRAPH_PATCH"
fi
cp "$TARGET" "$WORK/no-modules.js"
patch -d "$WORK" -p1 -F0 --batch --forward < "$PATCH"
PVE_MANAGER_JS="$TARGET" "${NODE:-node}" --test "$ROOT/build/test/node-search.test.js"
patch -d "$WORK" -p1 -F0 --batch --forward < "$GRAPH_PATCH"
patch -d "$WORK" -p1 -F0 --batch --reverse < "$PATCH"
grep -qF "Ext.define('PVE.mod.GuestSummaryChart'," "$TARGET"
patch -d "$WORK" -p1 -F0 --batch --reverse < "$GRAPH_PATCH"
cmp "$WORK/no-modules.js" "$TARGET"
echo 'Node Search forward/reapply/reverse tests passed.'

mkdir -p "$WORK/configure.d" "$WORK/conf.d"
cp "$ROOT/src/modules/node_search/node_search.configure.sh" "$WORK/configure.d/node_search.sh"
for mod in node_info nag_screen oidc_console_access guest_summary; do
    printf '%s_defaults() { :; }\n%s_load_conf() { :; }\n' "$mod" "$mod" > "$WORK/configure.d/$mod.sh"
done
export PVE_MODs_CONFIGURE_D="$WORK/configure.d"
sed '$d' "$ROOT/src/scripts/pve-mods-configure" > "$WORK/configure-functions.sh"
source "$WORK/configure-functions.sh"
CONF_FILE="$WORK/pve-mods.conf"
CONFD_DIR="$WORK/conf.d"
NODE_SEARCH_CONF="$CONFD_DIR/node_search.conf"
MOD_NODE_INFO=1; MOD_NAG_SCREEN=0; MOD_OIDC_CONSOLE_ACCESS=1; MOD_GUEST_SUMMARY=0; MOD_NODE_SEARCH=1; PVE_TRIGGER_ENABLED=1
write_main_conf
MOD_NODE_SEARCH=0
_load_main_conf
[[ "$MOD_NODE_SEARCH" == 1 ]]
node_search_write_conf
echo '# preserved user note' >> "$NODE_SEARCH_CONF"
node_search_write_conf
grep -qF '# preserved user note' "$NODE_SEARCH_CONF"
NODES_PM="$WORK/Nodes.pm"
: > "$NODES_PM"
APPLY_PATCHES="$WORK/apply.sh"
REVERT_PATCHES="$WORK/revert.sh"
printf '#!/bin/bash\nprintf "apply:%%s\\n" "$1" >> "%s"\n' "$WORK/actions" > "$APPLY_PATCHES"
printf '#!/bin/bash\nprintf "revert:%%s\\n" "$1" >> "%s"\n' "$WORK/actions" > "$REVERT_PATCHES"
chmod +x "$APPLY_PATCHES" "$REVERT_PATCHES"
main <<< 6 > "$WORK/menu-disable"
_load_main_conf
[[ "$MOD_NODE_SEARCH/$MOD_GUEST_SUMMARY" == "0/0" ]]
main <<< 6 > "$WORK/menu-enable"
_load_main_conf
[[ "$MOD_NODE_SEARCH/$MOD_GUEST_SUMMARY" == "1/0" ]]
main <<< 4 > "$WORK/menu-other"
_load_main_conf
[[ "$MOD_NODE_INFO/$MOD_OIDC_CONSOLE_ACCESS/$MOD_GUEST_SUMMARY/$MOD_NODE_SEARCH/$PVE_TRIGGER_ENABLED" == "1/1/0/1/0" ]]
printf 'revert:node_search\napply:node_search\n' > "$WORK/expected-actions"
cmp "$WORK/actions" "$WORK/expected-actions"
echo 'Independent Node Search configuration tests passed.'
