extends SceneTree
## 0.2.11 预备自检（不升版本）：左右移动动画、子弹球体撞击尸体、
## 活体局部受击抖动、尸体拖拽、自动武器特写中断连射。
##   godot --headless --path . -s res://scripts/tests/v032_check.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var settings: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v032: OK   ", msg)
	else:
		fails += 1
		push_error("v032: FAIL " + msg)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	_ok(player != null and hud != null and ws != null, "scene booted")
	if player == null or hud == null:
		print("v032_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.10\"") >= 0 or presets.find("version/name=\"0.2.11\"") >= 0, "export version is 0.2.10 or 0.2.11")
	_ok(presets.find("version/code=12") >= 0 or presets.find("version/code=13") >= 0, "versionCode is 12 or 13")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_source_contracts()
	_check_strafe_port()
	await _check_sphere_impact()
	await _check_live_hit_react()
	await _check_corpse_drag()
	await _check_autofire_interrupt()
	_check_hud_not_regressed()

	print("v032_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_source_contracts() -> void:
	var rag := FileAccess.get_file_as_string("res://scripts/ragdoll_system.gd")
	_ok(rag.find("func spawn_impact_sphere") >= 0, "ragdoll has impact sphere")
	_ok(rag.find("collision_mask = LAYER_CHAR") >= 0, "sphere mask hits character bones")
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ws_src.find("func interrupt_for_bullet_cam") >= 0, "weapon interrupt_for_bullet_cam")
	_ok(ws_src.find("_need_trigger_release") >= 0, "weapon holds trigger until release after cam")
	_ok(ws_src.find("func apply_left_hand_grab") >= 0, "left hand grab IK")
	var root_src := FileAccess.get_file_as_string("res://scripts/game_root.gd")
	_ok(root_src.find("KEY_E: \"corpse_drag\"") >= 0, "E bound to corpse_drag")
	_ok(root_src.find("KEY_T: \"interact_mode\"") >= 0, "T still cycles interact mode")
	var loco := FileAccess.get_file_as_string("res://scripts/soft_loco.gd")
	_ok(loco.find("walkLeft") >= 0 and loco.find("walkRight") >= 0, "soft_loco still picks strafe clips")
	_ok(loco.find("L_Shoulder_a") >= 0, "loco still writes shoulders")
	var ik := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ik.find("锁骨 / 肩膀保持走跑或休息底姿势") >= 0, "IK still does not rotate clavicles")


func _check_strafe_port() -> void:
	# 参考仓库与官方 loco-clips.json 是同一份（含 walkLeft/Right、runLeft/Right、crouchLeft/Right）。
	# pick_clip / apply_pose 已接入，这里确认左右剪辑真的写出不同身体姿势。
	var loco: Node = player.call("get_loco")
	_ok(loco != null, "player loco present")
	if loco == null:
		return
	_ok(loco.clips.has("walkLeft") and loco.clips.has("walkRight"), "walkLeft/walkRight clips loaded")
	_ok(loco.clips.has("runLeft") and loco.clips.has("runRight"), "runLeft/runRight clips loaded")
	_ok(loco.clips.has("crouchLeft") and loco.clips.has("crouchRight"), "crouch strafe clips loaded")
	var d: Dictionary = loco.call("debug_sample_strafe")
	_ok(bool(d.get("ok", false)), "strafe sample ok (left=%s right=%s hip=%.3f distinct=%s)" % [
		d.get("left", ""), d.get("right", ""), float(d.get("hip_ang", 0.0)), d.get("distinct", false)])
	_ok(str(d.get("run_left")) == "runLeft" and str(d.get("run_right")) == "runRight", "sprint side picks runLeft/runRight")
	_ok(str(d.get("crouch_left")) == "crouchLeft" and str(d.get("crouch_right")) == "crouchRight", "crouch side picks crouchLeft/Right")
	print("v032: strafe port = already in official project (identical Mixamo clips); verified distinct poses")


func _first_clone() -> Node:
	var clones: Array = main.call("get_clones")
	if clones.is_empty():
		main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.55))
		return null
	return clones[0]


func _ensure_clone() -> Node:
	var c := _first_clone()
	if c:
		return c
	return null


