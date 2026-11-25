extends MeshInstance3D
## 0.4.12：子宫 / 膀胱以短刚体段链（宫颈→宫体→宫底）扯出。
## 夹点直接跟着钳尖，其余由硬距离 / 角度约束跟上，不再用缓慢加档平移。
## 原网格刚体蒙皮到段链，不撕裂。档位 = 实际伸出创口的长度。
## 输卵管两端封口并埋进宫角 / 卵巢；卵巢钉在管尽头，无碰撞卡死。

const SEGS := 6
const ITER := 20
const DAMP := 0.68
const GRAVITY := Vector3(0, -9.8, 0)
const PULL_SPEED := 0.22
const PUTBACK_SPEED := 0.16
const TUBE_LEVEL := 4
const LEVELS := 5
const MAX_BEND := 0.85          # ~49°
const MAX_STRETCH := 1.02
const MAX_SPEED := 6.0
const TUBE_PTS := 7
const TUBE_RADIUS := 0.0034
const PHYS_SCALE := 1.10

const AdnexaChain := preload("res://scripts/surgery/adnexa_chain.gd")

var kind: String = "uterus"
var extract_charge: float = 0.0
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
var _seg_rest: PackedFloat32Array = PackedFloat32Array()
var _axis_ab: Vector3 = Vector3.UP
var _cervix_ab: Vector3 = Vector3.ZERO
var _fundus_ab: Vector3 = Vector3.ZERO
var _horn_ab: Array = [Vector3.ZERO, Vector3.ZERO]
var _rest_len: float = 0.05
var _frame: Transform3D = Transform3D.IDENTITY
var _prev_frame: Transform3D = Transform3D.IDENTITY
var _has_prev_frame := false
var _navel: Vector3 = Vector3.ZERO
var _inited := false
var _rest_up: Vector3 = Vector3.UP

var _vis_rest: PackedVector3Array = PackedVector3Array()
var _vis_nrm: PackedVector3Array = PackedVector3Array()
var _vis_uv: PackedVector2Array = PackedVector2Array()
var _vis_idx: PackedInt32Array = PackedInt32Array()
var _bind_seg: PackedInt32Array = PackedInt32Array()
var _bind_t: PackedFloat32Array = PackedFloat32Array()
var _bind_l0: PackedVector3Array = PackedVector3Array()
var _bind_l1: PackedVector3Array = PackedVector3Array()
var _rest_bone: Array = []
var _bone: Array = []
var _am: ArrayMesh

var _src: Array = []
var _adnex_src: Array = []
var _chains: Dictionary = {}
var _early: Dictionary = {}
var _mat: ShaderMaterial = null
var _tube_mat: ShaderMaterial = null
var _has_pull_target := false
var _pull_target: Vector3 = Vector3.ZERO
var _ovary_rest_ab_cache: Array = [Vector3.ZERO, Vector3.ZERO]
var _ovary_centered: Dictionary = {}


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


func physical_fraction() -> float:
	return 1.0 if organ_active and extract_charge > 0.0 else 0.0


func physical_cut() -> float:
	return 0.0 if organ_active and extract_charge > 0.0 else 2.0


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
	if _p.is_empty():
		return _frame * _cervix_ab
	return _p[0]


func fundus_world() -> Vector3:
	if _p.is_empty():
		return _frame * _fundus_ab
	return _p[_p.size() - 1]


func horn_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	if _bone.is_empty() or _rest_bone.is_empty():
		return _frame * (_horn_ab[side] as Vector3)
	return _xform_rest(_horn_ab[side] as Vector3)


func tube_chain_active(side: int) -> bool:
	var ch: Variant = _chains.get(side, null)
	return ch is Dictionary and bool((ch as Dictionary).get("active", false))


func any_tube_chain() -> bool:
	return tube_chain_active(0) or tube_chain_active(1)


func setup(p_kind: String, frame: Transform3D, navel: Vector3, main_meshes: Array, adnex_meshes: Array, cervix_rest: Vector3, fundus_rest: Vector3, horns: Array) -> void:
	kind = p_kind
	_frame = frame
	_prev_frame = frame
	_has_prev_frame = false
	_navel = navel
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
	_build_spine()
	_bind_visual()
	_cache_ovary_rest()
	_prepare_tube_mat()
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


func _build_spine() -> void:
	_rest_ab.resize(SEGS)
	_seg_rest.resize(SEGS - 1)
	for i in SEGS:
		_rest_ab[i] = _cervix_ab.lerp(_fundus_ab, float(i) / float(SEGS - 1))
	for i in SEGS - 1:
		_seg_rest[i] = _rest_ab[i].distance_to(_rest_ab[i + 1])
	# 静止骨骼（腹局部）
	_rest_up = Vector3.RIGHT.cross(_axis_ab)
	if _rest_up.length_squared() < 1e-8:
		_rest_up = Vector3.FORWARD.cross(_axis_ab)
	_rest_up = _rest_up.normalized()
	_rest_bone = []
	var up := _rest_up
	for i in SEGS:
		var axis: Vector3
		if i + 1 < SEGS:
			axis = _rest_ab[i + 1] - _rest_ab[i]
		else:
			axis = _rest_ab[i] - _rest_ab[i - 1]
		if axis.length_squared() < 1e-12:
			axis = _axis_ab
		axis = axis.normalized()
		var x := up.cross(axis)
		if x.length_squared() < 1e-10:
			x = Vector3.RIGHT.cross(axis)
		x = x.normalized()
		var y := axis.cross(x)
		up = y
		_rest_bone.append(Transform3D(Basis(x, y, axis), _rest_ab[i]))


