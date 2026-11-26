extends MeshInstance3D
## 脱垂专用的简化子宫 + 宫颈模型（t68u）：脱垂期间替换原子宫 / 宫颈网格。
##
## 沿脱垂链（宫颈尖 → 宫底）的中线生成一根低面数的管：截面 = 原子宫网格测得的 8 段剖面
## （与外口撑开、阴道着色器同一公式 mass_radius_at），宫颈尖是带宫口小凹的圆顶，宫底收口；
## IV 度宫底出了外口后，宫底到外口之间接一段细颈（阴道穹窿的蒂）。
## 两个面都用阴道黏膜材质再统一染成更红润、湿润的肉色：面 0 = 宫颈（宫口周围略深），
## 面 1 = 宫体 + 细颈（同一色系，交接处没有子宫红 / 阴道粉的硬边）。
##
## 网格建在腹部局部坐标里，节点变换 = 腹部坐标系：身体移动 / 呼吸时不用重建，只有链形状变了才重建
## （约 20 边 × ~27 环，平滑法线；仍远轻于原子宫 3839 顶点 + GPU 蒙皮 + 输卵管卵巢）。
class_name ProlapseUterusModel

const SIDES := 20
const BODY_RINGS := 14
const CERVIX_RINGS := 5
const NECK_RINGS := 5
const DOME_FRACS := [0.95, 0.78, 0.52, 0.0]
const OS_DIMPLE := 0.0025
const REBUILD_EPS := 0.00008

var vertex_count := 0
var rebuilds := 0
var neck_radius := 0.0      # 最近一次重建的细颈半径（0 = 没有细颈）
var _am: ArrayMesh
var _mat_body: Material = null
var _mat_cervix: Material = null
var _last_centers := PackedVector3Array()
var _last_radii := PackedFloat32Array()
var _last_arcs := PackedFloat32Array()
var _sig_nodes := PackedVector3Array()
var _sig_neck := -1.0
var _cs := PackedFloat32Array()
var _sn := PackedFloat32Array()


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	extra_cull_margin = 1.0
	_cs.resize(SIDES + 1)
	_sn.resize(SIDES + 1)
	for j in SIDES + 1:
		_cs[j] = cos(TAU * float(j) / float(SIDES))
		_sn[j] = sin(TAU * float(j) / float(SIDES))


## t96u：登记为可被普通互动工具抓取的悬垂器官（HangGrab 接口，解算在父节点 ProlapseController）。
func _enter_tree() -> void:
	add_to_group("hang_grab_organs")


func set_materials(body: Material, cervix: Material) -> void:
	_mat_body = body
	_mat_cervix = cervix if cervix else body


## 最近一次重建的中线采样（局部 = 腹部坐标；自检用）：环心、半径、弧长（宫颈尖 = 0，向宫底为正）。
func ring_centers() -> PackedVector3Array:
	return _last_centers


func ring_centers_world() -> PackedVector3Array:
	var out := PackedVector3Array()
	var xf := global_transform
	for c in _last_centers:
		out.append(xf * c)
	return out


func ring_radii() -> PackedFloat32Array:
	return _last_radii


func ring_arcs() -> PackedFloat32Array:
	return _last_arcs


func invalidate() -> void:
	_sig_nodes = PackedVector3Array()