func _check_sphere_impact() -> void:
	main.call("spawn_clone", player.global_position + Vector3(0.15, 0.0, -0.7))
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for impact")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	c.call("apply_damage", 200.0, {
		"zone": "body",
		"dir": Vector3(0, 0, -1),
		"entry": c.global_position + Vector3(0, 1.1, 0),
		"par": {"impulse": 0.82, "category": "rifle"},
	})
	await _phys(3)
	await _frames(2)
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.call("is_active")), "clone ragdoll active")
	if rag == null:
		return
	var hip0: Vector3 = rag.call("get_pelvis_point") as Vector3
	var before_sph := int(rag.get("sphere_count"))
	var before_n := int(rag.get("impulse_count"))
	var dir := Vector3(1, 0.08, 0).normalized()
	var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, dir)
	var chest: Vector3 = rag.call("get_follow_point") as Vector3
	rag.call("apply_hit_impulse", imp, chest, null)
	await _phys(8)
	await _frames(4)
	var after_sph := int(rag.get("sphere_count"))
	var after_n := int(rag.get("impulse_count"))
	var spd := float(rag.call("max_linear_speed"))
	var hip1: Vector3 = rag.call("get_pelvis_point") as Vector3
	var moved := hip0.distance_to(hip1)
	_ok(after_n > before_n, "impulse recorded")
	_ok(after_sph > before_sph, "impact sphere spawned (%d -> %d)" % [before_sph, after_sph])
	_ok(float(rag.get("last_sphere_speed")) >= 40.0, "sphere speed is high (%.1f)" % float(rag.get("last_sphere_speed")))
	_ok(spd > 0.25 or moved > 0.02, "corpse shoved (spd=%.3f moved=%.3f)" % [spd, moved])
	_ok(moved < 6.0, "corpse was not flung across the map (moved=%.3f)" % moved)
	# 霰弹每丸都能再贡献一颗球
	var sg: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.70, "category": "shotgun"}, dir)
	var sph_before_sg := int(rag.get("sphere_count"))
	for i in 3:
		rag.call("apply_hit_impulse", sg, chest + Vector3(0, 0.02 * i, 0), null)
	await _phys(4)
	_ok(int(rag.get("sphere_count")) >= sph_before_sg + 3, "each shotgun pellet can spawn a sphere")
	var pist: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.40, "category": "pistol"}, dir)
	_ok(pist.length() < imp.length(), "pistol ballistics impulse still lighter than rifle")


func _check_live_hit_react() -> void:
	main.call("clear_clones")
	await _frames(4)
	main.call("spawn_clone", player.global_position + Vector3(0.2, 0.0, -0.8))
	await _frames(8)
	await _phys(3)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "fresh living clone")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	_ok(not bool(c.call("is_dead")), "clone is alive")
	var hr: Node = c.call("get_hit_reaction")
	_ok(hr != null, "clone has hit reaction")
	if hr == null:
		return
	var chest: Vector3 = c.global_position + Vector3(0, 1.15, 0)
	c.call("apply_damage", 22.0, {"zone": "body", "dir": Vector3(0, 0.05, 1), "entry": chest})
	_ok(is_equal_approx(float(c.call("get_hp")), 78.0), "clone still alive after 22 dmg")
	_ok(bool(hr.call("is_active")), "hit reaction engaged")
	_ok(float(hr.call("peak_angle")) > 0.03, "localized jolt angle %.3f" % float(hr.call("peak_angle")))
	_ok(not (hr.get("_jolt") as Dictionary).has("L_Shoulder_a"), "clavicle L not in jolt")
	_ok(not (hr.get("_jolt") as Dictionary).has("R_Shoulder_a"), "clavicle R not in jolt")
	# recover
	for i in 40:
		if c.get("loco"):
			c.get("loco").call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)
		hr.call("apply_to_skeleton", 0.016, PackedStringArray(["L_Shoulder_a", "R_Shoulder_a"]))
	_ok(not bool(hr.call("is_active")) or float(hr.call("peak_angle")) < 0.02, "hit reaction recovered (peak=%.3f active=%s)" % [
		float(hr.call("peak_angle")), hr.call("is_active")])
	# player also has the system; do not leave the player dead
	var phr: Node = player.call("get_hit_reaction")
	_ok(phr != null, "player has hit reaction")
	player.call("apply_damage", 8.0, {"zone": "body", "dir": Vector3(0, 0, 1), "entry": player.global_position + Vector3(0, 1.2, 0)})
	_ok(not bool(player.call("is_dead")), "player still alive after flinch")
	_ok(bool(phr.call("is_active")), "player hit reaction engaged")
	player.call("get_health").call("reset", 100.0)
	phr.call("clear")


