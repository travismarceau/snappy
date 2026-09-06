#!/usr/bin/env python3
"""Render the Snappy menu-bar icon as a template image (single tint + alpha; the
system colours it). Matches the simplified Snappy mark used on the website: a
rounded screen, a tall window filled on the left, the top-right quadrant filled
lighter as a second region, and a light cross of grid lines."""

import os
from PIL import Image, ImageDraw

SS = 8            # supersample factor
U = 40.0          # design units (same proportions as the website mark)
FILL = 0.74       # fraction of the canvas the artwork occupies (leaves menu-bar padding)

FRAME = (0, 0, 0, 255)
WINDOW = (0, 0, 0, 255)
QUAD = (0, 0, 0, 110)
LINE = (0, 0, 0, 70)


def render(size):
    S = size * SS
    k = S * FILL / U
    off = (S - U * k) / 2          # centre the artwork in the canvas
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def rr(x, y, w, h, r, **kw):
        d.rounded_rectangle([off + x * k, off + y * k, off + (x + w) * k, off + (y + h) * k],
                            radius=r * k, **kw)

    def line(x1, y1, x2, y2, colour):
        d.line([(off + x1 * k, off + y1 * k), (off + x2 * k, off + y2 * k)],
               width=max(1, round(1.2 * k)), fill=colour)

    # the two regions
    rr(7, 7, 12.5, 26, 2.5, fill=WINDOW)          # left window
    rr(20.5, 7, 12.5, 12.5, 2.5, fill=QUAD)       # top-right quadrant

    # grid cross
    line(20.5, 7, 20.5, 33, LINE)
    line(7, 20, 33, 20, LINE)

    # rounded screen frame
    rr(1.6, 1.6, 36.8, 36.8, 7.6, outline=FRAME, width=max(1, round(2.0 * k)))

    return img.resize((size, size), Image.LANCZOS)


out = os.path.dirname(os.path.abspath(__file__))
setdir = os.path.join(os.path.dirname(out), "Snappy", "Assets.xcassets", "StatusTemplate.imageset")
os.makedirs(setdir, exist_ok=True)

for name, n in {"SnappyStatusTemplate22.png": 22,
                "SnappyStatusTemplate44.png": 44,
                "SnappyStatusTemplate.png": 66}.items():
    render(n).save(os.path.join(setdir, name))

with open(os.path.join(setdir, "Contents.json"), "w") as f:
    f.write("""{
  "images" : [
    { "filename" : "SnappyStatusTemplate22.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "SnappyStatusTemplate44.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "SnappyStatusTemplate.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""")

print("wrote", setdir)

# desktop preview: dark tint on a light card + the true 22px, scaled up crisply
card = Image.new("RGBA", (300, 170), (244, 244, 245, 255))
for i, n in enumerate((160, 22)):
    g = render(n)
    if n < 160:
        g = g.resize((160, 160), Image.NEAREST)
    tint = Image.new("RGBA", g.size, (22, 22, 24, 255))
    tint.putalpha(g.split()[3])
    card.alpha_composite(tint, (10 + i * 150, 5))
card.convert("RGB").save(os.path.expanduser("~/Desktop/snappy-menubar-preview.png"))
print("preview -> ~/Desktop/snappy-menubar-preview.png  (left: rendered large, right: real 22px upscaled)")
