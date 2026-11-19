#!/usr/bin/env bash
# Verifies package-upgrade reversion restores old patches without running
# disable/removal hooks, allowing a replacement patch to apply cleanly.
# Service operations are stubbed; no real services are changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREINST="${PVE_MODs_PREINST_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/debian/pve-mods.preinst}"
REVERT="${PVE_MODs_REVERT_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/src/scripts/revert-patches.sh}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "[test] $*" >&2; exit 1; }

ROOT="$TMP_DIR/root"
PATCHES="$TMP_DIR/patches"
CONF="$TMP_DIR/conf"
MOD_DIR="$PATCHES/test_mod"
export PVE_MODs_TEST_CALLS="$TMP_DIR/service-calls"
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TMP_DIR/bin"
: > "$PVE_MODs_TEST_CALLS"
cat > "$TMP_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$PVE_MODs_TEST_CALLS"
[[ ! -f "${PVE_MODs_TEST_CALLS}.fail" ]]
STUB
cat > "$TMP_DIR/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$PVE_MODs_TEST_CALLS"
[[ ! -f "${PVE_MODs_TEST_CALLS}.fail" ]]
STUB
chmod +x "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/systemd-run"

assert_proxy_reload() {
    [[ "$(cat "$PVE_MODs_TEST_CALLS")" == "systemctl reload-or-try-restart pveproxy" ]] \
        || fail "expected one graceful pveproxy reload, got: $(cat "$PVE_MODs_TEST_CALLS")"
}

mkdir -p "$ROOT/usr/share/demo" "$MOD_DIR" "$CONF"
printf 'version=old\n' > "$ROOT/usr/share/demo/config"

export PVE_MODs_MAIN_CONF="$CONF/pve-mods.conf"
write_main_conf() {
    printf '[modules]\ntest_mod=%s\nother_mod=%s\n\n[pve_trigger]\nenabled=0\n' "$1" "${2:-0}" > "$PVE_MODs_MAIN_CONF"
}
read_flag() { sed -n "s/^$1=//p" "$PVE_MODs_MAIN_CONF" | head -n1; }
write_main_conf 1

cat > "$MOD_DIR/old.patch" <<'PATCH'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
@@ -1 +1 @@
-version=old
+version=patched-old
PATCH

cat > "$MOD_DIR/patches.list" <<'MANIFEST'
old.patch
MANIFEST

cat > "$MOD_DIR/post-revert.sh" <<'HOOK'
#!/usr/bin/env bash
touch "$PVE_MODs_ROOT/hook-ran"
exit 0
HOOK
chmod +x "$MOD_DIR/post-revert.sh"

patch -p1 -F0 -d "$ROOT" < "$MOD_DIR/old.patch"
PVE_MODs_ROOT="$ROOT" \
PVE_MODs_PATCHES_DIR="$PATCHES" \
PATH="$TMP_DIR/bin:$PATH" \
    bash "$PREINST" install
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=patched-old" ]] || {
    echo "[test] initial install unexpectedly reverted an existing file" >&2
    exit 1
}
[[ ! -s "$PVE_MODs_TEST_CALLS" ]] || fail "preinst refreshed a service during initial installation"

upgrade_output="$(PVE_MODs_ROOT="$ROOT" \
    PVE_MODs_PATCHES_DIR="$PATCHES" \
    PATH="$TMP_DIR/bin:$PATH" \
bash "$PREINST" upgrade 2.0.0 2.1.0)"
echo "$upgrade_output"
grep -q "\[pve-mods\] Uninstalling patches from version 2.0.0 before installing version 2.1.0" <<< "$upgrade_output" || {
echo "[test] upgrade did not announce the old and new package versions" >&2
    exit 1
}
grep -q "\[pve-mods\] Uninstallation of patches from version 2.0.0 completed" <<< "$upgrade_output" || {
echo "[test] upgrade did not announce completion of patch uninstallation" >&2
exit 1
}

[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=old" ]] || {
    echo "[test] upgrade revert did not restore the original file" >&2
    exit 1
}
[[ ! -e "$ROOT/hook-ran" ]] || {
    echo "[test] upgrade revert ran the post-revert hook" >&2
    exit 1
}
assert_proxy_reload

