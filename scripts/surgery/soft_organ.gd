extends MeshInstance3D
## 0.4.11：子宫 / 膀胱的五档柔体脱出。
## - 一经扯出，整颗子宫立刻成为柔体（不再逐渐物理化）。
## - 档位 = 子宫伸出体外（创口）的程度：1 档宫底刚露出，5 档整颗伸出、宫颈留在创口。
## - 阴道始终接在宫颈上，随宫颈移动拉伸。输卵管 / 卵巢为从宫角出发的直悬链，卵巢在尽头；
##   未扯出创口时悬链不得穿出体壁。

const RINGS := 6
const SIDES := 8
const ITER := 8
const DAMP := 0.68
const GRAVITY := Vector3(0, -9.8, 0)
const CHARGE_RATE := 0.32          # 满强度每秒约 0.32 档，从 1 到 5 约 12.5 秒
const PUTBACK_RATE := 0.85
const TUBE_LEVEL := 4
const PEEK_OUT := 0.018
const LEVELS := 5
const PIN_IN := 0.78
const PIN_OUT := 0.08
const SPRING_K := 0.62
const MAX_SPEED := 1.2
const PHYS_SCALE := 1.04          # 轻微放大，绕当前宫颈，避免旧宫颈中心把网格撕开
const MAX_STRETCH := 1.18
const SHAPE_BETA := 0.32
const BEND_K := 0.28
const PHYS_FRAC_L1 := 0.20

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
var _navel: Vector3 = Vector3.ZERO
var _inited := false

var _vis_rest: PackedVector3Array = PackedVector3Array()
var _vis_nrm: PackedVector3Array = PackedVector3Array()
var _vis_uv: PackedVector2Array = PackedVector2Array()
var _vis_idx: PackedInt32Array = PackedInt32Array()
var _bind_i: PackedInt32Array = PackedInt32Array()   # 3 per vert
var _bind_w: PackedVector3Array = PackedVector3Array()
var _vis_along: PackedFloat32Array = PackedFloat32Array()
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


func physical_fraction() -> float:
	# 一经扯出就是整颗柔体。
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
	_vis_along.resize(_vis_rest.size())
	for i in _vis_rest.size():
		_vis_along[i] = clampf((_vis_rest[i] - _cervix_ab).dot(_axis_ab) / maxf(_rest_len, 1e-4), 0.0, 1.0)
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
		var rads: Array = []
		for p2 in (b["pts"] as Array):
			var off: Vector3 = (p2 as Vector3) - mid
			off -= _axis_ab * off.dot(_axis_ab)
			rads.append(off.length())
		if not rads.is_empty():
			rads.sort()
			var idx := clampi(int(round(float(rads.size() - 1) * 0.88)), 0, rads.size() - 1)
			rad = maxf(float(rads[idx]), 0.006)
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
			# 弯曲弹簧：隔环 / 隔柱，抑制尖角撕裂。
			if r + 2 < RINGS:
				var k3 := (r + 2) * SIDES + s
				_springs.append([i, k3, _rest_ab[i].distance_to(_rest_ab[k3])])
			var js := r * SIDES + ((s + 2) % SIDES)
			_springs.append([i, js, _rest_ab[i].distance_to(_rest_ab[js])])


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
	# 整颗子宫（含内膜）交给柔体，原网格在脱出期间隐藏。附件换成绑定复制件 / 悬链。
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
	# 出生必须落在体内原子宫位置，不能一出现就跳到创口上方。
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


func _horn_is_out(side: int) -> bool:
	var h := horn_world(side)
	return (h - wound_center).dot(outward) > -0.006


