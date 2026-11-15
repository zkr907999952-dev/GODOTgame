extends Node3D
## 狙击精英式弹道特写：判定本发将命中肠道 / 子宫后，慢动作从枪口跟随弹头，
## 弹头进入人体后相机停在受击点附近环绕，并以局部球形透视观察弹道与脏器受击。
## 同时只播一段；连发不会叠加或重开；点击 / 触摸 / 按键可跳过；结束后恢复时间与相机。

signal started
signal finished

const SLOW := 0.08
const WALL_MAX := 3.2
const FLY_SPEED := 8.5  # 特写里弹头在空气中的视速（米/秒，墙钟）
const PARK_SEC := 1.15
const COOLDOWN_SEC := 0.9
const SPHERE_R := 0.16
const SMOKE_FADE := 0.75
const SMOKE_DELAY := 0.05
const SMOKE_WIDTH := 0.012

var settings: Node
var player: Node
var playing: bool = false
var last_triggered: bool = false
var last_reason: PackedStringArray = PackedStringArray()
## 测试：>= 0 时替代 randf()
var debug_roll: float = -1.0
## 测试/截图：follow / park / idle
var debug_phase: String = "idle"

var _cam: Camera3D
var _prev: Camera3D
var _prev_xray: Dictionary = {}  # organs -> {on, amount, show}
var _bullet: Dictionary = {}
var _muzzle: Vector3
var _entry: Vector3
var _exit: Vector3
var _dir: Vector3
var _t: float = 0.0
var _wall: float = 0.0
var _park_t: float = 0.0
var _phase: String = "idle"
var _saved_scale: float = 1.0
var _organs: Node
var _skip_dt: bool = false
var _hud_hidden: CanvasLayer
var _cooldown: float = 0.0
var _burst_lock: bool = false
var _park_eye0: Vector3 = Vector3.ZERO
var _smoke_pts: Array = []  # {p, age}
var _smoke_mi: MeshInstance3D
var _smoke_mesh: ImmediateMesh
var _smoke_wait: float = 0.0


func setup(p: Node, s: Node) -> void:
	player = p
	settings = s
	_cam = Camera3D.new()
	_cam.name = "BulletCam"
	_cam.current = false
	_cam.fov = 42.0
	_cam.near = 0.02
	_cam.far = 80.0
	add_child(_cam)
	_build_smoke()
	set_process(true)
	set_process_unhandled_input(true)


func is_playing() -> bool:
	return playing


func has_smoke_trail() -> bool:
	return _smoke_mi != null and is_instance_valid(_smoke_mi)


func smoke_point_count() -> int:
	return _smoke_pts.size()


func debug_reset() -> void:
	if playing:
		_stop()
	_cooldown = 0.0
	_burst_lock = false
	debug_phase = "idle"


func skip() -> void:
	if playing:
		_stop()


func _unhandled_input(event: InputEvent) -> void:
	if not playing:
		return
	var go := false
	if event is InputEventKey and event.pressed and not event.echo:
		go = true
	elif event is InputEventMouseButton and event.pressed:
		go = true
	elif event is InputEventScreenTouch and event.pressed:
		go = true
	if go:
		_stop()
		get_viewport().set_input_as_handled()


func consider(info: Dictionary, projectile: Dictionary = {}) -> bool:
	last_triggered = false
	last_reason = PackedStringArray()
	if playing:
		return false
	# 连发：特写进行中或刚结束（扳机还按着 / 冷却）不再开下一段。调试 roll 可绕过冷却以便自检。
	if debug_roll < 0.0 and (_cooldown > 0.0 or _burst_lock):
		return false
	if settings == null or not bool(settings.get("bullet_cam_enabled")):
		return false
	if player and not bool(player.get("first_person")) and player.has_method("is_display_mode"):
		# 只在角色控制（可第一人称）下触发；展示模式不抢观察相机
		if bool(player.call("is_display_mode")):
			return false
	var gut := bool(info.get("gut", false))
	var ut := bool(info.get("uterus", false))
	if not gut and not ut:
		return false
	if gut:
		last_reason.append("gut")
	if ut:
		last_reason.append("uterus")
	var roll := debug_roll if debug_roll >= 0.0 else randf()
	var chance := float(settings.get("bullet_cam_chance"))
	if roll >= chance:
		return false
	_start(info, projectile)
	return true


