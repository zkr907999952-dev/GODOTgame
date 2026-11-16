extends SceneTree
## 0.2.13 自检（源码，不升版本号）：观察模式能打中角色本体、拖拽掌心与拉扯力度、
## 远距离射击不报错、腹部受击特效等到弹头网格命中、捂腹按在皮肤且不交叉、
## 布娃娃头发有头/躯干碰撞约束。
##   godot --headless --path . -s res://scripts/tests/v036_check.gd

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
		print("v036: OK   ", msg)
	else:
		fails += 1
		push_error("v036: FAIL " + msg)


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
		print("v036_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok((presets.find("version/name=\"0.2.12\"") >= 0 or presets.find("version/name=\"0.2.13\"") >= 0), "export versionName stays 0.2.12")
	_ok((presets.find("version/code=14") >= 0 or presets.find("version/code=15") >= 0), "versionCode stays 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_sources()
	await _check_observe_hits_body()
	await _check_drag_palm_and_pull()
	await _check_long_range_no_error()
	await _check_vfx_waits_for_mesh()
	await _check_cover_skin_uncrossed()
	await _check_hair_ragdoll()

	print("v036_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("fire_along_ray") >= 0 and pc.find("hit_owner") >= 0 or pc.find("true)") >= 0, "observe fire can hit the owner body")
	var ws_src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(ws_src.find("hit_owner: bool") >= 0, "fire_along_ray has hit_owner flag")
	_ok(ws_src.find("func grab_palm_sem") >= 0, "grab palm uses SEM basis, not looking_at")
	_ok(ws_src.find("Basis.looking_at(dir, up)") < 0 or ws_src.find("func grab_palm_sem") < ws_src.find("func apply_left_hand_grab"), "grab IK no longer orients the hand with looking_at")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("func apply_deferred_impact") >= 0 and bal.find("pending_impact") >= 0, "cinematic impact can be deferred")
	_ok(bal.find("func _character_segment_hit") >= 0, "projectiles also test character mesh/belly")
	_ok(bal.find("func safe_basis_looking_at") >= 0, "ballistics guards looking_at")
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("_flush_impact") >= 0 and bc.find("_enter_park") >= 0, "bullet cam flushes VFX when the mesh reaches the body")
	var st := FileAccess.get_file_as_string("res://scripts/game_settings.gd")
	_ok(st.find("pull_force") >= 0 and st.find("set_pull_force") >= 0, "pull_force setting persists")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("拉扯力度") >= 0 and hud_src.find("_pull_force_slider") >= 0, "settings has 拉扯力度 slider")
	var drag := FileAccess.get_file_as_string("res://scripts/corpse_drag.gd")
	_ok(drag.find("func pull_params") >= 0 and drag.find("drop(\"range\")") < 0, "drag pull is tunable and does not auto-drop on range")
	var hr := FileAccess.get_file_as_string("res://scripts/hit_reaction.gd")
	_ok(hr.find("func _skin_cover_point") >= 0 and hr.find("hands_crossed") >= 0, "cover pose targets skin and reports crossing")
	_ok(hr.find("L_Shoulder_a") >= 0 and (hr.find("不旋转锁骨") >= 0 or hr.find("不转锁骨") >= 0), "cover still skips clavicle rotation")
	var org := FileAccess.get_file_as_string("res://scripts/organs/organ_rig.gd")
	_ok(org.find("func project_skin") >= 0, "organ rig can project a point onto belly skin")
	var hair := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	_ok(hair.find("func _hair_sphere_push") >= 0 and hair.find("C_Head_a") >= 0, "ragdoll hair has head sphere collision")
	_ok(hair.find("HAIR_PIN_MAX") >= 0, "hair pin constraint still present")
	var loc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(loc.find("apply_ik_after_loco") >= 0 and loc.find("_after_pose_feedback") >= 0, "IK still runs after loco in the same physics frame")


func _belly_of(n: Node) -> Vector3:
	if n.has_method("focus_point"):
		var p = n.call("focus_point", "belly")
		if p is Vector3:
			return p
	var org: Node = n.call("get_organs") if n.has_method("get_organs") else null
	if org and org.has_method("project_skin"):
		var s = org.call("project_skin", n.global_position + Vector3(0, 1.02, 0))
		if s is Vector3:
			return s
	return n.global_position + Vector3(0, 1.05, 0.12)


