extends SceneTree
## 0.4.01 自检：身体无双重插值拖影、子弹最远飞行距离、直切口唇缘完全分开且无细长碎面、
## 环切覆盖直切口后环内残留清除、切口边缘红色渐变（无粉红涂鸦线）、拿取拉开持久保留、外露肠子链条物理。
##   godot --headless --path . -s res://scripts/tests/v0401_check.gd
##   V0401_ONLY=cut 只跑手术部分

const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var main: Node
var player: CharacterBody3D
var vs: Node
var s: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0401: OK   ", msg)
	else:
		fails += 1
		push_error("v0401: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/code=") >= 0, "export version 0.4.01+")
	if OS.get_environment("V0401_ONLY") != "cut":
		await _check_ghosting()
		await _check_sky_bullet()
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _phys(6)
	await _check_straight_clean()
	await _check_pull_persist()
	await _check_ring_over_straight()
	await _check_guts()
	print("v0401_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _enter_bed() -> bool:
	var bed: Node = null
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
	if bed == null:
		_ok(false, "exam bed exists")
		return false
	player.global_position = (bed as Node3D).global_position + Vector3(1.2, 0.1, 0.0)
	player.reset_physics_interpolation()
	vs.call("_update_nearest")
	vs.call("try_enter")
	await _frames(8)
	await _phys(4)
	_ok(str(player.get("occupancy")) == "exam_bed", "on the exam bed")
	return str(player.get("occupancy")) == "exam_bed"


# ---- 2. 拖影 ----
func _check_ghosting() -> void:
	_ok(player.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "player root is not engine-interpolated (Body is placed manually)")
	player.call("set_play_mode", 1)
	await _frames(10)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	# process_frame 信号在各节点 _process 之前发出，所以用一个最后执行的探针节点在本帧末尾测。
	var gd := GDScript.new()
	gd.source_code = "extends Node\nvar target: Node\nvar worst := 0.0\nvar n := 0\nfunc _process(_d):\n\tif target:\n\t\tworst = maxf(worst, float(target.call(\"debug_body_render_error\")))\n\t\tn += 1\n"
	gd.reload()
	var probe := Node.new()
	probe.set_script(gd)
	probe.process_priority = 100000
	probe.set("target", player)
	root.add_child(probe)
	var moved := player.global_position
	await _frames(40)
	var worst := float(probe.get("worst"))
	probe.queue_free()
	Input.action_release("move_forward")
	Input.action_release("sprint")
	var dist := player.global_position.distance_to(moved)
	_ok(dist > 0.3 and worst < 0.002, "running: rendered Body matches the camera's interpolated origin (moved %.2f m, worst %.2f mm)" % [dist, worst * 1000.0])
	player.call("set_play_mode", 0)
	await _frames(20)


# ---- 3. 子弹 ----
func _check_sky_bullet() -> void:
	var ws: Node = player.call("get_weapons")
	var bal: Node = ws.get("ballistics") if ws else null
	if bal == null:
		_ok(false, "ballistics exists")
		return
	var lim := float(bal.call("flight_limit", {"range_m": 400.0}))
	_ok(absf(lim - 800.0) < 0.1 and float(bal.call("flight_limit", {"range_m": 40.0})) >= 150.0, "flight limit: rifle 800 m, short weapons >= 150 m (%.0f)" % lim)
	var n0 := int(bal.call("live_count"))
	var c0 := int(bal.get("coarse_steps"))
	var t0 := Time.get_ticks_usec()
	for k in 8:
		bal.call("fire_projectile", player.global_position + Vector3(0, 300.0, 0), Vector3(0.05 * k, 1.0, 0.02), "rifle")
	var frames := 0
	while int(bal.call("live_count")) > n0 and frames < 200:
		await physics_frame
		frames += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok(int(bal.call("live_count")) <= n0, "sky shots are destroyed after the flight limit (%d physics frames)" % frames)
	_ok(int(bal.get("coarse_steps")) - c0 > 8 * 5, "open-air flight uses coarse sweeps, not 48 substeps / frame (%d coarse)" % (int(bal.get("coarse_steps")) - c0))
	print("v0401: sky bullets took %.0f ms wall for %d frames" % [ms, frames])


# ---- 5. 直切口干净 ----
func _lip_sets() -> Array:
	var left: PackedInt32Array = s.get("_lip_left")
	var right: PackedInt32Array = s.get("_lip_right")
	return [left, right]


func _check_straight_clean() -> void:
	var nav: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "straight")
	var a := nav + Vector3(-0.045, -0.05, 0.0)
	_ok(bool(s.call("debug_set_straight_preview", a, a + Vector3(0.09, -0.005, 0.0))), "straight preview")
	_ok(bool(s.call("confirm_cut", false)), "straight cut committed")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	await _phys(3)
	var outer: Geom.MeshData = s.get("_outer")
	var ls: Array = _lip_sets()
	var left: PackedInt32Array = ls[0]
	var right: PackedInt32Array = ls[1]
	var n := mini(left.size(), right.size())
	var shared := 0
	for i in range(1, n - 1):
		if left[i] == right[i]:
			shared += 1
	_ok(n > 4 and shared == 0, "straight cut: no shared vertex across the cut except the two end points (%d / %d)" % [shared, n])
	# 唇缘各点都在网格边界上（真正分开，没有被面黏住）。
	var bnd: Dictionary = s.call("_boundary_edges", outer)
	var bverts: Dictionary = {}
	for e in bnd:
		bverts[(e as Vector2i).x] = true
		bverts[(e as Vector2i).y] = true
	var stuck := 0
	for i2 in n:
		if not bverts.has(left[i2]) or not bverts.has(right[i2]):
			stuck += 1
	_ok(stuck == 0, "every lip vertex lies on an open boundary (stuck=%d)" % stuck)
	# 唇缘附近没有细长 / 尖刺三角。
	var near: Dictionary = {}
	for v in left:
		near[v] = true
	for v in right:
		near[v] = true
	var sliver := 0
	var worst := 1.0
	for f in outer.face_count():
		var touch := false
		for k in 3:
			touch = touch or near.has(outer.idx[f * 3 + k])
		if not touch:
			continue
		var q := Geom.tri_quality(outer.pos[outer.idx[f * 3]], outer.pos[outer.idx[f * 3 + 1]], outer.pos[outer.idx[f * 3 + 2]])
		worst = minf(worst, q)
		if q < 0.05:
			sliver += 1
			if OS.get_environment("V0401_DBG") != "":
				var ids := [outer.idx[f * 3], outer.idx[f * 3 + 1], outer.idx[f * 3 + 2]]
				for vv in ids:
					print("  sliver v=%d pos=%s li=%d ri=%d" % [vv, outer.pos[vv] - (s.get("_navel_rest") as Vector3), left.find(vv), right.find(vv)])
	_ok(sliver == 0, "no sliver / spike skin triangles along the lips and ends (slivers=%d worst q=%.3f)" % [sliver, worst])
	var wall: Geom.MeshData = s.get("_wall_md")
	var wsl := 0
	for f2 in wall.face_count():
		if Geom.tri_quality(wall.pos[wall.idx[f2 * 3]], wall.pos[wall.idx[f2 * 3 + 1]], wall.pos[wall.idx[f2 * 3 + 2]]) < 0.05:
			wsl += 1
	_ok(wsl == 0, "section wall has no slivers (q<0.05: %d of %d)" % [wsl, wall.face_count()])
	# 6. 无粉红涂鸦线，边缘红色渐变。
	_ok(not bool(s.call("has_incision_trail")), "no pink graffiti line on the skin after the cut")
	_ok(int(s.get("wound_tint_verts")) >= n, "skin at the lips carries the red gradient (%d verts)" % int(s.get("wound_tint_verts")))
	var mi: MeshInstance3D = s.get("_surgical_mi")
	var mat := mi.material_override as ShaderMaterial
	_ok(mat != null and float(mat.get_shader_parameter("wound_tint_on")) > 0.5, "surgical skin material has the wound tint enabled")
	var am := mi.mesh as ArrayMesh
	_ok(am != null and am.get_surface_count() > 0 and (am.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray).size() == outer.vert_count(), "surgical skin mesh carries wound vertex colors")


