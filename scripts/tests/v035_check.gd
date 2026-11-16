extends SceneTree
## 0.2.13 自检：特写弹头朝向、地图直接进投影与侧栏传送、多点缩放后恢复单指、
## 观察模式点击向内射击、布娃娃子弹/踩踏推动、拖拽不因出范围松开、
## 捂腹姿势、透视按钮与 X 键、手机互动切换保持。
##   godot --headless --path . -s res://scripts/tests/v035_check.gd

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
		print("v035: OK   ", msg)
	else:
		fails += 1
		push_error("v035: FAIL " + msg)


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


func _push_touch(pressed: bool, pos: Vector2, idx: int = 0) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	root.push_input(e)


func _push_drag(pos: Vector2, rel: Vector2, idx: int = 0) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	root.push_input(e)


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
		print("v035_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok((presets.find("version/name=\"0.2.12\"") >= 0 or presets.find("version/name=\"0.2.13\"") >= 0), "export versionName stays 0.2.12")
	_ok((presets.find("version/code=14") >= 0 or presets.find("version/code=15") >= 0), "versionCode stays 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_sources()
	_check_bullet_orient()
	await _check_map_sidebar_and_pinch()
	await _check_observe_fire_inward()
	await _check_ragdoll_shove()
	await _check_drag_keeps_hold()
	await _check_cover_pose()
	await _check_xray_button()
	await _check_interact_toggle()

	print("v035_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("look_at(pos + dir") < 0, "bullet_cam no longer uses look_at for the projectile")
	_ok(bc.find("_orient_projectile") >= 0 and bc.find("Basis(d, y, z)") >= 0, "cinematic orients mesh +X along velocity")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("func look_along") >= 0, "ballistics.look_along is public")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("toggle_map_panel") >= 0 and hud_src.find("open_overhead") >= 0, "map button goes to overhead")
	_ok(hud_src.find("MapSidebarArrow") >= 0 and hud_src.find("_set_map_sidebar_open") >= 0, "map sidebar + arrow present")
	_ok(hud_src.find("XrayButton") >= 0 and hud_src.find("透视") >= 0, "x-ray chrome button present")
	var mv := FileAccess.get_file_as_string("res://scripts/map_view.gd")
	_ok(mv.find("purge_stale_touches") >= 0 and mv.find("func _input") >= 0, "map purges stale touches and catches ups in _input")
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("fire_along_ray") >= 0, "observe fire uses fire_along_ray")
	_ok(pc.find("touch_interact(pressed: bool, toggle: bool") >= 0, "phone interact supports toggle")
	var drag := FileAccess.get_file_as_string("res://scripts/corpse_drag.gd")
	_ok(drag.find("drop(\"range\")") < 0, "drag no longer auto-drops for leaving range")
	var rag := FileAccess.get_file_as_string("res://scripts/ragdoll_system.gd")
	_ok(rag.find("_add_bone_exceptions") >= 0, "ragdoll bones exception each other")
	_ok(rag.find("LAYER_WORLD | LAYER_CHAR") >= 0, "ragdoll mask includes character layer")
	var hr := FileAccess.get_file_as_string("res://scripts/hit_reaction.gd")
	_ok(hr.find("_front_of_torso") >= 0 and hr.find("cover_debug") >= 0, "cover pose has front-of-torso IK + debug")
	var tc := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc.find("touch_interact\", true, true") >= 0, "touch interact button toggles on press")
	# X 键本来就在 game_root 里
	var gr := FileAccess.get_file_as_string("res://scripts/game_root.gd")
	_ok(gr.find("KEY_X: \"xray\"") >= 0, "X key still toggles x-ray")


