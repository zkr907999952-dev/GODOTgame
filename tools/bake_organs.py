"""
Bake web organs (intestines.glb + pelvis.glb from rouchangmoniqi3) into a compact
Godot runtime pack, placed inside Tifa exactly like the web figure.tsx pipeline:

  findNavel / sampleBand(abdomen) / sampleTorsoProfile
  placeGuts (liftColonFlexures, fitGutEnvelope, balanceLowerGuts, tuckColonSides, centerGutsInCavity)
  placePelvisPack (strip vulva, scale uterus to 5.8cm, shift internals, stubVagina)
  liftGutsOffUterus
  GutPeristalsis.attach (geodesic "along" + radial vectors)

Extra for Godot: decimate, weld seams, skin weights transferred from nearby torso skin
(only C_Hip_a / C_Spine_a..d, like web bind hint "organs" = /Spine|Hip/).

Run:
  /workspace/tools/blender/blender --background --python tools/bake_organs.py
Outputs (assets/organs/): organs_mesh.bin (gzip), organs_meta.json, *.jpg textures.
All coordinates are Three/Godot Y-up character space (+Z = belly front), same as
Tifa_Web_Skinned.glb mesh space.
"""
import bpy
import bmesh
import gzip
import heapq
import json
import math
import os
import struct

import numpy as np
from mathutils import kdtree

WEB = "/workspace/rouchangmoniqi3"
GODOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(GODOT, "assets", "organs")
TIFA = os.path.join(GODOT, "assets", "characters", "tifa", "Tifa_Web_Skinned.glb")
GUT_GLB = f"{WEB}/public/models/intestines.glb"
PELVIS_GLB = f"{WEB}/public/models/pelvis.glb"
DECIMATE = {"Tjocktarm_Default Material_0": 0.2, "Tjocktarm_Default Material_0.001": 0.22, "Tunntarm_Default Material_0": 0.36}
ORGAN_BONES = ["C_Hip_a", "C_Spine_a", "C_Spine_b", "C_Spine_c", "C_Spine_d"]


def smoothstep(x, a, b):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def b2t(a):  # blender Z-up -> three Y-up
    return np.stack([a[:, 0], a[:, 2], -a[:, 1]], axis=1)


def t2b(a):
    return np.stack([a[:, 0], -a[:, 2], a[:, 1]], axis=1)


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mesh_world_verts(o):
    me = o.data
    n = len(me.vertices)
    co = np.zeros(n * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    m = np.array(o.matrix_world)
    co = co @ m[:3, :3].T + m[:3, 3]
    return b2t(co)


def key_of(o):
    mat = o.data.materials[0].name if o.data.materials else ""
    par = o.parent.name if o.parent else ""
    return f"{o.name} {par} {mat}".lower()


# ---------------------------------------------------------------- body
def load_body():
    clear()
    bpy.ops.import_scene.gltf(filepath=TIFA)
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and "Ico" not in o.name]
    allv = np.concatenate([mesh_world_verts(o) for o in meshes])
    height = allv[:, 1].max() - allv[:, 1].min()
    torso_objs = [o for o in meshes if ("dress" in key_of(o) or "skin" in key_of(o))]
    torso = [mesh_world_verts(o) for o in torso_objs]
    # skin weights restricted to organ bones
    wts = []
    for o in torso_objs:
        n = len(o.data.vertices)
        W = np.zeros((n, len(ORGAN_BONES)))
        gi = {g.index: ORGAN_BONES.index(g.name) for g in o.vertex_groups if g.name in ORGAN_BONES}
        for v in o.data.vertices:
            for g in v.groups:
                j = gi.get(g.group)
                if j is not None:
                    W[v.index, j] = g.weight
        wts.append(W)
    print("body height", height, [o.name for o in torso_objs], [len(t) for t in torso])
    return height, torso, np.concatenate(torso), np.concatenate(wts)


