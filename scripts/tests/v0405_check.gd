extends "res://scripts/tests/v0404_check.gd"
## 0.4.05 自检：交叉直切皮瓣截面清理干净；每一刀的唇缘都能拿取 / 放拉钩；系膜间距加大；
## 子宫上移后移、阴道通道接到外阴；外阴皮肤分瓣（set_vulva_spread）。
##   godot --headless --path . -s res://scripts/tests/v0405_check.gd   （V0405_ONLY=walls|cuts|mes|organs|vulva|forceps|retr）


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
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.get_slice("version/code=", 1).get_slice("\n", 0).to_int() >= 48, "export version 0.4.05+ / 48+")
	var only := OS.get_environment("V0405_ONLY")
	if only == "" or only == "organs":
		await _check_organs_0405()
	if only == "" or only == "vulva":
		await _check_vulva()
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	if only == "" or only == "walls":
		await _check_cross_walls()
	if only == "" or only == "cuts":
		await _check_all_cuts()
	if only == "" or only == "mes":
		await _check_mesentery_spacing()
	if only == "" or only == "forceps":
		await _check_forceps_modes()
	if only == "" or only == "retr":
		await _check_retractor_hook_out()
	print("v0405_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _tri_cuts() -> Array:
	var nav: Vector3 = s.get("_navel_rest")
	var A := nav + Vector3(-0.05, -0.03, 0)
	var B := nav + Vector3(0.05, -0.03, 0)
	var C := nav + Vector3(0.0, -0.11, 0)
	for pr in [[A, B], [B, C], [C, A]]:
		var a: Vector3 = pr[0]
		var b: Vector3 = pr[1]
		var d := (b - a).normalized()
		_ok(_straight(a - d * 0.015, b + d * 0.015), "cut %s -> %s" % [a, b])
		s.call("debug_finish_cut_anim")
		s.call("debug_settle_eversion")
	return [A, B, C]


func _walls_inside(poly: PackedVector2Array) -> int:
	var wall: Geom.MeshData = s.get("_wall_md")
	var n := 0
	for f in wall.face_count():
		var c3 := wall.centroid(f)
		var c := Vector2(c3.x, c3.y)
		if Geometry2D.is_point_in_polygon(c, poly):
			var dm := 1e9
			for k in poly.size():
				dm = minf(dm, c.distance_to(Geometry2D.get_closest_point_to_segment(c, poly[k], poly[(k + 1) % poly.size()])))
			if dm > 0.001:
				n += 1
	return n


func _check_cross_walls() -> void:
	await _restart()
	var abc := _tri_cuts()
	var A: Vector3 = abc[0]
	var B: Vector3 = abc[1]
	var C: Vector3 = abc[2]
	var poly := PackedVector2Array([Vector2(A.x, A.y), Vector2(B.x, B.y), Vector2(C.x, C.y)])
	var before := _walls_inside(poly)
	print("v0402: bridging faces cleared while cutting: %d" % int(s.get("bridging_faces_cleared")))
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "triangle flap peeled")
	await _frames(3)
	var after := _walls_inside(poly)
	_ok(before > 100 and after == 0, "no section faces left inside the triangle opening (> 1 mm from the cut lines: %d before peel -> %d after)" % [before, after])
	# 身体那侧的截面：每个三角的来源顶点都在外皮边界上且彼此相邻
	var outer: Geom.MeshData = s.get("_outer")
	var bnd: Dictionary = s.call("_boundary_edges", outer)
	var bv := {}
	for e in bnd:
		bv[(e as Vector2i).x] = true
		bv[(e as Vector2i).y] = true
	var bad := 0
	var total := 0
	for part in s.get("_wall_parts"):
		var md: Geom.MeshData = (part as Dictionary)["md"]
		var src: PackedInt32Array = (part as Dictionary).get("src", PackedInt32Array())
		if src.size() != md.vert_count():
			continue
		for f in md.face_count():
			total += 1
			for k in 3:
				if not bv.has(src[md.idx[f * 3 + k]]):
					bad += 1
					break
	_ok(total > 100 and bad == 0, "every remaining section face hangs off a real lip of the body (%d faces, %d invalid)" % [total, bad])
	_ok(int(s.call("_drop_bridging_wall_faces")) == 0, "no section face bridges across another cut")
	# 皮瓣自己的周圈截面完整：皮瓣网格 = 外 + 内 + 周圈壁
	var fl: Node3D = s.get("flap_node")
	_ok(fl != null and is_instance_valid(fl), "triangle flap exists with its own rim wall")


