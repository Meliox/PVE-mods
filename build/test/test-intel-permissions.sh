#!/usr/bin/env bash
# No real capabilities, services or Proxmox files are changed.
set -euo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export INTEL_TEST_DIR="$TMP_DIR"
export PVE_MODs_INTEL_GPU_HELPER="$SOURCE/src/scripts/intel-gpu-permissions.sh"
export PVE_MODs_MAIN_CONF="$TMP_DIR/etc/pve-mods/pve-mods.conf"
export MOD_CONF="$TMP_DIR/etc/pve-mods/conf.d/node_info.conf"
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc/pve-mods/conf.d" \
    "$TMP_DIR/etc/systemd/system" "$TMP_DIR/lib"

cat > "$TMP_DIR/bin/intel_gpu_top" <<'STUB'
#!/usr/bin/env bash
exit 99
STUB
cat > "$TMP_DIR/bin/runuser" <<'STUB'
#!/usr/bin/env bash
echo probe >> "$INTEL_TEST_DIR/calls"
mode="$(cat "$INTEL_TEST_DIR/mode")"
case "$mode" in
    bad-output) echo "No device found"; exit 0 ;;
    bad-json) echo '[{"engines":'; exit 124 ;;
    bad-shape) echo '[{"engines":"not an object"}]'; exit 0 ;;
    failed-command) echo '{"engines":{}}'; exit 1 ;;
    no-output) exit 0 ;;
    permission) echo "Failed to initialize PMU! (Permission denied)"; exit 1 ;;
esac
if [[ "$mode" == "works" ]] || grep -q cap_perfmon "$INTEL_TEST_DIR/caps" 2>/dev/null; then
    printf '[\n{"engines":{"Render/3D":{"busy":0}}},\n'
    exit 124
fi
echo "Failed to initialize PMU! (Permission denied)"
exit 1
STUB
cat > "$TMP_DIR/bin/getcap" <<'STUB'
#!/usr/bin/env bash
[[ ! -f "$INTEL_TEST_DIR/getcap-fail" ]] || exit 1
[[ ! -s "$INTEL_TEST_DIR/caps" ]] || printf '%s %s\n' "$1" "$(cat "$INTEL_TEST_DIR/caps")"
exit 0
STUB
cat > "$TMP_DIR/bin/setcap" <<'STUB'
#!/usr/bin/env bash
echo "setcap $1" >> "$INTEL_TEST_DIR/calls"
[[ ! -f "$INTEL_TEST_DIR/setcap-fail" ]] || exit 1
case "$1" in
    -r) rm -f "$INTEL_TEST_DIR/caps" ;;
    *" cap_perfmon+ep")
        printf '%s cap_perfmon=ep\n' "${1% cap_perfmon+ep}" > "$INTEL_TEST_DIR/caps"
        ;;
    *" cap_perfmon-eip")
        printf '%s\n' "${1% cap_perfmon-eip}" | sed 's/ cap_perfmon=ep//g' > "$INTEL_TEST_DIR/caps"
        ;;
    *) printf '%s\n' "$1" > "$INTEL_TEST_DIR/caps" ;;
esac
STUB
cat > "$TMP_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$INTEL_TEST_DIR/calls"
if [[ "$1" == "is-active" ]]; then
    [[ -f "$INTEL_TEST_DIR/history-active" ]]
elif [[ "$1" == "restart" ]]; then
    [[ ! -f "$INTEL_TEST_DIR/restart-fail" ]]
fi
STUB
chmod +x "$TMP_DIR/bin/"*

# Redirect absolute service paths; retain the real-root branch and its checks.
sed -e "s|/etc/systemd/system|$TMP_DIR/etc/systemd/system|g" \
    -e "s|/var/lib/rrdcached/db/pve-mods-gpu|$TMP_DIR/rrd|g" \
    "$SOURCE/src/modules/node_info/patches/post-apply.sh" > "$TMP_DIR/post-apply.sh"
