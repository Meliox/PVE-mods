#!/usr/bin/env bash
# Verifies that enabling a module runs patch preflight without a false revert,
# while disabling or reconfiguring an applied module still reverts its patches.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "[test] $*" >&2; exit 1; }

MAIN_CONF="$TMP_DIR/pve-mods.conf"
CONFD_DIR="$TMP_DIR/conf.d"
NODES_PM="$TMP_DIR/Nodes.pm"
CONFIGURE_D="$TMP_DIR/configure.d"
PATCHES_DIR="$TMP_DIR/patches"
TEST_ROOT="$TMP_DIR/root"
CALLS="$TMP_DIR/systemctl-calls"
mkdir -p "$CONFD_DIR" "$CONFIGURE_D" "$PATCHES_DIR/node_info" \
    "$TEST_ROOT/usr/share/demo" "$TMP_DIR/bin"
: > "$NODES_PM"
: > "$CALLS"

cat > "$CONFIGURE_D/test-modules.sh" <<'STUB'
node_info_defaults() { :; }
node_info_load_conf() { :; }
node_info_configure() { :; }
node_info_write_conf() { printf '[gpu]\ngpu_history=0\n' > "$CONFD_DIR/node_info.conf"; }
nag_screen_defaults() { :; }
nag_screen_load_conf() { :; }
nag_screen_configure() { :; }
nag_screen_write_conf() { :; }
oidc_console_access_defaults() { :; }
oidc_console_access_load_conf() { :; }
oidc_console_access_configure() { OIDC_CONSOLE_ACCESS_UPGRADE_GROUPS=admins; }
oidc_console_access_write_conf() {
    printf '[access]\nupgrade=1\nshell=%s\n' "${OIDC_TEST_SHELL:-0}" > "$CONFD_DIR/oidc_console_access.conf"
}
guest_summary_defaults() { :; }
guest_summary_load_conf() { :; }
guest_summary_configure() { :; }
guest_summary_write_conf() { :; }
node_search_defaults() { :; }
node_search_load_conf() { :; }
node_search_configure() { :; }
node_search_write_conf() { :; }
STUB

cat > "$TMP_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$PVE_MODs_TEST_SYSTEMCTL_CALLS"
STUB
chmod +x "$TMP_DIR/bin/systemctl"

cat > "$MAIN_CONF" <<'CONF'
[modules]
node_info=0
nag_screen=0
oidc_console_access=0
guest_summary=0
node_search=0

[pve_trigger]
enabled=0
CONF

cat > "$PATCHES_DIR/node_info/patches.list" <<'MANIFEST'
incompatible.patch
MANIFEST
cat > "$PATCHES_DIR/node_info/incompatible.patch" <<'PATCH'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
@@ -1 +1 @@
-expected
+patched
PATCH

printf 'actual\n' > "$TEST_ROOT/usr/share/demo/config"

run_configure() {
    local input="$1"
    printf '%s\n' "$input" | env \
        PATH="$TMP_DIR/bin:$PATH" \
        PVE_MODs_TEST_SYSTEMCTL_CALLS="$CALLS" \
        PVE_MODs_CONF_FILE="$MAIN_CONF" \
        PVE_MODs_CONFD_DIR="$CONFD_DIR" \
        PVE_MODs_APPLY_PATCHES="$ROOT/src/scripts/apply-patches.sh" \
        PVE_MODs_REVERT_PATCHES="$ROOT/src/scripts/revert-patches.sh" \
        PVE_MODs_NODES_PM="$NODES_PM" \
        PVE_MODs_CONFIGURE_D="$CONFIGURE_D" \
        PVE_MODs_MAIN_CONF="$MAIN_CONF" \
        PVE_MODs_PATCHES_DIR="$PATCHES_DIR" \
        PVE_MODs_ROOT="$TEST_ROOT" \
        PVE_MODs_STASH_DIR="$TMP_DIR/stash" \
        bash "$ROOT/src/scripts/pve-mods-configure" 2>&1
}

if output="$(run_configure 1)"; then
    fail "enabling Node Info unexpectedly succeeded for an incompatible patch"
fi
echo "$output"
grep -q "does not apply cleanly" <<< "$output" \
    || fail "enabling Node Info did not reach patch preflight"
grep -q "marked as incompatible (state 2)" <<< "$output" \
    || fail "patch preflight did not mark Node Info incompatible"
