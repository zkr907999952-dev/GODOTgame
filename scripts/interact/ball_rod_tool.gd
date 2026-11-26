extends Node
## 长柄金属球：镀铬圆杆 + 末端圆球，直径滑条同时改外形和碰撞。
## 拖拽插入阴道，通道被球环弹性撑开；宫颈是阻力闸门，突破后宫腔和子宫被撑开。
class_name BallRodTool

const ChromeScript := preload("res://scripts/surgery/speculum_mesh.gd")
const InserterScript := preload("res://scripts/body/vulva/sphere_inserter.gd")

const DIAMETER_MIN := 0.012
const DIAMETER_MAX := 0.032
const DIAMETER_DEFAULT := 0.020
const SHAFT_RADIUS := 0.004
const SHAFT_CLEARANCE := 0.0065  # 杆半径 + 2.5 mm，管壁始终包住杆
const SHAFT_LEN := 0.18
const OS_REST_R := 0.0049

signal diameter_changed(diameter: float)
signal breakthrough(entered: bool)
## 0.4.12：大球在宫腔里被强行扯出 → 宫颈卡住球，子宫跟着脱垂（caught = true）；released = 球最终脱出宫颈。
signal prolapse_caught(caught: bool)

var mode: Node
var organs: Node
var player: Node

var diameter: float = DIAMETER_DEFAULT
var depth: float = -0.04
var lateral: Vector3 = Vector3.ZERO
var dragging := false
var through_cervix := false
var cervix_pressure := 0.0
var cervix_pulse := 0.0
var residual := 0.0
var last_step_usec := 0
var breakthrough_count := 0
var last_breakthrough_in := false
var jolt := Vector3.ZERO
var jolt_time := 0.0
var uterus_distend := 0.0
# 0.4.12 子宫脱垂触发 #1
var caught := false                 # 球卡在宫颈里，正拖着子宫
var last_pull_speed := 0.0          # 往外扯的速度（m/s，按期望深度的变化）
var last_pull_force := 0.0          # 被宫颈挡住的行程（m）
var prolapse_trigger_count := 0
var _last_desired := INF
var _caught_target := Vector3.ZERO

var _root: Node3D
var _tip_mi: MeshInstance3D
var _shaft_mi: MeshInstance3D
var _sphere_mesh: SphereMesh
var _cyl_mesh: CylinderMesh
var _area: Area3D
var _shape: SphereShape3D
var _inserter: RefCounted
var _parked := true
var _prev_tip: Vector3 = Vector3.ZERO
var _have_prev_tip := false
var _stir_world: Vector3 = Vector3.ZERO
var _straighten := 0.0
var _fundus_lift := 0.0
const FUNDUS_LIFT_MAX := 0.080
var _debug_dt := 0.0


func setup(p_mode: Node, p_organs: Node, p_player: Node) -> void:
	mode = p_mode
	organs = p_organs
	player = p_player
	_build_mesh()
	set_physics_process(true)


func activate() -> void:
	_parked = true
	through_cervix = false
	cervix_pressure = 0.0
	cervix_pulse = 0.0
	residual = 0.0
	uterus_distend = 0.0
	depth = -0.04 - radius()
	lateral = Vector3.ZERO
	dragging = false
	_have_prev_tip = false
	_stir_world = Vector3.ZERO
	_straighten = 0.0
	_fundus_lift = 0.0
	if _root:
		_root.visible = true
	_sync_pose(0.0)
	_apply_deform()


func deactivate() -> void:
	if caught:
		_release_catch(false)
	dragging = false
	through_cervix = false
	cervix_pressure = 0.0
	residual = 0.0
	uterus_distend = 0.0
	_fundus_lift = 0.0
	if organs:
		if organs.has_method("clear_canal_dilate"):
			organs.call("clear_canal_dilate")
		if organs.has_method("clear_uterus_ball"):
			organs.call("clear_uterus_ball")
		if organs.has_method("clear_canal_stir"):
			organs.call("clear_canal_stir")
		if organs.has_method("clear_uterus_straighten"):
			organs.call("clear_uterus_straighten")
		if organs.has_method("clear_fundus_lift"):
			organs.call("clear_fundus_lift")
		if organs.get("vulva") and organs.vulva.has_method("set_inserter") and not _prolapse_owns_introitus():
			organs.vulva.call("set_inserter", null)
	if _root:
		_root.visible = false


func _exit_tree() -> void:
	deactivate()
	if _root and is_instance_valid(_root):
		_root.queue_free()
		_root = null


func radius() -> float:
	return diameter * 0.5


func collider_radius() -> float:
	return _shape.radius if _shape else radius()


func tip_world() -> Vector3:
	return _root.global_position if _root else Vector3.ZERO


func is_in_uterus() -> bool:
	return through_cervix and depth > _cervix_depth()


func set_diameter(d: float) -> void:
	diameter = clampf(d, DIAMETER_MIN, DIAMETER_MAX)
	_sync_visual()
	diameter_changed.emit(diameter)
	# 卡住时把球缩到宫颈能放过的大小：球从宫颈滑出，子宫停在当前脱垂等级。
	if caught:
		var pc := _prolapse()
		var pp: Resource = pc.get("params") if pc else null
		var cap := float(pp.get("cervix_capacity_r")) * float(pp.get("catch_ratio")) if pp else 0.0
		if radius() < cap:
			_release_catch(true)
			return
	_apply_deform()


