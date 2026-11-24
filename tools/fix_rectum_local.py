#!/usr/bin/env python3
"""Conservatively fix only the distal rectum of the large-intestine mesh.

Does not move or uniformly scale the intestines, and does not touch the
small intestine or the second (poorly parameterized) colon mesh. Outlier
radii on the distal segment are pulled back toward a plausible rectum
radius, the centerline is eased slightly posterior so it no longer sits
inside the vaginal wall, and the geometric tip is eased toward the anus.
"""
from __future__ import annotations

import gzip
import shutil
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "assets/organs/organs_mesh.bin"
BACKUP = ROOT / "assets/organs/organs_mesh.pre_rectum.bin"
ANUS = np.array([0.0, 0.8969, -0.0021], dtype=np.float64)
# Only edit the well-parameterized colon (the rectum lives on this mesh).
TARGET_NAME = "Tjocktarm_Default Material_0"
ALONG0 = 0.88
# Target radii (metres).
R_FAT = 0.012
R_END = 0.008
R_CLAMP = 0.018
# Posterior safe plane for the rectum center, behind the vaginal wall (z~0.028).
Z_SAFE = 0.000
# Just inside the anus (a few mm superior / slightly anterior).
TARGET_END = ANUS + np.array([0.0, 0.006, 0.000])


def _read_str(buf: bytes, off: int):
    n = struct.unpack_from("<H", buf, off)[0]
    return buf[off + 2 : off + 2 + n].decode("utf-8"), off + 2 + n


def load_pack(path: Path):
    raw = path.read_bytes()
    if raw[:4] != b"ORGN":
        raw = gzip.decompress(raw)
    if raw[:4] != b"ORGN":
        raise SystemExit("not an ORGN pack")
    off = 8
    nb = struct.unpack_from("<I", raw, off)[0]
    off += 4
    for _ in range(nb):
        _, off = _read_str(raw, off)
    mc = struct.unpack_from("<I", raw, off)[0]
    off += 4
    meshes = []
    for _ in range(mc):
        mname, off = _read_str(raw, off)
        mat, off = _read_str(raw, off)
        group = raw[off]
        tex = struct.unpack_from("b", raw, off + 1)[0]
        off += 2
        off += 16
        vc, ic = struct.unpack_from("<II", raw, off)
        off += 8
        pos_off = off
        pos = np.frombuffer(raw, dtype="<f4", count=vc * 3, offset=off).reshape(-1, 3).copy()
        off += vc * 12
        nrm_off = off
        nrm = np.frombuffer(raw, dtype="<f4", count=vc * 3, offset=off).reshape(-1, 3).copy()
        off += vc * 12
        off += vc * 16
        off += vc * 8
        off += vc * 4
        off += vc * 16
        cust_off = off
        cust = np.frombuffer(raw, dtype="<f4", count=vc * 4, offset=off).reshape(-1, 4).copy()
        off += vc * 16
        idx = np.frombuffer(raw, dtype="<i4", count=ic, offset=off).copy()
        off += ic * 4
        meshes.append(
            {
                "name": mname,
                "mat": mat,
                "group": group,
                "tex": tex,
                "pos": pos,
                "nrm": nrm,
                "cust": cust,
                "idx": idx,
                "pos_off": pos_off,
                "nrm_off": nrm_off,
                "vc": vc,
            }
        )
    return raw, meshes


def _trimmed_center(pts: np.ndarray) -> np.ndarray:
    """Coordinate-wise median, then drop the farthest 40% and re-mean."""
    if len(pts) < 4:
        return pts.mean(axis=0)
    c = np.median(pts, axis=0)
    if len(pts) < 6:
        return c
    d = np.linalg.norm(pts - c, axis=1)
    keep = d <= np.quantile(d, 0.60)
    if keep.sum() < 3:
        return c
    return pts[keep].mean(axis=0)


def _bins(pos: np.ndarray, along: np.ndarray, lo=0.80, step=0.01):
    us, cents, rmeds = [], [], []
    a = lo
    while a < 1.001:
        sel = (along >= a) & (along < a + step)
        if sel.sum() >= 3:
            p = pos[sel]
            c = _trimmed_center(p)
            r = np.linalg.norm(p - c, axis=1)
            us.append(a + 0.5 * step)
            cents.append(c)
            rmeds.append(float(np.median(r)))
        a += step
    if len(us) < 3:
        return None
    return np.array(us), np.array(cents), np.array(rmeds)


