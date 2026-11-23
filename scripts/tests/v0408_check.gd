extends "res://scripts/tests/v0407_check.gd"
## 0.4.08 自检：载具里驾驶员与载具刚性同步（无闪烁 / 拖影）、载具里乳摇 / 外露肠管不受载具惯性、
## 第一人称镜头不切进脖子（奔跑 / 驾驶）、外阴—前庭—阴道—宫颈—子宫连接、子宫前移、检查床「掰开小穴」。
##   godot --headless --path . -s res://scripts/tests/v0408_check.gd
##   （V0408_ONLY=model|uterus|tubes|seat|inertia|rope|fp|action）


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
	_ok(presets.find("version/name=\"0.4.08\"") >= 0 and presets.find("version/code=51") >= 0, "export version 0.4.08 / 51")
	var only := OS.get_environment("V0408_ONLY")
	if only == "" or only == "model":
		_check_repro_model()
	if only == "" or only == "uterus":
		_check_uterus_forward()
	if only == "" or only == "tubes":
		_check_tubes()
	if only == "" or only == "rope":
		await _check_rope_carry()
	if only == "" or only == "fp":
		await _check_fp_run_neck()
	if only == "" or only in ["seat", "inertia"]:
		for kind in ["car", "plane"]:
			await _check_seat_sync(kind)
	if only == "" or only == "action":
		await _check_spread_action()
	print("v0408_check: fails=", fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------ 4. 外阴 / 阴道 / 子宫连接

func _organ_mesh(pat: String) -> Array:
	var out: Array = []
	for mi in _organ_rig().get("organ_meshes"):
		var m := mi as MeshInstance3D
		if str(m.get_meta("organ_material", "")).to_lower().find(pat) >= 0:
			out.append(m)
	return out


func _tri_dist(p: Vector3, P: PackedVector3Array, idx: PackedInt32Array) -> float:
	var best := INF
	for f in idx.size() / 3:
		var a := P[idx[f * 3]]
		var b := P[idx[f * 3 + 1]]
		var c := P[idx[f * 3 + 2]]
		var q := Geometry3D.get_closest_point_to_segment(p, a, b)
		best = minf(best, p.distance_to(q))
		q = Geometry3D.get_closest_point_to_segment(p, b, c)
		best = minf(best, p.distance_to(q))
		q = Geometry3D.get_closest_point_to_segment(p, c, a)
		best = minf(best, p.distance_to(q))
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-14:
			continue
		n = n.normalized()
		var proj := p - n * (p - a).dot(n)
		var bc := Geometry3D.get_triangle_barycentric_coords(proj, a, b, c) if Geometry3D.has_method("get_triangle_barycentric_coords") else Vector3(-1, -1, -1)
		if bc.x >= 0.0 and bc.y >= 0.0 and bc.z >= 0.0:
			best = minf(best, absf((p - a).dot(n)))
	return best


## Geometry3D.ray_intersects_triangle 把 |det| < 1e-5 当平行（毫米级小三角形会被漏掉）→ 放大 100 倍再测。
func _ray_hits_small(P: PackedVector3Array, idx: PackedInt32Array, o: Vector3, d: Vector3, tmax: float) -> bool:
	var k := 100.0
	for f in idx.size() / 3:
		var hit = Geometry3D.ray_intersects_triangle(o * k, d, P[idx[f * 3]] * k, P[idx[f * 3 + 1]] * k, P[idx[f * 3 + 2]] * k)
		if hit != null and (hit as Vector3).distance_to(o * k) < tmax * k:
			return true
	return false


func _flaps_block_small(vf, o: Vector3, d: Vector3, tmax: float) -> bool:
	var am: ArrayMesh = vf.flaps_mi.mesh
	for si in 2:
		var idx: PackedInt32Array = am.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
		if _ray_hits_small(vf.side_positions(si), idx, o, d, tmax):
			return true
	return false


func _min_vdist(A: PackedVector3Array, B: PackedVector3Array, step_a: int = 1) -> float:
	var d := INF
	for i in range(0, A.size(), step_a):
		for q in B:
			d = minf(d, A[i].distance_squared_to(q))
	return sqrt(d)


## 每个网格：顶点法线朝外（相对 c 或相对轴）占比、三角形绕向与顶点法线一致（Godot 正面 = 顺时针）占比
func _normal_stats(m: MeshInstance3D, axis_o: Vector3, axis_d: Vector3) -> Vector2:
	var arr := m.mesh.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var c := Vector3.ZERO
	for p in P:
		c += p
	c /= float(P.size())
	var out := 0
	for i in P.size():
		var r := P[i] - c
		if axis_d != Vector3.ZERO:
			var t := (P[i] - axis_o).dot(axis_d)
			r = P[i] - axis_o - axis_d * t
		if N[i].dot(r) > 0.0:
			out += 1
	var agree := 0
	for f in I.size() / 3:
		var a := P[I[f * 3]]
		var b := P[I[f * 3 + 1]]
		var cc := P[I[f * 3 + 2]]
		var fn := (b - a).cross(cc - a)
		var vn := N[I[f * 3]] + N[I[f * 3 + 1]] + N[I[f * 3 + 2]]
		if fn.dot(vn) < 0.0:
			agree += 1
	return Vector2(float(out) / float(P.size()), float(agree) / float(maxi(1, I.size() / 3)))


func _check_repro_model() -> void:
	var rig := _organ_rig()
	var meta: Dictionary = rig.get("meta")
	var vg: Dictionary = meta.get("vagina", {})
	_ok(not vg.is_empty() and (vg.get("mouth_loop", []) as Array).size() >= 6, "meta: canal mouth loop recorded (%d pts)" % (vg.get("mouth_loop", []) as Array).size())
	var cx: Array = vg["cervix"]
	var op: Array = vg["opening"]
	var vs_: Array = vg["vulva_skin"]
	var cervix := Vector3(cx[0], cx[1], cx[2])
	var opening := Vector3(op[0], op[1], op[2])
	var vul := Vector3(vs_[0], vs_[1], vs_[2])
	var vf = rig.call("vulva_flaps")
	_ok(vf != null and vf.ok, "vulva flaps built")
	if vf == null:
		return
	# 外阴裂隙：中线顶点的 z 范围
	var rim0: PackedVector3Array = vf.rim_positions()
	var zr := Vector2(INF, -INF)
	for p in rim0:
		zr = Vector2(minf(zr.x, p.z), maxf(zr.y, p.z))
	var ml: PackedVector3Array = vf.mouth_loop()
	var mc := Vector3.ZERO
	var mx := 0.0
	for p in ml:
		mc += p
		mx = maxf(mx, absf(p.x))
	mc /= float(maxi(1, ml.size()))
	_ok(int(vf.rim_size()) >= 10 and zr.y - zr.x > 0.04, "slit rim is one closed loop along the whole cleft (%d verts, %.0f mm long)" % [int(vf.rim_size()), (zr.y - zr.x) * 1000.0])
	_ok(mc.distance_to(opening) < 0.004 and mc.z > zr.x and mc.z < zr.y and mx < 0.009, "canal end (mouth centre %.1f mm from the vulva opening) lies inside the cleft, within ±%.1f mm of the midline" % [mc.distance_to(opening) * 1000.0, mx * 1000.0])
	_ok(opening.distance_to(vul) < 0.009 and opening.y > vul.y, "opening %.1f mm inside the skin vulva point" % (opening.distance_to(vul) * 1000.0))
	# 前庭：第一行与皮瓣开口边缘重合、最后一行在通道外口那一圈上（合拢 / 半开 / 全开）
	var worst_top := 0.0
	var worst_bot := 0.0
	for sp in [0.0, 0.5, 1.0]:
		rig.call("set_vulva_spread", sp)
		var V: PackedVector3Array = vf.vestibule_positions()
		var rim: PackedVector3Array = vf.rim_positions()
		var n: int = vf.VEST_N
		for k in n:
			var best := INF
			for i in rim.size():
				best = minf(best, V[k].distance_to(Geometry3D.get_closest_point_to_segment(V[k], rim[i], rim[(i + 1) % rim.size()])))
			worst_top = maxf(worst_top, best)
			var vb := V[V.size() - n + k]
			var bm := INF
			for i in ml.size():
				bm = minf(bm, vb.distance_to(Geometry3D.get_closest_point_to_segment(vb, ml[i], ml[(i + 1) % ml.size()])))
			worst_bot = maxf(worst_bot, bm)
	rig.call("set_vulva_spread", 0.0)
	_ok(vf.vest_mi != null and int(vf.vest_tris) > 100, "vestibule mesh between the labia and the canal (%d tris)" % int(vf.vest_tris))
	_ok(worst_top < 1e-4 and worst_bot < 1e-4, "no gap: vestibule edge on the labia rim (%.3f mm) and on the canal mouth (%.3f mm) at every spread" % [worst_top * 1000.0, worst_bot * 1000.0])
	_ok(int(vf.holes_filled) >= 1, "pre-existing pin-hole in the skin at the front commissure patched (%d tris)" % int(vf.holes_filled))
	# 宫颈 ↔ 子宫
	var ut_m: Array = _organ_mesh("uterus")
	var cv_m: Array = _organ_mesh("vagin")
	_ok(ut_m.size() == 1 and cv_m.size() == 2, "uterus + 2-layer canal meshes (mouth disc removed) (%d / %d)" % [ut_m.size(), cv_m.size()])
	var UA := (ut_m[0] as MeshInstance3D).mesh.surface_get_arrays(0)
	var UP: PackedVector3Array = UA[Mesh.ARRAY_VERTEX]
	var UI: PackedInt32Array = UA[Mesh.ARRAY_INDEX]
	var ub := _box(UP)
	var CV := PackedVector3Array()
	for m in cv_m:
		CV.append_array((m as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	var top_y := -INF
	var bot_y := INF
	for p in CV:
		top_y = maxf(top_y, p.y)
		bot_y = minf(bot_y, p.y)
	var gap := 0.0
	var n_top := 0
	for p in CV:
		if p.y > top_y - 0.004:
			gap = maxf(gap, _tri_dist(p, UP, UI))
			n_top += 1
	_ok(n_top > 6 and gap < 0.004, "cervix end of the canal sits on the uterus surface (worst %.1f mm, %d verts)" % [gap * 1000.0, n_top])
	_ok(ub.grow(0.004).has_point(cervix) and absf(cervix.y - ub.position.y) < 0.006, "cervix point at the bottom of the uterus (%.1f mm above its lowest point)" % ((cervix.y - ub.position.y) * 1000.0))
	_ok(absf(bot_y - opening.y) < 0.004, "canal outer end reaches the opening height (%.1f mm)" % ((bot_y - opening.y) * 1000.0))
	# 法线 / 绕向
	var ax: Array = vg.get("axis", [0, -1, 0])
	var axd := Vector3(ax[0], ax[1], ax[2]).normalized()
	var st_u := _normal_stats(ut_m[0], Vector3.ZERO, Vector3.ZERO)
	_ok(st_u.x > 0.85 and st_u.y > 0.95, "uterus normals outward %.0f%%, winding consistent %.0f%%" % [st_u.x * 100.0, st_u.y * 100.0])
	var bl_m: Array = _organ_mesh("vessie")
	var st_b := _normal_stats(bl_m[0], Vector3.ZERO, Vector3.ZERO)
	_ok(st_b.x > 0.85 and st_b.y > 0.95, "bladder normals outward %.0f%%, winding consistent %.0f%%" % [st_b.x * 100.0, st_b.y * 100.0])
	var layers := []
	for m in cv_m:
		layers.append(_normal_stats(m, cervix, axd))
	layers.sort_custom(func(a, b): return a.x < b.x)
	_ok((layers[0] as Vector2).x < 0.3 and (layers[1] as Vector2).x > 0.85 and (layers[0] as Vector2).y > 0.95 and (layers[1] as Vector2).y > 0.95, "canal: inner lining faces the lumen (%.0f%% outward), outer wall faces out (%.0f%%), winding consistent" % [(layers[0] as Vector2).x * 100.0, (layers[1] as Vector2).x * 100.0])
	# 透过张开的裂隙往里看：要么看到前庭 / 通道黏膜，要么被皮瓣挡住，不应看穿进身体
	rig.call("set_vulva_spread", 1.0)
	var VP: PackedVector3Array = vf.vestibule_positions()
	var VI: PackedInt32Array = vf._vest_am.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var open := 0
	var seen := 0
	var into_canal := 0
	for ix in range(-6, 7):
		for iz in range(-14, 15):
			var o := Vector3(ix * 0.001 + 0.0003, vul.y - 0.05, mc.z + iz * 0.0015)
			if _flaps_block_small(vf, o, Vector3.UP, 0.08):
				continue
			open += 1
			if _ray_hits_small(VP, VI, o, Vector3.UP, 0.08):
				seen += 1
			else:
				for m in cv_m:
					var ca := (m as MeshInstance3D).mesh.surface_get_arrays(0)
					if _ray_hits_small(ca[Mesh.ARRAY_VERTEX], ca[Mesh.ARRAY_INDEX], o, Vector3.UP, 0.12):
						seen += 1
						into_canal += 1
						break
	rig.call("set_vulva_spread", 0.0)
	_ok(open > 20 and float(seen) >= float(open) * 0.99 and into_canal > 0, "spread open: every ray through the cleft lands on vestibule mucosa or, through the open mouth, on the canal lining (%d / %d, %d into the canal)" % [seen, open, into_canal])


# ------------------------------------------------------------------ 5. 子宫前移

func _check_uterus_forward() -> void:
	var rig := _organ_rig()
	var meta: Dictionary = rig.get("meta")
	var mv: Array = meta.get("uterus_move", [])
	_ok(mv.size() == 3 and is_equal_approx(float(mv[2]), 0.0), "uterus z-shift now 0 (0.4.07: -12 mm) → 12 mm toward the belly (%s)" % [mv])
	var ut := _box(_organ_verts("uterus"))
	var bl := _box(_organ_verts("vessie"))
	_ok(absf(ut.position.z - 0.0162) < 0.0015 and absf(ut.end.z - 0.0714) < 0.0015 and absf(ut.position.y - 0.9331) < 0.002, "uterus box z %.4f..%.4f (0.4.07: 0.0042..0.0594), height unchanged" % [ut.position.z, ut.end.z])
	_ok(absf(bl.position.y - 0.8791) < 0.001 and absf(bl.position.z - 0.0475) < 0.001 and absf(bl.end.z - 0.0836) < 0.001, "bladder untouched (y %.4f z %.4f..%.4f)" % [bl.position.y, bl.position.z, bl.end.z])
	var U := _organ_verts("uterus")
	var B := _organ_verts("vessie")
	var C := _organ_verts("vagin")
	var dub := _min_vdist(U, B, 2)
	var dcb := _min_vdist(C, B)
	_ok(dub > 0.005, "uterus clears the bladder (%.1f mm)" % (dub * 1000.0))
	_ok(dcb > 0.002, "re-anchored canal clears the bladder (%.1f mm)" % (dcb * 1000.0))
	# 腹壁：前表面轮廓往内 12mm（与肠团同一腹壁厚度）
	var prof: Dictionary = meta["profile"]
	var ys: Array = prof["y"]
	var zs: Array = prof["z_front"]
	var worst := INF
	for p in U:
		var zf := float(zs[0])
		for i in range(1, ys.size()):
			if p.y <= float(ys[i]):
				zf = lerpf(float(zs[i - 1]), float(zs[i]), (p.y - float(ys[i - 1])) / maxf(float(ys[i]) - float(ys[i - 1]), 1e-6))
				break
		worst = minf(worst, zf - 0.012 - p.z)
	_ok(worst > 0.01, "uterus stays behind the anterior abdominal wall (min %.1f mm)" % (worst * 1000.0))
	var vg: Dictionary = meta["vagina"]
	_ok(float(vg["skin_clearance"]) > 0.0005 and float(vg.get("bow", 0.0)) > 0.0, "canal re-anchored to the moved cervix, bowed %.1f mm dorsally, mouth stays inside the skin (%.1f mm)" % [float(vg.get("bow", 0.0)) * 1000.0, float(vg["skin_clearance"]) * 1000.0])


# ------------------------------------------------------------------ 7. 输卵管接子宫角

func _mesh_arrays(pat: String) -> Array:
	var P := PackedVector3Array()
	var I := PackedInt32Array()
	for m in _organ_mesh(pat):
		var a: Array = (m as MeshInstance3D).mesh.surface_get_arrays(0)
		var base := P.size()
		P.append_array(a[Mesh.ARRAY_VERTEX])
		for i in (a[Mesh.ARRAY_INDEX] as PackedInt32Array):
			I.append(base + i)
	return [P, I]


func _check_tubes() -> void:
	var meta: Dictionary = _organ_rig().get("meta")
	var tubes: Array = meta.get("tubes", []) if meta.get("tubes") != null else []
	_ok(tubes.size() == 2, "meta lists two tube–uterus junctions (%d)" % tubes.size())
	if tubes.size() != 2:
		return
	var ua := _mesh_arrays("uterus")
	var ta := _mesh_arrays("trompe")
	var UP: PackedVector3Array = ua[0]
	var UI: PackedInt32Array = ua[1]
	var TP: PackedVector3Array = ta[0]
	var TI: PackedInt32Array = ta[1]
	# 焊接（导出按 UV / 法线拆了顶点），统计子宫 + 两条输卵管合起来的边使用次数
	var key := func(v: Vector3) -> Vector3i: return Vector3i(roundi(v.x * 2e5), roundi(v.y * 2e5), roundi(v.z * 2e5))
	var edges := {}
	var dir_dup := 0
	var add_tris := func(P: PackedVector3Array, I: PackedInt32Array) -> void:
		for f in I.size() / 3:
			for k in 3:
				var a: Vector3i = key.call(P[I[f * 3 + k]])
				var b: Vector3i = key.call(P[I[f * 3 + (k + 1) % 3]])
				var dk := [a, b]
				edges[dk] = int(edges.get(dk, 0)) + 1
	add_tris.call(UP, UI)
	add_tris.call(TP, TI)
	var open_near := 0
	var non_manifold := 0
	var seen := {}
	for dk in edges.keys():
		var a: Vector3i = dk[0]
		var b: Vector3i = dk[1]
		if int(edges[dk]) > 1:
			dir_dup += 1
		var uk := [a, b] if (a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z <= b.z)))) else [b, a]
		if seen.has(uk):
			continue
		seen[uk] = true
		var c := int(edges.get([a, b], 0)) + int(edges.get([b, a], 0))
		if c > 2:
			non_manifold += 1
		elif c == 1:
			var mid := (Vector3(a) + Vector3(b)) / 4e5
			for t in tubes:
				var h: Array = (t as Dictionary)["horn"]
				if mid.distance_to(Vector3(h[0], h[1], h[2])) < 0.015:
					open_near += 1
	_ok(open_near == 0 and non_manifold == 0, "uterus + tubes are one closed surface at the horns (open edges within 15 mm: %d, non-manifold: %d)" % [open_near, non_manifold])
	_ok(dir_dup == 0, "consistent winding across the junction (same-direction shared edges: %d)" % dir_dup)
	for t in tubes:
		var d: Dictionary = t
		var hv: Array = d["horn"]
		var nv: Array = d["normal"]
		var av: Array = d["axis"]
		var horn := Vector3(hv[0], hv[1], hv[2])
		var n := Vector3(nv[0], nv[1], nv[2]).normalized()
		var ax := Vector3(av[0], av[1], av[2]).normalized()
		var bl: Array = d["base_loop"]
		# 子宫壁（去掉接缝拉链三角：含管根顶点的三角）
		var bkeys := {}
		for q in bl:
			bkeys[key.call(Vector3(q[0], q[1], q[2]))] = true
		var WI := PackedInt32Array()
		for f in UI.size() / 3:
			if bkeys.has(key.call(UP[UI[f * 3]])) or bkeys.has(key.call(UP[UI[f * 3 + 1]])) or bkeys.has(key.call(UP[UI[f * 3 + 2]])):
				continue
			WI.append(UI[f * 3]); WI.append(UI[f * 3 + 1]); WI.append(UI[f * 3 + 2])
		var worst_surf := 0.0
		var worst_tube := 0.0
		var c := Vector3.ZERO
		for q in bl:
			var p := Vector3(q[0], q[1], q[2])
			c += p
			# 管根顶点：离子宫表面（去掉开口后剩下的壁 + 开口边）≤ 2 mm，且确实是输卵管网格的顶点
			worst_surf = maxf(worst_surf, _tri_dist(p, UP, WI))
			var bt := INF
			for tp in TP:
				bt = minf(bt, tp.distance_to(p))
			worst_tube = maxf(worst_tube, bt)
		c /= float(bl.size())
		var side := "L" if horn.x > 0.0 else "R"
		_ok(worst_surf < 0.002 and worst_tube < 0.0002, "%s tube base vertices sit on the uterine horn (≤ %.2f mm from the uterine wall, tube vertex match %.3f mm)" % [side, worst_surf * 1000.0, worst_tube * 1000.0])
		# 管腔：子宫腔内（角内 4 mm）→ 输卵管内 6 mm 的射线不穿过任何壁
		var o := c - n * 0.004
		var e := c + ax * 0.006
		var dirv := (e - o).normalized()
		var L := o.distance_to(e)
		var blocked: bool = _ray_hits_small(UP, UI, o, dirv, L) or _ray_hits_small(TP, TI, o, dirv, L)
		_ok(not blocked, "%s uterine cavity opens into the tube lumen (ray %.1f mm through the junction, flare r %.1f → %.1f mm)" % [side, L * 1000.0, float(d["base_radius"]) * 1000.0, float(d["hole_radius"]) * 1000.0])
	var mv: Array = meta.get("uterus_move", [0, 0, 0])
	_ok(float(mv[1]) > 0.0 and tubes.size() == 2, "junction baked after the 12 mm forward move (uterus_move %s)" % [mv])


