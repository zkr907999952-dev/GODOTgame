extends "res://scripts/tests/v0406_check.gd"
## 0.4.07 自检：肚脐凹陷延迟压平、取消手术刀关闭预览、撞墙跑步回落、特写弹孔更小、附身 / 分身清单、载具驾驶坐姿。
##   godot --headless --path . -s res://scripts/tests/v0407_check.gd
##   （V0407_ONLY=navel|preview|wall|bullet|possess|seat）


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
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.4.07\"") >= 0 and presets.find("version/code=50") >= 0, "export version 0.4.07 / 50")
	var only := OS.get_environment("V0407_ONLY")
	if only == "" or only == "wall":
		await _check_wall_run()
	if only == "" or only == "possess":
		await _check_possess()
	if only == "" or only == "seat":
		await _check_seats()
	if only == "" or only in ["navel", "preview", "bullet"]:
		if not await _enter_bed():
			quit(1)
			return
		s = player.call("get_surgery")
		s.call("enter_surgery")
		await _frames(4)
		if only == "" or only == "navel":
			await _check_navel_lazy_flat()
		if only == "" or only == "preview":
			await _check_preview_cleared()
		if only == "" or only == "bullet":
			_check_bullet_radius()
	print("v0407_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _scalpel() -> void:
	if str(s.get("tool")) != "scalpel":
		s.call("set_tool", "scalpel")


func _check_navel_lazy_flat() -> void:
	s.call("restore_body")
	await _phys(3)
	if not bool(s.call("is_active")):
		s.call("enter_surgery")
	_scalpel()
	await _frames(3)
	var nav: Vector3 = s.get("_navel_rest")
	var d0 := float(s.call("navel_dimple_depth"))
	_ok(int(s.get("navel_flattened")) > 20 and int(s.call("navel_dimple_vert_count")) > 20, "cut topology still pre-flattened (%d verts), dimple kept for display (%d verts)" % [int(s.get("navel_flattened")), int(s.call("navel_dimple_vert_count"))])
	_ok(d0 > 0.003 and not bool(s.get("navel_flat_applied")), "uncut abdomen keeps the concave navel (depth %.1f mm)" % (d0 * 1000.0))
	_ok(_straight(nav + Vector3(-0.03, -0.075, 0), nav + Vector3(0.03, -0.075, 0)), "far cut below the navel")
	_ok(not bool(s.get("navel_flat_applied")) and float(s.call("navel_dimple_depth")) > 0.003, "a cut 7.5 cm away keeps the navel concave")
	_ok(_straight(nav + Vector3(0.001, 0.05, 0), nav + Vector3(-0.001, -0.05, 0)), "cut through the navel centre")
	_ok(bool(s.get("navel_flat_applied")), "cutting the navel switches to the flattened cut surface")
	s.call("restore_body")
	await _phys(2)
	_ok(not bool(s.get("navel_flat_applied")) and float(s.call("navel_dimple_depth")) > 0.003, "restore body brings the concave navel back")


func _check_preview_cleared() -> void:
	s.call("restore_body")
	await _phys(2)
	_scalpel()
	var nav: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "straight")
	_ok(bool(s.call("debug_set_straight_preview", nav + Vector3(-0.03, -0.05, 0), nav + Vector3(0.03, -0.05, 0))), "scalpel preview drawn")
	_ok(bool(s.call("has_cut_preview")), "preview visible with scalpel")
	s.call("set_tool", "grab")
	var dash: Node3D = s.get("_dash")
	_ok(not bool(s.call("has_cut_preview")) and (dash == null or not dash.visible), "switching to grab hides & clears the cut preview")
	s.call("set_tool", "scalpel")
	_ok(not bool(s.call("has_cut_preview")), "re-selecting the scalpel does not bring back the old preview")
	s.call("debug_set_straight_preview", nav + Vector3(-0.03, -0.05, 0), nav + Vector3(0.03, -0.05, 0))
	s.call("set_tool", "scalpel")  # 再点一次 = 取消选择
	dash = s.get("_dash")
	_ok(str(s.get("tool")) == "" and not bool(s.call("has_cut_preview")) and (dash == null or not dash.visible), "deselecting the scalpel hides the preview")
	s.call("debug_set_straight_preview", nav + Vector3(-0.03, -0.05, 0), nav + Vector3(0.03, -0.05, 0))
	s.call("exit_surgery")
	_ok(not bool(s.call("has_cut_preview")), "leaving surgery clears the preview")
	s.call("enter_surgery")


