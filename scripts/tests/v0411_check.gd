extends "res://scripts/tests/v0410_check.gd"
## 未发布（0.4.10 开发中）：手术钳点选大肠 / 子宫 / 膀胱，大肠单点扯出，
## 子宫 / 膀胱五档柔体脱出，阴道跟随宫颈，输卵管悬链，放回与 restore_body。
##   godot --headless --path . -s res://scripts/tests/v0411_check.gd
##   （V0411_ONLY=pick|colon|uterus|tube|bladder|putback|restore）


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")
	_check_colon_tile()
	if not await _enter_bed():
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	s.call("set_tool", "scalpel")
	await _frames(4)
	var only := OS.get_environment("V0411_ONLY")
	if only == "" or only == "pick":
		await _check_picking()
	if only == "" or only == "colon":
		await _check_colon()
	if only == "" or only == "uterus":
		await _check_uterus()
	if only == "" or only == "tube":
		await _check_tubes()
	if only == "" or only == "bladder":
		await _check_bladder()
	if only == "" or only == "putback":
		await _check_putback()
	if only == "" or only == "restore":
		await _check_restore()
	print("v0411_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_colon_tile() -> void:
	_ok(ResourceLoader.exists("res://assets/organs/colon_tile_albedo.png"), "seamless colon albedo tile exists")
	_ok(ResourceLoader.exists("res://assets/organs/colon_tile_normal.png"), "seamless colon normal tile exists")
	var img := Image.new()
	var raw: PackedByteArray = FileAccess.get_file_as_bytes("res://assets/organs/colon_tile_albedo.png")
	_ok(not raw.is_empty(), "colon tile albedo loads")
	if raw.is_empty():
		return
	var err := img.load_png_from_buffer(raw)
	_ok(err == OK and img.get_width() >= 64, "colon tile is a readable source PNG")
	if err != OK:
		return
	if img == null:
		return
	var w := img.get_width()
	var h := img.get_height()
	var de := 0.0
	var n := 0
	for y in range(0, h, 4):
		var c0 := img.get_pixel(0, y)
		var c1 := img.get_pixel(w - 1, y)
		de += absf(c0.r - c1.r) + absf(c0.g - c1.g) + absf(c0.b - c1.b)
		n += 1
	de /= float(maxi(n, 1))
	_ok(de < 0.06, "colon tile is horizontally seamless (edge Δ=%.4f)" % de)
	# 只取大肠本体质感，不要掺进图集底色或其他器官贴图。
	var acc := Color(0, 0, 0, 0)
	var n2 := 0
	for y in range(0, h, 3):
		for x in range(0, w, 3):
			acc += img.get_pixel(x, y)
			n2 += 1
	acc /= float(maxi(n2, 1))
	# 大肠本体质感偏红棕（G/B 明显低于图集米色底）。
	_ok(acc.r > 0.55 and acc.g < 0.55 and acc.b < 0.50 and acc.g < acc.r - 0.12, "colon tile colour is colon flesh, not atlas paper or a mixed organ tint (mean=%.3f,%.3f,%.3f)" % [acc.r, acc.g, acc.b])


func _open_wound() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	var c := nav + Vector3(0.0, 0.035, 0.0)
	_ok(_straight(c + Vector3(-0.06, 0.0, 0.0), c + Vector3(0.06, 0.004, 0.0)), "wound: straight cut")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", c, 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "wound: ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	s.call("set_tool", "grab")
	_ok(bool(s.call("peel_flap")), "wound: flap peeled")
	await _phys(4)
	await _frames(16)
	s.call("set_tool", "forceps")
	s.call("set_forceps_mode", "pull")


func _aim_at_kind(kind: String) -> Array:
	# returns [origin, dir] toward the organ's rest centroid, or []
	var rig: Node = _organ_rig()
	var meshes: Array = rig.call("viscera_meshes", kind)
	if meshes.is_empty():
		return []
	var navel: Vector3 = rig.get("_navel_rest")
	# 用最靠前（+Z）的顶点，避免瞄准大肠环中空的质心而射空。
	var best := Vector3.ZERO
	var have := false
	for mi in meshes:
		var arr: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
		var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for p in P:
			if not have or p.z > best.z:
				best = p
				have = true
	if not have:
		return []
	var fr: Transform3D = rig.call("abdomen_frame")
	var world: Vector3 = fr * (best - navel)
	var origin := world + Vector3(0.0, 0.0, 0.12)
	var dir := (world - origin).normalized()
	return [origin, dir]


func _check_picking() -> void:
	# 点选不依赖创口：对每种新器官的网格射一枪，应命中对应 kind。
	var rig: Node = _organ_rig()
	_ok(rig != null, "organ rig ready for picking")
	# 种类标记已写在网格上
	for kind in ["colon", "uterus", "uterus_cavity", "bladder", "tube", "ovary", "small_intestine"]:
		var ms: Array = rig.call("viscera_meshes", kind)
		_ok(not ms.is_empty(), "organ_kind '%s' is tagged on at least one mesh (%d)" % [kind, ms.size()])
	for kind in ["colon", "uterus", "bladder"]:
		var aim := _aim_at_kind(kind)
		_ok(aim.size() == 2, "can aim a ray at %s" % kind)
		if aim.size() != 2:
			continue
		# 先按种类过滤，确认该器官网格本身能被点到（大肠周围常有小肠挡在同一射线上）。
		var filtered: PackedStringArray = PackedStringArray([kind])
		var hit: Dictionary = rig.call("ray_pick_viscera", aim[0], aim[1], filtered)
		_ok(not hit.is_empty() and str(hit.get("kind", "")) == kind, "ray_pick_viscera hits %s when aimed at it (got '%s')" % [kind, hit.get("kind", "")])
		# 从贴着器官表面的近处再射一枪，不被其它脏器挡住。
		if not hit.is_empty():
			var pt: Vector3 = hit["point"]
			var origin2: Vector3 = pt - (aim[1] as Vector3) * 0.008
			var hit2: Dictionary = rig.call("ray_pick_viscera", origin2, aim[1])
			_ok(not hit2.is_empty() and str(hit2.get("kind", "")) == kind, "near-surface pick of %s is not stolen by another organ (got '%s')" % [kind, hit2.get("kind", "")])
			s = player.call("get_surgery")
			var k2 := str(s.call("debug_pick_viscera", origin2, aim[1]))
			_ok(k2 == kind, "surgery debug_pick_viscera returns %s (got '%s')" % [kind, k2])


func _check_colon() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "colon")), "colon extract starts inside the open wound")
	await _frames(2)
	_ok(int(s.call("colon_pull_count")) == 1, "exactly one colon pull point after the first grab")
	var ropes: Array = s.call("colon_ropes")
	_ok(ropes.size() == 1, "one colon rope")
	if ropes.is_empty():
		return
	var rope: Node = ropes[0]
	_ok(is_equal_approx(float(rope.get("radius")), 0.0168), "colon is thicker (radius=%.4f)" % float(rope.get("radius")))
	_ok(is_equal_approx(float(rope.get("seg")), 0.040), "colon links are longer (seg=%.3f)" % float(rope.get("seg")))
	_ok(float(rope.get("damp")) <= 0.90 and float(rope.get("damp")) < 0.96, "colon damping is higher than the small intestine (damp=%.3f)" % float(rope.get("damp")))
	_ok(int(rope.get("max_pts")) <= 18, "colon has fewer segments (max_pts=%d)" % int(rope.get("max_pts")))
	_ok(float(rope.get("max_len")) <= 0.40, "colon max length is shorter (%.2f m)" % float(rope.get("max_len")))
	_ok(str(rope.get("profile_id")) == "colon", "rope profile is 'colon'")
	var gm := (rope as GeometryInstance3D).material_override as ShaderMaterial
	var tex = gm.get_shader_parameter("albedo_tex") if gm else null
	_ok(gm != null and tex is Texture2D and str((tex as Texture2D).resource_path).find("colon_tile") >= 0, "colon rope uses the seamless colon tile")
	# 再点一次不能出现第二个扯出点
	_ok(bool(s.call("debug_begin_extract", "colon")), "a second colon grab is accepted (reuses the existing pull)")
	_ok(int(s.call("colon_pull_count")) == 1, "still only one colon pull point")
	# 拉长，但不超过上限
	s.call("debug_forceps_drag_to", rope.get("hold_pos") + Vector3(0.0, 0.25, 0.12))
	await _frames(8)
	_ok(float(rope.get("fed_len")) <= float(rope.get("max_len")) + 1e-4, "colon fed_len stays at or under max_len (%.3f / %.3f)" % [float(rope.get("fed_len")), float(rope.get("max_len"))])
	s.call("debug_forceps_end")
	# 放回
	_ok(bool(s.call("debug_putback_organ", "colon")), "colon put-back starts")
	for i in 80:
		s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("colon_pull_count")) == 0, "colon rope retracts away after put-back")


