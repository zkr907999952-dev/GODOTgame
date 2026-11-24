extends "res://scripts/tests/v0411_check.gd"
## 0.4.11：柔体子宫黑三角/尺寸、肠管隐藏性能与远端先藏、直悬链卵巢在尽头、
## 渐进物理化、更细的肠管、钳子跟随、电脑按住夹拖 / 手机点选+1秒长按、扩张器前移。
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
	_ok(got.z > 0.5 and got.y > 0.02, "a hide window is active (center=%.2f half=%.2f)" % [got.x, got.y])
	var far := 1.0 if along <= 0.5 else 0.0
	# far=1 时窗口上沿 = center+half；far=0 时窗口下沿 = center-half。
	var covers_far := absf(got.x + (got.y if far > 0.5 else -got.y) - far) < 0.08
	_ok(covers_far, "hide window starts at the far end (along_hit=%.2f center=%.2f half=%.2f far=%.0f)" % [along, got.x, got.y, far])
	# 多扯一些，窗口向扯出点推进（半宽变大）
	var half0 := got.y
	rope.set("fed_len", minf(fed + 0.12, 0.36))
	s.call("_sync_gut_hide")
	var win2: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var half1 := 0.0
	for v2 in win2:
		if v2.z > 0.5:
			half1 = v2.y
	_ok(half1 > half0 + 0.01, "hiding grows toward the pull point as more is pulled (half %.3f -> %.3f)" % [half0, half1])
	# 放回反向恢复
	_ok(bool(s.call("debug_putback_organ", "colon")), "colon put-back")
	for i in 80:
		s.call("_update_guts", 1.0 / 30.0)
	var win3: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var left := 0.0
	for v3 in win3:
		if v3.z > 0.5:
			left = maxf(left, v3.y)
	_ok(left <= 0.001, "put-back reverses the hide (left half=%.3f)" % left)
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
	_ok(frac1 > 0.12 and frac1 < 0.35, "level 1 physical fraction is a fundus tip (%.2f)" % frac1)
	_advance_charge("uterus", 1.0, 6.0)
	s.call("_update_guts", 1.0 / 30.0)
	var mid := float(s.call("physical_fraction", "uterus"))
	_ok(mid > frac1 + 0.1, "higher level physicalizes more of the uterus (%.2f -> %.2f)" % [frac1, mid])
	_advance_charge("uterus", 1.0, 10.0)
	s.call("_update_guts", 1.0 / 30.0)
	var frac5 := float(s.call("physical_fraction", "uterus"))
	_ok(frac5 > 0.95 and int(s.call("extract_level", "uterus")) == 5, "level 5 is fully physicalized (%.2f)" % frac5)
	var ratio := float(s.call("soft_size_ratio", "uterus"))
	_ok(ratio >= 0.98, "physical uterus matches or exceeds original size (ratio=%.2f)" % ratio)
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
	s.call("debug_forceps_end")
	# 直悬链、卵巢在尽头
	_ok(bool(s.call("tube_chain_active", 0)) and bool(s.call("tube_chain_active", 1)), "both adnexa are chains at level 5")
	_ok(bool(s.call("chain_is_straight", 0)) and bool(s.call("chain_is_straight", 1)), "each tube/ovary is a straight chain, not a loop")
	_ok(bool(s.call("ovary_at_chain_end", 0)) and bool(s.call("ovary_at_chain_end", 1)), "ovaries sit at the far end of the chain")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


func _check_forceps_flows() -> void:
	await _open_wound()
	s.call("set_tool", "forceps")
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
	s.call("set_tool", "forceps")
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
	s.call("restore_body")
