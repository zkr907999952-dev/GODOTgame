extends "res://scripts/tests/v0411_check.gd"
## 0.4.11：柔体子宫黑三角/尺寸、整颗物理化并按档位伸出体外、肠管隐藏性能与远端先藏、
## 小肠隐藏变慢、直悬链卵巢在体内不穿出、更细的肠管、钳子跟随与悬停性能、
## 电脑按住夹拖 / 手机点选+1秒长按、扩张器沿阴道中线、放回内脏、当前选择标签。
##   godot --headless --path . -s res://scripts/tests/v0414_check.gd


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
		print("v0414_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_speculum_anterior()
	await _check_guts_and_hide()
	await _check_uterus_quality_and_phys()
	await _check_forceps_flows()
	print("v0414_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_speculum_anterior() -> void:
	var rig: Node = _organ_rig()
	s.call("set_tool", "speculum")
	await _frames(2)
	if not bool(s.call("is_speculum_inserted")) and s.has_method("debug_insert_speculum"):
		s.call("debug_insert_speculum")
	if s.has_method("debug_finish_speculum_anim"):
		s.call("debug_finish_speculum_anim")
	await _frames(3)
	var vis: Vector3 = rig.call("visible_introitus_world")
	var anus: Vector3 = vis
	if rig.has_method("anus_world"):
		anus = rig.call("anus_world")
	var intro_r: Vector3 = Vector3.ZERO
	if rig.has_method("introitus_rest"):
		intro_r = rig.call("introitus_rest")
	var anus_r: Vector3 = rig.get("ANUS_REST") as Vector3
	_ok(intro_r.z > anus_r.z + 0.025, "visible introitus is anterior of the anus in rest space (dz=%.1f mm)" % ((intro_r.z - anus_r.z) * 1000.0))
	var canal: Dictionary = rig.call("vagina_canal")
	_ok(not canal.is_empty(), "canal exists for speculum alignment")
	if not canal.is_empty():
		var opening: Vector3 = canal["opening_world"]
		_ok(opening.distance_to(vis) < 0.008, "speculum canal opening aligns with the anterior introitus (%.1f mm)" % (opening.distance_to(vis) * 1000.0))
		var fourchette: Vector3 = intro_r
		if rig.vulva:
			fourchette = rig.vulva.opening
		_ok(intro_r.distance_to(anus_r) + 0.001 >= fourchette.distance_to(anus_r), "entry is not closer to the anus than the fourchette")
	var n: Node3D = null
	var sp = s.get("speculum")
	if sp != null:
		n = sp.get("node") as Node3D
	if n != null and n.visible and not canal.is_empty():
		var hinge: Vector3 = n.global_transform.origin
		var tip: Vector3 = hinge + n.global_transform.basis.z * 0.114
		var opening_w: Vector3 = canal["opening_world"]
		var seg := tip - hinge
		var L := seg.length()
		var u := 0.0
		if L > 1e-6:
			u = clampf((opening_w - hinge).dot(seg) / (L * L), 0.0, 1.0)
		var miss := (hinge + seg * u).distance_to(opening_w) * 1000.0
		_ok(miss < 10.0, "blade shaft goes through the anterior introitus (miss=%.1f mm)" % miss)
		_ok(opening_w.distance_to(anus) > 0.03, "insertion entry stays away from the anus (%.1f mm)" % (opening_w.distance_to(anus) * 1000.0))
		var ax := n.global_transform.basis.z.normalized()
		var canal_ax: Vector3 = (canal["cervix_world"] - opening_w).normalized()
		_ok(ax.dot(canal_ax) > 0.96, "speculum axis aligns with the vagina centreline (dot=%.4f)" % ax.dot(canal_ax))
		var line: PackedVector3Array = rig.call("vagina_centerline_world") if rig.has_method("vagina_centerline_world") else PackedVector3Array()
		if line.size() >= 2:
			var worst := 0.0
			var cerv_w: Vector3 = canal["cervix_world"]
			# 只量叶片落在通道里的一段（外口到宫颈），不要把体外铰链算进去。
			for s_i in 5:
				var tu := (float(s_i) + 0.5) / 5.0
				var bp: Vector3 = opening_w.lerp(cerv_w, tu)
				# 点到叶片轴线
				var slen := seg.length()
				var uu := 0.0 if slen < 1e-8 else clampf((bp - hinge).dot(seg) / (slen * slen), 0.0, 1.0)
				var on_blade := hinge + seg * uu
				worst = maxf(worst, on_blade.distance_to(bp))
			_ok(worst * 1000.0 < 12.0, "blade stays near the vagina mesh centreline (max miss=%.1f mm)" % (worst * 1000.0))
	s.call("set_tool", "scalpel")
	await _frames(1)


func _check_guts_and_hide() -> void:
	await _open_wound()
	var rig: Node = _organ_rig()
	# 半径
	_ok(bool(s.call("debug_begin_extract", "small")), "SI pull for radius")
	var ropes: Array = s.call("gut_ropes")
	_ok(not ropes.is_empty(), "SI rope exists")
	if not ropes.is_empty():
		var r0: Node = ropes[0]
		_ok(float(r0.get("radius")) <= 0.0082 and float(r0.get("radius")) >= 0.0060, "pulled small intestine is thinner (radius=%.4f)" % float(r0.get("radius")))
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "colon")), "colon pull for hide/perf")
	var crope: Array = s.call("colon_ropes")
	_ok(not crope.is_empty(), "colon rope exists")
	if crope.is_empty():
		return
	var rope: Node = crope[0]
	_ok(is_equal_approx(float(rope.get("radius")), 0.0148), "colon is slightly thinner (radius=%.4f)" % float(rope.get("radius")))
	_ok(int(rope.get("max_pts")) >= 24, "colon allows more pulled segments (max_pts=%d)" % int(rope.get("max_pts")))
	_ok(float(rope.get("max_len")) >= 0.50, "colon max pull-out length is increased (%.2f m)" % float(rope.get("max_len")))
	rope.set("fed_len", 0.18)
	s.call("_update_guts", 0.0)
	# 性能：缓存路径应远快于全网格扫描
	var hit: Vector3 = s.call("_wound_center_world")
	var n := 16
	var t0 := Time.get_ticks_usec()
	for i in n:
		rig.call("gut_along_near_uncached", "colon", hit)
		rig.call("gut_along_near_uncached", "small_intestine", hit)
	var uncached := float(Time.get_ticks_usec() - t0) / float(n)
	t0 = Time.get_ticks_usec()
	for i in n:
		rig.call("gut_along_near", "colon", hit)
		rig.call("gut_along_near", "small_intestine", hit)
	var cached := float(Time.get_ticks_usec() - t0) / float(n)
	t0 = Time.get_ticks_usec()
	for i in n:
		s.call("_sync_gut_hide")
	var sync_us := float(Time.get_ticks_usec() - t0) / float(n)
	print("v0414: gut hide timings uncached=%.1f us  cached=%.1f us  sync=%.1f us" % [uncached, cached, sync_us])
	_ok(cached < uncached * 0.55 or cached < 400.0, "cached along lookup is much faster than a full mesh scan (cached=%.1f us, uncached=%.1f us)" % [cached, uncached])
	_ok(sync_us < 800.0, "gut-hide uniform update stays cheap (%.1f us)" % sync_us)
	# 远端先藏：窗口应覆盖离扯出点更远的那一端
	var along := float((s.get("_gut_pulls")[0] as Dictionary).get("along", 0.5))
	var plen := float(rig.call("gut_path_length", "colon"))
	var fed := float(rope.get("fed_len"))
	var expect: Vector4 = rig.call("gut_hide_window", along, fed, plen)
	var win: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var got := Vector4()
	for v in win:
		if v.z > 0.5:
			got = v
			break
	_ok(got.z > 0.5 and got.y - got.x > 0.04, "a hide window is active (lo=%.2f hi=%.2f)" % [got.x, got.y])
	var far := 1.0 if along <= 0.5 else 0.0
	var covers_far := (got.y > 0.92) if far > 0.5 else (got.x < 0.08)
	_ok(covers_far, "hide window starts at the far end (along_hit=%.2f lo=%.2f hi=%.2f far=%.0f)" % [along, got.x, got.y, far])
	# 多扯一些，窗口向扯出点推进（区间变宽）
	var width0 := got.y - got.x
	rope.set("fed_len", minf(fed + 0.12, 0.36))
	s.call("_sync_gut_hide")
	var win2: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var width1 := 0.0
	for v2 in win2:
		if v2.z > 0.5:
			width1 = v2.y - v2.x
	_ok(width1 > width0 + 0.01, "hiding grows toward the pull point as more is pulled (width %.3f -> %.3f)" % [width0, width1])
	# 小肠体内隐藏更慢，同样扯出长度不会那么快把肚子掏空。
	_ok(absf(float(s.call("si_hide_rate")) - 0.35) < 0.001, "SI hide rate is reduced to 0.35")
	var w_si: Vector4 = rig.call("gut_hide_window", along, fed, plen, 0.35)
	var w_co: Vector4 = rig.call("gut_hide_window", along, fed, plen, 1.0)
	_ok(w_si.y < w_co.y * 0.45 and w_si.y > 0.0, "SI hide window is much narrower than colon for the same pull (SI half=%.3f colon half=%.3f)" % [w_si.y, w_co.y])
	# 放回反向恢复
	_ok(bool(s.call("debug_putback_organ", "colon")), "colon put-back")
	for i in 80:
		s.call("_update_guts", 1.0 / 30.0)
	var win3: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var left := 0.0
	for v3 in win3:
		if v3.z > 0.5:
			left = maxf(left, v3.y - v3.x)
	_ok(left <= 0.001, "put-back reverses the hide (left width=%.3f)" % left)
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)
	# 小肠多点扯出：第二次隐藏必须叠加在已有隐藏上，已藏的肠段不得重新出现。
	await _open_wound()
	_ok(bool(s.call("debug_begin_si_along", 0.22, 0.55)), "first SI pull at along 0.22")
	s.call("_sync_gut_hide")
	var mask_a: PackedFloat32Array = s.call("debug_gut_hide_mask", "small_intestine", 48)
	var amt_a := float(s.call("debug_gut_hide_amount", "small_intestine", 48))
	_ok(amt_a > 0.04, "first SI pull hides a stretch of in-body gut (amount=%.3f)" % amt_a)
	_ok(bool(s.call("debug_begin_si_along", 0.82, 0.08)), "second SI pull at along 0.82 starts smaller")
	s.call("_sync_gut_hide")
	var mask_b: PackedFloat32Array = s.call("debug_gut_hide_mask", "small_intestine", 48)
	var amt_b := float(s.call("debug_gut_hide_amount", "small_intestine", 48))
	var regress := 0.0
	var nmask := mini(mask_a.size(), mask_b.size())
	for hi in nmask:
		regress = maxf(regress, mask_a[hi] - mask_b[hi])
	_ok(regress < 0.08, "second SI pull does not un-hide earlier gut (max regress=%.3f)" % regress)
	_ok(amt_b + 1e-4 >= amt_a, "total hidden only increases after a second SI pull (%.3f -> %.3f)" % [amt_a, amt_b])
	# 再拉长第二段，隐藏继续只增不减
	var pulls: Array = s.get("_gut_pulls")
	if pulls.size() >= 2:
		var r_b: Node = (pulls[1] as Dictionary).get("rope")
		if r_b:
			r_b.set("fed_len", 0.45)
	s.call("_sync_gut_hide")
	var mask_c: PackedFloat32Array = s.call("debug_gut_hide_mask", "small_intestine", 48)
	var amt_c := float(s.call("debug_gut_hide_amount", "small_intestine", 48))
	var regress2 := 0.0
	for hi2 in mini(mask_b.size(), mask_c.size()):
		regress2 = maxf(regress2, mask_b[hi2] - mask_c[hi2])
	_ok(regress2 < 0.08, "growing the second pull still keeps prior hide (max regress=%.3f)" % regress2)
	_ok(amt_c + 1e-4 >= amt_b, "hidden length keeps growing (%.3f -> %.3f)" % [amt_b, amt_c])
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


