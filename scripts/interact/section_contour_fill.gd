extends RefCounted
## 用剖切面与「变形后的真实网格」求交，把截面围成的区域涂成该网格的切面色。
## 体表最外轮廓以内、又不是器官切面的地方 = 腹膜/腹腔内壁深粉，不允许露出背景黑。
## 管腔用偶奇填充留空，露出腹腔色或单独的管腔色。

const COL_PERITONEUM := Color(0.48, 0.20, 0.26)
const COL_SKIN := Color(0.91, 0.75, 0.66)
const COL_VAG_WALL := Color(0.91, 0.55, 0.60)
const COL_VAG_LUMEN := Color(0.58, 0.24, 0.30)
const COL_UTER_WALL := Color(0.70, 0.30, 0.40)
const COL_UTER_LUMEN := Color(0.45, 0.16, 0.22)
const COL_ROD := Color(0.78, 0.82, 0.86)

const GRID := 160
const GAP_CLOSE := 0.0032
const STROKE_M := 0.0018

# 网格：0 空，1 体外，2 腹膜，3 体表描边，4+ 器官。描边与体外必须用不同编码，否则洪水灌完会把腹腔外也涂成肤色。
const C_EMPTY := 0
const C_OUT := 1
const C_PERIT := 2
const C_SKIN := 3
const C_VAG_W := 4
const C_VAG_L := 5
const C_UTER_W := 6
const C_UTER_L := 7
const C_ROD := 8

const _PALETTE := {
	C_PERIT: COL_PERITONEUM,
	C_SKIN: COL_SKIN,
	C_VAG_W: COL_VAG_WALL,
	C_VAG_L: COL_VAG_LUMEN,
	C_UTER_W: COL_UTER_WALL,
	C_UTER_L: COL_UTER_LUMEN,
	C_ROD: COL_ROD,
}


func color_of(code: int) -> Color:
	return _PALETTE.get(code, Color(0, 0, 0, 0))


