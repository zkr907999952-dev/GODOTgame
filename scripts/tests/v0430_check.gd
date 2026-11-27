extends "res://scripts/tests/v0409b_check.gd"
## 0.4.16：球 / 杆撑开子宫与阴道时内外壁同场平滑（无台阶、外壁不被内壁追上）、宫底顶起、
## 断面图体腔由体表网格判定（体外黑、体腔暗红、裆部不填充）。不打包。
##   godot --headless --path . -s res://scripts/tests/v0430_check.gd           （数值部分）
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . --rendering-method gl_compatibility \
##     --rendering-driver opengl3 -s res://scripts/tests/v0430_check.gd         （含像素部分）


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
		print("v0430_check: fails=", fails)
		quit(1)
		return
	var vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	var ctl: Node = vm.call("tool_controller")
	var org: Node = player.call("get_organs")
	var sec: Node = vm.call("cross_section")
	var opening: Vector3 = vm.call("introitus_world")
	var cerv: Vector3 = vm.call("cervix_world")
	var wall: float = float(org.call("uterus_shell_wall"))
	_ok(wall >= 0.0035, "uterine shell wall thickness known (%.2f mm)" % (wall * 1000.0))
	# 0) 平滑下限函数：单调、C0 连续、r<=n-w 时恰好落在 n。
	var prev := -1.0
	var worst_step := 0.0
	var monotone := true
	for i in 400:
		var r := float(i) * 0.0001
		var rr: float = r + float(org.call("smooth_push", r, 0.02, 0.008))
		if prev >= 0.0:
			# 斜率必须在 [0, 1]：不能倒退，也不能有台阶（一步最多前进 0.1 mm）。
			worst_step = maxf(worst_step, rr - prev - 0.0001)
			if rr < prev - 1e-9:
				monotone = false
		prev = rr
	_ok(monotone, "smooth push map r -> r + push(r) is monotone")
	_ok(worst_step < 1e-7, "smooth push has no step (worst excess %.4f mm per 0.1 mm)" % (worst_step * 1000.0))
	# 1) 球 + 杆在宫腔内：沿径向扫描，内外壁用同一个场。
	var contact: float = ctl.call("fundus_contact_depth")
	ctl.call("debug_set_depth", opening.distance_to(cerv) + float(ctl.call("radius")) * 0.9)
	await _frames(3)
	for k in 6:
		ctl.call("debug_push_depth", opening.distance_to(cerv) + float(ctl.call("radius")) * 1.4, 0.08)
	await _frames(3)
	var tip: Vector3 = ctl.call("tip_world")
	var R: float = float(ctl.call("radius"))
	var frame: Transform3D = org.call("abdomen_frame")
	var tip_ab: Vector3 = frame.affine_inverse() * tip
	var axis_ab: Vector3 = (frame.affine_inverse().basis * (vm.call("canal_axis_world") as Vector3)).normalized()
	var ortho: Vector3 = axis_ab.cross(Vector3.UP)
	if ortho.length_squared() < 1e-6:
		ortho = axis_ab.cross(Vector3.RIGHT)
	ortho = ortho.normalized()
	var ball_active := float(org.call("uterus_ball_distend")) > 0.0
	_ok(ball_active, "ball is inside the uterus (distend %.1f mm)" % (float(org.call("uterus_ball_distend")) * 1000.0))
	var worst_gap := 99.0
	var worst_jump := 0.0
	var worst_in_vs_out := 99.0
	for dir_i in 6:
		var dir := ortho.rotated(axis_ab, float(dir_i) * TAU / 6.0)
		var last_in := Vector3.ZERO
		var have := false
		for ri in 80:
			var rr := 0.002 + float(ri) * 0.0005
			# 沿球心径向放一对点：内膜在 rr，外膜在 rr + t（休息壁厚 t = 1.5~4 mm）。
			var p_in: Vector3 = tip_ab + dir * rr
			var off_in: Vector3 = org.call("uterus_ball_offset_at", p_in, 0.0)
			var fin_in := (p_in + off_in - tip_ab).length()
			if have:
				worst_jump = maxf(worst_jump, ((off_in - last_in)).length())
			last_in = off_in
			have = true
			for t in [0.0015, 0.0025, 0.004]:
				var p_out: Vector3 = tip_ab + dir * (rr + t)
				var off_out: Vector3 = org.call("uterus_ball_offset_at", p_out, -1.0)
				var fin_out := (p_out + off_out - tip_ab).length()
				worst_gap = minf(worst_gap, (fin_out - fin_in) - minf(t, wall))
				worst_in_vs_out = minf(worst_in_vs_out, fin_out - fin_in)
	_ok(worst_gap > -0.0002, "outer wall stays at least one wall thickness outside the inner wall around the ball (worst %.2f mm)" % (worst_gap * 1000.0))
	_ok(worst_in_vs_out > 0.0, "inner wall never ends up beyond the outer wall (min gap %.2f mm)" % (worst_in_vs_out * 1000.0))
	_ok(worst_jump < 0.0008, "displacement field is continuous across the sweep (worst step %.3f mm per 0.5 mm)" % (worst_jump * 1000.0))
	# 2) 通道（阴道 / 宫颈段）扩张：同样检查内外壁和连续性。
	var worst_gap_d := 99.0
	var worst_jump_d := 0.0
	var dax: Vector3 = axis_ab
	var open_ab: Vector3 = frame.affine_inverse() * opening
	for si in 20:
		var s_along := 0.01 + float(si) * 0.004
		var base: Vector3 = open_ab + dax * s_along
		var last := Vector3.ZERO
		var have2 := false
		for ri2 in 70:
			var rr2 := 0.002 + float(ri2) * 0.0005
			var pi_: Vector3 = base + ortho * rr2
			var oi: Vector3 = org.call("dilate_offset_at", pi_, 0.0)
			if have2:
				worst_jump_d = maxf(worst_jump_d, (oi - last).length())
			last = oi
			have2 = true
			for t2 in [0.0015, 0.0035]:
				var po: Vector3 = base + ortho * (rr2 + t2)
				var oo: Vector3 = org.call("dilate_offset_at", po, wall)
				var fi := ((pi_ + oi) - base).dot(ortho)
				var fo := ((po + oo) - base).dot(ortho)
				worst_gap_d = minf(worst_gap_d, fo - fi - minf(t2, wall) * 0.999)
	_ok(worst_gap_d > -0.0002, "canal dilation keeps the outer shell outside the inner shell (worst %.2f mm)" % (worst_gap_d * 1000.0))
	_ok(worst_jump_d < 0.0008, "canal dilation field is continuous (worst step %.3f mm per 0.5 mm)" % (worst_jump_d * 1000.0))
	# 3) 实网格壁厚（顶端）+ 深推时整例子宫顶起且球不穿宫底。
	for _i in 14:
		ctl.call("debug_push_depth", contact + 0.10, 0.08)
	await _frames(3)
	var lift: float = ctl.call("debug_fundus_lift")
	_ok(lift > 0.05, "pushing past the fundus displaces the whole uterus (%.1f mm)" % (lift * 1000.0))
	var enc: Dictionary = org.call("debug_insert_enclosure", ctl.call("tip_world"), R)
	_ok(bool(enc.get("inside_cavity", false)) and bool(enc.get("below_outer", false)), "ball stays inside the displaced uterus (cavity %.1f / outer %.1f mm)" % [float(enc.get("cavity_along", 0.0)) * 1000.0, float(enc.get("outer_along", 0.0)) * 1000.0])
	_ok(float(enc.get("wall_min", 99.0)) >= 0.002, "real mesh wall thickness stays >= 2 mm while stretched (%.2f mm)" % (float(enc.get("wall_min", 99.0)) * 1000.0))
	_ok(int(enc.get("wall_neg", 0)) == 0, "no inner vertex ends up beyond its outer wall (neg=%s)" % enc.get("wall_neg", 0))
	# 4) 断面图随子宫位移：切面拷贝带 fundus_lift / shell_wall，和主视图同一场。
	sec.call("set_view_mode", "both")
	await _frames(3)
	var seen_lift := false
	var seen_shell := false
	for rec in sec.get("_copies"):
		var m = rec.get("cap")
		if m is ShaderMaterial and str(rec.get("kind", "")) == "uterus":
			var fl = m.get_shader_parameter("fundus_lift")
			var sw = m.get_shader_parameter("shell_wall")
			if fl != null and float(fl) > 0.05:
				seen_lift = true
			if sw != null and float(sw) > 0.003:
				seen_shell = true
	_ok(seen_lift, "section copies of the uterus carry the fundus lift (cross-section shows the displaced uterus)")
	_ok(seen_shell, "section copies of the outer uterus carry the shell wall")
	# 5) 像素：体外黑、体腔暗红、裆部不填充（需要有显示的渲染器）。
	if DisplayServer.get_name() != "headless":
		sec.call("set_test_render", true)
		ctl.call("debug_set_depth", opening.distance_to(cerv) * 0.45)
		await _frames(5)
		for which in ["long", "coronal"]:
			sec.call("set_view_mode", which)
			await _frames(4)
			var img: Image = sec.call("debug_capture_section", which)
			_ok(img != null, "%s capture exists" % which)
			if img == null:
				continue
			img.convert(Image.FORMAT_RGBA8)
			var w := img.get_width()
			var h := img.get_height()
			var dark := 0
			var red := 0
			var tot := 0
			var top_red := 0
			var top_tot := 0
			var bot_black := 0
			var bot_tot := 0
			for y in h:
				for x in w:
					var c := img.get_pixel(x, y)
					var is_black := c.r < 0.06 and c.g < 0.06 and c.b < 0.06
					var is_red := absf(c.r - 0.48) < 0.06 and absf(c.g - 0.20) < 0.06 and absf(c.b - 0.26) < 0.06
					tot += 1
					if is_black:
						dark += 1
					if is_red:
						red += 1
					if y < h / 4:
						top_tot += 1
						if is_red:
							top_red += 1
					if y > h * 3 / 4:
						bot_tot += 1
						if is_black:
							bot_black += 1
			print("PIX %s black=%.3f red=%.3f top_red=%.3f bottom_black=%.3f" % [which, float(dark) / tot, float(red) / tot, float(top_red) / top_tot, float(bot_black) / bot_tot])
			_ok(float(red) / tot > 0.25, "%s: body cavity is dark red (%.2f of the pane)" % [which, float(red) / tot])
			_ok(float(dark) / tot > 0.05, "%s: area outside the body is black (%.2f of the pane)" % [which, float(dark) / tot])
			if which == "coronal":
				_ok(float(bot_black) / bot_tot > 0.35, "coronal: the crotch between the legs is not filled (bottom quarter black %.2f)" % (float(bot_black) / bot_tot))
				_ok(float(top_red) / top_tot > 0.5, "coronal: the body above is filled dark red (top quarter %.2f)" % (float(top_red) / top_tot))
		sec.call("set_test_render", false)
	print("v0430_check: fails=", fails)
	quit(1 if fails > 0 else 0)
