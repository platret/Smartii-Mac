#!/usr/bin/env bash
# Build a polished, drag-to-Applications Smartii.dmg with a custom gradient
# background, like premium Mac apps.
#
# Assumes build/Smartii.app exists. If it does not, this script runs
# Scripts/make-app.sh first to assemble + ad-hoc-sign it.
#
# Output: build/Smartii.dmg (compressed, read-only). Echoes that path.
#
# Usage (from repo root): bash Scripts/make-dmg.sh
set -euo pipefail

# Always operate from the repository root (the directory above Scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VOL_NAME="Smartii"
APP="build/Smartii.app"
STAGING="build/dmg-staging"
RW_DMG="build/Smartii-rw.dmg"
FINAL_DMG="build/Smartii.dmg"
# Mount at the default /Volumes location so Finder can address the volume by
# name ("disk \"Smartii\"") in AppleScript. A custom -mountpoint combined with
# -nobrowse hides the volume from Finder and breaks the `tell disk` lookup.
MOUNT_DIR="/Volumes/$VOL_NAME"
BG_SRC="Resources/dmg-background.png"
BG_SRC_2X="Resources/dmg-background@2x.png"

# --- Ensure the app bundle exists ------------------------------------------
if [[ ! -d "$APP" ]]; then
	echo "build/Smartii.app not found — building it first via make-app.sh" >&2
	bash Scripts/make-app.sh release
fi
if [[ ! -d "$APP" ]]; then
	echo "error: $APP still missing after make-app.sh" >&2
	exit 1
fi
if [[ ! -f "$BG_SRC" ]]; then
	echo "error: background image $BG_SRC not found (run Scripts/gen-dmg-background.py)" >&2
	exit 1
fi

# --- Robust detach helper ---------------------------------------------------
# hdiutil detach occasionally fails with "resource busy" right after Finder
# touches the volume; retry, then force-detach as a last resort.
detach_volume() {
	local target="$1"
	[[ -z "$target" ]] && return 0
	local i
	for i in 1 2 3 4 5; do
		if hdiutil detach "$target" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	hdiutil detach "$target" -force >/dev/null 2>&1 || true
}

# --- Clean any leftovers from a previous run --------------------------------
cleanup() {
	# Detach by device node if it is still attached.
	if [[ -n "${DEV_NODE:-}" ]]; then
		detach_volume "$DEV_NODE"
	fi
	if [[ -d "$MOUNT_DIR" ]] && mount | grep -q " on $MOUNT_DIR "; then
		detach_volume "$MOUNT_DIR"
	fi
	rm -rf "$STAGING"
}
trap cleanup EXIT

rm -f "$RW_DMG" "$FINAL_DMG"
rm -rf "$STAGING"
# Detach a stale volume of the same name from a previous aborted run.
if [[ -d "$MOUNT_DIR" ]] && mount | grep -q " on $MOUNT_DIR "; then
	detach_volume "$MOUNT_DIR"
fi

# --- Stage the contents -----------------------------------------------------
mkdir -p "$STAGING"
# Copy the app (preserve symlinks/permissions/signature).
ditto "$APP" "$STAGING/Smartii.app"
# Drag-to-install target.
ln -s /Applications "$STAGING/Applications"

# --- Create a read-write DMG from the staging dir ---------------------------
hdiutil create \
	-srcfolder "$STAGING" \
	-volname "$VOL_NAME" \
	-fs HFS+ \
	-fsargs "-c c=64,a=16,e=16" \
	-format UDRW \
	-ov \
	"$RW_DMG"

# --- Mount it (capture the device node so we can detach reliably) -----------
# Mount at the default /Volumes/Smartii location and let Finder browse it, so
# the AppleScript `tell disk "Smartii"` can find it.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" \
	-noautoopen)"
DEV_NODE="$(echo "$ATTACH_OUT" | grep -Eo '^/dev/disk[0-9]+' | head -1)"
echo "mounted $RW_DMG at $MOUNT_DIR (device ${DEV_NODE:-unknown})"

# Give the volume a moment to settle.
sleep 1

# --- Install the background images into the hidden .background folder --------
mkdir -p "$MOUNT_DIR/.background"
cp "$BG_SRC" "$MOUNT_DIR/.background/dmg-background.png"
if [[ -f "$BG_SRC_2X" ]]; then
	cp "$BG_SRC_2X" "$MOUNT_DIR/.background/dmg-background@2x.png"
fi

# --- Arrange the window with Finder via AppleScript -------------------------
# Window bounds {left, top, right, bottom} -> 660x420 content area.
# Icon row Y = 248 matches the arrow drawn in dmg-background.png.
osascript <<'APPLESCRIPT'
tell application "Finder"
	tell disk "Smartii"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 150, 860, 570}
		set theViewOptions to the icon view options of container window
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 120
		set text size of theViewOptions to 12
		set background picture of theViewOptions to file ".background:dmg-background.png"
		set position of item "Smartii.app" of container window to {165, 248}
		set position of item "Applications" of container window to {495, 248}
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT

# Let Finder flush the .DS_Store before we unmount.
sync
sleep 2

# --- Unmount ----------------------------------------------------------------
# hdiutil removes the /Volumes/Smartii mount point itself on detach.
detach_volume "${DEV_NODE:-$MOUNT_DIR}"
DEV_NODE=""

# --- Convert to compressed, read-only ---------------------------------------
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$FINAL_DMG"

# --- Clean up the read-write image ------------------------------------------
rm -f "$RW_DMG"
rm -rf "$STAGING"

echo "$ROOT_DIR/$FINAL_DMG"
