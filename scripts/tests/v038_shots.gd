extends SceneTree
## 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v038 godot --path . -s res://scripts/tests/v038_shots.gd

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
		push_error("v038_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v038_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v038_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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
		out_dir = "/workspace/screenshots/v038"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 30
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	if settings:
		settings.call("set_render_scale", 1.0)
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)

	# --- 低头持枪：腰部枢轴 + 手臂下移，不弯腰
	player.call("set_play_mode", 1)
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	await _phys(6)
	await _save("look_level_armed.png")

	player.set("_pitch", -0.70)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for i in 8:
		await _phys(1)
	await _frames(6)
	await _save("look_down_waist_pivot.png")

	# 开镜握持
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	player.set("_pitch", -0.25)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for i in 8:
		await _phys(1)
	await _save("hands_on_rifle_ads.png")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)

	# --- 霰弹特写：多弹头白色弹道，朝前方分身腹部开火
	player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	await _ready_gun("shotgun")
	var cam3: Camera3D = player.call("get_camera") if player.has_method("get_camera") else null
	var fwd := Vector3(0, 0, -1)
	if cam3:
		fwd = -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	main.call("spawn_clone", player.global_position + fwd * 1.8)
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	var target: Node = clones[clones.size() - 1] if not clones.is_empty() else player
	var organs: Node = target.call("get_organs")
	var cam: Node = main.get_node_or_null("BulletCam")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	if cam:
		cam.set("debug_roll", 0.0)
		cam.call("debug_reset")
	var origin: Vector3 = cam3.global_position if cam3 else player.global_position + Vector3(0, 1.5, 0)
	var belly: Vector3 = (target as Node3D).global_position + Vector3(0, 1.05, 0)
	if organs and organs.has_method("abdomen_frame"):
		belly = (organs.call("abdomen_frame") as Transform3D).origin
	var dir := (belly - origin).normalized()
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, dir, true)
	var bal: Node = ws.get("ballistics")
	var lead := {}
	if bal and bal.has_method("live_projectiles"):
		var arr: Array = bal.call("live_projectiles")
		if not arr.is_empty() and arr[0] is Dictionary:
			lead = arr[0]
	var info := {
		"gut": true, "body": target, "organs": organs,
		"entry": belly, "pos": belly, "exit": belly + dir * 0.22,
		"dir": dir, "origin": origin,
	}
	if cam:
		cam.call("consider", info, lead)
		if bool(cam.get("playing")):
			cam.call("debug_advance", 0.30)
			await _frames(3)
			await _save("shotgun_cinematic_trails.png")
			cam.call("debug_advance", 0.40)
			await _frames(3)
			await _save("shotgun_cinematic_trails_late.png")
			cam.call("debug_advance", 0.9)
			await _frames(3)
			await _save("organ_jello_park.png")
			cam.call("debug_advance", 0.8)
			await _frames(3)
			await _save("organ_jello_hold.png")
			cam.call("skip")
			cam.call("debug_reset")
		cam.set("debug_roll", -1.0)

	# 第三人称看持枪握持
	player.set("_pitch", -0.15)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	await _ready_gun("rifle")
	player.call("set_play_mode", 0)
	var focus: Vector3 = player.global_position + Vector3(0.05, 1.25, 0.15)
	_aim_tp(focus, 2.6, 0.18, 1.55)
	for i in 10:
		await _phys(1)
	await _save("tp_hands_on_rifle.png")

	print("v038_shots: done")
	quit(0)
