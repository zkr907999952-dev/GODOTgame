"""
头发蒙皮修正 + 头皮遮色（离线，原地改 Tifa_Web_Skinned.glb，不改变文件布局/大小）。

问题：烘焙时直接用了网页 nude-rig-data.json 的原始权重，而网页运行时还会做一次
SoftSkeleton.reskinHair()（头顶/前额/贴头皮的头发全部绑到 C_Head_a，只有下垂的发束
绑到 Hair_2..Hair_8）。Godot 版缺了这一步，结果头顶所有发片都带 0.2–0.5 的 Hair_2+
权重，发尾一甩头顶也跟着动。

本脚本移植 reskinHair，并改成连续衰减（无硬折痕）：
  free = f_y * f_scalp * f_front
    f_y     : 头顶(crownY=Hair_1.y-0.02) → Hair_2.y-0.04 之间 smoothstep 从 0 到 1
    f_scalp : 离头皮(头部网格)距离 0.8cm → 3.5cm 之间 smoothstep（贴头皮的发片刚性）
    f_front : z > -0.015（前额/鬓角/前垂发，网页 isFront）刚性
  权重 = head*(1-free) + 链(a,b 按 y 插值)*free
另外输出头皮遮色贴图 scalp_mask.png（头部 UV 空间，头发覆盖的头皮=白），
运行时作为头部材质 detail mask，用发色压暗头皮，避免透过发片看到肤色头皮。

Run: python3 tools/fix_hair_skin.py   (needs numpy + Pillow)
"""
import json
import os
import struct

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
GLB = os.path.join(HERE, "..", "assets", "characters", "tifa", "Tifa_Web_Skinned.glb")
MASK = os.path.join(HERE, "..", "assets", "characters", "tifa", "scalp_mask.png")
MASK_RES = 512

