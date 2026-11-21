extends MeshInstance3D
## 0.4.01：从创口掉出来的肠子——两端钉在创口内缘的长链条（Verlet 绳），像布娃娃一样随身体移动甩动。
## 不是一整块刚体：N 个质点 + 距离约束 + 腹部椭球碰撞，每帧用管状网格（ImmediateMesh）蒙上。
## 能掉出来的长度随创口大小变化（SurgerySystem 给 max_len），身体加速 / 重力朝外时逐渐往外滑。
## 手机友好：默认 18 个质点、8 边管，约 290 个三角，每帧 4 次约束迭代。

const N := 18
const SIDES := 8
const RADIUS := 0.0105
const ITER := 4
const GRAVITY := Vector3(0, -9.8, 0)
const DAMP := 0.985
const FEED_RATE := 0.35       # m/s：受到甩动 / 重力外拉时往外滑的最大速度
const FEED_ACCEL_K := 0.045   # 每 m/s² 的身体加速度带出的滑出速度
const START_LEN := 0.05       # 一开始鼓出来的一小段

var anchor_a: Vector3 = Vector3.ZERO   # 世界坐标：创口一侧
var anchor_b: Vector3 = Vector3.ZERO   # 世界坐标：创口另一侧
var out_dir: Vector3 = Vector3.FORWARD # 世界坐标：创口外法线
var max_len: float = 0.2               # 允许掉出的总长（创口越大越长）
var fed_len: float = START_LEN         # 当前掉出的长度
## 碰撞：腹部椭球（腹局部空间）+ 世界↔腹局部变换，由 SurgerySystem 每帧给
var ab_frame: Transform3D = Transform3D.IDENTITY
var ell_c: Vector3 = Vector3.ZERO
var ell_r: Vector3 = Vector3(0.12, 0.2, 0.08)

var _p: PackedVector3Array = PackedVector3Array()
var _q: PackedVector3Array = PackedVector3Array()
var _im: ImmediateMesh
var _prev_mid: Vector3 = Vector3.ZERO
var _prev_vel: Vector3 = Vector3.ZERO
var _inited := false


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_im = ImmediateMesh.new()
	mesh = _im
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.47, 0.45)
	m.roughness = 0.32
	m.metallic_specular = 0.6
	m.rim_enabled = true
	m.rim = 0.25
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = m


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
	# 身体运动：创口中点的加速度带动肠子往外滑；重力朝外（创口朝下 / 侧）也会往外拉。
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
	# Verlet 积分（端点钉住）
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
		# 腹部椭球碰撞：离创口两端两个质点以外不能钻回肚子里。
		for i2 in range(2, N - 2):
			var l2 := inv * _p[i2]
			var qn := (l2 - ell_c) / ell_r
			var r := qn.length()
			if r < 1.0 and r > 1e-5:
				l2 = ell_c + qn / r * ell_r * 1.0
				_p[i2] = ab_frame * l2
	_build_mesh()


func _build_mesh() -> void:
	_im.clear_surfaces()
	if _p.size() < 2:
		return
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	var prev_n := Vector3.ZERO
	for i in N:
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
		# 两端在创口里收细，中段有轻微的肠段鼓包
		var u := float(i) / float(N - 1)
		var rad := RADIUS * (0.55 + 0.45 * minf(1.0, sin(PI * u) * 3.0)) * (1.0 + 0.12 * sin(float(i) * 2.1))
		var ring: Array = []
		for k in SIDES:
			var ang := TAU * float(k) / float(SIDES)
			var dir := n * cos(ang) + bn * sin(ang)
			ring.append([_p[i] + dir * rad, dir])
		rings.append(ring)
	for i in N - 1:
		var r0: Array = rings[i]
		var r1: Array = rings[i + 1]
		for k in SIDES:
			var k1 := (k + 1) % SIDES
			_vtx(r0[k]); _vtx(r1[k]); _vtx(r1[k1])
			_vtx(r0[k]); _vtx(r1[k1]); _vtx(r0[k1])
	_im.surface_end()


func _vtx(pd: Array) -> void:
	_im.surface_set_normal(pd[1])
	_im.surface_add_vertex(pd[0])


func hang_depth() -> float:
	## 测试：最低点比创口中点低多少（米）。
	var mid := (anchor_a + anchor_b) * 0.5
	var lo := 0.0
	for p in _p:
		lo = maxf(lo, mid.y - p.y)
	return lo
