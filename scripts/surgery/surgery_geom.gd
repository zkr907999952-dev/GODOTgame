extends RefCounted
## 手术腹网格：从蒂法上半身 Dress 取出腹部、生成腹腔内壁，
## 并按手绘路径在绑定空间做曲面切割与层状腹壁截面。
## 不用平面切片、CSG，也不用旧贴图伤口。
class_name SurgeryGeom

const DEFAULT_THICKNESS := 0.012
const EPS := 1e-6
const PATH_CLOSE_DIST := 0.008
## 0.3.9：嵌入切口时的吸附（米）。离已有顶点/边太近就吸附，避免碎三角。
const SNAP_DIST := 0.0012
const EDGE_SNAP_BARY := 0.12
const EDGE_SPLIT_SNAP := 0.18
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
	## 0.3.9：外翻目标位移（rest + dsp = 外翻后），随顶点复制/插值一起走，截面拷贝顶点时自动继承。
	var dsp: PackedVector3Array = PackedVector3Array()
	## 0.3.9：腹腔内壁孪生网格（同顶点序、反绕序）。拓扑操作对 twin 做同样的插值，保证 1:1。
	var twin: MeshData = null

	func vert_count() -> int:
		return pos.size()

	func face_count() -> int:
		return idx.size() / 3

	func add_vert(p: Vector3, n: Vector3, t: Vector2, b: PackedInt32Array, w: PackedFloat32Array) -> int:
		var i := pos.size()
		if dsp.size() < i:
			dsp.resize(i)
		pos.append(p)
		nrm.append(n)
		uv.append(t)
		dsp.append(Vector3.ZERO)
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
		var ni := add_vert(src.pos[si], src.nrm[si], src.uv[si], b, w)
		if si < src.dsp.size():
			dsp[ni] = src.dsp[si]
		if src == self and twin != null and si < twin.vert_count():
			twin.copy_vert(twin, si)
		return ni

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
		var ni := add_vert(p, n, tex, b, w)
		if ia < dsp.size() and ib < dsp.size():
			dsp[ni] = dsp[ia].lerp(dsp[ib], t)
		if twin != null and ia < twin.vert_count() and ib < twin.vert_count():
			twin.lerp_vert(ia, ib, t)
		return ni

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
		m.dsp = dsp.duplicate()
		if m.dsp.size() != m.pos.size():
			m.dsp.resize(m.pos.size())
		return m

	func ensure_dsp() -> void:
		if dsp.size() != pos.size():
			dsp.resize(pos.size())

	func has_dsp() -> bool:
		for d in dsp:
			if d.length_squared() > 1e-12:
				return true
		return false

	func bake_dsp(amount: float = 1.0) -> void:
		## 把外翻位移并入 rest（下一刀从已外翻的形状继续），并清零。
		ensure_dsp()
		for i in pos.size():
			if dsp[i].length_squared() > 0.0:
				pos[i] += dsp[i] * amount
		dsp = PackedVector3Array()
		dsp.resize(pos.size())

	func with_dsp() -> MeshData:
		var m := clone()
		for i in m.pos.size():
			m.pos[i] += m.dsp[i]
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


## 0.4.04：把手术腹网（外皮 → 内壁由它 1:1 生成）里肚脐凹窝压平成与周围腹壁一致的光滑曲面。
## 凹窝是 6~7mm 深的陡壁小坑，XY 投影里坑壁三角互相重叠，切线嵌入 / 拆分在这里会出错面、粘连。
## 做法：按位置焊接顶点组；r < r_in 的组在 XY 上做 Tutte 松弛（边界环固定，保证不翻面），
## Z 取周围 r_fit0..r_fit1 环带拟合的二次曲面；r_in..r_out 过渡带只混合 Z。最后重算这些顶点的法线。
## 返回被移动的顶点数。肚脐贴图保留（只是不再有凹陷）。
static func flatten_navel(md: MeshData, navel: Vector3, r_in: float = 0.018, r_out: float = 0.024, r_fit0: float = 0.024, r_fit1: float = 0.04) -> int:
	var nv := md.vert_count()
	if nv == 0 or navel.x > 1e8:
		return 0
	var key_of: Dictionary = {}
	var grp := PackedInt32Array()
	grp.resize(nv)
	var gpos: Array[Vector3] = []
	for i in nv:
		var p: Vector3 = md.pos[i]
		var k := Vector3i(roundi(p.x * 1e6), roundi(p.y * 1e6), roundi(p.z * 1e6))
		if key_of.has(k):
			grp[i] = int(key_of[k])
		else:
			key_of[k] = gpos.size()
			grp[i] = gpos.size()
			gpos.append(p)
	var ng := gpos.size()
	var nb: Array = []
	nb.resize(ng)
	for g in ng:
		nb[g] = {}
	for f in md.face_count():
		var a := grp[md.idx[f * 3]]
		var b := grp[md.idx[f * 3 + 1]]
		var c := grp[md.idx[f * 3 + 2]]
		(nb[a] as Dictionary)[b] = true
		(nb[a] as Dictionary)[c] = true
		(nb[b] as Dictionary)[a] = true
		(nb[b] as Dictionary)[c] = true
		(nb[c] as Dictionary)[a] = true
		(nb[c] as Dictionary)[b] = true
	var rr := PackedFloat32Array()
	rr.resize(ng)
	for g2 in ng:
		rr[g2] = Vector2(gpos[g2].x - navel.x, gpos[g2].y - navel.y).length()
	# 二次曲面拟合 z = c0 + c1 x + c2 y + c3 x² + c4 xy + c5 y²（相对肚脐）
	var ata: Array = []
	for r0 in 6:
		var row := PackedFloat64Array()
		row.resize(7)
		ata.append(row)
	var cnt := 0
	for g3 in ng:
		if rr[g3] < r_fit0 or rr[g3] > r_fit1:
			continue
		var x := gpos[g3].x - navel.x
		var y := gpos[g3].y - navel.y
		var phi := [1.0, x, y, x * x, x * y, y * y]
		for r1 in 6:
			var row1: PackedFloat64Array = ata[r1]
			for c1 in 6:
				row1[c1] += phi[r1] * phi[c1]
			row1[6] += phi[r1] * (gpos[g3].z - navel.z)
			ata[r1] = row1
		cnt += 1
	if cnt < 8:
		return 0
	# 高斯消元（带一点正则，避免二次项病态）
	for d in 6:
		var rowd: PackedFloat64Array = ata[d]
		rowd[d] += 1e-9
		ata[d] = rowd
	for col in 6:
		var piv := col
		for r2 in range(col + 1, 6):
			if absf((ata[r2] as PackedFloat64Array)[col]) > absf((ata[piv] as PackedFloat64Array)[col]):
				piv = r2
		var tmp = ata[col]
		ata[col] = ata[piv]
		ata[piv] = tmp
		var pr: PackedFloat64Array = ata[col]
		if absf(pr[col]) < 1e-18:
			return 0
		for r3 in 6:
			if r3 == col:
				continue
			var rw: PackedFloat64Array = ata[r3]
			var fct := rw[col] / pr[col]
			if fct == 0.0:
				continue
			for c2 in range(col, 7):
				rw[c2] -= fct * pr[c2]
			ata[r3] = rw
	var co := PackedFloat64Array()
	co.resize(6)
	for r4 in 6:
		var rw2: PackedFloat64Array = ata[r4]
		co[r4] = rw2[6] / rw2[r4]
	var fit := func(x: float, y: float) -> float:
		return navel.z + co[0] + co[1] * x + co[2] * y + co[3] * x * x + co[4] * x * y + co[5] * y * y
	# Tutte 松弛（XY）
	var inside := PackedByteArray()
	inside.resize(ng)
	var ins: PackedInt32Array = PackedInt32Array()
	for g4 in ng:
		if rr[g4] < r_in:
			inside[g4] = 1
			ins.append(g4)
	var xy: Array[Vector2] = []
	xy.resize(ng)
	for g5 in ng:
		xy[g5] = Vector2(gpos[g5].x, gpos[g5].y)
	navel_flips = 0
	navel_retri = 0
	for _it in 400:
		for g6 in ins:
			var acc := Vector2.ZERO
			var m := 0
			for h in (nb[g6] as Dictionary):
				acc += xy[int(h)]
				m += 1
			if m > 0:
				xy[g6] = acc / float(m)
	for i5 in nv:
		var gg := grp[i5]
		if inside[gg] == 1:
			md.pos[i5] = Vector3(xy[gg].x, xy[gg].y, float(fit.call(xy[gg].x - navel.x, xy[gg].y - navel.y)))
	var touched := {}
	for g7 in ng:
		if inside[g7] == 1:
			gpos[g7] = Vector3(xy[g7].x, xy[g7].y, float(fit.call(xy[g7].x - navel.x, xy[g7].y - navel.y)))
			touched[g7] = true
		elif rr[g7] < r_out:
			var t := smoothstep(r_in, r_out, rr[g7])
			var zf := float(fit.call(gpos[g7].x - navel.x, gpos[g7].y - navel.y))
			# 过渡带只允许往外抬（填坑），不往里压
			var zn := lerpf(maxf(zf, gpos[g7].z), gpos[g7].z, t)
			if absf(zn - gpos[g7].z) > 1e-7:
				gpos[g7] = Vector3(gpos[g7].x, gpos[g7].y, zn)
				touched[g7] = true
	var moved := 0
	for i2 in nv:
		if touched.has(grp[i2]):
			md.pos[i2] = gpos[grp[i2]]
			moved += 1
	# 重算法线（只算受影响的组及其一圈邻居）
	var gn: Array[Vector3] = []
	gn.resize(ng)
	for g8 in ng:
		gn[g8] = Vector3.ZERO
	for f2 in md.face_count():
		var ia := md.idx[f2 * 3]
		var ib := md.idx[f2 * 3 + 1]
		var ic := md.idx[f2 * 3 + 2]
		var ga := grp[ia]
		var gb := grp[ib]
		var gc := grp[ic]
		if not (touched.has(ga) or touched.has(gb) or touched.has(gc)):
			continue
		var fnv := (md.pos[ib] - md.pos[ia]).cross(md.pos[ic] - md.pos[ia])
		gn[ga] += fnv
		gn[gb] += fnv
		gn[gc] += fnv
	for i3 in nv:
		var g9 := grp[i3]
		if gn[g9].length_squared() > 1e-20 and (touched.has(g9) or rr[g9] < r_out + 0.004):
			var nn := gn[g9].normalized()
			if nn.dot(md.nrm[i3]) < 0.0 and rr[g9] >= r_out:
				nn = -nn
			if nn.z < 0.0:
				nn = -nn
			md.nrm[i3] = nn
	# 松弛后的连接仍是原来坑里一圈圈的细长三角：把压平区域按周围腹壁的网格密度重新三角化（规则六边形点阵 + Delaunay）。
	navel_retri = _retriangulate_disk(md, navel, r_in, fit)
	if navel_retri == 0:
		navel_flips = _delaunay_flip_xy(md, navel, r_in)
	return moved


