#!/usr/bin/env python3
"""Renders the Poker Ledger chip mark to PNG (launcher icon + previews).

The in-app logo is drawn by lib/widgets/poker_chip_logo.dart (a
CustomPainter) so it stays crisp at any size and so the circular
"POKER LEDGER" text actually renders -- flutter_svg does not support
<text>/<textPath>. This script produces the raster copies Android/iOS
launcher icons need, from the same geometry, so the two never drift.

Usage:  python3 tool/generate_logo.py
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "images")
SS = 4  # supersampling factor

SERIF_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"

# ---- palette -------------------------------------------------------------
GOLD_LIGHT = (255, 243, 196)
GOLD = (212, 175, 55)
GOLD_DARK = (138, 106, 24)
FELT_LIGHT = (47, 156, 104)
FELT = (27, 122, 76)
FELT_DARK = (9, 58, 36)
INNER_FELT = (20, 107, 69)
INNER_FELT_DARK = (10, 64, 40)
CARD = (247, 245, 238)
INK = (18, 16, 14)
BG = (11, 18, 16)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def radial_disc(size, stops, cx=0.34, cy=0.26):
    """Disc with a radial gradient; returns RGBA image with alpha circle."""
    r = size / 2.0
    ox, oy = cx * size, cy * size
    ys, xs = np.mgrid[0:size, 0:size]
    maxd = math.hypot(max(ox, size - ox), max(oy, size - oy))
    t = np.clip(np.hypot(xs - ox, ys - oy) / maxd, 0, 1)
    ps = np.array([p for p, _ in stops], dtype=float)
    cs = np.array([c for _, c in stops], dtype=float)
    out = np.zeros((size, size, 4), dtype=np.uint8)
    for ch in range(3):
        out[:, :, ch] = np.interp(t, ps, cs[:, ch]).astype(np.uint8)
    inside = ((xs - r + 0.5) ** 2 + (ys - r + 0.5) ** 2) <= r * r
    out[:, :, 3] = np.where(inside, 255, 0)
    return Image.fromarray(out, "RGBA")


def linear_gold(size):
    """Diagonal gold sheen tile used for rims and text."""
    stops = [(0.0, GOLD_LIGHT), (0.22, (242, 209, 122)), (0.48, GOLD),
             (0.70, (184, 146, 44)), (1.0, GOLD_DARK)]
    ys, xs = np.mgrid[0:size, 0:size]
    t = (xs / size * 0.5 + ys / size * 0.5)
    ps = np.array([p for p, _ in stops], dtype=float)
    cs = np.array([c for _, c in stops], dtype=float)
    out = np.zeros((size, size, 4), dtype=np.uint8)
    for ch in range(3):
        out[:, :, ch] = np.interp(t, ps, cs[:, ch]).astype(np.uint8)
    out[:, :, 3] = 255
    return Image.fromarray(out, "RGBA")


def spade(d, cx, cy, s, fill):
    """Spade pip centred at (cx, cy), s = half-height-ish scale."""
    pts = []
    # lobes via two circles + a triangle top
    d.pieslice([cx - s, cy - 0.30 * s, cx + 0.05 * s, cy + 0.75 * s], 0, 360, fill=fill)
    d.pieslice([cx - 0.05 * s, cy - 0.30 * s, cx + s, cy + 0.75 * s], 0, 360, fill=fill)
    d.polygon([(cx, cy - 1.05 * s), (cx - s, cy + 0.35 * s), (cx + s, cy + 0.35 * s)], fill=fill)
    # stem
    d.polygon([(cx - 0.42 * s, cy + 1.02 * s), (cx - 0.10 * s, cy + 0.35 * s),
               (cx + 0.10 * s, cy + 0.35 * s), (cx + 0.42 * s, cy + 1.02 * s)], fill=fill)


def club(d, cx, cy, s, fill):
    r = 0.46 * s
    d.ellipse([cx - r, cy - 1.05 * s, cx + r, cy - 1.05 * s + 2 * r], fill=fill)
    d.ellipse([cx - 1.02 * s, cy - 0.22 * s, cx - 1.02 * s + 2 * r, cy - 0.22 * s + 2 * r], fill=fill)
    d.ellipse([cx + 1.02 * s - 2 * r, cy - 0.22 * s, cx + 1.02 * s, cy - 0.22 * s + 2 * r], fill=fill)
    d.polygon([(cx - 0.40 * s, cy + 1.05 * s), (cx - 0.12 * s, cy + 0.25 * s),
               (cx + 0.12 * s, cy + 0.25 * s), (cx + 0.40 * s, cy + 1.05 * s)], fill=fill)


def rounded_card(size_px, w, h, radius):
    card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    cd.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=CARD,
                         outline=(185, 179, 162), width=max(2, size_px // 220))
    return card, cd


def circular_text(base, text, radius, font, fill_img, center, start_deg, end_deg, flip=False):
    """Draws text along an arc by rotating one glyph at a time."""
    cx, cy = center
    tmp_d = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    widths = [tmp_d.textlength(ch, font=font) for ch in text]
    total = sum(widths)
    # angular span each glyph occupies
    span = end_deg - start_deg
    arc_len = abs(span) / 360.0 * (2 * math.pi * radius)
    gap = (arc_len - total) / max(1, len(text) - 1) if len(text) > 1 else 0

    pos = 0.0
    for ch, w in zip(text, widths):
        centre_len = pos + w / 2.0
        frac = centre_len / arc_len if arc_len else 0
        ang = start_deg + span * frac

        # render glyph in gold
        gw, gh = int(w) + 8, font.size + 16
        glyph = Image.new("RGBA", (gw, gh), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glyph)
        gd.text((gw / 2, gh / 2), ch, font=font, fill=(255, 255, 255, 255), anchor="mm")
        tile = fill_img.resize((gw, gh))
        tile.putalpha(glyph.split()[3])
        glyph = tile

        rot = glyph.rotate(-(ang + (180 if flip else 0)), resample=Image.BICUBIC, expand=True)
        rad = math.radians(ang - 90)
        px = cx + radius * math.cos(rad)
        py = cy + radius * math.sin(rad)
        base.alpha_composite(rot, (int(px - rot.width / 2), int(py - rot.height / 2)))
        pos += w + gap


def build(size=512, with_bg=True, pad_ratio=0.0):
    S = size * SS
    img = Image.new("RGBA", (S, S), BG + (255,) if with_bg else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    C = S / 2.0
    R = (S / 2.0) * (1.0 - pad_ratio)
    gold_tile = linear_gold(S)

    def disc(r, fill):
        d.ellipse([C - r, C - r, C + r, C + r], fill=fill)

    def gold_disc(r):
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).ellipse([C - r, C - r, C + r, C + r], fill=255)
        img.paste(gold_tile, (0, 0), m)

    # outer gold rim
    gold_disc(R)
    disc(R * 0.968, (11, 26, 19, 255))

    # 8 edge spots -- inset so they read as chip inlays, never overflow the rim
    spot_mask = Image.new("L", (S, S), 0)
    for k in range(8):
        a = math.radians(k * 45)
        w, h = R * 0.190, R * 0.150
        rect = Image.new("L", (int(w * 2), int(h * 2)), 0)
        ImageDraw.Draw(rect).rounded_rectangle([0, 0, int(w * 2) - 1, int(h * 2) - 1],
                                               radius=int(min(w, h) * 0.55), fill=255)
        rr = rect.rotate(-math.degrees(a), resample=Image.BICUBIC, expand=True)
        px = C + (R * 0.905) * math.sin(a)
        py = C - (R * 0.905) * math.cos(a)
        spot_mask.paste(rr, (int(px - rr.width / 2), int(py - rr.height / 2)), rr)
    clip = Image.new("L", (S, S), 0)
    ImageDraw.Draw(clip).ellipse([C - R * 0.968, C - R * 0.968, C + R * 0.968, C + R * 0.968], fill=255)
    spot_mask = Image.fromarray(
        (np.asarray(spot_mask).astype(np.uint16) * np.asarray(clip) // 255).astype(np.uint8))
    img.paste(gold_tile, (0, 0), spot_mask)

    # felt disc
    felt = radial_disc(int(R * 2 * 0.862), [(0.0, FELT_LIGHT), (0.42, FELT),
                                            (0.78, (15, 83, 52)), (1.0, FELT_DARK)])
    img.alpha_composite(felt, (int(C - felt.width / 2), int(C - felt.height / 2)))

    # text band rings
    def ring(r, width, alpha=255):
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).ellipse([C - r, C - r, C + r, C + r], outline=alpha, width=int(width))
        img.paste(gold_tile, (0, 0), m)

    ring(R * 0.838, max(2, S / 210))
    ring(R * 0.676, max(2, S / 210))

    # circular brand text
    fsize = int(R * 0.108)
    font = ImageFont.truetype(SERIF_BOLD, fsize)
    tr = R * 0.757
    # Same sweeps as lib/widgets/poker_chip_logo.dart so the raster icon
    # and the in-app painted mark are identical.
    circular_text(img, "POKER", tr, font, gold_tile, (C, C), -52, 52)
    circular_text(img, "LEDGER", tr, font, gold_tile, (C, C), 236, 124, flip=True)

    # side diamonds
    dm = Image.new("L", (S, S), 0)
    dd = ImageDraw.Draw(dm)
    for sx in (-1, 1):
        cx2 = C + sx * R * 0.757
        s2 = R * 0.052
        dd.polygon([(cx2, C - s2), (cx2 + s2 * 0.72, C), (cx2, C + s2), (cx2 - s2 * 0.72, C)], fill=255)
    img.paste(gold_tile, (0, 0), dm)

    # centre medallion
    inner = radial_disc(int(R * 2 * 0.652), [(0.0, INNER_FELT), (1.0, INNER_FELT_DARK)])
    img.alpha_composite(inner, (int(C - inner.width / 2), int(C - inner.height / 2)))
    ring(R * 0.652, max(3, S / 105))
    ring(R * 0.604, max(2, S / 300))

    # ---- crossed cards: King of Clubs behind-right, Ace of Spades front-left ----
    cw, ch = int(R * 0.430), int(R * 0.625)
    rad = int(cw * 0.13)

    # King of Clubs (behind, fanned right)
    k_card, kd = rounded_card(S, cw, ch, rad)
    kf = ImageFont.truetype(SERIF_BOLD, int(ch * 0.185))
    kd.text((cw * 0.13, ch * 0.05), "K", font=kf, fill=INK)
    club(kd, cw * 0.225, ch * 0.295, ch * 0.050, INK)
    club(kd, cw * 0.56, ch * 0.615, ch * 0.150, INK)
    kr = k_card.rotate(-19, resample=Image.BICUBIC, expand=True)
    img.alpha_composite(kr, (int(C + R * 0.150 - kr.width / 2),
                             int(C + R * 0.030 - kr.height / 2)))

    # Ace of Spades (front, fanned left)
    a_card, ad = rounded_card(S, cw, ch, rad)
    af = ImageFont.truetype(SERIF_BOLD, int(ch * 0.185))
    ad.text((cw * 0.13, ch * 0.05), "A", font=af, fill=INK)
    spade(ad, cw * 0.225, ch * 0.295, ch * 0.048, INK)
    spade(ad, cw * 0.50, ch * 0.615, ch * 0.165, INK)
    ar = a_card.rotate(19, resample=Image.BICUBIC, expand=True)
    img.alpha_composite(ar, (int(C - R * 0.150 - ar.width / 2),
                             int(C + R * 0.030 - ar.height / 2)))

    return img.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build(1024, with_bg=True).save(os.path.join(OUT, "app_icon.png"))
    build(1024, with_bg=False, pad_ratio=0.22).save(os.path.join(OUT, "app_icon_foreground.png"))
    build(1024, with_bg=False).save(os.path.join(OUT, "logo.png"))
    print("wrote app_icon.png, app_icon_foreground.png, logo.png")