func _bind_visual() -> void:
	var n := _vis_rest.size()
	_bind_seg.resize(n)
	_bind_t.resize(n)
	_bind_l0.resize(n)
	_bind_l1.resize(n)
	for vi in n:
		var p: Vector3 = _vis_rest[vi]
		var u := clampf((p - _cervix_ab).dot(_axis_ab) / maxf(_rest_len, 1e-4), 0.0, 1.0)
		var f := u * float(SEGS - 1)
		var i := clampi(int(floor(f)), 0, SEGS - 2)
		var t := clampf(f - float(i), 0.0, 1.0)
		_bind_seg[vi] = i
		_bind_t[vi] = t
		var b0: Transform3D = _rest_bone[i]
		var b1: Transform3D = _rest_bone[i + 1]
		_bind_l0[vi] = b0.affine_inverse() * p
		_bind_l1[vi] = b1.affine_inverse() * p


func _prepare_tube_mat() -> void:
	_chains = {0: {"active": false, "rope": null, "ovary": null}, 1: {"active": false, "rope": null, "ovary": null}}
	_early = {0: false, 1: false}
	for mi in _adnex_src:
		var m := mi as MeshInstance3D
		if m == null:
			continue
		if _tube_mat == null and m.material_override is ShaderMaterial:
			_tube_mat = (m.material_override as ShaderMaterial).duplicate() as ShaderMaterial
			_tube_mat.set_shader_parameter("is_uterus", false)
		var kind_m := str(m.get_meta("organ_kind", ""))
		var side := int(m.get_meta("organ_side", 0))
		if kind_m == "ovary" and m.mesh and not _ovary_centered.has(side):
			_ovary_centered[side] = _centered_mesh(m.mesh, m)


func _cache_ovary_rest() -> void:
	_ovary_rest_ab_cache = [_horn_ab[0] + Vector3(0.025, 0.0, -0.012), _horn_ab[1] + Vector3(-0.025, 0.0, -0.012)]
	for mi in _adnex_src:
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		if str(m.get_meta("organ_kind", "")) != "ovary":
			continue
		var side := clampi(int(m.get_meta("organ_side", 0)), 0, 1)
		var arr: Array = m.mesh.surface_get_arrays(0)
		var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if P.is_empty():
			continue
		var acc := Vector3.ZERO
		for p in P:
			acc += p
		_ovary_rest_ab_cache[side] = acc / float(P.size()) - _navel


func _centered_mesh(src: Mesh, mi: MeshInstance3D) -> Mesh:
	var arr: Array = src.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX].duplicate()
	if P.is_empty():
		return src
	var acc := Vector3.ZERO
	for p in P:
		acc += p
	var c := acc / float(P.size())
	for i in P.size():
		P[i] = P[i] - c
	arr[Mesh.ARRAY_VERTEX] = P
	var am := ArrayMesh.new()
	var fmt: int = int(src.surface_get_format(0)) if src.get_surface_count() > 0 else 0
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, fmt)
	return am


func add_hide_meshes(meshes: Array) -> void:
	for m in meshes:
		if m != null and m not in _src:
			_src.append(m)


func begin_extract(frame: Transform3D, wound: Vector3, out_dir: Vector3) -> void:
	_frame = frame
	_prev_frame = frame
	_has_prev_frame = false
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
		_has_pull_target = false
		_rebuild_visual()
		_ensure_bound_tubes()


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
	for i in n:
		var pw: Vector3 = _frame * _rest_ab[i]
		_p[i] = pw
		_q[i] = pw
	_update_bones()


func add_charge(strength: float, dt: float) -> void:
	if not organ_active or retracting:
		return
	dt = minf(maxf(dt, 0.0), 0.2)
	var dist := clampf(strength, 0.0, 1.5) * PULL_SPEED * dt
	if dist <= 1e-8:
		return
	if _p.size() != SEGS:
		_init_particles()
	var fund: Vector3 = _p[SEGS - 1]
	var desired: Vector3 = fund
	var to_move := dist
	var outd := (fund - wound_center).dot(outward)
	if outd < 0.004:
		var tgt := wound_center + outward * 0.006
		var d := tgt - fund
		var L := d.length()
		if L > 1e-6:
			var step := minf(to_move, L)
			desired += d * (step / L)
			to_move -= step
	if to_move > 0.0:
		desired += outward * to_move
	desired = _reachable_from_cervix(desired)
	# 整条段链跟着宫底一起走，像把硬一些的器官扯出来，而不是只把宫底拉长。
	var delta := desired - fund
	if delta.length_squared() > 1e-12:
		for i in _p.size():
			_p[i] = _p[i] + delta
			if i < _q.size():
				_q[i] = _q[i] + delta
	_has_pull_target = true
	_pull_target = desired


func start_putback() -> void:
	if not organ_active:
		return
	retracting = true
	hold_index = -1
	_has_pull_target = false


func force_reset() -> void:
	extract_charge = 0.0
	retracting = false
	organ_active = false
	hold_index = -1
	_has_pull_target = false
	visible = false
	_hide_sources(false)
	_clear_chains()
	_early = {0: false, 1: false}
	_p = PackedVector3Array()
	_q = PackedVector3Array()
	_has_prev_frame = false


func detach_adnexa(side: int) -> bool:
	if kind != "uterus" or not organ_active:
		return false
	side = clampi(side, 0, 1)
	if tube_chain_active(side):
		return true
	_early[side] = true
	_spawn_chain(side)
	return true


func rebind_adnexa() -> void:
	_clear_chains()
	_early = {0: false, 1: false}
	if organ_active:
		_ensure_bound_tubes()


