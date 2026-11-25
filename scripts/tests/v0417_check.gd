extends "res://scripts/tests/v0409b_check.gd"
## 未发布（0.4.12 开发中）：阴道互动模式框架——进入/退出、镜头预设与轴线对齐、
## 数据工具栏、扩张器从手术栏移入。不打包。
##   godot --headless --path . -s res://scripts/tests/v0417_check.gd


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
	_ok(player != null and player.has_method("get_vagina_mode"), "player exposes get_vagina_mode()")
	var vm = player.call("get_vagina_mode") if player else null
	_ok(vm != null, "vagina mode node exists")
	if vm == null:
		print("v0417_check: fails=", fails)
		quit(1)
		return
	var reg = vm.get("registry")
	_ok(reg != null and reg.has_method("has_tool") and bool(reg.call("has_tool", "speculum")), "tool registry contains the speculum")
	_ok(reg != null and bool(reg.call("has_tool", "ball_rod")), "tool registry reserves the ball-rod slot")
	_ok(int((reg.call("all_tools") as Array).size()) >= 4, "registry keeps reserved slots for future tools")
	if not await _enter_bed():
		print("v0417_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	await _check_mode_and_camera(vm)
	await _check_toolbar(vm)
	print("v0417_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_mode_and_camera(vm) -> void:
	# 先从观察模式进入。
	if bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	player.call("set_play_mode", 0)
	await _frames(2)
	_ok(bool(player.call("is_display_mode")), "player is in observe mode before vagina interaction")
	_ok(bool(vm.call("can_enter")) or str(player.get("occupancy")) == "exam_bed", "vagina mode can be entered from the exam bed")
	_ok(bool(vm.call("enter")), "vagina mode starts from observe mode")
	await _frames(3)
	_ok(bool(vm.call("is_active")) and bool(player.call("is_display_mode")), "mode stays in observe/orbit after enter")
	hud.call("_refresh_surgery_ui")
	await _frames(1)
	if hud.get("_btn_vagina_enter"):
		_ok(not bool(hud.get("_btn_vagina_enter").visible), "enter button hides while vagina mode is on")
	if hud.get("_btn_vagina_exit"):
		_ok(bool(hud.get("_btn_vagina_exit").visible), "exit vagina interaction is available")
	var opening: Vector3 = vm.call("introitus_world")
	_ok(opening.is_finite() and opening.length() > 0.1, "live introitus has a world position")
	var cam: Camera3D = player.call("get_camera")
	var dist := cam.global_position.distance_to(opening) if cam else 99.0
	_ok(dist < 1.25, "camera auto-flies near the genitals (dist=%.2f m)" % dist)
	_ok(int(vm.get("last_step_usec")) >= 0 and int(vm.get("last_step_usec")) < 8000, "camera update is cheap (%d µs)" % int(vm.get("last_step_usec")))

	vm.call("set_camera_preset", "introitus", true)
	await _frames(2)
	var err_i := float(vm.call("camera_alignment_error"))
	var ax_i := float(vm.call("camera_axis_angle"))
	_ok(err_i < deg_to_rad(18.0), "introitus preset looks along the canal (err=%.1f°)" % rad_to_deg(err_i))
	_ok(ax_i < deg_to_rad(18.0), "introitus camera is parallel to the vagina axis (%.1f°)" % rad_to_deg(ax_i))
	_ok((cam.global_transform.basis.x if cam else Vector3.RIGHT).is_finite() and cam.global_position.is_finite(), "introitus camera is finite")

	vm.call("set_camera_preset", "abdomen", true)
	await _frames(2)
	var err_a := float(vm.call("camera_alignment_error"))
	var ax_a := float(vm.call("camera_axis_angle"))
	_ok(err_a < deg_to_rad(22.0), "abdomen preset faces the organs from the belly (err=%.1f°)" % rad_to_deg(err_a))
	_ok(ax_a > deg_to_rad(70.0), "abdomen camera is perpendicular to the vagina axis (%.1f° from axis)" % rad_to_deg(ax_a))
	var up: Vector3 = vm.call("canal_up_world")
	var center: Vector3 = vm.call("organ_group_center")
	var on_belly: bool = cam != null and (cam.global_position - center).dot(up) > 0.0
	_ok(on_belly, "abdomen camera sits on the lower-abdomen side of the organs")

	# 互斥：进手术会退出互动。
	_ok(bool(s.call("enter_surgery")), "surgery can still start")
	await _frames(2)
	_ok(bool(s.call("is_active")) and not bool(vm.call("is_active")), "entering surgery leaves vagina mode")
	s.call("exit_surgery")
	await _frames(2)
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "vagina mode can be re-entered")
	await _frames(2)
	vm.call("exit")
	await _frames(2)
	_ok(not bool(vm.call("is_active")) and bool(player.call("is_display_mode")), "exiting vagina mode returns to observe mode")


func _check_toolbar(vm) -> void:
	if not bool(vm.call("is_active")):
		_ok(bool(vm.call("enter")), "re-enter for toolbar checks")
		await _frames(2)
	hud.call("_refresh_surgery_ui")
	await _frames(1)
	var bar = hud.get("_vagina_bar")
	_ok(bar != null and bool(bar.visible), "vagina toolbar is visible in the mode")
	var btn: Button = hud.get("_btn_tool_speculum")
	_ok(btn != null and bool(btn.visible) and btn.text == "阴道扩张器" and not btn.disabled, "speculum lives on the vagina toolbar")
	# 手术栏不应再挂扩张器。
	if bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(1)
	s.call("enter_surgery")
	await _frames(2)
	hud.call("_refresh_surgery_ui")
	await _frames(1)
	var sbar = hud.get("_surgery_bar")
	var spec_on_surgery := false
	if sbar:
		for c in sbar.get_children():
			if c == btn or (c is Button and str(c.text) == "阴道扩张器" and c != btn):
				spec_on_surgery = true
	_ok(not spec_on_surgery and not bool(s.call("is_active") and btn and btn.get_parent() == sbar), "speculum is not on the surgery toolbar")
	s.call("exit_surgery")
	await _frames(1)
	if not bool(vm.call("is_active")):
		vm.call("enter")
		await _frames(2)
	vm.call("set_tool", "speculum")
	await _frames(2)
	_ok(str(vm.call("current_tool")) == "speculum", "selecting speculum in vagina mode sets the current tool")
	_ok(bool(s.call("is_speculum_present")) or str(s.call("speculum_state")) == "inserting" or bool(s.call("is_speculum_inserted")), "speculum behavior still starts insertion (state=%s)" % str(s.call("speculum_state")))
	if s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
		await _frames(2)
	_ok(bool(s.call("is_speculum_inserted")), "speculum still seats in the canal from vagina mode")
	# 长柄金属球已在下一阶段启用，本框架测试只确认格子还在。
	var slots: Dictionary = hud.get("_vagina_tool_btns")
	if slots.has("ball_rod"):
		_ok(slots["ball_rod"] != null, "ball-rod slot remains on the vagina toolbar")
	vm.call("exit")
	await _frames(2)
	if s.has_method("restore_body"):
		s.call("restore_body")
		await _frames(1)
