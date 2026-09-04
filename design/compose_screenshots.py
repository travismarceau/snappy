#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow"]
# ///
"""Compose the App Store screenshots.

App Store Connect accepts only 1280x800, 1440x900, 2560x1600 and 2880x1800 for
macOS — aspect 1.60. The built-in display is 3456x2234, aspect 1.55, so a raw
capture is never a submittable size no matter how it is cropped. Every frame
therefore gets composed onto an exact 2880x1800 canvas.

The ground is drawn from the app icon's palette (render_icon.py), which is
deliberately monochrome: an off-white-to-grey gradient ruled with the same faint
grid the icon uses, graphite type. Same product, no marketing gradient.

    uv run design/compose_screenshots.py
    uv run design/compose_screenshots.py --only 01-overlay

Run scripts/capture-screenshots.sh first to produce store/screenshots/raw/.
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.exit("pillow is not installed.\n"
             "  uv run design/compose_screenshots.py     (recommended)\n"
             "  pip3 install pillow                      (or install it yourself)")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RAW = os.path.join(ROOT, "store", "screenshots", "raw")
OUT = os.path.join(ROOT, "store", "screenshots")

W, H = 2880, 1800                 # the ASC size we target

# Palette, lifted from render_icon.py so the listing and the icon agree. Each
# frame is the icon at another scale: ruled ground, one thing placed on it —
# except here the placed thing is the app itself. Snappy's own UI is light, so
# the ground has to be grey enough to let a light window sit proud of it.
GROUND_TOP = (0xF4, 0xF4, 0xF6)
GROUND_BOT = (0xD6, 0xD6, 0xDB)
RULE = (0xC2, 0xC2, 0xC2)         # the icon's grid lines
GRAPHITE = (0x2C, 0x2C, 0x2E)     # the icon's placed-window block

SFNS = "/System/Library/Fonts/SFNS.ttf"

CAPTION_SIZE = 72
CAPTION_TOP = 128                 # top of the caption's cap height
SHOT_TOP = 296                    # where the capture area begins
SHOT_BOTTOM_MARGIN = 104
SHOT_SIDE_MARGIN = 200

# The icon rules its grid every 181/1024 of its width; keeping that ratio makes
# the background read as the same drawing at a different scale.
RULE_SPACING = round(W * 181 / 1024)

# name, caption, whether the capture is an opaque rectangle needing its own
# rounded corners (a full-screen grab) or already has alpha corners (a
# window grab from `screencapture -o`).
FRAMES = [
    ("01-overlay",    "One key. One region.",                          True),
    ("02-placements", "Draw the regions you actually use.",            False),
    ("03-layouts",    "A whole arrangement in one keystroke.",         False),
    ("04-arranged",   "Editor, terminal, notes. One key.",             True),
    ("05-general",    "Grid size, margins, gaps.",                     False),
    ("06-menubar",    "Lives in the menu bar. No account, no network.", True),
]


def font(size, weight="Semibold"):
    f = ImageFont.truetype(SFNS, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass  # a non-variable fallback still renders, just at Regular
    return f


def ground():
    """Vertical gradient, ruled with the icon's grid."""
    strip = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        strip.putpixel((0, y), tuple(
            round(GROUND_TOP[i] + (GROUND_BOT[i] - GROUND_TOP[i]) * t) for i in range(3)
        ))
    img = strip.resize((W, H)).convert("RGBA")

    rules = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(rules)
    for x in range(RULE_SPACING, W, RULE_SPACING):
        d.line([(x, 0), (x, H)], fill=RULE + (30,), width=3)
    for y in range(RULE_SPACING, H, RULE_SPACING):
        d.line([(0, y), (W, y)], fill=RULE + (30,), width=3)
    return Image.alpha_composite(img, rules)


def rounded(img, radius):
    """Clip img to a rounded rectangle, preserving any alpha it already has."""
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1],
                                           radius=radius, fill=255)
    out = img.copy()
    existing = out.getchannel("A")
    out.putalpha(Image.composite(existing, Image.new("L", img.size, 0), mask))
    return out


