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


func build(dress: MeshInstance3D, vulva_point: Vector3, canal_opening: Vector3) -> bool:
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
	_commit()
	return true


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


var _flags := 0
