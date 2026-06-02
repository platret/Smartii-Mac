#!/usr/bin/env python3
"""Generate the Smartii DMG background images (1x and 2x).

Draws a smooth dark-violet -> near-black diagonal gradient, the Smartii logo
near the top-center, the "Smartii" title + install subtitle, and a subtle
violet->pink arrow pointing from the app-icon spot (left) to the
Applications spot (right). Writes:
  Resources/dmg-background.png       (660x420)
  Resources/dmg-background@2x.png    (1320x840)

Usage (from repo root): python3 Scripts/gen-dmg-background.py
"""

import math
import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
LOGO_PATH = os.path.join(RES, "SmartiiLogo.png")

# Logical (1x) canvas. The icon view in the DMG window uses these point
# coordinates, so the 1x image must be exactly this size.
W, H = 660, 420

# Brand palette.
VIOLET_TOP = (0x1a, 0x11, 0x40)   # #1a1140
NEAR_BLACK = (0x07, 0x07, 0x0b)   # #07070b
ACCENT_VIOLET = (0x7c, 0x5c, 0xff)  # #7c5cff
ACCENT_PINK = (0xff, 0x5e, 0x9c)    # #ff5e9c
TEXT = (0xf5, 0xf5, 0xf7)           # #f5f5f7
TEXT_SECONDARY = (0xf5, 0xf5, 0xf7)  # used with alpha


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def find_font(size, bold=False):
    """Best-effort load of a clean system sans-serif at the given size."""
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
        if bold
        else "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def diagonal_gradient(scale):
    """Smooth top-left violet -> bottom-right near-black gradient."""
    w, h = W * scale, H * scale
    base = Image.new("RGB", (w, h))
    px = base.load()
    maxd = (w - 1) + (h - 1)
    for y in range(h):
        for x in range(w):
            t = (x + y) / maxd
            px[x, y] = lerp(VIOLET_TOP, NEAR_BLACK, t)
    return base


def radial_glow(scale):
    """A soft violet glow behind the logo, blended additively."""
    w, h = W * scale, H * scale
    glow = Image.new("L", (w, h), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy = int(0.5 * w), int(0.22 * h)
    r = int(0.42 * w)
    for i in range(r, 0, -2):
        a = int(70 * (1 - i / r) ** 1.6)
        gd.ellipse([cx - i, cy - i, cx + i, cy + i], fill=a)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=18 * scale))
    tint = Image.new("RGB", (w, h), ACCENT_VIOLET)
    return tint, glow


def draw_arrow(draw, scale):
    """Subtle violet->pink arrow across the icon row, from the app-icon spot
    on the left to the Applications spot on the right.

    The DMG icons sit at point (165, 210) and (495, 210) in the window; the
    arrow lives in the gap between them, just under the logo+title block.
    """
    y = int(248 * scale)        # icon row, matches make-dmg.sh icon Y
    x0 = int(238 * scale)       # just right of the left icon
    x1 = int(422 * scale)       # just left of the right icon
    width = max(3, int(4 * scale))

    # A row of fading dashes leading into the arrowhead reads as motion.
    seg = (x1 - x0)
    dashes = 8
    for i in range(dashes):
        t = i / (dashes - 1)
        ax = int(x0 + seg * (i / dashes))
        bx = int(x0 + seg * ((i + 0.6) / dashes))
        col = lerp(ACCENT_VIOLET, ACCENT_PINK, t)
        alpha = int(55 + 165 * t)
        draw.line([(ax, y), (bx, y)], fill=col + (alpha,), width=width)

    # Arrowhead at the right end.
    head = int(13 * scale)
    hx = x1
    draw.polygon(
        [(hx, y - head), (hx + head * 1.5, y), (hx, y + head)],
        fill=ACCENT_PINK + (225,),
    )


def text_centered(draw, cx, y, txt, font, fill):
    bbox = draw.textbbox((0, 0), txt, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text((cx - tw / 2 - bbox[0], y - bbox[1]), txt, font=font, fill=fill)
    return th


def build(scale):
    w, h = W * scale, H * scale

    img = diagonal_gradient(scale).convert("RGBA")

    # Additive violet glow behind the logo.
    tint, glow = radial_glow(scale)
    img = Image.composite(
        Image.blend(img.convert("RGB"), tint, 0.5).convert("RGBA"),
        img,
        glow,
    )

    # Logo near top-center.
    logo = Image.open(LOGO_PATH).convert("RGBA")
    logo_size = int(116 * scale)
    logo = logo.resize((logo_size, logo_size), Image.LANCZOS)
    lx = (w - logo_size) // 2
    ly = int(26 * scale)
    img.alpha_composite(logo, (lx, ly))

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    cx = w / 2
    title_font = find_font(int(40 * scale), bold=True)
    sub_font = find_font(int(16 * scale))

    title_y = ly + logo_size + int(6 * scale)
    th = text_centered(draw, cx, title_y, "Smartii", title_font, TEXT + (255,))

    sub_y = title_y + th + int(12 * scale)
    text_centered(
        draw,
        cx,
        sub_y,
        "Drag Smartii into Applications to install",
        sub_font,
        TEXT_SECONDARY + (168,),
    )

    # Arrow lives at the icon row (y=210), but the title block above must not
    # bleed into it. We've kept the logo+title tight in the top third so the
    # arrow band stays clear.
    draw_arrow(draw, scale)

    img = Image.alpha_composite(img, overlay)
    return img.convert("RGB")


def main():
    one = build(1)
    out1 = os.path.join(RES, "dmg-background.png")
    one.save(out1, "PNG")
    print("wrote", out1, one.size)

    two = build(2)
    out2 = os.path.join(RES, "dmg-background@2x.png")
    two.save(out2, "PNG")
    print("wrote", out2, two.size)


if __name__ == "__main__":
    main()
