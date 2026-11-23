extends "res://scripts/tests/v0408_check.gd"
## 未发布自检：互动「动作」栏在检查床以外也可用、「掰开小穴」注册表、分身捂腹掌心方向、
## 阴部跟随腹部柔体 / 拖拽不留在原地、拨开后无 NaN 破面。不钉死导出版本号。
##   godot --headless --path . -s res://scripts/tests/v0409_check.gd


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
	var only := OS.get_environment("V0409_ONLY")
	if only == "" or only == "action":
		await _check_offbed_action()
	if only == "" or only == "cover":
		await _check_clone_cover_palms()
	if only == "" or only == "soft":
		await _check_genital_follow()
	if only == "" or only == "mesh":
		_check_spread_mesh()
	print("v0409_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _acts(host: Node = null):
	var h: Node = host if host else player
	return h.call("get_actions") if h and h.has_method("get_actions") else null


func _check_offbed_action() -> void:
	player.call("set_play_mode", 0)
	# 确保不在检查床上
	if str(player.get("occupancy")) == "exam_bed" and vs:
		vs.call("try_exit")
		await _phys(8)
		await _frames(4)
	var acts = _acts()
	_ok(acts != null, "player has a character_actions instance")
	if acts == null:
		return
	var ids: PackedStringArray = PackedStringArray()
	var labels: PackedStringArray = PackedStringArray()
	for it in acts.call("list", player):
		ids.append(str(it["id"]))
		labels.append(str(it["label"]))
		if str(it["id"]) == "spread_vulva":
			_ok(bool(it["available"]), "spread_vulva is available while standing off the exam bed")
	_ok(ids.has("spread_vulva") and labels.has("掰开小穴"), "action registry contains 掰开小穴 (ids=%s)" % [ids])
	# 打开互动面板，刷新动作栏。
	var panel = hud.get("_panel_interact")
	if panel:
		panel.visible = true
	hud.call("_refresh_interact_actions")
	await _frames(2)
	var bar: PackedStringArray = hud.get("debug_interact_action_labels")
	_ok(bar.has("掰开小穴"), "互动 menu action bar lists 掰开小穴 (%s)" % [bar])
	var rig: Node = player.call("get_organs")
	var skel: Skeleton3D = player.call("get_skeleton")
	var h0: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("L_Hand_a")).origin
	hud.call("debug_run_interact_action", "spread_vulva")
	await _phys(40)
	_ok(str(acts.get("active_id")) == "spread_vulva" and float(acts.get("hand_u")) > 0.3, "off-bed toggle starts the spread action (hand_u=%.2f)" % float(acts.get("hand_u")))
	await _phys(80)
	_ok(float(rig.call("vulva_spread")) > 0.99, "standing spread drives vulva_spread to 1 (%.2f)" % float(rig.call("vulva_spread")))
	var h1: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("L_Hand_a")).origin
	_ok(h1.distance_to(h0) > 0.08, "hands leave the idle pose to reach the vulva (moved %.0f mm)" % (h1.distance_to(h0) * 1000.0))
	_ok(h1.is_finite(), "hand position is finite")
	hud.call("debug_run_interact_action", "__stop")
	await _phys(90)
	_ok(not bool(acts.call("busy")) and float(rig.call("vulva_spread")) == 0.0, "停止 from the 互动 bar closes the pose and labia")
	# 检查床按钮在床下仍隐藏（0.4.08 约定保留）
	if "debug_bed_action_visible" in hud:
		_ok(not bool(hud.get("debug_bed_action_visible")), "exam-bed 动作 chrome button stays hidden off the bed")


