extends SceneTree
## 0.2.12 自检：拳交内脏随腹部变形、尸体拖拽（收枪/皮肤/开火键位）、受击力度、
## 地图真触摸路径点选与平移、前方锥角奔跑、胶囊碰撞与踩踏、观察点击射击、
## 武器/换弹对调、互动内武器菜单、玩家 1000 血、空手捂腹、近距隐藏弹头。
##   godot --headless --path . -s res://scripts/tests/v034_check.gd

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
		print("v034: OK   ", msg)
	else:
		fails += 1
		push_error("v034: FAIL " + msg)


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
	# 躲开先前测试留下的尸体，但仍停在出生点附近的地面上，避免掉出地图。
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
		print("v034_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.12\"") >= 0, "export versionName 0.2.12")
	_ok(presets.find("version/code=14") >= 0, "versionCode 14")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")
	_ok(presets.find("include_filter=\"assets/organs/*.bin,assets/organs/*.json\"") >= 0, "organs include_filter kept")
	_ok(presets.find("architectures/arm64-v8a=true") >= 0, "arm64 on")
	_ok(presets.find("architectures/armeabi-v7a=false") >= 0, "armeabi off")

	_check_sources()
	_check_hp()
	_check_weapon_menu()
	await _check_touch_layout()
	await _check_fist_follow()
	await _check_hit_force()
	await _check_sprint_cone()
	await _check_map_touch_path()
	await _check_drag()
	await _check_bump_stomp()
	await _check_observe_fire()
	await _check_cover()
	await _check_bullet_mesh()

	print("v034_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var organ_sh := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	_ok(organ_sh.find("organ_fist_offset(l)") >= 0 and organ_sh.find("off += belly") >= 0, "organ shader adds belly bulge to guts")
	var drag_src := FileAccess.get_file_as_string("res://scripts/corpse_drag.gd")
	_ok(drag_src.find("is_holstered") >= 0, "drag requires holster")
	_ok(drag_src.find("_mesh_skin_hit") >= 0 or drag_src.find("SKIN_RADIUS") >= 0, "skin grab present")
	_ok(drag_src.find("reaching") >= 0 and drag_src.find("pick_range") >= 0, "reach phase and longer pick range")
	_ok(drag_src.find("PinJoint3D") >= 0 and drag_src.find("不创建 PinJoint3D") >= 0, "still no live PinJoint on bones")
	var mv := FileAccess.get_file_as_string("res://scripts/map_view.gd")
	_ok(mv.find("handle_gui_event") >= 0 and mv.find("to_logical") >= 0, "map has GUI ingest + logical coords")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("MapInputCatcher") >= 0, "HUD map catcher present")
	_ok(hud_src.find("受击力度") >= 0, "settings have hit-force slider")
	_ok(hud_src.find("_btn_weapon.visible = false") >= 0, "standalone weapon chrome hidden")
	var tc := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc.find("out[\"drag\"]") >= 0, "touch drag occupies fire slot")
	_ok(tc.find("obs_fire") >= 0, "observe tap-fire role")
	# 换弹现在占用原来武器的偏左位置
	_ok(tc.find("reload") >= 0 and tc.find("x2 - 128.0") >= 0, "reload/weapon positions still use the 0.2.11 cluster constants")
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc.find("SPRINT_CONE") >= 0 and pc.find("_stomp_ragdolls") >= 0, "sprint cone and stomp present")
	_ok(pc.find("max_hp = 1000") >= 0, "player default 1000 HP in source")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("MESH_CAM_DIST") >= 0, "bullet mesh hidden near camera")


func _check_hp() -> void:
	_ok(is_equal_approx(float(player.call("get_max_hp")), 1000.0), "player max HP 1000")
	_ok(is_equal_approx(float(player.call("get_hp")), 1000.0), "player starts at 1000")
	var num: Label = hud.find_child("HpNumber", true, false)
	if hud.has_method("_refresh_player_hp"):
		hud.call("_refresh_player_hp")
	_ok(num != null and str(num.text).find("1000") >= 0, "HP UI shows 1000 (%s)" % (num.text if num else "missing"))


