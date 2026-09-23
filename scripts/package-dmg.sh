#!/usr/bin/env bash
# Package an exported Snappy.app in a DMG with a branded mounted volume.
set -euo pipefail

APP=${1:?Usage: package-dmg.sh Snappy.app output.dmg}
DMG=${2:?Usage: package-dmg.sh Snappy.app output.dmg}
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")
APP_ICON="$APP/Contents/Resources/${ICON_NAME%.icns}.icns"

if [[ ! -f "$APP_ICON" ]]; then
  echo "Missing exported app icon: $APP_ICON" >&2
  exit 1
fi

mkdir -p "$(dirname "$DMG")"
WORK=$(mktemp -d "$(dirname "$DMG")/.snappy-dmg.XXXXXX")
STAGE="$WORK/stage"
MOUNT="$WORK/mount"
WRITABLE="$WORK/writable.dmg"
MOUNTED=0

cleanup() {
  if (( MOUNTED )); then
    if ! hdiutil detach "$MOUNT" >/dev/null 2>&1; then
      echo "Could not unmount $MOUNT; leaving $WORK for recovery." >&2
      return
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE" "$MOUNT"
ditto "$APP" "$STAGE/Snappy.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP_ICON" "$STAGE/.VolumeIcon.icns"

# The source folder's Finder flag does not become the volume root's flag.
# Set it on a writable mounted image, then compress that image for release.
hdiutil create -volname "Snappy" -srcfolder "$STAGE" -format UDRW -quiet "$WRITABLE"
hdiutil attach -nobrowse -noautoopen -mountpoint "$MOUNT" "$WRITABLE" >/dev/null
MOUNTED=1
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null
MOUNTED=0
hdiutil convert "$WRITABLE" -format UDZO -ov -quiet -o "$DMG"
