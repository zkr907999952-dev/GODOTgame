extends SceneTree
## 0.2.14 t28u 截图（需要显示服务器，不要加 --headless）：
##   DISPLAY=:2 SHOT_DIR=/workspace/screenshots/v042 godot --rendering-driver opengl3 --path . -s res://scripts/tests/v042_shots.gd

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
		push_error("v042_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v042_shots: wrote ", path)


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
		out_dir = "/workspace/screenshots/v042"
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
	var bal: Node = ws.get("ballistics")
	var camf: Camera3D = player.call("get_camera")

	# 1) 暗红透明弹道孔（活体近景，体表无黑点贴花）
	player.call("set_play_mode", 1)
	_home()
	bal.call("clear_decals")
	var c: Node = await _clone(_fwd() * 1.8)
	# 用手枪打两发（伤害低，克隆体不会倒下），再关掉捂腹，露出弹孔
	await _ready_gun("pistol")
	for k in 2:
		_refill()
		var off := Vector3(0.05 * (k * 2 - 1), 0.02, 0.0)
		ws.call("fire_along_ray", camf.global_position, (_belly(c) + off - camf.global_position).normalized(), false)
		await _phys(20)
	var hr: Node = c.call("get_hit_reaction")
	player.call("set_play_mode", 0)
	var b := _belly(c)
	var cb := (c as Node3D).global_basis
	var yaw0 := atan2(cb.z.x, cb.z.z)
	for v in [[0.0, 0.05, 0.5, "hole_closeup_front.png"], [0.5, 0.1, 0.42, "hole_closeup_angle.png"], [0.0, 0.05, 1.0, "body_after_shots.png"]]:
		_aim_tp(b, yaw0 + float(v[0]), float(v[1]), float(v[2]))
		for i in 12:
			hr.set("cover_life", 0.0)
			hr.set("cover_weight", 0.0)
			await physics_frame
		hr.set("cover_life", 0.0)
		hr.set("cover_weight", 0.0)
		await _save(String(v[3]))
	print("v042_shots: clone dead=", c.call("is_dead"))
	print("v042_shots: body decals=%d wall decals=%d channels=%d" % [int(bal.call("body_decal_count", [c])), int(bal.call("decal_count")), (c.call("get_organs").get("_ball_ch") as Array).size()])
	c.queue_free()
	await _frames(3)

	# 2) 特写：弹头穿出继续飞，镜头环绕受击区域
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
		ws.call("fire_along_ray", origin, dd, false)
		var arr: Array = bal.call("live_projectiles")
		var lead: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
		var info := {"gut": true, "body": c, "organs": c.call("get_organs"), "entry": b, "pos": b, "exit": b + dd * 0.22, "dir": dd, "origin": origin}
		cam.call("debug_reset")
		if bool(cam.call("consider", info, lead)):
			var t := 0.0
			var shot_through := false
			var shot_hold := false
			while bool(cam.get("playing")) and t < 12.0:
				cam.call("debug_advance", 0.05)
				t += 0.05
				var ph := str(cam.get("debug_phase"))
				if ph == "through" and not shot_through:
					var dt: Dictionary = cam.call("debug_through")
					if float(dt["max_beyond_exit"]) > 0.6:
						shot_through = true
						await _frames(2)
						await _grab("cine_%s_bullet_beyond_cam_at_impact.png" % id)
						var f: Dictionary = cam.call("debug_cam_focus")
						print("v042_shots: %s through: cam %.2f m from impact, bullet %.2f m from cam, beyond exit %.2f m" % [id, float(f["dist"]), float(f["bullet_dist"]), float(dt["max_beyond_exit"])])
				if ph == "hold" and not shot_hold and float(cam.get("_hold_t")) > 2.0:
					shot_hold = true
					await _frames(2)
					await _grab("cine_%s_hold_orbit.png" % id)
			cam.call("skip")
		cam.call("debug_reset")
		await _phys(10)
	cam.set("debug_roll", -1.0)
	print("v042_shots: done")
	quit(0)
