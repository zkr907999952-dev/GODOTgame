extends MeshInstance3D
## 0.4.03：用手术钳从开放创口里扯出来的一段小肠袢（Verlet 链条）。
## - 两端锚点在腹腔内（被夹住处附近的体内肠管），由 SurgerySystem 每帧按蒙皮 / 软体重算。
## - 每端前 K_IN 个质点钉在「锚点 → 创口出口」的线段上：肠子先从创口里出来、搭过创缘，再往外垂，不穿腹壁。
## - 出口之外的质点：与腹部皮肤（创口周围外皮顶点采样，带法线）碰撞，只能在皮肤外面；四肢胶囊、床 / 地面碰撞。
## - 长度 = 被扯出的长度，按 SEG 一节一节地增加质点；每 MES_EVERY 节一根高弹性系膜弹簧（数量与节数成正比）。
## - 0.4.04：系膜拉向「创口周围」的锚点（mes_anchors，创缘内侧一圈），肠袢挂在腹部周围而不是全垂下去；
##   肠管之间球-球碰撞（同一根相隔 >2 节、以及不同肠袢之间），碰撞半径随蠕动收缩/鼓起变化。
## - 材质：小肠 organ 材质（无缝平铺贴图），CUSTOM0 = 沿管坐标 + 径向，与体内同一蠕动时钟。

const SIDES := 10
const RADIUS := 0.0105
const ITER := 6
const GRAVITY := Vector3(0, -9.8, 0)
const DAMP := 0.985
const SEG := 0.022            # 一节的长度
const MIN_PTS := 7
const MAX_PTS := 64
const K_IN := 2               # 每端钉在创口通道里的质点数
const MES_EVERY := 3          # 每 3 节一根系膜
const MES_K := 0.05           # 系膜弹簧每次迭代校正比例（越小越软）
const ALONG_UNIT := 0.5
const SKIN_CELL := 0.02
## 0.4.04：体外蠕动增强——CUSTOM0 径向 ×PERI_GAIN，管径静止时鼓 PERI_BULGE（收缩波过处更细）。
const PERI_GAIN := 2.0
const PERI_BULGE := 0.25
const GUT_CELL := 0.03
const SELF_GAP := 2           # 同一根肠子相隔多于 2 个质点才互相碰撞

var anchor_a: Vector3 = Vector3.ZERO
var anchor_b: Vector3 = Vector3.ZERO
var exit_a: Vector3 = Vector3.ZERO
var exit_b: Vector3 = Vector3.ZERO
var mes_root: Vector3 = Vector3.ZERO
var fed_len: float = 0.06
var max_len: float = 0.9
var floor_y: float = -1e9
var capsules: Array = []
## 皮肤采样（世界坐标）
var skin_p: PackedVector3Array = PackedVector3Array()
var skin_n: PackedVector3Array = PackedVector3Array()
## 被钳子夹住的质点（-1 = 没夹）与目标位置
var hold_index: int = -1
var hold_pos: Vector3 = Vector3.ZERO

var _p: PackedVector3Array = PackedVector3Array()
var _q: PackedVector3Array = PackedVector3Array()
var _am: ArrayMesh
var _inited := false
var _grow_side := 0
var _mat_is_organ := false
var _grid: Dictionary = {}
var capsule_pushes: int = 0
var skin_pushes: int = 0
var mesentery_count: int = 0
## 0.4.04：系膜锚点（世界坐标，创口周围、略向腹腔内）；空则退回 mes_root。
var mes_anchors: PackedVector3Array = PackedVector3Array()
## 其它肠袢：[[points, radii], ...]（上一帧的位置）
var others: Array = []
var gut_pushes: int = 0
var _rad: PackedFloat32Array = PackedFloat32Array()
var _kk: PackedFloat32Array = PackedFloat32Array()
var _mes_ai: Dictionary = {}


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
	return fed_len / float(maxi(_p.size() - 1, 1))


func outside_range() -> Vector2i:
	return Vector2i(K_IN + 1, _p.size() - 2 - K_IN)


func _want_pts() -> int:
	return clampi(int(ceil(fed_len / SEG)) + 1, MIN_PTS, MAX_PTS)


