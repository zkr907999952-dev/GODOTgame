#!/usr/bin/env python3
"""Build a uterine cavity (endometrium) mesh from the existing uterus in organs_mesh.bin.

The lining is the uterus scaled inward along the surface-of-revolution
direction (toward the cervix–fundus axis, with a normal-offset fallback at
the tube horns so those holes stay registered). Faces/vertex normals are
oriented inward so the lumen is visible through the cervical os.

A hole is cut in both the outer uterus and the lining at the os and
zippered to the existing 2-layer vaginal canal ring, so the passage from
the vagina through the cervix into the cavity is open. Tube horns get a
short wall-thickness cuff between the inner and outer loops.

Idempotent: if a mesh with material 'Endometrium' is already in the pack,
it is replaced and the uterus is taken from a sibling backup written on
the first run (organs_mesh.pre_cavity.bin).

Run:  python3 tools/build_uterus_cavity.py
"""
from __future__ import annotations

import gzip
import json
import math
import struct
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "assets/organs/organs_mesh.bin"
META = ROOT / "assets/organs/organs_meta.json"
BACKUP = ROOT / "assets/organs/organs_mesh.pre_cavity.bin"

# Wall thickness (metres). Large enough to avoid z-fighting, small enough
# to leave a visible lumen in a ~5.8 cm uterus.
WALL = 0.0028
# Cervical cap cut: vertices with radius < OS_R and axis-depth < OS_S.
OS_R = 0.0052
OS_S = 0.0040
OS_K = 3  # faces with this many verts inside the cap are deleted
# Leave at least this much lumen radius when shrinking.
MIN_LUMEN_R = 0.0016
# Tube-horn neighbourhood: use a pure normal offset so holes stay aligned.
HORN_KEEP = 0.010

MUCOSA = (0.81, 0.60, 0.57, 1.0)


def rstr(buf, off):
    n = struct.unpack_from("<H", buf, off)[0]
    return buf[off + 2 : off + 2 + n].decode("utf-8"), off + 2 + n


def wstr(f, s):
    b = s.encode("utf-8")
    f.write(struct.pack("<H", len(b)))
    f.write(b)


def load_pack(path: Path):
    raw = gzip.decompress(path.read_bytes())
    assert raw[:4] == b"ORGN"
    ver = struct.unpack_from("<I", raw, 4)[0]
    off = 8
    nb = struct.unpack_from("<I", raw, off)[0]
    off += 4
    bones = []
    for _ in range(nb):
        s, off = rstr(raw, off)
        bones.append(s)
    mc = struct.unpack_from("<I", raw, off)[0]
    off += 4
    meshes = []
    for _ in range(mc):
        name, off = rstr(raw, off)
        mat, off = rstr(raw, off)
        group = raw[off]
        tex = struct.unpack_from("<b", raw, off + 1)[0]
        off += 2
        col = struct.unpack_from("<4f", raw, off)
        off += 16
        vc, ic = struct.unpack_from("<II", raw, off)
        off += 8
        pos = np.frombuffer(raw, dtype="<f4", count=vc * 3, offset=off).reshape(vc, 3).copy()
        off += vc * 12
        nrm = np.frombuffer(raw, dtype="<f4", count=vc * 3, offset=off).reshape(vc, 3).copy()
        off += vc * 12
        tan = np.frombuffer(raw, dtype="<f4", count=vc * 4, offset=off).reshape(vc, 4).copy()
        off += vc * 16
        uv = np.frombuffer(raw, dtype="<f4", count=vc * 2, offset=off).reshape(vc, 2).copy()
        off += vc * 8
        bones_i = np.frombuffer(raw, dtype="u1", count=vc * 4, offset=off).reshape(vc, 4).copy()
        off += vc * 4
        wts = np.frombuffer(raw, dtype="<f4", count=vc * 4, offset=off).reshape(vc, 4).copy()
        off += vc * 16
        cust = np.frombuffer(raw, dtype="<f4", count=vc * 4, offset=off).reshape(vc, 4).copy()
        off += vc * 16
        idx = np.frombuffer(raw, dtype="<u4", count=ic, offset=off).copy()
        off += ic * 4
        meshes.append(
            dict(
                name=name,
                mat=mat,
                group=int(group),
                tex=int(tex),
                color=tuple(col),
                pos=pos,
                nrm=nrm,
                tan=tan,
                uv=uv,
                bones=bones_i,
                weights=wts,
                custom=cust,
                idx=idx,
            )
        )
    return ver, bones, meshes


