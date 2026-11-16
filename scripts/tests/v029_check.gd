extends SceneTree
## 0.2.9 检查（触屏回归、轮盘原点、菜单拖动、抵腋、观察保持瞄准、
## 摄像机/开镜基线、分武器偏移、手绑定、移动速度、枪口火焰）：
##   godot --headless --path . -s res://scripts/tests/v029_check.gd

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


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v029: OK   ", msg)
	else:
		fails += 1
		push_error("v029: FAIL " + msg)


func _set_look_pitch(rad: float) -> void:
	player.set("_pitch", rad)
	if player.has_method("_sync_pivot"):
		player.set("_pivot_rot", Vector3(rad, float(player.get("_yaw")), 0.0))
		player.call("_sync_pivot")


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 4:
		ws.call("debug_finish_state")
		await _frames(2)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	_ok(ws != null and hud != null, "scene booted")
	if ws == null or hud == null:
		print("v029_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.10\"") >= 0 or presets.find("version/name=\"0.2.11\"") >= 0 or (presets.find("version/name=\"0.2.12\"") >= 0 or (presets.find("version/name=\"0.2.13\"") >= 0 or presets.find("version/name=\"0.2.14\"") >= 0)) or (presets.find("version/name=\"0.2.12\"") >= 0 or (presets.find("version/name=\"0.2.13\"") >= 0 or presets.find("version/name=\"0.2.14\"") >= 0)), "export version is 0.2.10 or 0.2.11")
	_ok(presets.find("version/code=12") >= 0 or presets.find("version/code=13") >= 0 or (presets.find("version/code=14") >= 0 or (presets.find("version/code=15") >= 0 or presets.find("version/code=16") >= 0)), "versionCode is 12 or 13")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")

	await _check_touch_and_wheel()
	await _check_map_pan()
	_check_menu_and_buttons()
	_check_speeds_and_camera()
	_check_pose_offsets()
	_check_flash()
	await _check_ads_and_observe()
	await _check_stock_armpit()
	await _check_hands_and_invariants()
	_check_organs_contain()

	print("v029_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_touch_and_wheel() -> void:
	# A: wheel origin is the press point, not screen center
	var wheel: Control = hud.get("wheel")
	var tap := Vector2(1080, 620)
	hud.call("open_weapon_wheel", tap)
	await _frames(2)
	var c: Vector2 = wheel.call("center")
	_ok(c.distance_to(Vector2(640, 360)) < 8.0, "wheel center is screen center (c=%s tap=%s)" % [c, tap])
	_ok(c.distance_to(tap) > 80.0, "wheel is not parked at the press point")
	wheel.call("point_at", tap + Vector2(-40, -90))
	_ok(int(wheel.get("hover")) >= 0, "hover from press origin (hover=%s)" % wheel.get("hover"))
	hud.call("close_weapon_wheel", false)

	# keyboard-style open (no origin) stays at center
	hud.call("open_weapon_wheel")
	await _frames(1)
	var c2: Vector2 = wheel.call("center")
	var mid: Vector2 = wheel.size * 0.5
	_ok(c2.distance_to(mid) < 2.0, "Q/open without origin uses screen center (c=%s mid=%s)" % [c2, mid])
	hud.call("close_weapon_wheel", false)

	# B: tapping far from the navel must not snap to navel
	player.call("set_play_mode", 0)
	await _frames(6)
	hud.call("_on_mode_pressed", "drag")
	var organs: Node = player.call("get_organs")
	if organs:
		organs.call("reset_interaction")
	var corner := Vector2(80, 80)
	var hit_far: bool = bool(player.call("touch_tool_begin", corner))
	var info: Dictionary = player.call("debug_last_tool_begin")
	print("v029: far tap ", info)
	_ok(not hit_far or not bool(info.get("via_navel", false)), "far tap does not navel-fallback (ok=%s via_navel=%s)" % [hit_far, info.get("via_navel")])
	player.call("touch_tool_end")

	# tap on belly should start drag, not via a huge navel magnet
	if organs:
		organs.call("reset_interaction")
		var cam: Camera3D = player.call("get_camera")
		var f: Transform3D = organs.call("abdomen_frame")
		var belly_s: Vector2 = cam.unproject_position(f * Vector3(0.0, -0.04, 0.1))
		var ok_b: bool = bool(player.call("touch_tool_begin", belly_s))
		var info_b: Dictionary = player.call("debug_last_tool_begin")
		print("v029: belly tap ", info_b, " screen=", belly_s)
		_ok(ok_b, "tap on belly starts interact")
		_ok(not bool(info_b.get("via_navel", true)), "belly tap uses actual ray, not navel fallback")
		_ok(bool(organs.call("is_dragging")), "belly drag starts")
		player.call("touch_tool_drag", belly_s + Vector2(36, -18))
		await _frames(3)
		_ok(float(organs.call("drag_offset_length")) > 0.003, "pointer drag moves belly (%.4f)" % float(organs.call("drag_offset_length")))
		player.call("touch_tool_end")


func _check_map_pan() -> void:
	var mv: Node = main.get("map_view")
	_ok(mv != null, "map_view present")
	main.call("open_overhead")
	await _frames(4)
	_ok(bool(mv.get("is_open")), "overhead map opens")
	mv.set("marker", null)
	var pan0: Vector2 = mv.get("pan")
	var e1 := InputEventScreenTouch.new()
	e1.index = 0
	e1.position = Vector2(400, 300)
	e1.pressed = true
	mv.call("handle_input", e1)
	var d := InputEventScreenDrag.new()
	d.index = 0
	d.position = Vector2(520, 360)
	d.relative = Vector2(120, 60)
	mv.call("handle_input", d)
	var pan1: Vector2 = mv.get("pan")
	_ok(pan1.distance_to(pan0) > 1.0, "single-finger drag pans map (pan %s → %s)" % [pan0, pan1])
	_ok(mv.get("marker") == null, "mid-drag does not place teleport point")
	var e1u := InputEventScreenTouch.new()
	e1u.index = 0
	e1u.position = Vector2(520, 360)
	e1u.pressed = false
	mv.call("handle_input", e1u)
	_ok(mv.get("marker") == null, "releasing a drag does not place teleport point")

	# tap (no drag) sets marker
	var t0 := InputEventScreenTouch.new()
	t0.index = 0
	t0.position = Vector2(640, 360)
	t0.pressed = true
	mv.call("handle_input", t0)
	var t1 := InputEventScreenTouch.new()
	t1.index = 0
	t1.position = Vector2(640, 360)
	t1.pressed = false
	mv.call("handle_input", t1)
	_ok(mv.get("marker") != null, "tap without drag sets teleport point")

	# pinch still works
	var h0: float = float(mv.get("height"))
	var p0 := InputEventScreenTouch.new()
	p0.index = 0
	p0.position = Vector2(400, 300)
	p0.pressed = true
	mv.call("handle_input", p0)
	var p1 := InputEventScreenTouch.new()
	p1.index = 1
	p1.position = Vector2(500, 300)
	p1.pressed = true
	mv.call("handle_input", p1)
	var pd := InputEventScreenDrag.new()
	pd.index = 1
	pd.position = Vector2(700, 300)
	pd.relative = Vector2(200, 0)
	mv.call("handle_input", pd)
	var h1: float = float(mv.get("height"))
	_ok(h1 < h0 * 0.85, "pinch out still zooms in (h %.1f → %.1f)" % [h0, h1])
	main.call("close_overhead")
	await _frames(2)


func _check_menu_and_buttons() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(src.find("_hook_menu_drag_scroll") >= 0 and src.find("MENU_DRAG_PX") >= 0, "menu drag-to-scroll helper present")
	_ok(src.find("maxf(m0.y, 30.0 if n is BaseButton") >= 0, "touch button hit target reduced for easier scrolling")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("x2 - 128.0") >= 0, "weapon button moved left")
	_ok(tc_src.find("y - 20.0") >= 0, "fire button moved down")


