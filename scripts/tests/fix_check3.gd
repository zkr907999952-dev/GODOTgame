extends SceneTree
## 渲染自检 3（需要显示）：腹部透视正面（用户截图构图）/ 房间光照 / 城市击腹+拖拽 / 第一人称跑跳。
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-method forward_plus \
##     --resolution 960x600 -s res://scripts/tests/fix_check3.gd
## 输出目录：FIX_CHECK_OUT（默认 user://fix_check3），文件名前缀：FIX_CHECK_TAG。

var OUT := OS.get_environment("FIX_CHECK_OUT") if OS.has_environment("FIX_CHECK_OUT") else "user://fix_check3"
var TAG := OS.get_environment("FIX_CHECK_TAG") if OS.has_environment("FIX_CHECK_TAG") else ""
var ONLY := OS.get_environment("FIX_CHECK_ONLY")
var main: Node
var player: CharacterBody3D
var skel: Skeleton3D
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
	img.save_png("%s/%s%s.png" % [OUT, TAG, name])
	print("fix_check3: saved ", TAG, name)


func _look(from: Vector3, at: Vector3, fov: float = 40.0) -> void:
	cam.current = true
	cam.fov = fov
	cam.near = 0.02
	cam.global_position = from
	cam.look_at(at, Vector3.UP)


func _want(k: String) -> bool:
	return ONLY == "" or k in ONLY


func _run() -> void:
	var abs_out := ProjectSettings.globalize_path(OUT) if OUT.begins_with("user://") else OUT
	DirAccess.make_dir_recursive_absolute(abs_out)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(40)
	player = main.get_node("Player")
	skel = player.find_children("*", "Skeleton3D", true, false)[0]
	organs = player.call("get_organs")
	var hud := main.get_node_or_null("HUD")
	if hud and hud.has_method("toggle_ui_hidden"):
		hud.call("toggle_ui_hidden")
	await _frames(10)
	if _want("light"):
		await _shot("light_room_default")
	cam = Camera3D.new()
	main.add_child(cam)
	var fwd := (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var n: Vector3 = organs.call("navel_world")
	if _want("xray"):
		# 用户截图构图：正面，胸下到大腿
		_look(n + fwd * 1.05 + Vector3(0, 0.12, 0), n + Vector3(0, 0.08, 0), 36.0)
		await _shot("xray_front")
		_look(n + fwd * 0.9 + right * 0.45 + Vector3(0, 0.1, 0), n + Vector3(0, 0.06, 0), 36.0)
		await _shot("xray_oblique")
	if _want("light"):
		_look(n + fwd * 2.2 + right * 0.9 + Vector3(0, 0.35, 0), n + Vector3(0, 0.1, 0), 40.0)
		await _shot("light_room_full")
	if _want("city"):
		await main.call("switch_map", "city", 2)  # 跨海大桥，yaw = π/2
		await _frames(20)
		player.call("set_facing", 0.7)  # 任意朝向
		await _frames(10)
		fwd = (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
		right = fwd.cross(Vector3.UP).normalized()
		n = organs.call("navel_world")
		organs.call("strike_at", n + fwd * 0.12 + Vector3(0, 0.02, 0), 0.9, 0.5)
		_look(n + fwd * 0.75 + Vector3(0, 0.05, 0), n, 40.0)
		await _frames(14)
		await _shot("city_strike")
		organs.call("reset_interaction")
		var g := n + fwd * 0.12 + right * 0.03
		organs.call("begin_drag", g)
		organs.call("update_drag", g + right * 0.07 + fwd * 0.05)
		await _frames(30)
		await _shot("city_drag")
		organs.call("end_drag")
	if _want("fp"):
		cam.current = false
		await main.call("switch_map", "city", 4)
		player.call("set_play_mode", 1)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		player.set("_pitch", -1.25)
		player.get_camera().current = true
		await _frames(20)
		print("fix_check3: fp idle ", player.call("debug_fp_state"), " body=", player.get_node("Body").position, " player=", player.global_position)
		await _shot("fp_idle_lookdown")
		Input.action_press("move_forward")
		Input.action_press("sprint")
		await _frames(50)
		print("fix_check3: fp run ", player.call("debug_fp_state"), " body=", player.get_node("Body").position, " player=", player.global_position)
		await _shot("fp_run_lookdown")
		player.set("_pitch", 0.0)
		await _frames(6)
		await _shot("fp_run_ahead")
		player.set("_pitch", -1.1)
		Input.action_press("jump")
		await _frames(2)
		Input.action_release("jump")
		await _frames(12)
		await _shot("fp_jump_mid")
		await _frames(14)
		await _shot("fp_jump_land")
		Input.action_release("move_forward")
		Input.action_release("sprint")
	quit(0)
