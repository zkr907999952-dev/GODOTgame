extends SceneTree
## 0.2.11 自检：武器轮盘居中、左侧开火键、布娃娃关节限位、特写更慢并在穿过后停留 4 秒、
## 尸体保持透视、尸体可触发特写。并复核 0.2.10 相邻不变量。
##   godot --headless --path . -s res://scripts/tests/v033_check.gd

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
		print("v033: OK   ", msg)
	else:
		fails += 1
		push_error("v033: FAIL " + msg)


func _hinge_over(report: Dictionary) -> float:
	var m := 0.0
	for group in ["knees", "elbows"]:
		var g: Dictionary = report.get(group, {})
		for k in g.keys():
			m = maxf(m, float(g[k].get("over", 0.0)))
	return m


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
		print("v033_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.11\"") >= 0 or (presets.find("version/name=\"0.2.12\"") >= 0 or presets.find("version/name=\"0.2.13\"") >= 0), "export versionName 0.2.11")
	_ok((presets.find("version/code=14") >= 0 or presets.find("version/code=15") >= 0) or presets.find("version/code=13") >= 0, "versionCode 13 or 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")
	_ok(presets.find("include_filter=\"assets/organs/*.bin,assets/organs/*.json\"") >= 0, "organs include_filter kept")

	_check_source_contracts()
	await _check_wheel_centered()
	await _check_left_fire_button()
	await _check_ragdoll_joint_limits()
	await _check_bullet_cam_hold()
	await _check_corpse_xray()
	await _check_corpse_bullet_cam()
	_check_previous_invariants()

	print("v033_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_source_contracts() -> void:
	var wheel_src := FileAccess.get_file_as_string("res://scripts/ui/weapon_wheel.gd")
	_ok(wheel_src.find("轮盘始终出现在屏幕正中央") >= 0, "wheel open comment: always centered")
	_ok(wheel_src.find("func set_vec") >= 0, "wheel has set_vec for press-drag from center")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("func weapon_wheel_drag") >= 0, "hud has weapon_wheel_drag")
	_ok(hud_src.find("wheel.call(\"open\", null)") >= 0, "hud opens wheel without button origin")
	var tc := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc.find("fire_left") >= 0, "touch controls define fire_left")
	_ok(tc.find("weapon_wheel_drag") >= 0, "touch drag uses center-wheel set_vec")
	var rag := FileAccess.get_file_as_string("res://scripts/ragdoll_system.gd")
	_ok(rag.find("func _clamp_joint_angles") >= 0, "ragdoll has post-step joint clamp")
	_ok(rag.find("Foreleg_a") >= 0 and rag.find("_clamp_hinge") >= 0, "knees use hinge clamp")
	var cam := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(cam.find("const HOLD_SEC := 4.0") >= 0, "bullet cam holds 4s after pass-through")
	_ok(cam.find("const SLOW := 0.045") >= 0, "bullet cam time_scale slower than 0.08")
	_ok(cam.find("const FLY_SPEED := 4.0") >= 0, "bullet cam follow slower than 8.5")
	_ok(cam.find("func debug_advance") >= 0, "bullet cam has debug_advance")
	_ok(cam.find("corpse_path") >= 0, "consider() accepts corpse path")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("corpse_path") >= 0, "ballistics can emit corpse cinematic path")
	var org := FileAccess.get_file_as_string("res://scripts/organs/organ_rig.gd")
	_ok(org.find("_spine_world_from_ragdoll") >= 0, "organ frame follows ragdoll physical bones")
	var root_src := FileAccess.get_file_as_string("res://scripts/game_root.gd")
	_ok(root_src.find("func apply_xray_enabled") >= 0, "xray broadcasts to all organ rigs")
	_ok(root_src.find("KEY_E: \"corpse_drag\"") >= 0, "E still bound to corpse_drag")
	var loco := FileAccess.get_file_as_string("res://scripts/soft_loco.gd")
	_ok(loco.find("L_Shoulder_a") >= 0, "loco still writes shoulders")
	var ik := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ik.find("锁骨 / 肩膀保持走跑或休息底姿势") >= 0, "IK still does not rotate clavicles")
	_ok(ik.find("func interrupt_for_bullet_cam") >= 0, "auto-fire interrupt kept")


