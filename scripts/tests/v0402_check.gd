extends SceneTree
## 0.4.02 自检：皮瓣不触发镜头避让、手术「复原」按键、拿取回弹更强、拉钩工具（预览 / 放置 / 垂直 / 拖动 / 不回弹 / 多把 / 复原清除）、
## 外露肠子（小肠材质、腔内锚点跟随蒙皮、中间系膜弹簧、蠕动、腿部命中箱碰撞）、切口经过肚脐无粘连、两条直切口交叉处无残留截面。
##   godot --headless --path . -s res://scripts/tests/v0402_check.gd

const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var main: Node
var player: CharacterBody3D
var vs: Node
var s: Node
var hud: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0402: OK   ", msg)
	else:
		fails += 1
		push_error("v0402: FAIL " + msg)


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
	_ok(presets.find("version/code=4") >= 0, "export version 0.4.02 / 45")
	_ok(ResourceLoader.exists("res://assets/surgery/retractor.glb"), "retractor model (tool #5, Retractor Roux) is in the project")
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	var only := OS.get_environment("V0402_ONLY")
	if only == "" or only == "ui":
		await _check_restore_button()
	if only == "" or only == "retr":
		await _check_grab_and_retractor()
	if only == "" or only == "navel":
		await _check_navel_cut()
	if only == "" or only == "cross":
		await _check_cross_cuts()
	if only == "" or only == "guts":
		await _check_flap_camera_and_guts()
	print("v0402_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _enter_bed() -> bool:
	var bed: Node = null
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
	if bed == null:
		_ok(false, "exam bed exists")
		return false
	player.global_position = (bed as Node3D).global_position + Vector3(1.2, 0.1, 0.0)
	player.reset_physics_interpolation()
	vs.call("_update_nearest")
	vs.call("try_enter")
	await _frames(8)
	await _phys(4)
	_ok(str(player.get("occupancy")) == "exam_bed", "on the exam bed")
	return str(player.get("occupancy")) == "exam_bed"


func _restart() -> void:
	s.call("restore_body")
	await _phys(3)
	if not bool(s.call("is_active")):
		s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(3)


func _straight(a: Vector3, b: Vector3) -> bool:
	s.call("set_cut_mode", "straight")
	if not bool(s.call("debug_set_straight_preview", a, b)):
		return false
	var ok := bool(s.call("confirm_cut", false))
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	return ok


# ---- 2. 复原按键 ----
func _check_restore_button() -> void:
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.04, -0.05, 0), nav + Vector3(0.04, -0.05, 0)), "cut for restore test")
	await _frames(3)
	var btn: Button = hud.get("_btn_surgery_restore")
	var ex: Button = hud.get("_btn_surgery_exit")
	_ok(btn != null and btn.visible and btn.text == "复原", "surgery mode shows a 「复原」 button")
	if btn and ex:
		_ok(btn.position.x > ex.position.x + 40.0 and absf(btn.position.y - ex.position.y) < 2.0, "「复原」 sits right of 「退出手术模式」 (%.0f vs %.0f)" % [btn.position.x, ex.position.x])
		btn.emit_signal("pressed")
		await _frames(3)
		_ok(not bool(s.get("cut_open")), "「复原」 restores the body like 设置→复原身体")
	await _restart()


# ---- 3 / 4. 拿取回弹 + 拉钩 ----
func _lip_mean_disp(ids: PackedInt32Array, rest0: PackedVector3Array, a: int, b: int) -> float:
	var outer: Geom.MeshData = s.get("_outer")
	var acc := 0.0
	for i in range(a, b):
		acc += outer.pos[ids[i]].distance_to(rest0[ids[i]])
	return acc / float(maxi(b - a, 1))


