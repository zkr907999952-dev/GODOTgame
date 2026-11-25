extends "res://scripts/tests/v0412_check.gd"
## 未发布（0.4.12 开发中）：外阴接缝圈补面 / 细拓扑 / 连续 UV，
## 阴唇改为骨骼+PBD，外口跟随扩张器叶片真实截面，取出后回弹。
##   godot --headless --path . -s res://scripts/tests/v0416_check.gd


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
	_check_vulva_mesh()
	if not await _enter_bed():
		print("v0416_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_vulva_physics()
	print("v0416_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_vulva_mesh() -> void:
	var rig: Node = _rig()
	_ok(rig != null and rig.vulva != null and bool(rig.vulva.ok), "vulva flaps are built")
	if rig == null or rig.vulva == null:
		return
	var vf = rig.vulva
	_ok(vf.has_method("debug_mesh_quality"), "vulva exposes debug_mesh_quality")
	var q: Dictionary = vf.call("debug_mesh_quality")
	_ok(int(q.get("ring_holes", 99)) == 0, "junction ring has no boundary holes (loops=%s holes=%s)" % [q.get("boundary_loops"), q.get("ring_holes")])
	_ok(int(q.get("flipped_normals", 99)) == 0, "junction ring normals are consistent and outward/inward-correct (flipped=%s)" % q.get("flipped_normals"))
	_ok(int(q.get("degenerate_tris", 99)) == 0, "junction ring has no degenerate tris (%s)" % q.get("degenerate_tris"))
	_ok(int(q.get("uv_out_of_range", 99)) == 0, "UVs stay in range (out=%s)" % q.get("uv_out_of_range"))
	_ok(int(q.get("uv_flipped", 99)) == 0, "no flipped UV triangles (%s)" % q.get("uv_flipped"))
	_ok(int(q.get("nan", 99)) == 0, "junction ring has no NaN vertices")
	_ok(int(q.get("ring_tris", 0)) >= 1000, "junction ring is dense enough to stretch (%s tris)" % q.get("ring_tris"))
	_ok(int(q.get("flap_tris", 0)) >= 200, "labia flaps were refined (%s tris)" % q.get("flap_tris"))
	_ok(float(q.get("rim_uv_err", 1.0)) < 0.002, "vestibule rim UVs match the surrounding skin (err=%.4f)" % float(q.get("rim_uv_err", 1.0)))
	if vf.has_method("group_indices"):
		_ok(not (vf.call("group_indices", "introitus_ring") as Array).is_empty(), "named introitus_ring vertex group exists")
		_ok(not (vf.call("group_indices", "labia_majora_l") as Array).is_empty() and not (vf.call("group_indices", "labia_minora_l") as Array).is_empty(), "labia majora/minora groups are separated")
		_ok(not (vf.call("group_indices", "clitoral_hood") as Array).is_empty(), "clitoral hood group is reserved")
		_ok(not (vf.call("group_indices", "canal_seg_0") as Array).is_empty() and not (vf.call("group_indices", "canal_seg_10") as Array).is_empty(), "canal depth segments are named")
	_ok(vf.get("params") != null, "vulva parameters are data-driven")
	_ok(vf.has_method("set_inserter") and vf.has_method("set_capsule_insert"), "generic inserter interface is available")
	# 拨开后接缝圈仍不破。
	rig.call("set_vulva_spread", 1.0)
	var q2: Dictionary = vf.call("debug_mesh_quality")
	_ok(int(q2.get("ring_holes", 99)) == 0 and int(q2.get("nan", 1)) == 0, "spread junction ring stays closed and finite")
	_ok(int(q2.get("degenerate_tris", 99)) == 0, "spread junction ring has no degenerate tris")
	rig.call("set_vulva_spread", 0.0)


func _check_vulva_physics() -> void:
	var rig: Node = _rig()
	var vf = rig.vulva if rig else null
	_ok(vf != null, "vulva is available for physics")
	if vf == null:
		return
	if not bool(s.call("is_speculum_inserted")):
		s.call("set_tool", "speculum")
		s.call("debug_finish_speculum_anim")
		await _frames(3)
	var angles := [0.0, 12.0, 24.0]
	var hy_prev := -1.0
	for ang in angles:
		s.call("set_speculum_angle", ang)
		await _frames(3)
		var pen := float(vf.call("insert_penetration"))
		_ok(pen < 0.0008, "no ring/labia vertex inside the speculum at %.0f° (pen=%.2f mm)" % [ang, pen * 1000.0])
		var ratio := float(vf.call("max_edge_ratio"))
		# 外口现在贴合叶片真实半高（约 26 mm），边拉伸略高于旧的双叶误包络。
		_ok(ratio < 4.50, "max edge stretch is bounded at %.0f° (%.2f)" % [ang, ratio])
		var nan := 0
		for si in 2:
			for p in vf.call("side_positions", si):
				if not (p as Vector3).is_finite():
					nan += 1
		for p2 in vf.call("vestibule_positions"):
			if not (p2 as Vector3).is_finite():
				nan += 1
		_ok(nan == 0, "soft-body step is finite at %.0f°" % ang)
		var ext: Vector2 = vf.call("introitus_half_extents")
		if hy_prev >= 0.0:
			_ok(ext.y > hy_prev + 0.002, "introitus takes the blade height at %.0f° (hy %.1f mm)" % [ang, ext.y * 1000.0])
		else:
			_ok(ext.x >= 0.014 and ext.y >= 0.011, "closed introitus fits the blades (hx=%.1f hy=%.1f mm)" % [ext.x * 1000.0, ext.y * 1000.0])
		hy_prev = ext.y
		var usec := int(vf.get("last_step_usec"))
		_ok(usec < 6000, "soft-body step is cheap at %.0f° (%d µs)" % [ang, usec])
	# 取出后回弹到静息。
	if s.has_method("request_remove_speculum"):
		s.call("request_remove_speculum")
	if s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
		s.call("debug_finish_speculum_anim")
	await _frames(3)
	if rig.has_method("clear_speculum_deform"):
		rig.call("clear_speculum_deform")
	await _frames(2)
	var rest := float(vf.call("rest_error"))
	_ok(rest < 0.0005, "labia return to rest after removal (err=%.2f mm)" % (rest * 1000.0))
	_ok(float(vf.call("insert_penetration")) < 1e-6, "no leftover insert penetration after removal")
	_ok(int(vf.call("debug_mesh_quality").get("nan", 1)) == 0, "rest pose has no NaN")
	await _check_surgery_from_observe()


func _check_surgery_from_observe() -> void:
	# 从观察模式进入手术：工具可用，退出后回到观察。
	if bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	player.call("set_play_mode", 0)  # DISPLAY / 观察
	await _frames(2)
	_ok(bool(player.call("is_display_mode")), "player is in observe/display mode before surgery")
	_ok(bool(s.call("can_enter")) or str(player.get("occupancy")) == "exam_bed", "surgery can be entered from the exam bed in observe mode")
	_ok(bool(s.call("enter_surgery")), "surgery starts from observe mode")
	await _frames(2)
	_ok(bool(s.call("is_active")) and bool(player.call("is_display_mode")), "surgery stays in observe mode after enter (active=%s display=%s)" % [s.call("is_active"), player.call("is_display_mode")])
	hud.call("_refresh_surgery_ui")
	await _frames(1)
	if hud.get("_btn_surgery_enter"):
		_ok(not bool(hud.get("_btn_surgery_enter").visible), "enter button hides while surgery is on")
	if hud.get("_btn_surgery_exit"):
		_ok(bool(hud.get("_btn_surgery_exit").visible), "exit surgery is available in observe mode")
	s.call("set_tool", "scalpel")
	await _frames(2)
	_ok(str(s.call("current_tool")) == "scalpel", "tools can be selected in observe-mode surgery")
	_ok(bool(player.call("is_display_mode")), "picking a tool does not force first-person")
	_ok(not bool(player.call("surgery_look_locked")), "observe camera stays free while a tool is selected")
	s.call("exit_surgery")
	await _frames(2)
	_ok(not bool(s.call("is_active")) and bool(player.call("is_display_mode")), "exiting surgery returns to observe mode")
