#!/usr/bin/env bash
# install.sh — Bootstrap installer for pve-mods
# Usage: curl -sL https://github.com/Meliox/PVE-mods/releases/latest/download/install.sh | bash

set -euo pipefail

REPO="Meliox/PVE-mods"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

#region helpers
info() { echo -e "\e[0;32m[pve-mods] ${1}\e[0m"; }
err()  { echo -e "\e[0;31m[pve-mods] ERROR: ${1}\e[0m" >&2; exit 1; }
confirm_continue() {
    local reason="${1}"
    local response

    echo -e "\e[0;33m[pve-mods] WARNING: ${reason}\e[0m" >&2
    [[ -r /dev/tty ]] || err "Cannot ask for confirmation; aborting installation."
    read -r -p "Continue without checksum verification? [y/N] " response </dev/tty
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]] || err "Installation aborted."
}
confirm_install() {
    local version="${1}"
    local response

    [[ -r /dev/tty ]] || err "Cannot ask for confirmation; aborting installation."
    read -r -p "Install pve-mods ${version}? [Y/n] " response </dev/tty
    [[ -z "$response" || "$response" =~ ^[Yy]([Ee][Ss])?$ ]] || err "Installation aborted."
}
#endregion helpers

# ── Prerequisite checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "This installer must be run as root."

dpkg -l proxmox-ve &>/dev/null 2>&1 || \
    err "This system does not appear to be running Proxmox VE."

for cmd in curl dpkg sha256sum; do
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

# Extract SHA256SUMS download URL (exclude the .asc signature file)
SUMS_URL=$(echo "$RELEASE_JSON" \
    | grep '"browser_download_url"' \
    | grep 'SHA256SUMS"' \
    | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/' \
    | head -n1)

VERSION=$(echo "$RELEASE_JSON" \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name": "\([^"]*\)".*/\1/' \
    | head -n1)

info "Found version ${VERSION}..."

# ── Download and install ───────────────────────────────────────────────────────
TMP=$(mktemp /tmp/pve-mods-XXXXXX.deb)
SUMS_TMP=$(mktemp /tmp/pve-mods-XXXXXX.sums)
trap 'rm -f "$TMP" "$SUMS_TMP"' EXIT

curl -sL -o "$TMP" "$DEB_URL" || err "Failed to download package from $DEB_URL"

if [[ -n "$SUMS_URL" ]]; then
    if curl -sL -o "$SUMS_TMP" "$SUMS_URL"; then
        DEB_NAME=$(basename "$DEB_URL")
        EXPECTED_SUM=$(grep "${DEB_NAME}" "$SUMS_TMP" | awk '{print $1}' | head -n1)
        if [[ -z "$EXPECTED_SUM" ]]; then
            confirm_continue "Could not find checksum for ${DEB_NAME} in SHA256SUMS."
        else
            info "Verifying package checksum..."
            ACTUAL_SUM=$(sha256sum "$TMP" | awk '{print $1}')
            if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
                confirm_continue "Checksum verification failed for ${DEB_NAME}! Expected ${EXPECTED_SUM}, got ${ACTUAL_SUM}."
            else
                info "Checksum verified successfully."
            fi
        fi
    else
        confirm_continue "Failed to download SHA256SUMS from $SUMS_URL."
    fi
else
    confirm_continue "No SHA256SUMS file found in release; checksum verification will be skipped."
fi

confirm_install "$VERSION"
info "Installing pve-mods ${VERSION}..."

dpkg -i "$TMP" || {
    info "Resolving missing dependencies..."
    apt-get install -f -y
    dpkg -i "$TMP"
}

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "pve-mods ${VERSION} installed successfully."
info "Run 'pve-mods-configure' to enable and configure modules."
echo ""