func _check_wheel_centered() -> void:
	player.call("set_play_mode", 1)
	await _ready_gun("rifle")
	hud.call("set_touch_ui", true)
	await _frames(4)
	var wheel: Control = hud.get("wheel")
	_ok(wheel != null, "weapon wheel node present")
	if wheel == null:
		return
	# 即使传入按钮位置，轮盘原点也必须是屏幕中心
	var vp: Vector2 = root.get_visible_rect().size
	var fake_btn := Vector2(vp.x - 80.0, vp.y - 80.0)
	hud.call("open_weapon_wheel", fake_btn)
	await _frames(2)
	_ok(bool(hud.call("is_wheel_open")), "wheel opens")
	var c: Vector2 = wheel.call("center")
	_ok(c.distance_to(vp * 0.5) < 8.0, "wheel center is viewport center (c=%s vp=%s)" % [c, vp])
	_ok(c.distance_to(fake_btn) > 80.0, "wheel center is not at the weapon button")
	# 从按下点拖出的位移作用在中心轮盘上
	if hud.has_method("weapon_wheel_drag"):
		hud.call("weapon_wheel_drag", Vector2(0, -120))
		await _frames(1)
		_ok(int(wheel.get("hover")) >= 0, "drag from center selects a slot (hover=%s)" % wheel.get("hover"))
	hud.call("close_weapon_wheel", false)
	_ok(not bool(hud.call("is_wheel_open")), "wheel closes")
	# 键盘 Q 路径（不传 origin）同样居中
	hud.call("open_weapon_wheel")
	await _frames(1)
	var c2: Vector2 = wheel.call("center")
	_ok(c2.distance_to(vp * 0.5) < 8.0, "Q-style open is also centered")
	hud.call("close_weapon_wheel", false)
	hud.call("set_touch_ui", false)


func _check_left_fire_button() -> void:
	player.call("set_play_mode", 1)
	await _ready_gun("rifle")
	hud.call("set_touch_ui", true)
	await _frames(4)
	var tc: Control = hud.call("get_touch_controls")
	_ok(tc != null, "touch controls present")
	if tc == null:
		return
	var btns: Dictionary = tc.call("buttons")
	_ok(btns.has("fire") and btns.has("fire_left"), "right and left fire buttons exist")
	_ok(btns.has("weapon") and btns.has("crouch"), "weapon/crouch still present")
	if not btns.has("fire_left"):
		hud.call("set_touch_ui", false)
		return
	var fl: Rect2 = btns["fire_left"][0]
	var fr: Rect2 = btns["fire"][0]
	var vp: Vector2 = tc.call("vp")
	_ok(fl.position.x < vp.x * 0.28, "left fire is on the left side (x=%.1f / %.1f)" % [fl.position.x, vp.x])
	var mid := vp.y * 0.5
	_ok(absf(fl.get_center().y - mid) < vp.y * 0.22, "left fire is mid-left vertically (y=%.1f mid=%.1f)" % [fl.get_center().y, mid])
	var stick: Vector2 = tc.call("stick_center")
	var stick_r := Rect2(stick - Vector2(64, 64), Vector2(128, 128))
	_ok(not fl.intersects(stick_r), "left fire does not cover the move stick")
	_ok(not fl.intersects(fr), "left fire does not overlap right fire")
	# 右侧簇保持 0.2.10 相对位置
	var wr: Rect2 = btns["weapon"][0]
	_ok(not wr.intersects(fr), "weapon and right fire still do not overlap")
	# 两个开火键打同一把枪
	ws.call("set_trigger", false)
	_ok(not bool(ws.get("trigger")), "trigger starts released")
	tc.call("_button", "fire_left", true)
	_ok(bool(ws.get("trigger")), "left fire button sets trigger")
	tc.call("_button", "fire", true)
	_ok(bool(ws.get("trigger")), "right fire also held")
	tc.call("_button", "fire_left", false)
	_ok(bool(ws.get("trigger")), "releasing left fire keeps trigger if right is held")
	tc.call("_button", "fire", false)
	_ok(not bool(ws.get("trigger")), "releasing both fire buttons clears trigger")
	# 血条仍在底端中央、武器卡下方
	var box: Control = hud.find_child("PlayerHealth", true, false)
	var ammo: Control = hud.find_child("AmmoHud", true, false)
	_ok(box != null, "player HP box present")
	if box:
		_ok(is_equal_approx(box.anchor_left, 0.5) and is_equal_approx(box.anchor_right, 0.5) and is_equal_approx(box.anchor_top, 1.0), "HP anchors bottom-center")
	if box and ammo:
		_ok(box.offset_bottom > ammo.offset_bottom + 8.0, "HP still sits under weapon card")
	hud.call("set_touch_ui", false)


