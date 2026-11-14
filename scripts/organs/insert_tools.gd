extends RefCounted
## 拳交 / 刺刀 / 长刺刀（移植自网页 rouchangmoniqi3 src/lib/softbody/fist-play.ts + bayonet-play.ts）。
##
## 所有坐标都在 organ_rig 的「腹部局部坐标系」(ab-local：原点 = 肚脐，轴 = C_Spine_a 右/上/前)，
## 与网页的「静止姿态身体坐标 − 肚脐」一致，所以网页里的常数（米）可以直接用。
## 形变全部交给 GPU：organ_rig 把这里算出的「杆」(rod)、皮肤鼓包、刺入前压陷、肠道伤痕点
## 写进 organ_common / skin_common 的 uniform。道具网格（手臂 / 刺刀）只是普通网格，
## 在体外被皮肤挡住，透视窗口里能看到插入的部分。


# ---------------------------------------------------------------- 拳交（FistPlay）
const FIST_MIN_PITCH := 0.3
const FIST_MAX_PITCH := 1.22
const ARM_LEN := 0.38

# ---------------------------------------------------------------- 刺刀（BayonetPlay）
const SHORT_TOTAL := 0.248
const LONG_TOTAL := 0.42
const HOVER := 0.075
const SQUEEZE_MAX := 0.013
const BLADE_RAD := 0.016
const HIT_EVERY := 0.2
const MAX_CONE := deg_to_rad(30.0)
const MAX_WOUNDS := 10
const MAX_DMG := 12

# 网页 studio-store 默认参数（HUD 可调）
var fist_bulge: float = 1.4
var fist_spread: float = 1.0
var fist_gut: float = 1.0
var fist_lever: float = 1.0
var fist_max_depth: float = 1.0
var fist_rise: float = 0.7
var fist_thrust: bool = false
var fist_stir: bool = false
var fist_thrust_speed: float = 0.45
var fist_thrust_start: float = 0.025
var fist_stir_speed: float = 0.55
var fist_stir_radius: float = 0.4

var bayonet_kind: String = "short"  # short | long
var bayonet_auto: bool = false
var bayonet_pump: bool = false

# --- 拳交状态
var fist_enabled: bool = false
var fist_depth: float = 0.018
var fist_dir: Vector3 = Vector3(0, 0.85, 0.5).normalized()
var fist_entry: Vector3 = Vector3(0, 0.82, 0.47).normalized()
var fist_tip: Vector3 = Vector3.ZERO
var fist_arousal: float = 0.0
var anus: Vector3 = Vector3(0.0, -0.163, -0.104)
var _base_dir: Vector3 = Vector3(0, 0.85, 0.5).normalized()
var _base_depth: float = 0.018
var _thrust_phase: float = 0.0
var _stir_phase: float = 0.0
var _y_min: float = -0.15
var _y_max: float = 0.108
var _max_scale: float = 1.0
var _wall_z: float = -0.004
var _slices: Array = []  # [[y, half_x], ...] ab-local

# --- 刺刀状态
var blade_enabled: bool = false
var has_entry: bool = false
var punctured: bool = false
var penetration: float = 0.0
var raw_pen: float = -HOVER
var total_len: float = SHORT_TOTAL
var blade_len: float = SHORT_TOTAL * 0.6
var max_pen: float = SHORT_TOTAL * 0.6 * 0.97
var entry: Vector3 = Vector3.ZERO
var entry_normal: Vector3 = Vector3(0, 0, 1)
var rest_axis: Vector3 = Vector3(0, 0, -1)
var handle: Vector3 = Vector3.ZERO
var blade_dir: Vector3 = Vector3(0, 0, -1)
var _auto_phase: String = "idle"  # idle | in | hold | out
var _hold_t: float = 0.0
var _pump_t: float = 0.0
var _hit_acc: float = 0.0
var _back_spawned: bool = false
var _exit: Variant = null  # {p, n, dist}
var puncture_event: bool = false
var auto_released: bool = false

## 伤口：{p: ab-local, n: ab-local 法线, w, h, tile, twist}
var wounds: Array = []
## 肠道伤痕（网页 GutHealth：被刺中的肠段发红）：Vector4(xyz ab-local, 程度 0..1)
var damage: Array = []

