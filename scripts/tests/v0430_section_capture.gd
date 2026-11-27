extends "res://scripts/tests/v0409b_check.gd"
## 断面图截图（需要有显示的渲染器，非 headless）：
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s "-screen 0 1280x720x24" godot --path . \
##     --rendering-method gl_compatibility --rendering-driver opengl3 -s res://scripts/tests/v0430_section_capture.gd
## 输出到 SECTION_OUT（默认 user://section_capture）：<阶段>_<视图>.png。
var OUT := OS.get_environment("SECTION_OUT") if OS.has_environment("SECTION_OUT") else "user://section_capture"


func _run() -> void:
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
	var sec: Node = vm.call("cross_section")
	var ctl: Node = vm.call("tool_controller")
	var opening: Vector3 = vm.call("introitus_world")
	var cerv: Vector3 = vm.call("cervix_world")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	sec.call("set_test_render", true)
	var contact: float = ctl.call("fundus_contact_depth")
	var stages := {
		"a_canal": opening.distance_to(cerv) * 0.45,
		"b_cervix": opening.distance_to(cerv) + float(ctl.call("radius")) * 0.4,
		"c_fundus": contact - 0.006,
	}
	for st in stages.keys():
		ctl.call("debug_set_depth", stages[st])
		await _frames(4)
		await _snap(sec, st)
	# 顶起：连续深推。
	for _i in 12:
		ctl.call("debug_push_depth", contact + 0.06, 0.08)
	await _frames(6)
	print("lift_mm=", float(ctl.call("debug_fundus_lift")) * 1000.0)
	await _snap(sec, "d_pushed")
	print("v0430_section_capture done -> ", ProjectSettings.globalize_path(OUT))
	quit(0)


func _snap(sec: Node, tag: String) -> void:
	for which in ["long", "trans", "coronal"]:
		sec.call("set_view_mode", which)
		await _frames(3)
		var img: Image = sec.call("debug_capture_section", which)
		if img == null:
			print("no image ", tag, which)
			continue
		img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_NEAREST)
		img.save_png(OUT.path_join("%s_%s.png" % [tag, which]))
	sec.call("set_view_mode", "both")
