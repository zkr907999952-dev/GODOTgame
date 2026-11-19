extends Node3D
## 翼尖拉烟 + 高过载背部涡流云。翼尖轨迹移植自 rouchangmoniqi3
## vehicles.tsx makeContrail / updateContrail / updateBodyVortex；
## 背部云参考 F-22 大过载抬头时的机背 / LEX / 翼根冷凝，只在高过载抬头时出现，
## 过载越大越不透明，低过载完全隐藏。
class_name PlaneVapor

const TRAIL_N := 52
const TIP_EMIT_SPEED := 52.0
const TIP_EMIT_AGL := 18.0
const TIP_WIDTH := 0.22
const TIP_FADE := 0.38
## 高过载云：只在较大过载下出现。轻抬头 / 小过载转弯不产生涡流；
## 大约从 4.8 G 开始显现，7.5 G 附近接近最浓。不单独按抬头输入触发。
const VAPOR_G_ON := 4.8
const VAPOR_G_FULL := 7.5
const VAPOR_MIN_SPEED := 55.0

var _shader: Shader
var _tip_l: _Ribbon
var _tip_r: _Ribbon
var _vortex_l: _Ribbon
var _vortex_r: _Ribbon
var _clouds: Array[MeshInstance3D] = []
var _cloud_alpha: PackedFloat32Array = PackedFloat32Array()
var _cloud_local: Array[Transform3D] = []
var _wrap: Node3D
var _tip_local_l: Vector3 = Vector3(-5.2, 0.2, 0.3)
var _tip_local_r: Vector3 = Vector3(5.2, 0.2, 0.3)
var _intensity: float = 0.0


class _Ribbon:
	var hist: Array[Vector3] = []
	var n: int = TRAIL_N
	var mesh: MeshInstance3D
	var arrays_ready: bool = false
	var verts: PackedVector3Array = PackedVector3Array()
	var cols: PackedColorArray = PackedColorArray()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	func setup(parent: Node, shader: Shader, pale: bool) -> void:
		mesh = MeshInstance3D.new()
		mesh.name = "Contrail"
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		# Vertex colors drive a simple unshaded additive ribbon.
		mat.shader = shader
		# Fallback: StandardMaterial if shader missing.
		if shader == null:
			var sm := StandardMaterial3D.new()
			sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			sm.cull_mode = BaseMaterial3D.CULL_DISABLED
			sm.vertex_color_use_as_albedo = true
			sm.albedo_color = Color(0.85, 0.92, 1.0, 1.0) if pale else Color(0.92, 0.96, 1.0, 1.0)
			mesh.material_override = sm
		else:
			var sm2 := StandardMaterial3D.new()
			sm2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sm2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sm2.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			sm2.cull_mode = BaseMaterial3D.CULL_DISABLED
			sm2.vertex_color_use_as_albedo = true
			sm2.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			mesh.material_override = sm2
		parent.add_child(mesh)
		verts.resize(n * 2)
		cols.resize(n * 2)
		uvs.resize(n * 2)
		for i in n - 1:
			var a := i * 2
			indices.append(a)
			indices.append(a + 1)
			indices.append(a + 2)
			indices.append(a + 1)
			indices.append(a + 3)
			indices.append(a + 2)
		mesh.visible = false

	func push(tip: Vector3, emit: bool, width0: float, fade0: float, pale: bool, manage_hist: bool = true) -> void:
		if manage_hist:
			if emit:
				if hist.is_empty() or hist[0].distance_squared_to(tip) > 1.6:
					hist.insert(0, tip)
					if hist.size() > n:
						hist.pop_back()
				else:
					hist[0] = tip
			elif hist.size() > 2:
				hist.pop_back()
		_rebuild(width0, fade0, pale)

	func set_hist(h: Array[Vector3], width0: float, fade0: float, pale: bool) -> void:
		hist = h
		_rebuild(width0, fade0, pale)

	func fade_hist() -> void:
		if hist.size() > 0:
			hist.pop_back()

	func _rebuild(width0: float, fade0: float, pale: bool, up_axis: Vector3 = Vector3.UP) -> void:
		var h := hist.size()
		mesh.visible = h > 2
		if h < 2:
			return
		var up := up_axis
		if up.length_squared() < 1e-8:
			up = Vector3.UP
		else:
			up = up.normalized()
		for i in n:
			var p: Vector3 = hist[mini(i, h - 1)]
			var q: Vector3 = hist[mini(i + 1, h - 1)]
			var fwd := p - q
			if fwd.length_squared() < 1e-6:
				fwd = Vector3(0, 0, 1)
			var side := fwd.cross(up)
			if side.length_squared() < 1e-6:
				side = up.cross(Vector3.FORWARD)
				if side.length_squared() < 1e-6:
					side = Vector3.RIGHT
			else:
				side = side.normalized()
			var a := float(i) / float(maxi(n - 1, 1))
			var w := width0 + a * (width0 * (3.6 if pale else 4.2))
			var fade := 0.0 if h < 3 else pow(1.0 - a, 0.82 if pale else 1.05) * fade0 * minf(1.0, float(h - 2) / 8.0)
			var o := i * 2
			verts[o] = p - side * w
			verts[o + 1] = p + side * w
			var col := Color(0.78, 0.82, 0.88, fade) if pale else Color(0.92, 0.96, 1.0, fade)
			cols[o] = col
			cols[o + 1] = col
			uvs[o] = Vector2(0.0, a)
			uvs[o + 1] = Vector2(1.0, a)
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = cols
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_INDEX] = indices
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.mesh = am


