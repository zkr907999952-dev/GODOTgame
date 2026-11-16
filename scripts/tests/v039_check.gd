extends SceneTree
## 0.2.12 自检（源码，不升版本号）t24u：观察模式霰弹多弹头特写、减弱果冻、俯视不弯腰、
## 左手握持、降低透视强度、换弹同步、拖拽点跟手/视角、消除射击后悬浮黑点。
##   godot --headless --path . -s res://scripts/tests/v039_check.gd

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
		print("v039: OK   ", msg)
	else:
		fails += 1
		push_error("v039: FAIL " + msg)


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
		print("v039_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok((presets.find("version/name=\"0.2.12\"") >= 0 or (presets.find("version/name=\"0.2.13\"") >= 0 or presets.find("version/name=\"0.2.14\"") >= 0)), "export versionName stays 0.2.12")
	_ok((presets.find("version/code=14") >= 0 or (presets.find("version/code=15") >= 0 or presets.find("version/code=16") >= 0)), "versionCode stays 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_sources()
	await _check_observe_shotgun()
	await _check_jello_weaker()
	await _check_no_lean()
	await _check_left_grip()
	await _check_xray_weaker()
	await _check_reload_sync()
	await _check_drag_follows_view()
	await _check_no_black_dots()

	print("v039_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("projectiles_for_shot") >= 0 or FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd").find("func projectiles_for_shot") >= 0, "shot groups survive after pellets end")
	_ok(bc.find("const XRAY_K") >= 0 and bc.find("XRAY_K := 0.48") >= 0, "cinematic x-ray amount is reduced (XRAY_K=0.48)")
	var fade := FileAccess.get_file_as_string("res://shaders/skin_xray_fade.gdshader")
	_ok(fade.find("0.32") >= 0 and fade.find("mix(0.96, 0.05") < 0, "fade overlay keeps a visible skin floor")
	var sec := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	var waist_fn := sec.find("func _apply_aim_waist")
	_ok(waist_fn >= 0, "aim-waist hook still present")
	if waist_fn >= 0:
		var after := sec.substr(waist_fn, 500)
		var next_fn := after.find("\nfunc ", 8)
		var body := after if next_fn < 0 else after.substr(0, next_fn)
		_ok(body.find("_nudge_look_bone") < 0, "looking down does not nudge waist/spine bones")
		_ok(body.find("不再弯腰") >= 0 or body.find("return") >= 0, "aim waist is a no-op")
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ws_src.find("func _sync_gun_reload_anim") >= 0, "reload keeps gun anim in sync with hands")
	_ok(ws_src.find("func _foregrip_gun") >= 0, "left hand uses a foregrip/handguard attach")
	_ok(ws_src.find("apply_ik_after_loco") >= 0, "apply_ik_after_loco still present")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("不再把弹头") >= 0 or bal.find("spent_visible_count") >= 0, "spent projectile meshes are no longer left floating")
	var drag := FileAccess.get_file_as_string("res://scripts/corpse_drag.gd")
	_ok(drag.find("capture_hold(aimed_point)") >= 0, "drag captures a view-space hold immediately")
	var jello := FileAccess.get_file_as_string("res://shaders/organ_common.gdshaderinc")
	_ok(jello.find("rad * 2.8 * k") < 0 and jello.find("rad * 1.05 * k") >= 0, "organ jello amplitude was reduced in the shader")


