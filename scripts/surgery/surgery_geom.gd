extends RefCounted
## 手术腹网格：从蒂法上半身 Dress 取出腹部、生成腹腔内壁，
## 并按手绘路径在绑定空间做曲面切割与层状腹壁截面。
## 不用平面切片、CSG，也不用旧贴图伤口。
class_name SurgeryGeom

const DEFAULT_THICKNESS := 0.012
const EPS := 1e-6
const PATH_CLOSE_DIST := 0.008
## 截面 / 腹腔袋分段上限：降低分面率，减轻手机负担。
const WALL_MAX_SEGMENTS := 16
const WRAP_MAX_SEGMENTS := 28
const BULLET_SIDES := 8
const DENSE_WALL_MAX_SEGMENTS := 56

## 腹部选取（绑定空间，相对肚脐）
const BAND_Y0 := -0.22
const BAND_Y1 := 0.18
const BAND_X := 0.16
const BAND_Z := -0.06


class MeshData:
	var pos: PackedVector3Array = PackedVector3Array()
	var nrm: PackedVector3Array = PackedVector3Array()
	var uv: PackedVector2Array = PackedVector2Array()
	var bones: PackedInt32Array = PackedInt32Array()
	var weights: PackedFloat32Array = PackedFloat32Array()
	var idx: PackedInt32Array = PackedInt32Array()

	func vert_count() -> int:
		return pos.size()

	func face_count() -> int:
		return idx.size() / 3

	func add_vert(p: Vector3, n: Vector3, t: Vector2, b: PackedInt32Array, w: PackedFloat32Array) -> int:
		var i := pos.size()
		pos.append(p)
		nrm.append(n)
		uv.append(t)
		for k in 4:
			bones.append(b[k] if k < b.size() else 0)
		for k in 4:
			weights.append(w[k] if k < w.size() else 0.0)
		return i

	func copy_vert(src: MeshData, si: int) -> int:
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		for k in 4:
			b[k] = src.bones[si * 4 + k]
			w[k] = src.weights[si * 4 + k]
		return add_vert(src.pos[si], src.nrm[si], src.uv[si], b, w)

	func lerp_vert(ia: int, ib: int, t: float) -> int:
		t = clampf(t, 0.0, 1.0)
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		# 骨骼权重复用端点里较大的一组，再归一。
		var acc: Dictionary = {}
		for k in 4:
			var bi := bones[ia * 4 + k]
			var bw := weights[ia * 4 + k] * (1.0 - t)
			acc[bi] = float(acc.get(bi, 0.0)) + bw
		for k in 4:
			var bi2 := bones[ib * 4 + k]
			var bw2 := weights[ib * 4 + k] * t
			acc[bi2] = float(acc.get(bi2, 0.0)) + bw2
		var items: Array = []
		for k in acc.keys():
			items.append([float(acc[k]), int(k)])
		items.sort()
		items.reverse()
		var sumw := 0.0
		for k in 4:
			if k < items.size() and float(items[k][0]) > 0.0:
				b[k] = int(items[k][1])
				w[k] = float(items[k][0])
				sumw += w[k]
			else:
				b[k] = 0
				w[k] = 0.0
		if sumw > EPS:
			for k in 4:
				w[k] /= sumw
		var p := pos[ia].lerp(pos[ib], t)
		var n := nrm[ia].lerp(nrm[ib], t)
		if n.length_squared() > EPS:
			n = n.normalized()
		var tex := uv[ia].lerp(uv[ib], t)
		return add_vert(p, n, tex, b, w)

	func add_face(a: int, b: int, c: int) -> void:
		if a == b or b == c or c == a:
			return
		idx.append(a)
		idx.append(b)
		idx.append(c)

	func face_normal(fi: int) -> Vector3:
		var a := pos[idx[fi * 3]]
		var b := pos[idx[fi * 3 + 1]]
		var c := pos[idx[fi * 3 + 2]]
		var n := (b - a).cross(c - a)
		if n.length_squared() < EPS:
			return Vector3.FORWARD
		return n.normalized()

	func centroid(fi: int) -> Vector3:
		return (pos[idx[fi * 3]] + pos[idx[fi * 3 + 1]] + pos[idx[fi * 3 + 2]]) / 3.0

	func to_array_mesh() -> ArrayMesh:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		if bones.size() >= pos.size() * 4:
			arrays[Mesh.ARRAY_BONES] = bones
			arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = idx
		var am := ArrayMesh.new()
		if pos.is_empty() or idx.is_empty():
			return am
		var flags := 0
		if bones.size() >= pos.size() * 4:
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		else:
			arrays[Mesh.ARRAY_BONES] = null
			arrays[Mesh.ARRAY_WEIGHTS] = null
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return am

	func to_array_mesh_with_blend(shape: String, blended: MeshData) -> ArrayMesh:
		## 与 to_array_mesh 相同，并带一个同拓扑的 blend shape（用于切口外翻等）。
		if blended == null or blended.vert_count() != pos.size() or idx.is_empty():
			return to_array_mesh()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		if bones.size() >= pos.size() * 4:
			arrays[Mesh.ARRAY_BONES] = bones
			arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = idx
		var blend: Array = []
		blend.resize(Mesh.ARRAY_MAX)
		blend[Mesh.ARRAY_VERTEX] = blended.pos
		if blended.nrm.size() == pos.size():
			blend[Mesh.ARRAY_NORMAL] = blended.nrm
		var am := ArrayMesh.new()
		# Godot ArrayMesh 默认是 RELATIVE。这里传入的是目标绝对坐标；若按相对位移叠加，
		# 外翻权重到 1 时顶点会变成 rest+evert≈两倍绑定坐标，躺在检查床上的腹部会整片抬到上方。
		am.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_NORMALIZED
		am.add_blend_shape(shape)
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [blend])
		return am

	func clone() -> MeshData:
		var m := MeshData.new()
		m.pos = pos.duplicate()
		m.nrm = nrm.duplicate()
		m.uv = uv.duplicate()
		m.bones = bones.duplicate()
		m.weights = weights.duplicate()
		m.idx = idx.duplicate()
		return m


static func _v2(p: Vector3) -> Vector2:
	return Vector2(p.x, p.y)


