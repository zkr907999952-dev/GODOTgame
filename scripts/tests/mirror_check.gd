extends SceneTree
## 镜子渲染自检（需要有显示的渲染器，非 headless）：
##   xvfb-run -a godot --path . --rendering-driver opengl3 -s res://scripts/tests/mirror_check.gd
## 在多个相机位姿下截图（默认 user://mirror_check，可用环境变量 MIRROR_CHECK_OUT 指定目录），
## 并对测试标记做像素级反射一致性检查（镜像点的屏幕位置必须是标记颜色）。
## 测试标记只在本脚本内临时创建，不进入游戏场景。

var OUT := OS.get_environment("MIRROR_CHECK_OUT") if OS.has_environment("MIRROR_CHECK_OUT") else "user://mirror_check"

var main: Node
var player: Node
var mirror: Node3D
var free_cam: Camera3D
var markers: Array[Node3D] = []
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	main.add_child(mi)
	mi.global_position = pos
	markers.append(mi)
	return mi


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> Image:
	await _frames(4)
	var img := root.get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	print("mirror_check: saved ", name, " rendering=", mirror.call("is_rendering"))
	return img


## 世界点 p 在镜中的像：眼睛→p' 的连线与镜面交点，投影到屏幕。
func _reflected_screen_pos(cam: Camera3D, p: Vector3) -> Variant:
	var r: Dictionary = mirror.call("debug_reflect_eye", p)
	var pm: Vector3 = r["mirrored"]
	var n: Vector3 = r["normal"]
	var c: Vector3 = r["origin"]
	var e := cam.global_position
	var dir := pm - e
	var denom := dir.dot(n)
	if absf(denom) < 1e-6:
		return null
	var t := (c - e).dot(n) / denom
	var hit := e + dir * t
	if cam.is_position_behind(hit):
		return null
	# 实物遮挡（角色碰撞体等）时跳过像素检查。
	var q := PhysicsRayQueryParameters3D.create(e, hit - (hit - e).normalized() * 0.03)
	if main.get_world_3d().direct_space_state.intersect_ray(q):
		return "occluded"
	return cam.unproject_position(hit)


func _check_marker(img: Image, label: String, p: Vector3, want: Color) -> void:
	var cam := root.get_camera_3d()
	var sp = _reflected_screen_pos(cam, p)
	if sp == null:
		print("mirror_check: [%s] marker reflection not visible" % label)
		return
	if sp is String:
		print("mirror_check: [%s] reflection occluded by real object (skip)" % label)
		return
	var vp_size := root.get_visible_rect().size
	var px := Vector2(sp) * Vector2(img.get_width(), img.get_height()) / vp_size
	var x := int(px.x)
	var y := int(px.y)
	if x < 2 or y < 2 or x >= img.get_width() - 2 or y >= img.get_height() - 2:
		print("mirror_check: [%s] reflection off-screen at %s" % [label, px])
		return
	var col := img.get_pixel(x, y)
	var dist := Vector3(col.r - want.r, col.g - want.g, col.b - want.b).length()
	var ok := dist < 0.35
	if not ok:
		fails += 1
	print("mirror_check: [%s] reflected marker at px=%s col=%s want=%s %s" % [
		label, px.round(), col, want, "OK" if ok else "MISMATCH"])