func _horn_is_out(side: int) -> bool:
	var h := horn_world(side)
	return (h - wound_center).dot(outward) > -0.006


func _ovary_rest_ab(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	return _ovary_rest_ab_cache[side] as Vector3


func ovary_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	if tube_chain_active(side):
		var ch: Dictionary = _chains.get(side, {})
		var ov: MeshInstance3D = ch.get("ovary")
		if ov and is_instance_valid(ov):
			return ov.global_position
		var rope: Node = ch.get("rope")
		if rope and is_instance_valid(rope) and rope.has_method("tip"):
			return rope.call("tip")
	return _xform_rest(_ovary_rest_ab(side)) if organ_active and not _bone.is_empty() else _frame * _ovary_rest_ab(side)


func ovary_contained(side: int) -> bool:
	var p := ovary_world(side)
	var outd := (p - wound_center).dot(outward)
	if outd < 0.012:
		return true
	var radial := (p - wound_center) - outward * outd
	return radial.length() < 0.045 and outd < 0.08


func fundus_out_distance() -> float:
	return (fundus_world() - wound_center).dot(outward)


func cervix_out_distance() -> float:
	return (cervix_world() - wound_center).dot(outward)


func tube_head_gap(side: int) -> float:
	if kind != "uterus":
		return 0.0
	var horn := horn_world(side)
	if tube_chain_active(side) or (organ_active and _chain_node(side) != null):
		var rope := _chain_node(side)
		if rope and rope.has_method("head"):
			# 管头埋在宫角内，与宫角的间隙应约为 embed，不得离开宫角。
			var h: Vector3 = rope.call("head")
			var d: Vector3 = rope.get("_dir") if "_dir" in rope else (ovary_world(side) - horn)
			if d.length_squared() < 1e-10:
				d = Vector3.RIGHT
			d = d.normalized()
			var expect := horn - d * float(rope.get("horn_embed"))
			return h.distance_to(expect)
	return 0.0


func ovary_tip_gap(side: int) -> float:
	if tube_chain_active(side) or (organ_active and _chain_node(side) != null):
		var rope := _chain_node(side)
		if rope and rope.has_method("tip"):
			return ovary_world(side).distance_to(rope.call("tip"))
	# 绑定态：卵巢就在管尽头
	return 0.0


func _chain_node(side: int) -> Node:
	var ch: Variant = _chains.get(clampi(side, 0, 1), null)
	if ch is Dictionary:
		var r = (ch as Dictionary).get("rope")
		if r != null and is_instance_valid(r):
			return r
	return null


func _maybe_auto_chain() -> void:
	if kind != "uterus" or not organ_active:
		return
	if extract_charge + 1e-4 < float(TUBE_LEVEL):
		_ensure_bound_tubes()
		return
	for side in [0, 1]:
		if tube_chain_active(side):
			continue
		if _horn_is_out(side) or extract_charge >= float(LEVELS) - 1e-3:
			_spawn_chain(side)
	_ensure_bound_tubes()


func _ensure_bound_tubes() -> void:
	if kind != "uterus" or not organ_active:
		return
	for side in [0, 1]:
		if tube_chain_active(side):
			continue
		if _chain_node(side) == null:
			_spawn_bound(side)
		else:
			_place_bound(side)


func _spawn_bound(side: int) -> void:
	var rope := AdnexaChain.new()
	rope.name = "AdnexaBound%d" % side
	if _tube_mat:
		rope.use_organ_material(_tube_mat)
	add_child(rope)
	var horn := horn_world(side)
	var ovp := ovary_world(side)
	rope.setup_line(horn, ovp, TUBE_PTS)
	var ov := _make_ovary_blob(side)
	add_child(ov)
	ov.global_position = ovp
	_chains[side] = {"active": false, "rope": rope, "ovary": ov}


func _place_bound(side: int) -> void:
	var rope := _chain_node(side)
	if rope == null:
		return
	var horn := horn_world(side)
	var ovp := _xform_rest(_ovary_rest_ab(side))
	if rope.has_method("set_head_and_rest"):
		rope.call("set_head_and_rest", horn, ovp)
	var ch: Dictionary = _chains[side]
	var ov: MeshInstance3D = ch.get("ovary")
	if ov and is_instance_valid(ov):
		ov.global_position = ovp
		ov.visible = true


func _spawn_chain(side: int) -> void:
	if tube_chain_active(side):
		return
	# 若已有绑定管，就地改成悬挂，避免传送。
	var horn := horn_world(side)
	var ovp := ovary_world(side)
	var rope := _chain_node(side)
	var ov: MeshInstance3D = null
	var ch_old: Dictionary = _chains.get(side, {})
	if ch_old.get("ovary") != null:
		ov = ch_old.get("ovary")
	if rope == null:
		rope = AdnexaChain.new()
		rope.name = "AdnexaChain%d" % side
		if _tube_mat:
			rope.use_organ_material(_tube_mat)
		add_child(rope)
		rope.setup_line(horn, ovp, TUBE_PTS)
	else:
		if rope.has_method("set_head_and_rest"):
			rope.call("set_head_and_rest", horn, ovp)
	if ov == null:
		ov = _make_ovary_blob(side)
		add_child(ov)
	ov.global_position = ovp
	ov.visible = true
	_chains[side] = {"active": true, "rope": rope, "ovary": ov}
	_place_chain(side, 0.0)


func _make_ovary_blob(side: int) -> MeshInstance3D:
	var ov := MeshInstance3D.new()
	ov.name = "OvaryBlob%d" % side
	ov.top_level = true
	ov.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _ovary_centered.has(side):
		ov.mesh = _ovary_centered[side]
	else:
		var src := _ovary_source(side)
		if src and src.mesh:
			ov.mesh = _centered_mesh(src.mesh, src)
		else:
			var sm := SphereMesh.new()
			sm.radius = 0.0075
			sm.height = 0.015
			sm.radial_segments = 14
			sm.rings = 8
			ov.mesh = sm
	var src2 := _ovary_source(side)
	if src2 and src2.material_override:
		ov.material_override = src2.material_override
	elif _tube_mat:
		ov.material_override = _tube_mat
	return ov


func _ovary_source(side: int) -> MeshInstance3D:
	for m in _adnex_src:
		if m == null:
			continue
		if str(m.get_meta("organ_kind", "")) != "ovary":
			continue
		if int(m.get_meta("organ_side", -1)) == side:
			return m
	return null


func _clear_chains() -> void:
	for side in [0, 1]:
		var ch: Dictionary = _chains.get(side, {})
		var rope = ch.get("rope")
		if rope != null and is_instance_valid(rope):
			rope.queue_free()
		var ov = ch.get("ovary")
		if ov != null and is_instance_valid(ov):
			ov.queue_free()
		_chains[side] = {"active": false, "rope": null, "ovary": null}


func _place_chain(side: int, dt: float) -> void:
	var ch: Dictionary = _chains.get(side, {})
	var rope: Node = ch.get("rope")
	if rope == null or not is_instance_valid(rope):
		return
	var horn := horn_world(side)
	if not bool(ch.get("active", false)):
		_place_bound(side)
		return
	rope.set("gravity", gravity)
	rope.set("floor_y", floor_y)
	if rope.has_method("pin_head"):
		rope.call("pin_head", horn)
	# 宫角还在体内且未被夹住：锁回静止姿态，不要穿腹壁。
	var held := int(rope.get("hold_index")) >= 0
	if not _horn_is_out(side) and not held:
		var ovp := _xform_rest(_ovary_rest_ab(side))
		# 若已被向外拉过，允许沿创口方向，但侧面锁在静止侧。
		if rope.has_method("set_head_and_rest"):
			rope.call("set_head_and_rest", horn, ovp)
	elif dt > 0.0 and rope.has_method("step"):
		rope.call("step", dt)
		if not _horn_is_out(side) and not held:
			pass
		elif not _horn_is_out(side) and held:
			# 只许顺着创口出去，不许从腹壁侧面穿出。
			_clamp_chain_to_wound(rope)
	var ov: MeshInstance3D = ch.get("ovary")
	if ov != null and is_instance_valid(ov):
		var tip: Vector3 = rope.call("tip") if rope.has_method("tip") else horn
		ov.global_position = tip
		ov.visible = true


func _clamp_chain_to_wound(rope: Node) -> void:
	if rope == null or not rope.has_method("points"):
		return
	var pts: PackedVector3Array = rope.call("points")
	var changed := false
	for i in range(1, pts.size()):
		var p: Vector3 = pts[i]
		var rel := p - wound_center
		var outd := rel.dot(outward)
		var radial := rel - outward * outd
		# 侧面偏离创口太远就收回到创口圆柱内。
		if radial.length() > 0.035 and outd < 0.01:
			p = wound_center + outward * minf(outd, 0.0) + radial.normalized() * 0.02
			pts[i] = p
			changed = true
	if changed and rope.has_method("set_points"):
		rope.call("set_points", pts)


func rest_cervix_world() -> Vector3:
	return _frame * _cervix_ab


func rest_fundus_world() -> Vector3:
	return _frame * _fundus_ab


func centroid_world() -> Vector3:
	if _p.is_empty():
		return _frame * ((_cervix_ab + _fundus_ab) * 0.5)
	var s := Vector3.ZERO
	for p in _p:
		s += p
	return s / float(_p.size())


func max_edge_ratio() -> float:
	# 段长比 + 蒙皮网格边长比，刚体蒙皮应接近 1。
	var m := 1.0
	for i in _seg_rest.size():
		if i + 1 >= _p.size():
			break
		var rest: float = maxf(float(_seg_rest[i]), 1e-6)
		m = maxf(m, _p[i].distance_to(_p[i + 1]) / rest)
	if _vis_idx.size() >= 3 and not _bone.is_empty() and _vis_rest.size() > 0:
		var verts := _skin_all()
		for f in range(0, _vis_idx.size() - 2, 3):
			for ab in [[_vis_idx[f], _vis_idx[f + 1]], [_vis_idx[f + 1], _vis_idx[f + 2]], [_vis_idx[f + 2], _vis_idx[f]]]:
				var ia: int = ab[0]
				var ib: int = ab[1]
				if ia < 0 or ib < 0 or ia >= verts.size() or ib >= verts.size():
					continue
				var rest2 := _vis_rest[ia].distance_to(_vis_rest[ib])
				if rest2 < 1e-6:
					continue
				m = maxf(m, verts[ia].distance_to(verts[ib]) / rest2)
	return m


func ray_pick(origin: Vector3, dir: Vector3) -> Array:
	if not organ_active or _p.is_empty():
		return [-1, 1e9]
	var d := dir.normalized()
	var best := 1e9
	var bi := -1
	# 段链节点 + 在相邻段上的最近点，便于夹到宫体表面。
	for i in _p.size():
		var w := _p[i] - origin
		var t := w.dot(d)
		if t <= 0.0:
			continue
		var dist := (w - d * t).length()
		if dist < best:
			best = dist
			bi = i
	if best > 0.028:
		return [-1, best]
	return [bi, best]


func ray_pick_adnexa(origin: Vector3, dir: Vector3) -> int:
	if kind != "uterus" or not organ_active:
		return -1
	var d := dir.normalized()
	var best := 0.016
	var bs := -1
	for side in [0, 1]:
		var rope := _chain_node(side)
		if rope != null and is_instance_valid(rope) and rope.has_method("ray_pick"):
			var pk: Array = rope.call("ray_pick", origin, dir)
			if int(pk[0]) >= 0 and float(pk[1]) < best:
				best = float(pk[1])
				bs = side
		var ovw := ovary_world(side)
		var w: Vector3 = ovw - origin
		var t := w.dot(d)
		if t > 0.0:
			var dist := (w - d * t).length()
			if dist < best and dist < 0.014:
				best = dist
				bs = side
	return bs


func hold_particle(i: int, tip: Vector3) -> void:
	if _p.is_empty():
		hold_index = -1
		return
	hold_index = clampi(i, 0, _p.size() - 1)
	hold_pos = tip
	_has_pull_target = false


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
		# 提前夹住：先变成悬挂链再夹。
		_spawn_chain(side)
	if not tube_chain_active(side):
		return false
	var rope: Node = (_chains[side] as Dictionary)["rope"]
	if rope == null or not is_instance_valid(rope):
		return false
	var pk: Array = rope.call("ray_pick", origin, dir)
	var idx := int(pk[0])
	var pts: PackedVector3Array = rope.call("points")
	if pts.is_empty():
		return false
	if idx < 0:
		idx = pts.size() - 1
	rope.set("hold_index", idx)
	rope.set("hold_pos", pts[idx])
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
	if _has_pull_target:
		_pull_target = xf * _pull_target
	wound_center = xf * wound_center
	outward = (xf.basis * outward).normalized()
	for side in [0, 1]:
		var rope := _chain_node(side)
		if rope and is_instance_valid(rope) and rope.has_method("carry"):
			rope.call("carry", xf)
		var ch: Dictionary = _chains.get(side, {})
		var ov: MeshInstance3D = ch.get("ovary")
		if ov and is_instance_valid(ov):
			ov.global_position = xf * ov.global_position


func step(dt: float, frame: Transform3D, wound: Vector3, out_dir: Vector3) -> void:
	if not organ_active:
		return
	dt = minf(maxf(dt, 0.0), 1.0 / 30.0)
	if _has_prev_frame:
		var xf := frame * _prev_frame.affine_inverse()
		var moved := xf.origin.length_squared() > 1e-16
		if moved or not xf.basis.is_equal_approx(Basis.IDENTITY):
			# 只带着段链走，伤口稍后用传入值覆盖，避免和 tissue carry 抢伤口。
			var saved_w := wound_center
			var saved_o := outward
			carry(xf)
			wound_center = saved_w
			outward = saved_o
	_prev_frame = frame
	_has_prev_frame = true
	_frame = frame
	wound_center = wound
	if out_dir.length_squared() > 1e-8:
		outward = out_dir.normalized()
	if _p.size() != SEGS:
		_init_particles()
	if retracting:
		hold_index = -1
		_has_pull_target = false
		_retract_toward_rest(dt)
		_update_bones()
		_refresh_charge()
		if extract_charge < float(TUBE_LEVEL):
			for side_r in [0, 1]:
				var ch_r: Dictionary = _chains.get(side_r, {})
				ch_r["active"] = false
				_chains[side_r] = ch_r
				_early[side_r] = false
		for side_r2 in [0, 1]:
			_place_chain(side_r2, 0.0)
		_rebuild_visual()
		if _max_rest_offset() < 0.012 or extract_charge <= 1.05:
			force_reset()
			return
		return
	# 仍在体内且未被夹住时保持原位，不要被重力拽出创口。
	if hold_index < 0 and not _has_pull_target:
		var any_out := false
		for p0 in _p:
			if (p0 - wound_center).dot(outward) > 0.002:
				any_out = true
				break
		if not any_out:
			for i0 in _p.size():
				var pw: Vector3 = _frame * _rest_ab[i0]
				_p[i0] = pw
				_q[i0] = pw
			_update_bones()
			_refresh_charge()
			_maybe_auto_chain()
			for side0 in [0, 1]:
				_place_chain(side0, dt)
			_rebuild_visual()
			return
	# 夹点 / 拉动目标移动时，先把整条段链带上，再靠约束把宫颈留在轨道上。
	if hold_index >= 0 and hold_index < _p.size():
		var hd := hold_pos - _p[hold_index]
		if hd.length_squared() > 1e-12:
			for hi in _p.size():
				_p[hi] = _p[hi] + hd
				if hi < _q.size():
					_q[hi] = _q[hi] + hd
	elif _has_pull_target and _p.size() == SEGS:
		var pd := _pull_target - _p[SEGS - 1]
		if pd.length_squared() > 1e-12:
			for pi in _p.size():
				_p[pi] = _p[pi] + pd
				if pi < _q.size():
					_q[pi] = _q[pi] + pd
	# 积分
	var n := _p.size()
	for i in n:
		if i == hold_index:
			_q[i] = _p[i]
			_p[i] = hold_pos
			continue
		if _has_pull_target and i == n - 1 and hold_index < 0 and not retracting:
			_q[i] = _p[i]
			_p[i] = _pull_target
			continue
		var cur := _p[i]
		var v := (cur - _q[i]) * DAMP
		var sp := v.length()
		if sp > MAX_SPEED * dt:
			v = v * ((MAX_SPEED * dt) / maxf(sp, 1e-8))
		if i > 0:
			v += gravity * dt * dt
		_q[i] = cur
		_p[i] = cur + v
		if _p[i].y < floor_y + 0.008:
			_p[i].y = floor_y + 0.008
	for _it in ITER:
		_solve_fabrik()
		_solve_angles()
		_constrain_cervix()
	_solve_fabrik()
	if hold_index >= 0 and hold_index < _p.size():
		if _p[hold_index].distance_to(hold_pos) > 0.002:
			hold_pos = _p[hold_index]
	if _has_pull_target and _p.size() == SEGS:
		# 保留向外的拉动目标，不被约束回退改写。
		if _p[SEGS - 1].distance_to(_pull_target) < 0.002:
			_pull_target = _p[SEGS - 1]
	_update_bones()
	_refresh_charge()
	if not retracting:
		_maybe_auto_chain()
	else:
		if extract_charge < float(TUBE_LEVEL) and any_tube_chain():
			# 放回：悬链改回绑定，随宫体收回。
			for side in [0, 1]:
				var ch: Dictionary = _chains.get(side, {})
				ch["active"] = false
				_chains[side] = ch
				_early[side] = false
	for side in [0, 1]:
		_place_chain(side, 0.0 if retracting else dt)
	_rebuild_visual()


func _pin_drivers() -> void:
	if hold_index >= 0 and hold_index < _p.size():
		_p[hold_index] = hold_pos
	elif _has_pull_target and hold_index < 0 and not retracting and _p.size() == SEGS:
		_p[SEGS - 1] = _pull_target


func _solve_fabrik() -> void:
	# 从宫颈（轨道）和夹点 / 宫底目标双向把段长精确拉回静止长。
	var n := _p.size()
	if n < 2 or _seg_rest.size() < n - 1:
		return
	var goal_i := n - 1
	var goal: Vector3 = _p[n - 1]
	if hold_index >= 0 and hold_index < n:
		goal_i = hold_index
		goal = hold_pos
	elif _has_pull_target and hold_index < 0 and not retracting:
		goal = _pull_target
		goal_i = n - 1
	goal = _reachable_from_cervix(goal)
	# 先把宫颈留在轨道上
	_constrain_cervix()
	# 后退：从目标走到宫颈
	_p[goal_i] = goal
	for i in range(goal_i - 1, -1, -1):
		var rest := float(_seg_rest[i])
		var d := _p[i] - _p[i + 1]
		var L := d.length()
		if L < 1e-8:
			d = _frame.basis * _axis_ab
			L = 1.0
		_p[i] = _p[i + 1] + d * (rest / L)
	_constrain_cervix()
	# 前进：从宫颈把精确段长推回去
	for i in n - 1:
		var rest2 := float(_seg_rest[i])
		var d2 := _p[i + 1] - _p[i]
		var L2 := d2.length()
		if L2 < 1e-8:
			d2 = _frame.basis * _axis_ab
			L2 = 1.0
		_p[i + 1] = _p[i] + d2 * (rest2 / L2)
	# 若目标点不是尾端，再从目标向尾端推一段
	if goal_i < n - 1:
		for i in range(goal_i, n - 1):
			var rest3 := float(_seg_rest[i])
			var d3 := _p[i + 1] - _p[i]
			var L3 := d3.length()
			if L3 < 1e-8:
				d3 = _frame.basis * _axis_ab
				L3 = 1.0
			_p[i + 1] = _p[i] + d3 * (rest3 / L3)


func _solve_distances() -> void:
	var n := _p.size()
	for i in n - 1:
		var rest := float(_seg_rest[i]) if i < _seg_rest.size() else _p[i].distance_to(_p[i + 1])
		if rest < 1e-6:
			continue
		var d := _p[i + 1] - _p[i]
		var L := d.length()
		if L < 1e-8:
			continue
		# 硬约束，把段长拉回静止长（允许极小拉伸）。
		var lim := rest * MAX_STRETCH
		var target := rest if L > lim or L < rest * 0.98 else L
		if absf(L - rest) < rest * 0.001:
			continue
		var corr := (L - rest) / L
		var li := _is_locked(i)
		var lj := _is_locked(i + 1)
		if li and lj:
			continue
		if li:
			_p[i + 1] -= d * corr
		elif lj:
			_p[i] += d * corr
		else:
			_p[i] += d * corr * 0.5
			_p[i + 1] -= d * corr * 0.5


func _solve_angles() -> void:
	var n := _p.size()
	if n < 3:
		return
	for i in range(1, n - 1):
		if _is_locked(i):
			continue
		var a := _p[i] - _p[i - 1]
		var b := _p[i + 1] - _p[i]
		var la := a.length()
		var lb := b.length()
		if la < 1e-6 or lb < 1e-6:
			continue
		var c := clampf(a.dot(b) / (la * lb), -1.0, 1.0)
		var ang := acos(c)
		if ang <= MAX_BEND:
			continue
		# 弯过头：把中点推向两端中点，限制折叠。
		var mid := (_p[i - 1] + _p[i + 1]) * 0.5
		var t := clampf((ang - MAX_BEND) / maxf(ang, 1e-5), 0.0, 1.0)
		_p[i] = _p[i].lerp(mid, t * 0.85)


func _constrain_cervix() -> void:
	if kind != "uterus" or _p.is_empty():
		return
	if hold_index == 0:
		# 夹住宫颈也不让它飞出创口太远。
		var outd_h := (_p[0] - wound_center).dot(outward)
		if outd_h > 0.006:
			_p[0] -= outward * (outd_h - 0.006)
		return
	var rest_c: Vector3 = _frame * _cervix_ab
	var path := wound_center - rest_c
	var plen := path.length()
	if plen < 1e-6:
		_p[0] = rest_c
		return
	var dir_p := path / plen
	var t := clampf((_p[0] - rest_c).dot(dir_p) / plen, 0.0, 1.0)
	var on_path := rest_c + dir_p * (t * plen)
	_p[0] = _p[0].lerp(on_path, 0.9)
	var outd := (_p[0] - wound_center).dot(outward)
	if outd > 0.003:
		_p[0] -= outward * (outd - 0.003)


func _is_locked(i: int) -> bool:
	if i == hold_index:
		return true
	if _has_pull_target and hold_index < 0 and not retracting and i == SEGS - 1:
		return true
	return false


func _rest_total() -> float:
	var s := 0.0
	for i in _seg_rest.size():
		s += float(_seg_rest[i])
	return maxf(s, _rest_len)


func _rail_cervix(p: Vector3) -> Vector3:
	var rest_c: Vector3 = _frame * _cervix_ab
	var path := wound_center - rest_c
	var plen := maxf(path.length(), 1e-6)
	var t := clampf((p - rest_c).dot(path) / (plen * plen), 0.0, 1.0)
	var c := rest_c + path * t
	var outd := (c - wound_center).dot(outward)
	if outd > 0.003:
		c -= outward * (outd - 0.003)
	return c


func _reachable_from_cervix(desired: Vector3) -> Vector3:
	# 宫颈可在「体内原位 → 创口」轨道上滑动；宫底不超过静止总长。
	var lim := _rest_total()
	var q := _rail_cervix(desired)
	var d := desired - q
	var L := d.length()
	if L <= lim:
		return desired
	return q + d * (lim / L)


func _clamp_to_rest_length() -> void:
	# 整条段链总长不得超过静止长，从宫颈缩放。
	if _p.size() < 2:
		return
	var total := 0.0
	for i in _p.size() - 1:
		total += _p[i].distance_to(_p[i + 1])
	var lim := _rest_total() * MAX_STRETCH
	if total <= lim or total < 1e-6:
		return
	var c: Vector3 = _p[0]
	var s := lim / total
	for i in range(1, _p.size()):
		_p[i] = c + (_p[i] - c) * s


func _retract_toward_rest(dt: float) -> void:
	var n := _p.size()
	var step := PUTBACK_SPEED * dt
	for i in n:
		var tgt: Vector3 = _frame * _rest_ab[i]
		var d := tgt - _p[i]
		var L := d.length()
		if L <= 1e-6:
			_p[i] = tgt
			_q[i] = tgt
			continue
		var s := minf(step, L)
		_p[i] = _p[i] + d * (s / L)
		_q[i] = _p[i]


func _max_rest_offset() -> float:
	var m := 0.0
	for i in _p.size():
		m = maxf(m, _p[i].distance_to(_frame * _rest_ab[i]))
	return m


func _refresh_charge() -> void:
	if not organ_active:
		extract_charge = 0.0
		return
	var exp := exposed_length()
	var u := clampf(exp / maxf(_rest_len * 0.80, 0.025), 0.0, 1.0)
	extract_charge = 1.0 + 4.0 * u


func _update_bones() -> void:
	_bone = []
	if _p.size() != SEGS:
		return
	var up := _frame.basis * _rest_up
	if up.length_squared() < 1e-8:
		up = Vector3.UP
	else:
		up = up.normalized()
	for i in SEGS:
		var axis: Vector3
		if i + 1 < SEGS:
			axis = _p[i + 1] - _p[i]
		else:
			axis = _p[i] - _p[i - 1]
		if axis.length_squared() < 1e-12:
			axis = _frame.basis * _axis_ab
		axis = axis.normalized()
		var x := up.cross(axis)
		if x.length_squared() < 1e-10:
			x = Vector3.RIGHT.cross(axis)
			if x.length_squared() < 1e-10:
				x = Vector3.FORWARD.cross(axis)
		x = x.normalized()
		if i > 0:
			var prev_x: Vector3 = (_bone[i - 1] as Transform3D).basis.x
			if x.dot(prev_x) < 0.0:
				x = -x
		var y := axis.cross(x)
		up = y
		_bone.append(Transform3D(Basis(x, y, axis), _p[i]))


func _xform_rest(p_ab: Vector3) -> Vector3:
	if _bone.is_empty() or _rest_bone.is_empty():
		return _frame * p_ab
	var u := clampf((p_ab - _cervix_ab).dot(_axis_ab) / maxf(_rest_len, 1e-4), 0.0, 1.0)
	var f := u * float(SEGS - 1)
	var i := clampi(int(floor(f)), 0, SEGS - 2)
	var t := clampf(f - float(i), 0.0, 1.0)
	var b0r: Transform3D = _rest_bone[i]
	var b1r: Transform3D = _rest_bone[i + 1]
	var l0: Vector3 = b0r.affine_inverse() * p_ab
	var l1: Vector3 = b1r.affine_inverse() * p_ab
	var a: Vector3 = (_bone[i] as Transform3D) * l0
	var b: Vector3 = (_bone[i + 1] as Transform3D) * l1
	return a.lerp(b, t)


func _skin_all() -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(_vis_rest.size())
	if _bone.is_empty():
		for i in _vis_rest.size():
			out[i] = _frame * _vis_rest[i]
		return out
	for vi in _vis_rest.size():
		var i := _bind_seg[vi]
		var tw := _bind_t[vi]
		var a: Vector3 = (_bone[i] as Transform3D) * _bind_l0[vi]
		var b: Vector3 = (_bone[mini(i + 1, SEGS - 1)] as Transform3D) * _bind_l1[vi]
		var pw := a.lerp(b, tw)
		if not pw.is_finite():
			pw = _frame * _vis_rest[vi]
		out[vi] = pw
	# 绕当前段链质心均匀放大，补偿弯曲时线性混合把内侧边缩短。
	if PHYS_SCALE != 1.0 and out.size() > 0 and _p.size() > 0:
		var c := Vector3.ZERO
		for q in _p:
			c += q
		c /= float(_p.size())
		for vi in out.size():
			out[vi] = c + (out[vi] - c) * PHYS_SCALE
	return out


func _rebuild_mesh(am: ArrayMesh, verts: PackedVector3Array, nrm_rest: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var used := 0
	for f in range(0, idx.size() - 2, 3):
		var ia := idx[f]
		var ib := idx[f + 1]
		var ic := idx[f + 2]
		if ia < 0 or ib < 0 or ic < 0 or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
			continue
		var a: Vector3 = verts[ia]
		var b: Vector3 = verts[ib]
		var c: Vector3 = verts[ic]
		if not a.is_finite() or not b.is_finite() or not c.is_finite():
			continue
		var fn := (b - a).cross(c - a)
		if fn.length_squared() < 1e-16:
			continue
		for rec in [[ia, a], [ib, b], [ic, c]]:
			var vi: int = rec[0]
			var pv: Vector3 = rec[1]
			if vi < uv.size():
				st.set_uv(uv[vi])
			st.add_vertex(pv)
		used += 1
	if used == 0:
		am.clear_surfaces()
		return
	st.generate_normals()
	st.generate_tangents()
	am.clear_surfaces()
	st.commit(am)


func _rebuild_visual() -> void:
	if _vis_rest.is_empty() or _p.is_empty():
		return
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	var verts := _skin_all()
	_rebuild_mesh(_am, verts, _vis_nrm, _vis_uv, _vis_idx)


func exposed_length() -> float:
	if not organ_active or _p.is_empty():
		return 0.0
	var best := 0.0
	for i in _p.size():
		if (_p[i] - wound_center).dot(outward) > -0.004:
			best = maxf(best, _p[i].distance_to(wound_center))
	return best


func physical_size_ratio() -> float:
	# 网格边长相对静止边长的均值。下垂弯曲会让 AABB / 回转半径变小，但边长应保持。
	if _vis_rest.is_empty() or _p.is_empty() or _vis_idx.size() < 3:
		return 1.0
	var verts := _skin_all()
	var acc := 0.0
	var n := 0
	for f in range(0, _vis_idx.size() - 2, 3):
		for ab in [[_vis_idx[f], _vis_idx[f + 1]], [_vis_idx[f + 1], _vis_idx[f + 2]], [_vis_idx[f + 2], _vis_idx[f]]]:
			var ia: int = ab[0]
			var ib: int = ab[1]
			if ia < 0 or ib < 0 or ia >= verts.size() or ib >= verts.size():
				continue
			var rest := _vis_rest[ia].distance_to(_vis_rest[ib])
			if rest < 1e-6:
				continue
			acc += verts[ia].distance_to(verts[ib]) / rest
			n += 1
	if n < 8:
		return 1.0
	return acc / float(n)


func debug_mesh_quality() -> Dictionary:
	var out := {"nan_verts": 0, "deg_faces": 0, "nan_normals": 0, "faces": 0, "ok": true}
	if _am == null or _am.get_surface_count() < 1:
		return out
	var arr: Array = _am.surface_get_arrays(0)
	var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	for v in V:
		if not v.is_finite():
			out["nan_verts"] = int(out["nan_verts"]) + 1
	for nrm in N:
		if not nrm.is_finite():
			out["nan_normals"] = int(out["nan_normals"]) + 1
	for f in range(0, I.size() - 2, 3):
		out["faces"] = int(out["faces"]) + 1
		var a: Vector3 = V[I[f]]
		var b: Vector3 = V[I[f + 1]]
		var c: Vector3 = V[I[f + 2]]
		var fn := (b - a).cross(c - a)
		if fn.length_squared() < 1e-16 or not fn.is_finite():
			out["deg_faces"] = int(out["deg_faces"]) + 1
	out["ok"] = int(out["nan_verts"]) == 0 and int(out["nan_normals"]) == 0 and int(out["deg_faces"]) == 0
	return out


func chain_is_straight(side: int) -> bool:
	var rope := _chain_node(side)
	if rope == null or not bool(rope.get("open_chain")):
		return false
	var pts: PackedVector3Array = rope.call("points")
	if pts.size() < 3:
		return false
	var a: Vector3 = pts[0]
	var b: Vector3 = pts[pts.size() - 1]
	var ab := b - a
	var L := ab.length()
	if L < 1e-4:
		return false
	var dir := ab / L
	var worst := 0.0
	for i in range(1, pts.size() - 1):
		var t := clampf((pts[i] - a).dot(dir) / L, 0.0, 1.0)
		worst = maxf(worst, (pts[i] - (a + dir * (t * L))).length())
	return worst < L * 0.55 and L > 0.02


func ovary_at_chain_end(side: int) -> bool:
	var rope := _chain_node(side)
	if rope == null or not rope.has_method("tip") or not rope.has_method("head"):
		return false
	var tip: Vector3 = rope.call("tip")
	var head: Vector3 = rope.call("head")
	var ov := ovary_world(side)
	return ov.distance_to(tip) < 0.006 and ov.distance_to(head) > ov.distance_to(tip) + 0.01