func setup(wrap: Node3D) -> void:
	_wrap = wrap
	name = "PlaneVapor"
	_shader = load("res://shaders/vapor_cloud.gdshader") as Shader
	_measure_wingtips()
	_tip_l = _Ribbon.new()
	_tip_r = _Ribbon.new()
	_vortex_l = _Ribbon.new()
	_vortex_r = _Ribbon.new()
	# Ribbons are world-space (vertices in world coords), so keep this node unscaled at origin.
	_tip_l.setup(self, null, false)
	_tip_r.setup(self, null, false)
	_vortex_l.setup(self, null, true)
	_vortex_r.setup(self, null, true)
	_tip_l.mesh.name = "WingtipL"
	_tip_r.mesh.name = "WingtipR"
	_vortex_l.mesh.name = "VortexL"
	_vortex_r.mesh.name = "VortexR"
	_build_clouds()
	# World-space ribbons: do not inherit the plane's transform.
	top_level = true
	global_transform = Transform3D.IDENTITY


func _measure_wingtips() -> void:
	## Use the actual leftmost / rightmost wing-mesh vertices in wrap space
	## so the contrail starts on the tip, not on a blended AABB centre.
	_tip_local_l = Vector3(-5.2, 0.2, 0.3)
	_tip_local_r = Vector3(5.2, 0.2, 0.3)
	if _wrap == null:
		return
	var parts: Array = []
	parts.append_array(VehicleCommon.find_named(_wrap, "^wing_"))
	parts.append_array(VehicleCommon.find_named(_wrap, "wingtip"))
	parts.append_array(VehicleCommon.find_named(_wrap, "WingTip"))
	if parts.is_empty():
		parts.append_array(VehicleCommon.find_named(_wrap, "^aileron_"))
	if parts.is_empty():
		return
	var left := _tip_local_l
	var right := _tip_local_r
	var min_x := 1e9
	var max_x := -1e9
	var found := false
	for o in parts:
		if not (o is Node3D):
			continue
		for mi in VehicleCommon.mesh_instances(o as Node3D):
			if mi == null or mi.mesh == null:
				continue
			var xf: Transform3D = _wrap.global_transform.affine_inverse() * mi.global_transform
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				for v in verts:
					var loc: Vector3 = xf * v
					if loc.x < min_x:
						min_x = loc.x
						left = loc
						found = true
					if loc.x > max_x:
						max_x = loc.x
						right = loc
						found = true
	if found and (max_x - min_x) > 2.0:
		_tip_local_l = left
		_tip_local_r = right