def _interp(us, vals, t):
    if t <= us[0]:
        return vals[0]
    if t >= us[-1]:
        return vals[-1]
    i = int(np.searchsorted(us, t) - 1)
    i = max(0, min(i, len(us) - 2))
    f = (t - us[i]) / max(1e-8, us[i + 1] - us[i])
    return vals[i] * (1.0 - f) + vals[i + 1] * f


def _smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def _spatial_centers(pos: np.ndarray, mask: np.ndarray, half_y: float = 0.012) -> np.ndarray:
    """Trimmed center of nearby distal verts, binned by Y so along-mix cannot drag them."""
    cents = np.zeros_like(pos)
    ys = pos[:, 1]
    idx = np.where(mask)[0]
    # Pre-bin in 4 mm Y slots for speed.
    slots = {}
    for i in idx:
        k = int(round(ys[i] / 0.004))
        slots.setdefault(k, []).append(i)
    cache = {}
    for i in idx:
        k = int(round(ys[i] / 0.004))
        if k not in cache:
            neigh = []
            for kk in (k - 3, k - 2, k - 1, k, k + 1, k + 2, k + 3):
                neigh.extend(slots.get(kk, []))
            pts = pos[neigh] if neigh else pos[i : i + 1]
            cache[k] = _trimmed_center(pts)
        cents[i] = cache[k]
    return cents


def fix_colon(pos: np.ndarray, along: np.ndarray) -> tuple[np.ndarray, dict]:
    out = pos.copy()
    stats = {
        "n": 0,
        "moved": 0,
        "clamped": 0,
        "max_move_mm": 0.0,
        "tip_to_anus_mm": 0.0,
    }
    sel = along >= ALONG0
    sel_i = np.where(sel)[0]
    stats["n"] = int(len(sel_i))
    if stats["n"] < 10:
        return out, stats
    # Spatial centers of the distal verts (and a slightly wider along window for support).
    support = along >= 0.80
    cents = _spatial_centers(pos, support)
    MAX_MOVE = 0.040  # cap, stay conservative

    for i in sel_i:
        u = float(along[i])
        y = float(pos[i, 1])
        c_old = cents[i]
        c_new = c_old.copy()
        # Posterior ease: distal segment only, never more anterior.
        wp = _smoothstep((u - ALONG0) / 0.04)
        if y < 0.995 and c_new[2] > Z_SAFE:
            c_new[2] = c_new[2] * (1.0 - wp) + Z_SAFE * wp
        # Anus ease only for the already-descended geometric tip, never the high-Y blob.
        if y < 0.942:
            wa = _smoothstep((0.942 - y) / 0.030)
            c_new = c_new * (1.0 - wa) + TARGET_END * wa
        radial = pos[i] - c_old
        rn = float(np.linalg.norm(radial))
        t = float(np.clip((u - ALONG0) / max(1e-6, 1.0 - ALONG0), 0.0, 1.0))
        # Low-Y tip tapers; high-Y fat rings use the mid-rectum target.
        want = R_FAT * (1.0 - t) + R_END * t if y < 0.942 else R_FAT
        new_r = rn
        if rn > R_CLAMP:
            new_r = want
            stats["clamped"] += 1
        elif rn > want * 1.4 and (t > 0.15 or y < 0.95):
            new_r = want * 1.2
            stats["clamped"] += 1
        if new_r < 1e-6:
            dir_ = np.array([0.0, 0.0, -1.0])
        else:
            dir_ = radial / rn
        cand = c_new + dir_ * new_r
        delta = cand - pos[i]
        mv = float(np.linalg.norm(delta))
        if mv > MAX_MOVE:
            cand = pos[i] + delta * (MAX_MOVE / mv)
            mv = MAX_MOVE
        out[i] = cand
        if mv > 1e-6:
            stats["moved"] += 1
            stats["max_move_mm"] = max(stats["max_move_mm"], mv * 1000.0)

    tip_sel = (out[:, 1] < 0.930) & sel
    if tip_sel.sum() >= 5:
        tip = _trimmed_center(out[tip_sel])
    else:
        low = out[sel_i]
        tip = low[np.argmin(low[:, 1])]
    stats["tip_to_anus_mm"] = float(np.linalg.norm(tip - ANUS) * 1000.0)
    stats["tip"] = [round(float(x), 4) for x in tip]
    return out, stats


