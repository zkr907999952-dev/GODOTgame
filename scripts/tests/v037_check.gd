extends SceneTree
## 0.2.13 自检（源码，不升版本号）：观察模式可触发特写、霰弹多弹头同飞、
## 收枪轮盘判定圈加大、准星逻辑、右键按住拖拽、电脑按住/手机切换瞄准、
## 踩踏不把角色弹飞、武器无需换弹、低头弯腰跟枪、捂腹重做。
##   godot --headless --path . -s res://scripts/tests/v037_check.gd

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
		print("v037: OK   ", msg)
	else:
		fails += 1
		push_error("v037: FAIL " + msg)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _wait_holstered() -> void:
	if ws.has_method("holster"):
		ws.call("holster")
	for i in 30:
		if ws.has_method("debug_finish_state"):
			ws.call("debug_finish_state")
		await _frames(1)
		await _phys(1)
		if not bool(ws.call("is_armed")):
			return


func _open_space() -> void:
	var pos := Vector3(1.4, 0.0, 2.2)
	var w3: World3D = player.get_world_3d()
	if w3:
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 4, 0), pos + Vector3(0, -8, 0), 1)
		q.exclude = [player.get_rid()]
		var hit: Dictionary = w3.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			pos.y = hit["position"].y
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.set("input_locked", false)
	if player.get("_yaw") != null:
		player.set("_yaw", 0.0)
		player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")


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
		print("v037_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok((presets.find("version/name=\"0.2.12\"") >= 0 or presets.find("version/name=\"0.2.13\"") >= 0), "export versionName stays 0.2.12")
	_ok((presets.find("version/code=14") >= 0 or presets.find("version/code=15") >= 0), "versionCode stays 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_sources()
	await _check_observe_bullet_cam()
	await _check_shotgun_pellets()
	_check_holster_wheel()
	await _check_reticle()
	await _check_rmb_drag_and_e()
	_check_ads_hold_toggle()
	await _check_stomp_no_launch()
	await _check_no_reload()
	await _check_look_down_aim()
	await _check_cover_pose()

	print("v037_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("is_display_mode") < 0 or bc.find("return false") < 0 or bc.find("观察模式与第一人称一样") >= 0, "observe/display mode no longer blocks bullet cam")
	_ok(bc.find("func cinematic_pellet_count") >= 0 and bc.find("_collect_pellets") >= 0, "shotgun cinematic tracks sibling pellets")
	_ok(bc.find("SPHERE_R := 0.36") >= 0 or bc.find("SPHERE_R := 0.3") >= 0, "cinematic x-ray sphere is larger")
	_ok(bc.find("ORBIT_SPEED := 0.32") >= 0 or bc.find("ORBIT_SPEED") >= 0, "orbit speed constant present")
	_ok(bc.find("_avoid_mesh_clip") >= 0, "orbit camera avoids clipping through the body")
	var ww := FileAccess.get_file_as_string("res://scripts/ui/weapon_wheel.gd")
	_ok(ww.find("const DEAD := 58.0") >= 0 or ww.find("holster_dead_zone") >= 0, "holster wheel dead zone enlarged")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("func reticle_mode") >= 0 and hud_src.find("武器无需换弹") >= 0, "HUD has reticle modes and 无需换弹 setting")
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("func ads_is_toggle") >= 0 and pc.find("set_rmb_corpse_drag") >= 0, "PC hold-ADS and RMB drag helpers exist")
	_ok(pc.find("_cancel_ragdoll_launch") >= 0, "stomp cancels ragdoll launch on the player")
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ws_src.find("func no_reload") >= 0 and ws_src.find("begin_shot") >= 0, "no_reload + shotgun shot_id on fire")
	# t25u 有意改动：俯仰中心从腰部改为肩/枪托。
	_ok(ws_src.find("func _shoulder_pivot_xf") >= 0, "look-down weapon pitches around the shoulder / stock (t25u)")
	var sec := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	_ok(sec.find("func _apply_aim_waist") >= 0, "aim-waist hook still present")
	_ok(sec.find("不再弯腰") >= 0 or sec.find("return") >= 0, "aim waist no longer curls the torso")
	_ok(ws_src.find("func _waist_aim_xf") >= 0 or ws_src.find("func _waist_world") >= 0, "weapon aim pitches around the waist")
	var hr := FileAccess.get_file_as_string("res://scripts/hit_reaction.gd")
	_ok(hr.find("_solve_cover_elbow") >= 0 and hr.find("L_Shoulder_a") >= 0, "cover pose redone; clavicles still listed")
	_ok(hr.find("不旋转锁骨") >= 0 or hr.find("不转锁骨") >= 0, "cover still skips clavicle rotation")
	_ok(ws_src.find("func apply_ik_after_loco") >= 0, "apply_ik_after_loco still present")


