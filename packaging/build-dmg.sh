#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: packaging/build-dmg.sh /path/to/Lineform.app [output-dir]" >&2
  exit 64
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-dist}"
APP_NAME="Lineform"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKGROUND_IMAGE="${BACKGROUND_IMAGE:-$REPO_ROOT/packaging/assets/download-background.jpg}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 66
fi

if [[ ! -f "$BACKGROUND_IMAGE" ]]; then
  echo "error: DMG background not found: $BACKGROUND_IMAGE" >&2
  exit 66
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
VOLUME_NAME="$APP_NAME $VERSION"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lineform-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/$APP_NAME-$VERSION-rw.dmg"
FINAL_DMG="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
DEVICE=""

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR" "$OUTPUT_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov "$RW_DMG"

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/Apple_HFS/ {print $1; exit}')"
VOLUME_PATH="/Volumes/$VOLUME_NAME"

mkdir -p "$VOLUME_PATH/.background"
cp "$BACKGROUND_IMAGE" "$VOLUME_PATH/.background/download-background.jpg"

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 1020, 640}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set background picture of viewOptions to file ".background:download-background.jpg"
    set position of item "$APP_NAME.app" of container window to {270, 245}
    set position of item "Applications" of container window to {650, 245}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$FINAL_DMG"

echo "$FINAL_DMG"
