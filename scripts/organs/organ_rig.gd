extends Node
## 体内脏器 + 腹壁透视 + 软组织互动（移植自网页 rouchangmoniqi3 figure.tsx）。
##
## - 资源：tools/bake_organs.py 把网页的 intestines.glb / pelvis.glb 按网页同款流程摆进腹腔，
##   并烘好蒙皮权重（C_Hip_a / C_Spine_a..d）与肠蠕动参数，输出 assets/organs/organs_mesh.bin。
## - 透视：躯干皮肤换成 skin_xray（挖孔）+ skin_xray_fade（半透明覆盖层），与网页 attachXray 一致。
## - 互动：拖拽（setTissueDrag）/ 击腹（BellyStrike + 肠蠕动兴奋）。其余模式（拳头/刺刀/肚脐）仍为占位。

const PACK_PATH := "res://assets/organs/organs_mesh.bin"
const META_PATH := "res://assets/organs/organs_meta.json"
const SKIN_SHADER := preload("res://shaders/skin_xray.gdshader")
const SKIN_FADE_SHADER := preload("res://shaders/skin_xray_fade.gdshader")
const ORGAN_SHADER := preload("res://shaders/organ.gdshader")
const RING_SHADER := preload("res://shaders/fx_ring.gdshader")
const TEX := {
	0: ["res://assets/organs/colon_albedo.jpg", "res://assets/organs/colon_normal.jpg"],
	1: ["res://assets/organs/small_albedo.jpg", "res://assets/organs/small_normal.jpg"],
}
## 网页默认 abdomenXray = 0.38（X 键在 0 / 0.38 间切换）
const XRAY_DEFAULT := 0.38
## 光照层：腹内补光只照脏器
const ORGAN_LIGHT_LAYER := 1 << 19
const STRIKE_LIFE := 3.6

# --- 公共状态（HUD 读写）
var xray_enabled: bool = true
var xray_amount: float = XRAY_DEFAULT
var show_organs: bool = true
var interact_mode: String = "drag"
var strike_force: float = 0.52
var strike_range: float = 0.32
var strike_rebound: float = 0.72
var gut_amp: float = 0.3
var gut_speed: float = 0.5
var peristalsis_on: bool = true

var ready_ok: bool = false
var meta: Dictionary = {}
var organ_meshes: Array[MeshInstance3D] = []
var skin_meshes: Array[MeshInstance3D] = []

var _skel: Skeleton3D
var _spine_i: int = -1
var _navel_rest: Vector3 = Vector3(0.0, 1.06, 0.114)
var _skin_mats: Array[ShaderMaterial] = []
var _organ_mats: Array[ShaderMaterial] = []
var _all_mats: Array[ShaderMaterial] = []
var _time: float = 0.0
var _gut_exc: float = 0.0
var _waves: Array = []  # {p: Vector3 (ab-local), t, force, range, rebound}
var _drag_active: bool = false
var _drag_grab: Vector3 = Vector3.ZERO
var _drag_target: Vector3 = Vector3.ZERO
var _drag_off: Vector3 = Vector3.ZERO
var _drag_vel: Vector3 = Vector3.ZERO
var _frame: Transform3D = Transform3D.IDENTITY  # ab-local → world (orthonormal)
var _ellipsoid_c: Vector3 = Vector3(0.0, -0.03, -0.1)
var _ellipsoid_r: Vector3 = Vector3(0.13, 0.19, 0.1)
var _ring: MeshInstance3D
var _poke: MeshInstance3D
var _ring_mat: ShaderMaterial
var _poke_mat: ShaderMaterial
var _light: OmniLight3D