func _check_bullet_radius() -> void:
	var r1 := float(s.call("bullet_hole_radius", 1.0))
	var r0 := float(s.call("bullet_hole_radius", 0.0))
	_ok(r1 <= 0.0115 and r0 <= 0.0065 and r0 > 0.004, "bullet-cam hole radius smaller (%.1f–%.1f mm)" % [r0 * 1000.0, r1 * 1000.0])


func _check_wall_run() -> void:
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
	await _frames(4)
	var yaw := float(player.get("_yaw"))
	var fwd := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.3)
	cs.shape = box
	wall.add_child(cs)
	main.add_child(wall)
	wall.global_position = player.global_position + fwd * 2.0 + Vector3(0, 1.0, 0)
	wall.look_at(wall.global_position + fwd, Vector3.UP)
	await _phys(2)
	var loco: Node = player.call("get_loco")
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var ran := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600:
		await physics_frame
		if str(loco.get("current_clip")) == "run":
			ran = true
	_ok(ran, "sprinting in open space uses the run clip")
	var clips := []
	var ratios := []
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2200:
		await physics_frame
		clips.append(str(loco.get("current_clip")))
		ratios.append(float(player.call("debug_move_ratio")))
	var last := str(clips[clips.size() - 1])
	var mr := float(player.call("debug_move_ratio"))
	_ok(last != "run" and mr < 0.25, "pressed into the wall with Shift held: clip=%s ratio=%.2f" % [last, mr])
	# 平滑：比例不是瞬间跳到 0
	var drop_frames := 0
	for r in ratios:
		if float(r) > 0.2 and float(r) < 0.9:
			drop_frames += 1
	_ok(drop_frames >= 3, "run → walk/idle blends over several frames (%d intermediate)" % drop_frames)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	wall.queue_free()
	await _phys(4)


func _pz() -> Node:
	return main.get("possession")