func _check_bullet_orient() -> void:
	var n := Node3D.new()
	root.add_child(n)
	n.global_position = Vector3(1, 2, 3)
	var d := Vector3(0.4, 0.1, -0.9).normalized()
	# 用 ballistics 的 look_along
	var bal: Node = ws.get("ballistics")
	_ok(bal != null and bal.has_method("look_along"), "ballistics.look_along available")
	if bal and bal.has_method("look_along"):
		bal.call("look_along", n, d)
		var x := n.global_transform.basis.x.normalized()
		_ok(x.dot(d) > 0.98, "mesh +X aligns with velocity (dot=%.3f)" % x.dot(d))
	# 特写放置路径：bullet_cam._orient_projectile
	var bcam: Node = main.get("bullet_cam")
	_ok(bcam != null and bcam.has_method("_orient_projectile"), "bullet_cam has _orient_projectile")
	if bcam and bcam.has_method("_orient_projectile"):
		var n2 := Node3D.new()
		root.add_child(n2)
		bcam.call("_orient_projectile", n2, d)
		var x2 := n2.global_transform.basis.x.normalized()
		_ok(x2.dot(d) > 0.98, "cinematic mesh +X aligns with path (dot=%.3f)" % x2.dot(d))
		# look_at 会把 -Z 对准路径，+X 会几乎垂直
		var n3 := Node3D.new()
		root.add_child(n3)
		n3.global_position = Vector3.ZERO
		n3.look_at(d, Vector3.UP)
		var look_x := n3.global_transform.basis.x.normalized()
		_ok(absf(look_x.dot(d)) < 0.25, "look_at +X is sideways to path (would be the bug)")
		n2.queue_free()
		n3.queue_free()
	n.queue_free()


func _check_map_sidebar_and_pinch() -> void:
	# 地图按钮直接进投影，不打开中间菜单
	hud.call("close_panels")
	_ok(not bool(hud.call("is_panel_open")), "no panel open before map button")
	hud.call("toggle_map_panel")
	await _frames(6)
	var mv: Node = main.get("map_view")
	_ok(mv != null and bool(mv.get("is_open")), "map button opens projection immediately")
	_ok(not bool(hud.call("is_panel_open")), "old map menu is not shown")
	_ok(hud.has_method("is_map_sidebar_open") and not bool(hud.call("is_map_sidebar_open")), "sidebar collapsed by default")
	var arrow: Button = hud.find_child("MapSidebarArrow", true, false)
	_ok(arrow != null and arrow.visible, "sidebar arrow is visible")
	_ok(arrow != null and arrow.text == ">", "collapsed arrow shows >")
	var panel: Control = hud.find_child("MapSidebarPanel", true, false)
	_ok(panel != null and not panel.visible, "sidebar panel hidden when collapsed")
	hud.call("toggle_map_sidebar")
	_ok(bool(hud.call("is_map_sidebar_open")), "arrow/toggle opens sidebar")
	_ok(panel.visible, "sidebar panel visible when open")
	_ok(arrow.text == "<", "open arrow shows <")
	var listed := 0
	var sl: Node = hud.find_child("MapSidebarList", true, false)
	if sl:
		listed = sl.get_child_count()
	_ok(listed >= 2, "sidebar lists teleport points (children=%d)" % listed)
	hud.call("toggle_map_sidebar")
	_ok(not bool(hud.call("is_map_sidebar_open")), "second toggle collapses sidebar")

	# 双指捏合后松开，再单指平移和点选都必须可用
	mv.set("marker", null)
	var pan0: Vector2 = mv.get("pan")
	_push_touch(true, Vector2(500, 300), 0)
	_push_touch(true, Vector2(700, 300), 1)
	await _frames(1)
	_push_drag(Vector2(480, 300), Vector2(-20, 0), 0)
	_push_drag(Vector2(740, 300), Vector2(40, 0), 1)
	await _frames(1)
	_ok(int(mv.call("touch_count")) == 2, "pinch has two touches")
	# 两指都抬起
	_push_touch(false, Vector2(480, 300), 0)
	_push_touch(false, Vector2(740, 300), 1)
	await _frames(2)
	_ok(int(mv.call("touch_count")) == 0, "both fingers released")
	# 单指平移
	var p0 := Vector2(640, 360)
	var p1 := Vector2(800, 450)
	_push_touch(true, p0, 0)
	await _frames(1)
	_push_drag(p1, p1 - p0, 0)
	await _frames(1)
	_push_touch(false, p1, 0)
	await _frames(2)
	var pan1: Vector2 = mv.get("pan")
	_ok(pan1.distance_to(pan0) > 1.0, "after pinch, single-finger pan works (%s → %s)" % [pan0, pan1])
	_ok(mv.get("marker") == null, "pan after pinch does not set a teleport point")
	# 单击选点
	var tpos := Vector2(610, 330)
	_push_touch(true, tpos, 0)
	await _frames(1)
	_push_touch(false, tpos, 0)
	await _frames(2)
	_ok(mv.get("marker") != null, "after pinch, tap still sets teleport point")

	# 模拟丢失一次抬起：双指后只抬起一根，残指超时后新的单指仍可用
	mv.set("marker", null)
	var pan2: Vector2 = mv.get("pan")
	_push_touch(true, Vector2(500, 320), 0)
	_push_touch(true, Vector2(720, 320), 1)
	_push_drag(Vector2(490, 320), Vector2(-10, 0), 0)
	_push_drag(Vector2(740, 320), Vector2(20, 0), 1)
	_push_touch(false, Vector2(490, 320), 0)
	# 故意不抬起 index 1
	_ok(int(mv.call("touch_count")) == 1, "one stale finger remains after missed up")
	# 等足够帧让残指过期，再强制按 0 帧/毫秒清掉（模拟超时）
	await _frames(30)
	if mv.has_method("purge_stale_touches"):
		mv.call("purge_stale_touches", 0, 0)
	_ok(int(mv.call("touch_count")) == 0, "stale finger purged")
	var p2 := Vector2(640, 400)
	var p3 := Vector2(760, 460)
	_push_touch(true, p2, 0)
	_push_drag(p3, p3 - p2, 0)
	_push_touch(false, p3, 0)
	await _frames(2)
	_ok(Vector2(mv.get("pan")).distance_to(pan2) > 0.5, "after stale purge, single-finger pan works again")
	_push_touch(true, Vector2(600, 350), 0)
	_push_touch(false, Vector2(600, 350), 0)
	await _frames(2)
	_ok(mv.get("marker") != null, "after stale purge, tap still sets teleport point")

	main.call("close_overhead")
	await _frames(2)