static var navel_flips: int = 0
static var navel_retri: int = 0


## 压平区域重新三角化：取 r < r_in 的面，边界环保持不动（与外圈共享），内部换成间距 h 的六边形点阵，
## Godot 的 Delaunay 三角化后只保留环内三角。新顶点的 UV / 骨骼权重按松弛后旧三角的重心插值。
## 返回新三角数，失败返回 0（不改动网格）。
static func _retriangulate_disk(md: MeshData, c: Vector3, r_in: float, fit: Callable) -> int:
	var inside_f := PackedInt32Array()
	var keep := PackedInt32Array()
	for f in md.face_count():
		var all_in := true
		for k in 3:
			var p := md.pos[md.idx[f * 3 + k]]
			if Vector2(p.x - c.x, p.y - c.y).length() >= r_in:
				all_in = false
		if all_in:
			inside_f.append(f)
		else:
			keep.append(f)
	if inside_f.size() < 8:
		return 0
	# 边界有向边（只出现一次）
	var ecount: Dictionary = {}
	for f2 in inside_f:
		for k2 in 3:
			var a := md.idx[f2 * 3 + k2]
			var b := md.idx[f2 * 3 + (k2 + 1) % 3]
			ecount[Vector2i(a, b)] = true
	var nxt: Dictionary = {}
	for e in ecount:
		var ev := e as Vector2i
		if not ecount.has(Vector2i(ev.y, ev.x)):
			if nxt.has(ev.x):
				return 0
			nxt[ev.x] = ev.y
	if nxt.size() < 6:
		return 0
	var loop := PackedInt32Array()
	var start: int = nxt.keys()[0]
	var cur := start
	for _g in nxt.size() + 1:
		loop.append(cur)
		cur = int(nxt.get(cur, -1))
		if cur < 0:
			return 0
		if cur == start:
			break
	if loop.size() != nxt.size():
		return 0  # 多个环（中间有 UV 缝等），放弃
	var poly := PackedVector2Array()
	var per := 0.0
	for li in loop.size():
		var p2 := md.pos[loop[li]]
		poly.append(Vector2(p2.x, p2.y))
		per += p2.distance_to(md.pos[loop[(li + 1) % loop.size()]])
	var h := clampf(per / float(loop.size()), 0.0018, 0.0035)
	# 点阵
	var pts := poly.duplicate()
	var lo := poly[0]
	var hi := poly[0]
	for q in poly:
		lo = lo.min(q)
		hi = hi.max(q)
	var row := 0
	var y := lo.y
	while y <= hi.y:
		var x := lo.x + (h * 0.5 if row % 2 == 1 else 0.0)
		while x <= hi.x:
			var q2 := Vector2(x, y)
			if Geometry2D.is_point_in_polygon(q2, poly):
				var dmin := 1e9
				for li2 in poly.size():
					var sa := poly[li2]
					var sb := poly[(li2 + 1) % poly.size()]
					dmin = minf(dmin, q2.distance_to(Geometry2D.get_closest_point_to_segment(q2, sa, sb)))
				if dmin > h * 0.55:
					pts.append(q2)
			x += h
		y += h * 0.8660254
		row += 1
	var tri := Geometry2D.triangulate_delaunay(pts)
	if tri.is_empty():
		return 0
	var nl := loop.size()
	# 原来的绕向（XY 叉积符号）
	var f0 := inside_f[0]
	var s0 := signf(_xy_cross(md.pos[md.idx[f0 * 3]], md.pos[md.idx[f0 * 3 + 1]], md.pos[md.idx[f0 * 3 + 2]]))
	var new_tris: Array = []
	var have_e: Dictionary = {}
	for t in range(0, tri.size(), 3):
		var ia := tri[t]
		var ib := tri[t + 1]
		var ic := tri[t + 2]
		var cen := (pts[ia] + pts[ib] + pts[ic]) / 3.0
		if not Geometry2D.is_point_in_polygon(cen, poly):
			continue
		var cr := (pts[ib].x - pts[ia].x) * (pts[ic].y - pts[ia].y) - (pts[ib].y - pts[ia].y) * (pts[ic].x - pts[ia].x)
		if absf(cr) < 1e-12:
			continue
		if signf(cr) != s0:
			var tmp := ib
			ib = ic
			ic = tmp
		new_tris.append([ia, ib, ic])
		have_e[Vector2i(ia, ib)] = true
		have_e[Vector2i(ib, ic)] = true
		have_e[Vector2i(ic, ia)] = true
	# 每条边界边都必须出现（方向与原环一致），否则会裂缝
	for li3 in nl:
		if not have_e.has(Vector2i(li3, (li3 + 1) % nl)):
			return 0
	# 新顶点属性：在松弛后的旧三角里找重心坐标插值
	var map := PackedInt32Array()
	map.resize(pts.size())
	for li4 in nl:
		map[li4] = loop[li4]
	for pi in range(nl, pts.size()):
		var q3 := pts[pi]
		var best_f := -1
		var best_b := Vector3.ZERO
		var best_err := 1e9
		for f3 in inside_f:
			var A := md.pos[md.idx[f3 * 3]]
			var B := md.pos[md.idx[f3 * 3 + 1]]
			var C := md.pos[md.idx[f3 * 3 + 2]]
			var bc := _bary_2d(q3, Vector2(A.x, A.y), Vector2(B.x, B.y), Vector2(C.x, C.y))
			var err := maxf(maxf(-bc.x, -bc.y), -bc.z)
			if err < best_err:
				best_err = err
				best_f = f3
				best_b = bc
			if err <= 0.0:
				break
		var bb := best_b.clamp(Vector3.ZERO, Vector3.ONE)
		var sm := bb.x + bb.y + bb.z
		bb = bb / sm if sm > 1e-9 else Vector3(1, 0, 0)
		var va := md.idx[best_f * 3]
		var vb := md.idx[best_f * 3 + 1]
		var vc := md.idx[best_f * 3 + 2]
		var dom := va
		if bb.y > bb.x and bb.y >= bb.z:
			dom = vb
		elif bb.z > bb.x and bb.z > bb.y:
			dom = vc
		var uvn := md.uv[va] * bb.x + md.uv[vb] * bb.y + md.uv[vc] * bb.z
		var bo := PackedInt32Array()
		var we := PackedFloat32Array()
		bo.resize(4)
		we.resize(4)
		for k3 in 4:
			bo[k3] = md.bones[dom * 4 + k3]
			we[k3] = md.weights[dom * 4 + k3]
		var zz := float(fit.call(q3.x - c.x, q3.y - c.y))
		map[pi] = md.add_vert(Vector3(q3.x, q3.y, zz), md.nrm[dom], uvn, bo, we)
	var idx2 := PackedInt32Array()
	for f4 in keep:
		idx2.append(md.idx[f4 * 3])
		idx2.append(md.idx[f4 * 3 + 1])
		idx2.append(md.idx[f4 * 3 + 2])
	for t2 in new_tris:
		idx2.append(map[t2[0]])
		idx2.append(map[t2[1]])
		idx2.append(map[t2[2]])
	md.idx = idx2
	_compact_unused(md)
	# 法线：新区域及边界一圈按面法线重算（朝 +Z 外侧）
	var acc_n: Dictionary = {}
	for f5 in md.face_count():
		var a5 := md.idx[f5 * 3]
		var b5 := md.idx[f5 * 3 + 1]
		var c5 := md.idx[f5 * 3 + 2]
		var pa5 := md.pos[a5]
		if Vector2(pa5.x - c.x, pa5.y - c.y).length() > r_in + 0.004:
			continue
		var fn := (md.pos[b5] - pa5).cross(md.pos[c5] - pa5)
		for v5 in [a5, b5, c5]:
			acc_n[v5] = (acc_n.get(v5, Vector3.ZERO) as Vector3) + fn
	for v6 in acc_n:
		var nn: Vector3 = (acc_n[v6] as Vector3)
		if nn.length_squared() > 1e-20:
			nn = nn.normalized()
			if nn.z < 0.0:
				nn = -nn
			var pv := md.pos[int(v6)]
			if Vector2(pv.x - c.x, pv.y - c.y).length() < r_in - 1e-5:
				md.nrm[int(v6)] = nn
	return new_tris.size()


