#!/usr/bin/env bash
# /usr/lib/pve-mod/revert-patches.sh
#
# Generic patch reverter for pve-mod.
#
# Reverses every patch found under /usr/lib/pve-mod/patches/<mod>/ (regardless
# of whether the mod is currently enabled), using `patch -R -p1 -F0 -d /`.
# Patches are reverted in reverse manifest order. Patched text files need no
# backups - `patch -R` restores them exactly. Non-patch actions (e.g. the
# nag-screen min.js symlink) are undone by each mod's 'post-revert.sh' hook.
#
# Called by prerm before the package's files are removed.
#
# Hook exit-code convention: a hook returns 0 (no change), 100 (made a change,
# triggers a pveproxy restart), or any other code (error).

set -u

# Root paths (overridable via environment, mainly for testing).
PVE_MOD_ROOT="${PVE_MOD_ROOT:-/}"
CONFD_DIR="${PVE_MOD_CONFD_DIR:-/etc/pve-mod/conf.d}"
PATCHES_DIR="${PVE_MOD_PATCHES_DIR:-/usr/lib/pve-mod/patches}"
# Storage for non-patch replaced files (e.g. nag-screen's minified proxmoxlib).
STASH_DIR="${PVE_MOD_STASH_DIR:-/var/lib/pve-mod/backup}"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

# Revert a single patch. Returns 0 if a change was made, 1 otherwise.
revert_one_patch() {
    local patch="$1"
    # Not applied? (a clean forward apply means the change is absent)
    if patch -p1 -F0 -d "$PVE_MOD_ROOT" -f --dry-run -s < "$patch" >/dev/null 2>&1; then
        return 1
    fi
    if patch -R -p1 -F0 -d "$PVE_MOD_ROOT" -f --dry-run -s < "$patch" >/dev/null 2>&1; then
        patch -R -p1 -F0 -d "$PVE_MOD_ROOT" -f -s < "$patch"
        return 0
    fi
    warn "  $(basename "$patch") could not be reverted cleanly; manual cleanup may be needed"
    patch -R -p1 -F0 -f --dry-run --verbose -d "$PVE_MOD_ROOT" < "$patch" >&2 || true
    return 2
}

# ── main ──────────────────────────────────────────────────────────────────────
if ! command -v patch >/dev/null 2>&1; then
    warn "'patch' command not found; cannot revert mods."
    exit 0
fi

[[ -d "$PATCHES_DIR" ]] || exit 0

CHANGED=false
FAILED=false

mapfile -t _all_modules < <(for d in "$PATCHES_DIR"/*/; do [[ -d "$d" ]] && basename "$d"; done)
_target_modules=("${@:-${_all_modules[@]}}")
for mod in "${_target_modules[@]}"; do
    mod_dir="$PATCHES_DIR/$mod/"
    [[ -d "$mod_dir" ]] || continue
    manifest="$mod_dir/patches.list"
    mod_conf="$CONFD_DIR/$mod.conf"

    # Run the post-revert hook first (undo non-patch actions such as symlinks).
    hook="$mod_dir/post-revert.sh"
    if [[ -x "$hook" ]]; then
        info "Running post-revert hook for $mod"
        STASH_DIR="$STASH_DIR" MOD_CONF="$mod_conf" CONFD_DIR="$CONFD_DIR" "$hook"
        rc=$?
        case "$rc" in
            0)   ;;
            100) CHANGED=true ;;
            *)   warn "post-revert hook for $mod reported an error (exit $rc)" ;;
        esac
    fi

    [[ -f "$manifest" ]] || continue
    info "Reverting mod: $mod"

    # Collect patch names (ignore conditions and comments), then reverse order.
    mapfile -t patches < <(
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            [[ -z "$line" ]] && continue
            echo "${line%%[[:space:]]*}"
        done < "$manifest"
    )

    for (( i=${#patches[@]}-1 ; i>=0 ; i-- )); do
        patch_name="${patches[$i]}"
        patch_file="$mod_dir/$patch_name"
        [[ -f "$patch_file" ]] || continue
        revert_one_patch "$patch_file"
        rc=$?
        if [[ "$rc" -eq 0 ]]; then
            info "  reverted $patch_name"
            CHANGED=true
        elif [[ "$rc" -eq 2 ]]; then
            FAILED=true
        fi
    done
done

if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi

[[ "$FAILED" == "false" ]] || exit 1
exit 0
