extends RefCounted
## 手术模式「阴道扩张器」：沿阴道轴闭合插入、滑条开合、柔体撑开阴道壁，
## 点击先闭合再取出；切换其它工具时保持开口与位姿，并跟随身体（含拖拽/布娃娃/检查床）。

const MeshFactory := preload("res://scripts/surgery/speculum_mesh.gd")

const MAX_ANGLE := 24.0
const INSERT_SEC := 0.55
const CLOSE_SEC := 0.32
const WITHDRAW_SEC := 0.45
const HINGE_OUT := 0.008
const START_EXTRA := 0.07
## 叶片尖端停在宫颈前方的余量。叶片比阴道长，铰链因此落在体外。
const TIP_CLEARANCE := 0.004
## 插入（即使闭合）时阴唇 / 外口的拨开程度，与开合滑条无关。
const LABIA_SPREAD := 0.92

var host: Node = null
var organs: Node = null
var skel: Skeleton3D = null
var node: Node3D = null
var state: String = "idle"  # idle | inserting | inserted | closing | withdrawing
var angle: float = 0.0
var target_angle: float = 0.0
var _anim_t: float = 0.0
var _hold_angle: float = 0.0
var _seat_ab: Vector3 = Vector3.ZERO
var _start_ab: Vector3 = Vector3.ZERO
var _axis_ab: Vector3 = Vector3(0, 1, 0)
var _up_ab: Vector3 = Vector3(0, 0, 1)
var _open_ab: Vector3 = Vector3.ZERO
var _canal_len: float = 0.055
var _depth: float = 0.055
var _present: bool = false
var _spread_drive: float = 0.0


func setup(s: Node, o: Node, sk: Skeleton3D) -> void:
	host = s
	organs = o
	skel = sk


func is_present() -> bool:
	return _present and node != null and is_instance_valid(node)


func is_inserted() -> bool:
	return is_present() and (state == "inserted" or state == "closing" or state == "withdrawing")


func is_ready() -> bool:
	return is_present() and state == "inserted"


func is_animating() -> bool:
	return state == "inserting" or state == "closing" or state == "withdrawing"


func opening_angle() -> float:
	return angle


func max_angle() -> float:
	return MAX_ANGLE


func set_opening_angle(deg: float) -> void:
	target_angle = clampf(deg, 0.0, MAX_ANGLE)
	if state == "inserted":
		angle = target_angle
		_apply_jaws()
		_push_deform()


func begin_insert() -> bool:
	if is_present() and state != "idle":
		return true
	if not _refresh_canal():
		return false
	_ensure_node()
	state = "inserting"
	_anim_t = 0.0
	angle = 0.0
	target_angle = 0.0
	_present = true
	node.visible = true
	_place_at(_start_ab)
	_apply_jaws()
	_push_deform()
	return true


func request_remove() -> bool:
	if not is_present():
		return false
	if state == "closing" or state == "withdrawing":
		return true
	if state == "inserting":
		# 插入中途取出：先坐稳再收。直接改走撤回更干净。
		state = "closing"
		_anim_t = 0.0
		_hold_angle = angle
		return true
	state = "closing"
	_anim_t = 0.0
	_hold_angle = angle
	return true


func force_clear() -> void:
	_clear_deform()
	_present = false
	state = "idle"
	angle = 0.0
	target_angle = 0.0
	_spread_drive = 0.0
	if node and is_instance_valid(node):
		node.visible = false
		node.queue_free()
	node = null


func hits_ray(origin: Vector3, dir: Vector3) -> bool:
	if not is_present() or node == null or not node.visible:
		return false
	var d := dir.normalized()
	# 叶片沿 +Z，两只手柄主要沿 −Y（库斯科式后侧握把），另有一小段在铰链后方。
	var hinge := node.global_position
	var tip := hinge + node.global_transform.basis.z * MeshFactory.BLADE_LEN
	var handle := hinge - node.global_transform.basis.y * MeshFactory.HANDLE_LEN
	var back := hinge - node.global_transform.basis.z * 0.055
	return _ray_seg(origin, d, hinge, tip, 0.032) or _ray_seg(origin, d, handle, hinge, 0.028) or _ray_seg(origin, d, back, hinge, 0.028)


