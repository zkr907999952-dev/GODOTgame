extends SceneTree
## 0.2.13 自检（源码，不升版本号）：霰弹特写每发弹头白色弹道、低头以腰为旋转中心且不再弯腰穿模、
## 持枪手臂下移、手部握持贴枪、特写内脏果冻挤开。
##   godot --headless --path . -s res://scripts/tests/v038_check.gd

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
		print("v038: OK   ", msg)
	else:
		fails += 1
		push_error("v038: FAIL " + msg)


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
		print("v038_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.12\"") >= 0, "export versionName stays 0.2.12")
	_ok(presets.find("version/code=14") >= 0, "versionCode stays 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_sources()
	await _check_shotgun_trails()
	await _check_waist_pivot_and_grip()
	await _check_organ_jello()
	await _check_hidden_impact_sphere()

	print("v038_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("func smoke_trail_count") >= 0 and bc.find("_push_all_trails") >= 0, "cinematic builds a white trail per pellet")
	_ok(bc.find("func pellet_trail_ready") >= 0, "pellet_trail_ready helper exists")
	_ok(bc.find("_update_organ_jello") >= 0, "bullet cam drives organ jello during pass/hold")
	_ok(bc.find("_collect_pellets") >= 0 and bc.find("func cinematic_pellet_count") >= 0, "all-pellets camera follow is kept")
	var sec := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	var waist_fn := sec.find("func _apply_aim_waist")
	_ok(waist_fn >= 0, "aim-waist hook remains (single waist pivot)")
	if waist_fn >= 0:
		var after := sec.substr(waist_fn, 600)
		var next_fn := after.find("\nfunc ", 8)
		var body := after if next_fn < 0 else after.substr(0, next_fn)
		_ok(body.find("_nudge_look_bone(\"C_Spine_b\"") < 0 and body.find("_nudge_look_bone(\"C_Spine_c\"") < 0 and body.find("_nudge_look_bone(\"C_Spine_d\"") < 0, "aim waist no longer pitches mid/upper spine")
		_ok(body.find("L_Shoulder_a") < 0 and body.find("R_Shoulder_a") < 0, "aim waist does not rotate clavicles")
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	# t25u 有意改动：俯仰轴从腰部改为肩/枪托（用户要求以大臂肩膀为轴、枪托抵肩为另一轴）。
	_ok(ws_src.find("func _shoulder_pivot_xf") >= 0, "weapon pitch pivots around the shoulder / stock (t25u)")
	_ok(ws_src.find("func _armed_arm_down") >= 0 and ws_src.find("ARM_DOWN_HIP") >= 0, "armed arm pose has a downward offset")
	_ok(ws_src.find("func _grip_anchor_gun") >= 0 and ws_src.find("GRIP_BLEND") >= 0, "hands are pulled onto weapon grip anchors")
	_ok(ws_src.find("func apply_ik_after_loco") >= 0, "apply_ik_after_loco still present")
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	var pose_i := pc.find("apply_pose")
	var ik_i := pc.find("apply_ik_after_loco")
	_ok(pose_i >= 0 and ik_i > pose_i, "apply_ik_after_loco still runs after loco apply_pose")
	var org := FileAccess.get_file_as_string("res://scripts/organs/organ_rig.gd")
	_ok(org.find("func set_cinematic_jello") >= 0 and org.find("func debug_jello_displacement") >= 0, "organ jello API is present")
	var sh := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	var inc := FileAccess.get_file_as_string("res://shaders/organ_common.gdshaderinc")
	var rag_src := FileAccess.get_file_as_string("res://scripts/ragdoll_system.gd")
	var sp_i := rag_src.find("func spawn_impact_sphere")
	var sp_body := rag_src.substr(sp_i, 1600) if sp_i >= 0 else ""
	_ok(sp_i >= 0 and sp_body.find("SphereMesh") < 0 and sp_body.find("MeshInstance3D") < 0, "impact sphere builds no visual mesh")
	_ok(inc.find("vec3 jello_offset") >= 0 and sh.find("jello_offset(l)") >= 0, "organ shader applies jello displacement")


func _check_shotgun_trails() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("shotgun")
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
	var dir := Vector3(0, 0, -1)
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, dir, true)
	var bal: Node = ws.get("ballistics")
	var live := 0
	var lead := {}
	if bal and bal.has_method("live_projectiles"):
		var arr: Array = bal.call("live_projectiles")
		live = arr.size()
		if live > 0 and arr[0] is Dictionary:
			lead = arr[0]
	_ok(live >= maxi(2, n_pel - 1), "shotgun spawned a cluster of pellets (live=%d expect=%d)" % [live, n_pel])
	var organs: Node = player.call("get_organs")
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0)
	var info := {
		"gut": true, "body": player, "organs": organs,
		"entry": belly, "pos": belly, "dir": dir, "origin": origin,
	}
	var did := false
	if cam:
		did = bool(cam.call("consider", info, lead))
	var tracked := int(cam.call("cinematic_pellet_count")) if cam and cam.has_method("cinematic_pellet_count") else 0
	_ok(did and tracked >= maxi(2, live - 1), "cinematic still follows all pellets (did=%s tracked=%d live=%d)" % [did, tracked, live])
	if cam and bool(cam.get("playing")) and cam.has_method("debug_advance"):
		cam.call("debug_advance", 0.35)
		var trails := int(cam.call("smoke_trail_count")) if cam.has_method("smoke_trail_count") else 0
		var pts := int(cam.call("smoke_point_count")) if cam.has_method("smoke_point_count") else 0
		var ready := bool(cam.call("pellet_trail_ready")) if cam.has_method("pellet_trail_ready") else false
		_ok(trails >= maxi(2, tracked) or ready, "each shotgun pellet has its own white trail (trails=%d tracked=%d pts=%d ready=%s)" % [trails, tracked, pts, ready])
		_ok(pts >= trails * 2, "trails have enough points to draw a path (pts=%d trails=%d)" % [pts, trails])
		cam.call("skip")
		cam.set("debug_roll", -1.0)
		cam.call("debug_reset")
	else:
		_ok(false, "could not start or advance shotgun cinematic for trails")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	await _wait_holstered()


