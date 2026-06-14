#!/usr/bin/env bash
# Downloads upstream Proxmox VE packages and extracts all their files to real
# system paths, so the patch engine can be exercised on a plain CI runner.

set -euo pipefail

SUITE="${PVE_SUITE:-trixie}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[fetch] Configuring Proxmox no-subscription repo ($SUITE)..."
echo "deb [trusted=yes] http://download.proxmox.com/debian/pve $SUITE pve-no-subscription" \
    | sudo tee /etc/apt/sources.list.d/pve-test.list >/dev/null
sudo apt-get update -qq

echo "[fetch] Downloading pve-manager, proxmox-widget-toolkit, pve-yew-mobile-gui, libjson-perl, libpve-common-perl, libclone-perl, and libcommon-sense-perl..."
cd "$WORKDIR"
apt-get download pve-manager proxmox-widget-toolkit pve-yew-mobile-gui libjson-perl libpve-common-perl libclone-perl libcommon-sense-perl

echo "[fetch] Extracting to system paths..."
for deb in *.deb; do
    echo "[fetch]  $deb"
    sudo dpkg-deb -x "$deb" /
done

echo "[fetch] Done."