sed -e "s|/etc/systemd/system|$TMP_DIR/etc/systemd/system|g" \
    -e "s|/run/pve-mods-smart|$TMP_DIR/smart|g" \
    "$SOURCE/src/modules/node_info/patches/post-revert.sh" > "$TMP_DIR/post-revert.sh"
sed -e "s|/usr/lib/pve-mods|$TMP_DIR/lib|g" \
    -e "s|/etc/pve-mods|$TMP_DIR/etc/pve-mods|g" \
    -e "s|/usr/share/pve-mods|$TMP_DIR/defaults|g" \
    "$SOURCE/debian/pve-mods.postinst" > "$TMP_DIR/postinst"
cp "$PVE_MODs_INTEL_GPU_HELPER" "$TMP_DIR/lib/intel-gpu-permissions.sh"
printf '#!/usr/bin/env bash\necho apply >> "$INTEL_TEST_DIR/calls"\n' > "$TMP_DIR/lib/apply-patches.sh"
chmod +x "$TMP_DIR/lib/apply-patches.sh"

reset_case() {
    rm -f "$TMP_DIR/caps" "$TMP_DIR/setcap-fail" "$TMP_DIR/getcap-fail" \
        "$TMP_DIR/history-active" "$TMP_DIR/restart-fail"
    : > "$TMP_DIR/calls"
    echo needs-cap > "$TMP_DIR/mode"
    printf '[modules]\nnode_info=1\n[pve_trigger]\nenabled=0\n' > "$PVE_MODs_MAIN_CONF"
    printf '[gpu]\nintel_enabled=1\ngpu_history=0\n[debug]\nintel_mode=0\n' > "$MOD_CONF"
}

expect_rc() {
    local expected="$1" rc=0
    shift
    "$@" > "$TMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == "$expected" ]] || {
        echo "[test] Expected exit $expected, got $rc: $*" >&2
        cat "$TMP_DIR/output" >&2
        exit 1
    }
}

assert_no_grant() {
    if grep -q 'setcap .*cap_perfmon+ep' "$TMP_DIR/calls"; then
        echo "[test] Unexpected capability grant" >&2
        exit 1
    fi
}

source "$PVE_MODs_INTEL_GPU_HELPER"
reset_case
echo works > "$TMP_DIR/mode"
expect_rc 0 intel_gpu_can_collect "$TMP_DIR/bin/intel_gpu_top"
for mode in bad-output bad-json bad-shape failed-command no-output permission; do
    echo "$mode" > "$TMP_DIR/mode"
    expect_rc 1 intel_gpu_can_collect "$TMP_DIR/bin/intel_gpu_top"
done

reset_case
export CONFD_DIR="$TMP_DIR/etc/pve-mods/conf.d"
source "$SOURCE/src/modules/node_info/node_info.configure.sh"
info() { echo "$*"; }
warn() { echo "$*" >&2; }
ask() { echo y; }
expect_rc 0 _verify_intel_gpu_permission
grep -q cap_perfmon "$TMP_DIR/caps"
expect_rc 100 bash "$TMP_DIR/post-revert.sh"
! grep -q cap_perfmon "$TMP_DIR/caps"
expect_rc 100 bash "$TMP_DIR/post-apply.sh"
grep -q cap_perfmon "$TMP_DIR/caps"
: > "$TMP_DIR/calls"
expect_rc 0 bash "$TMP_DIR/post-apply.sh"
assert_no_grant

reset_case
echo cap_net_raw=ep > "$TMP_DIR/caps"
expect_rc 100 intel_gpu_restore_permission
grep -q cap_net_raw=ep "$TMP_DIR/caps"
expect_rc 100 intel_gpu_revoke_permission
grep -q cap_net_raw=ep "$TMP_DIR/caps"
! grep -q cap_perfmon "$TMP_DIR/caps"
expect_rc 0 intel_gpu_revoke_permission

