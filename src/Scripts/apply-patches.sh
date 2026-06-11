#!/usr/bin/env bash
# /usr/lib/pve-mod/apply-patches.sh
#
# Generic patch applier for pve-mod.
#
# Reads /etc/pve-mod/pve-mod.conf [modules] to learn which mods are enabled,
# then applies each enabled mod's patches from /usr/lib/pve-mod/patches/<mod>/.
#
# Patch convention: every .patch uses a/<path> b/<path> headers and is applied
# with `patch -p1 -F0 -d /` (zero fuzz: line offsets tolerated, fuzzy context
# matching disabled). Each mod folder contains a 'patches.list' manifest and
# optional 'post-apply.sh' / 'post-revert.sh' hooks.
#
# Per-mod atomicity: before applying, every active patch of a mod is dry-run.
# If any one cannot be applied (or is already partially/broken-applied), the
# whole mod is reverted to a clean state and reported as failed - a mod is
# never left half-applied.
#
# Idempotent: a patch that is already applied is detected (reverse dry-run) and
# skipped, so this script is safe to run repeatedly (e.g. from the dpkg trigger
# after a pve-manager upgrade).
#
# Hook exit-code convention: a hook returns 0 (no change), 100 (made a change,
# triggers a pveproxy restart), or any other code (error).

set -u

# Root paths (overridable via environment, mainly for testing).
PVE_MOD_ROOT="${PVE_MOD_ROOT:-/}"
MAIN_CONF="${PVE_MOD_MAIN_CONF:-/etc/pve-mod/pve-mod.conf}"
CONFD_DIR="${PVE_MOD_CONFD_DIR:-/etc/pve-mod/conf.d}"
PATCHES_DIR="${PVE_MOD_PATCHES_DIR:-/usr/lib/pve-mod/patches}"
# Storage for non-patch replaced files (e.g. nag-screen's minified proxmoxlib).
# Patched text files need no backups - `patch -R` reverts them.
STASH_DIR="${PVE_MOD_STASH_DIR:-/var/lib/pve-mod/backup}"

info() { echo "[pve-mod] $*"; }
warn() { echo "[pve-mod] WARNING: $*" >&2; }

# read_conf <file> <section> <key> [default]
# Prints one value from an INI file, or the default if absent.
read_conf() {
    local file="$1" section="$2" key="$3" default="${4:-0}"
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    local val
    val=$(awk -F= -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == k) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2; exit
            }
        }
    ' "$file")
    echo "${val:-$default}"
}

# List the keys of the [modules] section in the main config, one per line.
list_modules() {
    [[ -f "$MAIN_CONF" ]] || return 0
    awk -F= '
        /^\[/ { in_sec = ($0 == "[modules]") }
        in_sec && /^[^#=]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            print $1
        }
    ' "$MAIN_CONF"
}

# Patch-state helpers (all use zero fuzz for deterministic detection).
_dry_forward() { patch -p0 -F0 -f --dry-run --verbose < "$1"; }
_dry_reverse() { patch -R -p0 -F0 -f --dry-run --verbose < "$1"; }
is_applied()   { _dry_reverse "$1"; }
can_apply()    { _dry_forward "$1"; }
do_apply()     { patch -p0 -F0 -f -s < "$1"; }
do_revert()    { patch -R -p0 -F0 -f -s < "$1"; }

CHANGED=false
FAILED=false

# Run a mod hook honouring the exit-code convention. Sets CHANGED / FAILED.
run_hook() {
    local hook="$1" mod_conf="$2"
    [[ -x "$hook" ]] || return 0
    STASH_DIR="$STASH_DIR" MOD_CONF="$mod_conf" CONFD_DIR="$CONFD_DIR" "$hook"
    local rc=$?
    case "$rc" in
        0)   ;;
        100) CHANGED=true ;;
        *)   warn "  hook $(basename "$hook") reported an error (exit $rc)"; FAILED=true; return 1 ;;
    esac
    return 0
}

# ── main ──────────────────────────────────────────────────────────────────────
if ! command -v patch >/dev/null 2>&1; then
    warn "'patch' command not found; cannot apply mods. Install the 'patch' package."
    exit 1
