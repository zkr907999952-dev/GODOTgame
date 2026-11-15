extends SceneTree
## 开镜 / 观察持枪对比截图（需要有显示服务器，不要加 --headless）：
##   SHOT_DIR=/workspace/screenshots/v027 godot --path . -s res://scripts/tests/v027_shots.gd

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


func _set_look_pitch(rad: float) -> void:
	player.set("_pitch", rad)
	if player.has_method("_sync_pivot"):
		player.set("_pivot_rot", Vector3(rad, float(player.get("_yaw")), 0.0))
		player.call("_sync_pivot")


func _mark_and_save(name: String, mark_center: bool = true) -> void:
	await _frames(8)
	var tex := root.get_texture()
	if tex == null:
		push_error("v027_shots: no viewport texture")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("v027_shots: empty image")
		return
	if mark_center:
		_draw_guides(img)
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("v027_shots: wrote ", path, " ", img.get_width(), "x", img.get_height())


func _draw_guides(img: Image) -> void:
	# 白色十字 = 屏幕中心（瞄准基线应对准这里）。水平线贯穿全宽便于对比机瞄高度。
	var w := img.get_width()
	var h := img.get_height()
	var cx := w / 2
	var cy := h / 2
	var white := Color(1, 1, 1, 0.95)
	var acc := Color(0.95, 0.35, 0.2, 0.9)
	for x in w:
		img.set_pixel(x, cy, white)
	for y in range(maxi(0, cy - 18), mini(h, cy + 19)):
		img.set_pixel(cx, y, white)
	# 短红标在中心，避免和白线糊在一起
	for i in range(-4, 5):
		if cx + i >= 0 and cx + i < w:
			img.set_pixel(cx + i, cy, acc)
		if cy + i >= 0 and cy + i < h:
			img.set_pixel(cx, cy + i, acc)


func _run() -> void:
	if out_dir == "":
		out_dir = "/workspace/screenshots/v027"
	DirAccess.make_dir_recursive_absolute(out_dir)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
		push_warning("v027_shots: headless may yield a black frame")
	else:
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
	# 关掉 HUD 面板文字干扰，保留准星参考（截图脚本自己画中心线）
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	player.call("set_play_mode", 1)
	_set_look_pitch(0.0)
	await _frames(8)

	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _ready_gun(id)
		_set_look_pitch(0.0)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(8)
		await _mark_and_save("fp_hip_%s.png" % id, true)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(16)
		var parts: Dictionary = ws.call("debug_ads_parts")
		print("v027_shots: ADS ", id, " ", parts)
		await _mark_and_save("fp_ads_%s.png" % id, true)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)

	# 观察模式：长枪抵肩 + 手枪前伸
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	# 侧面略偏的观察位，方便看出抵肩/低头
	if player.has_method("set_tp_view"):
		var yaw: float = float(player.get("_yaw")) if "_yaw" in player else 0.0
		player.call("set_tp_view", yaw + 1.15, 0.08, 2.4, true)
	await _ready_gun("rifle")
	await _frames(16)
	await _mark_and_save("tp_rifle_aim.png", false)
	await _ready_gun("smg")
	await _frames(12)
	await _mark_and_save("tp_smg_aim.png", false)
	await _ready_gun("shotgun")
	await _frames(12)
	await _mark_and_save("tp_shotgun_aim.png", false)
	await _ready_gun("pistol")
	await _frames(12)
	await _mark_and_save("tp_pistol_hold.png", false)

	print("v027_shots: done dir=", out_dir)
	quit(0)