func _ovary_rest_ab(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	for rec in _adnex_vis:
		var d: Dictionary = rec
		if str(d.get("kind", "")) == "ovary" and int(d.get("side", -1)) == side:
			var rest: PackedVector3Array = d.get("rest", PackedVector3Array())
			if not rest.is_empty():
				var acc := Vector3.ZERO
				for p in rest:
					acc += p
				return acc / float(rest.size())
	var src := _ovary_source(side)
	if src and src.mesh:
		var arr: Array = src.mesh.surface_get_arrays(0)
		var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if not P.is_empty():
			var acc2 := Vector3.ZERO
			for p2 in P:
				acc2 += p2
			return acc2 / float(P.size()) - _navel
	var h_ab: Vector3 = _horn_ab[side]
	var side_x := 1.0 if h_ab.x >= 0.0 else -1.0
	return h_ab + Vector3(side_x * 0.025, 0.0, -0.012)


func _adnexa_inward_dir(side: int) -> Vector3:
	var horn := horn_world(side)
	var tgt: Vector3 = _frame * _ovary_rest_ab(side)
	var d := tgt - horn
	# 去掉朝创口外的分量，避免链条把卵巢推出腹壁。
	var outc := d.dot(outward)
	if outc > 0.0:
		d -= outward * outc
	if d.length_squared() < 1e-8:
		var h_ab: Vector3 = _horn_ab[clampi(side, 0, 1)]
		var side_x := 1.0 if h_ab.x >= 0.0 else -1.0
		d = _frame.basis * Vector3(side_x, 0.0, -0.25)
	return d.normalized()


func _contain_chain_inside(rope: Node, side: int) -> void:
	if rope == null or not is_instance_valid(rope):
		return
	var held := int(rope.get("hold_index")) >= 0
	var horn_out := _horn_is_out(side)
	if horn_out and held:
		return
	if horn_out:
		return
	# 宫角还在体内：关闭重力，把链节收在创口平面以内，贴着原卵巢方向。
	rope.set("gravity", Vector3.ZERO)
	if not rope.has_method("points"):
		return
	var pts: PackedVector3Array = rope.call("points")
	if pts.is_empty():
		return
	var changed := false
	for i in pts.size():
		var p: Vector3 = pts[i]
		var excess := (p - wound_center).dot(outward) + 0.004
		if excess > 0.0:
			p -= outward * excess
			changed = true
		# 皮肤外侧再往里推一点
		for k in mini(skin_p.size(), 48):
			var w := p - skin_p[k]
			var nd := skin_n[k] if k < skin_n.size() else Vector3.ZERO
			var push := w.dot(nd)
			if push > -0.002 and nd.length_squared() > 1e-8:
				p -= nd.normalized() * (push + 0.003)
				changed = true
				break
		pts[i] = p
	if changed and rope.has_method("set_points"):
		rope.call("set_points", pts)
	elif changed:
		rope.set("_p", pts)
		if "_q" in rope:
			rope.set("_q", pts)


func ovary_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	if tube_chain_active(side):
		var ch: Dictionary = _chains.get(side, {})
		var ov: MeshInstance3D = ch.get("ovary")
		if ov and is_instance_valid(ov):
			return ov.global_position
		var rope: Node = ch.get("rope")
		if rope and is_instance_valid(rope):
			var pts: PackedVector3Array = rope.call("points")
			if pts.size() > 0:
				return pts[pts.size() - 1]
	# 绑定在宫体上：用原卵巢休息位置随柔体位移。
	return _frame * _ovary_rest_ab(side) if not organ_active else _bound_ovary_world(side)


func _bound_ovary_world(side: int) -> Vector3:
	# 用变形后网格质心，不要用节点原点（复制网格常停在世界原点）。
	for rec in _adnex_vis:
		var d: Dictionary = rec
		if str(d.get("kind", "")) != "ovary" or int(d.get("side", -1)) != side:
			continue
		var rest: PackedVector3Array = d.get("rest", PackedVector3Array())
		var bi: PackedInt32Array = d.get("bind_i", PackedInt32Array())
		var bw: PackedVector3Array = d.get("bind_w", PackedVector3Array())
		if rest.size() > 0 and not _p.is_empty() and bi.size() >= rest.size() * 3:
			var verts := _skin_deform(rest, bi, bw, d.get("nrm", PackedVector3Array()))
			var acc := Vector3.ZERO
			for p in verts:
				acc += p
			return acc / float(verts.size())
	return _frame * _ovary_rest_ab(side)


func ovary_contained(side: int) -> bool:
	# 允许随宫体从创口出去，但不许从旁边的腹壁穿出很远。
	var p := ovary_world(side)
	var outd := (p - wound_center).dot(outward)
	if outd < 0.012:
		return true
	var radial := (p - wound_center) - outward * outd
	return radial.length() < 0.045 and outd < 0.06


func fundus_out_distance() -> float:
	return (fundus_world() - wound_center).dot(outward)


func cervix_out_distance() -> float:
	return (cervix_world() - wound_center).dot(outward)


func _maybe_auto_chain() -> void:
	if kind != "uterus" or not organ_active:
		return
	# 只有宫角已经露出创口（或达到 4 档且宫角靠近创口）才把附件变成悬链，
	# 避免还在体内时链条带着卵巢从腹壁/创口「卡出去」。
	if extract_charge + 1e-4 < float(TUBE_LEVEL):
		return
	for side in [0, 1]:
		if tube_chain_active(side):
			continue
		if _horn_is_out(side) or extract_charge >= float(LEVELS) - 1e-3:
			_spawn_chain(side)
	_set_adnex_bound_visible(true)


func _spawn_chain(side: int) -> void:
	if tube_chain_active(side):
		return
	var rope := GutRope.new()
	rope.name = "AdnexaChain%d" % side
	rope.apply_profile({
		"profile": "adnexa",
		"open_chain": true,
		"radius": 0.0034,
		"seg": 0.018,
		"damp": 0.90,
		"min_pts": 6,
		"max_pts": 8,
		"k_in": 1,
		"mes_every": 99,
	})
	rope.max_len = 0.10
	rope.fed_len = 0.08
	if _tube_mat:
		rope.use_organ_material(_tube_mat)
	add_child(rope)
	var horn := horn_world(side)
	# 沿原卵巢方向生长（盆腔内），不要朝腹壁 / 创口外推。
	var out := _adnexa_inward_dir(side)
	rope.anchor_a = horn
	rope.anchor_b = horn
	rope.exit_a = horn + out * 0.010
	rope.exit_b = horn + out * 0.010
	rope.mes_root = horn
	rope.call("step", 1.0 / 60.0)
	var ov := MeshInstance3D.new()
	ov.name = "OvaryBlob%d" % side
	ov.top_level = true
	var src_ov := _ovary_source(side)
	if src_ov and src_ov.mesh:
		ov.mesh = src_ov.mesh
		if src_ov.material_override:
			ov.material_override = src_ov.material_override
		elif src_ov.get_active_material(0):
			ov.material_override = src_ov.get_active_material(0)
	if ov.mesh == null:
		ov.mesh = _ovary_mesh()
	if ov.material_override == null and _tube_mat:
		ov.material_override = _tube_mat
	add_child(ov)
	_chains[side] = {"active": true, "rope": rope, "ovary": ov, "ovary_rest": src_ov}
	_place_chain(side, 0.0)


func _ovary_source(side: int) -> MeshInstance3D:
	for mi in _adnex_src:
		var m := mi as MeshInstance3D
		if m == null:
			continue
		if str(m.get_meta("organ_kind", "")) != "ovary":
			continue
		if int(m.get_meta("organ_side", side)) == side:
			return m
	for rec in _adnex_vis:
		var d: Dictionary = rec
		if str(d.get("kind", "")) == "ovary" and int(d.get("side", -1)) == side:
			var vis: MeshInstance3D = d.get("node")
			if vis:
				return vis
	return null


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
	var out := _adnexa_inward_dir(side)
	rope.set("exit_a", horn + out * 0.010)
	rope.set("exit_b", horn + out * 0.010)
	rope.set("mes_root", horn)
	rope.set("gravity", gravity)
	rope.set("floor_y", floor_y)
	rope.set("capsules", capsules)
	rope.set("skin_p", skin_p)
	rope.set("skin_n", skin_n)
	if dt > 0.0:
		rope.call("step", dt)
	_contain_chain_inside(rope, side)
	var ov: MeshInstance3D = ch.get("ovary")
	if ov != null and is_instance_valid(ov):
		var pts: PackedVector3Array = rope.call("points")
		if pts.size() > 0:
			# 卵巢在直链尽头（最后一点），不是链首/锚点。
			var tip: Vector3 = pts[pts.size() - 1]
			ov.global_position = tip
			if pts.size() >= 2:
				var tan: Vector3 = tip - pts[pts.size() - 2]
				if tan.length_squared() > 1e-8:
					var up := Vector3.UP
					if absf(tan.normalized().dot(up)) > 0.95:
						up = Vector3.RIGHT
					ov.look_at(tip + tan.normalized(), up)


func _extract_u(charge_v: float) -> float:
	if charge_v <= 1.0:
		return 0.0
	return clampf((charge_v - 1.0) / 4.0, 0.0, 1.0)


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
	var m := 1.0
	for sp in _springs:
		var i: int = sp[0]
		var j: int = sp[1]
		var rest: float = maxf(float(sp[2]), 1e-6)
		if i < 0 or j < 0 or i >= _p.size() or j >= _p.size():
			continue
		m = maxf(m, _p[i].distance_to(_p[j]) / rest)
	return m


func _kinematic_xf(charge_v: float) -> Transform3D:
	# L1 = 体内原位（不跳到创口）。L5 = 宫颈到创口，长轴略向外并朝重力下垂，不竖直顶在创口上方。
	var u := _extract_u(charge_v)
	var cervix_w: Vector3 = _frame * _cervix_ab
	var fundus_w: Vector3 = _frame * _fundus_ab
	var axis_rest := fundus_w - cervix_w
	if axis_rest.length_squared() < 1e-8:
		axis_rest = _frame.basis * _axis_ab
	axis_rest = axis_rest.normalized()
	if u <= 1e-5:
		return Transform3D(_frame.basis, _frame.origin)
	var down := gravity
	if down.length_squared() < 1e-8:
		down = Vector3.DOWN
	else:
		down = down.normalized()
	var hang := (outward * 0.28 + down * 0.72)
	if hang.length_squared() < 1e-8:
		hang = down
	hang = hang.normalized()
	var axis_now: Vector3 = axis_rest.slerp(hang, u)
	if axis_now.length_squared() < 1e-8:
		axis_now = hang
	else:
		axis_now = axis_now.normalized()
	var c_tgt: Vector3 = cervix_w.lerp(wound_center - outward * 0.006, u)
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
		idx = pts.size() - 1
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
	var u := _extract_u(extract_charge)
	# 重力作用在整颗器官上；宫颈环钉在目标上，宫底随重力下垂，不再把体外点强钉在创口上方。
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
		var ring := i / SIDES
		var at_cervix := kind == "uterus" and ring <= 1
		if not at_cervix:
			v += gravity * dt * dt * (0.35 + 0.65 * u)
		_q[i] = cur
		_p[i] = cur + v
		var tgt: Vector3 = xf * _rest_ab[i]
		var pin := PIN_OUT
		if at_cervix:
			pin = PIN_IN
		elif ring <= 2:
			pin = lerpf(0.42, 0.12, u)
		else:
			pin = lerpf(0.28, PIN_OUT, u)
		_p[i] = _p[i].lerp(tgt, pin)
		if _p[i].y < floor_y + 0.008:
			_p[i].y = floor_y + 0.008
	# 夹住拖拽时形状匹配会和钳尖拉扯对抗，把边拉断；此时主要靠弹簧和边长限制。
	if hold_index < 0:
		_shape_match(xf, SHAPE_BETA)
	var iters := ITER + (6 if hold_index >= 0 else 0)
	for _it in iters:
		_solve_springs(n)
		_clamp_edges(MAX_STRETCH, n)
		if hold_index >= 0 and hold_index < n:
			_p[hold_index] = hold_pos
		# 每次迭代后把宫颈轻轻拉回，避免弹簧把它拽裂。
		if kind == "uterus":
			for i2 in SIDES * 2:
				if i2 == hold_index:
					continue
				_p[i2] = _p[i2].lerp(xf * _rest_ab[i2], 0.55)
	for _c in 8:
		_clamp_edges(MAX_STRETCH, n)
		if hold_index >= 0 and hold_index < n:
			_p[hold_index] = hold_pos
	for side in [0, 1]:
		_place_chain(side, dt)
	_rebuild_visual()
	_rebuild_adnex()


func _is_locked(i: int) -> bool:
	return i == hold_index or (kind == "uterus" and i < SIDES)


func _solve_springs(n: int) -> void:
	for sp2 in _springs:
		var i: int = sp2[0]
		var j: int = sp2[1]
		var rest: float = sp2[2]
		if i < 0 or j < 0 or i >= n or j >= n:
			continue
		var d := _p[j] - _p[i]
		var L := d.length()
		if L < 1e-8:
			continue
		var k := SPRING_K
		# 弯曲弹簧（隔点）稍软。
		if int(i / SIDES) + 2 == int(j / SIDES) or absi((i % SIDES) - (j % SIDES)) == 2 or absi((i % SIDES) - (j % SIDES)) == SIDES - 2:
			k = BEND_K
		var corr := (L - rest) / L * k
		var locked_i := _is_locked(i)
		var locked_j := _is_locked(j)
		if locked_i and locked_j:
			continue
		if locked_i:
			_p[j] -= d * corr
		elif locked_j:
			_p[i] += d * corr
		else:
			_p[i] += d * corr * 0.5
			_p[j] -= d * corr * 0.5


func _clamp_edges(max_ratio: float, n: int) -> void:
	for sp2 in _springs:
		var i: int = sp2[0]
		var j: int = sp2[1]
		var rest: float = float(sp2[2])
		if i < 0 or j < 0 or i >= n or j >= n or rest < 1e-6:
			continue
		var d := _p[j] - _p[i]
		var L := d.length()
		var lim := rest * max_ratio
		if L <= lim or L < 1e-8:
			continue
		var corr := (L - lim) / L
		if _is_locked(i) and not _is_locked(j):
			_p[j] -= d * corr
		elif _is_locked(j) and not _is_locked(i):
			_p[i] += d * corr
		else:
			_p[i] += d * corr * 0.5
			_p[j] -= d * corr * 0.5


func _polar_basis(A: Basis) -> Basis:
	var Q := A
	for _i in 5:
		if absf(Q.determinant()) < 1e-10:
			return A.orthonormalized()
		var invt := Q.inverse().transposed()
		Q = Basis((Q.x + invt.x) * 0.5, (Q.y + invt.y) * 0.5, (Q.z + invt.z) * 0.5)
	return Q.orthonormalized()


func _shape_match(xf: Transform3D, beta: float) -> void:
	# 把笼点拉向当前运动学姿态下的静止形状，保持体积、减少撕裂。
	if beta <= 1e-5 or _p.size() != _rest_ab.size() or _p.size() < 4:
		return
	var n := _p.size()
	var c_p := Vector3.ZERO
	var c_r := Vector3.ZERO
	for i in n:
		c_p += _p[i]
		c_r += xf * _rest_ab[i]
	c_p /= float(n)
	c_r /= float(n)
	var Ax := Vector3.ZERO
	var Ay := Vector3.ZERO
	var Az := Vector3.ZERO
	for i in n:
		var q: Vector3 = (xf * _rest_ab[i]) - c_r
		var pv: Vector3 = _p[i] - c_p
		Ax += pv * q.x
		Ay += pv * q.y
		Az += pv * q.z
	var R := _polar_basis(Basis(Ax, Ay, Az))
	for i in n:
		if _is_locked(i):
			continue
		var goal: Vector3 = c_p + R * ((xf * _rest_ab[i]) - c_r)
		_p[i] = _p[i].lerp(goal, beta)


func _skin_deform(rest: PackedVector3Array, bind_i: PackedInt32Array, bind_w: PackedVector3Array, nrm: PackedVector3Array, along: PackedFloat32Array = PackedFloat32Array()) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(rest.size())
	# 用当前运动学姿态作为绑定静止位，绕活体宫颈轻微放大。不能再相对体内原宫颈缩放，否则网格被撕向上方。
	var xf := _kinematic_xf(extract_charge if organ_active else 1.0)
	var cervix_w: Vector3 = cervix_world() if organ_active and not _p.is_empty() else xf * _cervix_ab
	var fund_w: Vector3 = fundus_world() if organ_active and not _p.is_empty() else xf * _fundus_ab
	var axis_w: Vector3 = fund_w - cervix_w
	if axis_w.length_squared() < 1e-8:
		axis_w = xf.basis * _axis_ab
	axis_w = axis_w.normalized()
	for vi in rest.size():
		var i0 := bind_i[vi * 3]
		var i1 := bind_i[vi * 3 + 1]
		var i2 := bind_i[vi * 3 + 2]
		var w: Vector3 = bind_w[vi]
		var r0: Vector3 = xf * _rest_ab[i0]
		var r1: Vector3 = xf * _rest_ab[i1]
		var r2: Vector3 = xf * _rest_ab[i2]
		var rest_w: Vector3 = xf * rest[vi]
		var delta := (_p[i0] - r0) * w.x + (_p[i1] - r1) * w.y + (_p[i2] - r2) * w.z
		var pw: Vector3 = rest_w + delta
		var rel := pw - cervix_w
		var along_c := axis_w * rel.dot(axis_w)
		var rad := rel - along_c
		pw = cervix_w + along_c + rad * PHYS_SCALE
		if not pw.is_finite():
			pw = rest_w
		out[vi] = pw
	return out


func _rebuild_mesh(am: ArrayMesh, verts: PackedVector3Array, nrm_rest: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array, along: PackedFloat32Array = PackedFloat32Array()) -> void:
	# 黑三角的主因是柔体 ArrayMesh 没有切线，而材质开了 NORMAL_MAP，TBN 变成 NaN。
	# 用 SurfaceTool 重算法线并生成切线；丢掉退化三角形。
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
	var verts := _skin_deform(_vis_rest, _bind_i, _bind_w, _vis_nrm, _vis_along)
	_rebuild_mesh(_am, verts, _vis_nrm, _vis_uv, _vis_idx, _vis_along)


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


func physical_size_ratio() -> float:
	if _vis_rest.is_empty() or _p.is_empty():
		return 1.0
	var verts := _skin_deform(_vis_rest, _bind_i, _bind_w, _vis_nrm, _vis_along)
	var rmin := Vector3(INF, INF, INF)
	var rmax := Vector3(-INF, -INF, -INF)
	var dmin := Vector3(INF, INF, INF)
	var dmax := Vector3(-INF, -INF, -INF)
	var n := 0
	for i in _vis_rest.size():
		var rw: Vector3 = _frame * _vis_rest[i]
		var dw: Vector3 = verts[i]
		rmin = rmin.min(rw)
		rmax = rmax.max(rw)
		dmin = dmin.min(dw)
		dmax = dmax.max(dw)
		n += 1
	if n < 8:
		return 1.0
	var rs := rmax - rmin
	var ds := dmax - dmin
	var rlen := (rs.x + rs.y + rs.z) / 3.0
	var dlen := (ds.x + ds.y + ds.z) / 3.0
	if rlen < 1e-5:
		return 1.0
	return dlen / rlen


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
	if not tube_chain_active(side):
		return false
	var rope: Node = (_chains[side] as Dictionary).get("rope")
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
	# 允许重力下垂，但不应该绕成环（偏离中线超过链长的 45% 且首尾距离很短）。
	return worst < L * 0.55 and L > 0.03


func ovary_at_chain_end(side: int) -> bool:
	if not tube_chain_active(side):
		return false
	var ch: Dictionary = _chains[side]
	var ov: MeshInstance3D = ch.get("ovary")
	var rope: Node = ch.get("rope")
	if ov == null or rope == null:
		return false
	var pts: PackedVector3Array = rope.call("points")
	if pts.is_empty():
		return false
	var tip: Vector3 = pts[pts.size() - 1]
	var head: Vector3 = pts[0]
	return ov.global_position.distance_to(tip) < 0.012 and ov.global_position.distance_to(head) > ov.global_position.distance_to(tip) + 0.01
