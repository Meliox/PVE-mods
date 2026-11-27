#!/usr/bin/env bash
set -euo pipefail
trap 'echo "APT repository test failed at line $LINENO: $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

for channel in stable testing; do
    version=1.0
    [ "$channel" = testing ] && version=2.0~rc1
    package="$dir/package-$channel"
    mkdir -p "$package/DEBIAN" "$package/usr/share/doc/pve-mods" "$dir/packages/$channel"
    printf 'Package: pve-mods\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: Test package\n' "$version" > "$package/DEBIAN/control"
    printf 'pve-mods (%s) stable; urgency=low\n' "$version" | gzip -n > "$package/usr/share/doc/pve-mods/changelog.gz"
    dpkg-deb --build "$package" "$dir/packages/$channel/pve-mods_${version}_all.deb" > /dev/null
done

bash "$repo_root/build/apt-repository.sh" "$dir/repo" "$dir/packages"
test -s "$dir/repo/changelogs/main/p/pve-mods/pve-mods_1.0/changelog"
test -s "$dir/repo/changelogs/main/p/pve-mods/pve-mods_2.0~rc1/changelog"

mkdir -m 700 "$dir/gnupg"
gpg --batch --homedir "$dir/gnupg" --passphrase '' --quick-generate-key \
    'APT repository test <apt-test@example.invalid>' rsa2048 sign 0 > /dev/null
gpg --batch --homedir "$dir/gnupg" --export > "$dir/keyring.gpg"

for channel in stable testing; do
    version=1.0
    [ "$channel" = testing ] && version=2.0~rc1
    suite=trixie
    [ "$channel" = testing ] && suite=trixie-testing
    index="$dir/repo/dists/$suite/main/binary-amd64"
    grep -Fx "Version: $version" "$index/Packages" > /dev/null
    gzip -dc "$index/Packages.gz" | cmp - "$index/Packages"
    test ! -e "$dir/repo/dists/$channel"
    release="$dir/repo/dists/$suite/Release"
    grep -Fx "Suite: $suite" "$release" > /dev/null
    grep -Fx "Codename: $suite" "$release" > /dev/null
    gpg --batch --yes --homedir "$dir/gnupg" --clearsign \
        --output "$dir/repo/dists/$suite/InRelease" "$release"
done

mkdir -p "$dir/apt/lists/partial" "$dir/apt/archives/partial"
touch "$dir/apt/status"
apt_options=(
    -o "Dir::Etc::sourcelist=$dir/apt/pve-mods.sources"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::status=$dir/apt/status"
    -o "Dir::State::lists=$dir/apt/lists"
    -o "Dir::Cache::archives=$dir/apt/archives"
    -o "APT::Sandbox::User=$(id -un)"
    -o "APT::Architecture=amd64"
)

for suite in stable testing; do
    printf 'Types: deb\nURIs: file:%s\nSuites: %s\nComponents: main\nSigned-By: %s\n' \
        "$dir/repo" "$suite" "$dir/keyring.gpg" > "$dir/apt/pve-mods.sources"
    if apt-get "${apt_options[@]}" update > "$dir/apt/update.log" 2>&1; then
        echo "Legacy suite $suite unexpectedly succeeded" >&2
        exit 1
    fi
done

for suite in trixie trixie-testing; do
    version=1.0
    case "$suite" in *testing) version=2.0~rc1 ;; esac
    printf 'Types: deb\nURIs: file:%s\nSuites: %s\nComponents: main\nSigned-By: %s\n' \
        "$dir/repo" "$suite" "$dir/keyring.gpg" > "$dir/apt/pve-mods.sources"
    apt-get "${apt_options[@]}" update > "$dir/apt/update.log" 2>&1 || {
        cat "$dir/apt/update.log" >&2
        exit 1
    }
    if grep -E 'Conflicting distribution|changed its .*(Suite|Codename)' "$dir/apt/update.log"; then
        exit 1
    fi
    apt-cache "${apt_options[@]}" policy pve-mods | grep -F "Candidate: $version" > /dev/null
done

mkdir -p "$dir/empty-packages/stable" "$dir/empty-packages/testing"
cp "$dir/packages/stable/pve-mods_1.0_all.deb" "$dir/empty-packages/stable/"
bash "$repo_root/build/apt-repository.sh" "$dir/empty-repo" "$dir/empty-packages"
test ! -s "$dir/empty-repo/dists/trixie-testing/main/binary-amd64/Packages"
grep -Fx 'Codename: trixie-testing' "$dir/empty-repo/dists/trixie-testing/Release" > /dev/null

echo "APT suite metadata and signed updates passed"
