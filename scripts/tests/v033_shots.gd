extends SceneTree
## 0.2.11 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v033 godot --path . -s res://scripts/tests/v033_shots.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var settings: Node
var out_dir := OS.get_environment("SHOT_DIR")


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _save(name: String) -> void:
	await _frames(6)
	var tex := root.get_texture()
	if tex == null:
		push_error("v033_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v033_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v033_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _aim_tp(focus: Vector3, yaw: float, elev: float, dist: float) -> void:
	player.set("tp_auto_rotate", false)
	player.set("_tp_target_goal", focus - player.global_position)
	player.set("_tp_target", focus - player.global_position)
	player.set("_tp_focus", "")
	player.call("set_tp_view", yaw, elev, dist, true)


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v033"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	if settings:
		settings.call("set_render_scale", 1.0)
	var organs: Node = player.call("get_organs")
	if organs:
		organs.call("set_xray_enabled", true)
		organs.call("set_xray_amount", 0.42)

	# --- 触屏：左侧开火键 + 居中武器轮盘
	player.call("set_play_mode", 1)
	await _ready_gun("rifle")
	hud.call("set_touch_ui", true)
	await _frames(8)
	await _save("touch_left_fire.png")
	hud.call("open_weapon_wheel")
	await _frames(8)
	await _save("weapon_wheel_center.png")
	hud.call("close_weapon_wheel", false)
	hud.call("set_touch_ui", false)

	# --- 布娃娃膝关节 + 尸体透视：观察相机对准尸体
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	var home: Vector3 = player.global_position
	main.call("spawn_clone", home + Vector3(0.15, 0.0, 0.7))
	await _frames(16)
	await _phys(4)
	var c: Node = main.call("get_clones")[0]
	var org: Node = c.call("get_organs")
	if organs:
		organs.call("set_xray_enabled", false)
	if org:
		org.call("set_xray_enabled", true)
		org.call("set_xray_amount", 0.62)
	c.call("apply_damage", 200.0, {
		"zone": "body",
		"dir": Vector3(0.15, 0.4, -0.5).normalized(),
		"entry": c.global_position + Vector3(0, 1.15, 0),
		"par": {"impulse": 0.38, "category": "rifle"},
	})
	await _phys(40)
	await _frames(8)
	var rag: Node = c.call("get_ragdoll")
	var focus: Vector3 = rag.call("get_follow_point") if rag else c.global_position + Vector3(0, 0.6, 0)
	_aim_tp(focus, 0.95, 0.32, 2.25)
	await _frames(10)
	await _save("ragdoll_knees_limited.png")
	if org:
		org.call("set_xray_enabled", true)
		org.call("set_xray_amount", 0.72)
	_aim_tp(focus, 1.15, 0.42, 1.7)
	await _frames(10)
	await _save("corpse_xray_on.png")
	if org:
		org.call("set_xray_enabled", false)
	await _frames(6)
	await _save("corpse_xray_off.png")
	if org:
		org.call("set_xray_enabled", true)
		org.call("set_xray_amount", 0.72)

	# --- 尸体触发特写：控制模式 + 穿过后立刻拍 hold，避免墙钟把 4 秒走完
	player.call("set_play_mode", 1)
	await _frames(3)
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	var bcam: Node = main.get("bullet_cam")
	if bcam:
		bcam.call("debug_reset")
		bcam.set("debug_roll", 0.0)
		var entry: Vector3 = org.call("abdomen_frame").origin if org and org.has_method("abdomen_frame") else focus
		var dir := Vector3(0.2, -0.05, -1).normalized()
		var info := {
			"gut": true, "uterus": false, "organs": org,
			"entry": entry, "exit": entry + dir * 0.28,
			"dir": dir, "origin": entry - dir * 0.7,
			"body": c, "hit": true,
		}
		var did: bool = bool(bcam.call("consider", info, {}))
		print("v033_shots: corpse cam started=", did, " phase=", bcam.get("debug_phase"))
		if did:
			bcam.call("debug_advance", 0.18)
			await _save("corpse_bullet_cam_follow.png")
			var guard := 0
			while str(bcam.get("debug_phase")) != "hold" and bool(bcam.get("playing")) and guard < 40:
				bcam.call("debug_advance", 0.12)
				guard += 1
			print("v033_shots: hold phase=", bcam.get("debug_phase"), " hold_t=", bcam.get("_hold_t"))
			await _save("bullet_cam_hold.png")
			bcam.call("skip")
			player.call("set_play_mode", 0)
			_aim_tp(focus, 0.95, 0.32, 2.25)
			await _frames(8)
			await _save("bullet_cam_restored.png")

	print("v033_shots: done")
	quit(0)