func build(plane_pnt: Vector3, plane_n: Vector3, axis_x: Vector3, axis_y: Vector3, half_w: float, half_h: float, buckets: Array, limb_caps: Array, insert: Dictionary = {}) -> Dictionary:
	# buckets: Array of {kind, tissue, verts (world), idx}
	# 返回 {verts, colors, indices, stats, origin, x, y, half_w, half_h, grid, codes, cell}
	var n := plane_n.normalized()
	var x := axis_x - n * axis_x.dot(n)
	if x.length_squared() < 1e-10:
		x = Vector3.RIGHT - n * Vector3.RIGHT.dot(n)
	x = x.normalized()
	var y := n.cross(x).normalized()
	if y.dot(axis_y) < 0.0:
		y = -y
		x = -x
	var hw := maxf(half_w, 0.04)
	var hh := maxf(half_h, 0.04)
	var gw := GRID
	var gh := GRID
	var cell_w := (hw * 2.0) / float(gw)
	var cell_h := (hh * 2.0) / float(gh)
	var codes := PackedInt32Array()
	codes.resize(gw * gh)
	# ---- 体表线段
	var skin_segs: Array = []
	var organ_loops: Dictionary = {"vagina": [], "uterus": [], "uterus_cavity": [], "prolapse_uterus": [], "rod": [], "vestibule": []}
	for b in buckets:
		var kind := str(b.get("kind", ""))
		var verts: PackedVector3Array = b["verts"]
		var idx: PackedInt32Array = b["idx"]
		if kind == "skin" or kind == "flaps":
			var pts := _slice_points(verts, idx, plane_pnt, n, x, y)
			for pt in pts:
				skin_segs.append([pt, pt])
		else:
			var segs := _intersect_segments(verts, idx, plane_pnt, n, x, y, false, limb_caps)
			if organ_loops.has(kind):
				var loops := _stitch(segs)
				for lp in loops:
					organ_loops[kind].append(lp)
			elif kind == "sleeve":
				var loops2 := _stitch(segs)
				for lp2 in loops2:
					organ_loops["vagina"].append(lp2)
	# 体表：最大闭合圈，不行就用交点凸包（堵住阴道口等缺口）。横切特写若完全在体内、看不到体表，整格先涂腹膜。
	var body_poly := _body_silhouette(skin_segs)
	var filled_body := false
	var inside_only := false
	if body_poly.size() >= 3 and absf(_poly_area(body_poly)) > 0.0002:
		_fill_poly(codes, gw, gh, hw, hh, body_poly, C_PERIT)
		filled_body = true
	var stroke := maxi(1, int(ceil(STROKE_M / minf(cell_w, cell_h))))
	if body_poly.size() >= 3:
		for i_e in body_poly.size():
			_draw_seg(codes, gw, gh, hw, hh, body_poly[i_e], body_poly[(i_e + 1) % body_poly.size()], C_SKIN, stroke)
	else:
		for s2 in skin_segs:
			_draw_seg(codes, gw, gh, hw, hh, s2[0], s2[1], C_SKIN, stroke)
	_dilate_mask(codes, gw, gh, C_SKIN, maxi(stroke, 2))
	_erode_mask(codes, gw, gh, C_SKIN, maxi(stroke, 2))
	if filled_body:
		_flood_outside(codes, gw, gh)
	var organ_hit := false
	for k in organ_loops.keys():
		if not (organ_loops[k] as Array).is_empty():
			organ_hit = true
			break
	if not filled_body and organ_hit:
		# 镜头框在腹腔内，切不到体表轮廓：整格就是腹膜，再铺器官。
		for i in codes.size():
			if codes[i] == 0 or codes[i] == C_OUT:
				codes[i] = C_PERIT
		inside_only = true
	elif not filled_body:
		_flood_outside(codes, gw, gh)
	if not inside_only:
		for i2 in codes.size():
			if codes[i2] == 0:
				codes[i2] = C_PERIT
	# 器官：闭多边形，大圈=壁，内洞=管腔
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["vagina"], C_VAG_W, C_VAG_L)
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["vestibule"], C_VAG_W, C_VAG_L)
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["uterus"], C_UTER_W, C_UTER_L)
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["prolapse_uterus"], C_UTER_W, C_UTER_L)
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["uterus_cavity"], C_UTER_L, C_UTER_L)
	_paint_organ(codes, gw, gh, hw, hh, organ_loops["rod"], C_ROD, C_ROD)
	# t89u：用球+杆的真实平面截形盖住宫壁/内膜填充，避免网格交线不完整时粉色切面从钢球里穿出来。
	if not insert.is_empty() and float(insert.get("radius", 0.0)) > 1e-6:
		_stamp_insert(codes, gw, gh, hw, hh, plane_pnt, x, y, insert)
	# 网格 → 三角网（按行压缩成条带）
	var mv := PackedVector3Array()
	var mc := PackedColorArray()
	var mi := PackedInt32Array()
	var counts := {C_PERIT: 0, C_SKIN: 0, C_VAG_W: 0, C_VAG_L: 0, C_UTER_W: 0, C_UTER_L: 0, C_ROD: 0, C_OUT: 0}
	for row in gh:
		var col := 0
		while col < gw:
			var code := codes[row * gw + col]
			if code <= C_OUT:
				col += 1
				continue
			var c2 := col + 1
			while c2 < gw and codes[row * gw + c2] == code:
				c2 += 1
			_emit_run(mv, mc, mi, plane_pnt, x, y, hw, hh, cell_w, cell_h, col, c2, row, code)
			counts[code] = int(counts.get(code, 0)) + (c2 - col)
			col = c2
	var inside := 0
	for k in [C_PERIT, C_SKIN, C_VAG_W, C_VAG_L, C_UTER_W, C_UTER_L, C_ROD]:
		inside += int(counts.get(k, 0))
	var cell_area := cell_w * cell_h
	return {
		"verts": mv,
		"colors": mc,
		"indices": mi,
		"counts": counts,
		"inside_cells": inside,
		"area": float(inside) * cell_area,
		"peritoneum_area": float(counts[C_PERIT]) * cell_area,
		"origin": plane_pnt,
		"axis_x": x,
		"axis_y": y,
		"normal": n,
		"half_w": hw,
		"half_h": hh,
		"grid_w": gw,
		"grid_h": gh,
		"codes": codes,
		"cell_w": cell_w,
		"cell_h": cell_h,
		"tris": mi.size() / 3,
	}