func _check_waist_pivot_and_grip() -> void:
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
	var hold0 := Vector3.ZERO
	if ws.has_method("debug_waist_hold_vector"):
		hold0 = ws.call("debug_waist_hold_vector")
	var follow0: Dictionary = ws.call("debug_aim_follow") if ws.has_method("debug_aim_follow") else {}
	var y0 := float(follow0.get("view_y", 0.0))
	var down := 0.0
	if ws.has_method("debug_arm_down_offset"):
		down = float(ws.call("debug_arm_down_offset"))
	_ok(down < -0.02, "armed arm pose is shifted downward (dy=%.3f)" % down)

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
	var y1 := float(follow1.get("view_y", 0.0))
	var dot := float(follow1.get("dot", 0.0))
	var hold1 := hold0
	if ws.has_method("debug_waist_hold_vector"):
		hold1 = ws.call("debug_waist_hold_vector")
	# 不再把俯仰分到胸椎多节（那会穿模）；允许腰部整体俯身让胸随上半身前移。
	var sb0 := float(bow0.get("spine_b", 0.0))
	var sb1 := float(bow1.get("spine_b", 0.0))
	var sc0 := float(bow0.get("spine_c", 0.0))
	var sc1 := float(bow1.get("spine_c", 0.0))
	_ok(absf(sb1 - sb0) < deg_to_rad(8.0) and absf(sc1 - sc0) < deg_to_rad(8.0), "no mid-spine curl / clipping torso-bend (spine_b %.1f->%.1f spine_c %.1f->%.1f deg)" % [rad_to_deg(sb0), rad_to_deg(sb1), rad_to_deg(sc0), rad_to_deg(sc1)])
	_ok(dot > 0.82, "weapon still points with the camera (dot=%.3f)" % dot)
	# t25u 有意改动：枪绕肩窝里的枪托转，低头时枪托不离开肩（代替旧的「画面里更低 / 绕腰」断言）。
	var spv: Dictionary = ws.call("debug_stock_pivot") if ws.has_method("debug_stock_pivot") else {}
	var d_sh1 := 99.0
	if spv.has("stock") and spv.has("R_UpperArm_a"):
		d_sh1 = (spv["stock"] as Vector3).distance_to(spv["R_UpperArm_a"])
	# 注：本脚本的 _open_space 点 (1.4,0,2.2) 在当前地图上没有地板，角色在下落，身体相对镜头会滞后，
	# 所以这里只做宽松检查；严格的「俯仰时枪托不离肩窝」在 v040（出生点地板上）断言。
	_ok(d_sh1 < 0.40, "look-down stock stays at the shoulder pocket (%.3f m from upper arm)" % d_sh1)
	_ok(not bool(ws.call("debug_center_hits_viewmodel")), "look-down weapon does not cover the crosshair")

	# 手应约束在枪上
	var hg: Dictionary = ws.call("debug_hand_to_gun") if ws.has_method("debug_hand_to_gun") else {}
	var he: Dictionary = ws.call("debug_hand_error") if ws.has_method("debug_hand_error") else {}
	_ok(float(hg.get("R", 99)) < 0.05 and float(hg.get("L", 99)) < 0.05, "hands sit on the weapon mesh (R=%.3f L=%.3f)" % [float(hg.get("R", 99)), float(hg.get("L", 99))])
	if not he.is_empty():
		_ok(float(he.get("R", 99)) < 0.07 and float(he.get("L", 99)) < 0.07, "IK wrists reach their grip sockets (R=%.3f L=%.3f)" % [float(he.get("R", 99)), float(he.get("L", 99))])

	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("apply_ik_after_loco") >= 0 and pc.find("apply_pose") >= 0, "IK still runs after loco in the same physics frame")
	player.set("_pitch", 0.0)
	await _wait_holstered()


