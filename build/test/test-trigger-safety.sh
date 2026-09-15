#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/etc/pve-mod" "$ROOT/etc/pve-mod/conf.d" \
         "$ROOT/usr/lib/pve-mod/patches/node_info" \
         "$ROOT/usr/share/perl5/PVE/API2"

cat > "$ROOT/etc/pve-mod/pve-mod.conf" <<'EOF'
[modules]
node_info=1
nag_screen=0

[pve_trigger]
enabled=1
EOF

cat > "$ROOT/usr/share/perl5/PVE/API2/Nodes.pm" <<'EOF'
#!/usr/bin/perl
print "ok\n";
EOF

cat > "$ROOT/usr/lib/pve-mod/patches/node_info/patches.list" <<'EOF'
01-bad.patch
EOF

cat > "$ROOT/usr/lib/pve-mod/patches/node_info/01-bad.patch" <<'EOF'
--- a/usr/share/perl5/PVE/API2/Nodes.pm
+++ b/usr/share/perl5/PVE/API2/Nodes.pm
@@ -1 +1 @@
-this-will-not-match
+still-fails
EOF

set +e
PVE_MOD_ROOT="$ROOT" \
PVE_MOD_MAIN_CONF="$ROOT/etc/pve-mod/pve-mod.conf" \
PVE_MOD_CONFD_DIR="$ROOT/etc/pve-mod/conf.d" \
PVE_MOD_PATCHES_DIR="$ROOT/usr/lib/pve-mod/patches" \
PVE_MOD_STASH_DIR="$ROOT/var/lib/pve-mod/backup" \
 bash "$REPO_ROOT/src/scripts/apply-patches.sh" node_info > "$ROOT/apply.out" 2>&1
apply_rc=$?
set -e

if [[ "$apply_rc" -ne 0 ]]; then
  echo "FAIL: apply-patches.sh exited $apply_rc"
  cat "$ROOT/apply.out"
  exit 1
fi

if ! grep -qE 'node_info=0|disabled.*node_info|Mod .* disabled' "$ROOT/etc/pve-mod/pve-mod.conf"; then
  echo "FAIL: failed patch did not disable node_info in main config"
  echo "--- config ---"
  cat "$ROOT/etc/pve-mod/pve-mod.conf"
  echo "--- output ---"
  cat "$ROOT/apply.out"
  exit 1
fi

echo "PASS: incompatible patch disables the module"

mkdir -p "$ROOT/locks"
: > "$ROOT/locks/lock-frontend"

set +e
PATH="$PATH" \
DPKG_LOCK_FRONTEND="$ROOT/locks/lock-frontend" \
DPKG_LOCK="$ROOT/locks/lock" \
 bash "$REPO_ROOT/debian/pve-mod.postinst" triggered > "$ROOT/trigger.out" 2>&1
trigger_rc=$?
set -e

if [[ "$trigger_rc" -ne 0 ]]; then
  echo "FAIL: triggered hook exited $trigger_rc while dpkg lock was active"
  cat "$ROOT/trigger.out"
  exit 1
fi

if grep -q "apply-patches.sh" "$ROOT/trigger.out"; then
  echo "FAIL: triggered hook still called the patch applier while dpkg lock was active"
  cat "$ROOT/trigger.out"
  exit 1
fi

echo "PASS: triggered hook skips reapply while package manager is active"

echo "ALL TESTS PASSED"
