#!/bin/bash
# Runs the unit tests through Xcode's toolchain (the package depends on MLX).
# Prints every failing assertion, then the totals.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
xcodebuild test -scheme LocalFlow -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation > build/test.log 2>&1
status=$?
grep -E "error:" build/test.log | sort -u
grep -E "Executed [0-9]+ tests" build/test.log | tail -1
grep -E "TEST (SUCCEEDED|FAILED)" build/test.log | tail -1
exit $status
