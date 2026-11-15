extends SceneTree
## SHOT_DIR=/workspace/screenshots/v030 DISPLAY=:2 godot --path . -s res://scripts/tests/v030_shots.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
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
	await _frames(1)
	var tex := root.get_texture()
	if tex == null:
		push_error("v030_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v030_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v030_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v030"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	await _phys(4)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	var settings = main.get_node_or_null("GameSettings")
	if settings:
		settings.call("set_render_scale", 1.0)
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	# 观察视角看全身 + 左下血条
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	if player.has_method("set_tp_view"):
		var yaw: float = float(player.get("_yaw"))
		player.call("set_tp_view", yaw + 0.9, 0.18, 2.3, true)
	await _frames(8)
	await _save("player_hp_full.png")
	# 打到中低血看颜色
	player.call("apply_damage", 55.0, {"zone": "body"})
	await _frames(2)
	await _save("player_hp_mid.png")
	player.call("apply_damage", 30.0, {"zone": "body"})
	await _frames(2)
	await _save("player_hp_low.png")
	player.call("get_health").call("reset", 100.0)
	await _frames(2)

	# 拉远相机，把分身放到画面右侧空地，准星对准其头部
	if player.has_method("set_tp_view"):
		var yaw2: float = float(player.get("_yaw"))
		player.call("set_tp_view", yaw2 + 1.15, 0.34, 3.7, true)
	await _frames(8)
	var cam: Camera3D = player.call("get_camera")
	# 在玩家左前方（画面中偏右）放一个分身
	var side := cam.global_transform.basis.x
	var fwd := -cam.global_transform.basis.z
	side.y = 0.0
	fwd.y = 0.0
	if side.length_squared() > 1e-6:
		side = side.normalized()
	if fwd.length_squared() > 1e-6:
		fwd = fwd.normalized()
	var dest: Vector3 = player.global_position + side * 0.85 + fwd * 0.15
	main.call("spawn_clone", dest)
	await _frames(12)
	await _phys(2)
	var clone: Node = null
	for c in main.call("get_clones"):
		if not bool(c.call("is_dead")):
			clone = c
			break
	if clone:
		clone.global_position = dest
		var look := cam.global_position
		look.y = dest.y
		if (look - dest).length_squared() > 1e-4:
			clone.look_at(look, Vector3.UP)
		# 微调相机目标到分身头部，保证准星打中并露出全身
		var head: Vector3 = clone.call("get_head_world_position")
		if player.has_method("set_tp_view"):
			# 保持当前环绕角，把焦点偏向分身
			player.set("_tp_target_goal", head - player.call("_base_origin"))
			player.set("_tp_target", head - player.call("_base_origin"))
	await _frames(10)
	if hud.has_method("_refresh_world_hp"):
		hud.call("_refresh_world_hp", 0.25)
	await _save("world_hp_aimed.png")

	# 移开准星：把焦点拨回玩家，分身移出中心射线
	if clone:
		clone.global_position = dest + side * 2.2 + Vector3(0, 0, 0)
	if player.has_method("tp_home"):
		# 不复位距离，只把目标拉回玩家
		player.set("_tp_target_goal", Vector3(0.0, 1.06, 0.0))
	await _frames(4)
	if hud.has_method("_refresh_world_hp"):
		for i in 16:
			hud.call("_refresh_world_hp", 0.1)
	await _save("world_hp_hidden.png")

	# 分身拉回视野并让相机对着它再击杀
	if clone:
		clone.global_position = dest
		var head2: Vector3 = clone.call("get_head_world_position")
		player.set("_tp_target_goal", head2 - player.call("_base_origin") + Vector3(0, -0.15, 0))
		player.set("_tp_target", player.get("_tp_target_goal"))
		if player.has_method("set_tp_view"):
			var yaw3: float = float(player.get("_tp_yaw"))
			player.call("set_tp_view", yaw3, 0.22, 2.8, true)
		await _frames(8)
		if hud.has_method("_refresh_world_hp"):
			for i in 12:
				hud.call("_refresh_world_hp", 0.1)
		var hitp: Vector3 = clone.call("get_head_world_position")
		var ddir := side + Vector3(0, 0.15, 0.1)
		clone.call("apply_damage", 200.0, {
			"zone": "body",
			"dir": ddir.normalized(),
			"entry": hitp,
			"par": {"impulse": 1.0, "category": "rifle"},
		})
	var _follow := func() -> void:
		if clone == null or not clone.has_method("get_ragdoll"):
			return
		var rag0: Node = clone.call("get_ragdoll")
		if rag0 == null:
			return
		var fp: Vector3 = rag0.call("get_follow_point")
		player.set("_tp_target_goal", fp - player.call("_base_origin"))
		player.set("_tp_target", player.get("_tp_target_goal"))
	await _phys(6)
	_follow.call()
	await _frames(3)
	if hud.has_method("_refresh_world_hp"):
		for i in 10:
			hud.call("_refresh_world_hp", 0.1)
	await _save("ragdoll_mid_collapse.png")
	for i in 8:
		await _phys(3)
		_follow.call()
	await _frames(4)
	await _save("ragdoll_settled.png")

	if clone and clone.has_method("get_ragdoll"):
		var rag: Node = clone.call("get_ragdoll")
		var chest: Vector3 = rag.call("get_follow_point")
		var dir := (side + Vector3(0, 0.25, 0.05)).normalized()
		var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 1.0, "category": "shotgun"}, dir)
		rag.call("apply_hit_impulse", imp * 2.4, chest, null)
	await _phys(4)
	_follow.call()
	await _frames(3)
	await _save("corpse_shoved.png")
	print("v030_shots: done")
	quit()
