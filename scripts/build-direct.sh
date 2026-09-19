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

# An empty SUPublicEDKey ships an app that will reject every update it is ever
# offered, including the one that would fix it. Catch it here, not in the wild.
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Snappy/Info.plist 2>/dev/null | grep -q .; then
  echo "SUPublicEDKey is empty in Snappy/Info.plist." >&2
  echo "Run scripts/sparkle-keys.sh and paste the public key in before releasing." >&2
  exit 1
fi

# The appcast has to name the exact URL the zip will be published at, and
# Sparkle verifies the signature of whatever it finds there. Releases go to
# GitHub, so the URL is derived from the version rather than hand-maintained.
# -configuration Release is explicit on purpose. Without it xcodebuild answers
# for the project's default configuration, so a Debug/Release version mismatch
# reads as whichever one happens to be default -- which is how 1.100/106 sat in
# Debug while Release quietly still said 1.0/1.
SETTINGS=$(xcodebuild -project Snappy.xcodeproj -target Snappy -configuration Release \
  -showBuildSettings 2>/dev/null)
VERSION=$(awk '/ MARKETING_VERSION = / {print $3; exit}' <<<"$SETTINGS")
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from the project." >&2
  exit 1
fi
# CFBundleVersion, not the marketing string, is what Sparkle compares: the
# sparkle:version generate_appcast writes comes from here.
BUILD=$(awk '/ CURRENT_PROJECT_VERSION = / {print $3; exit}' <<<"$SETTINGS")
if [[ -z "$BUILD" ]]; then
  echo "Could not read CURRENT_PROJECT_VERSION from the project." >&2
  exit 1
fi
TAG="v${VERSION}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/travismarceau/snappy/releases/download/${TAG}/}"

# A release overwrites nothing. An existing tag means either the version was
# never bumped, or this is a re-cut of something already published -- and since
# the appcast names ${DOWNLOAD_URL_PREFIX}Snappy.zip, replacing that asset swaps
# the download out from under the signature the published feed told users to
# expect.
#
# The remote is what matters, and checking only the local repo misses the case
# this guard exists for: `gh release create` makes the tag server-side, so after
# a release the tag is on origin and NOT here until someone fetches. A local-only
# check sails straight through the second run. The local check is kept as a cheap
# offline pre-filter -- and because this repo carries ~100 inherited tags from
# Rectangle that were never pushed.
if [[ -z "${ALLOW_EXISTING_TAG:-}" ]]; then
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists on origin — that release is likely published." >&2
    echo "Re-uploading its asset would invalidate the signature the live appcast" >&2
    echo "advertises. Bump MARKETING_VERSION in the Snappy target, or re-run with" >&2
    echo "ALLOW_EXISTING_TAG=1 to deliberately re-cut it." >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists locally: $(git log -1 --format='%h %ad' --date=short "$TAG")." >&2
    echo "Bump MARKETING_VERSION in the Snappy target, or re-run with" >&2
    echo "ALLOW_EXISTING_TAG=1 if you are deliberately re-cutting that release." >&2
    exit 1
  fi
fi

# Sparkle offers an update only when the feed's sparkle:version exceeds what is
# installed. Publishing a feed whose newest entry is <= the last one produces an
# updater that never fires, and it fails silently: a feed offering nothing looks
# exactly like being up to date.
if [[ -f site/appcast.xml ]]; then
  PUBLISHED=$( { sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' site/appcast.xml
                 sed -n 's/.*sparkle:version="\([0-9][0-9]*\)".*/\1/p' site/appcast.xml
               } | sort -n | tail -1 )
  if [[ -n "$PUBLISHED" ]] && (( BUILD <= PUBLISHED )); then
    echo "CURRENT_PROJECT_VERSION is $BUILD, but site/appcast.xml already" >&2
    echo "advertises $PUBLISHED. Sparkle compares CFBundleVersion, so this build" >&2
    echo "would never be offered to anyone running the published one." >&2
    echo "Bump CURRENT_PROJECT_VERSION in the Snappy target." >&2
    exit 1
  fi
fi

# Release notes, checked here rather than after the archive: finding out that
# they are missing should cost a second, not a build and a notarization round
# trip. generate_appcast embeds the HTML as the <description> Sparkle renders in
# its update dialog, which is the only place most users will ever read it; the
# markdown is what the GitHub release body quotes.
#
# Hard failure on purpose. Releases change the bundle identifier from time to
# time, and macOS drops the Accessibility grant when they do -- an update that
# ships without saying so leaves every user with an app that launches and then
# silently refuses to move a window.
NOTES_HTML="site/releases/${TAG}.html"
NOTES_MD="site/releases/${TAG}.md"

# The two files say the same thing to different readers -- Sparkle's dialog
# renders the HTML, the GitHub release body quotes the markdown -- and nothing
# makes them agree. That is the shape of the bug that let store/site.html drift
# away from the deployed site until the copy here had no download button at all.
#
# These checks compare the files against each other rather than demanding any
# particular wording: a release that changes nothing about permissions should
# not be forced to mention them. What is not allowed is one file carrying a
# warning the other drops.
notes_prose() {
  # HTML minus its style block and tags, or markdown minus its syntax, reduced
  # to comparable words.
  sed -e '/<style>/,/<\/style>/d' -e 's/<[^>]*>//g' -e 's/[#*`_>-]//g' "$1" \
    | tr -s '[:space:]' '\n' | grep -c . || true
}