## frame：腹部坐标系（节点变换）；nodes_ab：宫颈 → 宫底的链节点（腹部局部）；arcs：各节点弧长；
## radius_fn(a)：截面半径；cervix_len：宫颈段长；neck_ab：宫底之后接到外口的细颈中线（可为空）。
## 返回是否真的重建了网格（形状没变只更新变换）。
func rebuild(frame: Transform3D, nodes_ab: PackedVector3Array, arcs: PackedFloat32Array, radius_fn: Callable, U: float, cervix_len: float, neck_ab: PackedVector3Array, neck_r: float, up_ab: Vector3) -> bool:
	global_transform = frame
	visible = true
	var n := mini(nodes_ab.size(), arcs.size())
	if n < 2:
		return false
	var neck_len := 0.0
	for i in maxi(neck_ab.size() - 1, 0):
		neck_len += neck_ab[i].distance_to(neck_ab[i + 1])
	if _same_shape(nodes_ab, neck_len):
		return false
	_sig_nodes = nodes_ab.duplicate()
	_sig_neck = neck_len
	rebuilds += 1
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	if _cs.size() != SIDES + 1:
		_ready()
	var r0 := maxf(float(radius_fn.call(0.0)), 0.004)
	var has_neck := neck_ab.size() >= 2 and neck_len > 1e-4
	# ---- 环的弧长采样：宫颈尖圆顶 → 宫颈段 → 宫体 → （细颈）
	var ring_a := PackedFloat32Array()
	for f in DOME_FRACS:
		ring_a.append(-r0 * float(f))
	for k in range(1, CERVIX_RINGS):
		ring_a.append(cervix_len * float(k) / float(CERVIX_RINGS))
	for k2 in BODY_RINGS + 1:
		ring_a.append(lerpf(cervix_len, U, float(k2) / float(BODY_RINGS)))
	if has_neck:
		for k3 in range(1, NECK_RINGS + 1):
			ring_a.append(U + neck_len * float(k3) / float(NECK_RINGS))
	var R := ring_a.size()
	var centers := PackedVector3Array()
	var radii := PackedFloat32Array()
	centers.resize(R)
	radii.resize(R)
	for ri in R:
		var a := ring_a[ri]
		centers[ri] = _center_at(a, nodes_ab, arcs, n, U, neck_ab)
		var r: float
		if a > U:
			r = neck_r
		elif a < 0.0:
			# 宫颈尖圆顶：半球形收口。
			r = r0 * sqrt(maxf(1.0 - (a / r0) * (a / r0), 0.0))
		else:
			r = float(radius_fn.call(minf(a, U * 0.999)))
			if a > U * 0.86:
				var t2 := clampf((a - U * 0.86) / (U * 0.14), 0.0, 1.0)
				if has_neck:
					r = lerpf(r, neck_r, t2)
				else:
					r *= sqrt(maxf(1.0 - t2 * t2, 0.0))
		radii[ri] = maxf(r, 0.0)
	_last_centers = centers
	_last_radii = radii
	neck_radius = neck_r if has_neck else 0.0
	_last_arcs = ring_a
	# ---- 切线 + 平行移动标架
	var tans := PackedVector3Array()
	var bxs := PackedVector3Array()
	var bys := PackedVector3Array()
	tans.resize(R)
	bxs.resize(R)
	bys.resize(R)
	for i2 in R:
		var tg := centers[mini(i2 + 1, R - 1)] - centers[maxi(i2 - 1, 0)]
		tans[i2] = tg.normalized() if tg.length_squared() > 1e-14 else Vector3.UP
	var nx := up_ab - tans[0] * up_ab.dot(tans[0])
	if nx.length_squared() < 1e-8:
		nx = tans[0].cross(Vector3.RIGHT if absf(tans[0].x) < 0.9 else Vector3.UP)
	nx = nx.normalized()
	for i3 in R:
		if i3 > 0:
			var q := nx - tans[i3] * nx.dot(tans[i3])
			if q.length_squared() > 1e-12:
				nx = q.normalized()
		bxs[i3] = nx
		bys[i3] = tans[i3].cross(nx).normalized()
	# ---- 两个面：0 = 宫颈（略深），1 = 宫体 + 细颈（统一红润黏膜）
	var v0 := PackedVector3Array()
	var n0 := PackedVector3Array()
	var u0 := PackedVector2Array()
	var i0 := PackedInt32Array()
	var v1 := PackedVector3Array()
	var n1 := PackedVector3Array()
	var u1 := PackedVector2Array()
	var i1 := PackedInt32Array()
	var W := SIDES + 1
	var prev_surf := -1
	for k4 in R - 1:
		var amid := 0.5 * (ring_a[k4] + ring_a[k4 + 1])
		# 宫颈略深；宫体和细颈同一黏膜色，避免子宫红 / 阴道粉的硬边。
		var surf := 0 if amid < cervix_len else 1
		var V: PackedVector3Array = v0 if surf == 0 else v1
		var N: PackedVector3Array = n0 if surf == 0 else n1
		var UV: PackedVector2Array = u0 if surf == 0 else u1
		var I: PackedInt32Array = i0 if surf == 0 else i1
		# 同一面连续的段共享上一环（只在换面处重复一环）。
		if surf != prev_surf:
			_ring(V, N, UV, centers, radii, ring_a, tans, bxs, bys, k4, R)
		var base := V.size() - W
		_ring(V, N, UV, centers, radii, ring_a, tans, bxs, bys, k4 + 1, R)
		for j2 in SIDES:
			var a0 := base + j2
			var b0 := base + W + j2
			# Godot 正面 = 顺时针（从外面看）。
			I.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
		if surf == 0:
			v0 = V
			n0 = N
			u0 = UV
			i0 = I
		else:
			v1 = V
			n1 = N
			u1 = UV
			i1 = I
		prev_surf = surf
	# 宫颈尖：带宫口小凹的顶盖；无细颈时宫底也封口。
	_cap(v0, n0, u0, i0, centers[0], -tans[0], bxs[0], bys[0], radii[0], true)
	if not has_neck:
		_cap(v1, n1, u1, i1, centers[R - 1], tans[R - 1], bxs[R - 1], bys[R - 1], radii[R - 1], false)
	_am.clear_surfaces()
	vertex_count = 0
	var sidx := 0
	for s in 2:
		var VV: PackedVector3Array = v0 if s == 0 else v1
		var II: PackedInt32Array = i0 if s == 0 else i1
		if II.is_empty():
			continue
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = VV
		arr[Mesh.ARRAY_NORMAL] = n0 if s == 0 else n1
		arr[Mesh.ARRAY_TEX_UV] = u0 if s == 0 else u1
		arr[Mesh.ARRAY_INDEX] = II
		_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var m := _mat_cervix if s == 0 else _mat_body
		if m:
			_am.surface_set_material(sidx, m)
		sidx += 1
		vertex_count += VV.size()
	return true