func setup(skel: Skeleton3D) -> bool:
	_skel = skel
	if _skel == null:
		push_warning("organs: no skeleton")
		return false
	_spine_i = _skel.find_bone("C_Spine_a")
	if _spine_i < 0:
		_spine_i = _skel.find_bone("C_Hip_a")
	meta = _load_meta()
	if meta.has("navel"):
		var n: Array = meta["navel"]
		_navel_rest = Vector3(n[0], n[1], n[2])
	_fit_hit_ellipsoid()
	_install_skin_xray()
	if not _build_organs():
		return false
	_build_fx()
	ready_ok = true
	_update_frame()
	# Park hidden FX quads at the navel (tiny) so body AABB checks stay valid.
	for q in [_ring, _poke]:
		q.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.01), _frame.origin)
	_push_uniforms()
	print("organs: ready meshes=", organ_meshes.size(), " skin=", skin_meshes.size(), " navel=", _navel_rest)
	return true


# ------------------------------------------------------------------ public API
func set_xray_enabled(on: bool) -> void:
	xray_enabled = on


func toggle_xray() -> void:
	xray_enabled = not xray_enabled


func set_xray_amount(v: float) -> void:
	xray_amount = clampf(v, 0.0, 1.0)


func effective_xray() -> float:
	return xray_amount if xray_enabled else 0.0


func set_show_organs(on: bool) -> void:
	show_organs = on
	for mi in organ_meshes:
		mi.visible = on


func set_interact_mode(m: String) -> void:
	interact_mode = m
	if m != "drag":
		end_drag()


## 该模式是否已接入脏器互动（网页：拖拽 / 击腹）
func mode_is_live(m: String = "") -> bool:
	var k := interact_mode if m == "" else m
	return k == "drag" or k == "strike"


## 网页 fireStrike：在世界坐标点释放一次击腹冲击
func strike_at(world_p: Vector3, force: float = -1.0, rng: float = -1.0) -> void:
	_update_frame()
	var f := strike_force if force < 0.0 else force
	var r := strike_range if rng < 0.0 else rng
	_waves.append({
		"p": _frame.affine_inverse() * world_p,
		"t": 0.0,
		"force": clampf(f, 0.08, 1.0),
		"range": clampf(r, 0.05, 1.0),
		"rebound": strike_rebound,
	})
	if _waves.size() > 4:
		_waves.pop_front()
	_gut_exc = minf(0.35, _gut_exc + 0.08 + f * 0.14)


func begin_drag(world_p: Vector3) -> void:
	_update_frame()
	_drag_active = true
	_drag_grab = _frame.affine_inverse() * world_p
	_drag_target = _drag_grab
	_drag_off = Vector3.ZERO
	_drag_vel = Vector3.ZERO


func update_drag(world_target: Vector3) -> void:
	if not _drag_active:
		return
	_drag_target = _frame.affine_inverse() * world_target


func end_drag() -> void:
	_drag_active = false


func is_dragging() -> bool:
	return _drag_active


func drag_grab_world() -> Vector3:
	return _frame * _drag_grab


func drag_offset_length() -> float:
	return _drag_off.length()


func active_waves() -> int:
	return _waves.size()


## 网页 strike 波对一个 ab-local 点的位移（用于自检）
func debug_strike_displacement(local_p: Vector3) -> float:
	var q := local_p
	for w in _waves:
		var t: float = w["t"]
		var force: float = w["force"]
		var rng: float = w["range"]
		var reb: float = w["rebound"]
		var p0: Vector3 = w["p"]
		var rec := 1.05 + (1.0 - clampf(reb, 0.0, 1.0)) * 2.4
		var decay := 0.28 + reb * 0.85
		var dx := q.x - p0.x
		var dy := q.y - p0.y
		var r := sqrt(dx * dx + dy * dy)
		var span := 0.055 + rng * 0.13
		var ring_r := t * (0.18 + rng * 0.15)
		var width := 0.03 + rng * 0.024
		var life := maxf(0.0, 1.0 - t / rec)
		var fade := life * life * (3.0 - 2.0 * life)
		var rr := (r - ring_r) / width
		var ring := exp(-rr * rr)
		var hole := exp(-(r * r) / (span * span * 0.55)) * exp(-t * decay)
		var amp := force * fade
		var inv := 0.0 if r < 1e-4 else 1.0 / r
		var push := amp * (0.03 * ring + 0.026 * hole)
		var crush := amp * (0.062 * hole + 0.018 * ring)
		q.x += dx * inv * push
		q.y += dy * inv * push * 0.7
		q.z -= crush
	return (q - local_p).length()


