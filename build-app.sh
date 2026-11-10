#!/bin/sh
# Builds DiskMap.app next to this script.
#   ./build-app.sh              build for this Mac and sign
#   ./build-app.sh --universal  build for Apple silicon and Intel (needs Xcode)
#   ./build-app.sh --install    also copy to /Applications
#
# CODESIGN_IDENTITY picks the signing identity; "-" forces an ad-hoc signature.
set -eu
cd "$(dirname "$0")"

ARCH_FLAGS=""
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) ARCH_FLAGS="--arch arm64 --arch x86_64" ;;
        --install) INSTALL=1 ;;
        *) echo "usage: $0 [--universal] [--install]" >&2; exit 2 ;;
    esac
done

# Written by the release pipeline; do not edit by hand.
VERSION=$(tr -d '[:space:]' < version.txt)

# shellcheck disable=SC2086 # the flags are meant to split into words
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

APP=DiskMap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DiskMap" "$APP/Contents/MacOS/DiskMap"
cp "$BIN/dmscan" "$APP/Contents/MacOS/dmscan"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DiskMap</string>
    <key>CFBundleDisplayName</key><string>DiskMap</string>
    <key>CFBundleIdentifier</key><string>io.github.kddige.diskmap</string>
    <key>CFBundleExecutable</key><string>DiskMap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key><string>DiskMap measures the files in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>DiskMap measures the files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>DiskMap measures the files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>DiskMap measures the files on removable volumes you choose to scan.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>DiskMap measures the files on network volumes you choose to scan.</string>
</dict>
</plist>
PLIST

# Full Disk Access is granted to a code signature. An ad-hoc signature changes
# with every build, so the grant has to be given again each time; a real
# identity keeps it.
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && $2 ~ /^[0-9A-F]+$/ {print $2}')}
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/dmscan" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP/Contents/MacOS/dmscan" "$APP"
    echo "Signed ad hoc (Full Disk Access must be granted again after each rebuild)"
fi

if [ "$INSTALL" = 1 ]; then
    rm -rf /Applications/DiskMap.app
    cp -R "$APP" /Applications/DiskMap.app
    echo "Installed /Applications/DiskMap.app $VERSION"
else
    echo "Built $(pwd)/$APP $VERSION"
fi
