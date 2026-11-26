extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.14 之后，t83u）：脱垂子宫与阴道连接统一为更红润湿润的黏膜色，
## 并与跟随大腿骨骼的胶囊碰撞，避免卡进腿里。不打包。
##   godot --headless --path . -s res://scripts/tests/v0423_prolapse_color_thigh_check.gd

var org: Node
var pc: Node
var vm: Node


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
	org = player.call("get_organs")
	vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	await _frames(6)
	await _check_standing()
	if not await _enter_bed():
		print("v0423_prolapse_color_thigh_check: fails=", fails)
		quit(1)
		return
	if s == null:
		s = player.call("get_surgery")
	if s and bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	await _check_bed()
	print("v0423_prolapse_color_thigh_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _settle(n: int) -> void:
	for i in n:
		await _phys(1)


func _color_delta(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))


func _check_colors(tag: String) -> void:
	var look: Dictionary = pc.call("mucosa_look")
	var p = pc.get("params")
	var vg: Array = org.call("viscera_meshes", "vagina")
	var src_v := (vg[0] as MeshInstance3D).material_override as ShaderMaterial if not vg.is_empty() else null
	var md = pc.call("model")
	_ok(md != null and md.visible and md.mesh and md.mesh.get_surface_count() >= 2, "%s: prolapse model has two mucosa surfaces" % tag)
	if md == null or md.mesh == null:
		return
	var mc := md.mesh.surface_get_material(0) as ShaderMaterial
	var mb := md.mesh.surface_get_material(1) as ShaderMaterial
	_ok(mc != null and mb != null and src_v != null, "%s: cervix / body / vagina materials exist" % tag)
	if mc == null or mb == null or src_v == null:
		return
	_ok(mc.shader == src_v.shader and mb.shader == src_v.shader, "%s: both surfaces keep the vaginal mucosa shader" % tag)
	_ok(mb.get_shader_parameter("albedo_tex") == src_v.get_shader_parameter("albedo_tex") and mc.get_shader_parameter("albedo_tex") == src_v.get_shader_parameter("albedo_tex"), "%s: both surfaces keep the vaginal mucosa texture" % tag)
	var want_b: Color = p.mucosa_tex_tint if bool(mb.get_shader_parameter("use_tex")) else p.mucosa_solid
	var want_c: Color = p.cervix_tex_tint if bool(mc.get_shader_parameter("use_tex")) else p.cervix_solid
	var bc: Color = mb.get_shader_parameter("base_color")
	var cc: Color = mc.get_shader_parameter("base_color")
	print("PROLAPSE color %s: body=%s cervix=%s wet=%.2f rough=%.2f vagina_src=%s" % [tag, bc, cc, float(mb.get_shader_parameter("wet")), float(mb.get_shader_parameter("roughness")), src_v.get_shader_parameter("base_color")])
	_ok(_color_delta(bc, want_b) < 0.02 and _color_delta(cc, want_c) < 0.02, "%s: tints match the unified ruddy mucosa palette (body %s cervix %s)" % [tag, bc, cc])
	_ok(_color_delta(bc, cc) < 0.20, "%s: body / cervix stay in one colour family (Δ=%.3f, no harsh red line)" % [tag, _color_delta(bc, cc)])
	# 红润：比原阴道乘色 (0.92, 0.84, 0.82) 更暖、更红；G 仍明显高于深暗红。
	var src_c: Color = src_v.get_shader_parameter("base_color")
	_ok(bc.r > bc.g and bc.g > 0.40 and bc.b < bc.r - 0.08, "%s: body is a ruddy pink-red mucosa (not pale, not deep red)" % tag)
	_ok(cc.r > cc.g and (cc.r + cc.g + cc.b) < (bc.r + bc.g + bc.b) - 0.02, "%s: cervix is slightly darker / more flushed around the os" % tag)
	_ok(float(mb.get_shader_parameter("wet")) >= 0.58 and float(mb.get_shader_parameter("roughness")) <= 0.34, "%s: mucosa is glossier / moister than the default organ finish" % tag)
	_ok(look.get("body") == mb or look.get("body_color") == bc, "%s: mucosa_look() reports the body tint" % tag)
	# 与原子宫底色分离（若原子宫不是同一套红润黏膜色）。
	var ut: Array = org.call("viscera_meshes", "uterus")
	if not ut.is_empty():
		var src_u := (ut[0] as MeshInstance3D).material_override as ShaderMaterial
		if src_u:
			var uc: Color = src_u.get_shader_parameter("base_color")
			var different: bool = _color_delta(bc, uc) > 0.04 or mb.get_shader_parameter("albedo_tex") != src_u.get_shader_parameter("albedo_tex")
			_ok(different, "%s: prolapsed body is no longer the original uterus colouring" % tag)
	# 细颈与宫体同一材质实例或同一底色。
	if int(pc.get("grade")) >= 4 or float(pc.call("amount")) > 0.85:
		_ok(_color_delta(bc, want_b) < 0.02, "%s: the vaginal connection uses the same ruddy mucosa tint as the uterus body" % tag)


