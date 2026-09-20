#!/usr/bin/env bash
# Verify a published Sparkle feed is actually serving a usable update.
#
# Usage: scripts/verify-release.sh [feed-url]
#        (default: SUFeedURL from Snappy/Info.plist)
#
# Why this exists rather than a curl for 200: getsnappy.fyi is a DigitalOcean
# static site whose catchall document is index.html, so EVERY unknown path
# answers 200 with the homepage. A missing appcast looks identical to a present
# one to anything that only reads status codes -- and Sparkle then fetches HTML,
# fails to parse it, and reports an update error to the user. Every check below
# corresponds to a way this has actually broken.
set -uo pipefail
cd "$(dirname "$0")/.."

FEED="${1:-$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Snappy/Info.plist 2>/dev/null)}"
[[ -n "$FEED" ]] || { echo "No feed URL given and none in Info.plist." >&2; exit 2; }

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "Feed: $FEED"

BODY=$(curl -fsSL --max-time 30 "$FEED" 2>/dev/null) || { echo "  FAIL  feed did not fetch" >&2; exit 1; }
CTYPE=$(curl -fsSI --max-time 30 "$FEED" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}')

# 1. Is it a feed at all, or the catchall homepage?
case "$CTYPE" in
  *xml*) ok "content-type is $CTYPE" ;;
  *)     bad "content-type is '${CTYPE:-unset}' -- the site's catchall is serving HTML, the feed is not deployed" ;;
esac
grep -q '<rss' <<<"$BODY" && ok "body is an RSS document" \
                          || bad "body is not RSS (first line: $(head -1 <<<"$BODY" | cut -c1-60))"

# 2. Does it advertise the build we actually shipped? Sparkle compares
#    CFBundleVersion, so that is the number that has to match.
FEED_BUILD=$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' <<<"$BODY" | sort -n | tail -1)
PROJ_BUILD=$(xcodebuild -project Snappy.xcodeproj -target Snappy -configuration Release \
             -showBuildSettings 2>/dev/null | awk '/ CURRENT_PROJECT_VERSION = / {print $3; exit}')
if [[ -z "$FEED_BUILD" ]]; then
  bad "no <sparkle:version> in the feed"
elif [[ "$FEED_BUILD" == "$PROJ_BUILD" ]]; then
  ok "advertises build $FEED_BUILD, matching the project"
else
  bad "advertises build $FEED_BUILD but the project is at $PROJ_BUILD"
fi

# 3. Release notes must be embedded. A sparkle:releaseNotesLink points at a file
#    that is not published, and the catchall then renders the whole homepage
#    inside the update dialog.
grep -q 'sparkle:releaseNotesLink' <<<"$BODY" \
  && bad "notes are LINKED, not embedded -- pass --embed-release-notes" \
  || ok "no releaseNotesLink"
grep -q '<description><!\[CDATA\[' <<<"$BODY" && ok "notes embedded as description" \
                                              || bad "no embedded <description>"

# 4. Signature and minimum OS.
grep -q 'sparkle:edSignature="' <<<"$BODY" && ok "EdDSA signature present" \
                                           || bad "no sparkle:edSignature -- updates will be rejected"
MINOS=$(sed -n 's/.*<sparkle:minimumSystemVersion>\([^<]*\)<.*/\1/p' <<<"$BODY" | head -1)
[[ -n "$MINOS" ]] && ok "minimumSystemVersion $MINOS" \
                  || bad "no minimumSystemVersion -- older macOS would be offered a build it cannot run"

# 5. The download the feed promises has to exist. Release assets on a private
#    repo 404 here, which is the single likeliest cutover mistake.
URL=$(sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' <<<"$BODY" | head -1)
if [[ -z "$URL" ]]; then
  bad "no enclosure url"
else
  # A ranged GET, not HEAD. GitHub release assets redirect to their object
  # store, and a HEAD against that redirect answers 404 even when the asset is
  # public and downloads perfectly -- which this script reported as a failed
  # release until someone checked by hand.
  read -r CODE DLTYPE < <(curl -fsSL --max-time 60 -r 0-0 -o /dev/null \
    -w '%{http_code} %{content_type}\n' "$URL" 2>/dev/null || echo "000 -")
  # A range request succeeds with 206 Partial Content.
  [[ "$CODE" == "206" ]] && CODE=200
  if [[ "$CODE" == "200" ]] && [[ "$DLTYPE" != text/html* ]]; then
    ok "download resolves ($CODE, $DLTYPE)"
  else
    bad "download $URL -> $CODE ${DLTYPE} (private repo? unpublished asset?)"
  fi
fi

echo
if (( fails )); then
  echo "$fails check(s) failed — do not announce this release."
  exit 1
fi
echo "All checks passed."
