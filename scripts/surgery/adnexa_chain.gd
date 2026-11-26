extends MeshInstance3D
## 输卵管短链：两端封口，宫角端埋进宫角，卵巢端没入卵巢。无器官/腹壁碰撞，避免卵巢被卡住。

const SIDES := 8
const ITER := 12
const DAMP := 0.88

var open_chain: bool = true
var hold_index: int = -1
var hold_pos: Vector3 = Vector3.ZERO
var gravity: Vector3 = Vector3(0, -9.8, 0)
var floor_y: float = -1e9
var radius: float = 0.0034
var horn_embed: float = 0.007
var ovary_embed: float = 0.006
var taper: bool = true          # false：等径（子宫系带用）

var _p: PackedVector3Array = PackedVector3Array()
var _q: PackedVector3Array = PackedVector3Array()
var _rest: PackedFloat32Array = PackedFloat32Array()
var _am: ArrayMesh
var _head: Vector3 = Vector3.ZERO
var _dir: Vector3 = Vector3.RIGHT


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am


func use_organ_material(mat: ShaderMaterial) -> void:
	if mat:
		material_override = mat.duplicate() as ShaderMaterial


func points() -> PackedVector3Array:
	return _p


func set_points(pts: PackedVector3Array) -> void:
	_p = pts.duplicate()
	_q = pts.duplicate()


## 由外部（子宫柔体）算好物理后写入位置与上一帧位置，只重建网格，不清速度。
## t82u：点位与上次建网格时相差都不到 MESH_EPS 就不重建网格（静挂 / 休眠时省掉每帧的管子重建）。
const MESH_EPS := 0.00005
var _mesh_pts: PackedVector3Array = PackedVector3Array()
var mesh_rebuilds: int = 0


func apply_points(pts: PackedVector3Array, prev: PackedVector3Array, dir: Vector3) -> void:
	_p = pts.duplicate()
	_q = prev.duplicate() if prev.size() == pts.size() else pts.duplicate()
	if dir.length_squared() > 1e-10:
		_dir = dir.normalized()
	if not _p.is_empty():
		_head = _p[0]
	if _mesh_pts.size() == _p.size() and not _p.is_empty():
		var same := true
		var e2 := MESH_EPS * MESH_EPS
		for i in _p.size():
			if _p[i].distance_squared_to(_mesh_pts[i]) > e2:
				same = false
				break
		if same:
			return
	_rebuild_mesh()


func point_count() -> int:
	return _p.size()


func tip() -> Vector3:
	if _p.is_empty():
		return _head
	return _p[_p.size() - 1]


func head() -> Vector3:
	if _p.is_empty():
		return _head
	return _p[0]


func setup_line(horn: Vector3, ovary: Vector3, npts: int = 7) -> void:
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	npts = maxi(npts, 4)
	var d := ovary - horn
	if d.length_squared() < 1e-10:
		d = Vector3(0.02, 0.0, 0.0)
	_dir = d.normalized()
	var L := d.length()
	# 第 0 点埋进宫角，最后一点在卵巢中心。
	_p.resize(npts)
	_q.resize(npts)
	_rest.resize(maxi(npts - 1, 1))
	for i in npts:
		var t := float(i) / float(npts - 1)
		# t=0 在 horn - dir*embed，t=1 在 ovary
		var a := horn - _dir * horn_embed
		_p[i] = a.lerp(ovary, t)
		_q[i] = _p[i]
	for i in npts - 1:
		_rest[i] = _p[i].distance_to(_p[i + 1])
	_head = _p[0]
	_rebuild_mesh()


func set_head_and_rest(horn: Vector3, ovary: Vector3) -> void:
	if _p.size() < 2:
		setup_line(horn, ovary)
		return
	var d := ovary - horn
	if d.length_squared() < 1e-10:
		d = _dir
	_dir = d.normalized()
	var a := horn - _dir * horn_embed
	var n := _p.size()
	for i in n:
		var t := float(i) / float(n - 1)
		_p[i] = a.lerp(ovary, t)
		_q[i] = _p[i]
	_head = _p[0]
	_rebuild_mesh()


func pin_head(horn: Vector3) -> void:
	if _p.is_empty():
		return
	var d := _dir
	if _p.size() >= 2:
		var dd := _p[1] - _p[0]
		if dd.length_squared() > 1e-10:
			d = dd.normalized()
	_dir = d
	_head = horn - d * horn_embed
	_p[0] = _head
	if _q.size() == _p.size():
		_q[0] = _head


func carry(xf: Transform3D) -> void:
	for i in _p.size():
		_p[i] = xf * _p[i]
	for i in _q.size():
		_q[i] = xf * _q[i]
	_head = xf * _head
	_dir = (xf.basis * _dir).normalized()
	if hold_index >= 0:
		hold_pos = xf * hold_pos


func ray_pick(origin: Vector3, dir: Vector3) -> Array:
	var d := dir.normalized()
	var best := 1e9
	var bi := -1
	var tol := radius + 0.010
	for i in _p.size():
		var w := _p[i] - origin
		var t := w.dot(d)
		if t <= 0.0:
			continue
		var dist := (w - d * t).length()
		if dist < best:
			best = dist
			bi = i
	if best > tol:
		return [-1, best]
	return [bi, best]