func _mesh_thigh_clearance() -> float:
	var md = pc.call("model")
	if md == null:
		return 1.0
	var caps: Array = pc.call("thigh_capsules")
	if caps.is_empty():
		return 1.0
	var cw: PackedVector3Array = md.call("ring_centers_world")
	var rr: PackedFloat32Array = md.call("ring_radii")
	var O: Vector3 = pc.call("introitus_world")
	var out: Vector3 = -(pc.call("canal_axis_world") as Vector3)
	var margin := float(pc.get("params").get("thigh_margin"))
	var best := 1.0
	for i in mini(cw.size(), rr.size()):
		if (cw[i] - O).dot(out) < -0.004:
			continue
		for cap in caps:
			var a: Vector3 = cap["a"]
			var b: Vector3 = cap["b"]
			var ab := b - a
			var denom := ab.length_squared()
			var c: Vector3 = a if denom < 1e-12 else a + ab * clampf((cw[i] - a).dot(ab) / denom, 0.0, 1.0)
			best = minf(best, cw[i].distance_to(c) - float(cap["r"]) - float(rr[i]) - margin)
	return best


func _assert_no_thigh_sink(tag: String) -> void:
	var cl := float(pc.call("thigh_clearance"))
	var mcl := _mesh_thigh_clearance()
	var caps: Array = pc.call("thigh_capsules")
	print("PROLAPSE thighs %s: capsules=%d node_clear=%.2f mm mesh_clear=%.2f mm" % [tag, caps.size(), cl * 1000.0, mcl * 1000.0])
	_ok(caps.size() == 2, "%s: both thigh capsules are tracked from UpperLeg→Foreleg" % tag)
	# 允许 0.5 mm 数值误差；不能明显陷进腿里。
	_ok(cl >= -0.0010, "%s: no simulated prolapse point is inside a thigh capsule (clearance %.2f mm)" % [tag, cl * 1000.0])
	_ok(mcl >= -0.0010, "%s: the visible tube stays out of the thighs (mesh clearance %.2f mm)" % [tag, mcl * 1000.0])


