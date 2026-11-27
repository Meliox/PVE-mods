#!/usr/bin/env bash
set -euo pipefail

output_dir="${1:?output directory required}"
packages_dir="$(cd "${2:?package directory required}" && pwd)"

mkdir -p "$output_dir"
touch "$output_dir/.nojekyll"
cd "$output_dir"

for channel in stable testing; do
    suite=trixie
    if [ "$channel" = testing ]; then
        suite=trixie-testing
    fi
    mkdir -p "dists/$suite/main/binary-amd64" pool/main/p/pve-mods

    shopt -s nullglob
    packages=("$packages_dir/$channel/"*.deb)
    if [ "${#packages[@]}" -gt 0 ]; then
        cp "${packages[@]}" pool/main/p/pve-mods/
    fi

    for package in "${packages[@]}"; do
        package_name=$(dpkg-deb --field "$package" Package)
        version=$(dpkg-deb --field "$package" Version)
        version=${version#*:}
        changelog_dir="changelogs/main/${package_name:0:1}/$package_name/${package_name}_$version"
        mkdir -p "$changelog_dir"
        dpkg-deb --fsys-tarfile "$package" \
            | tar -xOf - "./usr/share/doc/$package_name/changelog.gz" \
            | gzip -dc > "$changelog_dir/changelog"
        if [ ! -s "$changelog_dir/changelog" ]; then
            echo "::error::Missing or empty changelog in $package."
            exit 1
        fi
    done

    dpkg-scanpackages --multiversion --arch all pool /dev/null \
        > "dists/$suite/main/binary-amd64/Packages"
    gzip -9 -k "dists/$suite/main/binary-amd64/Packages"

    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="Meliox" \
        -o APT::FTPArchive::Release::Label="PVE-mods" \
        -o APT::FTPArchive::Release::Suite="$suite" \
        -o APT::FTPArchive::Release::Codename="$suite" \
        release "dists/$suite" \
        > "dists/$suite/Release"
    printf '%s\n' \
        'Changelogs: https://pve-mods-apt.meliox.workers.dev/changelogs/@CHANGEPATH@/changelog' \
        >> "dists/$suite/Release"

    rm -rf pool
done