func _check_observe_bullet_cam() -> void:
	player.call("set_play_mode", 0)  # display / observe
	_ok(bool(player.call("is_display_mode")), "player is in observe/display mode")
	await _ready_gun("rifle")
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam node present")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	if cam:
		cam.set("debug_roll", 0.0)
		cam.call("debug_reset")
	# 直接用 consider：观察模式不得再被 is_display_mode 挡住。
	var organs: Node = player.call("get_organs")
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0.12)
	if player.has_method("focus_point"):
		var fp = player.call("focus_point", "belly")
		if fp is Vector3:
			belly = fp
	var info := {
		"gut": true, "uterus": false, "hit": true,
		"body": player, "organs": organs,
		"entry": belly, "pos": belly,
		"dir": Vector3(0, 0, 1), "origin": belly + Vector3(0, 0, -1.2),
	}
	var did := false
	if cam:
		did = bool(cam.call("consider", info, {}))
	_ok(did and cam and bool(cam.get("playing")), "observe/display organ hit can start bullet cam (did=%s playing=%s)" % [did, cam.get("playing") if cam else false])
	if cam and bool(cam.get("playing")):
		cam.call("skip")
		cam.call("debug_reset")
	# 再走一遍真实观察点击：弹头打中腹部后也应能开特写。
	if cam:
		cam.set("debug_roll", 0.0)
		cam.call("debug_reset")
	player.call("set_play_mode", 0)
	await _frames(2)
	var obs_cam: Camera3D = player.call("get_camera")
	if obs_cam and player.has_method("observe_tap_fire"):
		# 把观察相机摆到腹前，朝腹开枪。
		if player.has_method("set_tp_view"):
			player.call("set_tp_view", 3.2, 0.12, 1.85, true)
		await _frames(6)
		var sp := obs_cam.unproject_position(belly)
		player.call("observe_tap_fire", sp)
		for _i in 24:
			await _phys(1)
			if cam and bool(cam.get("playing")):
				break
		_ok(bool(cam.get("playing")) or bool(cam.get("last_triggered")), "observe tap fire can trigger bullet cam (playing=%s last=%s)" % [cam.get("playing") if cam else false, cam.get("last_triggered") if cam else false])
		if cam and bool(cam.get("playing")):
			cam.call("skip")
			cam.call("debug_reset")
	if cam:
		cam.set("debug_roll", -1.0)
		cam.call("debug_reset")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	await _wait_holstered()


