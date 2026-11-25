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
const SUBDIV := 1
const PBD_ITERS := 3
const LAPLACE_ITERS := 4
const MAX_EDGE_STRETCH := 1.85
const ALONG_RANGE := 0.028
const SKIN_FALLOFF := 0.038

var flaps_mi: MeshInstance3D
var ok := false
var vulva := Vector3.ZERO
var opening := Vector3.ZERO
var slit_dir := Vector3(0, 0, 1)
var removed_faces := 0
var slit_verts := 0

var _arrays := [[], []]          # 每侧 surface 的原始数组
var _w := [PackedFloat32Array(), PackedFloat32Array()]
var _iw := [PackedFloat32Array(), PackedFloat32Array()]  # 插入权重：中线高、身体接缝 0，前后联合仍可被撑开
var _pin := [PackedByteArray(), PackedByteArray()]      # 仅身体接缝锁定
var _orders := [PackedInt32Array(), PackedInt32Array()]
var _inserter: RefCounted
var _hinge_p := [Vector3.ZERO, Vector3.ZERO]
var _mat: Material
var _spread := 0.0
var _am: ArrayMesh
## 扩张器插入时撑开阴道外口（与皮瓣 spread 独立）：椭圆半宽 / 半高与混合系数。
var _intro_hx := 0.0
var _intro_hy := 0.0
var _intro_mix := 0.0
var _intro_axis := Vector3(0, 1, 0)
var _intro_up := Vector3(0, 0, 1)
var _intro_sep := 0.0
var _intro_angle := 0.0
var _soft_P := [PackedVector3Array(), PackedVector3Array()]
var _rest_edges := [PackedInt32Array(), PackedInt32Array()]
var _rest_len := [PackedFloat32Array(), PackedFloat32Array()]
var last_step_usec := 0
var _skin_tex: Texture2D
var _adj_off := [PackedInt32Array(), PackedInt32Array()]
var _adj_to := [PackedInt32Array(), PackedInt32Array()]
var _cf_c := Vector3.ZERO
var _cf_ax := Vector3(0, 1, 0)
var _cf_up := Vector3(0, 0, 1)
var _cf_side := Vector3(1, 0, 0)
var _cf_ready := false
var _dress_mi: MeshInstance3D
var _body_am: ArrayMesh
var _body_flags := PackedInt32Array()
var _body_surf: Array = []
var _dress_rest := PackedVector3Array()
var _dress_inf := PackedFloat32Array()
var _dress_near := PackedInt32Array()
var _dress_active := PackedInt32Array()
var _seam_pair_flap := PackedInt32Array()
var _seam_pair_dress := PackedInt32Array()
var _dress_dirty := false


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
		var body_seam := {}
		for kv in keep:
			body_seam[kv] = true
		var pin := PackedByteArray()
		var iw := PackedFloat32Array()
		for v in order:
			var p := pos[v]
			var wx := clampf(1.0 - absf(p.x) / REGION_HALF_X, 0.0, 1.0)
			var tt := (p.dot(slit_dir) - lo) / maxf(hi - lo, 1e-5)
			var wt := clampf(sin(PI * clampf(tt, 0.0, 1.0)) * 1.6, 0.0, 1.0)
			# 与身体切口重合的外缘顶点必须完全不动，否则拨开后面片与躯干之间出现破缝。
			if body_seam.has(v):
				w.append(0.0)
				pin.append(1)
				iw.append(0.0)
			else:
				w.append(wx * wt)
				pin.append(0)
				# 插入权重不在前后联合处掉到 0，否则扩张器上下叶会从联合处穿出。
				iw.append(wx)
		_w[si] = w
		_pin[si] = pin
		_iw[si] = iw
		var sg := 1.0 if si == 0 else -1.0
		_hinge_p[si] = Vector3(sg * REGION_HALF_X, vulva.y, (Z0 + Z1) * 0.5)
	# 细化和接缝焊接必须在改写身体网格之前：接缝中点要同时写进皮瓣和躯干，避免拉开后面破。
	for _s in SUBDIV:
		for si2 in 2:
			_subdivide_side(si2)
	keep = _weld_body_seam(arr, keep)
	# 身体网格去掉这一块（保留其余 surface 与蒙皮）
	var body := ArrayMesh.new()
	_body_flags = PackedInt32Array()
	for sidx in src.get_surface_count():
		var a2 := src.surface_get_arrays(sidx)
		if sidx == 0:
			a2 = arr.duplicate()
			a2[Mesh.ARRAY_INDEX] = keep
		var fl := _fmt_flags(src, sidx)
		_body_flags.append(fl)
		body.add_surface_from_arrays(src.surface_get_primitive_type(sidx), a2, [], {}, fl)
		body.surface_set_material(sidx, src.surface_get_material(sidx))
	body.resource_name = src.resource_name
	var ovr: Array = []
	for sidx2 in dress.get_surface_override_material_count():
		ovr.append(dress.get_surface_override_material(sidx2))
	dress.mesh = body
	_body_am = body
	_dress_mi = dress
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
	if _mat is ShaderMaterial:
		_skin_tex = (_mat as ShaderMaterial).get_shader_parameter("albedo_tex") as Texture2D
	_build_rim_from_flaps()
	if _rim.size() < 6:
		_build_rim(keep, sides, pos)
	_mouth = mouth_loop
	if _rim.size() >= 6 and _mouth.size() >= 6:
		_setup_vestibule(dress)
	_prepare_soft()
	_capture_dress_soft()
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
		if bb.size.length() > 0.045:
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


## 扩张器在位时把前庭内圈（阴道外口）撑到能容纳闭合叶片的椭圆，与开合滑条无关。
func set_introitus_open(half_x: float, half_y: float, mix: float, axis: Vector3 = Vector3.ZERO, up: Vector3 = Vector3.ZERO, angle_deg: float = 0.0, blade_sep: float = 0.0) -> void:
	var m := clampf(mix, 0.0, 1.0)
	var hx := maxf(half_x, 0.0)
	var hy := maxf(half_y, 0.0)
	var ax := axis
	var u := up
	if ax.length_squared() < 1e-8:
		ax = _intro_axis
	if u.length_squared() < 1e-8:
		u = _intro_up
	ax = ax.normalized()
	u = (u - ax * u.dot(ax))
	if u.length_squared() < 1e-8:
		u = Vector3(0, 0, 1) - ax * ax.z
	u = u.normalized()
	var sep := maxf(blade_sep, 0.0)
	var ang := angle_deg
	if absf(m - _intro_mix) < 1e-4 and absf(hx - _intro_hx) < 1e-5 and absf(hy - _intro_hy) < 1e-5 and absf(sep - _intro_sep) < 1e-5 and absf(ang - _intro_angle) < 1e-3 and ax.dot(_intro_axis) > 0.999 and u.dot(_intro_up) > 0.999:
		return
	_intro_mix = m
	_intro_hx = hx
	_intro_hy = hy
	_intro_axis = ax
	_intro_up = u
	_intro_sep = sep
	_intro_angle = ang
	_sync_envelope_inserter()
	if ok:
		_commit()


## 当前外口在 side / up 平面上的半宽、半高（绑定空间，已含 introitus 撑开）。
func introitus_half_extents() -> Vector2:
	if _mouth_s.is_empty():
		return Vector2.ZERO
	var acc := Vector3.ZERO
	for p in _mouth_s:
		acc += _inflated_mouth_point(p)
	var c := acc / float(_mouth_s.size())
	var ax := _intro_axis.normalized()
	var up := (_intro_up - ax * _intro_up.dot(ax)).normalized()
	if up.length_squared() < 1e-8:
		up = Vector3(0, 0, 1)
	var side := ax.cross(up).normalized()
	var hx := 0.0
	var hy := 0.0
	for p0 in _mouth_s:
		var p := _inflated_mouth_point(p0)
		var r := p - c
		hx = maxf(hx, absf(r.dot(side)))
		hy = maxf(hy, absf(r.dot(up)))
	return Vector2(hx, hy)


