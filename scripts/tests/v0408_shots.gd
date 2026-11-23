extends "res://scripts/tests/v0407_check.gd"
## 0.4.08 截图（需要显示服务器）：外阴 / 阴道口近景（合拢 / 拨开），检查床「掰开小穴」。
##   DISPLAY=:2 SHOT_DIR=/workspace/shots/v0408 godot --rendering-driver opengl3 --path . -s res://scripts/tests/v0408_shots.gd

var out_dir := OS.get_environment("SHOT_DIR")


func _grab(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	img.save_png(out_dir.path_join(name))
	print("v0408_shots: wrote ", name)


func _hip_xf(skel: Skeleton3D) -> Transform3D:
	var hi := skel.find_bone("C_Hip_a")
	return skel.global_transform * skel.get_bone_global_pose(hi) * skel.get_bone_global_rest(hi).affine_inverse()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	if not await _enter_bed():
		quit(1)
		return
	player.call("set_play_mode", 0)
	await _frames(20)
	var rig: Node = player.call("get_organs") if player.has_method("get_organs") else player.get_node_or_null("OrganRig")
	var vf = rig.call("vulva_flaps")
	if OS.get_environment("XRAY") != "1":
		rig.call("set_xray_enabled", false)
	var skel: Skeleton3D = player.call("get_skeleton")
	var cam := Camera3D.new()
	cam.near = 0.005
	cam.fov = 40.0
	main.add_child(cam)
	cam.current = true
	var mode := OS.get_environment("SHOT_MODE")
	for sp in [0.0, 1.0]:
		if mode == "action":
			if sp > 0.0:
				hud.call("debug_run_bed_action", "spread_vulva")
				await _frames(90)
		else:
			rig.call("set_vulva_spread", sp)
		await _frames(4)
		var hx := _hip_xf(skel)
		var tgt: Vector3 = hx * (vf.opening as Vector3)
		for view in [["low", Vector3(0.0, -0.10, 0.07)], ["side", Vector3(0.09, -0.07, 0.06)], ["far", Vector3(0.0, -0.30, 0.35)]]:
			cam.global_position = hx * ((vf.opening as Vector3) + (view[1] as Vector3))
			cam.look_at(tgt, hx.basis * Vector3(0, 0, 1) if absf((view[1] as Vector3).normalized().z) < 0.9 else Vector3.UP)
			await _frames(3)
			await _grab("%s_%s_%d.png" % [mode if mode != "" else "flaps", view[0], int(sp)])
	quit(0)
