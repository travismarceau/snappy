#!/usr/bin/env bash
# Build the current source and run THAT, replacing whatever is in /Applications.
#
# Why this exists: the 1.1 rename changed the bundle identifier, so a new build
# no longer replaces an installed older one -- both sit in the menu bar with
# identical icons, and Spotlight keeps opening whichever is in /Applications.
# Every "why don't I see my change" ends up being an old copy.
#
#   scripts/run-latest.sh            build Release, install, run
#   scripts/run-latest.sh --debug    same with the Debug configuration
#   scripts/run-latest.sh --status   report what is running, change nothing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Release
STATUS_ONLY=
for a in "$@"; do
  case "$a" in
    --debug)  CONFIG=Debug ;;
    --status) STATUS_ONLY=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

describe() { # path -> "v1.1 (2)  com.x.y  Sparkle"
  local app=$1 pl="$1/Contents/Info.plist"
  [[ -f "$pl" ]] || { echo "(not an app bundle)"; return; }
  printf 'v%s (%s)  %s  %s' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$pl" 2>/dev/null)" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$pl" 2>/dev/null)" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$pl" 2>/dev/null)" \
    "$([[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] && echo Sparkle || echo no-Sparkle)"
}

running() {
  ps -Ao pid=,command= | grep '/Snappy.app/Contents/MacOS/Snappy' | grep -v grep || true
}

report_running() {
  local any=
  while read -r pid cmd; do
    [[ -n "${pid:-}" ]] || continue
    any=1
    local app="${cmd%%.app/*}.app"
    echo "  pid $pid  $(describe "$app")"
    echo "      $app"
  done < <(running)
  [[ -n "$any" ]] || echo "  (nothing running)"
}

if [[ -n "$STATUS_ONLY" ]]; then
  echo "Running:"; report_running
  echo
  echo "Installed:"
  [[ -d /Applications/Snappy.app ]] && echo "  $(describe /Applications/Snappy.app)" || echo "  (none in /Applications)"
  exit 0
fi

# Sign with Developer ID, not the automatic Apple Development identity.
#
# macOS keys the Accessibility grant to the code signature. An Apple Development
# signature changes enough between builds that TCC throws the grant away, so
# every reinstall silently un-authorised the app: the panel still appeared, the
# event tap could not be created, and keystrokes went to whatever was behind it.
# That reads exactly like "it worked for a second and then stopped".
#
# A Developer ID signature has a designated requirement built from the team and
# bundle id rather than the individual build, so one grant survives rebuilds.
# NEVER build this with the Release configuration's own entitlements. Those are
# the Mac App Store ones, which turn on the App Sandbox -- and a sandboxed Snappy
# is not a slightly worse Snappy, it is a completely inert one. The sandbox
# denies the mach lookup of com.apple.axserver, so AXIsProcessTrusted() returns
# true, the Accessibility checkbox looks granted, CGEventTapCreate returns a live
# enabled tap, and then nothing happens: no window moves and the tap never
# receives a single event. Every symptom points at permissions and none of them
# are the problem. docs/APP_STORE.md records the same finding, which is why
# build-direct.sh overrides this too.
#
# The path must be absolute: xcodebuild applies command-line build settings to
# every target, and the MASShortcut package resolves a relative one against its
# own checkout.
SIGN_ARGS=(CODE_SIGN_ENTITLEMENTS="$PWD/Snappy/SnappyDirect.entitlements")
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  SIGN_ARGS+=(CODE_SIGN_STYLE=Manual
             CODE_SIGN_IDENTITY="Developer ID Application"
             DEVELOPMENT_TEAM="${TEAM_ID:-P78K4VHEL3}"
             PROVISIONING_PROFILE_SPECIFIER="")
else
  echo "No Developer ID certificate found; falling back to the project's signing." >&2
  echo "Expect to re-grant Accessibility after every rebuild." >&2
fi

echo "Building ${CONFIG}…"
xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration "$CONFIG" \
  -destination 'platform=macOS' "${SIGN_ARGS[@]}" build >/dev/null

# Ask for build settings with the SAME flags used to build. The project sets a
# custom SYMROOT, so `-target` alone answers ./build/Release while a
# `-scheme` + `-destination` build writes to DerivedData -- and ./build/Release
# still holds a v1.0 from September. Querying the wrong one installs a stale
# app that looks plausible and is months old.
BUILT=$(xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration "$CONFIG" \
  -destination 'platform=macOS' "${SIGN_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR = / {print $3; exit}')/Snappy.app
[[ -d "$BUILT" ]] || { echo "Build produced no app at $BUILT" >&2; exit 1; }

# Refuse to install something older than the source that just built it.
BUILT_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist" 2>/dev/null)
PROJ_VER=$(xcodebuild -project Snappy.xcodeproj -scheme Snappy -configuration "$CONFIG" \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ MARKETING_VERSION = / {print $3; exit}')
if [[ "$BUILT_VER" != "$PROJ_VER" ]]; then
  echo "Built app says v$BUILT_VER but the project says v$PROJ_VER — stale artifact at" >&2
  echo "$BUILT" >&2
  exit 1
fi

# Quit every Snappy, whatever its identifier. A stale copy from before the
# rename has a different bundle id and will happily keep running beside the new
# one, which is most of why this is confusing in the first place.
while read -r pid _; do
  [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true
done < <(running)
sleep 2

# Keep the outgoing copy: it may be the last build of a published version.
if [[ -d /Applications/Snappy.app ]]; then
  OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Snappy.app/Contents/Info.plist 2>/dev/null)
  NEW_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist" 2>/dev/null)
  BACKUP="$HOME/Library/Application Support/Snappy/previous-app/Snappy.app"
  mkdir -p "$(dirname "$BACKUP")"
  rm -rf "$BACKUP"
  ditto /Applications/Snappy.app "$BACKUP"
  echo "Backed up the installed copy ($(describe /Applications/Snappy.app))"
  echo "  -> $BACKUP"
  [[ "$OLD_ID" != "$NEW_ID" ]] && echo "  note: identifier changes $OLD_ID -> $NEW_ID, so macOS treats this as a different app"
  rm -rf /Applications/Snappy.app
fi

ditto "$BUILT" /Applications/Snappy.app
open -a /Applications/Snappy.app
sleep 2

echo
echo "Now running: $(describe /Applications/Snappy.app)"
echo "             /Applications/Snappy.app"
report_running | tail -2
# Anything else on this machine is a copy you could open by accident.
echo
OTHERS=$( { find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name Snappy.app \
              -path '*/Build/Products/*' 2>/dev/null
            find "$PWD/build" -maxdepth 3 -name Snappy.app 2>/dev/null
          } | sort -u )
if [[ -n "$OTHERS" ]]; then
  echo "Other copies on this machine — any of these can be opened by mistake:"
  while read -r app; do
    [[ -f "$app/Contents/Info.plist" ]] || continue
    echo "  $(describe "$app")"
    echo "      $app"
  done <<<"$OTHERS"
fi

cat <<'NOTE'

If the overlay does nothing, it is Accessibility: the grant is keyed to the
bundle identifier and the code signature, so a rebuild or a rename needs it
again. System Settings > Privacy & Security > Accessibility, remove any Snappy
entry with -, add this one with +, then quit and reopen.
NOTE
