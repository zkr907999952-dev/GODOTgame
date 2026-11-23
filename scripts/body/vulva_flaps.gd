extends RefCounted
## 0.4.05：外阴皮肤分瓣（为之后「拨开外阴露出阴道通道」做准备）。
##
## 从躯干皮肤（Dress）网格里把外阴一小块（中线两侧各 REGION_HALF_X、z 在 Z0..Z1、外阴最低点以上 REGION_DY 内）
## 剪出来，做成独立的 MeshInstance3D「VulvaFlaps」：两个 surface = 左瓣（+X）/ 右瓣（-X）。
## 中线顶点左右各复制一份 → 两瓣沿中线（阴道口所在的裂隙）分开；外圈顶点与身体网格同位置、同法线、
## 同蒙皮、同材质，默认（spread = 0）与原来完全一样、看不出接缝。
##
## API：
##   build(dress_mi, vulva_point, canal_opening) -> bool    构建（只做一次）
##   set_spread(amount)        0 = 合拢（默认），1 = 完全拨开。每瓣绕自己的铰链轴（外缘，沿裂隙方向）
##                             向外翻 amount × MAX_ANGLE，越靠中线转得越多、前后联合处不动。
##   spread() / side_vertices(side) / hinge(side) -> [point, axis] / gap_width() / canal_opening()
##   flaps_mi：可直接拿去做别的工具（例如以后的拨开工具）。

const REGION_HALF_X := 0.017
const REGION_DY := 0.010
const Z0 := 0.030
const Z1 := 0.080
const MAX_ANGLE := deg_to_rad(55.0)

var flaps_mi: MeshInstance3D
var ok := false
var vulva := Vector3.ZERO
var opening := Vector3.ZERO
var slit_dir := Vector3(0, 0, 1)
var removed_faces := 0
var slit_verts := 0

var _arrays := [[], []]          # 每侧 surface 的原始数组
var _w := [PackedFloat32Array(), PackedFloat32Array()]
var _orders := [PackedInt32Array(), PackedInt32Array()]
var _hinge_p := [Vector3.ZERO, Vector3.ZERO]
var _mat: Material
var _spread := 0.0
var _am: ArrayMesh


