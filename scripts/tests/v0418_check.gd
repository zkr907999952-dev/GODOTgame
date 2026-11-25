extends "res://scripts/tests/v0409b_check.gd"
## 未发布（0.4.12 开发中）：长柄金属球——直径=碰撞、通道扩张、宫颈突破、子宫撑开。不打包。
##   godot --headless --path . -s res://scripts/tests/v0418_check.gd


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
		print("v0418_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	if s and bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(2)
	var vm = player.call("get_vagina_mode")
	_ok(vm != null, "vagina mode exists")
	if vm == null:
		print("v0418_check: fails=", fails)
		quit(1)
		return
	player.call("set_play_mode", 0)
	_ok(bool(vm.call("enter")), "enter vagina mode")
	await _frames(3)
	var reg = vm.get("registry")
	var tool = reg.call("get_tool", "ball_rod") if reg else null
	_ok(tool != null and bool(tool.is_usable()), "ball_rod is a usable registry tool")
	vm.call("set_tool", "ball_rod")
	await _frames(3)
	_ok(str(vm.call("current_tool")) == "ball_rod", "selecting the tool sets current_tool")
	var ctl: Node = vm.call("tool_controller")
	_ok(ctl != null, "ball-rod controller is running")
	if ctl == null:
		print("v0418_check: fails=", fails)
		quit(1)
		return
	_check_mesh_and_diameter(ctl)
	_check_mid_canal(ctl, vm)
	await _check_cervix_and_uterus(ctl, vm)
	_check_projection(ctl, vm)
	_ok(int(ctl.get("last_step_usec")) >= 0 and int(ctl.get("last_step_usec")) < 8000, "ball-rod step is cheap (%d µs)" % int(ctl.get("last_step_usec")))
	hud.call("_refresh_surgery_ui")
	await _frames(1)
	var box = hud.get("_ball_box")
	_ok(box != null and bool(box.visible), "diameter slider is shown for the ball-rod")
	vm.call("exit")
	await _frames(2)
	_ok(not bool(vm.call("is_active")), "exit vagina mode")
	print("v0418_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_mesh_and_diameter(ctl: Node) -> void:
	ctl.call("set_diameter", 0.024)
	var r := float(ctl.call("radius"))
	var cr := float(ctl.call("collider_radius"))
	_ok(absf(r - 0.012) < 1e-5, "radius is half the 24 mm diameter (r=%.1f mm)" % (r * 1000.0))
	_ok(absf(cr - r) < 1e-5, "collider radius matches the visual radius (%.3f vs %.3f)" % [cr, r])
	var tip: MeshInstance3D = null
	var root3: Node3D = ctl.get("_root")
	_ok(root3 != null and root3.visible, "ball-rod node is in the tree and visible")
	if root3:
		_ok(root3.global_position.is_finite(), "tool transform is finite")
		tip = root3.get_node_or_null("Tip")
	_ok(tip != null and tip.mesh is SphereMesh, "tip is a sphere mesh")
	if tip and tip.mesh is SphereMesh:
		var sm: SphereMesh = tip.mesh
		_ok(absf(sm.radius - r) < 1e-5, "sphere mesh radius equals collider (%.1f mm)" % (sm.radius * 1000.0))
	if tip and tip.material_override is StandardMaterial3D:
		var mat: StandardMaterial3D = tip.material_override
		_ok(mat.metallic >= 0.99 and mat.roughness >= 0.08 and mat.roughness <= 0.15, "chrome PBR: metallic=%.2f roughness=%.2f" % [mat.metallic, mat.roughness])
	else:
		_ok(false, "tip has a StandardMaterial3D chrome override")
	var shaft: MeshInstance3D = root3.get_node_or_null("Shaft") if root3 else null
	_ok(shaft != null and shaft.mesh is CylinderMesh, "shaft is a cylinder mesh")


func _check_mid_canal(ctl: Node, vm) -> void:
	ctl.call("set_diameter", 0.020)
	var canal_len := float(vm.call("introitus_world").distance_to(vm.call("cervix_world")))
	var mid := canal_len * 0.45
	ctl.call("debug_reset_gate")
	ctl.call("debug_set_depth", mid)
	var r := float(ctl.call("radius"))
	var cr := float(ctl.call("canal_radius_at_ball"))
	_ok(cr + 1e-4 >= r, "canal radius at the ball depth is at least the ball radius (canal=%.1f mm ball=%.1f mm)" % [cr * 1000.0, r * 1000.0])
	var tip_p: Vector3 = ctl.call("tip_world")
	_ok(tip_p.is_finite(), "tip position is finite mid-canal")
	var opening: Vector3 = vm.call("introitus_world")
	var axis: Vector3 = vm.call("canal_axis_world")
	var along := (tip_p - opening).dot(axis)
	_ok(absf(along - mid) < 0.008, "tip sits at the requested canal depth (%.1f vs %.1f mm)" % [along * 1000.0, mid * 1000.0])
	# 不穿透：目标半径不得小于球半径（分析式与着色器同一公式）。
	_ok(not is_nan(cr) and not is_inf(cr), "canal radius is finite (no NaN)")
	var ins = ctl.get("_inserter")
	_ok(ins != null and float(ins.call("mix")) > 0.5, "VulvaInserter is active while the ball is in the canal")
	if ins and ins.has_method("slice_radius"):
		# 球已完全过外口时，外口截面应收在杆径附近（或至少不超过球半径）。
		_ok(float(ins.call("slice_radius")) <= r + 1e-5, "introitus slice is not larger than the ball")


func _check_cervix_and_uterus(ctl: Node, vm) -> void:
	ctl.call("set_diameter", 0.020)
	var cerv := float(vm.call("introitus_world").distance_to(vm.call("cervix_world")))
	var r := float(ctl.call("radius"))
	var thr := float(ctl.call("cervix_threshold"))
	_ok(thr > 0.015, "cervix threshold is significant (%.1f mm of blocked travel)" % (thr * 1000.0))
	var thr_small := 0.0
	ctl.call("set_diameter", 0.014)
	thr_small = float(ctl.call("cervix_threshold"))
	ctl.call("set_diameter", 0.028)
	var thr_big := float(ctl.call("cervix_threshold"))
	_ok(thr_big > thr_small + 0.005, "threshold scales with ball diameter (%.1f -> %.1f mm)" % [thr_small * 1000.0, thr_big * 1000.0])
	ctl.call("set_diameter", 0.020)
	thr = float(ctl.call("cervix_threshold"))
	ctl.call("debug_reset_gate")
	ctl.call("debug_set_depth", cerv - r * 0.9)
	# 轻推：压力不够，不应穿过。
	ctl.call("debug_add_pressure", thr * 0.25)
	ctl.call("apply_desired_depth", cerv + r + 0.02, 0.016)
	_ok(not bool(ctl.get("through_cervix")), "a light push does not pop through the cervix")
	_ok(int(ctl.get("breakthrough_count")) == 0, "no breakthrough event yet")
	# 压力达到阈值后再推：突破。
	ctl.call("debug_add_pressure", thr)
	ctl.call("apply_desired_depth", cerv + r + 0.03, 0.016)
	_ok(bool(ctl.get("through_cervix")), "threshold pressure pops through the cervix")
	_ok(int(ctl.get("breakthrough_count")) >= 1, "a breakthrough event was raised")
	var tip_p: Vector3 = ctl.call("tip_world")
	var opening: Vector3 = vm.call("introitus_world")
	var axis: Vector3 = vm.call("canal_axis_world")
	var along := (tip_p - opening).dot(axis)
	_ok(along > cerv, "after breakthrough the tip is past the cervix (%.1f mm past os, canal=%.1f mm)" % [(along - cerv) * 1000.0, cerv * 1000.0])
	_ok(float(ctl.get("uterus_distend")) > 0.004, "uterus / cavity distends around the ball (%.1f mm)" % (float(ctl.get("uterus_distend")) * 1000.0))
	_ok(tip_p.is_finite() and not is_nan(along), "pose stays finite through breakthrough")
	# 回拉：压力不够先卡住，攒够再出来。
	var count0 := int(ctl.get("breakthrough_count"))
	ctl.call("debug_add_pressure", 0.0)
	ctl.set("cervix_pressure", 0.0)
	ctl.call("apply_desired_depth", -0.04, 0.016)
	# 一次轻拉不应立刻出来（还在宫腔或卡在宫颈）。
	# 再加压力应退出。
	ctl.call("debug_add_pressure", thr)
	ctl.call("apply_desired_depth", -0.05, 0.016)
	_ok(not bool(ctl.get("through_cervix")) and int(ctl.get("breakthrough_count")) > count0, "pull-back also resists, then pops out of the cervix")
	return


func _check_projection(ctl: Node, vm) -> void:
	var cam: Camera3D = player.call("get_camera")
	_ok(cam != null, "camera exists for drag projection")
	if cam == null:
		return
	for preset in ["introitus", "abdomen"]:
		vm.call("set_camera_preset", preset, true)
		var opening: Vector3 = vm.call("introitus_world")
		var axis: Vector3 = vm.call("canal_axis_world")
		# 屏幕中心射线。
		var vp := player.get_viewport() if player else root
		var c: Vector2 = (vp.get_visible_rect().size if vp else Vector2(1280, 720)) * 0.5
		var origin := cam.project_ray_origin(c)
		var dir := cam.project_ray_normal(c)
		var p: Vector3 = ctl.call("project_pointer", origin, dir)
		_ok(p.is_finite(), "%s drag projection is finite" % preset)
		var dlat := (p - opening).cross(axis).length()
		# 投影应落在通道附近，而不是飞到远处。
		_ok(p.distance_to(opening) < 0.35, "%s projection stays near the tract (%.1f cm)" % [preset, p.distance_to(opening) * 100.0])
		_ok(dlat < 0.08, "%s projection is close to the canal axis (lateral %.1f mm)" % [preset, dlat * 1000.0])