func _same_shape(nodes_ab: PackedVector3Array, neck_len: float) -> bool:
	if _sig_nodes.size() != nodes_ab.size() or absf(neck_len - _sig_neck) > REBUILD_EPS:
		return false
	for i in nodes_ab.size():
		if nodes_ab[i].distance_squared_to(_sig_nodes[i]) > REBUILD_EPS * REBUILD_EPS:
			return false
	return true


func _ring(V: PackedVector3Array, N: PackedVector3Array, UV: PackedVector2Array, centers: PackedVector3Array, radii: PackedFloat32Array, ring_a: PackedFloat32Array, tans: PackedVector3Array, bxs: PackedVector3Array, bys: PackedVector3Array, rr: int, R: int) -> void:
	var c := centers[rr]
	var r := radii[rr]
	var bx := bxs[rr]
	var by := bys[rr]
	var tg := tans[rr]
	var i_lo := maxi(rr - 1, 0)
	var i_hi := mini(rr + 1, R - 1)
	var dr := (radii[i_hi] - radii[i_lo]) / maxf(ring_a[i_hi] - ring_a[i_lo], 1e-5)
	dr = clampf(dr, -6.0, 6.0)
	var v := ring_a[rr] * 12.0
	for j in SIDES + 1:
		var dirv := bx * _cs[j] + by * _sn[j]
		V.append(c + dirv * r)
		N.append((dirv - tg * dr).normalized())
		UV.append(Vector2(float(j) / float(SIDES), v))


func _cap(V: PackedVector3Array, N: PackedVector3Array, UV: PackedVector2Array, I: PackedInt32Array, c: Vector3, out: Vector3, bx: Vector3, by: Vector3, r: float, dimple: bool) -> void:
	var base := V.size()
	var tip := c - out * minf(OS_DIMPLE, r * 0.5) if dimple else c
	V.append(tip)
	N.append(out)
	UV.append(Vector2(0.5, 0.0))
	for j in SIDES + 1:
		var dirv := bx * _cs[j] + by * _sn[j]
		V.append(c + dirv * r)
		N.append((dirv + out).normalized())
		UV.append(Vector2(float(j) / float(SIDES), 0.02))
	# 绕序：从 out 一侧看为顺时针（Godot 正面），与侧面一致。
	var flip := by.cross(bx).dot(out) < 0.0
	for j2 in SIDES:
		var a := base + 1 + j2
		if flip:
			I.append_array([base, a + 1, a])
		else:
			I.append_array([base, a, a + 1])


func _center_at(a: float, nodes: PackedVector3Array, arcs: PackedFloat32Array, n: int, U: float, neck: PackedVector3Array) -> Vector3:
	if a <= 0.0:
		var d := nodes[0] - nodes[1]
		if d.length_squared() < 1e-12:
			d = Vector3.DOWN
		return nodes[0] + d.normalized() * (-a)
	if a > U and neck.size() >= 2:
		var s := a - U
		for i in neck.size() - 1:
			var l := neck[i].distance_to(neck[i + 1])
			if s <= l or i == neck.size() - 2:
				return neck[i].lerp(neck[i + 1], clampf(s / maxf(l, 1e-6), 0.0, 1.0))
			s -= l
	for i2 in range(1, n):
		if a <= arcs[i2] or i2 == n - 1:
			var t := clampf((a - arcs[i2 - 1]) / maxf(arcs[i2] - arcs[i2 - 1], 1e-6), 0.0, 1.0)
			# Catmull-Rom：节点之间平滑弯曲（端点外推一节）
			var p1 := nodes[i2 - 1]
			var p2 := nodes[i2]
			var p0 := nodes[i2 - 2] if i2 >= 2 else p1 * 2.0 - p2
			var p3 := nodes[i2 + 1] if i2 + 1 < n else p2 * 2.0 - p1
			var t2 := t * t
			var t3 := t2 * t
			return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
	return nodes[n - 1]