func _advance_charge(kind: String, strength: float, seconds: float) -> void:
	# 用多次小步进累积档位，并让柔体跟上。
	var left := seconds
	while left > 0.0:
		var step := minf(left, 1.0 / 20.0)
		s.call("debug_add_extract_charge", kind, strength, step)
		left -= step


func _check_uterus() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract starts")
	s.call("debug_forceps_end")
	await _frames(2)
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("extract_level", "uterus")) == 1, "uterus starts at level 1")
	var still_vis := PackedStringArray()
	for mi in _organ_rig().get("organ_meshes"):
		var m := mi as MeshInstance3D
		if m == null or not m.visible:
			continue
		var k := str(m.get_meta("organ_kind", ""))
		if k == "uterus" or k == "uterus_cavity" or bool(m.get_meta("is_cavity", false)):
			still_vis.append("%s:%s" % [m.name, k])
	_ok(still_vis.is_empty() and bool(s.call("organ_source_hidden", "uterus")), "original uterus and cavity meshes are hidden (%s)" % ", ".join(still_vis))
	var so: Node = s.call("soft_organ", "uterus")
	_ok(so != null and bool(so.visible), "a physics soft-body uterus replaces the original")
	var peek := float(so.call("exposed_length"))
	var wound0: Vector3 = s.call("_wound_center_world")
	var cx1: Vector3 = s.call("cervix_world")
	var fund1: Vector3 = so.call("fundus_world")
	var cx1_d := cx1.distance_to(wound0)
	_ok(peek > 0.0, "level 1 exposes some of the uterus (%.1f mm)" % (peek * 1000.0))
	_ok(fund1.distance_to(wound0) < cx1_d, "level 1: fundus is closer to the wound than the cervix (still only a little is out)")
	# 缓慢升档：0.4 秒满强度大约 +0.13 档，仍停在 1 档附近
	var c0 := float(s.call("extract_charge", "uterus"))
	s.call("debug_add_extract_charge", "uterus", 1.0, 0.4)
	var c1 := float(s.call("extract_charge", "uterus"))
	_ok(c1 > c0 and c1 < 1.35 and int(s.call("extract_level", "uterus")) == 1, "level ramps slowly (charge %.2f -> %.2f after 0.4s)" % [c0, c1])
	# 拉到 5 档
	_advance_charge("uterus", 1.0, 14.0)
	_ok(int(s.call("extract_level", "uterus")) == 5, "sustained pull reaches level 5 (charge=%.2f)" % float(s.call("extract_charge", "uterus")))
	s.call("_update_guts", 1.0 / 30.0)
	var wound: Vector3 = s.call("_wound_center_world")
	var cx: Vector3 = s.call("cervix_world")
	_ok(cx.distance_to(wound) < 0.05, "at level 5 the cervix sits at the wound (%.1f mm)" % (cx.distance_to(wound) * 1000.0))
	_ok(cx1_d - cx.distance_to(wound) > 0.03, "level 5 has pulled much more of the uterus out than level 1 (cervix-to-wound %.1f -> %.1f mm)" % [cx1_d * 1000.0, cx.distance_to(wound) * 1000.0])
	var fund5: Vector3 = so.call("fundus_world")
	_ok(fund5.distance_to(wound) > 0.02, "level 5 fundus stays outside the wound (%.1f mm)" % (fund5.distance_to(wound) * 1000.0))
	# 阴道拉伸并跟到宫颈
	var rig: Node = _organ_rig()
	_ok(float(rig.call("canal_stretch_amount")) > 0.5, "vagina canal stretch is on")
	var os_now: Vector3 = rig.call("canal_os_now_world")
	_ok(os_now.distance_to(cx) < 0.008, "stretched vagina stays attached to the physics cervix (%.2f mm)" % (os_now.distance_to(cx) * 1000.0))
	# CPU 公式：宫颈附近的通道点应跟着走
	var canal: Dictionary = rig.call("vagina_canal")
	if not canal.is_empty():
		var deformed: Vector3 = rig.call("canal_deform_ab", canal["cervix_ab"])
		_ok(deformed.distance_to(canal["cervix_ab"]) > 0.01, "cervix-end canal points actually move")
	# 未到 4 档时不应因本段测试而在开始时挂悬链；现在已是 5 档，两侧都应是悬链
	_ok(bool(s.call("tube_chain_active", 0)) and bool(s.call("tube_chain_active", 1)), "at level 5 both tubes/ovaries are ragdoll chains")
	# 扩张器插入时阻止再一次子宫脱出：先放回再测
	s.call("debug_putback_organ", "uterus")
	for i in 40:
		s.call("_update_guts", 1.0 / 20.0)
	# 不强制等到完全回去；restore 在后面覆盖。这里只确认档位在下降。
	_ok(float(s.call("extract_charge", "uterus")) < 5.0, "put-back lowers the uterus charge")


