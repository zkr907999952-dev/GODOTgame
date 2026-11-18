extends Node3D
## Jet exhaust + shock diamonds, rebuilt from vehicles.tsx makeJetExhaust / setExhaust.
## Diamonds are more physical than the web sim: spacing follows a nozzle-pressure
## ratio model (grows with afterburner, slightly with altitude), brightness and
## visibility fade at low thrust and very high altitude.
class_name JetExhaust

const DIAMOND_COUNT := 5
## Approx nozzle exit diameter used for diamond spacing (metres).
const EXIT_DIAMETER := 0.55
const SEA_LEVEL_RHO := 1.225

var core: MeshInstance3D
var mid: MeshInstance3D
var glow: MeshInstance3D
var diamonds: Array[MeshInstance3D] = []
var light: OmniLight3D
var _flame_shader: Shader
var _diamond_shader: Shader


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


func apply(thrust: float, time: float, altitude: float = 0.0) -> void:
	var cr := clampf(thrust / 0.8, 0.0, 1.0)
	var ab := clampf((thrust - 0.8) / 0.2, 0.0, 1.0)
	var flicker := 1.0 + sin(time * (22.0 + ab * 36.0)) * (0.018 + ab * 0.05)
	var pull := 1.0 + sin(time * (7.0 + ab * 10.0)) * (0.05 + ab * 0.1)
	var length := (2.8 + cr * 3.4 + ab * 8.6) * flicker * pull
	var rad := 0.95 + cr * 0.08 + ab * 0.14
	core.scale = Vector3(rad * 0.78, length, rad * 0.78)
	core.position = Vector3(0.0, 0.0, length * 0.42)
	mid.scale = Vector3(rad * 1.12, length * 1.22, rad * 1.12)
	mid.position = Vector3(0.0, 0.0, length * 0.5)
	glow.scale = Vector3(rad * 1.08, rad * 0.72, rad * 1.08)
	glow.position = Vector3(0.0, 0.0, 0.04)
	var core_col := Color(0.91, 0.965, 1.0) if ab > 0.01 else Color(1.0, 0.878, 0.541)
	var mid_col := Color(0.227, 0.627, 1.0) if ab > 0.01 else Color(1.0, 0.165, 0.0)
	var glow_col := Color(0.494, 0.784, 1.0) if ab > 0.01 else Color(1.0, 0.353, 0.063)
	_set_flame(core, core_col, (0.3 + cr * 0.38 + ab * 0.28) * flicker)
	_set_flame(mid, mid_col, (0.16 + cr * 0.2 + ab * 0.26) * flicker)
	_set_flame(glow, glow_col, 0.22 + cr * 0.2 + ab * 0.26)
	light.light_color = Color(0.4, 0.784, 1.0) if ab > 0.15 else Color(1.0, 0.29, 0.07)
	light.light_energy = cr * 3.4 + ab * 16.0
	light.omni_range = 7.0 + ab * 16.0
	visible = thrust > 0.02
	_apply_diamonds(thrust, cr, ab, rad, flicker, altitude)


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
	for i in diamonds.size():
		var d := diamonds[i]
		if vis < 0.04:
			d.visible = false
			continue
		d.visible = true
		# First disk sits just aft of the throat, then evenly spaced, slightly stretching.
		var z := 0.38 + float(i) * spacing * (1.0 + float(i) * 0.04)
		d.position = Vector3(0.0, 0.0, z)
		var s := rad * (0.55 - float(i) * 0.06)
		d.scale = Vector3(s, s * 0.42, s)
		var alpha := vis * (0.16 + ab * 0.34) * (1.0 - float(i) * 0.16) * flicker
		var m := d.material_override as ShaderMaterial
		if m:
			m.set_shader_parameter("u_alpha", alpha)
			m.set_shader_parameter("u_index", float(i))
