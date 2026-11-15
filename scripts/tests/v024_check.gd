extends SceneTree
## 0.2.4 持枪坐标不弓腰。开镜三点一线（0.2.5 起取消孔下偏）。
##   godot --headless --path . -s res://scripts/tests/v024_check.gd

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
		print("v024: OK   ", msg)
	else:
		fails += 1
		push_error("v024: FAIL " + msg)


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
		print("v024_check: fails=", fails)
		quit(1)
		return
	# 代码里必须不再弓腰
	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(src.find("func _apply_aim_torso") < 0, "waist/spine look-follow removed")
	_ok(src.find("C_Spine_a") < 0 or src.find("_pitch_hold_xf") >= 0, "hold is pitch-adjusted in view space")
	_ok(src.find("ADS_HOLE_DOWN") < 0, "ADS downward hole bias removed")

	# ---- ADS：孔略低于中心，准星尖叠在孔上
	await _check_ads(Vector2i(1280, 720), 0.75, "desktop 16:9 75%")
	await _check_ads(Vector2i(1600, 720), 0.75, "phone landscape 20:9 75%")
	await _check_ads(Vector2i(1280, 720), 1.0, "desktop 100%")

	# ---- 俯仰：不弓腰，手不离枪
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
	print("v024: level spine=", bow0)
	var worst_hand := 0.0
	var worst_bow := 0.0
	var worst_at := 0.0
	for deg in [-80, -50, -20, 0, 20, 50, 80]:
		_set_look_pitch(deg_to_rad(float(deg)))
		await _frames(4)
		await _phys(2)
		await _frames(2)
		var hg: Dictionary = ws.call("debug_hand_to_gun")
		var he: Dictionary = ws.call("debug_hand_error")
		var bow: Dictionary = ws.call("debug_spine_bow")
		var d := maxf(float(he.get("R", 99)), float(he.get("L", 99)))
		var dbow := absf(float(bow.get("lean", 0.0)) - lean0)
		if d > worst_hand:
			worst_hand = d
			worst_at = float(deg)
		worst_bow = maxf(worst_bow, dbow)
		print("v024: pitch ", deg, "deg look_up=", ws.call("_look_up_angle") if ws.has_method("_look_up_angle") else "?", " hands=", he, " to_gun=", hg, " bowΔ=", dbow)
		_ok(maxf(float(hg.get("R", 99)), float(hg.get("L", 99))) < 0.045, "hands on gun mesh at %s deg" % deg)
	_ok(worst_hand < 0.07, "IK wrist stays on sockets through pitch (worst=%.3f m at %s deg)" % [worst_hand, worst_at])
	_ok(worst_bow < deg_to_rad(8.0), "waist/spine lean vs level stays small (worst=%.1f deg)" % rad_to_deg(worst_bow))

	# 走跑手不离枪
	_set_look_pitch(-0.15)
	player.velocity = Vector3(0, 0, 3.0)
	await _phys(8)
	await _frames(4)
	var walk: Dictionary = ws.call("debug_hand_to_gun")
	_ok(maxf(float(walk.get("R", 99)), float(walk.get("L", 99))) < 0.045, "hands stay on gun while walking (R=%s L=%s)" % [walk.get("R"), walk.get("L")])
	player.velocity = Vector3.ZERO
	await _frames(2)

	# 观察抵肩不被破坏
	player.call("set_play_mode", 0)
	ws.call("set_ads", false)
	await _frames(12)
	await _phys(6)
	var stock: Dictionary = ws.call("debug_stock_vs_head")
	_ok(bool(stock.get("ok", false)), "observe stock nearer shoulder than head (d_sh=%.3f d_head=%.3f)" % [float(stock.get("d_sh", 99)), float(stock.get("d_head", 99))])

	print("v024_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_ads(sz: Vector2i, scale: float, tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		root.size = sz
	if settings:
		settings.call("set_render_scale", scale)
	await _frames(2)
	player.call("set_play_mode", 1)
	ws.call("select", "rifle")
	for i in 3:
		ws.call("debug_finish_state")
		await _frames(2)
	ws.call("set_ads", true)
	ws.set("_ads_k", 1.0)
	await _frames(10)
	await _phys(2)
	var parts: Dictionary = ws.call("debug_ads_parts")
	print("v024: ADS ", tag, " parts=", parts)
	var dy := absf(float(parts.get("dy", 999.0)))
	var dx := absf(float(parts.get("dx", 999.0)))
	var stack := float(parts.get("stack", 999.0))
	# 0.2.5：取消孔下偏，孔和准星尖都应落在屏幕中心 + 上
	_ok(dy < 8.0, "ADS hole vertically on + (%s, dy=%.1f px)" % [tag, dy])
	_ok(dx < 8.0, "ADS hole horizontally on + (%s, dx=%.1f px)" % [tag, dx])
	_ok(stack < 8.0, "ADS front post stacked on hole (%s, stack=%.1f px)" % [tag, stack])
	ws.call("set_ads", false)
	ws.set("_ads_k", 0.0)
	if settings:
		settings.call("set_render_scale", 1.0)
	await _frames(2)
