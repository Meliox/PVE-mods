#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/packages" "$TMP_DIR/patches"
make_package() {
    local name="$1" version="$2" file root="$TMP_DIR/package"
    shift 2
    mkdir -p "$root/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.com>\nDescription: test package\n' \
        "$name" "$version" > "$root/DEBIAN/control"
    for file in "$@"; do
        mkdir -p "$root/$(dirname "$file")"
        printf 'original\n' > "$root/$file"
    done
    dpkg-deb --build "$root" "$TMP_DIR/packages/$name.deb" >/dev/null
    rm -rf "$root"
}

make_package pve-manager '1:9.2.28-1' usr/share/demo/config \
    usr/share/perl5/PVE/API2/Nodes.pm usr/share/pve-manager/js/pvemanagerlib.js
make_package proxmox-widget-toolkit '5.2.13' usr/share/demo/widget \
    usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
make_package pve-yew-mobile-gui '1.2.3' usr/share/pve-yew-mobile-gui/index.html.tpl
make_package unrelated '1.0' usr/share/demo/unrelated

cat > "$TMP_DIR/patches/patches.list" <<'EOF'
# Test conditional and duplicate targets.
one.patch
two.patch option.enabled=1
EOF
cat > "$TMP_DIR/patches/one.patch" <<'EOF'
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
--- a/usr/share/demo/missing
+++ b/usr/share/demo/missing
EOF
cat > "$TMP_DIR/patches/two.patch" <<'EOF'
--- /usr/share/demo/widget.orig
+++ /usr/share/demo/widget	2026-01-01
--- a/usr/share/demo/config
+++ b/usr/share/demo/config
EOF
cat > "$TMP_DIR/expected" <<'EOF'
- `/usr/share/demo/config`: `pve-manager` `1:9.2.28-1`
- `/usr/share/demo/missing`: no downloaded package provides this file
- `/usr/share/demo/widget`: `proxmox-widget-toolkit` `5.2.13`
EOF

bash "$SCRIPT_DIR/report-patch-packages.sh" "$TMP_DIR/patches" "$TMP_DIR/packages" > "$TMP_DIR/actual"
diff -u "$TMP_DIR/expected" "$TMP_DIR/actual"

cat > "$TMP_DIR/expected" <<'EOF'
{"proxmox-widget-toolkit": "5.2.13", "pve-manager": "1:9.2.28-1"}
EOF
bash "$SCRIPT_DIR/report-patch-packages.sh" "$TMP_DIR/patches" "$TMP_DIR/packages" json > "$TMP_DIR/actual"
diff -u "$TMP_DIR/expected" "$TMP_DIR/actual"

cat > "$TMP_DIR/expected" <<'EOF'
- `/usr/share/perl5/PVE/API2/Nodes.pm`: `pve-manager` `1:9.2.28-1`
- `/usr/share/pve-manager/js/pvemanagerlib.js`: `pve-manager` `1:9.2.28-1`
EOF
bash "$SCRIPT_DIR/report-patch-packages.sh" "$REPO_ROOT/src/modules/node_info/patches" "$TMP_DIR/packages" > "$TMP_DIR/actual"
diff -u "$TMP_DIR/expected" "$TMP_DIR/actual"

cat > "$TMP_DIR/expected" <<'EOF'
- `/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`: `proxmox-widget-toolkit` `5.2.13`
- `/usr/share/pve-manager/js/pvemanagerlib.js`: `pve-manager` `1:9.2.28-1`
- `/usr/share/pve-yew-mobile-gui/index.html.tpl`: `pve-yew-mobile-gui` `1.2.3`
EOF
bash "$SCRIPT_DIR/report-patch-packages.sh" "$REPO_ROOT/src/modules/nag_screen/patches" "$TMP_DIR/packages" > "$TMP_DIR/actual"
diff -u "$TMP_DIR/expected" "$TMP_DIR/actual"

mkdir "$TMP_DIR/empty"
if bash "$SCRIPT_DIR/report-patch-packages.sh" "$TMP_DIR/patches" "$TMP_DIR/empty" > "$TMP_DIR/output" 2>&1; then
    echo "[test] reporting unexpectedly succeeded without package archives" >&2
    exit 1
fi
grep -Fq 'No downloaded packages' "$TMP_DIR/output"

echo "[test] PASS: patch target package reporting"
