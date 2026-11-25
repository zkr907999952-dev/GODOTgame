extends "res://scripts/tests/v0409b_check.gd"
## 未发布（0.4.12 开发中）：断面图小窗——默认随金属球打开，纵向/横向剖切面参数、视口创建。不打包。
##   godot --headless --path . -s res://scripts/tests/v0419_check.gd


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	if not await _enter_bed():
		print("v0419_check: fails=", fails)
		quit(1)
		return
	var vm = player.call("get_vagina_mode")
	_ok(vm != null, "vagina mode exists")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(2)
	# 未选金属球时断面图不应默认出现。
	var sec0 = vm.call("cross_section") if vm.has_method("cross_section") else null
	_ok(sec0 == null or not bool(sec0.get("visible_on")), "PiP stays off until the ball-rod is selected")
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	var sec: Node = vm.call("cross_section")
	_ok(sec != null, "cross-section view is created with the ball-rod")
	if sec == null:
		print("v0419_check: fails=", fails)
		quit(1)
		return
	_ok(bool(sec.get("visible_on")), "PiP opens in the top-right by default")
	var panel: Control = sec.get("_panel")
	_ok(panel != null and bool(panel.visible), "section panel is in the tree and visible")
	if panel:
		var vis: Vector2 = (player.get_viewport().get_visible_rect().size if player.get_viewport() else Vector2(1280, 720))
		_ok(panel.position.x > vis.x * 0.5, "panel is on the right side (x=%.0f / %.0f)" % [panel.position.x, vis.x])
		_ok(panel.position.y < vis.y * 0.35, "panel is near the top (y=%.0f)" % panel.position.y)
	var lvp: SubViewport = sec.get("_long_vp")
	var tvp: SubViewport = sec.get("_trans_vp")
	_ok(lvp != null and tvp != null, "longitudinal and transverse SubViewports exist")
	_ok(sec.get("_long_cam") != null and sec.get("_trans_cam") != null, "each view has its own camera")
	_ok(str(sec.get("view_mode")) == "both", "default layout is side by side")
	if lvp and tvp:
		_ok(lvp.size.x > 0 and lvp.size.y > 0 and tvp.size.x > 0, "viewports have a pixel size")
	# 剖切面参数：纵向含轴线，横向过球心且垂直轴线。
	var long_pl: Plane = sec.call("longitudinal_plane")
	var trans_pl: Plane = sec.call("transverse_plane")
	_ok(long_pl.normal.is_finite() and trans_pl.normal.is_finite(), "cut-plane normals are finite")
	var axis: Vector3 = vm.call("canal_axis_world")
	var long_dot := absf(long_pl.normal.normalized().dot(axis.normalized()))
	var trans_dot := absf(trans_pl.normal.normalized().dot(axis.normalized()))
	_ok(long_dot < 0.18, "longitudinal plane contains the canal axis (normal·axis=%.3f)" % long_dot)
	_ok(trans_dot > 0.95, "transverse plane is perpendicular to the canal (normal·axis=%.3f)" % trans_dot)
	var ctl: Node = vm.call("tool_controller")
	if ctl and ctl.has_method("debug_set_depth"):
		var opening: Vector3 = vm.call("introitus_world")
		var cerv: Vector3 = vm.call("cervix_world")
		var mid: float = opening.distance_to(cerv) * 0.45
		ctl.call("debug_set_depth", mid)
		await _frames(2)
	var tip: Vector3 = ctl.call("tip_world") if ctl else Vector3.ZERO
	var td := absf(trans_pl.distance_to(tip))
	# 刷新平面。
	trans_pl = sec.call("transverse_plane")
	td = absf(trans_pl.distance_to(tip))
	_ok(td < 0.008, "transverse plane passes through the ball (dist=%.2f mm)" % (td * 1000.0))
	_ok(tip.is_finite() and not is_nan(td), "cut parameters stay finite (no NaN)")
	# 切换 / 开关。
	sec.call("set_view_mode", "long")
	await _frames(1)
	var lbox = sec.get("_long_box")
	var tbox = sec.get("_trans_box")
	_ok(str(sec.get("view_mode")) == "long" and lbox != null and bool(lbox.visible), "can switch to longitudinal only")
	sec.call("set_view_mode", "trans")
	await _frames(1)
	tbox = sec.get("_trans_box")
	_ok(str(sec.get("view_mode")) == "trans" and tbox != null and bool(tbox.visible), "can switch to transverse only")
	sec.call("set_view_mode", "both")
	sec.call("toggle")
	await _frames(1)
	_ok(not bool(sec.get("visible_on")), "PiP can be toggled off")
	sec.call("set_visible_on", true)
	await _frames(1)
	_ok(bool(sec.get("visible_on")), "PiP can be toggled back on")
	_ok(int(sec.get("last_step_usec")) >= 0 and int(sec.get("last_step_usec")) < 8000, "section update is cheap (%d µs)" % int(sec.get("last_step_usec")))
	# 退出模式后关闭。
	vm.call("exit")
	await _frames(2)
	var sec2 = vm.call("cross_section") if vm.has_method("cross_section") else null
	_ok(sec2 == null or not bool(sec2.get("visible_on")), "leaving the mode closes the PiP")
	print("v0419_check: fails=", fails)
	quit(1 if fails > 0 else 0)