## 删除没有被任何三角引用的顶点（重排索引）。只在烘焙时、还没有 twin / dsp 内容时调用。
static func _compact_unused(md: MeshData) -> void:
	var used := PackedByteArray()
	used.resize(md.vert_count())
	for i in md.idx:
		used[i] = 1
	var remap := PackedInt32Array()
	remap.resize(md.vert_count())
	var m := MeshData.new()
	for v in md.vert_count():
		if used[v] == 1:
			remap[v] = m.copy_vert(md, v)
		else:
			remap[v] = -1
	for k in md.idx.size():
		m.idx.append(remap[md.idx[k]])
	md.pos = m.pos
	md.nrm = m.nrm
	md.uv = m.uv
	md.bones = m.bones
	md.weights = m.weights
	md.dsp = m.dsp
	md.idx = m.idx


static func _xy_angle(p: Vector3, a: Vector3, b: Vector3) -> float:
	var u := Vector2(a.x - p.x, a.y - p.y)
	var v := Vector2(b.x - p.x, b.y - p.y)
	return absf(u.angle_to(v))


static func _xy_cross(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


static func _delaunay_flip_xy(md: MeshData, c: Vector3, r: float) -> int:
	var flips := 0
	var in_r := func(f: int) -> bool:
		for k in 3:
			var p := md.pos[md.idx[f * 3 + k]]
			if Vector2(p.x - c.x, p.y - c.y).length() > r:
				return false
		return true
	var faces := PackedInt32Array()
	for f in md.face_count():
		if in_r.call(f):
			faces.append(f)
	for _sweep in 30:
		var emap: Dictionary = {}
		for f2 in faces:
			for k2 in 3:
				emap[Vector2i(md.idx[f2 * 3 + k2], md.idx[f2 * 3 + (k2 + 1) % 3])] = f2
		var changed := 0
		var done: Dictionary = {}
		for f3 in faces:
			if done.has(f3):
				continue
			for k3 in 3:
				var a := md.idx[f3 * 3 + k3]
				var b := md.idx[f3 * 3 + (k3 + 1) % 3]
				var cc := md.idx[f3 * 3 + (k3 + 2) % 3]
				var key := Vector2i(b, a)
				if not emap.has(key):
					continue
				var g: int = emap[key]
				if done.has(g) or g == f3:
					continue
				var d := -1
				for k4 in 3:
					var v := md.idx[g * 3 + k4]
					if v != a and v != b:
						d = v
				if d < 0 or d == cc:
					continue
				var pa := md.pos[a]
				var pb := md.pos[b]
				var pc := md.pos[cc]
				var pd := md.pos[d]
				if _xy_angle(pc, pa, pb) + _xy_angle(pd, pa, pb) <= PI + 1e-4:
					continue
				var s0 := signf(_xy_cross(pa, pb, pc))
				if signf(_xy_cross(pc, pa, pd)) != s0 or signf(_xy_cross(pd, pb, pc)) != s0:
					continue
				if emap.has(Vector2i(cc, d)) or emap.has(Vector2i(d, cc)):
					continue
				md.idx[f3 * 3] = cc
				md.idx[f3 * 3 + 1] = a
				md.idx[f3 * 3 + 2] = d
				md.idx[g * 3] = d
				md.idx[g * 3 + 1] = b
				md.idx[g * 3 + 2] = cc
				done[f3] = true
				done[g] = true
				changed += 1
				break
		flips += changed
		if changed == 0:
			break
	return flips


static func make_cavity(outer: MeshData, thickness: float, organ_front_z: float = -1e9, navel: Vector3 = Vector3.INF) -> MeshData:
	var inner := MeshData.new()
	var th := maxf(thickness, 0.004)
	var has_nav := navel.x < 1e8
	for i in outer.vert_count():
		var n: Vector3 = outer.nrm[i]
		if n.length_squared() < EPS:
			n = Vector3.FORWARD
		else:
			n = n.normalized()
		var thv := th
		if has_nav:
			# 0.3.9：小腹下缘（腹股沟折痕附近）躺下屈髋时皮肤会内收，内壁在这里贴近外皮，免得从折痕穿出。
			var ry := outer.pos[i].y - navel.y
			thv = th * lerpf(1.0, LOWER_INNER_FRAC, smoothstep(LOWER_TAPER_Y0, LOWER_TAPER_Y1, -ry))
		var p: Vector3 = outer.pos[i] - n * thv
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
	## p3_hint 只用来挑面/挑近点，从不直接写入顶点：防止世界坐标误当绑定坐标把腹网拉到天上。
	var has_hint := p3_hint.x < 1e8
	var best_i := -1
	var best_d := SNAP_DIST * SNAP_DIST
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
	# 0.3.9：落点就是曲面上的重心插值（不再用 1.2cm 内的提示点替换，那会把顶点拉离曲面形成毛刺）。
	# 太靠近已有顶点 → 复用；太靠近某条边 → 改为拆这条边，避免 1 拆 3 产生细长三角。
	var tri_i := [fa, fb, fc]
	var bb := [bary.x, bary.y, bary.z]
	var p := md.pos[fa] * bary.x + md.pos[fb] * bary.y + md.pos[fc] * bary.z
	# 0.4.02：吸附半径随局部网格密度缩小（肚脐一带三角边只有 ~1mm，固定 1.2mm 吸附会让切线左右跳成锯齿、唇缘交错粘连）。
	var emin := minf(md.pos[fa].distance_to(md.pos[fb]), minf(md.pos[fb].distance_to(md.pos[fc]), md.pos[fc].distance_to(md.pos[fa])))
	var snap_r := minf(SNAP_DIST, emin * 0.3)
	for k in 3:
		if md.pos[tri_i[k]].distance_to(p) < snap_r:
			return tri_i[k]
	var kmin := 0
	for k in 3:
		if bb[k] < bb[kmin]:
			kmin = k
	if bb[kmin] < EDGE_SNAP_BARY:
		var e0: int = tri_i[(kmin + 1) % 3]
		var e1: int = tri_i[(kmin + 2) % 3]
		var w0: float = bb[(kmin + 1) % 3]
		var w1: float = bb[(kmin + 2) % 3]
		var te := w1 / maxf(w0 + w1, EPS)
		return _split_edge_at(md, e0, e1, te)
	var ni := _bary_vert(md, fa, fb, fc, bary)
	if md.twin != null and fa < md.twin.vert_count() and fb < md.twin.vert_count() and fc < md.twin.vert_count():
		_bary_vert(md.twin, fa, fb, fc, bary)
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


static func _bary_vert(md: MeshData, fa: int, fb: int, fc: int, bary: Vector3) -> int:
	var p := md.pos[fa] * bary.x + md.pos[fb] * bary.y + md.pos[fc] * bary.z
	var n := (md.nrm[fa] * bary.x + md.nrm[fb] * bary.y + md.nrm[fc] * bary.z)
	if n.length_squared() > EPS:
		n = n.normalized()
	var tex := md.uv[fa] * bary.x + md.uv[fb] * bary.y + md.uv[fc] * bary.z
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
	md.ensure_dsp()
	if fa < md.dsp.size() and fb < md.dsp.size() and fc < md.dsp.size():
		md.dsp[ni] = md.dsp[fa] * bary.x + md.dsp[fb] * bary.y + md.dsp[fc] * bary.z
	return ni


static func sync_twin_faces(md: MeshData) -> void:
	## 内壁 = 外皮同拓扑、反绕序。
	if md == null or md.twin == null:
		return
	var tw := md.twin
	if tw.vert_count() != md.vert_count():
		push_warning("surgery: twin vertex count drift %d vs %d" % [tw.vert_count(), md.vert_count()])
		return
	var ni := PackedInt32Array()
	ni.resize(md.idx.size())
	for f in md.face_count():
		ni[f * 3] = md.idx[f * 3]
		ni[f * 3 + 1] = md.idx[f * 3 + 2]
		ni[f * 3 + 2] = md.idx[f * 3 + 1]
	tw.idx = ni


static func _split_edge_at(md: MeshData, ia: int, ib: int, t: float) -> int:
	# 若端点已足够近，复用（按实际距离，避免产生针状三角）。
	var elen := md.pos[ia].distance_to(md.pos[ib])
	var snap_r := minf(SNAP_DIST, elen * 0.25)
	if t <= 0.02 or t * elen < snap_r:
		return ia
	if t >= 0.98 or (1.0 - t) * elen < snap_r:
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
		# 0.3.9：交点很靠近边端点、且端点离连线很近时直接走端点，不拆出细长三角。
		var mid := -1
		var u := clampf(best_u, 0.0, 1.0)
		var near_v := best_ia if u < 0.5 else best_ib
		var u_end := u if u < 0.5 else 1.0 - u
		if near_v != cur and u_end < EDGE_SPLIT_SNAP and not chain.has(near_v):
			var dl := _dist_point_seg_2d(_v2(md.pos[near_v]), a2, b2)
			var el := md.pos[best_ia].distance_to(md.pos[best_ib])
			if dl < minf(SNAP_DIST * 0.6, el * 0.2):
				mid = near_v
		if mid < 0:
			mid = _split_edge_at(md, best_ia, best_ib, clampf(best_u, 0.02, 0.98))
		if mid == cur:
			chain.append(ib)
			break
		chain.append(mid)
		cur = mid
	if chain[chain.size() - 1] != ib:
		chain.append(ib)
	return chain


static func _dist_point_seg_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var L2 := ab.length_squared()
	if L2 < 1e-14:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / L2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


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
	if md.twin != null and md.twin.vert_count() == md.vert_count():
		inside.twin = MeshData.new()
		outside.twin = MeshData.new()
	var _xfer := func(dest: MeshData, mp: Dictionary, si: int) -> int:
		var e := int(mp.get(si, -1))
		if e < 0:
			e = dest.copy_vert(md, si)
			if dest.twin != null:
				dest.twin.copy_vert(md.twin, si)
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
	sync_twin_faces(inside)
	sync_twin_faces(outside)
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


static func oval_path_on_mesh(md: MeshData, center: Vector3, rx: float, ry: float, steps: int = 24, grid: Dictionary = {}) -> PackedVector3Array:
	## 在腹前用绑定空间 XY 椭圆取样，再投影到网格表面，生成闭合路径。
	## 投影与 line_path_on_mesh / _project_to_mesh 相同：在覆盖该 XY 的面里取离提示点最近的一张，
	## 避免环状预览落在第一张 XY 命中面上、嵌入却贴到另一层而错位。
	var path := PackedVector3Array()
	for i in steps:
		var ang := TAU * float(i) / float(steps)
		var hint := Vector3(center.x + cos(ang) * rx, center.y + sin(ang) * ry, center.z)
		path.append(project_to_mesh_grid(md, grid, hint, hint))
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


static func line_path_on_mesh(md: MeshData, a: Vector3, b: Vector3, steps: int = 12, grid: Dictionary = {}) -> PackedVector3Array:
	var path := PackedVector3Array()
	var n := maxi(steps, 2)
	for i in n + 1:
		var t := float(i) / float(n)
		var p: Vector3 = a.lerp(b, t)
		path.append(project_to_mesh_grid(md, grid, p, p))
	return path


static func make_cavity_wrap(inner: MeshData, back_z: float, guts_min: Vector3 = Vector3.INF, guts_max: Vector3 = Vector3.INF, lumbar_z: float = -1e9, skin: MeshData = null, torso_n: int = -1, navel: Vector3 = Vector3.INF) -> MeshData:
	var has_nav := navel.x < 1e8
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
		if has_nav and skin != null:
			# 0.3.9：小腹下缘（腹股沟折痕）那段袋口往上、往里收，袋壁不再贴着折痕走（屈髋时会从折痕穿出）。
			var lowf := smoothstep(WRAP_LOW_Y0 + 0.03, WRAP_LOW_Y1, navel.y - p.y)
			if lowf > 0.0:
				var pl := p
				pl.y += WRAP_LOW_LIFT * 1.2 * lowf
				pl.x = lerpf(pl.x, mid.x, 0.15 * lowf)
				var fitf := _inset_inside_skin(skin, pl, 0.004 + 0.016 * lowf, torso_n)
				wrap.pos[front[i]] = fitf[0]
				for k3 in 4:
					wrap.bones[front[i] * 4 + k3] = (fitf[1] as PackedInt32Array)[k3]
					wrap.weights[front[i] * 4 + k3] = (fitf[2] as PackedFloat32Array)[k3]
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
		if has_nav:
			bp.y += WRAP_LOW_LIFT * smoothstep(WRAP_LOW_Y0, WRAP_LOW_Y1, navel.y - bp.y)
		if skin != null:
			# 0.3.9：后盖/后腰点必须在皮肤内侧 WRAP_INSET 以上，并用最近皮肤顶点的骨骼权重（跟随后腰蒙皮，不再沿用前壁边界权重）。
			var fit := _inset_inside_skin(skin, bp, WRAP_INSET, torso_n)
			bp = fit[0]
			b = fit[1]
			w = fit[2]
		back[i] = wrap.add_vert(bp, Vector3(0, 0, -1), inner.uv[src], b, w)
		acc_back += bp
	if skin != null:
		# 侧壁也收进皮肤内侧：两圈中间环，靠前那圈往里收得更深；小腹下缘（腹股沟折痕）再往上提，
		# 否则屈髋躺下时侧壁会从折痕/后腰侧穿出（腰侧与折痕是凹的，直连前后会戳出皮肤）。
		var prev := front
		for ring in [[0.22, WRAP_INSET + 0.010], [0.6, WRAP_INSET + 0.004]]:
			var rr := PackedInt32Array()
			rr.resize(n)
			for i3 in n:
				var pf: Vector3 = wrap.pos[front[i3]]
				var pb: Vector3 = wrap.pos[back[i3]]
				var pm := pf.lerp(pb, float(ring[0]))
				if has_nav:
					var low := smoothstep(WRAP_LOW_Y0, WRAP_LOW_Y1, navel.y - pm.y)
					pm.y += WRAP_LOW_LIFT * low
					pm.x = lerpf(pm.x, mid.x, 0.18 * low)
				var fit2 := _inset_inside_skin(skin, pm, float(ring[1]), torso_n)
				rr[i3] = wrap.add_vert(fit2[0], Vector3(0, 0, -1), wrap.uv[front[i3]], fit2[1], fit2[2])
			loft_wall(wrap, prev, rr, true)
			prev = rr
		loft_wall(wrap, prev, back, true)
	else:
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
	if skin != null:
		var fit3 := _inset_inside_skin(skin, acc, WRAP_INSET, torso_n)
		acc = fit3[0]
		bones0 = fit3[1]
		weights0 = fit3[2]
	var cid := wrap.add_vert(acc, Vector3(0, 0, -1), Vector2(0.5, 0.5), bones0, weights0)
	# 后盖朝 -Z（从 +Z 看为顺时针）。
	for i2 in n:
		wrap.add_face(cid, back[(i2 + 1) % n], back[i2])
	return wrap


const WRAP_INSET := 0.014
const WRAP_LOW_Y0 := 0.11
const WRAP_LOW_Y1 := 0.2
const WRAP_LOW_LIFT := 0.035
const LOWER_TAPER_Y0 := 0.10
const LOWER_TAPER_Y1 := 0.185
const LOWER_INNER_FRAC := 0.1


static func _inset_inside_skin(skin: MeshData, p: Vector3, inset: float, weight_n: int = -1) -> Array:
	## 取最近的几个皮肤顶点：若 p 在其切平面外侧或离皮肤不足 inset，就沿法线往里推；骨骼权重取最近点。
	var best: Array = [[1e9, -1], [1e9, -1], [1e9, -1]]
	for i in skin.vert_count():
		var d := skin.pos[i].distance_squared_to(p)
		if d < best[2][0]:
			best[2] = [d, i]
			best.sort_custom(func(x, y): return x[0] < y[0])
	var b := PackedInt32Array()
	var w := PackedFloat32Array()
	b.resize(4)
	w.resize(4)
	var i0: int = best[0][1]
	if i0 < 0:
		return [p, b, w]
	var sp := Vector3.ZERO
	var sn := Vector3.ZERO
	var cnt := 0
	for e in best:
		if int(e[1]) >= 0:
			sp += skin.pos[int(e[1])]
			sn += skin.nrm[int(e[1])]
			cnt += 1
	sp /= float(cnt)
	if sn.length_squared() > EPS:
		sn = sn.normalized()
	var q := p
	var h := (p - sp).dot(sn)
	if h > -inset:
		q = p - sn * (h + inset)
	# 骨骼权重只取躯干（Dress）部分的最近点，避免取到大腿权重、屈髋时跟着腿戳出腹股沟。
	var iw := i0
	if weight_n > 0 and i0 >= weight_n:
		var bd := 1e9
		for j in weight_n:
			var dj := skin.pos[j].distance_squared_to(q)
			if dj < bd:
				bd = dj
				iw = j
	for k in 4:
		b[k] = skin.bones[iw * 4 + k]
		w[k] = skin.weights[iw * 4 + k]
	return [q, b, w]


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


## 0.3.8 切割预览加速：绑定空间 XY 网格索引（面 + 顶点）。预览每次拖动都要把 13–25 个点投影到腹网、
## 找最近顶点，旧实现每个点遍历全部三角 / 顶点（GDScript 里几十万次运算，手机上明显卡顿）。
## 结果与暴力搜索一致：面按 XY 包围盒（外扩 1.5mm，覆盖重心容差）登记到所有覆盖的格子。
const GRID_CELL := 0.01


static func build_xy_grid(md: MeshData, cell: float = GRID_CELL) -> Dictionary:
	var faces: Dictionary = {}
	var verts: Dictionary = {}
	var pad := 0.0015
	for f in md.face_count():
		var a := md.pos[md.idx[f * 3]]
		var b := md.pos[md.idx[f * 3 + 1]]
		var c := md.pos[md.idx[f * 3 + 2]]
		var x0 := floori((minf(a.x, minf(b.x, c.x)) - pad) / cell)
		var x1 := floori((maxf(a.x, maxf(b.x, c.x)) + pad) / cell)
		var y0 := floori((minf(a.y, minf(b.y, c.y)) - pad) / cell)
		var y1 := floori((maxf(a.y, maxf(b.y, c.y)) + pad) / cell)
		for ix in range(x0, x1 + 1):
			for iy in range(y0, y1 + 1):
				var key := Vector2i(ix, iy)
				if not faces.has(key):
					faces[key] = []
				(faces[key] as Array).append(f)
	for i in md.vert_count():
		var key2 := Vector2i(floori(md.pos[i].x / cell), floori(md.pos[i].y / cell))
		if not verts.has(key2):
			verts[key2] = []
		(verts[key2] as Array).append(i)
	return {"cell": cell, "faces": faces, "verts": verts, "nf": md.face_count(), "nv": md.vert_count()}


static func grid_valid(md: MeshData, grid: Dictionary) -> bool:
	return md != null and not grid.is_empty() and int(grid.get("nf", -1)) == md.face_count() and int(grid.get("nv", -1)) == md.vert_count()


static func project_to_mesh_grid(md: MeshData, grid: Dictionary, hint: Vector3, fallback: Vector3) -> Vector3:
	if not grid_valid(md, grid):
		return _project_to_mesh(md, hint, fallback)
	var cell: float = grid["cell"]
	var list = (grid["faces"] as Dictionary).get(Vector2i(floori(hint.x / cell), floori(hint.y / cell)))
	var p2 := _v2(hint)
	var best := fallback
	var best_s := 1e9
	var found := false
	if list is Array:
		for f in list:
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
	var vi := nearest_vertex_grid(md, grid, hint)
	return md.pos[vi] if vi >= 0 else fallback


## 最近顶点（3D 距离）。按 XY 格子由近到远一圈圈搜，找到的距离不超过已搜半径就是精确解。
static func nearest_vertex_grid(md: MeshData, grid: Dictionary, p: Vector3) -> int:
	if md == null or md.vert_count() < 1:
		return -1
	if grid_valid(md, grid):
		var cell: float = grid["cell"]
		var verts: Dictionary = grid["verts"]
		var cx := floori(p.x / cell)
		var cy := floori(p.y / cell)
		var best := -1
		var best_s := 1e18
		for r in 6:
			for ix in range(cx - r, cx + r + 1):
				for iy in range(cy - r, cy + r + 1):
					if maxi(absi(ix - cx), absi(iy - cy)) != r:
						continue
					var list = verts.get(Vector2i(ix, iy))
					if not (list is Array):
						continue
					for i in list:
						var s := md.pos[i].distance_squared_to(p)
						if s < best_s:
							best_s = s
							best = i
			if best >= 0 and best_s <= (float(r) * cell) * (float(r) * cell):
				return best
	var bi := 0
	var bs := 1e18
	for j in md.vert_count():
		var s2 := md.pos[j].distance_squared_to(p)
		if s2 < bs:
			bs = s2
			bi = j
	return bi


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


## ───────────── 0.3.9：真正沿切线分开 + 平滑外翻场 ─────────────

static func split_path(md: MeshData, ids: PackedInt32Array, closed: bool, width: float) -> Dictionary:
	## 沿已嵌入的顶点链把网格真正切开：中间点（闭环为全部点）复制成左右两份，
	## 每个三角按「非切线顶点」在切线局部左右哪一侧，只引用那一侧的副本（twin 内壁同步）。
	## 左侧 = sdir 正方向，sdir = 法线 × 切向。返回 {ok, left, right, sdir}。
	var path := PackedInt32Array()
	for i in ids.size():
		var id: int = ids[i]
		if id < 0 or id >= md.vert_count():
			continue
		if path.size() > 0 and path[path.size() - 1] == id:
			continue
		path.append(id)
	if closed and path.size() >= 2 and path[0] == path[path.size() - 1]:
		path.remove_at(path.size() - 1)
	var n := path.size()
	if n < 2 or (closed and n < 3):
		return {"ok": false, "left": path, "right": path, "sdir": PackedVector3Array()}
	var P := PackedVector3Array()
	var sdir := PackedVector3Array()
	P.resize(n)
	sdir.resize(n)
	for i in n:
		P[i] = md.pos[path[i]]
	for i in n:
		var ip := (i - 1 + n) % n if closed else maxi(i - 1, 0)
		var inx := (i + 1) % n if closed else mini(i + 1, n - 1)
		var tang := P[inx] - P[ip]
		var nr: Vector3 = md.nrm[path[i]]
		if nr.length_squared() < EPS:
			nr = Vector3(0, 0, 1)
		var sd := nr.normalized().cross(tang)
		if sd.length_squared() < 1e-14:
			sd = Vector3.RIGHT
		sdir[i] = sd.normalized()
	var split_at: Dictionary = {}
	var on_path: Dictionary = {}
	for i in n:
		on_path[path[i]] = i
		if closed or (i > 0 and i < n - 1):
			split_at[path[i]] = i
	# 每个用到切点的三角判定左右。
	var face_side: Dictionary = {}
	for f in md.face_count():
		var tri := [md.idx[f * 3], md.idx[f * 3 + 1], md.idx[f * 3 + 2]]
		var k := -1
		for v in tri:
			if split_at.has(v):
				k = int(split_at[v])
				break
		if k < 0:
			continue
		var c := Vector3.ZERO
		var cnt := 0
		for v2 in tri:
			if not on_path.has(v2):
				c += md.pos[v2]
				cnt += 1
		if cnt == 0:
			c = (md.pos[tri[0]] + md.pos[tri[1]] + md.pos[tri[2]]) / 3.0
		else:
			c /= float(cnt)
		# 用离 c 最近的相邻线段判定（拐角处更稳）。
		var best_s := 0.0
		var best_d := 1e9
		var segs := []
		if closed or k > 0:
			segs.append([(k - 1 + n) % n, k])
		if closed or k < n - 1:
			segs.append([k, (k + 1) % n])
		for sg in segs:
			var a: Vector3 = P[sg[0]]
			var b: Vector3 = P[sg[1]]
			var ab := b - a
			var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-14), 0.0, 1.0)
			var q := a + ab * t
			var d := c.distance_to(q)
			var sd2: Vector3 = sdir[sg[0]].lerp(sdir[sg[1]], t)
			if d < best_d:
				best_d = d
				best_s = (c - q).dot(sd2)
		face_side[f] = 1 if best_s >= 0.0 else -1
	var left := PackedInt32Array()
	var right := PackedInt32Array()
	left.resize(n)
	right.resize(n)
	var copy_of: Dictionary = {}
	for i in n:
		var id2: int = path[i]
		left[i] = id2
		right[i] = id2
		if split_at.has(id2):
			var cp := md.copy_vert(md, id2)
			copy_of[id2] = cp
			right[i] = cp
	for f2 in face_side.keys():
		if int(face_side[f2]) >= 0:
			continue
		for kk in 3:
			var vi: int = md.idx[f2 * 3 + kk]
			if copy_of.has(vi):
				md.idx[f2 * 3 + kk] = int(copy_of[vi])
	var hw := width * 0.5
	for i in n:
		if left[i] == right[i]:
			continue
		var dv: Vector3 = sdir[i] * hw
		md.pos[left[i]] += dv
		md.pos[right[i]] -= dv
		if md.twin != null and right[i] < md.twin.vert_count():
			md.twin.pos[left[i]] += dv
			md.twin.pos[right[i]] -= dv
	sync_twin_faces(md)
	if closed:
		left.append(left[0])
		right.append(right[0])
		sdir.append(sdir[0])
	return {"ok": true, "left": left, "right": right, "sdir": sdir}