! grep -q "Refreshing patches\\|Reverting mod: node_info\\|could not be reverted cleanly" <<< "$output" \
    || fail "first enable attempted to revert unapplied patches"
grep -q '^node_info=2$' "$MAIN_CONF" \
    || fail "Node Info configuration did not retain the incompatible state"
[[ "$(cat "$TEST_ROOT/usr/share/demo/config")" == actual ]] \
    || fail "failed patch preflight modified the target file"

if output="$(run_configure $'1\nr')"; then
    fail "retrying Node Info unexpectedly succeeded for an incompatible patch"
fi
echo "$output"
grep -q "does not apply cleanly" <<< "$output" \
    || fail "retrying Node Info did not reach patch preflight"
! grep -q "Refreshing patches\\|Reverting mod: node_info\\|could not be reverted cleanly" <<< "$output" \
    || fail "retrying Node Info attempted to revert unapplied patches"
grep -q '^node_info=2$' "$MAIN_CONF" \
    || fail "failed Node Info retry did not retain the incompatible state"

printf 'patched\n' > "$TEST_ROOT/usr/share/demo/config"
cat > "$MAIN_CONF" <<'CONF'
[modules]
node_info=1
nag_screen=0
oidc_console_access=0
guest_summary=0
node_search=0

[pve_trigger]
enabled=0
CONF

output="$(run_configure 1)"
echo "$output"
grep -q "reverted incompatible.patch" <<< "$output" \
    || fail "disabling Node Info did not revert its applied patch"
grep -q '^node_info=0$' "$MAIN_CONF" \
    || fail "disabling Node Info did not save its disabled state"
[[ "$(cat "$TEST_ROOT/usr/share/demo/config")" == expected ]] \
    || fail "disabling Node Info did not restore the original target file"
grep -q '^reload-or-try-restart pveproxy$' "$CALLS" \
    || fail "reverting the patch did not request a pveproxy reload"

mkdir -p "$PATCHES_DIR/oidc_console_access"
cat > "$PATCHES_DIR/oidc_console_access/patches.list" <<'MANIFEST'
upgrade.patch access.upgrade=1
shell.patch   access.shell=1
MANIFEST
for name in upgrade shell; do
    cat > "$PATCHES_DIR/oidc_console_access/$name.patch" <<PATCH
--- a/usr/share/demo/$name
+++ b/usr/share/demo/$name
@@ -1 +1 @@
-expected
+patched
PATCH
done
sed -i 's/^node_info=.*/node_info=0/' "$MAIN_CONF"

# First enable from state 0 must not try to revert never-applied patches.
printf 'actual\n' > "$TEST_ROOT/usr/share/demo/upgrade"
printf 'expected\n' > "$TEST_ROOT/usr/share/demo/shell"
if output="$(run_configure 3)"; then
    fail "enabling OIDC Console Access unexpectedly succeeded for an incompatible patch"
fi
echo "$output"
! grep -q "Refreshing patches\\|could not be reverted cleanly" <<< "$output" \
    || fail "first OIDC enable attempted to revert unapplied patches"
grep -q "marked as incompatible (state 2)" <<< "$output" \
    || fail "patch preflight did not mark OIDC Console Access incompatible"
grep -q '^oidc_console_access=2$' "$MAIN_CONF" \
    || fail "OIDC Console Access did not retain the incompatible state"

# Reconfiguring an active module must still remove a feature switched off.
printf 'patched\n' > "$TEST_ROOT/usr/share/demo/upgrade"
printf 'patched\n' > "$TEST_ROOT/usr/share/demo/shell"
sed -i 's/^oidc_console_access=.*/oidc_console_access=1/' "$MAIN_CONF"
output="$(OIDC_TEST_SHELL=0 run_configure 3)"
echo "$output"
grep -q "Refreshing patches" <<< "$output" \
    || fail "reconfiguring active OIDC Console Access did not refresh patches"
[[ "$(cat "$TEST_ROOT/usr/share/demo/shell")" == expected ]] \
    || fail "disabled OIDC shell feature patch was not removed"
[[ "$(cat "$TEST_ROOT/usr/share/demo/upgrade")" == patched ]] \
    || fail "enabled OIDC upgrade feature patch was not re-applied"
grep -q '^oidc_console_access=1$' "$MAIN_CONF" \
    || fail "reconfigured OIDC Console Access did not stay enabled"

echo "[test] configure patch flow passed"