func begin_drag(_screen: Vector2, origin: Vector3, dir: Vector3) -> bool:
	if _root == null or not _root.visible:
		activate()
	dragging = true
	_last_desired = INF
	if caught:
		var pc := _prolapse()
		if pc:
			pc.call("begin_drive", "ball_rod", 0, _caught_pointer(origin, dir), true)
		_drive_caught(origin, dir)
		return true
	_move_from_ray(origin, dir, 1.0)
	return true


func update_drag(_screen: Vector2, origin: Vector3, dir: Vector3) -> void:
	if not dragging:
		return
	if caught:
		_drive_caught(origin, dir)
		return
	_move_from_ray(origin, dir, 1.0)


func end_drag() -> void:
	dragging = false
	_last_desired = INF
	if caught:
		# 松手：子宫停在已达到的等级挂着甩，球仍卡在宫颈里，可以再拖。
		var pc := _prolapse()
		if pc:
			pc.call("end_drive")


## 预设计算拖拽点（自检 / 输入共用）。
func project_pointer(origin: Vector3, dir: Vector3) -> Vector3:
	var opening := _opening_world()
	var axis := _axis_world()
	var up := _up_world()
	var preset := str(mode.call("current_preset")) if mode and mode.has_method("current_preset") else "free"
	if opening.length_squared() < 1e-12 or axis.length_squared() < 1e-12 or dir.length_squared() < 1e-12:
		return tip_world()
	var d := dir.normalized()
	if preset == "introitus":
		# 视线与阴道轴线的最近点：屏幕中央是深处，四周是外口，拖向中心即插入。
		return _closest_on_canal(origin, d, opening, axis, up)
	# 小腹 / 自由：投到含轴线、尽量侧对相机的平面上。
	var cam_fwd := d
	if player and player.has_method("get_camera"):
		var cam: Camera3D = player.call("get_camera")
		if cam:
			cam_fwd = -cam.global_transform.basis.z
	var n := axis.cross(cam_fwd.cross(axis))
	if n.length_squared() < 1e-8:
		n = up
	n = n.normalized()
	var plane_p := opening + axis * clampf(depth, -0.05, _canal_length() + 0.06)
	var den := d.dot(n)
	if absf(den) < 1e-5:
		return _closest_on_canal(origin, d, opening, axis, up)
	var t := (plane_p - origin).dot(n) / den
	t = clampf(t, 0.02, 1.6)
	return origin + d * t


func apply_desired_depth(desired: float, dt: float = 0.016) -> void:
	_apply_depth_gate(desired, dt)
	_sync_pose(dt)
	_apply_deform()


func debug_set_depth(s: float) -> void:
	# 测试布置：直接放到该深度，不走宫颈闸门。
	depth = s
	lateral = Vector3.ZERO
	var cerv := _cervix_depth()
	through_cervix = s > cerv + radius() * 0.4
	cervix_pressure = 0.0
	_have_prev_tip = false
	_stir_world = Vector3.ZERO
	_debug_dt = 0.5
	_sync_pose(0.0)
	_apply_deform()
	_debug_dt = 0.0


func debug_step_lateral(offset_world: Vector3, dt: float = 0.016) -> void:
	_debug_dt = maxf(dt, 1e-4)
	_prev_tip = tip_world()
	_have_prev_tip = true
	var axis := _axis_world()
	lateral = offset_world - axis * offset_world.dot(axis)
	_sync_pose(0.0)
	_apply_deform()
	_debug_dt = 0.0


func debug_settle(dt: float = 0.25) -> void:
	# 杆停下后让搅动位移回弹（目标速度为 0）。
	_debug_dt = maxf(dt, 1e-4)
	_prev_tip = tip_world()
	_have_prev_tip = true
	_apply_deform()
	_debug_dt = 0.0


func debug_stir_offset() -> Vector3:
	return _stir_world


func debug_straighten() -> float:
	return _straighten


func debug_fundus_lift() -> float:
	return _fundus_lift


func fundus_contact_depth() -> float:
	return _fundus_contact_depth()


func debug_push_depth(desired: float, dt: float = 0.05) -> void:
	# 测试：走闸门之后的深度逻辑（含宫底顶起），可连推多帧。
	_debug_dt = maxf(dt, 1e-4)
	apply_desired_depth(desired, _debug_dt)
	_debug_dt = 0.0


func _fundus_contact_depth() -> float:
	# 休息网格上的宫底内侧（沿通道轴），球心触壁深度。不含当前顶起。
	var r := radius()
	var wall := 0.0032
	if organs and organs.get("meta") is Dictionary and (organs.meta as Dictionary).has("uterus_cavity"):
		var uc = organs.meta["uterus_cavity"]
		if uc is Dictionary:
			wall = maxf(float(uc.get("wall_m", wall)), 0.0025) + 0.0006
	var cerv := _cervix_depth()
	var fund := _fundus_world()
	var uter_len := _cervix_world().distance_to(fund)
	if uter_len < 0.02:
		uter_len = maxf(_uterus_rest_len(), 0.04)
	# 前倾未拉直时，沿通道能走到的宫底更近；拉直后取满长。
	# 触壁再提前 3 mm，并在未拉直时更早开始顶起，避免球穿出宫底。
	var along := cerv + uter_len * lerpf(0.62, 0.92, _straighten)
	return along - wall - r - 0.003


