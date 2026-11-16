extends SceneTree
## 0.2.13 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v037 godot --path . -s res://scripts/tests/v037_shots.gd

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
		push_error("v037_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v037_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v037_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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
		out_dir = "/workspace/screenshots/v037"
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

	# --- 设置面板：武器无需换弹
	player.call("set_play_mode", 0)
	var set_btn: Button = null
	for b in hud.find_children("*", "Button", true, false):
		if b is Button and (b as Button).text == "设置":
			set_btn = b
			break
	if set_btn:
		set_btn.emit_signal("pressed")
	await _frames(8)
	for n in hud.find_children("*", "ScrollContainer", true, false):
		if n is ScrollContainer and (n as ScrollContainer).is_visible_in_tree():
			(n as ScrollContainer).scroll_vertical = 2500
			break
	await _frames(8)
	await _save("settings_no_reload.png")
	if hud.has_method("close_panels"):
		hud.call("close_panels")
	await _frames(4)

	# --- 准星：空手白点、髋射十字、开镜隐藏
	player.call("set_play_mode", 1)
	if ws.has_method("holster"):
		ws.call("holster")
		for i in 8:
			ws.call("debug_finish_state")
			await _frames(1)
	player.set("_pitch", -0.12)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	await _frames(6)
	await _save("reticle_unarmed_dot.png")

	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _frames(6)
	await _save("reticle_hip_cross.png")

	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(8)
	await _save("reticle_ads_hidden.png")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)

	# --- 低头持枪：武器应落在中下腹附近并跟着视线
	player.set("_pitch", -0.70)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for i in 8:
		await _phys(1)
	await _frames(6)
	await _save("look_down_weapon.png")
	player.set("_pitch", -0.12)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")

	# --- 武器轮盘中心收枪圈
	if hud.has_method("open_weapon_wheel"):
		hud.call("open_weapon_wheel")
	elif hud.get("wheel"):
		hud.get("wheel").call("open")
	await _frames(8)
	await _save("weapon_wheel_holster.png")
	if hud.has_method("close_weapon_wheel"):
		hud.call("close_weapon_wheel", false)
	elif hud.get("wheel"):
		hud.get("wheel").call("close", false)
	await _frames(4)

	# --- 捂腹：拍玩家本体（避免分身和玩家重叠），从正面绕拍。
	if ws.has_method("holster"):
		ws.call("holster")
		for i in 30:
			if ws.has_method("debug_finish_state"):
				ws.call("debug_finish_state")
			await _frames(1)
			await _phys(1)
			if not bool(ws.call("is_armed")):
				break
	player.call("set_play_mode", 0)
	var porg: Node = player.call("get_organs")
	if porg and porg.has_method("set_xray_enabled"):
		porg.call("set_xray_enabled", false)
	if main.has_method("apply_xray_enabled"):
		main.call("apply_xray_enabled", false)
	var belly: Vector3 = player.global_position + Vector3(0, 1.02, 0.12)
	if porg and porg.has_method("project_skin"):
		belly = porg.call("project_skin", belly)
	var hr: Node = player.call("get_hit_reaction")
	if hr and hr.has_method("start_cover"):
		hr.call("start_cover", belly)
	for i in 18:
		if hr:
			hr.set("cover_life", 100.0)
			hr.set("cover_weight", 1.0)
			var loco = player.call("get_loco") if player.has_method("get_loco") else null
			if loco:
				loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
			hr.call("apply_cover", 0.0)
		await _phys(1)
	_aim_tp(player.global_position + Vector3(0, 1.02, 0.10), 3.40, 0.16, 1.70)
	if hr:
		hr.set("cover_life", 100.0)
		hr.set("cover_weight", 1.0)
		hr.call("apply_cover", 0.0)
	for i in 6:
		if hr:
			hr.set("cover_life", 100.0)
			hr.set("cover_weight", 1.0)
			var loco2 = player.call("get_loco") if player.has_method("get_loco") else null
			if loco2:
				loco2.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
			hr.call("apply_cover", 0.0)
		await _phys(1)
		await _frames(1)
	await _save("cover_pose_redone.png")

	print("v037_shots: done")
	quit(0)