var _profile_fn: Callable  # y_rel → Vector3(half_x, z_front, z_back)


func setup(anus_l: Vector3, colon_end_l: Variant, slices: Array, profile_fn: Callable, y_min: float, y_max: float) -> void:
	_profile_fn = profile_fn
	_slices = slices
	_y_min = y_min
	_y_max = y_max
	if colon_end_l is Vector3 and ((colon_end_l as Vector3) - anus_l).length() > 1e-3:
		fist_entry = ((colon_end_l as Vector3) - anus_l).normalized()
	anus = anus_l + fist_entry * 0.01
	fist_reset()
	_set_kind_stats()


# ================================================================= 拳交
func fist_reset() -> void:
	fist_depth = 0.018
	fist_dir = fist_entry
	_base_dir = fist_entry
	_base_depth = 0.018
	_thrust_phase = 0.0
	_stir_phase = 0.0
	fist_arousal = 0.0
	fist_tip = anus + fist_dir * fist_depth


func set_fist_enabled(on: bool) -> void:
	if fist_enabled == on:
		return
	fist_enabled = on
	if not on:
		fist_reset()


func _reach() -> float:
	return ARM_LEN * 0.86 * _max_scale


func set_fist_max_scale(s: float) -> void:
	_max_scale = clampf(s, 0.5, 1.5)
	fist_depth = minf(fist_depth, _reach())
	_base_depth = minf(_base_depth, _reach())


## 网页 FistPlay.dragTo：to = 拖拽点（ab-local）
func fist_drag_to(to: Vector3) -> void:
	if not fist_enabled:
		return
	var v := to - anus
	var inward := v.dot(fist_entry)
	var length := v.length()
	if length < 1e-5:
		return
	if inward > 0.004:
		fist_dir = v.normalized()
		_clamp_pitch()
		fist_depth = clampf(length, 0.012, _reach())
	else:
		fist_depth = maxf(0.012, fist_depth + inward)
		var n := v - fist_entry * inward
		if n.length_squared() > 1e-8:
			fist_dir = (fist_dir + n.normalized() * 0.28).normalized()
			_clamp_pitch()
	_clamp_lateral()
	_base_dir = fist_dir
	_base_depth = fist_depth


## 直接设深度（0..1，HUD 滑条 / 自检）
func fist_set_depth01(t: float) -> void:
	fist_depth = clampf(0.012 + clampf(t, 0.0, 1.0) * (_reach() - 0.012), 0.012, _reach())
	_clamp_lateral()
	_base_dir = fist_dir
	_base_depth = fist_depth


func fist_depth01() -> float:
	return clampf((fist_depth - 0.012) / maxf(1e-4, _reach() - 0.012), 0.0, 1.0)


func _half_x_at(y: float) -> float:
	if _slices.is_empty():
		return 0.08
	if y <= float(_slices[0][0]):
		return float(_slices[0][1])
	for i in range(1, _slices.size()):
		var a: Array = _slices[i - 1]
		var b: Array = _slices[i]
		if y > float(b[0]):
			continue
		var t := (y - float(a[0])) / maxf(1e-5, float(b[0]) - float(a[0]))
		return lerpf(float(a[1]), float(b[1]), t)
	return float(_slices[_slices.size() - 1][1])


func _clamp_pitch() -> void:
	var pitch := atan2(maxf(0.0, fist_dir.z), maxf(0.04, fist_dir.y))
	var p := clampf(pitch, FIST_MIN_PITCH, FIST_MAX_PITCH)
	fist_dir = Vector3(fist_dir.x, cos(p), sin(p)).normalized()


func _clamp_lateral() -> void:
	_clamp_pitch()
	var fy := clampf(anus.y + fist_dir.y * fist_depth, _y_min, _y_max)
	var half := maxf(0.03, _half_x_at(fy) * 0.72)
	var fx := clampf(anus.x + fist_dir.x * fist_depth, -half, half)
	var fz := maxf(anus.z + 0.01, anus.z + fist_dir.z * fist_depth)
	var v := Vector3(fx - anus.x, fy - anus.y, fz - anus.z)
	var length := v.length()
	if length < 1e-5:
		return
	fist_dir = v.normalized()
	_clamp_pitch()
	fist_depth = clampf(length, 0.012, _reach())


