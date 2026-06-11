#!/usr/bin/env bash
# src/gen-rules.sh
#
# Generates the per-module portion of the Debian build configuration from each
# module's metadata, so adding or changing a module never requires touching
# debian/rules by hand.
#
# A module is any directory under src/ that contains a files/ and/or patches/
# subdirectory (so src/Scripts/, which has neither, is ignored). The module's
# directory name is its canonical mod key (matches the [modules] keys in
# pve-mod.conf and the install path usr/lib/pve-mod/patches/<mod>/).
#
# Usage:
#   gen-rules.sh            Emit dpkg install lines (tab-indented, no header).
#                           Append to debian/rules' override_dh_install recipe:
#                               bash src/gen-rules.sh >> debian/rules
#   gen-rules.sh conffiles  Emit per-module conffile paths (one per line).
#                           Append to debian/pve-mod.conffiles:
#                               bash src/gen-rules.sh conffiles >> debian/pve-mod.conffiles
#
# For each module it emits, in order:
#   1. files/files.list  -> install each mapped file at its destination.
#                           Format: <source> <destination> [permission]
#                           (permission defaults to 644; source is relative to
#                           the module's files/ directory).
#   2. patches/*         -> every file under patches/ recursively, including
#                           patches.list and hook scripts. Shell scripts (.sh)
#                           get mode 755, everything else 644. Installed under
#                           usr/lib/pve-mod/patches/<mod>/<relative-path>.
#   3. <mod>.conf        -> if present in the module root, installed as a
#                           conffile at etc/pve-mod/conf.d/<mod>.conf (644) plus
#                           a reference copy at
#                           usr/share/pve-mod/conf.d/<mod>.conf.default (644).

set -euo pipefail

# Resolve repository root from this script's location so paths are stable
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/src"
PKG_DIR="debian/pve-mod"

MODE="${1:-install}"

# Print the list of module directory names (basenames), sorted, that contain a
# files/ or patches/ subdirectory.
list_modules() {
    local d name
    for d in "$SRC_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        if [[ -d "$d/files" || -d "$d/patches" ]]; then
            echo "$name"
        fi
    done | sort
}

# Emit a single tab-indented `install -D` line.
# Args: <mode> <relative-source> <relative-destination>
emit_install() {
    printf '\tinstall -Dm%s %s %s/%s\n' "$1" "$2" "$PKG_DIR" "$3"
}

emit_install_rules() {
    local mod="$1"
    local mod_dir="$SRC_DIR/$mod"
    local rel_mod="src/$mod"

    # 1. Mapped files from files/files.list.
    local manifest="$mod_dir/files/files.list"
    if [[ -f "$manifest" ]]; then
        local src dest perm
        while read -r src dest perm; do
            # Tolerate CRLF line endings.
            src="${src%$'\r'}"; dest="${dest%$'\r'}"; perm="${perm%$'\r'}"
            # Skip comments and blank lines.
            [[ -z "${src:-}" || "$src" == \#* ]] && continue
            perm="${perm:-644}"
            emit_install "$perm" "$rel_mod/files/$src" "$dest"
        done < "$manifest"
    fi

    # 2. Everything under patches/ (recursive): .sh -> 755, else 644.
    local patches_dir="$mod_dir/patches"
    if [[ -d "$patches_dir" ]]; then
        local f rel perm
        while IFS= read -r f; do
            rel="${f#"$patches_dir"/}"
            if [[ "$rel" == *.sh ]]; then
                perm=755
            else
                perm=644
            fi
            emit_install "$perm" "$rel_mod/patches/$rel" "usr/lib/pve-mod/patches/$mod/$rel"
        done < <(find "$patches_dir" -type f | sort)
    fi

    # 3. Per-module config: conffile + reference default copy.
    local conf="$mod_dir/$mod.conf"
    if [[ -f "$conf" ]]; then
        emit_install 644 "$rel_mod/$mod.conf" "etc/pve-mod/conf.d/$mod.conf"
        emit_install 644 "$rel_mod/$mod.conf" "usr/share/pve-mod/conf.d/$mod.conf.default"
    fi
}

emit_conffiles() {
    local mod="$1"
    if [[ -f "$SRC_DIR/$mod/$mod.conf" ]]; then
        echo "/etc/pve-mod/conf.d/$mod.conf"
    fi
}

main() {
    local mod
    case "$MODE" in
        install)
            for mod in $(list_modules); do
                emit_install_rules "$mod"
            done
            ;;
        conffiles)
            for mod in $(list_modules); do
                emit_conffiles "$mod"
            done
            ;;
        *)
            echo "Usage: $0 [install|conffiles]" >&2
            exit 2
            ;;
    esac
}

main