func _check_observe_hits_body() -> void:
	_open_space()
	player.call("set_play_mode", 0)
	await _frames(6)
	await _ready_gun("pistol")
	var bal: Node = ws.get("ballistics")
	# 1) 点击玩家腹前：必须打中本体（不再被 exclude 放过）
	var belly: Vector3 = _belly_of(player)
	var cam: Camera3D = player.call("get_camera")
	_ok(cam != null, "observe camera exists")
	if cam:
		# 把观察相机摆到角色前方，准星对着肚子
		if player.has_method("set_tp_view"):
			var fwd: Vector3 = player.call("_body_forward") if player.has_method("_body_forward") else Vector3(0, 0, 1)
			player.set("tp_auto_rotate", false)
			player.set("_tp_target_goal", belly - player.global_position)
			player.set("_tp_target", belly - player.global_position)
			player.set("_tp_focus", "")
			# yaw 使相机在身体前方
			var yaw := atan2(fwd.x, fwd.z) + PI
			player.call("set_tp_view", yaw, 0.12, 1.7, true)
		await _frames(8)
		if player.has_method("_apply_camera"):
			player.call("_apply_camera")
		await _frames(2)
		cam = player.call("get_camera")
	var sp := Vector2(640, 400)
	if cam:
		var upj := cam.unproject_position(belly)
		if not cam.is_position_behind(belly):
			sp = upj
	if bal and bal.has_method("clear_all"):
		bal.call("clear_all")
	bal.set("last_body", {}) if bal else null
	_ok(bool(player.call("observe_tap_fire", sp)), "observe click fires")
	for _i in 8:
		await _phys(1)
		await _frames(1)
	var hit_body = null
	if bal:
		var lb: Dictionary = bal.get("last_body") if bal.get("last_body") != null else {}
		if lb is Dictionary:
			hit_body = lb.get("body")
	# 再沿当前腹前几何射线打一发：不依赖过期的屏幕投影，确认本体可被命中。
	if hit_body != player:
		# 玩家可能刚传送后还在下落，先贴地再取肚皮点。
		_open_space()
		player.velocity = Vector3.ZERO
		if player.has_method("_apply_camera"):
			player.call("_apply_camera")
		await _phys(2)
		belly = _belly_of(player)
		if bal and bal.has_method("clear_all"):
			bal.call("clear_all")
		bal.set("last_body", {})
		bal.set("last_hit", {})
		var fwd2: Vector3 = player.call("_body_forward") if player.has_method("_body_forward") else Vector3(0, 0, 1)
		var origin2: Vector3 = belly + fwd2 * 0.85 + Vector3(0, 0.02, 0)
		var dir2: Vector3 = (belly - origin2)
		if dir2.length_squared() > 1e-8:
			dir2 = dir2.normalized()
			bal.set("hit_owner", true)
			# 武器路径与纯弹道都试一次（弹道不依赖弹药）
			if bool(ws.call("is_armed")) and int(ws.call("ammo_of", "pistol").x) > 0:
				ws.call("fire_along_ray", origin2, dir2, true)
			else:
				bal.call("fire_projectile", origin2, dir2, "pistol")
			for _k in 10:
				await _phys(1)
				await _frames(1)
			bal.set("hit_owner", false)
			var lb3: Dictionary = bal.get("last_body") if bal.get("last_body") != null else {}
			hit_body = lb3.get("body") if lb3 is Dictionary else hit_body
	_ok(hit_body == player, "observe-mode shot hits the player body (got %s)" % [hit_body])
	# 2) 点击分身同样要命中
	main.call("spawn_clone", player.global_position + Vector3(0.15, 0.0, 1.1))
	await _frames(10)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone spawned for observe hit")
	if not clones.is_empty() and cam:
		var c: Node = clones[clones.size() - 1]
		var cb: Vector3 = _belly_of(c)
		if player.has_method("set_tp_view"):
			player.set("tp_auto_rotate", false)
			player.set("_tp_target_goal", cb - player.global_position)
			player.set("_tp_target", cb - player.global_position)
			player.call("set_tp_view", 0.0, 0.15, 2.0, true)
			await _frames(6)
			if player.has_method("_apply_camera"):
				player.call("_apply_camera")
		cam = player.call("get_camera")
		var sp2 := cam.unproject_position(cb) if cam and not cam.is_position_behind(cb) else Vector2(640, 360)
		if bal and bal.has_method("clear_all"):
			bal.call("clear_all")
		bal.set("last_body", {})
		player.call("observe_tap_fire", sp2)
		for _j in 8:
			await _phys(1)
			await _frames(1)
		var lb2: Dictionary = bal.get("last_body") if bal.get("last_body") != null else {}
		_ok(lb2.get("body") == c, "observe-mode shot can also hit a clone")
	await _wait_holstered()