func _use_free_cam(pos: Vector3, target: Vector3, fov: float = 60.0) -> void:
	free_cam.fov = fov
	free_cam.global_position = pos
	free_cam.look_at(target, Vector3.UP)
	free_cam.current = true


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(5)
	player = main.get_node("Player")
	mirror = main.get_node("RoomMirror")
	var body: Node3D = player.get_node("Body")
	free_cam = Camera3D.new()
	main.add_child(free_cam)
	var hud := main.get_node_or_null("HUD")
	if hud:
		hud.visible = false

	# 角色面向镜子（+Z）。
	body.rotation.y = 0.0
	var pp: Vector3 = player.global_position
	# 非对称标记：红块在角色左侧（面向 +Z 时左 = +X），蓝块高处右侧；绿块贴着镜面。
	var red := _box(Vector3(0.18, 0.18, 0.18), pp + Vector3(0.5, 1.0, 0.0), Color(1, 0, 0))
	var blue := _box(Vector3(0.12, 0.3, 0.12), pp + Vector3(-0.55, 1.5, -0.2), Color(0, 0.2, 1))
	var green := _box(Vector3(0.3, 0.3, 0.3), Vector3(1.2, 0.6, 0.965 - 0.15), Color(0, 1, 0))
	var yellow := _box(Vector3(0.05, 1.6, 0.05), Vector3(-1.3, 0.9, 0.965 - 0.4), Color(1, 0.9, 0))

	var checks := func(img: Image, label: String) -> void:
		_check_marker(img, label + "/red", red.global_position, Color(1, 0, 0))
		_check_marker(img, label + "/blue", blue.global_position, Color(0, 0.2, 1))
		_check_marker(img, label + "/green", green.global_position + Vector3(0, 0, -0.1), Color(0, 1, 0))

	# 1) 展示模式 TP：相机在角色后方（房间内）看镜子。
	player.call("set_play_mode", 0)
	player.set("_yaw", PI)
	player.set("_pitch", -0.12)
	player.call("_apply_camera")
	await _frames(6)
	var img := await _shot("01_tp_display_front")
	checks.call(img, "tp_front")

	# 2) 斜 45° 左 / 3) 斜右。
	_use_free_cam(Vector3(-1.7, 1.5, -1.3), Vector3(0.2, 1.1, 0.965))
	img = await _shot("02_oblique_left")
	checks.call(img, "oblique_left")
	_use_free_cam(Vector3(1.8, 1.5, -1.1), Vector3(-0.4, 1.1, 0.965))
	img = await _shot("03_oblique_right")
	checks.call(img, "oblique_right")

	# 4) 贴近镜面、掠射角（检查贴镜物体与镜像相接）。
	_use_free_cam(Vector3(0.4, 1.0, 0.45), Vector3(1.3, 0.6, 0.965), 70.0)
	img = await _shot("04_close_grazing")
	_use_free_cam(Vector3(-0.2, 1.45, 0.75), Vector3(-0.2, 1.4, 0.965), 60.0)
	img = await _shot("04b_very_close")
	checks.call(img, "close")

	# 5) 第一人称控制模式：看向镜子，镜中应有完整的脸/头发。
	var pcam: Camera3D = player.get_node("CameraPivot/Camera3D")
	pcam.current = true
	player.call("set_play_mode", 1)
	player.set("_yaw", PI)
	player.set("_pitch", -0.05)
	player.set("_body_logic_yaw", PI)
	player.call("_apply_camera")
	await _frames(8)
	img = await _shot("05_fp_control_mirror")
	checks.call(img, "fp")

	# 6) FP 低头看。
	player.set("_pitch", -0.45)
	player.call("_apply_camera")
	await _frames(4)
	img = await _shot("06_fp_look_down")
	checks.call(img, "fp_down")

	# 7) 展示模式默认（相机在空墙外侧）：镜子背面应透明，可看到房间里的角色。
	player.call("set_play_mode", 0)
	player.set("_yaw", 0.0)
	player.set("_pitch", -0.15)
	player.call("_apply_camera")
	await _frames(6)
	await _shot("07_tp_from_behind_mirror")

	# 8) 背对镜子：镜子不在视野内应停止渲染。
	player.set("_yaw", PI)
	player.call("set_play_mode", 1)
	player.set("_yaw", 0.0)
	player.set("_pitch", 0.0)
	player.call("_apply_camera")
	await _frames(6)
	print("mirror_check: facing away rendering=", mirror.call("is_rendering"))
	if bool(mirror.call("is_rendering")):
		fails += 1
		print("mirror_check: expected mirror rendering off when not on screen")

	# 9) 视差序列：横移相机，反射应稳定。
	for i in 3:
		var x := -1.4 + i * 1.4
		_use_free_cam(Vector3(x, 1.4, -1.8), Vector3(x * 0.3, 1.1, 0.965))
		img = await _shot("09_parallax_%d" % i)
		checks.call(img, "parallax_%d" % i)

	# 10) 连续运动：每帧移动相机后立即截取同一帧，检查反射无滞后 / 不漂移。
	for i in 8:
		var a := -0.6 + i * 0.17
		var pos := Vector3(sin(a) * 2.4, 1.3 + 0.1 * sin(i), 0.965 - cos(a) * 2.6)
		_use_free_cam(pos, Vector3(-0.2, 1.1, 0.965))
		await RenderingServer.frame_post_draw
		img = root.get_texture().get_image()
		checks.call(img, "motion_%d" % i)
	img.save_png("%s/10_motion_last.png" % OUT)

	for m in markers:
		m.queue_free()
	print("mirror_check: done fails=", fails)
	quit(1 if fails > 0 else 0)