func _update_fundus_lift(desired: float, dt: float) -> void:
	var contact0 := _fundus_contact_depth()
	var want := 0.0
	if through_cervix and not caught and desired > contact0:
		want = clampf(desired - contact0, 0.0, FUNDUS_LIFT_MAX)
	if dt <= 1e-5:
		dt = 0.016
	var k := 1.0 - exp(-dt * 18.0)
	_fundus_lift = lerpf(_fundus_lift, want, k)
	if _fundus_lift < 1e-5:
		_fundus_lift = 0.0
	if through_cervix and not caught:
		var wall_d := contact0 + _fundus_lift
		if depth > wall_d:
			depth = wall_d
	if organs == null:
		return
	if _fundus_lift > 1e-5 and organs.has_method("set_fundus_lift"):
		var opening_ab := Vector3.ZERO
		var cerv_ab := Vector3.ZERO
		var axis_ab := Vector3(0, 1, 0)
		if organs.has_method("vagina_canal"):
			var canal: Dictionary = organs.call("vagina_canal")
			opening_ab = canal.get("opening_ab", opening_ab)
			cerv_ab = canal.get("cervix_ab", cerv_ab)
			axis_ab = canal.get("axis_ab", axis_ab)
		organs.call("set_fundus_lift", _fundus_lift, opening_ab, cerv_ab, axis_ab)
	elif organs.has_method("clear_fundus_lift"):
		organs.call("clear_fundus_lift")


func debug_add_pressure(p: float) -> void:
	cervix_pressure += p


func debug_reset_gate() -> void:
	through_cervix = false
	cervix_pressure = 0.0
	breakthrough_count = 0


func cervix_threshold() -> float:
	# 随球直径明显变高：12 mm 约 1.7 cm 被挡住的行程，32 mm 约 4.0 cm。
	return 0.010 + 1.15 * radius()


func canal_radius_at_ball() -> float:
	if organs and organs.has_method("canal_dilate_radius_at"):
		return float(organs.call("canal_dilate_radius_at", depth))
	return 0.0


func consume_breakthrough() -> bool:
	if breakthrough_count > 0:
		return true
	return false


func _build_mesh() -> void:
	_root = Node3D.new()
	_root.name = "BallRod"
	if organs:
		organs.add_child(_root)
	else:
		add_child(_root)
	var mat: StandardMaterial3D = ChromeScript.chrome_material()
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radial_segments = 16
	_sphere_mesh.rings = 8
	_tip_mi = MeshInstance3D.new()
	_tip_mi.name = "Tip"
	_tip_mi.mesh = _sphere_mesh
	_tip_mi.material_override = mat
	_tip_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(_tip_mi)
	_cyl_mesh = CylinderMesh.new()
	_cyl_mesh.radial_segments = 12
	_cyl_mesh.rings = 1
	_cyl_mesh.top_radius = SHAFT_RADIUS
	_cyl_mesh.bottom_radius = SHAFT_RADIUS
	_cyl_mesh.height = SHAFT_LEN
	_shaft_mi = MeshInstance3D.new()
	_shaft_mi.name = "Shaft"
	_shaft_mi.mesh = _cyl_mesh
	_shaft_mi.material_override = mat
	_shaft_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 局部 +Z 朝宫颈；杆沿 -Z 向外。Cylinder 默认沿 +Y，先转到 -Z。
	_shaft_mi.rotation_degrees = Vector3(90, 0, 0)
	_root.add_child(_shaft_mi)
	_area = Area3D.new()
	_area.name = "TipCollider"
	_area.monitorable = false
	_area.monitoring = false
	_shape = SphereShape3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _shape
	_area.add_child(cs)
	_root.add_child(_area)
	_sync_visual()
	_root.visible = true


func _sync_visual() -> void:
	var r := radius()
	if _sphere_mesh:
		_sphere_mesh.radius = r
		_sphere_mesh.height = r * 2.0
	if _shape:
		_shape.radius = r
	if _shaft_mi:
		_shaft_mi.position = Vector3(0, 0, -(r * 0.12 + SHAFT_LEN * 0.5))


func _opening_world() -> Vector3:
	if mode and mode.has_method("introitus_world"):
		return mode.call("introitus_world")
	return Vector3.ZERO


func _axis_world() -> Vector3:
	if mode and mode.has_method("canal_axis_world"):
		return mode.call("canal_axis_world")
	return Vector3(0, 1, 0)


func _up_world() -> Vector3:
	if mode and mode.has_method("canal_up_world"):
		return mode.call("canal_up_world")
	return Vector3.UP


