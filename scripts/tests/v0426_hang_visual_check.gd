extends "res://scripts/tests/v0411_check.gd"
## 未发布（t99u）：手术扯出的子宫在角色走动时不闪烁 / 重影（手术系统与 organ_rig 用同一套渲染一致的
## 骨架 / 腹部变换），悬挂的阴道过渡管从体内阴道顶端接出（纯视觉，物理不变）。
##   godot --headless --path . -s res://scripts/tests/v0426_hang_visual_check.gd

const SS := preload("res://scripts/surgery/surgery_system.gd")

var org: Node
var so: Node
var rec: Array = []
var _walk_from := Vector3.INF


class Late extends Node:
	var cb: Callable
	func _process(_d):
		cb.call()


func _run() -> void:
	_check_fix_math()
	_check_source()
	root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	s = player.call("get_surgery")
	org = player.call("get_organs")
	player.call("set_play_mode", 0)
	await _frames(6)
	await _phys(6)
	hud.call("_refresh_surgery_ui")
	(hud.get("_btn_surgery_enter") as Button).emit_signal("pressed")
	for i in 10:
		await _phys(1); await _frames(1)
	s.call("ensure_tool", "scalpel")
	var navr: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "ring")
	s.call("debug_set_ring_preview", navr + Vector3(0.0, 0.035, 0.0), 0.03, 0.022)
	s.call("confirm_cut", false)
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	s.call("peel_flap")
	for i in 12:
		await _phys(1); await _frames(1)
	s.call("set_tool", "forceps")
	s.call("set_forceps_mode", "pull")
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extraction starts")
	so = s.call("soft_organ", "uterus")
	s.call("debug_forceps_end")
	for i in 40:
		s.call("debug_add_extract_charge", "uterus", 1.0, 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 60.0)
	for i in 200:
		s.call("_update_guts", 1.0 / 60.0)
	_ok(so != null and bool(so.call("is_extracted")), "uterus is extracted")
	if so == null:
		_done()
		return
	_check_transition_visual()
	_check_physics_untouched()
	s.call("exit_surgery")
	for i in 10:
		await _phys(1); await _frames(1)
	_ok(bool(s.get("persist")) and bool(so.call("is_extracted")), "extracted uterus persists after leaving surgery")
	player.call("set_play_mode", 1)
	for i in 20:
		await _phys(1); await _frames(1)
	_ok(bool(so.call("is_extracted")), "uterus still hanging in control mode")
	for tps in [20, 60]:
		await _walk(tps)
	_check_transition_visual()
	Engine.physics_ticks_per_second = 60
	_done()