def find_navel(T, h):
    y0, y1 = h * 0.568, h * 0.642
    m = (T[:, 1] >= y0) & (T[:, 1] <= y1) & (np.abs(T[:, 0]) <= 0.045) & (T[:, 2] >= 0.04)
    pts = T[m]
    cm = np.abs(pts[:, 0]) < 0.03
    maxZ = pts[cm, 2].max() if cm.any() else -1e9
    fallback = np.array([0, h * 0.6, max(0.08, maxZ)])
    if len(pts) < 12 or maxZ < 0.05:
        return fallback
    wall = maxZ - 0.02
    W = pts[pts[:, 2] >= wall]
    best, best_s = fallback, -1e18
    for p in W:
        if abs(p[0]) > 0.016:
            continue
        d2 = (W[:, 0] - p[0]) ** 2 + (W[:, 1] - p[1]) ** 2
        q = (d2 < 2.6e-4) & (d2 > 3e-7)
        n = q.sum()
        if n < 8:
            continue
        inset = W[q, 2].mean() - p[2]
        if inset < 0.0004 or inset > 0.018:
            continue
        s = inset * 22 - abs(p[0]) * 10 + (p[2] - wall) * 2
        if s > best_s:
            best_s, best = s, p
    if best_s < -1:
        c = W[np.abs(W[:, 0]) <= 0.01]
        if len(c):
            best = c[np.argmin(c[:, 2])]
    return np.array(best, dtype=np.float64)


def sample_band(torso_list, y0, y1, max_abs_x):
    pts = []
    for T in torso_list:
        step = max(1, len(T) // 6000)
        S = T[::step]
        m = (S[:, 1] >= y0) & (S[:, 1] <= y1) & (np.abs(S[:, 0]) <= max_abs_x)
        pts.append(S[m])
    P = np.concatenate(pts)
    return P.min(0), P.max(0), len(P)


def torso_profile(T, y0, y1, bands=20):
    dy = (y1 - y0) / bands
    ys = y0 + (np.arange(bands) + 0.5) * dy
    halfX = np.full(bands, 0.04)
    zF = np.full(bands, -1.0)
    zB = np.full(bands, 1.0)
    n = np.zeros(bands, dtype=int)
    m = (T[:, 1] >= y0) & (T[:, 1] <= y1) & (np.abs(T[:, 0]) <= 0.16) & (T[:, 2] >= -0.02)
    P = T[m]
    b = np.clip(((P[:, 1] - y0) / dy).astype(int), 0, bands - 1)
    for i in range(bands):
        q = P[b == i]
        if len(q):
            halfX[i] = max(0.04, np.abs(q[:, 0]).max())
            zF[i] = q[:, 2].max()
            zB[i] = q[:, 2].min()
            n[i] = len(q)
    for i in range(bands):
        if n[i] > 4:
            continue
        src = i - 1 if (i > 0 and n[i - 1] > 4) else min(bands - 1, i + 1)
        halfX[i], zF[i], zB[i] = halfX[src], zF[src], zB[src]
    return ys, halfX, zF, zB


def prof_at(prof, y):
    ys, hx, zf, zb = prof
    return np.interp(y, ys, hx), np.interp(y, ys, zf)


# ---------------------------------------------------------------- organs
class Part:
    def __init__(self, obj):
        self.obj = obj
        self.key = key_of(obj)
        self.name = obj.name


def import_parts(path, weld=True):
    clear()
    bpy.ops.import_scene.gltf(filepath=path)
    parts = []
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        p = Part(o)
        # bake world transform into mesh data
        me = o.data.copy()
        o.data = me
        me.transform(o.matrix_world)
        o.parent = None
        o.matrix_world.identity()
        if weld:
            bm = bmesh.new()
            bm.from_mesh(me)
            bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
            bm.to_mesh(me)
            bm.free()
        parts.append(p)
    return parts


def decimate(p, ratio):
    o = p.obj
    bpy.context.view_layer.objects.active = o
    md = o.modifiers.new("dec", "DECIMATE")
    md.ratio = ratio
    md.use_collapse_triangulate = True
    dg = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev)
    o.modifiers.remove(md)
    o.data = me


def get_pos(p):
    return mesh_world_verts(p.obj)


def set_pos(p, P):
    me = p.obj.data
    me.vertices.foreach_set("co", t2b(P).astype(np.float32).ravel())
    me.update()


def box_of(arrs):
    A = np.concatenate(arrs)
    return A.min(0), A.max(0)