func _check_shotgun_pellets() -> void:
	player.call("set_play_mode", 1)
	await _ready_gun("shotgun")
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam present for shotgun")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	if cam:
		cam.set("debug_roll", 0.0)
		cam.call("debug_reset")
	var def = ws.call("get_def", "shotgun") if ws.has_method("get_def") else ws.call("cur_def")
	var n_pel := 8
	if def:
		n_pel = maxi(1, int(def.get("pellets")))
	var origin: Vector3 = player.global_position + Vector3(0, 1.5, 0)
	var cam3: Camera3D = player.call("get_camera") if player.has_method("get_camera") else null
	if cam3:
		origin = cam3.global_position
	var dir := Vector3(0, 0, -1)
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, dir, true)
	# 不要等物理步进：高速弹头一帧就会打完，特写需要在生成后立刻把同组弹头收进来。
	var bal: Node = ws.get("ballistics")
	var live := 0
	var sid := 0
	if bal and bal.has_method("live_projectiles"):
		var arr: Array = bal.call("live_projectiles")
		live = arr.size()
		if live > 0 and arr[0] is Dictionary:
			sid = int(arr[0].get("shot_id", 0))
	_ok(live >= maxi(2, n_pel - 1), "shotgun spawned a cluster of pellets (live=%d expect=%d)" % [live, n_pel])
	# 用其中一发触发特写，应把同 shot_id 的弹头全部纳入。
	var organs: Node = player.call("get_organs")
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0)
	var lead := {}
	if bal and bal.has_method("live_projectiles"):
		var arr2: Array = bal.call("live_projectiles")
		# t25u：只有霰弹弹丸才触发成组特写；arr2[0] 可能是之前残留的其它武器弹头，取最新一发（本次霰弹）。
		for i in range(arr2.size() - 1, -1, -1):
			if arr2[i] is Dictionary:
				lead = arr2[i]
				break
	var info := {
		"gut": true, "body": player, "organs": organs,
		"entry": belly, "pos": belly, "dir": dir, "origin": origin,
		"projectile": lead,
	}
	var did := false
	if cam:
		did = bool(cam.call("consider", info, lead))
	var tracked := int(cam.call("cinematic_pellet_count")) if cam and cam.has_method("cinematic_pellet_count") else 0
	_ok(did and tracked >= maxi(2, live - 1), "shotgun cinematic tracks all pellets together (did=%s tracked=%d live=%d)" % [did, tracked, live])
	if cam:
		_ok(float(cam.call("xray_sphere_radius")) >= 0.30, "cinematic x-ray radius is enlarged (r=%.2f)" % float(cam.call("xray_sphere_radius")))
		_ok(float(cam.call("orbit_speed")) <= 0.40, "orbit speed is slower (%.2f)" % float(cam.call("orbit_speed")))
		cam.call("skip")
		cam.set("debug_roll", -1.0)
		cam.call("debug_reset")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	if bal and bal.has_method("clear_all"):
		bal.call("clear_all")
	await _wait_holstered()


func _check_holster_wheel() -> void:
	var wheel = hud.get("wheel") if hud else null
	_ok(wheel != null, "weapon wheel present")
	if wheel and wheel.has_method("holster_dead_zone"):
		var d := float(wheel.call("holster_dead_zone"))
		_ok(d >= 50.0, "holster center hit circle is larger (dead=%.1f)" % d)


func _check_reticle() -> void:
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	player.call("set_play_mode", 1)
	await _wait_holstered()
	await _frames(2)
	_ok(hud.has_method("reticle_mode"), "HUD exposes reticle_mode")
	_ok(str(hud.call("reticle_mode")) == "dot", "unarmed first-person shows a white dot (mode=%s)" % hud.call("reticle_mode"))
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	await _frames(2)
	_ok(str(hud.call("reticle_mode")) == "cross", "hip-fire shows a HUD reticle (mode=%s)" % hud.call("reticle_mode"))
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(2)
	_ok(str(hud.call("reticle_mode")) == "hidden", "ADS hides the HUD crosshair (mode=%s)" % hud.call("reticle_mode"))
	# 触屏开着也应是同一套逻辑
	if hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", true)
		_ok(str(hud.call("reticle_mode")) == "hidden", "phone ADS also hides the HUD crosshair")
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(1)
		_ok(str(hud.call("reticle_mode")) == "cross", "phone hip-fire still shows a reticle")
		hud.call("set_touch_ui", false)
	await _wait_holstered()
	_ok(str(hud.call("reticle_mode")) == "dot", "PC first-person unarmed white dot after holster")


func _check_rmb_drag_and_e() -> void:
	await _wait_holstered()
	player.call("set_play_mode", 1)
	_open_space()
	await _phys(1)
	main.call("spawn_clone", player.global_position + Vector3(0.1, 0.0, -0.55))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	if not bool(c.call("is_dead")):
		c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0, -1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.4, "category": "pistol"}})
		await _phys(4)
	var drag: Node = player.call("get_corpse_drag")
	var rag: Node = c.call("get_ragdoll")
	var chest: Vector3 = rag.call("get_follow_point") if rag else c.global_position + Vector3.UP
	player.global_position = Vector3(chest.x + 0.28, player.global_position.y, chest.z + 0.12)
	await _phys(2)
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(drag.call("is_holstered")), "holstered required to start RMB drag")
	_ok(player.has_method("set_rmb_corpse_drag"), "RMB drag API present")
	_ok(bool(player.call("set_rmb_corpse_drag", true)), "RMB hold starts drag")
	_ok(bool(drag.call("is_dragging")) or bool(drag.get("reaching")), "RMB hold is dragging or reaching")
	player.call("set_rmb_corpse_drag", false)
	_ok(not bool(drag.call("is_dragging")) and not bool(drag.get("reaching")), "RMB release drops the corpse")
	# E 仍是切换
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(player.call("toggle_corpse_drag")), "E toggle still starts drag")
	_ok(bool(drag.call("is_dragging")) or bool(drag.get("reaching")), "E toggle is dragging")
	_ok(bool(player.call("toggle_corpse_drag")), "E toggle again drops")
	_ok(not bool(drag.call("is_dragging")), "E toggle released the corpse")


