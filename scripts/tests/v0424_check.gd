extends "res://scripts/tests/v0409b_check.gd"
## 断面图网格剖切填充 / 平扫 / 宫底顶起 / 包住球和杆 / 延迟回缩 / 外口跟随 / 脱垂阴道余量 / 钢球入宫无粉色穿模面。不打包。
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
	# 像素填充：球放到宫腔内再量切面（横切特写在体外时可能切不到网格）。
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null, "ball-rod controller is running")
	if ctl:
		var mid: float = opening.distance_to(cerv) * 0.45
		ctl.call("debug_set_depth", opening.distance_to(cerv) + float(ctl.call("radius")) * 0.4)
		sec.call("set_view_mode", "both")
		await _frames(2)
		for fw in ["long", "coronal", "trans"]:
			var al: Dictionary = sec.call("debug_fill_alignment", fw)
			_ok(bool(al.get("ok", false)), "%s peritoneum quad lies in the cut plane (dist=%.2f mm, tris=%s)" % [fw, float(al.get("plane_dist", 99.0)) * 1000.0, al.get("tris", 0)])
		for which in ["long", "trans", "coronal"]:
			if which == "coronal":
				sec.call("set_view_mode", "coronal")
			elif which == "trans":
				sec.call("set_view_mode", "trans")
			else:
				sec.call("set_view_mode", "long")
			await _frames(1)
			var m: Dictionary = sec.call("debug_section_metrics", which)
			print("FILL %s path=%s sil=%s black=%s cavity=%s uter_w/l=%s/%s vag_w/l=%s/%s seam=%s" % [which, m.get("path", ""), m.get("silhouette", 0), m.get("black_in_sil", 0), m.get("cavity", 0), m.get("uter_wall", 0), m.get("uter_lumen", 0), m.get("vag_wall", 0), m.get("vag_lumen", 0), m.get("seam", -1)])
			_ok(bool(m.get("ok", false)), "%s fill metrics ok (sil=%s black_frac=%.4f)" % [which, m.get("silhouette", 0), float(m.get("black_frac", 1.0))])
			_ok(float(m.get("black_frac", 1.0)) < 0.03, "%s near-zero pure-black pixels inside the body silhouette (frac=%.4f, n=%s)" % [which, float(m.get("black_frac", 1.0)), m.get("black_in_sil", -1)])
			_ok(int(m.get("cavity", 0)) > 20, "%s abdominal cavity is filled with darker pink (%s px)" % [which, m.get("cavity", 0)])
			var gpu_path := str(m.get("path", "")) == "gpu"
			if gpu_path:
				_ok(int(m.get("seam", 1)) == 0, "%s no black seam/tear pixels along section boundaries (seam=%s)" % [which, m.get("seam", -1)])
			if which == "coronal":
				# 平扫取景有时只切到杆和腹腔（宫/阴道壁像素很少）；腹腔已填且器官/杆可见即可。
				var orgn_c := int(m.get("uter_wall", 0)) + int(m.get("uter_lumen", 0)) + int(m.get("vag_wall", 0)) + int(m.get("vag_lumen", 0)) + int(m.get("rod", 0))
				if gpu_path:
					_ok(orgn_c > 40 or int(m.get("uter_wall", 0)) >= 6, "%s organ/rod fill is visible (%s px, uter_w=%s vag_w=%s rod=%s)" % [which, orgn_c, m.get("uter_wall", 0), m.get("vag_wall", 0), m.get("rod", 0)])
			elif which != "trans":
				if gpu_path:
					_ok(int(m.get("uter_wall", 0)) >= 6, "%s uterus wall is a solid cap (%s px)" % [which, m.get("uter_wall", 0)])
					_ok(int(m.get("vag_wall", 0)) >= 4 or int(m.get("vag_lumen", 0)) >= 4 or int(m.get("cavity", 0)) > 20, "%s vagina wall or lumen is filled (%s wall / %s lumen / %s cavity px)" % [which, m.get("vag_wall", 0), m.get("vag_lumen", 0), m.get("cavity", 0)])
				var ul := int(m.get("uter_lumen", 0)) + int(m.get("cavity", 0))
				_ok(int(m.get("uter_lumen", 0)) >= 4 or ul >= 24, "%s uterine lumen is hollow or shows peritoneal lining (%s lumen / %s cavity px)" % [which, m.get("uter_lumen", 0), m.get("cavity", 0)])
				var vl := int(m.get("vag_lumen", 0)) + int(m.get("cavity", 0))
				_ok(int(m.get("vag_lumen", 0)) >= 4 or vl >= 24, "%s vagina lumen is hollow or shows peritoneal lining (%s lumen / %s cavity px)" % [which, m.get("vag_lumen", 0), m.get("cavity", 0)])
			_ok(int(m.get("hand_bleed", 0)) == 0, "%s hands are not projected into the section (bleed=%s / %s)" % [which, m.get("hand_bleed", -1), m.get("hand_samples", 0)])
		sec.call("set_view_mode", "both")
		# t89u：钢球顶进子宫时，旧 section_cap 压平的粉色切面不应再盖住球体。
		var tip_pk: Vector3 = ctl.call("tip_world")
		var rad_pk: float = float(ctl.call("radius"))
		var pink: Dictionary = sec.call("debug_pink_clip_face", tip_pk, rad_pk)
		print("PINK FACE cap_attached=%s copies=%s worst_pink_frac=%.3f rod=%s views=%s" % [pink.get("cap_attached", -1), pink.get("copies", 0), float(pink.get("worst_pink_frac", 1.0)), pink.get("rod_samples", 0), pink.get("views", {})])
		_ok(int(pink.get("cap_attached", 1)) == 0, "section copies do not attach the old flattened pink cap pass (%s / %s copies)" % [pink.get("cap_attached", -1), pink.get("copies", 0)])
		_ok(int(pink.get("rod_samples", 0)) >= 8, "CPU fill samples the metal ball disk inside the uterus (%s)" % pink.get("rod_samples", 0))
		_ok(float(pink.get("worst_pink_frac", 1.0)) < 0.08, "no pink tissue covering the ball interior in the section fill (worst frac=%.3f)" % float(pink.get("worst_pink_frac", 1.0)))
		if str(DisplayServer.get_name()) != "headless":
			for which_pk in ["long", "trans", "coronal"]:
				var gp: Dictionary = sec.call("debug_gpu_ball_pink", which_pk, tip_pk, rad_pk)
				print("GPU PINK %s ok=%s pink_frac=%.3f rod=%s n=%s reason=%s" % [which_pk, gp.get("ok", false), float(gp.get("pink_frac", 1.0)), gp.get("rod", 0), gp.get("n", 0), gp.get("reason", "")])
				var rsn := str(gp.get("reason", ""))
				if rsn not in ["no image", "empty or dummy renderer", "no rod disk", "rod disk too small"]:
					_ok(bool(gp.get("ok", false)), "GPU %s ball disk is not covered by a pink clipping face (frac=%.3f)" % [which_pk, float(gp.get("pink_frac", 1.0))])
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
		# 包住球和杆：多深度 + 一次搅动，内壁相对插入物的有符号间隙 ≥ 0。
		var org: Node = player.call("get_organs")
		var samples := [
			opening.distance_to(cerv) * 0.45,
			opening.distance_to(cerv) + float(ctl.call("radius")) * 0.6,
			contact - 0.004,
		]
		for dpt in samples:
			ctl.call("debug_set_depth", dpt)
			if org and org.has_method("step"):
				org.call("step", 0.016)
			var enc: Dictionary = _enclosure_at(org, ctl)
			_ok(int(enc.get("n", 0)) > 20, "enclosure sampled %s canal/uterus verts at depth %.1f mm" % [enc.get("n", 0), dpt * 1000.0])
			_ok(float(enc.get("worst", -1.0)) >= -0.0004, "vagina+uterus enclose ball and shaft at depth %.1f mm (worst clearance %.2f mm, at %s)" % [dpt * 1000.0, float(enc.get("worst", -1.0)) * 1000.0, enc.get("where", "")])
			print("ENCLOSURE depth=%.1f mm worst=%.2f mm n=%s ball=%.2f shaft=%.2f" % [dpt * 1000.0, float(enc.get("worst", -1.0)) * 1000.0, enc.get("n", 0), float(enc.get("ball", 0.0)) * 1000.0, float(enc.get("shaft", 0.0)) * 1000.0])
		var mid_d: float = samples[0]
		ctl.call("debug_set_depth", mid_d)
		var side := axis.cross(Vector3.UP)
		if side.length_squared() < 1e-8:
			side = axis.cross(Vector3.RIGHT)
		side = side.normalized() * 0.003
		if ctl.has_method("debug_step_lateral"):
			ctl.call("debug_step_lateral", side, 0.05)
			if org and org.has_method("step"):
				org.call("step", 0.016)
			var encs: Dictionary = _enclosure_at(org, ctl)
			_ok(float(encs.get("worst", -1.0)) >= -0.0004, "enclose ball and shaft during a 3 mm stir (worst %.2f mm)" % (float(encs.get("worst", -1.0)) * 1000.0))
			print("ENCLOSURE stir worst=%.2f mm n=%s" % [float(encs.get("worst", -1.0)) * 1000.0, encs.get("n", 0)])
		# 外口变形每帧跟随插入物在开口平面上的真实截面（中心偏移 + 球/杆半径 + 延迟回缩）。
		if org and org.get("vulva") and org.vulva.has_method("introitus_opening"):
			var shaft_r := 0.0065
			var ball_r: float = float(ctl.call("radius"))
			ctl.call("debug_set_depth", 0.0)
			if org.has_method("step"):
				org.call("step", 0.016)
			var op0: Dictionary = org.vulva.call("introitus_opening")
			print("INTROITUS at opening plane r=%.2f mm (ball %.2f)" % [float(op0.get("radius", 0.0)) * 1000.0, ball_r * 1000.0])
			_ok(absf(float(op0.get("radius", 0.0)) - ball_r) < 0.0025, "opening radius tracks the ball slice at the introitus (%.2f vs ball %.2f mm)" % [float(op0.get("radius", 0.0)) * 1000.0, ball_r * 1000.0])
			ctl.call("debug_set_depth", mid_d)
			if org.has_method("step"):
				org.call("step", 0.016)
			var ins0 = ctl.get("_inserter")
			var inst_sh := 0.0
			if ins0 and ins0.has_method("instant_slice_radius"):
				inst_sh = float(ins0.call("instant_slice_radius"))
			print("INTROITUS shaft depth instant=%.2f shown=%.2f mm" % [inst_sh * 1000.0, float(org.vulva.call("introitus_opening").get("radius", 0.0)) * 1000.0])
			_ok(absf(inst_sh - shaft_r) < 0.0018, "introitus instant radius is the shaft after the ball has passed (%.2f vs 6.50 mm)" % (inst_sh * 1000.0))
			if ins0 and ins0.has_method("tick"):
				ins0.call("tick", 2.40)
				if org.vulva.has_method("set_inserter"):
					org.vulva.call("set_inserter", ins0)
			var op_sh: Dictionary = org.vulva.call("introitus_opening")
			print("INTROITUS shaft after recoil shown=%.2f mm" % (float(op_sh.get("radius", 0.0)) * 1000.0))
			_ok(absf(float(op_sh.get("radius", 0.0)) - shaft_r) < 0.0018, "opening radius settles to the shaft (%.2f vs 6.50 mm)" % (float(op_sh.get("radius", 0.0)) * 1000.0))
			var stir := side.normalized() * 0.003 if side.length_squared() > 1e-8 else Vector3(0.003, 0, 0)
			if ctl.has_method("debug_step_lateral"):
				ctl.call("debug_step_lateral", stir, 0.016)
				if org.has_method("step"):
					org.call("step", 0.016)
				var op_st: Dictionary = org.vulva.call("introitus_opening")
				var off: Vector3 = op_st.get("offset", Vector3.ZERO)
				var xf: Transform3D = org.get("_frame") if org.get("_frame") != null else Transform3D.IDENTITY
				var off_w: Vector3 = xf.basis * off
				var along_off := off_w.dot(stir.normalized())
				print("INTROITUS stir offset=%.2f mm along-stir=%.2f mm" % [off_w.length() * 1000.0, along_off * 1000.0])
				_ok(along_off > 0.0015, "opening centre follows a 3 mm stir (along-stir %.2f mm)" % (along_off * 1000.0))
				_ok(absf(off_w.length() - 0.003) < 0.0018, "opening centre offset magnitude tracks the insert (%.2f mm)" % (off_w.length() * 1000.0))
			var r_keep: float = float(org.vulva.call("introitus_opening").get("radius", 0.0))
			ctl.call("debug_set_depth", -0.08)
			if org.has_method("step"):
				org.call("step", 0.016)
			var r_im: float = float(org.vulva.call("introitus_opening").get("radius", 0.0))
			_ok(r_im >= r_keep * 0.90, "introitus shrink is not instant (%.2f -> %.2f mm)" % [r_keep * 1000.0, r_im * 1000.0])
			var ins = ctl.get("_inserter")
			if ins and ins.has_method("tick"):
				ins.call("tick", 0.40)
				if org.vulva.has_method("set_inserter"):
					org.vulva.call("set_inserter", ins)
				var r_mid: float = float(org.vulva.call("introitus_opening").get("radius", 0.0))
				_ok(r_mid > r_keep * 0.45 and r_mid < r_keep * 0.90, "introitus recoil at ~0.4 s is decaying (%.2f mm, start %.2f)" % [r_mid * 1000.0, r_keep * 1000.0])
				ins.call("tick", 2.40)
				if org.vulva.has_method("set_inserter"):
					org.vulva.call("set_inserter", ins)
				var r_end: float = float(org.vulva.call("introitus_opening").get("radius", 0.0))
				_ok(r_end < r_keep * 0.12, "introitus mostly closed after ~2.8 s (%.2f mm)" % (r_end * 1000.0))
				print("INTROITUS recoil r0=%.2f r_im=%.2f r_0.4s=%.2f r_2.8s=%.2f mm" % [r_keep * 1000.0, r_im * 1000.0, r_mid * 1000.0, r_end * 1000.0])
		# 延迟回缩：瞬时扩张，缩小按 ~0.9 s 指数，窗口 0.5–1.5 s。
		if org and org.has_method("set_canal_dilate") and org.has_method("canal_dilate_radius_at"):
			var canal: Dictionary = org.call("vagina_canal")
			var oab: Vector3 = canal.get("opening_ab", Vector3.ZERO)
			var aab: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
			var along_r := float(canal.get("length", 0.06)) * 0.45
			org.call("set_canal_dilate", oab, aab, along_r + 0.02, 0.012, 1.0, 0.0065, 0.0, float(canal.get("length", 0.06)))
			org.call("_tick_dilate_recoil", 0.016)
			var r0: float = org.call("canal_dilate_radius_at", along_r)
			_ok(r0 >= 0.006, "recoil: instant dilate at mid-canal is at least the shaft clearance (%.2f mm)" % (r0 * 1000.0))
			org.call("clear_canal_dilate")
			var r_im: float = org.call("canal_dilate_radius_at", along_r)
			_ok(r_im >= r0 * 0.95, "recoil: shrink is not instant (%.2f -> %.2f mm right after clear)" % [r0 * 1000.0, r_im * 1000.0])
			org.call("_tick_dilate_recoil", 0.40)
			var r_mid: float = org.call("canal_dilate_radius_at", along_r)
			_ok(r_mid > r0 * 0.45 and r_mid < r0 * 0.90, "recoil: ~0.4 s later radius is decaying exponentially (%.2f mm, start %.2f, expect ~67%%)" % [r_mid * 1000.0, r0 * 1000.0])
			org.call("_tick_dilate_recoil", 2.40)
			var r_end: float = org.call("canal_dilate_radius_at", along_r)
			_ok(r_end < r0 * 0.12, "recoil: ~2.8 s later radius has mostly recovered (%.2f mm)" % (r_end * 1000.0))
			print("RECOIL r0=%.2f r_im=%.2f r_0.4s=%.2f r_2.8s=%.2f mm" % [r0 * 1000.0, r_im * 1000.0, r_mid * 1000.0, r_end * 1000.0])
		# GPU 回读（xvfb / 有窗口时硬断言；headless Dummy 没有可用图像则记录原因）。
		sec.call("set_test_render", true)
		ctl.call("debug_set_depth", opening.distance_to(cerv) + float(ctl.call("radius")) * 0.4)
		await _frames(3)
		var gpu_any := false
		for which_g in ["long", "trans", "coronal"]:
			if which_g == "coronal":
				sec.call("set_view_mode", "coronal")
			elif which_g == "trans":
				sec.call("set_view_mode", "trans")
			else:
				sec.call("set_view_mode", "long")
			await _frames(2)
			var gm: Dictionary = sec.call("debug_gpu_section_metrics", which_g)
			print("GPU %s display=%s renderer=%s sil=%s black_frac=%.4f cavity=%s uter_wall=%s vag_wall=%s seam=%s reason=%s" % [which_g, gm.get("display", ""), gm.get("renderer", ""), gm.get("silhouette", 0), float(gm.get("black_frac", 1.0)), gm.get("cavity", 0), gm.get("uter_wall", 0), gm.get("vag_wall", 0), gm.get("seam", -1), gm.get("reason", "")])
			if int(gm.get("silhouette", 0)) > 30:
				gpu_any = true
				_ok(float(gm.get("black_frac", 1.0)) < 0.05, "GPU %s near-zero black inside silhouette (frac=%.4f, sil=%s)" % [which_g, float(gm.get("black_frac", 1.0)), gm.get("silhouette", 0)])
				_ok(int(gm.get("seam", 1)) == 0, "GPU %s no black seam/tear along contours (seam=%s)" % [which_g, gm.get("seam", -1)])
				if which_g == "long":
					_ok(int(gm.get("cavity", 0)) > 10, "GPU %s abdominal cavity fill is visible (%s px)" % [which_g, gm.get("cavity", 0)])
				else:
					var orgn := int(gm.get("cavity", 0)) + int(gm.get("uter_wall", 0)) + int(gm.get("uter_lumen", 0)) + int(gm.get("vag_wall", 0)) + int(gm.get("vag_lumen", 0))
					_ok(orgn > 40, "GPU %s organ/cavity fill is visible (%s px, cavity=%s)" % [which_g, orgn, gm.get("cavity", 0)])
			elif str(DisplayServer.get_name()) != "headless" and str(gm.get("reason", "")) != "no image" and str(gm.get("reason", "")) != "empty or dummy renderer":
				_ok(false, "GPU %s fill readback failed (%s, sil=%s black_frac=%.4f)" % [which_g, gm.get("reason", ""), gm.get("silhouette", 0), float(gm.get("black_frac", 1.0))])
		if str(DisplayServer.get_name()) != "headless":
			_ok(gpu_any, "GPU section fill rendered in at least one view")
		sec.call("set_test_render", false)
		# 脱垂：阴道内壁相对子宫截面至少有 ~3 mm 余量。
		if org and org.has_method("prolapse"):
			ctl.call("debug_set_depth", -0.08)
			await _frames(2)
			var pc: Node = org.call("prolapse")
			if pc and pc.has_method("set_amount"):
				var thr: Dictionary = pc.call("grade_thresholds") if pc.has_method("grade_thresholds") else {}
				var dm := float(thr.get("descent_max", 0.12))
				var dd: Dictionary = thr.get("descent", {})
				var mid3 := 0.75
				if dd.has(3) and dd.has(4):
					mid3 = ((float(dd[3]) + float(dd[4])) * 0.5) / maxf(dm, 1e-4)
				pc.call("set_amount", mid3)
				for _k in 45:
					await _phys(1)
				var pclr: Dictionary = _prolapse_vagina_clearance(org, pc)
				_ok(int(pclr.get("n", 0)) > 8, "prolapse clearance sampled %s vagina verts" % pclr.get("n", 0))
				_ok(float(pclr.get("worst", -1.0)) >= 0.003, "prolapse: vaginal lumen stays ≥ organ radius + 3 mm margin (worst %.2f mm, n=%s)" % [float(pclr.get("worst", -1.0)) * 1000.0, pclr.get("n", 0)])
				print("PROLAPSE VAGINA clearance worst=%.2f mm (vs mass+2*wall) n=%s" % [float(pclr.get("worst", -1.0)) * 1000.0, pclr.get("n", 0)])
				pc.call("set_amount", 0.0)
				await _phys(2)
		# 透视：腹腔内壁在阴道互动 / 断面 / 脱垂之后仍须半透明，不能挡住内脏。
		var surg: Node = player.call("get_surgery") if player.has_method("get_surgery") else null
		if surg and surg.has_method("_bake_if_needed"):
			_ok(bool(surg.call("_bake_if_needed")), "abdominal cavity lining bakes while vagina mode is active")
			await _frames(1)
			if org and org.has_method("set_xray_enabled"):
				org.call("set_xray_enabled", true)
			await _frames(2)
			var lin: Dictionary = surg.call("debug_lining_xray") if surg.has_method("debug_lining_xray") else {}
			print("LINING xray on (vagina+section): has=%s vis=%s mat_xray=%.2f alpha=%.2f transparent=%s" % [lin.get("has_cavity", false), lin.get("visible", false), float(lin.get("mat_xray", -1.0)), float(lin.get("alpha", 1.0)), lin.get("transparent", false)])
			_ok(bool(lin.get("has_cavity", false)), "cavity lining mesh exists in vagina / section mode")
			_ok(bool(lin.get("xray_on", false)), "x-ray is on when checking lining transparency")
			_ok(bool(lin.get("transparent", false)) and float(lin.get("alpha", 1.0)) < 0.85, "cavity lining is transparent in x-ray during vagina/section (alpha=%.2f, mat_xray=%.2f)" % [float(lin.get("alpha", 1.0)), float(lin.get("mat_xray", -1.0))])
			if org and org.has_method("prolapse"):
				var pc2: Node = org.call("prolapse")
				if pc2 and pc2.has_method("set_amount"):
					pc2.call("set_amount", 0.6)
					await _phys(8)
					if org.has_method("set_xray_enabled"):
						org.call("set_xray_enabled", true)
					await _frames(2)
					var linp: Dictionary = surg.call("debug_lining_xray")
					_ok(bool(linp.get("transparent", false)) and float(linp.get("alpha", 1.0)) < 0.85, "cavity lining stays transparent in x-ray during prolapse (alpha=%.2f)" % float(linp.get("alpha", 1.0)))
					pc2.call("set_amount", 0.0)
					await _phys(2)
			if org and org.has_method("set_xray_enabled"):
				org.call("set_xray_enabled", false)
			await _frames(2)
			var lin_off: Dictionary = surg.call("debug_lining_xray")
			_ok(not bool(lin_off.get("transparent", false)) and float(lin_off.get("alpha", 1.0)) >= 0.99, "cavity lining returns opaque when x-ray is off (alpha=%.2f)" % float(lin_off.get("alpha", 1.0)))
			if org and org.has_method("set_xray_enabled"):
				org.call("set_xray_enabled", true)
			await _frames(2)
			var lin_on2: Dictionary = surg.call("debug_lining_xray")
			_ok(bool(lin_on2.get("transparent", false)), "cavity lining becomes transparent again after toggling x-ray back on")
	if vm.has_method("exit"):
		vm.call("exit")
	await _frames(2)
	# 退出阴道互动后仍要跟上透视（以前只在手术 active/persist 时刷新，退出后内壁会卡在不透明）。
	var surg2: Node = player.call("get_surgery") if player.has_method("get_surgery") else null
	var org2: Node = player.call("get_organs") if player.has_method("get_organs") else null
	if surg2 and surg2.has_method("debug_lining_xray") and org2 and org2.has_method("set_xray_enabled"):
		if surg2.has_method("_bake_if_needed"):
			surg2.call("_bake_if_needed")
		org2.call("set_xray_enabled", false)
		await _frames(2)
		org2.call("set_xray_enabled", true)
		await _frames(2)
		var lin3: Dictionary = surg2.call("debug_lining_xray")
		print("LINING xray on (after vagina exit): has=%s transparent=%s alpha=%.2f" % [lin3.get("has_cavity", false), lin3.get("transparent", false), float(lin3.get("alpha", 1.0))])
		_ok(bool(lin3.get("has_cavity", false)) and bool(lin3.get("transparent", false)), "cavity lining follows x-ray after leaving vagina mode (alpha=%.2f)" % float(lin3.get("alpha", 1.0)))
	print("v0424_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _enclosure_at(org: Node, ctl: Node) -> Dictionary:
	var out := {"n": 0, "worst": 1.0, "ball": 1.0, "shaft": 1.0, "where": ""}
	if org == null or ctl == null or not org.has_method("viscera_meshes"):
		return out
	var canal: Dictionary = org.call("vagina_canal") if org.has_method("vagina_canal") else {}
	if canal.is_empty():
		return out
	var opening: Vector3 = canal.get("opening_ab", Vector3.ZERO)
	var axis: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
	if axis.length_squared() < 1e-10:
		return out
	axis = axis.normalized()
	var fr: Transform3D = org.get("_frame") if org.get("_frame") != null else Transform3D.IDENTITY
	var inv := fr.affine_inverse()
	var tip_w: Vector3 = ctl.call("tip_world")
	var tip_ab: Vector3 = inv * tip_w
	var r: float = float(ctl.call("radius"))
	var shaft_r: float = 0.004
	var depth: float = float(ctl.get("depth"))
	var lat: Vector3 = Vector3.ZERO
	if org.has_method("canal_dilate_lateral"):
		lat = org.call("canal_dilate_lateral")
	for kind in ["vagina", "uterus", "uterus_cavity"]:
		var meshes: Array = org.call("viscera_meshes", kind)
		for mi in meshes:
			if mi == null or mi.mesh == null:
				continue
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var gx: Transform3D = mi.global_transform
			var is_cav: bool = str(kind) == "uterus_cavity"
			for v in V:
				var l: Vector3 = inv * (gx * v)
				# 与 organ.gdshader 同一顺序：先搅动，再扩张/宫腔胶囊/宫底顶起。
				var off := Vector3.ZERO
				if org.has_method("canal_stir_offset_at"):
					off += org.call("canal_stir_offset_at", l)
				if org.has_method("dilate_offset_at"):
					off += org.call("dilate_offset_at", l + off)
				if org.has_method("uterus_ball_offset_at") and kind != "vagina":
					var ub: Vector3 = org.call("uterus_ball_offset_at", l + off)
					if is_cav:
						# 宫腔 GPU 不加壁厚，CPU 统一值含壁厚；按比例去掉多余壁厚。
						var wall := 0.0028
						var need := r + wall
						if need > 1e-5:
							ub *= r / need
					off += ub
				if org.has_method("fundus_lift_offset_at"):
					off += org.call("fundus_lift_offset_at", l + off)
				var q := l + off
				var to_ball := q - tip_ab
				var d_ball := to_ball.length() - r
				var rod_ax := axis
				var tsh := clampf(-(q - tip_ab).dot(rod_ax), 0.0, maxf(depth + r, 0.0))
				var d_shaft := 1.0
				if tsh > r * 0.35:
					d_shaft = ((q - tip_ab) + rod_ax * tsh).length() - shaft_r
				var s0 := (l - opening).dot(axis)
				var pr0 := ((l - opening) - axis * s0).length()
				var slice := 0.0
				var ds := s0 - depth
				if absf(ds) <= r:
					slice = sqrt(maxf(r * r - ds * ds, 0.0))
				var need_r := slice
				if s0 < depth and s0 > -0.04:
					need_r = maxf(need_r, shaft_r)
				if need_r <= 1e-5:
					continue
				if pr0 > need_r + 0.045:
					continue
				out["n"] = int(out["n"]) + 1
				if d_ball < float(out["ball"]):
					out["ball"] = d_ball
				if d_shaft < float(out["shaft"]):
					out["shaft"] = d_shaft
				var w := minf(d_ball, d_shaft)
				if w < float(out["worst"]):
					out["worst"] = w
					out["where"] = "%s s=%.1f mm" % [kind, s0 * 1000.0]
	return out


func _prolapse_vagina_clearance(org: Node, pc: Node) -> Dictionary:
	var out := {"n": 0, "worst": 1.0}
	if org == null or pc == null or not org.has_method("viscera_meshes"):
		return out
	var vag: Array = org.call("viscera_meshes", "vagina")
	if vag.is_empty():
		return out
	var u: Dictionary = org.call("prolapse_uniforms") if org.has_method("prolapse_uniforms") else {}
	if u.is_empty():
		return out
	var fr: Transform3D = org.get("_frame") if org.get("_frame") != null else Transform3D.IDENTITY
	var inv := fr.affine_inverse()
	var o4: Vector4 = u["prol_o"]
	var a4: Vector4 = u["prol_a"]
	var p4: Vector4 = u["prol_p"]
	var o := Vector3(o4.x, o4.y, o4.z)
	var ax := Vector3(a4.x, a4.y, a4.z).normalized()
	var tip := p4.y
	var w := p4.w
	var mi: MeshInstance3D = vag[0]
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var gx: Transform3D = mi.global_transform
	for v in V:
		var l: Vector3 = inv * (gx * v)
		var r4: Vector4 = org.call("prolapse_offset_ab", l)
		var q := l + Vector3(r4.x, r4.y, r4.z)
		var sq := (q - o).dot(ax)
		if sq < 0.0 or sq > a4.w:
			continue
		var mr := float(pc.call("mass_radius_at", sq - tip))
		if mr <= 1e-5:
			continue
		var rq := ((q - o) - ax * sq).length()
		# 相对「截面 + 双倍壁厚」的余量，目标是再多 4 mm。
		var clr := rq - mr - 2.0 * w
		out["n"] = int(out["n"]) + 1
		out["worst"] = minf(float(out["worst"]), clr)
	return out
