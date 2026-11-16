extends SceneTree
## 0.2.13 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v036 godot --path . -s res://scripts/tests/v036_shots.gd

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
		push_error("v036_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v036_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v036_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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
		out_dir = "/workspace/screenshots/v036"
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

	# --- 设置面板：拉扯力度滑条
	player.call("set_play_mode", 0)
	if hud.has_method("open_panel"):
		hud.call("open_panel", 0)  # SETTINGS if enum 0
	# 更稳：点「设置」按钮
	var set_btn: Button = null
	for b in hud.find_children("*", "Button", true, false):
		if b is Button and (b as Button).text == "设置":
			set_btn = b
			break
	if set_btn:
		set_btn.emit_signal("pressed")
	await _frames(8)
	# 把设置列表滚到「受击力度 / 拉扯力度」
	var panel: Node = hud.get("_panel_settings") if hud.get("_panel_settings") != null else hud.find_child("*", true, false)
	if hud.has_method("_panel_scroll"):
		var sc: ScrollContainer = hud.call("_panel_scroll", hud.get("_panel_settings"))
		if sc:
			await _frames(2)
			sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value) if sc.get_v_scroll_bar() else 4000
	else:
		for n in hud.find_children("*", "ScrollContainer", true, false):
			if n is ScrollContainer and (n as ScrollContainer).is_visible_in_tree():
				(n as ScrollContainer).scroll_vertical = 4000
				break
	await _frames(8)
	await _save("settings_pull_force_slider.png")
	if hud.has_method("close_panels"):
		hud.call("close_panels")
	await _frames(4)

	# --- 捂腹：体内点投到皮肤，双手不交叉
	main.call("spawn_clone", player.global_position + Vector3(0.05, 0.0, 0.05))
	await _frames(16)
	await _phys(4)
	var c: Node = main.call("get_clones")[main.call("get_clones").size() - 1]
	_aim_tp(c.global_position + Vector3(0, 1.05, 0), 3.40, 0.18, 1.65)
	await _frames(8)
	# 透视关，避免手看起来像捂在内脏里
	var org: Node = c.call("get_organs") if c.has_method("get_organs") else null
	if org and org.has_method("set_xray_enabled"):
		org.call("set_xray_enabled", false)
	if main.has_method("apply_xray_enabled"):
		main.call("apply_xray_enabled", false)
	var porg: Node = player.call("get_organs")
	if porg and porg.has_method("set_xray_enabled"):
		porg.call("set_xray_enabled", false)
	var inside: Vector3 = c.global_position + Vector3(0, 1.02, 0.0)
	c.call("apply_damage", 16.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": inside})
	# 每帧锁满捂腹权重，避免显示服务器大 delta 把动作冲掉。
	var hr: Node = c.call("get_hit_reaction")
	for i in 16:
		if hr:
			hr.set("cover_life", 100.0)
			hr.set("cover_weight", 1.0)
		await _phys(1)
	_aim_tp(c.global_position + Vector3(0, 1.02, 0.08), 3.88, 0.10, 1.62)
	if hr:
		hr.set("cover_life", 100.0)
		hr.set("cover_weight", 1.0)
	await _frames(4)
	await _save("cover_pose_skin.png")

	# --- 观察模式点击本体开火
	await _ready_gun("pistol")
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0.12)
	if player.has_method("focus_point"):
		var fp = player.call("focus_point", "belly")
		if fp is Vector3:
			belly = fp
	_aim_tp(belly, 3.2, 0.12, 1.8)
	await _frames(8)
	var cam: Camera3D = player.call("get_camera")
	if cam:
		var sp := cam.unproject_position(belly)
		player.call("observe_tap_fire", sp)
	await _frames(8)
	await _save("observe_hit_body.png")
	if ws.has_method("holster"):
		ws.call("holster")

	print("v036_shots: done")
	quit(0)