func _check_observe_shotgun() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("shotgun")
	player.call("set_play_mode", 0)
	await _frames(2)
	await _phys(1)
	_ok(bool(ws.call("is_armed")), "shotgun stays drawn in observe mode")
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam present")
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
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0)
	if player.has_method("focus_point"):
		var fp = player.call("focus_point", "belly")
		if fp is Vector3:
			belly = fp
	var dir := (belly - origin).normalized()
	if dir.length_squared() < 1e-6:
		dir = Vector3(0, 0, -1)
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, dir, true)
	var bal: Node = ws.get("ballistics")
	var live := 0
	var lead := {}
	var sid := 0
	var hit_owner_n := 0
	var group: Array = []
	if bal and bal.has_method("live_projectiles"):
		var arr: Array = bal.call("live_projectiles")
		live = arr.size()
		if live > 0 and arr[0] is Dictionary:
			lead = arr[0]
			sid = int(lead.get("shot_id", 0))
	if bal and sid != 0 and bal.has_method("projectiles_for_shot"):
		group = bal.call("projectiles_for_shot", sid)
	if group.is_empty() and bal and bal.has_method("live_projectiles"):
		group = bal.call("live_projectiles")
	for p in group:
		if p is Dictionary:
			if int(p.get("shot_id", 0)) == sid and sid != 0:
				pass
			if bool(p.get("hit_owner", false)):
				hit_owner_n += 1
	_ok(live >= maxi(2, n_pel - 1) or group.size() >= maxi(2, n_pel - 1), "observe shotgun spawned a pellet cluster (live=%d group=%d expect=%d)" % [live, group.size(), n_pel])
	_ok(sid != 0, "observe shotgun volley shares a shot_id (sid=%d)" % sid)
	_ok(group.size() >= maxi(2, n_pel - 1), "projectiles_for_shot keeps the whole cluster (n=%d)" % group.size())
	_ok(hit_owner_n >= maxi(2, group.size() - 1), "every observe pellet can hit the owner body (hit_owner=%d / %d)" % [hit_owner_n, group.size()])
	var organs: Node = player.call("get_organs")
	var info := {
		"gut": true, "uterus": false, "hit": true,
		"body": player, "organs": organs,
		"entry": belly, "pos": belly, "exit": belly + dir * 0.22,
		"dir": dir, "origin": origin,
	}
	var did := false
	if cam:
		did = bool(cam.call("consider", info, lead))
	var tracked := int(cam.call("cinematic_pellet_count")) if cam and cam.has_method("cinematic_pellet_count") else 0
	_ok(did and tracked >= maxi(2, n_pel - 1), "observe shotgun organ hit starts multi-pellet cinematic (did=%s tracked=%d expect=%d)" % [did, tracked, n_pel])
	if cam and bool(cam.get("playing")) and cam.has_method("debug_advance"):
		cam.call("debug_advance", 0.35)
		var trails := int(cam.call("smoke_trail_count")) if cam.has_method("smoke_trail_count") else 0
		var ready := bool(cam.call("pellet_trail_ready")) if cam.has_method("pellet_trail_ready") else false
		_ok(trails >= maxi(2, tracked) or ready, "each observe-mode pellet gets its own trail (trails=%d tracked=%d ready=%s)" % [trails, tracked, ready])
		cam.call("skip")
		cam.set("debug_roll", -1.0)
		cam.call("debug_reset")
	else:
		_ok(false, "could not start observe shotgun cinematic")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	await _wait_holstered()


func _check_jello_weaker() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	var organs: Node = player.call("get_organs")
	_ok(organs != null and organs.has_method("set_cinematic_jello"), "organs expose cinematic jello")
	if organs == null:
		return
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0.05)
	if player.has_method("focus_point"):
		var fp = player.call("focus_point", "belly")
		if fp is Vector3:
			belly = fp
	var dir := Vector3(0, 0, 1)
	# 生产默认（更弱）
	organs.call("set_cinematic_jello", belly, belly + dir * 0.22, dir, 0.55, 0.011, 0.0, 0.38)
	var jd: Dictionary = organs.call("jello_debug") if organs.has_method("jello_debug") else {}
	var a: Vector3 = jd.get("a", Vector3.ZERO)
	var ddir: Vector3 = jd.get("d", Vector3(0, 0, 1))
	if ddir.length_squared() < 1e-8:
		ddir = Vector3(0, 0, 1)
	else:
		ddir = ddir.normalized()
	var mx := 0.0
	var mid := 0.0
	for i in 16:
		var s := float(i) * 0.014
		var p: Vector3 = a + ddir * s
		var d := float(organs.call("debug_jello_displacement", p))
		mx = maxf(mx, d)
		if i == 4:
			mid = d
		# 径向采样
		var off := float(organs.call("debug_jello_displacement", p + Vector3(0.01, 0.0, 0.0)))
		mx = maxf(mx, off)
	_ok(mx > 0.0015, "weaker jello still displaces tissue (max=%.4f mid=%.4f)" % [mx, mid])
	# 8018f6e 峰值约 0.1225；新效果必须明显更低。
	_ok(mx < 0.055, "organ jello max displacement is clearly lower than 8018f6e (max=%.4f, old ~0.12)" % mx)
	var far := float(organs.call("debug_jello_displacement", a + ddir * 0.04 + Vector3(0.18, 0.16, 0.0)))
	_ok(far < mx * 0.85 + 0.002, "far tissue still displaces less (far=%.4f max=%.4f)" % [far, mx])
	if organs.has_method("clear_cinematic_jello"):
		organs.call("clear_cinematic_jello")
	await _wait_holstered()


