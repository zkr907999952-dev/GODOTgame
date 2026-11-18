extends Node3D
## Jet exhaust + shock diamonds, rebuilt from vehicles.tsx makeJetExhaust / setExhaust.
## Diamonds are more physical than the web sim: spacing follows a nozzle-pressure
## ratio model (grows with afterburner, slightly with altitude), brightness and
## visibility fade at low thrust and very high altitude.
##
## The plume itself is a soft, lagged trail: mid/core segments follow a short
## history of the nozzle so the flame bends with flight-path inertia instead
## of staying a rigid straight cone behind the nozzles.
class_name JetExhaust

const DIAMOND_COUNT := 5
const TRAIL_COUNT := 7
## Approx nozzle exit diameter used for diamond spacing (metres).
const EXIT_DIAMETER := 0.55
const SEA_LEVEL_RHO := 1.225

var core: MeshInstance3D
var mid: MeshInstance3D
var glow: MeshInstance3D
var diamonds: Array[MeshInstance3D] = []
var _segs_core: Array[MeshInstance3D] = []
var _segs_mid: Array[MeshInstance3D] = []
var light: OmniLight3D
var _flame_shader: Shader
var _diamond_shader: Shader
## World-space lag points of the plume (index 0 = nozzle).
var _trail: PackedVector3Array = PackedVector3Array()
var _trail_ready: bool = false
var _last_time: float = -1.0


func _ready() -> void:
	_build()


func _build() -> void:
	name = "JetExhaust"
	_flame_shader = load("res://shaders/jet_exhaust.gdshader") as Shader
	_diamond_shader = load("res://shaders/jet_diamond.gdshader") as Shader
	core = _plume(0.22, Color(0.847, 0.965, 1.0), 0.7)
	core.name = "Core"
	mid = _plume(0.34, Color(0.227, 0.627, 1.0), 0.7)
	mid.name = "Mid"
	# Straight teardrops stay hidden; the lagged segments are the visible plume.
	core.visible = false
	mid.visible = false
	glow = MeshInstance3D.new()
	glow.name = "Glow"
	var sph := SphereMesh.new()
	sph.radius = 0.28
	sph.height = 0.56
	sph.radial_segments = 14
	sph.rings = 10
	glow.mesh = sph
	glow.material_override = _flame_mat(Color(0.604, 0.831, 1.0), 0.45)
	for i in DIAMOND_COUNT:
		var d := MeshInstance3D.new()
		d.name = "Diamond_%d" % i
		d.mesh = VehicleCommon.make_diamond_mesh()
		# Align diamond axis with aft (+Z) like the plume.
		d.rotation.x = PI * 0.5
		d.material_override = _diamond_mat(Color(1.0, 0.902, 0.69), 0.0, float(i))
		d.visible = false
		diamonds.append(d)
		add_child(d)
	for i in TRAIL_COUNT:
		var aim_c := Node3D.new()
		aim_c.name = "CoreAim_%d" % i
		add_child(aim_c)
		var sc := _plume(0.18, Color(0.847, 0.965, 1.0), 0.5)
		sc.name = "CoreSeg_%d" % i
		aim_c.add_child(sc)
		_segs_core.append(sc)
		var aim_m := Node3D.new()
		aim_m.name = "MidAim_%d" % i
		add_child(aim_m)
		var sm := _plume(0.28, Color(0.227, 0.627, 1.0), 0.4)
		sm.name = "MidSeg_%d" % i
		aim_m.add_child(sm)
		_segs_mid.append(sm)
	light = OmniLight3D.new()
	light.name = "ExhaustLight"
	light.light_color = Color(0.4, 0.878, 1.0)
	light.light_energy = 0.0
	light.omni_range = 14.0
	light.shadow_enabled = false
	add_child(core)
	add_child(mid)
	add_child(glow)
	add_child(light)
	visible = false