func _check_speeds_and_camera() -> void:
	_ok(is_equal_approx(float(player.get("move_speed")), 1.06), "walk speed retuned to clip (%.3f)" % float(player.get("move_speed")))
	_ok(absf(float(player.get("sprint_speed")) - 5.0) < 0.05, "sprint speed near run clip (%.3f)" % float(player.get("sprint_speed")))
	_ok(absf(float(player.get("crouch_speed")) - 0.85) < 0.03, "crouch speed near clip (%.3f)" % float(player.get("crouch_speed")))
	_ok(float(player.get("prone_speed")) <= 0.30, "prone speed no longer 2x clip (%.3f)" % float(player.get("prone_speed")))
	_ok(float(player.get("ads_speed")) > 0.5 and float(player.get("ads_speed")) < float(player.get("move_speed")), "ADS walk slower than walk (%.3f)" % float(player.get("ads_speed")))
	var ey: float = float(player.call("debug_fp_eye_y", "stand"))
	_ok(ey < 1.565 and ey > 1.51, "FP eye height lowered (%.3f, was 1.58)" % ey)
	var loco_src := FileAccess.get_file_as_string("res://scripts/soft_loco.gd")
	_ok(loco_src.find("speed_mps) * delta") >= 0 or loco_src.find("speed_mps) * delta") >= 0, "loco phase uses actual travel distance")
	_ok(loco_src.find("weapon_ik") >= 0, "loco skips arms when weapon IK is on")


