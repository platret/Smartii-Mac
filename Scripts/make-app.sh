#!/usr/bin/env bash
# Build the Smartii executable with SwiftPM and assemble a macOS .app bundle.
# Usage (from repo root): bash Scripts/make-app.sh [release|debug]
set -euo pipefail

# Always operate from the repository root (the directory above Scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-release}"

# Compile the executable target.
swift build -c "$CONFIG"

# Locate the built binary.
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Smartii"
if [[ ! -f "$BIN" ]]; then
	echo "error: built binary not found at $BIN" >&2
	exit 1
fi

# Assemble the .app bundle layout.
APP="build/Smartii.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy the executable and make sure it is runnable.
cp "$BIN" "$APP/Contents/MacOS/Smartii"
chmod +x "$APP/Contents/MacOS/Smartii"

# Copy the Info.plist.
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy the app icon if one is present.
if [[ -f "Resources/AppIcon.icns" ]]; then
	cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc code-sign the WHOLE bundle. Without this the bundle is only
# "linker-signed" (Info.plist not bound, resources not sealed) and Gatekeeper
# reports the app as "damaged" — which xattr cannot fix. An ad-hoc signature
# (identity "-") seals the bundle so it validates; users still clear quarantine
# (right-click → Open, or `xattr -dr com.apple.quarantine`) since it's unsigned
# by a Developer ID.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Emit the absolute path to the assembled bundle.
echo "$ROOT_DIR/$APP"