static func evert_field(md: MeshData, left: PackedInt32Array, right: PackedInt32Array, sdir: PackedVector3Array, closed: bool, scale: float = 1.0, hole: bool = false, boost_c: Vector3 = Vector3.INF, boost_r: float = 0.028, boost_k: float = 0.9) -> int:
	## 切口外翻：在 rest 上叠加一个平滑位移场到 md.dsp（twin 内壁较小），位移梯度 < 0.6，三角不会翻转或被拉成长条。
	## 外皮：宽场把两侧推开 + 窄场让唇缘卷起抬高；内壁只推开约三成，截面因此朝外倾斜、露出红色断面。
	var n := mini(left.size(), right.size())
	if n < 2:
		return 0
	md.ensure_dsp()
	var tw := md.twin
	if tw != null:
		tw.ensure_dsp()
	var M := PackedVector3Array()
	var S := PackedVector3Array()
	var U := PackedFloat32Array()
	var tot := 0.0
	for i in n:
		var m: Vector3 = (md.pos[left[i]] + md.pos[right[i]]) * 0.5
		if i > 0:
			tot += m.distance_to(M[i - 1])
		M.append(m)
		U.append(tot)
		S.append(sdir[i] if i < sdir.size() else Vector3.RIGHT)
	if tot < 1e-5:
		return 0
	var cen := Vector3.ZERO
	for m2 in M:
		cen += m2
	cen /= float(n)
	var R1 := 0.016 * scale
	var R2 := 0.0055 * scale
	var A1 := 0.0042 * scale
	var A2 := 0.0024 * scale
	var B1 := 0.0008 * scale
	var B2 := 0.0016 * scale
	var lip_side: Dictionary = {}
	if not hole:
		for i2 in n:
			lip_side[left[i2]] = 1.0
			lip_side[right[i2]] = -1.0 if left[i2] != right[i2] else 0.0
	var lo := M[0]
	var hi := M[0]
	for m3 in M:
		lo = lo.min(m3)
		hi = hi.max(m3)
	lo -= Vector3.ONE * R1
	hi += Vector3.ONE * R1
	var moved := 0
	for v in md.vert_count():
		var p: Vector3 = md.pos[v]
		if p.x < lo.x or p.y < lo.y or p.z < lo.z or p.x > hi.x or p.y > hi.y or p.z > hi.z:
			continue
		var best_d := 1e9
		var best_q := Vector3.ZERO
		var best_u := 0.0
		var best_s := Vector3.ZERO
		for i3 in n - 1:
			var a: Vector3 = M[i3]
			var b: Vector3 = M[i3 + 1]
			var ab := b - a
			var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-14), 0.0, 1.0)
			var q := a + ab * t
			var d := p.distance_to(q)
			if d < best_d:
				best_d = d
				best_q = q
				best_u = lerpf(U[i3], U[i3 + 1], t) / tot
				best_s = S[i3].lerp(S[i3 + 1], t)
		if best_d >= R1:
			continue
		var e := 1.0
		if not closed:
			e = pow(maxf(sin(PI * best_u), 0.0), 0.6)
		if e <= 1e-4:
			continue
		var nr: Vector3 = md.nrm[v]
		if nr.length_squared() < EPS:
			nr = Vector3(0, 0, 1)
		nr = nr.normalized()
		var lat: Vector3
		if hole:
			lat = p - cen
			lat -= nr * lat.dot(nr)
			if lat.length_squared() < 1e-12:
				continue
			lat = lat.normalized()
		else:
			var sg := 0.0
			if lip_side.has(v):
				sg = float(lip_side[v])
			if sg == 0.0:
				sg = 1.0 if (p - best_q).dot(best_s) >= 0.0 else -1.0
			lat = best_s.normalized() * sg
			lat -= nr * lat.dot(nr)
			if lat.length_squared() < 1e-12:
				continue
			lat = lat.normalized()
		var w1 := 1.0 - best_d / R1
		w1 = w1 * w1 * e
		var w2 := 0.0
		if best_d < R2:
			w2 = 1.0 - best_d / R2
			w2 = w2 * w2 * e
		# 0.4.03：肚脐附近两唇外翻间距加大（boost_c 为肚脐绑定坐标），避免凹窝处两侧截面贴在一起。
		var bk := 1.0
		if boost_c != Vector3.INF:
			var bd := Vector2(best_q.x - boost_c.x, best_q.y - boost_c.y).length()
			var tb := clampf(1.0 - bd / boost_r, 0.0, 1.0)
			bk = 1.0 + boost_k * tb * tb * (3.0 - 2.0 * tb)
		md.dsp[v] += lat * (A1 * w1 + A2 * w2) * bk + nr * (B1 * w1 + B2 * w2)
		if tw != null and v < tw.vert_count():
			tw.dsp[v] += lat * (A1 * 0.3 * w1) * bk + nr * (B1 * 0.6 * w1)
		moved += 1
	return moved