func step(dt: float) -> void:
	if _p.size() < 2:
		return
	dt = minf(maxf(dt, 0.0), 1.0 / 30.0)
	var n := _p.size()
	# 第 0 点钉在宫角（已由 pin_head 写入 _head）
	_p[0] = _head
	_q[0] = _head
	for i in range(1, n):
		if i == hold_index:
			_q[i] = _p[i]
			_p[i] = hold_pos
			continue
		var cur := _p[i]
		var v := (cur - _q[i]) * DAMP
		v += gravity * dt * dt
		_q[i] = cur
		_p[i] = cur + v
		if _p[i].y < floor_y + 0.006:
			_p[i].y = floor_y + 0.006
	for _it in ITER:
		_p[0] = _head
		if hold_index >= 0 and hold_index < n:
			_p[hold_index] = hold_pos
		_solve_dist(n)
	_p[0] = _head
	if hold_index >= 0 and hold_index < n:
		_p[hold_index] = hold_pos
	_rebuild_mesh()


func _solve_dist(n: int) -> void:
	for i in n - 1:
		var rest := _rest[i] if i < _rest.size() else _p[i].distance_to(_p[i + 1])
		if rest < 1e-6:
			continue
		var d := _p[i + 1] - _p[i]
		var L := d.length()
		if L < 1e-8:
			continue
		var corr := (L - rest) / L
		var li := i == 0 or i == hold_index
		var lj := (i + 1) == hold_index
		if li and lj:
			continue
		if li:
			_p[i + 1] -= d * corr
		elif lj:
			_p[i] += d * corr
		else:
			_p[i] += d * corr * 0.5
			_p[i + 1] -= d * corr * 0.5


func _rebuild_mesh() -> void:
	_mesh_pts = _p.duplicate()
	mesh_rebuilds += 1
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	var n := _p.size()
	if n < 2:
		_am.clear_surfaces()
		return
	# 轴 + 两端极点，封闭截面，不露出管子直径。
	var rings := n
	var verts := PackedVector3Array()
	var nrms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tans := PackedFloat32Array()
	var idx := PackedInt32Array()
	var frames: Array = []
	var prev_nn := Vector3.ZERO
	for i in n:
		var t := (_p[mini(i + 1, n - 1)] - _p[maxi(i - 1, 0)])
		if t.length_squared() < 1e-12:
			t = _dir if _dir.length_squared() > 1e-10 else Vector3.UP
		t = t.normalized()
		var nref := prev_nn if prev_nn != Vector3.ZERO else (Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT)
		var nn := nref - t * nref.dot(t)
		if nn.length_squared() < 1e-10:
			nn = t.cross(Vector3.RIGHT)
			if nn.length_squared() < 1e-10:
				nn = t.cross(Vector3.UP)
		nn = nn.normalized()
		prev_nn = nn
		var bn := t.cross(nn)
		frames.append([t, nn, bn])
	# 半径：首环埋在宫角内保持全径；尾环收进卵巢。
	var rads := PackedFloat32Array()
	rads.resize(n)
	for i in n:
		var u := float(i) / float(n - 1)
		var rad := radius
		if taper and u > 0.72:
			var s := (u - 0.72) / 0.28
			rad = radius * (1.0 - s * 0.92)
		rads[i] = maxf(rad, radius * 0.08)
	# 极点
	var t0: Vector3 = frames[0][0]
	var t1: Vector3 = frames[n - 1][0]
	var pole_a: Vector3 = _p[0] - t0 * radius * 0.55
	var pole_b: Vector3 = _p[n - 1] + t1 * maxf(rads[n - 1] * 0.4, 0.0004)
	var ia_pole := 0
	verts.append(pole_a)
	nrms.append(-t0)
	uvs.append(Vector2(0.0, 0.5))
	_push_tan(tans, -t0)
	var ring0 := 1
	for i in n:
		var fr: Array = frames[i]
		var nn: Vector3 = fr[1]
		var bn: Vector3 = fr[2]
		var tan: Vector3 = fr[0]
		var rad: float = rads[i]
		var u := float(i) / float(n - 1)
		for k in SIDES + 1:
			var ang := TAU * float(k) / float(SIDES)
			var dir := nn * cos(ang) + bn * sin(ang)
			verts.append(_p[i] + dir * rad)
			nrms.append(dir)
			uvs.append(Vector2(u, float(k) / float(SIDES)))
			_push_tan(tans, tan)
	var ib_pole := verts.size()
	verts.append(pole_b)
	nrms.append(t1)
	uvs.append(Vector2(1.0, 0.5))
	_push_tan(tans, t1)
	# 头帽
	for k in SIDES:
		var a := ring0 + k
		var b := ring0 + k + 1
		idx.append_array([ia_pole, a, b])  # t82u：端帽朝外（与解析法线一致）
	# 管身
	for i in n - 1:
		var ra := ring0 + i * (SIDES + 1)
		var rb := ring0 + (i + 1) * (SIDES + 1)
		for k in SIDES:
			var a := ra + k
			var b := rb + k
			idx.append_array([a, b, b + 1, a, b + 1, a + 1])
	# 尾帽
	var last := ring0 + (n - 1) * (SIDES + 1)
	for k in SIDES:
		var a := last + k
		var b := last + k + 1
		idx.append_array([b, a, ib_pole])
	# t82u：直接提交带索引的数组（解析法线 / 切线），不再逐顶点过 SurfaceTool 再 generate_normals / generate_tangents
	# （后者每次约 0.1 ms，体外悬挂摆动时每帧三根管子）。法线改为圆管的平滑径向法线。
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = nrms
	arr[Mesh.ARRAY_TANGENT] = tans
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mat := _am.surface_get_material(0) if _am.get_surface_count() > 0 else null
	_am.clear_surfaces()
	_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if mat:
		_am.surface_set_material(0, mat)


func _push_tan(tans: PackedFloat32Array, t: Vector3) -> void:
	tans.append(t.x)
	tans.append(t.y)
	tans.append(t.z)
	tans.append(1.0)
