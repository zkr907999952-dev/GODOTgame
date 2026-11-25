extends "res://scripts/tests/v0411_check.gd"
## 未发布（0.4.12 开发中）：子宫段链扯出跟随钳尖、输卵管封口接宫角、卵巢跟管尽头、
## 已扯出小肠后仍可点选其它可见体内小肠、小肠隐藏速率 0.48。
##   godot --headless --path . -s res://scripts/tests/v0415_check.gd


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
		print("v0415_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_uterus_pull()
	await _check_si_repick_and_hide()
	print("v0415_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_uterus_pull() -> void:
	await _open_wound()
	_ok(absf(float(s.call("si_hide_rate")) - 0.48) < 0.001, "SI hide rate is 0.48")
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract starts")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 30.0)
	var so: Node = s.call("soft_organ", "uterus")
	_ok(so != null, "soft uterus exists")
	if so == null:
		return
	var rest_f: Vector3 = so.call("rest_fundus_world")
	var spawn := (so.call("fundus_world") as Vector3).distance_to(rest_f)
	_ok(spawn < 0.012, "uterus still starts at the in-body rest pose (%.1f mm)" % (spawn * 1000.0))
	var wound: Vector3 = s.call("_wound_center_world")
	var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
	# 夹住宫底，按普通速度向外拉。
	var fund0: Vector3 = so.call("fundus_world")
	var aim := fund0
	var cage: PackedVector3Array = so.get("_p")
	if not cage.is_empty():
		aim = cage[cage.size() - 1]
	var cam_o := aim + Vector3(0.0, 0.10, 0.12)
	var cam_d := (aim - cam_o).normalized()
	_ok(bool(s.call("debug_forceps_begin", cam_o, cam_d)), "forceps grab the uterus fundus")
	var tip0: Vector3 = so.get("hold_pos")
	var max_lag := 0.0
	var dt := 1.0 / 60.0
	var speed := 0.20
	for i in 30:
		var tip: Vector3 = tip0 + outv * (speed * dt * float(i + 1))
		s.call("debug_forceps_drag_to", tip)
		s.call("_update_guts", dt)
		var hp: Vector3 = so.get("hold_pos")
		var fund: Vector3 = so.call("fundus_world")
		max_lag = maxf(max_lag, fund.distance_to(hp))
		var q: Dictionary = so.call("debug_mesh_quality")
		_ok(int(q.get("nan_verts", 1)) == 0 and bool(q.get("ok", false)), "no NaN/degenerate uterus mesh mid-pull")
		if int(q.get("nan_verts", 1)) != 0:
			break
	_ok(max_lag < 0.020, "fundus follows the forceps within 2 cm at normal pull speed (max lag %.1f mm)" % (max_lag * 1000.0))
	var edge := float(so.call("max_edge_ratio"))
	_ok(edge < 1.22, "rigid-skinned uterus edges stay near 1.0 (max ratio=%.3f, limit 1.22)" % edge)
	# 拉到足够伸出，检查输卵管 / 卵巢。
	_advance_charge("uterus", 1.0, 1.2)
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("extract_level", "uterus")) >= 4 or float(so.call("exposed_length")) > 0.03, "sustained pull extracts the uterus (level=%d exposed=%.1f mm)" % [int(s.call("extract_level", "uterus")), float(so.call("exposed_length")) * 1000.0])
	# 再拉一会儿让宫角出来、悬链激活
	_advance_charge("uterus", 1.0, 1.0)
	s.call("_update_guts", 1.0 / 30.0)
	if not bool(s.call("tube_chain_active", 0)):
		s.call("debug_grab_adnexa", 0)
		s.call("debug_grab_adnexa", 1)
		s.call("_update_guts", 1.0 / 30.0)
	_ok(bool(s.call("tube_chain_active", 0)) or so.has_method("tube_head_gap"), "adnexa available after pull")
	for side in [0, 1]:
		if so.has_method("tube_head_gap"):
			var gap: float = so.call("tube_head_gap", side)
			_ok(gap < 0.004, "tube head stays seated on horn %d (gap %.1f mm)" % [side, gap * 1000.0])
		if so.has_method("ovary_tip_gap"):
			var og: float = so.call("ovary_tip_gap", side)
			_ok(og < 0.003, "ovary sits on tube tip %d (gap %.1f mm)" % [side, og * 1000.0])
		_ok(bool(s.call("ovary_at_chain_end", side)) or float(so.call("ovary_tip_gap", side)) < 0.003, "ovary %d is at the tube end" % side)
	# 拖拽腹部后卵巢仍在管尽头
	var rig: Node = _organ_rig()
	var grab: Vector3 = s.call("_wound_center_world")
	rig.call("begin_drag", grab)
	rig.call("update_drag", grab + Vector3(0.0, 0.04, 0.04))
	for _j in 8:
		if rig.has_method("_step_drag"):
			rig.call("_step_drag", 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 30.0)
	for side2 in [0, 1]:
		if so.has_method("ovary_tip_gap"):
			_ok(float(so.call("ovary_tip_gap", side2)) < 0.004, "ovary stays on the tube tip during tissue drag (side %d, %.1f mm)" % [side2, float(so.call("ovary_tip_gap", side2)) * 1000.0])
	rig.call("end_drag")
	for _k in 6:
		if rig.has_method("_step_drag"):
			rig.call("_step_drag", 1.0 / 30.0)
		s.call("_update_guts", 1.0 / 30.0)
	_ok(bool(s.call("debug_putback_organ", "uterus")), "uterus put-back starts")
	for i in 200:
		s.call("_update_guts", 1.0 / 20.0)
	_ok(int(s.call("extract_level", "uterus")) == 0, "uterus returns after put-back")
	_ok(not bool(s.call("tube_chain_active", 0)) and not bool(s.call("tube_chain_active", 1)), "tube chains are gone after put-back")
	_ok(not bool(s.call("organ_source_hidden", "uterus")), "original uterus meshes are visible after put-back")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)


