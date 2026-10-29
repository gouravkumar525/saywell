#!/bin/bash
# Builds Saywell.app with xcodebuild (SwiftPM alone can't compile MLX's Metal shaders).
# Usage: Scripts/make_app.sh [Release|Debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="build/DerivedData"
LOG="build/xcodebuild.log"
mkdir -p build

if ! xcodebuild -scheme LocalFlow -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -skipMacroValidation \
    build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -20
    echo "BUILD FAILED (full log: $LOG)"
    exit 1
fi

PRODUCTS="$DERIVED/Build/Products/$CONFIG"
APP="build/Saywell.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The Swift target is still called LocalFlow (the code name); the shipped app is Saywell.
cp "$PRODUCTS/LocalFlow" "$APP/Contents/MacOS/Saywell"
cp Resources/Icon/Saywell.icns "$APP/Contents/Resources/Saywell.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# "Improve My Model…" runs this script with the bench cases (G7).
cp Scripts/improve_model.sh "$APP/Contents/Resources/improve_model.sh"
cp Bench/cases.tsv "$APP/Contents/Resources/cases.tsv"
# Credits and licences for everything bundled or downloaded (Help ▸ Acknowledgements in the menu).
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# SwiftPM resource bundles (MLX's mlx-swift_Cmlx.bundle holds default.metallib).
shopt -s nullglob
for b in "$PRODUCTS"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done

# Dynamic frameworks from binary packages (Sparkle for updates, FluidAudio's text normalizer).
mkdir -p "$APP/Contents/Frameworks"
for f in "$PRODUCTS"/*.framework "$PRODUCTS"/PackageFrameworks/*.framework; do
    ditto "$f" "$APP/Contents/Frameworks/$(basename "$f")"
done

# C6: the Claude Code hook helper (a small separate executable).
mkdir -p "$APP/Contents/Helpers"
xcrun swiftc -O -o "$APP/Contents/Helpers/saywell-hook" Scripts/hook/saywell-hook.swift

# A stable identity keeps macOS permissions across rebuilds; ad-hoc resets them.
SIGN_ID="${SIGN_ID:-LocalFlow Dev}"
if ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    echo "warning: signing identity \"$SIGN_ID\" not found; signing ad-hoc (permissions will reset)"
    SIGN_ID="-"
fi
# Frameworks are signed first (inside-out), then the app.
for f in "$APP"/Contents/Frameworks/*.framework; do codesign --force --deep --sign "$SIGN_ID" "$f"; done
codesign --force --sign "$SIGN_ID" --identifier com.gourav.saywell.hook "$APP/Contents/Helpers/saywell-hook"
codesign --force --sign "$SIGN_ID" --identifier com.gourav.saywell "$APP"

echo "Built $APP ($CONFIG, signed: $SIGN_ID)"
