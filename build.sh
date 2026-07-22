#!/bin/bash
# Verse — lyrics in your notch
#
#   ./build.sh          build Verse.app into ./build
#   ./build.sh run      build and launch
#   ./build.sh install  build and copy to /Applications
#   ./build.sh clean    remove build products
#
# Requires: Xcode command line tools, cmake (brew install cmake), git.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Verse
APP_BUNDLE="build/$APP_NAME.app"
ADAPTER_REPO="https://github.com/ungive/mediaremote-adapter.git"
ADAPTER_DIR="vendor/mediaremote-adapter"
ADAPTER_BUILD="$ADAPTER_DIR/build"
FRAMEWORK="$ADAPTER_BUILD/MediaRemoteAdapter.framework"

if [ "${1:-}" = "clean" ]; then
    rm -rf build .build "$ADAPTER_BUILD"
    echo "Cleaned."
    exit 0
fi

# ---- MediaRemoteAdapter.framework (now-playing access on macOS 15.4+) ----
if [ ! -d "$FRAMEWORK" ]; then
    if [ ! -d "$ADAPTER_DIR" ]; then
        echo "Cloning mediaremote-adapter…"
        git clone --depth 1 "$ADAPTER_REPO" "$ADAPTER_DIR"
    fi
    cmake -S "$ADAPTER_DIR" -B "$ADAPTER_BUILD"
    cmake --build "$ADAPTER_BUILD"
fi

# ---- App icon (.icns from the appiconset PNGs) ----
ICNS="build/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ assets/AppIcon.appiconset -nt "$ICNS" ]; then
    mkdir -p build
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    cp assets/AppIcon.appiconset/icon_*.png "$ICONSET/"
    iconutil -c icns "$ICONSET" -o "$ICNS"
    rm -rf "$ICONSET"
fi

# ---- App ----
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp "$ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp assets/MenuBarIcon.png assets/MenuBarIcon@2x.png "$APP_BUNDLE/Contents/Resources/"
cp -R "$FRAMEWORK" "$APP_BUNDLE/Contents/Resources/"

SCRIPT=$(find "$ADAPTER_DIR" -name 'mediaremote-adapter.pl' -not -path '*/build/*' | head -1)
if [ -z "$SCRIPT" ]; then
    echo "ERROR: mediaremote-adapter.pl not found in $ADAPTER_DIR" >&2
    exit 1
fi
cp "$SCRIPT" "$APP_BUNDLE/Contents/Resources/mediaremote-adapter.pl"

codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Built $APP_BUNDLE"

if [ "${1:-}" = "run" ]; then
    open "$APP_BUNDLE"
elif [ "${1:-}" = "install" ]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "Installed /Applications/$APP_NAME.app"
else
    echo "Run with: open $APP_BUNDLE   (or: ./build.sh run)"
fi