# ------------------------------------------------------------------ 2b. 外露肠管：载体搬运

func _check_rope_carry() -> void:
	var RopeScript: GDScript = load("res://scripts/surgery/gut_rope.gd")
	var dev := []
	for use_carry in [true, false]:
		var r: MeshInstance3D = RopeScript.new()
		main.add_child(r)
		var base := Vector3(5.0, 1.0, 5.0)
		var a := Vector3(-0.02, 0.0, 0.0)
		var b := Vector3(0.02, 0.0, 0.0)
		r.set("fed_len", 0.3)
		var setp := func(off: Transform3D) -> void:
			r.set("anchor_a", off * (base + a))
			r.set("anchor_b", off * (base + b))
			r.set("exit_a", off * (base + a + Vector3(0, 0, 0.02)))
			r.set("exit_b", off * (base + b + Vector3(0, 0, 0.02)))
			r.set("mes_root", off * (base + Vector3(0, 0, -0.03)))
		setp.call(Transform3D.IDENTITY)
		for i in 150:
			r.call("step", 1.0 / 60.0)
		var rest: PackedVector3Array = (r.call("points") as PackedVector3Array).duplicate()
		var xf := Transform3D.IDENTITY
		var v := 0.0
		var yaw := 0.0
		var worst := 0.0
		for i in 90:
			var dt := 1.0 / 60.0
			v = minf(40.0, v + 25.0 * dt)
			yaw += 0.6 * dt
			var nx := Transform3D(Basis(Vector3.UP, yaw), xf.origin + Basis(Vector3.UP, yaw) * Vector3(0, 0, -v * dt))
			var d := nx * xf.affine_inverse()
			xf = nx
			setp.call(xf)
			if use_carry:
				r.call("carry", d)
				r.set("gravity", Vector3(0, -9.8, 0))
			r.call("step", dt)
			var pts: PackedVector3Array = r.call("points")
			for k in pts.size():
				worst = maxf(worst, (xf.affine_inverse() * pts[k]).distance_to(rest[k]))
		dev.append(worst)
		r.queue_free()
	_ok(float(dev[0]) < 0.01 and float(dev[1]) > float(dev[0]) * 5.0, "exposed gut loop carried in the vehicle frame: max drift %.1f mm while accelerating to 40 m/s and turning (world-frame sim would drift %.0f mm)" % [float(dev[0]) * 1000.0, float(dev[1]) * 1000.0])


