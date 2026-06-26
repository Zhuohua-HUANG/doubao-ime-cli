#!/usr/bin/env bash
set -euo pipefail

# Build a drag-to-Applications DMG.
#
# Unlike the pkg installer, this artifact is self-contained:
#   DoubaoVoiceCLI.app/Contents/Resources/fsmn-runtime
#   DoubaoVoiceCLI.app/Contents/Resources/fsmn_vad_worker.py
#   DoubaoVoiceCLI.app/Contents/Resources/doubao-voice
#
# Users install it by opening the DMG and dragging DoubaoVoiceCLI.app to
# Applications.  No Installer.app step is required.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
LANGUAGE="${LANGUAGE:-zh-Hans}"
BINARY="${BINARY:-doubao-voice}"
APP_BUNDLE_NAME="DoubaoVoiceCLI.app"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
RUNTIME_DIR="$BUILD_DIR/fsmn-runtime"
DMG_ROOT="$BUILD_DIR/dmg-root"
DMG_PATH="$DIST_DIR/doubao-ime-cli-$VERSION.dmg"
VOLUME_NAME="Doubao Voice CLI"

cd "$ROOT_DIR"

make build BINARY="$BINARY" VERSION="$VERSION" LANGUAGE="$LANGUAGE"
"$ROOT_DIR/scripts/build-fsmn-runtime.sh" "$RUNTIME_DIR"
# Calculate dynamic space needed in MB plus 50MB overhead
APP_SIZE=$(du -sm "$BUILD_DIR/$APP_BUNDLE_NAME" | cut -f1)
RUNTIME_SIZE=$(du -sm "$RUNTIME_DIR" | cut -f1)
TOTAL_SIZE=$((APP_SIZE + RUNTIME_SIZE + 50))

TEMP_DMG_PATH="$BUILD_DIR/temp-doubao-voice.dmg"
rm -f "$TEMP_DMG_PATH"

echo "Creating temporary read-write DMG of size ${TOTAL_SIZE}MB..."
hdiutil create -size "${TOTAL_SIZE}m" -fs HFS+ -volname "$VOLUME_NAME" -o "$TEMP_DMG_PATH"

echo "Mounting temporary DMG..."
MOUNT_RESULT=$(hdiutil attach -noverify -noautoopen "$TEMP_DMG_PATH")
MOUNT_DIR=$(echo "$MOUNT_RESULT" | grep -o '/Volumes/.*' | head -n 1)
if [ -z "$MOUNT_DIR" ]; then
  echo "Error: Failed to mount temporary DMG"
  exit 1
fi

echo "Copying files to mounted DMG volume at $MOUNT_DIR..."
/usr/bin/ditto --norsrc --noextattr "$BUILD_DIR/$APP_BUNDLE_NAME" "$MOUNT_DIR/$APP_BUNDLE_NAME"
mkdir -p "$MOUNT_DIR/$APP_BUNDLE_NAME/Contents/Resources"
install -m 0755 "$BUILD_DIR/$BINARY" "$MOUNT_DIR/$APP_BUNDLE_NAME/Contents/Resources/doubao-voice"
/usr/bin/ditto --norsrc --noextattr "$RUNTIME_DIR" "$MOUNT_DIR/$APP_BUNDLE_NAME/Contents/Resources/fsmn-runtime"
ln -s /Applications "$MOUNT_DIR/Applications"

echo "Styling DMG window layout via AppleScript..."
osascript -e "
  tell application \"Finder\"
    tell disk \"$VOLUME_NAME\"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {400, 100, 800, 300}
      set theViewOptions to the icon view options of container window
      set icon size of theViewOptions to 96
      set arrangement of theViewOptions to not arranged
      set position of item \"$APP_BUNDLE_NAME\" of container window to {110, 100}
      set position of item \"Applications\" of container window to {290, 100}
      update without registering applications
      delay 2
      close
    end tell
  end tell
" || true

echo "Unmounting temporary DMG..."
sleep 1
hdiutil detach "$MOUNT_DIR" || hdiutil detach "$MOUNT_DIR" -force

echo "Converting temporary DMG to compressed production format..."
rm -f "$DMG_PATH"
hdiutil convert "$TEMP_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

echo "Cleaning up temporary files..."
rm -f "$TEMP_DMG_PATH"

echo
echo "Built drag-to-Applications DMG:"
echo "  $DMG_PATH"