func _canal_length() -> float:
	var d := {}
	if organs and organs.has_method("vagina_canal"):
		d = organs.call("vagina_canal")
	if d.has("length"):
		return maxf(float(d["length"]), 0.03)
	var o := _opening_world()
	var c := _cervix_world()
	return maxf(o.distance_to(c), 0.03)


func _cervix_world() -> Vector3:
	if mode and mode.has_method("cervix_world"):
		return mode.call("cervix_world")
	return _opening_world() + _axis_world() * 0.055


func _cervix_depth() -> float:
	return _canal_length()


func _fundus_world() -> Vector3:
	# 宫底大约在宫颈沿子宫长轴再往里数厘米。
	var c := _cervix_world()
	var axis := _axis_world()
	if organs and organs.has_method("viscera_meshes"):
		var arr: Array = organs.call("viscera_meshes", "uterus")
		if arr.is_empty():
			arr = organs.call("viscera_meshes", "uterus_cavity")
		var acc := Vector3.ZERO
		var n := 0
		for mi in arr:
			if mi is MeshInstance3D and (mi as MeshInstance3D).mesh:
				var xf: Transform3D = (mi as MeshInstance3D).global_transform
				var ab: AABB = (mi as MeshInstance3D).mesh.get_aabb()
				acc += xf * ab.get_center()
				n += 1
		if n > 0:
			var mid := acc / float(n)
			var far := mid + (mid - c)
			if (far - c).dot(axis) > 0.0:
				return c + axis * maxf((far - c).dot(axis), 0.03)
			return mid
	return c + axis * 0.05


func _closest_on_canal(origin: Vector3, dir: Vector3, opening: Vector3, axis: Vector3, up: Vector3) -> Vector3:
	# 两条直线最近点，再限制侧向偏移。
	var w0 := origin - opening
	var a := 1.0
	var b := dir.dot(axis)
	var c := 1.0
	var d := dir.dot(w0)
	var e := axis.dot(w0)
	var denom := a * c - b * b
	var t: float
	var s: float
	if absf(denom) < 1e-8:
		t = 0.12
		s = e
	else:
		t = (b * e - c * d) / denom
		s = (a * e - b * d) / denom
	t = clampf(t, 0.02, 1.6)
	var p_ray := origin + dir * t
	var along := (p_ray - opening).dot(axis)
	var lat := p_ray - (opening + axis * along)
	var slack := _lateral_slack(along)
	if lat.length() > slack:
		var side := axis.cross(up)
		if side.length_squared() < 1e-8:
			lat = lat.limit_length(slack)
		else:
			lat = lat.limit_length(slack)
	return opening + axis * along + lat


func _lateral_slack(along: float) -> float:
	if along < -0.01:
		return 0.045
	if along < radius():
		return 0.018
	if through_cervix:
		return 0.012
	return 0.0035


func _move_from_ray(origin: Vector3, dir: Vector3, _k: float) -> void:
	var p := project_pointer(origin, dir)
	var opening := _opening_world()
	var axis := _axis_world()
	var desired := (p - opening).dot(axis)
	var lat := p - (opening + axis * desired)
	var slack := _lateral_slack(desired)
	if lat.length() > slack:
		lat = lat.limit_length(slack)
	lateral = lat
	var dt := 0.016
	if Engine.get_main_loop():
		dt = clampf(float(Engine.get_main_loop().root.get_process_delta_time()) if Engine.get_main_loop().root else 0.016, 0.004, 0.05)
	_apply_depth_gate(desired, dt)
	_sync_pose(dt)
	_apply_deform()


