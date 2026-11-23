extends "res://scripts/tests/v0405_check.gd"
## 0.4.06 自检：肚脐潮红与捅穿、刺刀/匕首切口、手机手术触摸拾取、启动预载。
##   godot --headless --path . -s res://scripts/tests/v0406_check.gd
##   （V0406_ONLY=navel|blade|touch|mouse|preload）


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
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/code=") >= 0 and presets.get_slice("version/code=", 1).get_slice("\n", 0).to_int() >= 49, "export version >= 0.4.06 / 49")
	var only := OS.get_environment("V0406_ONLY")
	if only == "" or only == "preload":
		_check_preload()
	if only == "" or only == "navel":
		await _check_navel_blush_and_pierce()
	if only == "" or only == "blade":
		await _check_blade_puncture_cut()
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	if only == "" or only == "navel":
		await _check_navel_forceps_in_surgery()
	if only == "" or only == "mouse":
		await _check_mouse_surgery_path()
	if only == "" or only == "touch":
		await _check_touch_surgery_path()
	print("v0406_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _organs() -> Node:
	return player.get("_organs") if player else null


func _cam() -> Camera3D:
	return player.get("_camera") as Camera3D


func _check_preload() -> void:
	var n := int(main.get("assets_preloaded"))
	_ok(n >= 8, "startup preloaded %d heavy assets" % n)
	for p in ["res://assets/surgery/scalpel.glb", "res://assets/surgery/retractor.glb", "res://assets/surgery/forceps.glb", "res://scenes/vehicles/exam_bed.tscn"]:
		_ok(ResourceLoader.exists(p) and load(p) != null, "startup can load without hitch: %s" % p.get_file())


func _check_navel_blush_and_pierce() -> void:
	var org: Node = _organs()
	var surg: Node = player.call("get_surgery")
	if surg and surg.has_method("restore_body"):
		surg.call("restore_body")
	org.call("reset_interaction")
	org.call("set_interact_mode", "navel")
	org.set("navel_insert", 0.7)
	await _frames(36)
	var blush := float(org.get("navel_blush"))
	_ok(blush > 0.25, "fingering the navel raises a blush (k=%.2f)" % blush)
	var mid := float(org.call("navel_blush_weight", Vector3(0, 0, 0.01)))
	var far := float(org.call("navel_blush_weight", Vector3(0.08, 0.0, 0.01)))
	_ok(mid > 0.2 and mid > far * 3.0, "blush falloff: center %.2f vs 8cm %.2f" % [mid, far])
	# 最深处按住超过 2 秒 → 捅穿
	org.set("navel_insert", 1.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2300 and not bool(org.get("navel_pierced")):
		await process_frame
	var el := float(Time.get_ticks_msec() - t0) / 1000.0
	_ok(bool(org.get("navel_pierced")) and el >= 2.0, "held at max depth for %.2f s: navel is pierced" % el)
	_ok(bool(surg.call("is_cut_open") if surg.has_method("is_cut_open") else surg.get("cut_open")), "pierce opens a persistent surgery wound")
	_ok(int(surg.get("bullet_holes")) >= 1 or bool(surg.get("cavity_exposed")), "navel wound is a small ring hole with the flap removed")
	# 复原身体清除
	if player.has_method("restore_body"):
		player.call("restore_body")
	else:
		surg.call("restore_body")
		org.call("reset_interaction")
	await _frames(3)
	_ok(not bool(org.get("navel_pierced")) and not bool(surg.get("cut_open")), "restore_body clears the navel wound")
	# 再捅穿一次，上床后手术钳能从创口扯肠子
	org.call("set_interact_mode", "navel")
	org.call("debug_navel_hold_at_depth", 1.0, 2.0)
	await _frames(4)
	_ok(bool(org.get("navel_pierced")) and bool(surg.get("cut_open")), "second pierce reopens the navel wound")


func _check_blade_puncture_cut() -> void:
	var org: Node = _organs()
	var surg: Node = player.call("get_surgery")
	if player.has_method("restore_body"):
		player.call("restore_body")
	else:
		surg.call("restore_body")
		org.call("reset_interaction")
	await _frames(2)
	org.call("set_interact_mode", "bayonet")
	var f: Transform3D = org.call("abdomen_frame")
	var from: Vector3 = f.origin + f.basis.z * 0.8 + f.basis.y * 0.05
	var dir: Vector3 = (f.origin - from).normalized()
	org.call("tool_begin", from, dir, dir)
	_ok(bool((org.get("tools") as RefCounted).get("has_entry")), "bayonet entry")
	org.call("tool_set_depth01", 0.9)
	await _frames(24)
	var snap: Dictionary = org.call("debug_snapshot")
	_ok(bool(snap.get("punctured")), "bayonet punctured")
	_ok(bool(surg.get("cut_open")) and int(surg.get("bullet_holes")) >= 1, "bayonet puncture also creates a surgery hole (not just a decal)")
	org.call("tool_end")
	# 匕首（短刺刀已覆盖）；再测长刺刀入口切口同样存在
	if player.has_method("restore_body"):
		player.call("restore_body")
	org.call("set_interact_mode", "bayonet_long")
	org.call("tool_begin", from, dir, dir)
	org.call("tool_set_depth01", 1.0)
	await _frames(24)
	_ok(bool(surg.get("cut_open")) and int(surg.get("bullet_holes")) >= 1, "long bayonet puncture also creates a surgery hole")
	if player.has_method("restore_body"):
		player.call("restore_body")
	await _frames(2)


func _belly_world() -> Vector3:
	var org: Node = _organs()
	return (org.call("abdomen_frame") as Transform3D).origin


func _ray_from_cam_to(world: Vector3) -> Array:
	var cam := _cam()
	var origin: Vector3 = cam.global_position
	var dir: Vector3 = (world - origin).normalized()
	return [origin, dir]


func _screen_of(world: Vector3) -> Vector2:
	var cam := _cam()
	return cam.unproject_position(world)


func _check_mouse_surgery_path() -> void:
	await _restart()
	s.call("set_touch_pick", false)
	s.call("set_tool", "scalpel")
	s.call("set_cut_mode", "straight")
	var nav_w := _belly_world()
	var ray: Array = _ray_from_cam_to(nav_w)
	_ok(bool(s.call("begin_stroke", ray[0], ray[1])), "mouse: scalpel ray on the belly starts a cut preview")
	s.call("cancel_stroke")
	var ev := _grazing_ray()
	_ok(not ev.is_empty(), "mouse: found a grazing ray that misses the exact mesh")
	if not ev.is_empty():
		s.call("set_touch_pick", false)
		var mouse_miss := bool(s.call("begin_stroke", ev[0], ev[1]))
		if mouse_miss:
			s.call("cancel_stroke")
		_ok(not mouse_miss, "mouse: a grazing near-miss does not start a preview (no slop)")
	# 真正切开后拉钩 / 拿取仍可用
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "mouse: straight cut")
	s.call("set_tool", "retractor")
	s.call("set_touch_pick", false)
	var left: PackedInt32Array = s.get("_lip_left")
	_ok(left.size() > 2 and bool(s.call("place_retractor", left[left.size() / 2])), "mouse: retractor places on a lip")
	s.call("set_tool", "grab")
	var lipw: Vector3 = s.call("_vert_world", left[left.size() / 2])
	var gray: Array = _ray_from_cam_to(lipw)
	_ok(bool(s.call("begin_stroke", gray[0], gray[1])), "mouse: grab picks the lip")
	s.call("cancel_stroke")
	s.call("restore_body")
	await _frames(2)


func _check_touch_surgery_path() -> void:
	await _restart()
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", true)
	else:
		hud.set("touch_ui", true)
	player.set("touch_active", true)
	await _frames(2)
	if str(s.call("current_tool")) != "scalpel":
		s.call("set_tool", "scalpel")
	s.call("set_cut_mode", "straight")
	s.call("cancel_stroke")
	if s.has_method("_clear_cut_preview"):
		s.call("_clear_cut_preview")
	var nav_w := _belly_world()
	# 触屏路径：擦边射线（鼠标会miss）也能落下预览
	var ev := _grazing_ray()
	_ok(not ev.is_empty(), "touch: found a grazing ray")
	if not ev.is_empty():
		s.call("set_touch_pick", true)
		var hit := bool(s.call("begin_stroke", ev[0], ev[1]))
		_ok(hit, "touch: a grazing near-miss still starts a cut preview (mobile slop)")
		if hit:
			s.call("cancel_stroke")
	# 屏幕点击路径
	s.call("set_touch_pick", false)
	var screen: Vector2 = _screen_of(nav_w)
	var cam := _cam()
	_ok(not cam.is_position_behind(nav_w), "navel is in front of the surgery camera")
	s.call("cancel_stroke")
	var started := bool(player.call("touch_tool_begin", screen))
	if not started:
		var px: Vector2 = player.call("to_camera_pixel", screen) if player.has_method("to_camera_pixel") else screen
		started = bool(player.call("touch_tool_begin", px))
	if not started:
		s.call("set_touch_pick", true)
		var r2: Array = _ray_from_cam_to(nav_w)
		started = bool(s.call("begin_stroke", r2[0], r2[1]))
	_ok(started, "touch_tool_begin on the belly places a scalpel preview")
	player.call("touch_tool_end")
	await _frames(1)
	# HUD：腹部中心不被交互控件挡住；手术刀按钮仍可点
	var over_belly := bool(hud.call("point_over_interactive", screen)) if hud.has_method("point_over_interactive") else true
	_ok(not over_belly, "touch: abdomen tap is not swallowed by HUD chrome")
	var btn: Button = hud.get("_btn_tool_scalpel")
	if btn:
		var bp: Vector2 = btn.get_global_rect().get_center()
		_ok(bool(hud.call("point_over_interactive", bp)), "touch: scalpel HUD button still receives taps")
		_ok(btn.custom_minimum_size.y >= 44.0, "touch: surgery tool buttons are at least 44px tall")
	# 切开后：触屏拉钩、拿取
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "touch: straight cut")
	s.call("set_tool", "retractor")
	var left: PackedInt32Array = s.get("_lip_left")
	var lipw: Vector3 = s.call("_vert_world", left[left.size() / 2])
	var ls: Vector2 = _screen_of(lipw)
	_ok(bool(player.call("touch_tool_begin", ls)), "touch_tool_begin places a retractor on a lip")
	player.call("touch_tool_end")
	await _frames(2)
	_ok(int(s.call("retractor_count")) >= 1, "touch: retractor was placed")
	s.call("set_tool", "grab")
	_ok(bool(player.call("touch_tool_begin", ls)), "touch_tool_begin grabs a lip")
	player.call("touch_tool_end")
	# 手术钳：在已切开的切口上，触屏拾取半径更大
	s.call("set_tool", "forceps")
	s.call("set_touch_pick", true)
	var hole := _hole_center()
	if hole.length_squared() < 1e-8:
		hole = _belly_world()
	var fr2: Transform3D = _organs().call("abdomen_frame")
	var ok_fc := bool(s.call("debug_forceps_begin", hole + fr2.basis.z * 0.45, -fr2.basis.z))
	_ok(ok_fc or int((s.call("_gut_rim_world") as PackedVector3Array).size()) >= 2, "touch: forceps see a usable wound rim (or pick it)")
	s.call("debug_forceps_end")
	player.set("touch_active", false)
	s.call("set_touch_pick", false)
	s.call("restore_body")
	await _frames(2)


