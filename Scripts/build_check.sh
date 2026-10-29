#!/bin/bash
# Compiles the app (Debug, no bundle, no signing) and prints only errors. Fast check between steps.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
if xcodebuild -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation \
    build > build/xcodebuild-check.log 2>&1; then
    echo "BUILD OK"
else
    grep -E "error:" build/xcodebuild-check.log | sort -u | head -20
    echo "BUILD FAILED (build/xcodebuild-check.log)"
    exit 1
fi
