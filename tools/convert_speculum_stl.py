#!/usr/bin/env python3
"""Convert the two Cusco-speculum STL halves into assets/surgery/speculum.glb.

STLs are binary millimetre meshes (headers still say "solid …"):
  src/speculum_part1.stl  = Speculum_Part1 = upper jaw (2706 tris)
  src/speculum_part2.stl  = Speculum_Part2 = lower jaw (6054 tris)

Each half is put into the tool local frame (metres):
  origin    = hinge pin centre
  +X        = pin axis
  +Z        = blade tip (insertion)
  +Y        = opening / anterior (troughs face the midline)

The source STLs are not in a shared CAD frame and the trough of each
half opens *away* from its handle, so the open-hint is opposite the
handle direction. No extra Y-mirror is applied: after this alignment
the upper trough sits at +Y, the lower at −Y, and both handles stay
on the posterior (−Y) side (classic Cusco). Opening is then
  UpperJaw.rotation.x = −half, LowerJaw.rotation.x = +half.

No decimation (the meshes are already light). Facet normals are smoothed.
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SRC1 = ROOT / "assets/surgery/src/speculum_part1.stl"
SRC2 = ROOT / "assets/surgery/src/speculum_part2.stl"
OUT = ROOT / "assets/surgery/speculum.glb"
META = ROOT / "assets/surgery/speculum_meta.json"

# Pin holes measured from the geometry (mm, source coordinates).
# Part2: two perfect r=1.75 mm circles at X ends, Y=2.55645, Z=113.5207.
PART2_HINGE = np.array([96.924000, 2.556455, 113.520704], dtype=np.float64)
PART2_PIN_AXIS = np.array([1.0, 0.0, 0.0], dtype=np.float64)
PART2_TIP = np.array([96.9236, 1.0129, 0.0009], dtype=np.float64)  # min-Z tip
PART2_OPEN = np.array([0.0, -1.0, 0.0], dtype=np.float64)  # trough opens away from +Y handle

# Part1: perfect r=2.00 mm circles at X=3.75 and 45.75, Y=6.00002, Z=62.91483.
PART1_HINGE = np.array([24.75, 6.000020388678636, 62.91483272671854], dtype=np.float64)
PART1_PIN_AXIS = np.array([1.0, 0.0, 0.0], dtype=np.float64)
PART1_TIP = np.array([24.75, 105.7977, 7.4449], dtype=np.float64)
PART1_OPEN = np.array([0.0, 0.0, -1.0], dtype=np.float64)  # trough opens away from handle


def load_binary_stl(path: Path):
    data = path.read_bytes()
    if len(data) < 84:
        raise ValueError(f"{path} too small")
    header = data[:80]
    n = struct.unpack_from("<I", data, 80)[0]
    expected = 84 + n * 50
    if len(data) < expected:
        raise ValueError(f"{path} truncated: {len(data)} < {expected}")
    V = np.empty((n, 3, 3), dtype=np.float64)
    N = np.empty((n, 3), dtype=np.float64)
    off = 84
    for i in range(n):
        rec = struct.unpack_from("<12fH", data, off)
        off += 50
        N[i] = rec[0:3]
        V[i, 0] = rec[3:6]
        V[i, 1] = rec[6:9]
        V[i, 2] = rec[9:12]
    return header.decode("latin1", "replace").strip(), n, V, N


def make_frame(hinge, pin_axis, blade_dir, open_hint):
    x = pin_axis / np.linalg.norm(pin_axis)
    z = blade_dir / np.linalg.norm(blade_dir)
    z = z - x * np.dot(z, x)
    z /= np.linalg.norm(z)
    y = np.cross(x, z)
    y /= np.linalg.norm(y)
    if np.dot(y, open_hint) < 0:
        y = -y
        x = -x
    R = np.column_stack([x, y, z])  # columns = local axes in source space
    return hinge, R


def transform_mesh(V, N, hinge, R, scale=0.001, mirror_y=False):
    """V: (t,3,3) source mm. Returns V_m, N_m in metres, local frame."""
    Vt = (V - hinge) @ R * scale
    Nt = N @ R
    # recompute missing/zero normals from the transformed faces
    e1 = Vt[:, 1] - Vt[:, 0]
    e2 = Vt[:, 2] - Vt[:, 0]
    fn = np.cross(e1, e2)
    ln = np.linalg.norm(fn, axis=1)
    good = ln > 1e-14
    fn[good] /= ln[good, None]
    # prefer computed normals (more reliable after rotation)
    Nt = fn
    if mirror_y:
        Vt[:, :, 1] *= -1.0
        Nt[:, 1] *= -1.0
        # mirroring reverses winding — flip v1/v2 so fronts stay outward
        Vt = Vt[:, [0, 2, 1], :]
        Nt = -Nt  # after winding flip, flip normals back? 
        # Mirror Y: vertex (x,y,z)->(x,-y,z). Face normal Ny flips, and
        # winding as seen from the outside also flips, so we swap v1/v2
        # to restore CCW, which flips the computed normal again. Net:
        # we should recompute normals after the swap.
        e1 = Vt[:, 1] - Vt[:, 0]
        e2 = Vt[:, 2] - Vt[:, 0]
        fn = np.cross(e1, e2)
        ln = np.linalg.norm(fn, axis=1)
        good = ln > 1e-14
        fn[good] /= ln[good, None]
        # drop zero-area
        Vt, fn = Vt[good], fn[good]
        return Vt, fn
    return Vt[good], Nt[good]


def weld_and_smooth(V, N, quant=1e-6, sharp_deg=50.0):
    """Weld coincident vertices and angle-weighted smooth normals.

    V is (t,3,3). Returns unique verts, smooth normals, indices (t*3,).
    """
    pts = V.reshape(-1, 3)
    q = np.round(pts / quant) * quant
    # unique rows
    uniq, inv = np.unique(q, axis=0, return_inverse=True)
    # accumulate area-weighted face normals, split at sharp edges
    # first pass: unique index per corner
    faces = inv.reshape(-1, 3)
    fn = N  # one normal per face, already unit
    # area
    e1 = V[:, 1] - V[:, 0]
    e2 = V[:, 2] - V[:, 0]
    area = 0.5 * np.linalg.norm(np.cross(e1, e2), axis=1)
    # For each unique vertex, cluster incident face normals by angle
    # Simpler approach: accumulate all, then if a corner's face normal
    # disagrees with the average by > sharp, keep the face normal (split).
    # Even simpler (good enough for chrome metal): accumulate everything
    # (Phong), accept some softening of hard edges. Chrome still reads well.
    acc = np.zeros_like(uniq)
    wt = np.zeros((len(uniq),), dtype=np.float64)
    for t in range(len(V)):
        if area[t] <= 0:
            continue
        for k in range(3):
            acc[faces[t, k]] += fn[t] * area[t]
            wt[faces[t, k]] += area[t]
    ln = np.linalg.norm(acc, axis=1)
    ok = ln > 1e-14
    acc[ok] /= ln[ok, None]
    acc[~ok] = np.array([0, 0, 1])
    # per-corner: if angle to vertex normal is too sharp, use face normal
    # and we would need to split verts. For now, use vertex normals only
    # when within threshold, otherwise split that corner.
    sharp = np.cos(np.deg2rad(sharp_deg))
    # build expanded arrays; split when needed
    new_pts = []
    new_nrm = []
    new_idx = []
    vert_cache = {}  # (uniq_i, quantized normal) -> new index

    def quant_n(n):
        return tuple(np.round(n, 4))

    for t in range(len(V)):
        for k in range(3):
            ui = int(faces[t, k])
            vn = acc[ui]
            if np.dot(vn, fn[t]) < sharp:
                use = fn[t]
            else:
                use = vn
            key = (ui, quant_n(use))
            if key not in vert_cache:
                vert_cache[key] = len(new_pts)
                new_pts.append(uniq[ui])
                new_nrm.append(use)
            new_idx.append(vert_cache[key])
    return (
        np.asarray(new_pts, dtype=np.float32),
        np.asarray(new_nrm, dtype=np.float32),
        np.asarray(new_idx, dtype=np.uint32),
    )


def write_glb(path: Path, meshes: dict, extras: dict):
    """meshes: name -> (verts f32 Nx3, norms f32 Nx3, idx u32).

    Nodes: Speculum / UpperJaw / LowerJaw. Each jaw has one mesh.
    """
    # pack bin
    bin_parts = []
    views = []
    accessors = []
    mesh_defs = []
    offset = 0

    def align4(n):
        return (n + 3) & ~3

    def add_blob(buf: bytes, target, btype):
        nonlocal offset
        pad = align4(len(buf)) - len(buf)
        views.append({
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": len(buf),
            "target": target,
        })
        bin_parts.append(buf)
        if pad:
            bin_parts.append(b"\x00" * pad)
        offset += len(buf) + pad
        return len(views) - 1

    def add_vec3(arr, acc_type):
        arr = np.ascontiguousarray(arr, dtype=np.float32)
        view = add_blob(arr.tobytes(), 34962, "VEC3")  # ARRAY_BUFFER
        mn = arr.min(0).tolist()
        mx = arr.max(0).tolist()
        accessors.append({
            "bufferView": view,
            "componentType": 5126,
            "count": int(arr.shape[0]),
            "type": "VEC3",
            "min": [float(x) for x in mn],
            "max": [float(x) for x in mx],
        })
        return len(accessors) - 1

    def add_idx(idx):
        # use uint32 if needed, else uint16
        if idx.max() > 65535:
            buf = np.ascontiguousarray(idx, dtype=np.uint32).tobytes()
            ctype = 5125
        else:
            buf = np.ascontiguousarray(idx, dtype=np.uint16).tobytes()
            ctype = 5123
        view = add_blob(buf, 34963, "SCALAR")  # ELEMENT_ARRAY_BUFFER
        accessors.append({
            "bufferView": view,
            "componentType": ctype,
            "count": int(idx.size),
            "type": "SCALAR",
        })
        return len(accessors) - 1

    mesh_index = {}
    for name, (verts, norms, idx) in meshes.items():
        ip = add_vec3(verts, "POS")
        inn = add_vec3(norms, "NRM")
        ii = add_idx(idx)
        mesh_index[name] = len(mesh_defs)
        mesh_defs.append({
            "name": name,
            "primitives": [{
                "attributes": {"POSITION": ip, "NORMAL": inn},
                "indices": ii,
                "mode": 4,
            }],
        })

    blob = b"".join(bin_parts)
    # nodes: 0 root, 1 UpperJaw, 2 LowerJaw
    nodes = [
        {"name": "Speculum", "children": [1, 2]},
        {"name": "UpperJaw", "mesh": mesh_index["UpperJaw"]},
        {"name": "LowerJaw", "mesh": mesh_index["LowerJaw"]},
    ]
    doc = {
        "asset": {"version": "2.0", "generator": "tools/convert_speculum_stl.py"},
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accessors,
        "meshes": mesh_defs,
        "nodes": nodes,
        "scenes": [{"name": "Scene", "nodes": [0]}],
        "scene": 0,
        "extras": extras,
    }
    js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    js += b" " * (align4(len(js)) - len(js))
    blob += b"\x00" * (align4(len(blob)) - len(blob))

    json_chunk = struct.pack("<I", len(js)) + b"JSON" + js
    bin_chunk = struct.pack("<I", len(blob)) + b"BIN\x00" + blob
    total = 12 + len(json_chunk) + len(bin_chunk)
    header = struct.pack("<4sII", b"glTF", 2, total)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + json_chunk + bin_chunk)
    print(f"wrote {path} ({total} bytes)")


def mesh_stats(name, V):
    pts = V.reshape(-1, 3)
    mn, mx = pts.min(0), pts.max(0)
    print(f"  {name} AABB m: min={mn} max={mx} size={(mx-mn)*1000} mm")
    # tip = max Z
    tip = pts[np.argmax(pts[:, 2])]
    print(f"  {name} tip (max Z) = {tip}  length={tip[2]*1000:.2f} mm  y={tip[1]*1000:.2f} mm")
    return mn, mx, tip


def mid_blade_width(V, z0, z1):
    pts = V.reshape(-1, 3)
    sl = pts[(pts[:, 2] >= z0) & (pts[:, 2] <= z1)]
    if len(sl) < 8:
        return None
    return float(sl[:, 0].max() - sl[:, 0].min()), float(sl[:, 1].min()), float(sl[:, 1].max())


def main():
    h1, n1, V1, N1 = load_binary_stl(SRC1)
    h2, n2, V2, N2 = load_binary_stl(SRC2)
    print("Part1 header:", h1, "tris", n1)
    print("Part2 header:", h2, "tris", n2)

    hinge2, R2 = make_frame(PART2_HINGE, PART2_PIN_AXIS, PART2_TIP - PART2_HINGE, PART2_OPEN)
    hinge1, R1 = make_frame(PART1_HINGE, PART1_PIN_AXIS, PART1_TIP - PART1_HINGE, PART1_OPEN)
    print("Part2 frame R (cols X Y Z in source mm):\n", R2)
    print("Part1 frame R:\n", R1)
    print("Part2 blade length mm", np.linalg.norm(PART2_TIP - PART2_HINGE))
    print("Part1 blade length mm", np.linalg.norm(PART1_TIP - PART1_HINGE))

    # Lower = Part2, Upper = Part1. Open hints already put the troughs
    # on opposite sides of the midline; do not Y-mirror the upper half.
    Vl, Nl = transform_mesh(V2, N2, hinge2, R2, mirror_y=False)
    Vu, Nu = transform_mesh(V1, N1, hinge1, R1, mirror_y=False)
    print("after transform:")
    mesh_stats("Lower(Part2)", Vl)
    mesh_stats("Upper(Part1)", Vu)
    for name, V in [("Lower", Vl), ("Upper", Vu)]:
        w = mid_blade_width(V, 0.04, 0.07)
        print(f"  {name} mid-blade (40-70mm) width,y-min,y-max = {w}")

    up_pts, up_n, up_i = weld_and_smooth(Vu, Nu)
    lo_pts, lo_n, lo_i = weld_and_smooth(Vl, Nl)
    print(f"Upper welded verts {len(up_pts)} idx {len(up_i)} (tris {len(up_i)//3})")
    print(f"Lower welded verts {len(lo_pts)} idx {len(lo_i)} (tris {len(lo_i)//3})")

    extras = {
        "part1": "upper jaw (Speculum_Part1)",
        "part2": "lower jaw (Speculum_Part2)",
        "units": "metres",
        "source_units": "millimetres",
        "blade_length_m": {
            "upper": float(Vu.reshape(-1, 3)[:, 2].max()),
            "lower": float(Vl.reshape(-1, 3)[:, 2].max()),
        },
        "hinge": {
            "part1_mm": PART1_HINGE.tolist(),
            "part1_pin_radius_mm": 2.0,
            "part1_pin_width_mm": 42.0,
            "part2_mm": PART2_HINGE.tolist(),
            "part2_pin_radius_mm": 1.75,
            "part2_pin_width_mm": 40.9526,
        },
        "mid_blade_m": {
            "upper": mid_blade_width(Vu, 0.04, 0.07),
            "lower": mid_blade_width(Vl, 0.04, 0.07),
        },
        "scale": 0.001,
        "decimated": False,
        "upper_mirrored": False,
        "open_angle_signs": {"UpperJaw": -1, "LowerJaw": 1},
    }
    write_glb(OUT, {"UpperJaw": (up_pts, up_n, up_i), "LowerJaw": (lo_pts, lo_n, lo_i)}, extras)
    META.write_text(json.dumps(extras, indent=2) + "\n")
    print("wrote", META)
    return 0


if __name__ == "__main__":
    sys.exit(main())
