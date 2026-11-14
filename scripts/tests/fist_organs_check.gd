extends SceneTree
## 拳交脏器形变自检：对照网页 deformColon 公式，检查深度 0 / 中 / 满、抽插跟随、分身。
## SHOT_DIR + 非 headless：保存一张透视下拳头插入、肠管撑开/子宫位移的截图。

var SHOT_DIR := OS.get_environment("SHOT_DIR")
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _ok(c: bool, msg: String) -> void:
	if c:
		print("fist_organs: OK   ", msg)
	else:
		fails += 1
		print("fist_organs: FAIL ", msg)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _dbg(organs: Node) -> Dictionary:
	return organs.call("fist_deform_debug")


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(22)
	var player: Node = main.get_node("Player")
	var organs: Node = player.get_organs()
	var tools: RefCounted = organs.get("tools")
	_ok(tools != null and organs.get("ready_ok"), "organs + tools ready")
	# 子宫网格已标记
	var uter_n := 0
	for mi in organs.organ_meshes:
		if bool(mi.get_meta("is_uterus", false)):
			uter_n += 1
	_ok(uter_n == 1, "uterus mesh tagged (n=%d)" % uter_n)

	organs.call("set_interact_mode", "fist")
	organs.call("set_xray_enabled", true)
	organs.call("set_xray_amount", 0.75)
	tools.set("fist_gut", 1.0)

	# —— 深度 0：接近静止 ——
	organs.call("tool_set_depth01", 0.0)
	await _frames(36)
	var d0: Dictionary = _dbg(organs)
	_ok(float(d0["depth"]) < 0.025, "depth 0 near rest (%.4f)" % float(d0["depth"]))
	_ok(float(d0["uterus_off"]) < 0.003, "uterus at rest (off=%.4f)" % float(d0["uterus_off"]))
	_ok(float(d0["colon_open"]) < 0.005 and float(d0["rod_reach_s"]) < 0.03, "colon rod off at depth 0 (open=%.4f reach_s=%.4f)" % [float(d0["colon_open"]), float(d0["rod_reach_s"])])

	# 网页半径公式
	_ok(absf(float(d0["web_rad"]) - 0.018 * (0.55 + 1.0 * 0.7)) < 1e-6, "web rad formula at gut=1 (%.5f)" % float(d0["web_rad"]))
	tools.set("fist_gut", 0.4)
	await _frames(2)
	var g_lo: Dictionary = _dbg(organs)
	tools.set("fist_gut", 1.6)
	await _frames(2)
	var g_hi: Dictionary = _dbg(organs)
	_ok(float(g_hi["web_rad"]) > float(g_lo["web_rad"]) + 0.005, "web rad grows with 肠道撑开 (%.4f -> %.4f)" % [float(g_lo["web_rad"]), float(g_hi["web_rad"])])
	_ok(float(g_hi["tip_rad"]) >= float(g_hi["web_rad"]) - 1e-6, "physical tip rad >= web rad")
	_ok(float(g_hi["tip_rad"]) > float(g_lo["tip_rad"]), "physical tip rad grows with gut")
	tools.set("fist_gut", 1.0)

	# —— 中深度 ——
	organs.call("tool_set_depth01", 0.45)
	await _frames(36)
	var d_mid: Dictionary = _dbg(organs)
	_ok(float(d_mid["depth"]) > 0.10, "mid depth=%.3f" % float(d_mid["depth"]))
	_ok(absf(float(d_mid["web_rad"]) - 0.018 * (0.55 + 0.7)) < 1e-6, "mid web rad matches formula")
	_ok(float(d_mid["tip_rad"]) >= 0.036, "mid tip rad clears fist (%.4f)" % float(d_mid["tip_rad"]))
	_ok(float(d_mid["colon_open"]) > float(d0["colon_open"]) + 0.03, "colon opening increases mid vs 0 (%.4f)" % float(d_mid["colon_open"]))
	_ok(float(d_mid["rod_reach_s"]) > 0.10, "smoothed reach follows mid (%.3f)" % float(d_mid["rod_reach_s"]))
	_ok(float(d_mid["uterus_off"]) > 0.004, "uterus displaced at mid (%.4f)" % float(d_mid["uterus_off"]))
	_ok(float(d_mid["uterus_press"]) > 0.0, "uterus press mid=%.4f" % float(d_mid["uterus_press"]))

	# —— 满深度：通道更长，子宫受前臂压迫通常更大 ——
	organs.call("tool_set_depth01", 1.0)
	await _frames(36)
	var d_full: Dictionary = _dbg(organs)
	_ok(float(d_full["depth"]) > float(d_mid["depth"]) + 0.08, "full deeper than mid (%.3f > %.3f)" % [float(d_full["depth"]), float(d_mid["depth"])])
	_ok(float(d_full["rod_reach_s"]) > float(d_mid["rod_reach_s"]) + 0.06, "colon channel longer at full (%.3f > %.3f)" % [float(d_full["rod_reach_s"]), float(d_mid["rod_reach_s"])])
	_ok(float(d_full["colon_open"]) >= float(d_mid["colon_open"]) - 0.002, "colon open radius held at full")
	_ok(float(d_full["uterus_off"]) >= float(d_mid["uterus_off"]) - 0.002, "uterus offset at full >= mid (%.4f vs %.4f)" % [float(d_full["uterus_off"]), float(d_mid["uterus_off"])])

	# —— 抽插：形变跟随拳头（先回到中深度再突然拉满，短帧内 reach 已开始追上） ——
	organs.call("tool_set_depth01", 0.45)
	await _frames(28)
	var before: Dictionary = _dbg(organs)
	organs.call("tool_set_depth01", 1.0)
	await _frames(4)
	var rising: Dictionary = _dbg(organs)
	_ok(float(rising["rod_reach_s"]) > float(before["rod_reach_s"]) + 0.01, "thrust: smoothed reach follows fist (%.3f -> %.3f)" % [float(before["rod_reach_s"]), float(rising["rod_reach_s"])])
	# 搅动：方向变化
	await _frames(24)
	tools.set("fist_stir", true)
	tools.set("fist_stir_radius", 1.0)
	var dir0: Vector3 = _dbg(organs)["dir"]
	await _frames(24)
	var dir1: Vector3 = _dbg(organs)["dir"]
	_ok(dir0.angle_to(dir1) > 0.02, "stir: deformation axis moves with fist (ang=%.3f)" % dir0.angle_to(dir1))
	tools.set("fist_stir", false)

	# —— 分身同样生效 ——
	var root_g: Node = main
	if root_g.has_method("spawn_clone"):
		var msg: Variant = root_g.call("spawn_clone")
		print("fist_organs: clone ", msg)
	await _frames(8)
	var clones: Array = []
	for n in get_nodes_in_group("organ_rigs"):
		if n != organs:
			clones.append(n)
	_ok(clones.size() >= 1, "clone organ rig exists (n=%d)" % clones.size())
	if not clones.is_empty():
		var c: Node = clones[0]
		c.call("set_interact_mode", "fist")
		c.call("tool_set_depth01", 0.9)
		await _frames(36)
		var cd: Dictionary = c.call("fist_deform_debug")
		_ok(float(cd["rod_reach_s"]) > 0.15, "clone colon opens (reach_s=%.3f)" % float(cd["rod_reach_s"]))
		_ok(float(cd["uterus_off"]) > 0.003, "clone uterus displaced (%.4f)" % float(cd["uterus_off"]))
		# 本体不该被分身写入覆盖：本体仍在满深度附近
		var host: Dictionary = _dbg(organs)
		_ok(float(host["rod_reach_s"]) > 0.15, "player deform independent of clone")

	if SHOT_DIR != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(SHOT_DIR)
		if main.has_method("clear_clones"):
			main.call("clear_clones")
		player.call("set_play_mode", 0)
		organs.call("set_interact_mode", "fist")
		organs.call("tool_set_depth01", 0.92)
		organs.call("set_xray_enabled", true)
		organs.call("set_xray_amount", 0.8)
		await _frames(20)
		var f: Transform3D = organs.call("abdomen_frame")
		var cam := Camera3D.new()
		main.add_child(cam)
		cam.fov = 34.0
		cam.near = 0.02
		cam.global_position = f.origin + f.basis.z * 0.30 + f.basis.x * 0.14 + f.basis.y * 0.01
		cam.look_at(f.origin + f.basis.y * -0.09, Vector3.UP)
		cam.current = true
		await _frames(4)
		cam.current = true
		root.get_texture().get_image().save_png(SHOT_DIR.path_join("fist_organs_xray.png"))
		print("fist_organs: saved ", SHOT_DIR, "/fist_organs_xray.png")
		cam.queue_free()

	print("fist_organs_check: fails=%d" % fails)
	quit(1 if fails > 0 else 0)
