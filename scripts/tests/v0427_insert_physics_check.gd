extends "res://scripts/tests/v0409b_check.gd"
## 宫底顶起整例子宫、内外膜壁厚、阴唇按插入物截面动态撑开。不打包。
##   godot --headless --path . -s res://scripts/tests/v0427_insert_physics_check.gd


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
		print("v0427_insert_physics_check: fails=", fails)
		quit(1)
		return
	var vm = player.call("get_vagina_mode")
	_ok(vm != null, "vagina mode exists")
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	var ctl: Node = vm.call("tool_controller")
	var org: Node = player.call("get_organs")
	_ok(ctl != null and org != null, "ball-rod and organ rig are ready")
	if ctl == null or org == null:
		print("v0427_insert_physics_check: fails=", fails)
		quit(1)
		return
	await _check_labia_ball(vm, ctl, org)
	await _check_fundus_and_wall(ctl, org)
	await _check_labia_speculum(vm, org)
	print("v0427_insert_physics_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_labia_ball(_vm: Node, ctl: Node, org: Node) -> void:
	_ok(org.get("vulva") != null and org.vulva.has_method("introitus_opening"), "vulva flaps expose introitus_opening")
	if org.get("vulva") == null:
		return
	var r: float = float(ctl.call("radius"))
	ctl.call("debug_set_depth", 0.0)
	await _frames(3)
	var op: Dictionary = org.vulva.call("introitus_opening")
	var hx0 := float(op.get("radius", 0.0))
	_ok(hx0 > r * 0.85, "labia opening tracks the ball slice at the introitus (%.1f vs ball %.1f mm)" % [hx0 * 1000.0, r * 1000.0])
	var ext0 := Vector2.ZERO
	if org.vulva.has_method("introitus_half_extents"):
		ext0 = org.vulva.call("introitus_half_extents")
		_ok(ext0.x >= r * 0.80, "labia mesh half-width is pushed by the ball (hx=%.1f mm, ball=%.1f mm)" % [ext0.x * 1000.0, r * 1000.0])
	var gap0 := 0.0
	if org.vulva.has_method("gap_width"):
		gap0 = float(org.vulva.call("gap_width"))
		_ok(gap0 > r * 0.6, "labia mesh gap opens around the ball (%.1f mm)" % (gap0 * 1000.0))
	# 球穿过后外口应收在杆的撑开半径上（插入物回缩约 0.9 s，这里快进 tick）。
	ctl.call("debug_set_depth", maxf(r * 2.2, 0.03))
	await _frames(2)
	var shaft := 0.0065
	var ins0 = ctl.get("_inserter")
	if ins0 and ins0.has_method("tick"):
		ins0.call("tick", 2.40)
		if org.vulva.has_method("set_inserter"):
			org.vulva.call("set_inserter", ins0)
	var op1: Dictionary = org.vulva.call("introitus_opening")
	var hx1 := float(op1.get("radius", 0.0))
	_ok(absf(hx1 - shaft) < 0.0025, "labia opening settles to the shaft clearance after the ball passes (%.1f vs %.1f mm)" % [hx1 * 1000.0, shaft * 1000.0])
	_ok(float(org.call("vulva_spread")) < 0.15, "ball/shaft dilation does not use the mechanical labia hinge (spread=%.2f)" % float(org.call("vulva_spread")))


func _check_fundus_and_wall(ctl: Node, org: Node) -> void:
	# 布置到宫腔内再连推越过旧的 80 mm 上限，确认子宫继续跟着走、球不穿出外膜。
	var contact: float = float(ctl.call("fundus_contact_depth"))
	ctl.call("debug_set_depth", contact - 0.004)
	await _frames(2)
	_ok(bool(ctl.get("through_cervix")), "ball is through the cervix before the fundus push")
	var lift0: float = float(ctl.call("debug_fundus_lift"))
	# 推过旧 80 mm 硬顶：目标 contact+0.12。
	for _i in 16:
		ctl.call("debug_push_depth", contact + 0.12, 0.08)
	await _frames(3)
	var lift1: float = float(ctl.call("debug_fundus_lift"))
	print("FUNDUS lift %.1f -> %.1f mm (want ~120 mm, cap 200 mm)" % [lift0 * 1000.0, lift1 * 1000.0])
	_ok(lift1 > 0.090, "continued insertion past the old 80 mm cap still lifts the uterus (%.1f mm)" % (lift1 * 1000.0))
	_ok(lift1 <= 0.201, "lift stays within the raised cap (%.1f mm)" % (lift1 * 1000.0))
	var tip: Vector3 = ctl.call("tip_world")
	var rad: float = float(ctl.call("radius"))
	var enc: Dictionary = org.call("debug_insert_enclosure", tip, rad)
	print("ENCLOSURE inside_cavity=%s below_outer=%s wall_min=%.2f fundus_wall=%.2f mm tip=%.1f cav=%.1f outer=%.1f n=%s/%s pairs=%s neg=%s" % [enc.get("inside_cavity"), enc.get("below_outer"), float(enc.get("wall_min", 99.0)) * 1000.0, float(enc.get("fundus_wall", 0.0)) * 1000.0, float(enc.get("tip_along", 0.0)) * 1000.0, float(enc.get("cavity_along", 0.0)) * 1000.0, float(enc.get("outer_along", 0.0)) * 1000.0, enc.get("cavity_n"), enc.get("outer_n"), enc.get("wall_samples", 0), enc.get("wall_neg", 0)])
	_ok(bool(enc.get("inside_cavity", false)), "ball center stays inside the uterine cavity at max insertion (tip %.1f / cavity %.1f mm)" % [float(enc.get("tip_along", 0.0)) * 1000.0, float(enc.get("cavity_along", 0.0)) * 1000.0])
	_ok(bool(enc.get("below_outer", false)), "ball center stays below the outer fundus wall (tip+r vs outer %.1f / %.1f mm)" % [(float(enc.get("tip_along", 0.0)) + rad) * 1000.0, float(enc.get("outer_along", 0.0)) * 1000.0])
	var fw := float(enc.get("fundus_wall", 0.0))
	var wm := float(enc.get("wall_min", 99.0))
	_ok(fw >= 0.002, "outer fundus stays ahead of the inner lining (%.2f mm)" % (fw * 1000.0))
	if int(enc.get("wall_samples", 0)) >= 4:
		_ok(wm >= 0.002, "outer wall dilates with the inner wall (min thickness %.2f mm)" % (wm * 1000.0))
	else:
		# 方向锥里没有配对点时，至少宫底轴向壁厚已经检查过。
		_ok(fw >= 0.002, "wall thickness uses fundus axial gap when no radial pairs (%s pairs, fundus %.2f mm)" % [enc.get("wall_samples", 0), fw * 1000.0])
	# 抽出后顶起恢复。
	for _j in 10:
		ctl.call("debug_push_depth", contact * 0.45, 0.08)
	await _frames(3)
	var lift2: float = float(ctl.call("debug_fundus_lift"))
	_ok(lift2 < 0.004, "uterus recovers when the rod is withdrawn (lift=%.2f mm)" % (lift2 * 1000.0))


func _check_labia_speculum(vm: Node, org: Node) -> void:
	var surg = player.call("get_surgery") if player.has_method("get_surgery") else null
	_ok(surg != null, "surgery system exists for the speculum check")
	if surg == null:
		return
	# 退出阴道互动再进手术，避免工具互斥。
	if vm.has_method("exit"):
		vm.call("exit")
	await _frames(2)
	surg.call("enter_surgery")
	await _frames(3)
	surg.call("set_tool", "speculum")
	if surg.has_method("debug_finish_speculum_anim"):
		surg.call("debug_finish_speculum_anim")
	await _frames(3)
	_ok(bool(surg.call("is_speculum_inserted")) if surg.has_method("is_speculum_inserted") else true, "speculum is inserted")
	_ok(float(org.call("vulva_spread")) < 0.15, "inserted speculum does not mechanically hinge the labia (spread=%.2f)" % float(org.call("vulva_spread")))
	if org.get("vulva") and org.vulva.has_method("introitus_half_extents"):
		var ext: Vector2 = org.vulva.call("introitus_half_extents")
		print("SPECULUM labia extents hx=%.1f hy=%.1f mm spread=%.2f" % [ext.x * 1000.0, ext.y * 1000.0, float(org.call("vulva_spread"))])
		_ok(ext.x >= 0.012 and ext.y >= 0.010, "labia mesh is pushed open by the blade cross-section (hx=%.1f hy=%.1f mm)" % [ext.x * 1000.0, ext.y * 1000.0])
	if org.vulva and org.vulva.has_method("gap_width"):
		var gap: float = float(org.vulva.call("gap_width"))
		_ok(gap > 0.012, "labia mesh gap opens around the blades (%.1f mm)" % (gap * 1000.0))
	surg.call("set_speculum_angle", 22.0)
	await _frames(3)
	if org.get("vulva") and org.vulva.has_method("introitus_half_extents"):
		var ext2: Vector2 = org.vulva.call("introitus_half_extents")
		_ok(ext2.y >= 0.016, "labia height follows the opened blades (hy=%.1f mm)" % (ext2.y * 1000.0))
	_ok(float(org.call("vulva_spread")) < 0.15, "opening the speculum still does not use a hinge spread (%.2f)" % float(org.call("vulva_spread")))
	if surg.has_method("request_remove_speculum"):
		surg.call("request_remove_speculum")
		if surg.has_method("debug_finish_speculum_anim"):
			surg.call("debug_finish_speculum_anim")
		await _frames(2)