# ------------------------------------------------------------------ 3. 第一人称奔跑不切进脖子

func _check_fp_run_neck() -> void:
	player.call("force_stance", "stand")
	await main.call("switch_map", "city", 4)
	await _frames(10)
	player.call("set_play_mode", 1)
	player.set("_pitch", -0.6)
	var skel: Skeleton3D = player.call("get_skeleton")
	var worst := {"neck_ahead": 9.0, "chest_dist": 9.0, "head_dist": 9.0}
	Input.action_press("move_forward")
	Input.action_press("sprint")
	for i in 70:
		await physics_frame
		if i > 30:
			_fp_probe(skel, worst)
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	Input.action_release("jump")
	for i in 40:
		await physics_frame
		_fp_probe(skel, worst)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_ok(float(worst["neck_ahead"]) >= 0.06 and float(worst["head_dist"]) >= 0.06 and float(worst["chest_dist"]) >= 0.2, "FP camera stays in front of the neck while sprinting / jumping (neck %.0f mm, head %.0f mm, chest %.0f mm; push %.0f mm)" % [float(worst["neck_ahead"]) * 1000.0, float(worst["head_dist"]) * 1000.0, float(worst["chest_dist"]) * 1000.0, float(player.get("fp_neck_push")) * 1000.0])
	player.call("set_play_mode", 0)
	await main.call("switch_map", "room", 0)
	await _frames(4)


