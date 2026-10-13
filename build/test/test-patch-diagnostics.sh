#!/usr/bin/env bash
# Verifies patch preflight failures include the affected file and source context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPLY="${PVE_MODs_APPLY_SOURCE:-$REPO_ROOT/src/scripts/apply-patches.sh}"
REVERT="${PVE_MODs_REVERT_SOURCE:-$REPO_ROOT/src/scripts/revert-patches.sh}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/root"
PATCHES="$TMP_DIR/patches"
CONF="$TMP_DIR/conf"
MAIN_CONF="$TMP_DIR/pve-mods.conf"
MOD_DIR="$PATCHES/test_mod"
mkdir -p "$ROOT/usr/share/demo" "$MOD_DIR" "$CONF"

cat > "$ROOT/usr/share/demo/config" <<'FILE'
header
version=unexpected
footer
FILE
cat > "$MOD_DIR/bad.patch" <<'PATCH'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
@@ -1,3 +1,3 @@
 header
-version=old
+version=new
 footer
PATCH
printf 'bad.patch\n' > "$MOD_DIR/patches.list"
printf '[modules]\ntest_mod=1\n' > "$MAIN_CONF"

if PVE_MODs_ROOT="$ROOT" \
   PVE_MODs_PATCHES_DIR="$PATCHES" \
   PVE_MODs_CONFD_DIR="$CONF" \
   PVE_MODs_MAIN_CONF="$MAIN_CONF" \
    bash "$APPLY" > "$TMP_DIR/apply-error.log" 2>&1; then
    echo "[test] apply unexpectedly accepted a patch with mismatched context" >&2
    exit 1
fi

grep -Fq "Context at $ROOT/usr/share/demo/config:1" "$TMP_DIR/apply-error.log" || {
    echo "[test] apply failure did not include the absolute target path and line" >&2
    cat "$TMP_DIR/apply-error.log" >&2
    exit 1
}
grep -Fq "version=unexpected" "$TMP_DIR/apply-error.log" || {
    echo "[test] apply failure did not include the target file context" >&2
    cat "$TMP_DIR/apply-error.log" >&2
    exit 1
}

if PVE_MODs_ROOT="$ROOT" \
   PVE_MODs_PATCHES_DIR="$PATCHES" \
   PVE_MODs_CONFD_DIR="$CONF" \
    bash "$REVERT" test_mod > "$TMP_DIR/revert-error.log" 2>&1; then
    echo "[test] revert unexpectedly accepted a patch with mismatched context" >&2
    exit 1
fi

grep -Fq "Context at $ROOT/usr/share/demo/config:1" "$TMP_DIR/revert-error.log" || {
    echo "[test] revert failure did not include the absolute target path and line" >&2
    cat "$TMP_DIR/revert-error.log" >&2
    exit 1
}
grep -Fq "version=unexpected" "$TMP_DIR/revert-error.log" || {
    echo "[test] revert failure did not include the target file context" >&2
    cat "$TMP_DIR/revert-error.log" >&2
    exit 1
}

echo "[test] PASS: apply and revert failures report target path, line, and context"