for setting in disabled debug test-root; do
    reset_case
    case "$setting" in
        disabled) sed -i 's/intel_enabled=1/intel_enabled=0/' "$MOD_CONF" ;;
        debug) sed -i 's/intel_mode=0/intel_mode=1/' "$MOD_CONF" ;;
    esac
    if [[ "$setting" == "test-root" ]]; then
        expect_rc 0 env PVE_MODs_ROOT="$TMP_DIR/root" bash "$TMP_DIR/post-apply.sh"
        expect_rc 0 env PVE_MODs_ROOT="$TMP_DIR/root" bash "$TMP_DIR/post-revert.sh"
    else
        expect_rc 0 bash "$TMP_DIR/post-apply.sh"
    fi
    assert_no_grant
    [[ ! -s "$TMP_DIR/calls" ]]
done

reset_case
echo works > "$TMP_DIR/mode"
ask() { echo asked >> "$TMP_DIR/calls"; echo n; }
expect_rc 1 _verify_intel_gpu_permission
grep -q asked "$TMP_DIR/calls"
assert_no_grant
ask() { echo y; }
expect_rc 0 _verify_intel_gpu_permission
grep -q cap_perfmon "$TMP_DIR/caps"

for setting in disabled debug; do
    reset_case
    expect_rc 100 intel_gpu_restore_permission
    case "$setting" in
        disabled) sed -i 's/intel_enabled=1/intel_enabled=0/' "$MOD_CONF" ;;
        debug) sed -i 's/intel_mode=0/intel_mode=1/' "$MOD_CONF" ;;
    esac
    expect_rc 100 bash "$TMP_DIR/post-apply.sh"
    ! grep -q cap_perfmon "$TMP_DIR/caps"
done

for failure in setcap-fail getcap-fail; do
    reset_case
    touch "$TMP_DIR/$failure"
    expect_rc 0 bash "$TMP_DIR/post-apply.sh"
    grep -q 'ERROR: Intel GPU permission:' "$TMP_DIR/output"
    grep -q 'keeping Node Info installed' "$TMP_DIR/output"
done
reset_case
echo permission > "$TMP_DIR/mode"
expect_rc 100 intel_gpu_restore_permission
grep -q cap_perfmon "$TMP_DIR/caps"
! grep -q probe "$TMP_DIR/calls"
reset_case
echo cap_net_raw=ep > "$TMP_DIR/caps"
echo permission > "$TMP_DIR/mode"
expect_rc 100 intel_gpu_restore_permission
grep -q cap_net_raw=ep "$TMP_DIR/caps"
echo cap_perfmon=ep > "$TMP_DIR/caps"
touch "$TMP_DIR/setcap-fail"
expect_rc 1 bash "$TMP_DIR/post-revert.sh"
grep -q 'could not revoke' "$TMP_DIR/output"
mkdir -p "$TMP_DIR/patches/node_info"
cp "$TMP_DIR/post-revert.sh" "$TMP_DIR/patches/node_info/post-revert.sh"
chmod +x "$TMP_DIR/patches/node_info/post-revert.sh"
expect_rc 1 env PVE_MODs_PATCHES_DIR="$TMP_DIR/patches" \
    bash "$SOURCE/src/scripts/revert-patches.sh" node_info
grep -q 'post-revert hook for node_info reported an error' "$TMP_DIR/output"

# Optional GPU failure must not invoke the applier's whole-module rollback.
reset_case
touch "$TMP_DIR/setcap-fail"
mkdir -p "$TMP_DIR/root/usr/share/demo"
printf 'state=original\n' > "$TMP_DIR/root/usr/share/demo/state"
cat > "$TMP_DIR/patches/node_info/demo.patch" <<'PATCH'
--- a/usr/share/demo/state
+++ b/usr/share/demo/state
@@ -1 +1 @@
-state=original
+state=patched
PATCH
echo demo.patch > "$TMP_DIR/patches/node_info/patches.list"
printf '#!/usr/bin/env bash\nexport PVE_MODs_ROOT=/\nexec bash %q\n' \
    "$TMP_DIR/post-apply.sh" > "$TMP_DIR/patches/node_info/post-apply.sh"
