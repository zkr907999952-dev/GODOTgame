extends SceneTree
## 腹部透视 / 脏器 渲染自检（需要显示，非 headless）：
##   xvfb-run -a godot --path . -s res://scripts/tests/organs_check.gd
## 截图输出 user://organs_check（或环境变量 ORGANS_CHECK_OUT）。

var OUT := OS.get_environment("ORGANS_CHECK_OUT") if OS.has_environment("ORGANS_CHECK_OUT") else "user://organs_check"
var main: Node
var player: Node
var organs: Node
var cam: Camera3D


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await _frames(3)
	var img := root.get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	print("organs_check: saved ", name, " ", organs.call("debug_snapshot"))


func _look(from: Vector3, at: Vector3, fov: float = 40.0) -> void:
	cam.current = true
	cam.fov = fov
	cam.near = 0.02
	cam.global_position = from
	cam.look_at(at, Vector3.UP)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT) if OUT.begins_with("user://") else OUT)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(10)
	player = main.get_node("Player")
	organs = player.call("get_organs")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 1) default display TP view
	await _frames(20)
	await _shot("01_display_default")
	cam = Camera3D.new()
	main.add_child(cam)
	var f: Transform3D = organs.call("abdomen_frame")
	var n := f.origin
	var fwd := f.basis.z
	# 2) close front belly, xray on (default 0.38)
	_look(n + fwd * 0.62 + Vector3(0.12, 0.08, 0), n + Vector3(0, -0.03, 0))
	await _shot("02_belly_xray_default")
	organs.call("set_xray_amount", 1.0)
	await _shot("03_belly_xray_full")
	organs.call("set_xray_enabled", false)
	await _shot("04_belly_xray_off")
	organs.call("set_xray_enabled", true)
	organs.call("set_xray_amount", 0.38)
	# 3) strike
	organs.set("interact_mode", "strike")
	var hit = organs.call("ray_hit_belly", cam.global_position, (n + Vector3(0.03, -0.02, 0) - cam.global_position).normalized())
	print("organs_check: strike hit ", hit)
	if hit != null:
		organs.call("strike_at", hit, 0.9, 0.32)
	await _frames(12)
	await _shot("05_strike")
	await get_root().get_tree().create_timer(3.8).timeout
	# 4) drag
	organs.set("interact_mode", "drag")
	var hit2 = organs.call("ray_hit_belly", cam.global_position, (n + Vector3(-0.04, -0.06, 0) - cam.global_position).normalized())
	print("organs_check: drag hit ", hit2)
	organs.call("begin_drag", hit2)
	organs.call("update_drag", hit2 + f.basis.x * -0.09 + f.basis.y * 0.03 + fwd * 0.05)
	await _frames(30)
	await _shot("06_drag")
	organs.call("end_drag")
	await _frames(90)
	print("organs_check: after release drag_off=", organs.call("drag_offset_length"))
	# side view
	_look(n + f.basis.x * 0.7 + fwd * 0.35 + Vector3(0, 0.05, 0), n + Vector3(0, -0.04, -0.03))
	await _shot("07_side_xray")
	# 6) mirror: face the mirror, camera behind shoulder
	await _frames(5)
	var f2: Transform3D = organs.call("abdomen_frame")
	_look(f2.origin - f2.basis.z * 0.9 + f2.basis.x * 0.4 + Vector3(0, 0.3, 0), f2.origin + f2.basis.z * 1.2, 50.0)
	await _frames(10)
	await _shot("09_mirror")
	# 5) FP looking down
	cam.current = false
	player.call("set_play_mode", 1)
	player.set("_pitch", -1.5)
	player.call("_apply_camera")
	await _frames(20)
	await _shot("08_fp_down")
	player.call("set_play_mode", 0)
	# 7) crouch / prone: organs must ride the skeleton
	for st in ["crouch", "prone"]:
		player.set("_stance", st)
		player.call("_apply_stance_capsule")
		await _frames(60)
		var f3: Transform3D = organs.call("abdomen_frame")
		_look(f3.origin + f3.basis.z * 0.75 + f3.basis.x * 0.35 + Vector3(0, 0.25, 0), f3.origin, 45.0)
		await _shot("10_%s" % st)
	quit(0)