func _check_weapon_menu() -> void:
	var btn: Button = hud.get("_btn_weapon")
	_ok(btn != null, "weapon chrome button still exists")
	_ok(btn == null or not btn.visible, "no standalone 武器 button in the top bar")
	var interact: Control = hud.get("_panel_interact")
	# open interact to reveal embedded list
	if hud.has_method("toggle_weapon_panel"):
		hud.call("toggle_weapon_panel")
	var lst: Node = hud.find_child("WeaponList", true, false)
	_ok(lst != null, "weapon list lives in the 互动 panel")
	if interact:
		_ok(interact.visible, "互动 panel opens for the weapon menu")
	hud.call("close_panels")


func _check_touch_layout() -> void:
	hud.call("set_touch_ui", true)
	player.call("set_play_mode", 1)
	await _frames(4)
	var tc: Control = hud.call("get_touch_controls")
	_ok(tc != null, "touch controls present")
	if tc == null:
		hud.call("set_touch_ui", false)
		return
	# 先持枪看换弹/武器对调，再收枪看拖拽槽
	await _ready_gun("pistol")
	var btns: Dictionary = tc.call("buttons")
	_ok(btns.has("weapon") and btns.has("reload"), "weapon and reload present when armed")
	if btns.has("weapon") and btns.has("reload"):
		var wr: Rect2 = btns["weapon"][0]
		var rr: Rect2 = btns["reload"][0]
		_ok(wr.position.y < rr.position.y - 20.0, "武器 is above 换弹 after swap (w.y=%.1f r.y=%.1f)" % [wr.position.y, rr.position.y])
		_ok(rr.position.x < wr.position.x - 40.0, "换弹 is to the left of 武器 after swap")
	_ok(btns.has("fire") and btns.has("fire_left"), "fire cluster and mid-left fire kept")
	await _wait_holstered()
	btns = tc.call("buttons")
	_ok(not btns.has("fire"), "fire hidden when holstered")
	hud.call("set_touch_ui", false)


func _check_fist_follow() -> void:
	var organs: Node = player.call("get_organs")
	_ok(organs != null, "organs present")
	if organs == null:
		return
	organs.call("set_interact_mode", "fist")
	if organs.get("tools") and organs.get("tools").has_method("set_fist_enabled"):
		organs.get("tools").call("set_fist_enabled", true)
		organs.get("tools").set("fist_stir", true)
		organs.get("tools").set("fist_gut", 1.2)
	if organs.has_method("set_tool_depth01"):
		organs.call("set_tool_depth01", 0.72)
	elif organs.get("tools") and organs.get("tools").has_method("fist_set_depth01"):
		organs.get("tools").call("fist_set_depth01", 0.72)
	await _frames(8)
	await _phys(4)
	var dbg: Dictionary = organs.call("fist_deform_debug") if organs.has_method("fist_deform_debug") else {}
	_ok(bool(dbg.get("enabled", false)), "fist enabled for deform")
	_ok(float(dbg.get("depth", 0.0)) > 0.05, "fist has depth (%.3f)" % float(dbg.get("depth", 0.0)))
	_ok(float(dbg.get("reach", 0.0)) > 0.02 or float(dbg.get("rod_reach_s", 0.0)) > 0.02, "fist rod reach is live")
	var sh := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	_ok(sh.find("if (is_gut)") >= 0 and sh.find("belly * 0.95") >= 0, "guts follow 95% of belly offset")


func _check_hit_force() -> void:
	_ok(settings != null, "GameSettings present")
	if settings == null:
		return
	_ok(settings.get("hit_force") != null, "hit_force setting exists")
	settings.call("set_hit_force", 1.0)
	var def := float(settings.get("hit_force"))
	_ok(def > 0.9 and def < 1.1, "default hit force is 1.0 (%.2f)" % def)
	main.call("spawn_clone", player.global_position + Vector3(0.2, 0.0, -0.7))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone for force test")
	if clones.is_empty():
		return
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0.1, 1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(4)
	var rag: Node = c.call("get_ragdoll")
	settings.call("set_hit_force", 0.4)
	var lo: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, Vector3(0, 0, 1))
	settings.call("set_hit_force", 1.8)
	var hi: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, Vector3(0, 0, 1))
	_ok(hi.length() > lo.length() * 2.0, "hit force scales impulse (lo=%.2f hi=%.2f)" % [lo.length(), hi.length()])
	# 默认（1.0）应明显强于 0.2.11 的 8.5 系数：14 * 1.0 > 8.5
	settings.call("set_hit_force", 1.0)
	var mid: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, Vector3(0, 0, 1))
	_ok(mid.length() > 10.0, "default rifle impulse stronger than 0.2.11 (%.2f)" % mid.length())


