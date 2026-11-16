extends SceneTree
## 0.2.13 t27u 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v041 godot --rendering-driver opengl3 --path . -s res://scripts/tests/v041_shots.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var settings: Node
var out_dir := OS.get_environment("SHOT_DIR")
var spawn := Vector3.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _grab(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img == null:
		push_error("v041_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v041_shots: wrote ", path)


func _save(name: String) -> void:
	await _frames(6)
	await _grab(name)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _refill() -> void:
	var am: Dictionary = ws.get("ammo")
	am[String(ws.get("current"))] = Vector2i(99, 99)


func _home() -> void:
	player.global_position = spawn
	player.velocity = Vector3.ZERO
	player.set("input_locked", false)
	player.set("_yaw", 0.0)
	player.set("_pitch", 0.0)
	player.call("_apply_camera")


func _aim_tp(focus: Vector3, yaw: float, elev: float, dist: float) -> void:
	player.set("tp_auto_rotate", false)
	player.set("_tp_target_goal", focus - player.global_position)
	player.set("_tp_target", focus - player.global_position)
	player.set("_tp_focus", "")
	player.call("set_tp_view", yaw, elev, dist, true)


func _clone(off: Vector3) -> Node:
	main.call("spawn_clone", player.global_position + off)
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	return clones[clones.size() - 1] if not clones.is_empty() else null


func _belly(c: Node) -> Vector3:
	var o: Node = c.call("get_organs")
	if o and o.has_method("abdomen_frame"):
		return (o.call("abdomen_frame") as Transform3D).origin
	return (c as Node3D).global_position + Vector3(0, 1.0, 0)


func _fwd() -> Vector3:
	var cam3: Camera3D = player.call("get_camera")
	var f := -cam3.global_transform.basis.z
	f.y = 0.0
	return f.normalized()


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v041"
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
		settings.call("set_bullet_cam_chance", 0.0)
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	spawn = player.global_position

	# 1) 手枪：平视/抬头/低头（绕肩俯仰，双手握持）
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun("pistol")
	for pv in [[0.0, "level"], [0.5, "up"], [-0.6, "down"]]:
		player.set("_pitch", pv[0])
		player.call("_apply_camera")
		await _phys(14)
		await _save("fp_pistol_%s.png" % pv[1])
	player.set("_pitch", 0.0)
	player.call("_apply_camera")

	# 2) 受击捂腹近景（掌心贴腹，肘不反折）
	player.call("set_play_mode", 0)
	_home()
	var c: Node = await _clone(Vector3(0.0, 0.0, -1.2))
	var hr: Node = c.call("get_hit_reaction")
	var inside: Vector3 = (c.call("get_organs").call("abdomen_frame") as Transform3D) * Vector3(0, -0.02, -0.02)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": inside})
	await _phys(10)
	hr.set("cover_life", 6.0)
	hr.set("cover_weight", 1.0)
	var b := _belly(c)
	var cb := (c as Node3D).global_basis
	for v in [[0.0, "front"], [0.8, "left"], [-0.8, "right"]]:
		var yaw: float = atan2(cb.z.x, cb.z.z) + float(v[0])
		_aim_tp(b, yaw, 0.05, 0.75)
		hr.set("cover_life", 6.0)
		await _phys(8)
		await _save("cover_closeup_%s.png" % v[1])
	c.queue_free()
	await _frames(3)

	# 3) 霰弹泵动：拉到底那一帧（第一人称 + 观察模式左手近景）
	for mode in [1, 0]:
		player.call("set_play_mode", 1)
		_home()
		await _ready_gun("shotgun")
		if mode == 0:
			player.call("set_play_mode", 0)
			_aim_tp(player.global_position + Vector3(0.0, 1.2, 0.0), -2.2, 0.1, 1.1)
			await _phys(12)
		var cam3: Camera3D = player.call("get_camera")
		_refill()
		var dir: Vector3 = -player.global_basis.z if mode == 0 else -cam3.global_transform.basis.z
		ws.call("fire_along_ray", cam3.global_position if mode == 1 else player.global_position + Vector3(0, 1.4, 0), dir, false)
		var best := 0.0
		# 软件渲染帧率很低，放慢时间以抓到前托拉到底的那一帧。
		Engine.time_scale = 0.08
		for i in 400:
			await process_frame
			var d: Dictionary = ws.call("debug_pump")
			if not bool(d["active"]):
				break
			var pm := float(d["pump_m"])
			if pm > 0.03 and pm >= best:
				best = pm
				await _grab("shotgun_pump_midrack_%s.png" % ("fp" if mode == 1 else "observe"))
				print("v041_shots: pump %.1f cm palm->pump %.1f cm" % [pm * 100.0, float(d["palm_to_pump"]) * 100.0])
				break
		Engine.time_scale = 1.0
	player.call("set_play_mode", 1)

	# 4) 射击人体后无黑点弹孔（活体 + 布娃娃）
	_home()
	var bal: Node = ws.get("ballistics")
	bal.call("clear_decals")
	c = await _clone(_fwd() * 1.8)
	await _ready_gun("shotgun")
	var camf: Camera3D = player.call("get_camera")
	for k in 3:
		_refill()
		ws.call("fire_along_ray", camf.global_position, (_belly(c) - camf.global_position).normalized(), true)
		await _phys(20)
	player.call("set_play_mode", 0)
	b = _belly(c)
	cb = (c as Node3D).global_basis
	_aim_tp(b, atan2(cb.z.x, cb.z.z), 0.05, 0.9)
	await _phys(10)
	await _save("body_after_shots_alive.png")
	player.call("set_play_mode", 1)
	_home()
	c.call("apply_damage", 9999.0, {"zone": "head"})
	await _phys(60)
	await _ready_gun("rifle")
	for k in 3:
		_refill()
		ws.call("fire_along_ray", camf.global_position, (_belly(c) - camf.global_position).normalized(), true)
		await _phys(12)
	await _phys(20)
	player.call("set_play_mode", 0)
	_aim_tp(_belly(c), 0.6, 0.6, 1.1)
	await _phys(10)
	await _save("body_after_shots_ragdoll.png")
	print("v041_shots: body decals=%d wall decals=%d" % [int(bal.call("body_decal_count", [c])), int(bal.call("decal_count"))])
	c.queue_free()
	await _frames(3)

	# 5) 子弹穿出人体后继续飞（特写 through 段）
	player.call("set_play_mode", 1)
	_home()
	c = await _clone(_fwd() * 1.8)
	var cam: Node = main.get_node_or_null("BulletCam")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	for id in ["rifle", "shotgun"]:
		await _ready_gun(id)
		_refill()
		b = _belly(c)
		var origin: Vector3 = camf.global_position
		var dd := (b - origin).normalized()
		ws.call("fire_along_ray", origin, dd, true)
		var arr: Array = bal.call("live_projectiles")
		var lead: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
		var info := {"gut": true, "body": c, "organs": c.call("get_organs"), "entry": b, "pos": b, "exit": b + dd * 0.22, "dir": dd, "origin": origin}
		cam.call("debug_reset")
		if bool(cam.call("consider", info, lead)):
			var t := 0.0
			while bool(cam.get("playing")) and t < 12.0:
				cam.call("debug_advance", 0.05)
				t += 0.05
				if str(cam.get("debug_phase")) == "through":
					var dt: Dictionary = cam.call("debug_through")
					if float(dt["max_beyond_exit"]) > 0.7:
						break
			await _frames(2)
			await _grab("bullet_beyond_body_%s.png" % id)
			cam.call("skip")
		cam.call("debug_reset")
		await _phys(10)
	cam.set("debug_roll", -1.0)
	if settings:
		settings.call("set_bullet_cam_chance", 0.0)
	c.queue_free()
	await _frames(3)

	# 6) 走跑+跳跃中的一帧：枪和手随身体一起动
	for mode in [1, 0]:
		player.call("set_play_mode", 1)
		_home()
		await _ready_gun("rifle")
		if mode == 0:
			player.call("set_play_mode", 0)
			_aim_tp(player.global_position + Vector3(0, 1.3, 0), 1.75, 0.05, 2.0)
		Input.action_press("move_forward")
		await _phys(25)
		Input.action_press("jump")
		await _phys(3)
		Input.action_release("jump")
		await _phys(8)
		await _grab("jump_walk_%s.png" % ("fp" if mode == 1 else "observe"))
		var he: Dictionary = ws.call("debug_hand_error")
		print("v041_shots: jump %s hand err L %.1f cm R %.1f cm airborne=%s" % ["fp" if mode == 1 else "tp", float(he.get("L", 0.0)) * 100.0, float(he.get("R", 0.0)) * 100.0, not player.is_on_floor()])
		Input.action_release("move_forward")
		await _phys(40)
	print("v041_shots: done")
	quit(0)