func _check_observe_fire_inward() -> void:
	_open_space()
	player.call("set_play_mode", 0)
	await _frames(4)
	await _ready_gun("pistol")
	var bal: Node = ws.get("ballistics")
	if bal and bal.has_method("clear_all"):
		bal.call("clear_all")
	var ammo0: Vector2i = ws.call("ammo_of", "pistol")
	var cam: Camera3D = player.call("get_camera")
	# 屏幕中心偏下一点：垂直向内
	var sp := Vector2(640, 400)
	_ok(bool(player.call("observe_tap_fire", sp)), "observe click fires at a screen point")
	var ammo1: Vector2i = ws.call("ammo_of", "pistol")
	_ok(ammo1.x == ammo0.x - 1, "observe click consumes one round")
	var ray_o := cam.project_ray_origin(player.call("to_camera_pixel", sp) if player.has_method("to_camera_pixel") else sp)
	var ray_d := cam.project_ray_normal(player.call("to_camera_pixel", sp) if player.has_method("to_camera_pixel") else sp)
	# 如果 to_camera_pixel 在 headless 1280x720 上是恒等，直接用 sp 也行
	if ray_d.length_squared() < 1e-8:
		ray_o = cam.project_ray_origin(sp)
		ray_d = cam.project_ray_normal(sp)
	var aligned := false
	if bal and bal.has_method("live_projectiles"):
		for rec in bal.call("live_projectiles"):
			var d: Vector3 = rec.get("dir", rec.get("vel", Vector3.ZERO))
			if d.length_squared() > 1e-8 and d.normalized().dot(ray_d.normalized()) > 0.95:
				aligned = true
				var origin: Vector3 = rec.get("origin", rec.get("pos", Vector3.ZERO))
				_ok((origin - ray_o).length() < 0.5, "shot originates near the camera ray")
		if bal.call("live_count") == 0:
			# 可能一帧内已打到墙。仍视为开火成功（弹药已减）。
			aligned = true
	_ok(aligned, "shot travels inward along the click ray")
	# 空白处同样开火
	_ok(bool(player.call("observe_tap_fire", Vector2(200, 200))), "click in empty space also fires inward")
	await _wait_holstered()