# ---- 7. 拿取持久 ----
func _lip_side_offset(idx: PackedInt32Array, rest0: PackedVector3Array) -> float:
	var outer: Geom.MeshData = s.get("_outer")
	var acc := 0.0
	var n := idx.size()
	for i in range(n / 3, 2 * n / 3):
		acc += outer.pos[idx[i]].distance_to(rest0[idx[i]])
	return acc / float(maxi(2 * n / 3 - n / 3, 1))


func _check_pull_persist() -> void:
	var outer: Geom.MeshData = s.get("_outer")
	var rest0 := outer.pos.duplicate()
	var ls: Array = _lip_sets()
	var left: PackedInt32Array = ls[0]
	var right: PackedInt32Array = ls[1]
	var n := left.size()
	s.call("set_tool", "grab")
	var mid_bind := (outer.pos[left[n / 2]] + outer.pos[right[n / 2]]) * 0.5
	var sd := (outer.pos[left[n / 2]] - outer.pos[right[n / 2]]).normalized()
	var wl: Vector3 = s.call("_approx_world_bind", mid_bind + sd * 0.01)
	var wm: Vector3 = s.call("_approx_world_bind", mid_bind)
	var off_ab: Vector3 = s.call("_to_ab_delta", (wl - wm).normalized() * 0.02)
	_ok(bool(s.call("debug_drag_split_skin", off_ab)), "grab pulls side A")
	s.call("debug_release_split_skin")
	await _phys(30)
	_ok(bool(s.call("debug_drag_split_skin", -off_ab)), "grab pulls side B")
	s.call("debug_release_split_skin")
	await _phys(30)
	s.call("debug_bake_pull")
	outer = s.get("_outer")
	var la := _lip_side_offset(left, rest0)
	var lb := _lip_side_offset(right, rest0)
	_ok(la > 0.0015 and lb > 0.0015, "side A keeps its pull after side B is grabbed (A %.1f mm, B %.1f mm)" % [la * 1000.0, lb * 1000.0])
	s.call("set_tool", "scalpel")