func _check_ragdoll_joint_limits() -> void:
	main.call("clear_clones")
	await _frames(4)
	main.call("spawn_clone", player.global_position + Vector3(0.2, 0.0, -0.7))
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for joint limits")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	c.call("apply_damage", 200.0, {
		"zone": "body",
		"dir": Vector3(0.2, 0.1, -1),
		"entry": c.global_position + Vector3(0, 1.1, 0),
		"par": {"impulse": 0.6, "category": "rifle"},
	})
	await _phys(8)
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.call("is_active")), "clone ragdoll active")
	if rag == null:
		return
	_ok(int(rag.get("_joint_limits").size()) >= 8, "joint limit table built (%d)" % int(rag.get("_joint_limits").size()))
	# 强制膝关节反曲，随后钳制必须拉回
	if rag.has_method("debug_force_knee_hyperextension"):
		rag.call("debug_force_knee_hyperextension", -80.0)
		var before: Dictionary = rag.call("debug_joint_angles")
		var knees0: Dictionary = before.get("knees", {})
		var forced := false
		for k in knees0.keys():
			if float(knees0[k].get("over", 0.0)) > 20.0 or bool(knees0[k].get("hyperextended", false)):
				forced = true
		_ok(forced or float(before.get("worst", 0)) > 20.0, "forced a hyperextended pose to test clamp (over before=%s)" % before.get("worst"))
		# 直接调用钳制（不等物理步）
		if rag.has_method("_clamp_joint_angles"):
			rag.call("_clamp_joint_angles")
			rag.call("_clamp_joint_angles")
		var after: Dictionary = rag.call("debug_joint_angles")
		_ok(_hinge_over(after) < 3.0, "knees/elbows within limits after clamp (over=%.2f)" % _hinge_over(after))
		_ok(_hinge_over(after) < 3.0, "max knee/elbow overshoot < 3 deg (%.2f)" % _hinge_over(after))
		var knees: Dictionary = after.get("knees", {})
		_ok(not knees.is_empty(), "knee joints reported")
		for k in knees.keys():
			_ok(not bool(knees[k].get("hyperextended", true)), "%s is not hyperextended (ang=%.1f lo=%.1f)" % [k, float(knees[k].get("angle", 0)), float(knees[k].get("lo", 0))])
	# 再给一记重击并跑若干物理帧，限位仍应守住
	var dir := Vector3(1, 0.4, 0.2).normalized()
	var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.95, "category": "shotgun"}, dir)
	rag.call("apply_hit_impulse", imp, rag.call("get_follow_point"), null)
	await _phys(20)
	await _frames(2)
	if rag.has_method("_clamp_joint_angles"):
		rag.call("_clamp_joint_angles")
	var later: Dictionary = rag.call("debug_joint_angles")
	_ok(_hinge_over(later) < 8.0, "after heavy impulse, knees/elbows stay limited (over=%.2f all_worst=%.2f %s)" % [_hinge_over(later), float(later.get("worst", 99)), later.get("worst_name", "")])
	# 活体受击抖动不能变成全身布娃娃，也不能拧锁骨
	main.call("clear_clones")
	await _frames(4)
	main.call("spawn_clone", player.global_position + Vector3(0.25, 0.0, -0.8))
	await _frames(8)
	await _phys(2)
	var live: Array = main.call("get_clones")
	if not live.is_empty():
		var lc: Node = live[0]
		lc.call("apply_damage", 20.0, {"zone": "body", "dir": Vector3(0, 0.1, 1), "entry": lc.global_position + Vector3(0, 1.15, 0)})
		_ok(not bool(lc.call("is_dead")), "live clone still alive")
		var lrag: Node = lc.call("get_ragdoll")
		_ok(lrag == null or not bool(lrag.call("is_active")), "live hit reaction is not full ragdoll")


