extends SceneTree
## 拳交 / 刺刀 / 长刺刀 + 分身 + 抬头头发 自检（headless 可跑）：
##   godot --headless --path . -s res://scripts/tests/tools_clones_check.gd
## 设置 SHOT_DIR 环境变量（且非 headless）时额外保存两张关键截图。

var main: Node
var player: Node
var organs: Node
var fails := 0
var SHOT_DIR := OS.get_environment("SHOT_DIR")


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("tools_clones: OK   ", msg)
	else:
		fails += 1
		push_error("tools_clones: FAIL " + msg)


func _shot(name: String) -> void:
	if SHOT_DIR == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
	root.get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, name])
	print("tools_clones: saved ", SHOT_DIR, "/", name, ".png")


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(20)
	player = main.get_node("Player")
	organs = player.call("get_organs")
	var hud: Node = main.get_node("HUD")
	if SHOT_DIR != "":
		hud.call("toggle_ui_hidden")
	await _check_tools(hud)
	await _check_hair()
	await _check_clones(hud)
	print("tools_clones: done fails=", fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------ tools
func _check_tools(hud: Node) -> void:
	var t: RefCounted = organs.get("tools")
	_ok(t != null, "insert tools present")
	_ok(organs.call("mode_is_live", "fist") and organs.call("mode_is_live", "bayonet_long"), "fist/bayonet modes live")
	# 拳交
	hud.call("_on_mode_pressed", "fist")
	organs.call("tool_set_depth01", 0.85)
	await _frames(20)
	var snap: Dictionary = organs.call("debug_snapshot")
	_ok(str(snap["mode"]) == "fist" and float(snap["fist_depth"]) > 0.15, "fist inserted depth=%.3f" % float(snap["fist_depth"]))
	_ok(not (t.call("fist_rod") as Array).is_empty(), "fist colon rod active")
	var arm: MeshInstance3D = organs.get("_arm")
	_ok(arm != null and arm.visible and arm.mesh != null, "arm prop visible")
	# 鼠标拖拽路径：从正面抓拳头往里推
	var f: Transform3D = organs.call("abdomen_frame")
	var eye := f.origin + f.basis.z * 0.9 - f.basis.y * 0.1
	var tipw: Vector3 = f * (t.get("fist_tip") as Vector3)
	var d0 := (tipw - eye).normalized()
	_ok(organs.call("tool_begin", eye, d0, d0), "fist grab by ray")
	var d1 := ((f * ((t.get("fist_tip") as Vector3) + (t.get("fist_entry") as Vector3) * 0.05)) - eye).normalized()
	organs.call("tool_drag", eye, d1)
	organs.call("tool_end")
	await _frames(4)
	print("tools_clones: fist depth after drag=", t.get("fist_depth"), " over=", t.call("fist_wall_over"), " arousal=", t.get("fist_arousal"))
	# 刺刀（短）：射线选入口 → 推入
	hud.call("_on_mode_pressed", "bayonet")
	await _frames(2)
	_ok(str(t.get("bayonet_kind")) == "short", "bayonet short kind")
	var from := f.origin + f.basis.z * 0.8 + f.basis.y * 0.05
	var dir := (f.origin - from).normalized()
	organs.call("tool_begin", from, dir, dir)
	_ok(bool(t.get("has_entry")), "bayonet entry picked by ray")
	organs.call("tool_set_depth01", 0.9)
	await _frames(20)
	snap = organs.call("debug_snapshot")
	_ok(bool(snap["punctured"]) and float(snap["blade_pen"]) > 0.08 and int(snap["wounds"]) >= 1 and int(snap["damage"]) >= 1,
		"bayonet punctured pen=%.3f wounds=%d dmg=%d" % [float(snap["blade_pen"]), int(snap["wounds"]), int(snap["damage"])])
	_ok(not (t.call("blade_rod", 1.0) as Array).is_empty(), "blade gut rod active")
	var knife: MeshInstance3D = organs.get("_knife")
	_ok(knife.visible and knife.mesh != null, "bayonet prop visible")
	var decal0: Decal = (organs.get("_decals") as Array)[0]
	_ok(decal0.visible and decal0.texture_albedo != null, "wound decal shown")
	# 长刺刀：刺穿出背部伤口
	organs.call("tool_release")
	hud.call("_on_mode_pressed", "bayonet_long")
	await _frames(2)
	_ok(str(t.get("bayonet_kind")) == "long", "bayonet long kind")
	organs.call("tool_set_depth01", 1.0)
	await _frames(20)
	snap = organs.call("debug_snapshot")
	_ok(bool(snap["punctured"]) and float(snap["blade_pen"]) > 0.2, "long bayonet pen=%.3f wounds=%d" % [float(snap["blade_pen"]), int(snap["wounds"])])
	_ok(int(snap["wounds"]) >= 3, "long bayonet exit wound (wounds=%d)" % int(snap["wounds"]))
	if SHOT_DIR != "":
		organs.call("set_xray_amount", 0.75)
		var cam := Camera3D.new()
		main.add_child(cam)
		cam.current = true
		cam.fov = 40.0
		cam.near = 0.02
		f = organs.call("abdomen_frame")
		cam.global_position = f.origin + f.basis.z * 0.75 + f.basis.x * 0.45 + f.basis.y * 0.05
		cam.look_at(f.origin + f.basis.y * -0.04, Vector3.UP)
		await _shot("tool_long_bayonet_xray")
		cam.queue_free()
		await _frames(2)
		player.get("_camera").current = true
		organs.call("set_xray_amount", 0.38)
	# R 复位
	player.call("reset_view_and_belly")
	await _frames(2)
	snap = organs.call("debug_snapshot")
	_ok(int(snap["wounds"]) == 0 and not bool(snap["punctured"]), "reset clears tools / wounds")
	hud.call("_on_mode_pressed", "drag")


# ------------------------------------------------------------------ hair
func _check_hair() -> void:
	player.call("set_tp_view", player.get("_tp_yaw_goal"), 1.2, 1.5, true)
	await _frames(120)
	var sec: RefCounted = player.call("get_secondary")
	var sk: Skeleton3D = sec.get("skeleton")
	var sd := sk.get_bone_global_pose(sk.find_bone("C_Spine_d"))
	var inv := sd.affine_inverse()
	var chest_z := -INF
	var spheres: Array = []
	for b in ["L_Breast_b_Phy", "R_Breast_b_Phy"]:
		var bi := sk.find_bone(b)
		if bi >= 0:
			var bp := sk.get_bone_global_pose(bi)
			chest_z = maxf(chest_z, (inv * bp.origin).z)
			spheres.append(bp.origin)
	var names: PackedStringArray = sec.get("hair_names")
	var hp: Array = sec.get("hair_p")
	var min_front := INF
	var min_sphere := INF
	for k in range(3, names.size()):
		var p: Vector3 = hp[k]
		min_front = minf(min_front, chest_z - (inv * p).z)
		for c in spheres:
			min_sphere = minf(min_sphere, p.distance_to(c) - 0.068)
	_ok(min_front > 0.0 and min_sphere > 0.0, "look-up hair stays off chest: front gap=%.3f breast gap=%.3f" % [min_front, min_sphere])
	player.call("tp_home", true)
	await _frames(30)


# ------------------------------------------------------------------ clones
func _orphans() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))


