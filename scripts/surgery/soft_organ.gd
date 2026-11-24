extends MeshInstance3D
## 0.4.11：子宫 / 膀胱的五档柔体脱出。
## - 原网格隐藏，用笼（约 48 个质点）驱动一份视觉网格。
## - 档位随拉扯强度缓慢上升（1 = 刚露出一点，5 = 几乎整体脱出，仅锚端仍在体内）。
## - 露出体外的部分按 Verlet 积分，可被手术钳夹住，并带惯性。
## - 子宫：阴道宫颈端由 SurgerySystem 跟到 cervix_world()；
##   输卵管 / 卵巢在 4 档以下绑在柔体上，≥4 档或被提前夹住则变成短骨骼悬链。

const RINGS := 6
const SIDES := 8
const ITER := 4
const DAMP := 0.86
const GRAVITY := Vector3(0, -9.8, 0)
const CHARGE_RATE := 0.32          # 满强度每秒约 0.32 档，从 1 到 5 约 12.5 秒
const PUTBACK_RATE := 0.85
const TUBE_LEVEL := 4
const PEEK_OUT := 0.018
const LEVELS := 5
const PIN_IN := 0.82
const PIN_OUT := 0.10
const SPRING_K := 0.45
const MAX_SPEED := 1.4

const GutRope := preload("res://scripts/surgery/gut_rope.gd")

var kind: String = "uterus"        # uterus | bladder
var extract_charge: float = 0.0    # 0 或 1..5
var retracting: bool = false
var organ_active: bool = false
var gravity: Vector3 = GRAVITY
var floor_y: float = -1e9
var capsules: Array = []
var skin_p: PackedVector3Array = PackedVector3Array()
var skin_n: PackedVector3Array = PackedVector3Array()
var wound_center: Vector3 = Vector3.ZERO
var outward: Vector3 = Vector3.UP
var hold_index: int = -1
var hold_pos: Vector3 = Vector3.ZERO

var _rest_ab: PackedVector3Array = PackedVector3Array()
var _p: PackedVector3Array = PackedVector3Array()
var _q: PackedVector3Array = PackedVector3Array()
var _springs: Array = []           # [i, j, rest]
var _cervix_ids: PackedInt32Array = PackedInt32Array()
var _fundus_ids: PackedInt32Array = PackedInt32Array()
var _axis_ab: Vector3 = Vector3.UP
var _cervix_ab: Vector3 = Vector3.ZERO
var _fundus_ab: Vector3 = Vector3.ZERO
var _horn_ab: Array = [Vector3.ZERO, Vector3.ZERO]
var _rest_len: float = 0.05
var _frame: Transform3D = Transform3D.IDENTITY
var _inited := false

var _vis_rest: PackedVector3Array = PackedVector3Array()
var _vis_nrm: PackedVector3Array = PackedVector3Array()
var _vis_uv: PackedVector2Array = PackedVector2Array()
var _vis_idx: PackedInt32Array = PackedInt32Array()
var _bind_i: PackedInt32Array = PackedInt32Array()   # 3 per vert
var _bind_w: PackedVector3Array = PackedVector3Array()
var _am: ArrayMesh

var _src: Array = []               # original MeshInstance3Ds to hide
var _adnex_src: Array = []         # tubes + ovaries originals
var _adnex_vis: Array = []         # bound visual MeshInstance3D {node, side, rest, nrm, uv, idx, bind_i, bind_w}
var _chains: Dictionary = {}       # side -> {rope, ovary_mi, active}
var _early: Dictionary = {}        # side -> true if early-grabbed
var _mat: ShaderMaterial = null
var _tube_mat: ShaderMaterial = null


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am


func level() -> int:
	if extract_charge <= 0.0:
		return 0
	return clampi(int(floor(extract_charge + 1e-4)), 1, LEVELS)


func charge() -> float:
	return extract_charge


func is_extracted() -> bool:
	return organ_active and extract_charge > 0.0


func original_hidden() -> bool:
	if _src.is_empty():
		return not visible
	for mi in _src:
		if mi != null and is_instance_valid(mi) and (mi as MeshInstance3D).visible:
			return false
	return true


