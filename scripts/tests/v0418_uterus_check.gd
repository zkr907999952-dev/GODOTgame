extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中，t63u / t64u / t65u）：子宫扯出改为动态段链 + 可伸长系带，经创口伸出体外、可甩动摆动。手术复原后肚脐逐顶点等于原始精细肚脐。
##   godot --headless --path . -s res://scripts/tests/v0418_uterus_check.gd


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
		print("v0418_uterus_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_fling()
	await _check_navel_restore()
	print("v0418_uterus_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _tether_through_wound(so: Node, wound: Vector3, outv: Vector3) -> Array:
	# 系带 + 宫体整条链：每个跨过创口平面的段都要穿过洞口。
	var pts: PackedVector3Array = so.call("tether_points")
	var body: PackedVector3Array = so.get("_p")
	for i in range(1, body.size()):
		pts.append(body[i])
	var worst := 0.0
	var crossings := 0
	for i in pts.size() - 1:
		var da := (pts[i] - wound).dot(outv)
		var db := (pts[i + 1] - wound).dot(outv)
		if (da < 0.0) == (db < 0.0):
			continue
		crossings += 1
		var t := da / (da - db)
		var x := pts[i].lerp(pts[i + 1], t)
		var rel := x - wound
		worst = maxf(worst, (rel - outv * rel.dot(outv)).length())
	return [crossings, worst]


func _speed(so: Node, prev: Vector3, dt: float) -> float:
	return (so.call("fundus_world") as Vector3).distance_to(prev) / dt


func _check_fling() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract starts")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 60.0)
	var so: Node = s.call("soft_organ", "uterus")
	_ok(so != null, "soft uterus exists")
	if so == null:
		return
	# t64u：出生时与可见原子宫（骨盆骨骼上的真实变换）重合。
	var off: Dictionary = so.call("spawn_offset")
	print("SPAWN offset centroid=%.2f mm max=%.2f mm axis=%.2f°" % [float(off["centroid_mm"]), float(off["max_mm"]), float(off["axis_deg"])])
	_ok(float(off["centroid_mm"]) < 1.0 and float(off["max_mm"]) < 1.5 and float(off["axis_deg"]) < 1.0, "physics uterus spawns on the visible original (centroid %.2f mm, max %.2f mm, axis %.2f°)" % [float(off["centroid_mm"]), float(off["max_mm"]), float(off["axis_deg"])])
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var f_in := float(so.call("fundus_skin_distance"))
	print("SPAWN fundus signed distance to wound plane = %.1f cm" % (f_in * 100.0))
	_ok(f_in < 0.0, "fundus starts inside the body (%.1f cm)" % (f_in * 100.0))
	# 夹住宫底：先拉向创口，再向外拉到头。
	var cage: PackedVector3Array = so.get("_p")
	var aim: Vector3 = cage[cage.size() - 1]
	var cam_o := aim + outv * 0.12
	_ok(bool(s.call("debug_forceps_begin", cam_o, (aim - cam_o).normalized())), "forceps grab the uterus")
	var hi := int(so.get("hold_index"))
	print("GRAB hold_index=%d" % hi)
	var dt := 1.0 / 60.0
	var tip: Vector3 = so.get("hold_pos")
	var goal1 := wound + outv * 0.02
	var nan := 0
	var max_edge := 1.0
	var usec_acc := 0
	var usec_n := 0
	for i in 60:
		tip = tip.move_toward(goal1, 0.25 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		usec_acc += int(so.get("last_step_usec"))
		usec_n += 1
	for i2 in 60:
		tip = tip + outv * (0.2 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		usec_acc += int(so.get("last_step_usec"))
		usec_n += 1
		var me := float(so.call("max_edge_ratio"))
		max_edge = maxf(max_edge, me)
		var q: Dictionary = so.call("debug_mesh_quality")
		nan += int(q.get("nan_verts", 0))
	var f_out := float(so.call("fundus_skin_distance"))
	var c_out := float(so.call("cervix_out_distance"))
	var nout := int(so.call("body_out_count"))
	print("PULL fundus %.1f cm outside skin/wound plane, cervix %.1f cm, body nodes outside %d/6, tether %.1f/%.1f cm, level %d" % [f_out * 100.0, c_out * 100.0, nout, float(so.call("tether_length")) * 100.0, float(so.call("tether_max_length")) * 100.0, int(s.call("extract_level", "uterus"))])
	_ok(f_out > 0.03, "after a full pull the fundus is outside the body (%.1f cm)" % (f_out * 100.0))
	_ok(nout >= 5, "most of the uterus is outside (%d/6 nodes)" % nout)
	_ok(int(s.call("extract_level", "uterus")) == 5, "full pull reaches level 5")
	var tw: Array = _tether_through_wound(so, wound, outv)
	print("PULL chain crosses the wall %d time(s), worst crossing %.1f mm from wound centre" % [int(tw[0]), float(tw[1]) * 1000.0])
	_ok(int(tw[0]) >= 1 and float(tw[1]) < 0.022, "tether passes through the wound opening (%d crossing, %.1f mm)" % [int(tw[0]), float(tw[1]) * 1000.0])
	print("EDGE max mesh edge stretch during pull %.4f" % max_edge)
	_ok(max_edge < 1.03, "rigid skinning: max edge stretch %.3f" % max_edge)
	_ok(nan == 0, "no NaN in the uterus mesh during the pull")
	# 快速横甩后松手。
	var side: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	for j in 6:
		tip += side * (0.9 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
	s.call("debug_forceps_end")
	var prev: Vector3 = so.call("fundus_world")
	var speeds: Array = []
	var max_disp := 0.0
	var rel0: Vector3 = so.call("fundus_world")
	for k in 360:
		s.call("_update_guts", dt)
		usec_acc += int(so.get("last_step_usec"))
		usec_n += 1
		var f: Vector3 = so.call("fundus_world")
		speeds.append(f.distance_to(prev) / dt)
		max_disp = maxf(max_disp, f.distance_to(rel0))
		prev = f
		var q2: Dictionary = so.call("debug_mesh_quality")
		nan += int(q2.get("nan_verts", 0))
	var avg := func(a: int, b: int) -> float:
		var acc := 0.0
		for z in range(a, b):
			acc += float(speeds[z])
		return acc / float(b - a)
	var v0 := float(avg.call(0, 12))
	var v1 := float(avg.call(54, 66))
	var v2 := float(avg.call(114, 126))
	var v5 := float(avg.call(300, 360))
	print("SWING fundus speed after release: 0-0.2s %.3f m/s, ~1s %.3f m/s, ~2s %.3f m/s, 5-6s %.4f m/s; swing travel %.1f cm" % [v0, v1, v2, v5, max_disp * 100.0])
	_ok(v0 > 0.2, "the release keeps momentum (%.3f m/s)" % v0)
	_ok(v1 > 0.01, "it is still swinging after ~1 s (%.3f m/s)" % v1)
	_ok(v5 < v0 * 0.2, "the swing decays over several seconds (%.4f m/s at 5-6 s)" % v5)
	var f_hang := float(so.call("fundus_skin_distance"))
	print("HANG fundus %.1f cm outside after 6 s" % (f_hang * 100.0))
	_ok(f_hang > 0.0 and int(so.call("body_out_count")) >= 4, "the released uterus hangs outside the body (%.1f cm, %d/6)" % [f_hang * 100.0, int(so.call("body_out_count"))])
	var tw2: Array = _tether_through_wound(so, s.call("_wound_center_world"), (s.call("_cavity_outward") as Vector3).normalized())
	_ok(float(tw2[1]) < 0.022, "after swinging the tether still passes through the wound (%.1f mm)" % (float(tw2[1]) * 1000.0))
	var edge2 := float(so.call("max_edge_ratio"))
	print("EDGE max mesh edge stretch after swing %.4f" % edge2)
	_ok(edge2 < 1.03, "max edge stretch after swinging %.3f" % edge2)
	_ok(nan == 0, "no NaN during the swing")
	for side_i in [0, 1]:
		_ok(float(so.call("tube_head_gap", side_i)) < 0.003 and float(so.call("ovary_tip_gap", side_i)) < 0.003, "tube %d stays on its horn and the ovary on the tube tip" % side_i)
	var avg_us := float(usec_acc) / float(maxi(usec_n, 1))
	print("COST uterus step %.0f µs / frame average" % avg_us)
	_ok(avg_us < 2500.0, "uterus step is cheap (%.0f µs)" % avg_us)
	# 放回
	_ok(bool(s.call("debug_putback_organ", "uterus")), "put-back starts")
	var frames_back := 0
	for m in 400:
		s.call("_update_guts", 1.0 / 30.0)
		frames_back += 1
		if int(s.call("extract_level", "uterus")) == 0:
			break
	print("PUTBACK done in %.1f s" % (float(frames_back) / 30.0))
	_ok(int(s.call("extract_level", "uterus")) == 0, "put-back returns the uterus")
	_ok(not bool(s.call("organ_source_hidden", "uterus")), "original uterus visible after put-back")
	# 「放回内脏」按钮路径
	_ok(bool(s.call("debug_begin_extract", "uterus")), "second extraction")
	s.call("debug_add_extract_charge", "uterus", 1.0, 0.5)
	for _n in 30:
		s.call("_update_guts", dt)
	_ok(bool(s.call("restore_extracted_organs")), "「放回内脏」 restores extracted organs")
	_ok(int(s.call("extract_level", "uterus")) == 0 and not bool(s.call("organ_source_hidden", "uterus")), "after 「放回内脏」 the original uterus is back")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


## t65u：手术「复原」后肚脐必须是原始的精细肚脐（逐顶点位置 / 法线 / UV 与原网格一致）。
func _navel_near(P: PackedVector3Array, navel: Vector3, I: PackedInt32Array) -> PackedInt32Array:
	var used: Dictionary = {}
	for k in I:
		used[k] = true
	var o := PackedInt32Array()
	for i in P.size():
		if used.has(i) and Vector2(P[i].x - navel.x, P[i].y - navel.y).length() < 0.02 and P[i].z > navel.z - 0.05:
			o.append(i)
	return o


## 双向比较：显示出的手术腹网（_surgical_mi 实际渲染的网格）与原 Dress 网格在肚脐 2 cm 内逐顶点比对。
func _navel_diff() -> Dictionary:
	var orig: Mesh = s.get("_dress_mesh_orig")
	var mi = s.get("_surgical_mi")
	var navel: Vector3 = s.get("_navel_rest")
	var out := {"n": 0, "m": 0, "pos_mm": 0.0, "nrm_deg": 0.0, "uv": 0.0, "rev_mm": 0.0, "faces_o": 0, "faces_d": 0}
	if orig == null or mi == null or (mi as MeshInstance3D).mesh == null:
		out["n"] = -1
		return out
	var arr: Array = orig.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var U: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var darr: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
	var Q: PackedVector3Array = darr[Mesh.ARRAY_VERTEX]
	var M: PackedVector3Array = darr[Mesh.ARRAY_NORMAL]
	var T: PackedVector2Array = darr[Mesh.ARRAY_TEX_UV]
	var no := _navel_near(P, navel, arr[Mesh.ARRAY_INDEX])
	var nd := _navel_near(Q, navel, darr[Mesh.ARRAY_INDEX])
	# 唯一的（位置 + UV）顶点数：手术网格允许同位置重复顶点（小片接缝），但集合必须一致。
	for pk in [[P, U, no, "n"], [Q, T, nd, "m"]]:
		var seen: Dictionary = {}
		for i0 in (pk[2] as PackedInt32Array):
			var pv: Vector3 = (pk[0] as PackedVector3Array)[i0]
			var tv: Vector2 = (pk[1] as PackedVector2Array)[i0]
			seen[[roundi(pv.x * 1e6), roundi(pv.y * 1e6), roundi(pv.z * 1e6), roundi(tv.x * 1e5), roundi(tv.y * 1e5)]] = true
		out[pk[3]] = seen.size()
	# 面数（三个顶点都在 2 cm 内）：拓扑也要一致。
	for pack in [[arr, P, "faces_o"], [darr, Q, "faces_d"]]:
		var I: PackedInt32Array = pack[0][Mesh.ARRAY_INDEX]
		var PP: PackedVector3Array = pack[1]
		var cnt := 0
		for f in I.size() / 3:
			var inside := true
			for k in 3:
				var q := PP[I[f * 3 + k]]
				if Vector2(q.x - navel.x, q.y - navel.y).length() >= 0.02 or q.z < navel.z - 0.05:
					inside = false
			if inside:
				cnt += 1
		out[pack[2]] = cnt
	for dir in 2:
		var A: PackedVector3Array = P if dir == 0 else Q
		var AN: PackedVector3Array = N if dir == 0 else M
		var AU: PackedVector2Array = U if dir == 0 else T
		var B: PackedVector3Array = Q if dir == 0 else P
		var BN: PackedVector3Array = M if dir == 0 else N
		var BU: PackedVector2Array = T if dir == 0 else U
		var la: PackedInt32Array = no if dir == 0 else nd
		var lb: PackedInt32Array = nd if dir == 0 else no
		for i in la:
			var best := 1e9
			var bj := -1
			for j in lb:
				var sc := A[i].distance_squared_to(B[j]) + AU[i].distance_squared_to(BU[j]) + 1e-6 * AN[i].distance_squared_to(BN[j])
				if sc < best:
					best = sc
					bj = j
			if bj < 0:
				out["pos_mm"] = 1e9
				continue
			var key := "pos_mm" if dir == 0 else "rev_mm"
			out[key] = maxf(float(out[key]), A[i].distance_to(B[bj]) * 1000.0)
			out["uv"] = maxf(float(out["uv"]), AU[i].distance_to(BU[bj]))
			out["nrm_deg"] = maxf(float(out["nrm_deg"]), rad_to_deg(AN[i].angle_to(BN[bj])))
	return out


func _navel_line(tag: String, d: Dictionary) -> void:
	print("NAVEL %s: orig %d / shown %d verts, faces %d / %d, pos %.4f mm, reverse %.4f mm, normal %.3f°, uv %.6f" % [tag, int(d["n"]), int(d["m"]), int(d["faces_o"]), int(d["faces_d"]), float(d["pos_mm"]), float(d["rev_mm"]), float(d["nrm_deg"]), float(d["uv"])])


func _check_navel_restore() -> void:
	var d0 := _navel_diff()
	_navel_line("fresh surgery bake", d0)
	print("NAVEL patch faces %d, flat_applied %s" % [int(s.call("navel_patch_faces")), str(s.get("navel_flat_applied"))])
	_ok(float(d0["pos_mm"]) < 0.01 and float(d0["rev_mm"]) < 0.01 and int(d0["faces_o"]) == int(d0["faces_d"]), "entering surgery shows the original detailed navel")
	await _open_wound()
	_ok(bool(s.get("navel_flat_applied")), "a cut through the navel switches to the flattened cutting surface")
	main.call("restore_all_bodies")
	await _frames(4)
	var d1 := _navel_diff()
	_navel_line("after 复原", d1)
	_ok(int(d1["n"]) > 20 and int(d1["n"]) == int(d1["m"]), "navel region compared (%d orig / %d shown verts)" % [int(d1["n"]), int(d1["m"])])
	_ok(int(d1["faces_o"]) == int(d1["faces_d"]), "after 复原 navel face count matches the original (%d / %d)" % [int(d1["faces_o"]), int(d1["faces_d"])])
	_ok(float(d1["pos_mm"]) < 0.01 and float(d1["rev_mm"]) < 0.01, "after 复原 the navel matches the original vertex for vertex (%.4f / %.4f mm)" % [float(d1["pos_mm"]), float(d1["rev_mm"])])
	_ok(float(d1["nrm_deg"]) < 0.1 and float(d1["uv"]) < 1e-5, "after 复原 navel normals and UVs match the original (%.3f°, %.6f)" % [float(d1["nrm_deg"]), float(d1["uv"])])
	_ok(not bool(s.get("navel_flat_applied")) and float(s.call("navel_dimple_depth")) > 0.003, "the navel dimple is back after 复原 (depth %.1f mm)" % (float(s.call("navel_dimple_depth")) * 1000.0))
	var mi: MeshInstance3D = s.get("_surgical_mi")
	var pdiff := _param_diff(s.get("_dress") as MeshInstance3D, mi)
	print("NAVEL material params differing from the original skin: %s" % str(pdiff))
	_ok(pdiff.is_empty(), "after 复原 the surgical skin material matches the original skin params (except wound tint / deform)")
	s.call("exit_surgery")
	await _frames(2)
	main.call("restore_all_bodies")
	await _frames(2)
	var dress: MeshInstance3D = s.get("_dress")
	_ok(dress != null and dress.mesh == s.get("_dress_mesh_orig"), "outside surgery 复原 puts the original dress mesh back")


func _param_diff(dress: MeshInstance3D, mi: MeshInstance3D) -> Array:
	var res: Array = []
	if dress == null or mi == null:
		return ["missing"]
	var om: Material = s.get("_dress_mat_orig") if s.get("_dress_mat_orig") != null else null
	if om == null:
		om = dress.get_active_material(0)
	var sm: Material = mi.material_override
	if not (om is ShaderMaterial) or not (sm is ShaderMaterial):
		return res
	var a := om as ShaderMaterial
	var b := sm as ShaderMaterial
	if a.shader != b.shader:
		res.append("shader")
	for u in a.shader.get_shader_uniform_list():
		var nm: String = u["name"]
		if nm == "wound_tint_on" or nm.begins_with("ab_") or nm.begins_with("peri_"):
			continue
		var va = a.get_shader_parameter(nm)
		var vb = b.get_shader_parameter(nm)
		if typeof(va) != typeof(vb) or (va != vb and not (va is float and absf(float(va) - float(vb)) < 1e-6)):
			res.append(nm)
	return res
