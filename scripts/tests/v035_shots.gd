extends SceneTree
## 0.2.13 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v035 godot --path . -s res://scripts/tests/v035_shots.gd

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
		push_error("v035_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v035_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v035_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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
		out_dir = "/workspace/screenshots/v035"
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

	# --- 透视按钮在摄像机左边
	player.call("set_play_mode", 0)
	hud.call("close_panels")
	await _frames(8)
	await _save("xray_button_left_of_camera.png")
	# 打开透视（若已关）
	var org: Node = player.call("get_organs")
	if org and not bool(org.get("xray_enabled")):
		main.call("toggle_xray")
	if hud.has_method("sync"):
		hud.call("sync")
	await _frames(6)
	await _save("xray_button_on.png")

	# --- 地图：默认进投影，侧栏收起 / 展开
	hud.call("toggle_map_panel")
	await _frames(12)
	await _save("map_projection_sidebar_collapsed.png")
	if hud.has_method("toggle_map_sidebar"):
		hud.call("toggle_map_sidebar")
	await _frames(8)
	await _save("map_projection_sidebar_open.png")
	main.call("close_overhead")
	await _frames(4)

	# --- 手机互动切换（触屏 UI）
	player.call("set_play_mode", 1)
	hud.call("set_touch_ui", true)
	await _frames(8)
	await _save("phone_interact_off.png")
	player.call("touch_interact", true, true)
	await _frames(6)
	await _save("phone_interact_toggled_on.png")
	player.call("touch_interact", true, true)
	hud.call("set_touch_ui", false)
	await _frames(4)

	# --- 捂腹姿势（先摆好相机，再在拍照前触发，避免 2.2 秒覆盖在 vsync 下耗尽）
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.05, 0.0, 0.05))
	await _frames(16)
	await _phys(4)
	var c: Node = main.call("get_clones")[main.call("get_clones").size() - 1]
	_aim_tp(c.global_position + Vector3(0, 1.05, 0), 3.40, 0.18, 1.65)
	await _frames(8)
	c.call("apply_damage", 16.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": c.global_position + Vector3(0, 1.02, 0.08)})
	await _phys(5)
	await _frames(3)
	await _save("cover_pose_stomach.png")

	# --- 观察点击射击
	await _ready_gun("pistol")
	var cam: Camera3D = player.call("get_camera")
	if cam:
		player.call("observe_tap_fire", Vector2(640, 360))
	await _frames(8)
	await _save("observe_click_fire_inward.png")
	ws.call("holster")

	# --- 子弹朝向（若能找到弹头网格，拍一张；否则拍特写相关场景）
	if ws.get("ballistics") and ws.get("ballistics").has_method("look_along"):
		await _save("bullet_orient_scene.png")

	print("v035_shots: done")
	quit(0)
