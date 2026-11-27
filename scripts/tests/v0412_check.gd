extends "res://scripts/tests/v0409b_check.gd"
## 未发布自检：扩张器开合轴向、沿阴道插入、插入即拨开阴唇、
## 滑条撑阴道壁并让外口跟随叶片截面、宫颈位于通道末端、直肠局部缩放与肛门衔接、最大开口下尽量不穿模。
##   godot --headless --path . -s res://scripts/tests/v0412_check.gd


const MeshFactory := preload("res://scripts/surgery/speculum_mesh.gd")


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
	_check_canal_and_cervix()
	_check_rectum_local()
	if not await _enter_bed():
		print("v0412_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_opening_axis()
	await _check_insert_labia_and_walls()
	print("v0412_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _mid_blade_world(jaw: Node3D) -> Vector3:
	var mi := jaw.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return jaw.global_position + jaw.global_transform.basis.z * (MeshFactory.BLADE_LEN * 0.55)
	var arr = mi.mesh.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var acc := Vector3.ZERO
	var n := 0
	for p in P:
		if p.z > 0.03 and p.z < 0.09:
			acc += p
			n += 1
	if n < 8:
		return jaw.global_transform * Vector3(0, 0, MeshFactory.BLADE_LEN * 0.55)
	return jaw.global_transform * (acc / float(n))


func _check_canal_and_cervix() -> void:
	var rig: Node = _rig()
	_ok(rig != null and rig.has_method("vagina_canal"), "organ_rig exposes vagina_canal()")
	if rig == null:
		return
	var d: Dictionary = rig.call("vagina_canal")
	_ok(not d.is_empty(), "fitted canal landmarks exist")
	if d.is_empty():
		return
	var o: Vector3 = d["opening_ab"]
	var c: Vector3 = d["cervix_ab"]
	var ax: Vector3 = d["axis_ab"]
	var up: Vector3 = d["up_ab"]
	_ok(float(d["length"]) > 0.04 and float(d["length"]) < 0.09, "canal length is anatomical (%.1f cm)" % (float(d["length"]) * 100.0))
	_ok(ax.length() > 0.95 and absf(ax.dot(up)) < 0.08, "axis and anterior are unit and perpendicular")
	# 宫颈端应对齐子宫内腔口。
	var meta = rig.get("meta")
	if meta is Dictionary and meta.has("uterus_cavity"):
		var os = meta["uterus_cavity"].get("os_center", [])
		var navel: Vector3 = rig.get("_navel_rest")
		if os is Array and os.size() >= 3:
			var os_ab := Vector3(float(os[0]), float(os[1]), float(os[2])) - navel
			var dmm := c.distance_to(os_ab) * 1000.0
			_ok(dmm < 2.0, "canal cervix sits at the UterusCavity os (%.2f mm)" % dmm)
	if d.has("opening_rest"):
		var vis: Vector3 = rig.call("introitus_rest") if rig.has_method("introitus_rest") else d["opening_rest"]
		var omm := (d["opening_rest"] as Vector3).distance_to(vis) * 1000.0
		_ok(omm < 3.0, "canal opening matches the visible (anterior) introitus (%.2f mm)" % omm)
		var anus: Vector3 = rig.get("ANUS_REST") if rig.get("ANUS_REST") != null else Vector3(0.0, 0.8969, -0.0021)
		var opening_rest: Vector3 = d["opening_rest"]
		_ok(opening_rest.z > anus.z + 0.025, "introitus is anterior of the anus (dz=%.1f mm)" % ((opening_rest.z - anus.z) * 1000.0))
		var fourchette := vis
		if meta is Dictionary and meta.has("vagina"):
			var op = meta["vagina"].get("opening", [])
			if op is Array and op.size() >= 3:
				fourchette = Vector3(float(op[0]), float(op[1]), float(op[2]))
		_ok(opening_rest.z >= fourchette.z - 0.001, "introitus is not behind the fourchette / lowest vulva point")


func _check_rectum_local() -> void:
	var rig: Node = _rig()
	_ok(rig != null, "organ_rig is ready for rectum checks")
	if rig == null:
		return
	var anus_rest: Vector3 = rig.get("ANUS_REST") if rig.get("ANUS_REST") != null else Vector3(0.0, 0.8969, -0.0021)
	var colon: Array = rig.call("viscera_meshes", "colon") if rig.has_method("viscera_meshes") else []
	_ok(not colon.is_empty(), "colon meshes are instanced")
	if colon.is_empty():
		return
	var navel: Vector3 = rig.get("_navel_rest")
	var best := 1e9
	var rmax_low := 0.0
	var n_low := 0
	# 远端（靠近肛门、低 Y）半径与到肛门的距离。只看主要结肠网格。
	for mi in colon:
		if mi == null or mi.mesh == null:
			continue
		var arr = mi.mesh.surface_get_arrays(0)
		var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var low: Array = []
		for p in P:
			var wr: Vector3 = p  # bind / rest world
			var da := wr.distance_to(anus_rest)
			if da < best:
				best = da
			if wr.y < 0.93:
				low.append(wr)
		if low.size() >= 8 and str(mi.name).find("001") < 0:
			var acc := Vector3.ZERO
			for q in low:
				acc += q
			var c: Vector3 = acc / float(low.size())
			for q in low:
				rmax_low = maxf(rmax_low, q.distance_to(c))
			n_low = low.size()
	_ok(best < 0.015, "rectum tip is near the anus (%.1f mm)" % (best * 1000.0))
	_ok(n_low >= 8 and rmax_low < 0.025, "distal rectum local radius is not bloated (rmax=%.1f mm, n=%d)" % [rmax_low * 1000.0, n_low])


func _check_opening_axis() -> void:
	s.call("set_tool", "speculum")
	await _frames(2)
	s.call("debug_finish_speculum_anim")
	await _frames(3)
	var n: Node3D = s.call("speculum_node")
	_ok(n != null and n.visible, "speculum is seated for the opening-axis check")
	if n == null:
		return
	var ujaw := n.get_node_or_null("UpperJaw") as Node3D
	var ljaw := n.get_node_or_null("LowerJaw") as Node3D
	_ok(ujaw != null and ljaw != null, "UpperJaw / LowerJaw exist")
	if ujaw == null or ljaw == null:
		return
	var rig: Node = _rig()
	var canal: Dictionary = rig.call("vagina_canal") if rig else {}
	_ok(not canal.is_empty(), "canal available for opening-axis check")
	if canal.is_empty():
		return
	var up_w: Vector3 = ((canal["cervix_world"] as Vector3) - (canal["opening_world"] as Vector3)).cross(n.global_transform.basis.x).normalized()
	# Prefer the canal's own anterior if present.
	var fr: Transform3D = rig.call("abdomen_frame")
	var ant: Vector3 = (fr.basis * (canal["up_ab"] as Vector3)).normalized()
	var mu0 := _mid_blade_world(ujaw)
	var ml0 := _mid_blade_world(ljaw)
	var du0 := (mu0 - n.global_position).dot(ant)
	var dl0 := (ml0 - n.global_position).dot(ant)
	_ok(du0 > dl0, "closed: upper blade is already anterior of the lower (U=%.1f L=%.1f mm)" % [du0 * 1000.0, dl0 * 1000.0])
	s.call("set_speculum_angle", 22.0)
	await _frames(3)
	var mu1 := _mid_blade_world(ujaw)
	var ml1 := _mid_blade_world(ljaw)
	var du1 := (mu1 - n.global_position).dot(ant)
	var dl1 := (ml1 - n.global_position).dot(ant)
	_ok(du1 > du0 + 0.004, "upper blade moves further anterior as the jaws open (%.1f -> %.1f mm)" % [du0 * 1000.0, du1 * 1000.0])
	_ok(dl1 < dl0 - 0.004, "lower blade moves further posterior as the jaws open (%.1f -> %.1f mm)" % [dl0 * 1000.0, dl1 * 1000.0])
	_ok(ujaw.rotation.x < 0.0 and ljaw.rotation.x > 0.0, "Cusco signs: upper rotates negative, lower positive (U=%.1f° L=%.1f°)" % [rad_to_deg(ujaw.rotation.x), rad_to_deg(ljaw.rotation.x)])
	# 复位到闭合再测插入路径（下面的检查会重新打开）。
	s.call("set_speculum_angle", 0.0)
	await _frames(2)


func _speculum_offset_cpu(p: Vector3, o: Vector3, ax: Vector3, up: Vector3, depth: float, half_tip: float, half_side: float, mixv: float, half_closed: float) -> Vector3:
	if depth <= 0.0 or mixv <= 1e-5:
		return Vector3.ZERO
	ax = ax.normalized()
	up = (up - ax * up.dot(ax)).normalized()
	var side := ax.cross(up).normalized()
	var v := p - o
	var s := v.dot(ax)
	var smin := -0.022
	var smax := depth + 0.014
	if s < smin - 0.025 or s > smax + 0.025:
		return Vector3.ZERO
	var along_w := smoothstep(smin - 0.018, smin, s) * (1.0 - smoothstep(smax, smax + 0.02, s))
	if along_w < 0.01:
		return Vector3.ZERO
	var along := clampf(s / maxf(depth, 1e-4), 0.0, 1.15)
	var ry := lerpf(half_closed, half_tip, clampf(along, 0.0, 1.0)) + 0.003
	var rx := half_side * lerpf(1.0, 0.78, clampf(along, 0.0, 1.0))
	var xu := v.dot(side)
	var yu := v.dot(up)
	var radial := side * xu + up * yu
	var pr := radial.length()
	if pr < 1e-6:
		return Vector3.ZERO
	var e := (xu * xu) / maxf(rx * rx, 1e-8) + (yu * yu) / maxf(ry * ry, 1e-8)
	if e >= 1.0:
		return Vector3.ZERO
	var k := 1.0 / sqrt(maxf(e, 1e-6))
	var cap := (maxf(rx, ry) + 0.02) / pr
	k = minf(k, cap)
	return (radial / pr) * (pr * k - pr) * mixv * along_w


func _check_insert_labia_and_walls() -> void:
	if not bool(s.call("is_speculum_inserted")):
		s.call("set_tool", "speculum")
		s.call("debug_finish_speculum_anim")
		await _frames(3)
	s.call("set_speculum_angle", 0.0)
	await _frames(2)
	var n: Node3D = s.call("speculum_node")
	var rig: Node = _rig()
	_ok(n != null and rig != null, "inserted closed speculum is ready")
	if n == null or rig == null:
		return
	var canal: Dictionary = rig.call("vagina_canal")
	var opening: Vector3 = canal["opening_world"]
	var cervix: Vector3 = canal["cervix_world"]
	var ax_w: Vector3 = (cervix - opening).normalized()
	var z := n.global_transform.basis.z.normalized()
	_ok(z.dot(ax_w) > 0.98, "insertion path follows the vaginal axis (dot=%.4f)" % z.dot(ax_w))
	var tip := n.global_position + z * MeshFactory.BLADE_LEN
	_ok(tip.distance_to(cervix) < 0.018, "blade tip is at the canal end / cervix (%.1f mm)" % (tip.distance_to(cervix) * 1000.0))
	# 尖端应在外口的宫颈一侧，而不是还停在体外。
	_ok((tip - opening).dot(ax_w) > 0.03, "the tip is inside the canal, past the introitus")
	var vis_w: Vector3 = rig.call("visible_introitus_world") if rig.has_method("visible_introitus_world") else opening
	# 叶片轴线到可见外口中心的距离（点到线段）。
	var hpos := n.global_position
	var seg := tip - hpos
	var slen := seg.length()
	var u := 0.0 if slen < 1e-6 else clampf((vis_w - hpos).dot(seg) / (slen * slen), 0.0, 1.0)
	var closest := hpos + seg * u
	var miss := closest.distance_to(vis_w) * 1000.0
	_ok(miss < 8.0, "blade shaft goes through the visible introitus (miss=%.1f mm)" % miss)
	_ok(absf(float(s.call("speculum_max_angle")) if s.has_method("speculum_max_angle") else 24.0) <= 25.0, "max opening is reduced so the blades cannot over-clip")
	var spread0 := float(rig.call("vulva_spread"))
	_ok(spread0 < 0.15, "speculum does not use a mechanical left/right labia hinge (spread=%.2f)" % spread0)
	var ext0 := Vector2.ZERO
	if rig.vulva and rig.vulva.has_method("introitus_half_extents"):
		ext0 = rig.vulva.call("introitus_half_extents")
		_ok(ext0.x >= 0.014 and ext0.y >= 0.011, "introitus fits the closed blades (hx=%.1f hy=%.1f mm)" % [ext0.x * 1000.0, ext0.y * 1000.0])
	var gap0: float = rig.get("_spec_d").w
	s.call("set_speculum_angle", 24.0)
	await _frames(3)
	var spread1 := float(rig.call("vulva_spread"))
	_ok(spread1 < 0.15, "opening the blades still does not use a hinge spread (%.2f)" % spread1)
	if rig.vulva and rig.vulva.has_method("introitus_half_extents"):
		var ext1: Vector2 = rig.vulva.call("introitus_half_extents")
		_ok(ext1.y > ext0.y + 0.004, "introitus height follows the blade opening (hy %.1f -> %.1f mm)" % [ext0.y * 1000.0, ext1.y * 1000.0])
		_ok(absf(ext1.x - ext0.x) < 0.008, "introitus width stays near the blade width (hx %.1f -> %.1f mm)" % [ext0.x * 1000.0, ext1.x * 1000.0])
	var gap1: float = rig.get("_spec_d").w
	_ok(gap1 > gap0 + 0.010, "slider drives vaginal wall half-gap only (%.1f -> %.1f mm)" % [gap0 * 1000.0, gap1 * 1000.0])
	# 最大开口下，把 shader 的壁变形应用到阴道网格，测与直肠的间隙。
	var so: Vector4 = rig.get("_spec_o")
	var sd: Vector4 = rig.get("_spec_d")
	var su: Vector4 = rig.get("_spec_u")
	var sm: Vector4 = rig.get("_spec_m")
	var origin := Vector3(so.x, so.y, so.z)
	var ax_ab := Vector3(sd.x, sd.y, sd.z)
	var up_ab := Vector3(su.x, su.y, su.z)
	var vag: Array = rig.call("viscera_meshes", "vagina")
	var col: Array = rig.call("viscera_meshes", "colon")
	if vag.is_empty() or col.is_empty():
		# 阴道网格可能没打上 vagina 种类；退化为按名字找。
		for mi in rig.organ_meshes:
			var kn := str(mi.get_meta("organ_kind")) if mi.has_meta("organ_kind") else ""
			var nm := str(mi.name)
			if kn == "vagina" or nm.find("Object_26") >= 0 or nm.to_lower().find("vagin") >= 0:
				vag.append(mi)
	_ok(not vag.is_empty() and not col.is_empty(), "vagina and colon meshes are available for a clearance sample")
	if not vag.is_empty() and not col.is_empty():
		var colon_pts: PackedVector3Array = PackedVector3Array()
		for mi in col:
			if str(mi.name).find("001") >= 0 or mi.mesh == null:
				continue
			var arr = mi.mesh.surface_get_arrays(0)
			var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for p in P:
				if p.y < 0.96:
					colon_pts.append(p - rig.get("_navel_rest"))
		var best := 1e9
		for mi in vag:
			if mi.mesh == null:
				continue
			var arr2 = mi.mesh.surface_get_arrays(0)
			var V: PackedVector3Array = arr2[Mesh.ARRAY_VERTEX]
			for i in range(0, V.size(), 2):
				var p_ab: Vector3 = V[i] - rig.get("_navel_rest")
				p_ab += _speculum_offset_cpu(p_ab, origin, ax_ab, up_ab, so.w, sd.w, su.w, sm.x, sm.y)
				for j in range(0, colon_pts.size(), 3):
					best = minf(best, p_ab.distance_to(colon_pts[j]))
		if best < 1e8:
			_ok(best > 0.0005, "at max opening the deformed vaginal wall does not clip the rectum (clearance=%.1f mm)" % (best * 1000.0))
		else:
			_ok(false, "clearance sample produced no pairs")
	# 清理，避免影响其它自检同进程（本脚本单独跑）。
	s.call("request_remove_speculum")
	s.call("debug_finish_speculum_anim")
	await _frames(2)
