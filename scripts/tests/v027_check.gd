extends SceneTree
## 0.2.6 后续修正（俯视双指缩放、地图隐藏武器 UI、轮盘原点、左手/观察手枪、
## 步枪略缩小、长枪开镜基线、霰弹腰射前伸、换弹显匣、无限备弹、抵肩低头）：
##   godot --headless --path . -s res://scripts/tests/v027_check.gd

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
		print("v027: OK   ", msg)
	else:
		fails += 1
		push_error("v027: FAIL " + msg)


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
		print("v027_check: fails=", fails)
		quit(1)
		return

	# version / package untouched
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.6\"") >= 0, "export version stays 0.2.6")
	_ok(presets.find("version/code=8") >= 0, "versionCode stays 8")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")

	# ---- J: infinite reserve default on, still reloads, shows ∞, does not consume
	_ok(settings != null and bool(settings.get("infinite_reserve")), "infinite reserve default on")
	_ok(bool(ws.call("infinite_reserve")), "weapon system sees infinite reserve")
	_ok(str(ws.call("ammo_text", "rifle")).contains("∞"), "ammo text uses ∞")
	await _ready_gun("rifle")
	ws.call("debug_set_ammo", "rifle", 5, 7)
	_ok(bool(ws.call("has_reserve", "rifle")), "has_reserve true even with small reserve when infinite")
	_ok(bool(ws.call("reload")), "reload still required / starts with infinite reserve")
	ws.call("debug_finish_state")
	await _frames(3)
	var after: Vector2i = ws.call("ammo_of", "rifle")
	_ok(after.x == 31 and after.y == 7, "infinite reload fills mag, reserve unchanged (got %s)" % after)
	# dry fire with 0 recorded reserve still reloads（需在第一人称，扳机先松开）
	player.call("set_play_mode", 1)
	await _frames(4)
	await _ready_gun("rifle")
	ws.call("debug_set_ammo", "rifle", 0, 0)
	ws.call("set_trigger", false)
	await _frames(2)
	ws.call("set_trigger", true)
	await _frames(3)
	ws.call("set_trigger", false)
	_ok(str(ws.get("state")) == "reloading", "dry fire with infinite still reloads")
	ws.call("debug_finish_state")
	await _frames(2)
	# setting off restores numeric reserve rules
	settings.set("infinite_reserve", false)
	_ok(not bool(ws.call("infinite_reserve")), "can turn infinite reserve off")
	_ok(not str(ws.call("ammo_text", "rifle")).contains("∞"), "ammo text numeric when off")
	ws.call("debug_set_ammo", "rifle", 0, 0)
	_ok(not bool(ws.call("reload")), "no reserve and infinite off → cannot reload")
	settings.set("infinite_reserve", true)

	# ---- A: map pinch zoom
	var mv: Node = main.get("map_view")
	_ok(mv != null and mv.has_method("zoom_by") and mv.has_method("handle_input"), "map_view has pinch/zoom_by")
	main.call("open_overhead")
	await _frames(4)
	_ok(bool(mv.get("is_open")), "overhead map opens")
	var h0: float = float(mv.get("height"))
	# two-finger pinch out (distance increases) → zoom in (height down)
	var e1 := InputEventScreenTouch.new()
	e1.index = 0
	e1.position = Vector2(400, 300)
	e1.pressed = true
	mv.call("handle_input", e1)
	var e2 := InputEventScreenTouch.new()
	e2.index = 1
	e2.position = Vector2(500, 300)
	e2.pressed = true
	mv.call("handle_input", e2)
	var d1 := InputEventScreenDrag.new()
	d1.index = 1
	d1.position = Vector2(700, 300)
	d1.relative = Vector2(200, 0)
	mv.call("handle_input", d1)
	var h1: float = float(mv.get("height"))
	_ok(h1 < h0 * 0.85, "pinch out zooms in (h %.1f → %.1f)" % [h0, h1])
	mv.call("zoom_by", 2.0)
	var h2: float = float(mv.get("height"))
	_ok(h2 > h1 * 1.5, "zoom_by >1 raises height (%.1f → %.1f)" % [h1, h2])

	# ---- B: weapon UI hidden when map / overhead open
	_ok(bool(hud.call("should_hide_weapon_ui")), "weapon UI hidden in overhead")
	if hud.get("_wui"):
		hud.get("_wui").call("_refresh_ammo_hud")
		var box = hud.get("_wui").get("ammo_box")
		_ok(box == null or not bool(box.visible), "ammo HUD hidden in overhead")
	var btn_w = hud.get("_btn_weapon")
	_ok(btn_w == null or not bool(btn_w.visible), "chrome weapon button hidden in overhead")
	main.call("close_overhead")
	await _frames(3)
	_ok(not bool(hud.call("should_hide_weapon_ui")), "weapon UI allowed after closing overhead")
	hud.call("toggle_map_panel")
	await _frames(2)
	_ok(bool(hud.call("should_hide_weapon_ui")), "weapon UI hidden when map menu open")
	hud.call("toggle_map_panel")
	await _frames(2)

	# ---- C: weapon wheel origin is the tap point
	var wheel: Control = hud.get("wheel")
	var tap := Vector2(200, 500)
	hud.call("open_weapon_wheel", tap)
	await _frames(2)
	var c: Vector2 = wheel.call("center")
	_ok(c.distance_to(tap) < 1.0, "wheel center is tap point (c=%s tap=%s)" % [c, tap])
	# dragging relative to tap should hover a slot, not screen-center slot
	wheel.call("point_at", tap + Vector2(0, -80))
	_ok(int(wheel.get("hover")) >= 0, "hover from tap origin (hover=%s)" % wheel.get("hover"))
	hud.call("close_weapon_wheel", false)

	# ---- F: rifle slightly smaller
	var rifle_def = ws.call("get_def", "rifle")
	var smg_def = ws.call("get_def", "smg")
	var pistol_def = ws.call("get_def", "pistol")
	var shotgun_def = ws.call("get_def", "shotgun")
	_ok(rifle_def != null and float(rifle_def.view_scale) < 0.78 and float(rifle_def.view_scale) > 0.68, "rifle view_scale slightly smaller (%.3f)" % float(rifle_def.view_scale))
	_ok(is_equal_approx(float(smg_def.view_scale), 0.8), "smg scale unchanged")
	_ok(is_equal_approx(float(pistol_def.view_scale), 0.8), "pistol scale unchanged")

	# ---- H: shotgun hip farther forward than rifle
	var rh: Vector3 = ws.call("_hip_offset", rifle_def)
	var sh: Vector3 = ws.call("_hip_offset", shotgun_def)
	_ok(sh.y < rh.y - 0.03, "shotgun hip lower than rifle (sy=%.3f ry=%.3f)" % [sh.y, rh.y])
	_ok(sh.z < rh.z - 0.08, "shotgun hip farther forward (sz=%.3f rz=%.3f)" % [sh.z, rh.z])

	# ---- G / D / E / K: poses
	player.call("set_play_mode", 1)
	if settings:
		settings.call("set_render_scale", 1.0)
	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(src.find("LEFT_HAND_ADJUST") >= 0, "left-hand downward adjust present")
	_ok(src.find("_wrist_cam") >= 0, "shared wrist helper used by IK")

	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _ready_gun(id)
		_set_look_pitch(0.0)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(12)
		var parts: Dictionary = ws.call("debug_ads_parts")
		print("v027: ADS ", id, " ", parts)
		var label := str(id)
		_ok(float(parts.get("rear", 999)) < 6.0, "ADS rear on + (%s, %.1f px)" % [label, float(parts.get("rear", 999))])
		_ok(float(parts.get("front", 999)) < 6.0, "ADS front on + (%s, %.1f px)" % [label, float(parts.get("front", 999))])
		_ok(float(parts.get("stack", 999)) < 6.0, "ADS stack (%s, %.1f px)" % [label, float(parts.get("stack", 999))])
		_ok(float(parts.get("axis_deg", 999)) < 0.5, "ADS axis (%s, %.2f deg)" % [label, float(parts.get("axis_deg", 999))])
		_ok(absf(float(parts.get("roll_deg", 999))) < 2.0, "ADS roll (%s, %.2f deg)" % [label, float(parts.get("roll_deg", 999))])
		var hands: Dictionary = ws.call("debug_hand_to_gun")
		_ok(float(hands.get("L", 99)) < 0.12, "left hand on gun in ADS (%s, d=%.3f)" % [label, float(hands.get("L", 99))])
		_ok(float(hands.get("R", 99)) < 0.12, "right hand on gun in ADS (%s, d=%.3f)" % [label, float(hands.get("R", 99))])
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(2)

	# pistol ADS should still pass (unchanged path) — already in loop

	# ---- E + K: observation / third-person hold
	await _ready_gun("pistol")
	player.call("set_play_mode", 0)
	await _frames(10)
	var pst: Dictionary = ws.call("debug_stock_vs_head")
	print("v027: TP pistol ", pst)
	# 手枪应伸到身前，不应缩在躯干里：枪把远离肩骨中线/头，至少离开身体数厘米
	if skeleton_ok():
		var torso := _chest()
		var grip: Vector3 = pst.get("stock", Vector3.ZERO)
		var d_chest := grip.distance_to(torso) if torso != Vector3.INF else 99.0
		_ok(d_chest > 0.16, "observe pistol not buried in torso (d_chest=%.3f)" % d_chest)
	player.call("set_play_mode", 1)
	await _frames(4)

	await _ready_gun("rifle")
	player.call("set_play_mode", 0)
	await _frames(10)
	var st: Dictionary = ws.call("debug_stock_vs_head")
	print("v027: TP rifle ", st)
	_ok(bool(st.get("ok", false)), "TP rifle stock closer to shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(st.get("d_sh", 99)), float(st.get("d_head", 99))])
	_ok(float(st.get("d_sh", 99)) < 0.28, "TP rifle stock near shoulder pocket (d=%.3f)" % float(st.get("d_sh", 99)))
	# cheek weld should be engaged
	var sec = player.call("get_secondary") if player.has_method("get_secondary") else null
	if sec:
		_ok(float(sec.get("cheek_weld")) > 0.4, "cheek weld on in observe with rifle (k=%.2f)" % float(sec.get("cheek_weld")))
	# stock should not sit at forehead: stock Y well below head Y
	var stock: Vector3 = st.get("stock", Vector3.ZERO)
	var head: Vector3 = st.get("head", Vector3.ZERO)
	_ok(stock.y < head.y - 0.05, "TP rifle stock below head (sy=%.3f hy=%.3f)" % [stock.y, head.y])
	player.call("set_play_mode", 1)
	await _frames(3)

	# ---- I: new mag visible during insert
	await _ready_gun("rifle")
	settings.set("infinite_reserve", false)
	ws.call("debug_set_ammo", "rifle", 10, 90)
	_ok(bool(ws.call("reload")), "rifle reload started for mag visual")
	_ok(bool(ws.call("debug_mag_visible")), "mag visible at reload start")
	var due_e := float(ws.call("debug_mag_eject_at"))
	var due_i := float(ws.call("debug_mag_insert_at"))
	var dur := float(ws.get("state_len"))
	_ok(due_i > due_e + 0.04 and due_i < dur * 0.85, "insert time after eject (e=%.3f i=%.3f / %.3f)" % [due_e, due_i, dur])
	var steps := 0
	while not bool(ws.call("debug_mag_ejected")) and steps < 200:
		await process_frame
		steps += 1
	_ok(bool(ws.call("debug_mag_ejected")), "mag ejected")
	_ok(not bool(ws.call("debug_mag_visible")), "mag hidden right after eject")
	steps = 0
	while not bool(ws.call("debug_mag_visible")) and steps < 200:
		await process_frame
		steps += 1
	var at := float(ws.get("state_t"))
	_ok(bool(ws.call("debug_mag_visible")), "new mag visible at insert")
	_ok(at + 0.05 >= due_i or at >= due_i - 0.05, "visible around insert time (at=%.3f i=%.3f)" % [at, due_i])
	_ok(at < dur * 0.95, "new mag appears before reload ends (at=%.3f / %.3f)" % [at, dur])
	ws.call("debug_finish_state")
	await _frames(3)
	_ok(bool(ws.call("debug_mag_visible")), "mag visible after reload")

	# pistol mag too
	await _ready_gun("pistol")
	ws.call("debug_set_ammo", "pistol", 8, 40)
	_ok(bool(ws.call("reload")), "pistol reload started")
	steps = 0
	while not bool(ws.call("debug_mag_ejected")) and steps < 200:
		await process_frame
		steps += 1
	steps = 0
	while not bool(ws.call("debug_mag_visible")) and steps < 200:
		await process_frame
		steps += 1
	_ok(bool(ws.call("debug_mag_visible")), "pistol new mag visible during reload")
	ws.call("debug_finish_state")
	await _frames(2)
	settings.set("infinite_reserve", true)

	print("v027_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func skeleton_ok() -> bool:
	return player != null and player.has_method("get_skeleton") and player.call("get_skeleton") != null


func _chest() -> Vector3:
	var skel: Skeleton3D = player.call("get_skeleton")
	if skel == null:
		return Vector3.INF
	var i := skel.find_bone("C_Spine_c")
	if i < 0:
		return Vector3.INF
	return skel.global_transform * skel.get_bone_global_pose(i).origin