func _check_clone_cover_palms() -> void:
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.45, 0.0, -0.85))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for cover-pose check")
	if clones.is_empty():
		return
	var c: Node = clones[clones.size() - 1]
	var hr: Node = c.call("get_hit_reaction")
	var org: Node = c.call("get_organs")
	var inside: Vector3 = c.global_position + Vector3(0, 1.02, 0.0)
	if org and org.has_method("abdomen_frame"):
		var fr: Transform3D = org.call("abdomen_frame")
		inside = fr * Vector3(0, -0.02, -0.02)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": inside})
	await _phys(12)
	if hr:
		hr.set("cover_life", 2.2)
		hr.set("cover_weight", 1.0)
		var loco = c.get("loco")
		if loco:
			loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
		hr.call("apply_cover", 0.0)
	_ok(hr != null and bool(hr.call("is_covering")), "unarmed clone covers a hit")
	if hr == null or not hr.has_method("cover_joint_debug"):
		return
	var j: Dictionary = hr.call("cover_joint_debug")
	for side in ["L", "R"]:
		var palm_skin := float(j.get(side + "_palm_to_skin", -9.0))
		var palm_in := float(j.get(side + "_palm_in", -9.0))
		_ok(palm_skin > 0.25, "clone %s palm faces the belly skin (palm_to_skin=%.2f)" % [side, palm_skin])
		_ok(palm_in > 0.15, "clone %s palm faces inward, not twisted backward (palm_in=%.2f)" % [side, palm_in])
		var flex := float(j.get(side + "_flex_deg", 0.0))
		var hinge := float(j.get(side + "_hinge", 0.0))
		_ok(hinge > 0.0, "clone %s elbow hinge is not reversed (hinge=%.2f, flex=%.1f deg)" % [side, hinge, flex])
	if hr.has_method("cover_debug"):
		var d: Dictionary = hr.call("cover_debug")
		_ok(not bool(d.get("hands_crossed", true)), "clone cover hands are not crossed")


func _check_genital_follow() -> void:
	var rig: Node = player.call("get_organs")
	var vf = rig.call("vulva_flaps")
	_ok(vf != null and bool(vf.ok), "vulva flaps exist")
	if vf == null:
		return
	var vest: MeshInstance3D = vf.vest_mi
	_ok(vest != null, "vestibule mesh exists")
	var sm: ShaderMaterial = vf.soft_mat
	_ok(sm != null and sm.shader != null, "vestibule uses the soft-body mucosa shader")
	if sm:
		var col: Color = sm.get_shader_parameter("mucosa_color")
		# 不应再是饱和大红 (0.66, 0.33, 0.35)：色相偏粉、饱和度更低
		_ok(col.r < 0.90 and col.g > 0.50 and col.b > 0.48, "mucosa color is a natural pink (%.2f, %.2f, %.2f)" % [col.r, col.g, col.b])
		_ok(col.r - col.g < 0.30, "mucosa is not overly red versus green (Δ=%.2f)" % (col.r - col.g))
	var mats: Array = rig.get("_all_mats")
	_ok(sm != null and sm in mats, "vestibule material is registered for abdomen soft uniforms")
	# 拖拽柔体：前庭材质的 drag_off 必须跟腹壁一致
	var navel: Vector3 = (rig.call("abdomen_frame") as Transform3D).origin
	rig.call("begin_drag", navel)
	rig.call("update_drag", navel + Vector3(0.06, 0.0, 0.08))
	for i in 8:
		rig.call("_step_drag", 0.016)
		rig.call("_update_frame")
		rig.call("_push_uniforms")
	var off: Vector3 = rig.get("_drag_off")
	_ok(off.length() > 0.01, "belly drag produced a soft offset (%.1f mm)" % (off.length() * 1000.0))
	if sm:
		var uoff: Vector3 = sm.get_shader_parameter("drag_off")
		_ok(uoff.distance_to(off) < 1e-5, "vestibule shader drag_off follows the body (mat=%s rig=%s)" % [uoff, off])
	rig.call("end_drag")
	# 传送后阴部网格跟着髋骨走，不会留在原地
	var skel: Skeleton3D = player.call("get_skeleton")
	var hi := skel.find_bone("C_Hip_a")
	var hip0: Transform3D = skel.global_transform * skel.get_bone_global_pose(hi)
	var vest0: Vector3 = vest.global_position
	var flap0: Vector3 = vf.flaps_mi.global_position if vf.flaps_mi else Vector3.ZERO
	var origin0 := player.global_position
	player.global_position = origin0 + Vector3(1.7, 0.0, 0.4)
	player.reset_physics_interpolation()
	await _phys(4)
	await _frames(2)
	var hip1: Transform3D = skel.global_transform * skel.get_bone_global_pose(hi)
	var vest1: Vector3 = vest.global_position
	var flap1: Vector3 = vf.flaps_mi.global_position if vf.flaps_mi else Vector3.ZERO
	var hip_move := hip1.origin.distance_to(hip0.origin)
	_ok(hip_move > 1.0, "hip moved with the teleport (%.2f m)" % hip_move)
	_ok(vest1.distance_to(vest0) > 1.0 and absf(vest1.distance_to(vest0) - hip_move) < 0.08, "vestibule followed the hip (moved %.2f m, hip %.2f m)" % [vest1.distance_to(vest0), hip_move])
	_ok(flap1.distance_to(flap0) > 1.0 and absf(flap1.distance_to(flap0) - hip_move) < 0.08, "vulva flaps followed the hip (moved %.2f m)" % flap1.distance_to(flap0))
	player.global_position = origin0
	player.reset_physics_interpolation()
	await _phys(2)


