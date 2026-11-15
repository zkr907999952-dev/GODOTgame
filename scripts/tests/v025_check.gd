extends SceneTree
## 0.2.5：开镜三点一线、枪身摆正不横滚；俯仰不弓腰；观察抵肩。
##   godot --headless --path . -s res://scripts/tests/v025_check.gd

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


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v025: OK   ", msg)
	else:
		fails += 1
		push_error("v025: FAIL " + msg)


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
		print("v025_check: fails=", fails)
		quit(1)
		return

	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(src.find("func _apply_aim_torso") < 0, "waist/spine look-follow still absent")
	_ok(src.find("ADS_HOLE_DOWN") < 0, "ADS downward hole bias removed")
	_ok(src.find("_quat_map_dir_no_roll") >= 0, "ADS uses yaw+pitch, no-roll align")

	if organs.has_method("debug_skin_xray_state"):
		var xs: Dictionary = organs.call("debug_skin_xray_state")
		print("v025: skin xray ", xs)
		_ok(bool(xs.get("ok", false)), "skin_xray active with non-zero analytic hole (shader=%s xray=%s analytic=%s)" % [xs.get("shader"), xs.get("xray"), xs.get("analytic")])

	# ---- ADS all four guns, several aspect/scale combos
	var setups: Array = [
		[Vector2i(1280, 720), 0.75, "desktop 16:9 75%"],
		[Vector2i(1600, 720), 0.75, "phone landscape 20:9 75%"],
		[Vector2i(1280, 720), 1.0, "desktop 16:9 100%"],
	]
	for s in setups:
		for id in ["rifle", "smg", "pistol", "shotgun"]:
			await _check_ads(s[0], s[1], id, s[2])

	# ---- pitch: no bow, hands on gun (rifle)
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	if settings:
		settings.call("set_render_scale", 1.0)
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	_set_look_pitch(-0.15)
	await _frames(8)
	await _phys(2)
	var bow0: Dictionary = ws.call("debug_spine_bow")
	var lean0 := float(bow0.get("lean", 0.0))
	var worst_hand := 0.0
	var worst_bow := 0.0
	for deg in [-80, 0, 80]:
		_set_look_pitch(deg_to_rad(float(deg)))
		await _frames(4)
		await _phys(2)
		await _frames(2)
		var he: Dictionary = ws.call("debug_hand_error")
		var hg: Dictionary = ws.call("debug_hand_to_gun")
		var bow: Dictionary = ws.call("debug_spine_bow")
		var d := maxf(float(he.get("R", 99)), float(he.get("L", 99)))
		worst_hand = maxf(worst_hand, d)
		worst_bow = maxf(worst_bow, absf(float(bow.get("lean", 0.0)) - lean0))
		_ok(maxf(float(hg.get("R", 99)), float(hg.get("L", 99))) < 0.045, "hands on gun mesh at %s deg" % deg)
	_ok(worst_hand < 0.07, "IK wrist stays on sockets through pitch (worst=%.3f m)" % worst_hand)
	_ok(worst_bow < deg_to_rad(8.0), "waist/spine lean vs level stays small (worst=%.1f deg)" % rad_to_deg(worst_bow))

	_set_look_pitch(-0.15)
	player.velocity = Vector3(0, 0, 3.0)
	await _phys(8)
	await _frames(4)
	var walk: Dictionary = ws.call("debug_hand_to_gun")
	_ok(maxf(float(walk.get("R", 99)), float(walk.get("L", 99))) < 0.045, "hands stay on gun while walking")
	player.velocity = Vector3.ZERO

	player.call("set_play_mode", 0)
	ws.call("set_ads", false)
	await _frames(12)
	await _phys(6)
	var stock: Dictionary = ws.call("debug_stock_vs_head")
	_ok(bool(stock.get("ok", false)), "observe stock nearer shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(stock.get("d_sh", 99)), float(stock.get("d_head", 99))])

	print("v025_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_ads(sz: Vector2i, scale: float, id: String, tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		root.size = sz
	if settings:
		settings.call("set_render_scale", scale)
	await _frames(2)
	player.call("set_play_mode", 1)
	ws.call("select", id)
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	_set_look_pitch(0.0)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(10)
	await _phys(2)
	await _frames(2)
	var parts: Dictionary = ws.call("debug_ads_parts")
	print("v025: ADS ", id, " ", tag, " parts=", parts)
	var rear := float(parts.get("rear", 999.0))
	var front := float(parts.get("front", 999.0))
	var stack := float(parts.get("stack", 999.0))
	var axis := float(parts.get("axis_deg", 999.0))
	var roll := absf(float(parts.get("roll_deg", 999.0)))
	var label := "%s %s" % [id, tag]
	_ok(rear < 6.0, "ADS rear on + (%s, %.1f px)" % [label, rear])
	_ok(front < 6.0, "ADS front on + (%s, %.1f px)" % [label, front])
	_ok(stack < 6.0, "ADS 三点一线 stack (%s, %.1f px)" % [label, stack])
	_ok(axis < 0.5, "ADS sight axis vs camera -Z (%s, %.2f deg)" % [label, axis])
	_ok(roll < 2.0, "ADS gun roll near 0 (%s, %.2f deg)" % [label, roll])
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	if settings:
		settings.call("set_render_scale", 1.0)
	await _frames(2)
