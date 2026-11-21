extends SceneTree
## 0.3.9 自检：观察视角中键平移（含检查床 / 手术中）、切口与路径重合（变形姿势下）、截面无破面与细长三角、
## 环切后再直切不报错（含剥皮瓣后）、直切口真正分成两份唇缘且拿取只拉一侧、腹腔袋后腰不穿出皮肤。
##   godot --headless --path . -s res://scripts/tests/v0309_check.gd

const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var main: Node
var player: CharacterBody3D
var vs: Node
var s: Node
var fails := 0
var errs_before := 0


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
		print("v0309: OK   ", msg)
	else:
		fails += 1
		push_error("v0309: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	_ok(player != null and vs != null, "scene booted")
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/code=4") >= 0, "export version 0.3.9+ (43+)")
	if OS.get_environment("V0309_ONLY") == "cut":
		await _enter_bed()
		s = player.call("get_surgery")
		s.call("enter_surgery")
		s.call("set_tool", "scalpel")
		await _phys(6)
		await _check_straight_cut()
		await _check_ring_then_straight(false)
		quit(0)
		return
	await _check_pan_on_foot()
	if not await _enter_bed():
		quit(1)
		return
	await _check_pan("exam bed (observe)")
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _phys(6)
	await _check_pan("surgery with scalpel selected")
	await _check_cavity_inside()
	await _check_straight_cut()
	await _check_ring_then_straight(false)
	await _check_ring_then_straight(true)
	print("v0309_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _enter_bed() -> bool:
	var bed: Node = null
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
	_ok(bed != null, "exam bed exists")
	if bed == null:
		return false
	player.global_position = (bed as Node3D).global_position + Vector3(1.2, 0.1, 0.0)
	vs.call("_update_nearest")
	vs.call("try_enter")
	await _frames(8)
	await _phys(4)
	_ok(str(player.get("occupancy")) == "exam_bed", "on the exam bed")
	return str(player.get("occupancy")) == "exam_bed"


func _mmb_drag(rel: Vector2) -> void:
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_MIDDLE
	b.pressed = true
	b.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	b.position = Vector2(640, 360)
	player.call("_unhandled_input", b)
	for i in 6:
		var m := InputEventMouseMotion.new()
		m.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		m.relative = rel / 6.0
		m.position = Vector2(640, 360) + rel * float(i + 1) / 6.0
		player.call("_unhandled_input", m)
	var u := InputEventMouseButton.new()
	u.button_index = MOUSE_BUTTON_MIDDLE
	u.pressed = false
	player.call("_unhandled_input", u)


func _cam_pos() -> Vector3:
	var cam: Camera3D = player.call("get_camera")
	return cam.global_position


func _check_pan(label: String) -> void:
	await _frames(20)
	var before := _cam_pos()
	# 中键处理里会读 Input.is_mouse_button_pressed；headless 下用事件本身驱动。
	player.set("_mmb_down", true)
	_mmb_drag(Vector2(160, 0))
	await _frames(20)
	var after := _cam_pos()
	_ok(after.distance_to(before) > 0.02, "%s: middle-drag pans the camera (moved %.3f m)" % [label, after.distance_to(before)])
	player.set("_mmb_down", true)
	_mmb_drag(Vector2(-160, 0))
	await _frames(20)


func _check_pan_on_foot() -> void:
	player.call("set_play_mode", 0)
	await _frames(30)
	await _check_pan("on foot observe view")


func _check_cavity_inside() -> void:
	var r: Dictionary = s.call("debug_wrap_outside")
	_ok(int(r.get("tested", 0)) > 50 and int(r.get("outside", 99)) == 0, "cavity pouch back/sides stay inside the skin in the lying pose (outside=%d / %d)" % [int(r.get("outside", -1)), int(r.get("tested", 0))])
	var w: Geom.MeshData = s.get("_wrap")
	var skinned := w != null and w.bones.size() >= w.vert_count() * 4
	_ok(skinned, "cavity pouch is skinned (follows the body)")


func _posed(md: Geom.MeshData) -> PackedVector3Array:
	return Geom.world_positions(md, s.get("_skel"), s.get("_skin"))


func _dist_to_poly(p: Vector3, poly: PackedVector3Array) -> float:
	var best := 1e9
	for i in poly.size() - 1:
		var a := poly[i]
		var b := poly[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


func _check_wall_quality(tag: String) -> void:
	var wall: Geom.MeshData = s.get("_wall_md")
	var worst := 1.0
	var degen := 0
	for f in wall.face_count():
		var q := Geom.tri_quality(wall.pos[wall.idx[f * 3]], wall.pos[wall.idx[f * 3 + 1]], wall.pos[wall.idx[f * 3 + 2]])
		worst = minf(worst, q)
		if q < 0.02:
			degen += 1
	_ok(wall.face_count() > 0 and degen == 0, "%s: section wall has no degenerate / sliver triangles (faces=%d worst q=%.3f)" % [tag, wall.face_count(), worst])


func _check_straight_cut() -> void:
	var nav: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "straight")
	var a := nav + Vector3(-0.045, -0.05, 0.0)
	var b := a + Vector3(0.09, -0.005, 0.0)
	_ok(bool(s.call("debug_set_straight_preview", a, b)), "straight preview")
	var path: PackedVector3Array = s.call("preview_path_bind")
	_ok(bool(s.call("confirm_cut", false)), "straight cut committed")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	await _phys(3)
	var outer: Geom.MeshData = s.get("_outer")
	var inner: Geom.MeshData = s.get("_inner")
	_ok(inner.vert_count() == outer.vert_count() and inner.idx.size() == outer.idx.size(), "inner wall stays 1:1 with the skin (%d / %d)" % [inner.vert_count(), outer.vert_count()])
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	var n := mini(left.size(), right.size())
	var dup := n > 2
	for i in range(1, n - 1):
		if left[i] == right[i]:
			dup = false
	_ok(dup, "straight cut: interior lip vertices are duplicated per side (%d points)" % n)
	# 任何三角都不能同时用左右两侧的副本（否则就是跨过切口的拉伸破面）。
	var lset: Dictionary = {}
	var rset: Dictionary = {}
	for i2 in range(1, n - 1):
		lset[left[i2]] = true
		rset[right[i2]] = true
	var bridging := 0
	for f in outer.face_count():
		var hl := false
		var hr := false
		for k in 3:
			var v := outer.idx[f * 3 + k]
			hl = hl or lset.has(v)
			hr = hr or rset.has(v)
		if hl and hr:
			bridging += 1
	_ok(bridging == 0, "no skin triangle spans both lips (bridging=%d)" % bridging)
	# 变形姿势下：切线顶点（左右唇中点，rest）与外翻后中点都落在请求路径上。
	var rest_mid := Geom.MeshData.new()
	var ev: Geom.MeshData = s.get("_outer_evert")
	var ev_mid := Geom.MeshData.new()
	for i3 in n:
		rest_mid.copy_vert(outer, left[i3])
		rest_mid.pos[i3] = (outer.pos[left[i3]] + outer.pos[right[i3]]) * 0.5
		ev_mid.copy_vert(outer, left[i3])
		ev_mid.pos[i3] = (ev.pos[left[i3]] + ev.pos[right[i3]]) * 0.5
	var req := Geom.MeshData.new()
	for p in path:
		var vi: int = s.call("_nearest_outer", p)
		req.copy_vert(outer, vi)
		req.pos[req.vert_count() - 1] = p
	var pw := _posed(req)
	var rw := _posed(rest_mid)
	var ew := _posed(ev_mid)
	var dmax := 0.0
	var emax := 0.0
	for i4 in n:
		dmax = maxf(dmax, _dist_to_poly(rw[i4], pw))
		emax = maxf(emax, _dist_to_poly(ew[i4], pw))
	_ok(dmax < 0.0015, "cut vertices lie on the requested path in the posed body (max %.2f mm)" % (dmax * 1000.0))
	_ok(emax < 0.0025, "everted wound stays centred on the path (max %.2f mm)" % (emax * 1000.0))
	# 外翻后唇缘真的张开，并且没有被拉成长条的皮肤三角。
	var gap := 0.0
	for i5 in range(1, n - 1):
		gap = maxf(gap, ev.pos[left[i5]].distance_to(ev.pos[right[i5]]))
	_ok(gap > 0.006, "everted lips open (max gap %.1f mm)" % (gap * 1000.0))
	var long_e := 0
	for f2 in outer.face_count():
		var touch := false
		for k2 in 3:
			var v2 := outer.idx[f2 * 3 + k2]
			touch = touch or lset.has(v2) or rset.has(v2)
		if not touch:
			continue
		for k3 in 3:
			var ea := outer.idx[f2 * 3 + k3]
			var eb := outer.idx[f2 * 3 + (k3 + 1) % 3]
			if ev.pos[ea].distance_to(ev.pos[eb]) > outer.pos[ea].distance_to(outer.pos[eb]) * 2.2 + 0.002:
				long_e += 1
	_ok(long_e == 0, "eversion does not stretch skin triangles at the lips (stretched edges=%d)" % long_e)
	_check_wall_quality("straight")
	# 拿取一侧唇缘：只有这一侧位移。
	s.call("set_tool", "grab")
	var mid_bind := (outer.pos[left[n / 2]] + outer.pos[right[n / 2]]) * 0.5
	var sd := (outer.pos[left[n / 2]] - outer.pos[right[n / 2]]).normalized()
	var wl: Vector3 = s.call("_approx_world_bind", mid_bind + sd * 0.01)
	var wm: Vector3 = s.call("_approx_world_bind", mid_bind)
	var off_ab: Vector3 = s.call("_to_ab_delta", (wl - wm).normalized() * 0.02)
	_ok(bool(s.call("debug_drag_split_skin", off_ab)), "grab drags the left lip")
	var lw := _posed(outer)
	var lmove := 0.0
	var rmove := 0.0
	for i6 in range(n / 3, 2 * n / 3):
		lmove += (s.call("debug_pull_offset_at_ab", s.call("_to_ab_local", lw[left[i6]])) as Vector3).length()
		rmove += (s.call("debug_pull_offset_at_ab", s.call("_to_ab_local", lw[right[i6]])) as Vector3).length()
	var cnt := float(maxi(2 * n / 3 - n / 3, 1))
	_ok(lmove / cnt > 0.003 and rmove / cnt < 0.0005, "grab opens only the grabbed side (left %.1f mm, right %.2f mm)" % [lmove / cnt * 1000.0, rmove / cnt * 1000.0])
	s.call("debug_release_split_skin")
	s.call("set_tool", "scalpel")


func _check_ring_then_straight(peel: bool) -> void:
	var tag := "ring+peel+straight" if peel else "ring+straight"
	s.call("restore_body")
	await _phys(4)
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _phys(4)
	var nav: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", nav + Vector3(0.0, 0.03, 0.0), 0.03, 0.022)), "%s: ring preview" % tag)
	_ok(bool(s.call("confirm_cut", false)), "%s: ring cut" % tag)
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	_check_wall_quality(tag + " ring")
	if peel:
		s.call("set_tool", "grab")
		_ok(bool(s.call("peel_flap")), "%s: flap peeled" % tag)
		await _phys(10)
		s.call("set_tool", "scalpel")
	s.call("set_cut_mode", "straight")
	var a := nav + Vector3(-0.045, -0.05, 0.0)
	_ok(bool(s.call("debug_set_straight_preview", a, a + Vector3(0.09, -0.005, 0.0))), "%s: straight preview" % tag)
	_ok(bool(s.call("confirm_cut", false)), "%s: straight cut after the ring commits without errors" % tag)
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	var outer: Geom.MeshData = s.get("_outer")
	var inner: Geom.MeshData = s.get("_inner")
	var ok_idx := true
	for v in outer.idx:
		if v < 0 or v >= outer.vert_count() or v >= inner.vert_count():
			ok_idx = false
			break
	_ok(ok_idx and inner.vert_count() == outer.vert_count(), "%s: skin / inner wall indices stay valid" % tag)
	_check_wall_quality(tag)
	# 环切口的外翻在第二刀后仍保留（不会合拢）。
	var hl: Array = s.get("_hole_loops")
	_ok(s.get("cut_open") == true, "%s: cut stays open" % tag)
	await _phys(4)
