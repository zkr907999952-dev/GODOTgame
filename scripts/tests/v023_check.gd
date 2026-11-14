extends SceneTree
## 0.2.3 行为自检（headless）：
##   godot --headless --path . -s res://scripts/tests/v023_check.gd

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
		print("v023: OK   ", msg)
	else:
		fails += 1
		push_error("v023: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	_ok(str(ProjectSettings.get_setting("application/config/name")) == "蒂法玉腹沙盒", "display name")
	var skin_c := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	_ok(skin_c.find("xray_hole_analytic") >= 0 and skin_c.find("hole_center") >= 0, "shader has texture-free analytic hole")

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	organs = player.call("get_organs")
	settings = main.get_node_or_null("GameSettings")
	_ok(ws != null and organs != null, "scene booted")
	if ws == null or organs == null:
		print("v023_check: fails=", fails)
		quit(1)
		return
	_ok(bool(organs.get("xray_enabled")) and float(organs.get("xray_amount")) > 0.2, "x-ray on by default")
	var hole := float(organs.call("debug_xray_hole", Vector3(0.0, -0.02, 0.02), 0.85))
	_ok(hole > 0.25, "x-ray hole open at belly (%.2f)" % hole)
	var ahole := float(organs.call("debug_xray_hole_analytic_only", Vector3(0.0, -0.02, 0.02), 0.85))
	_ok(ahole > 0.25, "analytic fallback hole open without profile tex (%.2f)" % ahole)
	# 若透视开着但开孔为 0，视为失败
	_ok(not (bool(organs.get("xray_enabled")) and hole <= 0.01), "x-ray on must not yield a zero hole")

	# ---- ADS：机瞄孔 / 准星尖对屏幕中心，桌面与手机横屏、75% 3D
	await _check_ads(Vector2i(1280, 720), 0.75, "desktop 16:9 75%")
	await _check_ads(Vector2i(1600, 720), 0.75, "phone landscape 20:9 75%")
	await _check_ads(Vector2i(1280, 720), 1.0, "desktop 100%")

	# ---- 俯仰全程手不离枪
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	if settings:
		settings.call("set_render_scale", 1.0)
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _frames(8)
	var worst := 0.0
	var worst_p := 0.0
	var max_hand := 0.0
	for deg in [-80, -50, -20, 0, 20, 50, 80]:
		var p := deg_to_rad(float(deg))
		player.set("_pitch", p)
		await _frames(4)
		await _phys(2)
		await _frames(2)
		var hg: Dictionary = ws.call("debug_hand_to_gun")
		var he: Dictionary = ws.call("debug_hand_error")
		var d := maxf(float(hg.get("R", 99)), float(hg.get("L", 99)))
		var e := maxf(float(he.get("R", 99)), float(he.get("L", 99)))
		if d > worst:
			worst = d
			worst_p = float(deg)
		max_hand = maxf(max_hand, e)
		print("v023: pitch ", deg, "deg hand_to_gun=", hg, " hand_error=", he)
	_ok(worst < 0.045, "hands stay on gun mesh through look pitch (worst=%.3f m at %s deg)" % [worst, worst_p])
	_ok(max_hand < 0.07, "IK wrist stays on sockets through pitch (worst=%.3f m)" % max_hand)

	# 走跑时手也不离枪（不要回归旧 bug）
	player.set("_pitch", -0.15)
	player.velocity = Vector3(0, 0, 3.0)
	await _phys(8)
	await _frames(4)
	var walk: Dictionary = ws.call("debug_hand_to_gun")
	_ok(maxf(float(walk.get("R", 99)), float(walk.get("L", 99))) < 0.045, "hands stay on gun while walking (R=%s L=%s)" % [walk.get("R"), walk.get("L")])
	player.velocity = Vector3.ZERO
	await _frames(2)

	# ---- 观察抵肩不被破坏
	player.call("set_play_mode", 0)
	ws.call("set_ads", false)
	await _frames(12)
	await _phys(6)
	var stock: Dictionary = ws.call("debug_stock_vs_head")
	_ok(bool(stock.get("ok", false)), "observe stock nearer shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(stock.get("d_sh", 99)), float(stock.get("d_head", 99))])

	# ---- 观察点击：偏离肚脐的近距点击 + 真机事件序列
	await _check_near_tap()

	print("v023_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_ads(sz: Vector2i, scale: float, tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		root.size = sz
	if settings:
		settings.call("set_render_scale", scale)
	await _frames(2)
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(10)
	await _phys(2)
	var parts: Dictionary = ws.call("debug_ads_parts")
	var err: float = maxf(float(parts.get("rear", 999)), float(parts.get("front", 999)))
	print("v023: ADS ", tag, " parts=", parts)
	_ok(err < 28.0, "ADS aperture+post on crosshair (%s, err=%.1f px rear=%.1f front=%.1f)" % [tag, err, float(parts.get("rear", 999)), float(parts.get("front", 999))])
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	if settings:
		settings.call("set_render_scale", 1.0)
	await _frames(2)


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


func _check_near_tap() -> void:
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
	var navel: Vector3 = (organs.call("abdomen_frame") as Transform3D).origin
	var backing := Vector2(root.size)
	var vis := root.get_visible_rect().size
	var px: Vector2 = cam.unproject_position(navel)
	var logical := Vector2(px.x * vis.x / backing.x, px.y * vis.y / backing.y)
	# 故意偏离肚脐 55 逻辑像素，精确射线可能打空，近距兜底应仍能开始
	var missed := logical + Vector2(55, -40)
	var began := bool(player.call("touch_tool_begin", missed))
	_ok(began, "near-miss belly tap still starts tool (offset 55px)")
	player.call("touch_tool_end")
	var evp := root.get_final_transform() * missed
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
	_ok(role == "tool" or bool(player.call("touch_tool_active")), "ScreenTouch + emulate-mouse near-miss starts tool (role=%s)" % role)
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