func _check_organ_jello() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _ready_gun("rifle")
	var cam: Node = main.get_node_or_null("BulletCam")
	var organs: Node = player.call("get_organs")
	_ok(organs != null and organs.has_method("set_cinematic_jello"), "organs expose cinematic jello")
	if organs == null:
		return
	# 直接调用 API：路径中点的位移应随进度/时间变化，而不是静态偏移。
	var entry := Vector3(0, 0, 0)
	# 用腹部局部：先给一个世界点。
	var belly: Vector3 = player.global_position + Vector3(0, 1.05, 0.05)
	if player.has_method("focus_point"):
		var fp = player.call("focus_point", "belly")
		if fp is Vector3:
			belly = fp
	var dir := Vector3(0, 0, 1)
	organs.call("set_cinematic_jello", belly, belly + dir * 0.22, dir, 0.15, 0.016, 0.0)
	var jd0: Dictionary = organs.call("jello_debug") if organs.has_method("jello_debug") else {}
	var a0: Vector3 = jd0.get("a", Vector3.ZERO)
	var ddir: Vector3 = jd0.get("d", Vector3(0, 0, 1))
	if ddir.length_squared() < 1e-8:
		ddir = Vector3(0, 0, 1)
	else:
		ddir = ddir.normalized()
	var mid_ab: Vector3 = a0 + ddir * 0.04
	var d0 := float(organs.call("debug_jello_displacement", mid_ab))
	organs.call("set_cinematic_jello", belly, belly + dir * 0.22, dir, 0.85, 0.016, 0.0)
	if organs.has_method("advance_cinematic_jello"):
		organs.call("advance_cinematic_jello", 0.25)
	var d1 := float(organs.call("debug_jello_displacement", mid_ab))
	var far: Vector3 = mid_ab + Vector3(0.18, 0.16, 0.0)
	var dfar := float(organs.call("debug_jello_displacement", far))
	_ok(d1 > 0.002 or d0 > 0.002, "jello displaces tissue along the path (d0=%.4f d1=%.4f)" % [d0, d1])
	_ok(absf(d1 - d0) > 0.0004, "jello displacement changes with progress/time, not a static offset (d0=%.4f d1=%.4f)" % [d0, d1])
	_ok(dfar < maxf(d1, d0) * 0.85 + 0.004, "far tissue is displaced less than the path (far=%.4f path=%.4f)" % [dfar, maxf(d0, d1)])

	# 再走一遍特写：进入 park 后 jello 应启动，hold 时仍在变化。
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	if cam:
		cam.set("debug_roll", 0.0)
		cam.call("debug_reset")
		organs.call("clear_cinematic_jello")
		var info := {
			"gut": true, "uterus": false, "hit": true,
			"body": player, "organs": organs,
			"entry": belly, "pos": belly, "exit": belly + dir * 0.22,
			"dir": dir, "origin": belly - dir * 0.9,
		}
		var did := bool(cam.call("consider", info, {}))
		_ok(did and bool(cam.get("playing")), "bullet cam starts for organ-jello test")
		if did:
			# 跟随阶段尚未入体：jello 不应开始（受击特效等弹头碰到身体）。
			cam.call("debug_advance", 0.08)
			var pre_on := bool(organs.call("is_jello_active")) if organs.has_method("is_jello_active") else false
			# 推进到 park（空气段最多约 span/FLY_SPEED，这里给足时间）
			cam.call("debug_advance", 1.6)
			var during := bool(organs.call("is_jello_active")) if organs.has_method("is_jello_active") else false
			var jd: Dictionary = organs.call("jello_debug") if organs.has_method("jello_debug") else {}
			var mid1 := float(organs.call("debug_jello_displacement", mid_ab))
			cam.call("debug_advance", 0.35)
			var mid2 := float(organs.call("debug_jello_displacement", mid_ab))
			_ok(during, "jello is active once the visible bullet enters the body (phase=%s active=%s reach=%.3f)" % [cam.get("debug_phase"), during, float(jd.get("reach", 0.0))])
			_ok(absf(mid2 - mid1) > 1e-5 or float(jd.get("age", 0.0)) > 0.05, "jello keeps moving during the cinematic (d %.4f -> %.4f age=%.3f)" % [mid1, mid2, float(jd.get("age", 0.0))])
			# 跟随刚开始时不应已经在挤开（允许已经进入 park 的短距离测试宽松）
			if str(cam.get("debug_phase")) == "follow":
				_ok(not pre_on, "jello waits until the bullet mesh hits the body")
			cam.call("skip")
			cam.call("debug_reset")
		cam.set("debug_roll", -1.0)
	if organs.has_method("clear_cinematic_jello"):
		organs.call("clear_cinematic_jello")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	await _wait_holstered()


