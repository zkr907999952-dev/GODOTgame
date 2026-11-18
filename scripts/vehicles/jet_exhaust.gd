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
## Short tight chain of spherical fireballs behind the nozzle — NOT the
## Mach diamonds, and not a trail that can grow without bound.
const FIREBALL_COUNT := 4
const FIREBALL_SPACING := 0.20
const FIREBALL_MAX_ALONG := 0.92
const TRAIL_COUNT := 4
## Approx nozzle exit diameter used for diamond spacing (metres).
const EXIT_DIAMETER := 0.55
const SEA_LEVEL_RHO := 1.225

var core: MeshInstance3D
var mid: MeshInstance3D
var glow: MeshInstance3D
var diamonds: Array[MeshInstance3D] = []
var fireballs: Array[MeshInstance3D] = []
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
	# Visible teardrop body (0.2.20 makeJetExhaust / setExhaust) so the plume
	# has clear boundaries. The lagged trail is a soft curved halo around it.
	core.visible = true
	mid.visible = true
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
	# Short, capped chain of spherical fire lights behind the nozzle.
	# These are separate from the Mach diamonds and from the main teardrop plume.
	for i in FIREBALL_COUNT:
		var fb := MeshInstance3D.new()
		fb.name = "Fireball_%d" % i
		var ball := SphereMesh.new()
		ball.radius = 0.22
		ball.height = 0.44
		ball.radial_segments = 14
		ball.rings = 10
		fb.mesh = ball
		fb.material_override = _flame_mat(Color(1.0, 0.55, 0.16), 0.0)
		fb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fb.visible = false
		fireballs.append(fb)
		add_child(fb)
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
	# Restore the original plume body (clear core / mid boundaries).
	core.visible = thrust > 0.02
	mid.visible = thrust > 0.02
	core.scale = Vector3(rad * 0.78, length, rad * 0.78)
	core.position = Vector3(0.0, 0.0, length * 0.42)
	mid.scale = Vector3(rad * 1.12, length * 1.22, rad * 1.12)
	mid.position = Vector3(0.0, 0.0, length * 0.5)
	_set_flame(core, core_col, (0.42 + cr * 0.40 + ab * 0.30) * flicker)
	_set_flame(mid, mid_col, (0.24 + cr * 0.26 + ab * 0.28) * flicker)
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
	_pose_fireballs(thrust, cr, ab, rad, flicker, mid_col if ab > 0.01 else Color(1.0, 0.42, 0.08))
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


func _update_trail(_length: float, dt: float) -> void:
	var origin := global_position
	var aft := _aft_world()
	# Fireball chain length is hard-capped. Never inherit a spacing from the
	# (much longer) plume body — that is what stretched the balls into an
	# endlessly stacking streak.
	var spacing := FIREBALL_SPACING
	var max_along := FIREBALL_MAX_ALONG
	# A teleport / spawn jump would otherwise leave a leftover streak.
	if _trail_ready and _trail.size() == FIREBALL_COUNT and _trail[0].distance_to(origin) > 4.0:
		_trail_ready = false
	if not _trail_ready or _trail.size() != FIREBALL_COUNT:
		_trail = PackedVector3Array()
		_trail.resize(FIREBALL_COUNT)
		for i in FIREBALL_COUNT:
			var along := minf(0.16 + float(i) * spacing, max_along)
			_trail[i] = origin + aft * along
		_trail_ready = true
		return
	var follow := 1.0 - exp(-8.0 * dt)
	for i in FIREBALL_COUNT:
		var along := minf(0.16 + float(i) * spacing, max_along)
		var want: Vector3 = origin + aft * along
		# Tiny lag for a soft curve, but clamp so the chain cannot lengthen.
		_trail[i] = _trail[i].lerp(want, follow)
		if _trail[i].distance_to(origin) > max_along + 0.08:
			_trail[i] = want