func _check_no_lean() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for _i in 6:
		await _phys(1)
	var sec = player.call("get_secondary") if player.has_method("get_secondary") else null
	var chest0 := 0.0
	if sec and sec.has_method("debug_aim_waist"):
		chest0 = float(sec.call("debug_aim_waist").get("chest_fwd", 0.0))
	var bow0: Dictionary = ws.call("debug_spine_bow") if ws.has_method("debug_spine_bow") else {}
	player.set("_pitch", -1.15)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	for _i in 8:
		await _phys(1)
	var chest1 := chest0
	if sec and sec.has_method("debug_aim_waist"):
		chest1 = float(sec.call("debug_aim_waist").get("chest_fwd", 0.0))
	var bow1: Dictionary = ws.call("debug_spine_bow") if ws.has_method("debug_spine_bow") else {}
	var follow1: Dictionary = ws.call("debug_aim_follow") if ws.has_method("debug_aim_follow") else {}
	var dlean := absf(float(bow1.get("lean", 0.0)) - float(bow0.get("lean", 0.0)))
	var dsa := absf(float(bow1.get("spine_a", bow1.get("lean", 0.0))) - float(bow0.get("spine_a", bow0.get("lean", 0.0))))
	var dsb := absf(float(bow1.get("spine_b", 0.0)) - float(bow0.get("spine_b", 0.0)))
	var dsc := absf(float(bow1.get("spine_c", 0.0)) - float(bow0.get("spine_c", 0.0)))
	_ok(dlean < deg_to_rad(8.0) and dsa < deg_to_rad(8.0), "looking down does not lean the waist (dlean=%.1f dspine_a=%.1f deg)" % [rad_to_deg(dlean), rad_to_deg(dsa)])
	_ok(dsb < deg_to_rad(8.0) and dsc < deg_to_rad(8.0), "mid-spine stays unbent (b=%.1f c=%.1f deg)" % [rad_to_deg(dsb), rad_to_deg(dsc)])
	_ok(absf(chest1 - chest0) < 0.06, "chest does not lunge forward from a torso lean (%.3f -> %.3f)" % [chest0, chest1])
	_ok(float(follow1.get("dot", 0.0)) > 0.82, "weapon pitch still follows the look direction (dot=%.3f)" % float(follow1.get("dot", 0.0)))
	player.set("_pitch", 0.0)
	await _wait_holstered()


func _check_left_grip() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("rifle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	for _i in 8:
		await _phys(1)
	var hg: Dictionary = ws.call("debug_hand_to_gun") if ws.has_method("debug_hand_to_gun") else {}
	var he: Dictionary = ws.call("debug_hand_error") if ws.has_method("debug_hand_error") else {}
	_ok(float(hg.get("L", 99)) < 0.04, "left hand sits on the rifle mesh, not through it (L=%.3f)" % float(hg.get("L", 99)))
	_ok(float(hg.get("R", 99)) < 0.05, "right hand stays on the grip (R=%.3f)" % float(hg.get("R", 99)))
	if not he.is_empty():
		_ok(float(he.get("L", 99)) < 0.07, "left IK wrist reaches the handguard attach (L=%.3f)" % float(he.get("L", 99)))
	await _ready_gun("shotgun")
	for _i in 8:
		await _phys(1)
	var hg2: Dictionary = ws.call("debug_hand_to_gun") if ws.has_method("debug_hand_to_gun") else {}
	_ok(float(hg2.get("L", 99)) < 0.045, "left hand sits on the shotgun pump/handguard (L=%.3f)" % float(hg2.get("L", 99)))
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("apply_ik_after_loco") >= 0, "shoulder rule: IK still after loco")
	await _wait_holstered()


func _check_xray_weaker() -> void:
	var cam: Node = main.get_node_or_null("BulletCam")
	var organs: Node = player.call("get_organs")
	_ok(cam != null and organs != null, "cam and organs present for x-ray")
	if cam == null or organs == null:
		return
	var amt := 1.0
	if cam.has_method("cinematic_xray_amount"):
		amt = float(cam.call("cinematic_xray_amount"))
	var rad := float(cam.call("xray_sphere_radius")) if cam.has_method("xray_sphere_radius") else 0.0
	_ok(amt <= 0.62 and amt >= 0.28, "cinematic x-ray intensity is reduced (k=%.2f, was 0.95)" % amt)
	_ok(rad >= 0.30, "x-ray radius was not the only change (r=%.2f, still wide)" % rad)
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0)
	organs.call("set_xray_sphere_world", belly, rad, amt)
	var skin_a := 0.0
	if organs.has_method("debug_xray_skin_alpha_center"):
		skin_a = float(organs.call("debug_xray_skin_alpha_center"))
	_ok(skin_a >= 0.25, "skin silhouette remains visible inside the sphere (fade alpha=%.2f)" % skin_a)
	if organs.has_method("clear_xray_sphere"):
		organs.call("clear_xray_sphere")