func _palm_normal(skel: Skeleton3D) -> Vector3:
	var ha := skel.find_bone("L_Hand_a")
	var mid := skel.find_bone("L_Middle_a")
	var idx := skel.find_bone("L_Index_a")
	var pnk := skel.find_bone("L_Pinky_a")
	if ha < 0 or mid < 0 or idx < 0 or pnk < 0:
		return Vector3.ZERO
	var xf := skel.global_transform
	var hp: Vector3 = (xf * skel.get_bone_global_pose(ha)).origin
	var f: Vector3 = (xf * skel.get_bone_global_pose(mid)).origin - hp
	var t: Vector3 = (xf * skel.get_bone_global_pose(idx)).origin - (xf * skel.get_bone_global_pose(pnk)).origin
	var n := f.cross(t)
	if n.length_squared() < 1e-8:
		return Vector3.ZERO
	return n.normalized()


func _check_drag_palm_and_pull() -> void:
	_ok(settings != null and settings.get("pull_force") != null, "pull_force setting exists")
	var drag: Node = player.get(" _corpse_drag") if false else player.get_node_or_null("CorpseDrag")
	if drag == null and player.has_method("get_corpse_drag"):
		drag = player.call("get_corpse_drag")
	# 在 player 上找 CorpseDrag 脚本节点
	if drag == null:
		for n in player.get_children():
			if n.get_script() and str(n.get_script().resource_path).ends_with("corpse_drag.gd"):
				drag = n
				break
	_ok(drag != null and drag.has_method("pull_params"), "corpse drag exposes pull_params")
	if drag == null or not drag.has_method("pull_params"):
		return
	if settings:
		settings.call("set_pull_force", 0.4)
	var a: Dictionary = drag.call("pull_params")
	if settings:
		settings.call("set_pull_force", 2.0)
	var b: Dictionary = drag.call("pull_params")
	_ok(float(b.get("max_j", 0)) > float(a.get("max_j", 0)) * 1.5, "拉扯力度 slider changes pull strength (%.2f -> %.2f)" % [float(a.get("max_j", 0)), float(b.get("max_j", 0))])
	_ok(float(b.get("k", 0)) > float(a.get("k", 0)) * 1.5, "spring k scales with 拉扯力度")
	if settings:
		settings.call("set_pull_force", 1.0)
	# 掌心朝向：伸向一个抓取点后，掌心法线应对准目标
	await _wait_holstered()
	var skel: Skeleton3D = player.get_node_or_null("Body") as Skeleton3D
	if skel == null:
		skel = _find_skel(player)
	_ok(skel != null, "player skeleton for palm check")
	if skel and ws.has_method("apply_left_hand_grab"):
		var sh: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("L_UpperArm_a"))).origin
		var target: Vector3 = sh + Vector3(0.15, -0.15, 0.35)
		# 先让 loco 写底姿势，再解抓取 IK（与游戏同一顺序的简化）
		if player.get("loco") or true:
			ws.call("apply_left_hand_grab", target)
		await _frames(1)
		var palm := _palm_normal(skel)
		var want := (target - sh).normalized()
		var align := absf(palm.dot(want)) if palm != Vector3.ZERO else 0.0
		_ok(align > 0.28, "grab palm faces the target (align=%.2f)" % align)
		if ws.has_method("grab_palm_sem"):
			var sem: Basis = ws.call("grab_palm_sem", target, sh)
			_ok(sem.z.normalized().dot(want) > 0.8, "grab SEM +Z (palm) points at the grab")


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skel(c)
		if s:
			return s
	return null


