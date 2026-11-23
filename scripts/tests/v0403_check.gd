extends "res://scripts/tests/v0402_check.gd"
## 0.4.03 自检：肚脐竖直直切 + 两把拉钩撑开无粘连 / 无横跨截面、两侧唇都能选中、肚脐处外翻间距加大；
## 肠子默认不外露、手术钳夹住腹腔内肠子扯出肠袢（夹住动画、一节节变长、系膜随节数增加、搭出创缘不穿腹壁、
## 锚点在腹腔内并跟随身体、可再次夹取、多段、四肢碰撞、无缝平铺贴图、拿取不抓肠子、复原清除）。
##   godot --headless --path . -s res://scripts/tests/v0403_check.gd   （V0403_ONLY=navel|forceps）


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
	_ok(presets.find("version/code=") >= 0, "export version 0.4.03 / 46")
	_ok(ResourceLoader.exists("res://assets/surgery/forceps.glb"), "forceps model (Overholt clamp from the kit) is in the project")
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	var only := OS.get_environment("V0403_ONLY")
	if only == "" or only == "navel":
		await _check_navel_retracted()
	if only == "" or only == "forceps":
		await _check_forceps()
	print("v0403_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _wall_stretched(lim: float) -> int:
	var wall: Geom.MeshData = s.get("_wall_md")
	var bad := 0
	for f in wall.face_count():
		for k in 3:
			if wall.pos[wall.idx[f * 3 + k]].distance_to(wall.pos[wall.idx[f * 3 + (k + 1) % 3]]) > lim:
				bad += 1
				break
	return bad


## 截面上横跨两侧的面：一个面的顶点分别靠近左唇和右唇（各自 4mm 内，且两唇相距 > 10mm）。
func _wall_across(left: PackedInt32Array, right: PackedInt32Array) -> int:
	var wall: Geom.MeshData = s.get("_wall_md")
	var outer: Geom.MeshData = s.get("_outer")
	var lp := PackedVector3Array()
	var rp := PackedVector3Array()
	for v in left:
		lp.append(outer.pos[v])
	for v2 in right:
		rp.append(outer.pos[v2])
	var bad := 0
	for f in wall.face_count():
		var hl := false
		var hr := false
		for k in 3:
			var p := wall.pos[wall.idx[f * 3 + k]]
			var dl := 1e9
			var dr := 1e9
			for q in lp:
				dl = minf(dl, Vector2(p.x - q.x, p.y - q.y).length())
			for q2 in rp:
				dr = minf(dr, Vector2(p.x - q2.x, p.y - q2.y).length())
			if dl < 0.004 and dr > 0.01:
				hl = true
			if dr < 0.004 and dl > 0.01:
				hr = true
		if hl and hr:
			bad += 1
	return bad


func _check_navel_retracted() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(0.001, 0.07, 0), nav + Vector3(-0.001, -0.06, 0)), "long vertical straight cut through the navel")
	_cut_quality("navel long vertical")
	var outer: Geom.MeshData = s.get("_outer")
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	var n := left.size()
	var bi := 0
	var bd := 1e9
	for i in n:
		var d := absf(outer.pos[left[i]].y - nav.y)
		if d < bd:
			bd = d
			bi = i
	# 肚脐处外翻间距加大
	var ev: Geom.MeshData = s.get("_outer_evert")
	var g_nav := ev.pos[left[bi]].distance_to(ev.pos[right[bi]])
	var far := clampi(bi + n / 4, 0, n - 1)
	var g_far := ev.pos[left[far]].distance_to(ev.pos[right[far]])
	_ok(g_nav > g_far * 1.3, "lips open wider at the navel (%.1f mm vs %.1f mm away from it)" % [g_nav * 1000.0, g_far * 1000.0])
	# 两侧唇都能被选中：射线对准右唇 / 左唇
	s.call("set_tool", "grab")
	for side in [1, -1]:
		var vid: int = left[bi] if side == 1 else right[bi]
		var vw: Vector3 = s.call("_vert_world", vid)
		var o := vw + Vector3(0, 0.3, 0)
		_ok(bool(s.call("begin_stroke", o, (vw - o).normalized())), "grab starts on the %s lip at the navel" % ("left" if side == 1 else "right"))
		_ok(int(s.get("_pull_lip")) == side and int(s.get("_pull_np")) >= 2, "grab picks the %s lip (topological side, polyline pull)" % ("left" if side == 1 else "right"))
		s.call("cancel_stroke")
	# 两把拉钩在肚脐处左右撑开
	_ok(bool(s.call("place_retractor", left[bi])), "retractor on the left lip at the navel")
	await _frames(2)
	left = s.get("_lip_left")
	right = s.get("_lip_right")
	_ok(bool(s.call("place_retractor", right[bi])), "retractor on the right lip at the navel")
	await _frames(2)
	for k in 2:
		var zax: Vector3 = (s.call("retractor_nodes")[k] as Node3D).global_transform.basis.z
		s.call("debug_drag_retractor", k, s.call("_to_ab_delta", -zax.normalized() * 0.02))
		await _phys(10)
	s.call("debug_bake_pull")
	outer = s.get("_outer")
	var sep := 1e9
	for i2 in range(maxi(bi - 2, 1), mini(bi + 3, n - 1)):
		sep = minf(sep, (s.call("_vert_world", left[i2]) as Vector3).distance_to(s.call("_vert_world", right[i2])))
	_ok(sep > 0.015, "retracted navel opening is wide open (min lip gap %.1f mm)" % (sep * 1000.0))
	var across := _wall_across(left, right)
	_ok(across == 0, "no section-wall band stretched across the opening (%d faces span both sides)" % across)
	# 左右唇各自只往自己一侧移动（另一侧没被误拉）
	var e0 := outer.pos[left[0]]
	var e1 := outer.pos[left[n - 1]]
	var dir2 := Vector2(e1.x - e0.x, e1.y - e0.y).normalized()
	var nrm2 := Vector2(-dir2.y, dir2.x)
	var wrong := 0
	for i3 in range(2, n - 2):
		var dl := Vector2(outer.pos[left[i3]].x - e0.x, outer.pos[left[i3]].y - e0.y).dot(nrm2)
		var dr := Vector2(outer.pos[right[i3]].x - e0.x, outer.pos[right[i3]].y - e0.y).dot(nrm2)
		if signf(dl) == signf(dr) or absf(dl - dr) < 0.001:
			wrong += 1
	_ok(wrong == 0, "left / right lips stay on their own side after retracting (%d mixed)" % wrong)
	await _restart()