chmod +x "$TMP_DIR/patches/node_info/post-apply.sh"
expect_rc 0 env PVE_MODs_ROOT="$TMP_DIR/root" \
    PVE_MODs_PATCHES_DIR="$TMP_DIR/patches" PVE_MODs_CONFD_DIR="$CONFD_DIR" \
    bash "$SOURCE/src/scripts/apply-patches.sh" node_info
[[ "$(cat "$TMP_DIR/root/usr/share/demo/state")" == "state=patched" ]]
grep -q 'keeping Node Info installed' "$TMP_DIR/output"
! grep -q 'post-apply hook failed - reverting' "$TMP_DIR/output"

reset_case
touch "$TMP_DIR/history-active"
expect_rc 0 bash "$TMP_DIR/postinst" triggered /usr/bin/intel_gpu_top
grep -q cap_perfmon "$TMP_DIR/caps"
grep -q 'systemctl restart pveproxy' "$TMP_DIR/calls"
grep -q 'systemctl restart pve-mods-gpu-history.service' "$TMP_DIR/calls"
! grep -q '^apply$' "$TMP_DIR/calls"
: > "$TMP_DIR/calls"
expect_rc 0 bash "$TMP_DIR/postinst" triggered /usr/bin/intel_gpu_top
! grep -q 'systemctl restart' "$TMP_DIR/calls"
assert_no_grant

for setting in module-disabled intel-disabled debug; do
    reset_case
    case "$setting" in
        module-disabled) sed -i 's/node_info=1/node_info=0/' "$PVE_MODs_MAIN_CONF" ;;
        intel-disabled) sed -i 's/intel_enabled=1/intel_enabled=0/' "$MOD_CONF" ;;
        debug) sed -i 's/intel_mode=0/intel_mode=1/' "$MOD_CONF" ;;
    esac
    expect_rc 0 bash "$TMP_DIR/postinst" triggered /usr/bin/intel_gpu_top
    [[ ! -s "$TMP_DIR/calls" ]]
    echo cap_perfmon=ep > "$TMP_DIR/caps"
    expect_rc 0 bash "$TMP_DIR/postinst" triggered /usr/bin/intel_gpu_top
    ! grep -q cap_perfmon "$TMP_DIR/caps"
done
reset_case
touch "$TMP_DIR/setcap-fail"
expect_rc 0 bash "$TMP_DIR/postinst" triggered /usr/bin/intel_gpu_top
grep -q 'WARNING: Could not restore Intel GPU monitoring permission' "$TMP_DIR/output"
reset_case
touch "$TMP_DIR/restart-fail"
expect_rc 1 bash "$PVE_MODs_INTEL_GPU_HELPER"
grep -q 'could not restart pveproxy' "$TMP_DIR/output"

reset_case
sed -i 's/enabled=0/enabled=1/' "$PVE_MODs_MAIN_CONF"
expect_rc 0 bash "$TMP_DIR/postinst" triggered '/usr/bin/intel_gpu_top /usr/share/pve-manager/js'
grep -q '^apply$' "$TMP_DIR/calls"
grep -q cap_perfmon "$TMP_DIR/caps"
reset_case
expect_rc 0 bash "$TMP_DIR/postinst" triggered '/usr/bin/intel_gpu_top /usr/share/pve-manager/js'
! grep -q '^apply$' "$TMP_DIR/calls"
grep -q cap_perfmon "$TMP_DIR/caps"
grep -q 'auto re-patching is disabled' "$TMP_DIR/output"
grep -qx 'interest-noawait /usr/bin/intel_gpu_top' "$SOURCE/debian/pve-mods.triggers"
grep -q 'install -Dm644 src/scripts/intel-gpu-permissions.sh' "$SOURCE/debian/rules"

echo "[test] PASS: Intel permission checks, refresh, cleanup and binary-upgrade trigger"