func _apply_depth_gate(desired: float, dt: float) -> void:
	# 往外扯的速度（期望深度的变化率，按住时才算）。
	if _last_desired != INF and dt > 0.0:
		last_pull_speed = maxf((_last_desired - desired) / dt, 0.0)
	else:
		last_pull_speed = 0.0
	_last_desired = desired
	last_pull_force = 0.0
	var cerv := _cervix_depth()
	var r := radius()
	var contact0 := _fundus_contact_depth()
	var max_in := contact0 + FUNDUS_LIFT_MAX + 0.002
	var min_out := -0.06 - r
	desired = clampf(desired, min_out, max_in)
	var gate_start := cerv - r * 0.85
	var gate_end := cerv + r * 0.55
	var pushing := desired > depth + 1e-5
	var pulling := desired < depth - 1e-5
	if not through_cervix:
		if pushing and desired > gate_start and depth >= gate_start - r * 0.2:
			# 顶在宫颈上：深度几乎不动，攒压力。已攒够就突破，不必再等深度精确落到闸门上。
			var blocked := maxf(desired - gate_start, 0.0)
			cervix_pressure += blocked * clampf(dt * 2.8, 0.0, 0.12)
			depth = _approach(depth, minf(depth, gate_start) + 0.002, dt, 3.0)
			if cervix_pressure >= cervix_threshold():
				_do_breakthrough(true, cerv, r)
		else:
			# 未到闸门，或正在往外退：跟手。
			var cap := desired
			if desired > gate_start and not through_cervix:
				cap = gate_start + 1e-4
			depth = _approach(depth, cap, dt, 14.0)
			if desired <= gate_start or not pushing:
				cervix_pressure = maxf(cervix_pressure - dt * 1.8, 0.0)
			# 若调用方已经把压力加满，这一帧也可以突破。
			if pushing and desired > gate_start and cervix_pressure >= cervix_threshold():
				_do_breakthrough(true, cerv, r)
	else:
		if pulling and depth <= gate_end + r * 0.35:
			var blocked_out := maxf(gate_end - desired, 0.0)
			last_pull_force = blocked_out
			# 0.4.12 触发 #1：球够大 + 扯得够狠 → 宫颈卡住球，子宫被拖出来（不再弹出宫颈）。
			if _try_prolapse_trigger(desired):
				return
			cervix_pressure += blocked_out * clampf(dt * 2.8, 0.0, 0.12)
			depth = _approach(depth, maxf(depth, gate_end), dt, 3.0)
			if cervix_pressure >= cervix_threshold() * 0.85:
				_do_breakthrough(false, cerv, r)
		else:
			depth = _approach(depth, desired, dt, 10.0)
			# 往外扯时宫颈挡着：一帧扯得再快也不能直接越过闸门（先卡住，再按压力弹出或触发脱垂）。
			if pulling:
				depth = maxf(depth, gate_end)
			if desired >= gate_end or pushing:
				cervix_pressure = maxf(cervix_pressure - dt * 1.8, 0.0)
			if pulling and desired < gate_start and cervix_pressure >= cervix_threshold() * 0.85:
				_do_breakthrough(false, cerv, r)
	depth = clampf(depth, min_out, max_in)
	_update_fundus_lift(desired, dt)
	depth = clampf(depth, min_out, minf(max_in, _fundus_contact_depth() + _fundus_lift + 1e-4))
	# 球过后通道慢慢回缩。
	var target_res := 0.35 if (depth > r * 0.5 or through_cervix) else 0.0
	residual = lerpf(residual, target_res, clampf(dt * 2.2, 0.0, 1.0))
	if cervix_pulse > 0.0:
		cervix_pulse = maxf(cervix_pulse - dt * 3.5, 0.0)


func _do_breakthrough(entering: bool, cerv: float, r: float) -> void:
	through_cervix = entering
	cervix_pressure = 0.0
	cervix_pulse = 1.0
	residual = 0.7
	breakthrough_count += 1
	last_breakthrough_in = entering
	if entering:
		depth = cerv + r * 0.95 + 0.006
	else:
		depth = cerv - r * 0.9 - 0.004
		uterus_distend = 0.0
	# 组织 / 镜头短促一震。
	var axis := _axis_world()
	jolt = axis * (0.014 if entering else -0.010)
	jolt_time = 0.14
	breakthrough.emit(entering)


func _approach(cur: float, goal: float, dt: float, k: float) -> float:
	return lerpf(cur, goal, clampf(k * dt, 0.0, 1.0))


func _sync_pose(dt: float) -> void:
	if _root == null:
		return
	var opening := _opening_world()
	var axis := _axis_world()
	var up := _up_world()
	if opening.length_squared() < 1e-12 or axis.length_squared() < 1e-12:
		return
	var pos := opening + axis * depth + lateral
	if jolt_time > 0.0 and dt > 0.0:
		jolt_time = maxf(jolt_time - dt, 0.0)
		var w := jolt_time / 0.14
		pos += jolt * w
		if player and player.has_method("apply_orbit_pose") == false:
			pass
		# 镜头微震：只在突破瞬间推一下观察锚点。
		if mode and w > 0.4 and mode.has_method("fly_to_genitals") == false:
			pass
	var z := axis
	var x := up.cross(z)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT.cross(z)
	x = x.normalized()
	var y := z.cross(x).normalized()
	_root.global_transform = Transform3D(Basis(x, y, z), pos)
	if not pos.is_finite() or not x.is_finite():
		push_warning("ball_rod: non-finite pose")
	# 突破时把一小段震动交给模式，让相机跟着晃一下。
	if jolt_time > 0.08 and mode and mode.has_method("add_view_jolt"):
		mode.call("add_view_jolt", jolt * 0.55)


