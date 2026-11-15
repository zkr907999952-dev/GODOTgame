extends SceneTree
## SHOT_DIR=/workspace/screenshots/v028 DISPLAY=:2 godot --path . -s res://scripts/tests/v028_shots.gd

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


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)


func _save(name: String) -> void:
	await _frames(1)
	var tex := root.get_texture()
	if tex == null:
		push_error("v028_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v028_shots: empty image")
		return
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v028_shots: wrote ", path)


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v028"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(30)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	var settings = main.get_node_or_null("GameSettings")
	if settings:
		settings.call("set_render_scale", 1.0)
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)

	# Observe 3/4 + slightly front, fire shotgun/rifle, capture immediately
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	if player.has_method("set_tp_view"):
		var yaw: float = float(player.get("_yaw")) if "_yaw" in player else 0.0
		player.call("set_tp_view", yaw + 1.05, 0.12, 2.0, true)

	for id in ["shotgun", "rifle"]:
		await _ready_gun(id)
		ws.call("debug_set_ammo", id, 12, 40)
		await _frames(10)
		await _save("tp_%s_prefire.png" % id)
		ws.call("debug_fire_once")
		# 1–2 frames: body kick + breast impulse visible, not yet settled
		await _frames(2)
		await _save("tp_%s_fire.png" % id)

	# slightly more front-on
	if player.has_method("set_tp_view"):
		var yaw2: float = float(player.get("_yaw")) if "_yaw" in player else 0.0
		player.call("set_tp_view", yaw2 + 0.55, 0.08, 1.9, true)
	await _ready_gun("shotgun")
	ws.call("debug_set_ammo", "shotgun", 12, 40)
	await _frames(8)
	ws.call("debug_fire_once")
	await _frames(2)
	await _save("tp_shotgun_fire_front.png")

	print("v028_shots: done dir=", out_dir)
	quit(0)
