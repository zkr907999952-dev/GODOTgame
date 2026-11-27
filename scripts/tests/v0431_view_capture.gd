extends "res://scripts/tests/v0431_check.gd"
## 0.4.17 截图（需要显示）：VIEW_OUT=目录

var cam: Camera3D
var OUTD := ""


func _shot(name: String, focus0: Vector3) -> void:
	var so0: Node = s.call("soft_organ", "uterus")
	var focus := focus0
	var dist := 0.30
	if so0:
		focus = (so0.call("hang_point") as Vector3) + (so0.get("outward") as Vector3) * 0.03
		dist = 0.17
	for view in ["side", "front"]:
		var axis: Vector3 = (ctl.call("_axis_world") as Vector3).normalized()
		var side := axis.cross(Vector3.UP).normalized()
		var outw: Vector3 = Vector3(0, 0.54, 0.84)
		var so: Node = s.call("soft_organ", "uterus")
		if so:
			outw = so.get("outward")
		if view == "side":
			cam.global_position = focus + side * dist + Vector3.UP * 0.03
		else:
			cam.global_position = focus + outw.normalized() * dist + side * 0.05
		cam.look_at(focus, Vector3.UP)
		await _frames(3)
		var img: Image = root.get_texture().get_image()
		img.save_png(OUTD.path_join(name + "_" + view + ".png"))


func _run() -> void:
	OUTD = OS.get_environment("VIEW_OUT")
	DirAccess.make_dir_recursive_absolute(OUTD)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	await _enter_bed()
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	var so := await _extract()
	org = player.call("get_organs")
	vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	vm.call("enter")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	hud.visible = false
	ctl = vm.call("tool_controller")
	lk = ctl.call("link")
	ctl.call("set_diameter", 0.026)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.near = 0.01
	cam.far = 3.0
	cam.fov = 45.0
	var L: float = ctl.call("_canal_length")
	var V: Vector3 = (ctl.call("_opening_world") as Vector3) + (ctl.call("_axis_world") as Vector3) * L
	var W: Vector3 = so.get("wound_center")
	var focus := (V + W) * 0.5
	await _step(-0.03, 4)
	await _shot("a_hanging", focus)
	var d := 0.0
	while d < L + 0.02:
		d += 0.004
		await _step(d, 2)
	await _step(L + 0.02, 40)
	await _shot("b_straight", focus)
	var s_c := float(lk.get("s_cervix"))
	d = L + 0.02
	while d < s_c - 0.012:
		d += 0.004
		await _step(d, 2)
	await _shot("c_conduit", focus)
	for i2 in 90:
		await _step(s_c + 0.02, 1)
		if bool(ctl.get("through_cervix")):
			break
	await _step(float(ctl.get("depth")) + 0.01, 60)
	await _shot("d_in_uterus", focus)
	ctl.set("dragging", true)
	d = float(ctl.get("depth"))
	for i in 30:
		d -= 0.006
		await _step(d, 1)
		if bool(lk.get("reeling")):
			break
	for j in 12:
		d -= 0.005
		await _step(d, 1)
	await _shot("e_reel_mid", focus)
	while bool(lk.get("reeling")):
		d -= 0.005
		await _step(d, 1)
	await _shot("f_handoff", focus)
	var pc: Node = org.call("prolapse")
	var ax: Vector3 = ctl.call("_axis_world")
	var tgt: Vector3 = ctl.call("tip_world")
	for k2 in 60:
		tgt -= ax * 0.002
		ctl.call("drive_caught_to", tgt)
		await _phys(1)
	await _shot("g_prolapse", (ctl.call("_opening_world") as Vector3))
	print("capture done")
	quit(0)
