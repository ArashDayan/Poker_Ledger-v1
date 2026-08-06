#!/usr/bin/env python3
"""Installs the supplied brand logo into every place the app uses it.

Drop the designed logo anywhere and point this at it:

    python3 tool/install_logo.py path/to/logo.png

It produces, from that one file:

  assets/images/logo.png             - the in-app mark (transparent,
                                       square, trimmed to the chip)
  assets/images/app_icon.png         - launcher icon source (opaque,
                                       dark felt background)
  assets/images/app_icon_foreground.png
                                     - Android adaptive foreground, with
                                       the safe-zone padding Android
                                       requires so the launcher's mask
                                       cannot crop the chip

Why processing is needed rather than copying the file in:

* The supplied artwork is a photographic render on a dark background.
  Left as-is the app would show a dark rectangle behind the chip on
  every screen, including the poker-table centre where it must sit on
  green felt. This removes that background and keeps only the chip.
* Android adaptive icons crop to a circle/squircle. Without the safe
  zone the gold rim gets shaved off on many launchers.

Run again whenever the brand asset changes.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "images")

# Dark felt used behind the opaque launcher icon — matches AppColors.background.
ICON_BG = (11, 18, 16, 255)


def load(path):
    img = Image.open(path).convert("RGBA")
    return img


def _largest_component(mask):
    """Returns a mask containing only the largest connected blob.

    The backdrop in a photographic render is speckled/textured, so a pure
    brightness test leaves hundreds of stray bright dots scattered around
    the chip. Those specks are individually tiny but they wreck the
    bounding-box crop (the art never tightens onto the chip) and show up
    as dirt on transparent backgrounds. Keeping only the biggest blob
    keeps the chip and discards every speck, with no tuning needed.

    Iterative label propagation — no scipy dependency.
    """
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    labels[mask] = np.arange(1, mask.sum() + 1)

    # Propagate the maximum label through neighbours until stable. Each
    # pass is vectorised, so this converges quickly even on large images.
    while True:
        prev = labels
        cur = labels.copy()
        cur[1:, :] = np.maximum(cur[1:, :], labels[:-1, :])
        cur[:-1, :] = np.maximum(cur[:-1, :], labels[1:, :])
        cur[:, 1:] = np.maximum(cur[:, 1:], labels[:, :-1])
        cur[:, :-1] = np.maximum(cur[:, :-1], labels[:, 1:])
        cur[~mask] = 0
        if np.array_equal(cur, prev):
            break
        labels = cur

    ids, counts = np.unique(labels[labels > 0], return_counts=True)
    if len(ids) == 0:
        return mask
    return labels == ids[np.argmax(counts)]


def _fill_holes(mask):
    """Fills enclosed dark areas so detail inside the chip stays opaque.

    The chip's own green inlays and the dark card pips are darker than
    the brightness threshold. Without this they would be punched out as
    transparent holes in the middle of the logo. Anything reachable from
    the image border stays background; everything else is chip.
    """
    h, w = mask.shape
    outside = np.zeros((h, w), dtype=bool)
    free = ~mask
    outside[0, :] = free[0, :]
    outside[-1, :] = free[-1, :]
    outside[:, 0] = free[:, 0]
    outside[:, -1] = free[:, -1]

    while True:
        prev = outside.sum()
        grown = outside.copy()
        grown[1:, :] |= outside[:-1, :]
        grown[:-1, :] |= outside[1:, :]
        grown[:, 1:] |= outside[:, :-1]
        grown[:, :-1] |= outside[:, 1:]
        outside = grown & free
        if outside.sum() == prev:
            break
    return ~outside


def isolate_chip(img):
    """Crops to the chip and makes the surrounding backdrop transparent.

    The chip is a bright object on a dark backdrop, so luminance
    separates them. Three steps make that robust against a textured
    backdrop and against dark detail inside the chip itself:

      1. threshold on brightness, learned from the image's own corners
         (so it adapts to however the artwork was rendered),
      2. keep only the largest connected blob — discards backdrop speckle
         that would otherwise survive as dirt and block the crop,
      3. fill enclosed holes — keeps the green inlays and card pips
         opaque instead of punching them out.
    """
    a = np.array(img)
    rgb = a[:, :, :3].astype(float)
    lum = rgb.max(axis=2)

    h, w = lum.shape
    corner = np.concatenate([
        lum[:h // 12, :w // 12].ravel(),
        lum[:h // 12, -w // 12:].ravel(),
        lum[-h // 12:, :w // 12].ravel(),
        lum[-h // 12:, -w // 12:].ravel(),
    ])
    bg_level = float(np.percentile(corner, 90))
    thresh = max(bg_level + 25, 70)

    chip = lum > thresh
    chip = _largest_component(chip)
    chip = _fill_holes(chip)

    alpha = np.where(chip, 255, 0).astype(np.uint8)
    out = a.copy()
    out[:, :, 3] = alpha
    result = Image.fromarray(out, "RGBA")

    # Feather the cut edge by ~1px so the rim isn't sawtoothed.
    result.putalpha(result.split()[3].filter(ImageFilter.GaussianBlur(0.8)))

    # Trim to the chip, then pad back to a square so the mark is centred
    # and never distorted by a non-square canvas.
    bbox = result.split()[3].getbbox()
    if bbox:
        result = result.crop(bbox)
    side = max(result.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(result,
                 ((side - result.width) // 2, (side - result.height) // 2),
                 result)
    return square


def save_resized(img, path, size, background=None, pad_ratio=0.0):
    canvas_size = size
    inner = int(round(size * (1.0 - 2 * pad_ratio)))
    scaled = img.resize((inner, inner), Image.LANCZOS)

    if background is None:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    else:
        canvas = Image.new("RGBA", (canvas_size, canvas_size), background)

    off = (canvas_size - inner) // 2
    canvas.paste(scaled, (off, off), scaled)
    canvas.save(path, optimize=True)
    print(f"  wrote {os.path.basename(path):32s} {canvas_size}x{canvas_size}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    src = sys.argv[1]
    if not os.path.exists(src):
        print(f"error: {src} not found")
        sys.exit(1)

    os.makedirs(OUT, exist_ok=True)
    print(f"source: {src}")
    chip = isolate_chip(load(src))
    print(f"isolated chip: {chip.size[0]}x{chip.size[1]} (transparent background)")

    # In-app mark, used everywhere on screen (home hero, AppBar, splash,
    # table centre). 768px is ample: the largest on-screen use is ~210
    # logical px, which is ~630px even at a 3x device pixel ratio.
    save_resized(chip, os.path.join(OUT, "logo.png"), 768)

    # Launcher icon: opaque dark background, slight inset. Stays 1024
    # because the stores require it.
    save_resized(chip, os.path.join(OUT, "app_icon.png"), 1024,
                 background=ICON_BG, pad_ratio=0.04)

    # Adaptive foreground: Android masks to a circle/squircle, so the
    # mark needs a generous safe zone or the rim gets cropped.
    save_resized(chip, os.path.join(OUT, "app_icon_foreground.png"), 1024,
                 pad_ratio=0.22)

    print("done — run `dart run flutter_launcher_icons` to rebuild "
          "platform icons.")


if __name__ == "__main__":
    main()