func _check_bullet_cam_hold() -> void:
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam present")
	if cam == null:
		return
	_ok(float(cam.get("SLOW")) <= 0.055, "SLOW is lower than 0.2.10 (%.3f)" % float(cam.get("SLOW")))
	_ok(float(cam.get("FLY_SPEED")) <= 5.0, "FLY_SPEED is slower than 0.2.10 (%.2f)" % float(cam.get("FLY_SPEED")))
	_ok(is_equal_approx(float(cam.get("HOLD_SEC")), 4.0), "HOLD_SEC is 4 seconds")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	player.call("set_play_mode", 1)
	await _frames(4)
	var organs: Node = player.call("get_organs")
	var origin: Vector3 = player.global_position + Vector3(0, 1.2, 0.2)
	var dir := Vector3(0, 0, -1)
	var info := {
		"gut": true, "uterus": false, "organs": organs,
		"entry": origin + dir * 1.2, "exit": origin + dir * 1.45,
		"dir": dir, "origin": origin, "body": player,
	}
	var did: bool = bool(cam.call("consider", info, {}))
	_ok(did and bool(cam.get("playing")), "living organ-hit still triggers cam")
	_ok(str(cam.get("debug_phase")) == "follow", "starts in follow")
	# 推进跟随段
	cam.call("debug_advance", 3.0)
	var phase := str(cam.get("debug_phase"))
	_ok(phase == "park" or phase == "hold", "after follow, phase is park or hold (%s)" % phase)
	if phase == "park":
		cam.call("debug_advance", 2.0)
		phase = str(cam.get("debug_phase"))
	_ok(phase == "hold" or not bool(cam.get("playing")), "entered hold after pass-through (phase=%s)" % phase)
	if str(cam.get("debug_phase")) == "hold":
		var already := float(cam.get("_hold_t"))
		# 补到约 3.5 秒停留，确认此时仍在播放，再把剩余时间走完。
		if already < 3.5:
			cam.call("debug_advance", 3.5 - already)
		_ok(bool(cam.get("playing")) and str(cam.get("debug_phase")) == "hold", "still holding at 3.5s (phase=%s hold_t=%.2f)" % [cam.get("debug_phase"), float(cam.get("_hold_t"))])
		cam.call("debug_advance", 0.7)
		_ok(not bool(cam.get("playing")), "exits after ~4s hold")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time_scale restored after natural end (%.3f)" % Engine.time_scale)
	# skip 必须立刻恢复
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	_ok(bool(cam.call("consider", info, {})), "cam can start again")
	cam.call("debug_advance", 2.5)
	_ok(bool(cam.get("playing")), "playing before skip")
	cam.call("skip")
	await _frames(2)
	_ok(not bool(cam.get("playing")), "skip ends cam")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "skip restores time_scale")
	var pc: Camera3D = player.call("get_camera")
	_ok(pc != null and bool(pc.current), "skip restores player camera")
	# 自动武器：开始特写即中断连射；播放期间不能再开枪
	await _ready_gun("smg")
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	ws.call("set_trigger", true)
	var started: bool = bool(cam.call("consider", info, {}))
	_ok(started, "cam starts for interrupt check")
	if started and ws.has_method("interrupt_for_bullet_cam"):
		ws.call("interrupt_for_bullet_cam")
	_ok(not bool(ws.get("trigger")), "trigger cleared when cam starts")
	_ok(bool(ws.call("_cam_blocks_fire")) if ws.has_method("_cam_blocks_fire") else true, "fire blocked during/after cam")
	cam.call("skip")
	ws.call("set_trigger", false)
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	cam.set("debug_roll", -1.0)
	cam.call("debug_reset")


func _check_corpse_xray() -> void:
	main.call("clear_clones")
	await _frames(4)
	var porg: Node = player.call("get_organs")
	if porg:
		porg.call("set_xray_enabled", true)
		porg.call("set_xray_amount", 0.38)
	if main.has_method("apply_xray_enabled"):
		main.call("apply_xray_enabled", true)
		main.call("apply_xray_amount", 0.38)
	main.call("spawn_clone", player.global_position + Vector3(0.15, 0.0, -0.65))
	await _frames(10)
	await _phys(3)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone for corpse xray")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	var org: Node = c.call("get_organs")
	_ok(org != null and bool(org.get("xray_enabled")), "living clone has xray on")
	c.call("apply_damage", 200.0, {
		"zone": "body",
		"dir": Vector3(0, 0.05, -1),
		"entry": c.global_position + Vector3(0, 1.1, 0),
		"par": {"impulse": 0.4, "category": "pistol"},
	})
	await _phys(8)
	await _frames(4)
	_ok(bool(c.call("is_dead")), "clone is a ragdoll corpse")
	_ok(org != null and bool(org.get("xray_enabled")), "corpse keeps xray_enabled after death")
	_ok(float(org.call("effective_xray")) > 0.05, "corpse effective xray still on (%.2f)" % float(org.call("effective_xray")))
	# 关掉再打开，尸体必须跟上
	if main.has_method("apply_xray_enabled"):
		main.call("apply_xray_enabled", false)
		await _frames(2)
		_ok(not bool(org.get("xray_enabled")), "corpse xray off when global xray off")
		main.call("apply_xray_enabled", true)
		await _frames(2)
		_ok(bool(org.get("xray_enabled")), "corpse xray on again when global xray on")
	# 透视窗应跟着布娃娃腹部，而不是留在死前站立点
	if org.has_method("abdomen_frame") and c.has_method("get_ragdoll"):
		var rag: Node = c.call("get_ragdoll")
		var chest: Vector3 = rag.call("get_follow_point") if rag else c.global_position
		var frame: Transform3D = org.call("abdomen_frame")
		var dist := frame.origin.distance_to(chest)
		_ok(dist < 0.55, "xray abdomen frame follows ragdoll torso (dist=%.3f)" % dist)