def shadow_for(shot, layers):
    """Blurred silhouettes of the shot's own alpha, so a window's rounded
    corners cast the right shape rather than a plain rectangle.

    `layers` is a list of (offset, blur, alpha): a tight contact shadow pins
    the capture to the ground, a wide ambient one lifts it off. One shadow
    alone reads as either a sticker or a smudge.
    """
    pad = max(blur for _, blur, _ in layers) * 3
    out = Image.new("RGBA", (shot.width + pad * 2, shot.height + pad * 2), (0, 0, 0, 0))
    src_alpha = shot.getchannel("A")
    for offset, blur, alpha in layers:
        layer = Image.new("RGBA", out.size, (0, 0, 0, 0))
        silhouette = Image.new("RGBA", shot.size, (0, 0, 0, 255))
        silhouette.putalpha(src_alpha.point(lambda a, al=alpha: a * al // 255))
        layer.paste(silhouette, (pad, pad + offset), silhouette)
        out = Image.alpha_composite(out, layer.filter(ImageFilter.GaussianBlur(blur)))
    return out, pad


def compose(name, caption, needs_corners):
    src = os.path.join(RAW, f"{name}.png")
    if not os.path.exists(src):
        return None, f"missing {os.path.relpath(src, ROOT)}"

    shot = Image.open(src).convert("RGBA")
    canvas = ground()

    # Caption, centred, with its cap height at CAPTION_TOP.
    d = ImageDraw.Draw(canvas)
    f = font(CAPTION_SIZE)
    bbox = d.textbbox((0, 0), caption, font=f)
    d.text(((W - (bbox[2] - bbox[0])) / 2 - bbox[0], CAPTION_TOP - bbox[1]),
           caption, font=f, fill=GRAPHITE)

    # Fit the capture into what is left, preserving aspect. Fitting rather than
    # cropping keeps the menu bar intact in the full-screen shots.
    #
    # Never scale past 1:1. Captures are already Retina, so a full-screen grab
    # only ever shrinks; but the Settings window is a fixed 760pt (~1540px
    # captured), and stretching that to fill the canvas would be a ~1.6x upscale
    # — visibly soft, and pretending to a sharpness the pixels do not have. A
    # window that fills a little over half the frame and sits on open ground is
    # the honest composition.
    box_w = W - SHOT_SIDE_MARGIN * 2
    box_h = H - SHOT_TOP - SHOT_BOTTOM_MARGIN
    scale = min(box_w / shot.width, box_h / shot.height, 1.0)
    if scale != 1.0:
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)),
                           Image.LANCZOS)

    if needs_corners:
        shot = rounded(shot, 22)

    x = (W - shot.width) // 2
    y = SHOT_TOP + (box_h - shot.height) // 2

    glow, pad = shadow_for(shot, [(10, 14, 78), (36, 60, 58)])
    canvas.alpha_composite(glow, (x - pad, y - pad))
    canvas.alpha_composite(shot, (x, y))

    dest = os.path.join(OUT, f"{name}.png")
    canvas.convert("RGB").save(dest)
    return dest, None


def main():
    only = None
    args = sys.argv[1:]
    if args[:1] == ["--only"]:
        if len(args) < 2:
            sys.exit("--only needs a frame name")
        only = args[1]

    os.makedirs(OUT, exist_ok=True)
    written, problems = [], []

    for name, caption, needs_corners in FRAMES:
        if only and name != only:
            continue
        dest, err = compose(name, caption, needs_corners)
        if err:
            problems.append(err)
            print(f"  skip  {name:<14} {err}")
            continue
        with Image.open(dest) as check:
            size = check.size
        status = "ok  " if size == (W, H) else "BAD "
        print(f"  {status}  {name:<14} {size[0]}x{size[1]}")
        if size != (W, H):
            problems.append(f"{name} came out {size[0]}x{size[1]}, not {W}x{H}")
        written.append(dest)

    print(f"\n{len(written)} frame(s) in {os.path.relpath(OUT, ROOT)}")
    if problems:
        print("\nunresolved:")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)


if __name__ == "__main__":
    main()
