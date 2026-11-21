extends "res://scripts/tests/v0403_check.gd"
## 0.4.04 自检：肚脐压平后竖 / 横 / 斜直切穿过肚脐中心完全分开、两唇都能拿取；拉钩选中并清除；镜子分辨率只随距离降低；
## 系膜锚在创缘周围；肠子之间碰撞；拉钩倾斜；体外蠕动增强并影响碰撞半径；三条直切围成的独立皮瓣可拿走。
##   godot --headless --path . -s res://scripts/tests/v0404_check.gd   （V0404_ONLY=navel|retr|mirror|guts|flap）


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
	_ok(presets.find("version/code=4") >= 0, "export version present")
	var only := OS.get_environment("V0404_ONLY")
	if only == "" or only == "mirror":
		await _check_mirror()
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	if only == "" or only == "navel":
		await _check_navel_flat()
	if only == "" or only == "retr":
		await _check_retractor_remove()
	if only == "" or only == "guts":
		await _check_guts_0404()
	if only == "" or only == "flap":
		await _check_straight_flap()
	print("v0404_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_mirror() -> void:
	var mirror: Node3D = main.get_node_or_null("RoomMirror")
	_ok(mirror != null, "room mirror present")
	if mirror == null:
		return
	var was_vis := mirror.visible
	mirror.visible = true
	var prev_cam := root.get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = 70.0
	main.add_child(cam)
	cam.current = true
	var mo := mirror.global_position
	var n := mirror.global_transform.basis.z.normalized()
	var u := mirror.global_transform.basis.x.normalized()
	var vp := Vector2(root.get_viewport().get_visible_rect().size)
	# 近处斜看（掠射）：分辨率不降、贴图像素 ≥ 镜子在屏幕上占的像素
	var results := []
	for pose in [[0.6, 0.0], [0.45, 1.3], [1.2, 0.9]]:
		cam.global_position = mo + n * float(pose[0]) + u * float(pose[1]) + Vector3(0, -0.2, 0)
		cam.look_at(mo - u * 0.6, Vector3.UP)
		await _frames(3)
		var ts: Vector2i = mirror.call("get_texture_size")
		var lod := float(mirror.get("last_lod"))
		results.append("%dx%d lod %.2f" % [ts.x, ts.y, lod])
		_ok(bool(mirror.call("is_rendering")) and lod >= 0.999 and ts.x >= mini(int(vp.x * 0.3), 4096), "near/oblique mirror keeps full resolution (%s)" % results[-1])
	# 很远：才降分辨率
	cam.global_position = mo + n * 9.0
	cam.look_at(mo, Vector3.UP)
	await _frames(3)
	var lod_far := float(mirror.get("last_lod"))
	_ok(lod_far < 0.7, "mirror resolution drops only far away (lod %.2f at 9 m)" % lod_far)
	cam.queue_free()
	if prev_cam:
		prev_cam.current = true
	mirror.visible = was_vis
	await _frames(2)


# ---- 1. 肚脐 ----
func _check_navel_flat() -> void:
	await _restart()
	var outer: Geom.MeshData = s.get("_outer")
	var nav: Vector3 = s.get("_navel_rest")
	_ok(int(s.get("navel_flattened")) > 20, "navel dimple removed from the cut mesh (%d verts moved, retriangulated %d tris, flips %d)" % [int(s.get("navel_flattened")), Geom.navel_retri, Geom.navel_flips])
	var worst := 1.0
	var poor := 0
	for f0 in outer.face_count():
		var a0 := outer.pos[outer.idx[f0 * 3]]
		var cen0 := (a0 + outer.pos[outer.idx[f0 * 3 + 1]] + outer.pos[outer.idx[f0 * 3 + 2]]) / 3.0
		if Vector2(cen0.x - nav.x, cen0.y - nav.y).length() < 0.02:
			var q := Geom.tri_quality(a0, outer.pos[outer.idx[f0 * 3 + 1]], outer.pos[outer.idx[f0 * 3 + 2]])
			worst = minf(worst, q)
			if q < 0.2:
				poor += 1
	print("v0404: navel region tri quality worst %.3f, poor(<0.2) %d" % [worst, poor])
	# 肚脐区域没有陡壁 / 背向三角，XY 投影不重叠
	var steep := 0
	var flipped := 0
	var pos_n := 0
	var neg_n := 0
	for f in outer.face_count():
		var a := outer.pos[outer.idx[f * 3]]
		var b := outer.pos[outer.idx[f * 3 + 1]]
		var c := outer.pos[outer.idx[f * 3 + 2]]
		var cen := (a + b + c) / 3.0
		if Vector2(cen.x - nav.x, cen.y - nav.y).length() > 0.022:
			continue
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-14:
			continue
		var nz := n.normalized().z
		if nz < 0.0:
			neg_n += 1
		else:
			pos_n += 1
		if absf(nz) < 0.6:
			steep += 1
	flipped = mini(pos_n, neg_n)
	_ok(flipped == 0 and steep == 0, "navel region is a smooth regular surface (steep=%d flipped=%d)" % [steep, flipped])
	var cuts := [
		["vertical", Vector3(0.001, 0.05, 0), Vector3(-0.001, -0.05, 0)],
		["horizontal", Vector3(-0.045, 0.001, 0), Vector3(0.045, -0.001, 0)],
		["diagonal", Vector3(-0.04, 0.04, 0), Vector3(0.04, -0.04, 0)],
		["diagonal2", Vector3(0.035, 0.045, 0), Vector3(-0.035, -0.045, 0)],
	]
	for cdef in cuts:
		await _restart()
		var tag := "navel %s" % cdef[0]
		_ok(_straight(nav + (cdef[1] as Vector3), nav + (cdef[2] as Vector3)), "%s: straight cut through the navel centre" % tag)
		_cut_quality(tag)
		_grab_both_lips(tag)


func _grab_both_lips(tag: String) -> void:
	var outer: Geom.MeshData = s.get("_outer")
	var nav: Vector3 = s.get("_navel_rest")
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	var bi := 0
	var bd := 1e9
	for i in left.size():
		var d := Vector2(outer.pos[left[i]].x - nav.x, outer.pos[left[i]].y - nav.y).length()
		if d < bd:
			bd = d
			bi = i
	s.call("set_tool", "grab")
	for side in [1, -1]:
		var vid: int = left[bi] if side == 1 else right[bi]
		var vw: Vector3 = s.call("_vert_world", vid)
		var o := vw + Vector3(0, 0.3, 0)
		var ok: bool = bool(s.call("begin_stroke", o, (vw - o).normalized())) and int(s.get("_pull_lip")) == side
		s.call("cancel_stroke")
		_ok(ok, "%s: grab picks the %s lip at the navel" % [tag, "left" if side == 1 else "right"])
	s.call("set_tool", "scalpel")


func _check_retractor_remove() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "retractor: straight cut")
	var outer: Geom.MeshData = s.get("_outer")
	var left: PackedInt32Array = s.get("_lip_left")
	var n := left.size()
	var rest0 := outer.pos.duplicate()
	s.call("set_tool", "retractor")
	_ok(bool(s.call("place_retractor", left[n / 2])), "retractor placed")
	await _frames(2)
	var zax: Vector3 = (s.call("retractor_nodes")[0] as Node3D).global_transform.basis.z
	s.call("debug_drag_retractor", 0, s.call("_to_ab_delta", -zax.normalized() * 0.012))
	await _phys(4)
	var d_on := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	_ok(d_on > 0.006, "retractor holds the lip open (%.1f mm)" % (d_on * 1000.0))
	# 6. 倾斜：手柄外端离开皮肤
	var r0: Node3D = (s.call("retractor_nodes") as Array)[0]
	var vid: int = (s.get("_retractors") as Array)[0]["vid"]
	var skel: Skeleton3D = s.get("_skel")
	var sk: Skin = s.get("_skin")
	var lw: Vector3 = skel.global_transform * Geom.skin_vertex(outer.pos[vid], vid, outer, skel, sk)
	var nw: Vector3 = (skel.global_transform * Geom.skin_vertex(outer.pos[vid] + outer.nrm[vid].normalized() * 0.01, vid, outer, skel, sk) - lw).normalized()
	var far_end: Vector3 = r0.global_transform * Vector3(0, -0.0148, -0.074)
	var hook: Vector3 = r0.global_transform * Vector3(0, -0.0148, 0.066)
	var rise := (far_end - lw).dot(nw)
	var tilt := rad_to_deg(asin(clampf((far_end - hook).normalized().dot(nw), -1.0, 1.0)))
	_ok(rise > 0.02 and tilt > 10.0 and hook.distance_to(lw) < 0.004, "retractor tilts outward: handle end %.0f mm above the skin, %.0f° (hook still %.1f mm from the lip)" % [rise * 1000.0, tilt, hook.distance_to(lw) * 1000.0])
	# 点中选中
	var c: Vector3 = r0.global_transform * Vector3(0, 0, -0.03)
	var o := c + nw * 0.3
	s.call("begin_stroke", o, (c - o).normalized())
	s.call("end_stroke")
	await _frames(2)
	_ok(int(s.call("selected_retractor")) == 0, "clicking a placed retractor selects it")
	var btn: Button = hud.get("_btn_retr_remove")
	_ok(btn != null and btn.visible, "HUD shows 「移除拉钩」 for the selected retractor")
	if btn:
		btn.emit_signal("pressed")
	await _frames(2)
	_ok(int(s.call("retractor_count")) == 0 and int(s.call("selected_retractor")) == -1, "remove deletes the retractor")
	_ok(btn == null or not btn.visible, "remove button hides again")
	var d_mid := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	await _frames(50)
	var d_off := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	_ok(d_off < d_on * 0.25 and not bool(s.call("retractor_releasing")), "after removal the lip springs back (%.1f -> %.1f -> %.1f mm)" % [d_on * 1000.0, d_mid * 1000.0, d_off * 1000.0])
	# Delete 键：再放一把，选中，按 Delete
	_ok(bool(s.call("place_retractor", left[n / 2])), "place another retractor")
	s.call("select_retractor", 0)
	var ev := InputEventKey.new()
	ev.keycode = KEY_DELETE
	ev.pressed = true
	s.call("_unhandled_input", ev)
	_ok(int(s.call("retractor_count")) == 0, "Delete key removes the selected retractor")
	await _frames(40)
	await _restart()