func _check_grab_and_retractor() -> void:
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "straight cut for grab / retractor")
	var outer: Geom.MeshData = s.get("_outer")
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	var n := left.size()
	var rest0 := outer.pos.duplicate()
	# 3. 拿取右唇，松手后明显回弹。
	s.call("set_tool", "grab")
	var mid_bind := (outer.pos[left[n / 2]] + outer.pos[right[n / 2]]) * 0.5
	var sd := (outer.pos[right[n / 2]] - outer.pos[left[n / 2]]).normalized()
	var wr: Vector3 = s.call("_approx_world_bind", mid_bind + sd * 0.01)
	var wm: Vector3 = s.call("_approx_world_bind", mid_bind)
	var off_r: Vector3 = s.call("_to_ab_delta", (wr - wm).normalized() * 0.02)
	_ok(bool(s.call("debug_drag_split_skin", off_r)), "grab pulls the right lip")
	var peak := float(s.call("split_skin_drag_offset"))
	s.call("debug_release_split_skin")
	await _phys(50)
	var after := float(s.call("split_skin_drag_offset"))
	_ok(peak > 0.008 and after < peak * 0.25, "released grab springs back strongly (peak %.1f mm -> %.1f mm)" % [peak * 1000.0, after * 1000.0])
	# 4. 拉钩：左唇中点。
	s.call("set_tool", "retractor")
	var vid := left[n / 2]
	var vw: Vector3 = s.call("_vert_world", vid)
	var cam_o := vw + Vector3(0, 0.3, 0.0)
	s.call("hover_tool", cam_o, (vw - cam_o).normalized())
	_ok(bool(s.call("retractor_ghost_visible")), "hovering the incision edge shows a ghost placement preview")
	_ok(bool(s.call("begin_stroke", cam_o, (vw - cam_o).normalized())), "click on the lip starts placement")
	s.call("end_stroke")
	await _frames(2)
	_ok(int(s.call("retractor_count")) == 1 and not bool(s.call("retractor_ghost_visible")), "click places one retractor")
	outer = s.get("_outer")
	var r0: Node3D = (s.call("retractor_nodes") as Array)[0]
	var vid0: int = (s.get("_retractors") as Array)[0]["vid"]
	var hook: Vector3 = r0.global_transform * Vector3(0, -0.0148, 0.066)
	var lipw: Vector3 = s.call("_vert_world", vid0)
	_ok(hook.distance_to(lipw) < 0.004, "hook sits on the lip edge (%.1f mm)" % (hook.distance_to(lipw) * 1000.0))
	var ta: Vector3 = s.call("_vert_world", left[n / 2 - 2])
	var tb: Vector3 = s.call("_vert_world", left[n / 2 + 2])
	var tang := (tb - ta).normalized()
	var zax := r0.global_transform.basis.z.normalized()
	_ok(absf(zax.dot(tang)) < 0.25, "retractor blade is perpendicular to the incision (|cos|=%.2f)" % absf(zax.dot(tang)))
	var dl0 := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	_ok(dl0 > 0.003, "placing the retractor pulls the lip outward (%.1f mm)" % (dl0 * 1000.0))
	# 拖动拉钩 → 唇缘进一步拉开，且不回弹。
	var outw: Vector3 = -zax
	_ok(bool(s.call("debug_drag_retractor", 0, s.call("_to_ab_delta", outw * 0.012))), "drag the placed retractor by its handle")
	await _phys(50)
	var dl1 := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	_ok(dl1 > dl0 + 0.003, "dragging the retractor widens the opening (%.1f -> %.1f mm)" % [dl0 * 1000.0, dl1 * 1000.0])
	var hook2: Vector3 = r0.global_transform * Vector3(0, -0.0148, 0.066)
	var lipw2: Vector3 = s.call("_vert_world", (s.get("_retractors") as Array)[0]["vid"])
	_ok(hook2.distance_to(lipw2) < 0.004, "retractor follows the lip it holds")
	# 再拿取别处 → 拉钩唇缘不回弹。
	s.call("set_tool", "grab")
	s.call("debug_drag_split_skin", off_r)
	s.call("debug_release_split_skin")
	await _phys(50)
	s.call("debug_bake_pull")
	var dl2 := _lip_mean_disp(left, rest0, n / 2 - 2, n / 2 + 3)
	_ok(dl2 > dl1 - 0.0015, "lip held by the retractor does not spring back (%.1f mm)" % (dl2 * 1000.0))
	# 多把拉钩
	_ok(bool(s.call("place_retractor", right[n / 2])) and int(s.call("retractor_count")) == 2, "multiple retractors can be placed")
	await _restart()
	_ok(int(s.call("retractor_count")) == 0, "restore body removes all retractors")


