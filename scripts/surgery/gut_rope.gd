extends MeshInstance3D
## 0.4.01 / 0.4.02：从创口掉出来的小肠——Verlet 长链条，像布娃娃一样随身体甩动。
## 0.4.02：
## - 材质：复用体内小肠的 organ.gdshader 材质（同贴图 / 法线 / 湿润度），沿管长连续 UV；
##   带 CUSTOM0（沿管长坐标 + 径向）并加入器官材质列表，和体内小肠同一套蠕动时钟一起蠕动。
## - 锚点在腹腔里面：取创口唇缘对应的内壁（twin）顶点再往里，每帧按蒙皮 + 拿取位移重算，跟着腹部软体走。
## - 系膜：每隔几个质点有一根软弹簧拉回腹腔深处的系膜根（只在超出松弛长度时拉，弹性高）。
## - 碰撞：腹部椭球、四肢精细命中箱胶囊（character_hitboxes 的手臂 / 腿 / 脚）、检查床面 / 地面。

const N := 26
const SIDES := 9
const RADIUS := 0.0105
const ITER := 5
const GRAVITY := Vector3(0, -9.8, 0)
const DAMP := 0.988
const FEED_RATE := 0.35       # m/s：受到甩动 / 重力外拉时往外滑的最大速度
const FEED_ACCEL_K := 0.045   # 每 m/s² 的身体加速度带出的滑出速度
const START_LEN := 0.06       # 一开始鼓出来的一小段
const MES_EVERY := 4          # 每隔几个质点一根系膜弹簧
const MES_K := 0.06           # 系膜弹簧每次迭代的校正比例（越小越软 / 弹性越高）
const ALONG_UNIT := 0.5       # 蠕动沿管坐标：每 0.5m 记 1（与体内小肠波长同量级）
const UV_REPEAT := 0.045      # 贴图沿管每 4.5cm 重复一次

var anchor_a: Vector3 = Vector3.ZERO   # 世界坐标：腹腔内锚点 1
var anchor_b: Vector3 = Vector3.ZERO   # 世界坐标：腹腔内锚点 2
var mes_root: Vector3 = Vector3.ZERO   # 世界坐标：系膜根（腹腔深处）
var out_dir: Vector3 = Vector3.FORWARD # 世界坐标：创口外法线
var max_len: float = 0.2               # 允许掉出的总长（创口越大越长）
var fed_len: float = START_LEN         # 当前掉出的长度
var floor_y: float = -1e9              # 床面 / 地面
## 碰撞：腹部椭球（腹局部空间）+ 世界↔腹局部变换
var ab_frame: Transform3D = Transform3D.IDENTITY
var ell_c: Vector3 = Vector3.ZERO
var ell_r: Vector3 = Vector3(0.12, 0.2, 0.08)
## 胶囊 [a, b, r]（世界坐标）
var capsules: Array = []

var _p: PackedVector3Array = PackedVector3Array()
var _q: PackedVector3Array = PackedVector3Array()
var _am: ArrayMesh
var _idx: PackedInt32Array = PackedInt32Array()
var _prev_mid: Vector3 = Vector3.ZERO
var _prev_vel: Vector3 = Vector3.ZERO
var _inited := false
var _mat_is_organ := false
var capsule_pushes: int = 0


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_am = ArrayMesh.new()
	mesh = _am
	if material_override == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.86, 0.47, 0.45)
		m.roughness = 0.32
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_override = m
	for i in N - 1:
		for k in SIDES:
			var a := i * (SIDES + 1) + k
			var b := a + SIDES + 1
			_idx.append_array([a, b, b + 1, a, b + 1, a + 1])


func use_organ_material(mat: ShaderMaterial) -> void:
	material_override = mat
	_mat_is_organ = mat != null


func uses_organ_material() -> bool:
	return _mat_is_organ


func point_count() -> int:
	return _p.size()


func points() -> PackedVector3Array:
	return _p


func segment_rest() -> float:
	return fed_len / float(N - 1)


func _reset_chain() -> void:
	_p.resize(N)
	_q.resize(N)
	var mid := (anchor_a + anchor_b) * 0.5
	for i in N:
		var t := float(i) / float(N - 1)
		var bulge := sin(PI * t) * fed_len * 0.3
		_p[i] = anchor_a.lerp(anchor_b, t) + out_dir * bulge
		_q[i] = _p[i]
	_prev_mid = mid
	_prev_vel = Vector3.ZERO
	_inited = true


