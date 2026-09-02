#!/usr/bin/env python3
"""Render the Divvtangle app icon: Rectangle's blue-window-on-dark tile,
expressed as a highlighted region on a Divvy-style grid."""

import os
from PIL import Image, ImageDraw

SCALE = 4
U = 1024                      # design units
S = U * SCALE                 # render size

def px(v):                    # design units -> render px
    return round(v * SCALE)

def vgradient(w, h, top, bottom):
    """Vertical linear gradient RGBA image."""
    base = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        base.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return base.resize((w, h)).convert("RGBA")

def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m

def block(x, y, w, h, r, top, bottom, stroke=None):
    """Return (image, (x,y)) for a rounded gradient block in render px."""
    x, y, w, h, r = px(x), px(y), px(w), px(h), px(r)
    g = vgradient(w, h, top, bottom)
    g.putalpha(rounded_mask(w, h, r))
    if stroke:
        col, sw = stroke
        ImageDraw.Draw(g).rounded_rectangle(
            [sw // 2, sw // 2, w - 1 - sw // 2, h - 1 - sw // 2],
            radius=max(r - sw // 2, 1), outline=col, width=sw)
    return g, (x, y)

# ---- compose --------------------------------------------------------------
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# background
bg = vgradient(S, S, (0x58, 0x6A, 0x7E), (0x2E, 0x34, 0x40))
bg.putalpha(rounded_mask(S, S, px(230)))
icon.alpha_composite(bg)

# placed "window": left two columns of a 4x4 grid (content margin 150)
blk, pos = block(156, 156, 350, 712, 22, (0x5A, 0xA6, 0xFF), (0x1E, 0x6F, 0xE6),
                 stroke=((255, 255, 255, 51), px(3)))
icon.alpha_composite(blk, pos)

# a single coral cell — a nod to Divvy's coloured grid
cell, pos = block(699, 156, 169, 169, 16, (0xFF, 0x95, 0xA6), (0xF2, 0x63, 0x7E))
icon.alpha_composite(cell, pos)

# 4x4 grid lines over everything
grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(grid)
lines = [150, 331, 512, 693, 874]
for c in lines:
    gd.line([(px(c), px(150)), (px(c), px(874))], fill=(255, 255, 255, 48), width=px(3))
    gd.line([(px(150), px(c)), (px(874), px(c))], fill=(255, 255, 255, 48), width=px(3))
grid.putalpha(Image.composite(grid.getchannel("A"), Image.new("L", (S, S), 0), rounded_mask(S, S, px(230))))
icon.alpha_composite(grid)

# soft top-light sheen + rim
overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
alpha = Image.new("L", (1, S))
for y in range(S):
    alpha.putpixel((0, y), max(0, round(30 * (1 - y / (S * 0.6)))))
sheen = Image.new("RGBA", (S, S), (255, 255, 255, 0))
sheen.putalpha(alpha.resize((S, S)))
overlay.alpha_composite(sheen)
od = ImageDraw.Draw(overlay)
od.rounded_rectangle([px(4), px(4), S - px(4), S - px(4)], radius=px(228),
                     outline=(255, 255, 255, 30), width=px(3))
overlay.putalpha(Image.composite(overlay.getchannel("A"), Image.new("L", (S, S), 0), rounded_mask(S, S, px(230))))
icon.alpha_composite(overlay)

# ---- output -------------------------------------------------------------
out = os.path.dirname(os.path.abspath(__file__))
master = icon.resize((U, U), Image.LANCZOS)
master.save(os.path.join(out, "icon-1024.png"))

sizes = {
    "mac016pts1x.png": 16, "mac016pts2x.png": 32,
    "mac032pts1x.png": 32, "mac032pts2x.png": 64,
    "mac128pts1x.png": 128, "mac128pts2x.png": 256,
    "mac256pts1x.png": 256, "mac256pts2x.png": 512,
    "mac512pts1x.png": 512, "mac512pts2x.png": 1024,
}
setdir = os.path.join(out, "DivvtangleIcon.appiconset")
os.makedirs(setdir, exist_ok=True)
for name, n in sizes.items():
    src = master if n == U else icon.resize((n, n), Image.LANCZOS)
    src.save(os.path.join(setdir, name))
print("wrote", setdir, "and icon-1024.png")