cat > "$MOD_DIR/new.patch" <<'PATCH'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
@@ -1 +1 @@
-version=old
+version=patched-new
PATCH
cat > "$MOD_DIR/patches.list" <<'MANIFEST'
new.patch
MANIFEST

patch -p1 -F0 -d "$ROOT" < "$MOD_DIR/new.patch"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=patched-new" ]] || {
    echo "[test] replacement patch did not apply after upgrade revert" >&2
    exit 1
}

: > "$PVE_MODs_TEST_CALLS"
PVE_MODs_ROOT="$ROOT" \
PVE_MODs_PATCHES_DIR="$PATCHES" \
PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT" > "$TMP_DIR/revert.log" 2>&1
cat "$TMP_DIR/revert.log"
[[ -e "$ROOT/hook-ran" ]] || {
    echo "[test] regular revert did not run the post-revert hook" >&2
    exit 1
}
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=old" ]] || {
    echo "[test] regular revert did not restore the replacement patch" >&2
    exit 1
}
assert_proxy_reload

grep -Fq 'After this operation finishes, hard-refresh' "$TMP_DIR/revert.log" || fail "revert did not remind the user to refresh after completion"
grep -Fq 'Ctrl+F5 or Ctrl+Shift+R' "$TMP_DIR/revert.log" || fail "revert did not include refresh shortcuts"

printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"

# A second enabled module with a cleanly applied patch must still be reverted
# when another module is in an unknown state.
OTHER_DIR="$PATCHES/other_mod"
mkdir -p "$OTHER_DIR"
printf 'other=old\n' > "$ROOT/usr/share/demo/other"
cat > "$OTHER_DIR/o.patch" <<'PATCH'
--- a/usr/share/demo/other
+++ b/usr/share/demo/other
@@ -1 +1 @@
-other=old
+other=patched
PATCH
printf 'o.patch\n' > "$OTHER_DIR/patches.list"
patch -p1 -F0 -d "$ROOT" < "$OTHER_DIR/o.patch"

run_upgrade() {
    : > "$PVE_MODs_TEST_CALLS"
    PVE_MODs_ROOT="$ROOT" PVE_MODs_PATCHES_DIR="$PATCHES" PATH="$TMP_DIR/bin:$PATH" \
        bash "$PREINST" upgrade 2.0.0 2.1.0 > "$TMP_DIR/upgrade.log" 2>&1
}

# Enabled module in an unknown state: warn, mark it incompatible (2), never abort.
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 1 1
run_upgrade || { cat "$TMP_DIR/upgrade.log" >&2; fail "upgrade aborted on a patch in an unknown state"; }
grep -q "is in an unknown state" "$TMP_DIR/upgrade.log" || fail "no unknown-state warning"
grep -q "Module 'test_mod' is marked as incompatible (state 2)" "$TMP_DIR/upgrade.log" || fail "no incompatible-state warning"
grep -Fq "usr/share/demo/config" "$TMP_DIR/upgrade.log" || fail "warning did not name the modified file"
grep -Fq "Context at $ROOT/usr/share/demo/config:1" "$TMP_DIR/upgrade.log" || fail "no absolute target path and line"
grep -Fq "version=unexpected" "$TMP_DIR/upgrade.log" || fail "no target file context"
grep -q "re-enabled automatically if compatible" "$TMP_DIR/upgrade.log" || fail "warning did not explain the automatic retry"
grep -q "reinstall the packages that own these files" "$TMP_DIR/upgrade.log" || fail "warning did not explain how to restore the files"
grep -q "incompatible with" "$TMP_DIR/upgrade.log" || fail "warning did not mention version incompatibility"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "file in unknown state was modified"
[[ "$(read_flag test_mod)" == "2" ]] || fail "unknown-state module was not marked incompatible in the config"
[[ "$(read_flag other_mod)" == "1" ]] || fail "unrelated module was changed"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=old" ]] || fail "clean module was not reverted"
grep -q "^\[pve_trigger\]" "$PVE_MODs_MAIN_CONF" || fail "config sections were damaged"