func _check_possess() -> void:
	var pz := _pz()
	_ok(pz != null, "possession manager exists")
	if pz == null:
		return
	main.call("clear_clones")
	await _frames(2)
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
	await _frames(4)
	var fwd := Basis(Vector3.UP, float(player.get("_yaw"))) * Vector3(0, 0, -1)
	var p0: Vector3 = player.global_position
	main.call("spawn_clone", p0 + Vector3(1.3, 0, -0.5))
	main.call("spawn_clone", p0 + Vector3(0.9, 0, -1.6))
	await _frames(6)
	var cl: Array = main.call("get_clones")
	_ok(cl.size() == 2, "two clones spawned")
	var a: Node = cl[0]
	var b: Node = cl[1]
	_ok(is_equal_approx(float(player.call("get_max_hp")), 1000.0) and is_equal_approx(float(a.call("get_max_hp")), 100.0), "controlled max HP 1000, clone max HP 100")
	# 本体：持枪 + 蹲下 + 腹部有一个刺穿伤口（手术腹网）
	var ws: Node = player.call("get_weapons")
	ws.call("select", "pistol")
	for i in 90:
		await process_frame
		if str(ws.get("state")) == "ready":
			break
	player.call("force_stance", "crouch")
	var p_surg: Node = player.call("get_surgery")
	var org: Node = player.call("get_organs")
	var nav_w: Vector3 = org.call("navel_world") if org.has_method("navel_world") else player.global_position + Vector3(0, 1.0, 0)
	p_surg.call("apply_puncture_hole", nav_w + Vector3(0.03, -0.04, 0.0), -(player.get("_body") as Node3D).global_basis.z, 0.012)
	var holes0 := int(p_surg.get("bullet_holes"))
	_ok(holes0 >= 1, "player body has a wound before possession (holes=%d)" % holes0)
	a.call("apply_damage", 50.0, {})
	var p_body: Node = player.get("_body")
	var a_body: Node = a.get("body")
	# 选中 → 描边
	pz.call("select", a)
	await _frames(2)
	_ok(int(pz.call("outlined_mesh_count")) > 0, "selecting a clone outlines its model (%d meshes)" % int(pz.call("outlined_mesh_count")))
	var line := str(pz.call("clone_line", a))
	_ok(line.find("50/100") >= 0 and line.find("站立") >= 0, "clone list line shows HP and status: %s" % line)
	var a_pos: Vector3 = (a as Node3D).global_position
	var pl_pos: Vector3 = player.global_position
	var msg := str(pz.call("possess", a))
	print("v0407: possess -> ", msg)
	await _frames(2)
	_ok(player.get("_body") == a_body and a.get("body") == p_body, "bodies swapped between player and clone")
	_ok(player.call("get_surgery") != p_surg and a.call("get_surgery") == p_surg and int(p_surg.get("bullet_holes")) == holes0, "left body keeps its wound / surgery state")
	_ok(str(a.get("held_weapon")) == "pistol" and a.get("body").find_child("HeldWeapon", true, false) != null, "left body keeps holding the pistol")
	_ok(not bool(ws.call("is_armed")), "new body starts empty-handed")
	print("v0407: stances a=%s p=%s  pos p=%s a_old=%s  a=%s p_old=%s" % [a.call("get_stance"), player.call("get_stance"), player.global_position, a_pos, (a as Node3D).global_position, pl_pos])
	_ok(str(a.call("get_stance")) == "crouch" and str(player.call("get_stance")) == "stand", "left body stays crouched; new body keeps its stance")
	_ok(absf(float(player.call("get_hp")) - 500.0) < 1.0 and is_equal_approx(float(player.call("get_max_hp")), 1000.0), "controlled HP scaled to 1000 max (%.0f)" % float(player.call("get_hp")))
	_ok(absf(float(a.call("get_hp")) - 100.0) < 1.0 and is_equal_approx(float(a.call("get_max_hp")), 100.0), "old body as clone: %.0f/100" % float(a.call("get_hp")))
	_ok(player.global_position.distance_to(a_pos) < 0.3 and (a as Node3D).global_position.distance_to(pl_pos) < 0.3, "positions swapped")
	_ok(bool(pz.call("is_transitioning")), "camera transition started")
	var cam_a: Camera3D = root.get_viewport().get_camera_3d()
	_ok(cam_a != null and cam_a.name == "PossessCam", "transition camera active")
	var t0 := Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	_ok(not bool(pz.call("is_transitioning")) and root.get_viewport().get_camera_3d() == player.call("get_camera"), "camera transition ends on the new body's view")
	# 头部图层：离开的身体不再被第一人称剔除
	var head_hidden := 0
	for mi in p_body.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).layers == (1 << 18):
			head_hidden += 1
	_ok(head_hidden == 0, "left body has no first-person-only head layers")
	# HUD 清单
	hud.call("_refresh_clone_list", true)
	var rows: Dictionary = hud.get("_clone_rows")
	_ok(rows.size() == 2, "HUD clone list has 2 rows")
	var txt := ""
	for k in rows.keys():
		txt += (rows[k] as Button).text + " | "
	_ok(txt.find("持枪") >= 0 and txt.find("蹲下") >= 0 and txt.find("100/100") >= 0, "HUD rows show HP + status: %s" % txt)
	# 死亡分身：不能附身，可复原
	b.call("apply_damage", 500.0, {})
	await _frames(3)
	pz.call("select", b)
	_ok(not bool(pz.call("can_possess", b)) and str(pz.call("possess", b)).find("复原") >= 0, "dead ragdoll clone cannot be possessed")
	pz.call("restore_selected")
	await _frames(3)
	_ok(not bool(b.call("is_dead")) and bool(pz.call("can_possess", b)), "restore revives the selected clone")
	# 附身回去：拿回枪、蹲姿、伤口
	pz.call("possess", a)
	for i in 90:
		await process_frame
		if not bool(pz.call("is_transitioning")) and str(ws.get("state")) == "ready":
			break
	_ok(player.call("get_surgery") == p_surg and str(ws.get("current")) == "pistol" and str(player.call("get_stance")) == "crouch", "possessing back restores wound, pistol and crouch")
	print("v0407: back a stance=%s held=%s" % [a.call("get_stance"), a.get("held_weapon")])
	_ok(str(a.get("held_weapon")) == "" and str(a.call("get_stance")) == "stand", "the other body is a plain standing clone again")
	ws.call("possession_release")
	player.call("force_stance", "stand")
	# 第一人称瞄准分身 → 附身按钮
	if not bool(player.get("first_person")) and player.has_method("toggle_first_person"):
		player.call("toggle_first_person")
	await _frames(4)
	var target: Node3D = b
	var head: Vector3 = target.call("get_head_world_position")
	var cam: Camera3D = player.call("get_camera")
	var dir: Vector3 = (head - Vector3(0, 0.45, 0)) - cam.global_position
	player.set("_yaw", atan2(-dir.x, -dir.z))
	player.set("_pitch", atan2(dir.y, Vector2(dir.x, dir.z).length()))
	await _frames(6)
	_ok(pz.get("aimed") == b, "first-person crosshair on a clone is detected (fp=%s)" % str(player.get("first_person")))
	_ok(bool(hud.get("debug_possess_aim_visible")), "「附身」 button shows when aiming at a clone")
	var b_body: Node = b.get("body")
	main.call("run_action", "possess_aim")
	await _frames(2)
	_ok(player.get("_body") == b_body, "P / aim button possesses the aimed clone instantly")
	t0 = Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	# 检查床：附身床上的分身 → 上床；再附身回去 → 分身仍躺在床上
	await _bed_possess()
	main.call("clear_clones")
	await _frames(3)


