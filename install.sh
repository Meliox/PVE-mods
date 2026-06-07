#!/usr/bin/env bash
# install.sh — Bootstrap installer for pve-mod
# Usage: curl -sL https://github.com/Meliox/PVE-mods/releases/latest/download/install.sh | bash

set -euo pipefail

REPO="Meliox/PVE-mods"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

#region helpers
info() { echo -e "\e[0;32m[pve-mod] ${1}\e[0m"; }
err()  { echo -e "\e[0;31m[pve-mod] ERROR: ${1}\e[0m" >&2; exit 1; }
#endregion helpers

# ── Prerequisite checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "This installer must be run as root."

dpkg -l proxmox-ve &>/dev/null 2>&1 || \
    err "This system does not appear to be running Proxmox VE."

for cmd in curl dpkg; do
    command -v "$cmd" &>/dev/null || err "Required command not found: $cmd"
done

# ── Fetch latest release metadata ─────────────────────────────────────────────
info "Fetching latest release information..."
RELEASE_JSON=$(curl -sL "$API_URL") || err "Failed to contact GitHub API."

# Extract .deb download URL (no jq dependency)
DEB_URL=$(echo "$RELEASE_JSON" \
    | grep '"browser_download_url"' \
    | grep '\.deb"' \
    | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/' \
    | head -n1)

[[ -n "$DEB_URL" ]] || err "No .deb package found in the latest release."

VERSION=$(echo "$RELEASE_JSON" \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name": "\([^"]*\)".*/\1/' \
    | head -n1)

info "Installing pve-mod ${VERSION}..."

# ── Download and install ───────────────────────────────────────────────────────
TMP=$(mktemp /tmp/pve-mod-XXXXXX.deb)
trap 'rm -f "$TMP"' EXIT

curl -sL -o "$TMP" "$DEB_URL" || err "Failed to download package from $DEB_URL"

dpkg -i "$TMP" || {
    info "Resolving missing dependencies..."
    apt-get install -f -y
    dpkg -i "$TMP"
}

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "pve-mod ${VERSION} installed successfully."
info "Run 'pve-mod-configure' to enable and configure modules."
echo ""