func fist_step(dt: float) -> void:
	if not fist_enabled:
		fist_arousal += (0.0 - fist_arousal) * (1.0 - exp(-2.1 * dt))
		return
	fist_dir = _base_dir
	fist_depth = _base_depth
	if fist_thrust:
		_thrust_phase += dt * (0.35 + fist_thrust_speed * 1.7)
		var wave := 0.5 - 0.5 * cos(_thrust_phase)
		var start := clampf(fist_thrust_start, 0.012, maxf(0.014, _base_depth - 0.004))
		fist_depth = start + (_base_depth - start) * wave
	if fist_stir:
		_stir_phase += dt * (0.45 + fist_stir_speed * 2.5)
		var r := 0.005 + fist_stir_radius * 0.034
		var side := fist_dir.cross(Vector3.UP)
		if side.length_squared() < 1e-6:
			side = Vector3.RIGHT
		side = side.normalized()
		var bin := fist_dir.cross(side).normalized()
		var f := anus + fist_dir * fist_depth + (side * cos(_stir_phase) + bin * sin(_stir_phase)) * r
		var v := f - anus
		if v.length() > 1e-5:
			fist_dir = v.normalized()
			_clamp_pitch()
			fist_depth = clampf(v.length(), 0.012, _reach())
	var want := 0.0
	if fist_depth > 0.042:
		want = 0.48 + clampf((fist_depth - 0.042) / 0.2, 0.0, 1.0) * 0.4
		if fist_thrust:
			want = minf(1.0, want + 0.18)
		if fist_stir:
			want = minf(1.0, want + 0.32)
	var k := 2.6 if want > fist_arousal else 1.7
	fist_arousal += (want - fist_arousal) * (1.0 - exp(-k * dt))
	if not (fist_thrust or fist_stir):
		_clamp_lateral()
		_base_dir = fist_dir
		_base_depth = fist_depth
	# 网页 layoutArm：拳心 ≈ 前端往回 4.5cm
	fist_tip = anus + fist_dir * fist_depth - fist_dir * 0.045


## 网页 wallOver：拳头顶到前腹壁时的「超出量」→ 皮肤鼓包幅度
func fist_wall_over() -> float:
	var palm := maxf(0.01, fist_depth - 0.038)
	var fz := anus.z + fist_dir.z * palm
	var gap := _wall_z - fz
	var along := gap / maxf(0.18, fist_dir.z)
	return maxf(0.0, 0.058 - along)


## 皮肤鼓包参数：Vector4(tip.x, tip.y, over, 1) + Vector2(lean x, lean z)
func fist_bulge_params() -> Array:
	if not fist_enabled or fist_depth < 0.025:
		return [Vector4.ZERO, Vector2.ZERO]
	return [Vector4(fist_tip.x, fist_tip.y, fist_wall_over(), 1.0), Vector2(fist_dir.x - fist_entry.x, fist_dir.z - fist_entry.z)]


## 肠道「杆」：[anchor, dir, reach, radius, mix, s_min]（网页 deformColon）
func fist_rod() -> Array:
	if not fist_enabled or fist_depth < 0.02:
		return []
	return [anus, fist_dir, fist_depth, 0.018 * (0.55 + fist_gut * 0.7), 0.9 * clampf(fist_gut, 0.0, 2.0), 0.0]


## 手臂网格：前端（拳头）在 anus + dir·depth，手臂沿 -dir 伸出体外。
func fist_arm_xform() -> Transform3D:
	var tipp := anus + fist_dir * fist_depth
	return Transform3D(_basis_y_to(fist_dir), tipp)


# ================================================================= 刺刀
func _set_kind_stats() -> void:
	if bayonet_kind == "long":
		total_len = LONG_TOTAL
		blade_len = LONG_TOTAL * 0.75
	else:
		total_len = SHORT_TOTAL
		blade_len = SHORT_TOTAL * 0.6
	max_pen = blade_len * 0.97


func set_kind(kind: String) -> void:
	if kind != "long":
		kind = "short"
	if kind == bayonet_kind:
		return
	bayonet_kind = kind
	_set_kind_stats()
	if has_entry:
		raw_pen = clampf(raw_pen, -HOVER, max_pen)
		handle = entry - blade_dir * (total_len - raw_pen)
		_update_contact()