func _check_sprint_cone() -> void:
	player.call("set_play_mode", 1)  # control / FP
	_open_space()
	await _frames(4)
	await _phys(2)
	player.set("touch_move", Vector2(1.0, 0.0))  # pure strafe
	player.set("touch_sprint", true)
	player.set("input_locked", false)
	await _phys(8)
	await _frames(2)
	var spd := Vector2(player.velocity.x, player.velocity.z).length()
	_ok(spd < float(player.get("sprint_speed")) * 0.7, "sideways stick does not sprint (spd=%.2f)" % spd)
	var loco: Node = player.call("get_loco")
	if loco:
		var clip := str(loco.call("pick_clip", 0.0, 1.0, 1.0, false, true))
		_ok(clip == "walkRight" or clip == "walkLeft" or not clip.begins_with("run"), "side pick is walk, not run (%s)" % clip)
	player.set("touch_move", Vector2(0.0, -1.0))
	player.set("touch_sprint", true)
	await _phys(10)
	spd = Vector2(player.velocity.x, player.velocity.z).length()
	_ok(spd > float(player.get("move_speed")) * 1.2, "forward sprint still allowed (spd=%.2f)" % spd)
	player.set("touch_move", Vector2.ZERO)
	player.set("touch_sprint", false)
	player.velocity = Vector3.ZERO


func _check_map_touch_path() -> void:
	main.call("open_overhead")
	await _frames(6)
	var mv: Node = main.get("map_view")
	_ok(mv != null and bool(mv.get("is_open")), "overhead map opens")
	var catcher: Control = hud.find_child("MapInputCatcher", true, false)
	_ok(catcher != null, "MapInputCatcher is in the HUD tree")
	_ok(catcher != null and catcher.mouse_filter == Control.MOUSE_FILTER_STOP, "catcher uses STOP so touch reaches GUI")
	mv.set("marker", null)
	var pan0: Vector2 = mv.get("pan")
	# 走和真机相同的 Viewport.push_input 触控路径，而不是直接 handle_input。
	var p0 := Vector2(640, 360)
	var p1 := Vector2(760, 430)
	_push_touch(true, p0)
	await _frames(1)
	_push_drag(p1, p1 - p0)
	await _frames(1)
	_push_touch(false, p1)
	await _frames(2)
	var pan1: Vector2 = mv.get("pan")
	_ok(pan1.distance_to(pan0) > 1.0, "push_input single-finger drag pans map (%s → %s)" % [pan0, pan1])
	_ok(mv.get("marker") == null, "drag does not set a teleport point")
	# tap
	var tpos := Vector2(620, 340)
	_push_touch(true, tpos)
	await _frames(1)
	_push_touch(false, tpos)
	await _frames(2)
	_ok(mv.get("marker") != null, "push_input tap sets teleport point (%s)" % str(mv.get("marker")))
	main.call("close_overhead")
	await _frames(2)