func navel_world() -> Vector3:
	return _frame.origin


func abdomen_frame() -> Transform3D:
	return _frame


## 射线 vs 腹部椭球（ab-local），命中返回世界坐标点，否则返回 null
func ray_hit_belly(origin: Vector3, dir: Vector3) -> Variant:
	_update_frame()
	var inv := _frame.affine_inverse()
	var o := inv * origin - _ellipsoid_c
	var d := inv.basis * dir
	var on := o / _ellipsoid_r
	var dn := d / _ellipsoid_r
	var a := dn.dot(dn)
	var b := 2.0 * on.dot(dn)
	var c := on.dot(on) - 1.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0 or a < 1e-9:
		return null
	var sq := sqrt(disc)
	var t := (-b - sq) / (2.0 * a)
	if t < 0.0:
		t = (-b + sq) / (2.0 * a)
	if t < 0.0:
		return null
	return origin + dir * t


func debug_snapshot() -> Dictionary:
	return {
		"ready": ready_ok,
		"xray": effective_xray(),
		"xray_enabled": xray_enabled,
		"organs": organ_meshes.size(),
		"skin": skin_meshes.size(),
		"waves": _waves.size(),
		"drag_off": _drag_off.length(),
		"gut_exc": _gut_exc,
		"navel_w": _frame.origin,
	}


# ------------------------------------------------------------------ frame
func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if not ready_ok:
		return
	var dt := minf(delta, 0.05)
	_time += dt
	for w in _waves:
		w["t"] = float(w["t"]) + dt
	_waves = _waves.filter(func(w): return float(w["t"]) < STRIKE_LIFE)
	_gut_exc += (0.0 - _gut_exc) * (1.0 - exp(-0.42 * dt))
	_step_drag(dt)
	for mi in organ_meshes:
		mi.visible = show_organs
	_update_frame()
	_push_uniforms()
	_update_fx()


func _step_drag(dt: float) -> void:
	var target := Vector3.ZERO
	var k := 140.0
	var zeta := 0.32
	if _drag_active:
		target = _drag_target - _drag_grab
		if target.length() > 0.08:
			target = target.normalized() * 0.08
		k = 260.0
		zeta = 0.8
	var c := 2.0 * sqrt(k) * zeta
	# semi-implicit Euler, substeps for stability
	var n := 4
	var h := dt / float(n)
	for _i in n:
		var acc := (target - _drag_off) * k - _drag_vel * c
		_drag_vel += acc * h
		_drag_off += _drag_vel * h
	if not _drag_active and _drag_off.length() < 1e-5 and _drag_vel.length() < 1e-4:
		_drag_off = Vector3.ZERO
		_drag_vel = Vector3.ZERO


func _update_frame() -> void:
	if _skel == null or _spine_i < 0:
		return
	var m := _skel.global_transform * _skel.get_bone_global_pose(_spine_i) * _skel.get_bone_global_rest(_spine_i).affine_inverse()
	var o := m * _navel_rest
	var right := (m.basis * Vector3.RIGHT).normalized()
	var up := (m.basis * Vector3.UP).normalized()
	var fwd := right.cross(up).normalized()
	up = fwd.cross(right).normalized()
	_frame = Transform3D(Basis(right, up, fwd), o)


