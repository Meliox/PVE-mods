#!/usr/bin/env bash

# report_patch_failure <patch-file> [reverse]
# Prints patch's verbose failure details and context from the affected file.
report_patch_failure() {
    local patch_file="$1" direction="${2:-forward}" output line current_file=""
    local target_path root start end hunk_number
    local -a args

    args=(-p1 -F0 -f --dry-run --verbose -d "$PVE_MODs_ROOT")
    [[ "$direction" == "reverse" ]] && args=(-R "${args[@]}")
    output="$(patch "${args[@]}" < "$patch_file" 2>&1)" || true
    grep -E '^(checking file|Hunk #|[0-9]+ out of [0-9]+ hunks? FAILED)' <<< "$output" >&2 || true

    root="$PVE_MODs_ROOT"
    [[ "$root" == /* ]] || root="$PWD/$root"
    while IFS= read -r line; do
        if [[ "$line" =~ ^checking\ file\ (.+)$ ]]; then
            current_file="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Hunk\ \#([0-9]+)\ FAILED\ at\ ([0-9]+)\.?$ ]]; then
            hunk_number="${BASH_REMATCH[1]}"
            line="${BASH_REMATCH[2]}"
            target_path="${root%/}/$current_file"
            if [[ -f "$target_path" ]]; then
                start=$((line - 3))
                (( start < 1 )) && start=1
                end=$((line + 3))
                echo "Context at $target_path:$line (hunk #$hunk_number; 3 lines before/after):" >&2
                nl -ba "$target_path" | sed -n "${start},${end}p" >&2
            fi
        fi
    done <<< "$output"
}

# patch_target_files <patch-file>
# Prints the files a patch modifies (relative to the root), one per line.
patch_target_files() {
    awk '/^\+\+\+ / { sub(/^b\//, "", $2); print $2 }' "$1"
}

# report_restore_hint <patch-file>...
# Tells the user how to restore the original files a patch modifies: the
# owning package(s) when known, otherwise a generic instruction.
report_restore_hint() {
    local patch_file file pkg
    local -a pkgs=()
    if [[ "${PVE_MODs_ROOT:-/}" == "/" ]] && command -v dpkg >/dev/null 2>&1; then
        for patch_file in "$@"; do
            while IFS= read -r file; do
                [[ -n "$file" ]] || continue
                pkg="$(dpkg -S -- "/$file" 2>/dev/null | awk '!/^diversion/ { sub(/: .*/, ""); print; exit }')"
                [[ -n "$pkg" && " ${pkgs[*]} " != *" $pkg "* ]] && pkgs+=("$pkg")
            done < <(patch_target_files "$patch_file")
        done
    fi
    if (( ${#pkgs[@]} > 0 )); then
        echo "[pve-mods] If the file was modified outside pve-mods, restore it with: apt reinstall ${pkgs[*]}" >&2
    else
        echo "[pve-mods] If the file was modified outside pve-mods, reinstall the package that owns it ('dpkg -S <file>' shows which)." >&2
    fi
    echo "[pve-mods] If the file is unmodified, the patch is likely incompatible with the installed Proxmox version; check for a newer pve-mods release or report it at https://github.com/Meliox/PVE-mods/issues" >&2
}