func _check_ads_hold_toggle() -> void:
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", false)
	_ok(player.has_method("ads_is_toggle"), "ads_is_toggle exists")
	_ok(not bool(player.call("ads_is_toggle")), "PC (touch UI off) uses hold-to-ADS")
	if hud and hud.has_method("set_touch_ui"):
		hud.call("set_touch_ui", true)
		_ok(bool(player.call("ads_is_toggle")), "phone/touch UI uses toggle-ADS")
		hud.call("set_touch_ui", false)
		_ok(not bool(player.call("ads_is_toggle")), "switching back to PC restores hold-to-ADS")


func _check_stomp_no_launch() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _phys(2)
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.7))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0.2, 0.1, -1).normalized(), "entry": c.global_position + Vector3(0, 1.15, 0), "par": {"impulse": 0.5, "category": "rifle"}})
	await _phys(8)
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.get("active")), "stomp target is a ragdoll")
	var s0: Vector3 = rag.call("get_follow_point")
	player.global_position = Vector3(s0.x, s0.y + 0.05, s0.z)
	player.velocity = Vector3(1.8, 0.8, 0.2)
	var max_up := 0.0
	for _j in range(16):
		if player.has_method("_stomp_ragdolls"):
			player.call("_stomp_ragdolls", 0.016)
		if player.has_method("_cancel_ragdoll_launch"):
			player.call("_cancel_ragdoll_launch", true)
		await _phys(1)
		max_up = maxf(max_up, player.velocity.y)
	var s1: Vector3 = rag.call("get_follow_point")
	var spd := float(rag.call("max_linear_speed")) if rag.has_method("max_linear_speed") else 0.0
	_ok(s1.distance_to(s0) > 0.04 or spd > 0.25, "stomp still shoves the ragdoll (move=%.3f spd=%.2f)" % [s1.distance_to(s0), spd])
	_ok(max_up < 1.6 and player.velocity.y <= 0.35, "player is not launched by the ragdoll (max_up=%.2f vy=%.2f)" % [max_up, player.velocity.y])
	player.velocity = Vector3.ZERO


func _check_no_reload() -> void:
	player.call("set_play_mode", 1)
	await _ready_gun("pistol")
	_ok(settings != null and settings.has_method("set_no_reload"), "no_reload setting exists")
	# 关闭无需换弹时，无限备弹仍需换弹。
	settings.call("set_no_reload", false)
	settings.call("set_infinite_reserve", true)
	_ok(bool(ws.call("infinite_reserve")), "infinite reserve still on when no_reload is off")
	ws.call("debug_set_ammo", "pistol", 1, 30)
	_ok(bool(ws.call("reload")), "with no_reload off, a partial mag can still reload (infinite reserve)")
	await _frames(1)
	if ws.has_method("debug_finish_state"):
		for i in 8:
			ws.call("debug_finish_state")
			await _frames(1)
	# 开启无需换弹：弹匣不空，reload 被跳过，可连续开火。
	settings.call("set_no_reload", true)
	_ok(bool(ws.call("no_reload")), "no_reload is enabled")
	ws.call("debug_set_ammo", "pistol", 1, 30)
	var a0: Vector2i = ws.call("ammo_of", "pistol")
	_ok(not bool(ws.call("reload")), "no_reload skips the reload action")
	# 打若干发，弹匣不应打空到不能开火。
	var fired := 0
	for i in 6:
		if ws.has_method("fire_along_ray"):
			if bool(ws.call("fire_along_ray", player.global_position + Vector3(0, 1.5, 0), Vector3(0, 0, -1), true)):
				fired += 1
		await _phys(1)
	var a1: Vector2i = ws.call("ammo_of", "pistol")
	_ok(fired >= 5 and a1.x > 0, "no_reload lets the gun keep firing without emptying the mag (fired=%d mag=%d->%d)" % [fired, a0.x, a1.x])
	settings.call("set_no_reload", false)
	_ok(not bool(ws.call("no_reload")), "no_reload can be turned off")
	_ok(bool(ws.call("infinite_reserve")), "infinite reserve is unchanged after toggling no_reload")
	await _wait_holstered()