func _check_tubes() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "uterus")), "uterus extract for tube test")
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("extract_level", "uterus")) == 1, "starting at level 1")
	_ok(not bool(s.call("tube_chain_active", 0)) and not bool(s.call("tube_chain_active", 1)), "below level 4 the tubes stay bound to the uterus")
	# 提前夹住一侧
	_ok(bool(s.call("debug_grab_adnexa", 0)), "grabbing a tube/ovary before level 4 detaches that side")
	s.call("_update_guts", 1.0 / 30.0)
	_ok(bool(s.call("tube_chain_active", 0)), "the grabbed side is now a bone-chain ragdoll")
	_ok(not bool(s.call("tube_chain_active", 1)), "the other side stays bound until level 4")
	# 升到 4 档，另一侧也切换
	_advance_charge("uterus", 1.0, 10.0)
	_ok(float(s.call("extract_charge", "uterus")) >= 4.0, "charge reached level 4 (%.2f)" % float(s.call("extract_charge", "uterus")))
	s.call("_update_guts", 1.0 / 30.0)
	_ok(bool(s.call("tube_chain_active", 0)) and bool(s.call("tube_chain_active", 1)), "at level 4+ both sides are chains")
	# 放回后回到绑定
	_ok(bool(s.call("debug_putback_organ", "uterus")), "uterus put-back")
	for i in 200:
		s.call("_update_guts", 1.0 / 20.0)
	_ok(int(s.call("extract_level", "uterus")) == 0 or not bool(s.call("has_extracted_organs")), "uterus returned")
	_ok(not bool(s.call("tube_chain_active", 0)) and not bool(s.call("tube_chain_active", 1)), "ovaries and tubes return to the bound state")
	# 原网格应恢复显示
	_ok(not bool(s.call("organ_source_hidden", "uterus")), "original uterus meshes are visible again after put-back")