func cervix_world() -> Vector3:
	if _p.is_empty() or _cervix_ids.is_empty():
		return _frame * _cervix_ab
	var s := Vector3.ZERO
	for i in _cervix_ids:
		s += _p[i]
	return s / float(_cervix_ids.size())


func fundus_world() -> Vector3:
	if _p.is_empty() or _fundus_ids.is_empty():
		return _frame * _fundus_ab
	var s := Vector3.ZERO
	for i in _fundus_ids:
		s += _p[i]
	return s / float(_fundus_ids.size())


func horn_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	if _p.is_empty() or _rest_ab.is_empty():
		return _frame * (_horn_ab[side] as Vector3)
	# 最近笼点
	var tgt: Vector3 = _frame * (_horn_ab[side] as Vector3)
	# 用当前笼相对 rest 的位移：找 rest 上最近的点
	var bi := 0
	var bd := 1e9
	var h_ab: Vector3 = _horn_ab[side]
	for i in _rest_ab.size():
		var d := _rest_ab[i].distance_squared_to(h_ab)
		if d < bd:
			bd = d
			bi = i
	return _p[bi] + (_frame.basis * (h_ab - _rest_ab[bi]))


func tube_chain_active(side: int) -> bool:
	var ch: Variant = _chains.get(side, null)
	return ch is Dictionary and bool((ch as Dictionary).get("active", false))


func any_tube_chain() -> bool:
	return tube_chain_active(0) or tube_chain_active(1)


func setup(p_kind: String, frame: Transform3D, navel: Vector3, main_meshes: Array, adnex_meshes: Array, cervix_rest: Vector3, fundus_rest: Vector3, horns: Array) -> void:
	kind = p_kind
	_frame = frame
	_src = main_meshes.duplicate()
	_adnex_src = adnex_meshes.duplicate()
	_cervix_ab = cervix_rest - navel
	_fundus_ab = fundus_rest - navel
	_axis_ab = _fundus_ab - _cervix_ab
	_rest_len = maxf(_axis_ab.length(), 0.03)
	if _axis_ab.length_squared() < 1e-8:
		_axis_ab = Vector3(0, 1, 0)
	else:
		_axis_ab = _axis_ab.normalized()
	_horn_ab = [Vector3.ZERO, Vector3.ZERO]
	for i in mini(2, horns.size()):
		_horn_ab[i] = (horns[i] as Vector3) - navel
	# 收集视觉网格（主器官，通常就一块）
	_vis_rest = PackedVector3Array()
	_vis_nrm = PackedVector3Array()
	_vis_uv = PackedVector2Array()
	_vis_idx = PackedInt32Array()
	for mi in main_meshes:
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		if _mat == null and m.material_override is ShaderMaterial:
			_mat = (m.material_override as ShaderMaterial).duplicate() as ShaderMaterial
			_mat.set_shader_parameter("is_uterus", false)
			_mat.set_shader_parameter("is_gut", false)
		_append_surface(m.mesh, navel, _vis_rest, _vis_nrm, _vis_uv, _vis_idx)
	if _mat:
		material_override = _mat
		_mat.set_meta("soft_organ", kind)
	_build_cage()
	_bind_visual(_vis_rest, _bind_i, _bind_w)
	_prepare_adnex(navel)
	_inited = true
	visible = false


func _append_surface(msh: Mesh, navel: Vector3, rest: PackedVector3Array, nrm: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array) -> void:
	var arr: Array = msh.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var U: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var base := rest.size()
	for i in P.size():
		rest.append(P[i] - navel)
		if i < N.size():
			nrm.append(N[i])
		else:
			nrm.append(Vector3.UP)
		if i < U.size():
			uv.append(U[i])
		else:
			uv.append(Vector2.ZERO)
	if I.is_empty():
		for i in P.size():
			idx.append(base + i)
	else:
		for i in I.size():
			idx.append(base + I[i])


