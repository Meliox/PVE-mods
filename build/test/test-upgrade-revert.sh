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
grep -q "Uninstalling patches from version 2.0.0 before installing version 2.1.0" <<< "$upgrade_output" || {
echo "[test] upgrade did not announce the old and new package versions" >&2
    exit 1
}
grep -q "Uninstallation of patches from version 2.0.0 completed" <<< "$upgrade_output" || {
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
if PVE_MODs_ROOT="$ROOT" \
   PVE_MODs_PATCHES_DIR="$PATCHES" \
   PATH="$TMP_DIR/bin:$PATH" \
    bash "$PREINST" upgrade 2.0.0 2.1.0 > "$TMP_DIR/upgrade-error.log" 2>&1; then
    echo "[test] upgrade unexpectedly accepted a patch in an unknown state" >&2
    exit 1
fi
grep -q "cannot safely upgrade" "$TMP_DIR/upgrade-error.log" || {
    echo "[test] upgrade failure did not explain the unknown patch state" >&2
    cat "$TMP_DIR/upgrade-error.log" >&2
    exit 1
}
[[ "$(cat "$ROOT/usr/share/demo/config")" == "version=unexpected" ]] || {
    echo "[test] failed upgrade modified a file in an unknown state" >&2
    exit 1
}

echo "[test] PASS: upgrade revert restores patches without running hooks"
