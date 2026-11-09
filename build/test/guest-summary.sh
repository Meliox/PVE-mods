#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/root}/guest-summary-test.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
TARGET="$WORK/usr/share/pve-manager/js"
mkdir -p "$TARGET"
cp "${PVE_MANAGER_JS:-/usr/share/pve-manager/js/pvemanagerlib.js}" "$TARGET/pvemanagerlib.js"
PATCH="$ROOT/src/modules/guest_summary/patches/01-guest-summary-graphs.patch"
if grep -qF "Ext.define('PVE.mod.GuestSummaryChart'," "$TARGET/pvemanagerlib.js"; then
    patch -d "$WORK" -p1 -F0 --batch --reverse < "$PATCH"
fi
cp "$TARGET/pvemanagerlib.js" "$WORK/before.js"
patch -d "$WORK" -p1 -F0 --batch --forward < "$PATCH"
node --check "$TARGET/pvemanagerlib.js"
PVE_MANAGER_JS="$TARGET/pvemanagerlib.js" node --test "$ROOT/build/test/guest-summary.test.js"
if patch -d "$WORK" -p1 -F0 --batch --forward --dry-run < "$PATCH"; then
    echo "ERROR: patch must not apply twice" >&2
    exit 1
fi
patch -d "$WORK" -p1 -F0 --batch --reverse --dry-run < "$PATCH"
patch -d "$WORK" -p1 -F0 --batch --reverse < "$PATCH"
cmp "$WORK/before.js" "$TARGET/pvemanagerlib.js"

mkdir -p "$WORK/configure.d" "$WORK/conf.d"
cp "$ROOT/src/modules/guest_summary/guest_summary.configure.sh" "$WORK/configure.d/guest_summary.sh"
for mod in node_info nag_screen oidc_console_access node_search; do
    printf '%s_defaults() { :; }\n%s_load_conf() { :; }\n' "$mod" "$mod" > "$WORK/configure.d/$mod.sh"
done
PVE_MODs_CONFIGURE_D="$WORK/configure.d"
export PVE_MODs_CONFIGURE_D
sed '$d' "${PVE_MODS_CONFIGURATOR:-$ROOT/src/scripts/pve-mods-configure}" > "$WORK/configure-functions.sh"
source "$WORK/configure-functions.sh"
CONF_FILE="$WORK/pve-mods.conf"
CONFD_DIR="$WORK/conf.d"
GUEST_SUMMARY_CONF="$CONFD_DIR/guest_summary.conf"
MOD_NODE_INFO=1; MOD_NAG_SCREEN=0; MOD_OIDC_CONSOLE_ACCESS=1; MOD_GUEST_SUMMARY=1; MOD_NODE_SEARCH=0; PVE_TRIGGER_ENABLED=1
write_main_conf
MOD_NODE_INFO=0; MOD_OIDC_CONSOLE_ACCESS=0; MOD_GUEST_SUMMARY=0; PVE_TRIGGER_ENABLED=0
_load_main_conf
[[ "$MOD_NODE_INFO/$MOD_NAG_SCREEN/$MOD_OIDC_CONSOLE_ACCESS/$MOD_GUEST_SUMMARY/$PVE_TRIGGER_ENABLED" == "1/0/1/1/1" ]]
guest_summary_write_conf
echo '# preserved user note' >> "$GUEST_SUMMARY_CONF"
guest_summary_write_conf
grep -qF '# preserved user note' "$GUEST_SUMMARY_CONF"

NODES_PM="$WORK/Nodes.pm"
: > "$NODES_PM"
APPLY_PATCHES="$WORK/apply.sh"
REVERT_PATCHES="$WORK/revert.sh"
printf '#!/bin/bash\nprintf "apply:%%s\\n" "$1" >> "%s"\n' "$WORK/actions" > "$APPLY_PATCHES"
printf '#!/bin/bash\nprintf "revert:%%s\\n" "$1" >> "%s"\n' "$WORK/actions" > "$REVERT_PATCHES"
chmod +x "$APPLY_PATCHES" "$REVERT_PATCHES"
main <<< 5 > "$WORK/menu-disable"
_load_main_conf
[[ "$MOD_GUEST_SUMMARY" == 0 ]]
main <<< 5 > "$WORK/menu-enable"
_load_main_conf
[[ "$MOD_GUEST_SUMMARY" == 1 ]]
main <<< 4 > "$WORK/menu-other"
_load_main_conf
[[ "$MOD_NODE_INFO/$MOD_OIDC_CONSOLE_ACCESS/$MOD_GUEST_SUMMARY/$PVE_TRIGGER_ENABLED" == "1/1/1/0" ]]
printf 'revert:guest_summary\napply:guest_summary\n' > "$WORK/expected-actions"
cmp "$WORK/actions" "$WORK/expected-actions"
echo 'Guest graph patch forward/reapply/reverse and configuration preservation tests passed.'