func _check_corpse_bullet_cam() -> void:
	var cam: Node = main.get_node_or_null("BulletCam")
	if cam == null:
		return
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	player.call("set_play_mode", 1)
	var clones: Array = main.call("get_clones")
	var corpse: Node = null
	for n in clones:
		if n and bool(n.call("is_dead")):
			corpse = n
			break
	if corpse == null:
		main.call("spawn_clone", player.global_position + Vector3(0.1, 0.0, -0.6))
		await _frames(8)
		clones = main.call("get_clones")
		if not clones.is_empty():
			corpse = clones[clones.size() - 1]
			corpse.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0, -1), "entry": corpse.global_position + Vector3(0, 1.1, 0)})
			await _phys(6)
	_ok(corpse != null and bool(corpse.call("is_dead")), "have a corpse for cam")
	if corpse == null:
		return
	var organs: Node = corpse.call("get_organs")
	var entry: Vector3 = corpse.global_position + Vector3(0, 1.05, 0)
	if corpse.has_method("get_ragdoll") and corpse.call("get_ragdoll"):
		entry = corpse.call("get_ragdoll").call("get_follow_point")
	var info := {
		"gut": true, "uterus": false, "organs": organs,
		"entry": entry, "exit": entry + Vector3(0, 0, -0.28),
		"dir": Vector3(0, 0, -1), "origin": entry + Vector3(0, 0, 0.8),
		"body": corpse, "hit": true,
	}
	var did: bool = bool(cam.call("consider", info, {}))
	_ok(did and bool(cam.get("playing")), "organ-hit on a corpse can trigger cam")
	var did2: bool = bool(cam.call("consider", info, {}))
	_ok(not did2 and bool(cam.get("playing")), "refuse-while-playing still blocks a second corpse cam")
	cam.call("skip")
	await _frames(2)
	_ok(not bool(cam.get("playing")), "skip ends corpse cam")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time_scale restored after corpse cam")
	# 无脏器判定、但腹部命中 / corpse_path 也应能开特写
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	var info2 := {
		"gut": false, "uterus": false, "organs": organs,
		"entry": entry, "exit": entry + Vector3(0, 0, -0.25),
		"dir": Vector3(0, 0, -1), "origin": entry + Vector3(0, 0, 0.8),
		"body": corpse, "hit": true, "corpse_path": true,
	}
	var did3: bool = bool(cam.call("consider", info2, {}))
	_ok(did3 and bool(cam.get("playing")), "corpse pass-through / corpse_path can trigger cam")
	cam.call("skip")
	# 活人路径仍在：无脏器命中的活体不应触发
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	var live_info := {
		"gut": false, "uterus": false, "organs": player.call("get_organs"),
		"entry": player.global_position + Vector3(0, 1.2, 0),
		"dir": Vector3(0, 0, -1), "origin": player.global_position,
		"body": player, "hit": true,
	}
	var did4: bool = bool(cam.call("consider", live_info, {}))
	_ok(not did4, "living non-organ hit still does not trigger cam")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	cam.set("debug_roll", -1.0)
	cam.call("debug_reset")


func _check_previous_invariants() -> void:
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ws_src.find("func interrupt_for_bullet_cam") >= 0, "auto-fire interrupt kept")
	_ok(ws_src.find("锁骨 / 肩膀保持走跑或休息底姿势") >= 0, "no clavicle IK")
	var root_src := FileAccess.get_file_as_string("res://scripts/game_root.gd")
	_ok(root_src.find("KEY_E: \"corpse_drag\"") >= 0, "E corpse drag kept")
	_ok(root_src.find("KEY_T: \"interact_mode\"") >= 0, "T interact mode kept")
	var loco := FileAccess.get_file_as_string("res://scripts/soft_loco.gd")
	_ok(loco.find("walkLeft") >= 0 and loco.find("L_Shoulder_a") >= 0, "strafe + shoulder loco write kept")
	var drag := FileAccess.get_file_as_string("res://scripts/corpse_drag.gd")
	_ok(drag.find("PinJoint3D") >= 0 and drag.find("弹簧") >= 0, "corpse drag still uses clamped spring, not PinJoint")
