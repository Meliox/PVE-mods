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
