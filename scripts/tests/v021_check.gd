extends SceneTree
## 0.2.1 行为自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/v021_check.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var organs: Node
var settings: Node
var ballistics: Node
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
		print("v021: OK   ", msg)
	else:
		fails += 1
		push_error("v021: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)

	var skin_c := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	var organ_src := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	_ok(skin_c.find("prof_tex") >= 0, "profile packed in texture")
	_ok(skin_c.find("uniform float prof_y[24]") < 0, "no Mobile-unsafe prof_y[24] array")
	_ok(skin_c.find("inverse(MODEL_MATRIX) * vec4(wp") < 0, "skin does not invert translated MODEL_MATRIX")
	_ok(organ_src.find("inverse(MODEL_MATRIX) * vec4(wp") < 0, "organ does not invert translated MODEL_MATRIX")
	_ok(skin_c.find("inverse(mat3(MODEL_MATRIX))") >= 0, "skin uses 3x3 inverse for offsets")

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	organs = player.call("get_organs")
	settings = main.get_node_or_null("GameSettings")
	ballistics = ws.get("ballistics") if ws else null
	if ballistics == null:
		ballistics = main.find_child("Ballistics", true, false)
	_ok(ws != null and organs != null, "scene booted")

	# ---- 画面分辨率
	_ok(settings != null, "GameSettings exists")
	if settings:
		var def_sc: float = settings.call("default_render_scale")
		_ok(def_sc == 1.0 or is_equal_approx(def_sc, 0.75), "default render scale is 100% or 75% (%.2f)" % def_sc)
		settings.call("set_render_scale", 0.5)
		await _frames(2)
		_ok(is_equal_approx(root.scaling_3d_scale, 0.5), "render scale 50%% applied (%.2f)" % root.scaling_3d_scale)
		settings.call("set_render_scale", 0.75)
		await _frames(1)
		_ok(is_equal_approx(root.scaling_3d_scale, 0.75), "render scale 75%% applied")
		settings.call("set_render_scale", 1.0)
		await _frames(1)
		_ok(is_equal_approx(root.scaling_3d_scale, 1.0), "render scale 100%% applied")

	# ---- 透视窗口中心应落在腹部
	organs.call("set_xray_enabled", true)
	organs.call("set_xray_amount", 0.85)
	await _frames(4)
	var ab0: Transform3D = organs.call("abdomen_frame")
	var meta: Variant = organs.get("meta")
	var xd: Dictionary = meta.get("xray", {}) if meta is Dictionary else {}
	var ymid := 0.5 * (float(xd.get("y0", -0.2)) + float(xd.get("y1", 0.145)))
	var win_w: Vector3 = ab0 * Vector3(0.0, ymid, 0.02)
	_ok(win_w.distance_to(ab0.origin) < 0.16, "window center near navel (%.3f m)" % win_w.distance_to(ab0.origin))
	var hole_c: float = float(organs.call("debug_xray_hole", Vector3(0.0, ymid, 0.02), 0.85))
	var hole_s: float = float(organs.call("debug_xray_hole", Vector3(0.20, ymid, 0.02), 0.85))
	_ok(hole_c > 0.25, "x-ray hole open at belly center (%.2f)" % hole_c)
	_ok(hole_s < hole_c * 0.55, "x-ray hole not open at flank (c=%.2f s=%.2f)" % [hole_c, hole_s])
	var xcam := Camera3D.new()
	xcam.fov = 50.0
	main.add_child(xcam)
	xcam.global_position = ab0.origin + ab0.basis.z * 1.35 + ab0.basis.y * 0.04
	xcam.look_at(ab0.origin, Vector3.UP)
	await _frames(2)
	var wr: Dictionary = organs.call("debug_window_on_belly", xcam)
	_ok(bool(wr.get("ok", false)), "window projects onto belly (dist=%.3f)" % float(wr.get("dist", 99)))
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(720, 1280)
		await _frames(3)
		wr = organs.call("debug_window_on_belly", xcam)
		_ok(bool(wr.get("ok", false)), "portrait window on belly (dist=%.3f)" % float(wr.get("dist", 99)))
		root.size = Vector2i(1280, 720)
		await _frames(2)
	xcam.queue_free()
	player.call("set_play_mode", 0)
	await _frames(2)

	# ---- 步枪抵肩（观察模式）+ 开镜准星 + 手枪拇指
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	ws.call("set_ads", false)
	await _frames(10)
	await _phys(8)
	var stock: Dictionary = ws.call("debug_stock_vs_head")
	_ok(bool(stock.get("ok", false)), "rifle stock nearer shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(stock.get("d_sh", 99)), float(stock.get("d_head", 99))])

	player.call("set_play_mode", 1)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(8)
	var ads_err: float = float(ws.call("debug_ads_error"))
	_ok(ads_err < 48.0, "ADS iron sights near screen center (err=%.1f px)" % ads_err)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _frames(2)

	ws.call("select", "pistol")
	ws.call("debug_finish_state")
	await _frames(8)
	await _phys(8)
	var th: Dictionary = ws.call("debug_thumb_slide")
	_ok(bool(th.get("ok", false)), "pistol thumbs along slide (L=%.2f R=%.2f)" % [float(th.get("L", -1)), float(th.get("R", -1))])

	# ---- 霰弹黑色小球 + 子弹穿过肉体
	if ballistics == null:
		fails += 1
		push_error("v021: FAIL Ballistics node missing")
	else:
		await _check_ballistics()

	# ---- 观察模式单击 / 双击（含 DPI 逻辑坐标与 ScreenTouch 路径）
	await _check_observe_touch()

	print("v021_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_ballistics() -> void:
	var par: Dictionary = ballistics.call("params_of", "shotgun")
	_ok(str(par.get("proj", "")) == "pellet_sphere", "shotgun params use pellet_sphere")
	var f: Transform3D = organs.call("abdomen_frame")
	var origin: Vector3 = f.origin + f.basis.z * 0.55
	var dir: Vector3 = -f.basis.z
	ballistics.call("clear_all")
	var rec: Dictionary = ballistics.call("fire_projectile", origin, dir, "shotgun")
	var n: MeshInstance3D = rec.get("node")
	_ok(n != null and n.mesh is SphereMesh, "shotgun projectile is a sphere")
	var col := Color.WHITE
	if n and n.mesh and (n.mesh as SphereMesh).material is StandardMaterial3D:
		col = ((n.mesh as SphereMesh).material as StandardMaterial3D).albedo_color
	elif n and n.material_override is StandardMaterial3D:
		col = (n.material_override as StandardMaterial3D).albedo_color
	_ok(col.r < 0.15 and col.g < 0.15 and col.b < 0.15, "shotgun sphere is black (col=%s)" % col)
	# 步枪贯穿：测试弹从体外打向角色，临时取消自我排除
	ws.call("holster")
	if ws.has_method("debug_finish_state"):
		ws.call("debug_finish_state")
	await _frames(2)
	ballistics.call("clear_all")
	var old_ex: Array = ballistics.get("exclude")
	var empty: Array[RID] = []
	ballistics.set("exclude", empty)
	var rec2: Dictionary = ballistics.call("fire_projectile", origin, dir, "rifle")
	var entry: Vector3 = f.origin
	var left_on_skin := false
	var continued := false
	var hit_body := false
	var last_pos: Vector3 = rec2.get("pos", origin)
	for i in 24:
		await physics_frame
		var live: Array = ballistics.call("live_projectiles")
		if live.is_empty():
			break
		var p: Dictionary = live[0]
		last_pos = p.get("pos", last_pos)
		if bool(p.get("hit_body", false)):
			hit_body = true
		var traveled := last_pos.distance_to(origin)
		if traveled > 0.35 and hit_body:
			continued = true
			break
	var spent: Array = ballistics.get("_spent")
	for s in spent:
		if is_instance_valid(s.get("n")):
			var sp: Vector3 = (s["n"] as Node3D).global_position
			if sp.distance_to(entry) < 0.08:
				left_on_skin = true
	_ok(hit_body or continued, "rifle projectile struck the body")
	_ok(not left_on_skin, "body hit does not park bullet mesh on skin")
	_ok(continued or (hit_body and last_pos.distance_to(origin) > 0.25), "bullet continued through flesh (pos dist=%.3f hit=%s continued=%s)" % [last_pos.distance_to(origin), hit_body, continued])
	ballistics.set("exclude", old_ex)
	ballistics.call("clear_all")


func _logical_of(px: Vector2) -> Vector2:
	var backing := Vector2(root.size)
	var vis := root.get_visible_rect().size
	if backing.x < 1.0 or vis.x < 1.0:
		return px
	return Vector2(px.x * vis.x / backing.x, px.y * vis.y / backing.y)


func _inject_touch(idx: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = p
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _inject_drag(idx: int, p: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = p
	e.relative = rel
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _check_observe_touch() -> void:
	player.call("set_play_mode", 0)
	hud.call("set_touch_ui", true)
	# 模拟手机 DPI：逻辑尺寸 ≠ 3D 视口像素
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = Vector2i(800, 450)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1920, 1080)
	await _frames(4)
	var cam: Camera3D = player.call("get_camera")
	var _ab: Transform3D = organs.call("abdomen_frame")
	var navel: Vector3 = _ab.origin
	var px: Vector2 = cam.unproject_position(navel)
	var logical := _logical_of(px)
	var began := bool(player.call("touch_tool_begin", logical))
	_ok(began, "touch_tool_begin on belly under content-scale (logical=%s backing=%s vis=%s)" % [logical, Vector2(root.size), root.get_visible_rect().size])
	player.call("touch_tool_end")

	var tc: Control = hud.get("_touch")
	if tc == null and hud.has_method("get_touch_controls"):
		tc = hud.call("get_touch_controls")
	_ok(tc != null, "touch controls present")
	if hud.has_method("_close_all_panels"):
		hud.call("_close_all_panels")
	if hud.has_method("_on_mode_pressed"):
		hud.call("_on_mode_pressed", "drag")
	if hud.has_method("_close_all_panels"):
		hud.call("_close_all_panels")
	await _frames(2)
	# parse_input_event 会再乘窗口变换的逆；要注入窗口像素，控件收到的才是逻辑坐标
	if tc:
		tc.fingers.clear()
	var evp := root.get_final_transform() * logical
	_inject_touch(0, evp, true)
	await _frames(2)
	var role := ""
	if tc and tc.fingers.has(0):
		role = str(tc.fingers[0].get("role", ""))
	# 击腹等一次性工具不会保持 interact_held，以手指角色为准
	_ok(role == "tool" or bool(player.call("touch_tool_active")), "ScreenTouch single tap starts tool (role=%s)" % role)
	_inject_touch(0, evp, false)
	await _frames(2)
	player.call("touch_tool_end")

	var yaw0: float = float(player.get("_tp_yaw"))
	_inject_touch(0, evp, true)
	await _frames(1)
	_inject_touch(0, evp, false)
	await _frames(1)
	_inject_touch(0, evp, true)
	await _frames(1)
	for i in 8:
		var p2 := evp + Vector2(18.0 * float(i + 1), 0)
		_inject_drag(0, p2, Vector2(18, 0))
		await _frames(1)
	_inject_touch(0, evp + Vector2(144, 0), false)
	await _frames(2)
	var yaw1: float = float(player.get("_tp_yaw"))
	_ok(absf(yaw1 - yaw0) > 0.04, "double-tap + drag orbits (Δyaw=%.3f)" % absf(yaw1 - yaw0))

	root.content_scale_size = Vector2i(0, 0)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	await _frames(1)