func _apply_deform() -> void:
	if organs == null or not organs.has_method("vagina_canal"):
		return
	if caught:
		# 球在脱出的子宫里：通道 / 宫腔撑开交给脱垂系统（原子宫已隐藏），外口由脱出物占用。
		if organs.has_method("clear_canal_dilate"):
			organs.call("clear_canal_dilate")
		if organs.has_method("clear_uterus_ball"):
			organs.call("clear_uterus_ball")
		if organs.has_method("clear_canal_stir"):
			organs.call("clear_canal_stir")
		if organs.has_method("clear_uterus_straighten"):
			organs.call("clear_uterus_straighten")
		if organs.has_method("clear_fundus_lift"):
			organs.call("clear_fundus_lift")
		uterus_distend = 0.0
		_stir_world = Vector3.ZERO
		_straighten = 0.0
		_fundus_lift = 0.0
		return
	var canal: Dictionary = organs.call("vagina_canal")
	if canal.is_empty():
		return
	var opening_ab: Vector3 = canal.get("opening_ab", Vector3.ZERO)
	var axis_ab: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
	if axis_ab.length_squared() < 1e-8:
		return
	axis_ab = axis_ab.normalized()
	var up_ab: Vector3 = canal.get("up_ab", Vector3(0, 0, 1))
	var cerv_s := _cervix_depth()
	var r := radius()
	var mixv := 1.0
	if depth < -r:
		mixv = clampf((depth + r + 0.008) / 0.016, 0.0, 1.0)
	var lat_ab := Vector3.ZERO
	if organs.get("_frame") != null and lateral.length_squared() > 1e-10:
		var xf0: Transform3D = organs.get("_frame")
		lat_ab = xf0.basis.inverse() * lateral
	if organs.has_method("set_canal_dilate"):
		var res := residual + cervix_pulse * 0.45
		organs.call("set_canal_dilate", opening_ab, axis_ab, depth, r, mixv, SHAFT_CLEARANCE, res, cerv_s, lat_ab)
	# 阴唇 / 外口：VulvaInserter。扩张器在位时由叶片包络占用外口，避免每帧和扩张器抢写（否则会反复重建皮瓣）。
	if organs.get("vulva") and organs.vulva.has_method("set_inserter"):
		if _inserter == null:
			_inserter = InserterScript.new()
		_inserter.configure(depth, r, SHAFT_RADIUS, axis_ab, up_ab, mixv, lat_ab)
		if not _prolapse_owns_introitus() and not _speculum_owns_introitus():
			organs.vulva.call("set_inserter", _inserter if mixv > 0.02 else null)
	# 进入宫腔后撑开子宫和 UterusCavity。
	uterus_distend = 0.0
	if through_cervix and depth > cerv_s - r * 0.2 and organs.has_method("set_uterus_ball"):
		var xf2: Transform3D = organs.get("_frame") if organs.get("_frame") != null else Transform3D.IDENTITY
		var center_ab: Vector3 = xf2.affine_inverse() * tip_world() if _root else (opening_ab + axis_ab * depth)
		var wall := 0.0028
		if organs.get("meta") is Dictionary and (organs.meta as Dictionary).has("uterus_cavity"):
			var uc = organs.meta["uterus_cavity"]
			if uc is Dictionary:
				wall = float(uc.get("wall_m", wall))
		# 不设 28 mm 半径上限（否则球加壁厚会顶穿宫壁）；杆段用胶囊包住。
		organs.call("set_uterus_ball", center_ab, r, mixv, wall, 0.0, SHAFT_CLEARANCE, axis_ab)
		uterus_distend = r * mixv
	elif organs.has_method("clear_uterus_ball"):
		organs.call("clear_uterus_ball")
	_apply_stir_and_straighten(opening_ab, axis_ab, cerv_s, r, mixv, lat_ab)


func _apply_stir_and_straighten(opening_ab: Vector3, axis_ab: Vector3, cerv_s: float, r: float, mixv: float, lat_ab: Vector3) -> void:
	if organs == null:
		return
	# 脱垂进行中不跟球杆抢子宫姿态。
	if organs.has_method("has_prolapse") and bool(organs.call("has_prolapse")):
		var pc = organs.call("prolapse")
		if pc and pc.has_method("amount") and float(pc.call("amount")) > 0.02:
			if organs.has_method("clear_uterus_straighten"):
				organs.call("clear_uterus_straighten")
			if organs.has_method("clear_canal_stir"):
				organs.call("clear_canal_stir")
			_straighten = 0.0
			_stir_world = Vector3.ZERO
			return
	var tip := tip_world()
	var dt := _debug_dt if _debug_dt > 1e-5 else get_physics_process_delta_time()
	if dt <= 1e-5:
		dt = 1.0 / 60.0
	var vel := Vector3.ZERO
	if _have_prev_tip:
		vel = (tip - _prev_tip) / dt
	_prev_tip = tip
	_have_prev_tip = true
	# 跟随速度：杆在动时组织被带着走；停下后目标为 0，弹簧回弹。
	var target := vel * 0.07
	if target.length() > 0.018:
		target = target.normalized() * 0.018
	var k := 1.0 - exp(-dt * 14.0)
	_stir_world = _stir_world.lerp(target, k)
	var xf: Transform3D = organs.get("_frame") if organs.get("_frame") != null else Transform3D.IDENTITY
	var stir_ab: Vector3 = xf.basis.inverse() * _stir_world
	var tip_ab: Vector3 = xf.affine_inverse() * tip if tip.is_finite() else (opening_ab + axis_ab * depth + lat_ab)
	var influence := maxf(r * 4.5, 0.05)
	if organs.has_method("set_canal_stir"):
		if mixv > 0.05 and _stir_world.length() > 1e-5:
			organs.call("set_canal_stir", stir_ab, tip_ab, influence)
		elif organs.has_method("clear_canal_stir"):
			organs.call("clear_canal_stir")
	# 进入宫腔后按深入程度把前倾子宫顶直，抽出时放松。宫颈闸门仍由 _apply_depth_gate 管。
	var want := 0.0
	if through_cervix and depth > cerv_s - r * 0.2:
		var rest_len := _uterus_rest_len()
		var into := maxf(depth - cerv_s, 0.0)
		var t := clampf(into / maxf(rest_len * 0.65, 0.02), 0.0, 1.0)
		want = t * t * (3.0 - 2.0 * t)
	var ks := 1.0 - exp(-dt * 8.0)
	_straighten = lerpf(_straighten, want, ks)
	if organs.has_method("set_uterus_straighten") and _straighten > 0.01:
		var cerv_ab: Vector3 = opening_ab + axis_ab * cerv_s
		var rest_ax: Vector3 = organs.call("uterus_rest_axis_ab") if organs.has_method("uterus_rest_axis_ab") else axis_ab
		var rod_ax := axis_ab
		if _root:
			rod_ax = (xf.basis.inverse() * _axis_world())
			if rod_ax.length_squared() > 1e-8:
				rod_ax = rod_ax.normalized()
		organs.call("set_uterus_straighten", _straighten, cerv_ab, rest_ax, rod_ax, maxf(_uterus_rest_len(), 0.04))
	elif organs.has_method("clear_uterus_straighten"):
		organs.call("clear_uterus_straighten")


