extends SceneTree
## 0.2.12 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v034 godot --path . -s res://scripts/tests/v034_shots.gd

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
		push_error("v034_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v034_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v034_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


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
		out_dir = "/workspace/screenshots/v034"
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
		organs.call("set_xray_amount", 0.55)

	# --- 拳交：腹部鼓包，肠子跟随
	player.call("set_play_mode", 0)
	if organs:
		organs.call("set_interact_mode", "fist")
		if organs.get("tools"):
			organs.get("tools").call("set_fist_enabled", true)
			organs.get("tools").set("fist_stir", true)
			organs.get("tools").set("fist_gut", 1.3)
			organs.get("tools").set("fist_bulge", 1.8)
		if organs.has_method("set_tool_depth01"):
			organs.call("set_tool_depth01", 0.78)
		elif organs.get("tools") and organs.get("tools").has_method("fist_set_depth01"):
			organs.get("tools").call("fist_set_depth01", 0.78)
	_aim_tp(player.global_position + Vector3(0, 1.05, 0.05), 0.35, 0.15, 1.45)
	await _frames(16)
	await _save("fist_intestine_follow.png")

	# --- 触屏：武器/换弹对调、拖拽在开火位、玩家 1000 血
	player.call("set_play_mode", 1)
	await _ready_gun("pistol")
	hud.call("set_touch_ui", true)
	await _frames(8)
	if hud.has_method("_refresh_player_hp"):
		hud.call("_refresh_player_hp")
	await _save("touch_weapon_reload_swap.png")
	ws.call("holster")
	for i in 20:
		if ws.has_method("debug_finish_state"):
			ws.call("debug_finish_state")
		await _frames(1)
		if not bool(ws.call("is_armed")):
			break

	# --- 尸体拖拽
	var home: Vector3 = player.global_position
	main.call("spawn_clone", home + Vector3(0.2, 0.0, -0.55))
	await _frames(16)
	await _phys(4)
	var c: Node = main.call("get_clones")[0]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0.2, 1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.35, "category": "pistol"}})
	await _phys(20)
	var rag: Node = c.call("get_ragdoll")
	var chest: Vector3 = rag.call("get_follow_point") if rag else c.global_position
	player.global_position = Vector3(chest.x + 0.28, player.global_position.y, chest.z + 0.15)
	var drag: Node = player.call("get_corpse_drag")
	drag.call("debug_aim", c, "C_Spine_c", chest)
	player.call("toggle_corpse_drag")
	for i in 40:
		drag.call("physics_tick", 0.016)
		await _phys(1)
		if not bool(drag.get("reaching")):
			break
	if hud.has_method("_refresh_corpse_drag_btn"):
		hud.call("_refresh_corpse_drag_btn")
	await _save("corpse_drag_fire_slot.png")
	hud.call("set_touch_ui", false)
	await _frames(4)
	await _save("corpse_drag_pull.png")
	if drag.call("is_dragging"):
		player.call("toggle_corpse_drag")

	# --- 受击力度 + 更强推动
	if settings:
		settings.call("set_hit_force", 1.6)
	main.call("spawn_clone", player.global_position + Vector3(0.15, 0.0, -0.7))
	await _frames(12)
	var c2: Node = main.call("get_clones")[main.call("get_clones").size() - 1]
	c2.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0.2, 0.25, -0.7).normalized(), "entry": c2.global_position + Vector3(0, 1.15, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(24)
	var f2: Vector3 = c2.call("get_ragdoll").call("get_follow_point")
	_aim_tp(f2, 0.9, 0.35, 2.2)
	await _frames(8)
	await _save("ragdoll_bullet_shove.png")
	if settings:
		settings.call("set_hit_force", 1.0)
	# 设置面板
	player.call("set_play_mode", 0)
	if hud.has_method("_toggle_panel"):
		hud.call("_toggle_panel", 1)  # SETTINGS
	await _frames(8)
	await _save("settings_hit_force.png")
	hud.call("close_panels")

	# --- 地图点选 / 平移两帧
	main.call("open_overhead")
	await _frames(10)
	await _save("map_before_pan.png")
	var mv: Node = main.get("map_view")
	var pan0: Vector2 = mv.get("pan")
	var e0 := InputEventScreenTouch.new()
	e0.index = 0
	e0.position = Vector2(640, 360)
	e0.pressed = true
	root.push_input(e0)
	var d := InputEventScreenDrag.new()
	d.index = 0
	d.position = Vector2(820, 430)
	d.relative = Vector2(180, 70)
	root.push_input(d)
	var e1 := InputEventScreenTouch.new()
	e1.index = 0
	e1.position = Vector2(820, 430)
	e1.pressed = false
	root.push_input(e1)
	await _frames(6)
	await _save("map_after_pan.png")
	var t0 := InputEventScreenTouch.new()
	t0.index = 0
	t0.position = Vector2(600, 340)
	t0.pressed = true
	root.push_input(t0)
	var t1 := InputEventScreenTouch.new()
	t1.index = 0
	t1.position = Vector2(600, 340)
	t1.pressed = false
	root.push_input(t1)
	await _frames(6)
	await _save("map_tap_teleport.png")
	main.call("close_overhead")

	# --- 踩踏尸体
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.55))
	await _frames(12)
	await _phys(2)
	var c_stomp: Node = main.call("get_clones")[main.call("get_clones").size() - 1]
	c_stomp.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, -1, 0), "entry": c_stomp.global_position + Vector3(0, 1.0, 0), "par": {"impulse": 0.3, "category": "pistol"}})
	await _phys(10)
	var follow: Vector3 = c_stomp.call("get_ragdoll").call("get_follow_point")
	player.call("set_play_mode", 1)
	player.global_position = Vector3(follow.x, maxf(0.0, follow.y) + 0.02, follow.z)
	player.velocity = Vector3(0, -1.5, 0)
	await _phys(16)
	player.call("set_play_mode", 0)
	_aim_tp(follow, 1.1, 0.55, 2.0)
	await _frames(8)
	await _save("stomp_ragdoll.png")

	# --- 互动含武器菜单，无独立武器按钮
	if hud.has_method("toggle_weapon_panel"):
		hud.call("toggle_weapon_panel")
	await _frames(8)
	await _save("interact_weapon_menu.png")
	hud.call("close_panels")

	# --- 观察点击射击 + 捂腹 + 血量
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.1, 0.0, 0.8))
	await _frames(14)
	var c3: Node = main.call("get_clones")[main.call("get_clones").size() - 1]
	c3.call("apply_damage", 18.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, -1), "entry": c3.global_position + Vector3(0, 1.05, 0.08)})
	await _phys(6)
	_aim_tp(c3.global_position + Vector3(0, 1.1, 0), 3.4, 0.2, 1.8)
	await _frames(8)
	await _save("clone_cover_organ.png")
	await _ready_gun("pistol")
	var cam: Camera3D = player.call("get_camera")
	if cam:
		player.call("observe_tap_fire", cam.unproject_position(c3.global_position + Vector3(0, 1.15, 0)))
	await _frames(8)
	await _save("observe_click_fire.png")
	ws.call("holster")
	if hud.has_method("_refresh_player_hp"):
		hud.call("_refresh_player_hp")
	await _save("player_hp_1000.png")

	print("v034_shots: done")
	quit(0)
