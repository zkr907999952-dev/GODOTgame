extends "res://scripts/tests/v0411_check.gd"
## 未发布（t82u）：手术拉钩方向总是远离创口（两侧唇 / 环切洞缘，选位置时不翻转）；
## 取出子宫的悬挂点在创口下缘（靠耻骨侧）、阴道过渡入口随之降低；取出后整颗子宫留在腹腔外不再挤回；
## 子宫悬挂 / 摆动每帧开销。
## 未发布（t91u）：手术取子宫时不再先上升（平移到创口中心）再出来，而是原位沿钳子拉出、从创口下缘出。
## 未发布（t92u）：输卵管起点每帧与宫角表面重合相连；输卵管更长、有弹性（夹住可拉长、松手回弹）。
##   godot --headless --path . -s res://scripts/tests/v0423_surgery_check.gd


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
		print("v0423_surgery_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_retractor_straight()
	await _check_retractor_ring()
	await _check_uterus_hang()
	await _check_uterus_trajectory()
	await _check_tubes()
	print("v0423_surgery_check: fails=", fails)
	quit(1 if fails > 0 else 0)


# ---------------------------------------------------------------- 1. 拉钩方向

func _nearest(outer, pts: PackedInt32Array, p: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var bd := 1e9
	for w in pts:
		var d: float = (outer.pos[w] as Vector3).distance_to(p)
		if d < bd:
			bd = d
			best = outer.pos[w]
	return best


## 一侧唇缘所有（非端点）候选顶点的拉钩方向：都远离对侧唇、相邻点连续不翻转。返回该侧平均方向（绑定空间）。
func _lip_dirs(tag: String, lip: PackedInt32Array, other: PackedInt32Array) -> Vector3:
	var outer = s.get("_outer")
	var cands: PackedInt32Array = s.call("_lip_candidates")
	var bad := 0
	var flips := 0
	var n := 0
	var prev := Vector3.ZERO
	var acc := Vector3.ZERO
	var worst_adj := 1.0
	for i in range(2, lip.size() - 2):
		var v := lip[i]
		if not cands.has(v) or other.has(v):
			continue
		var o: Vector3 = s.call("_lip_out_bind", v)
		var p: Vector3 = outer.pos[v]
		var away := p - _nearest(outer, other, p)
		n += 1
		acc += o
		if away.length() > 0.0003 and o.dot(away.normalized()) <= 0.2:
			bad += 1
		if prev != Vector3.ZERO:
			worst_adj = minf(worst_adj, prev.dot(o))
			if prev.dot(o) < 0.5:
				flips += 1
		prev = o
	print("RETR %s: %d lip vertices, %d not pointing away from the incision, %d flips, worst adjacent cos %.2f" % [tag, n, bad, flips, worst_adj])
	_ok(n >= 8 and bad == 0, "%s: every retractor direction points away from the incision (%d bad of %d)" % [tag, bad, n])
	_ok(flips == 0 and worst_adj > 0.8, "%s: the direction is continuous along the lip, never flips (worst cos %.2f)" % [tag, worst_adj])
	return acc.normalized() if acc.length_squared() > 1e-10 else Vector3.ZERO


## 光标沿唇缘移动时的预览拉钩：手柄（-z）方向稳定、远离切口。
func _ghost_sweep(tag: String, lip: PackedInt32Array, other: PackedInt32Array) -> void:
	if s.has_method("ensure_tool"):
		s.call("ensure_tool", "retractor")
	else:
		s.call("set_tool", "retractor")
	var outer = s.get("_outer")
	var prev := Vector3.ZERO
	var worst := 1.0
	var bad := 0
	var shown := 0
	for i in range(3, lip.size() - 3):
		var v := lip[i]
		var vw: Vector3 = s.call("_vert_world", v)
		var cam_o := vw + Vector3(0, 0.3, 0.02)
		s.call("hover_tool", cam_o, (vw - cam_o).normalized())
		if not bool(s.call("retractor_ghost_visible")):
			continue
		var g: Node3D = s.get("_retr_ghost")
		var handle := -g.global_transform.basis.z.normalized()
		var gv := int(s.get("_retr_ghost_vid"))
		if gv < 0:
			continue
		shown += 1
		var pw: Vector3 = s.call("_vert_world", gv)
		var near_b := _nearest(outer, other, outer.pos[gv])
		var near_w: Vector3 = s.call("_approx_world_bind", near_b)
		var pw_a: Vector3 = s.call("_approx_world_bind", outer.pos[gv])
		var away := pw_a - near_w
		if away.length() > 0.0005 and handle.dot(away.normalized()) <= 0.0:
			bad += 1
		if prev != Vector3.ZERO:
			worst = minf(worst, prev.dot(handle))
		prev = handle
	print("RETR %s ghost sweep: %d positions, %d pointing into the wound, worst adjacent cos %.2f" % [tag, shown, bad, worst])
	_ok(shown >= 6 and bad == 0, "%s: the placement preview always pulls away from the wound (%d bad of %d)" % [tag, bad, shown])
	_ok(worst > 0.8, "%s: the preview direction stays stable while choosing the spot (worst cos %.2f)" % [tag, worst])
	s.call("_hide_retractor_ghost")


func _place_and_check(tag: String, vid: int, other: PackedInt32Array) -> void:
	var outer = s.get("_outer")
	var near_b := _nearest(outer, other, outer.pos[vid])
	var gap0: float = (outer.pos[vid] as Vector3).distance_to(near_b)
	var k := int(s.call("retractor_count"))
	_ok(bool(s.call("place_retractor", vid)), "%s: retractor placed" % tag)
	var r: Node3D = (s.call("retractor_nodes") as Array)[k]
	var handle := -r.global_transform.basis.z.normalized()
	var pw: Vector3 = s.call("_approx_world_bind", outer.pos[vid])
	var nw: Vector3 = s.call("_approx_world_bind", near_b)
	var away := (pw - nw)
	var c := handle.dot(away.normalized()) if away.length() > 1e-5 else 0.0
	outer = s.get("_outer")
	var vid2: int = (s.get("_retractors") as Array)[k]["vid"]
	var gap1: float = (outer.pos[vid2] as Vector3).distance_to(_nearest(outer, other, outer.pos[vid2]))
	print("RETR %s placed: handle·away %.2f, lip gap %.1f → %.1f mm" % [tag, c, gap0 * 1000.0, gap1 * 1000.0])
	_ok(c > 0.3, "%s: the placed retractor's handle points away from the incision (cos %.2f)" % [tag, c])
	_ok(gap1 > gap0 + 0.001, "%s: placing it pulls the lip open, not pushed in (%.1f → %.1f mm)" % [tag, gap0 * 1000.0, gap1 * 1000.0])


func _check_retractor_straight() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "retr: straight cut")
	var lr: Array = s.call("cut_lips", 0)
	var left: PackedInt32Array = lr[0]
	var right: PackedInt32Array = lr[1]
	var dl := _lip_dirs("straight left lip", left, right)
	var dr := _lip_dirs("straight right lip", right, left)
	print("RETR straight: mean left·right %.2f" % dl.dot(dr))
	_ok(dl.dot(dr) < -0.8, "straight: the two lips pull in opposite directions (cos %.2f)" % dl.dot(dr))
	await _ghost_sweep("straight left", left, right)
	await _ghost_sweep("straight right", right, left)
	var n := left.size()
	await _place_and_check("straight left", left[n / 2], right)
	lr = s.call("cut_lips", 0)
	await _place_and_check("straight right", (lr[1] as PackedInt32Array)[(lr[1] as PackedInt32Array).size() / 2], lr[0])
	# 斜切口（另一种方向）同样成立。
	await _restart()
	_ok(_straight(nav + Vector3(-0.03, -0.02, 0), nav + Vector3(0.035, -0.08, 0)), "retr: oblique cut")
	lr = s.call("cut_lips", 0)
	var d2l := _lip_dirs("oblique left lip", lr[0], lr[1])
	var d2r := _lip_dirs("oblique right lip", lr[1], lr[0])
	_ok(d2l.dot(d2r) < -0.8, "oblique: the two lips pull in opposite directions (cos %.2f)" % d2l.dot(d2r))


func _check_retractor_ring() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "retr: ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	var lr: Array = s.call("cut_lips", 0)
	_lip_dirs("ring lip A", lr[0], lr[1])
	_lip_dirs("ring lip B", lr[1], lr[0])
	# 剥掉皮瓣后只剩一圈洞缘：一律朝洞外。
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "retr: flap peeled")
	await _phys(4)
	await _frames(8)
	var outer = s.get("_outer")
	var loops: Array = s.get("_hole_loops")
	var loop: PackedInt32Array = loops[loops.size() - 1] if not loops.is_empty() else PackedInt32Array()
	var cen := Vector3.ZERO
	for v in loop:
		cen += outer.pos[v]
	cen /= float(maxi(loop.size(), 1))
	var cands: PackedInt32Array = s.call("_lip_candidates")
	var bad := 0
	var n := 0
	for v2 in loop:
		if not cands.has(v2):
			continue
		var o: Vector3 = s.call("_lip_out_bind", v2)
		n += 1
		if o.dot(((outer.pos[v2] as Vector3) - cen).normalized()) <= 0.2:
			bad += 1
	print("RETR peeled hole rim: %d vertices, %d not pointing out of the hole" % [n, bad])
	_ok(n >= 8 and bad == 0, "peeled hole: every retractor pulls away from the hole (%d bad of %d)" % [bad, n])
	await _restart()