static func extract_abdomen(mi: MeshInstance3D, navel: Vector3, include_front_only: bool = true) -> Dictionary:
	## 从 Dress 网格取出腹部三角。返回 {abdomen: MeshData, rest: MeshData, dress: MeshInstance3D}
	var out := {"abdomen": MeshData.new(), "rest": MeshData.new(), "ok": false, "dress": mi}
	if mi == null or mi.mesh == null:
		return out
	var mesh := mi.mesh
	if mesh.get_surface_count() < 1:
		return out
	var arr: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm_a: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uv_a: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var bones_a: PackedInt32Array = arr[Mesh.ARRAY_BONES] if arr[Mesh.ARRAY_BONES] != null else PackedInt32Array()
	var w_a: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS] if arr[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
	var ind: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if v.is_empty():
		return out
	if ind.is_empty():
		ind.resize(v.size())
		for i in v.size():
			ind[i] = i
	var in_band := PackedByteArray()
	in_band.resize(v.size())
	for i in v.size():
		var rel: Vector3 = v[i] - navel
		var ok := rel.y >= BAND_Y0 and rel.y <= BAND_Y1 and absf(rel.x) <= BAND_X and rel.z >= BAND_Z
		if include_front_only and nrm_a.size() > i and nrm_a[i].z < 0.05 and rel.z < 0.0:
			ok = false
		in_band[i] = 1 if ok else 0
	var ab: MeshData = out["abdomen"]
	var rest: MeshData = out["rest"]
	var map_ab: Dictionary = {}
	var map_rest: Dictionary = {}
	var _bones_of := func(i: int) -> PackedInt32Array:
		var b := PackedInt32Array()
		b.resize(4)
		for k in 4:
			var bi := i * 4 + k
			b[k] = bones_a[bi] if bi < bones_a.size() else 0
		return b
	var _w_of := func(i: int) -> PackedFloat32Array:
		var w := PackedFloat32Array()
		w.resize(4)
		for k in 4:
			var bi := i * 4 + k
			w[k] = w_a[bi] if bi < w_a.size() else 0.0
		return w
	var _nrm_of := func(i: int) -> Vector3:
		return nrm_a[i] if i < nrm_a.size() else Vector3.FORWARD
	var _uv_of := func(i: int) -> Vector2:
		return uv_a[i] if i < uv_a.size() else Vector2.ZERO
	for f in range(0, ind.size(), 3):
		var a := ind[f]
		var b := ind[f + 1]
		var c := ind[f + 2]
		if a >= v.size() or b >= v.size() or c >= v.size():
			continue
		var ab_face := int(in_band[a]) + int(in_band[b]) + int(in_band[c]) >= 2
		var dest: MeshData = ab if ab_face else rest
		var mp: Dictionary = map_ab if ab_face else map_rest
		var ia := int(mp.get(a, -1))
		if ia < 0:
			ia = dest.add_vert(v[a], _nrm_of.call(a), _uv_of.call(a), _bones_of.call(a), _w_of.call(a))
			mp[a] = ia
		var ib := int(mp.get(b, -1))
		if ib < 0:
			ib = dest.add_vert(v[b], _nrm_of.call(b), _uv_of.call(b), _bones_of.call(b), _w_of.call(b))
			mp[b] = ib
		var ic := int(mp.get(c, -1))
		if ic < 0:
			ic = dest.add_vert(v[c], _nrm_of.call(c), _uv_of.call(c), _bones_of.call(c), _w_of.call(c))
			mp[c] = ic
		dest.add_face(ia, ib, ic)
	out["ok"] = ab.face_count() > 20 and rest.face_count() > 0
	return out


static func make_cavity(outer: MeshData, thickness: float, organ_front_z: float = -1e9) -> MeshData:
	var inner := MeshData.new()
	var th := maxf(thickness, 0.004)
	for i in outer.vert_count():
		var n: Vector3 = outer.nrm[i]
		if n.length_squared() < EPS:
			n = Vector3.FORWARD
		else:
			n = n.normalized()
		var p: Vector3 = outer.pos[i] - n * th
		# 1:1 前壁只做厚度内收；不再把内壁推到脏器前方（否则包不住腹腔）。
		# organ_front_z 仅作深度下限的参考，真正的后壁/侧壁由 make_cavity_wrap 补上。
		if organ_front_z > -1e8 and p.z < organ_front_z - 0.06:
			p.z = organ_front_z - 0.06
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		for k in 4:
			b[k] = outer.bones[i * 4 + k]
			w[k] = outer.weights[i * 4 + k]
		# 内壁法线朝向脏器（向内）。
		inner.add_vert(p, -n, outer.uv[i], b, w)
	# 翻转绕序，使正面朝内。
	var fc := outer.face_count()
	for f in fc:
		var a := outer.idx[f * 3]
		var b := outer.idx[f * 3 + 1]
		var c := outer.idx[f * 3 + 2]
		inner.add_face(a, c, b)
	return inner


static func resolve_skin_bind(skin: Skin, skel: Skeleton3D, bind_i: int) -> Dictionary:
	## 本模型的 Skin.get_bind_bone 常为 -1，要靠 bind 名称找到骨骼；再不行才把槽位当骨骼索引。
	var bone_i := -1
	var bind_pose := Transform3D.IDENTITY
	if skin and bind_i >= 0 and bind_i < skin.get_bind_count():
		bone_i = skin.get_bind_bone(bind_i)
		bind_pose = skin.get_bind_pose(bind_i)
		if bone_i < 0:
			var nm := String(skin.get_bind_name(bind_i))
			if nm != "" and skel:
				bone_i = skel.find_bone(nm)
	if bone_i < 0 and skel and bind_i >= 0 and bind_i < skel.get_bone_count():
		bone_i = bind_i
		if bind_pose == Transform3D.IDENTITY:
			bind_pose = skel.get_bone_rest(bone_i).affine_inverse()
	return {"bone": bone_i, "pose": bind_pose}


static func skin_vertex(p: Vector3, vi: int, md: MeshData, skel: Skeleton3D, skin: Skin) -> Vector3:
	if skel == null or skin == null or md.bones.is_empty():
		return p
	var acc := Vector3.ZERO
	var wsum := 0.0
	for k in 4:
		var w: float = md.weights[vi * 4 + k]
		if w <= 1e-8:
			continue
		var bind_i: int = md.bones[vi * 4 + k]
		var rec: Dictionary = resolve_skin_bind(skin, skel, bind_i)
		var bone_i: int = int(rec["bone"])
		if bone_i < 0 or bone_i >= skel.get_bone_count():
			continue
		var xform := skel.get_bone_global_pose(bone_i) * (rec["pose"] as Transform3D)
		acc += w * (xform * p)
		wsum += w
	if wsum <= EPS:
		return p
	return acc / wsum


static func posed_positions(md: MeshData, skel: Skeleton3D, skin: Skin) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(md.vert_count())
	for i in md.vert_count():
		out[i] = skin_vertex(md.pos[i], i, md, skel, skin)
	return out


static func world_positions(md: MeshData, skel: Skeleton3D, skin: Skin) -> PackedVector3Array:
	var local := posed_positions(md, skel, skin)
	var xf := skel.global_transform if skel else Transform3D.IDENTITY
	for i in local.size():
		local[i] = xf * local[i]
	return local


static func _seg_intersect_2d(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Variant:
	var r := b - a
	var s := d - c
	var den := r.cross(s)
	if absf(den) < 1e-12:
		return null
	var qp := c - a
	var t := qp.cross(s) / den
	var u := qp.cross(r) / den
	if t >= 0.0 - 1e-5 and t <= 1.0 + 1e-5 and u >= 0.0 + 1e-5 and u <= 1.0 - 1e-5:
		return clampf(t, 0.0, 1.0)
	return null


static func _bary_2d(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var den := v0.cross(v1)
	if absf(den) < 1e-14:
		return Vector3(-1, -1, -1)
	var v := v2.cross(v1) / den
	var w := v0.cross(v2) / den
	var u := 1.0 - v - w
	return Vector3(u, v, w)


static func _point_in_tri_2d(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var bary := _bary_2d(p, a, b, c)
	return bary.x >= -1e-4 and bary.y >= -1e-4 and bary.z >= -1e-4


static func insert_point_in_mesh(md: MeshData, p2: Vector2, p3_hint: Vector3 = Vector3.INF) -> int:
	## 在 2D 投影里把点插进某个三角，返回顶点索引。已有近点则复用。
	## 复用顶点必须在三维上也足够近；选三角时与 _project_to_mesh 一样，
	## 在所有覆盖该 XY 的面里取离 p3_hint 最近的一张，避免预览和真正切口错位。
	var has_hint := p3_hint.x < 1e8
	var best_i := -1
	var best_d := (0.00035 * 0.00035) if has_hint else (0.00045 * 0.00045)
	for i in md.vert_count():
		var d: float
		if has_hint:
			d = md.pos[i].distance_squared_to(p3_hint)
		else:
			d = _v2(md.pos[i]).distance_squared_to(p2)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i >= 0:
		return best_i
	var found := -1
	var bary := Vector3.ZERO
	var fa := 0
	var fb := 0
	var fc := 0
	var best_s := 1e9
	for f in md.face_count():
		var a := md.idx[f * 3]
		var b := md.idx[f * 3 + 1]
		var c := md.idx[f * 3 + 2]
		var ba := _bary_2d(p2, _v2(md.pos[a]), _v2(md.pos[b]), _v2(md.pos[c]))
		if ba.x >= -1e-4 and ba.y >= -1e-4 and ba.z >= -1e-4:
			var got: Vector3 = md.pos[a] * ba.x + md.pos[b] * ba.y + md.pos[c] * ba.z
			var s := got.distance_squared_to(p3_hint) if has_hint else got.distance_squared_to(Vector3(p2.x, p2.y, got.z))
			if s < best_s:
				best_s = s
				found = f
				bary = ba
				fa = a
				fb = b
				fc = c
	if found < 0:
		# 最近三角的投影：有三维提示时按 3D 距离，否则按 XY 重心。
		best_s = 1e9
		for f2 in md.face_count():
			var a2 := md.idx[f2 * 3]
			var b2 := md.idx[f2 * 3 + 1]
			var c2 := md.idx[f2 * 3 + 2]
			var ba2 := _bary_2d(p2, _v2(md.pos[a2]), _v2(md.pos[b2]), _v2(md.pos[c2]))
			var bx := maxf(ba2.x, 0.0)
			var by := maxf(ba2.y, 0.0)
			var bz := maxf(ba2.z, 0.0)
			var sm := bx + by + bz
			if sm > EPS:
				bx /= sm
				by /= sm
				bz /= sm
			else:
				bx = 1.0 / 3.0
				by = 1.0 / 3.0
				bz = 1.0 / 3.0
			var got2: Vector3 = md.pos[a2] * bx + md.pos[b2] * by + md.pos[c2] * bz
			var s2: float
			if has_hint:
				s2 = got2.distance_squared_to(p3_hint)
			else:
				var cen := (_v2(md.pos[a2]) + _v2(md.pos[b2]) + _v2(md.pos[c2])) / 3.0
				s2 = cen.distance_squared_to(p2)
			if s2 < best_s:
				best_s = s2
				found = f2
				fa = a2
				fb = b2
				fc = c2
				bary = Vector3(bx, by, bz)
	if found < 0:
		return -1
	# 用三维重心插值，保证点落在原来的曲面上。
	# 路径提示只在已经贴面时采用，避免世界坐标误当绑定坐标插入后把腹网拉到天上。
	var p := md.pos[fa] * bary.x + md.pos[fb] * bary.y + md.pos[fc] * bary.z
	if has_hint and p3_hint.distance_squared_to(p) <= 0.012 * 0.012:
		p = p3_hint
	var n := (md.nrm[fa] * bary.x + md.nrm[fb] * bary.y + md.nrm[fc] * bary.z)
	if n.length_squared() > EPS:
		n = n.normalized()
	var tex := md.uv[fa] * bary.x + md.uv[fb] * bary.y + md.uv[fc] * bary.z
	# 权重
	var acc: Dictionary = {}
	for src_i in [[fa, bary.x], [fb, bary.y], [fc, bary.z]]:
		var si: int = src_i[0]
		var sw: float = src_i[1]
		for k in 4:
			var bi := md.bones[si * 4 + k]
			acc[bi] = float(acc.get(bi, 0.0)) + md.weights[si * 4 + k] * sw
	var items: Array = []
	for k in acc.keys():
		items.append([float(acc[k]), int(k)])
	items.sort()
	items.reverse()
	var bnew := PackedInt32Array()
	var wnew := PackedFloat32Array()
	bnew.resize(4)
	wnew.resize(4)
	var sumw := 0.0
	for k in 4:
		if k < items.size():
			bnew[k] = int(items[k][1])
			wnew[k] = float(items[k][0])
			sumw += wnew[k]
		else:
			bnew[k] = 0
			wnew[k] = 0.0
	if sumw > EPS:
		for k in 4:
			wnew[k] /= sumw
	var ni := md.add_vert(p, n, tex, bnew, wnew)
	# 把原三角替换成三块。
	var new_idx := PackedInt32Array()
	for f3 in md.face_count():
		if f3 == found:
			new_idx.append(fa)
			new_idx.append(fb)
			new_idx.append(ni)
			new_idx.append(fb)
			new_idx.append(fc)
			new_idx.append(ni)
			new_idx.append(fc)
			new_idx.append(fa)
			new_idx.append(ni)
		else:
			new_idx.append(md.idx[f3 * 3])
			new_idx.append(md.idx[f3 * 3 + 1])
			new_idx.append(md.idx[f3 * 3 + 2])
	md.idx = new_idx
	return ni


static func _split_edge_at(md: MeshData, ia: int, ib: int, t: float) -> int:
	# 若端点已足够近，复用。
	if t <= 0.02:
		return ia
	if t >= 0.98:
		return ib
	var p := md.pos[ia].lerp(md.pos[ib], t)
	for i in md.vert_count():
		if md.pos[i].distance_squared_to(p) < 1e-10:
			return i
	var mid := md.lerp_vert(ia, ib, t)
	var new_idx := PackedInt32Array()
	for f in md.face_count():
		var a := md.idx[f * 3]
		var b := md.idx[f * 3 + 1]
		var c := md.idx[f * 3 + 2]
		var hits: Array = []
		if (a == ia and b == ib) or (a == ib and b == ia):
			hits.append([0, 1])
		if (b == ia and c == ib) or (b == ib and c == ia):
			hits.append([1, 2])
		if (c == ia and a == ib) or (c == ib and a == ia):
			hits.append([2, 0])
		if hits.is_empty():
			new_idx.append(a)
			new_idx.append(b)
			new_idx.append(c)
			continue
		var vs := [a, b, c]
		# 一条边被拆：分成两个三角。
		var e: Array = hits[0]
		var i0: int = vs[e[0]]
		var i1: int = vs[e[1]]
		var i2: int = vs[3 - e[0] - e[1]]
		new_idx.append(i0)
		new_idx.append(mid)
		new_idx.append(i2)
		new_idx.append(mid)
		new_idx.append(i1)
		new_idx.append(i2)
	md.idx = new_idx
	return mid


static func connect_points(md: MeshData, ia: int, ib: int) -> PackedInt32Array:
	## 在曲面上把 ia 连到 ib：切开所有与 2D 线段相交的边。返回沿途顶点（含两端）。
	var chain := PackedInt32Array()
	chain.append(ia)
	if ia == ib:
		return chain
	var guard := 0
	var cur := ia
	while cur != ib and guard < 400:
		guard += 1
		# 已经有直连边？
		var linked := false
		for f in md.face_count():
			var a := md.idx[f * 3]
			var b := md.idx[f * 3 + 1]
			var c := md.idx[f * 3 + 2]
			if (a == cur and (b == ib or c == ib)) or (b == cur and (a == ib or c == ib)) or (c == cur and (a == ib or b == ib)):
				linked = true
				break
		if linked:
			chain.append(ib)
			cur = ib
			break
		var a2 := _v2(md.pos[cur])
		var b2 := _v2(md.pos[ib])
		var best_t := 1.1
		var best_ia := -1
		var best_ib := -1
		var best_u := 0.0
		# 收集当前网格边，找与 cur-ib 相交、离 cur 最近的一次。
		var seen: Dictionary = {}
		for f2 in md.face_count():
			var vs := [md.idx[f2 * 3], md.idx[f2 * 3 + 1], md.idx[f2 * 3 + 2]]
			for e in 3:
				var ea: int = vs[e]
				var eb: int = vs[(e + 1) % 3]
				if ea == eb:
					continue
				var key := mini(ea, eb) * 1000003 + maxi(ea, eb)
				if seen.has(key):
					continue
				seen[key] = true
				if ea == cur or eb == cur or ea == ib or eb == ib:
					continue
				var hit: Variant = _seg_intersect_2d(a2, b2, _v2(md.pos[ea]), _v2(md.pos[eb]))
				if hit == null:
					continue
				var t: float = float(hit)
				if t < 1e-4 or t > 1.0 - 1e-4:
					continue
				if t < best_t:
					best_t = t
					best_ia = ea
					best_ib = eb
					var pa := _v2(md.pos[ea])
					var pb := _v2(md.pos[eb])
					var den := (pb - pa).length_squared()
					best_u = 0.5 if den < EPS else (a2.lerp(b2, t) - pa).dot(pb - pa) / den
		if best_ia < 0:
			# 没有相交边，直接结束（可能共面但数值漂了）。
			chain.append(ib)
			break
		var mid := _split_edge_at(md, best_ia, best_ib, clampf(best_u, 0.02, 0.98))
		if mid == cur:
			chain.append(ib)
			break
		chain.append(mid)
		cur = mid
	if chain[chain.size() - 1] != ib:
		chain.append(ib)
	return chain


static func embed_path(md: MeshData, path3: PackedVector3Array) -> PackedInt32Array:
	## 把一条 3D 路径嵌进网格，返回路径顶点索引。会同步拆分三角。
	var ids := PackedInt32Array()
	if path3.size() < 2:
		return ids
	for i in path3.size():
		var p := path3[i]
		var vid := insert_point_in_mesh(md, _v2(p), p)
		if vid < 0:
			continue
		if ids.size() > 0 and ids[ids.size() - 1] == vid:
			continue
		if ids.size() > 0:
			var chain := connect_points(md, ids[ids.size() - 1], vid)
			for k in range(1, chain.size()):
				if ids.size() == 0 or ids[ids.size() - 1] != chain[k]:
					ids.append(chain[k])
		else:
			ids.append(vid)
	return ids


static func apply_same_splits(src_after: MeshData, dst_before: MeshData, index_map: Dictionary) -> void:
	## 不再使用：切割在 clone 上做完后，对 cavity 用同一套操作更简单。
	pass


static func embed_path_paired(outer: MeshData, inner: MeshData, path3: PackedVector3Array) -> PackedInt32Array:
	## 对外皮做路径嵌入，同时按相同顶点对应关系拆分内壁（内外顶点数保持同步）。
	# 先保证 inner 是 outer 的 1:1 克隆拓扑（顶点顺序一致）。
	if inner.vert_count() != outer.vert_count() or inner.idx.size() != outer.idx.size():
		push_warning("surgery: inner/outer topology mismatch")
		return embed_path(outer, path3)
	# 在 outer 上嵌入；每次 add_vert / 改 idx 时同步 inner。
	# 简化做法：只在 outer 上嵌入，然后按新顶点用最近外皮顶点的对应内壁点插值扩 inner。
	var old_count := outer.vert_count()
	var old_idx := outer.idx.duplicate()
	var ids := embed_path(outer, path3)
	# 把 inner 重建为与 outer 相同的三角，新增顶点沿对应边/重心插值。
	if outer.vert_count() == old_count and outer.idx.size() == old_idx.size():
		return ids
	# 新增顶点：用 outer 的来源不好追踪，按 2D 最近的「旧」顶点 + 法向厚度从内壁近似。
	# 更稳：对每个新 outer 顶点，用三个最近旧顶点做插值。
	var inner_new := MeshData.new()
	for i in outer.vert_count():
		if i < old_count:
			inner_new.copy_vert(inner, i)
			continue
		# 找外皮上最近的三个旧顶点做插值。
		var p2 := _v2(outer.pos[i])
		var best: Array = []
		for j in old_count:
			best.append([_v2(outer.pos[j]).distance_squared_to(p2), j])
		best.sort()
		var wsum := 0.0
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		var tex := Vector2.ZERO
		var acc: Dictionary = {}
		for k in mini(3, best.size()):
			var j: int = best[k][1]
			var ww := 1.0 / maxf(sqrt(float(best[k][0])), 1e-5)
			wsum += ww
			p += inner.pos[j] * ww
			n += inner.nrm[j] * ww
			tex += inner.uv[j] * ww
			for q in 4:
				var bi := inner.bones[j * 4 + q]
				acc[bi] = float(acc.get(bi, 0.0)) + inner.weights[j * 4 + q] * ww
		if wsum > EPS:
			p /= wsum
			n /= wsum
			tex /= wsum
		if n.length_squared() > EPS:
			n = n.normalized()
		var bnew := PackedInt32Array()
		var wnew := PackedFloat32Array()
		bnew.resize(4)
		wnew.resize(4)
		var items: Array = []
		for k in acc.keys():
			items.append([float(acc[k]), int(k)])
		items.sort()
		items.reverse()
		var sw := 0.0
		for k in 4:
			if k < items.size():
				bnew[k] = int(items[k][1])
				wnew[k] = float(items[k][0])
				sw += wnew[k]
			else:
				bnew[k] = 0
				wnew[k] = 0.0
		if sw > EPS:
			for k in 4:
				wnew[k] /= sw
		inner_new.add_vert(p, n, tex, bnew, wnew)
	inner_new.idx = outer.idx.duplicate()
	# 内壁三角绕序保持翻转（与生成时一致）。outer 新三角是正向，inner 需要翻转。
	var flipped := PackedInt32Array()
	for f in inner_new.face_count():
		var a := inner_new.idx[f * 3]
		var b := inner_new.idx[f * 3 + 1]
		var c := inner_new.idx[f * 3 + 2]
		flipped.append(a)
		flipped.append(c)
		flipped.append(b)
	inner_new.idx = flipped
	inner.pos = inner_new.pos
	inner.nrm = inner_new.nrm
	inner.uv = inner_new.uv
	inner.bones = inner_new.bones
	inner.weights = inner_new.weights
	inner.idx = inner_new.idx
	return ids


static func point_in_poly(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	if n < 3:
		return false
	var j := n - 1
	for i in n:
		var pi := poly[i]
		var pj := poly[j]
		if ((pi.y > p.y) != (pj.y > p.y)) and (p.x < (pj.x - pi.x) * (p.y - pi.y) / maxf(pj.y - pi.y, 1e-12) + pi.x):
			inside = not inside
		j = i
	return inside


static func is_path_closed(path3: PackedVector3Array, ids: PackedInt32Array = PackedInt32Array()) -> bool:
	if ids.size() >= 3 and ids[0] == ids[ids.size() - 1]:
		return true
	if path3.size() >= 3 and path3[0].distance_to(path3[path3.size() - 1]) <= PATH_CLOSE_DIST:
		return true
	return false


static func close_path_ids(md: MeshData, ids: PackedInt32Array) -> PackedInt32Array:
	if ids.size() < 3:
		return ids
	if ids[0] == ids[ids.size() - 1]:
		return ids
	var chain := connect_points(md, ids[ids.size() - 1], ids[0])
	var out := ids.duplicate()
	for k in range(1, chain.size()):
		if out[out.size() - 1] != chain[k]:
			out.append(chain[k])
	return out


static func loft_wall(body: MeshData, outer_ids: PackedInt32Array, inner_ids: PackedInt32Array, closed: bool) -> int:
	## 在 body 上追加连接外缘与内缘的层状截面三角，返回新增三角数。
	var n := mini(outer_ids.size(), inner_ids.size())
	if n < 2:
		return 0
	var added := 0
	var last := n if closed else n - 1
	# 截面法线大致沿切向，绕序：外 i -> 外 i+1 -> 内 i+1 -> 内 i，从切口里看得到正面。
	for i in last:
		var i0 := i
		var i1 := (i + 1) % n
		var oa := outer_ids[i0]
		var ob := outer_ids[i1]
		var ib := inner_ids[i1]
		var ia := inner_ids[i0]
		if oa < 0 or ob < 0 or ia < 0 or ib < 0:
			continue
		body.add_face(oa, ob, ib)
		body.add_face(oa, ib, ia)
		added += 2
	return added


static func extract_inside(md: MeshData, loop_ids: PackedInt32Array) -> Dictionary:
	## 按 2D 环把三角分成环内 / 环外。返回 {inside: MeshData, outside: MeshData, loop: PackedInt32Array}
	var poly := PackedVector2Array()
	var used: Dictionary = {}
	var clean := PackedInt32Array()
	for i in loop_ids.size():
		var id: int = loop_ids[i]
		if i > 0 and id == loop_ids[0] and i == loop_ids.size() - 1:
			break
		if used.has(id) and id != loop_ids[0]:
			continue
		used[id] = true
		clean.append(id)
		poly.append(_v2(md.pos[id]))
	var inside := MeshData.new()
	var outside := MeshData.new()
	var map_in: Dictionary = {}
	var map_out: Dictionary = {}
	var _xfer := func(dest: MeshData, mp: Dictionary, si: int) -> int:
		var e := int(mp.get(si, -1))
		if e < 0:
			e = dest.copy_vert(md, si)
			mp[si] = e
		return e
	var area_in := 0.0
	var area_out := 0.0
	var faces_in: Array = []
	var faces_out: Array = []
	for f in md.face_count():
		var a := md.idx[f * 3]
		var b := md.idx[f * 3 + 1]
		var c := md.idx[f * 3 + 2]
		var votes := 0
		for vi in [a, b, c]:
			if absf(winding_number(_v2(md.pos[vi]), poly)) >= 0.5:
				votes += 1
		var cen := _v2(md.centroid(f))
		var cen_in := absf(winding_number(cen, poly)) >= 0.5
		# 擦边三角：至少两顶点在内，或一顶点且重心明确在内，才算皮瓣。
		var inn := votes >= 2 or (votes == 1 and cen_in)
		var ar := _tri_area_xy(md.pos[a], md.pos[b], md.pos[c])
		if inn:
			faces_in.append([a, b, c])
			area_in += ar
		else:
			faces_out.append([a, b, c])
			area_out += ar
	# 皮瓣应是被环围住的较小一侧，避免自交/绕向把整片腹壁判成内侧。
	if area_in > area_out and area_out > 1e-8:
		var tmp_f: Array = faces_in
		faces_in = faces_out
		faces_out = tmp_f
		var tmp_a := area_in
		area_in = area_out
		area_out = tmp_a
	for tri in faces_in:
		inside.add_face(_xfer.call(inside, map_in, tri[0]), _xfer.call(inside, map_in, tri[1]), _xfer.call(inside, map_in, tri[2]))
	for tri2 in faces_out:
		outside.add_face(_xfer.call(outside, map_out, tri2[0]), _xfer.call(outside, map_out, tri2[1]), _xfer.call(outside, map_out, tri2[2]))
	# 环上顶点在内外都要有，截面才能焊上。
	var loop_in := PackedInt32Array()
	var loop_out := PackedInt32Array()
	for id2 in clean:
		loop_in.append(_xfer.call(inside, map_in, id2))
		loop_out.append(_xfer.call(outside, map_out, id2))
	return {
		"inside": inside,
		"outside": outside,
		"loop_in": loop_in,
		"loop_out": loop_out,
		"loop_src": clean,
		"inside_faces": inside.face_count(),
		"outside_faces": outside.face_count(),
		"inside_area": area_in,
		"outside_area": area_out,
	}


static func open_slit(md: MeshData, path_ids: PackedInt32Array, width: float) -> Dictionary:
	## 沿开放路径把顶点复制成左右唇，并沿垂直于路径的切向微微张开。
	var n := path_ids.size()
	if n < 2:
		return {"ok": false, "left": path_ids, "right": path_ids}
	var left := PackedInt32Array()
	var right := PackedInt32Array()
	left.resize(n)
	right.resize(n)
	# 端点保持焊接，中间点复制。
	for i in n:
		var id: int = path_ids[i]
		if i == 0 or i == n - 1:
			left[i] = id
			right[i] = id
			continue
		var prev := md.pos[path_ids[i - 1]]
		var nxt := md.pos[path_ids[mini(i + 1, n - 1)]]
		var tang := (nxt - prev)
		var nrm: Vector3 = md.nrm[id]
		var side := nrm.cross(tang)
		if side.length_squared() < EPS:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var copy := md.copy_vert(md, id)
		md.pos[id] = md.pos[id] + side * width * 0.5
		md.pos[copy] = md.pos[copy] - side * width * 0.5
		left[i] = id
		right[i] = copy
	# 按路径左侧 / 右侧重焊邻接三角：看三角重心在路径 2D 的哪一侧。
	# 简化：凡是用到被复制顶点的三角，按重心相对路径的叉积决定用 left 还是 right。
	var poly := PackedVector2Array()
	# 用路径做一个有向折线，判断点在左还是右。
	var new_idx := PackedInt32Array()
	for f in md.face_count():
		var tri := [md.idx[f * 3], md.idx[f * 3 + 1], md.idx[f * 3 + 2]]
		var replaced := false
		var cen := Vector2.ZERO
		for k in 3:
			cen += _v2(md.pos[tri[k]])
		cen /= 3.0
		var side_sign := 0.0
		for i2 in n - 1:
			var a := _v2(md.pos[path_ids[i2]] if i2 == 0 or i2 == n - 1 else md.pos[left[i2]])
			# 用原始路径位置更稳：改用原始 path 的 2D（张开前已改坐标，用相邻未改端点近似）。
		# 用复制前无法取回，改用 left/right 中点。
		for i3 in n - 1:
			var pa := _v2((md.pos[left[i3]] + md.pos[right[i3]]) * 0.5)
			var pb := _v2((md.pos[left[i3 + 1]] + md.pos[right[i3 + 1]]) * 0.5)
			var dir := pb - pa
			if dir.length_squared() < EPS:
				continue
			var t := clampf((cen - pa).dot(dir) / dir.length_squared(), 0.0, 1.0)
			if t <= 0.0 or t >= 1.0:
				if i3 != 0 and i3 != n - 2:
					continue
			var perp := dir.orthogonal()
			side_sign += perp.dot(cen - pa.lerp(pb, t))
		for k2 in 3:
			var vi: int = tri[k2]
			for i4 in n:
				if i4 == 0 or i4 == n - 1:
					continue
				if vi == path_ids[i4] or vi == left[i4] or vi == right[i4]:
					tri[k2] = left[i4] if side_sign >= 0.0 else right[i4]
					replaced = true
		new_idx.append(tri[0])
		new_idx.append(tri[1])
		new_idx.append(tri[2])
	md.idx = new_idx
	return {"ok": true, "left": left, "right": right}


static func ray_hit_mesh(md: MeshData, posed: PackedVector3Array, origin: Vector3, dir: Vector3) -> Variant:
	## 返回 {point, tri, bary, dist, index}（point 为世界/posed 空间，bary 可用于绑定空间插值）
	if posed.size() != md.vert_count():
		return null
	var best_t := 1e9
	var best: Dictionary = {}
	var d := dir.normalized()
	for f in md.face_count():
		var ia := md.idx[f * 3]
		var ib := md.idx[f * 3 + 1]
		var ic := md.idx[f * 3 + 2]
		if ia >= posed.size() or ib >= posed.size() or ic >= posed.size():
			continue
		var a := posed[ia]
		var b := posed[ib]
		var c := posed[ic]
		var n := (b - a).cross(c - a)
		var denom := n.dot(d)
		if absf(denom) < 1e-10:
			continue
		var t := n.dot(a - origin) / denom
		if t < 0.0005 or t >= best_t:
			continue
		var p := origin + d * t
		var v0 := b - a
		var v1 := c - a
		var v2 := p - a
		var dot00 := v0.dot(v0)
		var dot01 := v0.dot(v1)
		var dot02 := v0.dot(v2)
		var dot11 := v1.dot(v1)
		var dot12 := v1.dot(v2)
		var inv := dot00 * dot11 - dot01 * dot01
		if absf(inv) < 1e-14:
			continue
		inv = 1.0 / inv
		var u := (dot11 * dot02 - dot01 * dot12) * inv
		var v := (dot00 * dot12 - dot01 * dot02) * inv
		if u >= -1e-3 and v >= -1e-3 and u + v <= 1.0 + 1e-3:
			best_t = t
			var bind_p := md.pos[ia] * (1.0 - u - v) + md.pos[ib] * u + md.pos[ic] * v
			best = {
				"point": p,
				"bind": bind_p,
				"tri": f,
				"bary": Vector3(1.0 - u - v, u, v),
				"dist": t,
				"i0": ia,
				"i1": ib,
				"i2": ic,
			}
	if best.is_empty():
		return null
	return best


static func oval_path_on_mesh(md: MeshData, center: Vector3, rx: float, ry: float, steps: int = 24) -> PackedVector3Array:
	## 在腹前用绑定空间 XY 椭圆取样，再投影到网格表面，生成闭合路径。
	## 投影与 line_path_on_mesh / _project_to_mesh 相同：在覆盖该 XY 的面里取离提示点最近的一张，
	## 避免环状预览落在第一张 XY 命中面上、嵌入却贴到另一层而错位。
	var path := PackedVector3Array()
	for i in steps:
		var ang := TAU * float(i) / float(steps)
		var hint := Vector3(center.x + cos(ang) * rx, center.y + sin(ang) * ry, center.z)
		path.append(_project_to_mesh(md, hint, hint))
	# 闭合：末点不要重复，判定时再连回起点。
	return path


static func sync_inner(outer: MeshData, inner: MeshData) -> void:
	## 在 outer 增删顶点 / 改三角之后，把 inner 补到相同拓扑（新顶点按邻近旧点插值）。
	if outer == null or inner == null:
		return
	var old_count := inner.vert_count()
	if old_count == 0:
		return
	while inner.vert_count() < outer.vert_count():
		var i := inner.vert_count()
		var p2 := _v2(outer.pos[i])
		var best: Array = []
		for j in old_count:
			best.append([_v2(outer.pos[j] if j < outer.vert_count() else inner.pos[j]).distance_squared_to(p2), j])
		best.sort()
		var wsum := 0.0
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		var tex := Vector2.ZERO
		var acc: Dictionary = {}
		for k in mini(3, best.size()):
			var j: int = best[k][1]
			if j >= inner.vert_count():
				continue
			var ww := 1.0 / maxf(sqrt(float(best[k][0])), 1e-5)
			wsum += ww
			p += inner.pos[j] * ww
			n += inner.nrm[j] * ww
			tex += inner.uv[j] * ww
			for q in 4:
				var bi := inner.bones[j * 4 + q]
				acc[bi] = float(acc.get(bi, 0.0)) + inner.weights[j * 4 + q] * ww
		if wsum > EPS:
			p /= wsum
			n /= wsum
			tex /= wsum
		if n.length_squared() > EPS:
			n = n.normalized()
		var bnew := PackedInt32Array()
		var wnew := PackedFloat32Array()
		bnew.resize(4)
		wnew.resize(4)
		var items: Array = []
		for k in acc.keys():
			items.append([float(acc[k]), int(k)])
		items.sort()
		items.reverse()
		var sw := 0.0
		for k in 4:
			if k < items.size():
				bnew[k] = int(items[k][1])
				wnew[k] = float(items[k][0])
				sw += wnew[k]
			else:
				bnew[k] = 0
				wnew[k] = 0.0
		if sw > EPS:
			for k2 in 4:
				wnew[k2] /= sw
		inner.add_vert(p, n, tex, bnew, wnew)
	# 三角：拷贝 outer 并翻转绕序。
	var flipped := PackedInt32Array()
	var vc := inner.vert_count()
	for f in outer.face_count():
		var a := outer.idx[f * 3]
		var b := outer.idx[f * 3 + 1]
		var c := outer.idx[f * 3 + 2]
		if a < vc and b < vc and c < vc:
			flipped.append(a)
			flipped.append(c)
			flipped.append(b)
	if flipped.size() >= 3:
		inner.idx = flipped


static func open_loop_slit(md: MeshData, loop_ids: PackedInt32Array, width: float) -> Dictionary:
	## 闭合环：环上每个顶点都复制成内唇 / 外唇并沿切向张开，供切开后看见截面。
	var ids := PackedInt32Array()
	for i in loop_ids.size():
		var id: int = loop_ids[i]
		if ids.size() > 0 and ids[ids.size() - 1] == id:
			continue
		if ids.size() > 0 and i == loop_ids.size() - 1 and id == ids[0]:
			continue
		ids.append(id)
	var n := ids.size()
	if n < 3:
		return {"ok": false, "left": loop_ids, "right": loop_ids}
	var poly := PackedVector2Array()
	for i in n:
		poly.append(_v2(md.pos[ids[i]]))
	var left := PackedInt32Array()
	var right := PackedInt32Array()
	left.resize(n)
	right.resize(n)
	var loop_set: Dictionary = {}
	for i in n:
		loop_set[ids[i]] = i
	for i in n:
		var id: int = ids[i]
		var prev := md.pos[ids[(i - 1 + n) % n]]
		var nxt := md.pos[ids[(i + 1) % n]]
		var tang := nxt - prev
		var nrm: Vector3 = md.nrm[id]
		var side := nrm.cross(tang)
		if side.length_squared() < EPS:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var copy := md.copy_vert(md, id)
		md.pos[id] = md.pos[id] + side * width * 0.5
		md.pos[copy] = md.pos[copy] - side * width * 0.5
		left[i] = id
		right[i] = copy
	var new_idx := PackedInt32Array()
	for f in md.face_count():
		var tri := [md.idx[f * 3], md.idx[f * 3 + 1], md.idx[f * 3 + 2]]
		var cen := Vector2.ZERO
		for k in 3:
			var vi: int = tri[k]
			if loop_set.has(vi):
				cen += poly[int(loop_set[vi])]
			else:
				cen += _v2(md.pos[vi])
		cen /= 3.0
		var inside := point_in_poly(cen, poly)
		for k2 in 3:
			if loop_set.has(tri[k2]):
				var ii := int(loop_set[tri[k2]])
				tri[k2] = left[ii] if inside else right[ii]
		new_idx.append(tri[0])
		new_idx.append(tri[1])
		new_idx.append(tri[2])
	md.idx = new_idx
	var left_c := left.duplicate()
	left_c.append(left[0])
	var right_c := right.duplicate()
	right_c.append(right[0])
	return {"ok": true, "left": left_c, "right": right_c}


static func _tri_area_xy(a: Vector3, b: Vector3, c: Vector3) -> float:
	return absf((_v2(b) - _v2(a)).cross(_v2(c) - _v2(a))) * 0.5


static func winding_number(p: Vector2, poly: PackedVector2Array) -> float:
	var w := 0.0
	var n := poly.size()
	if n < 3:
		return 0.0
	var j := n - 1
	for i in n:
		var a := poly[j]
		var b := poly[i]
		if a.y <= p.y:
			if b.y > p.y and (b - a).cross(p - a) > 0.0:
				w += 1.0
		else:
			if b.y <= p.y and (b - a).cross(p - a) < 0.0:
				w -= 1.0
		j = i
	return w


static func simplify_path(path: PackedVector3Array, tol: float = 0.003, max_pts: int = 48) -> PackedVector3Array:
	## Ramer–Douglas–Peucker（XY）+ 点数上限，减轻密采样手绘卡顿。
	if path.size() <= 2:
		return path.duplicate()
	var use_tol := maxf(tol, 0.0005)
	var out := _rdp(path, use_tol)
	var guard := 0
	while out.size() > max_pts and use_tol < 0.08 and guard < 12:
		use_tol *= 1.45
		out = _rdp(path, use_tol)
		guard += 1
	if out.size() < 2:
		out = PackedVector3Array()
		out.append(path[0])
		out.append(path[path.size() - 1])
	return out


static func _rdp(path: PackedVector3Array, tol: float) -> PackedVector3Array:
	var n := path.size()
	if n <= 2:
		return path.duplicate()
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	_rdp_mark(path, 0, n - 1, tol, keep)
	var out := PackedVector3Array()
	for i in n:
		if keep[i] != 0:
			out.append(path[i])
	return out


static func _rdp_mark(path: PackedVector3Array, i0: int, i1: int, tol: float, keep: PackedByteArray) -> void:
	if i1 <= i0 + 1:
		return
	var a := _v2(path[i0])
	var b := _v2(path[i1])
	var ab := b - a
	var denom := ab.length_squared()
	var best_i := -1
	var best_d := tol
	for i in range(i0 + 1, i1):
		var p := _v2(path[i])
		var d: float
		if denom < 1e-16:
			d = p.distance_to(a)
		else:
			var t := clampf((p - a).dot(ab) / denom, 0.0, 1.0)
			d = p.distance_to(a.lerp(b, t))
		if d > best_d:
			best_d = d
			best_i = i
	if best_i >= 0:
		keep[best_i] = 1
		_rdp_mark(path, i0, best_i, tol, keep)
		_rdp_mark(path, best_i, i1, tol, keep)


static func path_area_xy(path: PackedVector3Array) -> float:
	var n := path.size()
	if n < 3:
		return 0.0
	var acc := 0.0
	var last := n - 1
	if path[0].distance_to(path[last]) <= PATH_CLOSE_DIST:
		last = n - 2
	var j := last
	for i in range(0, last + 1):
		var a := _v2(path[i])
		var b := _v2(path[j])
		acc += (b.x + a.x) * (b.y - a.y)
		j = i
	return absf(acc) * 0.5


static func clean_closed_loop(path: PackedVector3Array) -> PackedVector3Array:
	## 去重、简化，并把自交路径收成面积最大的简单环，避免剥错皮瓣。
	var work := PackedVector3Array()
	for p in path:
		if work.is_empty() or work[work.size() - 1].distance_to(p) > 0.001:
			work.append(p)
	if work.size() >= 2 and work[0].distance_to(work[work.size() - 1]) <= PATH_CLOSE_DIST:
		work.remove_at(work.size() - 1)
	work = simplify_path(work, 0.0024, 56)
	return largest_simple_loop(work)


static func largest_simple_loop(path: PackedVector3Array) -> PackedVector3Array:
	var n := path.size()
	if n < 4:
		return path.duplicate()
	var m := n
	if path[0].distance_to(path[n - 1]) <= PATH_CLOSE_DIST:
		m = n - 1
	if m < 4:
		return path.duplicate()
	var best := PackedVector3Array()
	var best_area := -1.0
	for i in m:
		var a0 := path[i]
		var a1 := path[(i + 1) % m]
		for j in range(i + 2, m):
			if i == 0 and j == m - 1:
				continue
			var b0 := path[j]
			var b1 := path[(j + 1) % m]
			var t: Variant = _seg_intersect_2d(_v2(a0), _v2(a1), _v2(b0), _v2(b1))
			if t == null:
				continue
			var hit: Vector3 = a0.lerp(a1, float(t))
			var loop := PackedVector3Array()
			loop.append(hit)
			var k := (i + 1) % m
			var guard := 0
			while k != (j + 1) % m and guard < m + 2:
				loop.append(path[k])
				k = (k + 1) % m
				guard += 1
			if loop.size() >= 3:
				var ar := path_area_xy(loop)
				if ar > best_area:
					best_area = ar
					best = loop
	if best.size() >= 3:
		return best
	return path.duplicate()


static func mesh_boundary_loop(md: MeshData) -> PackedInt32Array:
	var count: Dictionary = {}
	var ends: Dictionary = {}
	for f in md.face_count():
		var tri := [md.idx[f * 3], md.idx[f * 3 + 1], md.idx[f * 3 + 2]]
		for k in 3:
			var a: int = tri[k]
			var b: int = tri[(k + 1) % 3]
			var key := "%d_%d" % [mini(a, b), maxi(a, b)]
			count[key] = int(count.get(key, 0)) + 1
			if not ends.has(key):
				ends[key] = [a, b]
	var nbrs: Dictionary = {}
	for key in count.keys():
		if int(count[key]) != 1:
			continue
		var e: Array = ends[key]
		if not nbrs.has(e[0]):
			nbrs[e[0]] = []
		if not nbrs.has(e[1]):
			nbrs[e[1]] = []
		(nbrs[e[0]] as Array).append(e[1])
		(nbrs[e[1]] as Array).append(e[0])
	if nbrs.is_empty():
		return PackedInt32Array()
	var start: int = int(nbrs.keys()[0])
	for id in nbrs.keys():
		start = int(id)
		break
	var loop := PackedInt32Array()
	var prev := -1
	var cur := start
	for _s in md.vert_count() + 4:
		loop.append(cur)
		var opts: Array = nbrs.get(cur, [])
		var nxt := -1
		for o in opts:
			if int(o) != prev:
				nxt = int(o)
				break
		if nxt < 0 or nxt == start:
			if nxt == start:
				loop.append(start)
			break
		prev = cur
		cur = nxt
	return loop


static func lumbar_exterior_z(md: MeshData, navel: Vector3, y0: float = -0.16, y1: float = -0.02) -> float:
	## 后腰外皮在绑定空间的最靠后 Z（越小越靠后）。没有采样点时返回一个保守下限。
	if md == null or md.vert_count() < 1:
		return navel.z - 0.10
	var found := false
	var zmin := 1e9
	for i in md.vert_count():
		var p: Vector3 = md.pos[i]
		var rel := p - navel
		if rel.y < y0 or rel.y > y1 or absf(rel.x) > 0.14:
			continue
		# 朝后的顶点（或已经在肚脐后方）才算后腰外皮。
		var nrm: Vector3 = md.nrm[i] if i < md.nrm.size() else Vector3.ZERO
		if nrm.z > 0.15 and rel.z > -0.02:
			continue
		zmin = minf(zmin, p.z)
		found = true
	if not found:
		return -1e9
	return zmin


static func line_path_on_mesh(md: MeshData, a: Vector3, b: Vector3, steps: int = 12) -> PackedVector3Array:
	var path := PackedVector3Array()
	var n := maxi(steps, 2)
	for i in n + 1:
		var t := float(i) / float(n)
		var p: Vector3 = a.lerp(b, t)
		path.append(_project_to_mesh(md, p, p))
	return path


static func make_cavity_wrap(inner: MeshData, back_z: float, guts_min: Vector3 = Vector3.INF, guts_max: Vector3 = Vector3.INF, lumbar_z: float = -1e9) -> MeshData:
	## 从前壁边界挤到腹腔后方，再封后盖，把脏器体积包进袋状腔。
	## 后盖向中心收窄、后腰方向抬高，避免整圈前壁剪影直推到腰椎外皮之外。
	var wrap := MeshData.new()
	var loop := mesh_boundary_loop(inner)
	var ids := PackedInt32Array()
	for i in loop.size():
		var id: int = loop[i]
		if ids.size() > 0 and ids[ids.size() - 1] == id:
			continue
		if ids.size() > 0 and i == loop.size() - 1 and id == ids[0]:
			continue
		ids.append(id)
	ids = resample_index_loop(inner, ids, WRAP_MAX_SEGMENTS)
	var n := ids.size()
	if n < 3:
		return wrap
	var front := PackedInt32Array()
	var back := PackedInt32Array()
	front.resize(n)
	back.resize(n)
	var acc := Vector3.ZERO
	var acc_n := 0
	for i in n:
		var src: int = ids[i]
		acc += inner.pos[src]
		acc_n += 1
	var mid := acc / float(maxi(acc_n, 1))
	var safe_z := back_z
	if lumbar_z > -1e8:
		safe_z = maxf(safe_z, lumbar_z + 0.008)
	var have_guts := guts_min.x < 1e8 and guts_max.x > -1e8
	if have_guts:
		# 后壁要包住脏器，但不能比后腰外皮更靠后。
		safe_z = minf(safe_z, guts_min.z - 0.003)
		if lumbar_z > -1e8:
			safe_z = maxf(safe_z, minf(guts_min.z - 0.002, lumbar_z + 0.008))
	var acc_back := Vector3.ZERO
	for i in n:
		var src: int = ids[i]
		front[i] = wrap.copy_vert(inner, src)
		var p := inner.pos[src]
		# 后盖向腹中心收，下缘额外收得更紧，减轻后腰穿模。
		var shrink := 0.38
		if have_guts and p.y < mid.y:
			var tlow := clampf((mid.y - p.y) / maxf(mid.y - (guts_min.y - 0.02), 0.04), 0.0, 1.0)
			shrink += 0.22 * tlow
		var bp := Vector3(
			lerpf(p.x, mid.x, shrink),
			lerpf(p.y, mid.y, shrink * 0.85),
			safe_z
		)
		if have_guts:
			bp.x = clampf(bp.x, guts_min.x - 0.010, guts_max.x + 0.010)
			# 允许略低于脏器底，但不落到腰椎外皮那么低。
			var y_floor := guts_min.y - 0.010
			bp.y = clampf(bp.y, y_floor, guts_max.y + 0.012)
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		for k in 4:
			b[k] = inner.bones[src * 4 + k]
			w[k] = inner.weights[src * 4 + k]
		back[i] = wrap.add_vert(bp, Vector3(0, 0, -1), inner.uv[src], b, w)
		acc_back += bp
	loft_wall(wrap, front, back, true)
	# 后盖中心必须是均值。0.3.5 改写后盖时丢掉了「acc /= n」，
	# 中心变成所有后盖顶点之和（约 28 倍），腹腔袋被拉到天上。
	acc = acc_back / float(n)
	var bones0 := PackedInt32Array()
	var weights0 := PackedFloat32Array()
	bones0.resize(4)
	weights0.resize(4)
	for k2 in 4:
		bones0[k2] = wrap.bones[back[0] * 4 + k2]
		weights0[k2] = wrap.weights[back[0] * 4 + k2]
	var cid := wrap.add_vert(acc, Vector3(0, 0, -1), Vector2(0.5, 0.5), bones0, weights0)
	# 后盖朝 -Z（从 +Z 看为顺时针）。
	for i2 in n:
		wrap.add_face(cid, back[(i2 + 1) % n], back[i2])
	return wrap


static func dense_loft_tris(path_count: int, closed: bool, sides: int = 2) -> int:
	## 0.3.2 及更早：左右唇各沿全部路径点 loft，每段 2 三角。
	var segs := path_count if closed else maxi(path_count - 1, 0)
	return maxi(segs, 0) * 2 * sides


static func loft_tris_for_segments(segments: int, closed: bool, sides: int = 2) -> int:
	var segs := segments if closed else maxi(segments - 1, 0)
	return maxi(segs, 0) * 2 * sides


static func wall_tri_budget() -> int:
	## 切口左右唇按 WALL_MAX_SEGMENTS  loft 的三角上限。
	return loft_tris_for_segments(WALL_MAX_SEGMENTS, true, 2)


static func bullet_wall_tri_budget() -> int:
	## 单侧弹孔柱状壁（8 边闭环）的三角上限。
	return loft_tris_for_segments(BULLET_SIDES, true, 1)


static func resample_index_loop(md: MeshData, ids: PackedInt32Array, max_seg: int) -> PackedInt32Array:
	## 按弧长均匀抽稀闭合或开放折线，保留端点；闭合环尽量不超过 max_seg 个顶点。
	var clean := PackedInt32Array()
	for i in ids.size():
		var id: int = ids[i]
		if id < 0 or id >= md.vert_count():
			continue
		if clean.size() > 0 and clean[clean.size() - 1] == id:
			continue
		if clean.size() > 0 and i == ids.size() - 1 and id == clean[0]:
			continue
		clean.append(id)
	var n := clean.size()
	if n <= 2 or max_seg < 2 or n <= max_seg:
		return clean
	var closed := n >= 3 and md.pos[clean[0]].distance_to(md.pos[clean[n - 1]]) <= PATH_CLOSE_DIST * 3.0
	# 用点到点累积长度均匀取样。
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist[0] = 0.0
	for i in range(1, n):
		dist[i] = dist[i - 1] + md.pos[clean[i]].distance_to(md.pos[clean[i - 1]])
	var total: float = dist[n - 1]
	if closed:
		total += md.pos[clean[0]].distance_to(md.pos[clean[n - 1]])
	if total < EPS:
		return clean
	var keep := maxi(3 if closed else 2, max_seg)
	var out := PackedInt32Array()
	out.append(clean[0])
	var last := 0
	for k in range(1, keep if closed else keep - 1):
		var target := total * float(k) / float(keep if closed else keep - 1)
		var j := last
		while j + 1 < n and dist[j + 1] < target:
			j += 1
		last = j
		var pick: int = clean[j]
		if out[out.size() - 1] != pick:
			out.append(pick)
	if not closed:
		if out[out.size() - 1] != clean[n - 1]:
			out.append(clean[n - 1])
	if closed and out.size() >= 3 and out[0] == out[out.size() - 1]:
		out.remove_at(out.size() - 1)
	return out if out.size() >= (3 if closed else 2) else clean


static func resample_path(path: PackedVector3Array, max_seg: int, closed: bool = false) -> PackedVector3Array:
	var n := path.size()
	if n <= 2 or max_seg < 2 or n <= max_seg:
		return path.duplicate()
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist[0] = 0.0
	for i in range(1, n):
		dist[i] = dist[i - 1] + path[i].distance_to(path[i - 1])
	var total: float = dist[n - 1]
	if closed and n >= 3:
		total += path[0].distance_to(path[n - 1])
	if total < EPS:
		return path.duplicate()
	var keep := maxi(3 if closed else 2, max_seg)
	var out := PackedVector3Array()
	out.append(path[0])
	for k in range(1, keep if closed else keep - 1):
		var target := total * float(k) / float(keep if closed else keep - 1)
		var j := 0
		while j + 1 < n and dist[j + 1] < target:
			j += 1
		var p: Vector3 = path[j]
		if j + 1 < n and dist[j + 1] > dist[j]:
			var t := clampf((target - dist[j]) / (dist[j + 1] - dist[j]), 0.0, 1.0)
			p = path[j].lerp(path[j + 1], t)
		out.append(p)
	if not closed:
		out.append(path[n - 1])
	return out


static func circle_path_on_mesh(md: MeshData, center: Vector3, axis: Vector3, radius: float, steps: int = BULLET_SIDES) -> PackedVector3Array:
	## 在网格表面生成垂直于 axis 的小圆路径，供弹孔冲压。
	var nrm := axis
	if nrm.length_squared() < EPS:
		nrm = Vector3(0, 0, 1)
	else:
		nrm = nrm.normalized()
	var t := nrm.cross(Vector3.UP)
	if t.length_squared() < 1e-8:
		t = nrm.cross(Vector3.RIGHT)
	t = t.normalized()
	var b := nrm.cross(t).normalized()
	var path := PackedVector3Array()
	var sides := maxi(steps, 5)
	for i in sides:
		var ang := TAU * float(i) / float(sides)
		var hint: Vector3 = center + (t * cos(ang) + b * sin(ang)) * radius
		path.append(_project_to_mesh(md, hint, center))
	return path


static func _project_to_mesh(md: MeshData, hint: Vector3, fallback: Vector3) -> Vector3:
	var p2 := _v2(hint)
	var best := fallback
	var best_s := 1e9
	var found := false
	for f in md.face_count():
		var a := md.pos[md.idx[f * 3]]
		var b := md.pos[md.idx[f * 3 + 1]]
		var c := md.pos[md.idx[f * 3 + 2]]
		var bary := _bary_2d(p2, _v2(a), _v2(b), _v2(c))
		if bary.x >= -1e-3 and bary.y >= -1e-3 and bary.z >= -1e-3:
			var got: Vector3 = a * bary.x + b * bary.y + c * bary.z
			var s := got.distance_squared_to(hint)
			if s < best_s:
				best_s = s
				best = got
				found = true
	if found:
		return best
	for j in md.vert_count():
		var s2 := md.pos[j].distance_squared_to(hint)
		if s2 < best_s:
			best_s = s2
			best = md.pos[j]
	return best


static func skin_basis(vi: int, md: MeshData, skel: Skeleton3D, skin: Skin) -> Basis:
	if skel == null or skin == null or md.bones.is_empty() or vi < 0 or vi >= md.vert_count():
		return Basis.IDENTITY
	var acc := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var tw := 0.0
	for k in 4:
		var w: float = md.weights[vi * 4 + k]
		if w <= 0.0:
			continue
		var bind_i: int = md.bones[vi * 4 + k]
		var rec: Dictionary = resolve_skin_bind(skin, skel, bind_i)
		var bone_i: int = int(rec["bone"])
		if bone_i < 0 or bone_i >= skel.get_bone_count():
			continue
		var xform := skel.get_bone_global_pose(bone_i) * (rec["pose"] as Transform3D)
		acc.x += xform.basis.x * w
		acc.y += xform.basis.y * w
		acc.z += xform.basis.z * w
		tw += w
	if tw <= EPS:
		return Basis.IDENTITY
	acc.x /= tw
	acc.y /= tw
	acc.z /= tw
	return acc


static func world_dir_to_bind(world_dir: Vector3, vi: int, md: MeshData, skel: Skeleton3D, skin: Skin) -> Vector3:
	var b := skin_basis(vi, md, skel, skin)
	var wb: Basis = skel.global_transform.basis * b if skel else b
	var d := wb.inverse() * world_dir
	if d.length_squared() < EPS:
		return Vector3(0, 0, -1)
	return d.normalized()


static func evert_open_lips(md: MeshData, left: PackedInt32Array, right: PackedInt32Array, amount: float, roll: float = 0.008) -> void:
	## 把开放切口左右唇向外卷起，amount=1 为完全外翻。在副本上调用以做 blend。
	var n := mini(left.size(), right.size())
	if n < 2 or amount <= 0.0:
		return
	var R0 := maxf(roll, 0.003)
	for i in n:
		if i == 0 or i == n - 1:
			continue
		var li: int = left[i]
		var ri: int = right[i]
		if li < 0 or ri < 0 or li >= md.vert_count() or ri >= md.vert_count():
			continue
		# 直线切口：中间外翻更明显，靠近两端更轻。
		var u := float(i) / float(maxi(n - 1, 1))
		var falloff := sin(PI * u)
		falloff = 0.16 + 0.84 * falloff
		var mid: Vector3 = (md.pos[li] + md.pos[ri]) * 0.5
		var tang: Vector3 = md.pos[left[mini(i + 1, n - 1)]] - md.pos[left[maxi(i - 1, 0)]]
		if tang.length_squared() < EPS:
			tang = Vector3.RIGHT
		else:
			tang = tang.normalized()
		var ang := amount * 1.15 * falloff
		var R := R0 * (0.35 + 0.65 * falloff)
		_evert_one(md, li, mid, tang, ang, R)
		_evert_one(md, ri, mid, tang, ang, R)
	# 邻近顶点轻微跟随，让皮肉有弹性过渡。
	_evert_neighborhood(md, left, right, amount, R0 * 2.2)


static func evert_loop_lips(md: MeshData, left: PackedInt32Array, right: PackedInt32Array, amount: float, roll: float = 0.008) -> void:
	var n := mini(left.size(), right.size())
	if n < 3 or amount <= 0.0:
		return
	var R := maxf(roll, 0.003)
	var ang := amount * 1.15
	var nn := n
	if left[0] >= 0 and left[0] < md.vert_count() and left[n - 1] >= 0 and left[n - 1] < md.vert_count():
		if left[0] == left[n - 1] or md.pos[left[0]].distance_to(md.pos[left[n - 1]]) < PATH_CLOSE_DIST:
			nn = n - 1 if n > 3 else n
	for i in nn:
		var li: int = left[i]
		var ri: int = right[i]
		if li < 0 or ri < 0 or li >= md.vert_count() or ri >= md.vert_count():
			continue
		var mid: Vector3 = (md.pos[li] + md.pos[ri]) * 0.5
		var i0 := (i - 1 + nn) % nn
		var i1 := (i + 1) % nn
		if left[i0] < 0 or left[i0] >= md.vert_count() or left[i1] < 0 or left[i1] >= md.vert_count():
			continue
		var tang: Vector3 = md.pos[left[i1]] - md.pos[left[i0]]
		if tang.length_squared() < EPS:
			tang = Vector3.RIGHT
		else:
			tang = tang.normalized()
		_evert_one(md, li, mid, tang, ang, R)
		_evert_one(md, ri, mid, tang, ang, R)
	_evert_neighborhood(md, left, right, amount, R * 2.2)


static func evert_hole_rim(md: MeshData, loop: PackedInt32Array, amount: float, roll: float = 0.006) -> void:
	## 弹孔边缘轻微外翻，露出柱状内壁。
	var ids := PackedInt32Array()
	for i in loop.size():
		var id: int = loop[i]
		if id < 0 or id >= md.vert_count():
			continue
		if ids.size() > 0 and ids[ids.size() - 1] == id:
			continue
		if ids.size() > 0 and i == loop.size() - 1 and id == ids[0]:
			continue
		ids.append(id)
	var n := ids.size()
	if n < 3 or amount <= 0.0:
		return
	var acc := Vector3.ZERO
	for i in n:
		acc += md.pos[ids[i]]
	acc /= float(n)
	var R := maxf(roll, 0.003)
	var ang := amount * 0.95
	for i in n:
		var id: int = ids[i]
		var tang: Vector3 = md.pos[ids[(i + 1) % n]] - md.pos[ids[(i - 1 + n) % n]]
		if tang.length_squared() < EPS:
			tang = Vector3.RIGHT
		else:
			tang = tang.normalized()
		_evert_one(md, id, acc, tang, ang, R)


static func _evert_one(md: MeshData, vi: int, mid: Vector3, tang: Vector3, ang: float, roll: float) -> void:
	var p: Vector3 = md.pos[vi]
	var outward: Vector3 = p - mid
	if outward.length_squared() < 1e-10:
		outward = Vector3.RIGHT
	else:
		outward = outward.normalized()
	var nrm: Vector3 = md.nrm[vi]
	if nrm.length_squared() < EPS:
		nrm = tang.cross(outward)
		if nrm.length_squared() < EPS:
			nrm = Vector3(0, 0, 1)
		else:
			nrm = nrm.normalized()
	# 绕切向向外卷：既离开裂口，又把切面内壁翻向外侧。
	var sa := sin(ang)
	var ca := 1.0 - cos(ang)
	md.pos[vi] = p + outward * (roll * sa + 0.004 * ang) + nrm * (roll * ca * 0.35)
	var nn := (nrm * cos(ang) + outward * sin(ang))
	if nn.length_squared() > EPS:
		md.nrm[vi] = nn.normalized()


static func _evert_neighborhood(md: MeshData, left: PackedInt32Array, right: PackedInt32Array, amount: float, radius: float) -> void:
	if radius < 0.001 or amount <= 0.0:
		return
	var used: Dictionary = {}
	for id in left:
		used[id] = true
	for id2 in right:
		used[id2] = true
	var anchors: Array = []
	var n := mini(left.size(), right.size())
	for i in n:
		var li: int = left[i]
		var ri: int = right[i]
		if li >= 0 and li < md.vert_count() and ri >= 0 and ri < md.vert_count():
			var mid: Vector3 = (md.pos[li] + md.pos[ri]) * 0.5
			var side: Vector3 = md.pos[li] - mid
			anchors.append([mid, side])
	var r2 := radius * radius
	for vi in md.vert_count():
		if used.has(vi):
			continue
		var p: Vector3 = md.pos[vi]
		var best_s := r2
		var best_mid: Vector3 = p
		var best_side: Vector3 = Vector3.ZERO
		for a in anchors:
			var s: float = p.distance_squared_to(a[0])
			if s < best_s:
				best_s = s
				best_mid = a[0]
				best_side = a[1]
		if best_s >= r2:
			continue
		var fall := 1.0 - sqrt(best_s) / radius
		fall = fall * fall * amount * 0.55
		var side: Vector3 = best_side
		if side.length_squared() > EPS:
			side = side.normalized()
			# 按点在中线哪一侧决定外翻方向。
			if (p - best_mid).dot(side) < 0.0:
				side = -side
			md.pos[vi] = p + side * (0.005 * fall) + md.nrm[vi] * (0.002 * fall)
