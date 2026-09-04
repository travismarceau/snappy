#!/usr/bin/env bash
#
# capture-screenshots.sh — grab the raw material for the App Store screenshots.
#
# This only captures. It does not resize or crop, because the built-in display
# is 3456x2234 (aspect 1.55) and App Store Connect accepts only 1280x800 /
# 1440x900 / 2560x1600 / 2880x1800 (aspect 1.60) — nothing captured here is a
# submittable size. Run design/compose_screenshots.py afterwards to place these
# on exact 2880x1800 canvases.
#
# Two kinds of scene:
#
#   window  the Settings window, captured by window id with `-o` so it comes
#           back shadowless on a transparent ground and the compositor can
#           draw its own shadow at the right scale.
#   screen  a full-screen capture on a countdown. The placement overlay and an
#           open menu-bar menu can only be captured this way — both vanish the
#           moment focus moves, and neither is reachable from a script (the
#           overlay is driven by a global hotkey, not a URL action).
#
#   ./scripts/capture-screenshots.sh            # every scene, in order
#   ./scripts/capture-screenshots.sh --list     # show the scenes
#   ./scripts/capture-screenshots.sh --only 3   # redo scene 3

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RAW="$ROOT/store/screenshots/raw"
FRAMES="$ROOT/scripts/window-frames.swift"
COUNTDOWN=6

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m    %s\n' "$*"; }
bad()  { printf '\033[31m  fail\033[0m  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }

# name|kind|instructions
SCENES=(
"01-overlay|screen|The placement overlay, with the key map revealed.
  • Get a real working desktop on screen — an editor and a terminal, not an empty desktop.
  • When the countdown starts, press ⌃⌥Space and hold still.
  • Wait for the key→region map to fade in before the shutter fires."

"02-placements|window|Settings ▸ Placement ▸ Placements.
  • Open Snappy's Settings, go to the Placement tab, select the Placements sub-pane.
  • Have several bindings in the list and one selected, so the Region card shows a drawn region.
  • Leave the window frontmost."

"03-layouts|window|Settings ▸ Placement ▸ Layouts.
  • Same window, switch to the Layouts sub-pane.
  • Select a layout with two or three windows in it, and select one slot so the picker is populated."

"04-arranged|screen|A multi-window layout, just after it was applied.
  • Get the layout's apps open and scattered.
  • When the countdown starts, press ⌃⌥Space then the layout key, and let it settle."

"05-general|window|Settings ▸ General.
  • Switch to the General tab. Leave the window frontmost."

"06-menubar|screen|The menu-bar icon with its menu open.
  • When the countdown starts, click the Snappy menu-bar icon and leave the menu open."
)

# Pure bash, because the instructions field is multi-line and `cut` splits on
# newlines before it splits on the delimiter.
scene_field() { # $1 = scene record, $2 = field number
  local rest="${1#*|}"
  case "$2" in
    1) printf '%s' "${1%%|*}" ;;
    2) printf '%s' "${rest%%|*}" ;;
    3) printf '%s' "${rest#*|}" ;;
  esac
}

if [[ "${1:-}" == "--list" ]]; then
  bold "Scenes"
  for i in "${!SCENES[@]}"; do
    printf '  %d. %-16s (%s)\n' "$((i + 1))" \
      "$(scene_field "${SCENES[$i]}" 1)" "$(scene_field "${SCENES[$i]}" 2)"
  done
  exit 0
fi

ONLY=""
case "${1:-}" in
  "")       ;;
  --only)   ONLY="${2:?--only needs a scene number}" ;;
  -h|--help) sed -n '2,25p' "$0" | sed 's/^#\{1\} \{0,1\}//'; exit 0 ;;
  *)        echo "unknown argument: $1" >&2; exit 2 ;;
esac

mkdir -p "$RAW"

capture_window() {
  local out="$1" id
  if ! pgrep -x Snappy > /dev/null; then
    bad "Snappy is not running"
    return 1
  fi
  if ! id="$(swift "$FRAMES" --owner Snappy --id-only 2>/dev/null)"; then
    bad "Snappy has no ordinary window on screen — is Settings open?"
    return 1
  fi
  # -x silences the shutter, -o drops the window shadow so the compositor can
  # draw one that matches the final scale.
  screencapture -x -o -l"$id" "$out"
}

capture_screen() {
  local out="$1"
  info "capturing the full screen in ${COUNTDOWN}s — go"
  screencapture -x -T "$COUNTDOWN" "$out"
}

run_scene() {
  local scene="$1" index="$2"
  local name kind instructions out
  name="$(scene_field "$scene" 1)"
  kind="$(scene_field "$scene" 2)"
  instructions="$(scene_field "$scene" 3)"
  out="$RAW/$name.png"

  bold "$index. $name"
  printf '  %s\n' "$instructions"
  read -r -p "  Ready? Press Enter to capture (or s to skip) " reply
  [[ "$reply" == "s" ]] && { info "skipped"; return 0; }

  rm -f "$out"
  case "$kind" in
    window) capture_window "$out" || return 1 ;;
    screen) capture_screen "$out" ;;
  esac

  if [[ ! -s "$out" ]]; then
    bad "nothing was written to $out"
    return 1
  fi
  ok "$(basename "$out")  $(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
}

FAILED=0
for i in "${!SCENES[@]}"; do
  n=$((i + 1))
  [[ -n "$ONLY" && "$ONLY" != "$n" ]] && continue
  run_scene "${SCENES[$i]}" "$n" || FAILED=$((FAILED + 1))
done

bold "Captured into $RAW"
ls -1 "$RAW" 2>/dev/null | sed 's/^/  /' || info "(nothing)"

if [[ "$FAILED" -gt 0 ]]; then
  bad "$FAILED scene(s) failed — rerun them with --only N"
  exit 1
fi

bold "Next"
info "uv run design/compose_screenshots.py"