def place_guts(parts, cav_min, cav_max, navel, prof):
    P = [get_pos(p) for p in parts]
    smin, smax = box_of(P)
    ss = smax - smin
    ts = cav_max - cav_min
    s = min(ts[0] / max(ss[0], 1e-4), ts[1] / max(ss[1], 1e-4)) * 0.9
    sc = np.array([s, s, s * 1.2])
    P = [q * sc for q in P]
    amin, amax = box_of(P)
    ac = (amin + amax) * 0.5
    cz = (cav_min[2] + cav_max[2]) * 0.5
    off = np.array([navel[0] - ac[0], navel[1] + 0.016 - ac[1], cz - ac[2]])
    P = [q + off for q in P]
    ny = navel[1]
    # liftColonFlexures
    gmin, gmax = box_of(P)
    y0 = gmin[1]; span = max(1e-4, gmax[1] - y0); cx = (gmin[0] + gmax[0]) * 0.5
    for q in P:
        t = (q[:, 1] - y0) / span
        w = np.where(t >= 0.38, (t - 0.38) / 0.62, 0)
        side = smoothstep(np.abs(q[:, 0] - cx), 0.03, 0.075)
        q[:, 1] += 0.046 * w * (0.62 + 0.38 * side)
    # fitGutEnvelope
    gmin, gmax = box_of(P)
    y0 = gmin[1]; span = max(1e-4, gmax[1] - y0); cx = (gmin[0] + gmax[0]) * 0.5
    bands = 16
    gHalf = np.zeros(bands); gZ1 = np.full(bands, -1e3)
    for q in P:
        b = np.clip(((q[:, 1] - y0) / span * bands).astype(int), 0, bands - 1)
        np.maximum.at(gHalf, b, np.abs(q[:, 0] - cx))
        np.maximum.at(gZ1, b, q[:, 2])
    for b in range(1, bands):
        if gHalf[b] < 0.02: gHalf[b] = gHalf[b - 1]
        if gZ1[b] < -10: gZ1[b] = gZ1[b - 1]
    yb = y0 + (np.arange(bands) + 0.5) / bands * span
    hx, zf = prof_at(prof, yb)
    above = smoothstep(yb, ny + 0.08, ny + 0.22)
    allowX = np.maximum(0.05, hx * (0.78 - above * 0.02))
    sx = np.clip(allowX / np.maximum(gHalf, 1e-4), 0.84, 1)
    allowZ = np.minimum(cav_max[2], zf - 0.012)
    zPull = np.maximum(0, (gZ1 - allowZ) * 0.35)

    def lerpB(arr, t):
        x = np.clip(t, 0, 1) * (bands - 1)
        i = np.clip(np.floor(x).astype(int), 0, bands - 2)
        f = x - i
        return arr[i] * (1 - f) + arr[i + 1] * f

    for q in P:
        t = np.clip((q[:, 1] - y0) / span, 0, 1)
        q[:, 0] = cx + (q[:, 0] - cx) * lerpB(sx, t)
        z = q[:, 2] - lerpB(zPull, t)
        _, pzf = prof_at(prof, q[:, 1])
        zFront = np.minimum(cav_max[2], pzf - 0.01)
        q[:, 2] = np.where(z > zFront, zFront + (z - zFront) * 0.2, z)
    # balanceLowerGuts
    gmin, gmax = box_of(P)
    yLo = gmin[1]; yHi = ny + 0.02
    if yHi > yLo:
        A = np.concatenate(P)
        low = A[A[:, 1] <= yHi]
        if len(low) >= 20:
            cxl = low[:, 0].mean()
            left = max(0, -low[:, 0].min()); right = max(0, low[:, 0].max())
            spanx = max(left, right, 0.03)
            for q in P:
                t = 1 - smoothstep(q[:, 1], yLo, yHi)
                x = q[:, 0] - cxl * t * 0.8
                phx, _ = prof_at(prof, q[:, 1])
                allow = np.maximum(0.055, phx * 0.84)
                sxx = 1 + (allow / spanx - 1) * t * 0.7
                x = x * np.clip(sxx, 1, 1.4)
                q[:, 0] = np.where(t > 0, x, q[:, 0])
    # tuckColonSides
    for q in P:
        x = q[:, 0]; ax = np.abs(x)
        outer = smoothstep(ax, 0.022, 0.08)
        band = smoothstep(q[:, 1], ny + 0.02, ny + 0.16)
        w = outer * (0.4 + 0.6 * band)
        w = np.where(ax < 0.004, 0, w)
        _, pzf = prof_at(prof, q[:, 1])
        zl = pzf - 0.015
        z = q[:, 2]
        q[:, 2] = np.where(z > zl, z - (z - zl) * 0.45 * w, z)
        q[:, 0] = x - np.sign(x) * 0.011 * w
    # centerGutsInCavity
    gmin, gmax = box_of(P)
    gz = (gmin[2] + gmax[2]) * 0.5
    cz = (cav_min[2] + cav_max[2]) * 0.5
    dz = cz - gz
    front = gmax[2] + dz
    halfHave = max(1e-4, front - cz); halfAllow = max(1e-4, cav_max[2] - cz)
    sz = halfAllow / halfHave if halfHave > halfAllow else 1
    for q in P:
        z = q[:, 2] + dz
        q[:, 2] = cz + (z - cz) * sz
    for p, q in zip(parts, P):
        set_pos(p, q)


