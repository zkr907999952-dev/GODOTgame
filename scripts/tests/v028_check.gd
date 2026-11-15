extends SceneTree
## 0.2.8：开火驱动身体后坐与乳摇；同时回归 0.2.7 开镜基线与观察抵肩。
##   godot --headless --path . -s res://scripts/tests/v028_check.gd

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
		print("v028: OK   ", msg)
	else:
		fails += 1
		push_error("v028: FAIL " + msg)


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


func _sec():
	return player.call("get_secondary") if player.has_method("get_secondary") else null


func _breasts():
	var sec = _sec()
	return sec.get("breasts") if sec else null


func _breast_metrics() -> Dictionary:
	var br = _breasts()
	var out := {"speed": 0.0, "disp": 0.0}
	if br == null:
		return out
	var st: Dictionary = br.call("debug_state")
	for side in ["L", "R"]:
		if not st.has(side):
			continue
		var s: Dictionary = st[side]
		out["speed"] = maxf(float(out["speed"]), float(s.get("speed", 0.0)))
		out["disp"] = maxf(float(out["disp"]), float(s.get("disp", 0.0)))
	return out


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
		print("v028_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	# version asserts filled after the bump; still require package id
	_ok(presets.find("version/name=\"0.2.8\"") >= 0, "export version is 0.2.8")
	_ok(presets.find("version/code=10") >= 0, "versionCode is 10")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("assets/organs/*.bin") >= 0, "organs include_filter present")

	var br = _breasts()
	_ok(br != null, "breast physics live")
	if br:
		_ok(bool(br.get("enabled")), "乳摇 default on")
		_ok(float(br.get("strength")) > 0.2, "乳摇强度 default > 0 (got %.2f)" % float(br.get("strength")))
		_ok(br.has_method("apply_impulse"), "BreastPhysics.apply_impulse exists")
	var sec = _sec()
	_ok(sec != null and sec.has_method("apply_fire_recoil"), "SoftSecondary.apply_fire_recoil exists")

	# ---- G: ADS iron sight baseline still holds (v027)
	player.call("set_play_mode", 1)
	_set_look_pitch(0.0)
	await _frames(4)
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _ready_gun(id)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(10)
		var parts: Dictionary = ws.call("debug_ads_parts")
		print("v028: ADS ", id, " ", parts)
		var label: String = str(id)
		_ok(float(parts.get("rear", 999)) < 6.0, "ADS rear on + (%s, %.1f px)" % [label, float(parts.get("rear", 999))])
		_ok(float(parts.get("front", 999)) < 6.0, "ADS front on + (%s, %.1f px)" % [label, float(parts.get("front", 999))])
		_ok(float(parts.get("stack", 999)) < 6.0, "ADS stack (%s, %.1f px)" % [label, float(parts.get("stack", 999))])
		_ok(float(parts.get("axis_deg", 999)) < 0.5, "ADS axis (%s, %.2f deg)" % [label, float(parts.get("axis_deg", 999))])
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(2)

	# ---- TP seating (v027)
	await _ready_gun("rifle")
	player.call("set_play_mode", 0)
	await _frames(10)
	var st: Dictionary = ws.call("debug_stock_vs_head")
	print("v028: TP rifle rest ", st)
	_ok(bool(st.get("ok", false)), "TP rifle stock closer to shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(st.get("d_sh", 99)), float(st.get("d_head", 99))])
	_ok(float(st.get("d_sh", 99)) < 0.16, "TP rifle stock near shoulder pocket (d=%.3f)" % float(st.get("d_sh", 99)))
	_ok(float(st.get("along_right", 99)) < 0.03, "TP rifle stock not outside shoulder (right=%.3f)" % float(st.get("along_right", 99)))
	player.call("set_play_mode", 1)
	await _frames(3)

	# ---- L: fire drives body recoil + breast impulse (FP and observe)
	for mode in [1, 0]:
		var mode_n := "FP" if mode == 1 else "observe"
		player.call("set_play_mode", mode)
		await _frames(6)
		for id in ["shotgun", "rifle", "smg", "pistol"]:
			await _ready_gun(id)
			ws.call("debug_set_ammo", id, 10, 40)
			if sec:
				sec.set("fire_recoil_pitch", 0.0)
				sec.set("fire_recoil_yaw", 0.0)
			await _frames(8)
			var pre := _breast_metrics()
			var pre_kick: Vector2 = sec.call("debug_fire_recoil") if sec else Vector2.ZERO
			_ok(bool(ws.call("debug_fire_once")), "%s %s fire started" % [mode_n, id])
			var kick_now: Vector2 = sec.call("debug_fire_recoil") if sec else Vector2.ZERO
			print("v028: ", mode_n, " ", id, " body kick=", kick_now, " pre breast=", pre)
			_ok(kick_now.length() > 0.01, "%s %s body/spine recoil term non-zero (k=%s pre=%s)" % [mode_n, id, kick_now, pre_kick])
			await _frames(3)
			var post := _breast_metrics()
			print("v028: ", mode_n, " ", id, " post breast=", post)
			var moved := float(post["speed"]) > float(pre["speed"]) + 0.04 or float(post["disp"]) > float(pre["disp"]) + 0.0015
			_ok(moved, "%s %s breast speed/disp increased (pre s=%.4f d=%.4f → s=%.4f d=%.4f)" % [mode_n, id, float(pre["speed"]), float(pre["disp"]), float(post["speed"]), float(post["disp"])])
			# settle a bit so next shot starts cleaner
			await _frames(4)

	# scale: shotgun body pitch > rifle > smg > pistol
	player.call("set_play_mode", 1)
	await _frames(3)
	var pitches := {}
	for id in ["shotgun", "rifle", "smg", "pistol"]:
		await _ready_gun(id)
		ws.call("debug_set_ammo", id, 8, 20)
		if sec:
			sec.set("fire_recoil_pitch", 0.0)
			sec.set("fire_recoil_yaw", 0.0)
		ws.call("debug_fire_once")
		pitches[id] = absf(float((sec.call("debug_fire_recoil") as Vector2).x)) if sec else 0.0
	print("v028: pitch scale ", pitches)
	_ok(float(pitches["shotgun"]) > float(pitches["rifle"]), "shotgun body kick > rifle (%.3f > %.3f)" % [float(pitches["shotgun"]), float(pitches["rifle"])])
	_ok(float(pitches["rifle"]) > float(pitches["smg"]), "rifle body kick > smg (%.3f > %.3f)" % [float(pitches["rifle"]), float(pitches["smg"])])
	_ok(float(pitches["smg"]) > float(pitches["pistol"]), "smg body kick > pistol (%.3f > %.3f)" % [float(pitches["smg"]), float(pitches["pistol"])])

	# 乳摇关闭时不应再加冲量（身体后坐仍在）
	await _ready_gun("rifle")
	ws.call("debug_set_ammo", "rifle", 8, 20)
	if br:
		br.set("enabled", false)
	if sec:
		sec.set("fire_recoil_pitch", 0.0)
		sec.set("fire_recoil_yaw", 0.0)
	await _frames(4)
	var pre_off := _breast_metrics()
	ws.call("debug_fire_once")
	var kick_off: Vector2 = sec.call("debug_fire_recoil") if sec else Vector2.ZERO
	await _frames(3)
	var post_off := _breast_metrics()
	_ok(kick_off.length() > 0.01, "body kick still applies when 乳摇 is off")
	_ok(float(post_off["speed"]) <= float(pre_off["speed"]) + 0.02, "no breast impulse when 乳摇 off (s %.4f → %.4f)" % [float(pre_off["speed"]), float(post_off["speed"])])
	if br:
		br.set("enabled", true)
		br.call("reset")

	# After recoil settles, ADS + TP seating still hold
	if sec:
		sec.set("fire_recoil_pitch", 0.0)
		sec.set("fire_recoil_yaw", 0.0)
	await _frames(20)
	await _ready_gun("rifle")
	player.call("set_play_mode", 1)
	_set_look_pitch(0.0)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(12)
	var parts2: Dictionary = ws.call("debug_ads_parts")
	_ok(float(parts2.get("rear", 999)) < 6.0 and float(parts2.get("stack", 999)) < 6.0, "ADS rifle still aligned after recoil settle")
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	player.call("set_play_mode", 0)
	await _frames(10)
	var st2: Dictionary = ws.call("debug_stock_vs_head")
	_ok(float(st2.get("d_sh", 99)) < 0.16, "TP rifle seating still tight after recoil settle (d=%.3f)" % float(st2.get("d_sh", 99)))

	print("v028_check: fails=", fails)
	quit(1 if fails > 0 else 0)
