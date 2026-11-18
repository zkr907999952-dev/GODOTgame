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
## 高过载云：大约从 2.4 G 抬头开始显现，6 G 附近接近最浓。
const VAPOR_G_ON := 2.4
const VAPOR_G_FULL := 6.0
const VAPOR_MIN_SPEED := 55.0

var _shader: Shader
var _tip_l: _Ribbon
var _tip_r: _Ribbon
var _vortex_l: _Ribbon
var _vortex_r: _Ribbon
var _clouds: Array[MeshInstance3D] = []
var _cloud_alpha: PackedFloat32Array = PackedFloat32Array()
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

	func _rebuild(width0: float, fade0: float, pale: bool) -> void:
		var h := hist.size()
		mesh.visible = h > 2
		if h < 2:
			return
		for i in n:
			var p: Vector3 = hist[mini(i, h - 1)]
			var q: Vector3 = hist[mini(i + 1, h - 1)]
			var fwd := p - q
			if fwd.length_squared() < 1e-6:
				fwd = Vector3(0, 0, 1)
			var side := fwd.cross(Vector3.UP)
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
	_tip_local_l = Vector3(-5.2, 0.2, 0.3)
	_tip_local_r = Vector3(5.2, 0.2, 0.3)
	if _wrap == null:
		return
	var parts: Array = []
	parts.append_array(VehicleCommon.find_named(_wrap, "^wing_"))
	parts.append_array(VehicleCommon.find_named(_wrap, "^aileron_"))
	if parts.is_empty():
		return
	var box := AABB()
	var any := false
	for o in parts:
		if not (o is Node3D):
			continue
		var wa := VehicleCommon.world_aabb(o as Node3D)
		var mn := _wrap.to_local(wa.position)
		var mx := _wrap.to_local(wa.position + wa.size)
		var a2 := AABB(Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z)), (mx - mn).abs())
		if not any:
			box = a2
			any = true
		else:
			box = box.merge(a2)
	if not any:
		return
	var y := box.position.y * 0.2 + (box.position.y + box.size.y) * 0.8
	var z := box.position.z * 0.25 + (box.position.z + box.size.z) * 0.75
	_tip_local_l = Vector3(box.position.x, y, z)
	_tip_local_r = Vector3(box.position.x + box.size.x, y, z)


