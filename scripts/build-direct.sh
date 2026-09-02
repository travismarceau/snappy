#!/usr/bin/env bash
# Build a notarized, Developer-ID–signed Snappy.app for direct download.
#
# Prerequisites (one time):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + Developer ID Application),
#      or run this once from Xcode's Organizer ▸ Distribute App ▸ Developer ID.
#   2. Notary credentials in the keychain:
#        xcrun notarytool store-credentials snappy-notary \
#          --apple-id "you@example.com" --team-id P78K4VHEL3 \
#          --password "abcd-efgh-ijkl-mnop"   # an app-specific password
#
# This reuses the Release config (App Sandbox + hardened runtime) but signs with
# Developer ID instead of Apple Development. If on-device testing shows the
# sandbox blocks a feature, switch CODE_SIGN_ENTITLEMENTS to
# Rectangle/RectangleDirect.entitlements (no sandbox) via a dedicated build
# configuration — see docs/APP_STORE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE=build/Snappy-direct.xcarchive
EXPORT=build/export-direct
ZIP=build/Snappy.zip
NOTARY_PROFILE="${NOTARY_PROFILE:-snappy-notary}"

rm -rf "$ARCHIVE" "$EXPORT" "$ZIP"

xcodebuild -project Rectangle.xcodeproj -scheme Rectangle -configuration Release \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions-Direct.plist \
  -exportPath "$EXPORT"

APP="$EXPORT/Snappy.app"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to the notary service…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vvv --type exec "$APP" || true

echo
echo "Done: $APP"
echo "      $ZIP  (notarized + stapled — distribute this)"