func _push_uniforms() -> void:
	var b := _frame.basis
	var sp: Array = []
	var spar: Array = []
	for i in 4:
		if i < _waves.size():
			var w: Dictionary = _waves[i]
			var p: Vector3 = w["p"]
			sp.append(Vector4(p.x, p.y, p.z, float(w["t"])))
			spar.append(Vector4(float(w["force"]), float(w["range"]), float(w["rebound"]), 0.0))
		else:
			sp.append(Vector4(0, 0, 0, -1))
			spar.append(Vector4(0, 0, 0, 0))
	var xr := effective_xray()
	var g := _gut_exc
	for m in _all_mats:
		m.set_shader_parameter("ab_navel", _frame.origin)
		m.set_shader_parameter("ab_right", b.x)
		m.set_shader_parameter("ab_up", b.y)
		m.set_shader_parameter("ab_fwd", b.z)
		m.set_shader_parameter("strike_pos", sp)
		m.set_shader_parameter("strike_par", spar)
		m.set_shader_parameter("drag_grab", _drag_grab)
		m.set_shader_parameter("drag_off", _drag_off)
	for m in _skin_mats:
		m.set_shader_parameter("xray", xr)
	for m in _organ_mats:
		m.set_shader_parameter("peri_time", _time)
		m.set_shader_parameter("peri_amp", clampf(gut_amp * (1.0 + g * 0.38), 0.0, 1.0))
		m.set_shader_parameter("peri_speed", clampf(gut_speed * (1.0 + g * 0.3), 0.0, 1.0))
		m.set_shader_parameter("peri_on", 1.0 if peristalsis_on else 0.0)
	if _light:
		_light.global_position = _frame.origin - b.z * 0.04
		_light.light_energy = (0.05 + xr * 0.06) * 8.0 if (show_organs and xr > 0.08) else 0.0


# ------------------------------------------------------------------ build
func _load_meta() -> Dictionary:
	var f := FileAccess.open(META_PATH, FileAccess.READ)
	if f == null:
		push_warning("organs: meta missing")
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


func _fit_hit_ellipsoid() -> void:
	if not meta.has("profile"):
		return
	var prof: Dictionary = meta["profile"]
	var ys: Array = prof["y"]
	var hx: Array = prof["half_x"]
	var zf: Array = prof["z_front"]
	var zb: Array = prof["z_back"]
	var y := _navel_rest.y
	var best := 0
	for i in ys.size():
		if absf(float(ys[i]) - y) < absf(float(ys[best]) - y):
			best = i
	var rx := maxf(0.1, float(hx[best]) * 0.95)
	var front := float(zf[best])
	var back := float(zb[best])
	_ellipsoid_r = Vector3(rx, 0.2, maxf(0.06, (front - back) * 0.5))
	_ellipsoid_c = Vector3(0.0, -0.03, (front + back) * 0.5 - _navel_rest.z)


func _is_torso_skin(mi: MeshInstance3D) -> bool:
	var low := mi.name.to_lower()
	if "hair" in low or "_007_" in mi.name or "_eye" in low or "mouth" in low or "head" in low or "charm" in low:
		return false
	return "dress" in low or "skin" in low


func _install_skin_xray() -> void:
	var xr: Dictionary = meta.get("xray", {})
	for n in _skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or not _is_torso_skin(mi) or mi.mesh == null:
			continue
		var src := mi.get_active_material(0) as BaseMaterial3D
		var base := ShaderMaterial.new()
		base.shader = SKIN_SHADER
		var fade := ShaderMaterial.new()
		fade.shader = SKIN_FADE_SHADER
		for m in [base, fade]:
			_copy_skin_params(src, m)
			m.set_shader_parameter("xray_y0", float(xr.get("y0", -0.2)))
			m.set_shader_parameter("xray_y1", float(xr.get("y1", 0.145)))
			m.set_shader_parameter("xray_xmax", float(xr.get("x_max", 0.12)))
			m.set_shader_parameter("xray_zfront", float(xr.get("z_front", -0.01)))
			_skin_mats.append(m)
			_all_mats.append(m)
		base.next_pass = fade
		mi.set_surface_override_material(0, base)
		skin_meshes.append(mi)


func _copy_skin_params(src: BaseMaterial3D, m: ShaderMaterial) -> void:
	if src == null:
		return
	m.set_shader_parameter("albedo_tex", src.albedo_texture)
	m.set_shader_parameter("albedo_color", src.albedo_color)
	m.set_shader_parameter("metallic", src.metallic)
	m.set_shader_parameter("roughness", src.roughness)
	m.set_shader_parameter("specular", src.metallic_specular)
	var orm: Texture2D = src.roughness_texture
	m.set_shader_parameter("has_orm", orm != null)
	if orm:
		m.set_shader_parameter("orm_tex", orm)
	m.set_shader_parameter("has_normal", src.normal_enabled and src.normal_texture != null)
	if src.normal_texture:
		m.set_shader_parameter("normal_tex", src.normal_texture)
	m.set_shader_parameter("normal_scale", src.normal_scale)