func _done() -> void:
	print("v0426_hang_visual_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_fix_math() -> void:
	var live := Transform3D(Basis(Vector3.UP, 0.3), Vector3(1.0, 0.0, 2.0))
	var stale := Transform3D(Basis(Vector3.UP, 0.28), Vector3(0.96, 0.0, 1.95))
	var far := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	_ok(SS.ab_fix_for(live, live, false).is_equal_approx(Transform3D.IDENTITY), "fix: live == interpolated → no correction")
	_ok(SS.ab_fix_for(live, stale, true).is_equal_approx(Transform3D.IDENTITY), "fix: engine-interpolated body → keep organ_rig's interpolated frame")
	var fx := SS.ab_fix_for(live, stale, false)
	_ok((fx * stale).is_equal_approx(live), "fix: non-interpolated body with a stale interpolated value → frame moved to the live (rendered) body")
	_ok(SS.ab_fix_for(live, far, false).is_equal_approx(Transform3D.IDENTITY), "fix: organ_rig already fell back to live (> 0.5 m) → no correction")


func _check_source() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/surgery/surgery_system.gd")
	_ok(src.count("_skel.global_transform") == 1, "surgery_system reads the skeleton transform only through _skel_xf() (%d direct reads)" % src.count("_skel.global_transform"))
	_ok(src.count("_organs.call(\"abdomen_frame\")") == 1, "surgery_system reads the abdomen frame only through _ab_frame()")
	_ok(src.find("set_canal_stretch\", _to_organ_world(") >= 0, "canal stretch target is converted back to organ_rig's frame")


func _ab(p: Vector3) -> Vector3:
	return (s.call("_ab_frame") as Transform3D).affine_inverse() * p


func _check_transition_visual() -> void:
	var tp: PackedVector3Array = so.call("transition_points")
	var st: PackedVector3Array = so.call("transition_stump_points")
	var inner: PackedVector3Array = so.call("transition_inner_points")
	_ok(st.size() >= 2 and tp.size() == inner.size() + st.size(), "transition = inner (in-body) part + exposed stump (%d + %d)" % [inner.size(), st.size()])
	if st.size() < 2:
		return
	var tn: Node3D = so.get("_tether_node")
	_ok(tn != null and tn.visible and int(tn.call("point_count")) == tp.size(), "the hanging vagina tube is drawn with the in-body part")
	var apex: Vector3 = so.call("canal_os_world")
	# 同一帧的腹部坐标里比：着色器的阴道顶端 _canal_os_now 与过渡管起点所在的顶端。
	var vag_now: Vector3 = org.get("_canal_os_now")
	var apex_org: Vector3 = (so.get("_frame") as Transform3D).affine_inverse() * apex
	print("TRANSITION inner %d pts, start→vagina apex %.1f mm, apex vs shader os %.1f mm, in-body length %.1f cm, stump %.1f cm" % [inner.size(), tp[0].distance_to(apex) * 1000, apex_org.distance_to(vag_now) * 1000, _len(inner) * 100, float(so.call("transition_length")) * 100])
	_ok(inner.size() >= 3, "the tube has an in-body part back to the internal vagina")
	_ok(tp[0].distance_to(apex) <= 0.0065, "the tube starts at (inside) the internal vagina apex (%.1f mm)" % (tp[0].distance_to(apex) * 1000))
	_ok(apex_org.distance_to(vag_now) <= 0.002, "that apex is where the canal shader puts the internal vagina's top (%.1f mm)" % (apex_org.distance_to(vag_now) * 1000))
	var w: Vector3 = so.get("wound_center")
	var o: Vector3 = so.get("outward")
	var deepest := 0.0
	var max_out := -1e9
	for p in inner:
		deepest = minf(deepest, (p - w).dot(o))
		max_out = maxf(max_out, (p - w).dot(o))
	_ok(deepest < -0.015, "the tube starts deep in the body, not at the abdominal wall (%.1f cm under the wound)" % (-deepest * 100))
	_ok(max_out <= -0.005, "the in-body part stays under the wound plane (max %.1f mm)" % (max_out * 1000))
	var seg := 0.0
	for i in range(1, inner.size()):
		seg = maxf(seg, inner[i - 1].distance_to(inner[i]))
	_ok(inner[inner.size() - 1].distance_to(st[0]) <= seg * 1.2 + 1e-4, "in-body part joins the stump entry (%.1f mm, segments ≤ %.1f mm)" % [inner[inner.size() - 1].distance_to(st[0]) * 1000, seg * 1000])
	var worst := 0.0
	for i in range(1, tp.size() - 1):
		var a := (tp[i] - tp[i - 1]).normalized()
		var b := (tp[i + 1] - tp[i]).normalized()
		if (tp[i] - tp[i - 1]).length() > 1e-5 and (tp[i + 1] - tp[i]).length() > 1e-5:
			worst = maxf(worst, rad_to_deg(acos(clampf(a.dot(b), -1.0, 1.0))))
	_ok(worst <= 60.0, "the tube has no sharp kink (worst %.0f°)" % worst)
	_ok(st[st.size() - 1].distance_to(so.call("cervix_world")) <= 1e-4, "the tube still ends at the cervix")


func _len(a: PackedVector3Array) -> float:
	var l := 0.0
	for i in range(1, a.size()):
		l += a[i - 1].distance_to(a[i])
	return l


func _check_physics_untouched() -> void:
	var x0: PackedVector3Array = (so.get("_x") as PackedVector3Array).duplicate()
	var p0: PackedVector3Array = (so.get("_p") as PackedVector3Array).duplicate()
	for i in 3:
		so.call("transition_points")
		so.call("transition_inner_points")
	var same := x0 == (so.get("_x") as PackedVector3Array) and p0 == (so.get("_p") as PackedVector3Array)
	_ok(same, "drawing the in-body vagina part does not touch the tether / uterus physics")


func _walk(tps: int) -> void:
	rec.clear()
	Engine.physics_ticks_per_second = tps
	if _walk_from == Vector3.INF:
		_walk_from = player.global_position
	player.global_position = _walk_from
	player.set("velocity", Vector3.ZERO)
	for i in 6:
		await _phys(1); await _frames(1)
	var late := Late.new()
	late.process_priority = 1000000
	late.cb = _late
	root.add_child(late)
	var start := player.global_position
	Input.action_press("move_forward")
	for i in 150:
		await process_frame
	Input.action_release("move_forward")
	late.queue_free()
	await _frames(2)
	var moved := player.global_position.distance_to(start)
	var lag := 0.0
	var wgap := 0.0
	var dd := 0.0
	var tdd := 0.0
	for k in rec.size():
		lag = maxf(lag, rec[k][0])
		wgap = maxf(wgap, rec[k][1])
		if k > 0 and k < rec.size() - 1:
			dd = maxf(dd, ((rec[k][2] as Vector3) - ((rec[k - 1][2] as Vector3) + (rec[k + 1][2] as Vector3)) * 0.5).length())
			tdd = maxf(tdd, ((rec[k][3] as Vector3) - ((rec[k - 1][3] as Vector3) + (rec[k + 1][3] as Vector3)) * 0.5).length())
	print("WALK %d Hz physics: moved %.2f m, frames %d, frame lag %.2f mm, wound vs rendered rim %.2f mm, fundus jitter %.2f mm, tube-start jitter %.2f mm" % [tps, moved, rec.size(), lag * 1000, wgap * 1000, dd * 1000, tdd * 1000])
	_ok(moved > 0.3, "%d Hz: the character walked (%.2f m)" % [tps, moved])
	_ok(lag <= 1e-4, "%d Hz: the uterus is stepped with this frame's body frame (lag %.2f mm)" % [tps, lag * 1000])
	_ok(wgap <= 5e-4, "%d Hz: hang wound centre matches the rendered wound rim (%.2f mm)" % [tps, wgap * 1000])
	_ok(dd <= 0.002, "%d Hz: no frame-to-frame back-and-forth of the uterus relative to the body (%.2f mm)" % [tps, dd * 1000])
	_ok(tdd <= 0.003, "%d Hz: the vagina tube start (internal vagina apex, rides the tether swing) follows the body smoothly (%.2f mm)" % [tps, tdd * 1000])


func _late() -> void:
	if so == null or not is_instance_valid(so):
		return
	var fr_used: Transform3D = so.get("_frame")
	var fr: Transform3D = s.call("_ab_frame")
	var rim: PackedVector3Array = s.call("_gut_rim_world")
	var wc := Vector3.ZERO
	for q in rim:
		wc += q
	if rim.size() > 0:
		wc /= float(rim.size())
	var inv := fr.affine_inverse()
	var tp: PackedVector3Array = so.call("transition_points")
	rec.append([fr_used.origin.distance_to(fr.origin), (so.get("wound_center") as Vector3).distance_to(wc), inv * (so.call("fundus_world") as Vector3), inv * tp[0] if tp.size() > 0 else Vector3.ZERO])