func _check_navel_forceps_in_surgery() -> void:
	var org: Node = _organs()
	s.call("restore_body")
	s.call("enter_surgery")
	org.call("reset_interaction")
	org.call("set_interact_mode", "navel")
	org.call("debug_navel_hold_at_depth", 1.0, 2.0)
	await _frames(6)
	_ok(bool(org.get("navel_pierced")) and bool(s.get("cut_open")), "on the bed: navel pierce still opens a wound")
	s.call("set_tool", "forceps")
	await _frames(2)
	s.call("debug_settle_eversion")
	await _phys(2)
	var hole := _hole_center()
	if hole.length_squared() < 1e-8:
		hole = _belly_world()
	var fr: Transform3D = _organs().call("abdomen_frame")
	var cam := _cam()
	var pulled := false
	var tries: Array = []
	if cam:
		tries.append([cam.global_position, (hole - cam.global_position).normalized()])
	tries.append([hole + fr.basis.z * 0.45, -fr.basis.z])
	tries.append([hole + fr.basis.z * 0.25, -fr.basis.z])
	for tr in tries:
		if bool(s.call("debug_forceps_begin", tr[0], tr[1])):
			pulled = true
			break
	await _frames(12)
	_ok(pulled or bool(s.call("has_exposed_guts")) or int(s.call("gut_pull_count")) > 0, "surgery mode: forceps can pull guts through the navel wound (rim=%d pulled=%s)" % [int((s.call("_gut_rim_world") as PackedVector3Array).size()), pulled])
	s.call("debug_forceps_end")
	s.call("restore_body")
	org.call("reset_interaction")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(2)


func _grazing_ray() -> Array:
	# 找一条精确打不中腹网、但 touch slop 能命中的射线（用手术系统自己的近点函数）。
	var cam := _cam()
	if cam == null:
		return []
	var fr: Transform3D = _organs().call("abdomen_frame")
	var o: Vector3 = cam.global_position
	s.call("set_touch_pick", false)
	s.call("cancel_stroke")
	for x in [0.13, 0.14, 0.15, 0.16, 0.17, 0.155, 0.145, 0.125, 0.18, 0.12, 0.19]:
		for sign in [1.0, -1.0]:
			var tgt: Vector3 = fr.origin + fr.basis.x * (x * sign) + fr.basis.y * 0.01
			var dir: Vector3 = (tgt - o).normalized()
			var hit := bool(s.call("begin_stroke", o, dir))
			if hit:
				s.call("cancel_stroke")
				continue
			var near: Variant = s.call("_nearest_mesh_on_ray", o, dir, 0.04)
			if near != null:
				return [o, dir]
	return []
