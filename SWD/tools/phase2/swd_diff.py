"""Offline image diffing for the SWD automation probes (T5, T13, T14).

Reads PNG window captures written by ``Save-SwdWindowImage``; never touches SWD.
Uses only numpy, Pillow and scipy (installed on both Pythons here).

Usage::

    python swd_diff.py                       # self-check
    python swd_diff.py idle <dir>            # T5: noise over consecutive frames
    python swd_diff.py pair <before> <after> [--mask m.npy] [--expect x,y,w,h ...]

Coordinates are pixels of the captured bitmap, origin top-left.
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

TILE = 32


def load(path):
    """Greyscale float32 array of a PNG."""
    return np.asarray(Image.open(path).convert("L"), dtype=np.float32)


def tile_changes(a, b, tile=TILE):
    """Boolean (rows, cols) grid: True where any pixel in the tile differs."""
    d = a != b
    h, w = d.shape
    r, c = -(-h // tile), -(-w // tile)
    pad = np.zeros((r * tile, c * tile), bool)
    pad[:h, :w] = d
    return pad.reshape(r, tile, c, tile).any(axis=(1, 3))


def ssim_map(a, b, win=7, L=255.0):
    """Per-pixel SSIM (Wang et al. 2004) with a uniform window."""
    c1, c2 = (0.01 * L) ** 2, (0.03 * L) ** 2
    f = lambda x: ndimage.uniform_filter(x, win)
    ma, mb = f(a), f(b)
    va, vb, cov = f(a * a) - ma * ma, f(b * b) - mb * mb, f(a * b) - ma * mb
    return ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))


def boxes(mask):
    """Bounding boxes (x, y, w, h) of connected True regions."""
    lab, _ = ndimage.label(mask)
    return [(s[1].start, s[0].start, s[1].stop - s[1].start, s[0].stop - s[0].start)
            for s in ndimage.find_objects(lab) if s is not None]


def tiles_to_pixels(tmask, shape, tile=TILE):
    """Expand a tile grid to a pixel mask of ``shape``."""
    return np.kron(tmask, np.ones((tile, tile), bool))[:shape[0], :shape[1]]


def overlaps(box, rect):
    x, y, w, h = box
    rx, ry, rw, rh = rect
    return x < rx + rw and rx < x + w and y < ry + rh and ry < y + h


def classify(a, b, noise=None, expected=()):
    """Changed regions of a -> b, minus noise tiles, split in/out of the expected rects."""
    t = tile_changes(a, b)
    if noise is not None:
        t &= ~noise
    bx = boxes(tiles_to_pixels(t, a.shape))
    inside = [x for x in bx if any(overlaps(x, r) for r in expected)]
    return {"changed_tiles": int(t.sum()), "in_scope": inside,
            "out_of_scope": [x for x in bx if x not in inside],
            "missing_expected": [r for r in expected if not any(overlaps(x, r) for x in bx)]}


def idle(frames_dir):
    """T5: how often each method flags change between consecutive idle frames."""
    files = sorted(Path(frames_dir).glob("*.png"))
    frames = [load(f) for f in files]
    noise = np.zeros_like(tile_changes(frames[0], frames[0]))
    t_tile = t_ssim = 0.0
    fp_tile = fp_ssim = 0
    for a, b in zip(frames, frames[1:]):
        s = time.perf_counter(); t = tile_changes(a, b); t_tile += time.perf_counter() - s
        s = time.perf_counter(); m = ssim_map(a, b) < 0.99; t_ssim += time.perf_counter() - s
        noise |= t
        fp_tile += bool(t.any())
        fp_ssim += bool(m.any())
    n = max(len(frames) - 1, 1)
    np.save(Path(frames_dir) / "noise_mask.npy", noise)
    return {"frames": len(frames), "pairs": n,
            "pairs_flagged_tile": fp_tile, "pairs_flagged_ssim_lt_0.99": fp_ssim,
            "noise_tiles": int(noise.sum()), "noise_boxes": boxes(tiles_to_pixels(noise, frames[0].shape)),
            "ms_per_pair_tile": round(1000 * t_tile / n, 2), "ms_per_pair_ssim": round(1000 * t_ssim / n, 2)}


def _selfcheck():
    a = np.zeros((200, 300), np.float32)
    b = a.copy(); b[150:170, 250:280] = 255          # distant change
    c = a.copy(); c[10:20, 10:20] = 255              # change inside the expected rect
    r = classify(a, b, expected=[(0, 0, 64, 64)])
    assert r["out_of_scope"] and not r["in_scope"] and r["missing_expected"] == [(0, 0, 64, 64)], r
    r = classify(a, c, expected=[(0, 0, 64, 64)])
    assert r["in_scope"] and not r["out_of_scope"] and not r["missing_expected"], r
    noise = tile_changes(a, b)                       # masking the distant tiles hides the change
    assert classify(a, b, noise=noise)["changed_tiles"] == 0
    assert np.allclose(ssim_map(a + 7, a + 7), 1.0)
    assert boxes(np.zeros((5, 5), bool)) == []
    print("swd_diff self-check OK")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        _selfcheck()
    elif args[0] == "idle":
        print(json.dumps(idle(args[1]), indent=1))
    elif args[0] == "pair":
        noise = np.load(args[args.index("--mask") + 1]) if "--mask" in args else None
        exp = [tuple(map(int, s.split(","))) for s in args[args.index("--expect") + 1:]] if "--expect" in args else []
        print(json.dumps(classify(load(args[1]), load(args[2]), noise, exp), indent=1))
    else:
        sys.exit(__doc__)
