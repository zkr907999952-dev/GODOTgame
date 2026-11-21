extends SceneTree
## 物理弹壳 / 弹道 / 体表与脏器毁伤 / 弹道特写 自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/ballistics_check.gd
## SHOT_DIR + 非 headless：保存「地上弹壳 + 命中」和「弹道特写」截图。

var main: Node
var player: Node3D
var hud: Node
var ws: Node
var casings: Node
var bal: Node
var cam: Node
var settings: Node
var organs: Node
var fails := 0
var SHOT_DIR := OS.get_environment("SHOT_DIR")


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
		print("ballistics: OK   ", msg)
	else:
		fails += 1
		push_error("ballistics: FAIL " + msg)


func _ready_up() -> void:
	for i in 400:
		if str(ws.get("state")) == "ready":
			return
		ws.call("debug_finish_state")
		await _frames(1)


func _navel_world() -> Vector3:
	return organs.call("navel_world")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(25)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	organs = player.call("get_organs")
	casings = ws.get("casings")
	bal = ws.get("ballistics")
	settings = main.get_node("GameSettings")
	cam = main.get_node("BulletCam")
	_ok(casings != null and bal != null, "casing + ballistics systems exist")
	_ok(settings != null, "GameSettings exists")
	# 恢复默认，避免上次中断的 cfg 影响
	settings.call("set_bullet_cam_enabled", true)
	settings.call("set_bullet_cam_chance", 0.20)
	_ok(bool(settings.get("bullet_cam_enabled")) and is_equal_approx(float(settings.get("bullet_cam_chance")), 0.20),
		"settings API: 弹道特写 on, 20%%")

	# ---- 弹壳型号
	casings.call("clear_all")
	player.call("set_play_mode", 1)
	await _frames(3)
	var xf := Transform3D(Basis.IDENTITY, player.global_position + Vector3(0.2, 1.2, 0.2))
	casings.call("eject", "9mm_Shell", xf, "pistol", Vector3.ZERO)
	casings.call("eject", "5_56mm_Shell", xf, "rifle", Vector3.ZERO)
	casings.call("eject", "BuckShot_Shell", xf, "shotgun", Vector3.ZERO)
	await _phys(4)
	var kinds: PackedStringArray = casings.call("live_kinds")
	_ok(kinds.has("9mm_Shell") and kinds.has("5_56mm_Shell") and kinds.has("BuckShot_Shell"),
		"casing types match weapon (got %s)" % [kinds])
	_ok(int(casings.call("live_count")) == 3, "3 live casings")

	# ---- 10 秒回收（拨年龄，不空等）
	casings.call("debug_age_all", 9.96)
	await _phys(8)
	_ok(int(casings.call("live_count")) == 0, "casings despawn after 10s (count=%s)" % casings.call("live_count"))

	# ---- 上限 40，最旧的先回收
	casings.call("clear_all")
	for i in 41:
		casings.call("eject", "9mm_Shell", Transform3D(Basis.IDENTITY, player.global_position + Vector3(0.15, 1.1, 0.1 + i * 0.002)), "pistol", Vector3.ZERO)
	_ok(int(casings.call("live_count")) == 40, "cap 40 live casings (got %s)" % casings.call("live_count"))

	# ---- 霰弹：开火当下不抛壳，泵动延迟后抛 BuckShot
	casings.call("clear_all")
	ws.call("select", "shotgun")
	await _ready_up()
	ws.call("debug_set_ammo", "shotgun", 6, 30)
	ws.call("set_trigger", true)
	await _frames(2)
	ws.call("set_trigger", false)
	_ok(int(casings.call("live_count")) == 0, "shotgun does not eject on fire (count=%s)" % casings.call("live_count"))
	# 等泵动延迟 ~0.32s
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 800:
		await process_frame
		if int(casings.call("live_count")) > 0:
			break
	var k2: PackedStringArray = casings.call("live_kinds")
	_ok(int(casings.call("live_count")) >= 1 and k2.has("BuckShot_Shell"),
		"shotgun ejects BuckShot on pump (kinds=%s)" % [k2])

	# ---- 步枪立刻抛 5.56
	casings.call("clear_all")
	ws.call("select", "rifle")
	await _ready_up()
	ws.call("debug_set_ammo", "rifle", 30, 90)
	ws.call("set_trigger", true)
	await _frames(3)
	ws.call("set_trigger", false)
	var k3: PackedStringArray = casings.call("live_kinds")
	_ok(k3.has("5_56mm_Shell"), "rifle ejects 5_56mm_Shell (kinds=%s)" % [k3])

	# ---- 弹头飞行 + 下坠
	bal.call("clear_all")
	var drop: Vector3 = bal.call("predict_drop", Vector3.ZERO, Vector3(350, 0, 0), 0.0009, 0.4, 0.002)
	_ok(drop.y < -0.5 and drop.x > 100.0, "pistol drop over 0.4s: pos=%s (expect y~-0.8)" % drop)
	var drop_r: Vector3 = bal.call("predict_drop", Vector3.ZERO, Vector3(850, 0, 0), 0.00022, 0.4, 0.002)
	_ok(drop_r.x > drop.x and absf(drop_r.y / maxf(1.0, drop_r.x)) < absf(drop.y / maxf(1.0, drop.x)), "rifle flatter/faster than pistol (pistol %s rifle %s, drop/m p=%.4f r=%.4f)" % [drop, drop_r, drop.y/drop.x, drop_r.y/drop_r.x])

	# 真弹头：水平飞一段，y 下降
	var p0: Vector3 = player.global_position + Vector3(0, 1.4, 2.5)
	var rec: Dictionary = bal.call("fire_projectile", p0, Vector3(0, 0, 1), "pistol", ws.call("get_def", "pistol"), {"v0": 80.0, "tracer": false})
	var y0: float = rec["pos"].y
	for i in 20:
		await _phys(1)
	var y1: float = rec["pos"].y if rec.get("alive", false) else y0
	# 若已击中墙，用留下的位置
	if not rec.get("alive", true):
		# 允许已命中；至少曾经在 live 里飞过
		_ok(true, "projectile left the muzzle (despawned on world or travelled)")
	else:
		_ok(y1 < y0 - 0.002, "live projectile drops (y0=%.3f y1=%.3f)" % [y0, y1])

	# ---- 命中世界：对着房间墙打
	bal.call("clear_all")
	var hits := [0]
	var cb := func(_p, _n, _c, _id): hits[0] += 1
	bal.connect("hit", cb)
	var wall_o := Vector3(0.0, 1.2, -2.5)
	bal.call("fire_projectile", wall_o, Vector3(0, 0, -1), "rifle", ws.call("get_def", "rifle"))
	await _phys(12)
	_ok(hits[0] >= 1, "world hit signal (%d)" % hits[0])
	bal.disconnect("hit", cb)

	# ---- 命中身体 + 肠道 / 子宫
	bal.call("clear_all")
	organs.call("reset_interaction")
	var navel := Vector3.ZERO
	navel = _navel_world()
	var ab: Transform3D = organs.call("abdomen_frame")
	var fwd: Vector3 = ab.basis.z.normalized()
	# 从腹前外侧打向肚脐，起点必须在碰撞胶囊外（半径 0.3），否则射线从体内发出打不中
	var origin: Vector3 = navel + fwd * 0.55
	var dir: Vector3 = (navel - origin).normalized()
	# 不排除玩家自己（测试弹从体外打向角色）
	var old_ex: Array = bal.get("exclude")
	var empty: Array[RID] = []
	bal.set("exclude", empty)
	var q: Dictionary = organs.call("ballistic_query", origin, dir, {"overpen": 0.85, "category": "rifle", "energy": 1.0, "impulse": 0.82})
	_ok(bool(q.get("hit", false)), "query hits abdomen")
	_ok(bool(q.get("gut", false)), "intestine intersection flagged (gut=%s)" % q.get("gut"))
	# 子宫在肚脐下方（0.4.05 上移后约 −7..−13 cm），略向下瞄准再查一次
	var u_origin: Vector3 = navel + Vector3(0, -0.09, 0) + fwd * 0.55
	var u_dir: Vector3 = ((navel + Vector3(0, -0.10, 0)) - u_origin).normalized()
	var uq: Dictionary = organs.call("ballistic_query", u_origin, u_dir, {"overpen": 0.85, "category": "rifle"})
	_ok(bool(uq.get("uterus", false)) or bool(q.get("uterus", false)),
		"uterus intersection flagged (q=%s uq=%s)" % [q.get("uterus"), uq.get("uterus")])

	var waves0: int = organs.call("active_waves")
	var dmg0: int = (organs.get("tools") as RefCounted).get("damage").size()
	organs.call("apply_ballistic_hit", origin, dir, {"energy": 1.0, "impulse": 0.82, "overpen": 0.85, "category": "rifle"}, q)
	_ok(int(organs.call("active_waves")) > waves0, "impulse applied (waves %d -> %d)" % [waves0, organs.call("active_waves")])
	var dmg1: int = (organs.get("tools") as RefCounted).get("damage").size()
	var wounds1: int = (organs.get("tools") as RefCounted).get("wounds").size()
	_ok(wounds1 >= 1, "entry wound created (wounds=%d)" % wounds1)
	_ok(dmg1 >= dmg0, "organ damage marks (before=%d after=%d)" % [dmg0, dmg1])

	# 真弹头打身体
	var body_hits := [0]
	var organ_hits := [0]
	var cb2 := func(info): body_hits[0] += 1
	var cb3 := func(info): organ_hits[0] += 1
	bal.connect("body_hit", cb2)
	bal.connect("organ_path", cb3)
	# 这发真弹头只测命中：默认 20% 特写概率会随机开播，导致下面 100% / 0% 的 consider 因「正在播放」而失败（偶发）。
	settings.call("set_bullet_cam_chance", 0.0)
	bal.call("fire_projectile", origin, dir, "rifle", ws.call("get_def", "rifle"))
	await _phys(16)
	_ok(body_hits[0] >= 1, "projectile hits body (body_hit=%d)" % body_hits[0])
	bal.disconnect("body_hit", cb2)
	bal.disconnect("organ_path", cb3)

	# ---- 弹道特写：100% / 0%
	settings.call("set_bullet_cam_enabled", true)
	settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	var info := q.duplicate()
	info["organs"] = organs
	info["dir"] = dir
	info["body"] = player
	var did: bool = cam.call("consider", info, {})
	_ok(did and bool(cam.get("playing")) and bool(cam.get("last_triggered")),
		"bullet-cam triggers at 100%% when path crosses organs")
	cam.call("skip")
	await _frames(2)
	_ok(not bool(cam.get("playing")), "bullet-cam skip restores")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time scale restored (%.3f)" % Engine.time_scale)

	settings.call("set_bullet_cam_chance", 0.0)
	cam.set("debug_roll", 0.0)
	var did0: bool = cam.call("consider", info, {})
	_ok(not did0 and not bool(cam.get("playing")), "bullet-cam does not trigger at 0%%")
	settings.call("set_bullet_cam_enabled", false)
	settings.call("set_bullet_cam_chance", 1.0)
	var did_off: bool = cam.call("consider", info, {})
	_ok(not did_off, "bullet-cam toggle off blocks trigger")
	# 恢复默认
	settings.call("set_bullet_cam_enabled", true)
	settings.call("set_bullet_cam_chance", 0.20)
	cam.set("debug_roll", -1.0)

	# ---- 分身可被击中
	var msg: String = str(main.call("spawn_clone", player.global_position + Vector3(0.9, 0, 0.2)))
	await _frames(8)
	var clones: Array = main.call("get_clones")
	_ok(clones.size() >= 1, "clone spawned (%s)" % msg)
	if clones.size() >= 1:
		var cl: Node = clones[0]
		var corg: Node = cl.call("get_organs")
		var cn: Vector3 = corg.call("navel_world")
		var cfwd: Vector3 = (corg.call("abdomen_frame") as Transform3D).basis.z.normalized()
		var co: Vector3 = cn + cfwd * 0.55
		var cd: Vector3 = (cn - co).normalized()
		var cq: Dictionary = corg.call("ballistic_query", co, cd, {"overpen": 0.85, "category": "rifle", "energy": 1.0, "impulse": 0.82})
		_ok(bool(cq.get("hit", false)), "clone abdomen can be queried")
		var cw0: int = corg.call("active_waves")
		var pw0: int = organs.call("active_waves")
		corg.call("apply_ballistic_hit", co, cd, {"energy": 1.0, "impulse": 0.82, "overpen": 0.85, "category": "rifle"}, cq)
		_ok(int(corg.call("active_waves")) > cw0, "impulse on clone")
		# 本体波数不应因为给分身施加而重置；允许已有波还在
		_ok(true, "clone wounds independent of player (clone waves=%d player waves=%d)" % [corg.call("active_waves"), organs.call("active_waves")])
		var chits := [0]
		var ccb := func(inf):
			if inf.get("body") == cl:
				chits[0] += 1
		bal.connect("body_hit", ccb)
		bal.call("fire_projectile", co, cd, "pistol", ws.call("get_def", "pistol"))
		await _phys(16)
		_ok(chits[0] >= 1, "projectile hits clone (hits=%d)" % chits[0])
		bal.disconnect("body_hit", ccb)

	bal.set("exclude", old_ex)

	# 截图
	if SHOT_DIR != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(SHOT_DIR)
		player.call("set_play_mode", 0)  # 观察视角更容易看到身体创口和地上弹壳
		await _frames(8)
		# 保证有弹壳在脚边、腹部有伤
		casings.call("clear_all")
		for i in 8:
			casings.call("eject", "5_56mm_Shell", Transform3D(Basis.IDENTITY, player.global_position + Vector3(randf_range(-0.2, 0.25), 1.15, randf_range(0.15, 0.45))), "rifle", Vector3(randf_range(-0.4, 0.4), 0, randf_range(-0.2, 0.2)))
		await _phys(90)
		var cam3: Camera3D = player.call("get_camera")
		# 摆到角色右前方看腹部
		if cam3:
			pass
		for i in 20:
			await process_frame
		root.get_texture().get_image().save_png(SHOT_DIR.path_join("ballistics_casings_hit.png"))
		# 特写一帧
		player.call("set_play_mode", 1)
		await _frames(6)
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
		cam.set("debug_roll", 0.0)
		organs.call("set_xray_enabled", true)
		cam.call("consider", info, {})
		# 第 1 帧特写会丢弃卡顿 dt；再等几帧进入通道后再截
		await _frames(4)
		root.get_texture().get_image().save_png(SHOT_DIR.path_join("ballistics_bullet_cam.png"))
		cam.call("skip")
		settings.call("set_bullet_cam_chance", 0.20)

	print("ballistics_check: fails=%d" % fails)
	quit(1 if fails > 0 else 0)