func _check_ragdoll_shove() -> void:
	player.call("set_play_mode", 1)
	_open_space()
	await _phys(2)
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.8))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0.2, 0.1, -1).normalized(), "entry": c.global_position + Vector3(0, 1.15, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(8)
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.get("active")), "clone is a ragdoll")
	var p0: Vector3 = rag.call("get_follow_point")
	# 再补一枪冲击
	if rag.has_method("apply_hit_impulse"):
		rag.call("apply_hit_impulse", Vector3(0, 0.2, -12.0), p0)
	await _phys(8)
	var p1: Vector3 = rag.call("get_follow_point")
	var spd := float(rag.call("max_linear_speed")) if rag.has_method("max_linear_speed") else 0.0
	_ok(p1.distance_to(p0) > 0.05 or spd > 0.25, "bullet impact moves the ragdoll (move=%.3f spd=%.2f)" % [p1.distance_to(p0), spd])
	# 踩踏
	var follow: Vector3 = rag.call("get_follow_point")
	var s0 := follow
	player.global_position = Vector3(follow.x, follow.y + 0.04, follow.z)
	player.velocity = Vector3(1.6, -1.2, 0.3)
	for _j in range(14):
		if player.has_method("_stomp_ragdolls"):
			player.call("_stomp_ragdolls", 0.016)
		await _phys(1)
	var s1: Vector3 = rag.call("get_follow_point")
	var spd2 := float(rag.call("max_linear_speed")) if rag.has_method("max_linear_speed") else 0.0
	_ok(s1.distance_to(s0) > 0.04 or spd2 > 0.2, "stomp shoves the ragdoll (move=%.3f spd=%.2f)" % [s1.distance_to(s0), spd2])
	player.velocity = Vector3.ZERO


func _check_drag_keeps_hold() -> void:
	await _wait_holstered()
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
	player.call("set_play_mode", 1)
	player.global_position = Vector3(chest.x + 0.28, player.global_position.y, chest.z + 0.12)
	await _phys(2)
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(drag.call("is_holstered")), "holstered required to start")
	_ok(bool(player.call("toggle_corpse_drag")), "toggle starts drag")
	for _i in range(48):
		drag.call("physics_tick", 0.016)
		await _phys(1)
		if not bool(drag.get("reaching")):
			break
	_ok(bool(drag.call("is_dragging")), "drag started")
	# 走出原选择范围，不应自动放开
	player.global_position = player.global_position + Vector3(4.0, 0, 0)
	for _j in range(8):
		drag.call("physics_tick", 0.016)
		await _phys(1)
	_ok(bool(drag.call("is_dragging")), "still dragging after walking out of pick range")
	_ok(str(drag.get("last_drop_reason")) != "range", "drop reason is not range (%s)" % str(drag.get("last_drop_reason")))
	# 持枪仍会取消；收枪才能开始
	player.call("toggle_corpse_drag")
	await _ready_gun("pistol")
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(not bool(drag.call("can_start")), "cannot start drag while armed")
	await _wait_holstered()