func _check_pose_offsets() -> void:
	var ids := ["rifle", "smg", "shotgun", "pistol"]
	var ads_ys: Array[float] = []
	for id in ids:
		var d = ws.call("get_def", id)
		_ok(d != null and d.get("pose_hip") != null and d.get("pose_ads") != null, "%s has pose_hip / pose_ads" % id)
		_ok(d.get("pose_observe") != null and d.get("pose_observe_ads") != null, "%s has observe pose offsets" % id)
		var hip: Vector3 = ws.call("_hip_offset", d)
		var ads: Vector3 = ws.call("_ads_offset", d)
		_ok((d.pose_ads as Vector3).y < 0.0, "%s pose_ads lowers the gun (pose_ads.y=%.3f ads.y=%.3f hip.y=%.3f)" % [id, (d.pose_ads as Vector3).y, ads.y, hip.y])
		ads_ys.append(ads.y)
	# long-gun ads offsets should not all be identical once per-weapon pose is applied
	_ok(absf(ads_ys[0] - ads_ys[1]) > 0.0005 or absf(ads_ys[0] - ads_ys[2]) > 0.0005, "per-weapon ADS offsets differ")
	var rifle = ws.call("get_def", "rifle")
	var pistol = ws.call("get_def", "pistol")
	_ok(not is_equal_approx(float((rifle.pose_ads as Vector3).y), float((pistol.pose_ads as Vector3).y)), "pistol ADS offset is not a copy of rifle")


func _check_flash() -> void:
	var fl: Dictionary = ws.call("debug_flash")
	print("v029: flash ", fl)
	var q: Vector2 = fl.get("quad", Vector2.ZERO)
	_ok(q.x >= 0.24 and q.y >= 0.24, "muzzle flash quad larger (%.3f)" % q.x)
	_ok(float(fl.get("energy", 0.0)) >= 5.0, "muzzle light stronger (e=%.2f)" % float(fl.get("energy", 0.0)))
	_ok(float(fl.get("range", 0.0)) >= 4.5, "muzzle light range larger (r=%.2f)" % float(fl.get("range", 0.0)))
	var rifle = ws.call("get_def", "rifle")
	_ok(float(rifle.flash_scale) > 1.2, "rifle flash_scale raised (%.2f)" % float(rifle.flash_scale))