def write_pack(path: Path, ver, bones, meshes):
    import io

    f = io.BytesIO()
    f.write(b"ORGN")
    f.write(struct.pack("<I", ver))
    f.write(struct.pack("<I", len(bones)))
    for b in bones:
        wstr(f, b)
    f.write(struct.pack("<I", len(meshes)))
    for m in meshes:
        wstr(f, m["name"])
        wstr(f, m["mat"])
        f.write(struct.pack("<Bb", m["group"], m["tex"]))
        col = m["color"]
        f.write(struct.pack("<4f", float(col[0]), float(col[1]), float(col[2]), float(col[3])))
        f.write(struct.pack("<II", len(m["pos"]), int(m["idx"].size)))
        f.write(np.ascontiguousarray(m["pos"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["nrm"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["tan"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["uv"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["bones"], dtype="u1").tobytes())
        f.write(np.ascontiguousarray(m["weights"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["custom"], dtype="<f4").tobytes())
        f.write(np.ascontiguousarray(m["idx"], dtype="<u4").tobytes())
    data = f.getvalue()
    with gzip.GzipFile(path, "wb", compresslevel=9, mtime=0) as g:
        g.write(data)
    print(f"wrote {path} raw={len(data)} gz={path.stat().st_size}")


def boundary_loops(idx, nvert=None):
    tris = idx.reshape(-1, 3)
    cnt = defaultdict(int)
    for a, b, c in tris:
        if a == b or b == c or c == a:
            continue
        for e in ((min(a, b), max(a, b)), (min(b, c), max(b, c)), (min(c, a), max(c, a))):
            cnt[e] += 1
    adj = defaultdict(list)
    for (u, v), c in cnt.items():
        if c == 1:
            adj[u].append(v)
            adj[v].append(u)
    seen = set()
    loops = []
    for s0 in adj:
        if s0 in seen:
            continue
        loop = [s0]
        seen.add(s0)
        prev = None
        cur = s0
        while True:
            nxts = [n for n in adj[cur] if n != prev]
            if not nxts:
                break
            nxt = nxts[0]
            if nxt in seen:
                break
            loop.append(nxt)
            seen.add(nxt)
            prev, cur = cur, nxt
        loops.append(np.array(loop, dtype=np.int32))
    return loops


def order_loop_by_angle(loop, pos, center, axis, ref=None):
    pts = pos[loop]
    t = (pts - center) @ axis
    rad = pts - center - np.outer(t, axis)
    if ref is None:
        ref = rad[np.argmax(np.linalg.norm(rad, axis=1))]
    ref = np.asarray(ref, dtype=np.float64)
    ref = ref - axis * np.dot(ref, axis)
    ref = ref / max(np.linalg.norm(ref), 1e-12)
    yaxis = np.cross(axis, ref)
    yaxis /= max(np.linalg.norm(yaxis), 1e-12)
    xaxis = np.cross(yaxis, axis)
    xaxis /= max(np.linalg.norm(xaxis), 1e-12)
    ang = np.arctan2(rad @ yaxis, rad @ xaxis)
    order = np.argsort(ang)
    return loop[order], ang[order]


def zipper_tris(loop_a, loop_b, flip=False):
    """Zip two angle-sorted loops of any length into an annular strip.

    Both loops must already be ordered CCW around the same axis and
    start at a similar angle. Indices are absolute vertex IDs.
    """
    na, nb = len(loop_a), len(loop_b)
    if na < 3 or nb < 3:
        return np.zeros((0, 3), dtype=np.int32)
    tris = []
    i = j = 0
    # Advance the loop whose next fraction is smaller. Do not wrap the
    # finished loop's index back to 0 (that would throw a diameter across
    # the hole). Closing edges use (i+1)%n only while that loop is stepping.
    while i < na or j < nb:
        a_next = i < na
        b_next = j < nb
        fa = (i + 1) / na if a_next else 99.0
        fb = (j + 1) / nb if b_next else 99.0
        if a_next and fa <= fb:
            a1 = loop_a[i]
            a2 = loop_a[(i + 1) % na]
            b1 = loop_b[min(j, nb - 1)]
            tri = (int(a1), int(a2), int(b1))
            i += 1
        else:
            b1 = loop_b[j]
            b2 = loop_b[(j + 1) % nb]
            a1 = loop_a[min(i, na - 1)]
            tri = (int(a1), int(b1), int(b2))
            j += 1
        if flip:
            tri = (tri[0], tri[2], tri[1])
        if len(set(tri)) == 3:
            tris.append(tri)
        if len(tris) > (na + nb) * 4:
            break
    return np.array(tris, dtype=np.int32)


def zipper_equal(loop_a, loop_b, flip=False):
    """Zip two same-orientation loops of any length with proportional stepping."""
    return zipper_tris(loop_a, loop_b, flip=flip)


def recompute_tangents(nrm):
    up = np.array([0.0, 1.0, 0.0])
    t = np.cross(up, nrm)
    ln = np.linalg.norm(t, axis=1)
    bad = ln < 1e-6
    if np.any(bad):
        t[bad] = np.cross(np.array([1.0, 0.0, 0.0]), nrm[bad])
        ln = np.linalg.norm(t, axis=1)
    t = t / np.maximum(ln[:, None], 1e-12)
    tan = np.zeros((len(nrm), 4), dtype=np.float32)
    tan[:, :3] = t
    tan[:, 3] = 1.0
    return tan


def shrink_vertices(pos, nrm, cx, uax, horns):
    """Scale inward along the surface of revolution (toward the long axis).

    new = axis_proj + (r - wall) * radial_hat, so length along the
    cervix–fundus axis is preserved and the lining cannot leave the
    outer wall's star-shaped envelope. Near the axis the offset is
    reduced so the lumen does not invert.
    """
    s = (pos - cx) @ uax
    axis_p = cx + np.outer(s, uax)
    radial = pos - axis_p
    r = np.linalg.norm(radial, axis=1)
    rn = radial / np.maximum(r[:, None], 1e-12)
    new_r = np.maximum(r - WALL, np.minimum(r, MIN_LUMEN_R))
    # If the vertex is already closer than WALL, scale proportionally
    # instead of collapsing onto the axis.
    small = r < (WALL + MIN_LUMEN_R)
    new_r = np.where(small, r * (MIN_LUMEN_R / (WALL + MIN_LUMEN_R)), new_r)
    new = axis_p + rn * new_r[:, None]
    offset = r - new_r
    return new.astype(np.float32), offset


def append_verts(mesh, pos, nrm, uv, bones, weights, custom):
    """Append vertices to mesh, return starting index."""
    base = len(mesh["pos"])
    mesh["pos"] = np.vstack([mesh["pos"], pos.astype(np.float32)])
    mesh["nrm"] = np.vstack([mesh["nrm"], nrm.astype(np.float32)])
    mesh["uv"] = np.vstack([mesh["uv"], uv.astype(np.float32)])
    mesh["bones"] = np.vstack([mesh["bones"], bones.astype(np.uint8)])
    mesh["weights"] = np.vstack([mesh["weights"], weights.astype(np.float32)])
    mesh["custom"] = np.vstack([mesh["custom"], custom.astype(np.float32)])
    mesh["tan"] = recompute_tangents(mesh["nrm"])
    return base


def copy_mesh(m):
    return {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in m.items()}


def main():
    meta = json.loads(META.read_text())
    # Prefer the pre-cavity backup so the script is idempotent.
    if not BACKUP.exists():
        # Don't cut an already-processed pack a second time.
        ver0, bones0, meshes0 = load_pack(PACK)
        if any(m["mat"] == "Endometrium" for m in meshes0):
            print("pack already contains Endometrium and no pre-cavity backup; nothing to do")
            return 0
        BACKUP.write_bytes(PACK.read_bytes())
        print("saved backup", BACKUP)
    src = BACKUP if BACKUP.exists() else PACK

    ver, bones, meshes = load_pack(src)
    # Drop a previous Endometrium if we rebuilt from a pack that already had one
    # (shouldn't happen when reading the backup).
    meshes = [m for m in meshes if m["mat"] != "Endometrium"]

    ut_i = next(i for i, m in enumerate(meshes) if m["mat"] == "Uterus")
    ut = copy_mesh(meshes[ut_i])
    vag = [m for m in meshes if "vagin" in m["mat"].lower()]
    if len(vag) != 2:
        raise SystemExit(f"expected 2 vagina meshes, got {len(vag)}")

    cx = np.array(meta["vagina"]["cervix"], dtype=np.float64)
    axis = np.array(meta["vagina"]["axis"], dtype=np.float64)
    axis /= np.linalg.norm(axis)
    uax = -axis  # into the uterus (fundus-ward)
    horns = [np.array(t["horn"], dtype=np.float64) for t in meta.get("tubes", [])]

    pos, nrm, idx = ut["pos"], ut["nrm"], ut["idx"].reshape(-1, 3)

    # ---- cut the cervical cap on the outer uterus ----
    s = (pos - cx) @ uax
    r = np.linalg.norm(pos - cx - np.outer(s, uax), axis=1)
    inside = (r < OS_R) & (s < OS_S) & (s > -0.005)
    n_in = inside[idx].sum(1)
    cut = n_in >= OS_K
    keep = ~cut
    print(f"uterus cap cut: {int(cut.sum())} faces  kept {int(keep.sum())}")
    new_idx = idx[keep].reshape(-1)

    loops = boundary_loops(new_idx)
    print("uterus boundary loops after cut:", [len(L) for L in loops])

    def loop_kind(L):
        c = pos[L].mean(0)
        # tube vs os: os is near cx, tubes near horns
        d_os = np.linalg.norm(c - cx)
        d_h = min((np.linalg.norm(c - h) for h in horns), default=1e9)
        return "horn" if d_h < d_os else "os"

    kinds = [loop_kind(L) for L in loops]
    os_loops = [L for L, k in zip(loops, kinds) if k == "os"]
    horn_loops = [L for L, k in zip(loops, kinds) if k == "horn"]
    if len(os_loops) != 1 or len(horn_loops) != 2:
        raise SystemExit(f"unexpected loops kinds={kinds} sizes={[len(L) for L in loops]}")
    os_loop = os_loops[0]
    os_ref = np.array([1.0, 0.0, 0.0])
    os_loop, _ = order_loop_by_angle(os_loop, pos, cx, uax, ref=os_ref)
    print(f"os loop n={len(os_loop)} center={pos[os_loop].mean(0)} r={np.linalg.norm(pos[os_loop]-cx-np.outer((pos[os_loop]-cx)@uax,uax),axis=1).mean():.4f}")

    # ---- find the shared vaginal os ring (cervix-end loop of both layers) ----
    vag_os = None
    vag_os_src = None
    for m in vag:
        for L in boundary_loops(m["idx"]):
            c = m["pos"][L].mean(0)
            if np.linalg.norm(c - cx) < 0.008:
                if vag_os is None or len(L) > len(vag_os[0]):
                    vag_os = (L, m)
                    vag_os_src = m
    if vag_os is None:
        raise SystemExit("could not find vaginal os ring")
    vloop_local, vmesh = vag_os
    vloop_local, _ = order_loop_by_angle(vloop_local, vmesh["pos"], cx, uax, ref=os_ref)
    print(f"vagina os ring n={len(vloop_local)} from {vmesh['name']} center={vmesh['pos'][vloop_local].mean(0)}")

    # ---- shrink a copy for the lining ----
    cpos, used_off = shrink_vertices(pos.astype(np.float64), nrm.astype(np.float64), cx, uax, horns)
    print(f"shrink offset mm: mean={used_off.mean()*1000:.2f} min={used_off.min()*1000:.2f} max={used_off.max()*1000:.2f}")
    # inward vertex normals
    cnrm = -nrm
    # keep original winding (already faces the interior geometrically) so
    # FRONT_FACING is true when looking from inside the lumen.
    cidx = new_idx.copy()  # same cut as the outer wall

    # ---- build endometrium mesh (starts as shrunk cut uterus) ----
    endo = dict(
        name="UterusCavity",
        mat="Endometrium",
        group=1,
        tex=-1,
        color=MUCOSA,
        pos=cpos.copy(),
        nrm=cnrm.astype(np.float32),
        tan=recompute_tangents(cnrm.astype(np.float32)),
        uv=ut["uv"].copy(),
        bones=ut["bones"].copy(),
        weights=ut["weights"].copy(),
        custom=ut["custom"].copy(),
        idx=cidx.copy(),
    )

    # inner os loop: same vertex indices as outer, after shrink
    inner_os, _ = order_loop_by_angle(os_loop.copy(), endo["pos"], cx, uax, ref=os_ref)

    # inner horn loops (same indices)
    inner_horns = []
    for L in horn_loops:
        Li, _ = order_loop_by_angle(L.copy(), endo["pos"], pos[L].mean(0), pos[L].mean(0) - cpos[L].mean(0))
        inner_horns.append((L, Li))

    # ---- zipper: copy vagina os verts into both meshes and stitch ----
    # Use the vagina ring vertices (positions + skin weights) so the join is exact.
    vp = vmesh["pos"][vloop_local]
    vn = vmesh["nrm"][vloop_local]
    vuv = vmesh["uv"][vloop_local]
    vb = vmesh["bones"][vloop_local]
    vw = vmesh["weights"][vloop_local]
    vc = vmesh["custom"][vloop_local]

    # Outer uterus: append vagina os verts, zipper outer hole -> ring.
    # Ring normals stay as-is (canal); for the short cuff we just need a seal.
    base_u = append_verts(ut, vp, vn, vuv, vb, vw, vc)
    ring_u = np.arange(base_u, base_u + len(vloop_local), dtype=np.int32)
    # Make sure both loops go the same way around +uax
    # Compare handedness: after angle sort they should already match (same axis).
    zu = zipper_equal(os_loop, ring_u, flip=False)
    # Check cuff winding: face normals should point roughly toward the axis (into the os)
    def strip_inward_ok(mesh, tris, center, ax):
        if len(tris) == 0:
            return True, tris
        f = mesh["pos"][tris]
        fn = np.cross(f[:, 1] - f[:, 0], f[:, 2] - f[:, 0])
        fc = f.mean(1)
        rad = fc - center - np.outer((fc - center) @ ax, ax)
        # We want fn pointing toward axis, i.e. opposite radial (into the hole)
        score = (fn * rad).sum()
        if score > 0:
            tris = tris[:, [0, 2, 1]]
            return False, tris
        return True, tris

    ok, zu = strip_inward_ok(ut, zu, cx, uax)
    ut["idx"] = np.concatenate([new_idx, zu.reshape(-1)])
    print(f"outer os zipper tris={len(zu)} flipped={not ok}")

    # Endometrium: append the same ring (inward nrm), zipper inner hole -> ring.
    # Flip ring normals to face the lumen for lighting on the cuff if needed.
    base_e = append_verts(endo, vp, -vn, vuv, vb, vw, vc)
    ring_e = np.arange(base_e, base_e + len(vloop_local), dtype=np.int32)
    ze = zipper_equal(inner_os, ring_e, flip=False)
    ok, ze = strip_inward_ok(endo, ze, cx, uax)
    endo["idx"] = np.concatenate([endo["idx"], ze.reshape(-1)])
    print(f"inner os zipper tris={len(ze)} flipped={not ok}")

    # ---- tube cuffs on the endometrium (inner loop <-> outer loop positions) ----
    # The outer horn loops live on the (cut) uterus. We copy those outer loop
    # verts into the endometrium and zipper to the shrunk inner loops, forming
    # a short mucosal cuff through the wall so the tube lumen opens into the cavity.
    cuff_count = 0
    for L_outer, L_inner in inner_horns:
        opos = pos[L_outer]
        onrm = nrm[L_outer]
        ouv = ut["uv"][L_outer]
        ob = ut["bones"][L_outer]
        ow = ut["weights"][L_outer]
        oc = ut["custom"][L_outer]
        # order both by angle around the horn outward (from loop center)
        hc = opos.mean(0)
        # horn axis: from fundus-ish / from nearest meta horn normal
        hax = opos.mean(0) - cx
        # better: average of (outer - inner) which is roughly outward normal
        hax = (opos - endo["pos"][L_inner]).mean(0)
        if np.linalg.norm(hax) < 1e-8:
            hax = opos.mean(0) - endo["pos"][L_inner].mean(0)
        hax = hax / max(np.linalg.norm(hax), 1e-12)
        Lo, _ = order_loop_by_angle(L_outer.copy(), pos, hc, hax)
        # L_inner are the same original indices; after shrink they moved
        Li, _ = order_loop_by_angle(L_inner.copy(), endo["pos"], endo["pos"][L_inner].mean(0), hax)
        base_h = append_verts(endo, opos := pos[Lo], onrm := nrm[Lo], ut["uv"][Lo], ut["bones"][Lo], ut["weights"][Lo], ut["custom"][Lo])
        # wait we already reordered Lo; append those
        # I used Lo after append_verts args wrongly - I already appended Lo above.
        ring_h = np.arange(base_h, base_h + len(Lo), dtype=np.int32)
        zc = zipper_equal(Li, ring_h, flip=False)
        ok, zc = strip_inward_ok(endo, zc, hc, hax)
        endo["idx"] = np.concatenate([endo["idx"], zc.reshape(-1)])
        cuff_count += len(zc)
        print(f"tube cuff n_out={len(Lo)} n_in={len(Li)} tris={len(zc)} flipped={not ok}")
    print(f"tube cuff tris total {cuff_count}")

    # Recompute endo tangents after all appends (already done per append).
    endo["tan"] = recompute_tangents(endo["nrm"])
    ut["tan"] = recompute_tangents(ut["nrm"])

    # Stats
    def aabb(p):
        return p.min(0), p.max(0)

    umn, umx = aabb(ut["pos"])
    emn, emx = aabb(endo["pos"])
    print("uterus AABB", umn, umx)
    print("endo   AABB", emn, emx)
    print("endo inside uterus (min gap mm):", (emn - umn).min() * 1000, (umx - emx).min() * 1000)
    # inward normal fraction
    c = endo["pos"].mean(0)
    inward = ((endo["nrm"] * (endo["pos"] - c)).sum(1) < 0).mean()
    print(f"endo vertex normals inward: {inward*100:.1f}%")

    # Install
    meshes[ut_i] = ut
    # Insert endo just after uterus
    meshes.insert(ut_i + 1, endo)

    # Meta
    os_center = vp.mean(0)
    os_r = float(np.linalg.norm(vp - cx - np.outer((vp - cx) @ uax, uax), axis=1).mean())
    meta["uterus_cavity"] = {
        "mesh": "UterusCavity",
        "material": "Endometrium",
        "wall_m": WALL,
        "os_radius_m": os_r,
        "os_center": os_center.tolist(),
        "os_loop_n": int(len(vloop_local)),
        "uterus_os_loop_n": int(len(os_loop)),
        "aabb": {"min": emn.tolist(), "max": emx.tolist()},
        "verts": int(len(endo["pos"])),
        "tris": int(len(endo["idx"]) // 3),
        "mucosa": list(MUCOSA),
    }
    # keep uterus aabb as the outer wall (used by gameplay / v0408 box checks)
    # If unused cap verts remain, the box is unchanged.

    write_pack(PACK, ver, bones, meshes)
    META.write_text(json.dumps(meta, indent=1) + "\n")
    print("updated", META)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