COMP = {5126: ("<f4", 4), 5121: ("u1", 1), 5123: ("<u2", 2), 5125: ("<u4", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def smoothstep(x, a, b):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def load():
    data = bytearray(open(GLB, "rb").read())
    jlen = struct.unpack_from("<I", data, 12)[0]
    js = json.loads(bytes(data[20:20 + jlen]))
    bin_off = 20 + jlen + 8
    return data, js, bin_off


def acc_view(data, js, bin_off, ai):
    a = js["accessors"][ai]
    bv = js["bufferViews"][a["bufferView"]]
    dt, sz = COMP[a["componentType"]]
    nc = NCOMP[a["type"]]
    start = bin_off + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0)
    assert stride in (0, sz * nc), "interleaved buffers not supported"
    n = a["count"] * nc
    arr = np.frombuffer(bytes(data[start:start + n * sz]), dtype=dt).reshape(a["count"], nc)
    return arr.copy(), start


def prim_by_mat(js, matname):
    for m in js["meshes"]:
        for p in m["primitives"]:
            if js["materials"][p["material"]]["name"] == matname:
                return p
    raise KeyError(matname)


def nearest_dist(src, dst, chunk=2048):
    """min distance from each src point to the dst cloud (brute force, chunked)."""
    out = np.empty(len(src))
    d2 = (dst ** 2).sum(1)
    for i in range(0, len(src), chunk):
        s = src[i:i + chunk]
        dd = (s ** 2).sum(1)[:, None] + d2[None, :] - 2.0 * s @ dst.T
        out[i:i + chunk] = np.sqrt(np.maximum(dd.min(1), 0.0))
    return out


def main():
    data, js, bin_off = load()
    skin = js["skins"][0]
    names = [js["nodes"][j].get("name", "") for j in skin["joints"]]
    ibm, _ = acc_view(data, js, bin_off, skin["inverseBindMatrices"])
    jpos = {}
    for i, nm in enumerate(names):
        m = ibm[i].reshape(4, 4).T  # column-major
        jpos[nm] = np.linalg.inv(m)[:3, 3]
    ji = {nm: i for i, nm in enumerate(names)}
    head = ji["C_Head_a"]
    phys = [f"Hair_{k}" for k in range(2, 9) if f"Hair_{k}" in ji]
    phys_y = np.array([jpos[n][1] for n in phys])
    crown_y = jpos["Hair_1"][1] - 0.02
    y_free = phys_y[0] - 0.04
    print("head", jpos["C_Head_a"], "crownY", crown_y, "phys", list(zip(phys, phys_y.round(3))))

    hp = prim_by_mat(js, ".001")
    hd = prim_by_mat(js, "PC0002_01_Head")
    P, _ = acc_view(data, js, bin_off, hp["attributes"]["POSITION"])
    J, j_off = acc_view(data, js, bin_off, hp["attributes"]["JOINTS_0"])
    W, w_off = acc_view(data, js, bin_off, hp["attributes"]["WEIGHTS_0"])
    HP, _ = acc_view(data, js, bin_off, hd["attributes"]["POSITION"])
    P = P.astype(np.float64)
    HP = HP.astype(np.float64)

    d_scalp = nearest_dist(P, HP)
    y = P[:, 1]
    z = P[:, 2]
    f_y = smoothstep(crown_y - y, 0.0, crown_y - y_free)
    f_s = smoothstep(d_scalp, 0.008, 0.035)
    f_f = 1.0 - smoothstep(z, -0.05, -0.015)
    free = f_y * f_s * f_f
    free[free < 0.02] = 0.0

    # chain segment by height (web: k advances while y < phys[k].y)
    k = np.searchsorted(-phys_y, -y, side="left")  # first phys with y_k < y ... (phys_y descending)
    k = np.clip(k, 1, len(phys) - 1)
    ya = phys_y[k - 1]
    yb = phys_y[k]
    t = np.clip((ya - y) / np.maximum(0.02, ya - yb), 0.0, 1.0)
    above = y >= phys_y[0]
    t[above] = 0.0
    a_idx = np.array([ji[phys[i]] for i in range(len(phys))])[k - 1]
    b_idx = np.array([ji[phys[i]] for i in range(len(phys))])[k]

    NJ = np.zeros_like(J)
    NW = np.zeros_like(W)
    NJ[:, 0] = head
    NW[:, 0] = 1.0 - free
    NJ[:, 1] = a_idx
    NW[:, 1] = free * (1.0 - t)
    NJ[:, 2] = b_idx
    NW[:, 2] = free * t
    NJ[:, 3] = head
    NW = NW / NW.sum(1, keepdims=True)
    NW = NW.astype(np.float32)

    data[j_off:j_off + NJ.nbytes] = NJ.astype(np.uint8).tobytes()
    data[w_off:w_off + NW.nbytes] = NW.tobytes()
    open(GLB, "wb").write(bytes(data))
    rigid = (free == 0).sum()
    print(f"hair verts {len(P)} rigid {rigid} ({rigid / len(P):.0%}); top(y>{crown_y:.3f}) max free {free[y > crown_y].max() if (y > crown_y).any() else 0:.3f}")

    # ---- scalp mask (head UV space)
    UV, _ = acc_view(data, js, bin_off, hd["attributes"]["TEXCOORD_0"])
    idx, _ = acc_view(data, js, bin_off, hd["indices"])
    idx = idx.reshape(-1, 3)
    d_hair = nearest_dist(HP, P)
    hy, hz, hx = HP[:, 1], HP[:, 2], np.abs(HP[:, 0])
    hj = jpos["C_Head_a"]
    # scalp = above the forehead hairline / behind the ears; never the face
    face = (hz > hj[2] + 0.02) & (hy < hj[1] + 0.105)
    side_face = (hz > hj[2] - 0.015) & (hy < hj[1] + 0.06) & (hx > 0.04)
    jaw = (hz > hj[2] - 0.01) & (hy < hj[1] + 0.03)
    cov = (1.0 - smoothstep(d_hair, 0.006, 0.022))
    cov *= smoothstep(hy, hj[1] - 0.06, hj[1] - 0.02)  # nothing below the nape line
    cov[face | side_face | jaw] = 0.0
    print("scalp verts", int((cov > 0.5).sum()), "/", len(HP))
    img = Image.new("L", (MASK_RES, MASK_RES), 0)
    dr = ImageDraw.Draw(img)
    for tri in idx:
        c = cov[tri].mean()
        if c < 0.05:
            continue
        pts = [(float(UV[v, 0] * MASK_RES), float(UV[v, 1] * MASK_RES)) for v in tri]
        dr.polygon(pts, fill=int(round(c * 255)))
    img = img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(3))
    img.save(MASK, optimize=True)
    print("wrote", MASK, os.path.getsize(MASK))


if __name__ == "__main__":
    main()
