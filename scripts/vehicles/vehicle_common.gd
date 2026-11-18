extends RefCounted
## Shared helpers for vehicle models (facing, AABB, name search, mesh utils).
## Visual facing convention matches the web prototype after normalize_facing:
##   +Y up, -Z forward (nose), +X right, origin on the ground (y=0) then lifted by origin_y.
class_name VehicleCommon


static func find_named(root: Node, regex: String) -> Array[Node]:
	var re := RegEx.new()
	re.compile(regex)
	var out: Array[Node] = []
	_find_named_rec(root, re, out)
	return out


static func _find_named_rec(n: Node, re: RegEx, out: Array[Node]) -> void:
	if re.search(str(n.name)) != null:
		out.append(n)
	for c in n.get_children():
		_find_named_rec(c, re, out)


static func first_named(root: Node, regex: String) -> Node:
	var arr := find_named(root, regex)
	return arr[0] if arr.size() else null


static func world_aabb(n: Node3D) -> AABB:
	var acc := AABB()
	var any := false
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var mi := n as MeshInstance3D
		var a := mi.mesh.get_aabb()
		var xf := mi.global_transform
		for i in 8:
			var p := xf * a.get_endpoint(i)
			if not any:
				acc = AABB(p, Vector3.ZERO)
				any = true
			else:
				acc = acc.expand(p)
	for c in n.get_children():
		if c is Node3D:
			var ca := world_aabb(c as Node3D)
			if ca.size.length_squared() > 0.0 or ca.position != Vector3.ZERO:
				if not any:
					acc = ca
					any = true
				else:
					acc = acc.merge(ca)
	return acc


static func aabb_in(wrap: Node3D, n: Node3D) -> Dictionary:
	var wa := world_aabb(n)
	if wa.size == Vector3.ZERO and wa.position == Vector3.ZERO:
		return {"min": Vector3.ZERO, "max": Vector3.ZERO, "cx": 0.0, "cy": 0.0, "cz": 0.0,
			"minX": 0.0, "maxX": 0.0, "minY": 0.0, "maxY": 0.0, "minZ": 0.0, "maxZ": 0.0, "empty": true}
	var mn := wrap.to_local(wa.position)
	var mx := wrap.to_local(wa.position + wa.size)
	var a := Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z))
	var b := Vector3(maxf(mn.x, mx.x), maxf(mn.y, mx.y), maxf(mn.z, mx.z))
	return {
		"min": a, "max": b,
		"cx": (a.x + b.x) * 0.5, "cy": (a.y + b.y) * 0.5, "cz": (a.z + b.z) * 0.5,
		"minX": a.x, "maxX": b.x, "minY": a.y, "maxY": b.y, "minZ": a.z, "maxZ": b.z,
		"empty": false,
	}


static func marker_center_z(root: Node3D, regex: String) -> Variant:
	var n := first_named(root, regex)
	if n == null or not (n is Node3D):
		return null
	var a := world_aabb(n as Node3D)
	return a.position.z + a.size.z * 0.5


static func normalize_facing(root: Node3D, target_len: float, tail_re: String, nose_re: String) -> void:
	root.force_update_transform()
	var box := world_aabb(root)
	if box.size == Vector3.ZERO:
		return
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest > 0.01:
		root.scale *= target_len / longest
	root.force_update_transform()
	box = world_aabb(root)
	if box.size.x > box.size.z * 1.12:
		root.rotation.y += PI * 0.5
	root.force_update_transform()
	box = world_aabb(root)
	var center := box.position + box.size * 0.5
	var tail_z: Variant = marker_center_z(root, tail_re) if tail_re != "" else null
	var nose_z: Variant = marker_center_z(root, nose_re) if nose_re != "" else null
	var flip := false
	if nose_z != null:
		flip = float(nose_z) > center.z
	elif tail_z != null:
		flip = float(tail_z) < center.z
	if flip:
		root.rotation.y += PI
	root.force_update_transform()
	box = world_aabb(root)
	center = box.position + box.size * 0.5
	# Shift in parent space so xz is centered and y-min = 0 (same as the web prototype).
	var parent := root.get_parent() as Node3D
	var to_parent := func(p: Vector3) -> Vector3:
		return parent.to_local(p) if parent else p
	var c_local: Vector3 = to_parent.call(center)
	var min_local: Vector3 = to_parent.call(box.position)
	root.position.x -= c_local.x
	root.position.y -= min_local.y
	root.position.z -= c_local.z
	root.force_update_transform()