static func tri_quality(a: Vector3, b: Vector3, c: Vector3) -> float:
	## 1 = 等边，0 = 退化。4√3·面积 / 边长平方和。
	var ar := (b - a).cross(c - a).length() * 0.5
	var s2 := a.distance_squared_to(b) + b.distance_squared_to(c) + c.distance_squared_to(a)
	if s2 < 1e-16:
		return 0.0
	return 6.928203 * ar / s2


static func component_faces(md: MeshData, seeds: PackedInt32Array) -> Dictionary:
	## 从种子顶点出发、经共享顶点连通的所有三角（真正切开后皮瓣与身体互不相连）。
	var v2f: Dictionary = {}
	for f in md.face_count():
		for k in 3:
			var v: int = md.idx[f * 3 + k]
			if not v2f.has(v):
				v2f[v] = []
			(v2f[v] as Array).append(f)
	var seen_f: Dictionary = {}
	var seen_v: Dictionary = {}
	var stack: Array = []
	for sv in seeds:
		if not seen_v.has(sv):
			seen_v[sv] = true
			stack.append(sv)
	while not stack.is_empty():
		var v3: int = stack.pop_back()
		for f2 in v2f.get(v3, []):
			if seen_f.has(f2):
				continue
			seen_f[f2] = true
			for k2 in 3:
				var w: int = md.idx[f2 * 3 + k2]
				if not seen_v.has(w):
					seen_v[w] = true
					stack.append(w)
	return seen_f