func _init_chain() -> void:
	var n := _want_pts()
	_p.resize(n)
	_q.resize(n)
	var mid := (exit_a + exit_b) * 0.5
	for i in n:
		var t := float(i) / float(n - 1)
		var p: Vector3
		if t < 0.5:
			p = anchor_a.lerp(mid, t * 2.0)
		else:
			p = mid.lerp(anchor_b, t * 2.0 - 1.0)
		_p[i] = p
		_q[i] = p
	_inited = true


## 被扯出更多：在两侧出口处交替插入新的一节（肠子从创口里一节节被拉出来）。
func _grow() -> void:
	var want := _want_pts()
	while _p.size() < want:
		var side := _grow_side
		var n := _p.size()
		var at := K_IN + 1 if side == 0 else n - 1 - K_IN
		at = clampi(at, 1, n - 1)
		var src: Vector3 = (_p[at - 1] + _p[at]) * 0.5
		_p.insert(at, src)
		_q.insert(at, src)
		_mes_ai.clear()
		if hold_index >= at:
			hold_index += 1
		_grow_side = 1 - side


func step(dt: float) -> void:
	if dt <= 0.0:
		return
	dt = minf(dt, 1.0 / 30.0)
	if not _inited:
		_init_chain()
	fed_len = minf(fed_len, max_len)
	_grow()
	var n := _p.size()
	var rest := fed_len / float(n - 1)
	_build_grid()
	for i in range(1, n - 1):
		var cur := _p[i]
		var v := (cur - _q[i]) * DAMP
		_q[i] = cur
		_p[i] = cur + v + GRAVITY * dt * dt
	var mes_len := mesentery_length()
	_update_radii()
	capsule_pushes = 0
	skin_pushes = 0
	mesentery_count = 0
	for _it in ITER:
		_pin_channel()
		if hold_index > 0 and hold_index < n - 1:
			_p[hold_index] = hold_pos
		for i in n - 1:
			var a := _p[i]
			var b := _p[i + 1]
			var d := b - a
			var l := d.length()
			if l < 1e-7:
				continue
			var corr := d * ((l - rest) / l)
			var wa := 0.0 if _fixed(i) else 0.5
			var wb := 0.0 if _fixed(i + 1) else 0.5
			var ws := wa + wb
			if ws <= 0.0:
				continue
			_p[i] = a + corr * (wa / ws)
			_p[i + 1] = b - corr * (wb / ws)
		var cnt := 0
		for im in range(K_IN + MES_EVERY, n - 1 - K_IN, MES_EVERY):
			cnt += 1
			if _fixed(im):
				continue
			var root := mesentery_anchor(im)
			var dm := _p[im] - root
			var lm := dm.length()
			if lm > mes_len:
				_p[im] -= dm / lm * (lm - mes_len) * MES_K
		mesentery_count = cnt
		_collide_guts()
		if _it % 2 == 1:
			_collide()
	_pin_channel()
	if hold_index > 0 and hold_index < n - 1:
		_p[hold_index] = hold_pos
	_build_mesh()


## 系膜松弛长度：随扯出长度增加，但封顶——肠袢挂在创口周围。
func mesentery_length() -> float:
	return minf(0.03 + fed_len * 0.14, 0.11)


## 第 im 个质点的系膜锚点：创缘锚点里离它最近的那个（粘住不跳：第一次分配后保持，除非锚点数变化）。
func mesentery_anchor(im: int) -> Vector3:
	if mes_anchors.is_empty():
		return mes_root
	var ai: int = int(_mes_ai.get(im, -1))
	if ai < 0 or ai >= mes_anchors.size() or int(_mes_ai.get(-1, -1)) != mes_anchors.size():
		if int(_mes_ai.get(-1, -1)) != mes_anchors.size():
			_mes_ai.clear()
			_mes_ai[-1] = mes_anchors.size()
		var bd := 1e9
		ai = 0
		for j in mes_anchors.size():
			var d := _p[im].distance_squared_to(mes_anchors[j])
			if d < bd:
				bd = d
				ai = j
		_mes_ai[im] = ai
	return mes_anchors[ai]


