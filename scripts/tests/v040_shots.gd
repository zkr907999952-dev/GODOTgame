extends SceneTree
## 0.2.12 t25u 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v040 godot --path . -s res://scripts/tests/v040_shots.gd

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
		push_error("v040_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v040_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v040_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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


var spawn := Vector3.ZERO


func _home() -> void:
	player.global_position = spawn
	player.velocity = Vector3.ZERO
	player.set("input_locked", false)
	player.set("_yaw", 0.0)
	player.set("_pitch", 0.0)
	player.call("_apply_camera")


func _fp(id: String, ads: bool, pitch: float, name: String) -> void:
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun(id)
	ws.call("set_ads", ads)
	ws.set("_ads_k", 1.0 if ads else 0.0)
	player.set("_pitch", pitch)
	player.call("_apply_camera")
	for i in 10:
		await _phys(1)
	await _save(name)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)


func _tp(id: String, ads: bool, yaw: float, elev: float, dist: float, focus_off: Vector3, name: String) -> void:
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun(id)
	player.call("set_play_mode", 0)
	ws.call("set_ads", ads)
	ws.set("_ads_k", 1.0 if ads else 0.0)
	_aim_tp(player.global_position + focus_off, yaw, elev, dist)
	for i in 12:
		await _phys(1)
	await _save(name)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v040"
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
	spawn = player.global_position
	if OS.get_environment("SHOT_ONLY") == "fp":
		for id in ["rifle", "smg", "shotgun"]:
			await _fp(id, false, 0.0, "fp_%s_hip_level.png" % id)
			await _fp(id, true, 0.0, "fp_%s_ads_level.png" % id)
		quit(0)
		return
	if OS.get_environment("SHOT_ONLY") == "cam":
		await _cam_shots()
		print("v040_shots: done")
		quit(0)
		return

	# 第一人称：各武器腰射/开镜，平视/抬头/低头
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _fp(id, false, 0.0, "fp_%s_hip_level.png" % id)
		await _fp(id, true, 0.0, "fp_%s_ads_level.png" % id)
	await _fp("rifle", false, 0.5, "fp_rifle_hip_look_up.png")
	await _fp("rifle", false, -0.6, "fp_rifle_hip_look_down.png")

	# 观察模式：侧后方（类似附图 1），枪口应平指视线方向
	for id in ["rifle", "smg", "shotgun"]:
		await _tp(id, false, 1.75, 0.05, 2.0, Vector3(0.0, 1.35, 0.0), "observe_side_%s.png" % id)
	# 过肩近景（类似附图 2），看左手是否握在护木/泵动前托上
	for id in ["rifle", "smg", "shotgun"]:
		await _tp(id, false, 2.6, 0.18, 1.45, Vector3(0.05, 1.25, 0.15), "over_shoulder_%s.png" % id)
		await _tp(id, false, -2.2, 0.1, 1.1, Vector3(0.0, 1.2, 0.0), "left_hand_closeup_%s.png" % id)

	# 射击后不应留下悬浮黑点
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun("shotgun")
	var cam3: Camera3D = player.call("get_camera")
	for k in 3:
		var dir := (-cam3.global_transform.basis.z + Vector3(0.05 * k, -0.05, 0.0)).normalized()
		ws.call("fire_along_ray", cam3.global_position, dir, true)
		for i in 30:
			await _phys(1)
	await _tp("shotgun", false, 1.75, 0.05, 2.0, Vector3(0.0, 1.35, 0.0), "observe_after_shots.png")

	await _cam_shots()
	print("v040_shots: done")
	quit(0)


func _cam_shot(id: String, target: Node, cam: Node, name: String) -> void:
	await _ready_gun(id)
	var cam3: Camera3D = player.call("get_camera")
	var organs: Node = target.call("get_organs")
	var belly: Vector3 = (target as Node3D).global_position + Vector3(0, 1.05, 0)
	if organs and organs.has_method("abdomen_frame"):
		belly = (organs.call("abdomen_frame") as Transform3D).origin
	var origin: Vector3 = cam3.global_position
	var dir := (belly - origin).normalized()
	ws.call("fire_along_ray", origin, dir, true)
	var bal: Node = ws.get("ballistics")
	var arr: Array = bal.call("live_projectiles")
	var lead: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
	var info := {"gut": true, "body": target, "organs": organs, "entry": belly, "pos": belly, "exit": belly + dir * 0.22, "dir": dir, "origin": origin}
	cam.call("debug_reset")
	if bool(cam.call("consider", info, lead)):
		cam.call("debug_advance", 0.25)
		await _frames(3)
		print("v040_shots: %s mode=%s n=%d" % [id, str(cam.call("cinematic_mode")), int(cam.call("cinematic_pellet_count"))])
		await _save(name)
		cam.call("skip")
	cam.call("debug_reset")
	for i in 10:
		await _phys(1)


func _cam_shots() -> void:
	player.call("set_play_mode", 1)
	_home()
	var cam3: Camera3D = player.call("get_camera")
	var fwd := -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	main.call("spawn_clone", player.global_position + fwd * 1.8)
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	if clones.is_empty():
		return
	var target: Node = clones[clones.size() - 1]
	var cam: Node = main.get_node_or_null("BulletCam")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	await _cam_shot("shotgun", target, cam, "bulletcam_shotgun_cluster.png")
	await _cam_shot("rifle", target, cam, "bulletcam_rifle_single.png")
	await _cam_shot("pistol", target, cam, "bulletcam_pistol_single.png")
	cam.set("debug_roll", -1.0)