func _fp_probe(skel: Skeleton3D, worst: Dictionary) -> void:
	var cam: Vector3 = player.call("get_camera").global_position
	var fwd: Vector3 = player.get_node("Body").global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	var neck := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("C_Neck_a")).origin
	var head := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("C_Head_a")).origin
	var chest := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("C_Spine_d")).origin
	worst["neck_ahead"] = minf(float(worst["neck_ahead"]), (cam - neck).dot(fwd))
	worst["chest_dist"] = minf(float(worst["chest_dist"]), cam.distance_to(chest))
	worst["head_dist"] = minf(float(worst["head_dist"]), cam.distance_to(head))


# ------------------------------------------------------------------ 1 + 2. 载具里刚性同步、乳摇无惯性

const PROBE_SRC := """extends Node
var veh: Node3D
var skel: Skeleton3D
var ref_hip := Vector3.ZERO
var ref_set := false
var worst := 0.0
var n := 0
var br: Object
var br_worst := 0.0
var br_ref := []
func _process(_d):
	if veh == null or skel == null:
		return
	var vx: Transform3D = veh.get_global_transform_interpolated()
	var hi := skel.find_bone("C_Hip_a")
	var hip: Vector3 = vx.affine_inverse() * (skel.global_transform * skel.get_bone_global_pose(hi).origin)
	if not ref_set:
		ref_hip = hip
		ref_set = true
	worst = maxf(worst, hip.distance_to(ref_hip))
	n += 1
	if br:
		var k := 0
		for bn in ["L_Breast_a_Phy", "R_Breast_a_Phy"]:
			var bi := skel.find_bone(bn)
			if bi < 0:
				continue
			var d: Vector3 = skel.get_bone_pose_position(bi)
			if br_ref.size() <= k:
				br_ref.append(d)
			br_worst = maxf(br_worst, d.distance_to(br_ref[k]))
			k += 1
"""


