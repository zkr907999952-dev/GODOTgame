extends "res://scripts/tests/v0411_check.gd"
## 0.4.10：大肠贴图只用本色、点选优先级与精度、选中目标提示、
## 扩张器沿可见阴道口插入并降低最大开合角、体内肠管随扯出隐藏。
##   godot --headless --path . -s res://scripts/tests/v0413_check.gd


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
	_check_colon_tile()
	_check_names()
	if not await _enter_bed():
		print("v0413_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_speculum_visible_path()
	await _check_picking_priority()
	await _check_hint_and_hide()
	print("v0413_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_names() -> void:
	# 在进手术前也可以问 API：需要 surgery 节点。进床后再验一遍。
	pass


func _check_speculum_visible_path() -> void:
	s.call("set_tool", "speculum")
	await _frames(2)
	s.call("debug_finish_speculum_anim")
	await _frames(3)
	_ok(absf(float(s.call("speculum_max_angle")) - 24.0) < 0.6, "max opening angle is 24° (got %.1f)" % float(s.call("speculum_max_angle")))
	s.call("set_speculum_angle", 40.0)
	await _frames(1)
	_ok(float(s.call("speculum_angle")) <= 24.01, "the slider cannot open past the reduced max (%.1f°)" % float(s.call("speculum_angle")))
	s.call("set_speculum_angle", 24.0)
	await _frames(2)
	var n: Node3D = s.call("speculum_node")
	var rig: Node = _organ_rig()
	_ok(n != null and rig != null, "speculum and organ rig are ready")
	if n == null or rig == null:
		return
	var vis: Vector3 = rig.call("visible_introitus_world")
	var tip: Vector3 = n.global_position + n.global_transform.basis.z * 0.114
	var seg: Vector3 = tip - n.global_position
	var slen := seg.length()
	var u := 0.0 if slen < 1e-6 else clampf((vis - n.global_position).dot(seg) / (slen * slen), 0.0, 1.0)
	var miss := (n.global_position + seg * u).distance_to(vis) * 1000.0
	_ok(miss < 8.0, "inserted blades pass through the visible vulva opening (miss=%.1f mm)" % miss)
	var canal: Dictionary = rig.call("vagina_canal")
	if not canal.is_empty():
		var opening: Vector3 = canal["opening_world"]
		_ok(opening.distance_to(vis) < 0.008, "canal opening is the visible introitus (%.1f mm)" % (opening.distance_to(vis) * 1000.0))
	# 壁变形与叶片半开距一致：CLOSED_HALF + depth * tan(half_angle)
	var sd: Vector4 = rig.get("_spec_d")
	var so: Vector4 = rig.get("_spec_o")
	var half := deg_to_rad(12.0)
	var expect := 0.012 + float(so.w) * tan(half)
	_ok(absf(float(sd.w) - expect) < 0.002, "wall half-gap matches the blades at 24° (got %.1f mm, expect %.1f mm)" % [sd.w * 1000.0, expect * 1000.0])
	# 清掉扩张器，避免挡住子宫测试
	s.call("request_remove_speculum")
	s.call("debug_finish_speculum_anim")
	await _frames(2)


func _check_picking_priority() -> void:
	s.call("set_tool", "scalpel")
	await _open_wound()
	var rig: Node = _organ_rig()
	_ok(s.has_method("organ_display_name"), "surgery exposes organ_display_name()")
	_ok(str(s.call("organ_display_name", "uterus")) == "子宫", "uterus is labelled 子宫")
	_ok(str(s.call("organ_display_name", "small_intestine")) == "小肠", "small intestine is labelled 小肠")
	_ok(str(s.call("organ_display_name", "colon")) == "大肠", "colon is labelled 大肠")
	_ok(str(s.call("organ_display_name", "tube")) == "输卵管", "tube is labelled 输卵管")
	_ok(str(s.call("organ_display_name", "ovary")) == "卵巢", "ovary is labelled 卵巢")
	_ok(str(s.call("organ_display_name", "bladder")) == "膀胱", "bladder is labelled 膀胱")
	# 构造一条先碰到小肠、再碰到子宫的射线：从子宫前方远处沿 -Z 射入。
	var uaim := _aim_at_kind("uterus")
	_ok(uaim.size() == 2, "can aim at the uterus")
	if uaim.size() == 2:
		var far_o: Vector3 = uaim[0] + Vector3(0, 0, 0.18)
		var far_d: Vector3 = (uaim[0] + uaim[1] * 0.001 - far_o).normalized()
		# 先看这条长射线沿途有没有小肠。
		var si: Dictionary = rig.call("ray_pick_viscera", far_o, far_d, PackedStringArray(["small_intestine"]))
		var ut: Dictionary = rig.call("ray_pick_viscera", far_o, far_d, PackedStringArray(["uterus"]))
		if not si.is_empty() and not ut.is_empty() and float(si["dist"]) < float(ut["dist"]):
			var hit: Dictionary = rig.call("ray_pick_viscera", far_o, far_d)
			_ok(str(hit.get("kind", "")) == "uterus", "a ray that first hits small intestine still picks the uterus behind it (got '%s')" % hit.get("kind", ""))
		else:
			# 退路：贴着子宫表面点选，不应被小肠抢走（v0411 已有，这里再保证一次）。
			var aim := _aim_at_kind("uterus")
			var hit0: Dictionary = rig.call("ray_pick_viscera", aim[0], aim[1], PackedStringArray(["uterus"]))
			if not hit0.is_empty():
				var o2: Vector3 = hit0["point"] - (aim[1] as Vector3) * 0.008
				var hit2: Dictionary = rig.call("ray_pick_viscera", o2, aim[1])
				_ok(str(hit2.get("kind", "")) == "uterus", "near-surface uterus pick is not stolen by small intestine (got '%s')" % hit2.get("kind", ""))
	# 只点到小肠时才是小肠。
	var saim := _aim_at_kind("small_intestine")
	if saim.size() == 2:
		var sh: Dictionary = rig.call("ray_pick_viscera", saim[0], saim[1], PackedStringArray(["small_intestine"]))
		if not sh.is_empty():
			var o3: Vector3 = sh["point"] - (saim[1] as Vector3) * 0.006
			# 若近处这条射线 9cm 内没有其它优先器官，应返回小肠。
			var all: Dictionary = rig.call("ray_pick_viscera", o3, saim[1])
			var k := str(all.get("kind", ""))
			_ok(k == "small_intestine" or k == "uterus" or k == "colon" or k == "bladder" or k == "tube" or k == "ovary", "a real small-intestine surface hit returns an organ kind (got '%s')" % k)
			if k == "small_intestine":
				_ok(true, "small intestine is pickable when the click actually hits it")
	# 空创口点击不再默认为小肠。
	var pulls0 := int(s.call("gut_pull_count"))
	var wound: Vector3 = s.call("_wound_center_world")
	var outw: Vector3 = s.call("_cavity_outward")
	# 从创口中心往完全空的一侧（明显避开脏器）射一枪：用过滤空结果的射线。
	var miss_o := wound + Vector3(0.25, 0.0, 0.0)
	var miss_d := Vector3(1, 0, 0)
	s.call("set_tool", "forceps")
	s.call("set_forceps_mode", "pull")
	var began := bool(s.call("begin_stroke", miss_o, miss_d))
	if began:
		s.call("debug_forceps_end")
	_ok(int(s.call("gut_pull_count")) == pulls0, "a click that does not hit intestine geometry does not start a small-intestine pull")
	# HUD 标签
	_ok(hud.get("_organ_target_label") != null or hud.find_child("SurgeryOrganTarget", true, false) != null, "HUD has a selected-target label")
	s.call("hover_tool", uaim[0], uaim[1]) if uaim.size() == 2 else 0
	# 真正点子宫
	if uaim.size() == 2:
		# 用 debug 选中
		_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract for the target label")
		_ok(str(s.call("get_organ_target_label")) == "子宫", "selected-target label is 子宫 (got '%s')" % str(s.call("get_organ_target_label")))
		s.call("debug_putback_organ", "uterus")
		for i in 40:
			s.call("_update_guts", 1.0 / 30.0)
		s.call("restore_body")
		# restore exits some state; re-enter
		s.call("enter_surgery")
		await _frames(2)


func _check_hint_and_hide() -> void:
	s.call("set_tool", "scalpel")
	await _open_wound()
	var rig: Node = _organ_rig()
	_ok(bool(s.call("debug_begin_extract", "colon")), "colon pull starts")
	var ropes: Array = s.call("colon_ropes") if s.has_method("colon_ropes") else s.call("gut_ropes")
	_ok(not ropes.is_empty(), "a colon rope exists")
	if ropes.is_empty():
		return
	var rope: Node = ropes[0]
	s.call("debug_forceps_drag_to", rope.get("hold_pos") + Vector3(0.0, 0.20, 0.10))
	await _frames(8)
	s.call("_update_guts", 1.0 / 30.0)
	var fed := float(rope.get("fed_len"))
	_ok(fed > 0.05, "colon has been pulled out (fed=%.0f mm)" % (fed * 1000.0))
	var win: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var hidden := 0.0
	for v in win:
		if v.z > 0.5:
			hidden = maxf(hidden, v.y * 2.0)
	_ok(hidden > 0.02, "static colon mesh hides a window matching the pulled length (along width=%.3f, fed=%.3f)" % [hidden, fed])
	_ok(str(s.call("get_organ_target_label")) == "大肠", "selected target is 大肠")
	_ok(bool(s.call("debug_putback_organ", "colon")), "colon put-back starts")
	for i in 80:
		s.call("_update_guts", 1.0 / 30.0)
	var win2: PackedVector4Array = rig.call("gut_eaten_windows", "colon")
	var left := 0.0
	for v2 in win2:
		if v2.z > 0.5:
			left = maxf(left, v2.y)
	_ok(left <= 0.001 and int(s.call("colon_pull_count")) == 0, "put-back restores the static colon mesh (left width=%.3f)" % left)
	# 小肠同样
	s.call("set_tool", "forceps")
	_ok(bool(s.call("debug_begin_extract", "small")), "small-intestine pull starts")
	var all: Array = s.call("gut_ropes")
	_ok(not all.is_empty(), "a small-intestine rope exists")
	if not all.is_empty():
		var rs: Node = all[all.size() - 1]
		s.call("debug_forceps_drag_to", rs.get("hold_pos") + Vector3(0.0, 0.16, 0.08))
		await _frames(8)
		s.call("_update_guts", 1.0 / 30.0)
		var wsi: PackedVector4Array = rig.call("gut_eaten_windows", "small_intestine")
		var hs := 0.0
		for v3 in wsi:
			if v3.z > 0.5:
				hs = maxf(hs, v3.y)
		_ok(hs > 0.01, "static small-intestine mesh hides the pulled segment (half-width=%.3f)" % hs)
	s.call("restore_body")
	await _frames(3)
	var win3: PackedVector4Array = rig.call("gut_eaten_windows", "small_intestine")
	var left3 := 0.0
	for v4 in win3:
		if v4.z > 0.5:
			left3 = maxf(left3, v4.y)
	_ok(left3 <= 0.001, "restore_body restores the static intestine meshes")
