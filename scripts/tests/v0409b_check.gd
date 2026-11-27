extends "res://scripts/tests/v0409_check.gd"
## 0.4.09/0.4.10 阴道扩张器：实模网格 / 插入 / 开合 / 闭合取出 / 换工具保持 / 跟随身体，无 NaN。
## 不钉死导出版本号。
##   godot --headless --path . -s res://scripts/tests/v0409b_check.gd


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
	var only := OS.get_environment("V0409B_ONLY")
	if only == "" or only == "canal":
		_check_canal()
	if not await _enter_bed():
		print("v0409b_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	if only == "" or only == "insert":
		await _check_insert_open()
	if only == "" or only == "persist":
		await _check_persist_and_follow()
	if only == "" or only == "remove":
		await _check_close_remove()
	print("v0409b_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _rig() -> Node:
	return player.call("get_organs") if player and player.has_method("get_organs") else null


func _finite_xf(xf: Transform3D, msg: String) -> void:
	_ok(xf.origin.is_finite() and xf.basis.x.is_finite() and xf.basis.y.is_finite() and xf.basis.z.is_finite(), msg)
	_ok(not is_nan(xf.origin.x) and not is_inf(xf.origin.x), msg + " (no NaN/Inf)")


func _check_canal() -> void:
	var rig: Node = _rig()
	_ok(rig != null and rig.has_method("vagina_canal"), "organ_rig exposes vagina_canal()")
	if rig == null or not rig.has_method("vagina_canal"):
		return
	var d: Dictionary = rig.call("vagina_canal")
	_ok(not d.is_empty() and d.has("opening_ab") and d.has("cervix_ab") and d.has("axis_ab"), "vagina landmarks exist (opening, cervix, axis)")
	if d.is_empty():
		return
	var o: Vector3 = d["opening_ab"]
	var c: Vector3 = d["cervix_ab"]
	var ax: Vector3 = d["axis_ab"]
	var up: Vector3 = d["up_ab"]
	_ok(o.is_finite() and c.is_finite() and ax.is_finite() and up.is_finite(), "canal vectors are finite")
	_ok(float(d["length"]) > 0.03, "canal length is usable (%.1f cm)" % (float(d["length"]) * 100.0))
	_ok(o.distance_to(c) > 0.03, "cervix is distinct from the introitus (%.1f cm)" % (o.distance_to(c) * 100.0))
	_ok(ax.length() > 0.95 and absf(ax.dot(up)) < 0.08, "axis and opening direction are unit and perpendicular")
	# 宫颈点应落在子宫附近（0.4.08 已连接），扩张后应能看见。
	var cw: Vector3 = d["cervix_world"]
	_ok(cw.is_finite(), "cervix has a world position")


func _check_insert_open() -> void:
	_ok(s.has_method("set_speculum_angle") and s.has_method("is_speculum_inserted"), "surgery system exposes speculum API")
	hud.call("_refresh_surgery_ui")
	await _frames(2)
	var btn: Button = hud.get("_btn_tool_speculum")
	_ok(btn != null and btn.text == "阴道扩张器", "speculum tool button still exists (now on the vagina-interaction toolbar)")
	s.call("set_tool", "speculum")
	await _frames(2)
	_ok(str(s.call("current_tool")) == "speculum", "selecting the tool sets current_tool to speculum")
	_ok(bool(s.call("is_speculum_present")) or str(s.call("speculum_state")) == "inserting", "selecting the tool starts insertion (state=%s)" % str(s.call("speculum_state")))
	s.call("debug_finish_speculum_anim")
	await _frames(3)
	_ok(bool(s.call("is_speculum_inserted")), "insertion animation finishes in the seated closed pose (state=%s)" % str(s.call("speculum_state")))
	_ok(absf(float(s.call("speculum_angle"))) < 0.26, "initial opening is closed (%.2f°)" % float(s.call("speculum_angle")))
	var n: Node3D = s.call("speculum_node")
	_ok(n != null and n.visible, "speculum node is in the tree and visible")
	if n:
		_finite_xf(n.global_transform, "inserted speculum transform is finite")
		var ujaw := n.get_node_or_null("UpperJaw") as Node3D
		var ljaw := n.get_node_or_null("LowerJaw") as Node3D
		_ok(ujaw != null and ljaw != null, "speculum has UpperJaw / LowerJaw hinged halves")
		var mi := n.get_node_or_null("UpperJaw/Mesh") as MeshInstance3D
		if mi and mi.material_override is StandardMaterial3D:
			var mat: StandardMaterial3D = mi.material_override
			_ok(mat.metallic >= 0.99 and mat.roughness >= 0.08 and mat.roughness <= 0.15, "chrome metal: metallic=%.2f roughness=%.2f" % [mat.metallic, mat.roughness])
		else:
			_ok(false, "upper jaw has a StandardMaterial3D chrome override")
		# 叶片沿局部 +Z，实模约 11.4 cm。
		if mi and mi.mesh:
			var aabb: AABB = mi.mesh.get_aabb()
			var tip := aabb.position.z + aabb.size.z
			_ok(tip >= 0.095 and tip <= 0.13, "blade length is ~11.4 cm (tip at %.1f cm)" % (tip * 100.0))
			var idx = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			_ok(idx.size() >= 2000 * 3, "upper jaw uses the real STL mesh (%d tris)" % (idx.size() / 3))
		_ok(n.has_meta("speculum_source") and str(n.get_meta("speculum_source")) == "glb", "speculum is built from the converted STL glb")
		var lmi := n.get_node_or_null("LowerJaw/Mesh") as MeshInstance3D
		if lmi and lmi.mesh:
			var lidx = lmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			_ok(lidx.size() >= 5000 * 3, "lower jaw uses the real STL mesh (%d tris)" % (lidx.size() / 3))
	var rig: Node = _rig()
	var canal: Dictionary = rig.call("vagina_canal") if rig else {}
	var spread_closed := 0.0
	var gap_closed := 0.0
	if n and not canal.is_empty():
		var hinge := n.global_position
		var opening: Vector3 = canal["opening_world"]
		var cervix_w: Vector3 = canal["cervix_world"]
		var ax_w: Vector3 = (cervix_w - opening).normalized()
		var z := n.global_transform.basis.z.normalized()
		_ok(z.dot(ax_w) > 0.98, "inserted blades follow the vaginal axis (dot=%.4f)" % z.dot(ax_w))
		var tip := hinge + z * 0.114
		var tip_mm := tip.distance_to(cervix_w) * 1000.0
		_ok(tip_mm < 18.0, "blade tip sits just short of the cervix (%.1f mm)" % tip_mm)
		# 铰链在体外：叶片比阴道长，不能再要求铰链贴在外口。
		var h_mm := hinge.distance_to(opening) * 1000.0
		_ok(h_mm > 30.0 and h_mm < 90.0, "hinge stays outside the introitus (%.1f mm)" % h_mm)
	if rig:
		# 扩张器只按叶片截面撑开外口，不再驱动左右铰链（vulva_spread）。
		spread_closed = float(rig.call("vulva_spread"))
		_ok(spread_closed < 0.15, "inserted closed speculum does not mechanically hinge the labia (spread=%.2f)" % spread_closed)
		var so0: Vector4 = rig.get("_spec_o")
		gap_closed = float(rig.get("_spec_d").w)
		_ok(so0.w > 0.03 and so0.is_finite(), "wall deform is already on after closed insertion (depth=%.1f cm)" % (so0.w * 100.0))
		if rig.vulva and rig.vulva.has_method("introitus_half_extents"):
			var ext0: Vector2 = rig.vulva.call("introitus_half_extents")
			_ok(ext0.x >= 0.014 and ext0.y >= 0.011, "introitus opens enough for the closed blades (hx=%.1f hy=%.1f mm)" % [ext0.x * 1000.0, ext0.y * 1000.0])
	# 开合滑条和取出按钮已移到阴道互动工具栏。
	var vm: Node = player.call("get_vagina_mode") if player and player.has_method("get_vagina_mode") else null
	_ok(vm != null, "player exposes get_vagina_mode() for the relocated speculum HUD")
	if vm:
		vm.call("enter")
		vm.call("set_tool", "speculum")
		if hud.has_method("_refresh_vagina_ui"):
			hud.call("_refresh_vagina_ui")
		await _frames(2)
	var box: Control = hud.get("_speculum_box")
	var sl: Slider = hud.get("_speculum_slider")
	_ok(box != null and box.visible and sl != null, "opening slider is shown while the tool is active and inserted")
	s.call("set_speculum_angle", 22.0)
	await _frames(3)
	_ok(absf(float(s.call("speculum_angle")) - 22.0) < 0.3, "slider/API sets opening to 22° (got %.1f)" % float(s.call("speculum_angle")))
	if n:
		var ujaw2 := n.get_node_or_null("UpperJaw") as Node3D
		var ljaw2 := n.get_node_or_null("LowerJaw") as Node3D
		if ujaw2 and ljaw2:
			_ok(ujaw2.rotation.x < -0.15 and ljaw2.rotation.x > 0.15, "jaws rotate opposite ways around the pin (U=%.1f° L=%.1f°)" % [rad_to_deg(ujaw2.rotation.x), rad_to_deg(ljaw2.rotation.x)])
		_finite_xf(n.global_transform, "open speculum transform is finite")
	if rig:
		var spread_open := float(rig.call("vulva_spread"))
		_ok(absf(spread_open - spread_closed) < 0.08, "opening the slider does not change labia spread (closed=%.2f open=%.2f)" % [spread_closed, spread_open])
		var so: Vector4 = rig.get("_spec_o")
		var gap_open := float(rig.get("_spec_d").w)
		_ok(so.w > 0.03 and so.is_finite(), "vaginal wall deform is driven (depth=%.1f cm)" % (so.w * 100.0))
		_ok(gap_open > gap_closed + 0.008, "slider widens the vaginal wall gap only (%.1f -> %.1f mm)" % [gap_closed * 1000.0, gap_open * 1000.0])
	var rem: Button = hud.get("_btn_spec_remove")
	_ok(rem != null and rem.visible, "「取出扩张器」 is available on PC and touch")
	# 后续保持/取出用例仍走手术系统 API，需回到手术模式。
	if vm:
		vm.call("exit")
	s.call("enter_surgery")
	await _frames(2)


func _check_persist_and_follow() -> void:
	if not bool(s.call("is_speculum_inserted")):
		s.call("set_tool", "speculum")
		s.call("debug_finish_speculum_anim")
		s.call("set_speculum_angle", 22.0)
		await _frames(2)
	var n: Node3D = s.call("speculum_node")
	var p0 := n.global_position if n else Vector3.ZERO
	var a0 := float(s.call("speculum_angle"))
	s.call("set_tool", "scalpel")
	await _frames(4)
	_ok(str(s.call("current_tool")) == "scalpel", "switched to scalpel")
	_ok(bool(s.call("is_speculum_inserted")), "switching tools keeps the speculum inserted")
	_ok(absf(float(s.call("speculum_angle")) - a0) < 0.3, "opening angle is preserved on tool switch (%.1f°)" % float(s.call("speculum_angle")))
	if n and is_instance_valid(n):
		_ok(n.visible and n.global_position.distance_to(p0) < 0.02, "pose stays put when switching tools (moved %.1f mm)" % (n.global_position.distance_to(p0) * 1000.0))
	# 再选回来不应重新插入或把开口清零。
	s.call("set_tool", "speculum")
	await _frames(2)
	_ok(str(s.call("speculum_state")) == "inserted", "re-selecting the tool does not restart insertion (state=%s)" % str(s.call("speculum_state")))
	_ok(absf(float(s.call("speculum_angle")) - a0) < 0.3, "angle still %.1f° after re-select" % float(s.call("speculum_angle")))
	# 跟随腹部坐标系（检查床上姿态 / 呼吸轻微移动）。
	var rig: Node = _rig()
	if rig and n and rig.has_method("vagina_canal") and rig.has_method("begin_drag"):
		var canal: Dictionary = rig.call("vagina_canal")
		var open0: Vector3 = canal["opening_world"]
		var h0 := n.global_position
		var offset := (rig.call("abdomen_frame") as Transform3D).basis.x * 0.045
		rig.call("begin_drag", open0)
		rig.call("update_drag", open0 + offset)
		await _phys(12)
		await _frames(8)
		var h1 := n.global_position
		_ok(h1.is_finite(), "speculum stays finite while the abdomen is dragged")
		_ok(h1.distance_to(h0) > 0.006, "speculum follows soft-body / drag (moved %.1f mm, not left behind)" % (h1.distance_to(h0) * 1000.0))
		rig.call("end_drag")
		await _phys(16)
		await _frames(4)
		_finite_xf(n.global_transform, "speculum is finite after drag release")
	# 退出手术模式时器械仍留在体内并跟随。
	s.call("exit_surgery")
	await _frames(4)
	_ok(bool(s.call("is_speculum_inserted")) and n and is_instance_valid(n) and n.visible, "leaving surgery mode keeps the current opening and pose")
	s.call("enter_surgery")
	s.call("set_tool", "speculum")
	await _frames(2)


func _check_close_remove() -> void:
	if not bool(s.call("is_speculum_present")):
		s.call("set_tool", "speculum")
		s.call("debug_finish_speculum_anim")
		s.call("set_speculum_angle", 28.0)
		await _frames(2)
	var n: Node3D = s.call("speculum_node")
	var canal: Dictionary = _rig().call("vagina_canal") if _rig() else {}
	# 点击取出：射线打在器械上。
	if n and not canal.is_empty():
		var origin: Vector3 = n.global_position + n.global_transform.basis.y * 0.15
		var dir: Vector3 = (n.global_position - origin).normalized()
		_ok(bool(s.call("begin_stroke", origin, dir)), "clicking the inserted speculum starts close-then-withdraw")
	else:
		_ok(bool(s.call("request_remove_speculum")), "request_remove_speculum starts close-then-withdraw")
	await _frames(2)
	_ok(str(s.call("speculum_state")) == "closing" or str(s.call("speculum_state")) == "withdrawing" or not bool(s.call("is_speculum_present")), "remove animation is close-then-withdraw (state=%s)" % str(s.call("speculum_state")))
	s.call("debug_finish_speculum_anim")
	await _frames(3)
	_ok(not bool(s.call("is_speculum_present")), "after the withdraw animation the tool is gone")
	_ok(s.call("speculum_node") == null or not is_instance_valid(s.call("speculum_node")) or not (s.call("speculum_node") as Node3D).visible, "speculum node is removed or hidden")
	var rig: Node = _rig()
	if rig:
		var so: Vector4 = rig.get("_spec_o")
		_ok(so.w <= 0.0, "wall deform stops after removal")
	# 复原身体也会清掉未取出的扩张器。
	s.call("set_tool", "speculum")
	s.call("debug_finish_speculum_anim")
	s.call("set_speculum_angle", 20.0)
	await _frames(2)
	_ok(bool(s.call("is_speculum_inserted")), "can insert again after a full removal")
	s.call("restore_body")
	await _frames(3)
	_ok(not bool(s.call("is_speculum_present")), "restore_body removes a left-in-place speculum")