func sample_code(built: Dictionary, world: Vector3) -> int:
	if built.is_empty() or not built.has("codes"):
		return C_OUT
	var o: Vector3 = built["origin"]
	var x: Vector3 = built["axis_x"]
	var y: Vector3 = built["axis_y"]
	var hw: float = built["half_w"]
	var hh: float = built["half_h"]
	var gw: int = built["grid_w"]
	var gh: int = built["grid_h"]
	var u := (world - o).dot(x)
	var v := (world - o).dot(y)
	var ix := int(floor((u + hw) / (hw * 2.0) * float(gw)))
	var iy := int(floor((v + hh) / (hh * 2.0) * float(gh)))
	if ix < 0 or iy < 0 or ix >= gw or iy >= gh:
		return C_OUT
	return int((built["codes"] as PackedInt32Array)[iy * gw + ix])



func _slice_points(verts: PackedVector3Array, idx: PackedInt32Array, pnt: Vector3, n: Vector3, ax: Vector3, ay: Vector3) -> PackedVector2Array:
	# 只收集切到平面的边交点，不做四肢剔除（凸包仍包住腹腔）。
	var out := PackedVector2Array()
	var tri_n := idx.size() / 3 if idx.size() >= 3 else verts.size() / 3
	# 体表网格很密：每隔若干三角采样仍能还原轮廓，避免每帧跑完整万级三角。
	var step := 1
	if tri_n > 4000:
		step = 3
	elif tri_n > 2000:
		step = 2
	var t := 0
	while t < tri_n:
		var ia: int
		var ib: int
		var ic: int
		if idx.size() >= 3:
			ia = idx[t * 3]
			ib = idx[t * 3 + 1]
			ic = idx[t * 3 + 2]
		else:
			ia = t * 3
			ib = t * 3 + 1
			ic = t * 3 + 2
		t += step
		if ia < 0 or ib < 0 or ic < 0 or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
			continue
		var a: Vector3 = verts[ia]
		var b: Vector3 = verts[ib]
		var c: Vector3 = verts[ic]
		var sa := (a - pnt).dot(n)
		var sb := (b - pnt).dot(n)
		var sc := (c - pnt).dot(n)
		if sa > 0.0 and sb > 0.0 and sc > 0.0:
			continue
		if sa < 0.0 and sb < 0.0 and sc < 0.0:
			continue
		_edge_point(out, a, b, sa, sb, ax, ay, pnt)
		_edge_point(out, b, c, sb, sc, ax, ay, pnt)
		_edge_point(out, c, a, sc, sa, ax, ay, pnt)
	return out


func _edge_point(out: PackedVector2Array, a: Vector3, b: Vector3, sa: float, sb: float, ax: Vector3, ay: Vector3, pnt: Vector3) -> void:
	if sa * sb > 0.0:
		return
	if sa == 0.0 and sb == 0.0:
		return
	var hit: Vector3
	if sa == 0.0:
		hit = a
	elif sb == 0.0:
		hit = b
	else:
		hit = a.lerp(b, sa / (sa - sb))
	out.append(Vector2((hit - pnt).dot(ax), (hit - pnt).dot(ay)))


