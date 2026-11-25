extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中，t66u）：子宫脱垂系统。分度阈值、宫颈 / 宫底相对外口的位置、
## 阴道内翻（体内折叠 + 体外套筒）、外口撑开不穿模、柔性悬挂甩动衰减、触发 #1（长杆钢球）阈值、
## 手术经创口先复位再扯出、复原、无 NaN、每帧开销。不打包。
##   godot --headless --path . -s res://scripts/tests/v0420_prolapse_check.gd

var org: Node
var pc: Node
var vm: Node
var _nan_seen := 0


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
		print("v0420_prolapse_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	if s and bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	org = player.call("get_organs")
	vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(3)
	pc = org.call("prolapse")
	_ok(pc != null, "OrganRig.prolapse() exists")
	await _check_spawn()
	await _check_grades()
	await _check_swing()
	await _check_hand_drag()
	await _check_trigger()
	await _check_pip()
	await _check_reset()
	vm.call("exit")
	await _frames(2)
	await _check_surgery()
	_ok(_nan_seen == 0, "no NaN in prolapse nodes / sleeve during the whole run (%d)" % _nan_seen)
	print("v0420_prolapse_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _scan_nan() -> void:
	for p in pc.call("node_positions"):
		if not (p as Vector3).is_finite():
			_nan_seen += 1
	var sl = pc.call("sleeve")
	if sl and sl.visible:
		_nan_seen += int((sl.call("continuity_report") as Dictionary).get("nan", 0))


func _settle(n: int) -> void:
	for i in n:
		await _phys(1)
		_scan_nan()


# ------------------------------------------------------------------ 出生重合
func _check_spawn() -> void:
	pc.call("set_amount", 0.0005)
	await _settle(2)
	_ok(bool(pc.call("is_active")), "a tiny descent activates the prolapse soft organ")
	var so: Node = pc.call("soft_organ")
	var off: Dictionary = so.call("spawn_offset") if so else {}
	print("PROLAPSE spawn offset centroid=%.2f mm max=%.2f mm" % [float(off.get("centroid_mm", -1)), float(off.get("max_mm", -1))])
	_ok(float(off.get("centroid_mm", 99)) < 1.0 and float(off.get("max_mm", 99)) < 2.0, "physics uterus coincides with the visible original at d≈0 (centroid %.2f mm, max %.2f mm)" % [float(off.get("centroid_mm", 99)), float(off.get("max_mm", 99))])
	_ok(bool(org.call("kinds_hidden", "uterus")) if org.has_method("kinds_hidden") else true, "the original uterus is hidden while the prolapse soft organ is shown")
	pc.call("reset")
	await _settle(2)


# ------------------------------------------------------------------ 分度 / 位置 / 套筒 / 外口 / 阴道内翻
func _check_grades() -> void:
	var thr: Dictionary = pc.call("grade_thresholds")
	var dm := float(thr["descent_max"])
	var dd: Dictionary = thr["descent"]
	var aa: Dictionary = thr["amount"]
	print("PROLAPSE descent_max=%.1f mm  thresholds descent(mm): I=%.1f II=%.1f III=%.1f IV=%.1f  amount: I=%.3f II=%.3f III=%.3f IV=%.3f" % [dm * 1000, float(dd[1]) * 1000, float(dd[2]) * 1000, float(dd[3]) * 1000, float(dd[4]) * 1000, float(aa[1]), float(aa[2]), float(aa[3]), float(aa[4])])
	_ok(float(aa[1]) < float(aa[2]) and float(aa[2]) < float(aa[3]) and float(aa[3]) < float(aa[4]) and float(aa[4]) < 1.0, "grade thresholds increase 0 < I < II < III < IV < 1")
	var h := float(pc.get("params").get("hymen_band"))
	var wall := float(pc.get("params").get("wall"))
	# 每度取中点。
	var mids := {
		1: (float(dd[1]) + float(dd[2])) * 0.5,
		2: (float(dd[2]) + float(dd[3])) * 0.5,
		3: (float(dd[3]) + float(dd[4])) * 0.5,
		4: (float(dd[4]) + dm) * 0.5,
	}
	_ok(int(pc.call("grade_for_descent", 0.0)) == 0, "grade 0 at no descent")
	for g in [1, 2, 3, 4]:
		pc.call("set_amount", float(mids[g]) / dm)
		await _settle(45)
		var st: Dictionary = pc.call("debug_state")
		var csd := float(st["cervix_sd"])
		var fsd := float(st["fundus_sd"])
		var pen := float(org.vulva.call("insert_penetration"))
		var pr := float(pc.call("portal_radius"))
		var a_portal := float(pc.get("descent")) - float(st["sigma0"])
		var mass_r := float(pc.call("mass_radius_at", a_portal)) if a_portal > -0.02 else 0.0
		var ins = pc.call("inserter")
		var ins_r := float(ins.call("radius")) if ins and bool(pc.call("owns_introitus")) else 0.0
		print("PROLAPSE grade %s: descent=%.1f mm amount=%.2f cervix_sd=%+.1f mm fundus_sd=%+.1f mm out_nodes=%d introitus_r=%.1f mm mass_r=%.1f mm penetration=%.2f mm" % [pc.call("grade_name"), float(pc.get("descent")) * 1000, float(pc.call("amount")), csd * 1000, fsd * 1000, int(st["out"]), ins_r * 1000, mass_r * 1000, pen * 1000])
		_ok(int(pc.get("grade")) == g, "grade %d reached at its mid descent" % g)
		if g == 1:
			_ok(csd > h, "grade I: cervix still inside the canal (%.1f mm above the introitus)" % (csd * 1000))
		elif g == 2:
			_ok(absf(csd) <= h + 0.001, "grade II: cervix at the introitus (%+.1f mm)" % (csd * 1000))
		elif g == 3:
			_ok(csd < -h and fsd > 0.0, "grade III: cervix outside (%.1f mm), fundus still inside (%.1f mm)" % [csd * 1000, fsd * 1000])
		else:
			_ok(fsd < 0.0 and int(st["out"]) == int(pc.get("_n")), "grade IV: whole uterus outside (fundus %.1f mm out, %d/%d nodes)" % [fsd * 1000, int(st["out"]), int(pc.get("_n"))])
			_check_through_vagina()
		if g >= 2:
			_ok(pen < 0.001, "grade %d: no labia / vestibule penetration (%.2f mm)" % [g, pen * 1000])
			_ok(ins_r >= mass_r + wall - 1e-4, "grade %d: introitus opened to ≥ the mass cross-section (%.1f ≥ %.1f mm)" % [g, ins_r * 1000, (mass_r + wall) * 1000])
		if g >= 3:
			_check_sleeve(g)
		_check_vagina_deform(g)


func _check_through_vagina() -> void:
	# 宫底在外面，是从阴道口出来的：体外链锚在外口（不是腹部创口），每个节点都在会阴平面外侧。
	var O: Vector3 = pc.call("introitus_world")
	var ain: Vector3 = pc.call("canal_axis_world")
	var nodes: PackedVector3Array = pc.call("node_positions")
	var all_out := true
	for p in nodes:
		if (p - O).dot(-ain) < -0.001:
			all_out = false
	var seg: PackedFloat32Array = pc.get("_seg")
	var total := 0.0
	for l in seg:
		total += l
	var la := float(pc.get("descent")) - float((pc.get("_sigma") as PackedFloat32Array)[nodes.size() - 1])
	var reach := nodes[nodes.size() - 1].distance_to(O)
	var navel: Vector3 = (org.get("_frame") as Transform3D).origin
	var f_navel := nodes[nodes.size() - 1].distance_to(navel)
	print("PROLAPSE IV: fundus→introitus %.1f mm (rope %.1f mm), fundus→navel %.1f cm" % [reach * 1000, la * 1000, f_navel * 100])
	_ok(all_out and reach <= la + 0.003, "grade IV: the fundus hangs from the vaginal opening (fundus→introitus %.1f mm ≤ %.1f mm)" % [reach * 1000, la * 1000])
	_ok(f_navel > 0.12, "grade IV: the fundus is far from the abdomen / wound (%.1f cm from the navel)" % (f_navel * 100))


func _check_sleeve(g: int) -> void:
	var sl = pc.call("sleeve")
	_ok(sl != null and sl.visible, "grade %d: everted vaginal sleeve is shown outside" % g)
	if sl == null:
		return
	var rep: Dictionary = sl.call("continuity_report")
	var rings: Array = sl.call("rings")
	var O: Vector3 = pc.call("introitus_world")
	var c0: Vector3 = (rings[0] as Dictionary)["c"] if not rings.is_empty() else Vector3.INF
	var cl: Vector3 = (rings[rings.size() - 1] as Dictionary)["c"] if not rings.is_empty() else Vector3.INF
	var cerv: Vector3 = pc.call("cervix_world")
	var expose := cl.distance_to(cerv)
	print("PROLAPSE sleeve grade %d: rings=%d max_gap=%.1f mm inward_normals=%d wind_mismatch=%d nan=%d root→introitus=%.1f mm cervix exposed=%.1f mm" % [g, int(rep["rings"]), float(rep["max_gap"]) * 1000, int(rep["inward_normals"]), int(rep.get("wind_mismatch", -1)), int(rep["nan"]), c0.distance_to(O) * 1000, expose * 1000])
	_ok(int(rep["rings"]) >= 4 and float(rep["max_gap"]) < 0.008 and int(rep["nan"]) == 0, "grade %d: sleeve is one continuous tube (no gaps / holes)" % g)
	_ok(int(rep["inward_normals"]) == 0 and int(rep.get("wind_mismatch", 1)) == 0, "grade %d: sleeve mucosa faces outward (normals and winding)" % g)
	_ok(c0.distance_to(O) < 0.008, "grade %d: sleeve starts at the introitus (%.1f mm)" % [g, c0.distance_to(O) * 1000])
	_ok(expose > 0.008, "grade %d: cervix / os is exposed at the distal tip (%.1f mm past the sleeve)" % [g, expose * 1000])


func _check_vagina_deform(g: int) -> void:
	# CPU 版着色器公式：体内阴道顶端翻进去（双层），其余部分被脱出物撑开、不被穿透。
	var vag: Array = org.call("viscera_meshes", "vagina")
	if vag.is_empty():
		return
	var u: Dictionary = org.call("prolapse_uniforms")
	_ok(not u.is_empty() and (u["prol_o"] as Vector4).w > 0.5, "grade %d: vagina shader gets the prolapse uniforms" % g)
	if u.is_empty():
		return
	var mi: MeshInstance3D = vag[0]
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var fr: Transform3D = org.get("_frame")
	var inv := fr.affine_inverse()
	var o4: Vector4 = u["prol_o"]
	var a4: Vector4 = u["prol_a"]
	var p4: Vector4 = u["prol_p"]
	var o := Vector3(o4.x, o4.y, o4.z)
	var ax := Vector3(a4.x, a4.y, a4.z).normalized()
	var tip := p4.y
	var w := p4.w
	var inverted := 0
	var worst := 1.0
	var gx := mi.global_transform
	for v in V:
		var l: Vector3 = inv * (gx * v)
		var r4: Vector4 = org.call("prolapse_offset_ab", l)
		var q := l + Vector3(r4.x, r4.y, r4.z)
		if r4.w > 0.5:
			inverted += 1
			continue
		var sq := (q - o).dot(ax)
		if sq < 0.0 or sq > a4.w:
			continue
		var rq := ((q - o) - ax * sq).length()
		var mr := float(pc.call("mass_radius_at", sq - tip))
		if mr <= 0.0:
			continue
		worst = minf(worst, rq - mr - w)
	print("PROLAPSE vagina grade %d: inverted verts=%d / %d, min wall clearance to the mass=%.2f mm" % [g, inverted, V.size(), worst * 1000])
	if g >= 2:
		_ok(inverted > 0, "grade %d: upper vagina is inverted (folded over the descending mass)" % g)
	_ok(worst >= -0.0002, "grade %d: the descending mass does not poke through the canal wall (clearance %.2f mm)" % [g, worst * 1000])


# ------------------------------------------------------------------ 甩动衰减
func _check_swing() -> void:
	pc.call("set_amount", 0.97)
	await _settle(90)
	var n := int(pc.get("_n"))
	var nodes: PackedVector3Array = pc.call("node_positions")
	var f0 := nodes[n - 1]
	var side: Vector3 = (pc.call("canal_axis_world") as Vector3).cross(Vector3.UP).normalized()
	pc.call("begin_drive", "test", n - 1, f0, true)
	for i in 8:
		pc.call("drive_to", f0 + side * 0.05 * float(i + 1) / 8.0)
		await _settle(1)
	pc.call("end_drive")
	var prev: Vector3 = (pc.call("node_positions") as PackedVector3Array)[n - 1]
	var peak := 0.0
	var late := 0.0
	var seg: PackedFloat32Array = pc.get("_seg")
	var max_stretch := 0.0
	var usec := 0
	for f in 240:
		await _phys(1)
		_scan_nan()
		var np: PackedVector3Array = pc.call("node_positions")
		var v := np[n - 1].distance_to(prev) * 60.0
		prev = np[n - 1]
		usec += int(pc.get("last_step_usec"))
		if f < 40:
			peak = maxf(peak, v)
		if f >= 180:
			late = maxf(late, v)
		for b in range(1, n):
			max_stretch = maxf(max_stretch, np[b].distance_to(np[b - 1]) / maxf(float(seg[b - 1]), 1e-4))
	print("PROLAPSE swing: peak fundus speed %.3f m/s, after 3 s %.4f m/s (%.1f%%), max segment stretch %.3f, avg step %d µs" % [peak, late, late / maxf(peak, 1e-6) * 100.0, max_stretch, usec / 240])
	_ok(peak > 0.05, "a fling makes the hanging uterus swing (%.3f m/s)" % peak)
	_ok(late < peak * 0.12, "the swing decays (%.4f m/s after 3 s, %.1f%% of peak)" % [late, late / maxf(peak, 1e-6) * 100.0])
	_ok(max_stretch < 1.06, "flexible chain stays intact (max stretch %.3f)" % max_stretch)
	_ok(usec / 240 < 3000, "prolapse step is cheap while swinging (%d µs avg)" % (usec / 240))


# ------------------------------------------------------------------ 用手拖：可拉出 / 推回
func _check_hand_drag() -> void:
	pc.call("set_amount", 0.6)
	await _settle(40)
	var d0 := float(pc.get("descent"))
	var cam: Camera3D = player.call("get_camera")
	var cerv: Vector3 = pc.call("cervix_world")
	var origin := cerv + (cam.global_position - cerv).normalized() * 0.3 if cam else cerv + Vector3(0, 0, 0.3)
	var ok := bool(vm.call("begin_prolapse_drag", origin, (cerv - origin).normalized()))
	_ok(ok, "the outside prolapse is pickable for a hand drag")
	var ain: Vector3 = pc.call("canal_axis_world")
	for i in 40:
		pc.call("drive_to", cerv - ain * 0.002 * float(i + 1))
		await _settle(1)
	var d1 := float(pc.get("descent"))
	for i2 in 60:
		pc.call("drive_to", (pc.call("introitus_world") as Vector3) + ain * 0.03)
		await _settle(1)
	var d2 := float(pc.get("descent"))
	vm.call("end_prolapse_drag")
	print("PROLAPSE hand drag: descent %.1f → pull %.1f → push back %.1f mm" % [d0 * 1000, d1 * 1000, d2 * 1000])
	_ok(d1 > d0 + 0.02, "pulling the dragged uterus increases the prolapse (%.1f → %.1f mm)" % [d0 * 1000, d1 * 1000])
	_ok(d2 < d1 - 0.02, "pushing it back reduces the prolapse (%.1f → %.1f mm)" % [d1 * 1000, d2 * 1000])
	pc.call("reset")
	await _settle(2)


# ------------------------------------------------------------------ 触发 #1：长杆钢球
func _ball_in_uterus(ctl: Node, diam: float) -> float:
	ctl.call("set_diameter", diam)
	ctl.call("debug_reset_gate")
	var cerv := float(vm.call("introitus_world").distance_to(vm.call("cervix_world")))
	var r := float(ctl.call("radius"))
	ctl.call("debug_set_depth", cerv + r * 0.95 + 0.006)
	ctl.set("through_cervix", true)
	ctl.set("_last_desired", INF)
	return cerv


func _pull(ctl: Node, from_d: float, step: float, frames: int) -> void:
	var d := from_d
	for i in frames:
		d -= step
		ctl.call("apply_desired_depth", d, 1.0 / 60.0)
		await _phys(1)
		if bool(ctl.get("caught")) or not bool(ctl.get("through_cervix")):
			return


func _check_trigger() -> void:
	vm.call("set_tool", "ball_rod")
	await _frames(3)
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null and ctl.has_method("is_caught"), "ball-rod has the prolapse catch API")
	if ctl == null:
		return
	ctl.set("dragging", true)
	var cap := float(pc.get("params").get("cervix_capacity_r")) * float(pc.get("params").get("catch_ratio"))
	# a) 小球（20 mm）快扯：照旧从宫颈弹出，不脱垂。
	var d0 := _ball_in_uterus(ctl, 0.020) + 0.02
	await _pull(ctl, d0, 0.006, 40)
	var r_small := float(ctl.call("radius"))
	print("PROLAPSE trigger a) ball %.1f mm (catch ≥ %.1f mm radius) fast pull: caught=%s through_cervix=%s report=%s" % [r_small * 2000, cap * 1000, ctl.get("caught"), ctl.get("through_cervix"), pc.call("trigger", "ball_rod").get("last_report")])
	_ok(not bool(ctl.get("caught")) and not bool(pc.call("is_active")), "small ball + hard pull: no prolapse")
	_ok(not bool(ctl.get("through_cervix")), "small ball pops back out through the cervix as before")
	# b) 大球（30 mm）慢、轻拉（被挡行程 < 阈值）：不脱垂，攒够压力后照旧弹出。
	d0 = _ball_in_uterus(ctl, 0.030)
	var gate_end: float = d0 + float(ctl.call("radius")) * 0.55
	for i in 90:
		ctl.call("apply_desired_depth", gate_end - minf(0.0006 * float(i), 0.02), 1.0 / 60.0)
		await _phys(1)
		if not bool(ctl.get("through_cervix")) or bool(ctl.get("caught")):
			break
	var rep_b: Dictionary = pc.call("trigger", "ball_rod").get("last_report")
	print("PROLAPSE trigger b) ball 30 mm gentle pull: caught=%s through_cervix=%s speed=%.3f force=%.1f mm" % [ctl.get("caught"), ctl.get("through_cervix"), float(rep_b.get("pull_speed", 0)), float(rep_b.get("pull_force", 0)) * 1000])
	_ok(not bool(ctl.get("caught")) and not bool(pc.call("is_active")), "big ball + gentle pull: no prolapse")
	# c) 大球（30 mm）快扯：宫颈卡住球，子宫被拖出来。
	d0 = _ball_in_uterus(ctl, 0.030) + 0.01
	await _pull(ctl, d0, 0.005, 30)
	var rep_c: Dictionary = pc.call("trigger", "ball_rod").get("last_report")
	print("PROLAPSE trigger c) ball 30 mm hard pull: caught=%s speed=%.3f m/s force=%.1f mm state=%s report=%s depth=%.1f mm thr=%s" % [ctl.get("caught"), float(rep_c.get("pull_speed", 0)), float(rep_c.get("pull_force", 0)) * 1000, pc.get("state"), str(rep_c), float(ctl.get("depth")) * 1000, ctl.get("through_cervix")])
	_ok(bool(ctl.get("caught")) and bool(pc.call("is_active")) and str(pc.get("state")) == "driven", "big ball + hard pull: cervix catches the ball and the uterus starts to prolapse")
	if not bool(ctl.get("caught")):
		return
	# 继续往外拉：随拉出距离逐度加重。
	var O: Vector3 = pc.call("introitus_world")
	var ain: Vector3 = pc.call("canal_axis_world")
	var grades: Array = []
	var down := (-ain + Vector3(0, -0.6, 0)).normalized()
	var start: Vector3 = ctl.call("tip_world")
	var grade_mono := true
	var last_g := 0
	for i2 in 160:
		var tgt := start + down * 0.0012 * float(i2 + 1)
		ctl.call("drive_caught_to", tgt)
		await _settle(1)
		var g := int(pc.get("grade"))
		if g < last_g:
			grade_mono = false
		last_g = g
		if grades.is_empty() or int(grades[grades.size() - 1]) != g:
			grades.append(g)
		if g >= 3 and float(pc.call("amount")) > 0.7:
			break
	var ball_off := (ctl.call("tip_world") as Vector3).distance_to(pc.call("cervix_world"))
	print("PROLAPSE trigger pull: grades passed %s, amount %.2f, ball↔cervix %.1f mm" % [str(grades), float(pc.call("amount")), ball_off * 1000])
	_ok(grade_mono and last_g >= 3, "pulling the caught ball progresses the grades with distance (%s)" % str(grades))
	_ok(ball_off < float(ctl.call("radius")) + 0.004, "the ball stays caught at the cervix (%.1f mm)" % (ball_off * 1000))
	# 松手：停在已达到的等级挂着。
	var d_rel := float(pc.get("descent"))
	ctl.call("end_drag")
	await _settle(60)
	var d_after := float(pc.get("descent"))
	print("PROLAPSE release: descent %.1f → %.1f mm, state=%s grade=%s" % [d_rel * 1000, d_after * 1000, pc.get("state"), pc.call("grade_name")])
	_ok(str(pc.get("state")) == "hanging" and absf(d_after - d_rel) < 0.002, "after release it hangs at the reached grade (%.1f → %.1f mm)" % [d_rel * 1000, d_after * 1000])
	# 再拖：拉到头后再多拉，球从宫颈脱出，子宫留在 IV 度。
	ctl.call("begin_drag", Vector2.ZERO, O + Vector3(0, 0, 0.3), Vector3(0, 0, -1))
	var st2: Vector3 = ctl.call("tip_world")
	for i3 in 260:
		ctl.call("drive_caught_to", st2 + down * 0.0015 * float(i3 + 1))
		await _settle(1)
		if not bool(ctl.get("caught")):
			break
	print("PROLAPSE over-pull: caught=%s grade=%s amount=%.2f" % [ctl.get("caught"), pc.call("grade_name"), float(pc.call("amount"))])
	_ok(not bool(ctl.get("caught")) and int(pc.get("grade")) == 4, "pulling past total procidentia pops the ball out of the cervix; uterus stays at IV")
	ctl.call("end_drag")
	ctl.set("dragging", false)
	await _settle(10)


# ------------------------------------------------------------------ 断面小窗
func _check_pip() -> void:
	vm.call("set_tool", "ball_rod")
	await _frames(2)
	if not bool(pc.call("is_active")):
		pc.call("set_amount", 0.95)
	await _settle(4)
	var sec: Node = vm.get("_section")
	_ok(sec != null, "cross-section view exists")
	if sec == null:
		return
	sec.call("set_visible_on", true)
	await _frames(3)
	var copies: Array = sec.get("_copies")
	var has_so := false
	var has_sleeve := false
	var vag_on := false
	for rec in copies:
		var src: Node = rec["src"]
		if src == pc.call("soft_organ"):
			has_so = true
		if src == pc.call("sleeve"):
			has_sleeve = true
		if str(rec.get("kind", "")) == "vagina":
			var cut: ShaderMaterial = rec["cut"]
			var po = cut.get_shader_parameter("prol_o")
			if po is Vector4 and (po as Vector4).w > 0.5:
				vag_on = true
	_ok(has_so and has_sleeve, "PiP shows the prolapsed uterus and the everted sleeve (copies: uterus=%s sleeve=%s)" % [has_so, has_sleeve])
	_ok(vag_on, "PiP vagina copies get the eversion uniforms")
	var cam: Camera3D = sec.get("_long_cam")
	var fund: Vector3 = pc.call("fundus_world")
	var in_view := false
	if cam:
		var lp := cam.global_transform.affine_inverse() * fund
		in_view = absf(lp.x) < cam.size * 0.5 * 1.8 and absf(lp.y) < cam.size * 0.5
	_ok(in_view, "PiP longitudinal view frames the hanging fundus")
	_ok(int(sec.get("last_step_usec")) < 4000, "PiP update stays cheap with the prolapse (%d µs)" % int(sec.get("last_step_usec")))
	hud.call("_refresh_surgery_ui")
	await _frames(2)
	var lbl: Label = hud.get("_prolapse_label")
	print("PROLAPSE HUD label: '%s'" % (lbl.text if lbl else "<none>"))
	_ok(lbl != null and lbl.visible and lbl.text.find("度") >= 0, "HUD shows the prolapse grade in vagina mode")


# ------------------------------------------------------------------ 复原
func _check_reset() -> void:
	if not bool(pc.call("is_active")):
		pc.call("set_amount", 0.9)
		await _settle(10)
	player.call("restore_body")
	await _settle(4)
	var u: Dictionary = org.call("prolapse_uniforms")
	var vag: Array = org.call("viscera_meshes", "vagina")
	var po = (vag[0] as MeshInstance3D).material_override.get_shader_parameter("prol_o") if not vag.is_empty() else Vector4.ZERO
	var sl = pc.call("sleeve")
	var ut_vis := not bool(org.call("kinds_hidden", "uterus")) if org.has_method("kinds_hidden") else true
	print("PROLAPSE reset: active=%s grade=%d descent=%.2f mm sleeve_visible=%s intro_mix=%.3f" % [pc.call("is_active"), int(pc.get("grade")), float(pc.get("descent")) * 1000, sl.visible if sl else false, float(org.vulva.get("_intro_mix"))])
	_ok(not bool(pc.call("is_active")) and int(pc.get("grade")) == 0 and float(pc.get("descent")) == 0.0, "复原 restores the prolapse to grade 0")
	_ok(u.is_empty() and (po == null or (po as Vector4).w < 0.5), "复原 clears the vagina eversion uniforms")
	_ok(sl == null or not sl.visible, "复原 hides the sleeve")
	_ok(ut_vis, "复原 shows the original uterus again")
	_ok(float(org.vulva.get("_intro_mix")) < 1e-4, "复原 closes the introitus")


# ------------------------------------------------------------------ 手术：先复位，再从创口扯出
func _check_surgery() -> void:
	await _open_wound()
	pc.call("set_amount", 0.95)
	await _settle(60)
	var d_start := float(pc.get("descent"))
	_ok(int(pc.get("grade")) == 4, "prolapse set to IV before surgery (descent %.1f mm)" % (d_start * 1000))
	s.call("set_tool", "forceps")
	await _frames(2)
	var ok := bool(s.call("debug_begin_extract", "uterus"))
	_ok(ok and str(s.get("_fc_kind")) == "prolapse", "forceps through the wound grabs the prolapsed uterus for reduction (kind=%s)" % s.get("_fc_kind"))
	if not ok:
		return
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	var tip0: Vector3 = s.get("_fc_last")
	var mono := true
	var prev := d_start
	var extracted_early := false
	var handoff_frame := -1
	var d_at_handoff := -1.0
	for i in 400:
		s.call("debug_forceps_drag_to", tip0 + outv * 0.0015 * float(i + 1))
		await _phys(1)
		_scan_nan()
		var so: Node = s.call("soft_organ", "uterus")
		var d := float(pc.get("descent")) if bool(pc.call("is_active")) else 0.0
		if d > prev + 1e-5:
			mono = false
		prev = d
		var ext := so != null and bool(so.call("is_extracted"))
		if ext and handoff_frame < 0:
			handoff_frame = i
			d_at_handoff = d
		if ext and d > 1e-4:
			extracted_early = true
		if handoff_frame >= 0 and i > handoff_frame + 30:
			break
	print("PROLAPSE surgery: descent %.1f mm reduced monotonic=%s, handoff to wound extraction at frame %d with descent %.2f mm, fc_kind=%s handoffs=%d" % [d_start * 1000, mono, handoff_frame, d_at_handoff * 1000, s.get("_fc_kind"), int(s.get("prolapse_reduce_handoffs"))])
	_ok(mono and handoff_frame > 0, "surgery pull reduces the prolapse gradually (monotonic)")
	_ok(not extracted_early and d_at_handoff <= 1e-4, "wound extraction starts only after the prolapse is fully reduced (descent %.2f mm)" % (d_at_handoff * 1000))
	_ok(str(s.get("_fc_kind")) == "soft", "the same forceps continues into the normal wound extraction")
	s.call("debug_forceps_end")
	await _phys(2)
	_ok(bool(s.call("restore_extracted_organs")), "放回内脏 works after the hand-off")
	await _phys(3)
	pc.call("set_amount", 0.5)
	await _settle(5)
	s.call("restore_extracted_organs")
	await _settle(3)
	_ok(not bool(pc.call("is_active")), "放回内脏 also restores the prolapse")
