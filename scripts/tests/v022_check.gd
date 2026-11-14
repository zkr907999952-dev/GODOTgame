extends SceneTree
## 0.2.2 行为自检（headless）：
##   godot --headless --path . -s res://scripts/tests/v022_check.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var organs: Node
var settings: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v022: OK   ", msg)
	else:
		fails += 1
		push_error("v022: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)

	_ok(str(ProjectSettings.get_setting("application/config/name")) == "蒂法玉腹沙盒", "display name 蒂法玉腹沙盒")
	var skin_c := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	_ok(skin_c.find("prof_scale") >= 0 and skin_c.find("prof_bias") >= 0, "profile uses bias/scale decode")
	_ok(skin_c.find("FORMAT_RGBAF") < 0, "shader does not mention RGBAF")

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	organs = player.call("get_organs")
	settings = main.get_node_or_null("GameSettings")
	_ok(ws != null and organs != null, "scene booted")

	# ---- 剖面纹理必须是 RGBA8（真机安全），并带 bias/scale
	var pf: Dictionary = organs.call("debug_profile_tex")
	_ok(bool(pf.get("ok", false)), "profile texture is RGBA8 (format=%s n=%s)" % [pf.get("format"), pf.get("n")])
	var hole_c: float = float(organs.call("debug_xray_hole", Vector3(0.0, -0.02, 0.02), 0.85))
	_ok(hole_c > 0.25, "x-ray hole open at belly with RGBA8 profile (%.2f)" % hole_c)
	_ok(bool(organs.get("xray_enabled")) and float(organs.get("xray_amount")) > 0.2, "x-ray on by default")

	# ---- 开镜：照门/准星对屏幕中心，含 75% 3D 缩放
	if settings:
		settings.call("set_render_scale", 0.75)
		await _frames(2)
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(10)
	await _phys(4)
	var ads_err: float = float(ws.call("debug_ads_error"))
	_ok(ads_err < 28.0, "ADS rear/front sights on crosshair at 75%% scale (err=%.1f px)" % ads_err)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	if settings:
		settings.call("set_render_scale", 1.0)
	await _frames(2)

	# ---- 切到观察模式后，枪托在肩窝，不悬在胸前
	player.call("set_play_mode", 0)
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	ws.call("set_ads", false)
	await _frames(12)
	await _phys(8)
	var stock: Dictionary = ws.call("debug_stock_vs_head")
	_ok(bool(stock.get("ok", false)), "after mode switch, stock nearer shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(stock.get("d_sh", 99)), float(stock.get("d_head", 99))])
	var navel: Vector3 = (organs.call("abdomen_frame") as Transform3D).origin
	var d_chest: float = (stock.get("stock") as Vector3).distance_to(navel)
	var d_sh: float = float(stock.get("d_sh", 99))
	_ok(d_sh + 0.04 < d_chest, "stock closer to shoulder than navel (d_sh=%.3f d_navel=%.3f)" % [d_sh, d_chest])

	# ---- 手枪：打空挂机，换弹结束关闩
	player.call("set_play_mode", 1)
	ws.call("select", "pistol")
	# select 可能先收步枪再拔手枪，要连收两次状态
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	_ok(str(ws.get("state")) == "ready" and str(ws.get("current")) == "pistol", "pistol ready (state=%s id=%s)" % [ws.get("state"), ws.get("current")])
	ws.call("debug_set_ammo", "pistol", 1, 17)
	await _frames(2)
	ws.set("_trigger_used", false)
	ws.set("trigger", true)
	for i in 20:
		await process_frame
	ws.set("trigger", false)
	await _frames(8)
	_ok(int(ws.call("ammo_of", "pistol").x) == 0, "pistol mag empty after last shot (ammo=%s)" % ws.call("ammo_of", "pistol"))
	_ok(bool(ws.call("debug_slide_open")), "slide locks back when mag empties")
	# 换弹结束必须关闭
	_ok(bool(ws.call("reload")), "pistol reload starts")
	ws.call("debug_finish_state")
	await _frames(8)
	_ok(int(ws.call("ammo_of", "pistol").x) > 0, "pistol has ammo after reload")
	_ok(not bool(ws.call("debug_slide_open")), "slide closes after reload finishes")

	# ---- 观察触摸：非 1:1 逻辑坐标 + 3D 75% + ScreenTouch 后一帧模拟鼠标
	await _check_phone_touch()

	print("v022_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _inject_touch(idx: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = p
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _inject_emulated_mouse(p: Vector2, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.device = InputEvent.DEVICE_ID_EMULATION
	e.button_index = MOUSE_BUTTON_LEFT
	e.position = p
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _check_phone_touch() -> void:
	player.call("set_play_mode", 0)
	hud.call("set_touch_ui", true)
	if hud.has_method("_close_all_panels"):
		hud.call("_close_all_panels")
	if settings:
		settings.call("set_render_scale", 0.75)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = Vector2i(800, 450)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1920, 1080)
	await _frames(4)
	var cam: Camera3D = player.call("get_camera")
	var ab: Transform3D = organs.call("abdomen_frame")
	var navel: Vector3 = ab.origin
	var backing := Vector2(root.size)
	var vis := root.get_visible_rect().size
	var px: Vector2 = cam.unproject_position(navel)
	var logical := Vector2(px.x * vis.x / backing.x, px.y * vis.y / backing.y)
	var evp := root.get_final_transform() * logical
	var began := bool(player.call("touch_tool_begin", logical))
	_ok(began, "tool begin with logical coords under content-scale + 3D 75%%")
	player.call("touch_tool_end")
	# 真机路径：ScreenTouch down，下一帧再来一次模拟鼠标 down
	var tc: Control = hud.get("_touch")
	if tc:
		tc.fingers.clear()
	_inject_touch(0, evp, true)
	await _frames(1)
	_inject_emulated_mouse(evp, true)
	await _frames(2)
	var role := ""
	if tc and tc.fingers.has(0):
		role = str(tc.fingers[0].get("role", ""))
	_ok(role == "tool" or bool(player.call("touch_tool_active")), "ScreenTouch + delayed emulate-mouse still starts tool (role=%s)" % role)
	_inject_touch(0, evp, false)
	_inject_emulated_mouse(evp, false)
	await _frames(2)
	player.call("touch_tool_end")
	if settings:
		settings.call("set_render_scale", 1.0)
	root.content_scale_size = Vector2i(0, 0)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	await _frames(1)