func _check_spread_mesh() -> void:
	var rig: Node = player.call("get_organs")
	var vf = rig.call("vulva_flaps")
	if vf == null or not bool(vf.ok):
		_ok(false, "vulva flaps for mesh check")
		return
	rig.call("set_vulva_spread", 1.0)
	var nan := 0
	var deg := 0
	var tris := 0
	for si in 2:
		var P: PackedVector3Array = vf.side_positions(si)
		for p in P:
			if not p.is_finite():
				nan += 1
		var arr: Array = vf._arrays[si]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for f in idx.size() / 3:
			tris += 1
			var a := P[idx[f * 3]]
			var b := P[idx[f * 3 + 1]]
			var c := P[idx[f * 3 + 2]]
			if not a.is_finite() or not b.is_finite() or not c.is_finite():
				nan += 1
				continue
			if (b - a).cross(c - a).length() < 1e-10:
				deg += 1
	var VP: PackedVector3Array = vf.vestibule_positions()
	for p in VP:
		if not p.is_finite():
			nan += 1
	_ok(nan == 0, "spread mesh has no NaN vertices")
	_ok(deg < maxi(3, tris / 40), "spread mesh is not torn into degenerate faces (%d / %d)" % [deg, tris])
	# 与身体相接的外缘顶点在拨开后仍停在原位（权重 0），避免破缝
	var seam := 0
	var moved := 0
	for si in 2:
		var src: PackedVector3Array = (vf._arrays[si] as Array)[Mesh.ARRAY_VERTEX]
		var cur: PackedVector3Array = vf.side_positions(si)
		var w: PackedFloat32Array = vf._w[si]
		for i in w.size():
			if w[i] <= 1e-5:
				seam += 1
				if cur[i].distance_to(src[i]) > 1e-5:
					moved += 1
	_ok(seam > 8 and moved == 0, "body-seam flap vertices stay put when spread (%d locked, %d moved)" % [seam, moved])
	# 前庭外圈（第 0 行）应落在开口边缘折线上（允许在边中点，不必贴顶点）
	var rim: PackedVector3Array = vf.rim_positions()
	var gap := 0.0
	if rim.size() > 3 and VP.size() >= 48:
		for k in 48:
			var pk: Vector3 = VP[k]
			var best := INF
			for i in rim.size():
				var q := Geometry3D.get_closest_point_to_segment(pk, rim[i], rim[(i + 1) % rim.size()])
				best = minf(best, pk.distance_to(q))
			gap = maxf(gap, best)
		_ok(gap < 0.003, "vestibule outer ring welds to the flap rim (max gap %.1f mm)" % (gap * 1000.0))
	rig.call("set_vulva_spread", 0.0)
	_ok(float(rig.call("vulva_spread")) == 0.0, "spread resets to 0 after the mesh check")