func _plume(r_base: float, col: Color, alpha: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = VehicleCommon.make_teardrop_mesh(r_base)
	# Web: mesh.rotation.x = -PI/2, and exhaust sits at the tail pointing aft (+Z).
	# +90° X maps lathe +Y → +Z in Godot (right-handed, Y-up).
	mi.rotation.x = PI * 0.5
	mi.material_override = _flame_mat(col, alpha)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _flame_mat(col: Color, alpha: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _flame_shader
	m.set_shader_parameter("u_color", Vector3(col.r, col.g, col.b))
	m.set_shader_parameter("u_alpha", alpha)
	return m


func _diamond_mat(col: Color, alpha: float, index: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _diamond_shader
	m.set_shader_parameter("u_color", Vector3(col.r, col.g, col.b))
	m.set_shader_parameter("u_alpha", alpha)
	m.set_shader_parameter("u_index", index)
	return m


func _set_flame(mi: MeshInstance3D, col: Color, alpha: float) -> void:
	var m := mi.material_override as ShaderMaterial
	if m == null:
		return
	m.set_shader_parameter("u_color", Vector3(col.r, col.g, col.b))
	m.set_shader_parameter("u_alpha", alpha)


func apply(thrust: float, time: float, altitude: float = 0.0, delta: float = 0.016) -> void:
	var cr := clampf(thrust / 0.8, 0.0, 1.0)
	var ab := clampf((thrust - 0.8) / 0.2, 0.0, 1.0)
	var flicker := 1.0 + sin(time * (18.0 + ab * 28.0)) * (0.022 + ab * 0.06)
	var pull := 1.0 + sin(time * (6.0 + ab * 8.0)) * (0.06 + ab * 0.1)
	var length := (2.8 + cr * 3.4 + ab * 8.6) * flicker * pull
	var rad := 1.02 + cr * 0.10 + ab * 0.16
	# Soft nozzle glow stays on the exit plane.
	glow.scale = Vector3(rad * 1.14, rad * 0.78, rad * 1.14)
	glow.position = Vector3(0.0, 0.0, 0.04)
	var core_col := Color(0.91, 0.965, 1.0) if ab > 0.01 else Color(1.0, 0.878, 0.541)
	var mid_col := Color(0.227, 0.627, 1.0) if ab > 0.01 else Color(1.0, 0.165, 0.0)
	var glow_col := Color(0.494, 0.784, 1.0) if ab > 0.01 else Color(1.0, 0.353, 0.063)
	_set_flame(glow, glow_col, 0.22 + cr * 0.2 + ab * 0.26)
	light.light_color = Color(0.4, 0.784, 1.0) if ab > 0.15 else Color(1.0, 0.29, 0.07)
	light.light_energy = cr * 3.4 + ab * 16.0
	light.omni_range = 7.0 + ab * 16.0
	visible = thrust > 0.02
	var dt := delta
	if _last_time >= 0.0 and time > _last_time:
		dt = maxf(time - _last_time, 0.001)
	# time is often an epoch-ms style clock; keep delta from the caller when huge.
	if dt > 0.2:
		dt = maxf(delta, 0.008)
	_last_time = time
	_update_trail(length, dt)
	_pose_segments(length, rad, cr, ab, flicker, core_col, mid_col)
	_apply_diamonds(thrust, cr, ab, rad, flicker, altitude)


func _aft_world() -> Vector3:
	# Local +Z is aft of the nozzle.
	var aft := global_transform.basis.z
	if aft.length_squared() < 1e-8:
		return Vector3(0, 0, 1)
	return aft.normalized()


func reset_trail() -> void:
	_trail_ready = false
	_trail = PackedVector3Array()


func _update_trail(length: float, dt: float) -> void:
	var origin := global_position
	var aft := _aft_world()
	var spacing := length / float(maxi(TRAIL_COUNT - 1, 1))
	# A teleport / spawn jump would otherwise leave a huge leftover streak.
	if _trail_ready and _trail.size() == TRAIL_COUNT and _trail[0].distance_to(origin) > 8.0:
		_trail_ready = false
	if not _trail_ready or _trail.size() != TRAIL_COUNT:
		_trail = PackedVector3Array()
		_trail.resize(TRAIL_COUNT)
		for i in TRAIL_COUNT:
			_trail[i] = origin + aft * spacing * float(i)
		_trail_ready = true
		return
	# Head is glued to the nozzle. Later points chase the previous one like a
	# soft rope, so a turn leaves a gently curved lag along the flight path.
	_trail[0] = origin
	var follow := 1.0 - exp(-3.4 * dt)
	for i in range(1, TRAIL_COUNT):
		var inherit: Vector3 = _trail[i] - _trail[i - 1]
		if inherit.length_squared() < 1e-6:
			inherit = aft * spacing
		else:
			inherit = inherit.normalized() * spacing
		# Mostly keep the inherited direction (inertia), with a gentle pull to aft.
		var want: Vector3 = _trail[i - 1] + inherit.lerp(aft * spacing, 0.28)
		_trail[i] = _trail[i].lerp(want, follow)


func _pose_segments(
	length: float, rad: float, cr: float, ab: float, flicker: float,
	core_col: Color, mid_col: Color
) -> void:
	var inv := global_transform.affine_inverse()
	var seg_len := length / float(maxi(TRAIL_COUNT, 1))
	for i in TRAIL_COUNT:
		var a: Vector3 = inv * _trail[i]
		var b_world: Vector3 = _trail[i + 1] if i + 1 < TRAIL_COUNT else (_trail[i] + _aft_world())
		var b: Vector3 = inv * b_world
		var tangent := b - a
		if tangent.length_squared() < 1e-8:
			tangent = Vector3(0, 0, 1)
		else:
			tangent = tangent.normalized()
		# Aim parent +Z along the trail; the teardrop child keeps its +90° X
		# so the long axis follows that +Z.
		var up := Vector3.UP
		if absf(tangent.dot(up)) > 0.94:
			up = Vector3.RIGHT
		var basis := Basis.looking_at(-tangent, up)  # looking_at aims -Z at the arg, so -tangent → +Z along tangent
		var taper := 1.0 - float(i) / float(maxi(TRAIL_COUNT, 1))
		var sc: MeshInstance3D = _segs_core[i]
		var sm: MeshInstance3D = _segs_mid[i]
		var aim_c: Node3D = sc.get_parent()
		var aim_m: Node3D = sm.get_parent()
		var visible_seg := visible
		aim_c.visible = visible_seg
		aim_m.visible = visible_seg
		aim_c.transform = Transform3D(basis, a)
		aim_m.transform = Transform3D(basis, a)
		var rad_c := rad * (0.72 + taper * 0.28) * (0.9 + cr * 0.08)
		var rad_m := rad * (1.05 + taper * 0.2) * 1.08
		sc.position = Vector3.ZERO
		sm.position = Vector3.ZERO
		sc.scale = Vector3(rad_c, seg_len * 1.35, rad_c)
		sm.scale = Vector3(rad_m, seg_len * 1.55, rad_m)
		var fade := (0.34 + cr * 0.32 + ab * 0.24) * flicker * (0.45 + taper * 0.55)
		var fade_m := (0.18 + cr * 0.18 + ab * 0.22) * flicker * (0.4 + taper * 0.6)
		_set_flame(sc, core_col, fade)
		_set_flame(sm, mid_col, fade_m)


func trail_curve_amount() -> float:
	## 0 = colinear with current aft; larger means the plume is bent.
	if not _trail_ready or _trail.size() < 3:
		return 0.0
	var aft := _aft_world()
	var origin := _trail[0]
	var acc := 0.0
	for i in range(1, _trail.size()):
		var d: Vector3 = _trail[i] - origin
		if d.length_squared() < 1e-6:
			continue
		acc += d.normalized().cross(aft).length()
	return acc / float(_trail.size() - 1)


func _apply_diamonds(thrust: float, cr: float, ab: float, rad: float, flicker: float, altitude: float) -> void:
	# Ambient pressure ratio (ISA-ish). Higher altitude → lower Pa → higher NPR.
	var p_ratio := exp(-maxf(altitude, 0.0) / 8500.0)
	var density := clampf(p_ratio, 0.12, 1.0)
	# Nozzle pressure ratio grows with dry thrust and afterburner.
	var npr := 1.0 + cr * 1.6 + ab * 3.4
	npr /= maxf(p_ratio, 0.2)
	# Spacing of Mach disks ≈ 0.8–1.5 · D · sqrt(NPR − 1).
	var spacing := EXIT_DIAMETER * 1.15 * sqrt(maxf(npr - 1.0, 0.0)) * flicker
	spacing = clampf(spacing, 0.35, 2.4)
	# Visible once the jet is clearly underexpanded (high dry or any AB).
	var vis := clampf((thrust - 0.55) / 0.25, 0.0, 1.0)
	vis *= clampf(0.35 + ab * 0.9, 0.0, 1.0)
	# Fade in very thin air (plume barely scatters) and at low thrust.
	vis *= clampf(density * 1.15, 0.15, 1.0)
	var inv := global_transform.affine_inverse()
	for i in diamonds.size():
		var d := diamonds[i]
		if vis < 0.04:
			d.visible = false
			continue
		d.visible = true
		# Place disks along the lagged trail, not a straight aft line.
		var along := 0.38 + float(i) * spacing * (1.0 + float(i) * 0.04)
		d.position = inv * _point_along_trail(along)
		d.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		var s := rad * (0.55 - float(i) * 0.06)
		d.scale = Vector3(s, s * 0.42, s)
		var alpha := vis * (0.16 + ab * 0.34) * (1.0 - float(i) * 0.16) * flicker
		var m := d.material_override as ShaderMaterial
		if m:
			m.set_shader_parameter("u_alpha", alpha)
			m.set_shader_parameter("u_index", float(i))


func _point_along_trail(dist: float) -> Vector3:
	if not _trail_ready or _trail.size() < 2:
		return global_position + _aft_world() * dist
	var acc := 0.0
	for i in range(1, _trail.size()):
		var a: Vector3 = _trail[i - 1]
		var b: Vector3 = _trail[i]
		var seg := a.distance_to(b)
		if acc + seg >= dist or i == _trail.size() - 1:
			var t := 0.0 if seg < 1e-6 else clampf((dist - acc) / seg, 0.0, 1.0)
			return a.lerp(b, t)
		acc += seg
	return _trail[_trail.size() - 1]