func _hang_and_swing(tag: String) -> void:
	pc.call("set_amount", 0.97)
	await _settle(50)
	_ok(int(pc.get("grade")) == 4, "%s: grade IV hanging" % tag)
	var st: Dictionary = pc.call("debug_state")
	print("PROLAPSE hang %s: cervix %.1f cm and fundus %.1f cm below the opening, anterior %.1f mm" % [tag, float(st.get("cervix_drop", 0.0)) * 100, float(st.get("fundus_drop", 0.0)) * 100, float(st.get("fundus_anterior", 0.0)) * 1000])
	if tag.begins_with("standing"):
		_ok(float(st.get("cervix_drop", 0.0)) > 0.03, "%s: hangs down fully (cervix %.1f cm below the opening, between or in front of the thighs)" % [tag, float(st.get("cervix_drop", 0.0)) * 100])
	_check_colors(tag)
	_assert_no_thigh_sink(tag + " settled")
	var n := int(pc.get("_n"))
	var nodes: PackedVector3Array = pc.call("node_positions")
	var f0 := nodes[n - 1]
	var caps: Array = pc.call("thigh_capsules")
	# 朝最近的大腿内侧甩 / 推，确认会被推出而不是穿进去。
	if not caps.is_empty():
		var a: Vector3 = caps[0]["a"]
		var b: Vector3 = caps[0]["b"]
		var ab := b - a
		var denom := maxf(ab.length_squared(), 1e-12)
		var t := clampf((f0 - a).dot(ab) / denom, 0.15, 0.85)
		var c := a + ab * t
		var dir := c - f0
		if dir.length() < 0.01:
			dir = ab.cross(Vector3.UP)
		# 先甩向大腿，再把目标设到胶囊内部。
		pc.call("begin_drive", "test", n - 1, f0, true)
		for i in 8:
			pc.call("drive_to", f0.lerp(c, float(i + 1) / 8.0))
			await _settle(1)
		var inward := c + (c - f0).normalized() * 0.02
		pc.call("drive_to", inward)
		await _settle(16)
		_assert_no_thigh_sink(tag + " driven into thigh")
		pc.call("end_drive")
		await _settle(12)
	# 左右甩动，统计开销，并确认全程不穿腿。
	nodes = pc.call("node_positions")
	f0 = nodes[n - 1]
	var side := Vector3.RIGHT
	var ax: Vector3 = pc.call("canal_axis_world")
	if absf(ax.cross(Vector3.UP).length_squared()) > 1e-6:
		side = ax.cross(Vector3.UP).normalized()
	pc.call("begin_drive", "test", n - 1, f0, true)
	for i in 8:
		pc.call("drive_to", f0 + side * 0.04 * float(i + 1) / 8.0)
		await _settle(1)
	pc.call("end_drive")
	var worst := 1.0
	var usec := 0
	for f in 90:
		await _phys(1)
		usec += int(pc.get("last_step_usec"))
		worst = minf(worst, float(pc.call("thigh_clearance")))
		worst = minf(worst, _mesh_thigh_clearance())
	var avg := usec / 90
	print("PROLAPSE thighs %s swing: worst clearance %.2f mm, avg step %d µs" % [tag, worst * 1000.0, avg])
	_ok(worst >= -0.0010, "%s: swinging never sinks into the thighs (worst %.2f mm)" % [tag, worst * 1000.0])
	# t68u 前约 6400 µs，简化后自检上限 2000 µs；大腿碰撞必须保持在这个预算内。
	_ok(avg < 2000, "%s: thigh collision stays cheap (%d µs avg, budget 2000)" % [tag, avg])
	pc.call("reset")
	await _settle(2)


func _check_standing() -> void:
	hud.call("_refresh_surgery_ui")
	hud.call("_refresh_vagina_ui")
	var ok_enter := bool(vm.call("enter")) if vm and vm.has_method("enter") else false
	if not ok_enter and hud.get("_btn_vagina_enter"):
		hud.get("_btn_vagina_enter").emit_signal("pressed")
		await _settle(20)
		ok_enter = bool(vm.call("is_active"))
	else:
		await _settle(8)
	_ok(ok_enter and bool(vm.call("is_active")), "standing: enter vagina interaction")
	pc = org.call("prolapse")
	_ok(pc != null, "OrganRig.prolapse() exists")
	if pc == null:
		return
	await _hang_and_swing("standing")
	if vm and bool(vm.call("is_active")):
		vm.call("exit")
		await _frames(2)


func _check_bed() -> void:
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "bed: enter vagina mode")
	await _frames(3)
	pc = org.call("prolapse")
	await _hang_and_swing("bed")
	if vm and bool(vm.call("is_active")):
		vm.call("exit")
		await _frames(2)