for f in "$NOTES_HTML" "$NOTES_MD"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing release notes: $f" >&2
    echo "Write them before releasing. If this version changes the bundle" >&2
    echo "identifier or the signing identity, they MUST tell users to re-grant" >&2
    echo "Accessibility in System Settings -- TCC keys the grant to the bundle" >&2
    echo "id plus code signature and there is no API to transfer it, so users" >&2
    echo "who skip it see Snappy do nothing at all, with no error." >&2
    exit 1
  fi
  if ! grep -q "$VERSION" "$f"; then
    echo "Release notes $f never mention version $VERSION." >&2
    exit 1
  fi
done

# A warning in one file and not the other means someone edited one and forgot
# the other. Accessibility is called out by name because it is the one whose
# absence is silent: users who miss it get an app that launches and does nothing.
for topic in -i.accessibility -i.re-grant; do
  pattern=${topic#-i.}
  if grep -qi "$pattern" "$NOTES_MD" && ! grep -qi "$pattern" "$NOTES_HTML"; then
    echo "\"$pattern\" appears in $NOTES_MD but not $NOTES_HTML." >&2
    echo "Sparkle renders the HTML — that warning would not reach anyone updating." >&2
    exit 1
  fi
  if grep -qi "$pattern" "$NOTES_HTML" && ! grep -qi "$pattern" "$NOTES_MD"; then
    echo "\"$pattern\" appears in $NOTES_HTML but not $NOTES_MD." >&2
    echo "The GitHub release body quotes the markdown — it would omit that warning." >&2
    exit 1
  fi
done

# Catch wholesale divergence: one file rewritten, the other left behind.
MD_WORDS=$(notes_prose "$NOTES_MD")
HTML_WORDS=$(notes_prose "$NOTES_HTML")
if (( MD_WORDS == 0 || HTML_WORDS == 0 )); then
  echo "Release notes are empty after stripping markup (md=$MD_WORDS html=$HTML_WORDS)." >&2
  exit 1
fi
if (( MD_WORDS * 100 / HTML_WORDS < 60 || HTML_WORDS * 100 / MD_WORDS < 60 )); then
  echo "Release notes differ a lot in length: $NOTES_MD $MD_WORDS words," >&2
  echo "$NOTES_HTML $HTML_WORDS. One was probably edited without the other." >&2
  exit 1
fi

ARCHIVE=build/Snappy-direct.xcarchive
EXPORT=build/export-direct
ZIP=build/Snappy.zip
NOTARY_PROFILE="${NOTARY_PROFILE:-snappy-notary}"
TEAM_ID="${TEAM_ID:-P78K4VHEL3}"

rm -rf "$ARCHIVE" "$EXPORT" "$ZIP"

xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration Release \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_ENTITLEMENTS="$PWD/Snappy/SnappyDirect.entitlements" \
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

# Sparkle: sign the build and fold it into the appcast users actually poll.
#
# generate_appcast reads every archive in the directory, signs each with the
# private EdDSA key from the keychain, and rewrites appcast.xml. It needs the
# release notes and download URL to match what the website serves, so the
# appcast lives beside the zip and both are uploaded together.
APPCAST_DIR=build/appcast
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
  -type f 2>/dev/null | head -1)

if [[ -z "$GENERATE_APPCAST" ]]; then
  echo
  echo "Sparkle's generate_appcast wasn't found in DerivedData; skipping the appcast." >&2
  echo "The app is still built and notarized — but no existing user will be offered it." >&2
else
  mkdir -p "$APPCAST_DIR"
  cp "$ZIP" "$APPCAST_DIR/"

  # Release notes, embedded as the <description> Sparkle renders in its update
  # dialog -- the only place most users will ever read them.
  #
  # --embed-release-notes is required, not optional. generate_appcast embeds a
  # notes file automatically ONLY when it is a bare fragment; ours is a full
  # document with <!doctype> and <style>, so without the flag it writes a
  # sparkle:releaseNotesLink instead, pointing at a Snappy.html that is never
  # published. Worse than a 404: the site serves index.html for unknown paths,
  # so users would get the entire homepage rendered inside the update dialog.
  #
  # This is a hard failure, not a warning. Releases change the bundle
  # identifier from time to time, and macOS drops the Accessibility grant when
  # they do -- an update that ships without saying so leaves every user with an
  # app that launches and then silently refuses to move a window.
  cp "$NOTES_HTML" "$APPCAST_DIR/$(basename "$ZIP" .zip).html"

  "$GENERATE_APPCAST" --embed-release-notes \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_DIR"
  # The feed has to be served from SUFeedURL, which is getsnappy.fyi/appcast.xml,
  # and site/ is what that host deploys — so the generated feed belongs in the
  # repo, committed alongside the release it describes.
  cp "$APPCAST_DIR/appcast.xml" site/appcast.xml
  echo
  echo "Appcast written to site/appcast.xml — commit it with the release."
  echo
  echo "Now publish the zip at the URL the appcast names:"
  echo "  ${DOWNLOAD_URL_PREFIX}Snappy.zip"
  echo
  echo "    gh release create $TAG \"$ZIP\" --title \"Snappy $VERSION\" --notes-file $NOTES_MD"
  echo "    # re-cutting an already-published tag (ALLOW_EXISTING_TAG=1 to get here):"
  echo "    gh release upload $TAG \"$ZIP\" --clobber"
  echo
  echo "Then commit site/appcast.xml and $NOTES_HTML and push, so getsnappy.fyi"
  echo "serves the feed and the notes."
  echo
  echo "Finally, once it is deployed and the release is published:"
  echo "    scripts/verify-release.sh"
  echo "A 200 from the feed URL proves nothing — the site answers every unknown"
  echo "path with the homepage."
  echo "Sparkle verifies the signature of whatever it finds at that URL, so the"
  echo "zip published there must be this exact file."
fi

echo
echo "Done: $APP"
echo "      $ZIP  (notarized + stapled — distribute this)"