func _check_guts_0404() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	_ok(_straight(c + Vector3(-0.06, 0.0, 0.0), c + Vector3(0.06, 0.004, 0.0)), "guts: straight cut")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "guts: ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "guts: flap peeled")
	await _phys(4)
	s.call("set_tool", "forceps")
	var hc := _hole_center()
	_ok(bool(s.call("debug_forceps_begin", hc + Vector3(0, 0.3, 0), Vector3.DOWN)), "guts: first loop clamped")
	await _frames(14)
	var rope: Node = (s.call("gut_ropes") as Array)[0]
	var tip0: Vector3 = rope.get("hold_pos")
	for i in 50:
		s.call("debug_forceps_drag_to", tip0 + Vector3(0.14, 0.1, 0.02) * (float(i + 1) / 50.0))
		await process_frame
	s.call("debug_forceps_end")
	await _frames(30)
	# 第二段：从创口另一侧夹出，拖到第一段上方后松开 → 落在第一段上
	var rim: PackedVector3Array = s.call("_gut_rim_world")
	var pts: PackedVector3Array = rope.call("points")
	var bestq := hc
	var bestd := -1.0
	for q in rim:
		var cand := q.lerp(hc, 0.45)
		var dmin := 1e9
		for pp in pts:
			dmin = minf(dmin, Vector2(pp.x - cand.x, pp.z - cand.z).length())
		if dmin > bestd:
			bestd = dmin
			bestq = cand
	_ok(bool(s.call("debug_forceps_begin", bestq + Vector3(0, 0.3, 0), Vector3.DOWN)) and int(s.call("gut_pull_count")) == 2, "guts: second loop clamped")
	await _frames(14)
	var rope2: Node = (s.call("gut_ropes") as Array)[1]
	var t2: Vector3 = rope2.get("hold_pos")
	pts = rope.call("points")
	var over: Vector3 = pts[pts.size() / 2] + Vector3(0, 0.05, 0)
	for i in 50:
		s.call("debug_forceps_drag_to", t2.lerp(over, float(i + 1) / 50.0))
		await process_frame
	s.call("debug_forceps_end")
	await _frames(150)
	rim = s.call("_gut_rim_world")
	# 4. 系膜：锚点在创缘一圈，肠袢挂在创口周围
	var anc: PackedVector3Array = rope.get("mes_anchors")
	var worst_anc := 0.0
	for q in anc:
		var dm := 1e9
		for r in rim:
			dm = minf(dm, q.distance_to(r))
		worst_anc = maxf(worst_anc, dm)
	_ok(anc.size() >= 8 and worst_anc < 0.02, "mesentery anchors ring the wound rim (%d anchors, ≤ %.0f mm from the rim)" % [anc.size(), worst_anc * 1000.0])
	for rp in [rope, rope2]:
		var pp2: PackedVector3Array = rp.call("points")
		var ml := float(rp.call("mesentery_length"))
		var far_rim := 0.0
		var r0 := rp.call("outside_range") as Vector2i
		for i in range(r0.x, r0.y + 1):
			var dm2 := 1e9
			for r in rim:
				dm2 = minf(dm2, pp2[i].distance_to(r))
			far_rim = maxf(far_rim, dm2)
		var teth := 0.0
		for im in range(2 + 6, pp2.size() - 3, 6):
			teth = maxf(teth, pp2[im].distance_to(rp.call("mesentery_anchor", im)) - ml)
		_ok(teth < 0.03 and far_rim < 0.2, "gut loop hangs around the wound (tethers ≤ %.0f mm over slack, farthest point %.0f mm from the rim, fed %.0f mm)" % [teth * 1000.0, far_rim * 1000.0, float(rp.get("fed_len")) * 1000.0])
	# 5. 肠管互相碰撞
	var clr1 := float(rope.call("min_gut_clearance"))
	var clr2 := float(rope2.call("min_gut_clearance"))
	var pushes := int(rope.get("gut_pushes")) + int(rope2.get("gut_pushes"))
	_ok(clr1 > -0.002 and clr2 > -0.002 and pushes > 0, "guts collide with each other, no overlap (min clearance %.1f / %.1f mm, %d pushes)" % [clr1 * 1000.0, clr2 * 1000.0, pushes])
	# 7. 蠕动增强 + 碰撞半径跟随
	var rmin := 1e9
	var rmax := 0.0
	var changed := false
	var r_prev: PackedFloat32Array = (rope.call("radii") as PackedFloat32Array).duplicate()
	for f in 40:
		await process_frame
		var rr: PackedFloat32Array = rope.call("radii")
		for i in range(3, rr.size() - 3):
			rmin = minf(rmin, rr[i])
			rmax = maxf(rmax, rr[i])
			if i < r_prev.size() and absf(rr[i] - r_prev[i]) > 1e-4:
				changed = true
	var am: ArrayMesh = (rope as MeshInstance3D).mesh
	var arrs := am.surface_get_arrays(0)
	var cu: PackedFloat32Array = arrs[Mesh.ARRAY_CUSTOM0]
	var v0: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
	var ptsm: PackedVector3Array = rope.call("points")
	var mid := ptsm.size() / 2 * 11
	var radial := Vector3(cu[mid * 4 + 1], cu[mid * 4 + 2], cu[mid * 4 + 3]).length()
	var rv := v0[mid].distance_to(ptsm[ptsm.size() / 2])
	_ok(radial > rv * 1.5, "outside gut peristalsis amplified (shader radial %.1f mm vs tube radius %.1f mm)" % [radial * 1000.0, rv * 1000.0])
	_ok(changed and rmax > rmin * 1.4, "collision radius follows the peristalsis (%.1f..%.1f mm)" % [rmin * 1000.0, rmax * 1000.0])
	print("v0402: gut update %.2f ms / frame (2 loops)" % (float(s.get("gut_update_usec")) / 1000.0))
	s.call("restore_body")
	await _frames(3)