fi

for mod in $(list_modules); do
    [[ "$(read_conf "$MAIN_CONF" modules "$mod" 0)" == "1" ]] || continue

    mod_dir="$PATCHES_DIR/$mod"
    manifest="$mod_dir/patches.list"
    mod_conf="$CONFD_DIR/$mod.conf"

    if [[ ! -f "$manifest" ]]; then
        warn "No patch manifest for enabled mod '$mod' ($manifest); skipping."
        FAILED=true
        continue
    fi

    info "Checking mod: $mod"

    # Build the list of active patch files (those whose condition is met).
    active=()
    preflight_ok=true
    while IFS= read -r line; do
        # Strip comments and surrounding whitespace; skip blanks.
        line="${line%%#*}"
        line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [[ -z "$line" ]] && continue

        # Format: <patch-file> [section.key=value]
        patch_name="${line%%[[:space:]]*}"
        condition=""
        if [[ "$line" == *[[:space:]]* ]]; then
            condition="$(echo "${line#"$patch_name"}" | sed -E 's/^[[:space:]]+//')"
        fi

        # Evaluate optional condition against the mod's conf.d file.
        if [[ -n "$condition" ]]; then
            local_key="${condition%%=*}"
            want="${condition#*=}"
            sect="${local_key%%.*}"
            ckey="${local_key#*.}"
            if [[ "$(read_conf "$mod_conf" "$sect" "$ckey" 0)" != "$want" ]]; then
                info "  skip $patch_name (condition $condition not met)"
                continue
            fi
        fi

        patch_file="$mod_dir/$patch_name"
        if [[ ! -f "$patch_file" ]]; then
            warn "  patch file missing: $patch_file"
            preflight_ok=false
            continue
        fi
        active+=("$patch_file")
    done < "$manifest"

    # Preflight dry-run: every active patch must be already applied or cleanly
    # appliable. Otherwise the mod cannot be installed atomically.
    to_apply=()
    if [[ "$preflight_ok" == "true" ]]; then
        for pf in "${active[@]}"; do
            if is_applied "$pf"; then
                continue
            elif can_apply "$pf"; then
                to_apply+=("$pf")
            else
                warn "  $(basename "$pf") does not apply cleanly"
                preflight_ok=false
                break
            fi
        done
    fi

    # If preflight failed, revert the whole mod back to a clean state so it is
    # never left half-applied.
    if [[ "$preflight_ok" != "true" ]]; then
        warn "Mod '$mod': preflight failed - reverting mod to clean state."
        for (( i=${#active[@]}-1 ; i>=0 ; i-- )); do
            pf="${active[$i]}"
            if is_applied "$pf"; then
                do_revert "$pf" && { info "  reverted $(basename "$pf")"; CHANGED=true; }
            fi
        done
        run_hook "$mod_dir/post-revert.sh" "$mod_conf"
        FAILED=true
        continue
    fi

    # Apply the outstanding patches.
    if [[ ${#to_apply[@]} -gt 0 ]]; then
        for pf in "${to_apply[@]}"; do
            do_apply "$pf" && { info "  applied $(basename "$pf")"; CHANGED=true; }
        done
    else
        info "  already up to date"
    fi

    # Run the post-apply hook. If it errors, roll the mod back so it is never
    # left half-applied (matches the preflight atomicity contract).
    if ! run_hook "$mod_dir/post-apply.sh" "$mod_conf"; then
        warn "Mod '$mod': post-apply hook failed - reverting mod to clean state."
        run_hook "$mod_dir/post-revert.sh" "$mod_conf"
        for (( i=${#active[@]}-1 ; i>=0 ; i-- )); do
            pf="${active[$i]}"
            if is_applied "$pf"; then
                do_revert "$pf" && { info "  reverted $(basename "$pf")"; CHANGED=true; }
            fi
        done
        FAILED=true
        continue
    fi
done

if [[ "$CHANGED" == "true" ]]; then
    info "Restarting pveproxy..."
    systemctl restart pveproxy 2>/dev/null || true
fi

[[ "$FAILED" == "true" ]] && exit 1
exit 0