func _intersect_segments(verts: PackedVector3Array, idx: PackedInt32Array, pnt: Vector3, n: Vector3, x: Vector3, y: Vector3, exclude_limbs: bool, limb_caps: Array) -> Array:
	var segs: Array = []
	var tri_n := idx.size() / 3 if idx.size() >= 3 else verts.size() / 3
	for t in tri_n:
		var ia: int
		var ib: int
		var ic: int
		if idx.size() >= 3:
			ia = idx[t * 3]
			ib = idx[t * 3 + 1]
			ic = idx[t * 3 + 2]
		else:
			ia = t * 3
			ib = t * 3 + 1
			ic = t * 3 + 2
		if ia < 0 or ib < 0 or ic < 0 or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
			continue
		var a: Vector3 = verts[ia]
		var b: Vector3 = verts[ib]
		var c: Vector3 = verts[ic]
		if exclude_limbs and _in_limb(a, limb_caps) and _in_limb(b, limb_caps) and _in_limb(c, limb_caps):
			continue
		var sa := (a - pnt).dot(n)
		var sb := (b - pnt).dot(n)
		var sc := (c - pnt).dot(n)
		var hits: Array = []
		_edge_hit(hits, a, b, sa, sb, pnt, n)
		_edge_hit(hits, b, c, sb, sc, pnt, n)
		_edge_hit(hits, c, a, sc, sa, pnt, n)
		if hits.size() == 2:
			var p0: Vector3 = hits[0]
			var p1: Vector3 = hits[1]
			if p0.distance_squared_to(p1) < 1e-12:
				continue
			if exclude_limbs and (_in_limb(p0, limb_caps) or _in_limb(p1, limb_caps)):
				continue
			segs.append([Vector2(p0.dot(x) - pnt.dot(x), p0.dot(y) - pnt.dot(y)), Vector2(p1.dot(x) - pnt.dot(x), p1.dot(y) - pnt.dot(y))])
	return segs


func _edge_hit(hits: Array, a: Vector3, b: Vector3, sa: float, sb: float, _pnt: Vector3, _n: Vector3) -> void:
	if sa == 0.0 and sb == 0.0:
		return
	if sa == 0.0:
		hits.append(a)
		return
	if sb == 0.0:
		hits.append(b)
		return
	if sa * sb > 0.0:
		return
	var t := sa / (sa - sb)
	hits.append(a.lerp(b, clampf(t, 0.0, 1.0)))


func _in_limb(p: Vector3, caps: Array) -> bool:
	for li in caps:
		var a: Vector3 = li["a"]
		var b: Vector3 = li["b"]
		var r: float = float(li["r"]) + 0.008
		var ab := b - a
		var den := ab.length_squared()
		var u := clampf((p - a).dot(ab) / den, 0.0, 1.0) if den > 1e-10 else 0.0
		if p.distance_to(a + ab * u) <= r:
			return true
	return false


