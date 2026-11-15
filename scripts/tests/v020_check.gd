extends SceneTree
## 0.2.0 行为自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/v020_check.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v020: OK   ", msg)
	else:
		fails += 1
		push_error("v020: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)

	# ---- 着色器：Mobile 安全（无 SSS/CLEARCOAT 写入；挖孔走 alpha scissor）
	var organ_src := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	var skin_src := FileAccess.get_file_as_string("res://shaders/skin_xray.gdshader")
	_ok(organ_src.find("SSS_STRENGTH") < 0 and organ_src.find("CLEARCOAT") < 0, "organ shader has no SSS/CLEARCOAT")
	_ok(skin_src.find("ALPHA_SCISSOR_THRESHOLD") >= 0, "skin_xray uses ALPHA_SCISSOR")
	_ok(skin_src.find("discard") < 0, "skin_xray hole no longer uses discard")

	# ---- 公开名称
	_ok(str(ProjectSettings.get_setting("application/config/name")) == "蒂法玉腹沙盒", "project display name")

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	_ok(ws != null and player != null, "scene booted")

	# ---- 灵敏度分离
	_ok(is_equal_approx(float(player.get("mouse_sensitivity")), 0.0025), "PC mouse default 0.0025")
	_ok(is_equal_approx(float(player.get("touch_look_sensitivity")), 0.014), "mobile swipe default 0.014")
	_ok(bool(player.get("ads_toggle")), "ADS default toggle")
	var yaw0: float = player.get("_yaw")
	player.call("touch_look", Vector2(100, 0))
	var dyaw := absf(float(player.get("_yaw")) - yaw0)
	_ok(dyaw > 1.1 and dyaw < 1.7, "touch look uses mobile default (Δ=%.3f)" % dyaw)
	player.set("mouse_sensitivity", 0.01)
	yaw0 = player.get("_yaw")
	player.call("touch_look", Vector2(100, 0))
	var dyaw2 := absf(float(player.get("_yaw")) - yaw0)
	_ok(absf(dyaw2 - dyaw) < 0.05, "touch look independent of mouse sens")
	player.call("set_mouse_sensitivity", 0.0025)

	# ---- 方向
	player.call("set_play_mode", 1)
	await _frames(2)
	_ok(str(player.get("screen_orientation_request")) == "landscape", "FP requests landscape")
	player.call("set_play_mode", 0)
	await _frames(2)
	_ok(str(player.get("screen_orientation_request")) == "sensor", "observe allows portrait/sensor")

	# ---- 触屏布局
	hud.call("set_touch_ui", true)
	await _frames(3)
	var tc: Control = hud.get("_touch")
	_ok(tc != null, "touch ui exists")
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	await _frames(6)
	var bs: Dictionary = tc.call("buttons")
	var mode_r: Rect2 = bs["mode"][0]
	_ok(mode_r.position.y <= 16.0, "mode button at top edge (y=%.1f)" % mode_r.position.y)
	var jump_r: Rect2 = bs["jump"][0]
	var crouch_r: Rect2 = bs["crouch"][0]
	_ok(jump_r.position.y < crouch_r.position.y - 20.0, "jump is above crouch (swapped)")
	var weapon_r: Rect2 = bs["weapon"][0]
	_ok(weapon_r.position.x < jump_r.position.x - 40.0, "weapon button inward from right edge")
	_ok(weapon_r.position.y + 8.0 >= crouch_r.position.y, "weapon button sits low")
	_ok(bs.has("ads") and bs.has("fire"), "ADS + fire present when armed")
	var fire_r: Rect2 = bs["fire"][0]
	var ads_r: Rect2 = bs["ads"][0]
	_ok(not fire_r.intersects(ads_r), "ADS does not overlap fire")
	_ok(fire_r.size.x >= 44.0 and ads_r.size.x >= 44.0 and weapon_r.size.x >= 44.0, "targets >= 44px")
	var ammo: Control = hud.get("_wui").get("ammo_box") if hud.get("_wui") else null
	if ammo:
		var ac := ammo.get_global_rect()
		_ok(absf(ac.get_center().x - 640.0) < 120.0, "ammo HUD near horizontal center (x=%.0f)" % ac.get_center().x)
		_ok(ac.end.y > 720.0 - 80.0, "ammo HUD at bottom edge (bottom=%.0f)" % ac.end.y)

	# FOV bar gated
	_ok((tc.call("zoom_rect") as Rect2).size.y < 1.0, "FOV bar hidden by default")
	hud.call("_toggle_panel", 3)
	await _frames(2)
	_ok((tc.call("zoom_rect") as Rect2).size.y > 80.0, "FOV bar visible with camera panel")
	hud.call("_close_all_panels")
	await _frames(1)
	_ok((tc.call("zoom_rect") as Rect2).size.y < 1.0, "FOV bar hidden after close")

	# 观察：开火键隐藏，枪仍在手里
	player.call("set_play_mode", 0)
	await _frames(5)
	_ok(bool(ws.get("view").visible) and bool(ws.call("is_armed")), "gun stays out in observe")
	bs = tc.call("buttons")
	_ok(not bs.has("fire") and not bs.has("ads"), "fire/ADS hidden in observe")
	player.call("set_play_mode", 1)
	await _frames(4)

	# ---- 视模型间隙 + 手不离枪
	for id in ws.call("weapon_ids"):
		ws.call("select", id)
		ws.call("debug_finish_state")
		ws.call("set_ads", false)
		await _frames(6)
		var ahead: float = float(ws.call("debug_muzzle_ahead"))
		_ok(ahead >= 0.06, "%s muzzle >= 6cm past near plane (%.3f m)" % [id, ahead])
		_ok(not bool(ws.call("debug_center_hits_viewmodel")), "%s hip-fire does not cover crosshair" % id)
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	var g0: Dictionary = {}
	for i in 50:
		await process_frame
		g0 = ws.call("debug_hand_to_gun")
		if float(g0.get("R", 99.0)) < 0.06:
			break
	_ok(float(g0.get("R", 99.0)) < 0.06 and float(g0.get("L", 99.0)) < 0.08, "hands on gun at idle %s" % g0)
	player.set("touch_active", true)
	player.set("touch_move", Vector2(0, 1))
	player.set("touch_sprint", true)
	for i in 40:
		await process_frame
	var g1: Dictionary = ws.call("debug_hand_to_gun")
	_ok(float(g1.get("R", 99.0)) < 0.06 and float(g1.get("L", 99.0)) < 0.10, "hands stay on gun while sprinting %s" % g1)
	player.set("touch_move", Vector2.ZERO)
	player.set("touch_sprint", false)

	# ---- 抛弹匣（步枪有，霰弹跳过）
	var cas: Node = ws.get("casings")
	cas.call("clear_all")
	ws.call("debug_set_ammo", "rifle", 10, 30)
	ws.call("select", "rifle")
	ws.call("debug_finish_state")
	await _frames(3)
	_ok(bool(ws.call("reload")), "rifle reload starts")
	await _frames(4)
	var kinds: PackedStringArray = cas.call("live_kinds")
	var has_mag := false
	for k in kinds:
		if str(k).begins_with("mag_rifle"):
			has_mag = true
	_ok(has_mag, "rifle ejects physical mag (%s)" % [kinds])
	cas.call("clear_all")
	ws.call("debug_set_ammo", "shotgun", 3, 10)
	ws.call("select", "shotgun")
	ws.call("debug_finish_state")
	await _frames(3)
	ws.call("reload")
	await _frames(4)
	kinds = cas.call("live_kinds")
	var has_sg := false
	for k2 in kinds:
		if str(k2).begins_with("mag_"):
			has_sg = true
	_ok(not has_sg, "shotgun does not eject a magazine")

	hud.call("set_touch_ui", false)
	print("v020_check: fails=%d" % fails)
	quit(1 if fails > 0 else 0)
