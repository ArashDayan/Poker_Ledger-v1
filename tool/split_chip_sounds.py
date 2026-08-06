#!/usr/bin/env python3
"""Cuts the supplied chip recording into selectable UI sound variations.

The banker's master recording (assets/sounds/Chip_sound.wav) is a single
41-second take containing several different chip gestures performed one
after another with pauses between them.

This finds those pauses automatically and cuts at them, then picks a
spread of genuinely DIFFERENT gestures (not six near-identical drops) to
ship as selectable options in Settings.

Silence detection
-----------------
1. Build a 30 ms moving-average amplitude envelope of the mono sum.
2. Measure the true noise floor from the quietest half-second in the
   file and derive the open/close thresholds from it, so this keeps
   working if the master is ever re-recorded at a different level.
3. Walk the envelope with hysteresis (a high threshold to open a region,
   a much lower one to close it). This matters: a single threshold
   chatters during the quiet tail of a pour and shatters one gesture
   into a dozen fragments.
4. Merge regions separated by less than MERGE_GAP — the tiny gaps
   *inside* one pour are not gesture boundaries.
5. Drop anything too short to be a real gesture.

Each exported sample is trimmed to its onset, given short fades so it
can never click, and peak-normalised. No synthesis, no EQ, no layering —
these are the banker's own chips, just isolated.

Usage:  python3 tool/split_chip_sounds.py
"""
import json
import os
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SOUNDS = os.path.join(HERE, "..", "assets", "sounds")
SRC = os.path.join(SOUNDS, "Chip_sound.wav")

ENVELOPE_MS = 30
OPEN_FLOOR_MULT = 22
CLOSE_FLOOR_MULT = 6
MIN_OPEN = 0.0045
MIN_CLOSE = 0.0015
MERGE_GAP = 0.25
MIN_DURATION = 0.12
LEAD_IN = 0.006
TAIL_PAD = 0.045
FADE_IN = 0.002
FADE_OUT = 0.030
TARGET_PEAK = 0.92


def load(path):
    with wave.open(path) as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    raw = raw.astype(float) / 32768.0
    if ch == 2:
        return sr, raw[0::2], raw[1::2]
    return sr, raw, raw


def detect_regions(mono, sr):
    win = max(1, int(ENVELOPE_MS / 1000 * sr))
    env = np.convolve(np.abs(mono), np.ones(win) / win, "same")

    block = int(0.5 * sr)
    blocks = [
        np.sqrt((mono[i:i + block] ** 2).mean())
        for i in range(0, len(mono) - block, block)
    ]
    floor = min(blocks) if blocks else 0.0
    open_thr = max(MIN_OPEN, floor * OPEN_FLOOR_MULT)
    close_thr = max(MIN_CLOSE, floor * CLOSE_FLOOR_MULT)

    regions, inside, start = [], False, 0
    for i, v in enumerate(env):
        if not inside and v > open_thr:
            inside, start = True, i
        elif inside and v < close_thr:
            inside = False
            regions.append([start, i])
    if inside:
        regions.append([start, len(env)])

    merged, gap = [], int(MERGE_GAP * sr)
    for s, e in regions:
        if merged and s - merged[-1][1] < gap:
            merged[-1][1] = e
        else:
            merged.append([s, e])

    return [(s, e) for s, e in merged if (e - s) / sr >= MIN_DURATION], floor


def describe(mono, sr, s, e):
    seg = mono[s:e]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    freqs = np.fft.rfftfreq(len(seg), 1 / sr)
    fast = max(1, int(0.005 * sr))
    e2 = np.convolve(np.abs(seg), np.ones(fast) / fast, "same")
    hits, i = 0, 0
    while i < len(e2):
        if e2[i] > 0.02:
            hits += 1
            i += int(0.04 * sr)
        else:
            i += 1
    return {
        "duration": (e - s) / sr,
        "peak": float(np.abs(seg).max()),
        "rms": float(np.sqrt((seg ** 2).mean())),
        "centroid": float((spec * freqs).sum() / max(spec.sum(), 1e-9)),
        "hits": hits,
    }


