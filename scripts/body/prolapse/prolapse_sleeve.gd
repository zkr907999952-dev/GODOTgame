extends MeshInstance3D
## 外翻阴道套筒：沿体外段链的中线生成一根管，半径 = 脱出物截面 + 壁厚，黏膜朝外。
## 根部从外口里面一点开始（与前庭接上），末端收在宫颈上（宫颈露出 cervix_expose）。
## 每帧 CPU 重建：环数 ≤ 34、每环 18 点，开销很小。
class_name ProlapseSleeve

const SIDES := 18
const MAX_RINGS := 34

var ring_count := 0
var _am: ArrayMesh
var _last_rings: Array = []   # [{c, n, r}]


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	extra_cull_margin = 1.0


func rings() -> Array:
	return _last_rings


## centers：从外口里面到宫颈端的中线点；radii：每点半径；up_hint：截面参考方向。
func rebuild(centers: PackedVector3Array, radii: PackedFloat32Array, up_hint: Vector3) -> void:
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	_am.clear_surfaces()
	_last_rings = []
	ring_count = 0
	var n := mini(centers.size(), radii.size())
	if n < 2:
		visible = false
		return
	var V := PackedVector3Array()
	var N := PackedVector3Array()
	var UV := PackedVector2Array()
	var T := PackedFloat32Array()
	var I := PackedInt32Array()
	var ref := up_hint if up_hint.length_squared() > 1e-8 else Vector3.UP
	var arc := 0.0
	var prev_x := Vector3.ZERO
	# 截面朝向用「前后各约一个半径」窗口内的弦方向：急弯处相邻环不互相穿插（粗管不能折成直角）。
	var cum := PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for j in range(1, n):
		cum[j] = cum[j - 1] + centers[j].distance_to(centers[j - 1])
	for i in n:
		var win := maxf(radii[i], 0.002) * 1.1
		var ia := i
		while ia > 0 and cum[i] - cum[ia] < win:
			ia -= 1
		var ib := i
		while ib < n - 1 and cum[ib] - cum[i] < win:
			ib += 1
		var tan: Vector3 = centers[ib] - centers[ia]
		if tan.length_squared() < 1e-12:
			tan = Vector3.DOWN
		tan = tan.normalized()
		# 防折叠：相邻两环的倾角差不能让环边越过前一环（tan Δθ ≤ 间距 / 半径）。
		if i > 0:
			var prev_t: Vector3 = (_last_rings[i - 1] as Dictionary)["t"]
			var gap := centers[i].distance_to(centers[i - 1])
			var rr := maxf(maxf(radii[i], radii[i - 1]), 0.0005)
			var lim := atan(gap / rr) * 0.85
			var ang := prev_t.angle_to(tan)
			if ang > lim and ang > 1e-5:
				var ax := prev_t.cross(tan)
				if ax.length_squared() > 1e-12:
					tan = prev_t.rotated(ax.normalized(), lim).normalized()
		if i > 0:
			arc += centers[i].distance_to(centers[i - 1])
		# 平行传输截面基，避免扭转。
		var x: Vector3
		if i == 0:
			x = ref.cross(tan)
			if x.length_squared() < 1e-8:
				x = Vector3.RIGHT.cross(tan)
		else:
			x = prev_x - tan * prev_x.dot(tan)
			if x.length_squared() < 1e-8:
				x = ref.cross(tan)
		x = x.normalized()
		prev_x = x
		var y := tan.cross(x).normalized()
		var r := maxf(radii[i], 0.0005)
		_last_rings.append({"c": centers[i], "t": tan, "r": r})
		for k in SIDES + 1:
			var a := TAU * float(k) / float(SIDES)
			var dirv := x * cos(a) + y * sin(a)
			V.append(centers[i] + dirv * r)
			N.append(dirv)
			UV.append(Vector2(float(k) / float(SIDES), arc * 12.0))
			var tg := tan.cross(dirv).normalized()
			T.append_array([tg.x, tg.y, tg.z, 1.0])
	for i2 in n - 1:
		for k2 in SIDES:
			var a0 := i2 * (SIDES + 1) + k2
			var a1 := a0 + 1
			var b0 := a0 + SIDES + 1
			var b1 := b0 + 1
			# 外表面朝外（黏膜面）。
			I.append_array([a0, b0, a1, a1, b0, b1])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TANGENT] = T
	arr[Mesh.ARRAY_TEX_UV] = UV
	arr[Mesh.ARRAY_INDEX] = I
	_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if material_override == null and get_meta("mat", null) != null:
		material_override = get_meta("mat")
	ring_count = n
	visible = true


## 自检：套筒是否连续（相邻环中心距离 ≤ 环半径之和、无 NaN、法线朝外）。
func continuity_report() -> Dictionary:
	var out := {"rings": _last_rings.size(), "max_gap": 0.0, "nan": 0, "inward_normals": 0, "faces": 0, "bad_rings": []}
	if _am == null or _am.get_surface_count() < 1:
		return out
	var arr: Array = _am.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	out["faces"] = I.size() / 3
	for v in V:
		if not v.is_finite():
			out["nan"] = int(out["nan"]) + 1
	for i in range(1, _last_rings.size()):
		var a: Dictionary = _last_rings[i - 1]
		var b: Dictionary = _last_rings[i]
		var gap := (a["c"] as Vector3).distance_to(b["c"])
		out["max_gap"] = maxf(float(out["max_gap"]), gap)
	# 每个顶点法线与「顶点 - 所在环中心」同向 = 黏膜朝外。
	for ri in _last_rings.size():
		var c: Vector3 = (_last_rings[ri] as Dictionary)["c"]
		for k in SIDES + 1:
			var vi := ri * (SIDES + 1) + k
			if vi >= V.size():
				break
			if (V[vi] - c).dot(N[vi]) <= 0.0:
				out["inward_normals"] = int(out["inward_normals"]) + 1
	# 三角绕序与法线一致（外表面）。
	var bad_wind := 0
	for f in range(0, I.size(), 3):
		var fa: Vector3 = V[I[f]]
		var fb: Vector3 = V[I[f + 1]]
		var fc: Vector3 = V[I[f + 2]]
		var fnv := (fb - fa).cross(fc - fa)
		if fnv.length_squared() < 1e-18:
			continue
		var avg_n: Vector3 = N[I[f]] + N[I[f + 1]] + N[I[f + 2]]
		# Godot 正面为顺时针：叉积朝内即视为正面朝外。
		if fnv.dot(avg_n) > 0.0:
			bad_wind += 1
			var ring_i := int(f / 6) / SIDES
			if not (out["bad_rings"] as Array).has(ring_i):
				(out["bad_rings"] as Array).append(ring_i)
	out["wind_mismatch"] = bad_wind
	return out