func build(dress: MeshInstance3D, vulva_point: Vector3, canal_opening: Vector3, mouth_loop: PackedVector3Array = PackedVector3Array()) -> bool:
	if dress == null or dress.mesh == null or dress.mesh.get_surface_count() < 1:
		return false
	vulva = vulva_point
	opening = canal_opening
	var src := dress.mesh as ArrayMesh
	var arr := src.surface_get_arrays(0)
	var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	if idx.is_empty() or src.get_blend_shape_count() > 0:
		return false
	_vcount = pos.size()
	_flags = _fmt_flags(src, 0)
	var inside := func(p: Vector3) -> bool:
		return absf(p.x) <= REGION_HALF_X and p.z >= Z0 and p.z <= Z1 and p.y <= vulva.y + REGION_DY and p.y >= vulva.y - 0.01
	var keep := PackedInt32Array()
	var side_l := PackedInt32Array()
	var side_r := PackedInt32Array()
	for f in idx.size() / 3:
		var a := idx[f * 3]
		var b := idx[f * 3 + 1]
		var c := idx[f * 3 + 2]
		if inside.call((pos[a] + pos[b] + pos[c]) / 3.0):
			var cx := (pos[a].x + pos[b].x + pos[c].x) / 3.0
			if cx >= 0.0:
				side_l.append_array([a, b, c])
			else:
				side_r.append_array([a, b, c])
		else:
			keep.append_array([a, b, c])
	var sides: Array = [side_l, side_r]
	removed_faces = (side_l.size() + side_r.size()) / 3
	# 0.4.08：原皮肤在前联合处有一个小破洞（能看到里面的膀胱），先补上。
	holes_filled = 0
	if side_l.size() >= 9 and side_r.size() >= 9:
		var used0 := {}
		for v0 in keep:
			used0[v0] = true
		side_l = _fill_holes(side_l, pos, used0)
		side_r = _fill_holes(side_r, pos, used0)
		sides = [side_l, side_r]
	if sides[0].size() < 9 or sides[1].size() < 9:
		var nin := 0
		for p0 in pos:
			if inside.call(p0):
				nin += 1
		var near := 0
		var bb := AABB()
		for p1 in pos:
			if absf(p1.x) < 0.02 and absf(p1.y - vulva.y) < 0.02:
				near += 1
				bb = AABB(p1, Vector3.ZERO) if near == 1 else bb.expand(p1)
		print("vulva: region faces ", side_l.size() / 3, " / ", side_r.size() / 3)
		return false
	# 中线（裂隙）方向：区域内中线顶点按 z 排序的首尾
	var mid: Array = []
	for f2 in [sides[0], sides[1]]:
		for v in f2:
			if absf(pos[v].x) < 1e-4 and not mid.has(v):
				mid.append(v)
	slit_verts = mid.size()
	if mid.size() >= 2:
		mid.sort_custom(func(u, w): return pos[u].z < pos[w].z)
		slit_dir = (pos[mid[mid.size() - 1]] - pos[mid[0]]).normalized()
	_mat = dress.get_surface_override_material(0)
	if _mat == null:
		_mat = dress.get_active_material(0)
	# 每侧一个 surface（重新编号）；中线顶点在两侧各有一份 = 裂隙
	for si in 2:
		var fl: PackedInt32Array = sides[si]
		var remap := {}
		var order := PackedInt32Array()
		for v in fl:
			if not remap.has(v):
				remap[v] = order.size()
				order.append(v)
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		for k in Mesh.ARRAY_MAX:
			if k == Mesh.ARRAY_INDEX or arr[k] == null:
				continue
			out[k] = _gather(arr[k], order, k)
		var ni := PackedInt32Array()
		for v in fl:
			ni.append(int(remap[v]))
		out[Mesh.ARRAY_INDEX] = ni
		_arrays[si] = out
		_orders[si] = order
		# 转动权重：中线 1 → 外缘 0；沿裂隙两端（前后联合）也渐变到 0
		var w := PackedFloat32Array()
		var lo := INF
		var hi := -INF
		for v in order:
			var t0 := pos[v].dot(slit_dir)
			lo = minf(lo, t0)
			hi = maxf(hi, t0)
		for v in order:
			var p := pos[v]
			var wx := clampf(1.0 - absf(p.x) / REGION_HALF_X, 0.0, 1.0)
			var t := (p.dot(slit_dir) - lo) / maxf(hi - lo, 1e-5)
			var wt := clampf(sin(PI * clampf(t, 0.0, 1.0)) * 1.6, 0.0, 1.0)
			w.append(wx * wt)
		_w[si] = w
		var sg := 1.0 if si == 0 else -1.0
		_hinge_p[si] = Vector3(sg * REGION_HALF_X, vulva.y, (Z0 + Z1) * 0.5)
	# 身体网格去掉这一块（保留其余 surface 与蒙皮）
	var body := ArrayMesh.new()
	for sidx in src.get_surface_count():
		var a2 := src.surface_get_arrays(sidx)
		if sidx == 0:
			a2[Mesh.ARRAY_INDEX] = keep
		body.add_surface_from_arrays(src.surface_get_primitive_type(sidx), a2, [], {}, _fmt_flags(src, sidx))
		body.surface_set_material(sidx, src.surface_get_material(sidx))
	body.resource_name = src.resource_name
	var ovr: Array = []
	for sidx2 in dress.get_surface_override_material_count():
		ovr.append(dress.get_surface_override_material(sidx2))
	dress.mesh = body
	for sidx3 in ovr.size():
		dress.set_surface_override_material(sidx3, ovr[sidx3])
	flaps_mi = MeshInstance3D.new()
	flaps_mi.name = "VulvaFlaps"
	_am = ArrayMesh.new()
	flaps_mi.mesh = _am
	flaps_mi.skin = dress.skin
	flaps_mi.layers = dress.layers
	flaps_mi.cast_shadow = dress.cast_shadow
	dress.get_parent().add_child(flaps_mi)
	flaps_mi.skeleton = flaps_mi.get_path_to(dress.get_node(dress.skeleton)) if not dress.skeleton.is_empty() else NodePath()
	flaps_mi.transform = dress.transform
	ok = true
	_build_rim(keep, sides, pos)
	_mouth = mouth_loop
	if _rim.size() >= 6 and _mouth.size() >= 6:
		_setup_vestibule(dress)
	_commit()
	return true


