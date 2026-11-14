extends Node3D
## 狙击精英式弹道特写：弹道将穿过肠道 / 子宫时，按设置概率进入慢动作 + 透视跟随。
## 同时只播一段；点击 / 触摸 / 按键可跳过；结束后回到原来的相机与时间。

signal started
signal finished

const SLOW := 0.08
const WALL_SEC := 1.7
const CINE_SPEED := 0.55  # 特写里弹头穿过身体的速度（米/秒）

var settings: Node
var player: Node
var playing: bool = false
var last_triggered: bool = false
var last_reason: PackedStringArray = PackedStringArray()
## 测试：>= 0 时替代 randf()
var debug_roll: float = -1.0

var _cam: Camera3D
var _prev: Camera3D
var _prev_xray: Dictionary = {}  # organs -> {on, amount}
var _bullet: Dictionary = {}
var _path_from: Vector3
var _path_to: Vector3
var _t: float = 0.0
var _wall: float = 0.0
var _saved_scale: float = 1.0
var _organs: Node
var _skip_dt: bool = false
var _hud_hidden: CanvasLayer


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
	set_process(true)
	set_process_unhandled_input(true)


func is_playing() -> bool:
	return playing


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
	_organs = info.get("organs")
	_prev = get_viewport().get_camera_3d()
	var entry: Vector3 = info.get("entry", info.get("pos", Vector3.ZERO))
	var exit_v = info.get("exit")
	var dir: Vector3 = info.get("dir", Vector3.FORWARD)
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	_path_from = entry - dir * 0.08
	if exit_v is Vector3:
		_path_to = (exit_v as Vector3) + dir * 0.10
	else:
		_path_to = entry + dir * 0.28
	_t = 0.0
	_wall = 0.0
	_skip_dt = true
	_saved_scale = Engine.time_scale
	Engine.time_scale = SLOW
	# 打开被击中角色的透视
	_prev_xray.clear()
	if _organs:
		_prev_xray["on"] = bool(_organs.get("xray_enabled"))
		_prev_xray["amount"] = float(_organs.get("xray_amount"))
		_organs.call("set_xray_enabled", true)
		if float(_organs.get("xray_amount")) < 0.3:
			_organs.call("set_xray_amount", 0.38)
	_bullet = projectile
	if not _bullet.is_empty():
		_bullet["cinematic"] = true
		_bullet["pos"] = _path_from
	_cam.current = true
	_place_cam(_path_from, dir)
	var hud := get_parent().get_node_or_null("HUD")
	if hud is CanvasLayer:
		_hud_hidden = hud
		hud.visible = false
	started.emit()


func _process(dt: float) -> void:
	if not playing:
		return
	# 用墙钟；单帧上限避免软件渲染/卡顿一帧就把特写放完
	if _skip_dt:
		_skip_dt = false
		_place_cam(_path_from, (_path_to - _path_from).normalized())
		if not _cam.current:
			_cam.current = true
		return
	var wall := dt / maxf(Engine.time_scale, 1e-6)
	wall = minf(wall, 0.04)
	_wall += wall
	var span := _path_from.distance_to(_path_to)
	var dur := maxf(0.6, span / CINE_SPEED)
	_t = minf(1.0, _t + wall / dur)
	var pos := _path_from.lerp(_path_to, _t)
	var dir := (_path_to - _path_from).normalized()
	if not _bullet.is_empty():
		_bullet["pos"] = pos
		_bullet["vel"] = dir * CINE_SPEED
		if _bullet.get("node") and is_instance_valid(_bullet["node"]):
			var n: Node3D = _bullet["node"]
			n.visible = true
			n.global_position = pos
	_place_cam(pos, dir)
	if not _cam.current:
		_cam.current = true
	if _t >= 1.0 or _wall >= WALL_SEC:
		_stop()


func _place_cam(pos: Vector3, dir: Vector3) -> void:
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.9:
		up = Vector3.RIGHT
	var side := dir.cross(up).normalized()
	up = side.cross(dir).normalized()
	# 稍稍后上方、略偏一侧，看着弹头前方
	var eye := pos - dir * 0.12 + up * 0.045 + side * 0.03
	_cam.global_transform = Transform3D(Basis.looking_at(dir, up), eye)


func _stop() -> void:
	if not playing:
		return
	playing = false
	if _hud_hidden and is_instance_valid(_hud_hidden):
		_hud_hidden.visible = true
	_hud_hidden = null
	Engine.time_scale = _saved_scale if _saved_scale > 0.01 else 1.0
	if _organs and is_instance_valid(_organs) and not _prev_xray.is_empty():
		_organs.call("set_xray_enabled", bool(_prev_xray.get("on", true)))
		_organs.call("set_xray_amount", float(_prev_xray.get("amount", 0.38)))
	_prev_xray.clear()
	if not _bullet.is_empty():
		_bullet["cinematic"] = false
	_bullet = {}
	_cam.current = false
	if _prev and is_instance_valid(_prev):
		_prev.current = true
	elif player and player.has_method("get_camera"):
		var c: Camera3D = player.call("get_camera")
		if c:
			c.current = true
	finished.emit()
