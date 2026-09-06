#!/usr/bin/env bash
#
# verify-sandbox.sh — prove the *sandboxed* Snappy actually moves windows.
#
# Every bit of window management testing so far has been against the Debug
# build, whose Snappy/Snappy.entitlements is an empty dict — no sandbox
# at all. The App Store build is sandboxed (Snappy/SnappyRelease.ent-
# itlements). Sandbox + Accessibility is known to work for Magnet and Rectangle
# Pro, but "known to work for someone else" is not evidence about this binary.
#
# A plain Release build is enough to test it: it picks up the sandbox
# entitlements and is signed "Apple Development", which is a stable identity
# TCC will accept and remember. None of the three account-side exportArchive
# blockers (Xcode account, Mac Installer Distribution cert, provisioning
# profile) are in the way — those gate distribution, not local execution.
#
# Steps 1-4 are automatic. Steps 5+ need you at the keyboard: granting
# Accessibility is a TCC prompt only a human can accept, and the placement
# overlay is driven by a global hotkey, not a scriptable action.
#
#   ./scripts/verify-sandbox.sh                # full run
#   ./scripts/verify-sandbox.sh --skip-build   # re-run just the move tests
#   ./scripts/verify-sandbox.sh --skip-install # test whatever is already installed

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_BUILT="$ROOT/build/Release/Snappy.app"
APP_INSTALLED="/Applications/Snappy.app"
FRAMES="$ROOT/scripts/window-frames.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SKIP_BUILD=0
SKIP_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --skip-build)   SKIP_BUILD=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^#\{1\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
pass()  { printf '\033[32m  PASS\033[0m  %s\n' "$*"; }
fail()  { printf '\033[31m  FAIL\033[0m  %s\n' "$*"; }
info()  { printf '       %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

FAILURES=0
note_failure() { FAILURES=$((FAILURES + 1)); }

confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ---------------------------------------------------------------- 1. build

if [[ "$SKIP_BUILD" == 0 ]]; then
  step "1. Building Release (sandboxed, Apple Development signed)"
  xcodebuild -project Snappy.xcodeproj -scheme Snappy \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$ROOT/build/Release" \
    build > "$WORK/build.log" 2>&1 || {
      fail "build failed — last 40 lines:"
      tail -40 "$WORK/build.log"
      exit 1
    }
  pass "built $APP_BUILT"
else
  step "1. Build skipped (--skip-build)"
fi

[[ -d "$APP_BUILT" ]] || { fail "no build at $APP_BUILT — run without --skip-build"; exit 1; }

# ------------------------------------------- 2. assert it is really sandboxed

step "2. Verifying the signature and entitlements of the built binary"

# plutil -extract reads dots as key-path separators, so an entitlement name has
# to have each of its own dots escaped or the lookup silently finds nothing.
has_entitlement() { # $1 = plist path, $2 = entitlement key
  plutil -extract "${2//./\\.}" raw -o - "$1" 2>/dev/null | grep -qx true
}

codesign -d --entitlements :- --xml "$APP_BUILT" 2>/dev/null > "$WORK/ent.plist" || true

if has_entitlement "$WORK/ent.plist" com.apple.security.app-sandbox; then
  pass "com.apple.security.app-sandbox is present in the signature"
else
  fail "the built app is NOT sandboxed — this test would prove nothing"
  info "entitlements found:"
  plutil -p "$WORK/ent.plist" 2>/dev/null | sed 's/^/       /' || info "(none)"
  exit 1
fi

if has_entitlement "$WORK/ent.plist" com.apple.security.files.user-selected.read-write; then
  pass "user-selected file access is present (Import/Export, the app picker)"
else
  fail "user-selected file access is missing — Import/Export and the Layouts app picker will fail"
  note_failure
fi

AUTHORITY="$(codesign -dvv "$APP_BUILT" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2- || true)"
if [[ -n "$AUTHORITY" && "$AUTHORITY" != "(unsigned)" ]]; then
  pass "signed by: $AUTHORITY"
  case "$AUTHORITY" in
    *"Apple Development"*|*"Apple Distribution"*|*"Developer ID"*) ;;
    *) info "note: an ad-hoc signature will not hold a TCC grant across rebuilds" ;;
  esac
else
  fail "the app is unsigned — TCC will not remember the Accessibility grant"
  note_failure
fi