func _read_str(buf: PackedByteArray, off: int) -> Array:
	var n := buf.decode_u16(off)
	return [buf.slice(off + 2, off + 2 + n).get_string_from_utf8(), off + 2 + n]


func _build_organs() -> bool:
	var raw := FileAccess.get_file_as_bytes(PACK_PATH)
	if raw.is_empty():
		push_warning("organs: pack missing " + PACK_PATH)
		return false
	var buf := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if buf.size() < 16 or buf.slice(0, 4).get_string_from_ascii() != "ORGN":
		push_warning("organs: bad pack")
		return false
	var off := 8
	var nb := buf.decode_u32(off)
	off += 4
	var bone_names: Array[String] = []
	for _i in nb:
		var r := _read_str(buf, off)
		bone_names.append(r[0])
		off = r[1]
	# Skin binds copied (by name) from the body's skin so organs share the body's bind space.
	var body_skin: Skin = null
	if not skin_meshes.is_empty():
		body_skin = skin_meshes[0].skin
	var skin := Skin.new()
	for bn in bone_names:
		var pose := Transform3D.IDENTITY
		var found := false
		if body_skin:
			for bi in body_skin.get_bind_count():
				if String(body_skin.get_bind_name(bi)) == bn:
					pose = body_skin.get_bind_pose(bi)
					found = true
					break
		if not found:
			var idx := _skel.find_bone(bn)
			if idx >= 0:
				pose = _skel.get_bone_global_rest(idx).affine_inverse()
		skin.add_named_bind(bn, pose)
	var mesh_count := buf.decode_u32(off)
	off += 4
	var tex_cache := {}
	for _m in mesh_count:
		var r1 := _read_str(buf, off)
		var mname: String = r1[0]
		off = r1[1]
		var r2 := _read_str(buf, off)
		var matname: String = r2[0]
		off = r2[1]
		var group := buf.decode_u8(off)
		var tex_id := buf.decode_s8(off + 1)
		off += 2
		var col := Color(buf.decode_float(off), buf.decode_float(off + 4), buf.decode_float(off + 8), buf.decode_float(off + 12))
		off += 16
		var vc := buf.decode_u32(off)
		var ic := buf.decode_u32(off + 4)
		off += 8
		var pos_f := buf.slice(off, off + vc * 12).to_float32_array()
		off += vc * 12
		var nrm_f := buf.slice(off, off + vc * 12).to_float32_array()
		off += vc * 12
		var tan_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var uv_f := buf.slice(off, off + vc * 8).to_float32_array()
		off += vc * 8
		var bone_b := buf.slice(off, off + vc * 4)
		off += vc * 4
		var wt_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var cust_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var idx_i := buf.slice(off, off + ic * 4).to_int32_array()
		off += ic * 4

		var verts := PackedVector3Array()
		verts.resize(vc)
		var nrms := PackedVector3Array()
		nrms.resize(vc)
		var uvs := PackedVector2Array()
		uvs.resize(vc)
		var bones := PackedInt32Array()
		bones.resize(vc * 4)
		for i in vc:
			var j := i * 3
			verts[i] = Vector3(pos_f[j], pos_f[j + 1], pos_f[j + 2])
			nrms[i] = Vector3(nrm_f[j], nrm_f[j + 1], nrm_f[j + 2])
			uvs[i] = Vector2(uv_f[i * 2], uv_f[i * 2 + 1])
		for i in vc * 4:
			bones[i] = bone_b[i]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = nrms
		arrays[Mesh.ARRAY_TANGENT] = tan_f
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = wt_f
		arrays[Mesh.ARRAY_CUSTOM0] = cust_f
		arrays[Mesh.ARRAY_INDEX] = idx_i
		var am := ArrayMesh.new()
		var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)

		var mat := ShaderMaterial.new()
		mat.shader = ORGAN_SHADER
		var is_gut := group == 0
		mat.set_shader_parameter("is_gut", is_gut)
		if tex_id >= 0 and TEX.has(tex_id):
			if not tex_cache.has(tex_id):
				tex_cache[tex_id] = [load(TEX[tex_id][0]), load(TEX[tex_id][1])]
			mat.set_shader_parameter("use_tex", true)
			mat.set_shader_parameter("albedo_tex", tex_cache[tex_id][0])
			mat.set_shader_parameter("normal_tex", tex_cache[tex_id][1])
			mat.set_shader_parameter("base_color", Color(1, 1, 1, 1))
			mat.set_shader_parameter("roughness", 0.48)
		else:
			# 网页 polishOrgans：无贴图时颜色向 #c4786a 靠 12%
			var c := Color(col.r, col.g, col.b, 1.0).lerp(Color("#c4786a"), 0.12)
			mat.set_shader_parameter("use_tex", false)
			mat.set_shader_parameter("base_color", c)
			mat.set_shader_parameter("roughness", 0.42)
		mat.set_shader_parameter("strike_k", 1.0 if is_gut else 0.4)
		_organ_mats.append(mat)
		_all_mats.append(mat)

		var mi := MeshInstance3D.new()
		mi.name = ("Gut_" if is_gut else "Pelvis_") + mname.validate_node_name().replace(" ", "_")
		mi.mesh = am
		mi.material_override = mat
		mi.skin = skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 1 | ORGAN_LIGHT_LAYER
		mi.extra_cull_margin = 0.2
		mi.set_meta("organ_group", "gut" if is_gut else "pelvis")
		mi.set_meta("organ_material", matname)
		_skel.add_child(mi)
		mi.skeleton = mi.get_path_to(_skel)
		organ_meshes.append(mi)
	return organ_meshes.size() > 0