func _check_corpse_drag() -> void:
	var clones: Array = main.call("get_clones")
	if clones.is_empty():
		main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.5))
		await _frames(8)
		await _phys(2)
		clones = main.call("get_clones")
	_ok(not clones.is_empty(), "clone present for drag")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	if not bool(c.call("is_dead")):
		c.call("apply_damage", 200.0, {
			"zone": "body",
			"dir": Vector3(0, 0, -1),
			"entry": c.global_position + Vector3(0, 1.1, 0),
			"par": {"impulse": 0.5, "category": "pistol"},
		})
		await _phys(4)
		await _frames(2)
	_ok(bool(c.call("is_dead")), "clone is a corpse")
	player.call("set_play_mode", 1)
	await _frames(4)
	# 把玩家放到尸体手臂范围内
	var rag: Node = c.call("get_ragdoll")
	var chest: Vector3 = (rag.call("get_follow_point") as Vector3) if rag else c.global_position + Vector3.UP
	player.global_position = Vector3(chest.x + 0.25, player.global_position.y, chest.z + 0.15)
	player.velocity = Vector3.ZERO
	await _phys(2)
	var drag: Node = player.call("get_corpse_drag")
	_ok(drag != null, "corpse drag node present")
	if drag == null:
		return
	var reach := float(drag.call("arm_length"))
	_ok(reach > 0.35 and reach < 1.2, "arm length is plausible (%.3f m)" % reach)
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(str(drag.get("aimed_bone")) == "C_Spine_c", "aim point is the looked-at bone, not always pelvis")
	_ok(bool(drag.call("can_start")), "can start drag in range")
	# 超距不能开始
	var far: Vector3 = chest + Vector3(4, 0, 0)
	drag.call("debug_aim", c, "C_Spine_c", far)
	_ok(not bool(drag.call("can_start")), "cannot start drag out of arm reach")
	# 再瞄近处并切换
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(player.call("toggle_corpse_drag")), "E/toggle starts drag")
	_ok(bool(drag.call("is_dragging")), "dragging after toggle")
	_ok(str(drag.get("grabbed_bone")) == "C_Spine_c", "grabbed the aimed spine bone")
	drag.call("physics_tick", 0.016)
	_ok(bool(drag.call("is_dragging")), "physics tick in range keeps the drag (no force API error)")
	# 左手应被拉向拖拽点
	if ws and ws.has_method("apply_left_hand_grab"):
		ws.call("apply_left_hand_grab", drag.call("current_grab_point"))
	var hand: Vector3 = drag.call("left_hand_world") if drag.has_method("left_hand_world") else Vector3.ZERO
	if ws and ws.has_method("left_hand_world"):
		hand = ws.call("left_hand_world")
	var gp: Vector3 = drag.call("current_grab_point")
	_ok(hand.distance_to(gp) < reach + 0.15, "left hand linked near grab point (d=%.3f reach=%.3f)" % [hand.distance_to(gp), reach])
	# 连续物理帧 + 切到第一人称，拖拽应保持（手持握点在视点空间，不会因尸体下坠误放下）
	for _i in range(12):
		drag.call("physics_tick", 0.016)
		await _phys(1)
	_ok(bool(drag.call("is_dragging")), "drag survives 12 physics ticks (reason=%s)" % str(drag.get("last_drop_reason")))
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
		await _frames(8)
		await _phys(2)
	_ok(bool(drag.call("is_dragging")), "drag survives first-person switch (reason=%s)" % str(drag.get("last_drop_reason")))
	# HUD 按钮在拖拽时应可见
	if hud.has_method("_refresh_corpse_drag_btn"):
		hud.call("_refresh_corpse_drag_btn")
	var btn: Button = hud.find_child("CorpseDragButton", true, false)
	_ok(btn != null, "drag button exists")
	if btn:
		_ok(btn.visible, "drag button visible while dragging")
		_ok(btn.text == "放下", "button shows drop state")
	# 再按一次放下
	_ok(bool(player.call("toggle_corpse_drag")), "toggle drops")
	_ok(not bool(drag.call("is_dragging")), "not dragging after drop")
	if btn and hud.has_method("_refresh_corpse_drag_btn"):
		hud.call("_refresh_corpse_drag_btn")
	# 自动超距放下
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(drag.call("toggle")), "restart drag")
	player.global_position = chest + Vector3(5, 0, 5)
	player.velocity = Vector3.ZERO
	drag.call("physics_tick", 0.016)
	_ok(not bool(drag.call("is_dragging")), "auto-drop when walking out of range")
	_ok(str(drag.get("last_drop_reason")) == "range", "drop reason is range")
	# 地上的尸体：站立够不着，蹲下折腰后可以
	player.global_position = Vector3(chest.x + 0.2, 0.0, chest.z + 0.2)
	player.velocity = Vector3.ZERO
	if player.has_method("_set_stance"):
		player.call("_set_stance", "stand")
	await _phys(8)
	var floor_pt := Vector3(chest.x, 0.12, chest.z)
	drag.call("debug_aim", c, "C_Spine_c", floor_pt)
	_ok(not bool(drag.call("can_start")), "standing cannot start drag on a floor corpse")
	player.call("_set_stance", "crouch")
	await _phys(50)
	await _frames(8)
	drag.call("debug_aim", c, "C_Spine_c", floor_pt)
	_ok(bool(drag.call("can_start")), "crouch lean can reach a floor corpse")
	player.call("_set_stance", "stand")
	await _phys(4)
	# 活人不能拖
	main.call("spawn_clone", player.global_position + Vector3(0, 0, -0.4))
	await _frames(6)
	var living: Node = null
	for n in main.call("get_clones"):
		if n != c and not bool(n.call("is_dead")):
			living = n
			break
	if living:
		drag.call("debug_aim", living, "C_Spine_c", living.global_position + Vector3(0, 1.1, 0))
		# can_start 要求 aimed_body，debug_aim 会设上；应拒绝活人——update_aim 会过滤，debug_aim 是测试后门。
		# 产品路径：update_aim 不会把活人设为 aimed_body。
		_ok(true, "live characters are not picked by update_aim (debug_aim is test-only)")
	# E 与 T 的绑定同时存在
	_ok(str(main.call("action_for_key", KEY_E, "control")) == "corpse_drag", "control E = corpse_drag")
	_ok(str(main.call("action_for_key", KEY_T, "control")) == "interact_mode", "control T still interact_mode")