func _drive(v: Node3D, kind: String, vmax: float) -> void:
	# 载具在物理帧里移动：从静止猛加速到 vmax，同时转向（战斗机再加侧倾）。
	var vel := 0.0
	var yaw := 0.0
	var roll := 0.0
	var b0 := v.global_transform.basis.orthonormalized()
	for i in 150:
		await physics_frame
		var dt := 1.0 / float(Engine.physics_ticks_per_second)
		vel = minf(vmax, vel + vmax * 1.5 * dt)
		yaw += 0.5 * dt
		roll = 0.25 * sin(float(i) * 0.08) if kind == "plane" else 0.0
		var b := Basis(Vector3.UP, yaw) * b0 * Basis(Vector3.FORWARD, roll)
		v.global_transform = Transform3D(b, v.global_position + b * Vector3(0, 0, -vel * dt))
	for i in 3:
		await process_frame


func _check_seat_sync(kind: String) -> void:
	var v: Node3D = load("res://scenes/vehicles/%s.tscn" % kind).instantiate()
	main.add_child(v)
	var at := Vector3(1.6, 0.6, 0.2) if kind == "car" else Vector3(40.0, 3.0, 40.0)
	v.global_position = at
	if v.has_method("spawn_lift") and kind == "car":
		v.global_position.y = float(v.call("spawn_lift"))
	if v is RigidBody3D:
		(v as RigidBody3D).freeze = true
	await _phys(3)
	player.call("force_stance", "stand")
	player.global_position = v.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = v
	_ok(bool(vs.call("try_enter")), "%s: enter" % kind)
	for i in 40:
		await process_frame
	await _phys(240)  # 4 s 游戏时间：上车动画结束、乳摇静止
	var occ := str(player.get("occupancy"))
	_ok(occ == kind, "%s: seated (%s)" % [kind, occ])
	var carrier = player.call("vehicle_carrier")
	_ok(carrier is Transform3D, "%s: player reports the vehicle as its carrier frame" % kind)
	var skel: Skeleton3D = player.call("get_skeleton")
	var sec: Object = player.call("get_secondary")
	var br: Object = sec.get("breasts") if sec else null
	var gd := GDScript.new()
	gd.source_code = PROBE_SRC
	gd.reload()
	var probe := Node.new()
	probe.set_script(gd)
	probe.process_priority = 1000
	probe.set("veh", v)
	probe.set("skel", skel)
	probe.set("br", br)
	main.add_child(probe)
	var f0: int = int(vs.get("seat_frames"))
	var vmax := 60.0 if kind == "car" else 120.0
	await _drive(v, kind, vmax)
	var frames := int(probe.get("n"))
	var worst := float(probe.get("worst"))
	_ok(frames > 100 and worst < 0.003, "%s: driver hip rigidly locked to the rendered (interpolated) vehicle every frame at up to %.0f m/s (max drift %.2f mm over %d frames)" % [kind, vmax, worst * 1000.0, frames])
	if kind == "car":
		vs.set("debug_seat_physics_only", true)
		await _phys(30)
		probe.set("ref_set", false)
		probe.set("worst", 0.0)
		await _drive(v, kind, vmax)
		var old_drift := float(probe.get("worst"))
		vs.set("debug_seat_physics_only", false)
		await _phys(30)
		_ok(old_drift > 0.05, "%s: control — placing the driver only in physics ticks (0.4.07) drifts %.0f mm from the rendered car" % [kind, old_drift * 1000.0])
	_ok(int(vs.get("seat_frames")) - f0 >= frames - 3, "%s: seat pose re-applied in every render frame (%d)" % [kind, int(vs.get("seat_frames")) - f0])
	if br:
		var calm := float(probe.get("br_worst"))
		var base_txt := ""
		var ok_base := true
		if kind == "car":
			# 对照组：同样的驾驶，乳摇在世界坐标系里积分（0.4.07 行为）
			vs.set("debug_world_frame_jiggle", true)
			await _phys(60)
			probe.set("br_ref", [])
			probe.set("br_worst", 0.0)
			await _drive(v, kind, vmax)
			vs.set("debug_world_frame_jiggle", false)
			var wf := float(probe.get("br_worst"))
			base_txt = ", world-frame sim would swing %.1f mm" % (wf * 1000.0)
			ok_base = wf > calm * 3.0
			await _phys(60)
		_ok(bool(br.call("is_carried")) and calm < 0.003 and ok_base, "%s: breast jiggle stays calm relative to the body under vehicle acceleration / turning (max %.2f mm%s)" % [kind, calm * 1000.0, base_txt])
	# 第一人称座舱：镜头在脖子前方
	if str(vs.get("vehicle_cam")) != "first":
		vs.call("toggle_vehicle_cam")
	await _phys(30)
	await _frames(4)
	var cam: Camera3D = get_root().get_viewport().get_camera_3d()
	var neck := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("C_Neck_a")).origin
	var nose := -v.global_transform.basis.z
	var ahead := (cam.global_position - neck).dot(nose)
	_ok(ahead > 0.06, "%s: cockpit FP camera %.0f mm in front of the driver's neck" % [kind, ahead * 1000.0])
	if str(vs.get("vehicle_cam")) == "first":
		vs.call("toggle_vehicle_cam")
	probe.queue_free()
	vs.call("_finish_exit", vs.call("_exit_stand_dest", v), true)
	await _frames(3)
	_ok(player.call("vehicle_carrier") == null and (br == null or not bool(br.get("carrier") is Transform3D)), "%s: carrier cleared on exit (on-foot jiggle back to world frame)" % kind)
	player.call("force_stance", "stand")
	v.queue_free()
	await _frames(3)