func _check_straight_flap() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var A := nav + Vector3(-0.05, -0.03, 0)
	var B := nav + Vector3(0.05, -0.03, 0)
	var C := nav + Vector3(0.0, -0.11, 0)
	var k := 0
	for pr in [[A, B], [B, C], [C, A]]:
		var a: Vector3 = pr[0]
		var b: Vector3 = pr[1]
		var d := (b - a).normalized()
		_ok(_straight(a - d * 0.015, b + d * 0.015), "triangle: straight cut %d" % k)
		s.call("debug_finish_cut_anim")
		s.call("debug_settle_eversion")
		if k < 2:
			_ok(not bool(s.get("free_flap_ready")), "no independent flap before the triangle closes (cut %d)" % k)
		k += 1
	_ok(bool(s.get("free_flap_ready")) and bool(s.call("can_grab_flap")), "three crossing straight cuts isolate a triangular flap (%d faces)" % int(s.get("free_flap_faces")))
	var outer: Geom.MeshData = s.get("_outer")
	var comps: Array = Geom.all_components(outer)
	var comp: Dictionary = comps[1]
	var skel: Skeleton3D = s.get("_skel")
	var wp := Geom.world_positions(outer, skel, s.get("_skin"))
	var cw := Vector3.ZERO
	var cnt := 0
	for f in comp.keys():
		for j in 3:
			cw += wp[outer.idx[int(f) * 3 + j]]
			cnt += 1
	cw /= float(cnt)
	s.call("set_tool", "grab")
	# 点三角外（切口旁的皮肤）：不撕皮瓣
	var off := cw + (skel.global_transform.basis * Vector3(0.0, 0.07, 0.0))
	s.call("begin_stroke", off + Vector3(0, 0.3, 0), Vector3.DOWN)
	s.call("cancel_stroke")
	_ok(bool(s.get("free_flap_ready")) and int(s.get("free_flaps_removed")) == 0, "clicking skin outside the triangle does not tear it off")
	var faces0 := outer.face_count()
	_ok(bool(s.call("begin_stroke", cw + Vector3(0, 0.3, 0), Vector3.DOWN)), "grab the triangular flap")
	await _frames(2)
	var fl: Node3D = s.get("flap_node")
	_ok(fl != null and is_instance_valid(fl) and int(s.get("free_flaps_removed")) == 1 and bool(s.call("flap_is_held")), "triangular flap comes off and is held by the grab tool")
	var outer2: Geom.MeshData = s.get("_outer")
	_ok(Geom.all_components(outer2).size() == 1 and outer2.face_count() < faces0 and not bool(s.get("free_flap_ready")), "body skin keeps one piece, flap faces removed (%d -> %d)" % [faces0, outer2.face_count()])
	# 皮瓣那侧的截面随皮瓣带走：三角里不再有截面三角
	var wall: Geom.MeshData = s.get("_wall_md")
	var poly := PackedVector2Array([Vector2(A.x, A.y), Vector2(B.x, B.y), Vector2(C.x, C.y)])
	var cen := (poly[0] + poly[1] + poly[2]) / 3.0
	for i in 3:
		poly[i] = cen + (poly[i] - cen) * 0.8
	var inside_w := 0
	for f2 in wall.face_count():
		var c3 := wall.centroid(f2)
		if Geometry2D.is_point_in_polygon(Vector2(c3.x, c3.y), poly):
			inside_w += 1
	_ok(inside_w == 0 and int(s.get("free_flap_wall_dropped")) > 0 and wall.face_count() > 0, "flap-side section walls go with the flap, body-side walls stay (%d dropped, %d left, %d inside)" % [int(s.get("free_flap_wall_dropped")), wall.face_count(), inside_w])
	s.call("cancel_stroke")
	await _phys(20)
	var c0: Vector3 = s.call("flap_centroid")
	_ok(bool(s.call("debug_grab_move_flap", Vector3(0.0, 0.1, 0.06))), "triangular flap can be dragged")
	await _phys(2)
	await _frames(2)
	var c1: Vector3 = s.call("flap_centroid")
	_ok(c1.distance_to(c0) > 0.02, "dragged triangular flap moves (%.0f mm)" % (c1.distance_to(c0) * 1000.0))
	_ok(bool(s.call("debug_throw_flap", Vector3(0.6, 0.4, 0.2))), "and can be thrown away")
	await _phys(8)
	# 剩下的切口仍可拉扯，肠子仍可夹出
	s.call("set_tool", "forceps")
	var hc := cw
	_ok(bool(s.call("debug_forceps_begin", hc + Vector3(0, 0.3, 0), Vector3.DOWN)), "forceps reach into the triangular opening")
	s.call("debug_forceps_end")
	s.call("restore_body")
	await _frames(3)
	_ok(not bool(s.get("free_flap_ready")), "restore clears the free-flap state")
