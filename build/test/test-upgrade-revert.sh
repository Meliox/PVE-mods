#!/usr/bin/env bash
# Verifies package-upgrade reversion restores old patches without running
# disable/removal hooks, allowing a replacement patch to apply cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREINST="${PVE_MODs_PREINST_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/debian/pve-mods.preinst}"
REVERT="${PVE_MODs_REVERT_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)/src/scripts/revert-patches.sh}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/root"
PATCHES="$TMP_DIR/patches"
CONF="$TMP_DIR/conf"
MOD_DIR="$PATCHES/test_mod"
mkdir -p "$TMP_DIR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/systemctl"
chmod +x "$TMP_DIR/bin/systemctl"

mkdir -p "$ROOT/usr/share/demo" "$MOD_DIR" "$CONF"
printf 'version=old\n' > "$ROOT/usr/share/demo/config"

export PVE_MODs_MAIN_CONF="$CONF/pve-mods.conf"
write_main_conf() {
    printf '[modules]\ntest_mod=%s\nother_mod=%s\n\n[pve_trigger]\nenabled=0\n' "$1" "${2:-0}" > "$PVE_MODs_MAIN_CONF"
}
read_flag() { sed -n "s/^$1=//p" "$PVE_MODs_MAIN_CONF"; }
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

PVE_MODs_ROOT="$ROOT" \
PVE_MODs_PATCHES_DIR="$PATCHES" \
PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT"
[[ -e "$ROOT/hook-ran" ]] || {
    echo "[test] regular revert did not run the post-revert hook" >&2
    exit 1
}
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=old" ]] || {
    echo "[test] regular revert did not restore the replacement patch" >&2
    exit 1
}

printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
fail() { echo "[test] $*" >&2; exit 1; }

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

patch -R -p1 -F0 -d "$ROOT" < "$MOD_DIR/new.patch" >/dev/null
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
run_upgrade || fail "upgrade aborted for an incompatible module"
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
grep -q "compatible again and has been re-enabled" "$TMP_DIR/apply.log" || fail "no re-enable message after the new version"
[[ "$(read_flag test_mod)" == "1" ]] || fail "module was not set back to 1 by the new version"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=patched-compat" ]] || fail "new version's patch was not applied"

echo "[test] PASS: upgrade revert restores patches without running hooks"