func _start(info: Dictionary, projectile: Dictionary) -> void:
	playing = true
	last_triggered = true
	_burst_lock = true
	_organs = info.get("organs")
	_prev = get_viewport().get_camera_3d()
	_dir = info.get("dir", Vector3.FORWARD)
	if _dir.length_squared() < 1e-8:
		_dir = Vector3.FORWARD
	_dir = _dir.normalized()
	_entry = info.get("entry", info.get("pos", Vector3.ZERO))
	var exit_v = info.get("exit")
	if exit_v is Vector3:
		_exit = exit_v
	else:
		_exit = _entry + _dir * 0.28
	# 从枪口开始跟随：优先弹头/查询里的 origin，否则从入射点往回退一段。
	var muz = info.get("origin", info.get("muzzle", null))
	if muz is Vector3 and (_entry - muz).length() > 0.05:
		_muzzle = muz
	elif not projectile.is_empty() and projectile.get("origin") is Vector3:
		_muzzle = projectile["origin"]
	else:
		_muzzle = _entry - _dir * 0.85
	_t = 0.0
	_wall = 0.0
	_park_t = 0.0
	_phase = "follow"
	debug_phase = "follow"
	_skip_dt = true
	_saved_scale = Engine.time_scale if Engine.time_scale > 0.01 else 1.0
	Engine.time_scale = SLOW
	_prev_xray.clear()
	if _organs and is_instance_valid(_organs):
		_prev_xray["on"] = bool(_organs.get("xray_enabled"))
		_prev_xray["amount"] = float(_organs.get("xray_amount"))
		_prev_xray["show"] = bool(_organs.get("show_organs")) if _organs.get("show_organs") != null else true
		if _organs.has_method("set_show_organs") and not bool(_prev_xray["show"]):
			_organs.call("set_show_organs", true)
		# 用局部球透视，不打开全身透视窗；结束时清球并恢复原状态。
		if _organs.has_method("set_xray_sphere_world"):
			_organs.call("set_xray_sphere_world", _muzzle, SPHERE_R, 0.95)
	_bullet = projectile
	if not _bullet.is_empty():
		_bullet["cinematic"] = true
		_bullet["pos"] = _muzzle
	_smoke_pts.clear()
	_smoke_wait = 0.0
	_cam.current = true
	_place_follow(_muzzle)
	var hud := get_parent().get_node_or_null("HUD")
	if hud is CanvasLayer:
		_hud_hidden = hud
		hud.visible = false
	started.emit()


func _process(dt: float) -> void:
	# 冷却按墙钟走，即使没在播放也要减完，避免连发刚结束又立刻开下一段。
	var wall := dt / maxf(Engine.time_scale, 1e-6)
	wall = minf(wall, 0.05)
	if not playing:
		if _cooldown > 0.0:
			_cooldown = maxf(0.0, _cooldown - wall)
		_update_burst_lock()
		return
	if _skip_dt:
		_skip_dt = false
		_place_follow(_muzzle)
		if not _cam.current:
			_cam.current = true
		return
	_wall += wall
	if _phase == "follow":
		var span := maxf(0.15, _muzzle.distance_to(_entry))
		var dur := maxf(0.28, span / FLY_SPEED)
		_t = minf(1.0, _t + wall / dur)
		var pos := _muzzle.lerp(_entry, _t)
		_place_bullet(pos, _dir)
		_place_follow(pos)
		_push_smoke(pos, wall)
		_set_sphere(pos)
		if _t >= 1.0:
			_enter_park()
	elif _phase == "park":
		_park_t += wall
		# 弹头在体内继续走完短通道，相机不再跟随。
		var in_span := maxf(0.08, _entry.distance_to(_exit))
		var in_u := clampf(_park_t / maxf(0.35, in_span / 0.55), 0.0, 1.0)
		var bpos := _entry.lerp(_exit + _dir * 0.04, in_u)
		_place_bullet(bpos, _dir)
		_push_smoke(bpos, wall)
		_set_sphere(_entry.lerp(bpos, 0.45))
		_place_park(_park_t)
		if _park_t >= PARK_SEC or _wall >= WALL_MAX:
			_stop()
	if playing and not _cam.current:
		_cam.current = true
	if _wall >= WALL_MAX and playing:
		_stop()


func _enter_park() -> void:
	_phase = "park"
	debug_phase = "park"
	_park_t = 0.0
	var up := Vector3.UP
	if absf(_dir.dot(up)) > 0.9:
		up = Vector3.RIGHT
	var side := _dir.cross(up).normalized()
	up = side.cross(_dir).normalized()
	# 停在入射点侧后上方的合适距离，不要再贴着弹头飞。
	_park_eye0 = _entry - _dir * 0.22 + up * 0.10 + side * 0.14


func _place_follow(pos: Vector3) -> void:
	var up := Vector3.UP
	if absf(_dir.dot(up)) > 0.9:
		up = Vector3.RIGHT
	var side := _dir.cross(up).normalized()
	up = side.cross(_dir).normalized()
	var eye := pos - _dir * 0.14 + up * 0.05 + side * 0.035
	_cam.global_transform = Transform3D(Basis.looking_at(_dir, up), eye)


func _place_park(t: float) -> void:
	var up := Vector3.UP
	var rel: Vector3 = _park_eye0 - _entry
	var ang := t * 0.55
	var rot := Basis(up, ang)
	var eye: Vector3 = _entry + rot * rel
	var look := (_entry - eye)
	if look.length_squared() < 1e-8:
		look = _dir
	_cam.global_transform = Transform3D(Basis.looking_at(look.normalized(), up), eye)