## 每个质点的蠕动收缩量（与 organ.gdshader 的 pulse() 同一公式）和对应的碰撞半径。
func _update_radii() -> void:
	var n := _p.size()
	_rad.resize(n)
	_kk.resize(n)
	var amp := 0.3
	var on := 1.0
	var waves := 1.55
	var clk := Vector3.ZERO
	var segk := 1.0
	var sm := material_override as ShaderMaterial
	if sm:
		var v = sm.get_shader_parameter("peri_amp")
		if v != null: amp = float(v)
		v = sm.get_shader_parameter("peri_on")
		if v != null: on = float(v)
		v = sm.get_shader_parameter("peri_waves")
		if v != null: waves = float(v)
		v = sm.get_shader_parameter("peri_clock")
		if v != null: clk = v
		v = sm.get_shader_parameter("peri_seg")
		if v != null: segk = float(v)
	var s := 0.0
	for i in n:
		if i > 0:
			s += _p[i].distance_to(_p[i - 1])
		var k := pulse(s / ALONG_UNIT, clk, amp, waves, segk) * on if _mat_is_organ else 0.0
		_kk[i] = k
		_rad[i] = _base_rad(i, n) * maxf(0.15, 1.0 + PERI_BULGE - PERI_GAIN * k)


func _base_rad(i: int, n: int) -> float:
	var u := float(i) / float(maxi(n - 1, 1))
	return RADIUS * (0.75 + 0.25 * minf(1.0, sin(PI * u) * 4.0))


static func _lobe(frac: float, width: float) -> float:
	var d := minf(frac, 1.0 - frac)
	var t := 1.0 - minf(1.0, d / maxf(1e-4, width))
	return t * t * (3.0 - 2.0 * t)


static func pulse(along: float, clk: Vector3, amp: float, waves: float, segk: float) -> float:
	var n := maxf(0.2, waves)
	var p := fposmod(along * n - clk.x * n, 1.0)
	var perist := _lobe(p, 0.34)
	var p2 := fposmod(along * 0.85 - clk.x * 0.55, 1.0)
	var perist2 := _lobe(p2, 0.42)
	var haustra := 0.5 + 0.5 * sin(along * 12.0 * PI - clk.y)
	var mixv := 0.5 + 0.5 * sin(along * 7.0 * PI + clk.z)
	var hs := haustra * haustra * (3.0 - 2.0 * haustra)
	var ms := mixv * mixv * (3.0 - 2.0 * mixv)
	var seg := hs * 0.45 + ms * 0.25
	var shape := perist * 0.62 + perist2 * 0.28 + seg * 0.18 * segk
	return shape * (0.16 + amp * 0.42)


func radius_at(i: int) -> float:
	return _rad[i] if i >= 0 and i < _rad.size() else RADIUS


func radii() -> PackedFloat32Array:
	return _rad


## 肠管之间的球-球碰撞：同一根（相隔 > SELF_GAP）互推各一半；与其它肠袢只推自己（对方各自步进时推它自己）。
func _collide_guts() -> void:
	var n := _p.size()
	if _rad.size() != n:
		return
	var grid := {}
	for i in n:
		var c := Vector3i(floori(_p[i].x / GUT_CELL), floori(_p[i].y / GUT_CELL), floori(_p[i].z / GUT_CELL))
		if grid.has(c):
			(grid[c] as Array).append(i)
		else:
			grid[c] = [i]
	for i in n:
		var c0 := Vector3i(floori(_p[i].x / GUT_CELL), floori(_p[i].y / GUT_CELL), floori(_p[i].z / GUT_CELL))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var arr = grid.get(c0 + Vector3i(dx, dy, dz))
					if arr == null:
						continue
					for j in arr:
						if j <= i + SELF_GAP:
							continue
						var d := _p[j] - _p[i]
						var l := d.length()
						var rr := _rad[i] + _rad[j]
						if l >= rr:
							continue
						var dirv := d / l if l > 1e-6 else Vector3.UP
						var wi := 0.0 if _fixed(i) else 1.0
						var wj := 0.0 if _fixed(j) else 1.0
						if wi + wj <= 0.0:
							continue
						var corr := dirv * (rr - l)
						_p[i] -= corr * (wi / (wi + wj))
						_p[j] += corr * (wj / (wi + wj))
						gut_pushes += 1
	for o in others:
		var op: PackedVector3Array = o[0]
		var orr: PackedFloat32Array = o[1]
		for j in op.size():
			var q := op[j]
			var rj: float = orr[j] if j < orr.size() else RADIUS
			for i in n:
				if _fixed(i):
					continue
				var d := _p[i] - q
				var rr := _rad[i] + rj
				if absf(d.x) >= rr or absf(d.y) >= rr or absf(d.z) >= rr:
					continue
				var l := d.length()
				if l >= rr:
					continue
				_p[i] += (d / l if l > 1e-6 else Vector3.UP) * (rr - l)
				gut_pushes += 1