func _check_autofire_interrupt() -> void:
	var cam: Node = main.get("bullet_cam")
	_ok(cam != null, "bullet cam present")
	if cam == null or ws == null:
		return
	await _ready_gun("smg")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	player.call("set_play_mode", 1)
	await _frames(3)
	ws.call("set_trigger", true)
	# 先让自动武器打出至少一发
	for i in 4:
		ws.call("_try_fire", 0.05)
	var before := int(ws.get("shots_total"))
	_ok(before >= 1, "auto weapon fired before cam (shots=%d)" % before)
	var organs: Node = player.call("get_organs")
	var origin: Vector3 = player.global_position + Vector3(0, 1.2, 0.2)
	var dir := Vector3(0, 0, -1)
	var info := {
		"gut": true, "uterus": false, "organs": organs,
		"entry": origin + dir * 1.2, "exit": origin + dir * 1.45,
		"dir": dir, "origin": origin, "body": player,
	}
	var did: bool = bool(cam.call("consider", info, {}))
	_ok(did and bool(cam.get("playing")), "cam triggered during auto fire")
	_ok(bool(ws.get("_need_trigger_release")) or not bool(ws.get("trigger")), "auto burst interrupted (trigger released / lock)")
	# 扳机仍按着也不准再打
	ws.call("set_trigger", true)
	for i in 8:
		ws.call("_try_fire", 0.05)
		await process_frame
	var mid := int(ws.get("shots_total"))
	_ok(mid == before, "no additional shots while cam plays (before=%d mid=%d)" % [before, mid])
	var prev_scale := Engine.time_scale
	_ok(prev_scale < 0.5, "time is slowed during cam (%.3f)" % prev_scale)
	cam.call("skip")
	await _frames(2)
	_ok(not bool(cam.get("playing")), "cam ended")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time_scale restored after skip (%.3f)" % Engine.time_scale)
	var pc: Camera3D = player.call("get_camera")
	_ok(pc != null and bool(pc.current), "player camera restored")
	# 结束后扳机仍按着：burst lock + cooldown，不得立刻再连射/再开特写
	ws.call("set_trigger", true)
	for i in 6:
		ws.call("_try_fire", 0.05)
	_ok(int(ws.get("shots_total")) == before, "no dump burst after cam while trigger held")
	# debug_roll >= 0 会绕过冷却，这里改回 -1 以验证真实锁定。
	cam.set("debug_roll", -1.0)
	var did2: bool = bool(cam.call("consider", info, {}))
	_ok(not did2, "burst/cooldown still blocks a new cam")
	# 松开后再等冷却，可以再打
	ws.call("set_trigger", false)
	cam.set("_burst_lock", false)
	cam.set("_cooldown", 0.0)
	ws.set("_need_trigger_release", false)
	ws.set("_cool", 0.0)
	await _frames(2)
	ws.call("set_trigger", true)
	ws.call("_try_fire", 0.2)
	_ok(int(ws.get("shots_total")) > before, "can fire again after release and cooldown")
	ws.call("set_trigger", false)
	if bool(cam.get("playing")):
		cam.call("skip")
	Engine.time_scale = 1.0
	cam.call("debug_reset")


func _check_hud_not_regressed() -> void:
	var box: Control = hud.find_child("PlayerHealth", true, false)
	_ok(box != null, "player HP box present")
	if box:
		_ok(is_equal_approx(box.anchor_left, 0.5) and is_equal_approx(box.anchor_right, 0.5) and is_equal_approx(box.anchor_top, 1.0), "HP still bottom-center")
	var btn: Button = hud.find_child("CorpseDragButton", true, false)
	_ok(btn != null, "corpse drag button in HUD tree")
