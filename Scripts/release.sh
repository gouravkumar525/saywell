#!/bin/bash
# B13: builds a release with Sparkle updates and writes the appcast.
#
# One-time setup (Sparkle's tools come with the package):
#   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#     → stores the EdDSA private key in your login Keychain and prints the public key.
#   Pick where the appcast and zips will live (e.g. a GitHub Releases page or any HTTPS folder).
#
# Each release:
#   SPARKLE_PUBLIC_KEY=<public key> \
#   SPARKLE_FEED_URL=https://example.com/saywell/appcast.xml \
#   DOWNLOAD_URL_PREFIX=https://example.com/saywell/ \
#   BUILD_NUMBER=2 SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<profile> \
#   Scripts/release.sh
# then upload dist/updates/* (appcast.xml + the zip) to DOWNLOAD_URL_PREFIX.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SPARKLE_PUBLIC_KEY:?set SPARKLE_PUBLIC_KEY (from generate_keys)}"
: "${SPARKLE_FEED_URL:?set SPARKLE_FEED_URL (where appcast.xml will be served)}"
: "${DOWNLOAD_URL_PREFIX:?set DOWNLOAD_URL_PREFIX (where the zips will be served)}"
: "${BUILD_NUMBER:?set BUILD_NUMBER (must increase every release)}"
export SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL BUILD_NUMBER

Scripts/package.sh "$@"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
mkdir -p dist/updates
# Sparkle updates from a zip of the app itself.
ditto -c -k --keepParent "dist/Saywell-$VERSION/Saywell.app" "dist/updates/Saywell-$VERSION-$BUILD_NUMBER.zip"
"$BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" dist/updates
echo "Upload dist/updates/ to $DOWNLOAD_URL_PREFIX (appcast: $SPARKLE_FEED_URL)"
