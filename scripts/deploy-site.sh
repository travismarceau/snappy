#!/usr/bin/env bash
# Deploy the checked-in website/appcast and prove the expected build is live.
#
# Normally DigitalOcean deploys pushes through the GitHub integration in
# .do/app.yaml. Release publishing still calls this script explicitly so a
# delayed or missing webhook cannot leave an old appcast live.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${SNAPPY_DO_APP_NAME:-getsnappy}"
FEED="${SNAPPY_FEED_URL:-$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Snappy/Info.plist 2>/dev/null)}"
EXPECTED_BUILD=$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' site/appcast.xml |
  sort -n | tail -1)

command -v doctl >/dev/null || { echo "doctl is required." >&2; exit 2; }
[[ -n "$FEED" ]] || { echo "No feed URL found in Snappy/Info.plist." >&2; exit 2; }
[[ -n "$EXPECTED_BUILD" ]] || { echo "No build found in site/appcast.xml." >&2; exit 2; }

if [[ -n "${SNAPPY_DO_APP_ID:-}" ]]; then
  APP_ID="$SNAPPY_DO_APP_ID"
else
  APP_IDS=$(doctl apps list --format ID,Spec.Name --no-header |
    awk -v name="$APP_NAME" '$2 == name { print $1 }')
  if [[ $(wc -w <<<"$APP_IDS" | tr -d ' ') != 1 ]]; then
    echo "Expected exactly one DigitalOcean app named '$APP_NAME'; found: ${APP_IDS:-none}" >&2
    exit 2
  fi
  APP_ID="$APP_IDS"
fi

echo "Deploying $APP_NAME ($APP_ID) and waiting for that deployment..."
doctl apps create-deployment "$APP_ID" --force-rebuild --wait --format ID,Phase

# ACTIVE alone is insufficient: it may describe the deployment that was live
# before this one started. Poll the public feed itself until it serves the build
# in the committed appcast, without a cache-busting URL that Sparkle will never
# request.
LIVE_BUILD=""
for attempt in {1..12}; do
  LIVE_BODY=$(curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "$FEED" 2>/dev/null || true)
  LIVE_BUILD=$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' <<<"$LIVE_BODY" |
    sort -n | tail -1)
  if [[ "$LIVE_BUILD" == "$EXPECTED_BUILD" ]]; then
    echo "Live feed advertises build $LIVE_BUILD."
    ./scripts/verify-release.sh "$FEED"
    exit 0
  fi

  echo "Live feed advertises build ${LIVE_BUILD:-none}; waiting for $EXPECTED_BUILD ($attempt/12)..."
  sleep 5
done

echo "Deployment completed, but $FEED still advertises build ${LIVE_BUILD:-none}; expected $EXPECTED_BUILD." >&2
exit 1