## 不相邻质点之间的最小「表面间距」（负 = 重叠）；含其它肠袢。
func min_gut_clearance() -> float:
	# 只算创口外的质点（通道里钉住的质点在腹腔内，两段肠袢共用同一个创口）。
	var best := 1e9
	var n := _p.size()
	for i in n:
		if _fixed(i):
			continue
		for j in range(i + SELF_GAP + 1, n):
			if _fixed(j):
				continue
			best = minf(best, _p[i].distance_to(_p[j]) - radius_at(i) - radius_at(j))
		for o in others:
			var op: PackedVector3Array = o[0]
			var orr: PackedFloat32Array = o[1]
			for j in range(K_IN + 1, op.size() - K_IN - 1):
				best = minf(best, _p[i].distance_to(op[j]) - radius_at(i) - (orr[j] if j < orr.size() else RADIUS))
	return best


func _fixed(i: int) -> bool:
	var n := _p.size()
	return i <= K_IN or i >= n - 1 - K_IN or i == hold_index


func _pin_channel() -> void:
	var n := _p.size()
	for k in K_IN + 1:
		var t := float(k) / float(K_IN)
		_p[k] = anchor_a.lerp(exit_a, t)
		_p[n - 1 - k] = anchor_b.lerp(exit_b, t)
		_q[k] = _p[k]
		_q[n - 1 - k] = _p[n - 1 - k]


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / SKIN_CELL), floori(p.y / SKIN_CELL), floori(p.z / SKIN_CELL))


func _build_grid() -> void:
	_grid.clear()
	for i in skin_p.size():
		var c := _cell(skin_p[i])
		if _grid.has(c):
			(_grid[c] as PackedInt32Array).append(i)
		else:
			_grid[c] = PackedInt32Array([i])


## 皮肤外侧高度（< RADIUS 表示贴着或在皮肤里面），返回 [h, n]。
func _skin_h(p: Vector3) -> Array:
	var c0 := _cell(p)
	var best := 1e9
	var bi := -1
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var arr = _grid.get(c0 + Vector3i(dx, dy, dz))
				if arr == null:
					continue
				for i in arr:
					var d := p.distance_squared_to(skin_p[i])
					if d < best:
						best = d
						bi = i
	if bi < 0:
		return [1e9, Vector3.UP]
	var nn: Vector3 = skin_n[bi]
	return [(p - skin_p[bi]).dot(nn), nn]