func _check_bladder() -> void:
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "bladder")), "bladder extract starts")
	s.call("debug_forceps_end")
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("extract_level", "bladder")) == 1, "bladder starts at level 1")
	_ok(bool(s.call("organ_source_hidden", "bladder")), "original bladder mesh is hidden")
	var so: Node = s.call("soft_organ", "bladder")
	_ok(so != null and bool(so.visible), "a soft-body bladder replaces the original")
	var c0 := float(s.call("extract_charge", "bladder"))
	s.call("debug_add_extract_charge", "bladder", 1.0, 0.4)
	var c1 := float(s.call("extract_charge", "bladder"))
	_ok(c1 > c0 and c1 < 1.35, "bladder level also ramps slowly (%.2f -> %.2f)" % [c0, c1])
	_advance_charge("bladder", 1.0, 14.0)
	_ok(int(s.call("extract_level", "bladder")) == 5, "bladder reaches level 5")
	_ok(bool(s.call("debug_putback_organ", "bladder")), "bladder put-back starts")
	for i in 200:
		s.call("_update_guts", 1.0 / 20.0)
	_ok(int(s.call("extract_level", "bladder")) == 0, "bladder returns after put-back")
	_ok(not bool(s.call("organ_source_hidden", "bladder")), "original bladder is visible again")