def named(parts, pat):
    import re
    r = re.compile(pat)
    return [p for p in parts if r.search(p.key)]


def place_pelvis(parts, navel):
    import re
    kill = re.compile(r"vulve|clitoris|corpsetracines|materialcorps|materialbulbes")
    keep = []
    for p in parts:
        if kill.search(p.key):
            bpy.data.objects.remove(p.obj, do_unlink=True)
        else:
            keep.append(p)
    parts = keep
    P = {p.name: get_pos(p) for p in parts}
    ut = named(parts, "uterus")
    umin, umax = box_of([P[p.name] for p in ut])
    s = 0.058 / max(umax[1] - umin[1], 1e-4)
    for k in P: P[k] = P[k] * s
    umin, umax = box_of([P[p.name] for p in ut])
    uc = (umin + umax) * 0.5
    off = np.array([0, navel[1] - 0.1, navel[2] - 0.055]) - uc
    for k in P: P[k] = P[k] + off

    def scale_named(pat, f):
        for p in named(parts, pat):
            q = P[p.name]; c = q.mean(0)
            P[p.name] = c + (q - c) * f
    scale_named("uterus", 1.02)
    scale_named("vessie|bladder", 0.7)
    umin, umax = box_of([P[p.name] for p in ut])
    czz = (umin[2] + umax[2]) * 0.5
    dy = navel[1] - 0.06 - umax[1]
    dz = navel[2] - 0.07 - czz
    for p in named(parts, "uterus|vessie|bladder|ovaire|trompe|ligament|vagin"):
        P[p.name] = P[p.name] + np.array([0, dy, dz])
    # stubVagina
    umin, umax = box_of([P[p.name] for p in ut])
    c = np.array([0, (umin[1] + umax[1]) * 0.5 - 0.02, (umin[2] + umax[2]) * 0.5 + 0.008])
    for p in named(parts, "vagin"):
        q = P[p.name]
        d = np.linalg.norm(q - c, axis=1)
        w = np.clip((d - 0.028) / 0.05, 0, 1)[:, None]
        P[p.name] = q + (c - q) * w
    for p in parts:
        set_pos(p, P[p.name])
    umin, umax = box_of([P[p.name] for p in ut])
    return parts, umin, umax


def lift_guts_off_uterus(parts, umin, umax):
    uc = (umin + umax) * 0.5
    h = np.maximum(0.02, (umax - umin) * 0.5 + np.array([0.012, 0.01, 0.01]))
    ySurf = umax[1] + 0.006
    for p in parts:
        q = get_pos(p)
        nrm = (q - uc) / h
        d2 = (nrm ** 2).sum(1)
        m = d2 < 1
        d = np.sqrt(np.maximum(d2, 1e-6))
        s = (1.08 / d)[:, None]
        nq = uc + nrm * h * s
        nq[:, 1] = np.maximum(nq[:, 1], ySurf)
        q[m] = nq[m]
        set_pos(p, q)


# ---------------------------------------------------------------- peristalsis
def edges_of(tris):
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    src = np.concatenate([a, b, b, c, c, a])
    dst = np.concatenate([b, a, c, b, a, c])
    return src, dst


