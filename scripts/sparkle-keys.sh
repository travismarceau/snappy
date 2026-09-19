#!/usr/bin/env bash
# Generate (or show) the EdDSA key pair Sparkle uses to sign updates.
#
# Run this ONCE, ever. The private half goes into the login keychain and is
# never written to disk; the public half goes into Snappy/Info.plist as
# SUPublicEDKey, where it ships inside the app.
#
# Losing the private key means you can never ship another update to anyone
# already running Snappy: they verify every download against the public key
# baked into the copy they already have. Back up the keychain item.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=$(find ~/Library/Developer/Xcode/DerivedData \
        -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
        -type f 2>/dev/null | head -1)

if [[ -z "$BIN" ]]; then
  echo "Sparkle's generate_keys tool isn't in DerivedData yet." >&2
  echo "Build the app once so SwiftPM fetches Sparkle, then re-run this." >&2
  exit 1
fi

echo "Using $BIN"
echo
# With no arguments generate_keys creates a key if none exists and otherwise
# prints the existing public key, which is exactly the behaviour wanted here.
"$BIN"

cat <<'NOTE'

Next: copy the public key printed above into Snappy/Info.plist as the value of
SUPublicEDKey. Until that key is present, Sparkle refuses every update rather
than accepting an unsigned one.
NOTE