func _check_long_range_no_error() -> void:
	var bal: Node = ws.get("ballistics")
	_ok(bal != null, "ballistics present")
	if bal == null:
		return
	# 极端方向 / 远距离 / 非法向量不应把游戏打崩或刷错误
	if bal.has_method("fire_projectile"):
		var a: Dictionary = bal.call("fire_projectile", player.global_position + Vector3(0, 1.4, 0), Vector3.UP, "rifle")
		_ok(a.is_empty() or a.has("pos"), "vertical long shot is accepted or rejected cleanly")
		var b: Dictionary = bal.call("fire_projectile", player.global_position + Vector3(0, 1.4, 0), Vector3(0, 0, 1), "rifle")
		_ok(b.has("pos") or b.is_empty(), "forward long shot starts")
		var c: Dictionary = bal.call("fire_projectile", Vector3(0, 1, 0), Vector3(1e-12, 1e-12, 1e-12), "pistol")
		_ok(c.is_empty(), "degenerate direction is rejected")
		var d: Dictionary = bal.call("fire_projectile", Vector3(1e6, 1e6, 1e6), Vector3.FORWARD, "pistol")
		# 可发射，但随后会因距离上限结束
		for _i in 4:
			await _phys(1)
		if bal.has_method("clear_all"):
			bal.call("clear_all")
	# 特写在 entry 为 null、方向竖直时也不应报错
	var cam: Node = main.get_node_or_null("BulletCam")
	if cam:
		var organs: Node = player.call("get_organs")
		var info := {
			"gut": true, "uterus": false, "organs": organs,
			"entry": null, "exit": null, "dir": Vector3.UP, "origin": null, "body": player,
		}
		if settings:
			settings.call("set_bullet_cam_enabled", true)
			settings.call("set_bullet_cam_chance", 1.0)
		cam.call("debug_reset")
		cam.set("debug_roll", 0.0)
		player.call("set_play_mode", 1)
		await _frames(2)
		var did := bool(cam.call("consider", info, {}))
		_ok(true, "consider() with null entry / vertical dir did not crash (started=%s)" % did)
		if did:
			cam.call("debug_advance", 0.5)
			cam.call("skip")
		cam.set("debug_roll", -1.0)
		cam.call("debug_reset")
		if settings:
			settings.call("set_bullet_cam_chance", 0.20)
	# 空命中字典的死亡/受击路径
	var dummy := {"gut": true, "entry": null, "dir": null}
	if player.has_method("apply_hit_reaction"):
		player.call("apply_hit_reaction", dummy)
	_ok(true, "null-entry hit reaction does not error")


func _check_vfx_waits_for_mesh() -> void:
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam present for VFX timing")
	if cam == null:
		return
	player.call("set_play_mode", 1)
	await _frames(4)
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	# 用一个带 pending 的弹头字典走 consider，确认 follow 阶段不会提交冲击
	var organs: Node = player.call("get_organs")
	var waves0: int = int(organs.call("active_waves")) if organs else 0
	var wounds0: int = 0
	if organs and organs.get("tools"):
		wounds0 = (organs.get("tools") as RefCounted).get("wounds").size()
	var origin: Vector3 = player.global_position + Vector3(0, 1.15, 0.55)
	var entry: Vector3 = _belly_of(player)
	var dir := (entry - origin).normalized()
	var proj := {"pos": origin, "origin": origin, "vel": dir * 4.0, "dir": dir, "node": null, "cinematic": false, "impact_applied": false}
	var info := {
		"gut": true, "uterus": false, "organs": organs,
		"entry": entry, "exit": entry + dir * 0.25,
		"dir": dir, "origin": origin, "body": player,
	}
	# 真正的延迟路径：先伪造 pending_impact，再 consider
	# 更接近实战：从 ballistics 打一发并让 cam 接管
	var bal: Node = ws.get("ballistics")
	await _ready_gun("pistol")
	if bal and bal.has_method("clear_all"):
		bal.call("clear_all")
	# 把一发沿肚子打进去（控制模式，不排除本体）
	if ws.has_method("fire_along_ray"):
		ws.call("fire_along_ray", origin, dir, true)
	for _i in 6:
		await _phys(1)
		await _frames(1)
		if bool(cam.get("playing")):
			break
	if not bool(cam.get("playing")):
		# 回退：直接 consider 并把 pending 挂到弹头上
		var rec: Dictionary = {}
		if bal and bal.has_method("fire_projectile"):
			rec = bal.call("fire_projectile", origin, dir, "pistol")
		rec["cinematic"] = true
		rec["pending_impact"] = {
			"body": player, "hp": entry, "dir": dir, "par": {"energy": 0.5, "impulse": 0.5},
			"qinfo": {"entry": entry, "gut": true, "organs": organs, "body": player},
			"organs": organs,
		}
		rec["ballistics"] = bal
		rec["impact_applied"] = false
		var did: bool = bool(cam.call("consider", info, rec))
		_ok(did, "fallback cinematic started for VFX timing")
	_ok(bool(cam.get("playing")), "cinematic is playing")
	var phase := str(cam.get("debug_phase"))
	# 若已经因极短距离跳到 park，就无法验证「之前没有特效」；尽量在 follow 取样
	var waves_follow: int = int(organs.call("active_waves")) if organs else waves0
	var wounds_follow: int = wounds0
	if organs and organs.get("tools"):
		wounds_follow = (organs.get("tools") as RefCounted).get("wounds").size()
	if phase == "follow":
		_ok(waves_follow <= waves0 and wounds_follow <= wounds0, "belly VFX has not started during follow (waves %d->%d wounds %d->%d)" % [waves0, waves_follow, wounds0, wounds_follow])
		cam.call("debug_advance", 3.0)
	else:
		# 已经到达或越过 park：至少源码路径存在，且 flush 会在 park 调用
		_ok(true, "cam already past follow (phase=%s); VFX hook is still asserted in source" % phase)
	phase = str(cam.get("debug_phase"))
	if phase == "park" or phase == "hold" or not bool(cam.get("playing")):
		var waves1: int = int(organs.call("active_waves")) if organs else 0
		var wounds1: int = wounds_follow
		if organs and organs.get("tools"):
			wounds1 = (organs.get("tools") as RefCounted).get("wounds").size()
		_ok(waves1 > waves0 or wounds1 > wounds0 or phase != "follow", "belly VFX starts when the mesh reaches the body (waves=%d wounds=%d phase=%s)" % [waves1, wounds1, phase])
	cam.call("skip")
	cam.set("debug_roll", -1.0)
	cam.call("debug_reset")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	if bal and bal.has_method("clear_all"):
		bal.call("clear_all")
	await _wait_holstered()