func _bed_possess() -> void:
	var pz := _pz()
	var bed: Node = null
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
	if bed == null:
		_ok(false, "exam bed exists")
		return
	if bool(player.get("first_person")) and player.has_method("toggle_first_person"):
		player.call("toggle_first_person")
	player.global_position = (bed as Node3D).global_position + Vector3(1.2, 0.1, 0.0)
	player.reset_physics_interpolation()
	await _phys(3)
	vs.call("_update_nearest")
	var msg := str(main.call("place_clone_on_bed", bed))
	await _frames(3)
	var bc: Node = null
	for c in main.call("get_clones"):
		if bool(c.call("is_on_exam_bed")):
			bc = c
	_ok(bc != null, "clone placed on the exam bed (%s)" % msg)
	if bc == null:
		return
	var bc_surg: Node = bc.call("get_surgery")
	pz.call("possess", bc)
	await _frames(6)
	_ok(str(player.get("occupancy")) == "exam_bed" and player.call("get_surgery") == bc_surg, "possessing the clone on the bed puts you on the bed in that body")
	var t0 := Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	pz.call("possess", bc)
	await _frames(6)
	_ok(bool(bc.call("is_on_exam_bed")) and bc.call("get_surgery") == bc_surg and str(player.get("occupancy")) == "", "leaving that body keeps it lying on the bed")
	t0 = Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame


func _check_seats() -> void:
	for kind in ["car", "plane"]:
		await _check_seat(kind)


