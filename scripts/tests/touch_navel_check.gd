extends SceneTree
## 触屏 + 手机布局 + 肚脐 自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/touch_navel_check.gd
## SHOT_DIR + 非 headless：保存手机竖屏 HUD 截图（窗口建议 540x1170，模拟 1080x2340 @2.75x）。

var main: Node
var player: Node
var organs: Node
var hud: Node
var tc: Control
var fails := 0
var SHOT_DIR := OS.get_environment("SHOT_DIR")


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
		print("touch_navel: OK   ", msg)
	else:
		fails += 1
		push_error("touch_navel: FAIL " + msg)


func _touch(idx: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = _w(p)
	e.pressed = down
	Input.parse_input_event(e)
	await _frames(1)


func _drag(idx: int, from: Vector2, to: Vector2, steps: int = 6) -> void:
	var prev := from
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		var e := InputEventScreenDrag.new()
		e.index = idx
		e.position = _w(p)
		e.relative = _w(p) - _w(prev)
		prev = p
		Input.parse_input_event(e)
		await _frames(1)


## 视口坐标 → 窗口坐标（手机缩放 / 拉伸时，真实触摸事件是窗口像素）
func _w(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _vp() -> Vector2:
	return root.get_visible_rect().size


func _run() -> void:
	# headless 窗口默认 64x64，触摸坐标会被拉伸变换放大；固定窗口尺寸让测试坐标 = 视口坐标
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(20)
	player = main.get_node("Player")
	organs = player.call("get_organs")
	hud = main.get_node("HUD")
	_ok(bool(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch")), "emulate_mouse_from_touch on (GUI gets taps)")
	hud.call("set_touch_ui", true)
	tc = hud.call("get_touch_controls")
	await _frames(3)
	_ok(tc.visible and bool(player.get("touch_active")), "touch controls enabled")
	await _check_display()
	await _check_drawer()
	await _check_fp()
	await _check_navel()
	if SHOT_DIR != "":
		await _shot()
	print("touch_navel: done fails=", fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------ 观察模式手势
func _check_display() -> void:
	var c := _vp() * 0.5
	# 双指捏合（张开 = 放大 = 距离变小）
	var d0: float = player.call("get_tp_distance")
	await _touch(0, c + Vector2(-60, 140), true)
	await _touch(1, c + Vector2(60, 140), true)
	await _drag(1, c + Vector2(60, 140), c + Vector2(200, 140))
	var d1: float = player.call("get_tp_distance")
	_ok(d1 < d0 * 0.85, "pinch zoom in: dist %.2f → %.2f" % [d0, d1])
	# 双指平移
	var tgt0: Vector3 = player.get("_tp_target_goal")
	var a := c + Vector2(-60, 140)
	var b := c + Vector2(200, 140)
	for i in 6:
		var e0 := InputEventScreenDrag.new()
		e0.index = 0
		e0.position = _w(a + Vector2(0, -8.0 * (i + 1)))
		e0.relative = _w(Vector2(0, -8)) - _w(Vector2.ZERO)
		Input.parse_input_event(e0)
		var e1 := InputEventScreenDrag.new()
		e1.index = 1
		e1.position = _w(b + Vector2(0, -8.0 * (i + 1)))
		e1.relative = _w(Vector2(0, -8)) - _w(Vector2.ZERO)
		Input.parse_input_event(e1)
		await _frames(1)
	var tgt1: Vector3 = player.get("_tp_target_goal")
	_ok(tgt0.distance_to(tgt1) > 0.01, "two-finger pan moves target (%.3f m)" % tgt0.distance_to(tgt1))
	await _touch(1, b, false)
	await _touch(0, a, false)
	player.call("tp_home", true)
	await _frames(20)
	# 单指点身体 = 当前工具（打击）；同一次点按只算一次（模拟鼠标不重复处理）
	hud.call("_on_mode_pressed", "strike")
	organs.call("reset_interaction")
	var cam: Camera3D = player.call("get_camera")
	var f: Transform3D = organs.call("abdomen_frame")
	var belly_s := cam.unproject_position(f * Vector3(0.0, -0.02, 0.1))
	await _touch(0, belly_s, true)
	await _touch(0, belly_s, false)
	await _frames(2)
	_ok(int(organs.call("active_waves")) == 1, "tap on belly fires strike exactly once (waves=%d)" % int(organs.call("active_waves")))
	# 拖拽工具：按住拖动
	hud.call("_on_mode_pressed", "drag")
	organs.call("reset_interaction")
	await _frames(70)  # 让双击窗口过期
	await _touch(0, belly_s, true)
	_ok(bool(organs.call("is_dragging")), "touch-down on belly starts drag tool")
	await _drag(0, belly_s, belly_s + Vector2(40, -20))
	await _frames(5)
	_ok(float(organs.call("drag_offset_length")) > 0.005, "touch drag deforms belly (%.3f)" % float(organs.call("drag_offset_length")))
	await _touch(0, belly_s + Vector2(40, -20), false)
	_ok(not bool(organs.call("is_dragging")), "touch-up releases drag")
	# 单指在空白处拖动不再环绕（环绕只走双击后拖动）
	var yaw0: float = player.get("_tp_yaw_goal")
	var corner := Vector2(_vp().x * 0.85, _vp().y * 0.75)
	await _touch(0, corner, true)
	await _drag(0, corner, corner + Vector2(-120, 0))
	await _touch(0, corner + Vector2(-120, 0), false)
	_ok(absf(float(player.get("_tp_yaw_goal")) - yaw0) < 0.05, "one-finger drag off body does not orbit")
	# 双击后拖动（在身体上）= 环绕，不拖身体
	await _frames(70)
	organs.call("reset_interaction")
	yaw0 = player.get("_tp_yaw_goal")
	await _touch(0, belly_s, true)
	await _touch(0, belly_s, false)
	await _touch(0, belly_s, true)
	await _drag(0, belly_s, belly_s + Vector2(100, 0))
	await _touch(0, belly_s + Vector2(100, 0), false)
	_ok(absf(float(player.get("_tp_yaw_goal")) - yaw0) > 0.2 and not bool(organs.call("is_dragging")), "double-tap + drag on body orbits (web)")
	player.call("tp_home", true)
	await _frames(10)


# ------------------------------------------------------------------ 手机抽屉
func _check_drawer() -> void:
	hud.call("debug_force_mobile", 2.75, Vector4(0, 24, 0, 16))
	await _frames(4)
	var v := _vp()
	_ok(bool(hud.get("compact")), "compact (phone) layout at logical %s" % v)
	var btn: Button = hud.get("_btn_interact")
	_ok(btn.size.y >= 44.0, "menu button touch target %.0fpx" % btn.size.y)
	var bp := btn.get_global_rect().get_center()
	await _touch(0, bp, true)
	await _touch(0, bp, false)
	await _frames(3)
	_ok(str(hud.call("open_panel_name")).to_lower() == "interact", "tap menu button opens drawer (open=%s)" % str(hud.call("open_panel_name")))
	var pnl: PanelContainer = hud.get("_panel_interact")
	var r := pnl.get_global_rect()
	_ok(r.end.y > v.y - 40.0 and r.size.x > v.x * 0.85 and r.size.y <= v.y * 0.55, "drawer is a bottom sheet %s in %s" % [r, v])
	var close_b: Button = hud.get("_btn_sheet_close")
	_ok(close_b.visible, "drawer close handle visible")
	# 抽屉区域内的触摸交给 GUI，不触发场景手势
	_ok(bool(hud.call("point_over_ui", r.get_center())), "touch over drawer is UI")
	var cp := close_b.get_global_rect().get_center()
	await _touch(0, cp, true)
	await _touch(0, cp, false)
	await _frames(3)
	_ok(str(hud.call("open_panel_name")) == "" or not bool(hud.call("is_panel_open")), "tap 收起 closes drawer")
	hud.call("debug_force_mobile", 0.0, Vector4.ZERO)
	await _frames(4)


# ------------------------------------------------------------------ 第一人称
func _check_fp() -> void:
	var btns: Dictionary = tc.call("buttons")
	var mp: Vector2 = (btns["mode"][0] as Rect2).get_center()
	await _touch(3, mp, true)
	await _touch(3, mp, false)
	await _frames(30)
	_ok(bool(player.get("first_person")), "切换 button → control / first person")
	# 摇杆前推 + 同时右侧拖视角（多指）
	var p0: Vector3 = player.global_position
	var yaw0: float = player.get("_yaw")
	var sc: Vector2 = tc.call("stick_center")
	await _touch(0, sc, true)
	await _drag(0, sc, sc + Vector2(0, -60))
	var look := Vector2(_vp().x * 0.6, _vp().y * 0.4)
	await _touch(1, look, true)
	await _drag(1, look, look + Vector2(80, 0))
	var tm: Vector2 = player.get("touch_move")
	_ok(tm.y < -0.9 and bool(player.get("touch_sprint")), "stick full forward = run (move=%s)" % tm)
	await _phys(40)
	_ok(player.global_position.distance_to(p0) > 0.3, "joystick moves player (%.2f m)" % player.global_position.distance_to(p0))
	_ok(absf(float(player.get("_yaw")) - yaw0) > 0.1, "simultaneous look drag turns view")
	await _touch(1, look + Vector2(80, 0), false)
	await _touch(0, sc + Vector2(0, -60), false)
	await _frames(2)
	_ok((player.get("touch_move") as Vector2) == Vector2.ZERO, "stick released → stop")
	# 下蹲：点按 = 蹲，长按 = 匍匐
	btns = tc.call("buttons")
	var cpos: Vector2 = (btns.get("crouch", [Rect2()])[0] as Rect2).get_center()
	await _touch(2, cpos, true)
	await _touch(2, cpos, false)
	await _phys(5)
	_ok(str(player.call("get_stance")) == "crouch", "crouch tap → crouch")
	await _touch(2, cpos, true)
	await create_timer(0.65).timeout
	await _touch(2, cpos, false)
	await _phys(5)
	_ok(str(player.call("get_stance")) == "prone", "crouch long-press → prone")
	await _touch(2, cpos, true)
	await _touch(2, cpos, false)
	await _phys(30)
	# 跳跃
	btns = tc.call("buttons")
	var jp: Vector2 = (btns.get("jump", [Rect2()])[0] as Rect2).get_center()
	await _phys(30)
	var y0: float = player.global_position.y
	await _touch(2, jp, true)
	await _touch(2, jp, false)
	var ymax := y0
	for i in 20:
		await physics_frame
		ymax = maxf(ymax, player.global_position.y)
	_ok(ymax > y0 + 0.05, "jump button jumps (Δy=%.2f)" % (ymax - y0))
	# 缩放竖条：平时隐藏，打开摄像机面板后可用
	_ok((tc.call("zoom_rect") as Rect2).size.y < 1.0, "FOV bar hidden until camera panel")
	hud.call("_toggle_panel", 3)  # PanelId.CAMERA
	await _frames(2)
	var fov0: float = player.get("fp_fov")
	var zr: Rect2 = tc.call("zoom_rect")
	_ok(zr.size.y > 80.0, "FOV bar shown with camera panel")
	await _touch(2, zr.position + Vector2(18, 4), true)
	await _touch(2, zr.position + Vector2(18, 4), false)
	_ok(float(player.get("fp_fov")) < fov0 - 5.0, "FP zoom bar narrows FOV")
	hud.call("_close_all_panels")
	await _frames(1)
	_ok((tc.call("zoom_rect") as Rect2).size.y < 1.0, "FOV bar hides when camera panel closes")
	btns = tc.call("buttons")
	mp = (btns["mode"][0] as Rect2).get_center()
	await _touch(3, mp, true)
	await _touch(3, mp, false)
	await _frames(30)
	_ok(not bool(player.get("first_person")), "切换 back to observe")


# ------------------------------------------------------------------ 肚脐
func _tip_l(rig: Node, sk: Skeleton3D) -> Vector3:
	var f: Transform3D = rig.call("abdomen_frame")
	return f.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("R_Index_c")).origin)


func _check_navel() -> void:
	player.call("tp_home", true)
	hud.call("_on_mode_pressed", "navel")
	await _frames(5)
	var sk: Skeleton3D = (player.call("get_secondary") as RefCounted).get("skeleton")
	organs.call("tool_set_depth01", 0.0)
	await _frames(20)
	var t0 := _tip_l(organs, sk)
	organs.call("tool_set_depth01", 1.0)
	await _frames(20)
	var t1 := _tip_l(organs, sk)
	var snap: Dictionary = organs.call("debug_snapshot")
	print("touch_navel: fingertip park=", t0, " insert=", t1, " plane_z=", snap["navel_plane_z"])
	_ok(t0.z > 0.03 and t1.z < -0.03 and Vector2(t1.x, t1.y).length() < 0.03, "navel finger park in front → full insert inside")
	var m: Dictionary = organs.call("navel_insert_morph", 1.0, 0.7)
	_ok(absf(float(m["depth"]) - 0.76) < 1e-4 and absf(float(m["diameter"]) - 0.77) < 1e-4, "navelInsertMorph matches web (depth=%.2f dia=%.2f)" % [float(m["depth"]), float(m["diameter"])])
	_ok(float(snap["navel_plane_z"]) > -0.01 and float(snap["navel_plane_z"]) < 0.03, "navel ring plane from skin mesh")
	# 抽插：自动往复
	organs.set("navel_thrust", true)
	var lo := 9.0
	var hi := -9.0
	for i in 240:
		await process_frame
		lo = minf(lo, float(organs.get("navel_live")))
		hi = maxf(hi, float(organs.get("navel_live")))
	organs.set("navel_thrust", false)
	_ok(hi - lo > 0.3, "navel thrust oscillates (%.2f..%.2f)" % [lo, hi])
	# 触屏：按住肚脐往里拖（网页拖拽平面 = 竖直、法线 UP×视线，正面视角会退化，所以先斜 45°）
	organs.call("tool_set_depth01", 0.2)
	player.set("_tp_yaw_goal", float(player.get("_tp_yaw_goal")) + 0.8)
	await _frames(70)
	var cam: Camera3D = player.call("get_camera")
	var f: Transform3D = organs.call("abdomen_frame")
	var ns := cam.unproject_position(f.origin)
	await _touch(0, ns, true)
	var ins0: float = organs.get("navel_insert")
	await _drag(0, ns, ns + Vector2(-80, 0))
	var ins1: float = organs.get("navel_insert")
	await _touch(0, ns + Vector2(-80, 0), false)
	_ok(absf(ins1 - ins0) > 0.05, "touch drag on navel changes insert (%.2f → %.2f)" % [ins0, ins1])
	# 分身也能用
	var c: Node = null
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -1.4))
	await _frames(20)
	c = (main.call("get_clones") as Array)[0]
	var crig: Node = c.call("get_organs")
	crig.call("tool_set_depth01", 1.0)
	await _frames(20)
	var csk: Skeleton3D = c.get("skeleton")
	var ct := _tip_l(crig, csk)
	_ok(str(crig.get("interact_mode")) == "navel" and ct.z < -0.03, "clone navel insert works (tip z=%.3f)" % ct.z)
	main.call("clear_clones")
	hud.call("_on_mode_pressed", "drag")
	await _frames(5)
	_ok(int(organs.call("navel_pose_t")) == -1, "leaving navel mode releases pose")


func _shot() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# 逻辑宽 ≈ 393pt（iPhone 15 / 1080x2340 @2.75x 的同比例缩小窗口）
	var k := float(root.size.x) / 393.0
	hud.call("debug_force_mobile", k, Vector4(0, 47, 0, 34))
	hud.call("set_touch_ui", true)
	player.call("tp_home", true)
	player.call("set_play_mode", 1)
	player.set("_yaw", float(player.get("_yaw")) + PI)  # 背对墙，看向房间
	await _frames(60)
	root.get_texture().get_image().save_png(SHOT_DIR + "/phone_portrait_fp_touch.png")
	print("touch_navel: saved ", SHOT_DIR, "/phone_portrait_fp_touch.png")
	player.call("set_play_mode", 0)
	await _frames(20)
	hud.call("_on_mode_pressed", "navel")
	organs.call("tool_set_depth01", 0.75)
	hud.call("_toggle_panel", 2)  # INTERACT 抽屉（肚脐参数）
	await _frames(90)
	root.get_texture().get_image().save_png(SHOT_DIR + "/phone_portrait_navel_drawer.png")
	print("touch_navel: saved ", SHOT_DIR, "/phone_portrait_navel_drawer.png")
