#!/usr/bin/env bash
# Report which downloaded packages provide a module's patch targets.

set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 <module-patches-dir> <package-dir>" >&2; exit 2; }
patch_dir="$1"
package_dir="$2"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

[[ -f "$patch_dir/patches.list" ]] || { echo "Missing patch manifest: $patch_dir/patches.list" >&2; exit 1; }
shopt -s nullglob
packages=("$package_dir"/*.deb)
(( ${#packages[@]} > 0 )) || { echo "No downloaded packages in $package_dir" >&2; exit 1; }

: > "$workdir/targets"
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r patch_name _ <<< "$line"
    [[ -n "${patch_name:-}" ]] || continue
    patch_file="$patch_dir/$patch_name"
    [[ -f "$patch_file" ]] || { echo "Missing patch: $patch_file" >&2; exit 1; }
    awk '/^\+\+\+ / {
        path = $2
        sub(/^b\//, "", path)
        sub(/^\//, "", path)
        if (path != "dev/null") print path
    }' "$patch_file" >> "$workdir/targets"
done < "$patch_dir/patches.list"
sort -u "$workdir/targets" -o "$workdir/targets"
[[ -s "$workdir/targets" ]] || { echo "No patch targets found in $patch_dir" >&2; exit 1; }

: > "$workdir/owners"
for deb in "${packages[@]}"; do
    package="$(dpkg-deb --field "$deb" Package)"
    version="$(dpkg-deb --field "$deb" Version)"
    dpkg-deb --fsys-tarfile "$deb" | tar -tf - | awk -v pkg="$package" -v ver="$version" '
        { sub(/^\.\//, ""); print $0 "\t" pkg "\t" ver }
    ' >> "$workdir/owners"
done

awk -F '\t' '
    NR == FNR { targets[$0] = 1; order[++count] = $0; next }
    $1 in targets {
        owners[$1] = owners[$1] sprintf("- `/%s`: `%s` `%s`\n", $1, $2, $3)
    }
    END {
        for (i = 1; i <= count; i++) {
            path = order[i]
            if (path in owners) printf "%s", owners[path]
            else printf "- `/%s`: no downloaded package provides this file\n", path
        }
    }
' "$workdir/targets" "$workdir/owners"