func _inflated_mouth_point(p: Vector3) -> Vector3:
	if _intro_mix < 1e-4 or _intro_hx < 1e-5 or _intro_hy < 1e-5 or _mouth_s.is_empty():
		return p
	var acc := Vector3.ZERO
	for q0 in _mouth_s:
		acc += q0
	var c := acc / float(_mouth_s.size())
	var q := _envelope_point(p, c)
	return p.lerp(q, _intro_mix)


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
		# 细分中点的 order 是 -1，不能拿来左右配对，否则合拢时缝宽会被算成整块皮瓣的尺寸。
		if orr[j] >= 0:
			at_r[orr[j]] = j
	var best := 0.0
	var ol: PackedInt32Array = _orders[0]
	for i in ol.size():
		if ol[i] >= 0 and at_r.has(ol[i]):
			best = maxf(best, pl[i].distance_to(pr[int(at_r[ol[i]])]))
	return best


func side_positions(si: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ok:
		return out
	if _soft_P[si].size() == ((_arrays[si] as Array)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		return _soft_P[si]
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
	_cache_intro_frame()
	_step_soft()
	_commit_dress_soft()
	_am.clear_surfaces()
	var ang := _spread * MAX_ANGLE
	for si in 2:
		var a: Array = (_arrays[si] as Array).duplicate()
		var sg := 1.0 if si == 0 else -1.0
		var P: PackedVector3Array = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
		var N: PackedVector3Array = (a[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate() if a[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var Tg = a[Mesh.ARRAY_TANGENT]
		var T := PackedFloat32Array()
		if Tg is PackedFloat32Array:
			T = (Tg as PackedFloat32Array).duplicate()
		var posed: PackedVector3Array = _soft_P[si] if _soft_P[si].size() == P.size() else PackedVector3Array()
		for i in P.size():
			var t: float = ang * _w[si][i] * sg
			var dst: Vector3 = posed[i] if posed.size() == P.size() else _rot(P[i], si, t)
			P[i] = dst
			if posed.size() != P.size() and absf(t) > 1e-6:
				if i < N.size():
					N[i] = N[i].rotated(slit_dir, t)
				if T.size() >= (i + 1) * 4:
					var tv := Vector3(T[i * 4], T[i * 4 + 1], T[i * 4 + 2]).rotated(slit_dir, t)
					T[i * 4] = tv.x
					T[i * 4 + 1] = tv.y
					T[i * 4 + 2] = tv.z
		a[Mesh.ARRAY_VERTEX] = P
		if N.size() > 0:
			a[Mesh.ARRAY_NORMAL] = N
		if T.size() > 0:
			a[Mesh.ARRAY_TANGENT] = T
		_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, _flags)
		_am.surface_set_name(si, "VulvaLeft" if si == 0 else "VulvaRight")
		if _mat:
			flaps_mi.set_surface_override_material(si, _mat)
	_commit_vestibule()


# ------------------------------------------------------------------ 0.4.08 前庭（裂隙边缘 → 阴道外口）
## 两瓣之间的开口边缘（每瓣内侧的开放边，左瓣前→后 + 右瓣后→前 = 一圈）与阴道通道内层黏膜外口那一圈
## 之间做一圈黏膜管（前庭）。外圈顶点每帧取两瓣转动后的位置（与皮瓣边缘完全重合），内圈固定在通道外口
## → 任何拨开程度下皮肤与通道之间都没有缝隙，看进去是连续的粉色黏膜一直通到阴道内。
const VEST_N := 72
const VEST_ROWS := 10
var vest_mi: MeshInstance3D
var _rim: Array = []            # [[side, local_index], …] 一圈
var _mouth := PackedVector3Array()
var _rim_s: Array = []          # 每个采样：[ia, ib, f]（_rim 下标）
var _mouth_s := PackedVector3Array()
var _vest_bones := PackedInt32Array()
var _vest_w := PackedFloat32Array()
var _vest_per := 4
var _vest_am: ArrayMesh
var _vest_mat: ShaderMaterial
var vest_tris := 0
var soft_mat: ShaderMaterial
var _vest_uv := PackedVector2Array()
var _vest_col := PackedColorArray()


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
		var want := Vector3(sg * 0.0110, vulva.y + 0.0025, vulva.z + 0.005)
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
	_build_vest_uvs()
	_vest_mat = ShaderMaterial.new()
	_vest_mat.shader = preload("res://shaders/vulva_soft.gdshader")
	# 自然黏膜粉（略偏肤色，不要饱和大红）
	_vest_mat.set_shader_parameter("mucosa_color", Color(0.81, 0.60, 0.57, 1.0))
	_vest_mat.set_shader_parameter("roughness_v", 0.50)
	if _skin_tex:
		_vest_mat.set_shader_parameter("albedo_tex", _skin_tex)
		_vest_mat.set_shader_parameter("has_albedo", 1)
	else:
		_vest_mat.set_shader_parameter("has_albedo", 0)
	soft_mat = _vest_mat
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
			var p := top[k].lerp(_inflated_mouth_point(_mouth_s[k]), t)
			# 中间行略向外鼓（管壁圆润，不是直锥）
			var c := vulva.lerp(opening, t)
			var rad := p - c - axis * (p - c).dot(axis)
			p += rad * 0.12 * sin(PI * t)
			if _intro_mix > 1e-4:
				p = _project_out_of_insert(p, t > 0.72)
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
	# 统一网格绕向，法线由三角平均后再整体对齐到管内，避免逐三角翻转把 UV 绕向拧乱。
	if idx.size() >= 3 and P.size() > 0:
		var acc := 0.0
		for t0 in idx.size() / 3:
			var ia := idx[t0 * 3]
			var ib := idx[t0 * 3 + 1]
			var ic := idx[t0 * 3 + 2]
			var fn := (P[ib] - P[ia]).cross(P[ic] - P[ia])
			if fn.length_squared() < 1e-16 or ia >= N.size():
				continue
			acc += fn.dot(N[ia])
		if acc < 0.0:
			for t1 in idx.size() / 3:
				var tmp := idx[t1 * 3 + 1]
				idx[t1 * 3 + 1] = idx[t1 * 3 + 2]
				idx[t1 * 3 + 2] = tmp
		N.resize(P.size())
		for i0 in N.size():
			N[i0] = Vector3.ZERO
		for t2 in idx.size() / 3:
			var ja := idx[t2 * 3]
			var jb := idx[t2 * 3 + 1]
			var jc := idx[t2 * 3 + 2]
			var fn2 := (P[jb] - P[ja]).cross(P[jc] - P[ja])
			N[ja] += fn2
			N[jb] += fn2
			N[jc] += fn2
		for i1 in N.size():
			if N[i1].length_squared() > 1e-16:
				N[i1] = N[i1].normalized()
			else:
				N[i1] = Vector3(0, -1, 0)
	vest_tris = idx.size() / 3
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = P
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TANGENT] = _vest_tangents(P, N)
	if _vest_uv.size() == P.size():
		arr[Mesh.ARRAY_TEX_UV] = _vest_uv
	if _vest_col.size() == P.size():
		arr[Mesh.ARRAY_COLOR] = _vest_col
	arr[Mesh.ARRAY_BONES] = _vest_bones
	arr[Mesh.ARRAY_WEIGHTS] = _vest_w
	arr[Mesh.ARRAY_INDEX] = idx
	_vest_am.clear_surfaces()
	_vest_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if _vest_per == 8 else 0)
	_vest_am.surface_set_name(0, "Vestibule")
	vest_mi.set_surface_override_material(0, _vest_mat)


var _flags := 0


## ------------------------------------------------------------------ 细化 / 接缝焊接 / 骨骼+PBD / 网格自检

func _qkey(p: Vector3) -> Vector3i:
	return Vector3i(int(round(p.x * 200000.0)), int(round(p.y * 200000.0)), int(round(p.z * 200000.0)))


func _subdivide_side(si: int) -> void:
	var a: Array = _arrays[si]
	if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null or a[Mesh.ARRAY_INDEX] == null:
		return
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	if idx.size() < 3:
		return
	var mid := {}
	var new_idx := PackedInt32Array()
	for f in idx.size() / 3:
		var v0 := idx[f * 3]
		var v1 := idx[f * 3 + 1]
		var v2 := idx[f * 3 + 2]
		var m0 := _mid_vert(si, mid, v0, v1)
		var m1 := _mid_vert(si, mid, v1, v2)
		var m2 := _mid_vert(si, mid, v2, v0)
		new_idx.append_array([v0, m0, m2, m0, v1, m1, m2, m1, v2, m0, m1, m2])
	a[Mesh.ARRAY_INDEX] = new_idx
	_arrays[si] = a


func _mid_vert(si: int, mid: Dictionary, a: int, b: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if mid.has(key):
		return int(mid[key])
	var ni := _append_lerp_vert(si, a, b)
	mid[key] = ni
	return ni


func _append_lerp_vert(si: int, i: int, j: int) -> int:
	var a: Array = _arrays[si]
	var P: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var ni := P.size()
	P.append(P[i].lerp(P[j], 0.5))
	a[Mesh.ARRAY_VERTEX] = P
	if a[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var N: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var n := Vector3(0, -1, 0)
		if i < N.size() and j < N.size():
			n = N[i] + N[j]
			if n.length_squared() > 1e-10:
				n = n.normalized()
			else:
				n = N[i]
		N.append(n)
		a[Mesh.ARRAY_NORMAL] = N
	if a[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
		var u := Vector2(0.5, 0.5)
		if i < uv.size() and j < uv.size():
			u = uv[i].lerp(uv[j], 0.5)
		uv.append(u)
		a[Mesh.ARRAY_TEX_UV] = uv
	if a[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
		var uv2: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
		var u2 := Vector2(0.5, 0.5)
		if i < uv2.size() and j < uv2.size():
			u2 = uv2[i].lerp(uv2[j], 0.5)
		uv2.append(u2)
		a[Mesh.ARRAY_TEX_UV2] = uv2
	if a[Mesh.ARRAY_COLOR] is PackedColorArray:
		var col: PackedColorArray = a[Mesh.ARRAY_COLOR]
		var c := Color(1, 1, 1, 1)
		if i < col.size() and j < col.size():
			c = col[i].lerp(col[j], 0.5)
		col.append(c)
		a[Mesh.ARRAY_COLOR] = col
	if a[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		var T: PackedFloat32Array = a[Mesh.ARRAY_TANGENT]
		var t := Vector3(1, 0, 0)
		var s := 1.0
		if T.size() >= (maxi(i, j) + 1) * 4:
			t = Vector3(T[i * 4], T[i * 4 + 1], T[i * 4 + 2]).lerp(Vector3(T[j * 4], T[j * 4 + 1], T[j * 4 + 2]), 0.5)
			if t.length_squared() > 1e-10:
				t = t.normalized()
			s = (T[i * 4 + 3] + T[j * 4 + 3]) * 0.5
		T.append_array([t.x, t.y, t.z, s])
		a[Mesh.ARRAY_TANGENT] = T
	# 其余自定义通道按分量线性插值，避免细化后面数对不上。
	for ck in range(Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM3 + 1):
		if a[ck] == null:
			continue
		_lerp_packed_channel(a, ck, i, j, ni)
	_lerp_bones_into(a, i, j, ni)
	var w: PackedFloat32Array = _w[si]
	var nw := 0.0
	if i < w.size() and j < w.size():
		nw = (w[i] + w[j]) * 0.5
		if w[i] <= 1e-5 and w[j] <= 1e-5:
			nw = 0.0
	w.append(nw)
	_w[si] = w
	var pin: PackedByteArray = _pin[si]
	var pinv := 1 if (i < pin.size() and j < pin.size() and pin[i] != 0 and pin[j] != 0) else 0
	pin.append(pinv)
	_pin[si] = pin
	var iwa: PackedFloat32Array = _iw[si]
	var niv := 0.0
	if i < iwa.size() and j < iwa.size():
		niv = (iwa[i] + iwa[j]) * 0.5
		if iwa[i] <= 1e-5 and iwa[j] <= 1e-5:
			niv = 0.0
	if pinv != 0:
		niv = 0.0
	iwa.append(niv)
	_iw[si] = iwa
	_orders[si].append(-1)
	_arrays[si] = a
	return ni


func _lerp_packed_channel(a: Array, k: int, i: int, j: int, ni: int) -> void:
	var src = a[k]
	if src is PackedFloat32Array:
		var F: PackedFloat32Array = src
		if F.is_empty() or ni < 1 or F.size() % ni != 0:
			return
		var per := F.size() / ni
		for t in per:
			var va := F[i * per + t] if (i * per + t) < F.size() else 0.0
			var vb := F[j * per + t] if (j * per + t) < F.size() else va
			F.append((va + vb) * 0.5)
		a[k] = F
	elif src is PackedByteArray:
		var By: PackedByteArray = src
		if By.is_empty() or ni < 1 or By.size() % ni != 0:
			return
		var per2 := By.size() / ni
		for t2 in per2:
			var va2 := By[i * per2 + t2] if (i * per2 + t2) < By.size() else 0
			var vb2 := By[j * per2 + t2] if (j * per2 + t2) < By.size() else va2
			By.append(int((va2 + vb2) * 0.5))
		a[k] = By
	elif src is PackedInt32Array:
		var I: PackedInt32Array = src
		if I.is_empty() or ni < 1 or I.size() % ni != 0:
			return
		var per3 := I.size() / ni
		for t3 in per3:
			var va3 := I[i * per3 + t3] if (i * per3 + t3) < I.size() else 0
			I.append(va3)
		a[k] = I


func _lerp_bones_into(a: Array, i: int, j: int, _ni: int) -> void:
	if a[Mesh.ARRAY_BONES] == null or a[Mesh.ARRAY_WEIGHTS] == null:
		return
	var B: PackedInt32Array = a[Mesh.ARRAY_BONES]
	var W: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
	var nvert: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() - 1
	var per := 4
	if nvert > 0:
		per = B.size() / maxi(nvert, 1)
	if per < 1:
		per = 4
	var acc := {}
	for src in [i, j]:
		for k in per:
			var id: int = int(src) * per + k
			if id >= B.size() or id >= W.size():
				continue
			var bi: int = B[id]
			acc[bi] = float(acc.get(bi, 0.0)) + W[id] * 0.5
	var items: Array = []
	for bi in acc.keys():
		items.append([float(acc[bi]), int(bi)])
	items.sort_custom(func(p, q): return float(p[0]) > float(q[0]))
	var tot := 0.0
	for k in mini(per, items.size()):
		tot += float(items[k][0])
	for k in per:
		if k < items.size() and tot > 1e-8:
			B.append(int(items[k][1]))
			W.append(float(items[k][0]) / tot)
		else:
			B.append(0)
			W.append(1.0 if k == 0 and items.is_empty() else 0.0)
	a[Mesh.ARRAY_BONES] = B
	a[Mesh.ARRAY_WEIGHTS] = W


func _weld_body_seam(arr: Array, keep: PackedInt32Array) -> PackedInt32Array:
	if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null or keep.size() < 3:
		return keep
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var have := {}
	for v in keep:
		if v >= 0 and v < P.size():
			have[_qkey(P[v])] = v
	for si in 2:
		var fa: Array = _arrays[si]
		if fa.is_empty() or fa[Mesh.ARRAY_INDEX] == null:
			continue
		var FP: PackedVector3Array = fa[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = fa[Mesh.ARRAY_INDEX]
		var w: PackedFloat32Array = _w[si]
		var order: PackedInt32Array = _orders[si]
		for f in idx.size() / 3:
			for k in 3:
				var i: int = idx[f * 3 + k]
				var j: int = idx[f * 3 + (k + 1) % 3]
				if i >= w.size() or j >= w.size():
					continue
				var pin: PackedByteArray = _pin[si]
				var both_pin := (i < pin.size() and j < pin.size() and pin[i] != 0 and pin[j] != 0)
				if not both_pin and (w[i] > 1e-5 or w[j] > 1e-5):
					continue
				if not both_pin:
					continue
				var midp: Vector3 = FP[i].lerp(FP[j], 0.5)
				var key := _qkey(midp)
				if have.has(key):
					continue
				var oa := int(order[i]) if i < order.size() else -1
				var ob := int(order[j]) if j < order.size() else -1
				var nv := _append_dress_lerp(arr, oa, ob, midp)
				P = arr[Mesh.ARRAY_VERTEX]
				have[key] = nv
	P = arr[Mesh.ARRAY_VERTEX]
	var new_keep := PackedInt32Array()
	for f in keep.size() / 3:
		var v0 := keep[f * 3]
		var v1 := keep[f * 3 + 1]
		var v2 := keep[f * 3 + 2]
		if v0 >= P.size() or v1 >= P.size() or v2 >= P.size():
			new_keep.append_array([v0, v1, v2])
			continue
		var m01 := int(have.get(_qkey(P[v0].lerp(P[v1], 0.5)), -1))
		var m12 := int(have.get(_qkey(P[v1].lerp(P[v2], 0.5)), -1))
		var m20 := int(have.get(_qkey(P[v2].lerp(P[v0], 0.5)), -1))
		if m01 == v0 or m01 == v1:
			m01 = -1
		if m12 == v1 or m12 == v2:
			m12 = -1
		if m20 == v2 or m20 == v0:
			m20 = -1
		var nmid := (1 if m01 >= 0 else 0) + (1 if m12 >= 0 else 0) + (1 if m20 >= 0 else 0)
		if nmid == 0:
			new_keep.append_array([v0, v1, v2])
		elif nmid == 1:
			if m01 >= 0:
				new_keep.append_array([v0, m01, v2, m01, v1, v2])
			elif m12 >= 0:
				new_keep.append_array([v0, v1, m12, v0, m12, v2])
			else:
				new_keep.append_array([v0, v1, m20, m20, v1, v2])
		elif nmid == 2:
			if m01 < 0:
				new_keep.append_array([v0, v1, m12, v0, m12, m20, m20, m12, v2])
			elif m12 < 0:
				new_keep.append_array([v0, m01, m20, m01, v1, v2, m20, m01, v2])
			else:
				new_keep.append_array([v0, m01, v2, m01, v1, m12, m01, m12, v2])
		else:
			new_keep.append_array([v0, m01, m20, m01, v1, m12, m20, m12, v2, m01, m12, m20])
	return new_keep


func _append_dress_lerp(arr: Array, ia: int, ib: int, midp: Vector3) -> int:
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var ni := P.size()
	P.append(midp)
	arr[Mesh.ARRAY_VERTEX] = P
	var n0 := maxi(ni, 1)
	for k in Mesh.ARRAY_MAX:
		if k == Mesh.ARRAY_VERTEX or k == Mesh.ARRAY_INDEX or arr[k] == null:
			continue
		var src = arr[k]
		if src is PackedVector3Array:
			var A: PackedVector3Array = src
			var v := midp if k == Mesh.ARRAY_VERTEX else Vector3(0, -1, 0)
			if ia >= 0 and ib >= 0 and ia < A.size() and ib < A.size():
				v = A[ia].lerp(A[ib], 0.5)
				if k == Mesh.ARRAY_NORMAL and v.length_squared() > 1e-10:
					v = v.normalized()
			elif ia >= 0 and ia < A.size():
				v = A[ia]
			A.append(v)
			arr[k] = A
		elif src is PackedVector2Array:
			var A2: PackedVector2Array = src
			var u := Vector2(0.5, 0.5)
			if ia >= 0 and ib >= 0 and ia < A2.size() and ib < A2.size():
				u = A2[ia].lerp(A2[ib], 0.5)
			elif ia >= 0 and ia < A2.size():
				u = A2[ia]
			A2.append(u)
			arr[k] = A2
		elif src is PackedColorArray:
			var C: PackedColorArray = src
			var c := Color(1, 1, 1, 1)
			if ia >= 0 and ib >= 0 and ia < C.size() and ib < C.size():
				c = C[ia].lerp(C[ib], 0.5)
			elif ia >= 0 and ia < C.size():
				c = C[ia]
			C.append(c)
			arr[k] = C
		elif src is PackedFloat32Array:
			var F: PackedFloat32Array = src
			if F.is_empty() or n0 < 1 or F.size() % n0 != 0:
				continue
			var per := F.size() / n0
			for j in per:
				var va := F[ia * per + j] if ia >= 0 and (ia * per + j) < F.size() else (1.0 if j == 0 and k == Mesh.ARRAY_WEIGHTS else 0.0)
				var vb := F[ib * per + j] if ib >= 0 and (ib * per + j) < F.size() else va
				F.append((va + vb) * 0.5)
			arr[k] = F
		elif src is PackedInt32Array:
			var I: PackedInt32Array = src
			if I.is_empty() or n0 < 1 or I.size() % n0 != 0:
				continue
			var per2 := I.size() / n0
			# 骨骼索引不能取平均，沿用权重较大一端（这里简单拷贝 ia）。
			for j2 in per2:
				var va2 := I[ia * per2 + j2] if ia >= 0 and (ia * per2 + j2) < I.size() else 0
				I.append(va2)
			arr[k] = I
		elif src is PackedByteArray:
			var By: PackedByteArray = src
			if By.is_empty() or n0 < 1 or By.size() % n0 != 0:
				continue
			var per3 := By.size() / n0
			for j3 in per3:
				var va3 := By[ia * per3 + j3] if ia >= 0 and (ia * per3 + j3) < By.size() else 0
				var vb3 := By[ib * per3 + j3] if ib >= 0 and (ib * per3 + j3) < By.size() else va3
				By.append(int((va3 + vb3) * 0.5))
			arr[k] = By
	return ni


func _build_rim_from_flaps() -> void:
	_rim.clear()
	var chains: Array = []
	for si in 2:
		var a: Array = _arrays[si]
		if a.is_empty() or a[Mesh.ARRAY_INDEX] == null:
			chains.append([])
			continue
		var P: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var w: PackedFloat32Array = _w[si]
		var cnt := {}
		for f in idx.size() / 3:
			for k in 3:
				var a0 := idx[f * 3 + k]
				var b0 := idx[f * 3 + (k + 1) % 3]
				var key := Vector2i(mini(a0, b0), maxi(a0, b0))
				cnt[key] = int(cnt.get(key, 0)) + 1
		var adj := {}
		for key in cnt.keys():
			if int(cnt[key]) != 1:
				continue
			var e: Vector2i = key
			# 与身体焊接的外缘（pin）不进开口圈；前后联合仍算开口。
			var pin: PackedByteArray = _pin[si]
			if e.x < pin.size() and e.y < pin.size() and pin[e.x] != 0 and pin[e.y] != 0:
				continue
			if not adj.has(e.x):
				adj[e.x] = []
			if not adj.has(e.y):
				adj[e.y] = []
			adj[e.x].append(e.y)
			adj[e.y].append(e.x)
		var best: Array = []
		var best_sc := -1.0
		for st in adj.keys():
			var pin0: PackedByteArray = _pin[si]
			var st_pin: bool = int(st) < pin0.size() and pin0[int(st)] != 0
			if (adj[st] as Array).size() != 1 and not st_pin:
				continue
			var path: Array = [st]
			var cur: int = st
			while true:
				var nxt := -1
				var bx := INF
				for nb in adj[cur]:
					if path.has(nb):
						continue
					var ax := absf(P[int(nb)].x)
					if ax < bx:
						bx = ax
						nxt = int(nb)
				if nxt < 0:
					break
				path.append(nxt)
				cur = nxt
				if nxt < _pin[si].size() and _pin[si][nxt] != 0:
					break
			var sc := 0.0
			for v in path:
				sc += 1.0 - clampf(absf(P[int(v)].x) / 0.003, 0.0, 0.9)
			if path.size() >= 3 and sc > best_sc:
				best_sc = sc
				best = path
		chains.append(best)
	if chains[0].size() < 3 or chains[1].size() < 3:
		return
	var pl: PackedVector3Array = (_arrays[0] as Array)[Mesh.ARRAY_VERTEX]
	var pr: PackedVector3Array = (_arrays[1] as Array)[Mesh.ARRAY_VERTEX]
	var cl: Array = chains[0]
	var cr: Array = chains[1]
	if pl[cl[0]].dot(slit_dir) < pl[cl[cl.size() - 1]].dot(slit_dir):
		cl.reverse()
	if pr[cr[0]].dot(slit_dir) > pr[cr[cr.size() - 1]].dot(slit_dir):
		cr.reverse()
	for v in cl:
		_rim.append([0, int(v)])
	for j in cr.size():
		_rim.append([1, int(cr[j])])


func _build_vest_uvs() -> void:
	_vest_uv = PackedVector2Array()
	_vest_col = PackedColorArray()
	var mean := Vector2.ZERO
	for k0 in VEST_N:
		mean += _rim_sample_uv(k0)
	mean /= float(maxi(VEST_N, 1))
	for r in VEST_ROWS + 1:
		var t := float(r) / float(VEST_ROWS)
		# 第 0 行必须贴皮肤 UV；内圈改用沿圈单调的条带，避免继承皮肤图集时出现翻转三角。
		for k in VEST_N:
			var rim := _rim_sample_uv(k)
			var dv := 0.018 if mean.y + 0.018 <= 1.0 else -0.018
			var uv: Vector2
			if r == 0:
				uv = rim
			else:
				# 内圈用沿环单调的条带（与外圈皮肤 UV 在第 0 行相接处过渡由着色器按行混合黏膜色）。
				uv = Vector2(mean.x + (float(k) / float(VEST_N) - 0.5) * 0.05, clampf(mean.y + dv * t, 0.0, 1.0))
			_vest_uv.append(uv)
			_vest_col.append(Color(t, 0.0, 0.0, 1.0))


func _rim_sample_uv(k: int) -> Vector2:
	if k < 0 or k >= _rim_s.size():
		return Vector2(0.5, 0.5)
	var s0: Array = _rim_s[k]
	var ua := _flap_uv(_rim[int(s0[0])])
	var ub := _flap_uv(_rim[int(s0[1])])
	return ua.lerp(ub, float(s0[2]))


func _flap_uv(e: Array) -> Vector2:
	if e.is_empty():
		return Vector2(0.5, 0.5)
	var arr: Array = _arrays[int(e[0])]
	if arr.is_empty() or arr[Mesh.ARRAY_TEX_UV] == null:
		return Vector2(0.5, 0.5)
	var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var i: int = int(e[1])
	return uv[i] if i >= 0 and i < uv.size() else Vector2(0.5, 0.5)


func _vest_tangents(P: PackedVector3Array, N: PackedVector3Array) -> PackedFloat32Array:
	var T := PackedFloat32Array()
	T.resize(P.size() * 4)
	for r in VEST_ROWS + 1:
		for k in VEST_N:
			var i := r * VEST_N + k
			var i2 := r * VEST_N + (k + 1) % VEST_N
			var tan := P[i2] - P[i]
			var n: Vector3 = N[i] if i < N.size() else Vector3(0, 1, 0)
			tan = tan - n * tan.dot(n)
			if tan.length_squared() < 1e-12:
				tan = n.cross(Vector3(0, 0, 1))
				if tan.length_squared() < 1e-12:
					tan = n.cross(Vector3(1, 0, 0))
			tan = tan.normalized()
			T[i * 4] = tan.x
			T[i * 4 + 1] = tan.y
			T[i * 4 + 2] = tan.z
			T[i * 4 + 3] = 1.0
	return T


func _prepare_soft() -> void:
	for si in 2:
		var a: Array = _arrays[si]
		if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
			_soft_P[si] = PackedVector3Array()
			_rest_edges[si] = PackedInt32Array()
			_rest_len[si] = PackedFloat32Array()
			_adj_off[si] = PackedInt32Array()
			_adj_to[si] = PackedInt32Array()
			continue
		var P: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		_soft_P[si] = P.duplicate()
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var edges := PackedInt32Array()
		var lens := PackedFloat32Array()
		var seen := {}
		for f in idx.size() / 3:
			for k in 3:
				var a0 := idx[f * 3 + k]
				var b0 := idx[f * 3 + (k + 1) % 3]
				var key := Vector2i(mini(a0, b0), maxi(a0, b0))
				if seen.has(key):
					continue
				seen[key] = true
				edges.append(a0)
				edges.append(b0)
				lens.append(P[a0].distance_to(P[b0]))
		_rest_edges[si] = edges
		_rest_len[si] = lens
		var n := P.size()
		var lists: Array = []
		lists.resize(n)
		for i in n:
			lists[i] = PackedInt32Array()
		for e in lens.size():
			var ea := edges[e * 2]
			var eb := edges[e * 2 + 1]
			(lists[ea] as PackedInt32Array).append(eb)
			(lists[eb] as PackedInt32Array).append(ea)
		var off := PackedInt32Array()
		var to := PackedInt32Array()
		off.resize(n + 1)
		off[0] = 0
		for i2 in n:
			var li: PackedInt32Array = lists[i2]
			for j in li.size():
				to.append(li[j])
			off[i2 + 1] = to.size()
		_adj_off[si] = off
		_adj_to[si] = to


func _capture_dress_soft() -> void:
	_body_surf.clear()
	_dress_rest = PackedVector3Array()
	_dress_inf = PackedFloat32Array()
	_dress_near = PackedInt32Array()
	_dress_active = PackedInt32Array()
	_seam_pair_flap = PackedInt32Array()
	_seam_pair_dress = PackedInt32Array()
	if _dress_mi == null or _body_am == null or _body_am.get_surface_count() < 1:
		return
	for sidx in _body_am.get_surface_count():
		_body_surf.append({
			"arr": _body_am.surface_get_arrays(sidx),
			"prim": _body_am.surface_get_primitive_type(sidx),
			"mat": _body_am.surface_get_material(sidx),
			"name": _body_am.surface_get_name(sidx),
		})
	var arr: Array = _body_surf[0]["arr"]
	if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
		return
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	_dress_rest = P.duplicate()
	var seam_key := {}
	var seam_pos := PackedVector3Array()
	var seam_di_of_key := {}
	for si in 2:
		if (_arrays[si] as Array).is_empty():
			continue
		var FP: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX]
		var pin: PackedByteArray = _pin[si]
		for i in FP.size():
			if i < pin.size() and pin[i] != 0:
				seam_key[_qkey(FP[i])] = Vector2i(si, i)
				seam_pos.append(FP[i])
	_dress_inf.resize(P.size())
	_dress_near.resize(P.size())
	var box_r := SKIN_FALLOFF + 0.012
	for i in P.size():
		var p0: Vector3 = P[i]
		_dress_near[i] = -1
		var k := _qkey(p0)
		if seam_key.has(k):
			var pr: Vector2i = seam_key[k]
			_seam_pair_flap.append(pr.x)
			_seam_pair_flap.append(pr.y)
			_seam_pair_dress.append(i)
			_dress_inf[i] = 1.0
			_dress_near[i] = i
			_dress_active.append(i)
			continue
		if p0.distance_to(vulva) > box_r and p0.distance_to(opening) > box_r:
			_dress_inf[i] = 0.0
			continue
		var dmin := INF
		var nearest := -1
		for j in seam_pos.size():
			var d := p0.distance_squared_to(seam_pos[j])
			if d < dmin:
				dmin = d
				nearest = j
		dmin = sqrt(dmin) if dmin < INF else INF
		var w := clampf(1.0 - dmin / SKIN_FALLOFF, 0.0, 1.0)
		w *= w
		_dress_inf[i] = w
		# 最近接缝对应的身体顶点稍后在 pair 里找；先记下缝上的空间点下标，下面再映射。
		_dress_near[i] = nearest
		if w > 0.02:
			_dress_active.append(i)
	# 把「最近缝点」从缝空间下标改成对应的身体顶点下标。
	var seam_dress_of := PackedInt32Array()
	seam_dress_of.resize(seam_pos.size())
	for i2 in seam_dress_of.size():
		seam_dress_of[i2] = -1
	for k2 in _seam_pair_dress.size():
		var di: int = _seam_pair_dress[k2]
		var si2: int = _seam_pair_flap[k2 * 2]
		var fi: int = _seam_pair_flap[k2 * 2 + 1]
		var FP2: PackedVector3Array = (_arrays[si2] as Array)[Mesh.ARRAY_VERTEX]
		var want := _qkey(FP2[fi])
		for j2 in seam_pos.size():
			if _qkey(seam_pos[j2]) == want:
				seam_dress_of[j2] = di
				break
	for ai in _dress_active.size():
		var i3: int = _dress_active[ai]
		if _dress_inf[i3] >= 0.999:
			continue
		var sj: int = _dress_near[i3]
		_dress_near[i3] = seam_dress_of[sj] if sj >= 0 and sj < seam_dress_of.size() else -1


func _write_dress_verts(P: PackedVector3Array) -> void:
	if _body_am == null or _body_surf.is_empty() or _dress_mi == null:
		return
	var arr: Array = _body_surf[0]["arr"]
	arr[Mesh.ARRAY_VERTEX] = P
	_body_surf[0]["arr"] = arr
	_body_am.clear_surfaces()
	for sidx in _body_surf.size():
		var rec: Dictionary = _body_surf[sidx]
		var fl := _body_flags[sidx] if sidx < _body_flags.size() else 0
		_body_am.add_surface_from_arrays(rec["prim"], rec["arr"], [], {}, fl)
		if rec["mat"]:
			_body_am.surface_set_material(sidx, rec["mat"])
		if rec["name"]:
			_body_am.surface_set_name(sidx, rec["name"])
	_dress_mi.mesh = _body_am


func _commit_dress_soft() -> void:
	if _dress_rest.is_empty() or _dress_active.is_empty():
		return
	var P := _dress_rest.duplicate()
	if _intro_mix < 1e-4:
		if _dress_dirty:
			_write_dress_verts(P)
			_dress_dirty = false
		return
	var D := PackedVector3Array()
	D.resize(_dress_rest.size())
	for k in _seam_pair_dress.size():
		var di: int = _seam_pair_dress[k]
		var si: int = _seam_pair_flap[k * 2]
		var fi: int = _seam_pair_flap[k * 2 + 1]
		var posed := _dress_rest[di]
		if si < _soft_P.size() and fi < _soft_P[si].size():
			posed = _soft_P[si][fi]
		D[di] = posed - _dress_rest[di]
	for ai in _dress_active.size():
		var i: int = _dress_active[ai]
		var w: float = _dress_inf[i]
		if w >= 0.999:
			P[i] = _dress_rest[i] + D[i]
			continue
		var nj: int = _dress_near[i]
		var disp := D[nj] if nj >= 0 and nj < D.size() else Vector3.ZERO
		P[i] = _dress_rest[i] + disp * w
	_write_dress_verts(P)
	_dress_dirty = true


func _sync_envelope_inserter() -> void:
	var Envelope := preload("res://scripts/body/vulva/envelope_inserter.gd")
	if _intro_mix < 1e-4 or _intro_hx < 1e-5:
		_inserter = null
		return
	# 只回写椭圆/双叶插入物；自定义（球、以后的网格 SDF）自己管理 configure。
	if _inserter != null and _inserter.has_method("uses_envelope_configure") and bool(_inserter.call("uses_envelope_configure")) and _inserter.has_method("configure"):
		_inserter.configure(_intro_hx, _intro_hy, _intro_mix, _intro_axis, _intro_up, _intro_sep, ALONG_RANGE)
		return
	if _inserter != null:
		return
	var ins = Envelope.new()
	ins.configure(_intro_hx, _intro_hy, _intro_mix, _intro_axis, _intro_up, _intro_sep, ALONG_RANGE)
	_inserter = ins


func _is_pinned(si: int, i: int) -> bool:
	var pin: PackedByteArray = _pin[si]
	return i < pin.size() and pin[i] != 0


func _insert_w(si: int, i: int) -> float:
	var iw: PackedFloat32Array = _iw[si]
	if i < iw.size():
		return iw[i]
	return 0.0


func _mouth_center() -> Vector3:
	if _mouth_s.is_empty():
		return opening
	var acc := Vector3.ZERO
	for q in _mouth_s:
		acc += q
	return acc / float(_mouth_s.size())


func _intro_basis() -> Array:
	var ax := _intro_axis.normalized() if _intro_axis.length_squared() > 1e-8 else (opening - vulva).normalized()
	var up := (_intro_up - ax * _intro_up.dot(ax))
	if up.length_squared() < 1e-8:
		up = Vector3(0, 0, 1) - ax * ax.z
	up = up.normalized()
	var side := ax.cross(up)
	if side.length_squared() < 1e-8:
		side = Vector3(1, 0, 0)
	else:
		side = side.normalized()
	return [ax, up, side]


func _envelope_point(p: Vector3, c: Vector3) -> Vector3:
	var b: Array = _intro_basis()
	var ax: Vector3 = b[0]
	var up: Vector3 = b[1]
	var side: Vector3 = b[2]
	var r := p - c
	var x := r.dot(side)
	var y := r.dot(up)
	var along := r.dot(ax)
	var h := _hull_2d(x, y)
	return c + side * h.x + up * h.y + ax * along


func _hull_2d(x: float, y: float) -> Vector2:
	var hx := maxf(_intro_hx, 1e-5)
	var hy := maxf(_intro_hy, 1e-5)
	var cy := maxf(_intro_sep, 0.0)
	if cy < 1e-5:
		var e := (x * x) / (hx * hx) + (y * y) / (hy * hy)
		if e <= 1e-8:
			return Vector2(0.0, hy)
		var k := 1.0 / sqrt(e)
		return Vector2(x * k, y * k)
	var hh := maxf(hy - cy, 0.002)
	var L := sqrt(x * x + y * y)
	if L < 1e-8:
		return Vector2(0.0, hy)
	var dx := x / L
	var dy := y / L
	if absf(dx) > 1e-6:
		var t_side := hx / absf(dx)
		var y_hit := t_side * dy
		if absf(y_hit) <= cy + 1e-6:
			return Vector2(dx * t_side, dy * t_side)
	var sy := 1.0 if dy >= 0.0 else -1.0
	var A := (dx * dx) / (hx * hx) + (dy * dy) / (hh * hh)
	var B := -2.0 * dy * sy * cy / (hh * hh)
	var C := (cy * cy) / (hh * hh) - 1.0
	var disc := B * B - 4.0 * A * C
	if disc < 0.0 or A < 1e-12:
		return Vector2(dx * hx, dy * hy)
	var t := (-B + sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		t = (-B - sqrt(disc)) / (2.0 * A)
	t = maxf(t, 0.0)
	return Vector2(dx * t, dy * t)


func _ell_k(x: float, y: float, hx: float, hh: float) -> float:
	return (x * x) / maxf(hx * hx, 1e-8) + (y * y) / maxf(hh * hh, 1e-8)


func _closest_out_metal(x: float, y: float, hx: float, hh: float, cy: float) -> Vector2:
	var ku := _ell_k(x, y - cy, hx, hh)
	var kl := _ell_k(x, y + cy, hx, hh)
	var margin := 1.016
	if ku <= kl:
		if ku < 1e-8:
			return Vector2(0.0, cy + hh * margin)
		var s := margin / sqrt(ku)
		return Vector2(x * s, cy + (y - cy) * s)
	if kl < 1e-8:
		return Vector2(0.0, -(cy + hh * margin))
	var s2 := margin / sqrt(kl)
	return Vector2(x * s2, -cy + (y + cy) * s2)


func _cache_intro_frame() -> void:
	_cf_c = _mouth_center()
	var b: Array = _intro_basis()
	_cf_ax = b[0]
	_cf_up = b[1]
	_cf_side = b[2]
	_cf_ready = true


func _fast_inside_metal(p: Vector3) -> bool:
	if _intro_mix < 1e-4 or _intro_hx < 1e-5 or _intro_hy < 1e-5:
		return false
	var r := p - _cf_c
	if absf(r.dot(_cf_ax)) > ALONG_RANGE:
		return false
	var x := r.dot(_cf_side)
	var y := r.dot(_cf_up)
	var cy := maxf(_intro_sep, 0.0)
	var hx := maxf(_intro_hx, 1e-5)
	var hy := maxf(_intro_hy, 1e-5)
	if cy < 1e-5:
		return _ell_k(x, y, hx, hy) < 1.0
	var hh := maxf(hy - cy, 0.002)
	return _ell_k(x, y - cy, hx, hh) < 1.0 or _ell_k(x, y + cy, hx, hh) < 1.0


func _side_bias_x(x: float, side_sign: float) -> float:
	# 左瓣保持在 +side，右瓣保持在 -side，避免裂隙上相邻点被投影到开口对侧而撕开。
	if absf(side_sign) < 0.5:
		return x
	if x * side_sign < 0.002:
		return side_sign * 0.002
	return x


func _fast_project(p: Vector3, is_inner: bool, side_sign: float = 0.0) -> Vector3:
	if _intro_mix < 1e-4 or _intro_hx < 1e-5 or _intro_hy < 1e-5:
		return p
	if not _cf_ready:
		_cache_intro_frame()
	# 自定义插入物（非解析包络）走接口；扩张器 / 椭圆走本地热路径。
	if _inserter != null and not _inserter.has_method("configure") and _inserter.has_method("project_out"):
		return _inserter.project_out(p, _cf_c, _cf_ax, _cf_up)
	var r := p - _cf_c
	var along := r.dot(_cf_ax)
	if absf(along) > ALONG_RANGE:
		return p
	var x := _side_bias_x(r.dot(_cf_side), side_sign)
	var y := r.dot(_cf_up)
	var cy := maxf(_intro_sep, 0.0)
	var hx := maxf(_intro_hx, 1e-5)
	var hy := maxf(_intro_hy, 1e-5)
	var hh := maxf(hy - cy, 0.002)
	var inside := false
	var out2 := Vector2(x, y)
	if cy < 1e-5:
		var e := _ell_k(x, y, hx, hy)
		inside = e < 1.0
		if inside:
			if e < 1e-8:
				out2 = Vector2(side_sign * hx if absf(side_sign) > 0.5 else 0.0, hy * 1.016)
			else:
				var s := 1.016 / sqrt(e)
				out2 = Vector2(x * s, y * s)
	else:
		inside = _ell_k(x, y - cy, hx, hh) < 1.0 or _ell_k(x, y + cy, hx, hh) < 1.0
		if inside:
			out2 = _closest_out_metal(x, y, hx, hh, cy)
	if absf(side_sign) > 0.5 and out2.x * side_sign < 0.0:
		out2 = _hull_2d(x, y)
	if not inside and is_inner:
		var on := _hull_2d(x, y)
		if Vector2(x, y).length_squared() + 1e-10 < on.length_squared():
			out2 = on
			inside = true
	if inside or (is_inner and out2 != Vector2(x, y)):
		return _cf_c + _cf_side * out2.x + _cf_up * out2.y + _cf_ax * along
	return p


func _project_out_of_insert(p: Vector3, is_inner: bool) -> Vector3:
	return _fast_project(p, is_inner, 0.0)


func _inside_hull(p: Vector3, c: Vector3) -> bool:
	var b: Array = _intro_basis()
	var r := p - c
	var x := r.dot(b[2])
	var y := r.dot(b[1])
	var on := _hull_2d(x, y)
	return Vector2(x, y).length_squared() + 1e-10 < on.length_squared()


func _bone_posed(si: int, i: int) -> Vector3:
	var src: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX]
	var rest: Vector3 = src[i]
	var ang := _spread * MAX_ANGLE
	var sg := 1.0 if si == 0 else -1.0
	var hw: float = float(_w[si][i]) if i < _w[si].size() else 0.0
	var p := _rot(rest, si, ang * hw * sg)
	if _intro_mix < 1e-4 or _is_pinned(si, i):
		return p
	var iw := _insert_w(si, i)
	if iw <= 1e-5:
		return p
	var c := _mouth_center()
	# 只把已经进到叶片包络里的顶点撑到截面上；外侧皮肤不被吸进去。
	if not _inside_hull(p, c):
		return p
	var tgt := _envelope_point(p, c)
	var ax := _intro_axis.normalized() if _intro_axis.length_squared() > 1e-8 else (opening - vulva).normalized()
	var fa := clampf(1.0 - absf((p - c).dot(ax)) / 0.045, 0.0, 1.0)
	return p.lerp(tgt, minf(1.0, iw * 1.15) * _intro_mix * fa)


func _step_soft() -> void:
	var t0 := Time.get_ticks_usec()
	if not ok:
		last_step_usec = 0
		return
	if not _cf_ready:
		_cache_intro_frame()
	var ang := _spread * MAX_ANGLE
	for si in 2:
		var a: Array = _arrays[si]
		if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
			continue
		var rest: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n := rest.size()
		var pin: PackedByteArray = _pin[si]
		var iw: PackedFloat32Array = _iw[si]
		var w: PackedFloat32Array = _w[si]
		var sg := 1.0 if si == 0 else -1.0
		var C := PackedVector3Array()
		C.resize(n)
		for i in n:
			var hw: float = float(w[i]) if i < w.size() else 0.0
			C[i] = _rot(rest[i], si, ang * hw * sg)
		var P := C.duplicate()
		var sgx := 1.0 if si == 0 else -1.0
		if _intro_mix >= 1e-4 and _rest_len[si].size() > 0:
			var D := PackedVector3Array()
			D.resize(n)
			var hard := PackedByteArray()
			hard.resize(n)
			var was_in := PackedByteArray()
			was_in.resize(n)
			var wa_arr := PackedFloat32Array()
			wa_arr.resize(n)
			var near := PackedInt32Array()
			for i0 in n:
				var is_pin := i0 < pin.size() and pin[i0] != 0
				var iwv: float = iw[i0] if i0 < iw.size() else 0.0
				var inside0 := _fast_inside_metal(C[i0])
				was_in[i0] = 1 if inside0 else 0
				if inside0:
					# 进了叶片的点必须完全推出，接缝处也一样，周围皮肤跟着走。
					P[i0] = _fast_project(C[i0], false, sgx)
					D[i0] = P[i0] - C[i0]
					hard[i0] = 1
					near.append(i0)
				elif (not is_pin) and iwv > 0.55:
					var q0 := _fast_project(C[i0], true, sgx)
					D[i0] = q0 - C[i0]
					P[i0] = q0
					hard[i0] = 1 if q0 != C[i0] else 0
					near.append(i0)
				else:
					D[i0] = Vector3.ZERO
					hard[i0] = 1 if is_pin else 0
				if is_pin and not inside0:
					wa_arr[i0] = 0.0
				elif is_pin:
					wa_arr[i0] = 0.22
				else:
					wa_arr[i0] = maxf(iwv, 0.15)
			var off: PackedInt32Array = _adj_off[si]
			var to: PackedInt32Array = _adj_to[si]
			if off.size() == n + 1 and near.size() > 0:
				var marked := PackedByteArray()
				marked.resize(n)
				var ring := PackedInt32Array()
				for j0 in near.size():
					var ni: int = near[j0]
					if marked[ni] != 0:
						continue
					marked[ni] = 1
					ring.append(ni)
					var b0: int = off[ni]
					var b1: int = off[ni + 1]
					for k0 in range(b0, b1):
						var nj: int = to[k0]
						if marked[nj] == 0:
							marked[nj] = 1
							ring.append(nj)
				near = ring
			if off.size() == n + 1:
				for _it in LAPLACE_ITERS:
					var nxt := D.duplicate()
					for i1 in n:
						if hard[i1] != 0:
							continue
						var acc := Vector3.ZERO
						var cnt := 0
						var a0: int = off[i1]
						var a1: int = off[i1 + 1]
						for k in range(a0, a1):
							acc += D[to[k]]
							cnt += 1
						if cnt > 0:
							nxt[i1] = acc / float(cnt)
					D = nxt
			for i2 in n:
				P[i2] = C[i2] + D[i2]
			for jn in near.size():
				var i2b: int = near[jn]
				if _fast_inside_metal(P[i2b]):
					P[i2b] = _fast_project(P[i2b], false, sgx)
			var edges: PackedInt32Array = _rest_edges[si]
			var lens: PackedFloat32Array = _rest_len[si]
			for it in PBD_ITERS:
				for e in lens.size():
					var ia := edges[e * 2]
					var ib := edges[e * 2 + 1]
					var wa := wa_arr[ia]
					var wb := wa_arr[ib]
					if wa + wb < 1e-5:
						continue
					var d := P[ib] - P[ia]
					var L := d.length()
					if L < 1e-8:
						continue
					var restL: float = maxf(lens[e], 0.0005)
					var target := clampf(L, restL * 0.42, restL * MAX_EDGE_STRETCH)
					var corr := d * ((L - target) / L)
					var inv := 1.0 / (wa + wb)
					P[ia] += corr * (wa * inv)
					P[ib] -= corr * (wb * inv)
				for jn2 in near.size():
					var i3: int = near[jn2]
					if _fast_inside_metal(P[i3]):
						P[i3] = _fast_project(P[i3], false, sgx)
			for i4 in n:
				if _fast_inside_metal(P[i4]):
					P[i4] = _fast_project(P[i4], false, sgx)
				if not P[i4].is_finite():
					P[i4] = C[i4]
		else:
			for i5 in n:
				if not P[i5].is_finite():
					P[i5] = rest[i5]
		_soft_P[si] = P
	last_step_usec = int(Time.get_ticks_usec() - t0)


func set_insert_capsules(caps: Array, mix: float) -> void:
	# 预留：钳子等以胶囊截面撑开外口。当前扩张器走 set_introitus_open 的叶片包络。
	_intro_mix = clampf(mix, 0.0, 1.0)
	if ok:
		_commit()


func insert_penetration() -> float:
	if _intro_mix < 1e-4 or _intro_hx < 1e-5:
		return 0.0
	if not _cf_ready:
		_cache_intro_frame()
	var c := _cf_c
	var b: Array = [_cf_ax, _cf_up, _cf_side]
	var ax: Vector3 = b[0]
	var up: Vector3 = b[1]
	var depth := 0.0
	for si in 2:
		var P := side_positions(si)
		for i in P.size():
			if _is_pinned(si, i) or _insert_w(si, i) < 0.12:
				continue
			var p: Vector3 = P[i]
			if not p.is_finite():
				continue
			var d := 0.0
			if _inserter != null and _inserter.has_method("penetration"):
				d = float(_inserter.call("penetration", p, c, ax, up))
			else:
				d = _legacy_pen(p, c, b)
			depth = maxf(depth, d)
	for p2 in vestibule_positions():
		if not p2.is_finite():
			continue
		var d2 := 0.0
		if _inserter != null and _inserter.has_method("penetration"):
			d2 = float(_inserter.call("penetration", p2, c, ax, up))
		else:
			d2 = _legacy_pen(p2, c, b)
		depth = maxf(depth, d2)
	return depth


func _legacy_pen(p: Vector3, c: Vector3, b: Array) -> float:
	var ax: Vector3 = b[0]
	var up: Vector3 = b[1]
	var side: Vector3 = b[2]
	var r := p - c
	if absf(r.dot(ax)) > ALONG_RANGE:
		return 0.0
	var x := r.dot(side)
	var y := r.dot(up)
	var cy := maxf(_intro_sep, 0.0)
	var hx := maxf(_intro_hx, 1e-5)
	var hy := maxf(_intro_hy, 1e-5)
	var hh := maxf(hy - cy, 0.002)
	var k := 2.0
	if cy < 1e-5:
		k = _ell_k(x, y, hx, hy)
		if k < 1.0:
			return (1.0 - sqrt(maxf(k, 0.0))) * minf(hx, hy)
	else:
		k = minf(_ell_k(x, y - cy, hx, hh), _ell_k(x, y + cy, hx, hh))
		if k < 1.0:
			return (1.0 - sqrt(maxf(k, 0.0))) * minf(hx, hh)
	return 0.0



func max_edge_ratio() -> float:
	var best := 1.0
	# 短于 1.5mm 的细分边用这个底长算比值，避免 0.4mm 微边在外口撑开时把比值抬上天；真正的撕边（拉到数毫米以上）仍会失败。
	const MIN_L := 0.0015
	for si in 2:
		var P := side_positions(si)
		var edges: PackedInt32Array = _rest_edges[si]
		var lens: PackedFloat32Array = _rest_len[si]
		for e in lens.size():
			var ia := edges[e * 2]
			var ib := edges[e * 2 + 1]
			if ia >= P.size() or ib >= P.size() or lens[e] < 0.00025:
				continue
			best = maxf(best, P[ia].distance_to(P[ib]) / maxf(lens[e], MIN_L))
	return best


func rest_error() -> float:
	var best := 0.0
	for si in 2:
		var rest: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX]
		var cur := side_positions(si)
		for i in mini(rest.size(), cur.size()):
			best = maxf(best, cur[i].distance_to(rest[i]))
	return best


func debug_mesh_quality() -> Dictionary:
	var out := {
		"ring_holes": 0,
		"boundary_loops": 0,
		"flipped_normals": 0,
		"degenerate_tris": 0,
		"uv_out_of_range": 0,
		"uv_flipped": 0,
		"ring_verts": 0,
		"ring_tris": vest_tris,
		"flap_tris": 0,
		"nan": 0,
		"rim_uv_err": 0.0,
	}
	if vest_mi == null or _vest_am == null or _vest_am.get_surface_count() < 1:
		out["ring_holes"] = 99
		return out
	var arr := _vest_am.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var UV: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	out["ring_verts"] = P.size()
	out["ring_tris"] = idx.size() / 3
	for p in P:
		if not p.is_finite():
			out["nan"] = int(out["nan"]) + 1
	var axis := (opening - vulva).normalized()
	var cnt := {}
	for f in idx.size() / 3:
		var a := idx[f * 3]
		var b := idx[f * 3 + 1]
		var c := idx[f * 3 + 2]
		var e1 := P[b] - P[a]
		var e2 := P[c] - P[a]
		var fn := e1.cross(e2)
		if fn.length() < 1e-10 or e1.length() < 1e-8 or e2.length() < 1e-8:
			out["degenerate_tris"] = int(out["degenerate_tris"]) + 1
			continue
		# 内法线：指向管腔（-radial）。
		if a < N.size() and b < N.size() and c < N.size():
			var nsum: Vector3 = N[a] + N[b] + N[c]
			if nsum.length_squared() > 1e-16 and fn.normalized().dot(nsum.normalized()) < -0.25:
				out["flipped_normals"] = int(out["flipped_normals"]) + 1
		elif a < N.size() and fn.normalized().dot(N[a]) < -0.25:
			out["flipped_normals"] = int(out["flipped_normals"]) + 1
		if UV.size() > maxi(c, maxi(a, b)):
			for vi in [a, b, c]:
				var uv: Vector2 = UV[vi]
				if uv.x < -0.02 or uv.x > 1.02 or uv.y < -0.02 or uv.y > 1.02:
					out["uv_out_of_range"] = int(out["uv_out_of_range"]) + 1
			var u0: Vector2 = UV[b] - UV[a]
			var u1: Vector2 = UV[c] - UV[a]
			var us := u0.x * u1.y - u0.y * u1.x
			# 外圈继承皮肤图集，只检查内圈自身绕向是否一致（少数符号相反的才算翻转）。
			var on_rim := a < VEST_N or b < VEST_N or c < VEST_N
			var ka := a % VEST_N
			var kb := b % VEST_N
			var kc := c % VEST_N
			var wrap := maxi(ka, maxi(kb, kc)) - mini(ka, mini(kb, kc)) > VEST_N / 2
			# 贴皮肤的外圈、以及条带合口那一条，不计入翻转。
			if (not on_rim) and (not wrap) and a >= VEST_N and b >= VEST_N and c >= VEST_N and absf(us) > 1e-10:
				if us > 0.0:
					out["uv_pos"] = int(out.get("uv_pos", 0)) + 1
				else:
					out["uv_neg"] = int(out.get("uv_neg", 0)) + 1
		for k in 3:
			var ia := idx[f * 3 + k]
			var ib := idx[f * 3 + (k + 1) % 3]
			var key := Vector2i(mini(ia, ib), maxi(ia, ib))
			cnt[key] = int(cnt.get(key, 0)) + 1
	out["uv_flipped"] = mini(int(out.get("uv_pos", 0)), int(out.get("uv_neg", 0)))
	out["boundary_loops"] = _count_loops(cnt)
	# 一圈管道只有外口 / 内口两条边界；多出来的就是破洞。
	out["ring_holes"] = maxi(int(out["boundary_loops"]) - 2, 0)
	for si in 2:
		var fa: Array = _arrays[si]
		if fa.is_empty() or fa[Mesh.ARRAY_INDEX] == null:
			continue
		out["flap_tris"] = int(out["flap_tris"]) + (fa[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var fuv = fa[Mesh.ARRAY_TEX_UV]
		if fuv is PackedVector2Array:
			for uv2 in fuv:
				if uv2.x < -0.02 or uv2.x > 1.02 or uv2.y < -0.02 or uv2.y > 1.02:
					out["uv_out_of_range"] = int(out["uv_out_of_range"]) + 1
	# 前庭外圈 UV 应贴上皮瓣开口边 UV。
	var err := 0.0
	var nerr := 0
	if _vest_uv.size() >= VEST_N and _rim_s.size() == VEST_N:
		for k in VEST_N:
			err += _vest_uv[k].distance_to(_rim_sample_uv(k))
			nerr += 1
	out["rim_uv_err"] = err / float(maxi(nerr, 1))
	return out


func _count_loops(cnt: Dictionary) -> int:
	var adj := {}
	for key in cnt.keys():
		if int(cnt[key]) != 1:
			continue
		var e: Vector2i = key
		if not adj.has(e.x):
			adj[e.x] = []
		if not adj.has(e.y):
			adj[e.y] = []
		(adj[e.x] as Array).append(e.y)
		(adj[e.y] as Array).append(e.x)
	var seen := {}
	var loops := 0
	for st in adj.keys():
		if seen.has(st):
			continue
		var cur: int = st
		var prev := -1
		var guard := 0
		while not seen.has(cur) and guard < 10000:
			seen[cur] = true
			guard += 1
			var nxt := -1
			for nb in adj[cur]:
				if int(nb) != prev:
					nxt = int(nb)
					break
			if nxt < 0:
				break
			prev = cur
			cur = nxt
			if cur == st:
				loops += 1
				break
	return loops
