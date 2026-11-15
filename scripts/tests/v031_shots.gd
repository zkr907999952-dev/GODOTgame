extends SceneTree
## 0.2.10 肩臂 / HUD / 弹道特写截图（需要显示服务器，不要加 --headless）：
##   SHOT_DIR=/workspace/screenshots/v031 godot --path . -s res://scripts/tests/v031_shots.gd

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


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)


func _save(name: String) -> void:
	await _frames(8)
	var tex := root.get_texture()
	if tex == null:
		push_error("v031_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v031_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v031_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


func _set_look_pitch(rad: float) -> void:
	player.set("_pitch", rad)
	if player.has_method("_sync_pivot"):
		player.set("_pivot_rot", Vector3(rad, float(player.get("_yaw")), 0.0))
		player.call("_sync_pivot")


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v031"
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
		organs.call("set_xray_amount", 0.38)
	# 先拍观察肩臂（与 before_ 同机位）
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	var yaw: float = float(player.get("_yaw"))
	if player.has_method("set_tp_view"):
		player.call("set_tp_view", yaw + 2.7, 0.12, 2.3, true)
	for id in ["smg", "rifle"]:
		await _ready_gun(id)
		await _frames(16)
		if ws.has_method("debug_shoulder_metrics"):
			print("v031_shots: ", id, " front ", ws.call("debug_shoulder_metrics"))
		await _save("after_tp_%s_front.png" % id)
	if player.has_method("set_tp_view"):
		player.call("set_tp_view", yaw + 1.57, 0.05, 2.1, true)
	for id in ["smg", "rifle"]:
		await _ready_gun(id)
		await _frames(14)
		if ws.has_method("debug_shoulder_metrics"):
			print("v031_shots: ", id, " side ", ws.call("debug_shoulder_metrics"))
		await _save("after_tp_%s_side.png" % id)

	# 第一人称姿势
	player.call("set_play_mode", 1)
	_set_look_pitch(0.0)
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _frames(10)
	await _save("after_fp_rifle_hip.png")
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(14)
	await _save("after_fp_rifle_ads.png")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _ready_gun("smg")
	await _frames(10)
	await _save("after_fp_smg_hip.png")
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(12)
	await _save("after_fp_smg_ads.png")
	ws.call("set_ads", false)

	# HUD：触屏布局，血条在武器卡下，按键新位置
	hud.call("set_touch_ui", true)
	await _frames(8)
	await _save("hud_layout_fp.png")
	hud.call("set_touch_ui", false)

	# 弹道特写：从枪口跟随，再拍停在入射点的一帧
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	var cam: Node = main.get_node_or_null("BulletCam")
	if cam:
		cam.call("debug_reset")
		cam.set("debug_roll", 0.0)
		var origin: Vector3 = player.global_position + Vector3(0.0, 1.15, 0.15)
		var dir := Vector3(0, 0, -1)
		if player.has_method("get_camera"):
			var c: Camera3D = player.call("get_camera")
			if c:
				origin = c.global_position
				dir = -c.global_transform.basis.z
		var info := {
			"gut": true,
			"uterus": true,
			"organs": organs,
			"entry": origin + dir * 1.4,
			"exit": origin + dir * 1.7,
			"dir": dir,
			"origin": origin,
			"body": player,
		}
		cam.call("consider", info, {})
		await _frames(6)
		await _save("bullet_cam_follow.png")
		# 推到 park：多等一些墙钟
		var guard := 0
		while str(cam.get("debug_phase")) != "park" and bool(cam.get("playing")) and guard < 80:
			await process_frame
			guard += 1
		await _frames(6)
		await _save("bullet_cam_park.png")
		print("v031_shots: bullet cam phase=", cam.get("debug_phase"), " smoke=", cam.call("smoke_point_count"))
		cam.call("skip")
		await _frames(3)
		if settings:
			settings.call("set_bullet_cam_chance", 0.20)
		cam.set("debug_roll", -1.0)
	print("v031_shots: done dir=", out_dir)
	quit(0)
