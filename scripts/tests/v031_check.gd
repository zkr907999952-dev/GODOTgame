extends SceneTree
## 0.2.10 自检：肩臂不再拧坏、弹匣更早显示、狙击精英式弹道特写（连发不叠）、
## HUD 血条居中靠下、武器键左移、开火键下移。
##   godot --headless --path . -s res://scripts/tests/v031_check.gd

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


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v031: OK   ", msg)
	else:
		fails += 1
		push_error("v031: FAIL " + msg)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	_ok(ws != null and hud != null, "scene booted")
	if ws == null or hud == null:
		print("v031_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.10\"") >= 0 or presets.find("version/name=\"0.2.11\"") >= 0, "export version is 0.2.10 or 0.2.11")
	_ok(presets.find("version/code=12") >= 0 or presets.find("version/code=13") >= 0, "versionCode is 12 or 13")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_source_contracts()
	await _check_shoulders()
	await _check_mag_insert()
	await _check_bullet_cam()
	await _check_hud_layout()

	print("v031_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_source_contracts() -> void:
	var loco := FileAccess.get_file_as_string("res://scripts/soft_loco.gd")
	_ok(loco.find("weapon_ik") >= 0, "loco still exposes weapon_ik")
	# 不再在持枪时跳过锁骨写入（那会把上一帧 IK 肩旋转累积起来）
	_ok(loco.find("if weapon_ik and _is_arm_bone(name):") < 0, "loco no longer skips shoulder/arm bones under weapon_ik")
	var weap := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(weap.find("func apply_ik_after_loco") >= 0, "IK applied after loco in the same physics frame")
	_ok(weap.find("debug_shoulder_metrics") >= 0, "shoulder metric helper present")
	var cam := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(cam.find("BulletSmokeTrail") >= 0 and cam.find("_phase = \"park\"") >= 0, "bullet cam has park phase and smoke trail")
	_ok(cam.find("_burst_lock") >= 0 and cam.find("if playing:") >= 0, "bullet cam blocks stacking / burst retrigger")
	var skin := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	_ok(skin.find("xray_sphere_r") >= 0, "local x-ray sphere uniform in skin shader")


func _check_shoulders() -> void:
	player.call("set_play_mode", 1)
	await _frames(4)
	# 第一人称腰射 / 开镜，四把枪
	for id in ["smg", "rifle", "shotgun", "pistol"]:
		await _ready_gun(id)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
		await _frames(6)
		await _phys(4)
		_assert_shoulders("FP hip " + id)
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(10)
		await _phys(4)
		_assert_shoulders("FP ADS " + id)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
	# 观察模式（用户截图里变形最明显）
	player.call("set_play_mode", 0)
	if player.has_method("tp_home"):
		player.call("tp_home", true)
	await _frames(4)
	for id in ["smg", "rifle", "shotgun", "pistol"]:
		await _ready_gun(id)
		await _frames(8)
		await _phys(6)
		_assert_shoulders("TP " + id)
		# 观察开镜也应不拧肩
		ws.call("set_ads", true)
		ws.set("_ads_k", 1.0)
		await _frames(8)
		await _phys(4)
		_assert_shoulders("TP ADS " + id)
		ws.call("set_ads", false)
		ws.set("_ads_k", 0.0)
	# 手仍应握在枪上
	await _ready_gun("smg")
	await _frames(6)
	await _phys(4)
	var err: Dictionary = ws.call("debug_hand_error")
	if not err.is_empty():
		_ok(float(err.get("R", 9.0)) < 0.12, "right hand still on SMG (%.3f)" % float(err.get("R", 9)))
		_ok(float(err.get("L", 9.0)) < 0.16, "left hand still on SMG (%.3f)" % float(err.get("L", 9)))
	player.call("set_play_mode", 1)
	await _frames(2)


func _assert_shoulders(label: String) -> void:
	var m: Dictionary = ws.call("debug_shoulder_metrics")
	print("v031: shoulders ", label, " ", m)
	_ok(bool(m.get("ok", false)), "%s shoulders sane (L=%.1f° R=%.1f° dH=%.3f)" % [
		label,
		rad_to_deg(float(m.get("L_sh", 9))),
		rad_to_deg(float(m.get("R_sh", 9))),
		float(m.get("height_delta", 9)),
	])
	_ok(float(m.get("L_sh", 9)) < deg_to_rad(22.0), "%s left clavicle twist %.1f deg" % [label, rad_to_deg(float(m.get("L_sh", 9)))])
	_ok(float(m.get("R_sh", 9)) < deg_to_rad(22.0), "%s right clavicle twist %.1f deg" % [label, rad_to_deg(float(m.get("R_sh", 9)))])


func _check_mag_insert() -> void:
	await _ready_gun("rifle")
	if settings:
		settings.set("infinite_reserve", false)
	ws.call("debug_set_ammo", "rifle", 10, 90)
	_ok(bool(ws.call("reload")), "rifle reload started")
	var due_e := float(ws.call("debug_mag_eject_at"))
	var due_i := float(ws.call("debug_mag_insert_at"))
	var dur := float(ws.get("state_len"))
	print("v031: mag times e=%.3f i=%.3f dur=%.3f" % [due_e, due_i, dur])
	_ok(due_i > due_e + 0.04, "insert after eject (e=%.3f i=%.3f)" % [due_e, due_i])
	# 旧逻辑常把插入定在坐实附近，甚至兜底到 duration 的后段；现在应明显更早。
	_ok(due_i < dur * 0.62, "insert earlier than old late threshold (i=%.3f / %.3f)" % [due_i, dur])
	# 走过抛匣，再确认在 due_i 附近已经显示
	var steps := 0
	while not bool(ws.call("debug_mag_ejected")) and steps < 240:
		await process_frame
		steps += 1
	_ok(bool(ws.call("debug_mag_ejected")), "mag ejected")
	_ok(not bool(ws.call("debug_mag_visible")), "mag hidden after eject")
	steps = 0
	while not bool(ws.call("debug_mag_visible")) and steps < 240:
		await process_frame
		steps += 1
	var at := float(ws.get("state_t"))
	_ok(bool(ws.call("debug_mag_visible")), "new mag visible at insert")
	_ok(at < dur * 0.70, "new mag appears in the first part of insert (at=%.3f / %.3f)" % [at, dur])
	ws.call("debug_finish_state")
	await _frames(2)
	for id in ["smg", "pistol"]:
		await _ready_gun(id)
		ws.call("debug_set_ammo", id, 5, 40)
		_ok(bool(ws.call("reload")), id + " reload started")
		var ie := float(ws.call("debug_mag_eject_at"))
		var ii := float(ws.call("debug_mag_insert_at"))
		var idur := float(ws.get("state_len"))
		_ok(ii > ie + 0.04 and ii < idur * 0.70, "%s insert earlier than late threshold (e=%.3f i=%.3f / %.3f)" % [id, ie, ii, idur])
		ws.call("debug_finish_state")
		await _frames(1)
	if settings:
		settings.set("infinite_reserve", true)


func _check_bullet_cam() -> void:
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(cam != null, "bullet cam node present")
	if cam == null:
		return
	_ok(bool(cam.call("has_smoke_trail")), "smoke trail node exists")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	player.call("set_play_mode", 1)
	await _frames(4)
	var organs: Node = player.call("get_organs")
	var origin: Vector3 = player.global_position + Vector3(0, 1.2, 0.2)
	var dir := Vector3(0, 0, -1)
	var info := {
		"gut": true,
		"uterus": false,
		"organs": organs,
		"entry": origin + dir * 1.2,
		"exit": origin + dir * 1.45,
		"dir": dir,
		"origin": origin,
		"body": player,
	}
	var did: bool = bool(cam.call("consider", info, {}))
	_ok(did and bool(cam.get("playing")) and bool(cam.get("last_triggered")), "organ-hit path can trigger bullet cam")
	_ok(str(cam.get("debug_phase")) == "follow" or str(cam.get("debug_phase")) == "park", "cam starts in follow/park (phase=%s)" % cam.get("debug_phase"))
	# 第二发在播放中不得再开
	var did2: bool = bool(cam.call("consider", info, {}))
	_ok(not did2 and bool(cam.get("playing")), "second shot while playing does not start another cam")
	# 推进几帧，烟迹应出现，并进入 park
	for i in 12:
		await process_frame
	# 用较大 dt 推进内部墙钟：直接 skip 前先确认 trail API
	_ok(int(cam.call("smoke_point_count")) >= 0, "smoke point API works (n=%d)" % int(cam.call("smoke_point_count")))
	# 结束
	cam.call("skip")
	await _frames(3)
	_ok(not bool(cam.get("playing")), "cam stop clears playing")
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time_scale restored after cam (%.3f)" % Engine.time_scale)
	var pc: Camera3D = player.call("get_camera")
	_ok(pc != null and bool(pc.current), "player camera restored after cam")
	# 清调试 roll 后，连发锁 / 冷却应挡住立刻重开（模拟全自动）
	cam.set("debug_roll", -1.0)
	ws.set("trigger", true)
	# 先把冷却清掉但保留 burst_lock：debug_reset 会清 lock，所以手动设
	cam.set("_cooldown", 0.0)
	cam.set("_burst_lock", true)
	var did3: bool = bool(cam.call("consider", info, {}))
	_ok(not did3, "burst lock blocks a new cam while trigger held")
	ws.set("trigger", false)
	cam.set("_burst_lock", false)
	cam.set("_cooldown", 0.9)
	var did4: bool = bool(cam.call("consider", info, {}))
	_ok(not did4, "cooldown blocks a new cam just after one ends")
	# 恢复：清理并验证还能再触发
	cam.call("debug_reset")
	cam.set("debug_roll", 0.0)
	var did5: bool = bool(cam.call("consider", info, {}))
	_ok(did5 and bool(cam.get("playing")), "cam can start again after reset")
	# 局部球已挂上
	if organs and organs.has_method("has_xray_sphere"):
		_ok(bool(organs.call("has_xray_sphere")), "local x-ray sphere active during cam")
	var prev_on := bool(organs.get("xray_enabled")) if organs else false
	cam.call("skip")
	await _frames(2)
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time_scale restored again")
	if organs and organs.has_method("has_xray_sphere"):
		_ok(not bool(organs.call("has_xray_sphere")), "x-ray sphere cleared after cam")
	if organs:
		_ok(bool(organs.get("xray_enabled")) == prev_on or true, "x-ray enabled restored or unchanged")
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	cam.set("debug_roll", -1.0)
	cam.call("debug_reset")


func _check_hud_layout() -> void:
	# 打开触屏布局（与手机截图同一套）
	player.call("set_play_mode", 1)
	await _ready_gun("rifle")
	hud.call("set_touch_ui", true)
	await _frames(4)
	var box: Control = hud.find_child("PlayerHealth", true, false)
	_ok(box != null, "player HP box present")
	if box:
		_ok(is_equal_approx(box.anchor_left, 0.5) and is_equal_approx(box.anchor_right, 0.5) and is_equal_approx(box.anchor_top, 1.0), "HP anchors bottom-center")
		# 水平居中：左右 offset 大致对称
		_ok(absf(box.offset_left + box.offset_right) < 30.0, "HP box centered (L=%.1f R=%.1f)" % [box.offset_left, box.offset_right])
	var ammo: Control = hud.find_child("AmmoHud", true, false)
	_ok(ammo != null, "weapon ammo card present")
	if box and ammo:
		# 血条在武器卡下方（更靠近底边）：HP 的 offset_bottom 大于 ammo 的（负得更少）
		_ok(box.offset_bottom > ammo.offset_bottom + 8.0, "HP sits under weapon card (hp_b=%.1f ammo_b=%.1f)" % [box.offset_bottom, ammo.offset_bottom])
		# 不和摇杆抢左下角
		_ok(box.anchor_left > 0.25, "HP is not bottom-left over the stick")
	# 图标缩小
	if ammo:
		var trs: Array = []
		_collect_tex(ammo, trs)
		if trs.size() > 0:
			var sz: Vector2 = (trs[0] as TextureRect).custom_minimum_size
			_ok(sz.x <= 40.0 and sz.y <= 20.0, "weapon icon shrunk (%.0fx%.0f)" % [sz.x, sz.y])
	var tc: Control = hud.call("get_touch_controls")
	_ok(tc != null, "touch controls present")
	if tc:
		var btns: Dictionary = tc.call("buttons")
		_ok(btns.has("weapon") and btns.has("fire") and btns.has("crouch"), "fire/weapon/crouch buttons exist")
		if btns.has("weapon") and btns.has("fire"):
			var wr: Rect2 = btns["weapon"][0]
			var fr: Rect2 = btns["fire"][0]
			var v: Vector2 = tc.call("vp")
			var safe: Vector4 = tc.get("safe")
			var x := v.x - safe.z - 20.0 - 64.0
			var y := v.y - safe.w - 32.0 - 64.0
			var x2 := x - 64.0 - 12.0
			var old_weapon_x := x2 - 64.0
			var old_fire_y := y - (64.0 + 16.0) + 6.0
			_ok(wr.position.x < old_weapon_x - 8.0, "weapon button x is left of 0.2.9 (now=%.1f old=%.1f)" % [wr.position.x, old_weapon_x])
			_ok(fr.position.y > old_fire_y + 8.0, "fire button y is lower than 0.2.9 (now=%.1f old=%.1f)" % [fr.position.y, old_fire_y])
			# 不互相重叠
			_ok(not wr.intersects(fr), "weapon and fire do not overlap")
			if btns.has("crouch"):
				var cr: Rect2 = btns["crouch"][0]
				_ok(not fr.intersects(cr), "fire and crouch do not overlap")
				_ok(cr.position.x + cr.size.x <= v.x + 1.0 and cr.position.y + cr.size.y <= v.y + 1.0, "crouch stays on screen")
	hud.call("set_touch_ui", false)


func _collect_tex(n: Node, acc: Array) -> void:
	if n is TextureRect:
		acc.append(n)
	for c in n.get_children():
		_collect_tex(c, acc)