func _build_fx() -> void:
	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = RING_SHADER
	_ring_mat.set_shader_parameter("color", Color("#f2efe9"))
	_ring_mat.set_shader_parameter("inner", 0.92)
	_ring = _make_quad(_ring_mat, "StrikeRing")
	_poke_mat = ShaderMaterial.new()
	_poke_mat.shader = RING_SHADER
	_poke_mat.set_shader_parameter("color", Color(0.83, 0.71, 0.63, 0.8))
	_poke_mat.set_shader_parameter("inner", 0.66)
	_poke = _make_quad(_poke_mat, "PokeMarker")
	_light = OmniLight3D.new()
	_light.name = "BellyLight"
	_light.light_color = Color("#a07060")
	_light.omni_range = 0.48
	_light.light_energy = 0.0
	_light.light_cull_mask = ORGAN_LIGHT_LAYER
	_light.shadow_enabled = false
	_skel.add_child(_light)


func _make_quad(mat: ShaderMaterial, nm: String) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = q
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	mi.top_level = true
	_skel.add_child(mi)
	return mi


func _update_fx() -> void:
	var b := _frame.basis
	if _waves.is_empty():
		_ring.visible = false
	else:
		var w: Dictionary = _waves[_waves.size() - 1]
		var t: float = w["t"]
		var rr := maxf(0.02, t * (0.2 + float(w["range"]) * 0.16))
		var op := maxf(0.0, 1.0 - t / 1.2) * 0.85 * float(w["force"])
		var p: Vector3 = w["p"]
		var wp := _frame * (p + Vector3(0, 0, 0.012))
		_ring.global_transform = Transform3D(b.scaled(Vector3(rr, rr, 1.0)), wp)
		var c := Color("#f2efe9")
		c.a = op
		_ring_mat.set_shader_parameter("color", c)
		_ring.visible = op > 0.02
	if _drag_active:
		var tp := _frame * (_drag_grab + _drag_off + Vector3(0, 0, 0.01))
		_poke.global_transform = Transform3D(b.scaled(Vector3(0.036, 0.036, 1.0)), tp)
		_poke.visible = true
	else:
		_poke.visible = false