func step(dt: float) -> void:
	if not _present:
		return
	if not _refresh_canal() and state != "withdrawing":
		return
	if state == "inserting":
		_anim_t = minf(1.0, _anim_t + dt / INSERT_SEC)
		var u := _smooth(_anim_t)
		_place_at(_start_ab.lerp(_seat_ab, u))
		angle = 0.0
		_apply_jaws()
		_push_deform()
		if _anim_t >= 1.0:
			state = "inserted"
			angle = target_angle
			_apply_jaws()
			_push_deform()
	elif state == "inserted":
		angle = target_angle
		_place_at(_seat_ab)
		_apply_jaws()
		_push_deform()
	elif state == "closing":
		_anim_t = minf(1.0, _anim_t + dt / CLOSE_SEC)
		var u2 := _smooth(_anim_t)
		angle = lerpf(_hold_angle, 0.0, u2)
		target_angle = 0.0
		_place_at(_seat_ab)
		_apply_jaws()
		_push_deform()
		if _anim_t >= 1.0:
			state = "withdrawing"
			_anim_t = 0.0
	elif state == "withdrawing":
		_anim_t = minf(1.0, _anim_t + dt / WITHDRAW_SEC)
		var u3 := _smooth(_anim_t)
		angle = 0.0
		_place_at(_seat_ab.lerp(_start_ab, u3))
		_apply_jaws()
		_push_deform()
		if _anim_t >= 1.0:
			force_clear()


func debug_finish_anim() -> void:
	if state == "inserting":
		_anim_t = 1.0
		step(0.0)
	elif state == "closing":
		_anim_t = 1.0
		step(0.0)
		if state == "withdrawing":
			_anim_t = 1.0
			step(0.0)
	elif state == "withdrawing":
		_anim_t = 1.0
		step(0.0)


func world_transform() -> Transform3D:
	if node and is_instance_valid(node):
		return node.global_transform
	return Transform3D.IDENTITY


func _ensure_node() -> void:
	if node and is_instance_valid(node):
		return
	node = MeshFactory.build_root()
	node.top_level = true
	node.add_to_group("camera_ignore")
	node.visible = false
	if host:
		host.add_child(node)


func _refresh_canal() -> bool:
	if organs == null or not organs.has_method("vagina_canal"):
		return false
	var d: Dictionary = organs.call("vagina_canal")
	if d.is_empty():
		return false
	_open_ab = d["opening_ab"]
	_axis_ab = (d["axis_ab"] as Vector3).normalized()
	_up_ab = (d["up_ab"] as Vector3).normalized()
	_canal_len = float(d["length"])
	# 变形深度 = 进入阴道的长度；叶片尖端停在宫颈稍前方，铰链留在体外。
	var in_len := maxf(_canal_len - TIP_CLEARANCE, 0.03)
	_depth = in_len
	_seat_ab = _open_ab - _axis_ab * (MeshFactory.BLADE_LEN - in_len)
	_start_ab = _seat_ab - _axis_ab * START_EXTRA
	# 拖拽 / 软位移：铰链跟着开口走，避免阴部被拖走时器械留在原地。
	if organs.has_method("soft_offset_ab"):
		var off: Vector3 = organs.call("soft_offset_ab", _open_ab)
		_seat_ab += off
		_start_ab += off
	return _axis_ab.length() > 0.5 and _depth > 0.01


func _place_at(hinge_ab: Vector3) -> void:
	if node == null or organs == null or not organs.has_method("abdomen_frame"):
		return
	var fr: Transform3D = organs.call("abdomen_frame")
	var z := (fr.basis * _axis_ab).normalized()
	var y := (fr.basis * _up_ab).normalized()
	y = (y - z * y.dot(z)).normalized()
	if y.length() < 0.4:
		y = fr.basis.y
		y = (y - z * y.dot(z)).normalized()
	var x := y.cross(z).normalized()
	y = z.cross(x).normalized()
	if not x.is_finite() or not y.is_finite() or not z.is_finite():
		return
	var origin: Vector3 = fr * hinge_ab
	if not origin.is_finite():
		return
	node.global_transform = Transform3D(Basis(x, y, z), origin)


func _apply_jaws() -> void:
	if node:
		MeshFactory.set_open_angle(node, angle)


