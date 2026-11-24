#!/usr/bin/env python3
"""Build a seamless 256×256 tile from ONLY the colon albedo / normal maps.

The source atlases are unwrapped colon islands on a beige background. An earlier
fixed crop mixed that background (and looked like a colour mash-up). This script
masks the colon flesh, tightly crops the largest island, inpaints leftover
background with neighbouring flesh, then wraps the edges. It never samples
small-intestine or any other organ texture.
"""
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
SIZE = 256
OVERLAP = 40


def _bg_color(arr: np.ndarray) -> np.ndarray:
    h, w = arr.shape[:2]
    corners = np.concatenate(
        [
            arr[0:8, 0:8].reshape(-1, 3),
            arr[0:8, w - 8 : w].reshape(-1, 3),
            arr[h - 8 : h, 0:8].reshape(-1, 3),
            arr[h - 8 : h, w - 8 : w].reshape(-1, 3),
        ],
        axis=0,
    )
    return np.median(corners, axis=0)


def _flesh_mask(arr: np.ndarray) -> np.ndarray:
    bg = _bg_color(arr)
    dist = np.linalg.norm(arr.astype(np.float32) - bg[None, None, :], axis=2)
    # Flesh is clearly darker / redder than the flat beige paper.
    mask = dist > 18.0
    # Drop isolated specks.
    # 4-connected dilate/erode once
    m = mask.copy()
    for _ in range(2):
        p = np.pad(m, 1, mode="edge")
        nb = (
            p[0:-2, 1:-1]
            | p[2:, 1:-1]
            | p[1:-1, 0:-2]
            | p[1:-1, 2:]
        )
        m = m | (nb & mask)
    for _ in range(2):
        p = np.pad(m, 1, mode="edge")
        nb = (
            p[0:-2, 1:-1]
            & p[2:, 1:-1]
            & p[1:-1, 0:-2]
            & p[1:-1, 2:]
        )
        m = m & nb
    return m


def _components(mask: np.ndarray):
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=np.uint8)
    comps = []
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or seen[y, x]:
                continue
            stack = [(y, x)]
            seen[y, x] = 1
            ys = [y]
            xs = [x]
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    ny, nx = cy + dy, cx + dx
                    if ny < 0 or nx < 0 or ny >= h or nx >= w:
                        continue
                    if mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = 1
                        stack.append((ny, nx))
                        ys.append(ny)
                        xs.append(nx)
            comps.append((len(ys), min(ys), max(ys), min(xs), max(xs)))
    comps.sort(reverse=True)
    return comps