static func lift_origin(wrap: Node3D, origin_y: float) -> void:
	for ch in wrap.get_children():
		if ch is Node3D:
			(ch as Node3D).position.y -= origin_y
	wrap.force_update_transform()


static func local_thin_axis(obj: Node3D) -> String:
	var box := AABB()
	var any := false
	var xform_to := obj.global_transform.affine_inverse()
	for n in obj.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var step := maxi(1, verts.size() / 280)
		var xf := xform_to * mi.global_transform
		var i := 0
		while i < verts.size():
			var p: Vector3 = xf * verts[i]
			if not any:
				box = AABB(p, Vector3.ZERO)
				any = true
			else:
				box = box.expand(p)
			i += step
	if not any:
		return "z"
	var s := box.size
	if s.x <= s.y and s.x <= s.z:
		return "x"
	if s.y <= s.x and s.y <= s.z:
		return "y"
	return "z"


static func make_glass(root: Node, regex: String, opacity: float) -> void:
	var re := RegEx.new()
	re.compile(regex)
	var skip := RegEx.new()
	skip.compile("headlight|taillight|tail_light|daylight")
	var meshes: Array[MeshInstance3D] = []
	for node in find_named(root, regex):
		if node is MeshInstance3D:
			meshes.append(node as MeshInstance3D)
		for n in node.find_children("*", "MeshInstance3D", true, false):
			meshes.append(n as MeshInstance3D)
	var seen := {}
	for mi in meshes:
		if mi == null or seen.has(mi.get_instance_id()):
			continue
		seen[mi.get_instance_id()] = true
		if skip.search(mi.name.to_lower()) != null:
			continue
		var mats: Array = []
		if mi.mesh:
			for s in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(s)
				if mat:
					mats.append(mat)
		if mats.is_empty() and mi.material_override:
			mats.append(mi.material_override)
		if mats.is_empty():
			continue
		var first: Material = mats[0]
		var next := first.duplicate() as BaseMaterial3D
		if next == null:
			continue
		next.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		next.albedo_color = Color(0.557, 0.769, 0.902, opacity)
		next.metallic = 0.02
		next.roughness = 0.06
		next.albedo_texture = null
		next.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = next