# Disabled (0) modules are never touched by preinst.
patch -p1 -F0 -d "$ROOT" < "$OTHER_DIR/o.patch" >/dev/null
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 0 0
cp "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before"
run_upgrade || { cat "$TMP_DIR/upgrade.log" >&2; fail "upgrade failed with only disabled modules"; }
cmp -s "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before" || fail "config changed for a disabled module"
! grep -q "WARNING" "$TMP_DIR/upgrade.log" || fail "disabled module produced a warning"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "disabled module file was modified"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=patched" ]] || fail "disabled module patch was reverted"
[[ ! -s "$PVE_MODs_TEST_CALLS" ]] || fail "preinst refreshed a service without reverting patches"

# Incompatible (2) modules are handled like enabled ones, but an unknown state
# stays quiet and the flag stays 2. An applied patch is still reverted.
write_main_conf 2 2
cp "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before"
run_upgrade || { cat "$TMP_DIR/upgrade.log" >&2; fail "upgrade failed with state 2 modules"; }
cmp -s "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before" || fail "config changed for a state 2 module"
! grep -q "WARNING" "$TMP_DIR/upgrade.log" || fail "state 2 module produced a warning"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "state 2 module file in unknown state was modified"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=old" ]] || fail "applied patch of a state 2 module was not reverted"

# Missing config: nothing is reverted or edited.
patch -p1 -F0 -d "$ROOT" < "$OTHER_DIR/o.patch" >/dev/null
rm -f "$PVE_MODs_MAIN_CONF"
run_upgrade || fail "upgrade failed without a main config"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=patched" ]] || fail "reverted a patch without a main config"
[[ ! -e "$PVE_MODs_MAIN_CONF" ]] || fail "created a main config"

# apply-patches lifecycle: 1 -> 2 on incompatibility, quiet retries, 2 -> 1 once compatible.
APPLY="${PVE_MODs_APPLY_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/src/scripts/apply-patches.sh}"
run_apply() {
    : > "$PVE_MODs_TEST_CALLS"
    PVE_MODs_ROOT="$ROOT" PVE_MODs_PATCHES_DIR="$PATCHES" PVE_MODs_CONFD_DIR="$CONF" \
        PVE_MODs_STASH_DIR="$TMP_DIR/stash" PATH="$TMP_DIR/bin:$PATH" \
        bash "$APPLY" "$@" > "$TMP_DIR/apply.log" 2>&1
}

printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 1 0
if run_apply; then fail "apply succeeded for an incompatible module"; fi
grep -q "marked as incompatible (state 2)" "$TMP_DIR/apply.log" || fail "apply did not report the incompatible state"
[[ "$(read_flag test_mod)" == "2" ]] || fail "failing module was not set to 2"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "apply modified an incompatible file"

run_apply || { cat "$TMP_DIR/apply.log" >&2; fail "retry of a state 2 module failed the run"; }
! grep -q "WARNING" "$TMP_DIR/apply.log" || fail "state 2 retry was noisy"
grep -q "still incompatible" "$TMP_DIR/apply.log" || fail "state 2 retry did not report it is still incompatible"
[[ "$(read_flag test_mod)" == "2" ]] || fail "still incompatible module left state 2"

printf 'version=old\n' > "$ROOT/usr/share/demo/config"
run_apply || { cat "$TMP_DIR/apply.log" >&2; fail "compatible state 2 module failed to apply"; }
grep -q "compatible again and has been re-enabled" "$TMP_DIR/apply.log" || fail "no re-enable message"
[[ "$(read_flag test_mod)" == "1" ]] || fail "compatible module was not set back to 1"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=patched-new" ]] || fail "re-enabled module was not applied"
assert_proxy_reload
grep -Fq 'After this operation finishes, hard-refresh' "$TMP_DIR/apply.log" || fail "apply did not remind the user to refresh after completion"
grep -Fq 'Ctrl+F5 or Ctrl+Shift+R' "$TMP_DIR/apply.log" || fail "apply did not include refresh shortcuts"

run_apply || fail "reapplying unchanged patches failed"
[[ ! -s "$PVE_MODs_TEST_CALLS" ]] || fail "unchanged patches refreshed a service"
! grep -Fq 'hard-refresh' "$TMP_DIR/apply.log" || fail "unchanged patches printed a refresh reminder"