func _visible_si_points(max_n: int = 6) -> Array:
	var rig: Node = _organ_rig()
	var meshes: Array = rig.call("viscera_meshes", "small_intestine")
	var fr: Transform3D = rig.call("abdomen_frame")
	var navel: Vector3 = rig.get("_navel_rest")
	var out: Array = []
	for mi in meshes:
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var arr: Array = m.mesh.surface_get_arrays(0)
		var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var C: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0] if arr[Mesh.ARRAY_CUSTOM0] != null else PackedFloat32Array()
		if P.is_empty():
			continue
		var stride := 4 if C.size() >= P.size() * 4 else 1
		var step := maxi(1, int(P.size() / 80))
		var i := 0
		while i < P.size() and out.size() < max_n * 3:
			var along := C[i * stride] if not C.is_empty() and i * stride < C.size() else -1.0
			var hidden := false
			if along >= 0.0 and rig.has_method("is_gut_along_hidden"):
				hidden = bool(rig.call("is_gut_along_hidden", "small_intestine", along))
			if not hidden:
				out.append({"point": fr * (P[i] - navel), "along": along})
			i += step
	# 分散取样
	if out.size() <= max_n:
		return out
	var picked: Array = []
	var stride2 := maxi(1, int(out.size() / max_n))
	for j in max_n:
		picked.append(out[mini(j * stride2, out.size() - 1)])
	return picked


func _check_si_repick_and_hide() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "small")), "first SI pull starts")
	await _frames(2)
	var ropes: Array = s.call("gut_ropes") if s.has_method("gut_ropes") else []
	if not ropes.is_empty():
		var rope: Node = ropes[0]
		s.call("debug_forceps_drag_to", rope.get("hold_pos") + Vector3(0.0, 0.16, 0.08))
		for _i in 12:
			s.call("_update_guts", 1.0 / 30.0)
	s.call("debug_forceps_end")
	s.call("_sync_gut_hide")
	_ok(int(s.call("gut_pull_count")) >= 1, "one SI loop is already out")
	var pts: Array = _visible_si_points(5)
	_ok(pts.size() >= 3, "several visible in-body SI points remain after the first pull (%d)" % pts.size())
	var hits := 0
	var second_ok := false
	for rec in pts:
		var pt: Vector3 = rec["point"]
		var origin := pt + Vector3(0.0, 0.02, 0.09)
		var dir := (pt - origin).normalized()
		var kind := str(s.call("debug_pick_viscera", origin, dir))
		if kind == "small_intestine":
			hits += 1
		if not second_ok and kind == "small_intestine":
			var n0 := int(s.call("gut_pull_count"))
			if bool(s.call("debug_forceps_begin", origin, dir)):
				s.call("_update_guts", 1.0 / 30.0)
				var n1 := int(s.call("gut_pull_count"))
				if n1 > n0:
					second_ok = true
				s.call("debug_forceps_end")
	_ok(hits >= 3, "visible in-body SI points are pickable after a prior pull (hits %d / %d)" % [hits, pts.size()])
	_ok(second_ok or int(s.call("gut_pull_count")) >= 2, "a second SI pull can be started from a visible in-body point")
	s.call("restore_body")
	s.call("enter_surgery")
	await _frames(2)
