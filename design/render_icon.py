#!/usr/bin/env python3
"""Render the Snappy app icon: a monochrome take on Rectangle's snapped
window sitting on a Divvy-style grid. White ground, one dark region, gray grid."""

import os
from PIL import Image, ImageDraw

SCALE = 4
U = 1024                      # design units
S = U * SCALE                 # render size

def px(v):
    return round(v * SCALE)

def vgradient(w, h, top, bottom):
    base = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        base.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return base.resize((w, h)).convert("RGBA")

def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m

def clip_to_tile(img):
    a = Image.composite(img.getchannel("A"), Image.new("L", (S, S), 0), rounded_mask(S, S, px(230)))
    img.putalpha(a)
    return img

# grid geometry: 4x4 within a 150-unit content margin
MARGIN = 150
LINES = [150, 331, 512, 693, 874]
BLOCK = (156, 156, 350, 712, 22)   # x, y, w, h, radius  (left two columns)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 1. white tile
bg = vgradient(S, S, (0xFF, 0xFF, 0xFF), (0xEC, 0xEC, 0xEC))
bg.putalpha(rounded_mask(S, S, px(230)))
icon.alpha_composite(bg)

# 2. gray grid lines
grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(grid)
for c in LINES:
    gd.line([(px(c), px(MARGIN)), (px(c), px(874))], fill=(0xC2, 0xC2, 0xC2, 255), width=px(3))
    gd.line([(px(MARGIN), px(c)), (px(874), px(c))], fill=(0xC2, 0xC2, 0xC2, 255), width=px(3))
icon.alpha_composite(clip_to_tile(grid))

# 3. dark "placed window" region
bx, by, bw, bh, br = BLOCK
block = vgradient(px(bw), px(bh), (0x2C, 0x2C, 0x2E), (0x16, 0x16, 0x17))
block.putalpha(rounded_mask(px(bw), px(bh), px(br)))
icon.alpha_composite(block, (px(bx), px(by)))

# 3b. a second region — the top-right quarter, mid grey
cx, cy, cw, ch, cr = 518, 156, 350, 350, 22
cell = vgradient(px(cw), px(ch), (0xAC, 0xAC, 0xAC), (0x8E, 0x8E, 0x8E))
cell.putalpha(rounded_mask(px(cw), px(ch), px(cr)))
icon.alpha_composite(cell, (px(cx), px(cy)))

# 4. keep the grid visible across the dark region (light lines)
over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
od = ImageDraw.Draw(over)
for c in LINES:
    if bx < c < bx + bw:
        od.line([(px(c), px(by)), (px(c), px(by + bh))], fill=(255, 255, 255, 46), width=px(3))
    if by < c < by + bh:
        od.line([(px(bx), px(c)), (px(bx + bw), px(c))], fill=(255, 255, 255, 46), width=px(3))
icon.alpha_composite(over)

# 5. subtle rim so the white tile has an edge on light backgrounds
rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(rim).rounded_rectangle(
    [px(3), px(3), S - px(3), S - px(3)], radius=px(228),
    outline=(0, 0, 0, 28), width=px(3))
icon.alpha_composite(clip_to_tile(rim))

# ---- output -----------------------------------------------------------------
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
assets = os.path.join(os.path.dirname(out), "Rectangle", "Assets.xcassets")
setdirs = [os.path.join(assets, "SnappyIcon.appiconset"),
           os.path.join(assets, "AppIcon.appiconset")]
setdirs = [d for d in setdirs if os.path.isdir(d)] or [os.path.join(out, "SnappyIcon.appiconset")]
for setdir in setdirs:
    os.makedirs(setdir, exist_ok=True)
    for name, n in sizes.items():
        src = master if n == U else icon.resize((n, n), Image.LANCZOS)
        src.save(os.path.join(setdir, name))
    print("wrote", setdir)