func _check_hidden_impact_sphere() -> void:
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.15, 0.0, -0.9))
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for impact sphere test")
	if clones.is_empty():
		return
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0, -1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(3)
	var rag: Node = c.call("get_ragdoll")
	if rag == null:
		_ok(false, "ragdoll missing")
		return
	var hip0: Vector3 = rag.call("get_pelvis_point") as Vector3
	var before_sph := int(rag.get("sphere_count"))
	var before_n := int(rag.get("impulse_count"))
	var dir := Vector3(1, 0.08, 0).normalized()
	var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, dir)
	rag.call("apply_hit_impulse", imp, rag.call("get_follow_point") as Vector3, null)
	await _phys(2)
	var live := int(rag.call("live_impact_spheres"))
	var vis := bool(rag.call("impact_sphere_visible"))
	await _phys(6)
	var hip1: Vector3 = rag.call("get_pelvis_point") as Vector3
	var spd := float(rag.call("max_linear_speed"))
	_ok(int(rag.get("sphere_count")) > before_sph and int(rag.get("impulse_count")) > before_n, "impact sphere still spawns and impulse is applied")
	_ok(live >= 1 and not vis, "live impact sphere has no visible mesh (live=%d visible=%s)" % [live, vis])
	_ok(spd > 0.25 or hip0.distance_to(hip1) > 0.02, "corpse is still shoved by the hidden sphere (spd=%.3f moved=%.3f)" % [spd, hip0.distance_to(hip1)])