func _uterus_rest_len() -> float:
	var c := _cervix_world()
	# 用子宫网格中心到宫颈的距离估计宫腔长度，保留前倾弯折，不投影到阴道轴上。
	if organs and organs.has_method("viscera_meshes"):
		var arr: Array = organs.call("viscera_meshes", "uterus")
		if arr.is_empty():
			arr = organs.call("viscera_meshes", "uterus_cavity")
		var acc := Vector3.ZERO
		var n := 0
		for mi in arr:
			if mi is MeshInstance3D and (mi as MeshInstance3D).mesh:
				var xf: Transform3D = (mi as MeshInstance3D).global_transform
				acc += xf * (mi as MeshInstance3D).mesh.get_aabb().get_center()
				n += 1
		if n > 0:
			var mid := acc / float(n)
			var L := c.distance_to(mid)
			if L > 0.02:
				return L * 1.35
	return maxf(_opening_world().distance_to(_fundus_world()) * 0.7, 0.04)


func _ball_wall_clearance() -> float:
	# 宫腔内球心到（拉直 + 撑开后）宫壁的最小余量。负值表示穿模。
	if organs == null or not through_cervix:
		return 0.0
	var r := radius()
	var xf: Transform3D = organs.get("_frame") if organs.get("_frame") != null else Transform3D.IDENTITY
	var tip_ab: Vector3 = xf.affine_inverse() * tip_world()
	var worst := 1e9
	var n := 0
	if organs.has_method("viscera_meshes"):
		var arr: Array = organs.call("viscera_meshes", "uterus_cavity")
		if arr.is_empty():
			arr = organs.call("viscera_meshes", "uterus")
		for mi in arr:
			if not (mi is MeshInstance3D) or (mi as MeshInstance3D).mesh == null:
				continue
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			if mesh.get_surface_count() < 1:
				continue
			var a: Array = mesh.surface_get_arrays(0)
			if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
				continue
			var P: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var step := maxi(1, P.size() / 80)
			var gxf: Transform3D = (mi as MeshInstance3D).global_transform
			for i in range(0, P.size(), step):
				var p_ab: Vector3 = xf.affine_inverse() * (gxf * P[i])
				if organs.has_method("uterus_straighten_offset_at"):
					p_ab += organs.call("uterus_straighten_offset_at", p_ab)
				if organs.has_method("fundus_lift_offset_at"):
					p_ab += organs.call("fundus_lift_offset_at", p_ab)
				# 与 uterus_ball_offset 相同：球内点被推到 need 半径。
				var need := r
				var d := p_ab - tip_ab
				var dist := d.length()
				var def := p_ab
				if dist < 1e-6:
					def = tip_ab + Vector3(0, need * 0.25, 0)
				elif dist < need:
					def = tip_ab + d / dist * need
				var cl := def.distance_to(tip_ab) - r
				worst = minf(worst, cl)
				n += 1
	if n == 0:
		return 0.0
	return worst


func _physics_process(delta: float) -> void:

	if _root == null or not _root.visible:
		return
	var t0 := Time.get_ticks_usec()
	if caught:
		_follow_cervix()
		last_step_usec = int(Time.get_ticks_usec() - t0)
		return
	if not dragging:
		# 松手后位置跟着活中线，残留慢慢回。
		residual = lerpf(residual, 0.22 if (depth > radius() or through_cervix) else 0.0, clampf(delta * 1.6, 0.0, 1.0))
		if cervix_pulse > 0.0:
			cervix_pulse = maxf(cervix_pulse - delta * 3.5, 0.0)
		_sync_pose(delta)
		_apply_deform()
	else:
		# 拖拽中 _move_from_ray 已经写过；这里只补中线跟随。
		_sync_pose(delta)
	last_step_usec = int(Time.get_ticks_usec() - t0)


# ------------------------------------------------------------------ 0.4.12 子宫脱垂（触发 #1）

func _prolapse() -> Node:
	if organs == null or not organs.has_method("prolapse"):
		return null
	return organs.call("prolapse")