func _stitch(segs: Array, gap: float = -1.0) -> Array:
	# 返回闭合（或已尽量闭合）的多边形（PackedVector2Array 列表）
	if segs.is_empty():
		return []
	var close := GAP_CLOSE if gap < 0.0 else gap
	var close_sq := close * close
	var used := PackedByteArray()
	used.resize(segs.size())
	var loops: Array = []
	for start in segs.size():
		if used[start] != 0:
			continue
		used[start] = 1
		var chain: Array = [segs[start][0], segs[start][1]]
		var grown := true
		while grown:
			grown = false
			var head: Vector2 = chain[0]
			var tail: Vector2 = chain[chain.size() - 1]
			for i in segs.size():
				if used[i] != 0:
					continue
				var a: Vector2 = segs[i][0]
				var b: Vector2 = segs[i][1]
				if tail.distance_squared_to(a) <= close_sq:
					chain.append(b)
					used[i] = 1
					grown = true
					break
				if tail.distance_squared_to(b) <= close_sq:
					chain.append(a)
					used[i] = 1
					grown = true
					break
				if head.distance_squared_to(a) <= close_sq:
					chain.insert(0, b)
					used[i] = 1
					grown = true
					break
				if head.distance_squared_to(b) <= close_sq:
					chain.insert(0, a)
					used[i] = 1
					grown = true
					break
		if chain.size() < 3:
			continue
		var h: Vector2 = chain[0]
		var t2: Vector2 = chain[chain.size() - 1]
		if h.distance_to(t2) <= close * 2.5:
			if t2.distance_squared_to(h) > 1e-12:
				chain.append(h)
		else:
			# 仍开口：若两端不太远，直接封口；否则丢掉短碎段。
			if h.distance_to(t2) < maxf(0.012, close) and chain.size() >= 6:
				chain.append(h)
			else:
				continue
		var poly := PackedVector2Array()
		for p in chain:
			if poly.is_empty() or poly[poly.size() - 1].distance_squared_to(p) > 1e-12:
				poly.append(p)
		if poly.size() >= 3:
			loops.append(poly)
	return loops



func _body_silhouette(skin_segs: Array) -> PackedVector2Array:
	# 体表交点先按 3 mm 栅格去重，凸包只要轮廓。
	var seen := {}
	var pts := PackedVector2Array()
	for s in skin_segs:
		for q in [s[0], s[1]]:
			var key := Vector2i(int(round(q.x * 333.0)), int(round(q.y * 333.0)))
			if seen.has(key):
				continue
			seen[key] = true
			pts.append(q)
	return _convex_hull(pts)


