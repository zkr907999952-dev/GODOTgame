extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中，t66u / t68u）：子宫脱垂系统。分度阈值、宫颈 / 宫底相对外口的位置、
## 专用简化子宫模型（替换原子宫 / 宫颈、复用原材质、连续且朝外、面数低）、阴道不再内翻 / 无套筒、
## 外口撑开不穿模、IV 度垂得更低、柔性悬挂甩动衰减、手 / 手术钳 / 观察视角的手都能拖、
## 触发 #1（长杆钢球）阈值、手术经创口先复位再扯出、复原、无 NaN、每帧开销。不打包。
##   godot --headless --path . -s res://scripts/tests/v0420_prolapse_check.gd

var org: Node
var pc: Node
var vm: Node
var _nan_seen := 0


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
		print("v0420_prolapse_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	if s and bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	org = player.call("get_organs")
	vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(3)
	pc = org.call("prolapse")
	_ok(pc != null, "OrganRig.prolapse() exists")
	await _check_spawn()
	await _check_grades()
	await _check_swing()
	await _check_hand_drag()
	await _check_trigger()
	await _check_pip()
	await _check_reset()
	vm.call("exit")
	await _frames(2)
	await _check_observe_hand()
	await _check_surgery()
	_ok(_nan_seen == 0, "no NaN in prolapse nodes / model during the whole run (%d)" % _nan_seen)
	print("v0420_prolapse_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _scan_nan() -> void:
	for p in pc.call("node_positions"):
		if not (p as Vector3).is_finite():
			_nan_seen += 1
	var md = pc.call("model")
	if md and md.visible:
		for c in md.call("ring_centers"):
			if not (c as Vector3).is_finite():
				_nan_seen += 1


func _settle(n: int) -> void:
	for i in n:
		await _phys(1)
		_scan_nan()


# ------------------------------------------------------------------ 专用模型：替换原子宫 / 宫颈
func _check_spawn() -> void:
	pc.call("set_amount", 0.0005)
	await _settle(2)
	_ok(bool(pc.call("is_active")), "a tiny descent activates the prolapse")
	var md = pc.call("model")
	_ok(md != null and md.visible and pc.call("soft_organ") == md, "the dedicated prolapse uterus model is shown (soft_organ() returns it for the PiP)")
	_ok(pc.call("sleeve") == null, "no everted vaginal sleeve any more")
	var hid := true
	if org.has_method("kinds_hidden"):
		for k in ["uterus", "tube", "ovary"]:
			hid = hid and bool(org.call("kinds_hidden", k))
	_ok(hid, "the original uterus / tubes / ovaries are hidden while the model replaces them")
	if md == null:
		return
	var ut: Array = org.call("viscera_meshes", "uterus")
	var orig_v := 0
	for m in ut:
		var mi := m as MeshInstance3D
		if mi and mi.mesh:
			for si in mi.mesh.get_surface_count():
				orig_v += (mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var mv := int(md.get("vertex_count"))
	print("PROLAPSE model: %d verts (original uterus %d), surfaces=%d" % [mv, orig_v, md.mesh.get_surface_count() if md.mesh else 0])
	_ok(mv > 100 and mv < 700 and mv * 4 < orig_v, "the model is a simplified mesh (%d verts vs %d)" % [mv, orig_v])
	# 整段统一用阴道黏膜着色器 / 贴图，再染成更红润的肉色（不再用原子宫红）。
	var vg: Array = org.call("viscera_meshes", "vagina")
	var src_v := (vg[0] as MeshInstance3D).material_override as ShaderMaterial if not vg.is_empty() else null
	var mb := md.mesh.surface_get_material(1) as ShaderMaterial if md.mesh and md.mesh.get_surface_count() > 1 else null
	var mc := md.mesh.surface_get_material(0) as ShaderMaterial if md.mesh and md.mesh.get_surface_count() > 0 else null
	var same_sh: bool = mb != null and mc != null and src_v != null and mb.shader == src_v.shader and mc.shader == src_v.shader
	var same_tex: bool = mb != null and src_v != null and mb.get_shader_parameter("albedo_tex") == src_v.get_shader_parameter("albedo_tex")
	var bc: Color = mb.get_shader_parameter("base_color") if mb else Color.BLACK
	var cc: Color = mc.get_shader_parameter("base_color") if mc else Color.BLACK
	var close := absf(bc.r - cc.r) < 0.20 and absf(bc.g - cc.g) < 0.20 and absf(bc.b - cc.b) < 0.20
	var ruddy := bc.r > bc.g and bc.g > 0.35
	_ok(same_sh and same_tex and close and ruddy, "the model uses a unified ruddy vaginal-mucosa look (shader=%s tex=%s close=%s ruddy=%s body=%s cervix=%s)" % [same_sh, same_tex, close, ruddy, bc, cc])
	# 刚激活时与原子宫重合：模型宫颈尖（弧长 0 的环心）≈ 原宫颈位置。
	var cw: PackedVector3Array = md.call("ring_centers_world")
	var arcs: PackedFloat32Array = md.call("ring_arcs")
	var ci := 0
	for i in arcs.size():
		if absf(arcs[i]) < absf(arcs[ci]):
			ci = i
	var cerv: Vector3 = pc.call("cervix_world")
	var off := cw[ci].distance_to(cerv) if not cw.is_empty() else 99.0
	_ok(off < 0.002, "model cervix tip sits on the original cervix at d≈0 (%.2f mm)" % (off * 1000))
	pc.call("reset")
	await _settle(2)


# ------------------------------------------------------------------ 分度 / 位置 / 套筒 / 外口 / 阴道内翻
func _check_grades() -> void:
	var thr: Dictionary = pc.call("grade_thresholds")
	var dm := float(thr["descent_max"])
	var dd: Dictionary = thr["descent"]
	var aa: Dictionary = thr["amount"]
	print("PROLAPSE descent_max=%.1f mm  thresholds descent(mm): I=%.1f II=%.1f III=%.1f IV=%.1f  amount: I=%.3f II=%.3f III=%.3f IV=%.3f" % [dm * 1000, float(dd[1]) * 1000, float(dd[2]) * 1000, float(dd[3]) * 1000, float(dd[4]) * 1000, float(aa[1]), float(aa[2]), float(aa[3]), float(aa[4])])
	_ok(float(aa[1]) < float(aa[2]) and float(aa[2]) < float(aa[3]) and float(aa[3]) < float(aa[4]) and float(aa[4]) < 1.0, "grade thresholds increase 0 < I < II < III < IV < 1")
	var h := float(pc.get("params").get("hymen_band"))
	var wall := float(pc.get("params").get("wall"))
	# 每度取中点。
	var mids := {
		1: (float(dd[1]) + float(dd[2])) * 0.5,
		2: (float(dd[2]) + float(dd[3])) * 0.5,
		3: (float(dd[3]) + float(dd[4])) * 0.5,
		4: (float(dd[4]) + dm) * 0.5,
	}
	_ok(int(pc.call("grade_for_descent", 0.0)) == 0, "grade 0 at no descent")
	for g in [1, 2, 3, 4]:
		pc.call("set_amount", float(mids[g]) / dm)
		await _settle(45)
		var st: Dictionary = pc.call("debug_state")
		var csd := float(st["cervix_sd"])
		var fsd := float(st["fundus_sd"])
		var pen := float(org.vulva.call("insert_penetration"))
		var pr := float(pc.call("portal_radius"))
		var a_portal := float(pc.get("descent")) - float(st["sigma0"])
		var mass_r := float(pc.call("mass_radius_at", a_portal)) if a_portal > -0.02 else 0.0
		var ins = pc.call("inserter")
		var ins_r := float(ins.call("radius")) if ins and bool(pc.call("owns_introitus")) else 0.0
		print("PROLAPSE grade %s: descent=%.1f mm amount=%.2f cervix_sd=%+.1f mm fundus_sd=%+.1f mm out_nodes=%d introitus_r=%.1f mm mass_r=%.1f mm penetration=%.2f mm" % [pc.call("grade_name"), float(pc.get("descent")) * 1000, float(pc.call("amount")), csd * 1000, fsd * 1000, int(st["out"]), ins_r * 1000, mass_r * 1000, pen * 1000])
		_ok(int(pc.get("grade")) == g, "grade %d reached at its mid descent" % g)
		if g == 1:
			_ok(csd > h, "grade I: cervix still inside the canal (%.1f mm above the introitus)" % (csd * 1000))
		elif g == 2:
			_ok(absf(csd) <= h + 0.001, "grade II: cervix at the introitus (%+.1f mm)" % (csd * 1000))
		elif g == 3:
			_ok(csd < -h and fsd > 0.0, "grade III: cervix outside (%.1f mm), fundus still inside (%.1f mm)" % [csd * 1000, fsd * 1000])
		else:
			_ok(fsd < 0.0 and int(st["out"]) == int(pc.get("_n")), "grade IV: whole uterus outside (fundus %.1f mm out, %d/%d nodes)" % [fsd * 1000, int(st["out"]), int(pc.get("_n"))])
			_check_through_vagina()
		if g >= 2:
			_ok(pen < 0.001, "grade %d: no labia / vestibule penetration (%.2f mm)" % [g, pen * 1000])
			_ok(ins_r >= mass_r + wall - 1e-4, "grade %d: introitus opened to ≥ the mass cross-section (%.1f ≥ %.1f mm)" % [g, ins_r * 1000, (mass_r + wall) * 1000])
		_check_model(g)
		_check_vagina_deform(g)
	# t68u：IV 度最大时宫底垂得更低（fundus_out_max 14 → 50 mm）。
	pc.call("set_amount", 1.0)
	await _settle(90)
	var st2: Dictionary = pc.call("debug_state")
	var O2: Vector3 = pc.call("introitus_world")
	var f_drop := O2.y - (pc.call("fundus_world") as Vector3).y
	print("PROLAPSE max: fundus %.1f mm outside along the path, %.1f mm below the introitus" % [-float(st2["fundus_sd"]) * 1000, f_drop * 1000])
	_ok(float(st2["fundus_sd"]) < -0.035, "max grade IV: the uterus hangs low (fundus %.1f mm out, was ≤ 14 mm)" % (-float(st2["fundus_sd"]) * 1000))


func _check_through_vagina() -> void:
	# 宫底在外面，是从阴道口出来的：体外链锚在外口（不是腹部创口），每个节点都在会阴平面外侧。
	var O: Vector3 = pc.call("introitus_world")
	var ain: Vector3 = pc.call("canal_axis_world")
	var nodes: PackedVector3Array = pc.call("node_positions")
	var all_out := true
	for p in nodes:
		if (p - O).dot(-ain) < -0.001:
			all_out = false
	var seg: PackedFloat32Array = pc.get("_seg")
	var total := 0.0
	for l in seg:
		total += l
	var la := float(pc.get("descent")) - float((pc.get("_sigma") as PackedFloat32Array)[nodes.size() - 1])
	var reach := nodes[nodes.size() - 1].distance_to(O)
	var navel: Vector3 = (org.get("_frame") as Transform3D).origin
	var f_navel := nodes[nodes.size() - 1].distance_to(navel)
	print("PROLAPSE IV: fundus→introitus %.1f mm (rope %.1f mm), fundus→navel %.1f cm" % [reach * 1000, la * 1000, f_navel * 100])
	_ok(all_out and reach <= la + 0.003, "grade IV: the fundus hangs from the vaginal opening (fundus→introitus %.1f mm ≤ %.1f mm)" % [reach * 1000, la * 1000])
	_ok(f_navel > 0.12, "grade IV: the fundus is far from the abdomen / wound (%.1f cm from the navel)" % (f_navel * 100))


func _check_model(g: int) -> void:
	var md = pc.call("model")
	_ok(md != null and md.visible, "grade %d: prolapse model shown" % g)
	if md == null:
		return
	var cw: PackedVector3Array = md.call("ring_centers_world")
	var rr: PackedFloat32Array = md.call("ring_radii")
	var max_gap := 0.0
	for i in range(1, cw.size()):
		max_gap = maxf(max_gap, cw[i].distance_to(cw[i - 1]))
	# 绕序 / 法线：每个三角形的几何法线与顶点法线同向，且顶点法线背离中线（朝外）。
	var wind_bad := 0
	var wind_in := 0
	var mxf: Transform3D = md.global_transform
	var O: Vector3 = pc.call("introitus_world")
	var ain: Vector3 = pc.call("canal_axis_world")
	var inward := 0
	var tris := 0
	var mesh: ArrayMesh = md.mesh
	for si in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(si)
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for t in range(0, I.size(), 3):
			var a := V[I[t]]
			var b := V[I[t + 1]]
			var c := V[I[t + 2]]
			var gn := (b - a).cross(c - a)
			if gn.length_squared() < 1e-14:
				continue
			tris += 1
			var vn := N[I[t]] + N[I[t + 1]] + N[I[t + 2]]
			# Godot 正面 = 顺时针：右手几何法线应与外法线相反。
			if gn.dot(vn) > 0.0:
				# 体内急弯（阴道 → 前倾宫体）内侧环会互相压叠，那里看不见；体外部分必须全部正面朝外。
				var cen: Vector3 = mxf * ((a + b + c) / 3.0)
				if (cen - O).dot(-ain) > 0.002:
					wind_bad += 1
				else:
					wind_in += 1
	var lc: PackedVector3Array = md.call("ring_centers")
	var arr0: Array = mesh.surface_get_arrays(mesh.get_surface_count() - 1)
	var V0: PackedVector3Array = arr0[Mesh.ARRAY_VERTEX]
	var N0: PackedVector3Array = arr0[Mesh.ARRAY_NORMAL]
	for vi in V0.size():
		var best := 1e9
		var bc := Vector3.ZERO
		for c2 in lc:
			var dd := c2.distance_squared_to(V0[vi])
			if dd < best:
				best = dd
				bc = c2
		if (V0[vi] - bc).length() > 0.003 and N0[vi].dot(V0[vi] - bc) < 0.0:
			inward += 1
	var arcs: PackedFloat32Array = md.call("ring_arcs")
	var ci := 0
	for i2 in arcs.size():
		if absf(arcs[i2]) < absf(arcs[ci]):
			ci = i2
	var cerv: Vector3 = pc.call("cervix_world")
	var tip_off := cw[ci].distance_to(cerv)
	print("PROLAPSE model grade %d: rings=%d verts=%d max_gap=%.1f mm wind_bad_outside=%d folded_inside=%d /%d inward_normals=%d cervix_tip_off=%.2f mm rebuilds=%d" % [g, cw.size(), int(md.get("vertex_count")), max_gap * 1000, wind_bad, wind_in, tris, inward, tip_off * 1000, int(md.get("rebuilds"))])
	_ok(cw.size() >= 15 and max_gap < 0.012, "grade %d: model is one continuous tube (max ring gap %.1f mm)" % [g, max_gap * 1000])
	_ok(wind_bad == 0 and inward == 0, "grade %d: model surface outside the body faces outward (winding %d bad, %d inward normals)" % [g, wind_bad, inward])
	_ok(wind_in * 12 < tris, "grade %d: only a few triangles fold on the inner side of the in-body bend (%d / %d)" % [g, wind_in, tris])
	_ok(tip_off < 0.003, "grade %d: model cervix follows the physics chain (%.2f mm)" % [g, tip_off * 1000])
	if g >= 3:
		_ok((cerv - O).dot(-ain) > 0.005, "grade %d: model cervix / os is outside the introitus" % g)
	if g == 4:
		# t73u：外口到子宫的连接段（阴道壁蒂）够粗、肉粉色（阴道黏膜材质，不是子宫红）。
		var nr := float(md.get("neck_radius"))
		var rmax := 0.0
		for r2 in rr:
			rmax = maxf(rmax, r2)
		# 细颈与宫体同一黏膜面（面 1），统一红润肉色，不再用原子宫红。
		var m1 := mesh.surface_get_material(1) as ShaderMaterial if mesh.get_surface_count() > 1 else mesh.surface_get_material(0) as ShaderMaterial
		var ncol: Color = m1.get_shader_parameter("base_color") if m1 else Color.BLACK
		var pink: bool = m1 != null and ncol.r > ncol.g and ncol.g > 0.35
		var neck_rings := 0
		var Uu := float(pc.get("_U"))
		for a2 in arcs:
			if a2 > Uu:
				neck_rings += 1
		var v_s1 := (mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if mesh.get_surface_count() > 1 else 0
		print("PROLAPSE neck: radius %.1f mm (body max %.1f mm), rings %d, body+neck verts %d, pink=%s col=%s" % [nr * 1000, rmax * 1000, neck_rings, v_s1, pink, ncol])
		_ok(nr >= 0.013 and nr >= rmax * 0.55, "grade IV: the introitus→uterus connection is thick (%.1f mm radius vs body %.1f mm)" % [nr * 1000, rmax * 1000])
		_ok(pink and neck_rings >= 3 and v_s1 >= (neck_rings + 1) * 13, "grade IV: the connection uses the unified ruddy mucosa colour, not the red uterus colour")


func _check_vagina_deform(g: int) -> void:
	# CPU 版着色器公式：体内阴道顶端翻进去（双层），其余部分被脱出物撑开、不被穿透。
	var vag: Array = org.call("viscera_meshes", "vagina")
	if vag.is_empty():
		return
	var u: Dictionary = org.call("prolapse_uniforms")
	_ok(not u.is_empty() and (u["prol_o"] as Vector4).w > 0.5, "grade %d: vagina shader gets the prolapse uniforms" % g)
	if u.is_empty():
		return
	var mi: MeshInstance3D = vag[0]
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var fr: Transform3D = org.get("_frame")
	var inv := fr.affine_inverse()
	var o4: Vector4 = u["prol_o"]
	var a4: Vector4 = u["prol_a"]
	var p4: Vector4 = u["prol_p"]
	var o := Vector3(o4.x, o4.y, o4.z)
	var ax := Vector3(a4.x, a4.y, a4.z).normalized()
	var tip := p4.y
	var w := p4.w
	var inverted := 0
	var worst := 1.0
	var gx := mi.global_transform
	for v in V:
		var l: Vector3 = inv * (gx * v)
		var r4: Vector4 = org.call("prolapse_offset_ab", l)
		var q := l + Vector3(r4.x, r4.y, r4.z)
		if r4.w > 0.5:
			inverted += 1
			continue
		var sq := (q - o).dot(ax)
		if sq < 0.0 or sq > a4.w:
			continue
		var rq := ((q - o) - ax * sq).length()
		var mr := float(pc.call("mass_radius_at", sq - tip))
		if mr <= 0.0:
			continue
		worst = minf(worst, rq - mr - w)
	print("PROLAPSE vagina grade %d: inverted verts=%d / %d, min wall clearance to the mass=%.2f mm" % [g, inverted, V.size(), worst * 1000])
	_ok(inverted == 0, "grade %d: vagina is no longer inverted / folded (simplified, %d folded verts)" % [g, inverted])
	_ok(worst >= -0.0002, "grade %d: the descending mass does not poke through the canal wall (clearance %.2f mm)" % [g, worst * 1000])


# ------------------------------------------------------------------ 甩动衰减
func _measure_swing() -> Dictionary:
	pc.call("set_amount", 0.97)
	await _settle(90)
	var n := int(pc.get("_n"))
	var nodes: PackedVector3Array = pc.call("node_positions")
	var f0 := nodes[n - 1]
	var side: Vector3 = (pc.call("canal_axis_world") as Vector3).cross(Vector3.UP).normalized()
	pc.call("begin_drive", "test", n - 1, f0, true)
	for i in 8:
		pc.call("drive_to", f0 + side * 0.05 * float(i + 1) / 8.0)
		await _settle(1)
	pc.call("end_drive")
	var prev: Vector3 = (pc.call("node_positions") as PackedVector3Array)[n - 1]
	var prev_v := 0.0
	var peak := 0.0
	var late := 0.0
	var peak_acc := 0.0
	var late_acc := 0.0
	var late_sum := 0.0
	var late_n := 0
	var seg: PackedFloat32Array = pc.get("_seg")
	var max_stretch := 0.0
	var usec := 0
	for f in 240:
		await _phys(1)
		_scan_nan()
		var np: PackedVector3Array = pc.call("node_positions")
		var v := np[n - 1].distance_to(prev) * 60.0
		var acc := 0.0
		if f > 0:
			acc = absf(v - prev_v) * 60.0
		prev = np[n - 1]
		prev_v = v
		usec += int(pc.get("last_step_usec"))
		if f < 40:
			peak = maxf(peak, v)
			peak_acc = maxf(peak_acc, acc)
		if f >= 180:
			late = maxf(late, v)
			late_acc = maxf(late_acc, acc)
			late_sum += acc
			late_n += 1
		for b in range(1, n):
			max_stretch = maxf(max_stretch, np[b].distance_to(np[b - 1]) / maxf(float(seg[b - 1]), 1e-4))
	return {
		"peak": peak,
		"late": late,
		"peak_acc": peak_acc,
		"late_acc": late_acc,
		"late_acc_avg": late_sum / maxf(float(late_n), 1.0),
		"max_stretch": max_stretch,
		"usec": usec / 240,
	}


func _set_swing_tune(air: float, vmax: float, push: float, impulse: float, absorb: float) -> void:
	var pr = pc.get("params")
	pr.set("air_damp", air)
	pr.set("max_speed", vmax)
	pr.set("collision_push", push)
	pr.set("collision_impulse_max", impulse)
	pr.set("collision_vel_absorb", absorb)


func _check_swing() -> void:
	var pr = pc.get("params")
	var saved := {
		"air": float(pr.get("air_damp")),
		"vmax": float(pr.get("max_speed")),
		"push": float(pr.get("collision_push")),
		"impulse": float(pr.get("collision_impulse_max")),
		"absorb": float(pr.get("collision_vel_absorb")),
	}
	# 对照：改阻尼之前的轻量硬投影（只用于抖动计量，不断言必须更抖）。
	_set_swing_tune(0.986, 5.0, 1.0, 0.05, 0.0)
	if pc.has_method("reset"):
		pc.call("reset")
		await _settle(2)
	var before: Dictionary = await _measure_swing()
	print("PROLAPSE swing BEFORE damp: peak %.3f m/s, late %.4f m/s (%.1f%%), late accel peak/avg %.1f/%.1f m/s², stretch %.3f, %d µs" % [float(before.peak), float(before.late), float(before.late) / maxf(float(before.peak), 1e-6) * 100.0, float(before.late_acc), float(before.late_acc_avg), float(before.max_stretch), int(before.usec)])
	_set_swing_tune(saved.air, saved.vmax, saved.push, saved.impulse, saved.absorb)
	if pc.has_method("reset"):
		pc.call("reset")
		await _settle(2)
	var after: Dictionary = await _measure_swing()
	print("PROLAPSE swing AFTER damp: peak %.3f m/s, late %.4f m/s (%.1f%%), late accel peak/avg %.1f/%.1f m/s², stretch %.3f, %d µs" % [float(after.peak), float(after.late), float(after.late) / maxf(float(after.peak), 1e-6) * 100.0, float(after.late_acc), float(after.late_acc_avg), float(after.max_stretch), int(after.usec)])
	_ok(float(after.peak) > 0.05, "a fling makes the hanging uterus swing (%.3f m/s)" % float(after.peak))
	_ok(float(after.late) < float(after.peak) * 0.12, "the swing decays (%.4f m/s after 3 s, %.1f%% of peak)" % [float(after.late), float(after.late) / maxf(float(after.peak), 1e-6) * 100.0])
	_ok(float(after.max_stretch) < 1.06, "flexible chain stays intact (max stretch %.3f)" % float(after.max_stretch))
	_ok(int(after.usec) < 2000, "prolapse step is cheap while swinging (%d µs avg)" % int(after.usec))
	var late_before := maxf(float(before.late_acc), 0.01)
	var late_after := float(after.late_acc)
	_ok(late_after < late_before * 0.65 or late_after < 4.0, "settled swing jitter drops (late accel %.1f → %.1f m/s², avg %.1f → %.1f)" % [late_before, late_after, float(before.late_acc_avg), float(after.late_acc_avg)])
	var md = pc.call("model")
	var rb0 := int(md.get("rebuilds")) if md else 0
	await _settle(30)
	var rb1 := int(md.get("rebuilds")) if md else 0
	print("PROLAPSE model rebuilds while settled: %d in 30 frames" % (rb1 - rb0))
	_ok(rb1 - rb0 <= 10, "a settled hanging uterus mostly skips model rebuilds (%d / 30)" % (rb1 - rb0))
	_set_swing_tune(saved.air, saved.vmax, saved.push, saved.impulse, saved.absorb)


# ------------------------------------------------------------------ 用手拖：可拉出 / 推回
func _check_hand_drag() -> void:
	pc.call("set_amount", 0.6)
	await _settle(40)
	var d0 := float(pc.get("descent"))
	var cam: Camera3D = player.call("get_camera")
	var cerv: Vector3 = pc.call("cervix_world")
	var origin := cerv + (cam.global_position - cerv).normalized() * 0.3 if cam else cerv + Vector3(0, 0, 0.3)
	var ok := bool(vm.call("begin_prolapse_drag", origin, (cerv - origin).normalized()))
	_ok(ok, "the outside prolapse is pickable for a hand drag")
	var ain: Vector3 = pc.call("canal_axis_world")
	for i in 40:
		pc.call("drive_to", cerv - ain * 0.002 * float(i + 1))
		await _settle(1)
	var d1 := float(pc.get("descent"))
	for i2 in 60:
		pc.call("drive_to", (pc.call("introitus_world") as Vector3) + ain * 0.03)
		await _settle(1)
	var d2 := float(pc.get("descent"))
	vm.call("end_prolapse_drag")
	print("PROLAPSE hand drag: descent %.1f → pull %.1f → push back %.1f mm" % [d0 * 1000, d1 * 1000, d2 * 1000])
	_ok(d1 > d0 + 0.02, "pulling the dragged uterus increases the prolapse (%.1f → %.1f mm)" % [d0 * 1000, d1 * 1000])
	_ok(d2 < d1 - 0.02, "pushing it back reduces the prolapse (%.1f → %.1f mm)" % [d1 * 1000, d2 * 1000])
	pc.call("reset")
	await _settle(2)


# ------------------------------------------------------------------ 触发 #1：长杆钢球
func _ball_in_uterus(ctl: Node, diam: float) -> float:
	ctl.call("set_diameter", diam)
	ctl.call("debug_reset_gate")
	var cerv := float(vm.call("introitus_world").distance_to(vm.call("cervix_world")))
	var r := float(ctl.call("radius"))
	ctl.call("debug_set_depth", cerv + r * 0.95 + 0.006)
	ctl.set("through_cervix", true)
	ctl.set("_last_desired", INF)
	return cerv


func _pull(ctl: Node, from_d: float, step: float, frames: int) -> void:
	var d := from_d
	for i in frames:
		d -= step
		ctl.call("apply_desired_depth", d, 1.0 / 60.0)
		await _phys(1)
		if bool(ctl.get("caught")) or not bool(ctl.get("through_cervix")):
			return


func _check_trigger() -> void:
	vm.call("set_tool", "ball_rod")
	await _frames(3)
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null and ctl.has_method("is_caught"), "ball-rod has the prolapse catch API")
	if ctl == null:
		return
	ctl.set("dragging", true)
	var cap := float(pc.get("params").get("cervix_capacity_r")) * float(pc.get("params").get("catch_ratio"))
	# a) 小球（20 mm）快扯：照旧从宫颈弹出，不脱垂。
	var d0 := _ball_in_uterus(ctl, 0.020) + 0.02
	await _pull(ctl, d0, 0.006, 40)
	var r_small := float(ctl.call("radius"))
	print("PROLAPSE trigger a) ball %.1f mm (catch ≥ %.1f mm radius) fast pull: caught=%s through_cervix=%s report=%s" % [r_small * 2000, cap * 1000, ctl.get("caught"), ctl.get("through_cervix"), pc.call("trigger", "ball_rod").get("last_report")])
	_ok(not bool(ctl.get("caught")) and not bool(pc.call("is_active")), "small ball + hard pull: no prolapse")
	_ok(not bool(ctl.get("through_cervix")), "small ball pops back out through the cervix as before")
	# b) 大球（30 mm）慢、轻拉（被挡行程 < 阈值）：不脱垂，攒够压力后照旧弹出。
	d0 = _ball_in_uterus(ctl, 0.030)
	var gate_end: float = d0 + float(ctl.call("radius")) * 0.55
	for i in 90:
		ctl.call("apply_desired_depth", gate_end - minf(0.0006 * float(i), 0.02), 1.0 / 60.0)
		await _phys(1)
		if not bool(ctl.get("through_cervix")) or bool(ctl.get("caught")):
			break
	var rep_b: Dictionary = pc.call("trigger", "ball_rod").get("last_report")
	print("PROLAPSE trigger b) ball 30 mm gentle pull: caught=%s through_cervix=%s speed=%.3f force=%.1f mm" % [ctl.get("caught"), ctl.get("through_cervix"), float(rep_b.get("pull_speed", 0)), float(rep_b.get("pull_force", 0)) * 1000])
	_ok(not bool(ctl.get("caught")) and not bool(pc.call("is_active")), "big ball + gentle pull: no prolapse")
	# c) 大球（30 mm）快扯：宫颈卡住球，子宫被拖出来。
	d0 = _ball_in_uterus(ctl, 0.030) + 0.01
	await _pull(ctl, d0, 0.005, 30)
	var rep_c: Dictionary = pc.call("trigger", "ball_rod").get("last_report")
	print("PROLAPSE trigger c) ball 30 mm hard pull: caught=%s speed=%.3f m/s force=%.1f mm state=%s report=%s depth=%.1f mm thr=%s" % [ctl.get("caught"), float(rep_c.get("pull_speed", 0)), float(rep_c.get("pull_force", 0)) * 1000, pc.get("state"), str(rep_c), float(ctl.get("depth")) * 1000, ctl.get("through_cervix")])
	_ok(bool(ctl.get("caught")) and bool(pc.call("is_active")) and str(pc.get("state")) == "driven", "big ball + hard pull: cervix catches the ball and the uterus starts to prolapse")
	if not bool(ctl.get("caught")):
		return
	# 继续往外拉：随拉出距离逐度加重。
	var O: Vector3 = pc.call("introitus_world")
	var ain: Vector3 = pc.call("canal_axis_world")
	var grades: Array = []
	var down := (-ain + Vector3(0, -0.6, 0)).normalized()
	var start: Vector3 = ctl.call("tip_world")
	var grade_mono := true
	var last_g := 0
	for i2 in 160:
		var tgt := start + down * 0.0012 * float(i2 + 1)
		ctl.call("drive_caught_to", tgt)
		await _settle(1)
		var g := int(pc.get("grade"))
		if g < last_g:
			grade_mono = false
		last_g = g
		if grades.is_empty() or int(grades[grades.size() - 1]) != g:
			grades.append(g)
		if g >= 3 and float(pc.call("amount")) > 0.7:
			break
	var ball_off := (ctl.call("tip_world") as Vector3).distance_to(pc.call("cervix_world"))
	print("PROLAPSE trigger pull: grades passed %s, amount %.2f, ball↔cervix %.1f mm" % [str(grades), float(pc.call("amount")), ball_off * 1000])
	_ok(grade_mono and last_g >= 3, "pulling the caught ball progresses the grades with distance (%s)" % str(grades))
	_ok(ball_off < float(ctl.call("radius")) + 0.004, "the ball stays caught at the cervix (%.1f mm)" % (ball_off * 1000))
	# 松手：停在已达到的等级挂着。
	var d_rel := float(pc.get("descent"))
	ctl.call("end_drag")
	await _settle(60)
	var d_after := float(pc.get("descent"))
	print("PROLAPSE release: descent %.1f → %.1f mm, state=%s grade=%s" % [d_rel * 1000, d_after * 1000, pc.get("state"), pc.call("grade_name")])
	_ok(str(pc.get("state")) == "hanging" and absf(d_after - d_rel) < 0.002, "after release it hangs at the reached grade (%.1f → %.1f mm)" % [d_rel * 1000, d_after * 1000])
	# 再拖：拉到头后再多拉，球从宫颈脱出，子宫留在 IV 度。
	ctl.call("begin_drag", Vector2.ZERO, O + Vector3(0, 0, 0.3), Vector3(0, 0, -1))
	var st2: Vector3 = ctl.call("tip_world")
	for i3 in 260:
		ctl.call("drive_caught_to", st2 + down * 0.0015 * float(i3 + 1))
		await _settle(1)
		if not bool(ctl.get("caught")):
			break
	print("PROLAPSE over-pull: caught=%s grade=%s amount=%.2f" % [ctl.get("caught"), pc.call("grade_name"), float(pc.call("amount"))])
	_ok(not bool(ctl.get("caught")) and int(pc.get("grade")) == 4, "pulling past total procidentia pops the ball out of the cervix; uterus stays at IV")
	ctl.call("end_drag")
	ctl.set("dragging", false)
	await _settle(10)


# ------------------------------------------------------------------ 断面小窗
func _check_pip() -> void:
	vm.call("set_tool", "ball_rod")
	await _frames(2)
	if not bool(pc.call("is_active")):
		pc.call("set_amount", 0.95)
	await _settle(4)
	var sec: Node = vm.get("_section")
	_ok(sec != null, "cross-section view exists")
	if sec == null:
		return
	sec.call("set_visible_on", true)
	await _frames(3)
	var copies: Array = sec.get("_copies")
	var has_so := false
	var vag_on := false
	for rec in copies:
		var src: Node = rec["src"]
		if src == pc.call("soft_organ"):
			has_so = true
		if str(rec.get("kind", "")) == "vagina":
			var cut: ShaderMaterial = rec["cut"]
			var po = cut.get_shader_parameter("prol_o")
			if po is Vector4 and (po as Vector4).w > 0.5:
				vag_on = true
	_ok(has_so, "PiP shows the dedicated prolapse uterus model")
	_ok(vag_on, "PiP vagina copies get the prolapse stretch uniforms")
	var cam: Camera3D = sec.get("_long_cam")
	var fund: Vector3 = pc.call("fundus_world")
	var in_view := false
	if cam:
		var lp := cam.global_transform.affine_inverse() * fund
		in_view = absf(lp.x) < cam.size * 0.5 * 1.8 and absf(lp.y) < cam.size * 0.5
	_ok(in_view, "PiP longitudinal view frames the hanging fundus")
	_ok(int(sec.get("last_step_usec")) < 4000, "PiP update stays cheap with the prolapse (%d µs)" % int(sec.get("last_step_usec")))
	hud.call("_refresh_surgery_ui")
	await _frames(2)
	var lbl: Label = hud.get("_prolapse_label")
	print("PROLAPSE HUD label: '%s'" % (lbl.text if lbl else "<none>"))
	_ok(lbl != null and lbl.visible and lbl.text.find("度") >= 0, "HUD shows the prolapse grade in vagina mode")


# ------------------------------------------------------------------ 复原
func _check_reset() -> void:
	if not bool(pc.call("is_active")):
		pc.call("set_amount", 0.9)
		await _settle(10)
	player.call("restore_body")
	await _settle(4)
	var u: Dictionary = org.call("prolapse_uniforms")
	var vag: Array = org.call("viscera_meshes", "vagina")
	var po = (vag[0] as MeshInstance3D).material_override.get_shader_parameter("prol_o") if not vag.is_empty() else Vector4.ZERO
	var md = pc.call("model")
	var ut_vis := not bool(org.call("kinds_hidden", "uterus")) if org.has_method("kinds_hidden") else true
	print("PROLAPSE reset: active=%s grade=%d descent=%.2f mm model_visible=%s intro_mix=%.3f" % [pc.call("is_active"), int(pc.get("grade")), float(pc.get("descent")) * 1000, md.visible if md else false, float(org.vulva.get("_intro_mix"))])
	_ok(not bool(pc.call("is_active")) and int(pc.get("grade")) == 0 and float(pc.get("descent")) == 0.0, "复原 restores the prolapse to grade 0")
	_ok(u.is_empty() and (po == null or (po as Vector4).w < 0.5), "复原 clears the vagina prolapse uniforms")
	_ok(md == null or not md.visible, "复原 hides the prolapse model")
	_ok(ut_vis, "复原 shows the original uterus again")
	_ok(float(org.vulva.get("_intro_mix")) < 1e-4, "复原 closes the introitus")


# ------------------------------------------------------------------ 观察 / 普通视角：手拖体外脱垂（t68u）
func _check_observe_hand() -> void:
	pc.call("set_amount", 0.6)
	await _settle(40)
	var d0 := float(pc.get("descent"))
	var cam: Camera3D = player.call("get_camera")
	var cerv: Vector3 = pc.call("cervix_world")
	var origin := cam.global_position if cam else cerv + Vector3(0, 0, 0.4)
	var ok := bool(player.call("debug_begin_prolapse_hand", origin, (cerv - origin).normalized()))
	_ok(ok and str(pc.get("drive_source")) == "hand", "outside vagina mode the hand can grab the hanging uterus (src=%s)" % pc.get("drive_source"))
	var ain: Vector3 = pc.call("canal_axis_world")
	var down := -ain
	for i in 50:
		var tgt := cerv + down * 0.002 * float(i + 1)
		player.call("debug_update_prolapse_hand", origin, (tgt - origin).normalized())
		await _settle(1)
	var d1 := float(pc.get("descent"))
	player.call("_end_prolapse_hand")
	await _settle(2)
	print("PROLAPSE observe hand: descent %.1f → %.1f mm, driving after release=%s" % [d0 * 1000, d1 * 1000, pc.call("is_driving")])
	_ok(d1 > d0 + 0.01, "the observe-view hand drag moves / pulls the prolapse (%.1f → %.1f mm)" % [d0 * 1000, d1 * 1000])
	_ok(not bool(pc.call("is_driving")), "releasing the hand ends the drive")
	pc.call("reset")
	await _settle(2)


# ------------------------------------------------------------------ 手术：钳子拖体外部分；经创口先复位，再扯出
func _check_surgery() -> void:
	await _open_wound()
	pc.call("set_amount", 0.95)
	await _settle(60)
	# t68u：手术钳直接夹住阴道口外悬垂的子宫拖动（不经创口）。
	s.call("set_tool", "forceps")
	await _frames(2)
	var n := int(pc.get("_n"))
	var fund: Vector3 = (pc.call("node_positions") as PackedVector3Array)[n - 1]
	var cam: Camera3D = player.call("get_camera")
	var org0 := cam.global_position if cam else fund + Vector3(0, 0.2, 0.3)
	var okf := bool(s.call("_begin_forceps", org0, (fund - org0).normalized()))
	_ok(okf and str(s.get("_fc_kind")) == "prolapse_out" and str(pc.get("drive_source")) == "forceps", "forceps grabs the outside prolapse directly (kind=%s src=%s)" % [s.get("_fc_kind"), pc.get("drive_source")])
	if okf:
		var side: Vector3 = (pc.call("canal_axis_world") as Vector3).cross(Vector3.UP).normalized()
		var dn := int(pc.call("drive_node"))
		var p0: Vector3 = (pc.call("node_positions") as PackedVector3Array)[dn]
		var tip0f: Vector3 = s.get("_fc_last")
		for i in 30:
			s.call("debug_forceps_drag_to", tip0f + side * 0.0015 * float(i + 1))
			await _settle(1)
		var p1: Vector3 = (pc.call("node_positions") as PackedVector3Array)[dn]
		s.call("debug_forceps_end")
		await _settle(2)
		print("PROLAPSE forceps drag: node %d moved %.1f mm sideways, driving after release=%s" % [dn, (p1 - p0).dot(side) * 1000, pc.call("is_driving")])
		_ok((p1 - p0).dot(side) > 0.015, "forceps drags the hanging uterus (%.1f mm)" % ((p1 - p0).dot(side) * 1000))
		_ok(not bool(pc.call("is_driving")), "releasing the forceps ends the drive")
	pc.call("set_amount", 0.95)
	await _settle(30)
	var d_start := float(pc.get("descent"))
	_ok(int(pc.get("grade")) == 4, "prolapse set to IV before surgery (descent %.1f mm)" % (d_start * 1000))
	s.call("set_tool", "forceps")
	await _frames(2)
	var ok := bool(s.call("debug_begin_extract", "uterus"))
	_ok(ok and str(s.get("_fc_kind")) == "prolapse", "forceps through the wound grabs the prolapsed uterus for reduction (kind=%s)" % s.get("_fc_kind"))
	if not ok:
		return
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var tip0: Vector3 = s.get("_fc_last")
	var mono := true
	var prev := d_start
	var extracted_early := false
	var handoff_frame := -1
	var d_at_handoff := -1.0
	for i in 400:
		s.call("debug_forceps_drag_to", tip0 + outv * 0.0015 * float(i + 1))
		await _phys(1)
		_scan_nan()
		var so: Node = s.call("soft_organ", "uterus")
		var d := float(pc.get("descent")) if bool(pc.call("is_active")) else 0.0
		if d > prev + 1e-5:
			mono = false
		prev = d
		var ext := so != null and bool(so.call("is_extracted"))
		if ext and handoff_frame < 0:
			handoff_frame = i
			d_at_handoff = d
		if ext and d > 1e-4:
			extracted_early = true
		if handoff_frame >= 0 and i > handoff_frame + 30:
			break
	print("PROLAPSE surgery: descent %.1f mm reduced monotonic=%s, handoff to wound extraction at frame %d with descent %.2f mm, fc_kind=%s handoffs=%d" % [d_start * 1000, mono, handoff_frame, d_at_handoff * 1000, s.get("_fc_kind"), int(s.get("prolapse_reduce_handoffs"))])
	_ok(mono and handoff_frame > 0, "surgery pull reduces the prolapse gradually (monotonic)")
	_ok(not extracted_early and d_at_handoff <= 1e-4, "wound extraction starts only after the prolapse is fully reduced (descent %.2f mm)" % (d_at_handoff * 1000))
	_ok(str(s.get("_fc_kind")) == "soft", "the same forceps continues into the normal wound extraction")
	s.call("debug_forceps_end")
	await _phys(2)
	_ok(bool(s.call("restore_extracted_organs")), "放回内脏 works after the hand-off")
	await _phys(3)
	pc.call("set_amount", 0.5)
	await _settle(5)
	s.call("restore_extracted_organs")
	await _settle(3)
	_ok(not bool(pc.call("is_active")), "放回内脏 also restores the prolapse")
