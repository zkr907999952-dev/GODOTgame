extends SceneTree
## 渲染自检 4（需要显示）：用户构图上半身高光 / 蹲姿头部朝向（镜子）/ 下蹲过渡第一人称 /
## 地面影子带头（两种模式）/ 城市面部特写。
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-method forward_plus \
##     --resolution 960x600 -s res://scripts/tests/fix_check4.gd
## 环境变量：FIX_CHECK_OUT（默认 user://fix_check4）、FIX_CHECK_TAG（文件名前缀）、
## FIX_CHECK_ONLY（子串列表：tp crouch trans shadow face）。

var OUT := OS.get_environment("FIX_CHECK_OUT") if OS.has_environment("FIX_CHECK_OUT") else "user://fix_check4"
var TAG := OS.get_environment("FIX_CHECK_TAG") if OS.has_environment("FIX_CHECK_TAG") else ""
var ONLY := OS.get_environment("FIX_CHECK_ONLY")
var main: Node
var player: CharacterBody3D
var skel: Skeleton3D
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
	print("fix_check4: saved ", TAG, name)


func _look(from: Vector3, at: Vector3, fov: float = 40.0) -> void:
	cam.current = true
	cam.fov = fov
	cam.near = 0.02
	cam.global_position = from
	cam.look_at(at, Vector3.UP)


func _want(k: String) -> bool:
	return ONLY == "" or k in ONLY


func _bone(n: String) -> Vector3:
	return (skel.global_transform * skel.get_bone_global_pose(skel.find_bone(n))).origin


## 让第一人称相机朝向世界水平方向 dir（不依赖 yaw 约定：试 32 个角取最接近的）。
func _fp_face(dir: Vector3) -> void:
	dir.y = 0.0
	dir = dir.normalized()
	var best := 0.0
	var best_d := -2.0
	for i in 32:
		var a := TAU * float(i) / 32.0
		player.set("_yaw", a)
		player.call("_apply_camera")
		var f: Vector3 = -player.get_camera().global_transform.basis.z
		f.y = 0.0
		var d: float = f.normalized().dot(dir)
		if d > best_d:
			best_d = d
			best = a
	player.set("_yaw", best)


