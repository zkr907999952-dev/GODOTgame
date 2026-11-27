extends "res://scripts/tests/v0411_check.gd"
## 0.4.17（t5u）：手术把子宫扯出体外后，阴道互动模式插入长柄钢球：
## 阴道 + 过渡管 + 体外子宫逐渐捋直，球穿过体外宫颈进宫腔（宫体包住球）；
## 大球往外拉 → 子宫跟着球经创口回到体内静止位 → 无跳变地接上普通子宫脱垂。
##   godot --headless --path . -s res://scripts/tests/v0431_check.gd

const DT := 1.0 / 60.0

var vm: Node
var ctl: Node
var org: Node
var lk: RefCounted


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
		print("v0431_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	var so := await _extract()
	_ok(so != null and bool(so.call("is_extracted")), "uterus pulled out of the abdominal wound (surgery)")
	if so == null:
		print("v0431_check: fails=", fails)
		quit(1)
		return
	org = player.call("get_organs")
	vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode with the uterus still hanging outside")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	ctl = vm.call("tool_controller")
	lk = ctl.call("link")
	_ok(ctl != null and lk != null, "ball rod + extracted-uterus link ready")
	ctl.call("set_diameter", 0.026)
	await _phys(2)
	await _check_insert(so)
	await _check_reel(so)
	print("v0431_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _extract() -> Node:
	await _open_wound()
	s.call("set_tool", "forceps")
	s.call("debug_begin_extract", "uterus")
	s.call("debug_forceps_end")
	var so: Node = s.call("soft_organ", "uterus")
	for i in 40:
		s.call("debug_add_extract_charge", "uterus", 1.0, 1.0 / 30.0)
		s.call("_update_guts", DT)
	for i2 in 200:
		s.call("_update_guts", DT)
	s.call("set_tool", "")
	return so


func _step(desired: float, n: int = 1) -> void:
	for i in n:
		ctl.call("debug_push_depth", desired, DT)
		await _phys(1)
		s.call("_update_guts", DT)


func _line_dev(pts: PackedVector3Array, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var L := ab.length()
	var worst := 0.0
	for p in pts:
		var t := clampf((p - a).dot(ab) / (L * L), 0.0, 1.0)
		worst = maxf(worst, p.distance_to(a + ab * t))
	return worst


func _tube_dev(so: Node) -> float:
	# 过渡管（阴道顶端 → 创口入口）偏离直线的最大距离
	var pts: PackedVector3Array = so.call("transition_points")
	if so.get("rod_tube_pts") is PackedVector3Array and (so.get("rod_tube_pts") as PackedVector3Array).size() >= 2:
		pts = so.get("rod_tube_pts")
	var V := (ctl.call("_opening_world") as Vector3) + (ctl.call("_axis_world") as Vector3) * float(ctl.call("_canal_length"))
	var E: Vector3 = (so.call("hang_point") as Vector3) - (so.get("outward") as Vector3) * 0.012
	var sub := PackedVector3Array()
	for p in pts:
		var t := (p - V).dot(E - V) / maxf((E - V).length_squared(), 1e-8)
		if t >= 0.05 and t <= 0.95:
			sub.append(p)
	return _line_dev(sub, V, E)


func _check_insert(so: Node) -> void:
	var r: float = float(ctl.call("radius"))
	var L: float = float(ctl.call("_canal_length"))
	var dev0 := _tube_dev(so)
	var tilt0 := (so.call("cervix_axis_world") as Vector3)
	# 1) 球在体外：不捋直
	ctl.call("debug_set_depth", -0.03)
	await _phys(3)
	_ok(float(lk.get("k")) < 0.01, "ball outside: nothing straightened yet (k=%.2f)" % float(lk.get("k")))
	# 2) 沿阴道慢慢推：k 逐渐变大（不是一下到位），阴道顶端回到静止轴
	var ks: Array = []
	var d := 0.0
	while d < L + 0.02:
		d += 0.003
		await _step(d, 2)
		ks.append(float(lk.get("k")))
	var mono := true
	var max_jump := 0.0
	for i in range(1, ks.size()):
		if float(ks[i]) < float(ks[i - 1]) - 1e-4:
			mono = false
		max_jump = maxf(max_jump, float(ks[i]) - float(ks[i - 1]))
	_ok(mono and max_jump < 0.2, "straightening grows gradually with insertion depth (max step %.2f)" % max_jump)
	await _step(L + 0.02, 40)
	_ok(float(lk.get("k")) > 0.98, "vagina + transition tube fully straightened when the ball reaches the vault (k=%.2f)" % float(lk.get("k")))
	var os_now: Vector3 = org.call("canal_os_now_world") if org.has_method("canal_os_now_world") else Vector3.ZERO
	var os_rest: Vector3 = ctl.call("_cervix_world")
	var root_w: Vector3 = so.call("root_world")
	var vk := float(so.get("rod_vault_k"))
	_ok(vk > 0.98, "vaginal vault pulled back onto the rod axis (vault_k=%.2f, os %.1f mm from rest)" % [vk, os_now.distance_to(os_rest) * 1000.0])
	var dev1 := _tube_dev(so)
	print("T5 tube deviation from straight: %.1f → %.1f mm" % [dev0 * 1000.0, dev1 * 1000.0])
	_ok(dev1 < 3.0e-3, "transition tube is a straight line vault → wound (%.1f mm)" % (dev1 * 1000.0))
	# 3) 继续推：经过渡管到体外宫颈，攒压力穿过宫颈进宫腔
	var s_c := float(lk.get("s_cervix"))
	var s_e := float(lk.get("s_entry"))
	print("T5 path: vault %.1f cm, wound %.1f cm, cervix %.1f cm, fundus %.1f cm" % [float(lk.get("s_vault")) * 100, s_e * 100, s_c * 100, float(lk.get("s_fundus")) * 100])
	_ok(s_c > s_e and s_e > L, "path order: vault < wound entry < external cervix")
	d = L + 0.02
	var max_tip_step := 0.0
	var prev_tip: Vector3 = ctl.call("tip_world")
	var tube_ok := true
	while d < s_c - r * 0.9:
		d += 0.004
		await _step(d, 2)
		var tp: Vector3 = ctl.call("tip_world")
		max_tip_step = maxf(max_tip_step, tp.distance_to(prev_tip))
		prev_tip = tp
		# 过渡管在球处被撑开、杆处至少杆余量
		var tube: PackedVector3Array = so.get("rod_tube_pts")
		var rad: PackedFloat32Array = so.get("rod_tube_radii")
		for i in tube.size():
			var dist: float = tube[i].distance_to(tp)
			if dist < r * 0.6 and rad[i] < r * 0.95:
				tube_ok = false
	_ok(tube_ok, "transition tube dilates around the ball while it passes")
	_ok(max_tip_step < 0.012, "ball slides smoothly through the conduit (max %.1f mm/step)" % (max_tip_step * 1000.0))
	var ku_mid := float(lk.get("ku"))
	for i2 in 90:
		await _step(s_c + r * 1.4, 1)
		if bool(ctl.get("through_cervix")):
			break
	_ok(bool(ctl.get("through_cervix")) and bool(ctl.call("is_in_uterus")), "ball pushed through the external cervix into the hanging uterus")
	await _step(float(ctl.get("depth")) + 0.01, 60)
	var ku := float(lk.get("ku"))
	var cax: Vector3 = so.call("cervix_axis_world")
	var ex: Vector3 = lk.get("exit_dir")
	var ang := rad_to_deg(cax.angle_to(ex))
	print("T5 uterus axis: tilt0 %.0f° → %.1f° from rod line (ku mid %.2f → %.2f)" % [rad_to_deg(tilt0.angle_to(ex)), ang, ku_mid, ku])
	_ok(ku > 0.98 and ang < 8.0, "hanging uterus straightened onto the rod line (%.1f°)" % ang)
	var P: PackedVector3Array = so.get("_p")
	var cav := float(so.call("rod_cavity_offset_max"))
	_ok(cav < 0.001, "curved uterine cavity straightened onto the rod (%.1f mm left)" % (cav * 1000.0))
	var out_n := int(so.call("body_out_count"))
	_ok(out_n >= 4, "uterus is still outside the body while threaded on the rod (%d nodes out)" % out_n)
	# 宫腔包住球
	var cl := float(so.call("rod_ball_clearance", r))
	print("T5 ball in hanging uterus: clearance %.2f mm" % (cl * 1000.0))
	_ok(cl > 0.0, "hanging uterus wall wraps the ball (clearance %.2f mm)" % (cl * 1000.0))
	# 撑开映射单调：原来离球心更远的点撑开后仍更远（内膜追不上外膜），球处壁厚 ≥ 子宫壁厚
	var c0: Vector3 = so.get("rod_ball_center")
	var axb: Vector3 = (c0 - (so.get("rod_shaft_entry") as Vector3)).normalized()
	var pa := axb.cross(Vector3.UP).normalized()
	var pb := axb.cross(pa).normalized()
	var dirs := [pa, pb, (pa + pb).normalized(), axb, (axb + pa).normalized()]
	var mono_ok := true
	for dv in dirs:
		var prev_d := -1.0
		for j in 60:
			var dd0 := 0.0005 * float(j + 1)
			var pp: Vector3 = so.call("rod_push_point", c0 + (dv as Vector3) * dd0)
			var dn := pp.distance_to(c0)
			if dn <= prev_d:
				mono_ok = false
			prev_d = dn
	var thick := (so.call("rod_push_point", c0 + pa * 0.008) as Vector3).distance_to(c0) - (so.call("rod_push_point", c0 + pa * 0.0005) as Vector3).distance_to(c0)
	_ok(mono_ok and thick >= float(lk.call("uterus_wall")), "distension is monotone (no inner-over-outer), wall at the ball %.1f mm" % (thick * 1000.0))
	var q: Dictionary = so.call("debug_mesh_quality")
	_ok(bool(q.get("ok", false)), "soft uterus mesh stays clean while distended (%s)" % str(q))
	var tip: Vector3 = ctl.call("tip_world")
	var on_axis := _line_dev(PackedVector3Array([tip]), P[0], P[P.size() - 1])
	_ok(on_axis < 0.004, "ball sits on the uterus axis (%.1f mm)" % (on_axis * 1000.0))
	var bs: MeshInstance3D = ctl.call("debug_bent_shaft")
	_ok(bs != null and bs.visible, "rod follows the conduit (bent shaft shown)")
	# 小球：往外拉不卡住，不会带回
	ctl.call("set_diameter", 0.018)
	var dd := float(ctl.get("depth"))
	for i3 in 40:
		dd -= 0.004
		await _step(dd, 1)
		if not bool(ctl.get("through_cervix")):
			break
	_ok(not bool(lk.get("reeling")) and not bool(ctl.get("through_cervix")), "small ball pops back out of the cervix without catching")
	ctl.call("set_diameter", 0.026)
	await _phys(2)
	for i4 in 90:
		await _step(float(lk.get("s_cervix")) + 0.02, 1)
		if bool(ctl.get("through_cervix")):
			break
	await _step(float(ctl.get("depth")) + 0.005, 30)
	_ok(bool(ctl.call("is_in_uterus")), "big ball back inside the hanging uterus")


func _check_reel(so: Node) -> void:
	var r: float = float(ctl.call("radius"))
	var pc: Node = org.call("prolapse") if org.has_method("prolapse") else null
	# 往外拉（每帧 6 mm，> 触发速度）；模拟按住拖拽
	ctl.set("dragging", true)
	var d := float(ctl.get("depth"))
	var caught_reel := false
	for i in 30:
		d -= 0.006
		await _step(d, 1)
		if bool(lk.get("reeling")):
			caught_reel = true
			break
	_ok(caught_reel, "big ball pulled outward catches in the external cervix → uterus follows")
	if not caught_reel:
		return
	var total := float(lk.call("reel_total"))
	var rest_nodes := PackedVector3Array()
	for b in 6:
		rest_nodes.append(so.call("rest_node_world", b))
	var prev_nodes: PackedVector3Array = (so.get("_p") as PackedVector3Array).duplicate()
	var max_node_step := 0.0
	var out_hist: Array = []
	var clr_min := 1e9
	var steps := 0
	var tip_before := Vector3.ZERO
	var nodes_before := PackedVector3Array()
	var rest_gap := -1.0
	while bool(lk.get("reeling")) and steps < 400:
		d -= 0.005
		tip_before = ctl.call("tip_world")
		nodes_before = (so.get("_p") as PackedVector3Array).duplicate()
		await _step(d, 1)
		steps += 1
		if not is_instance_valid(so) or not bool(lk.get("reeling")):
			if is_instance_valid(so) or nodes_before.size() > 0:
				rest_gap = 0.0
				for b0 in nodes_before.size():
					rest_gap = maxf(rest_gap, nodes_before[b0].distance_to(rest_nodes[b0]))
			break
		var P: PackedVector3Array = so.get("_p")
		for b in mini(P.size(), prev_nodes.size()):
			max_node_step = maxf(max_node_step, P[b].distance_to(prev_nodes[b]))
		prev_nodes = P.duplicate()
		out_hist.append(int(so.call("body_out_count")))
		clr_min = minf(clr_min, float(so.call("rod_ball_clearance", r)))
	print("T5 reel: total %.1f cm in %d steps, max node step %.1f mm, out counts %s, min wall clearance %.2f mm" % [total * 100, steps, max_node_step * 1000.0, str(out_hist.slice(0, 40)), clr_min * 1000.0])
	_ok(max_node_step < 0.012, "uterus follows the ball smoothly (max %.1f mm/frame)" % (max_node_step * 1000.0))
	var back_in := out_hist.size() > 0 and int(out_hist[out_hist.size() - 1]) == 0
	_ok(back_in, "uterus travels back through the wound into the body")
	_ok(clr_min > 0.0, "uterus keeps wrapping the caught ball while reeled in (%.2f mm)" % (clr_min * 1000.0))
	print("T5 uterus gap to rest pose the frame before handoff: %.1f mm" % (rest_gap * 1000.0))
	_ok(rest_gap >= 0.0 and rest_gap < 0.009, "uterus is (almost) at its rest pose when the surgical body is swapped (%.1f mm)" % (rest_gap * 1000.0))
	_ok(int(lk.get("handoff_count")) == 1, "reaching the rest pose hands off to the normal prolapse")
	_ok(not bool(org.get_meta("uterus_extracted", true)), "surgery no longer marks the uterus as extracted")
	_ok(s.call("soft_organ", "uterus") == null, "surgical soft uterus removed")
	_ok(bool(ctl.get("caught")) and pc != null and bool(pc.call("is_active")), "ball is caught in the cervix of the normal prolapse")
	var jump := float(lk.get("last_handoff_jump"))
	print("T5 handoff: ball jump %.2f mm, descent %.3f" % [jump * 1000.0, float(pc.get("descent")) if pc else -1.0])
	_ok(jump >= 0.0 and jump < 0.006, "no pop at the handoff (ball moved %.1f mm)" % (jump * 1000.0))
	_ok(pc != null and float(pc.get("descent")) < 0.01, "prolapse starts from the rest position (descent %.3f)" % (float(pc.get("descent")) if pc else -1.0))
	# 继续往外拉：正常脱垂
	if pc:
		var ax: Vector3 = ctl.call("_axis_world")
		var tgt: Vector3 = ctl.call("tip_world")
		for i2 in 90:
			tgt -= ax * 0.002
			ctl.call("drive_caught_to", tgt)
			await _phys(1)
		print("T5 after handoff pull: descent %.3f, amount %.2f" % [float(pc.get("descent")), float(pc.call("amount"))])
		_ok(float(pc.get("descent")) > 0.03, "pulling further continues as a normal uterine prolapse (descent %.1f cm)" % (float(pc.get("descent")) * 100.0))