func set_blade_enabled(on: bool) -> void:
	blade_enabled = on
	if not on and has_entry:
		release_entry()


## 网页 BayonetPlay.pick：point / normal（ab-local，法线朝外）
func blade_pick(point: Vector3, normal: Vector3) -> void:
	has_entry = true
	punctured = false
	puncture_event = false
	penetration = 0.0
	raw_pen = -HOVER
	_hit_acc = 0.0
	_auto_phase = "idle"
	_hold_t = 0.0
	_pump_t = 0.0
	auto_released = false
	entry = point
	entry_normal = normal.normalized() if normal.length_squared() > 1e-6 else Vector3(0, 0, 1)
	rest_axis = -entry_normal
	blade_dir = rest_axis
	_back_spawned = false
	_exit = null
	handle = entry - blade_dir * (total_len - raw_pen)
	_update_contact()
	if bayonet_auto and not bayonet_pump:
		begin_auto()


func begin_auto() -> void:
	if not has_entry:
		return
	_auto_phase = "in"
	_hold_t = 0.0
	auto_released = false


func is_auto() -> bool:
	return _auto_phase != "idle"


func release_entry() -> void:
	has_entry = false
	punctured = false
	puncture_event = false
	penetration = 0.0
	raw_pen = -HOVER
	_hit_acc = 0.0
	_auto_phase = "idle"


## 网页 dragTo：to = 刀柄拖到的位置（ab-local）
func blade_drag_to(to: Vector3) -> void:
	if not blade_enabled or not has_entry:
		return
	_auto_phase = "idle"
	var v := entry - to
	var length := v.length()
	if length < 1e-5:
		return
	v = _clamp_cone(v.normalized(), rest_axis, MAX_CONE)
	blade_dir = v
	var intended := total_len - length
	if not punctured and intended >= SQUEEZE_MAX * 0.92:
		_puncture()
	var mp := max_pen if punctured else SQUEEZE_MAX
	var min_d := maxf(0.04, total_len - mp)
	var max_d := total_len + HOVER + 0.08
	handle = entry - blade_dir * clampf(length, min_d, max_d)
	_update_contact()


func pen01() -> float:
	return clampf((raw_pen + HOVER) / (max_pen + HOVER), 0.0, 1.0)


func set_pen01(t: float) -> void:
	if not has_entry:
		return
	raw_pen = -HOVER + clampf(t, 0.0, 1.0) * (max_pen + HOVER)
	handle = entry - blade_dir * (total_len - raw_pen)
	_update_contact()


func blade_step(dt: float, grabbing: bool, gut: float) -> void:
	if not blade_enabled:
		return
	if has_entry and not grabbing:
		if bayonet_pump:
			_auto_phase = "idle"
			_pump_t += dt * 2.35
			set_pen01(0.16 + 0.8 * (0.5 - 0.5 * cos(_pump_t)))
		elif _auto_phase == "in":
			var t := minf(1.0, pen01() + dt * 1.7)
			set_pen01(t)
			if t >= 0.94:
				_auto_phase = "hold"
				_hold_t = 0.0
		elif _auto_phase == "hold":
			_hold_t += dt
			if _hold_t > 0.16:
				_auto_phase = "out"
		elif _auto_phase == "out":
			var t2 := maxf(0.0, pen01() - dt * 1.5)
			set_pen01(t2)
			if t2 <= 0.02:
				release_entry()
				auto_released = true
	if not has_entry:
		return
	_update_contact()
	if punctured and penetration > 0.012:
		_hit_acc += dt
		if _hit_acc >= HIT_EVERY:
			_hit_acc = 0.0
			for i in range(1, 4):
				add_damage(entry + blade_dir * (penetration * float(i) / 3.2), 0.22 + penetration * 0.4)
	var _g := gut


func _update_contact() -> void:
	raw_pen = total_len - handle.distance_to(entry)
	if not punctured and raw_pen >= SQUEEZE_MAX * 0.92:
		_puncture()
	penetration = maxf(0.0, raw_pen) if punctured else 0.0
	if bayonet_kind == "long" and punctured and not _back_spawned:
		_try_exit_wound()