var holes_filled := 0


## 区域内（不含中线裂隙、不含与身体相连的外缘）的开放边界 = 原网格的破洞 → 扇形三角补洞。
## 返回补好的索引数组（Packed 数组按值传递）。
func _fill_holes(fl: PackedInt32Array, pos: PackedVector3Array, used: Dictionary) -> PackedInt32Array:
	var cnt := {}
	var dir := {}
	for f in fl.size() / 3:
		for k in 3:
			var a := fl[f * 3 + k]
			var b := fl[f * 3 + (k + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			cnt[key] = int(cnt.get(key, 0)) + 1
			dir[key] = Vector2i(a, b)
	var nxt := {}
	var has_in := {}
	for key in cnt.keys():
		if int(cnt[key]) != 1:
			continue
		var e: Vector2i = dir[key]
		if used.has(e.x) and used.has(e.y):
			continue  # 与身体相连的外缘
		if absf(pos[e.x].x) < 1e-4 and absf(pos[e.y].x) < 1e-4:
			continue  # 中线裂隙
		nxt[e.x] = e.y
		has_in[e.y] = true
	var starts: Array = []
	for v in nxt.keys():
		if not has_in.has(v):
			starts.append(v)
	for v in nxt.keys():
		if not starts.has(v):
			starts.append(v)
	var out := fl
	var seen := {}
	for st in starts:
		if seen.has(st):
			continue
		var path: Array = [st]
		seen[st] = true
		var cur: int = st
		while nxt.has(cur) and path.size() < 40:
			cur = nxt[cur]
			if seen.has(cur):
				break
			path.append(cur)
			seen[cur] = true
		if path.size() < 3:
			continue
		var bb := AABB(pos[path[0]], Vector3.ZERO)
		for v in path:
			bb = bb.expand(pos[v])
		if bb.size.length() > 0.02:
			continue
		# 边界走向与所在三角形同向 → 补洞三角形反向绕（与周围面同朝向）
		for i in range(1, path.size() - 1):
			out.append_array([path[0], path[i + 1], path[i]])
			holes_filled += 1
	return out


func _fmt_flags(src: ArrayMesh, sidx: int) -> int:
	# 只保留需要显式声明的格式标志（自定义通道格式、骨骼数 8 等）
	var f := src.surface_get_format(sidx)
	var keep := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
	for ch in 4:
		keep |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << (Mesh.ARRAY_FORMAT_CUSTOM_BASE + ch * Mesh.ARRAY_FORMAT_CUSTOM_BITS)
	return f & keep


func _gather(a, order: PackedInt32Array, k: int):
	var per := 1
	if k == Mesh.ARRAY_TANGENT:
		per = 4
	elif k == Mesh.ARRAY_BONES or k == Mesh.ARRAY_WEIGHTS:
		per = (a.size() / maxi(1, _vcount)) if _vcount > 0 else 4
	elif k >= Mesh.ARRAY_CUSTOM0 and k <= Mesh.ARRAY_CUSTOM3:
		per = (a.size() / maxi(1, _vcount)) if _vcount > 0 else 4
	if a is PackedVector3Array:
		var o3 := PackedVector3Array()
		for v in order:
			o3.append(a[v])
		return o3
	if a is PackedVector2Array:
		var o2 := PackedVector2Array()
		for v in order:
			o2.append(a[v])
		return o2
	if a is PackedColorArray:
		var oc := PackedColorArray()
		for v in order:
			oc.append(a[v])
		return oc
	if a is PackedFloat32Array:
		var of := PackedFloat32Array()
		for v in order:
			for j in per:
				of.append(a[v * per + j])
		return of
	if a is PackedInt32Array:
		var oi := PackedInt32Array()
		for v in order:
			for j in per:
				oi.append(a[v * per + j])
		return oi
	if a is PackedByteArray:
		var ob := PackedByteArray()
		for v in order:
			for j in per:
				ob.append(a[v * per + j])
		return ob
	return null


var _vcount := 0


func set_spread(amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if not ok or absf(amount - _spread) < 1e-5:
		_spread = amount
		return
	_spread = amount
	_commit()


func spread() -> float:
	return _spread


func hinge(side: int) -> Array:
	return [_hinge_p[0 if side >= 0 else 1], slit_dir]


func canal_opening() -> Vector3:
	return opening


## 当前（绑定空间）裂隙两侧同一原顶点的两份之间的最大距离（合拢时 = 0）。
func gap_width() -> float:
	var pl := side_positions(0)
	var pr := side_positions(1)
	var at_r := {}
	var orr: PackedInt32Array = _orders[1]
	for j in orr.size():
		at_r[orr[j]] = j
	var best := 0.0
	var ol: PackedInt32Array = _orders[0]
	for i in ol.size():
		if at_r.has(ol[i]):
			best = maxf(best, pl[i].distance_to(pr[int(at_r[ol[i]])]))
	return best


func side_positions(si: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ok:
		return out
	var src: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX]
	var ang := _spread * MAX_ANGLE
	var sg := 1.0 if si == 0 else -1.0
	for i in src.size():
		out.append(_rot(src[i], si, ang * _w[si][i] * sg))
	return out


func _rot(p: Vector3, si: int, a: float) -> Vector3:
	if absf(a) < 1e-6:
		return p
	var h: Vector3 = _hinge_p[si]
	# 绕外缘铰链轴（沿裂隙）转：中线一侧往外下方翻开
	return h + (p - h).rotated(slit_dir, a)


func _commit() -> void:
	_am.clear_surfaces()
	var ang := _spread * MAX_ANGLE
	for si in 2:
		var a: Array = (_arrays[si] as Array).duplicate()
		var sg := 1.0 if si == 0 else -1.0
		if ang > 1e-6:
			var P: PackedVector3Array = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
			var N: PackedVector3Array = (a[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate() if a[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			for i in P.size():
				var t: float = ang * _w[si][i] * sg
				P[i] = _rot(P[i], si, t)
				if i < N.size():
					N[i] = N[i].rotated(slit_dir, t)
			a[Mesh.ARRAY_VERTEX] = P
			if N.size() > 0:
				a[Mesh.ARRAY_NORMAL] = N
		_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, _flags)
		_am.surface_set_name(si, "VulvaLeft" if si == 0 else "VulvaRight")
		if _mat:
			flaps_mi.set_surface_override_material(si, _mat)
	_commit_vestibule()


# ------------------------------------------------------------------ 0.4.08 前庭（裂隙边缘 → 阴道外口）
## 两瓣之间的开口边缘（每瓣内侧的开放边，左瓣前→后 + 右瓣后→前 = 一圈）与阴道通道内层黏膜外口那一圈
## 之间做一圈黏膜管（前庭）。外圈顶点每帧取两瓣转动后的位置（与皮瓣边缘完全重合），内圈固定在通道外口
## → 任何拨开程度下皮肤与通道之间都没有缝隙，看进去是连续的粉色黏膜一直通到阴道内。
const VEST_N := 28
const VEST_ROWS := 4
var vest_mi: MeshInstance3D
var _rim: Array = []            # [[side, local_index], …] 一圈
var _mouth := PackedVector3Array()
var _rim_s: Array = []          # 每个采样：[ia, ib, f]（_rim 下标）
var _mouth_s := PackedVector3Array()
var _vest_bones := PackedInt32Array()
var _vest_w := PackedFloat32Array()
var _vest_per := 4
var _vest_am: ArrayMesh
var _vest_mat: StandardMaterial3D
var vest_tris := 0


## 0.4.08：手指落点——每瓣靠裂隙一侧（距中线约 8.5mm、裂隙中段）的大阴唇皮肤点，
## 返回 [位置, 外法线]（绑定空间，随当前拨开角度转动）。
var _contact_i := [-1, -1]


func contact(side: int) -> Array:
	var si := 0 if side == 0 else 1
	if not ok:
		return [vulva, Vector3(0, -1, 0)]
	var src: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX]
	if int(_contact_i[si]) < 0:
		var sg := 1.0 if si == 0 else -1.0
		var want := Vector3(sg * 0.0085, vulva.y + 0.002, vulva.z + 0.004)
		var best := 0
		var bd := INF
		for i in src.size():
			var d := src[i].distance_squared_to(want)
			if d < bd:
				bd = d
				best = i
		_contact_i[si] = best
	var i0: int = _contact_i[si]
	var sg2 := 1.0 if si == 0 else -1.0
	var a: float = _spread * MAX_ANGLE * float(_w[si][i0]) * sg2
	var nn: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_NORMAL]
	var n := nn[i0] if i0 < nn.size() else Vector3(0, -1, 0)
	return [_rot(src[i0], si, a), n.rotated(slit_dir, a).normalized() if absf(a) > 1e-6 else n.normalized()]


func rim_size() -> int:
	return _rim.size()


func mouth_loop() -> PackedVector3Array:
	return _mouth


## 当前拨开程度下，开口边缘一圈的位置（绑定空间）。
func rim_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	if _rim.is_empty():
		return out
	var pl := side_positions(0)
	var pr := side_positions(1)
	for e in _rim:
		out.append(pl[e[1]] if int(e[0]) == 0 else pr[e[1]])
	return out


func _build_rim(keep: PackedInt32Array, sides: Array, dress_pos: PackedVector3Array) -> void:
	_rim.clear()
	var used := {}
	for v in keep:
		used[v] = true
	var chains: Array = []
	for si in 2:
		var fl: PackedInt32Array = sides[si]
		var cnt := {}
		for f in fl.size() / 3:
			for k in 3:
				var a := fl[f * 3 + k]
				var b := fl[f * 3 + (k + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				cnt[key] = int(cnt.get(key, 0)) + 1
		var adj := {}
		for key in cnt.keys():
			if int(cnt[key]) != 1:
				continue
			var e: Vector2i = key
			if used.has(e.x) and used.has(e.y):
				continue  # 区域外缘（与身体网格相连）
			if not adj.has(e.x):
				adj[e.x] = []
			if not adj.has(e.y):
				adj[e.y] = []
			adj[e.x].append(e.y)
			adj[e.y].append(e.x)
		# 最长的一条链（从度为 1 的端点出发）
		# 从端点（度 1，或与身体相连的前后联合顶点）出发，优先走最靠中线的边；碰到与身体相连的顶点即终止。
		var src_p: PackedVector3Array = dress_pos
		var best: Array = []
		for st in adj.keys():
			if (adj[st] as Array).size() != 1 and not used.has(st):
				continue
			var path: Array = [st]
			var cur: int = st
			while true:
				var nxt := -1
				var bx := INF
				for w in adj[cur]:
					if path.has(w):
						continue
					var ax := absf(src_p[int(w)].x)
					if ax < bx:
						bx = ax
						nxt = int(w)
				if nxt < 0:
					break
				path.append(nxt)
				cur = nxt
				if used.has(nxt):
					break
			var sc := 0.0
			for v in path:
				sc += 1.0 - clampf(absf(src_p[int(v)].x) / 0.003, 0.0, 0.9)
			if path.size() >= 3 and (best.is_empty() or sc > float(best[0])):
				best = [sc, path]
		best = best[1] if not best.is_empty() else []
		chains.append(best)
	var cl: Array = chains[0]
	var cr: Array = chains[1]
	if cl.size() < 3 or cr.size() < 3:
		return
	var src: PackedVector3Array = (_arrays[0] as Array)[Mesh.ARRAY_VERTEX]
	var srcr: PackedVector3Array = (_arrays[1] as Array)[Mesh.ARRAY_VERTEX]
	var ol: PackedInt32Array = _orders[0]
	var orr: PackedInt32Array = _orders[1]
	var li := {}
	for i in ol.size():
		li[ol[i]] = i
	var ri := {}
	for i in orr.size():
		ri[orr[i]] = i
	# 左链：前（z 大）→ 后；右链：后 → 前
	if src[li[cl[0]]].dot(slit_dir) < src[li[cl[cl.size() - 1]]].dot(slit_dir):
		cl.reverse()
	if srcr[ri[cr[0]]].dot(slit_dir) > srcr[ri[cr[cr.size() - 1]]].dot(slit_dir):
		cr.reverse()
	for v in cl:
		_rim.append([0, int(li[v])])
	for j in cr.size():
		var v2: int = cr[j]
		# 前后联合处两链共用同一原顶点：只留一份
		if (j == 0 and v2 == cl[cl.size() - 1]) or (j == cr.size() - 1 and v2 == cl[0]):
			continue
		_rim.append([1, int(ri[v2])])


func _loop_params(P: PackedVector3Array) -> PackedFloat32Array:
	var acc := PackedFloat32Array([0.0])
	var tot := 0.0
	for i in P.size():
		tot += P[i].distance_to(P[(i + 1) % P.size()])
		acc.append(tot)
	for i in acc.size():
		acc[i] = acc[i] / maxf(tot, 1e-6)
	return acc


func _sample_idx(par: PackedFloat32Array, n: int, u: float) -> Array:
	u = fposmod(u, 1.0)
	for i in n:
		if u <= par[i + 1]:
			var f := (u - par[i]) / maxf(par[i + 1] - par[i], 1e-6)
			return [i, (i + 1) % n, f]
	return [n - 1, 0, 1.0]


func _setup_vestibule(dress: MeshInstance3D) -> void:
	# 参数化在完全拨开时计算（开口最圆），之后固定
	var sp0 := _spread
	_spread = 1.0
	var rim := rim_positions()
	_spread = sp0
	var axis := (opening - vulva).normalized()
	var rc := Vector3.ZERO
	for p in rim:
		rc += p
	rc /= float(rim.size())
	var mc := Vector3.ZERO
	for p in _mouth:
		mc += p
	mc /= float(_mouth.size())
	# 方向一致：投影到垂直于轴的平面后比较绕向
	var e1 := slit_dir - axis * slit_dir.dot(axis)
	e1 = e1.normalized()
	var e2 := axis.cross(e1)
	var area := func(P: PackedVector3Array, c: Vector3) -> float:
		var a := 0.0
		for i in P.size():
			var p0 := P[i] - c
			var p1 := P[(i + 1) % P.size()] - c
			a += p0.dot(e1) * p1.dot(e2) - p1.dot(e1) * p0.dot(e2)
		return a
	var mouth := _mouth.duplicate()
	if signf(area.call(rim, rc)) != signf(area.call(mouth, mc)):
		mouth.reverse()
	# 起点对齐：外口上离开口边缘起点方向最近的点
	var d0 := rim[0] - rc
	var a0 := atan2(d0.dot(e2), d0.dot(e1))
	var best := 0
	var bd := 1e9
	for i in mouth.size():
		var d := mouth[i] - mc
		var da := absf(wrapf(atan2(d.dot(e2), d.dot(e1)) - a0, -PI, PI))
		if da < bd:
			bd = da
			best = i
	var m2 := PackedVector3Array()
	for i in mouth.size():
		m2.append(mouth[(best + i) % mouth.size()])
	_mouth = m2
	var pr := _loop_params(rim)
	var pm := _loop_params(_mouth)
	_rim_s.clear()
	_mouth_s = PackedVector3Array()
	for k in VEST_N:
		var u := float(k) / float(VEST_N)
		_rim_s.append(_sample_idx(pr, rim.size(), u))
		var sm: Array = _sample_idx(pm, _mouth.size(), u)
		_mouth_s.append(_mouth[sm[0]].lerp(_mouth[sm[1]], sm[2]))
	# 蒙皮：每列取开口边缘最近顶点的骨骼 / 权重
	var a_l: Array = _arrays[0]
	var a_r: Array = _arrays[1]
	var nv0: int = (a_l[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_vest_per = 4
	if a_l[Mesh.ARRAY_BONES] != null and nv0 > 0:
		_vest_per = (a_l[Mesh.ARRAY_BONES] as PackedInt32Array).size() / nv0
	_vest_bones = PackedInt32Array()
	_vest_w = PackedFloat32Array()
	for r in VEST_ROWS + 1:
		for k in VEST_N:
			var s0: Array = _rim_s[k]
			var e: Array = _rim[s0[0] if float(s0[2]) < 0.5 else s0[1]]
			var arr: Array = a_l if int(e[0]) == 0 else a_r
			var bi: PackedInt32Array = arr[Mesh.ARRAY_BONES] if arr[Mesh.ARRAY_BONES] != null else PackedInt32Array()
			var wi: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS] if arr[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
			for j in _vest_per:
				var id: int = int(e[1]) * _vest_per + j
				_vest_bones.append(bi[id] if id < bi.size() else 0)
				_vest_w.append(wi[id] if id < wi.size() else (1.0 if j == 0 else 0.0))
	_vest_mat = StandardMaterial3D.new()
	_vest_mat.albedo_color = Color(0.66, 0.33, 0.35)
	_vest_mat.roughness = 0.42
	_vest_mat.metallic_specular = 0.55
	_vest_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_vest_mat.rim_enabled = true
	_vest_mat.rim = 0.25
	_vest_mat.rim_tint = 0.6
	_vest_am = ArrayMesh.new()
	vest_mi = MeshInstance3D.new()
	vest_mi.name = "VulvaVestibule"
	vest_mi.mesh = _vest_am
	vest_mi.skin = dress.skin
	vest_mi.layers = dress.layers
	vest_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dress.get_parent().add_child(vest_mi)
	vest_mi.skeleton = vest_mi.get_path_to(dress.get_node(dress.skeleton)) if not dress.skeleton.is_empty() else NodePath()
	vest_mi.transform = dress.transform


## 前庭当前的顶点（绑定空间）：第 0 行 = 开口边缘，最后一行 = 阴道外口。
func vestibule_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	if _rim_s.is_empty():
		return out
	var rim := rim_positions()
	var top := PackedVector3Array()
	for k in VEST_N:
		var s0: Array = _rim_s[k]
		top.append(rim[s0[0]].lerp(rim[s0[1]], s0[2]))
	var axis := (opening - vulva).normalized()
	for r in VEST_ROWS + 1:
		var t := float(r) / float(VEST_ROWS)
		for k in VEST_N:
			var p := top[k].lerp(_mouth_s[k], t)
			# 中间行略向外鼓（管壁圆润，不是直锥）
			var c := vulva.lerp(opening, t)
			var rad := p - c - axis * (p - c).dot(axis)
			p += rad * 0.12 * sin(PI * t)
			out.append(p)
	return out


func _commit_vestibule() -> void:
	if vest_mi == null or _vest_am == null:
		return
	var P := vestibule_positions()
	var N := PackedVector3Array()
	N.resize(P.size())
	var axis := (opening - vulva).normalized()
	for r in VEST_ROWS + 1:
		var t := float(r) / float(VEST_ROWS)
		var c := vulva.lerp(opening, t)
		for k in VEST_N:
			var p := P[r * VEST_N + k]
			var rad := p - c - axis * (p - c).dot(axis)
			N[r * VEST_N + k] = (-rad.normalized() if rad.length_squared() > 1e-10 else -axis)
	var idx := PackedInt32Array()
	for r in VEST_ROWS:
		for k in VEST_N:
			var a := r * VEST_N + k
			var b := r * VEST_N + (k + 1) % VEST_N
			var c2 := (r + 1) * VEST_N + k
			var d := (r + 1) * VEST_N + (k + 1) % VEST_N
			idx.append_array([a, c2, b, b, c2, d])
	vest_tris = idx.size() / 3
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = P
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_BONES] = _vest_bones
	arr[Mesh.ARRAY_WEIGHTS] = _vest_w
	arr[Mesh.ARRAY_INDEX] = idx
	_vest_am.clear_surfaces()
	_vest_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if _vest_per == 8 else 0)
	_vest_am.surface_set_name(0, "Vestibule")
	vest_mi.set_surface_override_material(0, _vest_mat)


var _flags := 0
