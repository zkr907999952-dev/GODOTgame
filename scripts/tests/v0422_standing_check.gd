extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中，t71u / T-15）：观察视角以当前站姿直接进入阴道互动 / 手术（不上检查床）。
## 不移动角色、不躺床、不布娃娃；镜头按当前姿态框住外阴 / 腹部；球杆 / 扩张器能进阴道通道；
## 断面小窗；脱垂子宫向下悬垂；站姿切口 + 经创口取出子宫、悬垂向下；退出回到观察；检查床路径照旧。
##   godot --headless --path . -s res://scripts/tests/v0422_standing_check.gd

var g: Node
var vm: Node
var org: Node
var pos0 := Vector3.ZERO


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
	g = main
	s = player.call("get_surgery")
	vm = player.call("get_vagina_mode")
	org = player.call("get_organs")
	player.call("set_play_mode", 0)
	await _frames(6)
	await _phys(6)
	pos0 = player.global_position
	_ok(str(player.get("occupancy")) == "", "starts standing on foot (occupancy='%s')" % player.get("occupancy"))
	await _check_vagina_standing()
	await _check_surgery_standing()
	await _check_bed_path()
	print("v0422_standing_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _still_standing(tag: String) -> void:
	var moved := player.global_position.distance_to(pos0)
	_ok(str(player.get("occupancy")) == "" and vs.get("occupied") == null, "%s: not moved onto any exam bed" % tag)
	_ok(moved < 0.02, "%s: character keeps her standing position (moved %.1f mm)" % [tag, moved * 1000])
	_ok(not bool(player.call("is_ragdoll")), "%s: no ragdoll / fall" % tag)
	_ok(bool(player.call("is_display_mode")), "%s: stays in the observe view" % tag)


func _cam() -> Camera3D:
	return player.call("get_camera")


func _framed(p: Vector3, max_dist: float, max_deg: float) -> Array:
	var cam := _cam()
	var d := p - cam.global_position
	var fwd := -cam.global_transform.basis.z
	var ang := rad_to_deg(acos(clampf(fwd.dot(d.normalized()), -1.0, 1.0)))
	return [d.length() <= max_dist and ang <= max_deg, d.length(), ang]


func _settle(n: int) -> void:
	for i in n:
		await _phys(1)
		await _frames(1)


# ------------------------------------------------------------------ 阴道互动
func _check_vagina_standing() -> void:
	hud.call("_refresh_surgery_ui")
	hud.call("_refresh_vagina_ui")
	var bv: Button = hud.get("_btn_vagina_enter")
	_ok(bv != null and bv.visible, "observe: 阴道互动 button visible while standing")
	bv.emit_signal("pressed")
	await _settle(20)
	_ok(bool(vm.call("is_active")) and bool(vm.get("standing_session")), "阴道互动 enters immediately in the standing pose (standing_session)")
	_ok(bool(g.call("body_mode_standing")), "game_root reports a standing body mode")
	_still_standing("vagina")
	var O: Vector3 = vm.call("introitus_world")
	var ax: Vector3 = vm.call("canal_axis_world")
	print("STANDING canal: opening y=%.3f (feet %.3f), axis=%s" % [O.y, player.global_position.y, ax])
	_ok(ax.y > 0.5, "standing: the canal axis points up into the body (axis.y=%.2f)" % ax.y)
	var f := _framed(O, 1.0, 12.0)
	print("STANDING free view: opening %.2f m away, %.1f° off-centre" % [f[1], f[2]])
	_ok(bool(f[0]), "free view frames the vulva (%.2f m, %.1f°)" % [f[1], f[2]])
	vm.call("set_camera_preset", "introitus", true)
	await _settle(4)
	var fi := _framed(O, 0.45, 12.0)
	var cam_y := _cam().global_position.y
	print("STANDING 阴道口视角: %.2f m, %.1f°, camera %.2f m above the feet, align err %.1f°" % [fi[1], fi[2], cam_y - player.global_position.y, rad_to_deg(float(vm.call("camera_alignment_error")))])
	_ok(bool(fi[0]), "阴道口视角 frames the opening from close by (%.2f m, %.1f°)" % [fi[1], fi[2]])
	_ok(cam_y > player.global_position.y + 0.15, "阴道口视角 camera stays above the floor")
	_ok(float(vm.call("camera_alignment_error")) < deg_to_rad(15.0), "阴道口视角 camera looks along the preset direction")
	vm.call("set_camera_preset", "abdomen", true)
	await _settle(4)
	var C: Vector3 = vm.call("organ_group_center")
	var fa := _framed(C, 0.8, 12.0)
	print("STANDING 小腹视角: %.2f m, %.1f°" % [fa[1], fa[2]])
	_ok(bool(fa[0]), "小腹视角 frames the lower abdomen (%.2f m, %.1f°)" % [fa[1], fa[2]])
	vm.call("set_camera_preset", "free", true)
	# 球杆：沿阴道通道进去，碰到宫颈。
	vm.call("set_tool", "ball_rod")
	await _settle(3)
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null, "ball rod tool is created while standing")
	if ctl:
		var cerv: Vector3 = vm.call("cervix_world")
		var L := O.distance_to(cerv)
		ctl.call("debug_set_depth", L * 0.6)
		await _settle(2)
		var tip: Vector3 = ctl.call("tip_world")
		var rel := tip - O
		var along := rel.dot(ax)
		var perp := (rel - ax * along).length()
		print("STANDING ball rod: depth %.1f mm along the canal, %.1f mm off-axis (canal %.1f mm)" % [along * 1000, perp * 1000, L * 1000])
		_ok(along > L * 0.3 and perp < 0.012, "ball rod reaches into the canal while standing (%.1f mm in, %.1f mm off-axis)" % [along * 1000, perp * 1000])
		var sec: Node = vm.call("cross_section")
		_ok(sec != null and bool(sec.get("visible_on")) if sec and "visible_on" in sec else sec != null, "cross-section PiP opens with the ball rod while standing")
		ctl.call("debug_set_depth", 0.0)
		await _settle(2)
	vm.call("set_tool", "")
	# 扩张器
	vm.call("set_tool", "speculum")
	await _settle(2)
	if s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
	await _settle(2)
	var ins := bool(s.call("is_speculum_inserted")) if s.has_method("is_speculum_inserted") else false
	var sp = s.get("speculum")
	var sp_d := 99.0
	if sp and sp.get("node") is Node3D and is_instance_valid(sp.get("node")):
		var sn: Vector3 = (sp.get("node") as Node3D).global_position
		var r2 := sn - O
		sp_d = (r2 - ax * r2.dot(ax)).length()
	print("STANDING speculum: inserted=%s, %.1f mm off the canal axis" % [ins, sp_d * 1000])
	_ok(ins and sp_d < 0.05, "speculum inserts into the canal while standing (%.1f mm off-axis)" % (sp_d * 1000))
	if s.has_method("request_remove_speculum"):
		s.call("request_remove_speculum")
	if s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
		s.call("debug_finish_speculum_anim")
	vm.call("set_tool", "")
	await _settle(2)
	# 脱垂：子宫从阴道口向下悬垂（重力对站姿）。
	var pc: Node = org.call("prolapse")
	pc.call("set_amount", 0.97)
	await _settle(90)
	var fund: Vector3 = pc.call("fundus_world")
	var cerv2: Vector3 = pc.call("cervix_world")
	var O2: Vector3 = pc.call("introitus_world")
	var st: Dictionary = pc.call("debug_state") if pc.has_method("debug_state") else {}
	var drop_c := (O2.y - cerv2.y) * 100
	var drop_f := (O2.y - fund.y) * 100
	var ant := float(st.get("fundus_anterior", 0.0))
	var tcl := float(st.get("thigh_clearance", 1.0))
	print("STANDING prolapse: cervix %.1f cm and fundus %.1f cm below the opening, grade %d, anterior %.1f mm, thigh_clear %.2f mm" % [drop_c, drop_f, int(pc.get("grade")), ant * 1000, tcl * 1000])
	# 两腿之间或被顶到腿前面都可以，只要向下垂、不卡进腿里、不被腿根托住。
	_ok(int(pc.get("grade")) == 4 and cerv2.y < O2.y - 0.03, "standing prolapse hangs down from the vaginal opening (cervix %.1f cm below, %s of the thighs)" % [drop_c, "in front" if ant > 0.01 else "between / at"])
	_ok(tcl >= -0.001, "standing prolapse does not clip into the thighs (clearance %.2f mm)" % (tcl * 1000))
	_ok(fund.y > player.global_position.y, "the hanging uterus stays above the floor")
	pc.call("reset")
	await _settle(3)
	_still_standing("vagina tools")
	# 退出 → 回到观察。
	vm.call("exit")
	await _settle(6)
	_ok(not bool(vm.call("is_active")) and not bool(vm.get("standing_session")), "exit vaginal interaction ends the standing session")
	_still_standing("after vagina exit")
	# Y 键也是站姿进入。
	main.call("run_action", str(main.call("action_for_key", KEY_Y)), KEY_Y)
	await _settle(6)
	_ok(bool(vm.call("is_active")) and str(player.get("occupancy")) == "", "Y enters vaginal interaction standing too")
	vm.call("exit")
	await _settle(4)
	# 切到第一人称 → 站姿会话自动结束。
	vm.call("enter_standing")
	await _settle(3)
	player.call("set_play_mode", 1)
	await _settle(4)
	_ok(not bool(vm.call("is_active")), "leaving the observe view ends the standing vaginal interaction")
	player.call("set_play_mode", 0)
	await _settle(6)
	pos0 = player.global_position