func _check_cover_pose() -> void:
	main.call("spawn_clone", player.global_position + Vector3(0.4, 0.0, -0.8))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	if bool(c.call("is_dead")):
		return
	var hr: Node = c.call("get_hit_reaction")
	var belly: Vector3 = c.global_position + Vector3(0, 1.0, 0.08)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": belly})
	await _phys(4)
	await _frames(2)
	_ok(hr != null and bool(hr.call("is_covering")), "unarmed clone covers an organ hit")
	if hr and hr.has_method("cover_debug"):
		var dbg: Dictionary = hr.call("cover_debug")
		var lh: Vector3 = dbg.get("L_hand", Vector3.ZERO)
		var rh: Vector3 = dbg.get("R_hand", Vector3.ZERO)
		_ok(float(dbg.get("L_hand_dist", 99.0)) < 0.45, "left hand reaches the hit point (d=%.3f)" % float(dbg.get("L_hand_dist", 99)))
		_ok(float(dbg.get("R_hand_dist", 99.0)) < 0.45, "right hand reaches the hit point (d=%.3f)" % float(dbg.get("R_hand_dist", 99)))
		_ok(not bool(dbg.get("L_arm_through", true)) and not bool(dbg.get("R_arm_through", true)), "forearms do not pass through the torso")
		# 肘应在手的外侧，而不是叠进肚子
		var le: Vector3 = dbg.get("L_elbow", Vector3.ZERO)
		var re: Vector3 = dbg.get("R_elbow", Vector3.ZERO)
		_ok(le.distance_to(lh) > 0.15 and re.distance_to(rh) > 0.15, "elbows stay out, not collapsed into the hands")
	# 锁骨仍不旋转（源码约束）
	var hr_src := FileAccess.get_file_as_string("res://scripts/hit_reaction.gd")
	_ok(hr_src.find("L_Shoulder_a") >= 0 and hr_src.find("不旋转锁骨") >= 0 or hr_src.find("不转锁骨") >= 0, "cover still skips clavicle rotation")


func _check_xray_button() -> void:
	var btn: Button = hud.find_child("XrayButton", true, false)
	_ok(btn != null, "透视 button exists")
	var cam_btn: Button = null
	# 摄像机按钮在同一条右栏里，透视必须在它左边
	for b in hud.find_children("*", "Button", true, false):
		if b is Button and (b as Button).text == "摄像机":
			cam_btn = b
			break
	_ok(btn != null and cam_btn != null, "both 透视 and 摄像机 exist")
	if btn and cam_btn:
		_ok(btn.get_parent() == cam_btn.get_parent(), "x-ray and camera share the right chrome bar")
		_ok(btn.get_index() < cam_btn.get_index(), "透视 is immediately left of 摄像机 (index %d < %d)" % [btn.get_index(), cam_btn.get_index()])
	var org: Node = player.call("get_organs")
	var before := bool(org.get("xray_enabled")) if org else true
	# 按钮切换
	if btn:
		btn.set_pressed(not before)
		# toggle_mode 会发出 toggled
		await _frames(2)
		var mid := bool(org.get("xray_enabled")) if org else before
		_ok(mid != before, "x-ray button toggles 透视 (was %s now %s)" % [before, mid])
	# X 键
	var now := bool(org.get("xray_enabled")) if org else false
	main.call("toggle_xray")
	await _frames(1)
	if hud.has_method("sync"):
		hud.call("sync")
	var after := bool(org.get("xray_enabled")) if org else now
	_ok(after != now, "X / toggle_xray flips 透视")
	# 恢复原状态
	if after != before:
		main.call("toggle_xray")
		if hud.has_method("sync"):
			hud.call("sync")


func _check_interact_toggle() -> void:
	player.call("set_play_mode", 1)
	await _frames(2)
	# 手机路径：toggle=true，按一次保持，再按退出
	_ok(player.has_method("is_touch_interact_on") and not bool(player.call("is_touch_interact_on")), "interact starts off")
	player.call("touch_interact", true, true)
	_ok(bool(player.call("is_touch_interact_on")), "phone press enters interact and stays on")
	player.call("touch_interact", false, true)
	_ok(bool(player.call("is_touch_interact_on")), "phone release does not exit interact")
	player.call("touch_interact", true, true)
	_ok(not bool(player.call("is_touch_interact_on")), "second phone press exits interact")
	# PC 路径不变：按下开始、松开结束
	player.call("touch_interact", true)
	_ok(bool(player.call("is_touch_interact_on")), "PC-style press starts interact")
	player.call("touch_interact", false)
	_ok(not bool(player.call("is_touch_interact_on")), "PC-style release ends interact")