def dijkstra(start, n, adj):
    dist = np.full(n, 1e12)
    dist[start] = 0.0
    h = [(0.0, start)]
    while h:
        dv, v = heapq.heappop(h)
        if dv > dist[v] + 1e-12:
            continue
        for u, w in adj[v]:
            nd = dv + w
            if nd < dist[u]:
                dist[u] = nd
                heapq.heappush(h, (nd, u))
    return dist


def smooth_field(f, src, dst, n, iters):
    deg = np.bincount(src, minlength=n).astype(np.float64) + 1
    for _ in range(iters):
        if f.ndim == 1:
            s = f.copy(); np.add.at(s, src, f[dst])
            f = s / deg
        else:
            s = f.copy(); np.add.at(s, src, f[dst])
            f = s / deg[:, None]
    return f


def compute_along_rad(rest, tris):
    n = len(rest)
    src, dst = edges_of(tris)
    w = np.linalg.norm(rest[src] - rest[dst], axis=1)
    adj = [[] for _ in range(n)]
    for s_, d_, ww in zip(src.tolist(), dst.tolist(), w.tolist()):
        adj[s_].append((d_, ww))
    along = np.zeros(n); seen = np.zeros(n, bool)
    for i in range(n):
        if seen[i]:
            continue
        dist = dijkstra(i, n, adj)
        vis = dist < 1e11
        if vis.sum() < 12:
            seen[i] = True; along[i] = 0; continue
        idx = np.where(vis)[0]
        rectum = idx[np.argmin(rest[idx, 1])]
        dist = dijkstra(rectum, n, adj)
        prox = idx[np.argmax(dist[idx])]
        dist = dijkstra(prox, n, adj)
        L = dist[idx].max()
        along[idx] = np.minimum(1, dist[idx] / max(1e-5, L))
        seen[idx] = True
    along = smooth_field(along, src, dst, n, 10)
    lo, hi = along.min(), along.max()
    along = (along - lo) / max(1e-5, hi - lo)
    bins = 96
    b = np.clip((along * bins).astype(int), 0, bins - 1)
    cn = np.bincount(b, minlength=bins).astype(np.float64)
    C = np.zeros((bins, 3))
    for k in range(3):
        C[:, k] = np.bincount(b, weights=rest[:, k], minlength=bins)
    C[cn > 0] /= cn[cn > 0, None]
    for k in range(1, bins):
        if cn[k] >= 6:
            continue
        C[k] = C[k - 1]; cn[k] = cn[k - 1]
    u = along * (bins - 1)
    bi = np.clip(u.astype(int), 0, bins - 2)
    f = (u - bi)[:, None]
    mid = C[bi] * (1 - f) + C[bi + 1] * f
    r = rest - mid
    ln = np.linalg.norm(r, axis=1)
    sc = np.where(ln > 0.022, 0.022 / np.maximum(ln, 1e-9), 1)[:, None]
    r = r * sc
    r = smooth_field(r, src, dst, n, 6)
    return along, r