## 0.4.04：所有经共享顶点连通的三角块（按三角数从大到小）。每项 = {face: true} 字典。
static func all_components(md: MeshData) -> Array:
	var v2f: Dictionary = {}
	for f in md.face_count():
		for k in 3:
			var v: int = md.idx[f * 3 + k]
			if not v2f.has(v):
				v2f[v] = []
			(v2f[v] as Array).append(f)
	var seen: Dictionary = {}
	var out: Array = []
	for f0 in md.face_count():
		if seen.has(f0):
			continue
		var comp: Dictionary = {}
		var stack: Array = [f0]
		seen[f0] = true
		while not stack.is_empty():
			var f: int = stack.pop_back()
			comp[f] = true
			for k in 3:
				for g in v2f.get(md.idx[f * 3 + k], []):
					if not seen.has(g):
						seen[g] = true
						stack.append(g)
		out.append(comp)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.size() > y.size())
	return out


static func extract_faces(md: MeshData, inside_faces: Dictionary, loop_in_src: PackedInt32Array, loop_out_src: PackedInt32Array) -> Dictionary:
	## 按给定三角集合拆成 inside/outside（twin 同步），返回与 extract_inside 相同格式。
	var inside := MeshData.new()
	var outside := MeshData.new()
	if md.twin != null and md.twin.vert_count() == md.vert_count():
		inside.twin = MeshData.new()
		outside.twin = MeshData.new()
	var map_in: Dictionary = {}
	var map_out: Dictionary = {}
	var _xfer := func(dest: MeshData, mp: Dictionary, si: int) -> int:
		var e := int(mp.get(si, -1))
		if e < 0:
			e = dest.copy_vert(md, si)
			if dest.twin != null:
				dest.twin.copy_vert(md.twin, si)
			mp[si] = e
		return e
	for f in md.face_count():
		var a := md.idx[f * 3]
		var b := md.idx[f * 3 + 1]
		var c := md.idx[f * 3 + 2]
		if inside_faces.has(f):
			inside.add_face(_xfer.call(inside, map_in, a), _xfer.call(inside, map_in, b), _xfer.call(inside, map_in, c))
		else:
			outside.add_face(_xfer.call(outside, map_out, a), _xfer.call(outside, map_out, b), _xfer.call(outside, map_out, c))
	var loop_in := PackedInt32Array()
	var loop_out := PackedInt32Array()
	for id in loop_in_src:
		if id >= 0 and id < md.vert_count():
			loop_in.append(_xfer.call(inside, map_in, id))
	for id2 in loop_out_src:
		if id2 >= 0 and id2 < md.vert_count():
			loop_out.append(_xfer.call(outside, map_out, id2))
	sync_twin_faces(inside)
	sync_twin_faces(outside)
	return {
		"inside": inside,
		"outside": outside,
		"loop_in": loop_in,
		"loop_out": loop_out,
		"inside_faces": inside.face_count(),
		"outside_faces": outside.face_count(),
		"map_out": map_out,
	}


