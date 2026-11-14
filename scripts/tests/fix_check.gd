extends SceneTree
## 渲染自检（需要显示，非 headless）：内脏布局 / 头发头皮固定 + 发尾甩动 / 头发渲染 / 观察相机 / 乳摇。
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##     --resolution 960x600 -s res://scripts/tests/fix_check.gd
## 输出目录：环境变量 FIX_CHECK_OUT（默认 user://fix_check）。

var OUT := OS.get_environment("FIX_CHECK_OUT") if OS.has_environment("FIX_CHECK_OUT") else "user://fix_check"
var main: Node
var player: Node
var skel: Skeleton3D
var organs: Node
var sec: RefCounted
var cam: Camera3D


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _grab() -> Image:
	return root.get_texture().get_image()


func _save(img: Image, name: String) -> void:
	img.save_png("%s/%s.png" % [OUT, name])
	print("fix_check: saved ", name)


func _shot(name: String) -> void:
	await _frames(3)
	_save(_grab(), name)


func _look(from: Vector3, at: Vector3, fov: float = 40.0) -> void:
	cam.current = true
	cam.fov = fov
	cam.near = 0.02
	cam.global_position = from
	cam.look_at(at, Vector3.UP)


func _strip(imgs: Array, crop: Rect2i) -> Image:
	var out := Image.create(crop.size.x * imgs.size(), crop.size.y, false, Image.FORMAT_RGBA8)
	for i in imgs.size():
		var im: Image = imgs[i]
		im.convert(Image.FORMAT_RGBA8)
		out.blit_rect(im, crop, Vector2i(crop.size.x * i, 0))
	return out


func _bone_w(n: String) -> Transform3D:
	return skel.global_transform * skel.get_bone_global_pose(skel.find_bone(n))


func _run() -> void:
	var abs_out := ProjectSettings.globalize_path(OUT) if OUT.begins_with("user://") else OUT
	DirAccess.make_dir_recursive_absolute(abs_out)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(40)
	player = main.get_node("Player")
	skel = player.find_children("*", "Skeleton3D", true, false)[0]
	organs = player.call("get_organs")
	for c in player.get_children():
		if c.get("secondary") != null:
			sec = c.get("secondary")
	var hud := main.get_node_or_null("HUD")
	if hud and hud.has_method("_sync_from_systems"):
		hud.call("_sync_from_systems")
	await _frames(10)
	# 1) 默认观察视角（房间内、正对角色）
	await _shot("01_tp_default")
	if hud and hud.has_method("_toggle_panel"):
		hud.call("_toggle_panel", 3)  # 摄像机面板
		await _shot("01b_tp_camera_panel")
		hud.call("_toggle_panel", 3)
	cam = Camera3D.new()
	main.add_child(cam)
	var fwd := (skel.global_transform.basis * Vector3(0, 0, 1)).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	# 2) 内脏：正面 / 侧面（X 光拉满看布局）
	organs.call("set_xray_amount", 1.0)
	var n: Vector3 = organs.call("navel_world")
	_look(n + fwd * 0.75 + Vector3(0, 0.02, 0), n + Vector3(0, -0.03, 0), 42.0)
	await _shot("02_organs_front")
	_look(n + right * 0.75 + fwd * 0.12, n + Vector3(0, -0.03, -0.03), 42.0)
	await _shot("03_organs_side")
	organs.call("set_xray_amount", 0.38)
	_look(n + fwd * 1.3 + Vector3(0, 0.15, 0), n + Vector3(0, 0.15, 0), 45.0)
	await _shot("04_organs_torso_default_xray")
	# 3) 头发：头顶近景（头皮不透）
	var h := _bone_w("C_Head_a").origin + Vector3(0, 0.07, 0)
	_look(h + fwd * 0.35 + Vector3(0, 0.3, 0), h, 35.0)
	await _shot("05_hair_crown_front")
	_look(h - fwd * 0.5 + Vector3(0, 0.12, 0), h - Vector3(0, 0.05, 0), 35.0)
	await _shot("06_hair_back")
	# 4) 甩发序列：侧后方，头顶应完全不动，只有垂下的发尾甩
	_look(h - fwd * 0.9 + right * 0.9 + Vector3(0, -0.15, 0), h - Vector3(0, 0.35, 0), 42.0)
	await _frames(20)
	var seq: Array = [_grab()]
	if sec:
		sec.call("debug_jerk_root", right * 0.22)
	for i in 3:
		await _frames(2 + i)
		seq.append(_grab())
	var vs := seq[0].get_size() as Vector2i
	_save(_strip(seq, Rect2i(vs.x / 4, 0, vs.x / 2, vs.y)), "07_hair_swing_strip")
	# 5) 乳摇：侧面，冲击后摆动并回稳
	var ch := _bone_w("C_Spine_d").origin + fwd * 0.08 - Vector3(0, 0.07, 0)
	_look(ch + right * 0.6 + fwd * 0.25, ch, 38.0)
	await _frames(30)
	var br: RefCounted = sec.get("breasts") if sec else null
	var js: Array = [_grab()]
	if br:
		br.call("debug_kick", Vector3(0, -1.1, 0.2))
	for i in 4:
		await _frames(1)
		js.append(_grab())
		if br:
			print("fix_check: jiggle ", br.call("debug_state"))
	vs = js[0].get_size()
	_save(_strip(js, Rect2i(vs.x * 3 / 10, vs.y / 8, vs.x * 2 / 5, vs.y * 3 / 4)), "08_jiggle_strip")
	await _frames(90)
	await _shot("09_jiggle_settled")
	quit(0)
