extends "res://scripts/tests/v0408_check.gd"
## 未发布（0.4.10 开发中）：子宫内腔（内膜）存在、法线朝内、位于子宫壁内、
## 在子宫口与阴道通道贯通、并跟随子宫柔体变形。不钉死导出版本号。
##   godot --headless --path . -s res://scripts/tests/v0410_check.gd


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
	_check_cavity_mesh()
	await _check_cavity_follow()
	print("v0410_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _cavity_mesh() -> MeshInstance3D:
	var found: MeshInstance3D = null
	for mi in _organ_rig().get("organ_meshes"):
		var m := mi as MeshInstance3D
		var matn := str(m.get_meta("organ_material", "")).to_lower()
		var nm := str(m.name).to_lower()
		if matn.find("endometr") >= 0 or nm.find("uteruscavity") >= 0 or bool(m.get_meta("is_cavity", false)):
			found = m
			break
	return found


func _check_cavity_mesh() -> void:
	var rig: Node = _organ_rig()
	_ok(rig != null, "organ rig is ready")
	var meta: Dictionary = rig.get("meta") if rig else {}
	_ok(meta.has("uterus_cavity"), "organs_meta.json records uterus_cavity")
	var cav: MeshInstance3D = _cavity_mesh()
	_ok(cav != null and cav.mesh != null, "endometrium / uterine cavity mesh exists")
	if cav == null:
		return
	_ok(bool(cav.get_meta("is_uterus", false)), "cavity is flagged is_uterus so it uses the same organ deform")
	var mat: ShaderMaterial = cav.material_override as ShaderMaterial
	_ok(mat != null, "cavity has a ShaderMaterial override")
	var all_mats: Array = rig.get("_all_mats")
	_ok(mat in all_mats, "cavity material is registered in OrganRig._all_mats")
	if mat:
		var col: Color = mat.get_shader_parameter("base_color")
		# Natural mucosa pink, not the saturated red of the outer uterus.
		_ok(col.g > 0.45 and col.r - col.g < 0.35 and col.b > 0.40, "cavity mucosa is a natural pink (%.2f, %.2f, %.2f)" % [col.r, col.g, col.b])
		_ok(bool(mat.get_shader_parameter("is_uterus")), "cavity shader is_uterus is on")
	var arr: Array = cav.mesh.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	_ok(P.size() > 2000 and I.size() / 3 > 4000, "cavity has a real lining (%d verts, %d tris)" % [P.size(), I.size() / 3])
	# Vertex normals face the lumen (toward the centroid).
	var c := Vector3.ZERO
	for p in P:
		c += p
	c /= float(P.size())
	var inward := 0
	for i in P.size():
		if N[i].dot(P[i] - c) < 0.0:
			inward += 1
	var frac := float(inward) / float(P.size())
	_ok(frac > 0.85, "cavity normals face inward (%.0f%%)" % (frac * 100.0))
	# Body sits inside the outer uterus (connection rings at the os / horns may
	# reach the outer surface, so allow 0.5 mm of slack on the AABB).
	var ut_m: Array = _organ_mesh("uterus")
	_ok(ut_m.size() == 1, "still exactly one outer uterus mesh (not confused with the cavity) (%d)" % ut_m.size())
	var UP: PackedVector3Array = (ut_m[0] as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var ub := _box(UP)
	var cb := _box(P)
	var grown := ub.grow(0.0006)
	_ok(grown.has_point(cb.position) and grown.has_point(cb.end), "cavity AABB sits inside the uterus (uterus %s, cavity %s)" % [ub, cb])
	# Connects at the os: some cavity verts lie on the vaginal cervix ring.
	var vg: Dictionary = meta.get("vagina", {})
	var cx: Array = vg.get("cervix", [0, 0, 0])
	var cervix := Vector3(cx[0], cx[1], cx[2])
	var ax: Array = vg.get("axis", [0, -1, 0])
	var axis := Vector3(ax[0], ax[1], ax[2]).normalized()
	var near := 0
	var best := INF
	for p in P:
		var d := p.distance_to(cervix)
		best = minf(best, d)
		if d < 0.008:
			near += 1
	_ok(near > 8 and best < 0.006, "cavity meets the cervix os (nearest %.1f mm, %d verts within 8 mm)" % [best * 1000.0, near])
	# Open passage: a ray from mid-canal along the axis passes the os and
	# hits the fundus lining deeper in the cavity; a short ray from just
	# inside the os back toward the vagina is not blocked by a closed cap.
	var opening := Vector3(vg["opening"][0], vg["opening"][1], vg["opening"][2])
	var mid: Vector3 = opening - axis * 0.025
	var into := -axis  # from the opening toward the fundus
	var canal_len := float(vg.get("length", 0.055))
	var t_fundus := _first_hit(P, I, mid, into, 0.14)
	_ok(t_fundus > canal_len - 0.025 + 0.015, "canal opens into the cavity: mid-vagina ray hits the lining %.1f mm in (past the os)" % (t_fundus * 1000.0))
	var inside: Vector3 = cervix - axis * 0.006
	var t_back := _first_hit(P, I, inside, axis, 0.025)
	_ok(t_back < 0.0, "just inside the os, a ray back into the vagina is not blocked by a closed cap (hit at %.1f mm)" % (t_back * 1000.0))
	# Also the outer uterus no longer has a closed cap on that same back-ray.
	var UI: PackedInt32Array = (ut_m[0] as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var t_back_u := _first_hit(UP, UI, inside, axis, 0.025)
	_ok(t_back_u < 0.0, "outer uterus is open at the os (back-ray hit at %.1f mm)" % (t_back_u * 1000.0))


func _first_hit(P: PackedVector3Array, idx: PackedInt32Array, o: Vector3, d: Vector3, tmax: float) -> float:
	# Same 100× scale trick as v0408 (_ray_hits_small) so millimetre triangles register.
	var k := 100.0
	var origin := o * k
	var dir := d.normalized()
	var best := INF
	for f in idx.size() / 3:
		var a := P[idx[f * 3]] * k
		var b := P[idx[f * 3 + 1]] * k
		var c := P[idx[f * 3 + 2]] * k
		var hit = Geometry3D.ray_intersects_triangle(origin, dir, a, b, c)
		if hit == null:
			continue
		var t := origin.distance_to(hit as Vector3) / k
		if t > 1e-4 and t < tmax and t < best:
			best = t
	return best if best < INF else -1.0


func _check_cavity_follow() -> void:
	var rig: Node = _organ_rig()
	var cav: MeshInstance3D = _cavity_mesh()
	var ut_m: Array = _organ_mesh("uterus")
	if cav == null or ut_m.is_empty() or rig == null:
		_ok(false, "cavity follow: missing meshes")
		return
	var cmat: ShaderMaterial = cav.material_override as ShaderMaterial
	var umat: ShaderMaterial = (ut_m[0] as MeshInstance3D).material_override as ShaderMaterial
	_ok(cmat != null and umat != null, "both uterus wall and cavity have shader materials")
	if cmat == null or umat == null:
		return
	# Same shared uniforms as the outer uterus (pivot / soft / current offsets).
	var piv_c: Vector3 = cmat.get_shader_parameter("uter_pivot")
	var piv_u: Vector3 = umat.get_shader_parameter("uter_pivot")
	_ok(piv_c.distance_to(piv_u) < 1e-5, "cavity and uterus share uter_pivot")
	var sc = cmat.get_shader_parameter("organ_soft")
	var su = umat.get_shader_parameter("organ_soft")
	_ok(sc == su, "cavity and uterus share organ_soft (%s / %s)" % [sc, su])
	# Drag the abdomen: both materials receive the same drag_off / uter_off.
	if rig.has_method("vagina_canal") and rig.has_method("begin_drag"):
		var canal: Dictionary = rig.call("vagina_canal")
		var open0: Vector3 = canal["opening_world"]
		var offset := (rig.call("abdomen_frame") as Transform3D).basis.x * 0.04
		rig.call("begin_drag", open0)
		rig.call("update_drag", open0 + offset)
		await _phys(12)
		await _frames(8)
		var d_c: Vector3 = cmat.get_shader_parameter("drag_off")
		var d_u: Vector3 = umat.get_shader_parameter("drag_off")
		_ok(d_c.is_finite() and d_c.distance_to(d_u) < 1e-6, "cavity follows the same soft-body drag as the uterus (c=%s u=%s)" % [d_c, d_u])
		_ok(d_c.length() > 0.002, "drag actually moved the organ uniforms (%.1f mm)" % (d_c.length() * 1000.0))
		var uo_c: Vector3 = cmat.get_shader_parameter("uter_off")
		var uo_u: Vector3 = umat.get_shader_parameter("uter_off")
		_ok(uo_c.distance_to(uo_u) < 1e-6, "cavity and uterus share uter_off during deform")
		rig.call("end_drag")
		await _phys(8)
		await _frames(2)
	# x-ray / visibility: same layers and profile uniforms as other pelvis organs.
	_ok(cav.layers == (ut_m[0] as MeshInstance3D).layers, "cavity uses the same render layers as the uterus (x-ray / organ light)")
	_ok(cav.visible == (ut_m[0] as MeshInstance3D).visible, "cavity visibility matches the outer uterus")