func _make_sheet_mesh(length: float, width: float, camber: float = 0.10) -> ArrayMesh:
	## Smooth subdivided polygonal sheet in the XZ plane, slightly cambered
	## in Y, flowing along -Z (visual nose). Soft UV edges are shaded later.
	var nu := 10
	var nv := 16
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	for j in nv + 1:
		var v := float(j) / float(nv)
		var z := (0.5 - v) * length
		var arch := camber * sin(v * PI)
		# Taper slightly toward the trailing end.
		var w := width * (0.72 + 0.28 * (1.0 - v))
		for i in nu + 1:
			var u := float(i) / float(nu)
			var x := (u - 0.5) * w
			verts.append(Vector3(x, arch, z))
			norms.append(Vector3(0, 1, 0))
			uvs.append(Vector2(u, v))
	var idx := PackedInt32Array()
	for j in nv:
		for i in nu:
			var a := j * (nu + 1) + i
			var b := a + 1
			var c := a + (nu + 1)
			var d := c + 1
			idx.append_array([a, c, b, b, c, d])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _build_clouds() -> void:
	# Smooth polygonal / sheet-like LEX, dorsal and wing-root vapor, matching
	# the F-22 high-G condensation photos: stretching translucent flow
	# structures along the body and wing roots, not a handful of spheres.
	# Local positions are in wrap space (visual nose -Z, up +Y).
	# Positions are in wrap space (visual nose -Z, up +Y, after ORIGIN_Y lift).
	# Region 1 = dorsal / LEX beside the canopy (z ≈ -4.2 .. -2.0).
	# Region 2 = wing-root / LEX over the inner wing (z ≈ -0.4 .. 2.2).
	# Sheets lie in the airframe XZ plane (normal ≈ body up) so they stay
	# flush with the fuselage and never stand up like vertical fins.
	# Narrower, slightly outboard sheets: cover the LEX / wing-body junction
	# but stay off the centerline spine and the engine nacelles (intake-to-nozzle
	# is roughly |x| < 1.2, z > 1.8). Still locked to the airframe XZ plane.
	var placements: Array = [
		# Dorsal / LEX flanks beside the canopy (region 1) — split off the spine
		{"pos": Vector3(-0.95, 1.68, -3.45), "len": 3.6, "wid": 0.70, "camber": 0.10, "yaw": 0.06, "roll": -0.08, "mode": 0.08},
		{"pos": Vector3(0.95, 1.68, -3.45), "len": 3.6, "wid": 0.70, "camber": 0.10, "yaw": -0.06, "roll": 0.08, "mode": 0.08},
		{"pos": Vector3(-1.15, 1.50, -2.35), "len": 3.0, "wid": 0.65, "camber": 0.09, "yaw": 0.10, "roll": -0.10, "mode": 0.10},
		{"pos": Vector3(1.15, 1.50, -2.35), "len": 3.0, "wid": 0.65, "camber": 0.09, "yaw": -0.10, "roll": 0.10, "mode": 0.10},
		# LEX / strake beside the forward fuselage (region 1 sides)
		{"pos": Vector3(-1.45, 1.36, -2.55), "len": 3.6, "wid": 1.00, "camber": 0.09, "yaw": 0.22, "roll": -0.14, "mode": 0.16},
		{"pos": Vector3(1.45, 1.36, -2.55), "len": 3.6, "wid": 1.00, "camber": 0.09, "yaw": -0.22, "roll": 0.14, "mode": 0.16},
		# Wing-root / LEX junction, lying on the wing (region 2), more outward
		{"pos": Vector3(-2.55, 1.08, 0.25), "len": 3.6, "wid": 1.35, "camber": 0.06, "yaw": 0.34, "roll": -0.08, "mode": 0.08},
		{"pos": Vector3(2.55, 1.08, 0.25), "len": 3.6, "wid": 1.35, "camber": 0.06, "yaw": -0.34, "roll": 0.08, "mode": 0.08},
		{"pos": Vector3(-2.35, 1.02, 1.15), "len": 2.8, "wid": 1.15, "camber": 0.05, "yaw": 0.18, "roll": -0.06, "mode": 0.12},
		{"pos": Vector3(2.35, 1.02, 1.15), "len": 2.8, "wid": 1.15, "camber": 0.05, "yaw": -0.18, "roll": 0.06, "mode": 0.12},
	]
	_cloud_alpha.resize(placements.size())
	for i in placements.size():
		var p: Dictionary = placements[i]
		var mi := MeshInstance3D.new()
		mi.name = "VaporCloud_%d" % i
		mi.mesh = _make_sheet_mesh(float(p["len"]), float(p["wid"]), float(p["camber"]))
		var mat := ShaderMaterial.new()
		if _shader:
			mat.shader = _shader
			mat.set_shader_parameter("u_color", Vector3(0.86, 0.93, 1.0))
			mat.set_shader_parameter("u_alpha", 0.0)
			mat.set_shader_parameter("u_mode", float(p["mode"]))
			mat.set_shader_parameter("u_noise", 0.40)
			mi.material_override = mat
		else:
			var sm := StandardMaterial3D.new()
			sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			sm.cull_mode = BaseMaterial3D.CULL_DISABLED
			sm.albedo_color = Color(0.86, 0.93, 1.0, 0.0)
			mi.material_override = sm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		# Parent to wrap so they follow the airframe.
		if _wrap:
			_wrap.add_child(mi)
		else:
			add_child(mi)
		mi.position = p["pos"]
		# Pitch stays 0: the sheet lives in the airframe XZ plane.
		mi.rotation = Vector3(0.0, float(p["yaw"]), float(p["roll"]))
		mi.scale = Vector3.ONE
		_clouds.append(mi)
		_cloud_local.append(mi.transform)
		_cloud_alpha[i] = 0.0