func step(dt: float) -> void:
	if dt <= 0.0:
		return
	dt = minf(dt, 1.0 / 30.0)
	if not _inited:
		_reset_chain()
	var mid := (anchor_a + anchor_b) * 0.5
	var vel := (mid - _prev_mid) / dt
	var acc := (vel - _prev_vel) / dt
	_prev_mid = mid
	_prev_vel = vel
	if acc.length() > 400.0:  # 传送 / 换姿势：不当成甩动
		acc = Vector3.ZERO
		_reset_chain()
	var gd := GRAVITY.normalized().dot(out_dir)
	var pull_out := maxf(gd, 0.0) * 0.6 + (1.0 - absf(gd)) * 0.15 + minf(acc.length() * FEED_ACCEL_K, 1.0)
	fed_len = minf(max_len, fed_len + FEED_RATE * pull_out * dt)
	var rest := segment_rest()
	var mes_len := 0.03 + fed_len * 0.25
	for i in range(1, N - 1):
		var cur := _p[i]
		var v := (cur - _q[i]) * DAMP
		_q[i] = cur
		_p[i] = cur + v + GRAVITY * dt * dt
	_p[0] = anchor_a
	_q[0] = anchor_a
	_p[N - 1] = anchor_b
	_q[N - 1] = anchor_b
	var inv := ab_frame.affine_inverse()
	capsule_pushes = 0
	for _it in ITER:
		for i in N - 1:
			var a := _p[i]
			var b := _p[i + 1]
			var d := b - a
			var l := d.length()
			if l < 1e-7:
				continue
			var corr := d * ((l - rest) / l)
			var wa := 0.0 if i == 0 else 0.5
			var wb := 0.0 if i + 1 == N - 1 else 0.5
			var ws := wa + wb
			if ws <= 0.0:
				continue
			_p[i] = a + corr * (wa / ws)
			_p[i + 1] = b - corr * (wb / ws)
		# 系膜：软弹簧拉回腹腔深处（超出松弛长度才拉）
		for im in range(MES_EVERY, N - 1, MES_EVERY):
			var dm := _p[im] - mes_root
			var lm := dm.length()
			if lm > mes_len:
				_p[im] -= dm / lm * (lm - mes_len) * MES_K
		for i2 in range(1, N - 1):
			var p := _p[i2]
			# 腹部椭球：离锚点 3 个质点以外不能钻回肚皮里（锚点附近本来就在腹腔里）。
			if i2 >= 3 and i2 <= N - 4:
				var l2 := inv * p
				var qn := (l2 - ell_c) / ell_r
				var r := qn.length()
				if r < 1.0 and r > 1e-5:
					p = ab_frame * (ell_c + qn / r * ell_r)
			# 四肢精细胶囊
			for cap in capsules:
				var ca: Vector3 = cap[0]
				var cb: Vector3 = cap[1]
				var cr: float = float(cap[2]) + RADIUS
				var ab := cb - ca
				var t := clampf((p - ca).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
				var cpt := ca + ab * t
				var dv := p - cpt
				var dl := dv.length()
				if dl < cr:
					p = cpt + (dv / dl if dl > 1e-6 else Vector3.UP) * cr
					capsule_pushes += 1
			if p.y < floor_y + RADIUS:
				p.y = floor_y + RADIUS
			_p[i2] = p
	_build_mesh()


func _build_mesh() -> void:
	_am.clear_surfaces()
	if _p.size() < 2:
		return
	var nv := N * (SIDES + 1)
	var verts := PackedVector3Array()
	var nrms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cust := PackedFloat32Array()
	verts.resize(nv)
	nrms.resize(nv)
	uvs.resize(nv)
	cust.resize(nv * 4)
	var prev_n := Vector3.ZERO
	var s := 0.0
	for i in N:
		if i > 0:
			s += _p[i].distance_to(_p[i - 1])
		var t := (_p[mini(i + 1, N - 1)] - _p[maxi(i - 1, 0)])
		if t.length_squared() < 1e-12:
			t = Vector3.UP
		t = t.normalized()
		var nref := prev_n if prev_n != Vector3.ZERO else (Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT)
		var n := (nref - t * nref.dot(t))
		if n.length_squared() < 1e-10:
			n = t.cross(Vector3.RIGHT)
		n = n.normalized()
		prev_n = n
		var bn := t.cross(n)
		var u := float(i) / float(N - 1)
		var rad := RADIUS * (0.6 + 0.4 * minf(1.0, sin(PI * u) * 3.0))
		for k in SIDES + 1:
			var ang := TAU * float(k) / float(SIDES)
			var dir := n * cos(ang) + bn * sin(ang)
			var vi := i * (SIDES + 1) + k
			verts[vi] = _p[i] + dir * rad
			nrms[vi] = dir
			uvs[vi] = Vector2(s / UV_REPEAT, float(k) / float(SIDES))
			# CUSTOM0 = (沿管坐标, 径向 × 半径)：organ.gdshader 的蠕动按它收缩管径
			cust[vi * 4] = s / ALONG_UNIT
			cust[vi * 4 + 1] = dir.x * rad
			cust[vi * 4 + 2] = dir.y * rad
			cust[vi * 4 + 3] = dir.z * rad
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nrms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = cust
	arrays[Mesh.ARRAY_INDEX] = _idx
	var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)


func hang_depth() -> float:
	var mid := (anchor_a + anchor_b) * 0.5
	var lo := 0.0
	for p in _p:
		lo = maxf(lo, mid.y - p.y)
	return lo


## 测试：链条上离最近胶囊表面的最小距离（负 = 穿入）。
func min_capsule_clearance() -> float:
	var best := 1e9
	for p in _p:
		for cap in capsules:
			var ca: Vector3 = cap[0]
			var cb: Vector3 = cap[1]
			var ab := cb - ca
			var t := clampf((p - ca).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			best = minf(best, p.distance_to(ca + ab * t) - float(cap[2]) - RADIUS)
	return best
