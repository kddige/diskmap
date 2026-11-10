#!/bin/sh
# Regenerates docs/screenshot.png from made-up data, so the README never shows
# anybody's real files.
#
# Mounts a scratch disk image, fills it with scripts/demo-tree.swift, scans it
# with the app and saves a picture of the window. The fake files reserve real
# disk space while this runs (60 GB unless you pass another total); it is
# released at the end.
#
#   scripts/make-screenshot.sh [total GB]
set -eu
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
VOLUME="/Volumes/Demo"
cleanup() {
    hdiutil detach "$VOLUME" -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

[ ! -e "$VOLUME" ] || { echo "$VOLUME already exists" >&2; exit 1; }

swift build -c release
hdiutil create -size 200g -type SPARSE -fs APFS -volname Demo "$WORK/demo.sparseimage" >/dev/null 2>&1
hdiutil attach "$WORK/demo.sparseimage" -nobrowse >/dev/null 2>&1
swift scripts/demo-tree.swift "$VOLUME" "${1:-60}"

mkdir -p docs
.build/release/DiskMap "$VOLUME" --snapshot "$WORK/window.png" -AppleLocale en_US -AppleLanguages "(en)"
# Twice the width GitHub shows it at, so it stays sharp on a Retina display.
sips --resampleWidth 1760 "$WORK/window.png" --out docs/screenshot.png >/dev/null
echo "Wrote docs/screenshot.png"