func _check_look_down_aim() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	# 先水平，再低头，对比胸前移与枪指向。
	player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	await _phys(3)
	var sec = player.call("get_secondary") if player.has_method("get_secondary") else null
	var chest0 := 0.0
	if sec and sec.has_method("debug_aim_waist"):
		chest0 = float(sec.call("debug_aim_waist").get("chest_fwd", 0.0))
	var follow0: Dictionary = ws.call("debug_aim_follow") if ws.has_method("debug_aim_follow") else {}
	var y0 := float(follow0.get("view_y", 0.0))
	player.set("_pitch", -1.25)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for _i in 6:
		await _phys(1)
	var chest1 := chest0
	if sec and sec.has_method("debug_aim_waist"):
		var d: Dictionary = sec.call("debug_aim_waist")
		chest1 = float(d.get("chest_fwd", 0.0))
	var follow1: Dictionary = ws.call("debug_aim_follow") if ws.has_method("debug_aim_follow") else {}
	var y1 := float(follow1.get("view_y", 0.0))
	var dot := float(follow1.get("dot", 0.0))
	# 不再用多节弯腰穿模；枪仍要跟着视线，并在画面里更低。
	_ok(dot > 0.82, "weapon points with the camera when looking down (dot=%.3f)" % dot)
	# t25u 有意改动：绕肩/枪托俯仰后，低头时枪在画面中的高度不再必然下降；改为确认不挡准心。
	_ok(not bool(ws.call("debug_center_hits_viewmodel")), "look-down weapon does not cover the crosshair (view y %.3f -> %.3f)" % [y0, y1])
	# 锁骨不应被 IK 旋转：源码已保证；这里确认 apply_ik_after_loco 仍在同一物理帧调用。
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("apply_ik_after_loco") >= 0 and pc.find("apply_pose") >= 0, "IK still runs after loco in the same physics frame")
	player.set("_pitch", 0.0)
	await _wait_holstered()


func _check_cover_pose() -> void:
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.4, 0.0, -0.8))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	if bool(c.call("is_dead")):
		return
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
	_ok(hr != null and bool(hr.call("is_covering")), "unarmed clone covers an organ hit")
	if hr and hr.has_method("cover_debug"):
		var dbg: Dictionary = hr.call("cover_debug")
		var skin: Vector3 = dbg.get("skin", dbg.get("point", Vector3.ZERO))
		_ok(skin != Vector3.ZERO, "cover has a skin target")
		if org and org.has_method("project_skin"):
			var projected: Vector3 = org.call("project_skin", inside)
			_ok(skin.distance_to(projected) < 0.08, "cover point is on the projected skin surface")
		_ok(float(dbg.get("L_skin_dist", 99.0)) < 0.16, "left hand is on the skin (d=%.3f)" % float(dbg.get("L_skin_dist", 99)))
		_ok(float(dbg.get("R_skin_dist", 99.0)) < 0.16, "right hand is on the skin (d=%.3f)" % float(dbg.get("R_skin_dist", 99)))
		_ok(not bool(dbg.get("hands_crossed", true)), "hands are not crossed/swapped (L_side=%.3f R_side=%.3f)" % [float(dbg.get("L_side", 0)), float(dbg.get("R_side", 0))])
		_ok(not bool(dbg.get("L_arm_through", true)) and not bool(dbg.get("R_arm_through", true)), "forearms do not pass through the torso")
		var le: Vector3 = dbg.get("L_elbow", Vector3.ZERO)
		var re: Vector3 = dbg.get("R_elbow", Vector3.ZERO)
		var lh: Vector3 = dbg.get("L_hand", Vector3.ZERO)
		var rh: Vector3 = dbg.get("R_hand", Vector3.ZERO)
		_ok(le.distance_to(lh) > 0.15 and re.distance_to(rh) > 0.15, "elbows stay out, not collapsed into the hands")
		_ok(le.y < skin.y + 0.22 and re.y < skin.y + 0.22, "elbows stay around the belly, not raised to the chest")
	var hr_src := FileAccess.get_file_as_string("res://scripts/hit_reaction.gd")
	_ok(hr_src.find("L_Shoulder_a") >= 0, "cover still lists clavicles in SKIP")