func _pose_fireballs(thrust: float, cr: float, ab: float, rad: float, flicker: float, col: Color) -> void:
	var on := visible and thrust > 0.02
	var inv := global_transform.affine_inverse()
	var n := fireballs.size()
	for i in n:
		var fb := fireballs[i]
		if not on:
			fb.visible = false
			continue
		var along := minf(0.16 + float(i) * FIREBALL_SPACING, FIREBALL_MAX_ALONG)
		var pos: Vector3
		if _trail_ready and i < _trail.size():
			pos = inv * _trail[i]
			# Hard cap in local space so a lagged point cannot run away.
			if pos.length() > FIREBALL_MAX_ALONG + 0.08:
				pos = Vector3(0.0, 0.0, along)
		else:
			pos = Vector3(0.0, 0.0, along)
		fb.visible = true
		fb.position = pos
		var taper := 1.0 - float(i) / float(maxi(n, 1))
		var s := rad * (0.42 + taper * 0.22) * (0.85 + cr * 0.10 + ab * 0.16)
		fb.scale = Vector3(s, s, s)
		var alpha := (0.28 + cr * 0.22 + ab * 0.34) * flicker * (0.55 + taper * 0.45)
		_set_flame(fb, col, alpha)


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
	# Restore a physical, clearly visible Mach-diamond spacing. Tight spacing
	# was applied to the fireball chain (not the diamonds) in 0.2.26.
	var spacing := EXIT_DIAMETER * 1.15 * sqrt(maxf(npr - 1.0, 0.0)) * flicker
	spacing = clampf(spacing, 0.38, 1.15)
	# Visible once dry thrust is clearly up, and obviously on afterburner.
	var vis := clampf((thrust - 0.38) / 0.28, 0.0, 1.0)
	vis *= clampf(0.55 + ab * 0.8, 0.0, 1.0)
	# Fade in very thin air (plume barely scatters) and at low thrust.
	vis *= clampf(density * 1.20, 0.22, 1.0)
	# Mach diamonds stay inside the visible plume, but are no longer crushed
	# into a short invisible stack.
	var tip := plume_tip_length()
	var last_along := 0.42 + float(maxi(diamonds.size() - 1, 0)) * spacing
	var cap := maxf(tip * 0.92, 1.15)
	if last_along > cap and last_along > 1e-4:
		spacing *= cap / last_along
		spacing = maxf(spacing, 0.32)
	for i in diamonds.size():
		var d := diamonds[i]
		if vis < 0.05:
			d.visible = false
			continue
		var along := 0.42 + float(i) * spacing
		along = minf(along, cap)
		if tip > 0.4 and along > tip - 0.04:
			d.visible = false
			continue
		d.visible = true
		# Diamonds sit on a straight aft line (the shock train), not on the
		# lagged fireball trail — mixing the two hid the disks.
		d.position = Vector3(0.0, 0.0, along)
		d.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		var s := rad * (0.92 - float(i) * 0.08)
		d.scale = Vector3(s, s * 0.55, s)
		var alpha := vis * (0.55 + ab * 0.55) * (1.0 - float(i) * 0.10) * flicker
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


func plume_body_length() -> float:
	## World-ish length of the visible teardrop body (core scale.y is the lathe length).
	if core == null or not visible:
		return 0.0
	return absf(core.scale.y)


func plume_tip_length() -> float:
	## Distance from the nozzle to the visible mid-plume tip (teardrop y in [-0.5, 0.5]).
	if mid == null or not visible:
		return plume_body_length()
	return absf(mid.position.z) + absf(mid.scale.y) * 0.5


func plume_body_visible() -> bool:
	return visible and core != null and core.visible and mid != null and mid.visible

func fireball_span() -> float:
	## Local-Z distance from the first visible fireball to the last.
	var zs: Array[float] = []
	for fb in fireballs:
		if fb and fb.visible:
			zs.append(absf(fb.position.z))
	if zs.size() < 2:
		return 0.0 if zs.is_empty() else zs[0]
	zs.sort()
	return zs[zs.size() - 1] - zs[0]


func fireball_visible_count() -> int:
	var n := 0
	for fb in fireballs:
		if fb and fb.visible:
			n += 1
	return n


func diamond_visible_count() -> int:
	var n := 0
	for d in diamonds:
		if d and d.visible:
			n += 1
	return n


func diamond_spacing() -> float:
	var alongs: Array[float] = []
	for d in diamonds:
		if d and d.visible:
			alongs.append(d.position.z)
	alongs.sort()
	if alongs.size() < 2:
		return 0.0
	return alongs[1] - alongs[0]