: > "$PVE_MODs_TEST_CALLS"
PVE_MODs_ROOT="$ROOT" PVE_MODs_PATCHES_DIR="$PATCHES" PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT" test_mod > "$TMP_DIR/revert.log" 2>&1 || fail "test module reversion failed"
PVE_MODs_ROOT="$ROOT" PVE_MODs_PATCHES_DIR="$PATCHES" PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT" test_mod > "$TMP_DIR/revert.log" 2>&1 || fail "unchanged reversion failed"
! grep -Fq 'hard-refresh' "$TMP_DIR/revert.log" || fail "unchanged reversion printed a refresh reminder"

write_main_conf 0 0
run_apply || fail "apply failed with only disabled modules"
[[ "$(read_flag test_mod)" == "0" ]] || fail "disabled module state changed"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=old" ]] || fail "disabled module was applied"

# Explicitly applying a module (as pve-mods-configure does) also records the failure.
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 1 0
if run_apply test_mod; then fail "explicit apply succeeded for an incompatible module"; fi
[[ "$(read_flag test_mod)" == "2" ]] || fail "explicit apply failure did not set 2"

# Full upgrade path: the file was changed by another tool, so the old patch is
# incompatible and the module ends up at 2. A newer pve-mods then ships a patch
# that fits the changed file, and the post-upgrade apply re-enables the module.
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 1 0
echo "[test] scenario: upgrade 2.0.0 -> 2.1.0, file changed by another tool"
echo "[test]   before upgrade:       test_mod=$(read_flag test_mod)"
run_upgrade || fail "upgrade aborted for an incompatible module"
echo "[test]   after 2.0.0 preinst:  test_mod=$(read_flag test_mod)"
[[ "$(read_flag test_mod)" == "2" ]] || fail "preinst did not mark the module incompatible"
cat > "$MOD_DIR/compat.patch" <<'PATCH'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
@@ -1 +1 @@
-version=unexpected
+version=patched-compat
PATCH
printf 'compat.patch\n' > "$MOD_DIR/patches.list"
run_apply || { cat "$TMP_DIR/apply.log" >&2; fail "newer patch did not apply to the changed file"; }
echo "[test]   after 2.1.0 apply:    test_mod=$(read_flag test_mod)"
grep "re-enabled" "$TMP_DIR/apply.log" | sed 's/^/[test]   apply-patches: /'
grep -q "compatible again and has been re-enabled" "$TMP_DIR/apply.log" || fail "no re-enable message after the new version"
[[ "$(read_flag test_mod)" == "1" ]] || fail "module was not set back to 1 by the new version"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=patched-compat" ]] || fail "new version's patch was not applied"

# A state 2 module that is partly applied (one clean patch applied, one in an
# unknown state) must be rolled back completely and stay 2.
MULTI_DIR="$PATCHES/multi_mod"
mkdir -p "$MULTI_DIR"
printf 'a=old\n' > "$ROOT/usr/share/demo/multi-a"
printf 'b=old\n' > "$ROOT/usr/share/demo/multi-b"
for n in a b; do
    cat > "$MULTI_DIR/$n.patch" <<PATCH
--- a/usr/share/demo/multi-$n
+++ b/usr/share/demo/multi-$n
@@ -1 +1 @@
-$n=old
+$n=patched
PATCH
done
printf 'a.patch\nb.patch\n' > "$MULTI_DIR/patches.list"
patch -p1 -F0 -d "$ROOT" < "$MULTI_DIR/a.patch" >/dev/null
printf 'b=unexpected\n' > "$ROOT/usr/share/demo/multi-b"
printf '[modules]\nmulti_mod=2\n\n[pve_trigger]\nenabled=0\n' > "$PVE_MODs_MAIN_CONF"
run_apply || { cat "$TMP_DIR/apply.log" >&2; fail "partly applied state 2 module failed the run"; }
[[ "$(read_flag multi_mod)" == "2" ]] || fail "partly applied module left state 2"
[[ "$(cat "$ROOT/usr/share/demo/multi-a")" == "a=old" ]] || fail "applied patch of a state 2 module was not rolled back"
[[ "$(cat "$ROOT/usr/share/demo/multi-b")" == "b=unexpected" ]] || fail "file in unknown state was modified"
! grep -q "WARNING" "$TMP_DIR/apply.log" || fail "state 2 rollback was noisy"

