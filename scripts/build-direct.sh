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
# This reuses the Release config (hardened runtime, Developer ID signing) but
# overrides its entitlements: the App Sandbox blocks the Accessibility API, so a
# sandboxed build cannot move windows at all. See "Sandbox verification" in
# docs/APP_STORE.md for the evidence. The override must be an ABSOLUTE path --
# xcodebuild applies command-line settings to every target, including the
# MASShortcut package, which resolves a relative path against its own checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

# Fail on the missing prerequisite rather than 200 lines into an archive log.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No \"Developer ID Application\" certificate in the keychain." >&2
  echo "Create one in Xcode > Settings > Accounts > Manage Certificates > + ," >&2
  echo "or via Organizer > Distribute App > Developer ID once." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-snappy-notary}" >/dev/null 2>&1; then
  echo "No notary credentials stored under profile \"${NOTARY_PROFILE:-snappy-notary}\"." >&2
  echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE:-snappy-notary} \\" >&2
  echo "    --apple-id <your-apple-id> --team-id ${TEAM_ID:-P78K4VHEL3} --password <app-specific-password>" >&2
  exit 1
fi

ARCHIVE=build/Snappy-direct.xcarchive
EXPORT=build/export-direct
ZIP=build/Snappy.zip
NOTARY_PROFILE="${NOTARY_PROFILE:-snappy-notary}"
TEAM_ID="${TEAM_ID:-P78K4VHEL3}"

rm -rf "$ARCHIVE" "$EXPORT" "$ZIP"

xcodebuild -project Rectangle.xcodeproj -scheme Rectangle -configuration Release \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_ENTITLEMENTS="$PWD/Rectangle/RectangleDirect.entitlements" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
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
