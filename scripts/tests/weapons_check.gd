extends SceneTree
## 武器模块自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/weapons_check.gd
## SHOT_DIR + 非 headless：保存「第一人称持步枪 + 弹药 HUD」和「Q 轮盘」两张截图。

var main: Node
var player: Node
var game: Node
var hud: Node
var ws: Node
var fails := 0
var SHOT_DIR := OS.get_environment("SHOT_DIR")
var shots := 0
var shot_sig := 0
var flash_any := false
var recoil_max := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("weapons: OK   ", msg)
	else:
		fails += 1
		push_error("weapons: FAIL " + msg)


func _key(k: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = down
	Input.parse_input_event(e)
	await _frames(2)


func _touch(idx: int, p: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = root.get_final_transform() * p
	e.pressed = down
	Input.parse_input_event(e)
	await _frames(1)


func _drag(idx: int, from: Vector2, to: Vector2, steps: int = 6) -> void:
	var prev := from
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		var e := InputEventScreenDrag.new()
		e.index = idx
		e.position = root.get_final_transform() * p
		e.relative = p - prev
		prev = p
		Input.parse_input_event(e)
		await _frames(1)


## 等到可开火（跳过取枪动画）
func _ready_up() -> void:
	for i in 400:
		if str(ws.get("state")) == "ready":
			return
		ws.call("debug_finish_state")
		await _frames(1)


## 按住扳机 sec 秒（真实时间），返回开火次数
func _hold(sec: float) -> int:
	var s0 := shots
	ws.call("set_trigger", true)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await process_frame
		if ws.get("flash").visible:
			flash_any = true
		recoil_max = maxf(recoil_max, Vector2(ws.get("recoil")).length())
	ws.call("set_trigger", false)
	await _frames(1)
	return shots - s0


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(20)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	game = main
	ws = player.call("get_weapons")
	_ok(ws != null, "weapon system exists")
	var ids: PackedStringArray = ws.call("weapon_ids")
	_ok(ids.size() == 4 and ids[0] == "pistol" and ids[1] == "rifle", "4 data-driven defs loaded in order: %s" % [ids])
	ws.connect("fired", func(_id): shots += 1)
	ws.connect("shot_fired", func(_o, _d, _id): shot_sig += 1)

	# ---- 观察模式下隐藏 / 不响应
	player.call("set_play_mode", 0)
	await _frames(3)
	ws.call("select", "rifle")
	await _frames(5)
	_ok(not ws.get("view").visible, "view hidden in display mode")
	ws.call("holster")
	ws.call("debug_finish_state")
	await _frames(3)
	player.call("set_play_mode", 1)
	await _frames(5)

	# ---- 数字键（真实按键事件 → keymap）
	await _key(KEY_2, true)
	await _key(KEY_2, false)
	_ok(str(ws.get("current")) == "rifle", "key 2 selects rifle (cur=%s)" % ws.get("current"))
	await _ready_up()
	await _frames(5)
	_ok(ws.get("view").visible, "view visible when armed in control mode")
	_ok(bool(player.call("weapon_armed")), "player.weapon_armed()")
	var err: Dictionary = ws.call("debug_hand_error")
	_ok(not err.is_empty(), "IK active on our own arms (err=%s)" % [err])

	# ---- 菜单
	hud.call("toggle_weapon_panel")
	await _frames(3)
	var cards: Dictionary = hud.get("_wui").get("cards")
	_ok(cards.size() == 4, "weapon menu has 4 cards")
	var am: Label = cards["smg"]["ammo"]
	_ok(am.text.find("/") >= 0, "menu card shows ammo bottom-right (%s)" % am.text)
	(cards["pistol"]["btn"] as Button).pressed.emit()
	await _frames(2)
	await _ready_up()
	_ok(str(ws.get("current")) == "pistol", "menu pick → pistol (cur=%s)" % ws.get("current"))
	hud.call("toggle_weapon_panel")
	await _frames(2)

	# ---- Q 轮盘（按住 Q，指向格子，松开 Q）
	await _key(KEY_Q, true)
	_ok(bool(hud.call("is_wheel_open")), "Q opens wheel")
	var wheel: Control = hud.get("wheel")
	var c: Vector2 = wheel.call("center")
	var r: float = wheel.call("radius")
	# 第 4 格（shotgun）方向：-90° + 360°·3/4
	var a := -PI * 0.5 + TAU * 3.0 / 4.0
	hud.call("weapon_wheel_point", c + Vector2(cos(a), sin(a)) * r * 0.8)
	await _frames(1)
	await _key(KEY_Q, false)
	_ok(not bool(hud.call("is_wheel_open")), "Q release closes wheel")
	await _frames(2)
	await _ready_up()
	_ok(str(ws.get("current")) == "shotgun", "wheel pick → shotgun (cur=%s)" % ws.get("current"))

	# ---- 鼠标滚轮式循环
	ws.call("cycle", 1)
	await _frames(2)
	await _ready_up()
	_ok(str(ws.get("current")) == "pistol", "cycle wraps shotgun → pistol (cur=%s)" % ws.get("current"))

	# ---- 半自动：按住 1 秒只打 1 发
	ws.call("debug_set_ammo", "pistol", 8, 40)
	var n_semi: int = await _hold(1.0)
	_ok(n_semi == 1, "semi-auto pistol: held 1 s → %d shot" % n_semi)
	_ok(ws.call("ammo_of", "pistol") == Vector2i(7, 40), "ammo decrement 8 → 7")
	_ok(shot_sig >= 1, "shot_fired(origin, dir, weapon) emitted")

	# ---- 全自动：步枪 780 RPM 按住 1 秒 ≈ 13 发
	ws.call("select", "rifle")
	await _frames(2)
	await _ready_up()
	ws.call("debug_set_ammo", "rifle", 30, 90)
	flash_any = false
	recoil_max = 0.0
	var n_auto: int = await _hold(1.0)
	_ok(n_auto >= 11 and n_auto <= 15, "full-auto rifle 780rpm: held 1 s → %d shots" % n_auto)
	_ok(flash_any, "muzzle flash on when firing")
	_ok(recoil_max > 0.01, "recoil camera kick (max %.3f rad)" % recoil_max)
	await _frames(1)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1200:
		await process_frame
	_ok(not ws.get("flash").visible, "muzzle flash off after firing")
	_ok(Vector2(ws.get("recoil")).length() < 0.002, "recoil recovers to ~0 (%s)" % ws.get("recoil"))

	# ---- 换弹（战术：保留余弹 + 膛内 1 发）
	ws.call("debug_set_ammo", "rifle", 10, 90)
	_ok(bool(ws.call("reload")), "reload starts")
	var tac_len: float = ws.get("state_len")
	ws.call("debug_finish_state")
	await _frames(2)
	_ok(ws.call("ammo_of", "rifle") == Vector2i(31, 69), "tactical reload 10/90 → 31/69 (+1 chamber): %s" % ws.call("ammo_of", "rifle"))
	# 空仓换弹更慢，没有 +1
	ws.call("debug_set_ammo", "rifle", 0, 20)
	ws.call("reload")
	var emp_len: float = ws.get("state_len")
	_ok(emp_len > tac_len, "empty reload slower (%.2fs > %.2fs)" % [emp_len, tac_len])
	ws.call("debug_finish_state")
	await _frames(2)
	_ok(ws.call("ammo_of", "rifle") == Vector2i(20, 0), "empty reload 0/20 → 20/0: %s" % ws.call("ammo_of", "rifle"))
	# R 键（控制模式持枪 = 换弹）
	ws.call("debug_set_ammo", "rifle", 5, 30)
	await _key(KEY_R, true)
	await _key(KEY_R, false)
	_ok(str(ws.get("state")) == "reloading", "R key reloads when armed")
	ws.call("debug_finish_state")
	await _frames(2)
	# 空枪扣扳机：咔哒 + 自动换弹；无备弹不换
	var dry := [0]
	ws.connect("dry_fired", func(_id): dry[0] += 1)
	ws.call("debug_set_ammo", "rifle", 0, 0)
	await _hold(0.2)
	_ok(dry[0] == 1 and str(ws.get("state")) == "ready", "dry fire click, no reserve → no reload")
	ws.call("debug_set_ammo", "rifle", 0, 30)
	await _hold(0.1)
	_ok(dry[0] == 2 and str(ws.get("state")) == "reloading", "dry fire with reserve → auto reload")
	ws.call("debug_finish_state")
	await _frames(2)

	# ---- 霰弹：泵动，单发装填
	ws.call("select", "shotgun")
	await _frames(2)
	await _ready_up()
	ws.call("debug_set_ammo", "shotgun", 6, 30)
	var s0 := shot_sig
	var n_pump: int = await _hold(1.0)
	_ok(n_pump == 1 and shot_sig - s0 == 8, "pump shotgun: 1 shot, 8 pellets (%d / %d)" % [n_pump, shot_sig - s0])
	ws.call("debug_set_ammo", "shotgun", 3, 30)
	ws.call("reload")
	for i in 30:
		ws.call("debug_finish_state")
		await _frames(1)
		if str(ws.get("state")) == "ready":
			break
	_ok(ws.call("ammo_of", "shotgun") == Vector2i(6, 27), "shell-by-shell reload 3/30 → 6/27: %s" % ws.call("ammo_of", "shotgun"))

	# ---- 触屏：武器按钮按住拖到轮盘格子 = 选中；开火 / 换弹按钮
	hud.call("set_touch_ui", true)
	await _frames(3)
	var tc: Control = hud.call("get_touch_controls")
	var bs: Dictionary = tc.call("buttons")
	_ok(bs.has("weapon") and bs.has("fire") and bs.has("reload"), "touch: 武器 / 开火 / 换弹 buttons when armed")
	var wb: Vector2 = (bs["weapon"][0] as Rect2).get_center()
	await _touch(3, wb, true)
	_ok(bool(hud.call("is_wheel_open")), "touch: 武器 button opens wheel")
	c = wheel.call("center")
	a = -PI * 0.5 + TAU * 1.0 / 4.0  # 第 2 格 = rifle
	var tgt := c + Vector2(cos(a), sin(a)) * r * 0.8
	await _drag(3, wb, tgt)
	await _touch(3, tgt, false)
	await _frames(2)
	await _ready_up()
	_ok(str(ws.get("current")) == "rifle" and not bool(hud.call("is_wheel_open")), "touch wheel drag → rifle (cur=%s)" % ws.get("current"))
	bs = tc.call("buttons")
	ws.call("debug_set_ammo", "rifle", 30, 90)
	var fb: Vector2 = (bs["fire"][0] as Rect2).get_center()
	var sb := shots
	await _touch(4, fb, true)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 400:
		await process_frame
	await _touch(4, fb, false)
	_ok(shots - sb >= 3, "touch 开火 hold fires auto (%d)" % (shots - sb))
	var rb: Vector2 = (bs["reload"][0] as Rect2).get_center()
	await _touch(5, rb, true)
	await _touch(5, rb, false)
	_ok(str(ws.get("state")) == "reloading", "touch 换弹 reloads")
	ws.call("debug_finish_state")
	await _frames(2)
	hud.call("set_touch_ui", false)
	await _frames(2)

	# ---- 收枪 / 观察模式
	await _key(KEY_G, true)
	await _key(KEY_G, false)
	await _ready_up()
	ws.call("debug_finish_state")
	await _frames(3)
	_ok(str(ws.get("state")) == "holstered", "G holsters (state=%s)" % ws.get("state"))
	ws.call("select", "rifle")
	await _ready_up()
	player.call("set_play_mode", 0)
	await _frames(5)
	_ok(not ws.get("view").visible and not ws.get("hidden_by_mode") == false, "hidden in display mode")
	player.call("set_play_mode", 1)
	await _frames(5)

	if SHOT_DIR != "" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(SHOT_DIR)
		await _ready_up()
		for i in 60:
			await process_frame
		root.get_texture().get_image().save_png(SHOT_DIR.path_join("weapons_fp_rifle.png"))
		hud.call("open_weapon_wheel")
		hud.call("weapon_wheel_point", wheel.call("center") + Vector2(0, -1) * r * 0.8)
		await _frames(6)
		root.get_texture().get_image().save_png(SHOT_DIR.path_join("weapons_wheel.png"))
		hud.call("close_weapon_wheel", false)
	print("weapons_check: fails=%d" % fails)
	quit(1 if fails > 0 else 0)