# ---------------------------------------------------------------- export
def extract(p, body_kd, body_w, along=None, rad=None):
    o = p.obj
    me = o.data
    for poly in me.polygons:
        poly.use_smooth = True
    if hasattr(me, "has_custom_normals") and me.has_custom_normals:
        bpy.context.view_layer.objects.active = o
        with bpy.context.temp_override(object=o, active_object=o, selected_objects=[o]):
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
    me.calc_loop_triangles()
    has_uv = len(me.uv_layers) > 0
    if has_uv:
        me.calc_tangents(uvmap=me.uv_layers[0].name)
    nl = len(me.loops)
    lv = np.zeros(nl, dtype=np.int64); me.loops.foreach_get("vertex_index", lv)
    ln = np.zeros(nl * 3); me.loops.foreach_get("normal", ln); ln = ln.reshape(-1, 3)
    if has_uv:
        uv = np.zeros(nl * 2); me.uv_layers[0].data.foreach_get("uv", uv); uv = uv.reshape(-1, 2)
        lt = np.zeros(nl * 3); me.loops.foreach_get("tangent", lt); lt = lt.reshape(-1, 3)
        ls = np.zeros(nl); me.loops.foreach_get("bitangent_sign", ls)
    else:
        uv = np.zeros((nl, 2)); lt = np.zeros((nl, 3)); ls = np.ones(nl)
    keymat = np.concatenate([lv[:, None].astype(np.float64), np.round(uv, 5), np.round(ln, 3)], axis=1)
    _, first, inv = np.unique(keymat, axis=0, return_index=True, return_inverse=True)
    inv = inv.ravel()
    vi = lv[first]
    nv = len(me.vertices)
    co = np.zeros(nv * 3); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
    pos = b2t(co[vi])
    nrm = b2t(ln[first])
    tan = b2t(lt[first])
    sgn = -ls[first]  # v flip
    uvo = np.stack([uv[first, 0], 1.0 - uv[first, 1]], axis=1)
    tri_l = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64)
    me.loop_triangles.foreach_get("loops", tri_l)
    tri = inv[tri_l].reshape(-1, 3)[:, [0, 2, 1]]  # Godot clockwise front
    # skin weights from nearest torso skin
    k = 8
    W = np.zeros((len(pos), len(ORGAN_BONES)))
    pb = t2b(pos)
    for i in range(len(pos)):
        acc = np.zeros(len(ORGAN_BONES)); tw = 0
        for (_, idx, d) in body_kd.find_n(pb[i], k):
            ww = 1.0 / (d + 0.004)
            acc += body_w[idx] * ww; tw += ww
        W[i] = acc / max(tw, 1e-9)
    s = W.sum(1)
    fallback = 0 if "pelvis" in p.group else 1
    W[s < 1e-4, fallback] = 1
    W /= W.sum(1, keepdims=True)
    order = np.argsort(-W, axis=1)[:, :4]
    bw = np.take_along_axis(W, order, 1)
    bw /= bw.sum(1, keepdims=True)
    cust = np.zeros((len(pos), 4), dtype=np.float32)
    if along is not None:
        cust[:, 0] = along[vi]
        cust[:, 1:4] = rad[vi]
    return dict(pos=pos, nrm=nrm, tan=np.concatenate([tan, sgn[:, None]], 1), uv=uvo,
                bones=order.astype(np.uint8), weights=bw, custom=cust, idx=tri.astype(np.uint32))


def wstr(f, s):
    b = s.encode("utf-8")
    f.write(struct.pack("<H", len(b))); f.write(b)


def save_textures(path):
    clear()
    bpy.ops.import_scene.gltf(filepath=path)
    names = {"Image_0": "colon_albedo", "Image_1": "colon_normal", "Image_2": "small_albedo", "Image_3": "small_normal"}
    for im in bpy.data.images:
        if im.name not in names:
            continue
        if im.size[0] > 1024:
            im.scale(1024, 1024)
        out = os.path.join(OUT, names[im.name] + ".jpg")
        im.filepath_raw = out
        im.file_format = "JPEG"
        im.save(filepath=out, quality=88)
        print("tex", out, os.path.getsize(out))


