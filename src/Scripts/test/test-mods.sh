#!/usr/bin/env bash
# src/Scripts/test/test-mods.sh
#
# Exercises pve-mod's patch engine against the installed Proxmox files.
#
# Usage: test-mods.sh <mod> | all
#
# Mods are auto-discovered from the [modules] section of the main config, so
# adding a new mod (a new [modules] key plus a patches/<mod>/ directory) is
# picked up automatically - no edits to this script are required.
#
# For each target mod it:
#   1. enables only that mod in the main config
#   2. turns on every conditional flag referenced by the mod's patches.list,
#      so all of the mod's patches are exercised (e.g. node_info's gpu_history)
#   3. runs apply-patches.sh and asserts it exits 0
#   4. runs revert-patches.sh and asserts it reports no unclean reversions
#
# Failure detection relies on the apply exit code: the patch engine performs an
# atomic preflight dry-run and exits non-zero if any mod cannot apply cleanly.
#
# Must run as root (it edits /etc/pve-mod and the patched system files).

set -u

MAIN_CONF="${PVE_MOD_MAIN_CONF:-/etc/pve-mod/pve-mod.conf}"
CONFD_DIR="${PVE_MOD_CONFD_DIR:-/etc/pve-mod/conf.d}"
PATCHES_DIR="${PVE_MOD_PATCHES_DIR:-/usr/lib/pve-mod/patches}"
APPLY="${PVE_MOD_APPLY:-/usr/lib/pve-mod/apply-patches.sh}"
REVERT="${PVE_MOD_REVERT:-/usr/lib/pve-mod/revert-patches.sh}"

info() { echo "[test] $*"; }
warn() { echo "[test] WARNING: $*" >&2; }

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

# set_conf <file> <section> <key> <value>: set an existing key within a section.
set_conf() {
    local file="$1" section="$2" key="$3" value="$4"
    [[ -f "$file" ]] || { warn "config not found: $file"; return 1; }
    awk -v sec="[$section]" -v k="$key" -v v="$value" '
        /^\[/ { in_sec = ($0 == sec) }
        {
            if (in_sec && $0 ~ "^[[:space:]]*"k"[[:space:]]*=") {
                print k"="v
            } else {
                print
            }
        }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Disable every discovered mod in the main config.
disable_all_modules() {
    local m
    for m in $(list_modules); do
        set_conf "$MAIN_CONF" modules "$m" 0
    done
}

# Turn on every conditional flag a mod's patches.list references, so all of its
# patches become active. Conditions look like: <patch-file> section.key=value
enable_conditions() {
    local mod="$1"
    local manifest="$PATCHES_DIR/$mod/patches.list"
    local mod_conf="$CONFD_DIR/$mod.conf"
    [[ -f "$manifest" ]] || return 0
    local line cond local_key want sect ckey
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [[ -z "$line" ]] && continue
        # Skip lines without a condition (no whitespace after the patch name).
        [[ "$line" == *[[:space:]]* ]] || continue
        cond="$(echo "${line#*[[:space:]]}" | sed -E 's/^[[:space:]]+//')"
        [[ "$cond" == *=* ]] || continue
        local_key="${cond%%=*}"
        want="${cond#*=}"
        sect="${local_key%%.*}"
        ckey="${local_key#*.}"
        set_conf "$mod_conf" "$sect" "$ckey" "$want" \
            && info "  enabled condition $local_key=$want in $(basename "$mod_conf")"
    done < "$manifest"
}

# Test a single mod end to end. Returns 0 on success, 1 on failure.
test_one_mod() {
    local mod="$1"
    echo "::group::Testing mod: $mod"
    local ok=0

    if [[ ! -f "$PATCHES_DIR/$mod/patches.list" ]]; then
        warn "no patch manifest for mod '$mod' ($PATCHES_DIR/$mod/patches.list)"
        echo "::endgroup::"
        return 1
    fi

    disable_all_modules
    set_conf "$MAIN_CONF" modules "$mod" 1
    enable_conditions "$mod"

    info "Applying patches for '$mod'..."
    local apply_log apply_rc
    apply_log="$("$APPLY" 2>&1)"; apply_rc=$?
    echo "$apply_log"
    if [[ $apply_rc -ne 0 ]]; then
        warn "apply-patches.sh failed for mod '$mod' (exit $apply_rc)"
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        info "Reverting patches for '$mod'..."
        local revert_log
        revert_log="$("$REVERT" 2>&1)"
        echo "$revert_log"
        if echo "$revert_log" | grep -qE "could not be reverted cleanly|reported an error"; then
            warn "revert-patches.sh reported an unclean revert for mod '$mod'"
            ok=1
        fi
    fi

    if [[ $ok -eq 0 ]]; then
        info "PASS: $mod"
    else
        warn "FAIL: $mod"
    fi
    echo "::endgroup::"
    return $ok
}

# ── main ──────────────────────────────────────────────────────────────────────
[[ $# -eq 1 ]] || { echo "Usage: $0 <mod>|all" >&2; exit 2; }

if ! command -v patch >/dev/null 2>&1; then
    warn "'patch' command not found; install the 'patch' package."
    exit 1
fi

targets=()
if [[ "$1" == "all" ]]; then
    mapfile -t targets < <(list_modules)
    [[ ${#targets[@]} -gt 0 ]] || { warn "no mods found in [modules] of $MAIN_CONF"; exit 1; }
else
    targets=("$1")
fi

failed=()
for mod in "${targets[@]}"; do
    test_one_mod "$mod" || failed+=("$mod")
done

echo ""
if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed mods: ${failed[*]}"
    exit 1
fi
info "All tested mods passed: ${targets[*]}"
exit 0