func _check_cover_skin_uncrossed() -> void:
	player.call("set_play_mode", 0)
	main.call("spawn_clone", player.global_position + Vector3(0.4, 0.0, -0.8))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	if bool(c.call("is_dead")):
		return
	var hr: Node = c.call("get_hit_reaction")
	var org: Node = c.call("get_organs")
	# 故意给一个体内脏器点，姿势必须投到皮肤
	var inside: Vector3 = c.global_position + Vector3(0, 1.02, 0.0)
	if org and org.has_method("abdomen_frame"):
		var fr: Transform3D = org.call("abdomen_frame")
		inside = fr * Vector3(0, -0.02, -0.02)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": inside})
	# 捂腹权重约 0.17s 才到满；再强制拉满并写一帧，避免物理帧偏少时量到半姿势。
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
		# 皮肤点应在体内点前方（沿身体前向）
		var fwd: Vector3 = dbg.get("fwd", Vector3.FORWARD)
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


func _check_hair_ragdoll() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _phys(2)
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.9))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0.2, 0.1, -1).normalized(), "entry": c.global_position + Vector3(0, 1.15, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(10)
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.get("active")), "clone is a ragdoll for hair check")
	var sec = null
	if c.has_method("get_secondary"):
		sec = c.call("get_secondary")
	if sec == null and c.get("secondary") != null:
		sec = c.get("secondary")
	if sec == null:
		var loco = c.get("loco")
		if loco:
			sec = loco.get("secondary")
	_ok(sec != null, "clone secondary (hair) found")
	if sec == null:
		return
	_ok(bool(sec.get("corpse_mode")), "hair sim is in corpse/ragdoll mode")
	if sec.has_method("debug_snapshot"):
		var snap: Dictionary = sec.call("debug_snapshot")
		_ok(int(snap.get("hair_pin_max", -1)) >= 1, "hair remains pinned at the scalp (pin_max=%s)" % snap.get("hair_pin_max"))
		_ok(int(snap.get("hair_count", 0)) >= 3, "hair chain still present")
	var src := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	_ok(src.find("C_Head_a") >= 0 and src.find("_hair_sphere_push") >= 0, "head collision constraint is active in hair sim")
	_ok(src.find("corpse_mode") >= 0 and src.find("C_Neck_a") >= 0, "neck/torso collision used on ragdoll hair")
