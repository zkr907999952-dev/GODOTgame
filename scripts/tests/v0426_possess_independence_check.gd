extends SceneTree
## 未发布（t99u）：分身 / 附身 = 多个独立可控角色。阴道互动、脱垂、手术、透视、扩张等状态按身体独立，
## 工具永远作用在当前附身 / 当前对象的身体上；来回切换不串、不污染。
##   godot --headless --path . -s res://scripts/tests/v0426_possess_independence_check.gd

var main: Node
var player: Node
var pz: Node
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0426: OK   ", msg)
	else:
		fails += 1
		push_error("v0426: FAIL " + msg)


func _dil(org: Node) -> float:
	var v: Variant = org.get("_dilate_p")
	return (v as Vector4).x if v is Vector4 else 0.0


func _wait_transition() -> void:
	var t0 := Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame


func _possess(c: Node) -> String:
	var msg := str(pz.call("possess", c))
	await _frames(4)
	await _wait_transition()
	await _frames(2)
	return msg


func _ball(vm: Node, depth: float) -> Node:
	vm.call("set_tool", "ball_rod")
	await _frames(2)
	var ctl: Node = vm.call("tool_controller")
	if ctl:
		ctl.call("debug_set_depth", depth)
	await _frames(3)
	return ctl


func _cut(s: Node) -> bool:
	s.call("set_tool", "scalpel")
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	s.call("set_cut_mode", "ring")
	var ok := bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false))
	s.call("debug_finish_cut_anim")
	return ok and bool(s.get("cut_open"))


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	pz = main.get("possession")
	var vs: Node = main.get("vehicle_system")
	main.call("clear_clones")
	await _frames(2)
	var p0: Vector3 = player.global_position
	main.call("spawn_clone", p0 + Vector3(1.4, 0, -0.6))
	await _frames(4)
	var a: Node = main.call("get_clones")[0]
	var org_p: Node = player.call("get_organs")
	var org_a: Node = a.call("get_organs")
	var s_p: Node = player.call("get_surgery")
	var s_a: Node = a.call("get_surgery")
	var vm: Node = player.call("get_vagina_mode")

	# ---- 0. 「掰开小穴」动作的进度属于身体：附身后跟着身体走
	var acts_p0 = player.call("get_actions")
	_ok(bool(acts_p0.call("toggle_on", player, "spread_vulva")), "start the spread action on body P")
	await _phys(90)
	var sp_p0 := float(org_p.call("vulva_spread"))
	_ok(sp_p0 > 0.5 and float(org_a.call("vulva_spread")) < 0.05, "spread is on P only (P=%.2f A=%.2f)" % [sp_p0, float(org_a.call("vulva_spread"))])
	await _possess(a)
	await _phys(10)
	_ok(str(a.call("get_actions").get("active_id")) == "spread_vulva" and not bool(player.call("get_actions").call("is_active")), "after possession the action continues on body P (now the clone), not on the new body")
	_ok(float(org_p.call("vulva_spread")) > 0.5 and float(org_a.call("vulva_spread")) < 0.05, "spread stays on body P (P=%.2f A=%.2f)" % [float(org_p.call("vulva_spread")), float(org_a.call("vulva_spread"))])
	a.call("get_actions").call("stop")
	await _phys(90)
	await _possess(a)
	_ok(player.call("get_organs") == org_p and float(org_p.call("vulva_spread")) < 0.05, "back in P, the stopped action has closed")

	# ---- 1. 本体 P：阴道互动 + 脱垂 + 临时透视，只作用在 P 身上
	_ok(bool(main.call("toggle_vagina")) or bool(vm.call("is_active")), "Y enters a vagina session on the controlled body")
	_ok(vm.get("organs") == org_p and vm.call("get_subject") == player, "session targets body P")
	var ctl: Node = await _ball(vm, 0.05)
	_ok(ctl != null and _dil(org_p) > 0.5 and _dil(org_a) < 1e-4, "ball rod dilates P only (P=%.2f A=%.2f)" % [_dil(org_p), _dil(org_a)])
	var a_x0 := bool(org_a.get("xray_enabled"))
	var a_xa0 := float(org_a.get("xray_amount"))
	vm.call("set_camera_preset", "abdomen", true)
	await _frames(3)
	_ok(bool(org_p.get("xray_enabled")) and bool(org_a.get("xray_enabled")) == a_x0 and is_equal_approx(float(org_a.get("xray_amount")), a_xa0), "the session's temporary x-ray stays on P, clones keep the user setting (A on=%s amt=%.2f)" % [org_a.get("xray_enabled"), org_a.get("xray_amount")])
	vm.call("set_camera_preset", "free", true)
	var pc_p: Node = org_p.call("prolapse")
	pc_p.call("set_amount", 0.35)
	await _phys(3)
	_ok(bool(org_p.call("has_prolapse")) and not bool(org_a.call("has_prolapse")), "prolapse lives on P only")
	# ---- 2. 会话中直接附身 A：会话先在 P 身上收尾，再换身体
	var msg := await _possess(a)
	print("v0426: possess A -> ", msg)
	_ok(player.call("get_organs") == org_a and a.call("get_organs") == org_p, "bodies swapped (player has A, clone node has P)")
	_ok(not bool(vm.call("is_active")) and vm.call("tool_controller") == null, "possessing ends the vagina session")
	await _frames(70)
	_ok(_dil(org_p) < 1e-4, "the ball's dilation was released on body P, not left behind (P=%.3f)" % _dil(org_p))
	_ok(not org_p.has_meta("xray_session") and not org_a.has_meta("xray_session"), "no temporary x-ray override leaked")
	_ok(bool(org_p.call("has_prolapse")) and not bool(org_a.call("has_prolapse")), "prolapse stays with body P (now the clone), A has none")
	_ok(vm.get("organs") == org_a and vm.get("surgery") == s_a, "vagina controller now resolves A's organs / surgery")
	# ---- 3. 在新身体 A 上互动：只改 A
	_ok(bool(main.call("toggle_vagina")) or bool(vm.call("is_active")), "enter vagina session on body A")
	ctl = await _ball(vm, 0.05)
	_ok(_dil(org_a) > 0.5 and _dil(org_p) < 1e-4, "ball rod now dilates A only (A=%.2f P=%.2f)" % [_dil(org_a), _dil(org_p)])
	var intro: Vector3 = vm.call("introitus_world")
	var d_me := Vector2(intro.x - player.global_position.x, intro.z - player.global_position.z).length()
	var d_other := Vector2(intro.x - a.global_position.x, intro.z - a.global_position.z).length()
	_ok(d_me < 0.35 and d_other > 0.5, "camera / tool target the controlled body's introitus (%.2f m from me, %.2f m from clone)" % [d_me, d_other])
	var tip: Vector3 = ctl.call("tip_world") if ctl else Vector3.ZERO
	_ok(Vector2(tip.x - player.global_position.x, tip.z - player.global_position.z).length() < 0.35, "ball rod is inside the controlled body")
	# 宿主换了 OrganRig（模拟任何换身体路径）→ 会话自动在旧身体上收尾退出
	pz.call("possess", a)
	await _frames(4)
	await _wait_transition()
	await _frames(60)
	_ok(not bool(vm.call("is_active")) and _dil(org_a) < 1e-4 and _dil(org_p) < 1e-4, "switching back mid-session releases A's dilation and touches nothing else (A=%.3f P=%.3f)" % [_dil(org_a), _dil(org_p)])
	_ok(player.call("get_organs") == org_p and bool(org_p.call("has_prolapse")), "back in body P, its prolapse is intact")
	pc_p.call("reset")
	await _phys(2)

	# ---- 4. 检查床上的分身 B：手术只作用于 B；对 B 的阴道互动也只作用于 B
	var bed: Node = null
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
	_ok(bed != null, "exam bed exists")
	if bed == null:
		_finish()
		return
	player.global_position = (bed as Node3D).global_position + Vector3(1.2, 0.1, 0.0)
	player.reset_physics_interpolation()
	await _phys(3)
	vs.call("_update_nearest")
	vs.set("nearest", bed)
	main.call("place_clone_on_bed", bed)
	await _frames(4)
	var b: Node = null
	for c in main.call("get_clones"):
		if bool(c.call("is_on_exam_bed")):
			b = c
	_ok(b != null, "clone B is on the exam bed")
	if b == null:
		_finish()
		return
	# place_clone_on_bed 会优先复用现成的分身；再生成一个站着的分身 C 作为「其它角色」对照。
	main.call("spawn_clone", player.global_position + Vector3(0.0, 0, 1.4))
	await _frames(4)
	var c3: Node = null
	for c in main.call("get_clones"):
		if c != b:
			c3 = c
	a = c3
	var org_b: Node = b.call("get_organs")
	var s_b: Node = b.call("get_surgery")
	var s_now: Node = player.call("get_surgery")
	vs.set("nearest", bed)
	_ok(main.call("surgery_subject") == b, "surgery subject is the clone on the nearby bed")
	main.call("toggle_surgery")
	await _frames(3)
	_ok(bool(s_b.call("is_active")) and not bool(s_now.call("is_active")), "surgery toggle opens B's surgery only")
	_ok(_cut(s_b), "cut B open")
	_ok(not bool(s_now.get("cut_open")) and not bool((a.call("get_surgery") as Node).get("cut_open")), "the cut exists on B only (me=%s other=%s)" % [s_now.get("cut_open"), (a.call("get_surgery") as Node).get("cut_open")])
	_ok(s_b.call("_find_exam_bed") == bed, "B's surgery finds B's own bed (flap catch board / floor)")
	# 手术中切到对 B 的阴道互动
	vs.set("nearest", bed)
	_ok(main.call("vagina_mode_of", b) == vm, "the vagina controller can target the clone on the bed")
	main.call("toggle_vagina")
	await _frames(3)
	_ok(bool(vm.call("is_active")) and vm.call("get_subject") == b and vm.get("organs") == org_b, "vagina session targets clone B (subject=%s)" % str(vm.call("get_subject")))
	_ok(not bool(s_b.call("is_active")) and bool(s_b.get("cut_open")), "entering it closes B's surgery but keeps the incision")
	ctl = await _ball(vm, 0.05)
	_ok(_dil(org_b) > 0.5 and _dil(player.call("get_organs")) < 1e-4 and _dil(a.call("get_organs")) < 1e-4, "ball dilates B only (B=%.2f me=%.2f A=%.2f)" % [_dil(org_b), _dil(player.call("get_organs")), _dil(a.call("get_organs"))])
	var ib: Vector3 = vm.call("introitus_world")
	_ok(ib.distance_to((b as Node3D).global_position) < 1.4 and ib.distance_to(player.global_position) > 0.5, "camera anchors on B's introitus")
	# 对 B 做会话时，受控角色自己的「站姿进入」被挡住，不串会话
	_ok(not bool(main.call("can_enter_body_mode_from_observe")), "cannot start a second session on yourself while one runs on B")
	vm.call("set_camera_preset", "abdomen", true)
	await _frames(4)
	_ok(bool(org_b.get("xray_enabled")) and org_b.has_meta("xray_session"), "B's temporary x-ray is not overwritten by the clone settings sync")
	# 按 Y 退出（对象是分身也能退）
	main.call("toggle_vagina")
	await _frames(60)
	_ok(not bool(vm.call("is_active")) and _dil(org_b) < 1e-4 and not org_b.has_meta("xray_session"), "Y exits B's session and B's dilation / x-ray are restored")
	_ok(vm.call("get_subject") == player, "controller falls back to the controlled body")
	# ---- 5. 附身 B（带切口），再切回：每具身体的手术状态各自保留
	var org_me: Node = player.call("get_organs")
	await _possess(b)
	_ok(player.call("get_surgery") == s_b and bool(s_b.get("cut_open")) and s_b.get("player") == player, "possessing B takes over B's incision")
	_ok(not bool(s_now.get("cut_open")) and s_now.get("player") == b, "the body you left has no incision and its surgery host is clone B")
	var ok_tool := bool(main.call("toggle_vagina")) or bool(vm.call("is_active"))
	_ok(ok_tool and vm.get("organs") == org_b, "vagina session in possessed B targets B's organs")
	vm.call("exit")
	await _frames(2)
	await _possess(b)
	_ok(player.call("get_organs") == org_me and b.call("get_surgery") == s_b and bool(s_b.get("cut_open")), "switching back: B keeps its incision, you have your own body")
	_finish()


func _finish() -> void:
	print("v0426: fails=", fails)
	quit(1 if fails > 0 else 0)