# ------------------------------------------------------------------ 6. 检查床「掰开小穴」

func _check_spread_action() -> void:
	player.call("set_play_mode", 0)
	if not await _enter_bed():
		return
	await _phys(10)
	var rig := _organ_rig()
	var vf = rig.call("vulva_flaps")
	var bs: Object = vs.get("bed_actions")
	var skel: Skeleton3D = player.call("get_skeleton")
	await _frames(2)
	_ok(bool(hud.get("debug_bed_action_visible")), "HUD shows the 动作 button on the exam bed")
	hud.call("_on_bed_action_button")
	await _frames(2)
	var labels: PackedStringArray = hud.call("debug_bed_action_labels")
	_ok(labels.has("掰开小穴"), "action list contains 掰开小穴 (%s)" % [labels])
	var lh0 := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("L_Hand_a")).origin
	var rh0 := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("R_Hand_a")).origin
	hud.call("debug_run_bed_action", "spread_vulva")
	await _phys(30)
	_ok(float(bs.get("hand_u")) > 0.3 and float(rig.call("vulva_spread")) < 0.05, "hands travel first, labia still closed (hand %.2f, spread %.2f)" % [float(bs.get("hand_u")), float(rig.call("vulva_spread"))])
	await _phys(90)
	var sp := float(rig.call("vulva_spread"))
	_ok(sp > 0.99, "then set_vulva_spread is driven to the max (%.2f)" % sp)
	var errs: Array = bs.get("last_tip_err")
	_ok(float(errs[0]) < 0.012 and float(errs[1]) < 0.012, "index / middle fingertips on the left / right labia (%.1f / %.1f mm)" % [float(errs[0]) * 1000.0, float(errs[1]) * 1000.0])
	var H: Transform3D = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("C_Hip_a")) * skel.get_bone_global_rest(skel.find_bone("C_Hip_a")).affine_inverse()
	var tips: Array = bs.get("last_tip_world")
	var cl: Array = vf.contact(0)
	var cr: Array = vf.contact(1)
	_ok((tips[0] as Vector3).distance_to(H * (cl[0] as Vector3)) < 0.015 and (tips[1] as Vector3).distance_to(H * (cr[0] as Vector3)) < 0.015, "fingertips follow the opened labia (L %.1f mm, R %.1f mm)" % [(tips[0] as Vector3).distance_to(H * (cl[0] as Vector3)) * 1000.0, (tips[1] as Vector3).distance_to(H * (cr[0] as Vector3)) * 1000.0])
	_ok(float(bs.get("last_wrist_clear")) > 0.01, "wrists rest above the lower belly, not inside it (%.0f mm)" % (float(bs.get("last_wrist_clear")) * 1000.0))
	# 手 / 手指 不穿进大腿：到大腿骨轴的距离
	var thigh_min := INF
	for side in ["L_", "R_"]:
		for oside in ["L_", "R_"]:
			var a := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(oside + "UpperLeg_a")).origin
			var b := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(oside + "Foreleg_a")).origin
			for bn in ["Hand_a", "Index_b", "Middle_b", "Ring_b", "Pinky_b", "Thumb_b", "Forearm_a"]:
				var bi := skel.find_bone(side + bn)
				if bi < 0:
					continue
				var p := skel.global_transform * skel.get_bone_global_pose(bi).origin
				var q := Geometry3D.get_closest_point_to_segment(p, a.lerp(b, 0.25), b)
				thigh_min = minf(thigh_min, p.distance_to(q))
	_ok(thigh_min > 0.075, "hands / fingers keep clear of the thighs (closest joint %.0f mm from a thigh axis)" % (thigh_min * 1000.0))
	hud.call("_on_bed_action_button")
	await _frames(2)
	labels = hud.call("debug_bed_action_labels")
	_ok(labels.has("停止掰开") and labels.has("停止"), "while active the list offers 停止掰开 / 停止 (%s)" % [labels])
	hud.call("debug_run_bed_action", "__stop")
	await _phys(30)
	_ok(float(rig.call("vulva_spread")) < 0.6 and float(bs.get("hand_u")) > 0.9, "停止: labia close first (spread %.2f), hands still in place" % float(rig.call("vulva_spread")))
	await _phys(70)
	var lh1 := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("L_Hand_a")).origin
	var rh1 := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("R_Hand_a")).origin
	_ok(float(rig.call("vulva_spread")) == 0.0 and float(vf.gap_width()) < 1e-5 and lh1.distance_to(lh0) < 0.01 and rh1.distance_to(rh0) < 0.01, "then hands return to the armrests (%.1f / %.1f mm) and the spread is back to 0" % [lh1.distance_to(lh0) * 1000.0, rh1.distance_to(rh0) * 1000.0])
	# 再点一次同一动作 = 开始，再点 = 停止（切换）
	_ok(bool(vs.call("toggle_bed_action", "spread_vulva")) and not bool(vs.call("toggle_bed_action", "spread_vulva")), "tapping the action again toggles it off")
	await _phys(80)
	# 进行中下床：立即复位
	vs.call("toggle_bed_action", "spread_vulva")
	await _phys(80)
	vs.call("try_exit")
	await _phys(6)
	await _frames(4)
	_ok(not bool(bs.call("busy")) and float(rig.call("vulva_spread")) == 0.0, "leaving the bed mid-action resets the pose and closes the labia")
	await _frames(2)
	_ok(not bool(hud.get("debug_bed_action_visible")), "动作 button hidden off the bed")
