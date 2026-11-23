extends RefCounted
## 库斯科式阴道扩张器：上下两瓣绕中心销轴开合。白膜镀铬亮面金属。
## 用户提供的两瓣 STL 当时未落到本机附件目录，按实拍/实尺（叶片约 10.5 cm）程序生成，铰链在销孔轴上。

const BLADE_LEN := 0.105
const BLADE_WIDTH := 0.028
const BLADE_THICK := 0.0022
const CLOSED_HALF := 0.0042
const HANDLE_LEN := 0.088
const PIN_R := 0.0036
const PIN_L := 0.016

static func chrome_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.86, 0.875, 0.90)
	m.metallic = 1.0
	m.roughness = 0.11
	m.metallic_specular = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	m.clearcoat_enabled = true
	m.clearcoat = 0.45
	m.clearcoat_roughness = 0.08
	m.rim_enabled = true
	m.rim = 0.18
	m.rim_tint = 0.55
	return m


static func build_root() -> Node3D:
	var root := Node3D.new()
	root.name = "Speculum"
	var mat := chrome_material()
	var pin := MeshInstance3D.new()
	pin.name = "HingePin"
	pin.mesh = _pin_mesh()
	pin.material_override = mat
	pin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(pin)
	var upper := Node3D.new()
	upper.name = "UpperJaw"
	var um := MeshInstance3D.new()
	um.name = "Mesh"
	um.mesh = _jaw_mesh(true)
	um.material_override = mat
	um.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	upper.add_child(um)
	root.add_child(upper)
	var lower := Node3D.new()
	lower.name = "LowerJaw"
	var lm := MeshInstance3D.new()
	lm.name = "Mesh"
	lm.mesh = _jaw_mesh(false)
	lm.material_override = mat
	lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	lower.add_child(lm)
	root.add_child(lower)
	return root


static func set_open_angle(root: Node3D, total_deg: float) -> void:
	if root == null:
		return
	var a := deg_to_rad(clampf(total_deg, 0.0, 48.0) * 0.5)
	var u := root.get_node_or_null("UpperJaw") as Node3D
	var l := root.get_node_or_null("LowerJaw") as Node3D
	if u:
		u.rotation = Vector3(a, 0.0, 0.0)
	if l:
		l.rotation = Vector3(-a, 0.0, 0.0)


static func _pin_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 16
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var c0 := Vector3(0.0, PIN_R * sin(a0), PIN_R * cos(a0))
		var c1 := Vector3(0.0, PIN_R * sin(a1), PIN_R * cos(a1))
		var x0 := -PIN_L * 0.5
		var x1 := PIN_L * 0.5
		var n := Vector3(0.0, sin((a0 + a1) * 0.5), cos((a0 + a1) * 0.5))
		_quad(st, Vector3(x0, c0.y, c0.z), Vector3(x1, c0.y, c0.z), Vector3(x1, c1.y, c1.z), Vector3(x0, c1.y, c1.z), n)
		# caps
		_tri(st, Vector3(x0, 0, 0), Vector3(x0, c1.y, c1.z), Vector3(x0, c0.y, c0.z), Vector3(-1, 0, 0))
		_tri(st, Vector3(x1, 0, 0), Vector3(x1, c0.y, c0.z), Vector3(x1, c1.y, c1.z), Vector3(1, 0, 0))
	st.generate_normals()
	st.index()
	return st.commit()


static func _jaw_mesh(upper: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sgn := 1.0 if upper else -1.0
	var zs := 18
	var asg := 10
	# Duck-bill gutter (concave toward the midline) + thickness.
	for iz in zs:
		var t0 := float(iz) / float(zs)
		var t1 := float(iz + 1) / float(zs)
		for ia in asg:
			var u0 := float(ia) / float(asg)
			var u1 := float(ia + 1) / float(asg)
			var i00 := _blade_pt(t0, u0, 0.0, sgn)
			var i10 := _blade_pt(t1, u0, 0.0, sgn)
			var i11 := _blade_pt(t1, u1, 0.0, sgn)
			var i01 := _blade_pt(t0, u1, 0.0, sgn)
			var o00 := _blade_pt(t0, u0, 1.0, sgn)
			var o10 := _blade_pt(t1, u0, 1.0, sgn)
			var o11 := _blade_pt(t1, u1, 1.0, sgn)
			var o01 := _blade_pt(t0, u1, 1.0, sgn)
			_quad(st, i00, i10, i11, i01, Vector3.ZERO)
			_quad(st, o00, o01, o11, o10, Vector3.ZERO)
			if ia == 0:
				_quad(st, i00, o00, o10, i10, Vector3.ZERO)
			if ia == asg - 1:
				_quad(st, i01, i11, o11, o01, Vector3.ZERO)
			if iz == zs - 1:
				_quad(st, i10, o10, o11, i11, Vector3.ZERO)
			if iz == 0:
				_quad(st, i00, i01, o01, o00, Vector3.ZERO)
	_add_handle(st, sgn)
	st.generate_normals()
	st.index()
	return st.commit()


static func _blade_pt(t: float, u: float, outer: float, sgn: float) -> Vector3:
	# t: 0 at hinge, 1 at tip. u: 0..1 across the half-ellipse.
	var z := 0.004 + t * (BLADE_LEN - 0.004)
	var taper := lerpf(1.0, 0.58, t * t)
	var w := (BLADE_WIDTH * 0.5) * taper + outer * BLADE_THICK
	var h := 0.011 * lerpf(1.0, 0.50, t) + outer * BLADE_THICK
	var ang := u * PI
	var x := -w * cos(ang)
	var y := sgn * (CLOSED_HALF + outer * BLADE_THICK * 0.15 + h * sin(ang))
	# slightly rounded tip droop
	if t > 0.86:
		var k := (t - 0.86) / 0.14
		z -= k * k * 0.004
		y += sgn * k * 0.001
	return Vector3(x, y, z)


static func _add_handle(st: SurfaceTool, sgn: float) -> void:
	# Flattened handle on the far side of the hinge, opposite the blades.
	var y0 := sgn * 0.006
	var y1 := sgn * 0.016
	var x0 := -0.008
	var x1 := 0.008
	var z0 := 0.002
	var z1 := -HANDLE_LEN
	# slight flare at the grip
	var hx0 := -0.011
	var hx1 := 0.011
	var hy0 := sgn * 0.004
	var hy1 := sgn * 0.018
	# neck box
	_box(st, Vector3(x0, minf(y0, y1), minf(z1 * 0.25, z0)), Vector3(x1, maxf(y0, y1), maxf(z1 * 0.25, z0)))
	# grip
	_box(st, Vector3(hx0, minf(hy0, hy1), z1), Vector3(hx1, maxf(hy0, hy1), z1 * 0.25))
	# thin neck connecting to the pin
	_box(st, Vector3(-0.005, minf(0.0, y1), -0.004), Vector3(0.005, maxf(0.0, y1), 0.004))


static func _box(st: SurfaceTool, a: Vector3, b: Vector3) -> void:
	var p := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	var faces := [
		[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0],
	]
	for f in faces:
		_quad(st, p[f[0]], p[f[1]], p[f[2]], p[f[3]], Vector3.ZERO)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var nn := n
	if nn.length_squared() < 1e-10:
		nn = (b - a).cross(c - a)
		if nn.length_squared() < 1e-14:
			return
		nn = nn.normalized()
	st.set_normal(nn)
	st.add_vertex(a)
	st.set_normal(nn)
	st.add_vertex(b)
	st.set_normal(nn)
	st.add_vertex(c)