func _fp_mode(on: bool) -> void:
	cam.current = false
	player.call("set_play_mode", 1 if on else 0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if on:
		player.get_camera().current = true


func _run() -> void:
	var abs_out := ProjectSettings.globalize_path(OUT) if OUT.begins_with("user://") else OUT
	DirAccess.make_dir_recursive_absolute(abs_out)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(40)
	player = main.get_node("Player")
	skel = player.find_children("*", "Skeleton3D", true, false)[0]
	var hud := main.get_node_or_null("HUD")
	if hud and hud.has_method("toggle_ui_hidden"):
		hud.call("toggle_ui_hidden")
	cam = Camera3D.new()
	main.add_child(cam)
	await _frames(10)
	var fwd := (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	if _want("tp"):
		# 用户截图构图：观察模式默认正面第三人称。
		player.call("set_tp_view", player.get("_tp_yaw_goal"), 0.05, 1.6, true)
		await _frames(20)
		await _shot("tp_front")
		var chest := _bone("C_Spine_d")
		_look(chest + fwd * 0.75 + Vector3(0, 0.05, 0), chest, 40.0)
		await _shot("tp_chest_close")
	if _want("face"):
		var head := _bone("C_Head_a") + Vector3(0, 0.08, 0)
		_look(head + fwd * 0.42 + right * 0.1, head, 35.0)
		await _shot("face_room")
	if _want("crouch"):
		# 房间：控制模式蹲下，朝镜子（房间 +Z 方向墙）看左/右/上/下；镜头从斜前方 + 第一人称看镜子。
		_fp_mode(true)
		player.call("set_facing", 0.0)
		await _frames(10)
		player.call("_set_stance", "crouch")
		await _frames(60)
		var b0 := float(player.get("_body_logic_yaw"))
		for item in [["c", 0.0, 0.0], ["L", 0.6, 0.0], ["R", -0.6, 0.0], ["U", 0.0, 0.45], ["D", 0.0, -0.45]]:
			player.set("_yaw", b0 + float(item[1]))
			player.set("_pitch", float(item[2]))
			await _frames(30)
			var hp := _bone("C_Head_a")
			var cfw: Vector3 = -player.get_camera().global_transform.basis.z
			print("fix_check4: crouch ", item[0], " cam_fwd=", cfw)
			var fb := (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
			var rb := fb.cross(Vector3.UP).normalized()
			_look(hp + fb * 0.9 + rb * 0.5 + Vector3(0, 0.15, 0), hp + Vector3(0, -0.05, 0), 40.0)
			await _shot("crouch_look_" + item[0])
			cam.current = false
			player.get_camera().current = true
		# 第一人称转身面向镜子（房间 +Z），蹲着看左/右/上/下，镜子里看头部朝向。
		player.call("set_facing", b0 + PI)
		await _frames(5)
		_fp_face(Vector3(0, 0, 1))
		var b1 := float(player.get("_yaw"))
		for item in [["c", 0.0, 0.0], ["L", 0.5, 0.0], ["R", -0.5, 0.0], ["U", 0.0, 0.35], ["D", 0.0, -0.35]]:
			player.set("_yaw", b1 + float(item[1]))
			player.set("_pitch", float(item[2]))
			await _frames(30)
			await _shot("crouch_mirror_" + item[0])
		player.call("_set_stance", "stand")
		await _frames(60)
		_fp_mode(false)
	if _want("trans"):
		_fp_mode(true)
		player.call("set_facing", 0.0)
		player.set("_yaw", float(player.get("_body_logic_yaw")))
		player.set("_pitch", -1.45)
		await _frames(30)
		print("fix_check4: trans cam=", player.get_camera().global_position, " fwd=", -player.get_camera().global_transform.basis.z, " player=", player.global_position, " body_fwd=", skel.global_transform.basis.z, " neck=", _bone("C_Neck_a"))
		# 软件渲染一帧很慢、物理会一次追好几步，放慢时间才能拍到过渡中间。
		Engine.time_scale = 0.12
		player.call("_set_stance", "crouch")
		for i in 4:
			await _frames(3)
			print("fix_check4: trans down ", i, " eye_blend=", player.get("_fp_eye_blend"), " body_blend=", player.get("_stance_blend"))
			await _shot("trans_down_%d" % i)
		await _frames(40)
		player.call("_set_stance", "stand")
		for i in 4:
			await _frames(3)
			print("fix_check4: trans up ", i, " eye_blend=", player.get("_fp_eye_blend"), " body_blend=", player.get("_stance_blend"))
			await _shot("trans_up_%d" % i)
		Engine.time_scale = 1.0
		await _frames(40)
		_fp_mode(false)
	if _want("shadow") or _want("face"):
		await main.call("switch_map", "city", 4)
		await _frames(30)
		fwd = (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
		right = fwd.cross(Vector3.UP).normalized()
	if _want("face"):
		var head2 := _bone("C_Head_a") + Vector3(0, 0.08, 0)
		_look(head2 + fwd * 0.42 + right * 0.1, head2, 35.0)
		await _shot("face_city")
		player.call("set_tp_view", player.get("_tp_yaw_goal"), 0.05, 1.6, true)
		cam.current = false
		player.get_camera().current = true
		await _frames(20)
		await _shot("tp_front_city")
	if _want("shadow"):
		var sun_dir := Vector3(80, 140, 40).normalized()
		var away := Vector3(-sun_dir.x, 0, -sun_dir.z).normalized()
		var p := player.global_position
		var sh := p + away * 1.6
		_look(sh + Vector3(0, 3.2, 0) + away.cross(Vector3.UP) * 1.2, sh, 50.0)
		await _shot("shadow_display")
		_fp_mode(true)
		_fp_face(away)
		player.set("_pitch", -1.05)
		await _frames(30)
		await _shot("shadow_fp")
		_fp_mode(false)
	quit(0)