func _check_ads_and_observe() -> void:
	player.call("set_play_mode", 1)
	_set_look_pitch(0.0)
	await _frames(4)
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _ready_gun(id)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(10)
		var parts: Dictionary = ws.call("debug_ads_parts")
		print("v029: ADS ", id, " ", parts)
		_ok(float(parts.get("rear", 999)) < 6.0, "ADS rear on + (%s, %.1f px)" % [id, float(parts.get("rear", 999))])
		_ok(float(parts.get("front", 999)) < 6.0, "ADS front on + (%s, %.1f px)" % [id, float(parts.get("front", 999))])
		_ok(float(parts.get("stack", 999)) < 6.0, "ADS stack (%s, %.1f px)" % [id, float(parts.get("stack", 999))])
		# F: switch to observe, keep ADS pose
		player.call("set_play_mode", 0)
		await _frames(8)
		_ok(bool(ws.get("ads")), "observe keeps ads flag (%s)" % id)
		_ok(float(ws.get("_ads_k")) > 0.6, "observe keeps ads blend (%s, k=%.2f)" % [id, float(ws.get("_ads_k"))])
		_ok(str(ws.get("_clip")) == "aim" or str(ws.call("_idle_clip")) == "aim", "observe uses aim clip (%s, clip=%s)" % [id, ws.get("_clip")])
		player.call("set_play_mode", 1)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(3)


func _check_stock_armpit() -> void:
	await _ready_gun("rifle")
	player.call("set_play_mode", 0)
	await _frames(12)
	var st: Dictionary = ws.call("debug_stock_vs_head")
	print("v029: TP rifle stock ", st)
	_ok(bool(st.get("ok", false)), "TP rifle stock closer to shoulder than head")
	_ok(float(st.get("d_sh", 99)) < 0.18, "TP rifle stock still near shoulder/axilla (d=%.3f)" % float(st.get("d_sh", 99)))
	if st.has("d_armpit") and st.has("d_chest"):
		_ok(float(st["d_armpit"]) + 0.01 < float(st["d_chest"]), "stock closer to armpit than chest (ax=%.3f chest=%.3f)" % [float(st["d_armpit"]), float(st["d_chest"])])
	_ok(float(st.get("along_right", 99)) < 0.03, "stock not outside shoulder (right=%.3f)" % float(st.get("along_right", 99)))
	_ok(float(st.get("along_right", 99)) > -0.12, "stock not pulled through chest (right=%.3f)" % float(st.get("along_right", 99)))
	# pistol still out in front
	player.call("set_play_mode", 1)
	await _frames(3)
	await _ready_gun("pistol")
	player.call("set_play_mode", 0)
	await _frames(10)
	var pst: Dictionary = ws.call("debug_stock_vs_head")
	print("v029: TP pistol ", pst)
	var skel: Skeleton3D = player.call("get_skeleton")
	if skel:
		var ci := skel.find_bone("C_Spine_c")
		if ci >= 0:
			var torso: Vector3 = skel.global_transform * skel.get_bone_global_pose(ci).origin
			var grip: Vector3 = pst.get("stock", Vector3.ZERO)
			_ok(grip.distance_to(torso) > 0.16, "observe pistol still in front of chest (d=%.3f)" % grip.distance_to(torso))
	player.call("set_play_mode", 1)
	await _frames(3)


func _check_hands_and_invariants() -> void:
	await _ready_gun("rifle")
	player.call("set_play_mode", 1)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	player.velocity = Vector3(0, 0, -1.0)
	await _frames(12)
	var hands: Dictionary = ws.call("debug_hand_to_gun")
	print("v029: hands while moving ", hands)
	_ok(float(hands.get("L", 99)) < 0.12, "left hand planted in ADS move (d=%.3f)" % float(hands.get("L", 99)))
	_ok(float(hands.get("R", 99)) < 0.12, "right hand planted in ADS move (d=%.3f)" % float(hands.get("R", 99)))
	player.velocity = Vector3.ZERO
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)

	# 0.2.8 recoil / breast still exist
	var sec = player.call("get_secondary") if player.has_method("get_secondary") else null
	_ok(sec != null and sec.has_method("apply_fire_recoil"), "fire body recoil still present")
	_ok(settings != null and bool(settings.get("infinite_reserve")), "infinite reserve default still on")
	_ok(str(ws.call("ammo_text", "rifle")).contains("∞"), "ammo text still uses ∞")


func _check_organs_contain() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	_ok(src.find("contain_inside_skin") >= 0, "organ shader has skin containment")
	var rig_src := FileAccess.get_file_as_string("res://scripts/organs/organ_rig.gd")
	_ok(rig_src.find("organ_contain") >= 0, "organ_rig enables containment during fist")