static func flip_slivers(md: MeshData, qmin: float = 0.08, passes: int = 3) -> int:
	## 0.4.01：切口端点 / 唇缘附近的细长三角做边翻转（只翻内部边；唇缘已是开放边界，不会被翻）。
	## 翻转后两张三角的最差质量必须变好，且法线方向不反。twin 由调用方 sync_twin_faces 同步。
	var flips := 0
	for _p in passes:
		var emap: Dictionary = {}
		for f in md.face_count():
			for k in 3:
				var a := md.idx[f * 3 + k]
				var b := md.idx[f * 3 + (k + 1) % 3]
				emap[Vector2i(a, b)] = f
		var changed := false
		for f in md.face_count():
			var ia := md.idx[f * 3]
			var ib := md.idx[f * 3 + 1]
			var ic := md.idx[f * 3 + 2]
			if ia == ib or ib == ic or ia == ic:
				continue
			var q0 := tri_quality(md.pos[ia], md.pos[ib], md.pos[ic])
			if q0 >= qmin:
				continue
			# 最长边 (a,b)，对顶点 c
			var tri := [ia, ib, ic]
			var best_k := 0
			var best_l := -1.0
			for k2 in 3:
				var l := md.pos[tri[k2]].distance_squared_to(md.pos[tri[(k2 + 1) % 3]])
				if l > best_l:
					best_l = l
					best_k = k2
			var a2: int = tri[best_k]
			var b2: int = tri[(best_k + 1) % 3]
			var c2: int = tri[(best_k + 2) % 3]
			if not emap.has(Vector2i(b2, a2)):
				continue
			var g: int = emap[Vector2i(b2, a2)]
			var d2 := -1
			for k3 in 3:
				var v := md.idx[g * 3 + k3]
				if v != a2 and v != b2:
					d2 = v
			if d2 < 0 or d2 == c2:
				continue
			var qg := tri_quality(md.pos[md.idx[g * 3]], md.pos[md.idx[g * 3 + 1]], md.pos[md.idx[g * 3 + 2]])
			# 新三角 (c,a,d) 与 (d,b,c)，保持与原来相同的绕向
			var q1 := tri_quality(md.pos[c2], md.pos[a2], md.pos[d2])
			var q2 := tri_quality(md.pos[d2], md.pos[b2], md.pos[c2])
			if minf(q1, q2) <= minf(q0, qg) + 1e-4:
				continue
			var n_old := (md.pos[b2] - md.pos[a2]).cross(md.pos[c2] - md.pos[a2]) + (md.pos[a2] - md.pos[b2]).cross(md.pos[d2] - md.pos[b2])
			var n1 := (md.pos[a2] - md.pos[c2]).cross(md.pos[d2] - md.pos[c2])
			var n2 := (md.pos[b2] - md.pos[d2]).cross(md.pos[c2] - md.pos[d2])
			if n1.dot(n_old) <= 0.0 or n2.dot(n_old) <= 0.0:
				continue
			# 新边 (c,d) 不能已存在（否则非流形）
			if emap.has(Vector2i(c2, d2)) or emap.has(Vector2i(d2, c2)):
				continue
			md.idx[f * 3] = c2
			md.idx[f * 3 + 1] = a2
			md.idx[f * 3 + 2] = d2
			md.idx[g * 3] = d2
			md.idx[g * 3 + 1] = b2
			md.idx[g * 3 + 2] = c2
			flips += 1
			changed = true
			break
		if not changed:
			break
	return flips