# ---- 6. 肚脐 ----
func _cut_quality(tag: String) -> void:
	var outer: Geom.MeshData = s.get("_outer")
	var inner: Geom.MeshData = s.get("_inner")
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	var n := mini(left.size(), right.size())
	_ok(inner.vert_count() == outer.vert_count(), "%s: inner wall stays 1:1" % tag)
	var shared := 0
	for i in range(1, n - 1):
		if left[i] == right[i]:
			shared += 1
	var bnd: Dictionary = s.call("_boundary_edges_raw", outer)
	var bv: Dictionary = {}
	for e in bnd:
		bv[(e as Vector2i).x] = true
		bv[(e as Vector2i).y] = true
	var stuck := 0
	for i2 in range(1, n - 1):
		if not bv.has(left[i2]) or not bv.has(right[i2]):
			stuck += 1
	var lset: Dictionary = {}
	var rset: Dictionary = {}
	for i3 in range(1, n - 1):
		lset[left[i3]] = true
		rset[right[i3]] = true
	var bridging := 0
	var sliver := 0
	var worst := 1.0
	for f in outer.face_count():
		var hl := false
		var hr := false
		for k in 3:
			var v := outer.idx[f * 3 + k]
			hl = hl or lset.has(v)
			hr = hr or rset.has(v)
		if hl and hr:
			bridging += 1
		if hl or hr:
			var q := Geom.tri_quality(outer.pos[outer.idx[f * 3]], outer.pos[outer.idx[f * 3 + 1]], outer.pos[outer.idx[f * 3 + 2]])
			worst = minf(worst, q)
			if q < 0.05:
				sliver += 1
	_ok(n > 4 and shared == 0 and stuck == 0 and bridging == 0, "%s: lips fully separated (pts=%d shared=%d stuck=%d bridging=%d)" % [tag, n, shared, stuck, bridging])
	_ok(sliver == 0, "%s: no sliver / broken faces along the lips (slivers=%d worst q=%.3f)" % [tag, sliver, worst])
	# 切线不能来回折返 / 锯齿；左右唇在整条切口上始终各在一侧，不交错（交错 = 粘连 / 破面）。
	var eb: PackedVector3Array = s.get("last_embedded_bind")
	var e0 := eb[0]
	var e1 := eb[eb.size() - 1]
	var dir2 := Vector2(e1.x - e0.x, e1.y - e0.y).normalized()
	var nrm2 := Vector2(-dir2.y, dir2.x)
	var back := 0
	var dev := 0.0
	var prev_a := -1e9
	for e in eb:
		var a5 := Vector2(e.x - e0.x, e.y - e0.y).dot(dir2)
		if a5 < prev_a - 1e-5:
			back += 1
		prev_a = a5
		dev = maxf(dev, absf(Vector2(e.x - e0.x, e.y - e0.y).dot(nrm2)))
	_ok(back == 0 and dev < 0.0015, "%s: embedded cut runs straight, no backtracking (backtracks=%d max off-line %.2f mm)" % [tag, back, dev * 1000.0])
	var crossed := 0
	var sgn := 0.0
	var minsep := 1.0
	for i5 in range(1, n - 1):
		var dlr := outer.pos[left[i5]] - outer.pos[right[i5]]
		var sep := Vector2(dlr.x, dlr.y).dot(nrm2)
		if sgn == 0.0:
			sgn = signf(sep)
		if sep * sgn <= 0.0:
			crossed += 1
		minsep = minf(minsep, sep * sgn)
	_ok(crossed == 0 and minsep > 0.0008, "%s: left / right lips never cross (crossed=%d min separation %.2f mm)" % [tag, crossed, minsep * 1000.0])
	var ev: Geom.MeshData = s.get("_outer_evert")
	var gap := 0.0
	if ev and ev.vert_count() == outer.vert_count():
		for i4 in range(n / 4, 3 * n / 4):
			gap += ev.pos[left[i4]].distance_to(ev.pos[right[i4]])
		gap /= float(maxi(3 * n / 4 - n / 4, 1))
	_ok(gap > 0.004, "%s: everted lips actually open along the middle (mean gap %.1f mm)" % [tag, gap * 1000.0])
	var wall: Geom.MeshData = s.get("_wall_md")
	var ws := 0
	for f2 in wall.face_count():
		if Geom.tri_quality(wall.pos[wall.idx[f2 * 3]], wall.pos[wall.idx[f2 * 3 + 1]], wall.pos[wall.idx[f2 * 3 + 2]]) < 0.02:
			ws += 1
	_ok(ws == 0, "%s: section wall has no degenerate faces (%d)" % [tag, ws])


func _check_navel_cut() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, 0.0, 0), nav + Vector3(0.045, 0.002, 0)), "horizontal straight cut through the navel")
	_cut_quality("navel horizontal")
	await _restart()
	_ok(_straight(nav + Vector3(0.001, 0.045, 0), nav + Vector3(-0.001, -0.045, 0)), "vertical straight cut through the navel")
	_cut_quality("navel vertical")
	await _restart()
	_ok(_straight(nav + Vector3(-0.04, 0.006, 0), nav + Vector3(0.04, 0.004, 0)), "straight cut grazing the navel")
	_cut_quality("navel graze")