func _check_drag() -> void:
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
	player.velocity = Vector3.ZERO
	await _phys(2)
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(bool(drag.call("is_holstered")), "player is holstered")
	_ok(bool(drag.call("can_start")), "can start when holstered and in pick range")
	# 选的范围比手臂长：1.6m 应能选到，但不能一上来按手臂长抓住
	var mid: Vector3 = chest + Vector3(1.6, 0, 0)
	drag.call("debug_aim", c, "C_Spine_c", mid)
	_ok(bool(drag.call("can_start")), "can select a corpse beyond arm length (1.6m)")
	_ok(float(drag.call("pick_range")) > float(drag.call("arm_length")) + 1.0, "pick range is longer than arm")
	# 持枪时不能拖
	await _ready_gun("pistol")
	drag.call("debug_aim", c, "C_Spine_c", chest)
	_ok(not bool(drag.call("can_start")), "cannot start drag while armed")
	await _wait_holstered()
	drag.call("debug_aim", c, "C_Spine_c", chest)
	var p0: Vector3 = chest
	_ok(bool(player.call("toggle_corpse_drag")), "toggle starts drag")
	_ok(bool(drag.get("reaching")) or bool(drag.call("is_dragging")), "starts in reach or hold")
	# 让手和点靠拢
	for _i in range(48):
		drag.call("physics_tick", 0.016)
		await _phys(1)
		if not bool(drag.get("reaching")):
			break
	_ok(bool(drag.call("is_dragging")), "still dragging after reach ticks")
	_ok(not bool(drag.get("reaching")), "reach completed, hold started")
	var p1: Vector3 = drag.call("current_grab_point")
	# 转视角应把尸体拉起来
	if player.has_method("fp_view_transform") or true:
		player._yaw = float(player.get("_yaw")) + 0.6
		player._pitch = float(player.get("_pitch")) - 0.25
		if player.has_method("_apply_camera"):
			player.call("_apply_camera")
		for _j in range(10):
			drag.call("physics_tick", 0.016)
			await _phys(1)
	var p2: Vector3 = drag.call("current_grab_point")
	_ok(p2.distance_to(p1) > 0.05 or p2.distance_to(p0) > 0.08, "view move pulls the ragdoll (d=%.3f)" % p2.distance_to(p1))
	# 触屏关：HUD 按钮应出现在开火键位置
	hud.call("set_touch_ui", false)
	if hud.has_method("_refresh_corpse_drag_btn"):
		hud.call("_refresh_corpse_drag_btn")
	var btn: Button = hud.find_child("CorpseDragButton", true, false)
	_ok(btn != null and btn.visible and btn.text == "放下", "PC drag button visible at fire-slot while dragging")
	player.call("toggle_corpse_drag")
	# 皮肤抓取 API
	_ok(drag.has_method("update_aim"), "update_aim can pick skin")
	_ok("SKIN_RADIUS" in FileAccess.get_file_as_string("res://scripts/corpse_drag.gd"), "skin radius used")


func _check_bump_stomp() -> void:
	# 活体分身胶囊应挡住玩家
	player.call("set_play_mode", 1)
	_open_space()
	await _phys(4)
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0.0, -0.7))
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	var live: Node = null
	for c in clones:
		if not bool(c.call("is_dead")):
			live = c
			break
	_ok(live != null, "living clone for bump")
	if live == null:
		return
	_ok(is_equal_approx(float(live.call("get_max_hp")), 100.0), "clone still defaults to 100 HP")
	# 等落地，避免掉出地图后胶囊对不上。
	if absf(live.global_position.y - player.global_position.y) > 0.6:
		live.global_position = player.global_position + Vector3(0.0, 0.0, -0.7)
		await _phys(3)
	var start: Vector3 = player.global_position
	# 朝分身走
	var toward: Vector3 = live.global_position - player.global_position
	toward.y = 0
	if toward.length() > 0.01:
		player.velocity = toward.normalized() * 3.0
	for _i in range(16):
		await _phys(1)
	var traveled := Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
	var gap := Vector2(player.global_position.x - live.global_position.x, player.global_position.z - live.global_position.z).length()
	_ok(gap > 0.35, "player capsule does not pass through clone (gap=%.3f traveled=%.3f)" % [gap, traveled])
	player.velocity = Vector3.ZERO
	# 踩踏：弄死它，站上去
	live.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, -1, 0), "entry": live.global_position + Vector3(0, 1, 0), "par": {"impulse": 0.3, "category": "pistol"}})
	await _phys(6)
	var rag: Node = live.call("get_ragdoll")
	var follow: Vector3 = rag.call("get_follow_point")
	var p0 := follow
	player.global_position = Vector3(follow.x, follow.y + 0.02, follow.z)
	player.velocity = Vector3(1.2, -1.0, 0.4)
	for _j in range(12):
		if player.has_method("_stomp_ragdolls"):
			player.call("_stomp_ragdolls", 0.016)
		await _phys(1)
	var p1: Vector3 = rag.call("get_follow_point")
	var spd := float(rag.call("max_linear_speed")) if rag.has_method("max_linear_speed") else 0.0
	_ok(p1.distance_to(p0) > 0.03 or spd > 0.15, "stomping shoves the ragdoll (move=%.3f spd=%.2f)" % [p1.distance_to(p0), spd])