func _build_cage() -> void:
	_rest_ab.resize(RINGS * SIDES)
	_cervix_ids = PackedInt32Array()
	_fundus_ids = PackedInt32Array()
	# 用视觉顶点按轴分箱，估每环中心与半径。
	var bins: Array = []
	for r in RINGS:
		bins.append({"c": Vector3.ZERO, "n": 0, "rad": 0.0, "pts": []})
	if _vis_rest.is_empty():
		for r in RINGS:
			var t := float(r) / float(RINGS - 1)
			var c := _cervix_ab.lerp(_fundus_ab, t)
			var rad := 0.012 + 0.018 * sin(t * PI)
			for s in SIDES:
				var ang := TAU * float(s) / float(SIDES)
				var i := r * SIDES + s
				_rest_ab[i] = c + _radial(ang) * rad
		_fill_rings()
		_build_springs()
		return
	for p in _vis_rest:
		var t := clampf((p - _cervix_ab).dot(_axis_ab) / _rest_len, 0.0, 0.9999)
		var r := clampi(int(t * RINGS), 0, RINGS - 1)
		var b: Dictionary = bins[r]
		b["c"] = (b["c"] as Vector3) + p
		b["n"] = int(b["n"]) + 1
		(b["pts"] as Array).append(p)
	for r in RINGS:
		var b: Dictionary = bins[r]
		var n: int = maxi(int(b["n"]), 1)
		var c: Vector3 = (b["c"] as Vector3) / float(n) if int(b["n"]) > 0 else _cervix_ab.lerp(_fundus_ab, float(r) / float(RINGS - 1))
		# 落到轴上再加平均半径
		var mid := _cervix_ab + _axis_ab * clampf((c - _cervix_ab).dot(_axis_ab), 0.0, _rest_len)
		var rad := 0.008
		var acc := 0.0
		var cnt := 0
		for p2 in (b["pts"] as Array):
			var off: Vector3 = (p2 as Vector3) - mid
			off -= _axis_ab * off.dot(_axis_ab)
			acc += off.length()
			cnt += 1
		if cnt > 0:
			rad = maxf(acc / float(cnt), 0.006)
		b["c"] = mid
		b["rad"] = rad
		for s in SIDES:
			var ang := TAU * float(s) / float(SIDES)
			var i := r * SIDES + s
			_rest_ab[i] = mid + _radial(ang) * rad
	_fill_rings()
	_build_springs()


func _radial(ang: float) -> Vector3:
	var up := Vector3.RIGHT.cross(_axis_ab)
	if up.length_squared() < 1e-8:
		up = Vector3.FORWARD.cross(_axis_ab)
	up = up.normalized()
	var rt := _axis_ab.cross(up).normalized()
	return up * cos(ang) + rt * sin(ang)


func _fill_rings() -> void:
	_cervix_ids.clear()
	_fundus_ids.clear()
	for s in SIDES:
		_cervix_ids.append(s)
		_fundus_ids.append((RINGS - 1) * SIDES + s)


func _build_springs() -> void:
	_springs.clear()
	for r in RINGS:
		for s in SIDES:
			var i := r * SIDES + s
			var j := r * SIDES + ((s + 1) % SIDES)
			_springs.append([i, j, _rest_ab[i].distance_to(_rest_ab[j])])
			if r + 1 < RINGS:
				var k := (r + 1) * SIDES + s
				_springs.append([i, k, _rest_ab[i].distance_to(_rest_ab[k])])
				var k2 := (r + 1) * SIDES + ((s + 1) % SIDES)
				_springs.append([i, k2, _rest_ab[i].distance_to(_rest_ab[k2])])


func _bind_visual(rest: PackedVector3Array, bind_i: PackedInt32Array, bind_w: PackedVector3Array) -> void:
	bind_i.resize(rest.size() * 3)
	bind_w.resize(rest.size())
	for vi in rest.size():
		var p: Vector3 = rest[vi]
		var d0 := 1e9
		var d1 := 1e9
		var d2 := 1e9
		var i0 := 0
		var i1 := 0
		var i2 := 0
		for ci in _rest_ab.size():
			var d := p.distance_squared_to(_rest_ab[ci])
			if d < d0:
				d2 = d1
				i2 = i1
				d1 = d0
				i1 = i0
				d0 = d
				i0 = ci
			elif d < d1:
				d2 = d1
				i2 = i1
				d1 = d
				i1 = ci
			elif d < d2:
				d2 = d
				i2 = ci
		var w0 := 1.0 / maxf(d0, 1e-8)
		var w1 := 1.0 / maxf(d1, 1e-8)
		var w2 := 1.0 / maxf(d2, 1e-8)
		var s := w0 + w1 + w2
		bind_i[vi * 3] = i0
		bind_i[vi * 3 + 1] = i1
		bind_i[vi * 3 + 2] = i2
		bind_w[vi] = Vector3(w0 / s, w1 / s, w2 / s)


