extends "res://scripts/tests/v0409b_check.gd"
## 3D 视图截图：体表隐藏，直接看球 / 杆撑开的阴道和子宫（需要有显示的渲染器）。
##   VIEW_OUT=/tmp/x LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . --rendering-method gl_compatibility \
##     --rendering-driver opengl3 -s res://scripts/tests/v0430_view_capture.gd
var OUT := OS.get_environment("VIEW_OUT") if OS.has_environment("VIEW_OUT") else "user://view_capture"


func _run() -> void:
	root.size = Vector2i(900, 700)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	if not await _enter_bed():
		quit(1)
		return
	var vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	vm.call("enter")
	await _frames(2)
	vm.call("set_tool", "ball_rod")
	await _frames(4)
	hud.visible = false
	var ctl: Node = vm.call("tool_controller")
	var org: Node = player.call("get_organs")
	var opening: Vector3 = vm.call("introitus_world")
	var cerv: Vector3 = vm.call("cervix_world")
	for mi in org.get("skin_meshes"):
		if mi is MeshInstance3D:
			(mi as MeshInstance3D).visible = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var contact: float = ctl.call("fundus_contact_depth")
	var stages := {"a_vagina": opening.distance_to(cerv) * 0.5, "b_cervix": opening.distance_to(cerv) + 0.004, "c_uterus": contact - 0.02, "d_pushed": contact + 0.08}
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.near = 0.01
	cam.far = 3.0
	cam.fov = 40.0
	for st in stages.keys():
		var d: float = stages[st]
		for _i in 14:
			ctl.call("debug_push_depth", d, 0.08)
		await _frames(4)
		var tip: Vector3 = ctl.call("tip_world")
		var axis: Vector3 = (vm.call("canal_axis_world") as Vector3).normalized()
		var side: Vector3 = axis.cross(Vector3.UP)
		if side.length_squared() < 1e-6:
			side = axis.cross(Vector3.RIGHT)
		side = side.normalized()
		var focus: Vector3 = (opening + tip) * 0.5 if st == "a_vagina" else tip - axis * 0.02
		cam.global_position = focus + side * 0.16 + Vector3.UP * 0.02
		cam.look_at(focus, Vector3.UP)
		await _frames(3)
		var img: Image = root.get_texture().get_image()
		img.save_png(OUT.path_join(st + ".png"))
	print("view capture done")
	quit(0)