func _prolapse_owns_introitus() -> bool:
	if organs == null or not organs.has_method("has_prolapse") or not bool(organs.call("has_prolapse")):
		return false
	var pc := _prolapse()
	return pc != null and bool(pc.call("owns_introitus"))


func _speculum_owns_introitus() -> bool:
	var s = null
	if mode != null:
		s = mode.get("surgery")
	if s == null and organs != null:
		var p = organs.get("player")
		if p and p.has_method("get_surgery"):
			s = p.call("get_surgery")
	if s == null:
		return false
	if s.has_method("is_speculum_inserted"):
		return bool(s.call("is_speculum_inserted"))
	if s.has_method("is_speculum_present"):
		return bool(s.call("is_speculum_present"))
	return false


func is_caught() -> bool:
	return caught


func _try_prolapse_trigger(_desired: float) -> bool:
	var pc := _prolapse()
	if pc == null:
		return false
	var ctx := {
		"in_uterus": is_in_uterus(),
		"ball_radius": radius(),
		"pull_speed": last_pull_speed,
		"pull_force": last_pull_force,
		"target": tip_world(),
	}
	if not bool(pc.call("try_trigger", "ball_rod", ctx)):
		return false
	caught = true
	prolapse_trigger_count += 1
	cervix_pressure = 0.0
	cervix_pulse = 1.0
	_caught_target = tip_world()
	if not dragging:
		pc.call("end_drive")
	jolt = -_axis_world() * 0.008
	jolt_time = 0.14
	prolapse_caught.emit(true)
	_apply_deform()
	return true


## 卡住时的拖拽点：过球心、尽量正对相机的平面。
func _caught_pointer(origin: Vector3, dir: Vector3) -> Vector3:
	var d := dir.normalized() if dir.length_squared() > 1e-12 else Vector3.FORWARD
	var n := d
	if player and player.has_method("get_camera"):
		var cam: Camera3D = player.call("get_camera")
		if cam:
			n = -cam.global_transform.basis.z
	var p0 := tip_world()
	var den := d.dot(n)
	if absf(den) < 1e-5:
		return p0
	var t := clampf((p0 - origin).dot(n) / den, 0.02, 2.0)
	return origin + d * t


func _drive_caught(origin: Vector3, dir: Vector3) -> void:
	var tgt := _caught_pointer(origin, dir)
	drive_caught_to(tgt)


## 卡住时直接给目标点（世界坐标），自检 / 输入共用。拉过最大脱垂再多 release_over_pull 球就从宫颈脱出。
func drive_caught_to(target: Vector3) -> void:
	var pc := _prolapse()
	if pc == null or not caught:
		return
	_caught_target = target
	if not bool(pc.call("is_driving")):
		pc.call("begin_drive", "ball_rod", 0, target, true)
	pc.call("drive_to", target)
	var dmax := float(pc.call("descent_max"))
	var pp: Resource = pc.get("params")
	var over := float(pp.get("release_over_pull")) if pp else 0.03
	if float(pc.get("descent")) >= dmax - 1e-4:
		var c: Vector3 = pc.call("cervix_world")
		if target.distance_to(c) > over:
			_release_catch(true)
			return
	_follow_cervix()


func _follow_cervix() -> void:
	var pc := _prolapse()
	if pc == null or not bool(pc.call("is_active")):
		# 脱垂被复原（复原按钮 / 手术）：球留在宫腔里，回到普通状态。
		caught = false
		prolapse_caught.emit(false)
		return
	var nodes: PackedVector3Array = pc.call("node_positions")
	if nodes.size() < 2 or _root == null:
		return
	var c := nodes[0]
	var din := (nodes[1] - nodes[0]).normalized()
	if not din.is_finite() or din.length_squared() < 0.5:
		din = _axis_world()
	var pos := c + din * radius() * 0.6
	var z := din
	var up := _up_world()
	var x := up.cross(z)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT.cross(z)
	x = x.normalized()
	var y := z.cross(x).normalized()
	_root.global_transform = Transform3D(Basis(x, y, z), pos)
	# 深度只作参考（沿阴道轴的投影，体外为负）。
	depth = (c - _opening_world()).dot(_axis_world())


## 球离开宫颈：slipped = 往外扯过头 / 缩小后滑出（球到体外）；否则（复原 / 退出）球回到普通状态。
func _release_catch(slipped: bool) -> void:
	if not caught:
		return
	caught = false
	var pc := _prolapse()
	if pc:
		pc.call("end_drive")
	if slipped:
		through_cervix = false
		cervix_pressure = 0.0
		cervix_pulse = 1.0
		uterus_distend = 0.0
		# 球已经在体外：深度放到外面（沿通道轴最外），位置跟手。
		depth = -0.06 - radius()
		lateral = Vector3.ZERO
		if _root:
			var z := _axis_world()
			var up := _up_world()
			var x := up.cross(z)
			if x.length_squared() < 1e-8:
				x = Vector3.RIGHT.cross(z)
			x = x.normalized()
			_root.global_transform = Transform3D(Basis(x, z.cross(x).normalized(), z), _caught_target)
		jolt = -_axis_world() * 0.012
		jolt_time = 0.14
		breakthrough.emit(false)
	prolapse_caught.emit(false)
	_apply_deform()