func _prepare_adnex(navel: Vector3) -> void:
	_adnex_vis.clear()
	_chains = {0: {"active": false, "rope": null, "ovary": null}, 1: {"active": false, "rope": null, "ovary": null}}
	_early = {0: false, 1: false}
	for mi in _adnex_src:
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var vis := MeshInstance3D.new()
		vis.top_level = true
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.visible = false
		vis.name = "Bound_" + m.name
		var mat: ShaderMaterial = null
		if m.material_override is ShaderMaterial:
			mat = (m.material_override as ShaderMaterial).duplicate() as ShaderMaterial
			mat.set_shader_parameter("is_uterus", false)
			if _tube_mat == null:
				_tube_mat = mat
		vis.material_override = mat
		var rest := PackedVector3Array()
		var nrm := PackedVector3Array()
		var uv := PackedVector2Array()
		var idx := PackedInt32Array()
		_append_surface(m.mesh, navel, rest, nrm, uv, idx)
		var bi := PackedInt32Array()
		var bw := PackedVector3Array()
		_bind_visual(rest, bi, bw)
		add_child(vis)
		_adnex_vis.append({
			"node": vis,
			"side": int(m.get_meta("organ_side", 0)),
			"kind": str(m.get_meta("organ_kind", "")),
			"rest": rest,
			"nrm": nrm,
			"uv": uv,
			"idx": idx,
			"bind_i": bi,
			"bind_w": bw,
			"am": ArrayMesh.new(),
		})
		vis.mesh = (_adnex_vis[_adnex_vis.size() - 1] as Dictionary)["am"]


func add_hide_meshes(meshes: Array) -> void:
	for m in meshes:
		if m != null and m not in _src:
			_src.append(m)


func begin_extract(frame: Transform3D, wound: Vector3, out_dir: Vector3) -> void:
	_frame = frame
	wound_center = wound
	outward = out_dir.normalized()
	if outward.length_squared() < 1e-8:
		outward = Vector3.UP
	if not organ_active:
		_hide_sources(true)
		_init_particles()
		extract_charge = 1.0
		retracting = false
		organ_active = true
		visible = true
		_set_adnex_bound_visible(true)
		_rebuild_visual()


func _hide_sources(hide: bool) -> void:
	for mi in _src:
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).visible = not hide
	for mi2 in _adnex_src:
		if mi2 != null and is_instance_valid(mi2):
			(mi2 as MeshInstance3D).visible = not hide


func _init_particles() -> void:
	var n := _rest_ab.size()
	_p.resize(n)
	_q.resize(n)
	var xf := _kinematic_xf(1.0)
	for i in n:
		var pw: Vector3 = xf * _rest_ab[i]
		_p[i] = pw
		_q[i] = pw


func add_charge(strength: float, dt: float) -> void:
	if not organ_active or retracting:
		return
	var s := clampf(strength, 0.0, 1.5)
	extract_charge = clampf(extract_charge + s * CHARGE_RATE * dt, 1.0, float(LEVELS))
	_maybe_auto_chain()


func start_putback() -> void:
	if not organ_active:
		return
	retracting = true
	hold_index = -1


func force_reset() -> void:
	extract_charge = 0.0
	retracting = false
	organ_active = false
	hold_index = -1
	visible = false
	_hide_sources(false)
	_clear_chains()
	_set_adnex_bound_visible(false)
	_early = {0: false, 1: false}
	_p = PackedVector3Array()
	_q = PackedVector3Array()


func _set_adnex_bound_visible(on: bool) -> void:
	for rec in _adnex_vis:
		var d: Dictionary = rec
		var side := int(d["side"])
		var vis: MeshInstance3D = d["node"]
		vis.visible = on and organ_active and not tube_chain_active(side)


func detach_adnexa(side: int) -> bool:
	if kind != "uterus" or not organ_active:
		return false
	side = clampi(side, 0, 1)
	if tube_chain_active(side):
		return true
	_early[side] = true
	_spawn_chain(side)
	_set_adnex_bound_visible(true)
	return true