def export(left, right, sr, s, e, path):
    a = max(0, s - int(LEAD_IN * sr))
    b = min(len(left), e + int(TAIL_PAD * sr))
    l, r = left[a:b].copy(), right[a:b].copy()

    fi = min(int(FADE_IN * sr), len(l) // 4)
    fo = min(int(FADE_OUT * sr), len(l) // 3)
    for seg in (l, r):
        if fi:
            seg[:fi] *= np.linspace(0, 1, fi)
        if fo:
            seg[-fo:] *= np.linspace(1, 0, fo)

    peak = max(np.abs(l).max(), np.abs(r).max())
    if peak > 0:
        g = TARGET_PEAK / peak
        l *= g
        r *= g

    out = np.empty(len(l) * 2, dtype=np.int16)
    out[0::2] = (np.clip(l, -1, 1) * 32767).astype(np.int16)
    out[1::2] = (np.clip(r, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as o:
        o.setnchannels(2)
        o.setsampwidth(2)
        o.setframerate(sr)
        o.writeframes(out.tobytes())
    return len(l) / sr


def pick(regions, stats):
    """Choose a spread of genuinely different gestures.

    Sorting purely by "best" would return six almost identical single
    drops. Bucketing by character first means the options a banker sees
    in Settings actually sound different from one another.
    """
    idx = list(range(len(regions)))

    def score(i):
        return stats[i]["peak"] * 0.6 + min(stats[i]["rms"] * 4, 0.4)

    buckets = {
        "long_pour": [i for i in idx if stats[i]["duration"] >= 0.75],
        "medium_pour": [i for i in idx if 0.45 <= stats[i]["duration"] < 0.75],
        "riffle": [i for i in idx
                   if 0.28 <= stats[i]["duration"] < 0.45 and stats[i]["hits"] >= 5],
        "drop": [i for i in idx
                 if 0.20 <= stats[i]["duration"] < 0.32 and stats[i]["hits"] <= 5],
        "click": [i for i in idx if stats[i]["duration"] < 0.24],
    }

    chosen, used = [], set()
    for members in buckets.values():
        members = [i for i in members if i not in used]
        if not members:
            continue
        best = max(members, key=score)
        used.add(best)
        chosen.append(best)

    spare = sorted((i for i in idx if i not in used), key=score, reverse=True)
    while len(chosen) < 6 and spare:
        chosen.append(spare.pop(0))
    return chosen[:6]


def label_for(st):
    """Names a sample from what it actually SOUNDS like, measured, so the
    name in Settings always matches the sound."""
    d, hits = st["duration"], st["hits"]
    if d >= 0.75 or hits >= 12:
        return "Chip Pour", "A long cascade of chips onto the felt"
    if d >= 0.55 or hits >= 8:
        return "Chip Cascade", "A shorter pour, chips settling"
    if d >= 0.38:
        return "Chip Riffle", "Chips riffled and stacked"
    if d >= 0.28:
        return "Chip Drop", "A handful of chips dropped"
    return "Single Chip", "One clean chip set down"


def main():
    sr, left, right = load(SRC)
    mono = (left + right) / 2
    regions, floor = detect_regions(mono, sr)
    stats = [describe(mono, sr, s, e) for s, e in regions]

    print(f"source: {len(mono)/sr:.2f}s @ {sr} Hz, noise floor {floor:.6f}")
    print(f"detected {len(regions)} gestures between silences")

    chosen = pick(regions, stats)
    # Shortest first: the snappy ones are what most bankers want under a
    # tap, so they head the list in Settings.
    chosen.sort(key=lambda i: stats[i]["duration"])

    manifest, used_titles = [], {}
    print(f"\nexporting {len(chosen)} variations:")
    for n, i in enumerate(chosen, start=1):
        s, e = regions[i]
        fname = f"chip_{n}.wav"
        dur = export(left, right, sr, s, e, os.path.join(SOUNDS, fname))
        title, desc = label_for(stats[i])
        # Unique names — two options both called "Chip Drop" would be
        # impossible to choose between.
        if title in used_titles:
            used_titles[title] += 1
            title = f"{title} {used_titles[title]}"
        else:
            used_titles[title] = 1
        manifest.append({
            "file": fname, "title": title, "description": desc,
            "duration": round(dur, 3),
            "source_start": round(s / sr, 3),
        })
        print(f"  {fname}  {title:<14} {dur:.3f}s  (from {s/sr:.2f}s)")

    with open(os.path.join(SOUNDS, "chip_samples.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("\nwrote chip_samples.json")
    print("Update kChipSamples in lib/services/sound_service.dart to match.")


if __name__ == "__main__":
    main()