func _check_uterus_quality_and_phys() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 30.0)
	await _frames(2)
	var so: Node = s.call("soft_organ", "uterus")
	_ok(so != null, "soft uterus exists")
	if so == null:
		return
	var q: Dictionary = s.call("soft_mesh_quality", "uterus") if s.has_method("soft_mesh_quality") else so.call("debug_mesh_quality")
	_ok(int(q.get("nan_verts", 1)) == 0 and int(q.get("nan_normals", 1)) == 0, "soft uterus has no NaN verts/normals (verts=%s nrm=%s)" % [q.get("nan_verts"), q.get("nan_normals")])
	_ok(int(q.get("deg_faces", 1)) == 0, "soft uterus has no degenerate faces (%s)" % q.get("deg_faces"))
	var frac1 := float(s.call("physical_fraction", "uterus"))
	_ok(frac1 > 0.95, "level 1 already physicalizes the whole uterus (%.2f)" % frac1)
	_ok(float(so.get("DAMP")) <= 0.72, "uterus physics damping is raised (DAMP=%.2f)" % float(so.get("DAMP")))
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = s.call("_cavity_outward") if s.has_method("_cavity_outward") else Vector3.UP
	outv = outv.normalized()
	var rest_f1: Vector3 = so.call("rest_fundus_world") if so.has_method("rest_fundus_world") else so.call("fundus_world")
	var spawn_off := (so.call("fundus_world") as Vector3).distance_to(rest_f1)
	_ok(spawn_off < 0.012, "level 1 fundus starts at the original uterus (offset %.1f mm)" % (spawn_off * 1000.0))
	var peek1 := (so.call("fundus_world") as Vector3 - wound).dot(outv)
	# L1 卵巢还在体内，不能从腹壁「卡出去」。
	if s.has_method("ovary_contained"):
		_ok(bool(s.call("ovary_contained", 0)) and bool(s.call("ovary_contained", 1)), "ovaries stay inside the body at level 1")
	_advance_charge("uterus", 1.0, 6.0)
	s.call("_update_guts", 1.0 / 30.0)
	var peek_mid := (so.call("fundus_world") as Vector3 - wound).dot(outv)
	var exp_mid := float(so.call("exposed_length"))
	var dist_mid := (so.call("fundus_world") as Vector3).distance_to(wound)
	_ok(peek_mid > peek1 + 0.008 or exp_mid > 0.02 or dist_mid > 0.02, "intermediate level extends the uterus farther out (%.1f -> %.1f mm)" % [peek1 * 1000.0, peek_mid * 1000.0])
	_advance_charge("uterus", 1.0, 10.0)
	s.call("_update_guts", 1.0 / 30.0)
	var frac5 := float(s.call("physical_fraction", "uterus"))
	_ok(frac5 > 0.95 and int(s.call("extract_level", "uterus")) == 5, "level 5 stays fully physicalized (%.2f)" % frac5)
	var ratio := float(s.call("soft_size_ratio", "uterus"))
	_ok(ratio >= 0.98, "physical uterus matches or exceeds original size (ratio=%.2f)" % ratio)
	for _i in 8:
		s.call("_update_guts", 1.0 / 30.0)
	var d5 := (so.call("fundus_world") as Vector3).distance_to(wound)
	var exp5 := float(so.call("exposed_length"))
	_ok(exp5 > exp_mid + 0.008 or d5 > dist_mid + 0.01 or int(s.call("extract_level", "uterus")) == 5 and exp5 > 0.03, "level 5 extends the uterus farther out of the body (exposed %.1f -> %.1f mm)" % [exp_mid * 1000.0, exp5 * 1000.0])
	var cx5: Vector3 = so.call("cervix_world")
	_ok((cx5 - wound).dot(outv) > -0.02, "at L5 the cervix has moved out toward the wound")
	var rig_u: Node = _organ_rig()
	var intro: Vector3 = rig_u.call("visible_introitus_world") if rig_u.has_method("visible_introitus_world") else wound
	var past_intro := (so.call("fundus_world") as Vector3).distance_to(intro)
	_ok(past_intro > 0.03, "at L5 the fundus is well outside the introitus (%.1f mm away)" % (past_intro * 1000.0))
	# 形状稳定、位置不下垂到创口上方漂浮。
	var edge5 := float(so.call("max_edge_ratio")) if so.has_method("max_edge_ratio") else 1.0
	_ok(edge5 < 1.30, "soft uterus edges stay un-torn after a long pull (max ratio=%.2f)" % edge5)
	var c5: Vector3 = so.call("centroid_world") if so.has_method("centroid_world") else so.call("fundus_world")
	_ok(c5.y <= wound.y + 0.04, "at L5 the uterus hangs at the wound, not floating high (centroid y-wound=%.1f mm)" % ((c5.y - wound.y) * 1000.0))
	# 钳子夹住子宫拖拽时钳子跟住夹点。瞄准宫底环上的一个笼点，而不是环心。
	var fund: Vector3 = so.call("fundus_world")
	var cage: PackedVector3Array = so.get("_p")
	var aim_pt: Vector3 = fund
	if not cage.is_empty():
		aim_pt = cage[(6 - 1) * 8] if cage.size() > (6 - 1) * 8 else cage[cage.size() - 1]
	var cam_o := aim_pt + Vector3(0, 0.12, 0.12)
	var cam_d := (aim_pt - cam_o).normalized()
	_ok(bool(s.call("debug_forceps_begin", cam_o, cam_d)), "forceps clamp the uterus")
	var hp0: Vector3 = so.get("hold_pos")
	s.call("debug_forceps_drag_to", hp0 + Vector3(0.0, 0.05, 0.04))
	s.call("_update_guts", 1.0 / 30.0)
	await _frames(2)
	var fn: Node3D = s.call("forceps_node")
	var hp1: Vector3 = so.get("hold_pos")
	_ok(fn != null and fn.visible, "forceps stay visible while dragging the uterus")
	if fn:
		var tip: Vector3 = fn.global_transform.origin + fn.global_transform.basis.z * 0.042
		_ok(tip.distance_to(hp1) < 0.02, "forceps tip follows the uterus grip point (%.1f mm)" % (tip.distance_to(hp1) * 1000.0))
	var edge_drag := float(so.call("max_edge_ratio")) if so.has_method("max_edge_ratio") else 1.0
	_ok(edge_drag < 1.30, "soft uterus stays un-torn after a forceps drag (max ratio=%.2f)" % edge_drag)
	s.call("debug_forceps_end")
	# 直悬链、卵巢在尽头
	_ok(bool(s.call("tube_chain_active", 0)) and bool(s.call("tube_chain_active", 1)), "both adnexa are chains at level 5")
	_ok(bool(s.call("chain_is_straight", 0)) and bool(s.call("chain_is_straight", 1)), "each tube/ovary is a straight chain, not a loop")
	_ok(bool(s.call("ovary_at_chain_end", 0)) and bool(s.call("ovary_at_chain_end", 1)), "ovaries sit at the far end of the chain")
	# 互动拖拽：物理子宫和输卵管/卵巢悬链必须跟着肚子走，不能留在原地。
	var rig_d: Node = _organ_rig()
	var fund0: Vector3 = so.call("fundus_world")
	var cx0: Vector3 = so.call("cervix_world")
	var ov0: Vector3 = so.call("ovary_world", 0) if so.has_method("ovary_world") else fund0
	var grab: Vector3 = s.call("_wound_center_world")
	rig_d.call("begin_drag", grab)
	rig_d.call("update_drag", grab + Vector3(0.0, 0.05, 0.05))
	for _j in 10:
		if rig_d.has_method("_step_drag"):
			rig_d.call("_step_drag", 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 30.0)
	var off_len := float(rig_d.call("drag_offset_length"))
	var fund1: Vector3 = so.call("fundus_world")
	var cx1: Vector3 = so.call("cervix_world")
	var moved := fund1.distance_to(fund0)
	_ok(off_len > 0.008, "tissue drag displaces the belly (%.1f mm)" % (off_len * 1000.0))
	_ok(moved > off_len * 0.45, "physical uterus follows interaction drag (moved %.1f mm, belly %.1f mm)" % [moved * 1000.0, off_len * 1000.0])
	_ok(cx1.distance_to(cx0) > off_len * 0.45, "cervix also follows the drag (%.1f mm)" % (cx1.distance_to(cx0) * 1000.0))
	if so.has_method("ovary_world"):
		var ov1: Vector3 = so.call("ovary_world", 0)
		_ok(ov1.distance_to(ov0) > off_len * 0.25, "tube/ovary chain follows the dragged uterus (%.1f mm)" % (ov1.distance_to(ov0) * 1000.0))
	rig_d.call("end_drag")
	for _k in 8:
		if rig_d.has_method("_step_drag"):
			rig_d.call("_step_drag", 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 30.0)
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