func rebind_adnexa() -> void:
	_clear_chains()
	_early = {0: false, 1: false}
	_set_adnex_bound_visible(organ_active)


func _maybe_auto_chain() -> void:
	if kind != "uterus" or not organ_active:
		return
	if extract_charge + 1e-4 < float(TUBE_LEVEL):
		return
	for side in [0, 1]:
		if not tube_chain_active(side):
			_spawn_chain(side)
	_set_adnex_bound_visible(true)


func _spawn_chain(side: int) -> void:
	if tube_chain_active(side):
		return
	var rope := GutRope.new()
	rope.name = "AdnexaChain%d" % side
	rope.apply_profile({
		"profile": "adnexa",
		"radius": 0.0036,
		"seg": 0.016,
		"damp": 0.90,
		"min_pts": 5,
		"max_pts": 8,
		"k_in": 1,
		"mes_every": 8,
	})
	rope.max_len = 0.11
	rope.fed_len = 0.09
	if _tube_mat:
		rope.use_organ_material(_tube_mat)
	add_child(rope)
	var horn := horn_world(side)
	var out := (_p[_fundus_ids[0]] - horn).normalized() if not _fundus_ids.is_empty() and not _p.is_empty() else outward
	if out.length_squared() < 1e-8:
		out = outward
	rope.anchor_a = horn
	rope.anchor_b = horn
	rope.exit_a = horn + out * 0.008
	rope.exit_b = horn + out * 0.008
	rope.mes_root = horn
	rope.call("step", 1.0 / 60.0)
	# 卵巢小球挂在链末端
	var ov := MeshInstance3D.new()
	ov.name = "OvaryBlob%d" % side
	ov.top_level = true
	ov.mesh = _ovary_mesh()
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.82, 0.42, 0.48)
	sm.roughness = 0.45
	ov.material_override = sm
	add_child(ov)
	_chains[side] = {"active": true, "rope": rope, "ovary": ov}
	_place_chain(side, 0.0)


func _ovary_mesh() -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = 0.008
	s.height = 0.016
	s.radial_segments = 10
	s.rings = 6
	return s


func _clear_chains() -> void:
	for side in [0, 1]:
		var ch: Dictionary = _chains.get(side, {})
		if ch.is_empty():
			continue
		var rope = ch.get("rope")
		var ov = ch.get("ovary")
		if rope != null and is_instance_valid(rope):
			rope.queue_free()
		if ov != null and is_instance_valid(ov):
			ov.queue_free()
		_chains[side] = {"active": false, "rope": null, "ovary": null}


func _place_chain(side: int, dt: float) -> void:
	var ch: Dictionary = _chains.get(side, {})
	if not bool(ch.get("active", false)):
		return
	var rope: Node = ch.get("rope")
	if rope == null or not is_instance_valid(rope):
		return
	var horn := horn_world(side)
	rope.set("anchor_a", horn)
	rope.set("anchor_b", horn)
	var out := outward
	if not _p.is_empty() and not _fundus_ids.is_empty():
		out = (fundus_world() - horn)
		if out.length_squared() < 1e-8:
			out = outward
		else:
			out = out.normalized()
	rope.set("exit_a", horn + out * 0.006)
	rope.set("exit_b", horn + out * 0.006)
	rope.set("mes_root", horn)
	rope.set("gravity", gravity)
	rope.set("floor_y", floor_y)
	rope.set("capsules", capsules)
	rope.set("skin_p", skin_p)
	rope.set("skin_n", skin_n)
	if dt > 0.0:
		rope.call("step", dt)
	var ov: MeshInstance3D = ch.get("ovary")
	if ov != null and is_instance_valid(ov):
		var pts: PackedVector3Array = rope.call("points")
		if pts.size() > 0:
			ov.global_position = pts[pts.size() - 2] if pts.size() > 2 else pts[pts.size() - 1]


