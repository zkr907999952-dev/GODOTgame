extends SceneTree
## 0.2.6：长枪开镜抵肩、霰弹腰射下调前伸、空弹匣按动画抛出、触屏默认灵敏度、
## 导出包含脏器数据。
##   godot --headless --path . -s res://scripts/tests/v026_check.gd

var main: Node
var player: Node
var hud: Node
var ws: Node
var organs: Node
var settings: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v026: OK   ", msg)
	else:
		fails += 1
		push_error("v026: FAIL " + msg)


func _set_look_pitch(rad: float) -> void:
	player.set("_pitch", rad)
	if player.has_method("_sync_pivot"):
		player.set("_pivot_rot", Vector3(rad, float(player.get("_yaw")), 0.0))
		player.call("_sync_pivot")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	organs = player.call("get_organs")
	settings = main.get_node_or_null("GameSettings")
	_ok(ws != null and organs != null, "scene booted")
	if ws == null or organs == null:
		print("v026_check: fails=", fails)
		quit(1)
		return

	# ---- export includes organ pack + new apk name / version
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("assets/organs/*.bin") >= 0 and presets.find("assets/organs/*.json") >= 0, "export include_filter has organs bin/json")
	_ok(presets.find("version/name=\"0.2.6\"") >= 0, "export version 0.2.6")
	_ok(presets.find("build/android/蒂法玉腹沙盒.apk") >= 0, "android export path uses new name")
	_ok(presets.find("build/android/rouchang.apk") < 0, "old rouchang.apk export path removed")
	_ok(FileAccess.file_exists("res://assets/organs/organs_mesh.bin"), "organs_mesh.bin present")
	_ok(FileAccess.file_exists("res://assets/organs/organs_meta.json"), "organs_meta.json present")

	# ---- touch default
	_ok(is_equal_approx(float(player.get("touch_look_sensitivity")), 0.014), "touch look default 0.014")
	var yaw0: float = player.get("_yaw")
	player.call("touch_look", Vector2(100, 0))
	var dyaw := absf(float(player.get("_yaw")) - yaw0)
	_ok(dyaw > 1.1 and dyaw < 1.7, "touch look step at new default (Δ=%.3f)" % dyaw)
	player.call("set_touch_look_sensitivity", 0.014)

	# ---- shotgun hip lower + more forward than generic long-gun
	var rifle_def = ws.call("get_def", "rifle")
	var shotgun_def = ws.call("get_def", "shotgun")
	var rh: Vector3 = ws.call("_hip_offset", rifle_def)
	var sh: Vector3 = ws.call("_hip_offset", shotgun_def)
	_ok(sh.y < rh.y - 0.03, "shotgun hip lower than rifle (sy=%.3f ry=%.3f)" % [sh.y, rh.y])
	_ok(sh.z < rh.z - 0.03, "shotgun hip farther forward than rifle (sz=%.3f rz=%.3f)" % [sh.z, rh.z])

	# ---- ADS: sights still on center; long-gun stock not over-extended
	player.call("set_play_mode", 1)
	if settings:
		settings.call("set_render_scale", 1.0)
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		ws.call("select", id)
		for i in 3:
			ws.call("debug_finish_state")
			await _frames(2)
		_set_look_pitch(0.0)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(10)
		var parts: Dictionary = ws.call("debug_ads_parts")
		print("v026: ADS ", id, " ", parts)
		var label := str(id)
		_ok(float(parts.get("rear", 999)) < 6.0, "ADS rear on + (%s, %.1f px)" % [label, float(parts.get("rear", 999))])
		_ok(float(parts.get("front", 999)) < 6.0, "ADS front on + (%s, %.1f px)" % [label, float(parts.get("front", 999))])
		_ok(float(parts.get("stack", 999)) < 6.0, "ADS stack (%s, %.1f px)" % [label, float(parts.get("stack", 999))])
		_ok(float(parts.get("axis_deg", 999)) < 0.5, "ADS axis (%s, %.2f deg)" % [label, float(parts.get("axis_deg", 999))])
		_ok(absf(float(parts.get("roll_deg", 999))) < 2.0, "ADS roll (%s, %.2f deg)" % [label, float(parts.get("roll_deg", 999))])
		if id != "pistol":
			# 枪托应靠近镜头平面（相机空间 z 接近 0），不应在 0.25m 以外
			_ok(float(parts.get("stock_cam_z", -99)) > -0.16, "ADS stock not over-extended (%s, z=%.3f)" % [label, float(parts.get("stock_cam_z", -99))])
			_ok(float(parts.get("d_shoulder", 99)) < 0.28, "ADS stock near shoulder (%s, d=%.3f)" % [label, float(parts.get("d_shoulder", 99))])
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(2)

	# ---- mag eject syncs with reload, not immediately
	ws.call("select", "rifle")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("debug_set_ammo", "rifle", 10, 90)
	var started := bool(ws.call("reload"))
	_ok(started, "rifle reload started")
	_ok(not bool(ws.call("debug_mag_ejected")), "empty mag not ejected at reload start")
	var due := float(ws.call("debug_mag_eject_at"))
	var dur := float(ws.get("state_len"))
	_ok(due > 0.08 and due < dur * 0.85, "eject time mid-reload (t=%.3f / %.3f)" % [due, dur])
	var steps := 0
	while not bool(ws.call("debug_mag_ejected")) and steps < 180:
		await process_frame
		steps += 1
	var at := float(ws.get("state_t"))
	_ok(bool(ws.call("debug_mag_ejected")), "mag ejected during reload")
	_ok(at + 0.02 >= due, "eject not earlier than detected frame (at=%.3f due=%.3f)" % [at, due])
	ws.call("debug_finish_state")
	await _frames(4)

	# pistol too
	ws.call("select", "pistol")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("debug_set_ammo", "pistol", 8, 40)
	_ok(bool(ws.call("reload")), "pistol reload started")
	_ok(not bool(ws.call("debug_mag_ejected")), "pistol mag not ejected at start")
	steps = 0
	while not bool(ws.call("debug_mag_ejected")) and steps < 180:
		await process_frame
		steps += 1
	_ok(bool(ws.call("debug_mag_ejected")), "pistol mag ejected during reload")
	ws.call("debug_finish_state")
	await _frames(2)

	# organs still follow in this session
	if organs.has_method("debug_skin_xray_state"):
		var xs: Dictionary = organs.call("debug_skin_xray_state")
		_ok(bool(xs.get("ok", false)), "skin_xray active")
	var f0: Transform3D = organs.call("abdomen_frame")
	player.global_position += Vector3(1.5, 0.0, 0.0)
	await _frames(6)
	var f1: Transform3D = organs.call("abdomen_frame")
	_ok(f0.origin.distance_to(f1.origin) > 0.8, "xray frame follows character (d=%.3f)" % f0.origin.distance_to(f1.origin))

	print("v026_check: fails=", fails)
	quit(1 if fails > 0 else 0)