# ---------------------------------------------------------------- 2–4. 子宫悬挂

func _ab(p: Vector3) -> Vector3:
	return (_organ_rig().call("abdomen_frame") as Transform3D).affine_inverse() * p


func _check_uterus_hang() -> void:
	await _open_wound()
	var rim: PackedVector3Array = s.call("_gut_rim_world")
	var w: Vector3 = s.call("_wound_center_world")
	var low := 1e9
	for q in rim:
		low = minf(low, _ab(q).y)
	var w_ab := _ab(w)
	_ok(bool(s.call("debug_begin_extract", "uterus")), "hang: uterus extract starts")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 60.0)
	var so: Node = s.call("soft_organ", "uterus")
	if so == null:
		_ok(false, "hang: soft uterus exists")
		return
	var hang: Vector3 = s.call("uterus_hang_world")
	var h_ab := _ab(hang)
	print("ANCHOR wound centre ab.y %.1f cm, wound lower rim %.1f cm, hang point %.1f cm (navel = 0)" % [w_ab.y * 100, low * 100, h_ab.y * 100])
	_ok(h_ab.y <= w_ab.y - 0.012, "hang point is lowered toward the pubis (%.1f cm below the wound centre)" % ((w_ab.y - h_ab.y) * 100))
	_ok(h_ab.y >= low - 0.003 and hang.distance_to(w) <= float(so.get("HOLE_R")) + 1e-4, "hang point stays inside the lower part of the wound opening")
	# 拉出
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var cage: PackedVector3Array = so.get("_p")
	var aim: Vector3 = cage[cage.size() - 1]
	var cam_o := aim + outv * 0.12
	_ok(bool(s.call("debug_forceps_begin", cam_o, (aim - cam_o).normalized())), "hang: forceps grab the uterus")
	var dt := 1.0 / 60.0
	var tip: Vector3 = so.get("hold_pos")
	var pull_us := 0
	for i in 60:
		tip = tip.move_toward(w + outv * 0.02, 0.25 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		pull_us += int(so.get("last_step_usec"))
	for i2 in 60:
		tip += outv * (0.2 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		pull_us += int(so.get("last_step_usec"))
	_ok(int(s.call("extract_level", "uterus")) == 5, "hang: full pull reaches level 5")
	var tp: PackedVector3Array = so.call("transition_points")
	if not tp.is_empty():
		print("ANCHOR vaginal transition entry ab.y %.1f cm (wound centre %.1f cm)" % [_ab(tp[0]).y * 100, w_ab.y * 100])
		_ok(_ab(tp[0]).y <= w_ab.y - 0.01, "the vaginal transition enters at the lowered anchor (%.1f cm below the wound centre)" % ((w_ab.y - _ab(tp[0]).y) * 100))
	# 甩一下再松手
	var side: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	for j in 6:
		tip += side * (0.9 * dt)
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
	s.call("debug_forceps_end")
	var swing_us := 0
	var swing_guts := 0
	var reentry := 0
	var min_d := 1e9
	for k in 120:
		var t0 := Time.get_ticks_usec()
		s.call("_update_guts", dt)
		swing_guts += Time.get_ticks_usec() - t0
		swing_us += int(so.get("last_step_usec"))
		reentry += 6 - int(so.call("body_out_count"))
		min_d = minf(min_d, _min_body_d(so))
	for k2 in 360:
		s.call("_update_guts", dt)
		reentry += 6 - int(so.call("body_out_count"))
		min_d = minf(min_d, _min_body_d(so))
	var hang_guts := 0
	var hang_us := 0
	for k3 in 120:
		var t1 := Time.get_ticks_usec()
		s.call("_update_guts", dt)
		hang_guts += Time.get_ticks_usec() - t1
		hang_us += int(so.get("last_step_usec"))
	var cerv_ab := _ab(so.call("cervix_world"))
	var fund_ab := _ab(so.call("fundus_world"))
	print("HANG after 8 s: cervix ab.y %.1f cm, fundus ab.y %.1f cm (wound centre %.1f cm), body node re-entries %d, min body clearance %.1f mm, asleep=%s" % [cerv_ab.y * 100, fund_ab.y * 100, w_ab.y * 100, reentry, min_d * 1000, so.get("_asleep")])
	_ok(cerv_ab.y < w_ab.y - 0.01, "the cervix hangs below the wound centre (%.1f cm lower)" % ((w_ab.y - cerv_ab.y) * 100))
	_ok(reentry == 0, "no part of the extracted uterus slips back into the cavity while swinging / hanging (%d node-frames)" % reentry)
	_ok(min_d >= 0.0065, "the extracted uterus stays clear of the wound plane, mesh not sunk into the body (min %.1f mm)" % (min_d * 1000))
	# 试着用钳子把它推回去：仍留在体外（只有「放回」才收回）。
	cage = so.get("_p")
	aim = cage[cage.size() - 1]
	cam_o = aim + outv * 0.12
	if bool(s.call("debug_forceps_begin", cam_o, (aim - cam_o).normalized())):
		tip = so.get("hold_pos")
		for m in 60:
			tip -= outv * (0.6 * dt)
			s.call("debug_forceps_drag_to", tip)
			s.call("_update_guts", dt)
		s.call("debug_forceps_end")
		for m2 in 30:
			s.call("_update_guts", dt)
		print("PUSH-IN: body nodes outside %d/6, min clearance %.1f mm" % [int(so.call("body_out_count")), _min_body_d(so) * 1000])
		_ok(int(so.call("body_out_count")) == 6 and _min_body_d(so) >= 0.0, "pushing it with the forceps does not squeeze it back inside")
	_check_transition_ok(so, w)
	var sw_avg := float(swing_us) / 120.0
	var sg_avg := float(swing_guts) / 120.0
	var hg_avg := float(hang_guts) / 120.0
	print("COST pull step %.0f µs | swing step %.0f µs, swing _update_guts %.0f µs | hanging _update_guts %.0f µs, step %.0f µs" % [float(pull_us) / 120.0, sw_avg, sg_avg, hg_avg, float(hang_us) / 120.0])
	_ok(sw_avg < 800.0, "swinging uterus step is cheap (%.0f µs < 800)" % sw_avg)
	_ok(hg_avg < 180.0, "a still hanging uterus costs almost nothing per frame (%.0f µs < 180)" % hg_avg)
	# 放回仍然有效
	_ok(bool(s.call("debug_putback_organ", "uterus")), "hang: put-back starts")
	for m3 in 400:
		s.call("_update_guts", 1.0 / 30.0)
		if int(s.call("extract_level", "uterus")) == 0:
			break
	_ok(int(s.call("extract_level", "uterus")) == 0 and not bool(s.call("organ_source_hidden", "uterus")), "hang: put-back still returns the uterus")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


func _min_body_d(so: Node) -> float:
	var body: PackedVector3Array = so.get("_p")
	var wc: Vector3 = so.get("wound_center")
	var ov: Vector3 = so.get("outward")
	var m := 1e9
	for p in body:
		m = minf(m, (p - wc).dot(ov))
	return m


func _check_transition_ok(so: Node, wound: Vector3) -> void:
	var tl := float(so.call("transition_length"))
	_ok(tl > 0.0 and tl <= 0.035, "the short flesh-coloured vaginal transition is kept (%.1f cm)" % (tl * 100))


# ---------------------------------------------------------------- 5. t91u 取出轨迹：不先上升

func _check_uterus_trajectory() -> void:
	await _open_wound()
	var fr: Transform3D = _organ_rig().call("abdomen_frame")
	var inv := fr.affine_inverse()
	var w: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var aim_r: Array = _aim_at_kind("uterus")
	if aim_r.size() < 2 or not bool(s.call("debug_forceps_begin", aim_r[0], aim_r[1])):
		_ok(false, "trajectory: forceps grab the uterus")
		return
	var so: Node = s.call("soft_organ", "uterus")
	var hang_y := _ab(s.call("uterus_hang_world")).y
	var ref: Vector3 = s.get("_fc_ray_ref")
	var down := -fr.basis.y.normalized()
	var dt := 1.0 / 60.0
	var maxy_in := -1e9
	var exit_y := 1e9
	var hold_max_before_exit := -1e9
	for i in 150:
		s.call("_drag_forceps", ref + down * (0.0015 * i) + outv * 0.3, -outv)
		s.call("_update_guts", dt)
		var P: PackedVector3Array = so.get("_p")
		for b in P.size():
			if (P[b] - w).dot(outv) < -0.004:
				maxy_in = maxf(maxy_in, (inv * P[b]).y)
		var hp: Vector3 = so.get("hold_pos")
		var od := (hp - w).dot(outv)
		if od < 0.0 and exit_y > 1e8:
			hold_max_before_exit = maxf(hold_max_before_exit, (inv * hp).y)
		elif exit_y > 1e8:
			exit_y = (inv * hp).y
	s.call("debug_forceps_end")
	var wy := (inv * w).y
	print("TRAJ wound centre ab.y %.1f cm, hang %.1f cm, max ab.y of still-inside body nodes %.1f cm, hold max before exit %.1f cm, hold at exit %.1f cm" % [wy * 100, hang_y * 100, maxy_in * 100, hold_max_before_exit * 100, exit_y * 100])
	_ok(maxy_in <= hang_y + 0.004 and maxy_in < wy - 0.01, "trajectory: the uterus is not lifted toward the wound centre before it comes out (inside max %.1f cm, hang %.1f cm)" % [maxy_in * 100, hang_y * 100])
	_ok(exit_y < 1e8 and exit_y < wy - 0.01, "trajectory: it exits through the lower part of the wound (%.1f cm below the centre)" % ((wy - exit_y) * 100))
	_ok(hold_max_before_exit <= hang_y + 0.006 and hold_max_before_exit < wy - 0.01, "trajectory: the grip is never lifted toward the wound centre on the way out (max %.1f cm)" % (hold_max_before_exit * 100))
	var ec: Vector3 = s.call("uterus_exit_center", so.call("fundus_world"), w, outv)
	_ok((inv * ec).y <= wy - 0.01, "trajectory: the pull exit centre sits below the wound centre")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


# ---------------------------------------------------------------- 6. t92u 输卵管附着 / 弹性

func _tri_sd(P: PackedVector3Array, I: PackedInt32Array, q: Vector3) -> float:
	## 到网格的有符号距离（+ = 在子宫网格内侧）。
	var best := 1e9
	var sg := 1.0
	for f in range(0, I.size() - 2, 3):
		var a := P[I[f]]
		var b := P[I[f + 1]]
		var c := P[I[f + 2]]
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-14:
			continue
		n = n.normalized()
		var pl := q - n * (q - a).dot(n)
		var d := 1e9
		if (b - a).cross(pl - a).dot(n) >= 0 and (c - b).cross(pl - b).dot(n) >= 0 and (a - c).cross(pl - c).dot(n) >= 0:
			d = absf((q - a).dot(n))
		else:
			d = minf(q.distance_to(Geometry3D.get_closest_point_to_segment(q, a, b)), minf(q.distance_to(Geometry3D.get_closest_point_to_segment(q, b, c)), q.distance_to(Geometry3D.get_closest_point_to_segment(q, c, a))))
		if d < best:
			best = d
			sg = 1.0 if (q - a).dot(n) >= 0 else -1.0
	return best * sg


func _check_attach(so: Node, tag: String) -> void:
	var P: PackedVector3Array = so.call("_skin_all")
	var I: PackedInt32Array = so.get("_vis_idx")
	for side in 2:
		var tb: Dictionary = (so.get("_tubes") as Dictionary).get(side, {})
		if tb.is_empty():
			_ok(false, "tubes %s: tube %d exists" % [tag, side])
			continue
		var p: PackedVector3Array = tb["p"]
		var horn: Vector3 = so.call("horn_world", side)
		var hs := _tri_sd(P, I, horn)
		var s0 := _tri_sd(P, I, p[0])
		var s1 := _tri_sd(P, I, p[1])
		var gap := float(so.call("tube_head_gap", side))
		print("TUBE %s side %d: horn→mesh %.2f mm, tube head %.1f mm inside, first node %.1f mm outside, head gap %.3f mm" % [tag, side, hs * 1000, s0 * 1000, -s1 * 1000, gap * 1000])
		_ok(absf(hs) < 0.0005, "tubes %s: the attachment point lies on the uterus surface (side %d, %.2f mm)" % [tag, side, hs * 1000])
		_ok(s0 > 0.0 and s1 < 0.0, "tubes %s: the tube runs through the horn surface — start embedded, first node outside (side %d)" % [tag, side])
		_ok(gap < 0.0002, "tubes %s: tube start coincides with the horn every frame (side %d, %.3f mm)" % [tag, side, gap * 1000])


func _check_tubes() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
	s.call("debug_begin_extract", "uterus")
	s.call("debug_forceps_end")
	var so: Node = s.call("soft_organ", "uterus")
	for i in 40:
		s.call("debug_add_extract_charge", "uterus", 1.0, 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 60.0)
	_check_attach(so, "pulled")
	var worst_gap := 0.0
	for i2 in 240:
		s.call("_update_guts", 1.0 / 60.0)
		for sd in 2:
			worst_gap = maxf(worst_gap, float(so.call("tube_head_gap", sd)))
	_check_attach(so, "hanging")
	_ok(worst_gap < 0.0002, "tubes: no frame with a gap between tube and horn while hanging (%.3f mm)" % (worst_gap * 1000))
	var rl := float(so.call("tube_rest_length", 0))
	var straight := (so.call("horn_world", 0) as Vector3).distance_to(so.call("ovary_world", 0))
	print("TUBE rest length %.1f mm (0.4.14 tubes were ≈ 24 mm), hanging stretch %.3f / %.3f" % [rl * 1000, float(so.call("tube_stretch", 0)), float(so.call("tube_stretch", 1))])
	_ok(rl >= 0.045, "tubes are longer (%.1f mm ≥ 45 mm)" % (rl * 1000))
	_ok(float(so.call("tube_stretch", 0)) < 1.08 and float(so.call("tube_stretch", 1)) < 1.08, "tubes hang near their rest length under their own weight")
	# 夹住卵巢往外拉：弹性伸长（> 1.04 老上限）、仍连在宫角；松手回弹。
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var sidev: Vector3 = (_organ_rig().call("abdomen_frame") as Transform3D).basis.x.normalized()
	var ov: Vector3 = so.call("ovary_world", 0)
	var co := ov + outv * 0.1
	if not (bool(s.call("debug_forceps_begin", co, (ov - co).normalized())) and str(s.get("_fc_kind")) == "tube"):
		_ok(false, "tubes: forceps grab the ovary")
		return
	var dt := 1.0 / 60.0
	var t2 := ov
	var mx := 1.0
	for k in 90:
		t2 += (outv - sidev).normalized() * 0.3 * dt
		s.call("debug_forceps_drag_to", t2)
		s.call("_update_guts", dt)
		mx = maxf(mx, float(so.call("tube_stretch", 0)))
		worst_gap = maxf(worst_gap, float(so.call("tube_head_gap", 0)))
	s.call("debug_forceps_end")
	var back := []
	for k2 in 60:
		s.call("_update_guts", dt)
		if k2 % 20 == 19:
			back.append("%.3f" % float(so.call("tube_stretch", 0)))
	print("TUBE drag ovary: max stretch %.3f (old cap 1.04), head gap %.3f mm; after release %s" % [mx, worst_gap * 1000, ", ".join(back)])
	_ok(mx > 1.15 and mx <= 1.62, "tubes stretch elastically when the ovary is pulled (%.3f)" % mx)
	_ok(worst_gap < 0.0002, "tubes stay attached to the horn while stretched")
	_ok(float(so.call("tube_stretch", 0)) < 1.08, "tubes spring back after release (%.3f)" % float(so.call("tube_stretch", 0)))
	_check_attach(so, "released")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)
