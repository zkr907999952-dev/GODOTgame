extends "res://scripts/tests/v0409b_check.gd"
## 断面图填充 / 平扫视图 / 宫底顶起。不打包。
##   godot --headless --path . -s res://scripts/tests/v0424_check.gd


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
		print("v0424_check: fails=", fails)
		quit(1)
		return
	var vm = player.call("get_vagina_mode")
	_ok(vm != null, "vagina mode exists")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	var sec: Node = vm.call("cross_section")
	_ok(sec != null and bool(sec.get("visible_on")), "PiP is open with the ball-rod")
	if sec == null:
		print("v0424_check: fails=", fails)
		quit(1)
		return
	_ok(sec.get("_coronal_vp") != null and sec.get("_coronal_cam") != null, "coronal SubViewport and camera exist")
	_ok(sec.get("_btn_coronal") != null and str(sec.get("_btn_coronal").text) == "平扫", "view switch includes 平扫")
	# 三平面互相垂直，平扫含轴线并过宫颈。
	var axis: Vector3 = vm.call("canal_axis_world")
	var up: Vector3 = vm.call("canal_up_world") if vm.has_method("canal_up_world") else Vector3.UP
	var long_pl: Plane = sec.call("longitudinal_plane")
	var trans_pl: Plane = sec.call("transverse_plane")
	var cor_pl: Plane = sec.call("coronal_plane")
	_ok(long_pl.normal.is_finite() and trans_pl.normal.is_finite() and cor_pl.normal.is_finite(), "all three cut normals are finite")
	var an := axis.normalized()
	_ok(absf(long_pl.normal.normalized().dot(an)) < 0.18, "sagittal contains the canal axis (n·axis=%.3f)" % absf(long_pl.normal.normalized().dot(an)))
	_ok(absf(trans_pl.normal.normalized().dot(an)) > 0.95, "transverse is perpendicular to the canal (n·axis=%.3f)" % absf(trans_pl.normal.normalized().dot(an)))
	_ok(absf(cor_pl.normal.normalized().dot(an)) < 0.18, "coronal contains the canal axis (n·axis=%.3f)" % absf(cor_pl.normal.normalized().dot(an)))
	_ok(absf(long_pl.normal.normalized().dot(cor_pl.normal.normalized())) < 0.18, "sagittal and coronal are perpendicular (dot=%.3f)" % absf(long_pl.normal.normalized().dot(cor_pl.normal.normalized())))
	_ok(absf(trans_pl.normal.normalized().dot(cor_pl.normal.normalized())) < 0.18, "transverse and coronal are perpendicular (dot=%.3f)" % absf(trans_pl.normal.normalized().dot(cor_pl.normal.normalized())))
	var un := (up - an * up.dot(an))
	if un.length_squared() > 1e-8:
		un = un.normalized()
		_ok(absf(cor_pl.normal.normalized().dot(un)) > 0.95, "coronal is parallel to the lower abdomen (n·ventral=%.3f)" % absf(cor_pl.normal.normalized().dot(un)))
	var opening: Vector3 = vm.call("introitus_world")
	var cerv: Vector3 = vm.call("cervix_world")
	_ok(absf(cor_pl.distance_to(opening)) < 0.008, "coronal plane contains the canal (opening dist=%.2f mm)" % (absf(cor_pl.distance_to(opening)) * 1000.0))
	_ok(absf(cor_pl.distance_to(cerv)) < 0.008, "coronal plane passes through the cervix (dist=%.2f mm)" % (absf(cor_pl.distance_to(cerv)) * 1000.0))
	var st: Dictionary = sec.call("debug_section_state")
	_ok(float(st.get("coronal_cam_along_normal", 0.0)) > 0.98, "coronal camera faces the cut (dot=%.3f)" % float(st.get("coronal_cam_along_normal", 0.0)))
	_ok(int(st.get("rod_copies", 0)) >= 2, "rod copies exist before switching to coronal")
	_ok(bool(st.get("hands_excluded", false)), "section reports hands excluded")
	# 切换平扫：第三视口可见，棒拷贝在冠状层。
	sec.call("set_view_mode", "coronal")
	await _frames(2)
	var cbox = sec.get("_coronal_box")
	_ok(str(sec.get("view_mode")) == "coronal" and cbox != null and bool(cbox.visible), "can switch to coronal-only (平扫)")
	st = sec.call("debug_section_state")
	var cor_n := 0
	for rec in sec.get("_copies"):
		if str(rec.get("which", "")) == "coronal":
			cor_n += 1
	_ok(cor_n >= 4, "coronal has its own copies (skin/organs/rod) (%s)" % cor_n)
	_ok(int(st.get("rod_copies", 0)) >= 2, "rod copies are present in the coronal section")
	sec.call("set_view_mode", "both")
	await _frames(1)
	_ok(str(sec.get("view_mode")) == "both" and bool(sec.get("_long_box").visible) and bool(sec.get("_trans_box").visible) and bool(sec.get("_coronal_box").visible), "并排 shows all three views")
	# 像素填充：球放到宫腔内，三视图都应有宫壁/宫腔，轮廓内近乎无纯黑。
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null, "ball-rod controller is running")
	if ctl:
		var mid: float = opening.distance_to(cerv) * 0.45
		ctl.call("debug_set_depth", opening.distance_to(cerv) + float(ctl.call("radius")) * 0.4)
		await _frames(2)
		for which in ["long", "trans", "coronal"]:
			if which == "coronal":
				sec.call("set_view_mode", "coronal")
			elif which == "trans":
				sec.call("set_view_mode", "trans")
			else:
				sec.call("set_view_mode", "long")
			await _frames(1)
			var m: Dictionary = sec.call("debug_section_metrics", which)
			_ok(bool(m.get("ok", false)), "%s fill metrics ok (sil=%s black_frac=%.4f)" % [which, m.get("silhouette", 0), float(m.get("black_frac", 1.0))])
			_ok(float(m.get("black_frac", 1.0)) < 0.03, "%s near-zero pure-black pixels inside the body silhouette (frac=%.4f, n=%s)" % [which, float(m.get("black_frac", 1.0)), m.get("black_in_sil", -1)])
			_ok(int(m.get("cavity", 0)) > 20, "%s abdominal cavity is filled with darker pink (%s px)" % [which, m.get("cavity", 0)])
			if which != "trans":
				_ok(int(m.get("uter_wall", 0)) >= 6, "%s uterus wall is a solid cap (%s px)" % [which, m.get("uter_wall", 0)])
				_ok(int(m.get("uter_lumen", 0)) >= 4, "%s uterine lumen is visible as a hollow (%s px)" % [which, m.get("uter_lumen", 0)])
				_ok(int(m.get("vag_wall", 0)) >= 4, "%s vagina wall is filled (%s px)" % [which, m.get("vag_wall", 0)])
				_ok(int(m.get("vag_lumen", 0)) >= 4, "%s vagina lumen is hollow (%s px)" % [which, m.get("vag_lumen", 0)])
			_ok(int(m.get("hand_bleed", 0)) == 0, "%s hands are not projected into the section (bleed=%s / %s)" % [which, m.get("hand_bleed", -1), m.get("hand_samples", 0)])
		sec.call("set_view_mode", "both")
		# 宫底顶起：继续深入时子宫沿轴平移，球不穿壁。
		var contact: float = ctl.call("fundus_contact_depth")
		_ok(contact > opening.distance_to(cerv), "fundus contact is deeper than the cervix (%.1f / %.1f mm)" % [contact * 1000.0, opening.distance_to(cerv) * 1000.0])
		# 先放到宫腔内再连推越过宫底。
		ctl.call("debug_set_depth", contact - 0.006)
		await _frames(2)
		var lift0: float = ctl.call("debug_fundus_lift")
		var tip0: Vector3 = ctl.call("tip_world")
		var along0 := (tip0 - opening).dot(axis.normalized())
		for _i in 10:
			ctl.call("debug_push_depth", contact + 0.025, 0.08)
		await _frames(2)
		var lift1: float = ctl.call("debug_fundus_lift")
		var tip1: Vector3 = ctl.call("tip_world")
		var along1 := (tip1 - opening).dot(axis.normalized())
		var contact1: float = ctl.call("fundus_contact_depth")
		var wall_now := contact1 + lift1
		_ok(lift1 > lift0 + 0.008, "pushing past the fundus lifts the uterus (%.2f -> %.2f mm)" % [lift0 * 1000.0, lift1 * 1000.0])
		_ok(along1 <= wall_now + 0.0015, "ball does not go past the (moving) fundus wall (along=%.2f contact+lift=%.2f mm)" % [along1 * 1000.0, wall_now * 1000.0])
		_ok(along1 > along0 + 0.004, "ball and uterus advance together along the axis (%.2f -> %.2f mm)" % [along0 * 1000.0, along1 * 1000.0])
		if ctl.has_method("_ball_wall_clearance"):
			var cl: float = ctl.call("_ball_wall_clearance")
			_ok(cl > -0.0015, "ball does not penetrate the uterine wall at the fundus (clearance=%.2f mm)" % (cl * 1000.0))
		# 抽出后顶起恢复。
		for _j in 10:
			ctl.call("debug_push_depth", mid, 0.08)
		await _frames(2)
		var lift2: float = ctl.call("debug_fundus_lift")
		_ok(lift2 < 0.003, "uterus recovers when the rod is withdrawn (lift=%.2f mm)" % (lift2 * 1000.0))
	if vm.has_method("exit"):
		vm.call("exit")
	await _frames(2)
	print("v0424_check: fails=", fails)
	quit(1 if fails > 0 else 0)