func _push_deform() -> void:
	if organs == null or not organs.has_method("set_speculum_deform"):
		return
	if not _present or state == "withdrawing" and _anim_t > 0.65:
		_clear_deform()
		return
	# 开合角驱动阴道壁半开距。两瓣共享同一 stadium 体积：半高 = 闭合半高 + 距铰链 * tan(半角)。
	var half := deg_to_rad(angle * 0.5)
	var half_gap := MeshFactory.CLOSED_HALF + MeshFactory.BLADE_LEN * tan(half)
	var mixv := 1.0
	if state == "inserting":
		mixv = _smooth(_anim_t)
	elif state == "withdrawing":
		mixv = 1.0 - _smooth(_anim_t)
	var origin := _open_ab
	if organs.has_method("soft_offset_ab"):
		origin += organs.call("soft_offset_ab", _open_ab)
	var half_width := MeshFactory.BLADE_WIDTH * 0.5 + MeshFactory.BLADE_THICK
	var overhang := maxf(MeshFactory.BLADE_LEN - _depth, 0.0)
	var half_intro := MeshFactory.CLOSED_HALF + overhang * tan(half)
	const CORNER := 0.004
	organs.call("set_speculum_deform", origin, _axis_ab, _up_ab, _depth, half_gap, mixv, half_intro, half_width, CORNER)
	# 外口截面贴合叶片外壳（一个体积，不是上下两团更大的椭圆）。
	var z_intro := maxf(overhang, 0.006)
	var t_along := clampf(z_intro / MeshFactory.BLADE_LEN, 0.0, 1.0)
	var taper := lerpf(1.0, 0.85, t_along)
	var hx := MeshFactory.BLADE_WIDTH * 0.5 * taper + MeshFactory.BLADE_THICK
	var hy := half_intro + 0.0008
	var blade_sep := maxf(hy - CORNER, 0.0)
	# 插入一开始（甚至还在体外接近外口时）阴唇和外口就要张开，容纳闭合叶片。
	var labia_mix := mixv
	if state == "inserting":
		labia_mix = maxf(mixv, 0.75)
	elif state == "inserted" or state == "closing":
		labia_mix = 1.0
	_spread_drive = LABIA_SPREAD * labia_mix
	if organs.has_method("set_speculum_labia"):
		organs.call("set_speculum_labia", labia_mix, hx, hy, _axis_ab, _up_ab, angle, blade_sep)
	if organs.has_method("set_vulva_spread"):
		var want := _spread_drive
		var p = organs.get("player") if organs != null else null
		if p == null and host:
			p = host.get("player")
		if p and p.has_method("get_actions"):
			var acts = p.call("get_actions")
			if acts and str(acts.get("active_id")) == "spread_vulva":
				want = maxf(want, 1.0)
		organs.call("set_vulva_spread", want)


func _clear_deform() -> void:
	if organs and organs.has_method("clear_speculum_deform"):
		organs.call("clear_speculum_deform")
	if organs and organs.has_method("set_vulva_spread") and _spread_drive > 0.0:
		var keep := 0.0
		# 若动作栏仍在拨开，让动作系统下一帧接手；这里先回到 0 以免残留。
		var p = organs.get("player") if organs != null else null
		if p == null and host:
			p = host.get("player")
		if p and p.has_method("get_actions"):
			var acts = p.call("get_actions")
			if acts and str(acts.get("active_id")) == "spread_vulva":
				keep = -1.0
		if keep >= 0.0 and organs.has_method("vulva_spread"):
			if float(organs.call("vulva_spread")) <= _spread_drive + 0.02:
				organs.call("set_vulva_spread", 0.0)
	_spread_drive = 0.0


func _smooth(t: float) -> float:
	var u := clampf(t, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


func _ray_seg(o: Vector3, d: Vector3, a: Vector3, b: Vector3, rad: float) -> bool:
	var ab := b - a
	var len := ab.length()
	if len < 1e-6:
		return o.distance_to(a) <= rad + 0.01 or _ray_sphere(o, d, a, rad)
	var n := ab / len
	# 射线到线段最短距离
	var ao := a - o
	var dd := d.dot(d)
	var dn := d.dot(n)
	var det := dd - dn * dn
	var t: float
	var s: float
	if absf(det) < 1e-8:
		t = 0.0
		s = clampf((-ao).dot(n), 0.0, len)
	else:
		t = (ao.dot(d) - ao.dot(n) * dn) / det
		s = clampf((t * dn - ao.dot(n)), 0.0, len)
	if t < -0.02:
		return false
	var p := o + d * t
	var q := a + n * s
	return p.distance_to(q) <= rad + 0.008


func _ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> bool:
	var v := o - c
	var b := v.dot(d)
	var disc := b * b - v.dot(v) + r * r
	if disc < 0.0:
		return false
	var t := -b - sqrt(disc)
	if t < -0.02:
		t = -b + sqrt(disc)
	return t >= -0.02