func _check_all_cuts() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var ys := [-0.03, -0.065, -0.10]
	var first_l := PackedInt32Array()
	var first_r := PackedInt32Array()
	for i in 3:
		var y: float = ys[i]
		_ok(_straight(nav + Vector3(-0.045, y, 0), nav + Vector3(0.045, y - 0.002, 0)), "parallel cut %d" % i)
		s.call("debug_finish_cut_anim")
		s.call("debug_settle_eversion")
	_ok(int(s.call("cut_count")) == 3, "all three cuts remembered (%d)" % int(s.call("cut_count")))
	var lips: Array = s.call("cut_lips", int(OS.get_environment("CUT_IDX")) if OS.has_environment("CUT_IDX") else 0)
	first_l = lips[0]
	first_r = lips[1]
	var outer: Geom.MeshData = s.get("_outer")
	var mi := first_l.size() / 2
	var vl: int = first_l[mi]
	# 对面那侧唇上离 vl 最近的点
	var vr: int = first_r[0]
	var bd := 1e9
	for v in first_r:
		var dd := outer.pos[v].distance_to(outer.pos[vl])
		if dd < bd:
			bd = dd
			vr = v
	var gap0 := (s.call("_vert_world", vl) as Vector3).distance_to(s.call("_vert_world", vr))
	s.call("set_tool", "grab")
	var gap_prev := gap0
	for side in [1, -1]:
		var vid: int = vl if side == 1 else vr
		var other: int = vr if side == 1 else vl
		var vw: Vector3 = s.call("_vert_world", vid)
		var ow: Vector3 = s.call("_vert_world", other)
		var o := vw + Vector3(0, 0.3, 0)
		var ok := bool(s.call("begin_stroke", o, (vw - o).normalized()))
		var lip_ok: bool = int(s.get("_pull_lip")) == side and (s.get("_lip_left") as PackedInt32Array) == first_l
		_ok(ok and lip_ok, "grab picks the %s lip of the FIRST cut (pull lip %d)" % ["left" if side == 1 else "right", int(s.get("_pull_lip"))])
		var away := (vw - ow)
		away.y = 0.0
		away = away.normalized() * 0.018
		for k in 12:
			var tgt := vw + away * (float(k + 1) / 12.0)
			s.call("drag_stroke", tgt + Vector3(0, 0.3, 0), Vector3.DOWN)
			await process_frame
		# 按住时把当前拉开量写进网格（等同松手瞬间、回弹之前），测真实横向张开量
		await _frames(2)
		s.call("_bake_pull")
		s.call("end_stroke")
		await _frames(4)
		var gh := (s.call("_vert_world", vl) as Vector3).distance_to(s.call("_vert_world", vr))
		_ok(gh > gap_prev + 0.004, "pulling the %s lip of the first cut opens it sideways (gap %.1f -> %.1f mm)" % ["left" if side == 1 else "right", gap_prev * 1000.0, gh * 1000.0])
		gap_prev = gh
	var gap1 := (s.call("_vert_world", vl) as Vector3).distance_to(s.call("_vert_world", vr))
	_ok(gap1 > gap0 + 0.009, "first cut opens laterally with both lips pulled (%.1f -> %.1f mm)" % [gap0 * 1000.0, gap1 * 1000.0])
	# 旧切口上放拉钩：单侧唇拉开（不再退回径向）
	s.call("set_tool", "retractor")
	_ok(bool(s.call("place_retractor", first_l[mi + 2])), "retractor placed on the first (older) cut")
	await _frames(2)
	_ok(int(s.get("_pull_mode")) == 1 or (s.get("_lip_left") as PackedInt32Array) == first_l, "retractor on the older cut uses that cut's lip (mode %d)" % int(s.get("_pull_mode")))
	s.call("restore_body")
	await _frames(3)


func _check_mesentery_spacing() -> void:
	var GR = load("res://scripts/surgery/gut_rope.gd")
	_ok(int(GR.MES_EVERY) >= 6, "mesentery tethers every %d segments (was 3)" % int(GR.MES_EVERY))


func _organ_rig() -> Node:
	return player.get_node_or_null("OrganRig")


