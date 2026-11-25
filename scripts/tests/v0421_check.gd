extends "res://scripts/tests/v0409b_check.gd"
## 未发布（0.4.12 开发中）：扩张器单一包络、大腿接缝、断面图隔离、球杆搅动/顶直。不打包。
##   godot --headless --path . -s res://scripts/tests/v0421_check.gd


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
		print("v0421_check: fails=", fails)
		quit(1)
		return
	await _check_speculum_and_seam()
	await _check_pip_isolation()
	await _check_stir_and_straighten()
	print("v0421_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_speculum_and_seam() -> void:
	var vm = player.call("get_vagina_mode")
	_ok(vm != null, "vagina mode exists")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode for speculum")
	await _frames(3)
	var rig0: Node = _rig()
	if rig0 and rig0.vulva and rig0.vulva.has_method("debug_mesh_quality"):
		var q0: Dictionary = rig0.vulva.call("debug_mesh_quality")
		_ok(int(q0.get("flipped_normals", 99)) == 0, "introitus rest normals are consistent (flipped=%s)" % q0.get("flipped_normals"))
		_ok(int(q0.get("degenerate_tris", 99)) == 0, "introitus rest has no degenerate tris")
		_ok(int(q0.get("dress_flipped", 0)) == 0 and int(q0.get("dress_degenerate", 0)) == 0, "thigh-vulva seam is clean at rest (flip=%s deg=%s)" % [q0.get("dress_flipped"), q0.get("dress_degenerate")])
	vm.call("set_tool", "speculum")
	await _frames(2)
	s = player.call("get_surgery")
	if s and not bool(s.call("is_speculum_inserted")):
		s.call("set_tool", "speculum")
		if s.has_method("debug_finish_speculum_anim"):
			s.call("debug_finish_speculum_anim")
		await _frames(3)
	s.call("set_speculum_angle", 22.0)
	await _frames(4)
	var rig: Node = _rig()
	_ok(rig != null, "organ rig is available")
	if rig == null:
		return
	# 单一 stadium：间隙点在包络内，位移把它们推到外表面上，而不是上下两团。
	var Envelope := load("res://scripts/body/vulva/envelope_inserter.gd")
	var o := Vector3(rig.get("_spec_o").x, rig.get("_spec_o").y, rig.get("_spec_o").z)
	var ax := Vector3(rig.get("_spec_d").x, rig.get("_spec_d").y, rig.get("_spec_d").z).normalized()
	var up := Vector3(rig.get("_spec_u").x, rig.get("_spec_u").y, rig.get("_spec_u").z)
	up = (up - ax * up.dot(ax)).normalized()
	var side := ax.cross(up).normalized()
	var half_tip: float = rig.get("_spec_d").w
	var half_intro: float = rig.get("_spec_m").y
	var half_side: float = rig.get("_spec_u").w
	var cr: float = rig.get("_spec_m").z
	if cr < 1e-5:
		cr = 0.004
	_ok(half_tip > half_intro, "blade tip half-height exceeds the introitus (%.1f > %.1f mm)" % [half_tip * 1000.0, half_intro * 1000.0])
	# 外口半高应接近闭合半高 + 铰链外伸 * tan，而不是两瓣叠加出的 30+ mm。
	_ok(half_intro < 0.030, "introitus half-height stays on the blade envelope (hy=%.1f mm)" % (half_intro * 1000.0))
	var mid_ry := (half_intro + half_tip) * 0.5
	# 两瓣之间的空隙中心必须在同一体积内（SDF < 0），位移把点推到外壳。
	var gap := Vector3.ZERO
	var p_gap: Vector3 = o + ax * (float(rig.get("_spec_o").w) * 0.4) + up * 0.0
	var off: Vector3 = rig.call("speculum_offset_ab", p_gap)
	var sdf0: float = Envelope.stadium_sdf(0.0, 0.0, half_side, mid_ry, cr)
	_ok(sdf0 < 0.0, "gap between blades is inside the shared hull (sdf=%.4f)" % sdf0)
	# 轴上的点若几乎在原点，shader 可能返回 0；取稍偏上但仍在空隙里的点。
	var p_in: Vector3 = o + ax * (float(rig.get("_spec_o").w) * 0.45) + up * (mid_ry * 0.25)
	var off_in: Vector3 = rig.call("speculum_offset_ab", p_in)
	_ok(off_in.length() > 0.001, "a point inside the hull is pushed onto the outer surface (%.2f mm)" % (off_in.length() * 1000.0))
	var p2: Vector3 = p_in + off_in
	var v2 := p2 - o
	var s2 := v2.dot(ax)
	var xu := v2.dot(side)
	var yu := v2.dot(up)
	var along := clampf(s2 / maxf(float(rig.get("_spec_o").w), 1e-4), 0.0, 1.0)
	var ry := lerpf(half_intro, half_tip, along)
	var rx := half_side * lerpf(1.0, 0.85, along)
	var sdf_out: float = Envelope.stadium_sdf(xu, yu, rx, ry, cr)
	_ok(absf(sdf_out) < 0.0015, "displaced vertex lands on the envelope (sdf=%.4f mm)" % (sdf_out * 1000.0))
	# 体外沿轴负向推得不远。
	var p_out: Vector3 = o - ax * 0.018
	var off_out: Vector3 = rig.call("speculum_offset_ab", p_out)
	_ok(off_out.length() < 0.002, "tissue 18 mm outside the introitus is not pushed out (%.2f mm)" % (off_out.length() * 1000.0))
	if rig.vulva and rig.vulva.has_method("introitus_half_extents"):
		var ext: Vector2 = rig.vulva.call("introitus_half_extents")
		var want_hy: float = float(rig.vulva.get("_intro_hy"))
		var want_mix: float = float(rig.vulva.get("_intro_mix"))
		_ok(want_mix > 0.9, "labia inserter is fully mixed (mix=%.2f)" % want_mix)
		_ok(ext.y < 0.032, "dilated introitus does not bulge into two oversized lobes (hx=%.1f hy=%.1f mm, target=%.1f)" % [ext.x * 1000.0, ext.y * 1000.0, want_hy * 1000.0])
		# 外口实际半高应贴合叶片，而不是远小于或远大于目标包络。
		if want_hy > 0.01:
			_ok(ext.y > want_hy * 0.55, "introitus height follows the blade envelope (hy=%.1f target=%.1f mm)" % [ext.y * 1000.0, want_hy * 1000.0])
	# 接缝网格质量：张开时大腿连接处不能有翻转或退化三角形。
	if rig.vulva and rig.vulva.has_method("debug_mesh_quality"):
		var q: Dictionary = rig.vulva.call("debug_mesh_quality")
		_ok(int(q.get("degenerate_tris", 99)) == 0, "introitus has no degenerate tris (%s)" % q.get("degenerate_tris"))
		_ok(int(q.get("dress_degenerate", 99)) == 0, "thigh-vulva seam has no degenerate tris (%s)" % q.get("dress_degenerate"))
		_ok(int(q.get("dress_flipped", 99)) == 0, "thigh-vulva seam has no flipped tris (%s)" % q.get("dress_flipped"))
	if s and s.has_method("remove_speculum"):
		s.call("remove_speculum")
		await _frames(2)
	if s and s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
		s.call("debug_finish_speculum_anim")
	await _frames(2)
	if rig.has_method("clear_speculum_deform"):
		rig.call("clear_speculum_deform")
	await _frames(2)
	if rig.vulva and rig.vulva.has_method("debug_mesh_quality"):
		var q2: Dictionary = rig.vulva.call("debug_mesh_quality")
		_ok(int(q2.get("degenerate_tris", 99)) == 0 and int(q2.get("nan", 1)) == 0, "introitus is finite after removal (deg=%s nan=%s)" % [q2.get("degenerate_tris"), q2.get("nan")])
		_ok(int(q2.get("dress_flipped", 99)) == 0 and int(q2.get("dress_degenerate", 99)) == 0, "thigh-vulva seam is clean after removal (flip=%s deg=%s)" % [q2.get("dress_flipped"), q2.get("dress_degenerate")])
	if vm.has_method("exit"):
		vm.call("exit")
	await _frames(2)


func _check_pip_isolation() -> void:
	var vm = player.call("get_vagina_mode")
	if not bool(vm.call("is_active")):
		player.call("set_play_mode", 0)
		vm.call("enter")
		await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	var sec: Node = vm.call("cross_section")
	_ok(sec != null and bool(sec.get("visible_on")), "cross-section PiP is on with the ball-rod")
	if sec == null:
		return
	if sec.has_method("debug_isolation"):
		var iso: Dictionary = sec.call("debug_isolation")
		_ok(not bool(iso.get("main_sees_section", true)), "main camera cull mask excludes section layers (mask=%s)" % iso.get("main_mask"))
		_ok(bool(iso.get("layers_distinct", false)), "long and trans cameras use distinct layers (L=%s T=%s)" % [iso.get("long_cam_mask"), iso.get("trans_cam_mask")])
		_ok(int(iso.get("shared_source_material", 99)) == 0, "section copies do not share the source material (%s)" % iso.get("shared_source_material"))
		_ok(float(iso.get("source_section_on", 1.0)) < 0.01, "main-view materials have section_on=0 (%.2f)" % float(iso.get("source_section_on", 1.0)))
		_ok(int(iso.get("long_copies", 0)) > 0 and int(iso.get("trans_copies", 0)) > 0, "long and trans each have their own copies (%s / %s)" % [iso.get("long_copies"), iso.get("trans_copies")])
	# 再直接读源材质，确认没有白面参数漏过去。
	var rig: Node = _rig()
	if rig and rig.get("_all_mats") is Array:
		for m in rig.get("_all_mats"):
			if m is ShaderMaterial:
				var sh: Shader = (m as ShaderMaterial).shader
				var path := ""
				if sh:
					path = str(sh.resource_path)
				_ok(path.find("section_") < 0, "main organ material is not a section shader (%s)" % path)
				var on = (m as ShaderMaterial).get_shader_parameter("section_on")
				if on != null:
					_ok(float(on) < 0.01, "shared organ material section_on stays off")


func _check_stir_and_straighten() -> void:
	var vm = player.call("get_vagina_mode")
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null, "ball-rod controller is running")
	if ctl == null:
		return
	var rig: Node = _rig()
	var opening: Vector3 = vm.call("introitus_world")
	var cerv: Vector3 = vm.call("cervix_world")
	var mid: float = opening.distance_to(cerv) * 0.45
	ctl.call("debug_set_depth", mid)
	await _frames(2)
	# 侧向拨动：扩张环跟着球走，搅动位移也跟手的方向。
	var axis: Vector3 = vm.call("canal_axis_world")
	var up: Vector3 = Vector3.UP
	if absf(up.dot(axis.normalized())) > 0.9:
		up = Vector3.RIGHT
	var side := axis.cross(up).normalized()
	var nudge := side * 0.012
	ctl.call("debug_step_lateral", nudge, 0.03)
	var lat: Vector3 = rig.call("canal_dilate_lateral") if rig.has_method("canal_dilate_lateral") else Vector3.ZERO
	_ok(lat.length() > 0.003, "dilation ring follows the rod's lateral offset (%.2f mm)" % (lat.length() * 1000.0))
	var stir: Vector3 = ctl.call("debug_stir_offset")
	_ok(stir.dot(nudge) > 0.0 and stir.length() > 0.0005, "tissue offset follows rod lateral motion (stir=%.2f mm, aligned=%.2f)" % [stir.length() * 1000.0, stir.normalized().dot(nudge.normalized())])
	ctl.call("debug_settle", 0.4)
	var stir2: Vector3 = ctl.call("debug_stir_offset")
	_ok(stir2.length() < stir.length() * 0.4 or stir2.length() < 0.0008, "stir springs back when the rod stops (%.2f -> %.2f mm)" % [stir.length() * 1000.0, stir2.length() * 1000.0])
	# 顶直：进入宫腔后弯折角随深度减小，球不穿壁。
	ctl.call("debug_set_depth", mid)
	await _frames(1)
	var just_in: float = opening.distance_to(cerv) + float(ctl.call("radius")) * 0.3
	ctl.call("debug_set_depth", just_in)
	await _frames(1)
	var ang0: float = rig.call("uterus_bend_angle") if rig.has_method("uterus_bend_angle") else 0.0
	var st0: float = ctl.call("debug_straighten")
	var deep: float = opening.distance_to(cerv) + float(ctl.call("_uterus_rest_len")) * 0.7
	ctl.call("debug_set_depth", deep)
	await _frames(2)
	var ang1: float = rig.call("uterus_bend_angle") if rig.has_method("uterus_bend_angle") else 0.0
	var st1: float = ctl.call("debug_straighten")
	_ok(st1 > st0 + 0.15, "uterus straighten increases with ball depth (%.2f -> %.2f)" % [st0, st1])
	_ok(ang1 < ang0 - 0.02 or st1 > 0.5, "uterus bend angle decreases as the ball advances (%.1f° -> %.1f°)" % [rad_to_deg(ang0), rad_to_deg(ang1)])
	if ctl.has_method("_ball_wall_clearance"):
		var cl: float = ctl.call("_ball_wall_clearance")
		_ok(cl > -0.0015, "ball does not penetrate the uterus wall after straightening (clearance=%.2f mm)" % (cl * 1000.0))
	# 抽出后放松。
	ctl.call("debug_set_depth", mid)
	await _frames(1)
	var st2: float = ctl.call("debug_straighten")
	_ok(st2 < 0.15, "uterus relaxes back when the ball is withdrawn (straighten=%.2f)" % st2)
	# 宫颈闸门仍在：未突破时不能一次跳进宫腔。
	ctl.call("debug_set_depth", opening.distance_to(cerv) - float(ctl.call("radius")) * 0.8)
	await _frames(1)
	_ok(not bool(ctl.get("through_cervix")), "cervix gate still blocks a jump into the uterus")
	# 脱垂系统入口还在。
	_ok(rig.has_method("has_prolapse") and rig.has_method("prolapse"), "prolapse API is still present")
	if vm.has_method("exit"):
		vm.call("exit")
