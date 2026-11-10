#!/bin/sh
# Installs the latest DiskMap release.
#
#   curl -fsSL https://raw.githubusercontent.com/kddige/diskmap/main/install.sh | sh
#
# DISKMAP_DIR      where to put DiskMap.app (default: /Applications)
# DISKMAP_VERSION  a release tag such as v0.1.0 (default: the latest release)
set -eu

# Everything runs from main, so a download cut off halfway executes nothing.
main() {
    repo="kddige/diskmap"

    [ "$(uname -s)" = "Darwin" ] || fail "DiskMap only runs on macOS."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 15 ] || fail "DiskMap needs macOS 15 or later (this is $(sw_vers -productVersion))."

    dest=${DISKMAP_DIR:-/Applications}
    if [ ! -w "$dest" ]; then
        [ -z "${DISKMAP_DIR:-}" ] || fail "Cannot write to $dest."
        dest="$HOME/Applications"
        mkdir -p "$dest"
    fi

    if [ -n "${DISKMAP_VERSION:-}" ]; then
        url="https://github.com/$repo/releases/download/$DISKMAP_VERSION"
    else
        url="https://github.com/$repo/releases/latest/download"
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    echo "Downloading DiskMap..."
    curl -fsSL "$url/DiskMap.zip" -o "$tmp/DiskMap.zip" || fail "Download failed: $url/DiskMap.zip"
    curl -fsSL "$url/DiskMap.zip.sha256" -o "$tmp/DiskMap.zip.sha256" || fail "Download failed: $url/DiskMap.zip.sha256"
    (cd "$tmp" && shasum -a 256 -c DiskMap.zip.sha256 >/dev/null) || fail "The download is damaged (checksum mismatch)."

    ditto -x -k "$tmp/DiskMap.zip" "$tmp"
    [ -d "$tmp/DiskMap.app" ] || fail "The archive does not contain DiskMap.app."

    rm -rf "$dest/DiskMap.app"
    ditto "$tmp/DiskMap.app" "$dest/DiskMap.app"

    # DiskMap is not notarized by Apple. Files fetched by curl are not
    # quarantined, but clear the flag anyway so Gatekeeper never blocks it.
    xattr -dr com.apple.quarantine "$dest/DiskMap.app" 2>/dev/null || true

    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dest/DiskMap.app/Contents/Info.plist" 2>/dev/null || echo "?")
    echo "Installed DiskMap $version in $dest"
    echo "Start it with:  open \"$dest/DiskMap.app\""
}

fail() {
    echo "install.sh: $1" >&2
    exit 1
}

main "$@"