func _check_observe_fire() -> void:
	_open_space()
	player.call("set_play_mode", 0)  # display / observe
	await _frames(4)
	await _ready_gun("pistol")
	var ammo0: Vector2i = ws.call("ammo_of", "pistol")
	var cam: Camera3D = player.call("get_camera")
	# 把分身放到观察相机正前方，避免被玩家身体或城市场景挡住射线。
	var in_front: Vector3 = cam.global_position + (-cam.global_transform.basis.z) * 2.6 + cam.global_transform.basis.y * -0.2
	in_front.y = maxf(0.0, in_front.y)
	main.call("spawn_clone", in_front)
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	var aim_at: Vector3 = c.global_position + Vector3(0, 1.15, 0)
	if cam.is_position_behind(aim_at):
		# 再往相机前挪一点
		c.global_position = cam.global_position + (-cam.global_transform.basis.z) * 2.4
		await _phys(1)
		aim_at = c.global_position + Vector3(0, 1.15, 0)
	var sp: Vector2 = cam.unproject_position(aim_at)
	_ok(bool(player.call("observe_tap_fire", sp)), "observe tap on a character fires")
	var ammo1: Vector2i = ws.call("ammo_of", "pistol")
	_ok(ammo1.x == ammo0.x - 1, "tap-fire consumes one round (%d → %d)" % [ammo0.x, ammo1.x])
	# 0.2.13：点击任意位置沿视线向内射击，不再要求点中人物。
	var ammo2: Vector2i = ammo1
	_ok(bool(player.call("observe_tap_fire", Vector2(8, 8))), "tap on empty space still fires inward")
	_ok(ws.call("ammo_of", "pistol").x == ammo2.x - 1, "empty-space tap consumes one round")
	ws.call("holster")


func _check_cover() -> void:
	main.call("spawn_clone", player.global_position + Vector3(0.4, 0.0, -0.8))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	if bool(c.call("is_dead")):
		return
	var hr: Node = c.call("get_hit_reaction")
	var belly: Vector3 = c.global_position + Vector3(0, 1.05, 0.08)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": belly})
	await _phys(3)
	await _frames(2)
	_ok(hr != null and bool(hr.call("is_covering")), "unarmed clone covers an organ hit")
	var p0: Vector3 = hr.get("cover_point")
	var belly2: Vector3 = belly + Vector3(0.08, 0.04, 0.0)
	c.call("apply_damage", 10.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": belly2})
	await _phys(2)
	var p1: Vector3 = hr.get("cover_point")
	_ok(p1.distance_to(p0) > 0.02, "new organ hit updates the covered point")
	# 持枪的玩家不捂（至少在持枪时）
	await _ready_gun("pistol")
	var phr: Node = player.get_node_or_null("HitReaction")
	if phr and player.has_method("apply_damage"):
		player.call("apply_damage", 8.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": player.global_position + Vector3(0, 1.05, 0.08)})
		await _phys(2)
		_ok(not bool(phr.call("is_covering")), "armed player does not cover")
	ws.call("holster")


func _check_bullet_mesh() -> void:
	var bal: Node = ws.get("ballistics")
	_ok(bal != null, "ballistics present")
	_ok(float(bal.get("MESH_CAM_DIST")) >= 0.5, "near-camera hide distance is set")
	var cam: Camera3D = player.call("get_camera")
	if bal.has_method("_mesh_far_enough") and cam:
		var near: bool = bool(bal.call("_mesh_far_enough", cam.global_position + (-cam.global_transform.basis.z) * 0.2))
		var far: bool = bool(bal.call("_mesh_far_enough", cam.global_position + (-cam.global_transform.basis.z) * 2.0))
		_ok(not near, "mesh hidden close to camera")
		_ok(far, "mesh visible after leaving the camera")