def recompute_normals(pos: np.ndarray, idx: np.ndarray, nrm: np.ndarray, changed: np.ndarray) -> np.ndarray:
    out = nrm.copy()
    acc = np.zeros_like(out)
    w = np.zeros(len(out), dtype=np.int32)
    tris = idx.reshape(-1, 3)
    touch = changed[tris].any(axis=1)
    for a, b, c in tris[touch]:
        fn = np.cross(pos[b] - pos[a], pos[c] - pos[a])
        acc[a] += fn
        acc[b] += fn
        acc[c] += fn
        w[a] += 1
        w[b] += 1
        w[c] += 1
    sel = w > 0
    ln = np.linalg.norm(acc[sel], axis=1, keepdims=True)
    ln = np.maximum(ln, 1e-8)
    out[sel] = (acc[sel] / ln).astype(np.float32)
    return out


def write_pack(original: bytes, meshes, out_path: Path) -> None:
    buf = bytearray(original)
    for m in meshes:
        if "new_pos" not in m:
            continue
        pos = m["new_pos"].astype("<f4").tobytes()
        nrm = m["new_nrm"].astype("<f4").tobytes()
        assert len(pos) == m["vc"] * 12
        buf[m["pos_off"] : m["pos_off"] + len(pos)] = pos
        buf[m["nrm_off"] : m["nrm_off"] + len(nrm)] = nrm
    packed = gzip.compress(bytes(buf), compresslevel=9)
    out_path.write_bytes(packed)
    print("wrote", out_path, "bytes", len(packed))


def _vagina_clearance(meshes, colon_pos):
    vag = None
    for m in meshes:
        if m["name"] == "Object_26":
            vag = m["pos"]
            break
    if vag is None:
        return None
    # chunked min distance between vagina and distal colon
    csel = colon_pos[:, 1] < 0.96
    C = colon_pos[csel]
    best = 1e9
    for i in range(0, len(vag), 40):
        a = vag[i : i + 40]
        d = ((a[:, None, :] - C[None, :, :]) ** 2).sum(2)
        best = min(best, float(np.sqrt(d.min())))
    return best * 1000.0


def main() -> int:
    src = BACKUP if BACKUP.exists() else PACK
    if not PACK.exists() and not BACKUP.exists():
        print("missing", PACK, file=sys.stderr)
        return 1
    if not BACKUP.exists():
        shutil.copy2(PACK, BACKUP)
        print("backup", BACKUP)
    raw, meshes = load_pack(src)
    for m in meshes:
        if m["name"] != TARGET_NAME:
            continue
        along = m["cust"][:, 0]
        new, stats = fix_colon(m["pos"], along)
        changed = np.linalg.norm(new - m["pos"], axis=1) > 1e-7
        nrm = recompute_normals(new, m["idx"], m["nrm"], changed)
        m["new_pos"] = new
        m["new_nrm"] = nrm
        clr0 = _vagina_clearance(meshes, m["pos"])
        clr1 = _vagina_clearance(meshes, new)
        stats["vag_clear_mm_before"] = clr0
        stats["vag_clear_mm_after"] = clr1
        print(f"{m['name']}: {stats}")
        # report distal radii after
        for lo, hi in ((0.88, 0.92), (0.92, 0.96), (0.96, 0.985), (0.985, 1.01)):
            sel = (along >= lo) & (along < hi)
            if sel.sum() < 3:
                continue
            c = _trimmed_center(new[sel])
            r = np.linalg.norm(new[sel] - c, axis=1)
            print(
                f"  along {lo:.3f}-{hi:.3f} n={int(sel.sum())} "
                f"c=({c[0]:+.4f},{c[1]:.4f},{c[2]:.4f}) "
                f"rmed={np.median(r)*1000:.1f} rmax={r.max()*1000:.1f}"
            )
    write_pack(raw, meshes, PACK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