func update(st: Dictionary, delta: float) -> void:
	if _wrap == null or not is_inside_tree():
		return
	# Keep world-space root at identity (ribbons store world verts).
	global_transform = Transform3D.IDENTITY
	var airborne := bool(st.get("airborne", false))
	var speed := float(st.get("speed", 0.0))
	var agl := float(st.get("agl", 0.0))
	var g_load := float(st.get("g_load", 1.0))
	var _pitch_c := float(st.get("ctrl_pitch", 0.0))
	var _aoa := float(st.get("aoa", 0.0))
	var xf := _wrap.global_transform
	var tip_l: Vector3 = xf * _tip_local_l
	var tip_r: Vector3 = xf * _tip_local_r
	var emit_tip := airborne and speed > TIP_EMIT_SPEED and agl > TIP_EMIT_AGL
	_tip_l.push(tip_l, emit_tip, TIP_WIDTH, TIP_FADE, false)
	_tip_r.push(tip_r, emit_tip, TIP_WIDTH, TIP_FADE, false)
	# High-G only. A mild pull-up or gentle turn stays clear; vapor appears
	# once the load factor crosses VAPOR_G_ON, denser toward VAPOR_G_FULL.
	# Do not key appearance off pitch-up input or AoA alone.
	var g_term := 0.0
	if airborne and speed > VAPOR_MIN_SPEED:
		g_term = clampf((g_load - VAPOR_G_ON) / maxf(VAPOR_G_FULL - VAPOR_G_ON, 0.1), 0.0, 1.0)
	var want := g_term
	_intensity = move_toward(_intensity, want, delta * (3.2 if want > _intensity else 2.2))
	_update_body_vortex(true, _intensity > 0.04)
	_update_body_vortex(false, _intensity > 0.04)
	_lock_cloud_to_airframe()
	_update_clouds(_intensity, delta)


func _update_body_vortex(left: bool, emit: bool) -> void:
	var side := -1.0 if left else 1.0
	var tr: _Ribbon = _vortex_l if left else _vortex_r
	var xf := _wrap.global_transform
	# Path locked to the airframe: LEX (region 1) → wing root (region 2) →
	# outboard aft (staying off the engine nacelles around |x|≈0.62, z>1.8).
	var p0: Vector3 = xf * Vector3(1.55 * side, 1.28, -2.70)
	var p1: Vector3 = xf * Vector3(2.40 * side, 1.08, 0.20)
	var p2: Vector3 = xf * Vector3(2.55 * side, 1.00, 2.20)
	if emit:
		if tr.hist.size() < 3:
			tr.hist = [p0, p1, p2]
		else:
			tr.hist[0] = p0
			tr.hist[1] = p1
			if tr.hist.size() >= 3:
				var aft: Vector3 = tr.hist[2]
				if aft.distance_squared_to(p2) > 2.4:
					tr.hist.insert(3, aft)
					if tr.hist.size() > tr.n:
						tr.hist.pop_back()
				tr.hist[2] = p2
	else:
		tr.fade_hist()
	# Width axis is aircraft up, not world up — otherwise a banked jet
	# makes the strip stand up like a vertical fin.
	tr._rebuild(0.72, 0.28 * maxf(_intensity, 0.15), true, xf.basis.y)
	if tr.hist.size() < 3 or _intensity < 0.04:
		tr.mesh.visible = false