def _inpaint(arr: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Fill background pixels with the nearest flesh colour (no beige left)."""
    out = arr.copy()
    if mask.all():
        return out
    # Repeated dilation average, then a nearest-neighbour fallback.
    m = mask.copy()
    cur = arr.astype(np.float32)
    for _ in range(64):
        if m.all():
            break
        p = np.pad(m, 1, mode="edge")
        cpad = np.pad(cur, ((1, 1), (1, 1), (0, 0)), mode="edge")
        acc = np.zeros_like(cur)
        w = np.zeros(m.shape, dtype=np.float32)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            wm = p[1 + dy : 1 + dy + m.shape[0], 1 + dx : 1 + dx + m.shape[1]]
            acc += cpad[1 + dy : 1 + dy + m.shape[0], 1 + dx : 1 + dx + m.shape[1]] * wm[..., None]
            w += wm.astype(np.float32)
        grow = (~m) & (w > 0)
        if not grow.any():
            break
        cur[grow] = acc[grow] / w[grow, None]
        m[grow] = True
    out[~mask] = np.clip(cur[~mask], 0, 255).astype(arr.dtype)
    return out


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



def _solid_patches(arr: np.ndarray, mask: np.ndarray, size: int = 64) -> list:
    """Axis-aligned windows that lie entirely on colon flesh."""
    h, w = mask.shape
    out = []
    step = max(8, size // 4)
    for y in range(0, h - size + 1, step):
        for x in range(0, w - size + 1, step):
            if mask[y : y + size, x : x + size].all():
                out.append((x, y))
    return out


def _quilt(arr: np.ndarray, mask: np.ndarray, out_size: int = 256, patch: int = 64, overlap: int = 16) -> np.ndarray:
    locs = _solid_patches(arr, mask, patch)
    if len(locs) < 8:
        # fallback: slightly smaller patches
        patch = 48
        overlap = 12
        locs = _solid_patches(arr, mask, patch)
    if len(locs) < 4:
        raise SystemExit("not enough solid colon-flesh patches to quilt a tile")
    patches = [arr[y : y + patch, x : x + patch].astype(np.float32) for x, y in locs]
    rng = np.random.default_rng(7)
    stride = patch - overlap
    n = 1 + int(np.ceil((out_size - patch) / float(stride)))
    canvas = np.zeros((stride * (n - 1) + patch, stride * (n - 1) + patch, 3), dtype=np.float32)
    weight = np.zeros(canvas.shape[:2], dtype=np.float32)
    # Raised-cosine overlap weights
    wy = np.ones(patch, dtype=np.float32)
    wx = np.ones(patch, dtype=np.float32)
    if overlap > 0:
        ramp = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, overlap, dtype=np.float32))
        wy[:overlap] = ramp
        wy[-overlap:] = ramp[::-1]
        wx[:overlap] = ramp
        wx[-overlap:] = ramp[::-1]
    ww = wy[:, None] * wx[None, :]

    def pick(target, tw):
        # target: (patch,patch,3) or None; tw mask of already-filled overlap
        if target is None:
            return patches[int(rng.integers(0, len(patches)))]
        best = None
        best_e = 1e18
        # try a subset for speed
        idx = rng.choice(len(patches), size=min(len(patches), 48), replace=False)
        for i in idx:
            p = patches[i]
            m = tw > 0.05
            if not m.any():
                return p
            e = float(((p - target)[m] ** 2).mean())
            if e < best_e:
                best_e = e
                best = p
        return best if best is not None else patches[0]

    for iy in range(n):
        for ix in range(n):
            y = iy * stride
            x = ix * stride
            region = canvas[y : y + patch, x : x + patch]
            tw = weight[y : y + patch, x : x + patch]
            source = pick(region if tw.any() else None, tw)
            w = ww.copy()
            canvas[y : y + patch, x : x + patch] += source * w[..., None]
            weight[y : y + patch, x : x + patch] += w
    weight = np.maximum(weight, 1e-6)
    canvas = canvas / weight[..., None]
    canvas = canvas[:out_size, :out_size]
    return np.clip(canvas, 0, 255).astype(np.uint8)


def _quilt_normal(nrm: np.ndarray, mask: np.ndarray, out_size: int = 256, patch: int = 64, overlap: int = 16) -> np.ndarray:
    # Same placement as albedo would differ; just quilt independently from flesh windows.
    return _quilt(nrm, mask, out_size, patch, overlap)


def build() -> None:
    alb = np.asarray(Image.open(SRC_A).convert("RGB"))
    nrm = np.asarray(Image.open(SRC_N).convert("RGB"))
    if alb.shape != nrm.shape:
        raise SystemExit("colon albedo / normal size mismatch")
    mask = _flesh_mask(alb)
    flesh_mean = alb[mask].mean(axis=0)
    bg = _bg_color(alb)
    tile_a = _quilt(alb, mask, SIZE, 64, 16)
    tile_n = _quilt_normal(nrm, mask, SIZE, 64, 16)
    aa = make_seamless(tile_a, overlap=OVERLAP)
    # Keep the average on the colon flesh; never drift toward the beige paper.
    aa = aa - aa.mean(axis=(0, 1)) + flesh_mean
    aa = _force_wrap(np.clip(aa, 0, 255).astype(np.uint8))
    Image.fromarray(aa).save(OUT_A)

    nn = make_seamless(tile_n, overlap=OVERLAP)
    f = nn / 255.0 * 2.0 - 1.0
    norm = np.maximum(np.linalg.norm(f, axis=2, keepdims=True), 1e-6)
    f = f / norm
    nn = _force_wrap(np.clip((f * 0.5 + 0.5) * 255.0, 0, 255).astype(np.uint8))
    Image.fromarray(nn).save(OUT_N)

    tile = np.asarray(Image.open(OUT_A))
    # Sanity: tile stays close to flesh, far from the atlas background.
    tmean = tile.mean(axis=(0, 1))
    d_flesh = float(np.linalg.norm(tmean - flesh_mean))
    d_bg = float(np.linalg.norm(tmean - bg))
    if d_flesh > 12.0 or d_bg < d_flesh:
        raise SystemExit(f"tile colour drifted (d_flesh={d_flesh:.1f} d_bg={d_bg:.1f} mean={tmean})")
    print(
        "wrote",
        OUT_A,
        "and",
        OUT_N,
        "patches",
        len(_solid_patches(alb, mask, 64)),
        "tile_mean",
        [round(float(x), 1) for x in tmean],
        "flesh_mean",
        [round(float(x), 1) for x in flesh_mean],
        "bg_mean",
        [round(float(x), 1) for x in bg],
        "d_flesh",
        round(d_flesh, 2),
        "d_bg",
        round(d_bg, 2),
    )


if __name__ == "__main__":
    sys.exit(build() or 0)