func _check_putback() -> void:
	# 综合：大肠 + 子宫同时存在时分别放回
	await _open_wound()
	_ok(bool(s.call("debug_begin_extract", "colon")), "put-back combo: colon out")
	_ok(bool(s.call("debug_begin_extract", "uterus")), "put-back combo: uterus out")
	s.call("debug_grab_adnexa", 1)
	_advance_charge("uterus", 1.0, 2.0)
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("colon_pull_count")) == 1 and int(s.call("extract_level", "uterus")) >= 1, "both organs are out")
	_ok(bool(s.call("debug_putback_organ", "colon")), "colon put-back")
	_ok(bool(s.call("debug_putback_organ", "uterus")), "uterus put-back")
	for i in 200:
		s.call("_update_guts", 1.0 / 20.0)
	_ok(int(s.call("colon_pull_count")) == 0, "colon is gone after put-back")
	_ok(int(s.call("extract_level", "uterus")) == 0, "uterus level is 0 after put-back")
	_ok(not bool(s.call("tube_chain_active", 0)) and not bool(s.call("tube_chain_active", 1)), "tubes rebound after uterus put-back")


func _check_restore() -> void:
	await _open_wound()
	s.call("debug_begin_extract", "colon")
	s.call("debug_begin_extract", "uterus")
	s.call("debug_begin_extract", "bladder")
	s.call("debug_grab_adnexa", 0)
	_advance_charge("uterus", 1.0, 8.0)
	_advance_charge("bladder", 1.0, 8.0)
	s.call("_update_guts", 1.0 / 30.0)
	_ok(int(s.call("colon_pull_count")) == 1 or int(s.call("extract_level", "uterus")) >= 1, "organs are extracted before restore")
	s.call("restore_body")
	await _frames(4)
	_ok(int(s.call("colon_pull_count")) == 0, "restore_body clears the colon pull")
	_ok(int(s.call("extract_level", "uterus")) == 0 and int(s.call("extract_level", "bladder")) == 0, "restore_body resets uterus and bladder levels")
	_ok(not bool(s.call("has_extracted_organs")), "restore_body reports no extracted organs")
	_ok(not bool(s.call("organ_source_hidden", "uterus")) and not bool(s.call("organ_source_hidden", "bladder")), "restore_body shows the original organ meshes")
	_ok(not bool(s.call("tube_chain_active", 0)) and not bool(s.call("tube_chain_active", 1)), "restore_body clears tube chains")
	var rig: Node = _organ_rig()
	_ok(float(rig.call("canal_stretch_amount")) <= 1e-5, "restore_body clears vagina stretch")