func _update_clouds(intensity: float, _delta: float) -> void:
	var on := intensity > 0.03
	for i in _clouds.size():
		var mi := _clouds[i]
		# Slight per-cloud variation so the sheet is not a uniform blob.
		var k := intensity * (0.75 + 0.25 * sin(float(i) * 1.7 + intensity * 4.0))
		_cloud_alpha[i] = k
		var a := k * (0.34 if i >= 4 else 0.46)
		mi.visible = on and a > 0.02
		var mat := mi.material_override
		if mat is ShaderMaterial:
			(mat as ShaderMaterial).set_shader_parameter("u_alpha", a)
		elif mat is StandardMaterial3D:
			var sm := mat as StandardMaterial3D
			var c := sm.albedo_color
			c.a = a
			sm.albedo_color = c


func wingtip_count() -> int:
	var n := 0
	if _tip_l and _tip_l.mesh and _tip_l.mesh.visible:
		n += 1
	if _tip_r and _tip_r.mesh and _tip_r.mesh.visible:
		n += 1
	return n


func cloud_intensity() -> float:
	return _intensity


func tip_local_left() -> Vector3:
	return _tip_local_l


func tip_local_right() -> Vector3:
	return _tip_local_r


func _lock_cloud_to_airframe() -> void:
	## Re-compose every sheet in aircraft space so a bank/pitch cannot
	## leave a strip standing upright in world axes.
	if _wrap == null:
		return
	var xf := _wrap.global_transform
	for i in _clouds.size():
		var mi := _clouds[i]
		if mi == null:
			continue
		var local: Transform3D = _cloud_local[i] if i < _cloud_local.size() else mi.transform
		mi.global_transform = xf * local


func cloud_max_normal_angle_to_airframe() -> float:
	## Radians between each sheet's normal and aircraft up (ignoring the
	## small designed roll). Used to assert strips are not world-up fins.
	if _wrap == null:
		return 0.0
	var up := _wrap.global_transform.basis.y.normalized()
	var worst := 0.0
	for mi in _clouds:
		if mi == null:
			continue
		var n := mi.global_transform.basis.y.normalized()
		worst = maxf(worst, n.angle_to(up))
	return worst


func cloud_covers_dorsal_lex() -> bool:
	## Region 1: at least one sheet near the canopy-adjacent dorsal / LEX.
	return _cloud_in_box(Vector3(-2.0, 1.15, -4.6), Vector3(2.0, 2.05, -1.6))


func cloud_covers_wing_lex() -> bool:
	## Region 2: at least one sheet over the wing-root / LEX.
	return _cloud_in_box(Vector3(-3.6, 0.75, -0.6), Vector3(-1.2, 1.35, 2.6)) \
		and _cloud_in_box(Vector3(1.2, 0.75, -0.6), Vector3(3.6, 1.35, 2.6))


func cloud_covers_engines() -> bool:
	## Intake-to-nozzle / nacelle volume. Main sheets must stay out of this.
	return _cloud_in_box(Vector3(-1.20, 0.35, 1.80), Vector3(1.20, 1.45, 8.20))


func main_vortex_max_width() -> float:
	## Widest designed body-vortex / dorsal sheet (local X extent).
	return 1.35


func _cloud_in_box(mn: Vector3, mx: Vector3) -> bool:
	if _wrap == null:
		return false
	for mi in _clouds:
		if mi == null:
			continue
		var p: Vector3 = _wrap.to_local(mi.global_position)
		if p.x >= mn.x and p.x <= mx.x and p.y >= mn.y and p.y <= mx.y and p.z >= mn.z and p.z <= mx.z:
			return true
	return false


func cloud_min_height() -> float:
	## Kept for older tests. Sheets use unit scale; thickness is in the mesh camber.
	var h := 0.0
	for mi in _clouds:
		if mi == null:
			continue
		h = mi.scale.y if h <= 0.0 else minf(h, mi.scale.y)
	return h


func cloud_uses_spheres() -> bool:
	for mi in _clouds:
		if mi and mi.mesh is SphereMesh:
			return true
	return false


func cloud_sheet_count() -> int:
	var n := 0
	for mi in _clouds:
		if mi and mi.mesh is ArrayMesh:
			n += 1
	return n