func _convex_hull(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var arr: Array = []
	for p in pts:
		arr.append(p)
	arr.sort_custom(func(a, b):
		var pa: Vector2 = a
		var pb: Vector2 = b
		return pa.x < pb.x or (is_equal_approx(pa.x, pb.x) and pa.y < pb.y)
	)
	var lower: Array = []
	for p2 in arr:
		while lower.size() >= 2 and _cross(lower[lower.size() - 2], lower[lower.size() - 1], p2) <= 0.0:
			lower.pop_back()
		lower.append(p2)
	var upper: Array = []
	var i := arr.size() - 1
	while i >= 0:
		var p3: Vector2 = arr[i]
		while upper.size() >= 2 and _cross(upper[upper.size() - 2], upper[upper.size() - 1], p3) <= 0.0:
			upper.pop_back()
		upper.append(p3)
		i -= 1
	if not lower.is_empty():
		lower.pop_back()
	if not upper.is_empty():
		upper.pop_back()
	var out := PackedVector2Array()
	for q in lower:
		out.append(q)
	for q2 in upper:
		out.append(q2)
	return out


func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


func _stamp_insert(codes: PackedInt32Array, gw: int, gh: int, hw: float, hh: float, origin: Vector3, ax: Vector3, ay: Vector3, insert: Dictionary) -> void:
	var c: Vector3 = insert.get("center", Vector3.ZERO)
	var R: float = float(insert.get("radius", 0.0))
	if R <= 1e-6:
		return
	var inward: Vector3 = insert.get("axis", Vector3.ZERO)
	if inward.length_squared() > 1e-12:
		inward = inward.normalized()
	else:
		inward = Vector3.ZERO
	var sr: float = float(insert.get("shaft_radius", 0.004))
	var slen: float = float(insert.get("shaft_len", 0.18))
	var cw := (hw * 2.0) / float(gw)
	var ch := (hh * 2.0) / float(gh)
	var a := c - inward * (R * 0.10)
	var b := c - inward * (R * 0.10 + slen)
	var ab := b - a
	var ab2 := maxf(ab.dot(ab), 1e-12)
	var slop := 0.0005
	for row in gh:
		var v := -hh + (float(row) + 0.5) * ch
		for col in gw:
			var u := -hw + (float(col) + 0.5) * cw
			var p: Vector3 = origin + ax * u + ay * v
			var inside := p.distance_to(c) <= R + slop
			if not inside and inward != Vector3.ZERO and sr > 1e-6:
				var t := clampf((p - a).dot(ab) / ab2, 0.0, 1.0)
				if (p - (a + ab * t)).length() <= sr + slop:
					inside = true
			if inside:
				codes[row * gw + col] = C_ROD


func _paint_organ(codes: PackedInt32Array, gw: int, gh: int, hw: float, hh: float, loops: Array, wall_code: int, lumen_code: int) -> void:

	if loops.is_empty():
		return
	# 按面积从大到小：大圈先涂壁，完全落在另一圈里的涂管腔。
	var recs: Array = []
	for lp in loops:
		var area := _poly_area(lp)
		if absf(area) < 1e-8:
			continue
		recs.append({"poly": lp, "area": absf(area), "cent": _poly_cent(lp)})
	recs.sort_custom(func(a, b): return float(a["area"]) > float(b["area"]))
	var is_hole := PackedByteArray()
	is_hole.resize(recs.size())
	for i in recs.size():
		var ci: Vector2 = recs[i]["cent"]
		for j in i:
			if _point_in_poly(ci, recs[j]["poly"]):
				is_hole[i] = 1
				break
	for i2 in recs.size():
		var code := lumen_code if is_hole[i2] == 1 else wall_code
		_fill_poly(codes, gw, gh, hw, hh, recs[i2]["poly"], code)


func _poly_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var j := (i + 1) % p.size()
		a += p[i].x * p[j].y - p[j].x * p[i].y
	return 0.5 * a


func _poly_cent(p: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for q in p:
		c += q
	return c / float(maxi(p.size(), 1))


func _point_in_poly(pt: Vector2, p: PackedVector2Array) -> bool:
	var inside := false
	var j := p.size() - 1
	for i in p.size():
		var yi := p[i].y
		var yj := p[j].y
		if ((yi > pt.y) != (yj > pt.y)) and (pt.x < (p[j].x - p[i].x) * (pt.y - yi) / maxf(yj - yi, 1e-12) + p[i].x):
			inside = not inside
		j = i
	return inside


func _fill_poly(codes: PackedInt32Array, gw: int, gh: int, hw: float, hh: float, poly: PackedVector2Array, code: int) -> void:
	# 扫描线偶奇填充。
	var cw := (hw * 2.0) / float(gw)
	var ch := (hh * 2.0) / float(gh)
	# 包围盒
	var miny := 1e9
	var maxy := -1e9
	for p in poly:
		miny = minf(miny, p.y)
		maxy = maxf(maxy, p.y)
	var y0 := clampi(int(floor((miny + hh) / ch)), 0, gh - 1)
	var y1 := clampi(int(ceil((maxy + hh) / ch)), 0, gh - 1)
	for row in range(y0, y1 + 1):
		var y := -hh + (float(row) + 0.5) * ch
		var xs: Array = []
		var n := poly.size()
		for i in n:
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % n]
			if (a.y > y) == (b.y > y):
				continue
			var t := (y - a.y) / maxf(b.y - a.y, 1e-12)
			xs.append(a.x + (b.x - a.x) * t)
		xs.sort()
		var k := 0
		while k + 1 < xs.size():
			var x_a: float = xs[k]
			var x_b: float = xs[k + 1]
			var c0 := clampi(int(floor((x_a + hw) / cw)), 0, gw - 1)
			var c1 := clampi(int(ceil((x_b + hw) / cw)), 0, gw)
			for col in range(c0, c1):
				var cur := codes[row * gw + col]
				if cur == C_OUT:
					continue
				codes[row * gw + col] = code
			k += 2


func _draw_seg(codes: PackedInt32Array, gw: int, gh: int, hw: float, hh: float, a: Vector2, b: Vector2, code: int, radius: int) -> void:
	var cw := (hw * 2.0) / float(gw)
	var ch := (hh * 2.0) / float(gh)
	var ax := int(round((a.x + hw) / cw))
	var ay := int(round((a.y + hh) / ch))
	var bx := int(round((b.x + hw) / cw))
	var by := int(round((b.y + hh) / ch))
	var dx := absi(bx - ax)
	var dy := -absi(by - ay)
	var sx := 1 if ax < bx else -1
	var sy := 1 if ay < by else -1
	var err := dx + dy
	var x := ax
	var y := ay
	while true:
		_stamp(codes, gw, gh, x, y, code, radius)
		if x == bx and y == by:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy


func _stamp(codes: PackedInt32Array, gw: int, gh: int, x: int, y: int, code: int, radius: int) -> void:
	for oy in range(-radius, radius + 1):
		for ox in range(-radius, radius + 1):
			if ox * ox + oy * oy > radius * radius + 1:
				continue
			var xx := x + ox
			var yy := y + oy
			if xx < 0 or yy < 0 or xx >= gw or yy >= gh:
				continue
			codes[yy * gw + xx] = code


func _dilate_mask(codes: PackedInt32Array, gw: int, gh: int, src: int, radius: int) -> void:
	if radius <= 0:
		return
	var copy := codes.duplicate()
	for y in gh:
		for x in gw:
			if copy[y * gw + x] != src:
				continue
			_stamp(codes, gw, gh, x, y, src, radius)



func _erode_mask(codes: PackedInt32Array, gw: int, gh: int, src: int, radius: int) -> void:
	if radius <= 0:
		return
	var copy := codes.duplicate()
	for y in gh:
		for x in gw:
			if copy[y * gw + x] != src:
				continue
			var keep := true
			for oy in range(-radius, radius + 1):
				if not keep:
					break
				for ox in range(-radius, radius + 1):
					if ox * ox + oy * oy > radius * radius + 1:
						continue
					var xx := x + ox
					var yy := y + oy
					if xx < 0 or yy < 0 or xx >= gw or yy >= gh or copy[yy * gw + xx] != src:
						keep = false
						break
			if not keep:
				codes[y * gw + x] = 0



func _flood_outside(codes: PackedInt32Array, gw: int, gh: int) -> void:
	var stack := PackedInt32Array()
	var push := func(x: int, y: int) -> void:
		if x < 0 or y < 0 or x >= gw or y >= gh:
			return
		var i := y * gw + x
		if codes[i] != 0:
			return
		codes[i] = C_OUT
		stack.append(i)
	for x in gw:
		push.call(x, 0)
		push.call(x, gh - 1)
	for y in gh:
		push.call(0, y)
		push.call(gw - 1, y)
	while stack.size() > 0:
		var i2 := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var x2 := i2 % gw
		var y2 := int(i2 / gw)
		push.call(x2 + 1, y2)
		push.call(x2 - 1, y2)
		push.call(x2, y2 + 1)
		push.call(x2, y2 - 1)


func _emit_run(mv: PackedVector3Array, mc: PackedColorArray, mi: PackedInt32Array, origin: Vector3, ax: Vector3, ay: Vector3, hw: float, hh: float, cw: float, ch: float, c0: int, c1: int, row: int, code: int) -> void:
	var col: Color = color_of(code)
	var u0 := -hw + float(c0) * cw
	var u1 := -hw + float(c1) * cw
	var v0 := -hh + float(row) * ch
	var v1 := -hh + float(row + 1) * ch
	var p00 := origin + ax * u0 + ay * v0
	var p10 := origin + ax * u1 + ay * v0
	var p11 := origin + ax * u1 + ay * v1
	var p01 := origin + ax * u0 + ay * v1
	var b := mv.size()
	mv.append_array([p00, p10, p11, p01])
	mc.append_array([col, col, col, col])
	mi.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