func _kinematic_xf(charge_v: float) -> Transform3D:
	# 1 档：宫底刚出创口 PEEK_OUT，刚体形状保持。
	# 5 档：宫颈在创口，长轴沿 outward，整体露出。
	var cervix_w: Vector3 = _frame * _cervix_ab
	var fundus_w: Vector3 = _frame * _fundus_ab
	var axis_rest := fundus_w - cervix_w
	if axis_rest.length_squared() < 1e-8:
		axis_rest = _frame.basis * _axis_ab
	var rest_len := maxf(axis_rest.length(), _rest_len)
	axis_rest = axis_rest.normalized()
	var wound_out := wound_center + outward * PEEK_OUT
	# L1：平移使宫底到创口外一点点
	var fund_l1 := wound_out
	var cerv_l1 := fund_l1 - axis_rest * rest_len
	# L5：宫颈在创口内侧，宫底沿 outward 伸出
	var cerv_l5 := wound_center - outward * 0.006
	var fund_l5 := cerv_l5 + outward * rest_len
	var u := 0.0
	if charge_v <= 1.0:
		u = 0.0
	else:
		u = clampf((charge_v - 1.0) / 4.0, 0.0, 1.0)
	if charge_v <= 0.0:
		# 尚未脱出：就是静止姿态
		return Transform3D(_frame.basis, _frame.origin)
	var c_tgt := cerv_l1.lerp(cerv_l5, u)
	var f_tgt := fund_l1.lerp(fund_l5, u)
	var axis_now := f_tgt - c_tgt
	if axis_now.length_squared() < 1e-8:
		axis_now = outward
	else:
		axis_now = axis_now.normalized()
	var R := _align_basis(axis_rest, axis_now) * _frame.basis
	return Transform3D(R, c_tgt - R * _cervix_ab)


func _align_basis(from_a: Vector3, to_a: Vector3) -> Basis:
	var a := from_a.normalized()
	var b := to_a.normalized()
	var c := a.cross(b)
	var cl := c.length()
	if cl < 1e-6:
		if a.dot(b) > 0.0:
			return Basis.IDENTITY
		# 180°
		var ortho := Vector3.RIGHT if absf(a.x) < 0.9 else Vector3.UP
		ortho = ortho.cross(a).normalized()
		return Basis(ortho, deg_to_rad(180.0))
	var axis := c / cl
	var ang := atan2(cl, a.dot(b))
	return Basis(axis, ang)


func ray_pick(origin: Vector3, dir: Vector3) -> Array:
	if not organ_active or _p.is_empty():
		return [-1, 1e9]
	var d := dir.normalized()
	var best := 1e9
	var bi := -1
	for i in _p.size():
		# 只夹露出创口平面的部分（体内钉住的环不易抓）
		if (_p[i] - wound_center).dot(outward) < -0.004:
			continue
		var w := _p[i] - origin
		var t := w.dot(d)
		if t <= 0.0:
			continue
		var dist := (w - d * t).length()
		if dist < best:
			best = dist
			bi = i
	return [bi, best]


func ray_pick_adnexa(origin: Vector3, dir: Vector3) -> int:
	## 返回被点到的一侧（0/1），否则 -1。
	if kind != "uterus" or not organ_active:
		return -1
	var d := dir.normalized()
	var best := 0.016
	var bs := -1
	for side in [0, 1]:
		if tube_chain_active(side):
			var ch: Dictionary = _chains[side]
			var rope: Node = ch.get("rope")
			if rope != null and is_instance_valid(rope):
				var pk: Array = rope.call("ray_pick", origin, dir)
				if int(pk[0]) >= 0 and float(pk[1]) < best:
					best = float(pk[1])
					bs = side
			var ov: MeshInstance3D = ch.get("ovary")
			if ov != null and is_instance_valid(ov):
				var w: Vector3 = ov.global_position - origin
				var t := w.dot(d)
				if t > 0.0:
					var dist := (w - d * t).length()
					if dist < best and dist < 0.014:
						best = dist
						bs = side
		else:
			# 绑在柔体上的输卵管 / 卵巢视觉网格：用包围球
			for rec in _adnex_vis:
				var dd: Dictionary = rec
				if int(dd["side"]) != side:
					continue
				var vis: MeshInstance3D = dd["node"]
				if vis == null or not vis.visible or vis.mesh == null:
					continue
				var aabb: AABB = vis.mesh.get_aabb()
				var c: Vector3 = vis.global_transform * aabb.get_center()
				var r: float = aabb.size.length() * 0.5 + 0.006
				var w2 := c - origin
				var t2 := w2.dot(d)
				if t2 <= 0.0:
					continue
				var dist2 := (w2 - d * t2).length()
				if dist2 < r and dist2 < best:
					best = dist2
					bs = side
	return bs


