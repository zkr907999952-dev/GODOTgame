extends SceneTree
## 0.2.11 预备截图（需要显示服务器，不要加 --headless）：
##   SHOT_DIR=/workspace/screenshots/v032 godot --path . -s res://scripts/tests/v032_shots.gd

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
	await _frames(8)
	var tex := root.get_texture()
	if tex == null:
		push_error("v032_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v032_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v032_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v032"
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
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)

	# --- 左右移动身体姿势（观察视角）
	# 写好姿势后把 loco 冻住，避免 _physics_process 用待机覆盖。
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	var yaw: float = float(player.get("_yaw"))
	if player.has_method("set_tp_view"):
		player.call("set_tp_view", yaw + 3.05, 0.05, 2.55, true)
	var loco: Node = player.call("get_loco")
	if loco:
		loco.call("set_mode", "stand")
		loco.set("frozen", false)
		loco.set("phase", 0.32)
		if loco.has_method("_reset_blend_for_debug"):
			loco.call("_reset_blend_for_debug")
		loco.call("apply_pose", 0.0, -1.0, 1.0, false, false, 0.016, 1.06)
		loco.set("frozen", true)
	await _frames(12)
	await _save("strafe_walk_left.png")
	if loco:
		loco.set("frozen", false)
		loco.set("phase", 0.32)
		if loco.has_method("_reset_blend_for_debug"):
			loco.call("_reset_blend_for_debug")
		loco.call("apply_pose", 0.0, 1.0, 1.0, false, false, 0.016, 1.06)
		loco.set("frozen", true)
	await _frames(12)
	await _save("strafe_walk_right.png")
	if loco:
		loco.set("frozen", false)
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)

	# --- 活体受击抖动：分身站在本体右侧，冻住姿势后只叠抖动
	main.call("spawn_clone", player.global_position + Vector3(0.7, 0.0, 0.15))
	await _frames(16)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[0] if not clones.is_empty() else null
	if c:
		var cloco: Node = c.get("loco")
		if cloco:
			cloco.set("frozen", false)
			cloco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)
		c.call("apply_damage", 34.0, {
			"zone": "body",
			"dir": Vector3(-0.4, 0.15, 1).normalized(),
			"entry": c.global_position + Vector3(0, 1.18, 0.08),
		})
		if c.has_method("get_hit_reaction"):
			var hr: Node = c.call("get_hit_reaction")
			if hr:
				hr.call("apply_to_skeleton", 0.016, PackedStringArray(["L_Shoulder_a", "R_Shoulder_a"]))
		if cloco:
			cloco.set("frozen", true)
	if player.has_method("set_tp_view"):
		player.call("set_tp_view", yaw + 3.2, 0.06, 2.35, true)
	await _frames(4)
	await _save("live_hit_react.png")
	if c and c.get("loco"):
		c.get("loco").set("frozen", false)

	# --- 子弹球体撞击尸体
	if c and not bool(c.call("is_dead")):
		c.call("apply_damage", 200.0, {
			"zone": "body",
			"dir": Vector3(1, 0.1, 0),
			"entry": c.global_position + Vector3(0, 1.1, 0),
			"par": {"impulse": 0.82, "category": "rifle"},
		})
		await _phys(3)
	if c and c.has_method("get_ragdoll"):
		var rag: Node = c.call("get_ragdoll")
		if rag and bool(rag.call("is_active")):
			var dir := Vector3(1, 0.12, 0).normalized()
			var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, dir)
			rag.call("apply_hit_impulse", imp, rag.call("get_follow_point"), null)
	await _phys(3)
	await _frames(6)
	await _save("ragdoll_sphere_impact.png")

	# --- 第一人称：准星对准尸体显示拖拽按钮；左手抓住；再放下
	# 不要把玩家传送到尸体坐标（撞击后可能靠墙或出房间，第一人称会拍到黑屏）。
	# 在房间出生点旁再刷一具尸体，观察视角沿用 tp_home 的取景。
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	var home: Vector3 = player.global_position
	var home_yaw: float = float(player.get("_yaw"))
	main.call("spawn_clone", home + Vector3(0.42, 0.0, 0.12))
	await _frames(16)
	await _phys(4)
	var clones2: Array = main.call("get_clones")
	var corpse: Node = null
	for n in clones2:
		if n != null and bool(n.call("is_dead")):
			corpse = n
			break
	if corpse == null and clones2.size() > 0:
		corpse = clones2[clones2.size() - 1]
		if not bool(corpse.call("is_dead")):
			corpse.call("apply_damage", 200.0, {
				"zone": "body",
				"dir": Vector3(-0.2, 0.05, 0.4).normalized(),
				"entry": corpse.global_position + Vector3(0, 1.1, 0),
				"par": {"impulse": 0.22, "category": "pistol"},
			})
			await _phys(5)
	if corpse and corpse.has_method("get_ragdoll"):
		var rag2: Node = corpse.call("get_ragdoll")
		var chest: Vector3 = (rag2.call("get_follow_point") as Vector3) if rag2 else corpse.global_position + Vector3.UP
		var step: Vector3 = chest - home
		step.y = 0.0
		if step.length() > 0.22:
			player.global_position = home + step.normalized() * 0.18
		player.velocity = Vector3.ZERO
		await _phys(2)
		chest = (rag2.call("get_follow_point") as Vector3) if rag2 else chest
		var drag: Node = player.call("get_corpse_drag")
		if drag:
			drag.call("debug_aim", corpse, "C_Spine_c", chest)
			if not bool(drag.call("can_start")):
				player.call("_set_stance", "crouch")
				await _phys(50)
				await _frames(8)
				chest = (rag2.call("get_follow_point") as Vector3) if rag2 else chest
				drag.call("debug_aim", corpse, "C_Spine_c", chest)
		var cam: Camera3D = player.call("get_camera")
		player.call("set_play_mode", 1)
		await _frames(4)
		if cam:
			var eye: Vector3 = cam.global_position
			var to: Vector3 = chest - eye
			var look_yaw := atan2(-to.x, -to.z)
			var horiz := Vector2(to.x, to.z).length()
			var look_pitch := clampf(atan2(to.y, maxf(horiz, 0.01)), -1.2, 1.2)
			player.set("_yaw", look_yaw)
			player.set("_body_logic_yaw", look_yaw)
			player.set("_pitch", look_pitch)
			if player.has_method("_apply_camera"):
				player.call("_apply_camera")
		if drag:
			drag.call("debug_aim", corpse, "C_Spine_c", chest)
		if hud.has_method("_refresh_corpse_drag_btn"):
			hud.call("_refresh_corpse_drag_btn")
		await _frames(8)
		await _phys(2)
		await _save("fp_drag_button.png")
		if drag:
			var started: bool = bool(drag.call("toggle"))
			print("v032_shots: drag started=", started, " reason=", drag.get("last_drop_reason"))
			await _phys(5)
			player.call("set_play_mode", 0)
			if player.has_method("tp_home"):
				player.call("tp_home", true)
			if player.has_method("set_tp_view"):
				player.call("set_tp_view", home_yaw + 2.85, 0.08, 2.4, true)
			if hud.has_method("_refresh_corpse_drag_btn"):
				hud.call("_refresh_corpse_drag_btn")
			await _frames(10)
			await _phys(3)
			print("v032_shots: left-hand dragging=", drag.call("is_dragging"), " reason=", drag.get("last_drop_reason"))
			await _save("fp_dragging_left_hand.png")
			drag.call("drop", "toggle")
			player.call("set_play_mode", 1)
			if player.has_method("_apply_camera"):
				player.call("_apply_camera")
			if drag:
				drag.call("debug_aim", corpse, "C_Spine_c", chest)
			if hud.has_method("_refresh_corpse_drag_btn"):
				hud.call("_refresh_corpse_drag_btn")
			await _frames(10)
			await _save("fp_drag_dropped.png")

	# --- 自动武器特写中断：开始特写的一帧（连射应已停）
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	var cam: Node = main.get("bullet_cam")
	if cam:
		cam.call("debug_reset")
		cam.set("debug_roll", 0.0)
		ws.call("select", "smg")
		for i in 5:
			ws.call("debug_finish_state")
			await _frames(2)
		ws.call("set_trigger", true)
		ws.call("_try_fire", 0.05)
		var origin: Vector3 = player.global_position + Vector3(0, 1.2, 0.2)
		var dir2 := Vector3(0, 0, -1)
		var info := {
			"gut": true, "uterus": false, "organs": organs,
			"entry": origin + dir2 * 1.2, "exit": origin + dir2 * 1.45,
			"dir": dir2, "origin": origin, "body": player,
		}
		cam.call("consider", info, {})
		await _frames(6)
		await _save("autofire_cam_interrupt.png")
		cam.call("skip")
		ws.call("set_trigger", false)
		await _frames(4)
		await _save("autofire_cam_restored.png")

	print("v032_shots: done")
	quit(0)