# The launcher is nested code; the App Store requires it be sandboxed too.
LAUNCHER="$APP_BUILT/Contents/Library/LoginItems"
if [[ -d "$LAUNCHER" ]]; then
  for helper in "$LAUNCHER"/*.app; do
    [[ -e "$helper" ]] || continue
    codesign -d --entitlements :- --xml "$helper" 2>/dev/null > "$WORK/helper-ent.plist" || true
    if has_entitlement "$WORK/helper-ent.plist" com.apple.security.app-sandbox; then
      pass "nested login item is sandboxed: $(basename "$helper")"
    else
      fail "nested login item is NOT sandboxed: $(basename "$helper")"
      note_failure
    fi
  done
fi

# ------------------------------------------------- 3. clear the field

step "3. Checking for a conflicting Snappy already running"

if pgrep -x Snappy > /dev/null; then
  info "A Snappy is already running. Two instances fight over the same global"
  info "hotkey, and the ad-hoc Debug build shows up in System Settings under"
  info "the same name — which makes the Accessibility list ambiguous."
  pgrep -xl Snappy | sed 's/^/       /'
  if confirm "Quit the running Snappy?"; then
    osascript -e 'quit app "Snappy"' 2>/dev/null || pkill -x Snappy || true
    sleep 1
    pass "quit"
  else
    info "continuing anyway — results may be misleading"
  fi
else
  pass "no Snappy running"
fi

# ------------------------------------------------- 4. install

if [[ "$SKIP_INSTALL" == 0 ]]; then
  step "4. Installing to $APP_INSTALLED"
  info "TCC keys the grant to this path and signature, so testing from a stable"
  info "location means you only grant Accessibility once."
  if confirm "Copy the build to $APP_INSTALLED (replacing any existing copy)?"; then
    rm -rf "$APP_INSTALLED"
    ditto "$APP_BUILT" "$APP_INSTALLED"
    pass "installed"
  else
    APP_INSTALLED="$APP_BUILT"
    info "using $APP_INSTALLED instead"
  fi
else
  step "4. Install skipped (--skip-install)"
fi

[[ -d "$APP_INSTALLED" ]] || { fail "nothing at $APP_INSTALLED"; exit 1; }

# ------------------------------------------------- 5. grant Accessibility

step "5. Granting Accessibility (needs you)"

open "$APP_INSTALLED"
sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<'EOS'
       In System Settings ▸ Privacy & Security ▸ Accessibility:
         • Remove any stale "Snappy" entry first (the old ad-hoc Debug build
           has a different signature and its grant does not carry over).
         • Enable Snappy. Use + and pick /Applications/Snappy.app if it is
           not listed.
         • If macOS asks, let it relaunch Snappy.
EOS

read -r -p "Press Enter once Snappy is enabled and running... "

if ! pgrep -x Snappy > /dev/null; then
  info "Snappy is not running — relaunching"
  open "$APP_INSTALLED"
  sleep 2
fi

# ------------------------------------------------- 6/7. move tests

snapshot() { swift "$FRAMES" > "$1"; }

# Diffs two snapshots and reports every layer-0 window whose frame changed.
# Matching is by (pid, id) so a window that merely came to the front is not
# mistaken for one that moved. Snappy's own windows are excluded — the overlay
# appearing is not evidence that anything was placed.
diff_frames() {
  python3 - "$1" "$2" <<'PY'
import json, sys

def load(path):
    with open(path) as f:
        return {(w["pid"], w["id"]): w for w in json.load(f)}

before, after = load(sys.argv[1]), load(sys.argv[2])
moved = []
for key, b in before.items():
    a = after.get(key)
    if a is None or a["owner"] == "Snappy":
        continue
    if (b["x"], b["y"], b["width"], b["height"]) != (a["x"], a["y"], a["width"], a["height"]):
        moved.append((b, a))

if not moved:
    print("NO-CHANGE")
    sys.exit(1)

for b, a in moved:
    print(f'MOVED {b["owner"]}: '
          f'{b["width"]}x{b["height"]}+{b["x"]}+{b["y"]} -> '
          f'{a["width"]}x{a["height"]}+{a["x"]}+{a["y"]}')
PY
}

run_move_test() {
  local label="$1" instructions="$2"
  step "$label"
  printf '%s\n' "$instructions"
  read -r -p "Press Enter when the windows are positioned and ready... "
  snapshot "$WORK/before.json"
  info "captured 'before' — now perform the placement"
  read -r -p "Press Enter once the placement has finished... "
  snapshot "$WORK/after.json"

  local out
  if out="$(diff_frames "$WORK/before.json" "$WORK/after.json")"; then
    pass "the sandboxed build moved a window it does not own:"
    printf '%s\n' "$out" | sed 's/^/         /'
  else
    fail "no window changed frame — the sandboxed build did not move anything"
    info "if the overlay never appeared, the hotkey is not registering;"
    info "if it appeared but nothing moved, the AX write is being denied"
    note_failure
  fi
}

# A plain document window, opened without Apple Events so this script needs no
# Automation permission either. Deliberately not inside $WORK, which is deleted
# on exit — TextEdit would still have it open.
TESTDOC="${TMPDIR:-/tmp}/snappy-sandbox-check.txt"
printf 'Snappy sandbox verification — close this without saving when done.\n' > "$TESTDOC"
open -a TextEdit "$TESTDOC"
sleep 2

run_move_test "6. Single-window placement" "$(cat <<'EOS'
       A TextEdit document has been opened. Click it to focus it, then:
         • press ⌃⌥Space to open the placement grid
         • press a key you have bound to a region
EOS
)"

run_move_test "7. Multi-window layout" "$(cat <<'EOS'
       Open the two or more apps one of your saved Layouts arranges, then:
         • press ⌃⌥Space
         • press the key bound to that Layout
       (Skip by pressing Enter twice without doing anything — it will report
        FAIL, which is accurate: nothing was verified.)
EOS
)"

# ------------------------------------------------- summary

step "Summary"
if [[ "$FAILURES" == 0 ]]; then
  pass "the sandboxed build moves windows — every check passed"
  info "Record it under 'Sandbox verification' in docs/APP_STORE.md:"
  info "today's date, $(sw_vers -productName) $(sw_vers -productVersion), and the"
  info "before/after frames printed above."
else
  fail "$FAILURES check(s) failed"
  info "If the AX moves are what failed, the fallback is documented:"
  info "point the Release config at Snappy/SnappyDirect.entitlements"
  info "and ship direct-download instead of the App Store."
  exit 1
fi