func hold_particle(i: int, tip: Vector3) -> void:
	hold_index = i
	hold_pos = tip


func release_hold() -> void:
	hold_index = -1


func chain_ropes() -> Array:
	var out: Array = []
	for side in [0, 1]:
		if tube_chain_active(side):
			out.append((_chains[side] as Dictionary)["rope"])
	return out


func chain_hold(side: int, origin: Vector3, dir: Vector3) -> bool:
	if not tube_chain_active(side):
		return false
	var rope: Node = (_chains[side] as Dictionary)["rope"]
	if rope == null or not is_instance_valid(rope):
		return false
	var pk: Array = rope.call("ray_pick", origin, dir)
	var idx := int(pk[0])
	if idx < 0:
		# 夹卵巢小球：用末端点
		var pts: PackedVector3Array = rope.call("points")
		if pts.is_empty():
			return false
		idx = pts.size() - 2 if pts.size() > 2 else pts.size() - 1
		rope.set("hold_index", idx)
		rope.set("hold_pos", pts[idx])
		return true
	var pts2: PackedVector3Array = rope.call("points")
	rope.set("hold_index", idx)
	rope.set("hold_pos", pts2[idx])
	return true


func chain_drag(side: int, tip: Vector3) -> void:
	if not tube_chain_active(side):
		return
	var rope: Node = (_chains[side] as Dictionary)["rope"]
	if rope and is_instance_valid(rope) and int(rope.get("hold_index")) >= 0:
		rope.set("hold_pos", tip)


func chain_release(side: int) -> void:
	if not tube_chain_active(side):
		return
	var rope: Node = (_chains[side] as Dictionary)["rope"]
	if rope and is_instance_valid(rope):
		rope.set("hold_index", -1)


func carry(xf: Transform3D) -> void:
	for i in _p.size():
		_p[i] = xf * _p[i]
	for i in _q.size():
		_q[i] = xf * _q[i]
	if hold_index >= 0:
		hold_pos = xf * hold_pos
	wound_center = xf * wound_center
	outward = (xf.basis * outward).normalized()
	for side in [0, 1]:
		if tube_chain_active(side):
			var rope: Node = (_chains[side] as Dictionary)["rope"]
			if rope and is_instance_valid(rope) and rope.has_method("carry"):
				rope.call("carry", xf)


func step(dt: float, frame: Transform3D, wound: Vector3, out_dir: Vector3) -> void:
	if not organ_active:
		return
	dt = minf(maxf(dt, 0.0), 1.0 / 30.0)
	_frame = frame
	wound_center = wound
	if out_dir.length_squared() > 1e-8:
		outward = out_dir.normalized()
	if retracting:
		hold_index = -1
		extract_charge = maxf(0.0, extract_charge - PUTBACK_RATE * dt)
		if extract_charge < float(TUBE_LEVEL):
			# 放回时输卵管回到绑定
			if any_tube_chain():
				_clear_chains()
				_early = {0: false, 1: false}
				_set_adnex_bound_visible(true)
		if extract_charge <= 0.12:
			force_reset()
			return
	if _p.size() != _rest_ab.size():
		_init_particles()
	_maybe_auto_chain()
	var xf := _kinematic_xf(extract_charge)
	var n := _p.size()
	# Verlet
	for i in n:
		if i == hold_index:
			_q[i] = _p[i]
			_p[i] = hold_pos
			continue
		var cur := _p[i]
		var v := (cur - _q[i]) * DAMP
		var sp := v.length()
		if sp > MAX_SPEED * dt:
			v = v * ((MAX_SPEED * dt) / maxf(sp, 1e-8))
		var tgt: Vector3 = xf * _rest_ab[i]
		var outside := (cur - wound_center).dot(outward) > -0.004
		if outside:
			v += gravity * dt * dt
		_q[i] = cur
		_p[i] = cur + v
		# 钉向运动学目标：体内钉得死，体外留柔性和惯性
		var pin := PIN_OUT if outside else PIN_IN
		# 宫颈环始终更强地钉住，保证阴道连接点稳定
		if i < SIDES:
			pin = maxf(pin, 0.72)
		_p[i] = _p[i].lerp(tgt, pin)
		if _p[i].y < floor_y + 0.008:
			_p[i].y = floor_y + 0.008
	# 弹簧
	for _it in ITER:
		for sp2 in _springs:
			var i: int = sp2[0]
			var j: int = sp2[1]
			var rest: float = sp2[2]
			var d := _p[j] - _p[i]
			var L := d.length()
			if L < 1e-8:
				continue
			var corr := (L - rest) / L * SPRING_K
			var locked_i := i == hold_index or i < SIDES
			var locked_j := j == hold_index or j < SIDES
			if locked_i and locked_j:
				continue
			if locked_i:
				_p[j] -= d * corr
			elif locked_j:
				_p[i] += d * corr
			else:
				_p[i] += d * corr * 0.5
				_p[j] -= d * corr * 0.5
		if hold_index >= 0 and hold_index < n:
			_p[hold_index] = hold_pos
	for side in [0, 1]:
		_place_chain(side, dt)
	_rebuild_visual()
	_rebuild_adnex()