func _collide() -> void:
	var n := _p.size()
	for i in range(1, n - 1):
		if _fixed(i):
			continue
		var p := _p[i]
		var ri := radius_at(i)
		var sh := _skin_h(p)
		var h: float = sh[0]
		# 只处理皮肤附近（内侧 4cm 以内），更深的点说明离开了采样区域
		if h < ri and h > -0.04:
			p += (sh[1] as Vector3) * (ri - h)
			skin_pushes += 1
		for cap in capsules:
			var ca: Vector3 = cap[0]
			var cb: Vector3 = cap[1]
			var cr: float = float(cap[2]) + ri
			var ab := cb - ca
			var t := clampf((p - ca).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			var cpt := ca + ab * t
			var dv := p - cpt
			var dl := dv.length()
			if dl < cr:
				p = cpt + (dv / dl if dl > 1e-6 else Vector3.UP) * cr
				capsule_pushes += 1
		if p.y < floor_y + ri:
			p.y = floor_y + ri
		_p[i] = p


func _build_mesh() -> void:
	_am.clear_surfaces()
	var n := _p.size()
	if n < 2:
		return
	var nv := n * (SIDES + 1)
	var verts := PackedVector3Array()
	var nrms := PackedVector3Array()
	var tans := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var cust := PackedFloat32Array()
	verts.resize(nv)
	nrms.resize(nv)
	tans.resize(nv * 4)
	uvs.resize(nv)
	cust.resize(nv * 4)
	var prev_n := Vector3.ZERO
	var s := 0.0
	var circ := TAU * RADIUS
	for i in n:
		if i > 0:
			s += _p[i].distance_to(_p[i - 1])
		var t := (_p[mini(i + 1, n - 1)] - _p[maxi(i - 1, 0)])
		if t.length_squared() < 1e-12:
			t = Vector3.UP
		t = t.normalized()
		var nref := prev_n if prev_n != Vector3.ZERO else (Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT)
		var nn := (nref - t * nref.dot(t))
		if nn.length_squared() < 1e-10:
			nn = t.cross(Vector3.RIGHT)
		nn = nn.normalized()
		prev_n = nn
		var bn := t.cross(nn)
		var u := float(i) / float(n - 1)
		var rad := RADIUS * (0.75 + 0.25 * minf(1.0, sin(PI * u) * 4.0))
		var rad_v := rad * (1.0 + PERI_BULGE) if _mat_is_organ else rad
		var rad_c := rad * PERI_GAIN
		for k in SIDES + 1:
			var ang := TAU * float(k) / float(SIDES)
			var dir := nn * cos(ang) + bn * sin(ang)
			var vi := i * (SIDES + 1) + k
			verts[vi] = _p[i] + dir * rad_v
			nrms[vi] = dir
			tans[vi * 4] = t.x
			tans[vi * 4 + 1] = t.y
			tans[vi * 4 + 2] = t.z
			tans[vi * 4 + 3] = 1.0
			# 无缝平铺：绕管一周 = 贴图 1 个周期；沿管按周长等比例（方形纹素），连续弧长。
			uvs[vi] = Vector2(s / circ, float(k) / float(SIDES))
			cust[vi * 4] = s / ALONG_UNIT
			cust[vi * 4 + 1] = dir.x * rad_c
			cust[vi * 4 + 2] = dir.y * rad_c
			cust[vi * 4 + 3] = dir.z * rad_c
	var idx := PackedInt32Array()
	for i in n - 1:
		for k in SIDES:
			var a := i * (SIDES + 1) + k
			var b := a + SIDES + 1
			idx.append_array([a, b, b + 1, a, b + 1, a + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nrms
	arrays[Mesh.ARRAY_TANGENT] = tans
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = cust
	arrays[Mesh.ARRAY_INDEX] = idx
	var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)


func hang_depth() -> float:
	var mid := (anchor_a + anchor_b) * 0.5
	var lo := 0.0
	for p in _p:
		lo = maxf(lo, mid.y - p.y)
	return lo


## 离皮肤外表面最小高度（只算出口以外的质点；负 = 穿进腹壁）。
func min_skin_clearance() -> float:
	_build_grid()
	var best := 1e9
	var r := outside_range()
	for i in range(r.x, r.y + 1):
		var sh := _skin_h(_p[i])
		var h: float = sh[0]
		if h > -0.04:
			best = minf(best, h - radius_at(i))
	return best


func min_capsule_clearance() -> float:
	var best := 1e9
	for i in _p.size():
		var p := _p[i]
		for cap in capsules:
			var ca: Vector3 = cap[0]
			var cb: Vector3 = cap[1]
			var ab := cb - ca
			var t := clampf((p - ca).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			best = minf(best, p.distance_to(ca + ab * t) - float(cap[2]) - radius_at(i))
	return best


## 射线最近的质点（夹取已扯出的肠袢），返回 [index, dist]。
func ray_pick(origin: Vector3, dir: Vector3) -> Array:
	var d := dir.normalized()
	var best := 1e9
	var bi := -1
	var r := outside_range()
	for i in range(maxi(r.x, 1), mini(r.y, _p.size() - 2) + 1):
		var w := _p[i] - origin
		var t := w.dot(d)
		if t <= 0.0:
			continue
		var dist := (w - d * t).length()
		if dist < best:
			best = dist
			bi = i
	return [bi, best]