# ------------------------------------------------------------------ 手术
func _check_surgery_standing() -> void:
	hud.call("_refresh_surgery_ui")
	var bs: Button = hud.get("_btn_surgery_enter")
	_ok(bs != null and bs.visible, "observe: 开始手术 button visible while standing")
	bs.emit_signal("pressed")
	await _settle(10)
	_ok(bool(s.call("is_active")) and bool(s.get("standing_session")), "开始手术 enters immediately in the standing pose")
	_still_standing("surgery")
	var nav: Vector3 = s.call("surgery_camera_target")
	var fs := _framed(nav, 1.1, 12.0)
	print("STANDING surgery camera: navel %.2f m away, %.1f° off-centre" % [fs[1], fs[2]])
	_ok(bool(fs[0]), "surgery camera frames the abdomen of the standing body (%.2f m, %.1f°)" % [fs[1], fs[2]])
	# 切口 + 揭皮瓣（绑定空间坐标，与姿态无关）。
	s.call("ensure_tool", "scalpel")
	var navr: Vector3 = s.get("_navel_rest")
	var c := navr + Vector3(0.0, 0.035, 0.0)
	_ok(_straight(c + Vector3(-0.06, 0.0, 0.0), c + Vector3(0.06, 0.004, 0.0)), "standing: straight cut")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "standing: ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "standing: flap peeled")
	await _settle(12)
	var flap_y := -999.0
	var fl = s.get("flap_node")
	if fl and is_instance_valid(fl) and fl is Node3D:
		flap_y = (fl as Node3D).global_position.y
	_ok(float(s.call("_catch_top_y")) <= player.global_position.y + 0.01, "standing: the cut flap falls to the floor, not onto a far-away bed (catch y %.2f, feet %.2f)" % [float(s.call("_catch_top_y")), player.global_position.y])
	# 经创口取出子宫：向外拉，松手后挂在创口下方。
	s.call("set_tool", "forceps")
	s.call("set_forceps_mode", "pull")
	await _frames(2)
	var ok := bool(s.call("debug_begin_extract", "uterus"))
	_ok(ok, "standing: forceps grabs the uterus through the wound")
	var dt := 1.0 / 60.0
	if ok:
		var so: Node = s.call("soft_organ", "uterus")
		var wound: Vector3 = s.call("_wound_center_world")
		var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
		var tip: Vector3 = so.get("hold_pos") if so else wound
		for i in 120:
			tip = tip.move_toward(wound + outv * 0.12, 0.25 * dt)
			s.call("debug_forceps_drag_to", tip)
			s.call("_update_guts", dt)
		s.call("debug_forceps_end")
		for k in 240:
			s.call("_update_guts", dt)
		if so:
			var fw: Vector3 = so.call("fundus_world")
			var cw: Vector3 = so.call("cervix_world")
			var lvl := int(s.call("extract_level", "uterus"))
			print("STANDING extraction: level %d, fundus %.1f cm below the wound, cervix→wound %.1f cm, out nodes %d, transition %.1f cm" % [lvl, (wound.y - fw.y) * 100, cw.distance_to(wound) * 100, int(so.call("body_out_count")), float(so.call("transition_length")) * 100])
			_ok(lvl >= 3 and int(so.call("body_out_count")) >= 3, "standing: the uterus comes out through the wound (level %d)" % lvl)
			_ok(fw.y < wound.y - 0.02, "standing: the extracted uterus hangs down under gravity (fundus %.1f cm below the wound)" % ((wound.y - fw.y) * 100))
			_ok(fw.y > player.global_position.y and cw.distance_to(wound) < 0.04, "standing: it stays near the wound, above the floor")
		_ok(bool(s.call("restore_extracted_organs")), "standing: 放回内脏 works")
		await _settle(4)
	s.call("restore_body")
	await _settle(4)
	s.call("exit_surgery")
	await _settle(6)
	_ok(not bool(s.call("is_active")) and not bool(s.get("standing_session")), "exit surgery ends the standing session")
	_still_standing("after surgery exit")
	var tp: Dictionary = player.call("debug_tp_state")
	var belly: Vector3 = player.call("focus_point", "belly")
	print("STANDING after exit: orbit target %.2f m from the belly focus" % (tp["target"] as Vector3).distance_to(belly))
	_ok((tp["target"] as Vector3).distance_to(belly) < 0.15, "after exiting, the observe camera returns to the normal orbit")


# ------------------------------------------------------------------ 检查床路径照旧
func _check_bed_path() -> void:
	if not await _enter_bed():
		return
	await _settle(4)
	_ok(bool(vm.call("enter")) and not bool(vm.get("standing_session")), "on the exam bed vaginal interaction still uses the bed path")
	vm.call("exit")
	await _settle(2)
	_ok(bool(s.call("enter_surgery")) and not bool(s.get("standing_session")), "on the exam bed surgery still uses the bed path")
	await _settle(4)
	_ok(bool(s.call("is_active")), "bed surgery stays active (not auto-exited)")
	s.call("exit_surgery")