func _build_clouds() -> void:
	# Soft additive discs / ellipsoids on the upper fuselage, LEX and wing roots.
	# Local positions are in wrap space (visual nose -Z, up +Y).
	var placements: Array = [
		# 1 = dorsal / spine / LEX (F-22 label 1)
		{"pos": Vector3(0.0, 1.15, -1.6), "size": Vector3(1.6, 0.55, 2.6), "mode": 0.15},
		{"pos": Vector3(0.0, 1.05, 0.4), "size": Vector3(1.3, 0.48, 2.2), "mode": 0.2},
		{"pos": Vector3(-0.55, 0.95, -0.6), "size": Vector3(1.1, 0.42, 1.8), "mode": 0.25},
		{"pos": Vector3(0.55, 0.95, -0.6), "size": Vector3(1.1, 0.42, 1.8), "mode": 0.25},
		# 2 = larger cloud off the wing / LEX / leading-edge (F-22 label 2)
		{"pos": Vector3(-2.4, 0.72, -0.2), "size": Vector3(2.4, 0.7, 2.8), "mode": 0.05},
		{"pos": Vector3(2.4, 0.72, -0.2), "size": Vector3(2.4, 0.7, 2.8), "mode": 0.05},
		{"pos": Vector3(-1.5, 0.85, -1.8), "size": Vector3(1.6, 0.5, 1.8), "mode": 0.15},
		{"pos": Vector3(1.5, 0.85, -1.8), "size": Vector3(1.6, 0.5, 1.8), "mode": 0.15},
	]
	_cloud_alpha.resize(placements.size())
	for i in placements.size():
		var p: Dictionary = placements[i]
		var mi := MeshInstance3D.new()
		mi.name = "VaporCloud_%d" % i
		var mesh := SphereMesh.new()
		mesh.radius = 0.5
		mesh.height = 1.0
		mesh.radial_segments = 20
		mesh.rings = 12
		mi.mesh = mesh
		var mat := ShaderMaterial.new()
		if _shader:
			mat.shader = _shader
			mat.set_shader_parameter("u_color", Vector3(0.83, 0.92, 1.0))
			mat.set_shader_parameter("u_alpha", 0.0)
			mat.set_shader_parameter("u_mode", float(p["mode"]))
			mi.material_override = mat
		else:
			var sm := StandardMaterial3D.new()
			sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			sm.cull_mode = BaseMaterial3D.CULL_DISABLED
			sm.albedo_color = Color(0.83, 0.92, 1.0, 0.0)
			mi.material_override = sm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		# Parent to wrap so they follow the airframe.
		if _wrap:
			_wrap.add_child(mi)
		else:
			add_child(mi)
		mi.position = p["pos"]
		mi.scale = p["size"]
		_clouds.append(mi)
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
	var pitch_c := float(st.get("ctrl_pitch", 0.0))
	var aoa := float(st.get("aoa", 0.0))
	var xf := _wrap.global_transform
	var tip_l: Vector3 = xf * _tip_local_l
	var tip_r: Vector3 = xf * _tip_local_r
	var emit_tip := airborne and speed > TIP_EMIT_SPEED and agl > TIP_EMIT_AGL
	_tip_l.push(tip_l, emit_tip, TIP_WIDTH, TIP_FADE, false)
	_tip_r.push(tip_r, emit_tip, TIP_WIDTH, TIP_FADE, false)
	# High-G pull-up only (ctrl_pitch > 0 = nose up). Intensity scales with G.
	var pull_up := airborne and pitch_c > 0.18 and speed > VAPOR_MIN_SPEED
	var g_term := 0.0
	if pull_up:
		g_term = clampf((g_load - VAPOR_G_ON) / maxf(VAPOR_G_FULL - VAPOR_G_ON, 0.1), 0.0, 1.0)
		if aoa > 0.16:
			g_term = maxf(g_term, clampf((aoa - 0.16) / 0.22, 0.0, 0.55) * clampf(speed / 90.0, 0.0, 1.0))
	var want := g_term if pull_up else 0.0
	_intensity = move_toward(_intensity, want, delta * (3.2 if want > _intensity else 2.2))
	_update_body_vortex(true, _intensity > 0.04)
	_update_body_vortex(false, _intensity > 0.04)
	_update_clouds(_intensity, delta)


func _update_body_vortex(left: bool, emit: bool) -> void:
	var side := -1.0 if left else 1.0
	var tr: _Ribbon = _vortex_l if left else _vortex_r
	var xf := _wrap.global_transform
	var p0: Vector3 = xf * Vector3(1.42 * side, 0.62, -1.2)
	var p1: Vector3 = xf * Vector3(1.42 * side * 0.22, 0.86, 1.55)
	var p2: Vector3 = xf * Vector3(1.42 * side * 0.38, 0.42, 5.35)
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
	tr._rebuild(1.35, 0.28 * maxf(_intensity, 0.15), true)
	if tr.hist.size() < 3 or _intensity < 0.04:
		tr.mesh.visible = false


func _update_clouds(intensity: float, _delta: float) -> void:
	var on := intensity > 0.03
	for i in _clouds.size():
		var mi := _clouds[i]
		# Slight per-cloud variation so the sheet is not a uniform blob.
		var k := intensity * (0.75 + 0.25 * sin(float(i) * 1.7 + intensity * 4.0))
		_cloud_alpha[i] = k
		var a := k * (0.22 if i >= 4 else 0.32)
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