# Changing one module's state must not touch similarly named keys, other
# sections, or the config file's permissions.
printf '[modules]\ntest_mod=1\ntest_mod_extra=1\n\n[other]\ntest_mod=1\n\n[pve_trigger]\nenabled=0\n' > "$PVE_MODs_MAIN_CONF"
chmod 640 "$PVE_MODs_MAIN_CONF"
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
printf 'new.patch\n' > "$MOD_DIR/patches.list"
if run_apply test_mod; then fail "apply succeeded for an incompatible module"; fi
[[ "$(read_flag test_mod)" == "2" ]] || fail "target module was not set to 2"
[[ "$(read_flag test_mod_extra)" == "1" ]] || fail "similarly named module was changed"
grep -A1 '^\[other\]' "$PVE_MODs_MAIN_CONF" | grep -qx 'test_mod=1' || fail "key in another section was changed"
[[ "$(stat -c %a "$PVE_MODs_MAIN_CONF")" == "640" ]] || fail "config permissions were not preserved"

# postinst lists modules in state 2 and stays silent otherwise.
POSTINST="${PVE_MODs_POSTINST_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/debian/pve-mods.postinst}"
report_incompatible() {
    CONF_DIR="$CONF" bash -c "$(awk '/^_report_incompatible_modules\(\)/,/^}/' "$POSTINST"); _report_incompatible_modules" 2>&1
}
printf '[modules]\nnode_info=2\nnag_screen=1\nnode_search=0\n' > "$PVE_MODs_MAIN_CONF"
report_incompatible > "$TMP_DIR/postinst.log"
grep -qx '    node_info' "$TMP_DIR/postinst.log" || fail "postinst did not list the state 2 module"
! grep -q 'nag_screen\|node_search' "$TMP_DIR/postinst.log" || fail "postinst listed a module that is not in state 2"
printf '[modules]\nnode_info=1\nnag_screen=0\n' > "$PVE_MODs_MAIN_CONF"
[[ -z "$(report_incompatible)" ]] || fail "postinst printed output with no state 2 modules"

# Refresh failures remain non-fatal but must be visible to the user.
write_main_conf 1 0
printf 'version=old\n' > "$ROOT/usr/share/demo/config"
touch "${PVE_MODs_TEST_CALLS}.fail"
run_apply || fail "reload failure aborted patch application"
assert_proxy_reload
grep -q 'WARNING: Could not reload pveproxy' "$TMP_DIR/apply.log" || fail "apply hid the reload failure"
: > "$PVE_MODs_TEST_CALLS"
PVE_MODs_ROOT="$ROOT" PVE_MODs_PATCHES_DIR="$PATCHES" PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT" test_mod > "$TMP_DIR/revert.log" 2>&1 || fail "reload failure aborted patch reversion"
assert_proxy_reload
grep -q 'WARNING: Could not reload pveproxy' "$TMP_DIR/revert.log" || fail "revert hid the reload failure"
rm -f "${PVE_MODs_TEST_CALLS}.fail"

# OIDC hooks must schedule a graceful refresh, never stop the daemon running APT.
for hook in post-apply.sh post-revert.sh; do
    : > "$PVE_MODs_TEST_CALLS"
    rc=0
    bash "$SCRIPT_DIR/../../src/modules/oidc_console_access/patches/$hook" > "$TMP_DIR/hook.log" 2>&1 || rc=$?
    [[ "$rc" == "100" ]] || fail "$hook did not request a pveproxy reload"
    [[ "$(cat "$PVE_MODs_TEST_CALLS")" == "systemd-run --quiet --on-active=5s --unit=pve-mods-reload-pvedaemon systemctl reload-or-try-restart pvedaemon" ]] \
        || fail "$hook did not schedule a graceful pvedaemon reload"

    touch "${PVE_MODs_TEST_CALLS}.fail"
    rc=0
    bash "$SCRIPT_DIR/../../src/modules/oidc_console_access/patches/$hook" > "$TMP_DIR/hook.log" 2>&1 || rc=$?
    [[ "$rc" == "100" ]] || fail "$hook aborted after a scheduling failure"
    grep -q 'WARNING: Could not schedule pvedaemon reload' "$TMP_DIR/hook.log" || fail "$hook hid the scheduling failure"
    rm -f "${PVE_MODs_TEST_CALLS}.fail"
done

echo "[test] PASS: upgrade reversion and graceful service reloads"