func _place_bullet(pos: Vector3, dir: Vector3) -> void:
	if _bullet.is_empty():
		return
	_bullet["pos"] = pos
	_bullet["vel"] = dir * FLY_SPEED
	if _bullet.get("node") and is_instance_valid(_bullet["node"]):
		var n: Node3D = _bullet["node"]
		n.visible = true
		n.global_position = pos
		if dir.length_squared() > 1e-8:
			n.look_at(pos + dir, Vector3.UP)


func _set_sphere(pos: Vector3) -> void:
	if _organs and is_instance_valid(_organs) and _organs.has_method("set_xray_sphere_world"):
		_organs.call("set_xray_sphere_world", pos, SPHERE_R, 0.95)


func _update_burst_lock() -> void:
	if not _burst_lock:
		return
	var trig := false
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws:
			trig = bool(ws.get("trigger"))
	if not trig:
		_burst_lock = false


func _stop() -> void:
	if not playing:
		return
	playing = false
	_phase = "idle"
	debug_phase = "idle"
	_cooldown = COOLDOWN_SEC
	if _hud_hidden and is_instance_valid(_hud_hidden):
		_hud_hidden.visible = true
	_hud_hidden = null
	Engine.time_scale = _saved_scale if _saved_scale > 0.01 else 1.0
	if _organs and is_instance_valid(_organs):
		if _organs.has_method("clear_xray_sphere"):
			_organs.call("clear_xray_sphere")
		if not _prev_xray.is_empty():
			_organs.call("set_xray_enabled", bool(_prev_xray.get("on", false)))
			_organs.call("set_xray_amount", float(_prev_xray.get("amount", 0.38)))
			if _organs.has_method("set_show_organs") and _prev_xray.has("show"):
				_organs.call("set_show_organs", bool(_prev_xray["show"]))
	_prev_xray.clear()
	if not _bullet.is_empty():
		_bullet["cinematic"] = false
	_bullet = {}
	_smoke_pts.clear()
	_rebuild_smoke()
	_cam.current = false
	if _prev and is_instance_valid(_prev):
		_prev.current = true
	elif player and player.has_method("get_camera"):
		var c: Camera3D = player.call("get_camera")
		if c:
			c.current = true
	finished.emit()


func _build_smoke() -> void:
	if _smoke_mi:
		return
	_smoke_mesh = ImmediateMesh.new()
	_smoke_mi = MeshInstance3D.new()
	_smoke_mi.name = "BulletSmokeTrail"
	_smoke_mi.mesh = _smoke_mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.93, 0.94, 0.96, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.86, 0.88, 0.92)
	mat.emission_energy_multiplier = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	_smoke_mi.material_override = mat
	_smoke_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_smoke_mi)


func _push_smoke(pos: Vector3, wall: float) -> void:
	_smoke_wait += wall
	# 略微滞后于弹头，形成拖在后面的白烟。
	if _smoke_wait >= SMOKE_DELAY or _smoke_pts.is_empty():
		_smoke_wait = 0.0
		if _smoke_pts.is_empty() or pos.distance_to(_smoke_pts[_smoke_pts.size() - 1]["p"]) > 0.012:
			_smoke_pts.append({"p": pos, "age": 0.0})
	var i := 0
	while i < _smoke_pts.size():
		_smoke_pts[i]["age"] = float(_smoke_pts[i]["age"]) + wall
		if float(_smoke_pts[i]["age"]) > SMOKE_FADE:
			_smoke_pts.remove_at(i)
		else:
			i += 1
	while _smoke_pts.size() > 80:
		_smoke_pts.remove_at(0)
	_rebuild_smoke()


func _rebuild_smoke() -> void:
	if _smoke_mesh == null:
		return
	_smoke_mesh.clear_surfaces()
	if _smoke_pts.size() < 2:
		return
	_smoke_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(_smoke_pts.size()):
		var a: Vector3 = _smoke_pts[i]["p"]
		var nxt: Vector3 = _smoke_pts[mini(i + 1, _smoke_pts.size() - 1)]["p"]
		var prv: Vector3 = _smoke_pts[maxi(i - 1, 0)]["p"]
		var tan: Vector3 = nxt - prv
		if tan.length_squared() < 1e-10:
			tan = _dir
		tan = tan.normalized()
		var side := tan.cross(Vector3.UP)
		if side.length_squared() < 1e-8:
			side = tan.cross(Vector3.RIGHT)
		side = side.normalized() * SMOKE_WIDTH
		var age := float(_smoke_pts[i]["age"])
		var alpha := clampf(1.0 - age / SMOKE_FADE, 0.0, 1.0)
		alpha *= 0.72
		var col := Color(0.93, 0.95, 0.97, alpha)
		_smoke_mesh.surface_set_color(col)
		_smoke_mesh.surface_add_vertex(a + side)
		_smoke_mesh.surface_set_color(col)
		_smoke_mesh.surface_add_vertex(a - side)
	_smoke_mesh.surface_end()
