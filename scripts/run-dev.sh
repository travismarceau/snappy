#!/usr/bin/env bash
# Build the current source and run it, as a separate app from the installed one.
#
#   scripts/run-dev.sh            build and run the dev app
#   scripts/run-dev.sh --release  build with the Release configuration instead
#   scripts/run-dev.sh --status   report what is running, change nothing
#
# This never touches /Applications. The installed Snappy is whatever the last
# release put there and updates itself through Sparkle; this script is for the
# copy you are working on, and the two are deliberately different apps.
#
# In the Debug configuration the app is "Snappy Dev": bundle identifier
# com.simarholonipaa.snappy.dev, URL scheme snappy-dev, and no updater. So it
# has its own preferences, its own Accessibility grant, its own entry in the
# permissions list, and it cannot claim snappy:// URLs or replace itself with a
# release. Both can run at once; the menu bar shows two icons because there
# genuinely are two apps.
#
# An earlier version of this script installed over /Applications/Snappy.app.
# That made every development build masquerade as the release, which is how a
# five-month-old build ended up installed, and how a dev build with a different
# signature repeatedly invalidated the Accessibility grant.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Debug
STATUS_ONLY=
for a in "$@"; do
  case "$a" in
    --release) CONFIG=Release ;;
    --status)  STATUS_ONLY=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

describe() {
  local pl="$1/Contents/Info.plist"
  [[ -f "$pl" ]] || { printf '(not an app bundle)'; return; }
  printf 'v%s (%s)  %s' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$pl" 2>/dev/null)" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$pl" 2>/dev/null)" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$pl" 2>/dev/null)"
}

report() {
  echo "Installed release:"
  [[ -d /Applications/Snappy.app ]] \
    && echo "  $(describe /Applications/Snappy.app)  /Applications/Snappy.app" \
    || echo "  (none)"
  echo "Running:"
  local any=
  while read -r pid path; do
    [[ -n "${pid:-}" ]] || continue
    any=1
    echo "  pid $pid  $(describe "$path")  $path"
  done < <(ps -Ao pid=,command= | grep '/Snappy.app/Contents/MacOS/Snappy$' \
           | sed 's#\(.*/Snappy.app\)/Contents/MacOS/Snappy$#\1#' \
           | awk '{pid=$1; $1=""; sub(/^ /,""); print pid, $0}')
  [[ -n "$any" ]] || echo "  (nothing)"
}

if [[ -n "$STATUS_ONLY" ]]; then report; exit 0; fi

# Sign with Developer ID rather than ad-hoc. macOS keys the Accessibility grant
# to the code signature, and an ad-hoc signature changes every build, so the dev
# app would need re-authorising after each one.
SIGN_ARGS=(CODE_SIGN_ENTITLEMENTS="$PWD/Snappy/SnappyDirect.entitlements")
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  SIGN_ARGS+=(CODE_SIGN_STYLE=Manual
              CODE_SIGN_IDENTITY="Developer ID Application"
              DEVELOPMENT_TEAM="${TEAM_ID:-P78K4VHEL3}"
              PROVISIONING_PROFILE_SPECIFIER="")
else
  echo "No Developer ID certificate; expect to re-grant Accessibility after each build." >&2
fi

echo "Building ${CONFIG}…"
xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration "$CONFIG" \
  -destination 'platform=macOS' "${SIGN_ARGS[@]}" build >/dev/null

# Ask for the build settings with the same flags used to build. The project sets
# a custom SYMROOT, so `-target` alone answers ./build/<config> while a
# `-scheme` + `-destination` build writes to DerivedData.
BUILT=$(xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration "$CONFIG" \
  -destination 'platform=macOS' "${SIGN_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR = / {print $3; exit}')/Snappy.app
[[ -d "$BUILT" ]] || { echo "Build produced no app at $BUILT" >&2; exit 1; }

BUILT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")
if [[ "$BUILT_ID" == "com.simarholonipaa.snappy" ]]; then
  echo "Refusing to run: this build has the released app's identifier." >&2
  echo "A Release build shares the installed app's preferences, Accessibility" >&2
  echo "grant and URL scheme. Use the Debug configuration for development." >&2
  exit 1
fi

# Only quit the dev app. The installed release is left alone.
while read -r pid; do [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true; done \
  < <(pgrep -f "$BUILT/Contents/MacOS/Snappy" || true)
sleep 1

open -a "$BUILT"
sleep 2
echo
report
cat <<'NOTE'

This is a separate app from the installed Snappy. The first time you run it,
grant it Accessibility in its own right — it appears in the list under its own
name, alongside the release.
NOTE