func _check_reload_sync() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("rifle")
	if settings and settings.has_method("set_no_reload"):
		settings.call("set_no_reload", false)
	var ammo: Dictionary = ws.get("ammo")
	if ammo.has("rifle"):
		ammo["rifle"] = Vector2i(10, 60)
		ws.set("ammo", ammo)
	var started := bool(ws.call("reload"))
	_ok(started, "rifle reload started")
	if not started:
		await _wait_holstered()
		return
	var clip_len := 1.0
	if ws.get("_clips"):
		clip_len = float(ws.get("_clips").call("length", "reload"))
	var state_len := float(ws.get("state_len"))
	var worst := 0.0
	var samples := 0
	# 头less 帧间隔可能极短，主动抽样几个换弹进度点，确认枪和手对齐。
	for u in [0.18, 0.36, 0.52, 0.68]:
		if str(ws.get("state")) != "reloading":
			break
		ws.set("_clip_t", clip_len * float(u))
		ws.set("state_t", state_len * float(u))
		if ws.has_method("_sync_gun_reload_anim"):
			ws.call("_sync_gun_reload_anim")
		if ws.has_method("_step_reload_eject"):
			ws.call("_step_reload_eject")
		await _frames(2)
		await _phys(1)
		if not ws.has_method("debug_reload_sync"):
			break
		var d: Dictionary = ws.call("debug_reload_sync")
		var err := float(d.get("sync_err", 0.0))
		worst = maxf(worst, err)
		samples += 1
		print("v039: reload sync u=", u, " ", d)
	_ok(samples >= 3, "sampled reload midway (n=%d)" % samples)
	_ok(worst < 0.08, "hand clip and weapon reload stay in sync (worst u err=%.3f)" % worst)
	# 让换弹走完，避免卡住后续测试
	for _j in 40:
		if ws.has_method("debug_finish_state"):
			ws.call("debug_finish_state")
		await _frames(1)
		if str(ws.get("state")) != "reloading":
			break
	await _wait_holstered()


func _check_drag_follows_view() -> void:
	await _wait_holstered()
	_open_space()
	await _phys(1)
	main.call("spawn_clone", player.global_position + Vector3(0.1, 0.0, -0.55))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for drag follow")
	if clones.is_empty():
		return
	var c: Node = clones[clones.size() - 1]
	if not bool(c.call("is_dead")):
		c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0, -1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.4, "category": "pistol"}})
		await _phys(4)
	var drag: Node = player.call("get_corpse_drag")
	var rag: Node = c.call("get_ragdoll")
	var chest: Vector3 = rag.call("get_follow_point") if rag else c.global_position + Vector3.UP
	player.call("set_play_mode", 1)
	player.global_position = Vector3(chest.x + 0.28, player.global_position.y, chest.z + 0.12)
	player.velocity = Vector3.ZERO
	await _phys(2)
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(drag.call("can_start")), "can start drag")
	_ok(bool(player.call("toggle_corpse_drag")), "toggle starts drag")
	for _i in range(40):
		drag.call("physics_tick", 0.016)
		await _phys(1)
		if not bool(drag.get("reaching")):
			break
	_ok(bool(drag.call("is_dragging")), "still dragging")
	var hold0: Vector3 = drag.call("hold_world")
	var bone0: Vector3 = drag.call("current_grab_point")
	var yaw0 := float(player.get("_yaw"))
	player.set("_yaw", yaw0 + 0.7)
	player.set("_pitch", float(player.get("_pitch")) - 0.2)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")
	var hold1: Vector3 = drag.call("hold_world")
	_ok(hold1.distance_to(hold0) > 0.08, "rotating the view moves the drag target (hold d=%.3f)" % hold1.distance_to(hold0))
	for _j in range(12):
		drag.call("physics_tick", 0.016)
		await _phys(1)
	var bone1: Vector3 = drag.call("current_grab_point")
	_ok(bone1.distance_to(bone0) > 0.04 or bone1.distance_to(hold1) < bone0.distance_to(hold1), "grabbed bone is pulled toward the moving hold (bone d=%.3f)" % bone1.distance_to(bone0))
	player.call("toggle_corpse_drag")
	player.set("_yaw", yaw0)
	player.set("_pitch", 0.0)
	if player.has_method("_apply_camera"):
		player.call("_apply_camera")


func _check_no_black_dots() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("shotgun")
	var bal: Node = ws.get("ballistics")
	var origin: Vector3 = player.global_position + Vector3(0, 1.5, 0)
	var cam3: Camera3D = player.call("get_camera") if player.has_method("get_camera") else null
	if cam3:
		origin = cam3.global_position
	# 打向地面，弹头应命中并回收，不应留下悬浮黑球。
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, Vector3(0.05, -1, -0.2).normalized(), false)
	for _i in 24:
		await _phys(1)
		await _frames(1)
	var spent := 0
	var linger := 0
	if bal and bal.has_method("spent_visible_count"):
		spent = int(bal.call("spent_visible_count"))
	if bal and bal.has_method("lingering_visible_shot_meshes"):
		linger = (bal.call("lingering_visible_shot_meshes") as Array).size()
	_ok(spent == 0 and linger == 0, "no lingering visible projectile meshes after the shot (spent=%d linger=%d)" % [spent, linger])
	# 冲击球仍不可见
	await _wait_holstered()