# ---- 4. 环切覆盖直切口 ----
func _check_ring_over_straight() -> void:
	s.call("restore_body")
	await _phys(4)
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _phys(4)
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	s.call("set_cut_mode", "straight")
	_ok(bool(s.call("debug_set_straight_preview", c + Vector3(-0.06, 0.0, 0.0), c + Vector3(0.06, 0.004, 0.0))), "ring-over-straight: straight preview")
	_ok(bool(s.call("confirm_cut", false)), "ring-over-straight: straight cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)), "ring-over-straight: ring preview")
	_ok(bool(s.call("confirm_cut", false)), "ring-over-straight: ring cut across the straight incision")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "ring-over-straight: flap peeled")
	await _phys(6)
	s.call("set_tool", "scalpel")
	var outer: Geom.MeshData = s.get("_outer")
	var inner: Geom.MeshData = s.get("_inner")
	var ok_idx := inner.vert_count() == outer.vert_count()
	for v in outer.idx:
		if v < 0 or v >= outer.vert_count():
			ok_idx = false
			break
	_ok(ok_idx, "ring-over-straight: indices valid, inner 1:1")
	# 环内（略内缩）不能再有皮肤面、截面或涂鸦。
	var inside_skin := 0
	for f in outer.face_count():
		var p := outer.centroid(f) - c
		if (p.x / 0.026) * (p.x / 0.026) + (p.y / 0.018) * (p.y / 0.018) < 1.0:
			inside_skin += 1
	_ok(inside_skin == 0, "ring-over-straight: no skin / lip faces left inside the ring hole (%d)" % inside_skin)
	var wall: Geom.MeshData = s.get("_wall_md")
	var inside_wall := 0
	for f2 in wall.face_count():
		var q := wall.centroid(f2) - c
		if (q.x / 0.024) * (q.x / 0.024) + (q.y / 0.016) * (q.y / 0.016) < 1.0:
			inside_wall += 1
	_ok(inside_wall == 0, "ring-over-straight: no straight-cut section pieces inside the ring (%d)" % inside_wall)
	_ok(not bool(s.call("has_incision_trail")), "ring-over-straight: no trail left")
	# 环外两段直切口仍在（唇缘张开）。
	var outside_lip := 0
	var ls: Array = _lip_sets()
	var bnd: Dictionary = s.call("_boundary_edges", outer)
	for e in bnd:
		var pm: Vector3 = (outer.pos[(e as Vector2i).x] + outer.pos[(e as Vector2i).y]) * 0.5 - c
		if absf(pm.y) < 0.008 and absf(pm.x) > 0.036 and absf(pm.x) < 0.058:
			outside_lip += 1
	_ok(outside_lip >= 4, "ring-over-straight: straight segments outside the ring remain open (%d boundary edges)" % outside_lip)


# ---- 1. 外露肠子 ----
func _check_guts() -> void:
	# 0.4.03：肠子默认不外露，只能用手术钳从腹腔里扯出来（v0403_check 覆盖）。
	await _phys(2)
	await _frames(20)
	_ok(not bool(s.call("has_exposed_guts")), "0.4.03: no automatic gut spill at the peeled hole")
	s.call("restore_body")
	await _frames(3)
