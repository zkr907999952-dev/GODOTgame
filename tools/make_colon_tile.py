#!/usr/bin/env python3
"""Build a seamless 256×256 tile from the source colon albedo / normal maps."""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_A = os.path.join(ROOT, "assets/organs/colon_albedo.jpg")
SRC_N = os.path.join(ROOT, "assets/organs/colon_normal.jpg")
OUT_A = os.path.join(ROOT, "assets/organs/colon_tile_albedo.png")
OUT_N = os.path.join(ROOT, "assets/organs/colon_tile_normal.png")
CROP = (0, 448, 512, 960)
SIZE = 256
OVERLAP = 48


def _blend_axis(a: np.ndarray, axis: int, ov: int) -> np.ndarray:
    n = a.shape[axis]
    rolled = np.roll(a, n // 2, axis=axis)
    coord = np.minimum(np.arange(n), n - 1 - np.arange(n)).astype(np.float32)
    w = np.clip(coord / float(ov), 0.0, 1.0)
    w = 0.5 - 0.5 * np.cos(w * np.pi)
    if axis == 0:
        w = w[:, None, None]
    else:
        w = w[None, :, None]
    return a * w + rolled * (1.0 - w)


def make_seamless(arr: np.ndarray, overlap: int = OVERLAP) -> np.ndarray:
    a = arr.astype(np.float32)
    a = _blend_axis(a, 1, overlap)
    a = _blend_axis(a, 0, overlap)
    return a


def _force_wrap(a: np.ndarray) -> np.ndarray:
    a = a.copy()
    a[:, -1] = a[:, 0]
    a[-1] = a[0]
    return a


def build() -> None:
    tile_a = Image.open(SRC_A).convert("RGB").crop(CROP).resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    tile_n = Image.open(SRC_N).convert("RGB").crop(CROP).resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    aa = make_seamless(np.asarray(tile_a))
    mean0 = np.asarray(tile_a).astype(np.float32).mean()
    aa = (aa - aa.mean()) * 1.08 + mean0
    aa = _force_wrap(np.clip(aa, 0, 255).astype(np.uint8))
    Image.fromarray(aa).save(OUT_A)

    nn = make_seamless(np.asarray(tile_n))
    f = nn / 255.0 * 2.0 - 1.0
    norm = np.maximum(np.linalg.norm(f, axis=2, keepdims=True), 1e-6)
    f = f / norm
    nn = _force_wrap(np.clip((f * 0.5 + 0.5) * 255.0, 0, 255).astype(np.uint8))
    Image.fromarray(nn).save(OUT_N)
    print("wrote", OUT_A, "and", OUT_N)


if __name__ == "__main__":
    sys.exit(build() or 0)