func _hole_center() -> Vector3:
	var rim: PackedVector3Array = s.call("_gut_rim_world")
	var c := Vector3.ZERO
	for q in rim:
		c += q
	return c / float(maxi(rim.size(), 1))


func _check_forceps() -> void:
	await _restart()
	var btn: Button = hud.get("_btn_tool_forceps")
	_ok(btn != null and btn.text == "手术钳", "HUD has a 「手术钳」 tool button")
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
	await _frames(30)
	_ok(not bool(s.call("has_exposed_guts")), "by default no guts hang out of the open wound")
	s.call("set_tool", "forceps")
	_ok(str(s.call("current_tool")) == "forceps", "forceps tool selectable")
	var hc := _hole_center()
	var o := hc + Vector3(0, 0.3, 0)
	var d := (hc - o).normalized()
	# 点在皮肤上（离创口很远）不会夹出肠子
	var far := hc + Vector3(0.12, 0, 0)
	_ok(not bool(s.call("debug_forceps_begin", far + Vector3(0, 0.3, 0), Vector3.DOWN)), "clicking intact skin far from the wound grabs nothing")
	_ok(bool(s.call("debug_forceps_begin", o, d)), "forceps clamp the intestine inside the open cavity")
	await _frames(1)
	var ang0 := float(s.call("forceps_jaw_angle"))
	var fn: Node3D = s.call("forceps_node")
	_ok(fn != null and fn.visible and fn.find_child("JawPosX", true, false) != null, "forceps model shown with two jaw halves")
	await _frames(14)
	var ang1 := float(s.call("forceps_jaw_angle"))
	_ok(ang0 > 3.0 and ang1 < 0.5, "jaw-closing clamp animation (%.1f° -> %.1f°)" % [ang0, ang1])
	var rope: Node = (s.call("gut_ropes") as Array)[0]
	var n0 := int(rope.call("point_count"))
	var f0 := float(rope.get("fed_len"))
	var m0 := int(rope.get("mesentery_count"))
	# 往上、往侧面拉 → 一节节扯出
	var tip0: Vector3 = rope.get("hold_pos")
	for i in 60:
		var t := float(i + 1) / 60.0
		s.call("debug_forceps_drag_to", tip0 + Vector3(0.16 * t, 0.12 * t, 0.02 * t))
		await process_frame
	print("v0403: pulled tip distance %.0f mm" % ((rope.get("hold_pos") as Vector3).distance_to((rope.get("exit_a") as Vector3)) * 1000.0))
	var n1 := int(rope.call("point_count"))
	var f1 := float(rope.get("fed_len"))
	var m1 := int(rope.get("mesentery_count"))
	_ok(f1 > f0 + 0.2 and n1 > n0 + 6, "pulling further extrudes the gut segment by segment (%.0f -> %.0f mm, %d -> %d points)" % [f0 * 1000.0, f1 * 1000.0, n0, n1])
	_ok(m1 > m0 and m1 >= (n1 - 6) / 6 - 1, "mesentery springs scale with pulled segments (%d -> %d for %d points)" % [m0, m1, n1])
	var hp: Vector3 = rope.get("hold_pos")
	var pts: PackedVector3Array = rope.call("points")
	_ok(pts[int(rope.get("hold_index"))].distance_to(hp) < 1e-4, "held point follows the forceps tip")
	s.call("debug_forceps_end")
	await _frames(150)
	_ok(bool(s.call("has_exposed_guts")), "released gut stays out")
	print("v0403: gut update %.2f ms / frame" % (float(s.get("gut_update_usec")) / 1000.0))
	var clr := float(rope.call("min_skin_clearance"))
	_ok(clr > -0.003, "outside gut drapes over the skin, not through the abdominal wall (min clearance %.1f mm)" % (clr * 1000.0))
	_ok(int(rope.get("skin_pushes")) >= 0 and float(rope.call("hang_depth")) > 0.0, "gut hangs")
	# 锚点在腹腔内（创口平面以下），出口在创缘处
	var a: Vector3 = rope.get("anchor_a")
	var ea: Vector3 = rope.get("exit_a")
	hc = _hole_center()
	_ok(hc.y - a.y > 0.01, "gut anchor lies inside the cavity below the wound (%.1f mm)" % ((hc.y - a.y) * 1000.0))
	_ok(ea.distance_to(hc) < 0.05 and ea.y > a.y + 0.008, "gut exits through the wound opening")
	# 锚点跟随身体
	var skel: Node3D = s.get("_skel")
	var base := skel.position
	await _frames(2)
	a = rope.get("anchor_a")
	# 骨架根在物理帧里会被姿势系统拉回，所以同一帧里移动后直接刷新一次
	s.call("_update_guts", 0.0)
	a = rope.get("anchor_a")
	skel.position = base + Vector3(0.05, 0, 0)
	s.call("_update_guts", 0.0)
	var a2: Vector3 = rope.get("anchor_a")
	_ok(absf(a2.distance_to(a) - 0.05) < 0.006, "anchor follows the body (%.1f mm for 50 mm)" % (a2.distance_to(a) * 1000.0))
	skel.position = base
	await _frames(3)
	# 材质 / 贴图
	var gm := (rope as GeometryInstance3D).material_override as ShaderMaterial
	var tex = gm.get_shader_parameter("albedo_tex") if gm else null
	_ok(gm != null and bool(gm.get_shader_parameter("is_gut")) and tex is Texture2D and str(tex.resource_path).find("small_tile") >= 0, "pulled gut uses the seamless small-intestine tile texture")
	var organs: Node = s.get("_organs")
	_ok(gm in organs.get("_organ_mats"), "pulled gut peristalses with the internal intestine")
	var am: ArrayMesh = (rope as MeshInstance3D).mesh
	var fmt := am.surface_get_format(0)
	_ok((fmt & Mesh.ARRAY_FORMAT_CUSTOM0) != 0 and (fmt & Mesh.ARRAY_FORMAT_TANGENT) != 0, "tube has CUSTOM0 + tangents (normal map without seams)")
	var img: Image = (tex as Texture2D).get_image()
	if img:
		if img.is_compressed():
			img.decompress()
		var w := img.get_width()
		var h := img.get_height()
		var de := 0.0
		for y in range(0, h, 8):
			var c0 := img.get_pixel(0, y)
			var c1 := img.get_pixel(w - 1, y)
			de += absf(c0.r - c1.r) + absf(c0.g - c1.g) + absf(c0.b - c1.b)
		de /= float(h / 8)
		_ok(de < 0.08, "tile texture wraps seamlessly (edge diff %.3f)" % de)
	# 四肢胶囊
	var caps: Array = rope.get("capsules")
	_ok(caps.size() >= 10 and float(rope.call("min_capsule_clearance")) > -0.002, "gut does not clip into limb hitboxes (%d capsules)" % caps.size())
	# 拿取不抓肠子
	pts = rope.call("points")
	var mid := pts[pts.size() / 2]
	s.call("set_tool", "grab")
	s.call("begin_stroke", mid + Vector3(0, 0.3, 0), Vector3.DOWN)
	_ok(int(rope.get("hold_index")) == -1, "grab tool never drags the gut (flaps / skin only)")
	s.call("cancel_stroke")
	# 再次夹取已扯出的肠袢
	s.call("set_tool", "forceps")
	pts = rope.call("points")
	var r := rope.call("outside_range") as Vector2i
	var pk := pts[(r.x + r.y) / 2]
	_ok(bool(s.call("debug_forceps_begin", pk + Vector3(0, 0.3, 0), Vector3.DOWN)) and int(s.call("gut_pull_count")) == 1 and int(rope.get("hold_index")) > 0, "released gut can be re-grabbed with the forceps")
	s.call("debug_forceps_end")
	await _frames(3)
	# 第二段：瞄准创口里离第一段肠袢最远的位置
	var rim: PackedVector3Array = s.call("_gut_rim_world")
	pts = rope.call("points")
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
	_ok(bool(s.call("debug_forceps_begin", bestq + Vector3(0, 0.3, 0), Vector3.DOWN)) and int(s.call("gut_pull_count")) == 2, "a second gut loop can be pulled (%.0f mm from the first)" % (bestd * 1000.0))
	s.call("debug_forceps_end")
	s.call("restore_body")
	await _frames(3)
	_ok(not bool(s.call("has_exposed_guts")) and int(s.call("gut_pull_count")) == 0 and not (gm in organs.get("_organ_mats")), "restore body clears pulled guts")