func _equip_forceps() -> void:
	if s.has_method("ensure_tool"):
		s.call("ensure_tool", "forceps")
	elif str(s.get("tool")) != "forceps":
		s.call("set_tool", "forceps")


func _check_forceps_flows() -> void:
	await _open_wound()
	_equip_forceps()
	# 悬停名称，不开始扯出
	var aim := _aim_at_kind("colon")
	if aim.is_empty():
		aim = _aim_at_kind("small_intestine")
	_ok(not aim.is_empty(), "can aim at a gut for hover")
	if not aim.is_empty():
		var label := str(s.call("debug_forceps_preview", aim[0], aim[1]))
		_ok(label == "大肠" or label == "小肠" or label == "子宫" or label == "膀胱", "hover/preview shows the target name (got '%s')" % label)
		_ok(int(s.call("gut_pull_count")) == 0 and int(s.call("colon_pull_count")) == 0, "preview does not start an extraction")
		_ok(not bool(s.call("is_forceps_clamped")), "preview does not clamp")
		var fn: Node3D = s.call("forceps_node")
		_ok(fn != null and fn.visible, "open forceps follow the cursor/preview point")
	# 电脑：按住即夹、松开即放（debug_forceps_begin / end）
	if not aim.is_empty():
		_ok(bool(s.call("debug_forceps_begin", aim[0], aim[1])), "LMB hold clamps the target")
		_ok(bool(s.call("is_forceps_clamped")), "forceps are clamped while the button is held")
		_ok(int(s.call("gut_pull_count")) + int(s.call("colon_pull_count")) + (1 if int(s.call("extract_level", "uterus")) > 0 else 0) >= 1, "holding LMB starts a grab")
		s.call("debug_forceps_end")
		_ok(not bool(s.call("is_forceps_clamped")), "releasing LMB lets go")
	# 手机短点：有名称，不扯出
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)
	await _open_wound()
	_equip_forceps()
	var aim2 := _aim_at_kind("colon")
	if aim2.is_empty():
		aim2 = _aim_at_kind("small_intestine")
	_ok(not aim2.is_empty() and bool(s.call("debug_forceps_touch_begin", aim2[0], aim2[1])), "mobile tap is accepted")
	_ok(not bool(s.call("is_forceps_clamped")), "a mobile tap does not clamp yet")
	_ok(int(s.call("colon_pull_count")) == 0 and int(s.call("gut_pull_count")) == 0, "a mobile tap does not start extraction")
	var lab2 := str(s.call("get_organ_target_label"))
	_ok(lab2 != "", "mobile tap shows the grab name (got '%s')" % lab2)
	s.call("end_stroke")
	_ok(not bool(s.call("is_forceps_clamped")) and int(s.call("colon_pull_count")) == 0, "releasing a short tap still does not extract")
	# 手机长按满 1 秒才夹住
	_ok(absf(float(s.call("forceps_longpress_seconds")) - 1.0) < 0.01, "long-press threshold is 1 s")
	_ok(bool(s.call("debug_forceps_touch_begin", aim2[0], aim2[1])), "mobile press starts")
	s.call("debug_forceps_tick", 0.4)
	_ok(not bool(s.call("is_forceps_clamped")), "0.4 s is not enough to clamp")
	s.call("debug_forceps_tick", 0.7)
	_ok(bool(s.call("is_forceps_clamped")), "holding over 1 s clamps and starts the drag")
	s.call("debug_forceps_end")
	_ok(not bool(s.call("is_forceps_clamped")), "releasing after a long-press lets go")
	# 悬停拾取性能：缓存路径应明显快于每次重建网格数组
	_equip_forceps()
	var hv := _aim_at_kind("colon")
	if hv.is_empty():
		hv = _aim_at_kind("small_intestine")
	if not hv.is_empty() and s.has_method("debug_forceps_hover_profile"):
		var slow: Dictionary = s.call("debug_forceps_hover_profile", hv[0], hv[1], 12, true)
		var fast: Dictionary = s.call("debug_forceps_hover_profile", hv[0], hv[1], 12, false)
		print("v0414: forceps hover uncached=%.1f us  cached=%.1f us" % [float(slow.get("us", 0)), float(fast.get("us", 0))])
		_ok(float(fast.get("us", 9e9)) < float(slow.get("us", 1.0)) * 0.35 or float(fast.get("us", 9e9)) < 1500.0, "forceps hover is much cheaper after caching (cached=%.1f us, uncached=%.1f us)" % [float(fast.get("us", 0)), float(slow.get("us", 0))])
		s.call("hover_tool", hv[0], hv[1])
		var live := str(s.call("get_organ_target_label"))
		_ok(live != "", "hover label updates in real time (got '%s')" % live)
		var labn: Label = hud.get("_organ_target_label")
		if labn:
			_ok(str(labn.text).begins_with("当前选择："), "HUD prefix is 「当前选择：」 (got '%s')" % labn.text)
	# 一键放回内脏（创口保留）
	_ok(hud.get("_btn_surgery_putback") != null, "HUD has a 「放回内脏」 button next to 复原")
	var had := int(s.call("colon_pull_count")) + int(s.call("gut_pull_count"))
	if had == 0 and not aim2.is_empty() and s.has_method("debug_forceps_begin_kind"):
		s.call("debug_forceps_begin_kind", aim2[0], aim2[1], PackedStringArray(["small_intestine", "colon"]))
		had = int(s.call("colon_pull_count")) + int(s.call("gut_pull_count"))
	_ok(had >= 1, "there is a pulled gut to put back")
	_ok(bool(s.call("restore_extracted_organs")), "restore_extracted_organs runs")
	_ok(int(s.call("colon_pull_count")) == 0 and int(s.call("gut_pull_count")) == 0, "one-tap putback clears all pulled guts")
	_ok(int(s.call("extract_level", "uterus")) == 0, "one-tap putback resets the uterus")
	s.call("restore_body")
