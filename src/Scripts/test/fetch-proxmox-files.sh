#!/usr/bin/env bash
# src/Scripts/test/fetch-proxmox-files.sh
#
# Downloads the upstream Proxmox VE files that pve-mod patches and installs them
# at their real system paths, so the patch engine can be exercised on a plain
# (non-Proxmox) CI runner.
#
# Pulls pve-manager and proxmox-widget-toolkit from the Proxmox no-subscription
# repository (default: PVE 9 / Debian trixie) and extracts the target files.
#
# CI-only helper. The repo is added with [trusted=yes]: we are only fetching
# public, unmodified UI files to patch against, not installing Proxmox, so
# managing the signing key would add nothing.

set -euo pipefail

SUITE="${PVE_SUITE:-trixie}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Files provided by the two packages, relative to the filesystem root. These are
# exactly the paths the .patch files (and the nag_screen post-apply hook) touch.
FILES=(
    usr/share/perl5/PVE/API2/Nodes.pm
    usr/share/pve-manager/js/pvemanagerlib.js
    usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js
)

echo "[fetch] Configuring Proxmox no-subscription repo ($SUITE)..."
echo "deb [trusted=yes] http://download.proxmox.com/debian/pve $SUITE pve-no-subscription" \
    | sudo tee /etc/apt/sources.list.d/pve-test.list >/dev/null
sudo apt-get update -qq

echo "[fetch] Downloading pve-manager and proxmox-widget-toolkit..."
cd "$WORKDIR"
apt-get download pve-manager proxmox-widget-toolkit

for deb in *.deb; do
    echo "[fetch] Extracting $deb"
    dpkg-deb -x "$deb" extract
done

for rel in "${FILES[@]}"; do
    src="extract/$rel"
    dst="/$rel"
    if [[ ! -f "$src" ]]; then
        echo "[fetch] ERROR: expected file not found in packages: $rel" >&2
        exit 1
    fi
    sudo install -Dm644 "$src" "$dst"
    echo "[fetch] Installed $dst"
done

echo "[fetch] Done."
