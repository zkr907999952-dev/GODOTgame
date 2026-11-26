extends "res://scripts/tests/v0411_check.gd"
## 未发布（t96u / t97u）：普通互动工具（拖拽手等，不只是手术拿取工具）都能抓住并拖动悬垂的物理器官：
## 取出悬挂的子宫、输卵管 / 卵巢、肠袢、脱垂子宫（共享 HangGrab 接口）。
##   godot --headless --path . -s res://scripts/tests/v0425_hang_grab_check.gd

const DT := 1.0 / 60.0


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
		print("v0425_hang_grab_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_gut()
	await _check_uterus_and_tubes()
	await _check_prolapse()
	print("v0425_hang_grab_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _cam_n() -> Vector3:
	var cam: Camera3D = player.call("get_camera")
	return (-cam.global_transform.basis.z).normalized() if cam else Vector3.FORWARD


## 从相机方向对准 p 抓；然后在相机平面里把射线平移 move（每帧一小步）。返回抓点总位移。
func _grab_and_drag(p: Vector3, move: Vector3, steps: int, step_guts: bool) -> bool:
	var n := _cam_n()
	var o := p - n * 0.25
	if not bool(player.call("debug_begin_hang_grab", o, n)):
		return false
	for i in steps:
		player.call("debug_update_hang_grab", o + move * (float(i + 1) / float(steps)), n)
		if step_guts:
			s.call("_update_guts", DT)
		else:
			await _phys(1)
	return true


func _side_move(amount: float) -> Vector3:
	var n := _cam_n()
	var side := n.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = Vector3.RIGHT
	return side.normalized() * amount


# ---------------------------------------------------------------- 肠袢
func _check_gut() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	var aim: Array = _aim_at_kind("small_intestine")
	if aim.is_empty() or not bool(s.call("debug_forceps_begin_kind", aim[0], aim[1], PackedStringArray(["small_intestine", "colon"]))):
		_ok(false, "gut: forceps pull a loop out first")
		return
	var rope: Node = (s.call("gut_ropes") as Array)[0]
	var tip0: Vector3 = rope.get("hold_pos")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	for i in 60:
		s.call("debug_forceps_drag_to", tip0 + outv * (0.10 * float(i + 1) / 60.0))
		s.call("_update_guts", DT)
	s.call("debug_forceps_end")
	for i2 in 30:
		s.call("_update_guts", DT)
	s.call("set_tool", "")
	var r: Vector2i = rope.call("outside_range")
	var pts: PackedVector3Array = rope.call("points")
	var mid := clampi((r.x + r.y) / 2, 1, pts.size() - 2)
	var p0 := pts[mid]
	var f0 := float(rope.get("fed_len"))
	var ok := await _grab_and_drag(p0, _side_move(0.05), 40, true)
	var organ: Node = player.call("hang_grab_organ")
	var moved := (rope.get("hold_pos") as Vector3).distance_to(p0)
	for i3 in 20:
		s.call("_update_guts", DT)
	var pts2: PackedVector3Array = rope.call("points")
	var moved_pt := pts2[mid].distance_to(p0) if mid < pts2.size() else 0.0
	player.call("debug_end_hang_grab")
	print("HANG gut: grabbed=%s organ=%s hold moved %.1f cm, point moved %.1f cm, fed %.1f → %.1f cm, hold after release %d" % [ok, organ.name if organ else "-", moved * 100, moved_pt * 100, f0 * 100, float(rope.get("fed_len")) * 100, int(rope.get("hold_index"))])
	_ok(ok and organ == rope, "gut: with no surgery tool the hand grabs the hanging intestine loop")
	_ok(moved_pt > 0.015, "gut: the loop follows the hand drag (%.1f cm)" % (moved_pt * 100))
	_ok(float(rope.get("fed_len")) <= f0 + 1e-4, "gut: dragging by hand does not pull more intestine out")
	_ok(int(rope.get("hold_index")) < 0, "gut: release lets it go")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


# ---------------------------------------------------------------- 子宫 + 输卵管 / 卵巢
func _extract_uterus() -> Node:
	await _open_wound()
	s.call("set_tool", "forceps")
	s.call("debug_begin_extract", "uterus")
	s.call("debug_forceps_end")
	var so: Node = s.call("soft_organ", "uterus")
	for i in 40:
		s.call("debug_add_extract_charge", "uterus", 1.0, 1.0 / 30.0)
		s.call("_update_guts", DT)
	for i2 in 200:
		s.call("_update_guts", DT)
	return so


func _body_pt(so: Node) -> Array:
	var P: PackedVector3Array = so.get("_p")
	for b in range(P.size() - 1, -1, -1):
		if bool(so.call("node_outside", b)):
			return [b, P[b]]
	return [-1, Vector3.ZERO]


func _check_uterus_and_tubes() -> void:
	var so := await _extract_uterus()
	if so == null:
		_ok(false, "uterus: extracted")
		return
	s.call("set_tool", "")
	# 1) 手术模式、不拿工具：用手抓悬挂的子宫
	var bp: Array = _body_pt(so)
	var lvl0 := int(s.call("extract_level", "uterus"))
	var ch0 := float(s.call("extract_charge", "uterus"))
	var P0: PackedVector3Array = (so.get("_p") as PackedVector3Array).duplicate()
	var ok := await _grab_and_drag(bp[1], _side_move(0.05), 40, true)
	var part := str(so.call("hang_grab_part"))
	bp[0] = int(so.get("hold_index"))
	var P1: PackedVector3Array = so.get("_p")
	var moved := P1[int(bp[0])].distance_to(P0[int(bp[0])]) if int(bp[0]) >= 0 else 0.0
	player.call("debug_end_hang_grab")
	for i in 60:
		s.call("_update_guts", DT)
	print("HANG uterus (surgery, no tool): grabbed=%s part=%s node %d moved %.1f cm, level %d→%d, charge %.2f→%.2f, out nodes %d" % [ok, part, int(bp[0]), moved * 100, lvl0, int(s.call("extract_level", "uterus")), ch0, float(s.call("extract_charge", "uterus")), int(so.call("body_out_count"))])
	_ok(ok and part == "body", "uterus: the hand grabs the hanging extracted uterus")
	_ok(moved > 0.015, "uterus: it follows the hand (%.1f cm)" % (moved * 100))
	_ok(int(s.call("extract_level", "uterus")) == lvl0 and absf(float(s.call("extract_charge", "uterus")) - ch0) < 1e-4, "uterus: hand dragging does not pull it further out")
	_ok(int(so.call("body_out_count")) == 6 and int(so.get("hold_index")) < 0, "uterus: released, still outside, swinging free")
	# 2) 输卵管 / 卵巢
	var ov: Vector3 = so.call("ovary_world", 0)
	var ok2 := await _grab_and_drag(ov, _side_move(0.04) + Vector3.UP * 0.02, 40, true)
	var part2 := str(so.call("hang_grab_part"))
	var ov2: Vector3 = so.call("ovary_world", 0)
	var gap := float(so.call("tube_head_gap", 0))
	player.call("debug_end_hang_grab")
	print("HANG ovary/tube: grabbed=%s part=%s ovary moved %.1f cm, horn gap %.3f mm, stretch %.3f" % [ok2, part2, ov2.distance_to(ov) * 100, gap * 1000, float(so.call("tube_stretch", 0))])
	_ok(ok2 and part2 == "tube", "tubes: the hand grabs the tube / ovary")
	_ok(ov2.distance_to(ov) > 0.015, "tubes: the ovary follows the hand (%.1f cm)" % (ov2.distance_to(ov) * 100))
	_ok(gap < 0.0002, "tubes: still attached to the horn while dragged by hand")
	# 3) 退出手术（保留体外子宫），普通互动：拖拽、拳交模式都能抓
	s.call("exit_surgery")
	await _frames(2)
	var org: Node = _organ_rig()
	for mode in ["drag", "fist"]:
		org.call("set_interact_mode", mode)
		var bp2: Array = _body_pt(so)
		var Pa: PackedVector3Array = (so.get("_p") as PackedVector3Array).duplicate()
		var cam: Camera3D = player.call("get_camera")
		var scr: Vector2 = cam.unproject_position(bp2[1]) if cam else Vector2.ZERO
		var began := bool(player.call("_try_begin_interact", scr))
		var via_hang: Node = player.call("hang_grab_organ")
		var ok3 := began and via_hang == so
		var part3 := str(so.call("hang_grab_part"))
		var side3 := int(so.get("_hg_side"))
		var ov_a: Vector3 = so.call("ovary_world", maxi(side3, 0))
		if ok3:
			bp2[0] = int(so.get("hold_index"))
		if ok3:
			var n := _cam_n()
			var o := (bp2[1] as Vector3) - n * 0.25
			for i in 40:
				player.call("debug_update_hang_grab", o + _side_move(0.05) * (float(i + 1) / 40.0), n)
				await _phys(1)
		var Pb: PackedVector3Array = so.get("_p")
		var mv := 0.0
		if part3 == "tube":
			mv = (so.call("ovary_world", side3) as Vector3).distance_to(ov_a)
		elif int(bp2[0]) >= 0:
			mv = Pb[int(bp2[0])].distance_to(Pa[int(bp2[0])])
		player.call("_end_interact")
		await _phys(2)
		print("HANG uterus (normal mode %s): began=%s via HangGrab=%s part=%s moved %.1f cm" % [mode, began, via_hang == so, part3, mv * 100])
		_ok(ok3, "uterus: in normal %s mode a click on the hanging uterus grabs it" % mode)
		_ok(mv > 0.01, "uterus: normal %s mode drags it (%.1f cm)" % [mode, mv * 100])
		_ok(player.call("hang_grab_organ") == null and int(so.get("hold_index")) < 0 and str(so.call("hang_grab_part")) == "", "uterus: ending the interaction releases it (%s)" % mode)
	org.call("set_interact_mode", "drag")
	s.call("enter_surgery")
	await _frames(2)
	s.call("restore_body")
	await _frames(2)


# ---------------------------------------------------------------- 脱垂子宫
func _check_prolapse() -> void:
	s.call("exit_surgery")
	await _frames(2)
	var org: Node = player.call("get_organs")
	var pc: Node = org.call("prolapse") if org.has_method("prolapse") else null
	if pc == null:
		_ok(false, "prolapse: controller exists")
		return
	pc.call("set_amount", 0.6)
	for i in 40:
		await _phys(1)
	var cerv: Vector3 = pc.call("cervix_world")
	var n := _cam_n()
	var pk := HangGrab.pick(get_root().get_tree() if false else player.get_tree(), cerv - n * 0.25, n)
	var is_model: bool = not pk.is_empty() and (pk["organ"] as Node).get_parent() == pc
	var d0 := float(pc.get("descent"))
	var ok := bool(player.call("debug_begin_hang_grab", cerv - n * 0.25, n))
	var src := str(pc.get("drive_source"))
	var ain: Vector3 = pc.call("canal_axis_world")
	var o := cerv - n * 0.25
	for i2 in 50:
		player.call("debug_update_prolapse_hand", o, ((cerv - ain * 0.002 * float(i2 + 1)) - o).normalized())
		await _phys(1)
	var d1 := float(pc.get("descent"))
	player.call("_end_interact")
	await _phys(2)
	print("HANG prolapse: HangGrab picks the model=%s, grabbed=%s src=%s descent %.1f → %.1f mm, driving after release=%s" % [is_model, ok, src, d0 * 1000, d1 * 1000, pc.call("is_driving")])
	_ok(is_model, "prolapse: the prolapsed uterus is registered with the shared hang-grab interface")
	_ok(ok and src == "hand", "prolapse: the hand grabs the prolapsed uterus")
	_ok(absf(d1 - d0) > 0.005, "prolapse: dragging moves it (%.1f → %.1f mm)" % [d0 * 1000, d1 * 1000])
	_ok(not bool(pc.call("is_driving")), "prolapse: release ends the drive")
	pc.call("reset")
