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
export PVE_MODs_STATE_DIR="$TMP_DIR/state"
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

# Enabled module in an unknown state: warn, disable it, never abort.
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 1 1
run_upgrade || { cat "$TMP_DIR/upgrade.log" >&2; fail "upgrade aborted on a patch in an unknown state"; }
grep -q "is in an unknown state" "$TMP_DIR/upgrade.log" || fail "no unknown-state warning"
grep -q "Module 'test_mod' was disabled automatically" "$TMP_DIR/upgrade.log" || fail "no auto-disable warning"
grep -Fq "usr/share/demo/config" "$TMP_DIR/upgrade.log" || fail "warning did not name the modified file"
grep -Fq "Context at $ROOT/usr/share/demo/config:1" "$TMP_DIR/upgrade.log" || fail "no absolute target path and line"
grep -Fq "version=unexpected" "$TMP_DIR/upgrade.log" || fail "no target file context"
grep -q "pve-mods-configure" "$TMP_DIR/upgrade.log" || fail "warning did not point to pve-mods-configure"
grep -q "reinstall the packages that own these files" "$TMP_DIR/upgrade.log" || fail "warning did not explain how to restore the files"
grep -q "incompatible with" "$TMP_DIR/upgrade.log" || fail "warning did not mention version incompatibility"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "file in unknown state was modified"
[[ "$(read_flag test_mod)" == "0" ]] || fail "unknown-state module was not disabled in the config"
[[ "$(read_flag other_mod)" == "1" ]] || fail "unrelated module was disabled"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=old" ]] || fail "clean module was not reverted"
grep -qx "test_mod" "$PVE_MODs_STATE_DIR/auto-disabled" || fail "auto-disabled marker missing"
grep -q "^\[pve_trigger\]" "$PVE_MODs_MAIN_CONF" || fail "config sections were damaged"

# Disabled module with a modified file: ignored, config untouched, no warning.
printf 'version=unexpected\n' > "$ROOT/usr/share/demo/config"
write_main_conf 0 0
cp "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before"
rm -rf "$PVE_MODs_STATE_DIR"
run_upgrade || { cat "$TMP_DIR/upgrade.log" >&2; fail "upgrade failed with only disabled modules"; }
cmp -s "$PVE_MODs_MAIN_CONF" "$TMP_DIR/conf.before" || fail "config changed for a disabled module"
! grep -q "WARNING" "$TMP_DIR/upgrade.log" || fail "disabled module produced a warning"
[[ ! -e "$PVE_MODs_STATE_DIR/auto-disabled" ]] || fail "marker written for a disabled module"
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || fail "disabled module file was modified"

# Missing config: nothing is reverted or edited.
patch -p1 -F0 -d "$ROOT" < "$OTHER_DIR/o.patch" >/dev/null
rm -f "$PVE_MODs_MAIN_CONF"
run_upgrade || fail "upgrade failed without a main config"
[[ "$(cat "$ROOT/usr/share/demo/other")" == "other=patched" ]] || fail "reverted a patch without a main config"
[[ ! -e "$PVE_MODs_MAIN_CONF" ]] || fail "created a main config"

echo "[test] PASS: upgrade revert restores patches without running hooks"