# ---- 7. 交叉直切口 ----
func _check_cross_cuts() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, -0.06, 0.0)
	_ok(_straight(c + Vector3(-0.045, 0, 0), c + Vector3(0.045, 0.002, 0)), "cross: first straight cut")
	var p0 := c + Vector3(0.001, 0.04, 0)
	var p1 := c + Vector3(-0.001, -0.04, 0)
	_ok(_straight(p0, p1), "cross: second straight cut crosses the first (X)")
	var wall: Geom.MeshData = s.get("_wall_md")
	# 截面不能横跨第二刀的开口（旧截面在交叉处残留会挡住角上的皮瓣）。
	var d2 := Vector2(p1.x - p0.x, p1.y - p0.y).normalized()
	var nrm2 := Vector2(-d2.y, d2.x)
	var bridging := 0
	for f in wall.face_count():
		var sp := 0
		var sn := 0
		for k in 3:
			var q := wall.pos[wall.idx[f * 3 + k]]
			var along := Vector2(q.x - p0.x, q.y - p0.y).dot(d2)
			if along < 0.0 or along > Vector2(p1.x - p0.x, p1.y - p0.y).length():
				continue
			var sd := Vector2(q.x - p0.x, q.y - p0.y).dot(nrm2)
			if sd > 0.0015:
				sp += 1
			elif sd < -0.0015:
				sn += 1
		if sp > 0 and sn > 0:
			bridging += 1
	_ok(bridging == 0, "cross: no section-wall faces bridge the crossing cut (%d)" % bridging)
	# 第一刀的旧截面在第二刀开口处的那一段必须去掉。
	var parts: Array = s.get("_wall_parts")
	var old_near := 0
	for pi in parts.size() - 1:
		var pm: Geom.MeshData = (parts[pi] as Dictionary)["md"]
		for f3 in pm.face_count():
			var cc := pm.centroid(f3)
			if Geom._dist_point_seg_2d(Vector2(cc.x, cc.y), Vector2(p0.x, p0.y), Vector2(p1.x, p1.y)) < 0.0025:
				old_near += 1
	_ok(int(s.get("cross_faces_cleared")) > 0 and old_near == 0, "cross: leftover first-cut section at the crossing is removed (cleared %d, left %d)" % [int(s.get("cross_faces_cleared")), old_near])
	var outer: Geom.MeshData = s.get("_outer")
	var inner: Geom.MeshData = s.get("_inner")
	_ok(inner.vert_count() == outer.vert_count(), "cross: inner stays 1:1")
	# 角上的皮瓣：拿取第二刀一侧可以拉开。
	s.call("set_tool", "grab")
	var wr: Vector3 = s.call("_approx_world_bind", c + Vector3(0.012, 0.012, 0))
	var wm: Vector3 = s.call("_approx_world_bind", c + Vector3(0.0, 0.012, 0))
	_ok(bool(s.call("debug_drag_split_skin", s.call("_to_ab_delta", (wr - wm).normalized() * 0.02))), "cross: corner flap can be grabbed open")
	_ok(float(s.call("split_skin_drag_offset")) > 0.006, "cross: corner flap opens (%.1f mm)" % (float(s.call("split_skin_drag_offset")) * 1000.0))
	s.call("debug_release_split_skin")
	s.call("set_tool", "scalpel")
	# T 型：第三刀止于第一刀
	await _restart()
	_ok(_straight(c + Vector3(-0.045, 0, 0), c + Vector3(0.045, 0.002, 0)), "T: first straight cut")
	_ok(_straight(c + Vector3(0.0, 0.045, 0), c + Vector3(0.0, 0.0005, 0)), "T: second cut ends on the first (T)")
	var outer2: Geom.MeshData = s.get("_outer")
	_ok((s.get("_inner") as Geom.MeshData).vert_count() == outer2.vert_count(), "T: inner stays 1:1, no errors")


# ---- 1 / 5 ----
func _check_flap_camera_and_guts() -> void:
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
	await _frames(6)
	# ---- 1. 皮瓣不挡镜头 ----
	var fl: Node3D = s.get("flap_node")
	_ok(fl != null and fl.is_in_group("camera_ignore"), "peeled flap is in the camera_ignore group")
	if fl:
		var cos_: Array = []
		if fl is CollisionObject3D:
			cos_.append(fl)
		for n in fl.find_children("*", "CollisionObject3D", true, false):
			cos_.append(n)
		var all_ign := true
		for co in cos_:
			all_ign = all_ign and bool(player.call("debug_camera_ignores", co))
		_ok(all_ign, "camera collision avoidance ignores the flap's colliders (%d)" % cos_.size())
	# ---- 5. 外露肠子：0.4.03 起默认不外露，改由手术钳扯出（见 v0403_check） ----
	_ok(not bool(s.call("has_exposed_guts")), "0.4.03: guts no longer spill out by themselves")


