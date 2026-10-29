#!/bin/bash
# Builds a shareable Saywell package: dist/Saywell-<version>.dmg and .zip,
# each holding Saywell.app, Install.command, Uninstall.command, INSTALL.md and PRIVACY.md.
#
#   Scripts/package.sh                       # app only (models download on first use)
#   Scripts/package.sh --with-model qwen3             # also bundle Qwen3-4B (~2.3 GB) for offline installs
#   Scripts/package.sh --with-model parakeet          # also bundle the Parakeet recognizer (~460 MB)
#   Scripts/package.sh --with-model qwen3,parakeet    # both
#   Scripts/package.sh --no-build            # reuse build/Saywell.app
#
# Signing: uses $SIGN_ID (default "LocalFlow Dev", self-signed). For distribution
# without Gatekeeper warnings set SIGN_ID="Developer ID Application: …" and
# NOTARY_PROFILE=<notarytool keychain profile>; the app is then signed with the
# hardened runtime and notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1; MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --with-model) MODEL="$2"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done

[ "$BUILD" = 1 ] && ./Scripts/make_app.sh Release
APP="build/Saywell.app"
[ -d "$APP" ] || { echo "missing $APP; run without --no-build"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Saywell-$VERSION"
[ -n "$MODEL" ] && NAME="$NAME-with-${MODEL//,/-}"
STAGE="dist/$NAME"
rm -rf "$STAGE" "dist/$NAME.dmg" "dist/$NAME.zip"
mkdir -p "$STAGE"

ditto "$APP" "$STAGE/Saywell.app"

# B13: Sparkle updates are switched on only when both are given (see Scripts/release.sh).
if [ -n "${SPARKLE_FEED_URL:-}" ] && [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
  PL="$STAGE/Saywell.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$PL"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$PL"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PL"
  [ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PL"
  echo "Sparkle updates on: $SPARKLE_FEED_URL"
fi

SIGN_ID="${SIGN_ID:-LocalFlow Dev}"
if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
  # Hardened runtime, inside-out: Sparkle's helpers, the frameworks, then the app.
  for f in "$STAGE"/Saywell.app/Contents/Frameworks/*.framework; do
    find "$f" \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) -prune -print0 2>/dev/null |
      xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_ID" {}
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$f"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier com.gourav.saywell.hook \
    "$STAGE/Saywell.app/Contents/Helpers/saywell-hook"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Saywell.entitlements \
    --sign "$SIGN_ID" --identifier com.gourav.saywell "$STAGE/Saywell.app"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$STAGE/Saywell.app" "dist/notarize.zip"
    xcrun notarytool submit "dist/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE/Saywell.app"
    rm -f "dist/notarize.zip"
  fi
fi
if [[ "$SIGN_ID" != "Developer ID Application"* ]] && [ -n "${SPARKLE_FEED_URL:-}" ]; then
  # Info.plist changed above; re-seal with the same identity.
  codesign --force --sign "$SIGN_ID" --identifier com.gourav.saywell "$STAGE/Saywell.app"
fi
codesign --verify --deep --strict "$STAGE/Saywell.app"

cp Scripts/dist/Install.command Scripts/dist/Uninstall.command "$STAGE/"
chmod +x "$STAGE/Install.command" "$STAGE/Uninstall.command"
cp INSTALL.md PRIVACY.md THIRD_PARTY_NOTICES.md "$STAGE/"

for M in ${MODEL//,/ }; do
  case "$M" in
    qwen3) REPO="mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    parakeet) REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml" ;;
    *) echo "unknown model $M (qwen3|parakeet)"; exit 2 ;;
  esac
  # B3: the pinned revision only, verified against the same manifest the app uses.
  INSTALLED="$HOME/Library/Application Support/Saywell/models/${REPO//\//--}"
  REV=$(grep "repo: \"$REPO\"" Sources/LocalFlowCore/ModelManifests.swift | grep -o 'revision: "[0-9a-f]*"' | cut -d'"' -f2)
  SNAP="$HOME/.cache/huggingface/hub/models--${REPO//\//--}/snapshots/$REV"
  if [ -f "$INSTALLED/config.json" ]; then SRC="$INSTALLED"; elif [ -f "$SNAP/config.json" ]; then SRC="$SNAP"; else
    echo "model $REPO@$REV isn't on this Mac; select it in Saywell once to download it"; exit 1; fi
  "$APP/Contents/MacOS/Saywell" --verify-model "$REPO" "$SRC"
  DEST="$STAGE/models/${REPO//\//--}"
  # Only the manifest's files (nested for Core ML bundles), dereferencing the cache's
  # symlinks; no marker (the app writes it after a test run on the new Mac).
  for f in $(grep -A60 "repo: \"$REPO\"" Sources/LocalFlowCore/ModelManifests.swift | sed '/^        \]),/q' | grep -o 'name: "[^"]*"' | cut -d'"' -f2); do
    mkdir -p "$(dirname "$DEST/$f")"
    cp -L "$SRC/$f" "$DEST/$f"
  done
done

DMGBUILD="build/dmgvenv/bin/dmgbuild"
if [ -z "$MODEL" ] && [ -x "$DMGBUILD" ]; then
  # A standard installer window: Saywell + Applications on a designed background,
  # drag to install. (Bundled-model packages keep the folder with Install.command,
  # which copies the models into place.)
  "$APP/Contents/MacOS/Saywell" --dmg-background build/dmg-background
  tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png -out build/dmg-background.tiff 2>/dev/null
  rm -f "dist/$NAME.dmg"
  "$DMGBUILD" -s Scripts/dist/dmg_settings.py -D app="$STAGE/Saywell.app" -D icon=Resources/Icon/Saywell.icns \
    -D background=build/dmg-background.tiff "Saywell" "dist/$NAME.dmg" > build/dmgbuild.log
  # The .dmg file itself shows Saywell's icon in Finder (kept by AirDrop and zip, lost by some uploads).
  swift -e 'import AppKit; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: CommandLine.arguments[1]), forFile: CommandLine.arguments[2], options: [])' \
    Resources/Icon/Saywell.icns "dist/$NAME.dmg" 2>/dev/null || true
else
  # dmgbuild lives in build/dmgvenv: python3 -m venv build/dmgvenv && build/dmgvenv/bin/pip install dmgbuild
  hdiutil create -quiet -volname "Saywell" -srcfolder "$STAGE" -format UDZO -ov "dist/$NAME.dmg"
fi
ditto -c -k --keepParent "$STAGE" "dist/$NAME.zip"
shasum -a 256 "dist/$NAME.dmg" "dist/$NAME.zip" | tee "dist/$NAME.sha256"
du -sh "dist/$NAME.dmg" "dist/$NAME.zip"
echo "Package ready: dist/$NAME.dmg (or .zip). Share it with INSTALL.md's requirements."
