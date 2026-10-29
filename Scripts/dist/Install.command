#!/bin/bash
# Installs Saywell from this folder (double-click, or run: bash Install.command).
set -euo pipefail
cd "$(dirname "$0")"
echo "== Saywell installer"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Saywell needs an Apple Silicon Mac (M1 or newer). This Mac is $(uname -m)."
  exit 1
fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 14 ]; then
  echo "Saywell needs macOS 14 (Sonoma) or newer. This Mac runs $(sw_vers -productVersion)."
  exit 1
fi

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Saywell 2>/dev/null || true
# Saywell was called LocalFlow before; replace the old app and keep its data.
pkill -x LocalFlow 2>/dev/null || true
for d in /Applications "$HOME/Applications"; do rm -rf "$d/LocalFlow.app"; done
SUPPORT="$HOME/Library/Application Support"
if [ -d "$SUPPORT/LocalFlow" ] && [ ! -d "$SUPPORT/Saywell" ]; then
  mv "$SUPPORT/LocalFlow" "$SUPPORT/Saywell"
  [ -f "$SUPPORT/Saywell/localflow.sqlite" ] && mv "$SUPPORT/Saywell/localflow.sqlite" "$SUPPORT/Saywell/saywell.sqlite"
  echo "Moved your LocalFlow data to Saywell"
fi
rm -rf "$DEST/Saywell.app"
ditto Saywell.app "$DEST/Saywell.app"
# Downloaded files are quarantined; the app isn't notarized (self-signed).
xattr -dr com.apple.quarantine "$DEST/Saywell.app" 2>/dev/null || true
echo "Installed $DEST/Saywell.app"

if [ -d models ]; then
  MODELS="$HOME/Library/Application Support/Saywell/models"
  mkdir -p "$MODELS"
  for m in models/*/; do
    name=$(basename "$m")
    echo "Copying model $name (a few GB)…"
    rm -rf "$MODELS/$name"
    ditto "$m" "$MODELS/$name"
  done
  echo "Models installed in $MODELS (no download needed)"
fi

RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [ "$RAM_GB" -lt 16 ]; then
  echo "Note: this Mac has ${RAM_GB} GB RAM. Use Apple's model or rules-only cleanup; local 4B models want 16 GB."
fi

open "$DEST/Saywell.app"
echo "Done. Saywell is in the menu bar (mic icon). Follow the 'Set Up Saywell' window to grant permissions."