func _organ_verts(pat: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	var rig := _organ_rig()
	for mi in rig.get("organ_meshes"):
		var m := mi as MeshInstance3D
		if str(m.get_meta("organ_material", "")).to_lower().find(pat) >= 0:
			out.append_array(m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	return out


func _box(P: PackedVector3Array) -> AABB:
	var bb := AABB(P[0], Vector3.ZERO)
	for p in P:
		bb = bb.expand(p)
	return bb


func _check_organs_0405() -> void:
	var rig := _organ_rig()
	_ok(rig != null, "organ rig present")
	var meta: Dictionary = rig.get("meta")
	var mv: Array = meta.get("uterus_move", [])
	_ok(mv.size() == 3 and is_equal_approx(float(mv[1]), 0.03) and (is_equal_approx(float(mv[2]), -0.012) or is_equal_approx(float(mv[2]), 0.0)), "uterus moved up 30 mm (0.4.08: back-shift undone, 12 mm forward again) (%s)" % [mv])
	var ut := _box(_organ_verts("uterus"))
	var bl := _box(_organ_verts("vessie"))
	# 0.4.04 的位置：子宫 y 0.9031..0.9623、z 0.0162..0.0714；膀胱 y 0.8791..0.9271、z 0.0475..0.0836
	_ok(absf(ut.position.y - 0.9331) < 0.002 and (absf(ut.position.z - 0.0042) < 0.002 or absf(ut.position.z - (0.0042 + float(mv[2]) + 0.012)) < 0.002), "uterus box now y %.4f.. z %.4f.. (was 0.9031 / 0.0162)" % [ut.position.y, ut.position.z])
	_ok(absf(bl.position.y - 0.8791) < 0.001 and absf(bl.end.z - 0.0836) < 0.001, "bladder unchanged (y %.4f, z max %.4f)" % [bl.position.y, bl.end.z])
	var GV := PackedVector3Array()
	for mi in rig.get("organ_meshes"):
		if str((mi as MeshInstance3D).get_meta("organ_group", "")) == "gut":
			GV.append_array((mi as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	var gut := _box(GV)
	var vg = meta.get("vagina", null)
	_ok(vg is Dictionary, "meta has the vaginal canal")
	var V := _organ_verts("vagin")
	_ok(V.size() > 300, "full vaginal canal mesh present (%d verts, was a stub / missing)" % V.size())
	if V.size() == 0 or not (vg is Dictionary):
		return
	var cx: Array = vg["cervix"]
	var op: Array = vg["opening"]
	var vs: Array = vg["vulva_skin"]
	var cervix := Vector3(cx[0], cx[1], cx[2])
	var opening := Vector3(op[0], op[1], op[2])
	var vul := Vector3(vs[0], vs[1], vs[2])
	var vb := _box(V)
	var lowest := V[0]
	var highest := V[0]
	for p in V:
		if p.y < lowest.y:
			lowest = p
		if p.y > highest.y:
			highest = p
	_ok(ut.grow(0.004).has_point(highest) and cervix.distance_to(Vector3(0, ut.position.y, cervix.z)) < 0.01, "canal starts at the relocated cervix (top %.3f, uterus bottom %.3f)" % [highest.y, ut.position.y])
	_ok(opening.distance_to(vul) < 0.009 and lowest.y > vul.y and lowest.y - vul.y < 0.008, "canal outer end meets the skin vulva from inside (%.1f mm above the skin)" % ((lowest.y - vul.y) * 1000.0))
	_ok(float(vg["skin_clearance"]) > 0.0005, "canal opening stays inside the skin (clearance %.1f mm)" % (float(vg["skin_clearance"]) * 1000.0))
	_ok(float(vg["length"]) > 0.05 and opening.z > cervix.z + 0.015 and float(vg["tilt_deg"]) > 15.0, "canal slants down and forward to the crotch (%.0f mm, %.0f° from vertical)" % [float(vg["length"]) * 1000.0, float(vg["tilt_deg"])])
	var V2 := _organ_verts("vessie")
	var dmin := 1e9
	for i in range(0, V.size(), 2):
		for j in range(0, V2.size(), 3):
			dmin = minf(dmin, V[i].distance_to(V2[j]))
	_ok(dmin > 0.002, "canal clears the bladder (%.1f mm)" % (dmin * 1000.0))
	# 直肠远端接到肛门后，大肠 AABB 最低点会低于子宫底；不允许整包肠管掉到肛门以下。
	var anus_y := 0.8969
	_ok(gut.position.y > anus_y - 0.008, "guts stay at or above the anus (gut min %.3f)" % gut.position.y)
	# 蒙皮：只绑髋 / 脊柱骨（与其它盆腔器官一样）
	var bones_ok := true
	var skel: Skeleton3D = rig.get("_skel")
	for mi in rig.get("organ_meshes"):
		var m := mi as MeshInstance3D
		if str(m.get_meta("organ_material", "")).to_lower().find("vagin") < 0:
			continue
		var sk: Skin = m.skin
		for b in sk.get_bind_count():
			var bn := str(sk.get_bind_name(b))
			if bn == "" and sk.get_bind_bone(b) >= 0:
				bn = skel.get_bone_name(sk.get_bind_bone(b))
			if not (bn.begins_with("C_Hip") or bn.begins_with("C_Spine")):
				bones_ok = false
	_ok(bones_ok, "canal skinned to hip / spine bones")
	_ok(vb.size.x < 0.04, "canal width %.0f mm" % (vb.size.x * 1000.0))


func _ray_hits_tris(P: PackedVector3Array, idx: PackedInt32Array, o: Vector3, d: Vector3, tmax: float) -> bool:
	# 细化后三角形只有几个平方毫米，Geometry3D 的交点在这个尺度上会全部判空，改用重心坐标自算。
	for f in idx.size() / 3:
		var a: Vector3 = P[idx[f * 3]]
		var b: Vector3 = P[idx[f * 3 + 1]]
		var c: Vector3 = P[idx[f * 3 + 2]]
		var n: Vector3 = (b - a).cross(c - a)
		var nd := n.dot(d)
		if absf(nd) < 1e-16:
			continue
		var t := n.dot(a - o) / nd
		if t < 0.0 or t > tmax:
			continue
		var p0: Vector3 = o + d * t
		var n2 := n.dot(n)
		if n2 < 1e-20:
			continue
		var u := n.dot((c - b).cross(p0 - b)) / n2
		var v := n.dot((a - c).cross(p0 - c)) / n2
		if u >= -1e-5 and v >= -1e-5 and u + v <= 1.0 + 1e-5:
			return true
	return false


func _flaps_block(vf, o: Vector3, d: Vector3, tmax: float) -> bool:
	var am: ArrayMesh = vf.flaps_mi.mesh
	for si in 2:
		var idx: PackedInt32Array = am.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
		if _ray_hits_tris(vf.side_positions(si), idx, o, d, tmax):
			return true
	return false


func _check_vulva() -> void:
	var rig := _organ_rig()
	var vf = rig.call("vulva_flaps")
	_ok(vf != null and vf.ok, "vulva skin split into flaps")
	if vf == null:
		return
	var mi: MeshInstance3D = vf.flaps_mi
	var am: ArrayMesh = mi.mesh
	_ok(am.get_surface_count() == 2 and am.surface_get_name(0) == "VulvaLeft" and am.surface_get_name(1) == "VulvaRight", "left / right labia are separate surfaces")
	_ok(int(vf.removed_faces) > 40 and int(vf.slit_verts) >= 4 and mi.skin != null and mi.get_surface_override_material(0) != null, "flaps cut from the body skin (%d faces, slit %d verts), same skin + material" % [int(vf.removed_faces), int(vf.slit_verts)])
	var h0: Array = vf.hinge(1)
	var h1: Array = vf.hinge(-1)
	_ok((h0[0] as Vector3).x > 0.01 and (h1[0] as Vector3).x < -0.01, "each flap has its own hinge (x %.0f / %.0f mm)" % [(h0[0] as Vector3).x * 1000.0, (h1[0] as Vector3).x * 1000.0])
	# 默认合拢：两瓣中线重合、和原皮肤一模一样
	_ok(float(vf.spread()) == 0.0 and float(vf.gap_width()) < 1e-5, "default: closed, unchanged (gap %.3f mm)" % (float(vf.gap_width()) * 1000.0))
	# 皮肤原本就有一道外阴裂隙（中线约 ±2.5mm 无面）。按 1mm 网格从下往上打射线，统计没被皮瓣挡住的格子。
	var op: Vector3 = vf.canal_opening()
	var o := Vector3(0.0, op.y - 0.06, op.z)
	var open_cells := func() -> int:
		var n := 0
		for ix in range(-8, 9):
			for iz in range(-6, 7):
				if not _flaps_block(vf, Vector3(ix * 0.001 + 0.0003, op.y - 0.06, op.z + iz * 0.001), Vector3.UP, 0.08):
					n += 1
		return n
	var c0: int = open_cells.call()
	rig.call("set_vulva_spread", 1.0)
	var c1: int = open_cells.call()
	_ok(float(rig.call("vulva_spread")) == 1.0 and float(vf.gap_width()) > 0.006, "set_vulva_spread(1) parts the labia (slit edges %.1f mm apart)" % (float(vf.gap_width()) * 1000.0))
	_ok(c1 >= c0 * 2 and c1 >= 40, "spreading exposes the canal entrance (open area %d -> %d mm²)" % [c0, c1])
	var V := _organ_verts("vagin")
	var reach := false
	for p in V:
		if Vector2(p.x - o.x, p.z - o.z).length() < 0.004 and p.y < op.y + 0.01:
			reach = true
			break
	_ok(reach, "canal mouth sits right behind the opening")
	rig.call("set_vulva_spread", 0.0)
	_ok(float(vf.gap_width()) < 1e-5 and int(open_cells.call()) == c0, "closing again restores the skin exactly")


func _open_wound() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	_ok(_straight(c + Vector3(-0.06, 0.0, 0.0), c + Vector3(0.06, 0.004, 0.0)), "forceps: straight cut")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "forceps: ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "forceps: flap peeled")
	await _phys(4)


func _check_forceps_modes() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	await _frames(2)
	var bp: Button = hud.get("_btn_fc_pull")
	var bb: Button = hud.get("_btn_fc_back")
	_ok(bp != null and bb != null and bp.text == "扯出" and bb.text == "放回" and bp.visible and bb.visible, "HUD shows 「扯出」/「放回」 for the forceps")
	_ok(str(s.get("forceps_mode")) == "pull" and bp.button_pressed and not bb.button_pressed, "default forceps mode is 扯出")
	var hc := _hole_center()
	_ok(_begin_cavity_gut(hc + Vector3(0, 0.3, 0), Vector3.DOWN), "扯出: clamp gut in the cavity")
	await _frames(14)
	var rope: Node = (s.call("gut_ropes") as Array)[0]
	var tip0: Vector3 = rope.get("hold_pos")
	for i in 40:
		s.call("debug_forceps_drag_to", tip0 + Vector3(0.12, 0.1, 0.02) * (float(i + 1) / 40.0))
		await process_frame
	# 8. 阻尼：钳尖来回猛甩，节长不超过 1.05 倍
	var far: Vector3 = rope.get("hold_pos")
	var worst := 1.0
	for i in 30:
		var off := Vector3(0.05 if i % 2 == 0 else -0.05, 0.0, 0.03 if i % 4 < 2 else -0.03)
		s.call("debug_forceps_drag_to", far + off)
		await process_frame
		worst = maxf(worst, float(rope.get("last_max_stretch")))
	_ok(worst <= 1.06, "jerking the forceps: segments stretch at most %.3f× (limit 1.05 + solver tolerance)" % worst)
	s.call("debug_forceps_drag_to", far)
	s.call("debug_forceps_end")
	await _frames(90)
	# 抖动 = 逐帧来回（二阶差分），蠕动带来的缓慢移动不算
	var hist: Array = []
	for f in 12:
		hist.append((rope.call("points") as PackedVector3Array).duplicate())
		await process_frame
	var jit := 0.0
	for f in range(1, hist.size() - 1):
		var a0: PackedVector3Array = hist[f - 1]
		var a1: PackedVector3Array = hist[f]
		var a2: PackedVector3Array = hist[f + 1]
		for i in mini(a0.size(), mini(a1.size(), a2.size())):
			jit = maxf(jit, (a2[i] - a1[i] * 2.0 + a0[i]).length())
	_ok(not bool(rope.get("retracting")) and bool(s.call("has_exposed_guts")), "扯出 mode: released loop stays outside")
	_ok(jit < 0.003, "damped: no frame-to-frame jitter at rest (max %.2f mm)" % (jit * 1000.0))
	# 9. 放回
	bb.emit_signal("pressed")
	await _frames(1)
	_ok(str(s.get("forceps_mode")) == "putback" and bb.button_pressed and not bp.button_pressed, "「放回」 button switches the forceps mode")
	var n_before := int(s.call("gut_pull_count"))
	var in_hc := _hole_center()
	var aim2 := _aim_cavity_gut(in_hc + Vector3(0.008, 0.3, 0.0), Vector3.DOWN)
	var kinds := PackedStringArray(["small_intestine", "colon"])
	var got_new := bool(s.call("debug_forceps_begin_kind", aim2[0], aim2[1], kinds)) and int(s.call("gut_pull_count")) > n_before
	if bool(s.get("_fc_active")):
		s.call("debug_forceps_end")
	_ok(not got_new, "放回 mode never pulls a new loop out")
	await _frames(3)
	# 先在远处松手：不缩回
	var pts: PackedVector3Array = rope.call("points")
	var r := rope.call("outside_range") as Vector2i
	var pk := pts[(r.x + r.y) / 2]
	_ok(bool(s.call("debug_forceps_begin", pk + Vector3(0, 0.3, 0), Vector3.DOWN)), "放回: clamp the outside loop")
	s.call("debug_forceps_drag_to", pk + Vector3(0.03, 0.04, 0))
	s.call("debug_forceps_end")
	await _frames(3)
	_ok(not bool(rope.get("retracting")), "released far from the wound anchor: no put-back")
	# 拖到创口锚点附近松手：约 1 秒内一节节缩回、然后删除
	pts = rope.call("points")
	r = rope.call("outside_range") as Vector2i
	pk = pts[(r.x + r.y) / 2]
	_ok(bool(s.call("debug_forceps_begin", pk + Vector3(0, 0.3, 0), Vector3.DOWN)), "放回: clamp again")
	var anc: Vector3 = s.call("gut_wound_anchor", rope)
	var hp: Vector3 = rope.get("hold_pos")
	for i in 20:
		s.call("debug_forceps_drag_to", hp.lerp(anc + Vector3(0, 0.02, 0), float(i + 1) / 20.0))
		await process_frame
	var n0 := int(rope.call("point_count"))
	var f0 := float(rope.get("fed_len"))
	var t0 := Time.get_ticks_msec()
	s.call("debug_forceps_end")
	_ok(bool(rope.get("retracting")), "released near the wound anchor (%.0f mm): loop starts going back in" % ((rope.get("hold_pos") as Vector3).distance_to(anc) * 1000.0))
	while Time.get_ticks_msec() - t0 < 500:
		await process_frame
	var n1 := int(rope.call("point_count")) if is_instance_valid(rope) else 0
	var f1 := float(rope.get("fed_len")) if is_instance_valid(rope) else 0.0
	_ok(n1 < n0 - 3 and f1 < f0 * 0.75, "retracts segment by segment (%d -> %d points, %.0f -> %.0f mm)" % [n0, n1, f0 * 1000.0, f1 * 1000.0])
	while Time.get_ticks_msec() - t0 < 3000 and int(s.call("gut_pull_count")) >= n_before:
		await process_frame
	var el := float(Time.get_ticks_msec() - t0) / 1000.0
	_ok(int(s.call("gut_pull_count")) == n_before - 1 and int(s.get("gut_putbacks_done")) == 1 and el > 0.7 and el < 1.6, "fully inserted loop is removed (%.2f s after release)" % el)
	s.call("set_forceps_mode", "pull")
	s.call("restore_body")
	await _frames(3)


func _check_retractor_hook_out() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "retr-out: straight cut")
	var outer: Geom.MeshData = s.get("_outer")
	var left: PackedInt32Array = s.get("_lip_left")
	s.call("set_tool", "retractor")
	_ok(bool(s.call("place_retractor", left[left.size() / 2])), "retr-out: placed")
	await _frames(2)
	var r0: Node3D = (s.call("retractor_nodes") as Array)[0]
	var vid: int = (s.get("_retractors") as Array)[0]["vid"]
	var skel: Skeleton3D = s.get("_skel")
	var sk: Skin = s.get("_skin")
	var lw: Vector3 = skel.global_transform * Geom.skin_vertex(outer.pos[vid], vid, outer, skel, sk)
	var nw: Vector3 = (skel.global_transform * Geom.skin_vertex(outer.pos[vid] + outer.nrm[vid].normalized() * 0.01, vid, outer, skel, sk) - lw).normalized()
	var hook: Vector3 = r0.global_transform * Vector3(0, -0.0148, 0.066)
	var far_end: Vector3 = r0.global_transform * Vector3(0, -0.0148, -0.074)
	var out := (hook - lw).dot(nw)
	var tilt := rad_to_deg(asin(clampf((far_end - hook).normalized().dot(nw), -1.0, 1.0)))
	_ok(out > 0.0025 and out < 0.008, "hook contact sits %.1f mm outside the skin (a few mm out, no longer buried)" % (out * 1000.0))
	_ok(hook.distance_to(lw) < 0.007, "hook still holds the cut face (%.1f mm from the lip)" % (hook.distance_to(lw) * 1000.0))
	_ok(tilt > 10.0, "14° outward tilt is kept (%.0f°)" % tilt)
	s.call("restore_body")
	await _frames(2)