func _skin_deform(rest: PackedVector3Array, bind_i: PackedInt32Array, bind_w: PackedVector3Array, nrm: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(rest.size())
	for vi in rest.size():
		var i0 := bind_i[vi * 3]
		var i1 := bind_i[vi * 3 + 1]
		var i2 := bind_i[vi * 3 + 2]
		var w: Vector3 = bind_w[vi]
		var r0: Vector3 = _frame * _rest_ab[i0]
		var r1: Vector3 = _frame * _rest_ab[i1]
		var r2: Vector3 = _frame * _rest_ab[i2]
		var delta := (_p[i0] - r0) * w.x + (_p[i1] - r1) * w.y + (_p[i2] - r2) * w.z
		out[vi] = (_frame * rest[vi]) + delta
	return out


func _rebuild_mesh(am: ArrayMesh, verts: PackedVector3Array, nrm_rest: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array) -> void:
	# 粗略法线：用相邻笼位移，不每帧重算精确切线（移动端）
	var nrm := PackedVector3Array()
	nrm.resize(verts.size())
	for i in verts.size():
		nrm[i] = nrm_rest[i] if i < nrm_rest.size() else Vector3.UP
	# 累积面法线
	if idx.size() >= 3:
		for i in verts.size():
			nrm[i] = Vector3.ZERO
		for f in range(0, idx.size() - 2, 3):
			var a := verts[idx[f]]
			var b := verts[idx[f + 1]]
			var c := verts[idx[f + 2]]
			var fn := (b - a).cross(c - a)
			nrm[idx[f]] += fn
			nrm[idx[f + 1]] += fn
			nrm[idx[f + 2]] += fn
		for i in nrm.size():
			if nrm[i].length_squared() < 1e-10:
				nrm[i] = Vector3.UP
			else:
				nrm[i] = nrm[i].normalized()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nrm
	if uv.size() == verts.size():
		arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	am.clear_surfaces()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _rebuild_visual() -> void:
	if _vis_rest.is_empty() or _p.is_empty():
		return
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	var verts := _skin_deform(_vis_rest, _bind_i, _bind_w, _vis_nrm)
	_rebuild_mesh(_am, verts, _vis_nrm, _vis_uv, _vis_idx)


func _rebuild_adnex() -> void:
	for rec in _adnex_vis:
		var d: Dictionary = rec
		var vis: MeshInstance3D = d["node"]
		if vis == null or not vis.visible:
			continue
		var verts := _skin_deform(d["rest"], d["bind_i"], d["bind_w"], d["nrm"])
		_rebuild_mesh(d["am"], verts, d["nrm"], d["uv"], d["idx"])


func exposed_length() -> float:
	if not organ_active or _p.is_empty():
		return 0.0
	var best := 0.0
	for i in _p.size():
		# 在创口平面以外的点到创口的距离（下垂的宫体也算露出）。
		if (_p[i] - wound_center).dot(outward) > -0.004:
			best = maxf(best, _p[i].distance_to(wound_center))
	return best