func _puncture() -> void:
	punctured = true
	puncture_event = true
	var long := bayonet_kind == "long"
	_add_wound(entry, entry_normal, 0.038 if long else 0.05, 0.054 if long else 0.082)
	for i in range(1, 6):
		add_damage(entry + blade_dir * (maxf(penetration, 0.03) * float(i) / 5.0), 0.38)


## 长刺刀刺穿：沿刀身方向在躯干截面轮廓里找背面 / 侧面出口（网页 findSkinExit 的射线版）。
func _try_exit_wound() -> void:
	if _exit == null:
		_exit = _find_exit()
		if _exit == null:
			_exit = {}
	var ex: Dictionary = _exit
	if ex.is_empty() or raw_pen < float(ex["dist"]) - 0.005:
		return
	_back_spawned = true
	_add_wound(ex["p"], ex["n"], 0.03, 0.042)


func _find_exit() -> Variant:
	if not _profile_fn.is_valid():
		return null
	var t := 0.07
	while t < 0.55:
		var q := entry + blade_dir * t
		var pr: Vector3 = _profile_fn.call(q.y)
		if q.z < pr.z:
			return {"p": Vector3(q.x, q.y, pr.z), "n": Vector3(0, 0, -1), "dist": t}
		if absf(q.x) > pr.x:
			return {"p": Vector3(signf(q.x) * pr.x, q.y, q.z), "n": Vector3(signf(q.x), 0, 0), "dist": t}
		t += 0.004
	return null


func _add_wound(p: Vector3, n: Vector3, w: float, h: float) -> void:
	wounds.append({"p": p, "n": n.normalized(), "w": w, "h": h, "tile": randi() % 4, "twist": randf_range(-0.25, 0.25), "dir": blade_dir})
	while wounds.size() > MAX_WOUNDS:
		wounds.pop_front()


## 网页 GutHealth.hit 的简化：附近已有伤痕就加深，否则新加一个点。
func add_damage(p: Vector3, amount: float) -> void:
	var dmg := 0.16 + amount * 0.48
	for i in damage.size():
		var d: Vector4 = damage[i]
		if Vector3(d.x, d.y, d.z).distance_to(p) < 0.03:
			damage[i] = Vector4(d.x, d.y, d.z, minf(1.0, d.w + dmg))
			return
	damage.append(Vector4(p.x, p.y, p.z, minf(1.0, dmg)))
	while damage.size() > MAX_DMG:
		damage.pop_front()


func clear_marks() -> void:
	wounds.clear()
	damage.clear()


## 刺入前压陷（网页 squeezeTarget → setTissueDrag）：[grab, target, radius] 或 []
func squeeze_target() -> Array:
	if not blade_enabled or not has_entry or raw_pen <= 0.0008:
		return []
	var depth := minf(0.018, 0.008 + penetration * 0.04) if punctured else minf(SQUEEZE_MAX, raw_pen)
	return [entry, entry + blade_dir * depth, 0.055 if punctured else 0.07]


func blade_rod(gut: float) -> Array:
	if not blade_enabled or not has_entry or not punctured or penetration <= 0.012:
		return []
	return [entry, blade_dir, penetration + 0.012, BLADE_RAD * (0.7 + gut * 0.55), 0.88 * clampf(gut, 0.2, 2.0), -0.012]


## 刀网格：原点 = 刀柄端，+Y = 刀尖方向；刃口朝下（网页 orientBladeDown）。
func blade_xform() -> Transform3D:
	var y := blade_dir
	var x := y.cross(Vector3.DOWN)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y).normalized()
	if z.y > 0.0:
		x = -x
		z = -z
	return Transform3D(Basis(x, y, z), handle)


func blade_tip() -> Vector3:
	return handle + blade_dir * total_len


# ================================================================= util
static func _basis_y_to(d: Vector3) -> Basis:
	var y := d.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


static func _clamp_cone(d: Vector3, axis: Vector3, max_ang: float) -> Vector3:
	var a := axis.normalized()
	var ang := acos(clampf(a.dot(d), -1.0, 1.0))
	if ang <= max_ang or ang < 1e-6:
		return d
	var n := a.cross(d)
	if n.length_squared() < 1e-10:
		return a
	return a.rotated(n.normalized(), max_ang)
