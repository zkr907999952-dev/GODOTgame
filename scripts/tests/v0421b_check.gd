extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中，t67u / T-11，T-15 起观察视角以站姿进入不上床）：观察视角进入阴道互动 / 手术；拿取工具拖动悬垂内脏
## （扯出量不变、不放回）；手术钳绕钳口倾斜；夹子宫向腹腔外拉；输卵管 / 卵巢拉伸有上限。
##   godot --headless --path . -s res://scripts/tests/v0421b_check.gd


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
	await _check_observe_entry()
	s = player.call("get_surgery")
	if not bool(s.call("is_active")):
		if str(player.get("occupancy")) != "exam_bed":
			await _enter_bed()
		s.call("enter_surgery")
	await _frames(4)
	await _check_tilt()
	await _check_outward_pull()
	await _check_tubes_bounded()
	await _check_grab_soft()
	await _check_grab_gut()
	print("v0421b_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _wait_until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if bool(cond.call()):
			return true
		await _frames(1)
	return bool(cond.call())


func _leave_bed() -> void:
	var vm: Node = player.call("get_vagina_mode")
	if vm and bool(vm.call("is_active")):
		vm.call("exit")
	var su: Node = player.call("get_surgery")
	if su and bool(su.call("is_active")):
		su.call("exit_surgery")
	await _frames(2)
	if vs.get("occupied") != null:
		vs.call("try_exit")
	await _wait_until(func(): return vs.get("occupied") == null, 90)
	await _frames(4)


func _check_observe_entry() -> void:
	var g: Node = main
	player.call("set_play_mode", 0)
	await _frames(3)
	hud.call("_refresh_surgery_ui")
	var bs: Button = hud.get("_btn_surgery_enter")
	var bv: Button = hud.get("_btn_vagina_enter")
	_ok(str(player.get("occupancy")) != "exam_bed", "observe: player starts on foot")
	_ok(bool(g.call("can_enter_body_mode_from_observe")), "observe: modes can be entered from the character observe view")
	_ok(bs != null and bs.visible, "observe: 开始手术 button is visible in the observe view")
	_ok(bv != null and bv.visible, "observe: 阴道互动 button is visible in the observe view")
	_ok(str(g.call("action_for_key", KEY_Y)) == "vagina_toggle", "observe: Y maps to vagina_toggle")
	_ok(str(g.call("action_for_key", KEY_T)) == "interact_mode", "observe: T keeps cycling interact modes off the bed")
	player.call("set_play_mode", 1)
	await _frames(3)
	hud.call("_refresh_surgery_ui")
	_ok(not bs.visible and not bv.visible, "control mode: the observe entry buttons are hidden")
	player.call("set_play_mode", 0)
	await _frames(3)
	hud.call("_refresh_surgery_ui")
	bv.emit_signal("pressed")
	var vm: Node = player.call("get_vagina_mode")
	var ok_v := await _wait_until(func(): return vm != null and bool(vm.call("is_active")), 40)
	_ok(ok_v, "observe: 阴道互动 button enters vagina mode")
	# T-15：不再自动上检查床，以当前站姿进入。
	_ok(str(player.get("occupancy")) == "" and vs.get("occupied") == null, "observe: player stays standing (not moved onto the exam bed)")
	_ok(bool(player.call("is_display_mode")), "observe: stays in the observe view")
	await _leave_bed()
	_ok(vs.get("occupied") == null and not bool(vm.call("is_active")), "observe: left vagina mode again")
	main.call("run_action", str(main.call("action_for_key", KEY_Y)), KEY_Y)
	var ok_y := await _wait_until(func(): return bool(vm.call("is_active")), 40)
	_ok(ok_y, "observe: Y enters vagina mode from the observe view")
	await _leave_bed()
	hud.call("_refresh_surgery_ui")
	_ok(bs.visible, "observe: 开始手术 button visible again after leaving")
	bs.emit_signal("pressed")
	var su: Node = player.call("get_surgery")
	var ok_s := await _wait_until(func(): return bool(su.call("is_active")), 40)
	_ok(ok_s, "observe: 开始手术 button starts surgery")
	_ok(str(player.get("occupancy")) == "" and bool(su.get("standing_session")), "observe: surgery starts in the standing pose (no bed)")
	_ok(bool(player.call("is_display_mode")), "observe: surgery keeps the observe view")
	# 后面的钳子 / 拿取检查沿用检查床路径。
	su.call("exit_surgery")
	await _frames(2)


func _check_tilt() -> void:
	var cam: Camera3D = player.call("get_camera")
	var tip: Vector3 = s.call("_wound_center_world")
	var dir: Vector3 = (tip - cam.global_position).normalized()
	s.call("_place_forceps", tip, dir)
	var fn: Node3D = s.get("_forceps_node")
	var z: Vector3 = fn.global_transform.basis.z.normalized()
	var ang := rad_to_deg(acos(clampf(z.dot(dir), -1.0, 1.0)))
	var jaw: Vector3 = fn.global_transform.origin + z * float(s.get("FORCEPS_JAW_Z"))
	print("TILT forceps axis vs view ray %.1f°, jaw pivot error %.2f mm" % [ang, jaw.distance_to(tip) * 1000.0])
	_ok(ang > 20.0 and ang < 50.0, "forceps is tilted off the view ray (%.1f°)" % ang)
	_ok(jaw.distance_to(tip) < 0.0005, "tilt pivots around the jaw tip")
	fn.visible = false


func _tube_ratio(so: Node) -> float:
	var m := 0.0
	var tubes: Dictionary = so.get("_tubes")
	for side in tubes.keys():
		var tb: Dictionary = tubes[side]
		if tb.is_empty():
			continue
		var p: PackedVector3Array = tb["p"]
		var rest: PackedFloat32Array = tb["rest"]
		for k in rest.size():
			m = maxf(m, p[k].distance_to(p[k + 1]) / maxf(rest[k], 1e-6))
	return m


func _check_outward_pull() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	_ok(bool(s.call("debug_begin_extract", "uterus")), "outward: forceps grabs the uterus in the cavity")
	var so: Node = s.call("soft_organ", "uterus")
	if so == null:
		return
	var start: Vector3 = s.get("_fc_last")
	_ok((start - wound).dot(outv) < 0.0, "outward: grab point starts inside the cavity")
	var side: Vector3 = outv.cross(Vector3.FORWARD if absf(outv.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var eye := start + outv * 0.25 + side * 0.05
	var dt := 1.0 / 60.0
	var worst_wall := 1.0
	var max_out := -1.0
	var plane_d := 0.0
	var prev_d := -1.0
	var prev_n := start
	for i in 120:
		var p_scr := start + side * (0.0015 * float(i + 1))
		var dir := (p_scr - eye).normalized()
		s.call("_drag_forceps", eye, dir)
		s.call("_update_guts", dt)
		var hp: Vector3 = so.get("hold_pos")
		max_out = maxf(max_out, (hp - wound).dot(outv))
		# t91u：钳尖目标直接从原位拉向创口下缘（不先抬到中心）；真正要穿过洞口的是被夹住的那个子宫节点。
		var X: PackedVector3Array = so.get("_x")
		var dn: Vector3 = X[int(so.get("_drv_i"))] if int(so.get("_drv_i")) >= 0 else hp
		var d := (dn - wound).dot(outv)
		if prev_d < 0.0 and d >= 0.0:
			# 穿过创口平面的那一帧：插值求穿越点离创口中心的距离。
			var t := -prev_d / maxf(d - prev_d, 1e-6)
			var xp := prev_n.lerp(dn, t) - wound
			worst_wall = minf(worst_wall, 0.022 - (xp - outv * xp.dot(outv)).length())
		prev_d = d
		prev_n = dn
		plane_d = (p_scr - wound).dot(outv)
	print("OUTWARD pull: hold point max %.1f cm outside the wound plane (plain drag plane stays at %.1f cm), wall margin %.1f mm, level %d" % [max_out * 100.0, plane_d * 100.0, worst_wall * 1000.0, int(s.call("extract_level", "uterus"))])
	_ok(max_out > 0.03, "outward: a sideways drag pulls the uterus out of the cavity (%.1f cm out)" % (max_out * 100.0))
	_ok(plane_d < 0.0, "outward: (control) the plain drag plane is still inside the cavity")
	_ok(worst_wall > -0.004, "outward: the pulled uterus passes through the wound opening (%.1f mm)" % (worst_wall * 1000.0))
	var pp: Vector3 = s.call("forceps_pull_path", wound - outv * 0.05, wound, outv, side * 0.02)
	_ok((pp - wound).dot(outv) < 0.0 and (pp - (wound - outv * 0.05)).normalized().dot(outv) > 0.95, "outward: path first heads straight to the wound")
	s.call("debug_forceps_end")


func _check_tubes_bounded() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	s.call("debug_begin_extract", "uterus")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 60.0)
	var so: Node = s.call("soft_organ", "uterus")
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var cage: PackedVector3Array = so.get("_p")
	var aim: Vector3 = cage[cage.size() - 1]
	var cam_o := aim + outv * 0.12
	s.call("debug_forceps_begin", cam_o, (aim - cam_o).normalized())
	var dt := 1.0 / 60.0
	var tip: Vector3 = so.get("hold_pos")
	var mx := 0.0
	var gap := 0.0
	for i in 60:
		tip = tip.move_toward(wound + outv * 0.02, 0.25 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		mx = maxf(mx, _tube_ratio(so))
	for i in 60:
		tip += outv * 0.2 * dt
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		mx = maxf(mx, _tube_ratio(so))
	var sidev: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	for j in 12:
		tip += sidev * (0.9 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		mx = maxf(mx, _tube_ratio(so))
	s.call("debug_forceps_end")
	for k in 120:
		s.call("_update_guts", dt)
		mx = maxf(mx, _tube_ratio(so))
		for sd in [0, 1]:
			gap = maxf(gap, maxf(float(so.call("tube_head_gap", sd)), float(so.call("ovary_tip_gap", sd))))
	print("TUBES pull + fling: max tube segment stretch %.3f, worst horn/ovary gap %.2f mm" % [mx, gap * 1000.0])
	# t92u：输卵管是弹性管——可伸长，但有安全上限，不会被拉成细线 / 发散。
	_ok(mx <= 1.62, "tubes: segment stretch stays within the elastic safety cap during pull + fling (%.3f)" % mx)
	_ok(gap < 0.003, "tubes: tube head stays on the horn, ovary on the tube tip (%.2f mm)" % (gap * 1000.0))
	var ov: Vector3 = so.call("ovary_world", 0)
	var co := ov + outv * 0.1
	_ok(bool(s.call("debug_forceps_begin", co, (ov - co).normalized())) and str(s.get("_fc_kind")) == "tube", "tubes: forceps grabs the ovary/tube chain")
	var t2 := ov
	var mx2 := 0.0
	for k2 in 90:
		t2 += (outv - sidev).normalized() * 0.3 * dt
		s.call("debug_forceps_drag_to", t2)
		s.call("_update_guts", dt)
		mx2 = maxf(mx2, _tube_ratio(so))
	print("TUBES drag ovary far: max stretch %.3f, ovary gap %.2f mm, head gap %.2f mm" % [mx2, float(so.call("ovary_tip_gap", 0)) * 1000.0, float(so.call("tube_head_gap", 0)) * 1000.0])
	_ok(mx2 > 1.1 and mx2 <= 1.62, "tubes: dragging the ovary far stretches the tube elastically, within the cap (%.3f)" % mx2)
	_ok(float(so.call("tube_head_gap", 0)) < 0.001, "tubes: tube stays attached to the horn while dragged")
	s.call("debug_forceps_end")
	for k3 in 90:
		s.call("_update_guts", dt)
	print("TUBES released: stretch %.3f" % float(so.call("tube_stretch", 0)))
	_ok(float(so.call("tube_stretch", 0)) < 1.08, "tubes: the tube springs back after the forceps let go (%.3f)" % float(so.call("tube_stretch", 0)))


func _settle(n: int) -> void:
	for i in n:
		s.call("_update_guts", 1.0 / 60.0)


func _check_grab_soft() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	s.call("debug_begin_extract", "uterus")
	var so: Node = s.call("soft_organ", "uterus")
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var tip: Vector3 = so.get("hold_pos")
	var dt := 1.0 / 60.0
	for i in 60:
		tip = tip.move_toward(wound + outv * 0.02, 0.25 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
	for i in 30:
		tip += outv * 0.2 * dt
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
	s.call("debug_forceps_end")
	_settle(120)
	var t0 := float(so.call("tether_length"))
	var c0 := float(s.call("extract_charge", "uterus"))
	var l0 := int(s.call("extract_level", "uterus"))
	var n0 := int(so.call("body_out_count"))
	var puts0 := int(s.get("organ_putbacks"))
	var cage: PackedVector3Array = so.get("_p")
	var bi := cage.size() - 1
	for b in range(cage.size() - 1, -1, -1):
		if bool(so.call("node_outside", b)):
			bi = b
			break
	var aim := cage[bi]
	var eye := aim + outv * 0.15 + Vector3(0.0, 0.0, 0.01)
	var ok := bool(s.call("debug_organ_grab_begin", eye, (aim - eye).normalized()))
	_ok(ok and str(s.get("organ_grab_kind")) == "soft", "grab tool: picks the dangling uterus (kind=%s)" % s.get("organ_grab_kind"))
	var sidev: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	var g := aim
	var tmax := t0
	var cmax := c0
	var inside_hits := 0
	var moved := 0.0
	for i in 60:
		g += outv * 0.004
		s.call("debug_organ_grab_to", g)
		s.call("_update_guts", dt)
		tmax = maxf(tmax, float(so.call("tether_length")))
		cmax = maxf(cmax, float(s.call("extract_charge", "uterus")))
	for i in 30:
		g += sidev * (0.012 if (i / 10) % 2 == 0 else -0.012)
		s.call("debug_organ_grab_to", g)
		s.call("_update_guts", dt)
		tmax = maxf(tmax, float(so.call("tether_length")))
		cmax = maxf(cmax, float(s.call("extract_charge", "uterus")))
		moved = maxf(moved, (so.get("hold_pos") as Vector3).distance_to(aim))
	for i in 60:
		g = g.move_toward(wound - outv * 0.06, 0.004)
		s.call("debug_organ_grab_to", g)
		s.call("_update_guts", dt)
		var hp: Vector3 = so.get("hold_pos")
		if (hp - wound).dot(outv) < 0.0:
			inside_hits += 1
		tmax = maxf(tmax, float(so.call("tether_length")))
	var during_c := float(s.call("extract_charge", "uterus"))
	s.call("debug_organ_grab_end")
	_settle(150)
	var t1 := float(so.call("tether_length"))
	var l1 := int(s.call("extract_level", "uterus"))
	var n1 := int(so.call("body_out_count"))
	print("GRAB soft uterus: tether %.2f→max %.2f→%.2f cm, charge %.2f (max during %.2f, at push %.2f), level %d→%d, out nodes %d→%d, moved %.1f cm, held point inside %d frames, retracting=%s" % [t0 * 100, tmax * 100, t1 * 100, c0, cmax, during_c, l0, l1, n0, n1, moved * 100, inside_hits, so.get("retracting")])
	_ok(moved > 0.02, "grab tool: the dangling uterus moves / swings with the grab")
	_ok(tmax <= t0 + 1e-5 and absf(t1 - t0) < 1e-5, "grab tool: tether is not pulled longer (nothing more comes out)")
	_ok(absf(cmax - c0) < 1e-4 and absf(during_c - c0) < 1e-4, "grab tool: extraction charge frozen while dragging")
	_ok(l1 == l0, "grab tool: extraction level unchanged after release (%d→%d)" % [l0, l1])
	_ok(inside_hits == 0, "grab tool: pushing toward the wound does not put the held part back inside")
	_ok(not bool(so.get("retracting")) and int(s.get("organ_putbacks")) == puts0, "grab tool: release never starts a put-back")
	_ok(n1 >= n0 - 1, "grab tool: uterus still outside after release (%d→%d nodes)" % [n0, n1])
	if bool(so.call("tube_chain_active", 0)):
		var rope: Node = so.call("_chain_node", 0)
		var pts: PackedVector3Array = rope.call("points")
		var a2 := pts[pts.size() / 2]
		var e2 := a2 + outv * 0.12
		var ok2 := bool(s.call("debug_organ_grab_begin", e2, (a2 - e2).normalized()))
		_ok(ok2 and str(s.get("organ_grab_kind")) in ["tube", "soft"], "grab tool: picks a dangling tube chain (kind=%s)" % s.get("organ_grab_kind"))
		var g2 := a2
		var mxr := 0.0
		for i in 40:
			g2 += (outv + sidev).normalized() * 0.004
			s.call("debug_organ_grab_to", g2)
			s.call("_update_guts", dt)
			mxr = maxf(mxr, _tube_ratio(so))
		s.call("debug_organ_grab_end")
		_ok(absf(float(so.call("tether_length")) - t0) < 1e-5, "grab tool: dragging a tube does not pull the uterus further")
		_ok(mxr <= 1.62, "grab tool: dragged tube stretches elastically but within the safety cap (%.3f)" % mxr)


func _check_grab_gut() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	_ok(bool(s.call("debug_begin_extract", "small_intestine")), "gut: small intestine loop pulled out")
	var pulls: Array = s.get("_gut_pulls")
	if pulls.is_empty():
		return
	var rope: Node = (pulls[pulls.size() - 1] as Dictionary)["rope"]
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var tip: Vector3 = rope.get("hold_pos")
	for i in 30:
		tip += outv * 0.002
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", 1.0 / 60.0)
	s.call("debug_forceps_end")
	_settle(60)
	var fed0 := float(rope.get("fed_len"))
	var r := rope.call("outside_range") as Vector2i
	var pts: PackedVector3Array = rope.call("points")
	var mid := clampi((r.x + r.y) / 2, r.x, r.y)
	var aim := pts[mid]
	var eye := aim + outv * 0.12
	var ok := bool(s.call("debug_organ_grab_begin", eye, (aim - eye).normalized()))
	_ok(ok and str(s.get("organ_grab_kind")) == "gut", "gut: grab tool picks the dangling loop (kind=%s)" % s.get("organ_grab_kind"))
	var g := aim
	var fmax := fed0
	var sidev: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	var moved := 0.0
	for i in 80:
		g += (outv * 0.004) if i < 40 else (sidev * (0.01 if (i / 8) % 2 == 0 else -0.01))
		s.call("debug_organ_grab_to", g)
		s.call("_update_guts", 1.0 / 60.0)
		fmax = maxf(fmax, float(rope.get("fed_len")))
		moved = maxf(moved, (rope.get("hold_pos") as Vector3).distance_to(aim))
	s.call("debug_organ_grab_end")
	_settle(30)
	var fed1 := float(rope.get("fed_len"))
	print("GRAB gut: fed %.2f → max %.2f → %.2f cm, moved %.1f cm, retracting=%s" % [fed0 * 100, fmax * 100, fed1 * 100, moved * 100, rope.get("retracting")])
	_ok(moved > 0.01, "gut: the loop moves with the grab")
	_ok(fmax <= fed0 + 1e-6 and absf(fed1 - fed0) < 1e-6, "gut: grab drag does not pull more intestine out")
	_ok(not bool(rope.get("retracting")), "gut: release does not put the loop back")