def main():
    os.makedirs(OUT, exist_ok=True)
    height, torso_list, T, TW = load_body()
    navel = find_navel(T, height)
    yN = navel[1]
    print("navel", navel)
    amin, amax, cnt = sample_band(torso_list, yN - 0.08, yN + 0.11, 0.12)
    if cnt <= 40:
        amin = np.array([-0.11, yN - 0.08, -0.04]); amax = np.array([0.11, yN + 0.11, 0.1])
    abx = max(0.11, min(0.13, (amax[0] - amin[0]) * 0.42))
    acx = (amin[0] + amax[0]) * 0.5
    amin[0], amax[0] = acx - abx, acx + abx
    skinZ = navel[2]
    amax[2] = skinZ - 0.012
    amin[2] = skinZ - 0.1
    gut_min = np.array([acx - 0.12, yN - 0.16, amin[2]])
    gut_max = np.array([acx + 0.12, yN + 0.22, amax[2]])
    prof = torso_profile(T, gut_min[1] - 0.02, gut_max[1] + 0.1)
    # weights KD on torso skin (blender coords)
    TB = t2b(T)
    kd = kdtree.KDTree(len(TB))
    for i, v in enumerate(TB):
        kd.insert(v, i)
    kd.balance()

    meshes = []
    # ---- pelvis
    pparts = import_parts(PELVIS_GLB, weld=False)
    pparts, umin, umax = place_pelvis(pparts, navel)
    print("uterus box", umin, umax)
    for p in pparts:
        p.group = "pelvis"
        mat = p.obj.data.materials[0]
        col = list(mat.diffuse_color)
        try:
            bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
            col = list(bsdf.inputs["Base Color"].default_value)
            col[3] = bsdf.inputs["Alpha"].default_value
        except Exception:
            pass
        d = extract(p, kd, TW)
        d.update(name=p.name, group=1, tex=-1, color=col, mat=mat.name)
        meshes.append(d)
    # ---- guts
    gparts = import_parts(GUT_GLB, weld=True)
    # place first (on full-res, like web), then decimate
    place_guts(gparts, gut_min, gut_max, navel, prof)
    lift_guts_off_uterus(gparts, umin, umax)
    for p in gparts:
        decimate(p, DECIMATE.get(p.name, 0.25))
        p.group = "gut"
        me = p.obj.data
        rest = get_pos(p)
        me.calc_loop_triangles()
        tl = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64)
        me.loop_triangles.foreach_get("vertices", tl)
        along, rad = compute_along_rad(rest, tl.reshape(-1, 3))
        tex = 0 if "tjock" in p.key else 1
        d = extract(p, kd, TW, along, rad)
        d.update(name=p.name, group=0, tex=tex, color=[1, 1, 1, 1], mat=me.materials[0].name)
        meshes.append(d)
        print("gut", p.name, len(d["pos"]), "verts", len(d["idx"]), "tris")
    gmin, gmax = box_of([m["pos"] for m in meshes if m["group"] == 0])
    pmin, pmax = box_of([m["pos"] for m in meshes if m["group"] == 1])

    import io
    f = io.BytesIO()
    f.write(b"ORGN"); f.write(struct.pack("<I", 1))
    f.write(struct.pack("<I", len(ORGAN_BONES)))
    for b in ORGAN_BONES:
        wstr(f, b)
    f.write(struct.pack("<I", len(meshes)))
    for m in meshes:
        wstr(f, m["name"]); wstr(f, m["mat"])
        f.write(struct.pack("<Bb", m["group"], m["tex"]))
        f.write(struct.pack("<4f", *m["color"]))
        f.write(struct.pack("<II", len(m["pos"]), m["idx"].size))
        f.write(m["pos"].astype("<f4").tobytes())
        f.write(m["nrm"].astype("<f4").tobytes())
        f.write(m["tan"].astype("<f4").tobytes())
        f.write(m["uv"].astype("<f4").tobytes())
        f.write(m["bones"].astype("u1").tobytes())
        f.write(m["weights"].astype("<f4").tobytes())
        f.write(m["custom"].astype("<f4").tobytes())
        f.write(m["idx"].astype("<u4").tobytes())
    data = f.getvalue()
    with gzip.GzipFile(os.path.join(OUT, "organs_mesh.bin"), "wb", compresslevel=9, mtime=0) as g:
        g.write(data)
    meta = {
        "source": "rouchangmoniqi3 public/models/intestines.glb + pelvis.glb, placed by tools/bake_organs.py (port of figure.tsx)",
        "height": float(height),
        "navel": navel.tolist(),
        "abdomen": {"min": amin.tolist(), "max": amax.tolist()},
        "gut_cavity": {"min": gut_min.tolist(), "max": gut_max.tolist()},
        "guts": {"min": gmin.tolist(), "max": gmax.tolist()},
        "pelvis": {"min": pmin.tolist(), "max": pmax.tolist()},
        "uterus": {"min": umin.tolist(), "max": umax.tolist()},
        # web attachXray(yX0 - navel.y, yX1 - navel.y, 0.12, skinZ - 0.01 - navel.z)
        "xray": {"y0": -0.2, "y1": 0.145, "x_max": 0.12, "z_front": -0.01},
        "profile": {"y": prof[0].tolist(), "half_x": prof[1].tolist(), "z_front": prof[2].tolist(), "z_back": prof[3].tolist()},
        "bones": ORGAN_BONES,
    }
    with open(os.path.join(OUT, "organs_meta.json"), "w") as g:
        json.dump(meta, g, indent=1)
    print("wrote", len(data), "raw bytes; gz", os.path.getsize(os.path.join(OUT, "organs_mesh.bin")))
    save_textures(GUT_GLB)


main()