static func make_teardrop_mesh(r_base: float) -> ArrayMesh:
	## Lathe around +Y, y in [-0.5, 0.5], matching the web makeTeardropGeo.
	var n := 40
	var segs := 24
	var rings: Array[float] = []
	var ys: Array[float] = []
	for i in n + 1:
		var t := float(i) / float(n)
		var y := t - 0.5
		var r: float
		if t < 0.16:
			var u := t / 0.16
			r = r_base * (0.9 + 0.12 * u)
		else:
			var u := (t - 0.16) / 0.84
			r = r_base * 1.02 * pow(1.0 - u, 1.08) * (1.0 - 0.35 * u)
		rings.append(maxf(0.00035, r))
		ys.append(y)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in n + 1:
		for j in segs:
			var ang := TAU * float(j) / float(segs)
			var x := rings[i] * cos(ang)
			var z := rings[i] * sin(ang)
			verts.append(Vector3(x, ys[i], z))
			var nr := Vector3(x, 0.0, z)
			if nr.length_squared() < 1e-8:
				nr = Vector3(0, 1, 0) if i == 0 else Vector3(0, -1, 0)
			else:
				# Approximate; refined after index generation if needed.
				nr = nr.normalized()
			norms.append(nr)
			uvs.append(Vector2(float(j) / float(segs), float(i) / float(n)))
	var idx := PackedInt32Array()
	for i in n:
		for j in segs:
			var j2 := (j + 1) % segs
			var a := i * segs + j
			var b := i * segs + j2
			var c := (i + 1) * segs + j
			var d := (i + 1) * segs + j2
			idx.append_array([a, c, b, b, c, d])
	# Recompute smooth normals.
	var acc := PackedVector3Array()
	acc.resize(verts.size())
	var t := 0
	while t < idx.size():
		var ia := idx[t]
		var ib := idx[t + 1]
		var ic := idx[t + 2]
		var fn := (verts[ib] - verts[ia]).cross(verts[ic] - verts[ia])
		acc[ia] += fn
		acc[ib] += fn
		acc[ic] += fn
		t += 3
	for i in acc.size():
		norms[i] = acc[i].normalized() if acc[i].length_squared() > 1e-10 else Vector3.UP
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func make_diamond_mesh() -> ArrayMesh:
	## Double cone (diamond / mach-disk envelope) along +Y, unit height.
	var segs := 16
	var verts := PackedVector3Array()
	var top := Vector3(0, 0.5, 0)
	var bot := Vector3(0, -0.5, 0)
	verts.append(top)
	verts.append(bot)
	for j in segs:
		var ang := TAU * float(j) / float(segs)
		verts.append(Vector3(0.5 * cos(ang), 0.0, 0.5 * sin(ang)))
	var idx := PackedInt32Array()
	for j in segs:
		var a := 2 + j
		var b := 2 + ((j + 1) % segs)
		idx.append_array([0, a, b, 1, b, a])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func split_mesh_by_x(mi: MeshInstance3D, wrap: Node3D, keep_left: bool, eps: float = 0.0) -> MeshInstance3D:
	## Keep triangles whose wrap-local centroid is on one side of x = 0. Web splitTriangles port.
	if mi == null or mi.mesh == null:
		return null
	var src := mi.mesh
	var keep_v := PackedVector3Array()
	var keep_n := PackedVector3Array()
	var keep_u := PackedVector2Array()
	var xf := mi.global_transform
	var inv_wrap := wrap.global_transform.affine_inverse()
	for s in src.get_surface_count():
		var arr := src.surface_get_arrays(s)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tri_count: int
		var get_i := func(k: int) -> int:
			return indices[k] if indices.size() else k
		if indices.size():
			tri_count = indices.size() / 3
		else:
			tri_count = verts.size() / 3
		for t in tri_count:
			var i0: int = get_i.call(t * 3)
			var i1: int = get_i.call(t * 3 + 1)
			var i2: int = get_i.call(t * 3 + 2)
			var w0: Vector3 = inv_wrap * (xf * verts[i0])
			var w1: Vector3 = inv_wrap * (xf * verts[i1])
			var w2: Vector3 = inv_wrap * (xf * verts[i2])
			var cx := (w0.x + w1.x + w2.x) / 3.0
			var side := cx < -eps if keep_left else cx > eps
			if not side:
				continue
			keep_v.append(verts[i0])
			keep_v.append(verts[i1])
			keep_v.append(verts[i2])
			if norms.size() > i2:
				keep_n.append(norms[i0])
				keep_n.append(norms[i1])
				keep_n.append(norms[i2])
			if uvs.size() > i2:
				keep_u.append(uvs[i0])
				keep_u.append(uvs[i1])
				keep_u.append(uvs[i2])
	if keep_v.size() < 3:
		return null
	var out_arr: Array = []
	out_arr.resize(Mesh.ARRAY_MAX)
	out_arr[Mesh.ARRAY_VERTEX] = keep_v
	if keep_n.size() == keep_v.size():
		out_arr[Mesh.ARRAY_NORMAL] = keep_n
	if keep_u.size() == keep_v.size():
		out_arr[Mesh.ARRAY_TEX_UV] = keep_u
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arr)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	if mi.mesh.get_surface_count() > 0:
		var mat := mi.get_active_material(0)
		if mat:
			inst.material_override = mat
	inst.global_transform = mi.global_transform
	return inst


static func reparent_keep_global(n: Node3D, new_parent: Node3D) -> void:
	var xf := n.global_transform
	if n.get_parent():
		n.get_parent().remove_child(n)
	new_parent.add_child(n)
	n.global_transform = xf


static func add_box_shape(body: CollisionObject3D, name: String, center: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.name = name
	var box := BoxShape3D.new()
	box.size = size.abs()
	cs.shape = box
	cs.transform = Transform3D(basis, center)
	body.add_child(cs)
	return cs


static func mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		out.append(n as MeshInstance3D)
	return out