func _check_clones(hud: Node) -> void:
	await _frames(5)
	var orph0 := _orphans()
	var obj0 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var base: Vector3 = (player as Node3D).global_position
	var pts := [base + Vector3(-0.9, 0, -1.4), base + Vector3(0.0, 0, -1.7), base + Vector3(0.9, 0, -1.4)]
	for p in pts:
		print("tools_clones: ", main.call("spawn_clone", p))
	await _frames(30)
	var clones: Array = main.call("get_clones")
	_ok(clones.size() == 3, "3 clones spawned")
	_ok(get_nodes_in_group("organ_rigs").size() == 4, "4 organ rigs (player + 3)")
	var all_ready := true
	for c in clones:
		all_ready = all_ready and bool(c.call("get_organs").get("ready_ok"))
	_ok(all_ready, "clone organ rigs ready")
	var c2: Node = clones[1]
	var sec2: RefCounted = c2.call("get_secondary")
	_ok(sec2 != null and (sec2.get("hair_names") as PackedStringArray).size() > 0, "clone secondary (hair/breath) running")
	# 第一人称：瞄准分身 #2 的腹部
	player.call("set_play_mode", 1)
	await _frames(40)
	_ok(bool(player.get("first_person")), "player in first person")
	var org2: Node = c2.call("get_organs")
	var target: Vector3 = org2.call("navel_world")
	for it in 4:
		var cam: Camera3D = player.call("get_camera")
		var d := (target - cam.global_position).normalized()
		player.set("_yaw", atan2(-d.x, -d.z))
		player.set("_pitch", asin(clampf(d.y, -1.0, 1.0)))
		await _frames(6)
	var cam2: Camera3D = player.call("get_camera")
	var ray_o := cam2.global_position
	var ray_d := -cam2.global_transform.basis.z
	_ok(player.call("pick_interact_rig", ray_o, ray_d) == org2, "FP centre ray picks clone #2")
	hud.call("_on_mode_pressed", "strike")
	await _frames(3)
	var center: Vector2 = root.get_visible_rect().size * 0.5
	var hit: bool = player.call("_try_begin_interact", center)
	player.call("_end_interact")
	await _frames(2)
	_ok(hit and int(org2.call("active_waves")) > 0 and int(organs.call("active_waves")) == 0 and int((clones[0] as Node).call("get_organs").call("active_waves")) == 0,
		"FP strike hits only clone #2 (waves=%d)" % int(org2.call("active_waves")))
	hud.call("_on_mode_pressed", "bayonet")
	await _frames(3)
	player.call("_try_begin_interact", center)
	player.call("_end_interact")
	var t2: RefCounted = org2.get("tools")
	_ok(bool(t2.get("has_entry")), "FP bayonet entry on clone #2")
	org2.call("tool_set_depth01", 0.8)
	await _frames(10)
	_ok(bool(t2.get("punctured")) and not bool((organs.get("tools") as RefCounted).get("punctured")), "clone #2 punctured independently")
	if SHOT_DIR != "":
		player.call("set_play_mode", 0)
		await _frames(10)
		player.call("set_tp_view", player.get("_tp_yaw_goal"), 1.2, 1.6, true)
		await _frames(60)
		var cam := Camera3D.new()
		main.add_child(cam)
		cam.current = true
		cam.fov = 60.0
		cam.global_position = base + Vector3(1.6, 1.9, 1.1)
		cam.look_at(base + Vector3(-0.1, 0.9, -0.9), Vector3.UP)
		await _shot("clones_and_hair")
		cam.queue_free()
		player.get("_camera").current = true
	hud.call("_on_mode_pressed", "drag")
	print("tools_clones: ", main.call("clear_clones"))
	await _frames(10)
	_ok(int(main.call("clone_count")) == 0 and get_nodes_in_group("organ_rigs").size() == 1, "clear removes all clones")
	var orph1 := _orphans()
	var obj1 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_ok(orph1 <= orph0, "no orphan nodes leaked (before=%d after=%d)" % [orph0, orph1])
	_ok(absi(obj1 - obj0) <= 4, "node count restored (before=%d after=%d)" % [obj0, obj1])
	_ok(not is_instance_valid(c2), "clone freed")
	player.call("set_play_mode", 0)
	await _frames(5)