func _check_seat(kind: String) -> void:
	var v: Node = load("res://scenes/vehicles/%s.tscn" % kind).instantiate()
	main.add_child(v)
	var at := Vector3(1.6, 0.6, 0.2) if kind == "car" else Vector3(40.0, 3.0, 40.0)
	v.global_position = at
	if v.has_method("spawn_lift"):
		v.global_position.y = float(v.call("spawn_lift")) if kind == "car" else at.y
	if v is RigidBody3D:
		(v as RigidBody3D).freeze = true
	await _phys(3)
	await _frames(3)
	player.global_position = v.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = v
	_ok(bool(vs.call("try_enter")), "%s: enter" % kind)
	for i in 50:
		await process_frame
	vs.call("_apply_seat_pose")
	var st: Dictionary = vs.call("debug_seat_state")
	print("v0407: seat ", kind, " ", st)
	if st.is_empty():
		_ok(false, "%s: seat state" % kind)
		return
	var trim: Vector3 = (vs.get("SEAT_EYE_TRIM") as Dictionary).get(kind, Vector3.ZERO)
	var eye: Vector3 = st["eye"]
	var ck: Vector3 = st["cockpit"]
	var hip: Vector3 = st["C_Hip_a"]
	var knee: Vector3 = st["L_Foreleg_a"]
	var foot: Vector3 = st["L_Foot_a"]
	_ok(bool(st["visible"]), "%s: driver body visible (not hidden)" % kind)
	var et: Vector3 = st["eye_target"]
	_ok(eye.distance_to(et) < 0.05 and float(st["shift"]) <= 0.5, "%s: head eye at the (reach-adjusted) cockpit view point (err %.3f m, shift %.2f m)" % [kind, eye.distance_to(et), float(st["shift"])])
	_ok(eye.y - hip.y > 0.35 and eye.y - hip.y < 0.95, "%s: seated torso height eye-hip %.2f m" % [kind, eye.y - hip.y])
	_ok(knee.z < hip.z - 0.25 and absf(knee.y - hip.y) < 0.3, "%s: thighs forward (knee %.2f m ahead, dy %.2f)" % [kind, hip.z - knee.z, knee.y - hip.y])
	_ok(foot.y < knee.y - 0.05 and foot.z < hip.z - 0.3, "%s: shins down to the pedals (foot %.2f below knee)" % [kind, knee.y - foot.y])
	var el := (st["L_Hand_a"] as Vector3).distance_to(st["hand_l_target"])
	var er := (st["R_Hand_a"] as Vector3).distance_to(st["hand_r_target"])
	_ok(el < 0.1 and er < 0.1, "%s: hands on the controls (L %.3f, R %.3f m)" % [kind, el, er])
	_ok((st["hand_r_target"] as Vector3).z < hip.z, "%s: controls in front of the seat" % kind)
	var hb: Node = player.get("_hitboxes")
	vs.call("_finish_exit", vs.call("_exit_stand_dest", v), true)
	await _frames(2)
	player.call("force_stance", "stand")  # 前面的附身用例可能留下蹲姿
	await _frames(4)
	await _frames(80)
	var body: Node3D = player.get_node("Body")
	var skel: Skeleton3D = player.call("get_skeleton")
	var li := skel.find_bone("L_UpperLeg_a")
	var rest_q := skel.get_bone_rest(li).basis.get_rotation_quaternion()
	var now_q := skel.get_bone_pose_rotation(li)
	_ok(str(player.get("occupancy")) == "" and body.visible and absf(body.rotation.x) < 0.01 and absf(body.rotation.z) < 0.01, "%s: exit restores upright standing body" % kind)
	_ok(rest_q.angle_to(now_q) < 0.6 or str(player.call("get_loco").get("current_clip")) == "jump", "%s: seated leg pose cleared on exit (%.2f rad, frozen=%s)" % [kind, rest_q.angle_to(now_q), "%s clip=%s stance=%s occ=%s mode=%s" % [str(player.call("get_loco").get("frozen")), str(player.call("get_loco").get("current_clip")), str(player.call("get_stance")), str(player.get("occupancy")), str(player.get("play_mode"))]])
	if hb:
		var en := false
		for b in hb.call("bodies"):
			if b is CollisionObject3D and (b as CollisionObject3D).collision_layer != 0:
				en = true
		_ok(en, "%s: hitboxes re-enabled after exit" % kind)
	v.queue_free()
	await _frames(3)
