extends MeshInstance3D
## 0.4.12（t63u / t64u）：子宫 / 膀胱扯出改为真正的动态段链，不再沿固定轨道整体平移。
## - 宫体 6 节硬段（宫颈→宫底）+ 关节角度限制，带惯性与重力：快拖会被甩起，松手后在体外摆动、下垂。
## - 宫颈经一根可伸长的系带（阴道上段 + 韧带被拉长）连到盆腔深处的根点；系带跟肠子一样只从创口穿出。
## - 腹壁视作只在创口开洞的膜：每个质点记住在体内 / 体外，只能经创口进出，跨膜的段必须穿过洞口。
## - 夹点只驱动一个节点，其余靠约束和动量跟随；最远伸出受系带最大长度限制。
## - 出生时按原网格真实的世界变换（骨盆骨骼，而非腹部坐标系）重建静止姿态，与可见原子宫重合。
## - 原网格刚体蒙皮到段链，不撕裂；输卵管 / 卵巢是挂在宫角上的独立小链，在体外受重力下垂。

const SEGS := 6
const ITER := 14
## t82u：没被夹着、自由悬挂 / 摆动时的约束迭代数（宫体最后还有一遍刚性摆直 + FABRIK，少几遍看不出差别）。
const ITER_FREE := 8
const TUBE_ITER := 8
const TUBE_ITER_FREE := 5
const DAMP := 0.68              # 体内：周围组织托住，速度很快被吃掉
const AIR_DAMP := 0.988         # 体外：每步（60 Hz 基准）保留的速度，摆动几秒后才停
const TUBE_AIR_DAMP := 0.97
const GRAVITY := Vector3(0, -9.8, 0)
const PULL_SPEED := 0.22
const PUTBACK_SPEED := 0.16
const TUBE_LEVEL := 4
const LEVELS := 5
const MAX_BEND := 0.03          # 每个关节最多约 1.7°：宫体是硬的肌性器官，摆动来自系带；线性蒙皮几乎不拉伸
const MAX_STRETCH := 1.02
const MAX_SPEED := 6.0
const TUBE_PTS := 9
const TUBE_RADIUS := 0.0034
const PHYS_SCALE := 1.0         # 与原网格等大，出生时完全重合
const TETHER_N := 8             # 系带节点数（含根点）
const TETHER_MIN := 0.004
const OUT_EXTRA := 0.012        # t72u：宫颈最多伸出创口约 1.2 cm（整颗子宫仍可完全在体外，但不再挂得很远）
## t72u：系带只画创口内侧这一小段到宫颈（短的肉色阴道上段过渡），体内更深的部分不画。
const TRANSITION_IN := 0.012
const CERVIX_OUT_MAX := 0.02    # 体外宫颈 / 系带点离创口中心最远 2 cm
const TRANSITION_R := 0.0105
const TRANSITION_INNER_MIN := 0.004   # t99u：体内阴道顶端离入口不足此距离就不画体内段
const TRANSITION_INNER_N := 6         # 体内段采样数（不含入口）
const TRANSITION_EMBED := 0.006       # 体内段起点埋进阴道顶端的深度
const TRANSITION_CERV_EMBED := 0.004  # t105u：管末端插进宫颈尖的深度（此处宫颈外径 ≈ 管径）
const TRANSITION_STUMP_N := 6         # 外露断端采样段数
const TRANSITION_COLOR := Color(0.8038, 0.5382, 0.4751)
const HOLE_R := 0.020           # 创口洞半径（质点中线可偏离的范围）
const WALL_MARGIN := 0.004
const BODY_R := 0.016           # 体外宫体与皮肤的碰撞半径
const TETHER_R := 0.006
const IN_SPRING := 0.10
const TUBE_IN_SPRING := 0.35
## T-11：输卵管段最多拉长到静止长度的这个倍数（绳子硬上限，卵巢跟着走，不会被扯成细线）。
## t92u：输卵管是弹性管（不再是 1.04 的硬绳）：只抗拉、松弛时自然下垂；被钳子夹住拉远时
## 整体弹性伸长，最多到 TUBE_MAX_STRETCH（安全上限），松手后按 TUBE_STIFF 回弹到静长。
const TUBE_MAX_STRETCH := 1.6
const TUBE_STIFF := 0.9
## 不夹时的自重下垂上限（迭代次数有限，PBD 链在重力下会被「拉长」，这里兜住）；
## 松手后上限从当前伸长每帧回落 TUBE_RECOIL → 平滑回弹，而不是一下弹回。
const TUBE_FREE_STRETCH := 1.06
const TUBE_RECOIL := 0.035
## 管长 = 宫角→卵巢直线距离 × TUBE_LEN_MUL（至少 TUBE_LEN_MIN），静止时呈自然弧形。
const TUBE_LEN_MUL := 1.7
const TUBE_LEN_MIN := 0.045
## 管头：p0 嵌在宫角表面内 TUBE_EMBED，p1 沿宫角表面法线伸出 TUBE_STEM —— 管子从表面那一点直接长出来。
const TUBE_EMBED := 0.0022
const TUBE_STEM := 0.004
const BODY_STIFF := 1.0         # 形状匹配比例：宫体整体是刚体（摆动 / 甩动来自系带），蒙皮边长不变
const BODY_W := 0.35            # 宫体节点相对系带节点的逆质量
const SKIN_CELL := 0.02
const PUTBACK_TIMEOUT := 8.0

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
## t82u：悬挂点 = 创口中心 + hang_offset（手术每帧给出：创口下缘、靠耻骨一侧）。宫颈 / 阴道过渡拴在这里，
## 而不是创口正中（切口在肚脐附近时子宫被挂得太高）。洞口判定仍用 wound_center。
var hang_offset: Vector3 = Vector3.ZERO
## t82u：取出后体外的宫体节点保持在体外（不再被系带 / 碰撞拽回创口里），只有「放回」才收回。
const BODY_CLEAR := 0.016       # 体外宫体节点离创口平面至少这么远（≈ 宫体半厚），网格不陷进腹腔
const CERVIX_CLEAR := 0.008     # 宫颈节点（接过渡段）
const CLEAR_FADE := 0.03        # 离洞口远处改由皮肤碰撞接管，这段距离内平滑过渡
var hold_index: int = -1
var hold_pos: Vector3 = Vector3.ZERO
## T-11：拿取工具「只拖不扯」：系带不再伸长、夹点不回到腹壁内、扯出档位冻结。
var hold_no_feed: bool = false
var _nf_reach: float = 0.0
var _nf_charge: float = -1.0
var last_step_usec: int = 0
var _asleep := false
var _quiet_frames := 0
const SLEEP_QUIET := 20
var _sleep_vis_ok := false

var _rest_ab: PackedVector3Array = PackedVector3Array()
var _p: PackedVector3Array = PackedVector3Array()   # 宫体节点（只读视图，供拾取 / 测试）
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

# 合并质点：[0, TETHER_N) 系带（0 = 根点），[TETHER_N, TETHER_N + SEGS) 宫体
var _x: PackedVector3Array = PackedVector3Array()
var _xq: PackedVector3Array = PackedVector3Array()
var _st: PackedByteArray = PackedByteArray()       # 0 = 体内，1 = 体外
var _tlen: float = TETHER_MIN
var _drag_off: Vector3 = Vector3.ZERO
var _drv_i: int = -1
var _drv_pos: Vector3 = Vector3.ZERO
var _putback_t: float = 0.0

# 未校正的原始静止数据（网格局部 - 肚脐），出扯时按原网格实际世界变换重建
var _raw_vis: PackedVector3Array = PackedVector3Array()
var _raw_cervix: Vector3 = Vector3.ZERO
var _raw_fundus: Vector3 = Vector3.ZERO
var _raw_horn: Array = [Vector3.ZERO, Vector3.ZERO]
var _src_mi: MeshInstance3D = null
var _corr: Transform3D = Transform3D.IDENTITY
var _raw_tan: PackedFloat32Array = PackedFloat32Array()
var _skel: Skeleton3D = null
var _skin_res: Skin = null

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
var _tubes: Dictionary = {}       # side -> {p, q, st, rest_u}
var _early: Dictionary = {}
var _mat: ShaderMaterial = null
var _tube_mat: ShaderMaterial = null
var _has_pull_target := false
var _pull_target: Vector3 = Vector3.ZERO
var _ovary_rest_ab_cache: Array = [Vector3.ZERO, Vector3.ZERO]
var _ovary_basis: Array = [Basis.IDENTITY, Basis.IDENTITY]
var _ovary_centered: Dictionary = {}
var _tether_node: Node = null
var _grid: Dictionary = {}


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _am == null:
		_am = ArrayMesh.new()
		mesh = _am
	add_to_group(HangGrab.GROUP)


# ---------------------------------------------------------------- t96u 悬垂器官共享抓取接口（HangGrab）
## 体外的宫体节点（悬挂 / 甩动中）和已成悬链的输卵管 / 卵巢都能被普通互动工具抓住拖动；
## 宫体用 T-11 拿取工具同一套「只拖已在体外的部分」限制，不会再扯出更多，也不会被推回。
var _hg_part := ""
var _hg_side := -1


func hang_pick(origin: Vector3, dir: Vector3) -> Dictionary:
	if not organ_active or retracting or not visible and not external_drive:
		return {}
	var d := dir.normalized()
	var best := {}
	var best_t := INF
	if not external_drive and is_extracted():
		for bi in _p.size():
			if not node_outside(bi):
				continue
			var w := _p[bi] - origin
			var t := w.dot(d)
			if t <= 0.0:
				continue
			var pp := (w - d * t).length()
			if pp < BODY_R + 0.008 and t < best_t:
				best_t = t
				best = {"t": t, "point": origin + d * t, "anchor": _p[bi], "part": "body", "idx": bi, "score": pp / (BODY_R + 0.008)}
	if kind == "uterus":
		for side in [0, 1]:
			var rope := _chain_node(side)
			if rope == null or not rope.is_visible_in_tree():
				continue
			if not tube_chain_active(side) and not is_extracted() and not external_drive:
				continue
			var pk: Array = rope.call("ray_pick", origin, d)
			var idx := int(pk[0])
			if idx < 0 or float(pk[1]) > 0.010:
				continue
			var pts: PackedVector3Array = rope.call("points")
			if idx >= pts.size():
				continue
			# 只抓体外那段（还在腹腔里的输卵管不拿）。
			var tbp: Dictionary = _tubes.get(side, {})
			if not tbp.is_empty() and idx < (tbp["st"] as PackedByteArray).size() and (tbp["st"] as PackedByteArray)[idx] == 0 and not external_drive:
				continue
			var t2 := (pts[idx] - origin).dot(d)
			# 细管优先：射线明显对准输卵管 / 卵巢（相对容差更准）时选管，而不是旁边粗的宫体。
			var sc := float(pk[1]) / 0.010
			if t2 > 0.0 and (best.is_empty() or t2 < best_t + 0.004 or (sc < 0.5 and sc < float(best.get("score", 1.0)) * 0.6)):
				best_t = t2
				best = {"t": t2, "point": origin + d * t2, "anchor": pts[idx], "part": "tube", "side": side, "idx": idx, "score": sc}
	return best


func hang_grab(hit: Dictionary, origin: Vector3, dir: Vector3) -> bool:
	hang_release()
	match str(hit.get("part", "")):
		"body":
			if not hold_particle_swing(int(hit["idx"]), hit["anchor"]):
				return false
			_hg_part = "body"
		"tube":
			var side := int(hit["side"])
			if not chain_hold(side, origin, dir):
				return false
			_hg_part = "tube"
			_hg_side = side
		_:
			return false
	return true


func hang_drag(target: Vector3) -> void:
	match _hg_part:
		"body":
			if hold_index >= 0:
				hold_particle(hold_index, target)
				hold_no_feed = true
		"tube":
			chain_drag(_hg_side, target)


func hang_release() -> void:
	match _hg_part:
		"body":
			release_hold()
		"tube":
			chain_release(_hg_side)
	_hg_part = ""
	_hg_side = -1


func hang_grab_part() -> String:
	return _hg_part


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
	var vi := int(_horn_vi[side])
	if vi >= 0 and vi < _vis_rest.size():
		return _skin_vertex(vi)
	if _bone.is_empty() or _rest_bone.is_empty():
		return _frame * (_horn_ab[side] as Vector3) + _drag_off
	return _xform_rest(_horn_ab[side] as Vector3)


## t92u：宫角附着点 = 宫角处真实可见网格上的一个顶点（随 GPU 蒙皮同样的两骨混合移动），
## 法线 = 该处表面外法线（同样随骨骼旋转）。输卵管从这一点垂直长出，所以每帧都与子宫表面重合相连。
var _horn_vi: Array = [-1, -1]
var _horn_n_ab: Array = [Vector3.RIGHT, Vector3.LEFT]
var _tube_bulge: Array = [0.0, 0.0]
## 每个管点在弧上的参数（按等弧长取样，保证各节静长相等）。
var _tube_tk: Array = [PackedFloat32Array(), PackedFloat32Array()]
var _tube_lim: Array = [TUBE_FREE_STRETCH, TUBE_FREE_STRETCH]


func _bind_horns() -> void:
	_horn_vi = [-1, -1]
	if _vis_rest.is_empty():
		return
	var cb := _corr.basis
	for side in 2:
		var h: Vector3 = _horn_ab[side]
		var best := -1
		var bd := 1e9
		for i in _vis_rest.size():
			var dd := _vis_rest[i].distance_squared_to(h)
			if dd < bd:
				bd = dd
				best = i
		if best < 0:
			continue
		var c := _vis_rest[best]
		var nsum := Vector3.ZERO
		for j in _vis_rest.size():
			if _vis_rest[j].distance_squared_to(c) < 0.006 * 0.006 and j < _vis_nrm.size():
				nsum += (cb * _vis_nrm[j]).normalized()
		# 法线必须朝外（远离子宫轴线）。
		var t := clampf((c - _cervix_ab).dot(_axis_ab), 0.0, _rest_len)
		var lat := c - (_cervix_ab + _axis_ab * t)
		if nsum.length_squared() < 1e-10:
			nsum = lat
		nsum = nsum.normalized()
		if lat.length_squared() > 1e-10 and nsum.dot(lat) < 0.0:
			nsum = -nsum
		_horn_vi[side] = best
		_horn_n_ab[side] = nsum


func _skin_vertex(vi: int) -> Vector3:
	if _bone.is_empty() or _rest_bone.is_empty() or vi >= _bind_seg.size():
		return _frame * _vis_rest[vi] + _drag_off
	var sg := _bind_seg[vi]
	var s1 := mini(sg + 1, SEGS - 1)
	var tw := _bind_t[vi]
	var r := _vis_rest[vi]
	var a: Vector3 = (_bone[sg] as Transform3D) * ((_rest_bone[sg] as Transform3D).affine_inverse() * r)
	var b: Vector3 = (_bone[s1] as Transform3D) * ((_rest_bone[s1] as Transform3D).affine_inverse() * r)
	return a.lerp(b, tw)


## 宫角表面外法线（世界坐标）。
func horn_normal_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	var n_ab: Vector3 = _horn_n_ab[side]
	var vi := int(_horn_vi[side])
	if _bone.is_empty() or _rest_bone.is_empty() or vi < 0 or vi >= _bind_seg.size():
		return (_frame.basis * n_ab).normalized()
	var sg := _bind_seg[vi]
	var s1 := mini(sg + 1, SEGS - 1)
	var na: Vector3 = (_bone[sg] as Transform3D).basis * ((_rest_bone[sg] as Transform3D).basis.inverse() * n_ab)
	var nb: Vector3 = (_bone[s1] as Transform3D).basis * ((_rest_bone[s1] as Transform3D).basis.inverse() * n_ab)
	var nn := na.lerp(nb, _bind_t[vi])
	return nn.normalized() if nn.length_squared() > 1e-12 else Vector3.RIGHT


## 管头两个点（嵌入点、表面外第一点），每帧钉死在宫角表面上。
func _tube_head_pts(side: int) -> Array:
	var a := horn_world(side)
	var nn := horn_normal_world(side)
	return [a - nn * TUBE_EMBED, a + nn * TUBE_STEM]


func tube_chain_active(side: int) -> bool:
	var ch: Variant = _chains.get(side, null)
	return ch is Dictionary and bool((ch as Dictionary).get("active", false))


func any_tube_chain() -> bool:
	return tube_chain_active(0) or tube_chain_active(1)


## 系带（阴道上段 + 韧带）当前的节点，0 为盆腔根点，最后接宫颈。
func tether_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in mini(TETHER_N, _x.size()):
		out.append(_x[i])
	if not _p.is_empty():
		out.append(_p[0])
	return out


func tether_length() -> float:
	return _tlen


## t72u：创口外露的过渡断端（创口内侧 TRANSITION_IN 处 → 宫颈）的点；系带全在深处时为空。
func transition_stump_points() -> PackedVector3Array:
	var pts := tether_points()
	var out := PackedVector3Array()
	if pts.size() < 2:
		return out
	var lim := -TRANSITION_IN
	var start := -1
	for i in pts.size():
		if (pts[i] - wound_center).dot(outward) >= lim:
			start = i
			break
	if start < 0:
		return out
	# 入口固定在创口中心正下方 TRANSITION_IN 处：断端从创口里伸出来。
	var hang := hang_point()
	var entry := hang - outward * TRANSITION_IN
	# t105u：入口 → 宫颈的平滑三次曲线：从创口垂直出来，沿宫颈轴线（宫颈 → 宫底）插进宫颈，
	# 末端在宫颈尖往宫体里 TRANSITION_CERV_EMBED 处（管径 ≈ 那里的宫颈外径），宫颈口的开口边被管口包住，
	# 不再从侧面斜着碰到宫颈、旁边露出一个圆帽和撕裂的宫颈断面。纯视觉，物理点不变。
	var tip := cervix_join_world()
	var ax := cervix_axis_world()
	var span := entry.distance_to(tip)
	var c1 := entry + outward * (span * 0.4)
	var c2 := tip - ax * (span * 0.45)
	out.append(entry)
	for k in range(1, TRANSITION_STUMP_N):
		var t := float(k) / float(TRANSITION_STUMP_N)
		var u := 1.0 - t
		out.append(entry * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + tip * (t * t * t))
	out.append(tip)
	return out


## t105u：宫颈轴线（世界，宫颈 → 宫底方向），取渲染骨骼 0 的轴，与蒙皮网格一致。
func cervix_axis_world() -> Vector3:
	if not _bone.is_empty():
		return ((_bone[0] as Transform3D).basis.z).normalized()
	if _p.size() >= 2 and _p[0].distance_squared_to(_p[1]) > 1e-12:
		return (_p[1] - _p[0]).normalized()
	return (_frame.basis * _axis_ab).normalized()


## t105u：阴道过渡管接到宫颈的位置（世界）：宫颈尖沿轴往里 TRANSITION_CERV_EMBED，按蒙皮网格同一变换。
func cervix_join_world() -> Vector3:
	return _xform_rest(_cervix_ab + _axis_ab * TRANSITION_CERV_EMBED)


## t99u：体内段（纯视觉）——从体内阴道（canal 着色器拉到的顶端 canal_os_world）沿阴道方向
## 平滑弯到创口入口，与外露断端相切连接，悬挂的阴道管看起来接着体内阴道，而不是从腹壁里冒出来。
## 不改任何物理量：只读系带 / 宫颈 / 创口数据。
func transition_inner_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	var stump := transition_stump_points()
	if stump.size() < 2 or _x.size() < TETHER_N:
		return out
	var entry := stump[0]
	var apex := canal_os_world()
	var span := apex.distance_to(entry)
	if span < TRANSITION_INNER_MIN:
		return out
	# 阴道顶端的走向：canal 着色器只平移阴道上端，顶端切向 = 通道轴（外口 → 宫颈，由 surgery_system 给）；
	# 没给时用静止根点 → 被拉出的顶端；再退化就直接朝入口。
	var vdir := _frame.basis * vagina_axis_ab
	if vdir.length_squared() < 1e-8:
		vdir = apex - (_frame * _raw_cervix + _drag_off)
	if vdir.length_squared() < 1e-8:
		vdir = entry - apex
	vdir = vdir.normalized()
	var to_e := (entry - apex) / span
	if vdir.dot(to_e) < 0.0:
		vdir = (vdir - to_e * 2.0 * vdir.dot(to_e)).normalized()
	var sdir := stump[1] - stump[0]
	sdir = sdir.normalized() if sdir.length_squared() > 1e-10 else outward
	# 起点埋进阴道顶端一点，管口藏在阴道网格里。
	var p0 := apex - vdir * TRANSITION_EMBED
	var c1 := apex + vdir * (span * 0.4)
	var c2 := entry - sdir * (span * 0.35)
	out.append(p0)
	for k in TRANSITION_INNER_N:
		var t := float(k) / float(TRANSITION_INNER_N)
		var u := 1.0 - t
		out.append(apex * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + entry * (t * t * t))
	return out


## 真正画出来的阴道过渡管：体内阴道顶端 → 创口入口 → 宫颈（视觉）。
func transition_points() -> PackedVector3Array:
	var stump := transition_stump_points()
	if stump.is_empty():
		return stump
	var out := transition_inner_points()
	out.append_array(stump)
	return out


## 外露断端长度（创口入口 → 宫颈），体内段不计。
func transition_length() -> float:
	var pts := transition_stump_points()
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i - 1].distance_to(pts[i])
	return l


func set_transition_color(c: Color) -> void:
	if _tether_node and is_instance_valid(_tether_node):
		var m := (_tether_node as GeometryInstance3D).material_override as StandardMaterial3D
		if m:
			m.albedo_color = c
	_transition_color = c


var _transition_color := TRANSITION_COLOR
## t99u：体内阴道通道轴（腹部坐标，外口 → 宫颈）；只用于画体内过渡段。
var vagina_axis_ab := Vector3.ZERO


func hang_point() -> Vector3:
	return wound_center + hang_offset


func tether_max_length() -> float:
	return _wound_depth() + OUT_EXTRA


func root_world() -> Vector3:
	return _frame * _cervix_ab + _drag_off


## 阴道宫颈端应该跟随的位置（世界坐标，已换回 canal 着色器使用的腹部坐标约定）。
## 阴道只被系带带出一小段（≤ 2 cm），其余由系带管子表现，不再把整条阴道拉成一根怪管。
func canal_os_world() -> Vector3:
	var root := root_world()
	var tgt := root
	if _x.size() >= TETHER_N:
		var want := minf(_tlen, 0.02)
		var acc := 0.0
		tgt = _x[0]
		for i in range(1, TETHER_N):
			var seg := _x[i - 1].distance_to(_x[i])
			if acc + seg >= want and seg > 1e-6:
				tgt = _x[i - 1].lerp(_x[i], (want - acc) / seg)
				break
			acc += seg
			tgt = _x[i]
	# canal 着色器的静止宫颈在腹部坐标约定下（未做骨骼校正）。
	var raw_root := _frame * _raw_cervix + _drag_off
	return tgt + (raw_root - root)


func setup(p_kind: String, frame: Transform3D, navel: Vector3, main_meshes: Array, adnex_meshes: Array, cervix_rest: Vector3, fundus_rest: Vector3, horns: Array) -> void:
	kind = p_kind
	_frame = frame
	_prev_frame = frame
	_has_prev_frame = false
	_navel = navel
	_src = main_meshes.duplicate()
	_adnex_src = adnex_meshes.duplicate()
	_raw_cervix = cervix_rest - navel
	_raw_fundus = fundus_rest - navel
	_raw_horn = [Vector3.ZERO, Vector3.ZERO]
	for i in mini(2, horns.size()):
		_raw_horn[i] = (horns[i] as Vector3) - navel
	_raw_vis = PackedVector3Array()
	_raw_tan = PackedFloat32Array()
	_vis_nrm = PackedVector3Array()
	_vis_uv = PackedVector2Array()
	_vis_idx = PackedInt32Array()
	_src_mi = null
	for mi in main_meshes:
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		if _src_mi == null:
			_src_mi = m
		if _mat == null and m.material_override is ShaderMaterial:
			_mat = (m.material_override as ShaderMaterial).duplicate() as ShaderMaterial
			_mat.set_shader_parameter("is_uterus", false)
			_mat.set_shader_parameter("is_gut", false)
		_append_surface(m.mesh, navel, _raw_vis, _vis_nrm, _vis_uv, _vis_idx)
	if _mat:
		material_override = _mat
		_mat.set_meta("soft_organ", kind)
	_prepare_tube_mat()
	_rebase()
	_inited = true
	visible = false


## 原子宫挂在骨盆骨骼上（MeshInstance 的全局变换），与腹部坐标系 _frame 并不一致；
## 这里求出 C = _frame⁻¹ · G · T(navel)，把所有静止数据换成「腹部坐标下真实可见的位置」。
func _rebase() -> void:
	_corr = Transform3D.IDENTITY
	if _src_mi != null and is_instance_valid(_src_mi) and _src_mi.is_inside_tree():
		_corr = _frame.affine_inverse() * _src_mi.global_transform * Transform3D(Basis.IDENTITY, _navel)
	_cervix_ab = _corr * _raw_cervix
	_fundus_ab = _corr * _raw_fundus
	_axis_ab = _fundus_ab - _cervix_ab
	_rest_len = maxf(_axis_ab.length(), 0.03)
	if _axis_ab.length_squared() < 1e-8:
		_axis_ab = Vector3(0, 1, 0)
	else:
		_axis_ab = _axis_ab.normalized()
	_horn_ab = [_corr * (_raw_horn[0] as Vector3), _corr * (_raw_horn[1] as Vector3)]
	_vis_rest.resize(_raw_vis.size())
	for i in _raw_vis.size():
		_vis_rest[i] = _corr * _raw_vis[i]
	_build_spine()
	_bind_visual()
	_build_skinned_mesh()
	_cache_ovary_rest()
	_bind_horns()


## 原网格做成 GPU 蒙皮网格（顶点在校正后的腹部坐标，绑定 = 静止骨骼的逆），
## 每帧只写 6 根骨骼的姿态，不再每帧用 SurfaceTool 重建几千个顶点。
func _build_skinned_mesh() -> void:
	if _vis_rest.is_empty():
		return
	if _am == null:
		_am = ArrayMesh.new()
	mesh = _am
	var n := _vis_rest.size()
	var nrm := PackedVector3Array()
	nrm.resize(n)
	var tan := PackedFloat32Array()
	tan.resize(n * 4)
	var bones := PackedInt32Array()
	bones.resize(n * 4)
	var wts := PackedFloat32Array()
	wts.resize(n * 4)
	var cb := _corr.basis
	for i in n:
		var nn: Vector3 = (cb * (_vis_nrm[i] if i < _vis_nrm.size() else Vector3.UP)).normalized()
		nrm[i] = nn
		var tt := Vector3(_raw_tan[i * 4], _raw_tan[i * 4 + 1], _raw_tan[i * 4 + 2]) if _raw_tan.size() >= (i + 1) * 4 else Vector3.RIGHT
		tt = (cb * tt).normalized()
		tan[i * 4] = tt.x
		tan[i * 4 + 1] = tt.y
		tan[i * 4 + 2] = tt.z
		tan[i * 4 + 3] = _raw_tan[i * 4 + 3] if _raw_tan.size() >= (i + 1) * 4 else 1.0
		var sg := _bind_seg[i]
		var tw := _bind_t[i]
		bones[i * 4] = sg
		bones[i * 4 + 1] = mini(sg + 1, SEGS - 1)
		bones[i * 4 + 2] = 0
		bones[i * 4 + 3] = 0
		wts[i * 4] = 1.0 - tw
		wts[i * 4 + 1] = tw
		wts[i * 4 + 2] = 0.0
		wts[i * 4 + 3] = 0.0
	# 去掉静止网格里本来就退化的三角（以前的黑三角来源）。
	var idx := PackedInt32Array()
	for f in range(0, _vis_idx.size() - 2, 3):
		var ia := _vis_idx[f]
		var ib := _vis_idx[f + 1]
		var ic := _vis_idx[f + 2]
		if ia < 0 or ib < 0 or ic < 0 or ia >= n or ib >= n or ic >= n:
			continue
		if (_vis_rest[ib] - _vis_rest[ia]).cross(_vis_rest[ic] - _vis_rest[ia]).length_squared() < 1e-16:
			continue
		idx.append_array([ia, ib, ic])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _vis_rest
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_TANGENT] = tan
	arr[Mesh.ARRAY_TEX_UV] = _vis_uv
	arr[Mesh.ARRAY_BONES] = bones
	arr[Mesh.ARRAY_WEIGHTS] = wts
	arr[Mesh.ARRAY_INDEX] = idx
	_am.clear_surfaces()
	_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if _mat:
		_am.surface_set_material(0, _mat)
	if _skel == null or not is_instance_valid(_skel):
		_skel = Skeleton3D.new()
		_skel.name = "UterusSkeleton"
		add_child(_skel)
		for b in SEGS:
			_skel.add_bone("seg%d" % b)
	_skin_res = Skin.new()
	for b2 in SEGS:
		_skin_res.add_bind(b2, (_rest_bone[b2] as Transform3D).affine_inverse())
	skin = _skin_res
	skeleton = get_path_to(_skel) if is_inside_tree() else NodePath("UterusSkeleton")
	extra_cull_margin = 2.0


func spawn_offset() -> Dictionary:
	## 柔体网格与可见原网格（按其真实全局变换）之间的偏差，出生时应约为 0。
	var out := {"centroid_mm": 0.0, "max_mm": 0.0, "axis_deg": 0.0}
	if _src_mi == null or not is_instance_valid(_src_mi) or _raw_vis.is_empty():
		return out
	var verts := _skin_all()
	var ca := Vector3.ZERO
	var cb := Vector3.ZERO
	var mx := 0.0
	var gx := _src_mi.global_transform
	for i in verts.size():
		var orig: Vector3 = gx * (_raw_vis[i] + _navel)
		ca += verts[i]
		cb += orig
		mx = maxf(mx, verts[i].distance_to(orig))
	ca /= float(verts.size())
	cb /= float(verts.size())
	out["centroid_mm"] = ca.distance_to(cb) * 1000.0
	out["max_mm"] = mx * 1000.0
	var ax_now := (fundus_world() - cervix_world()).normalized()
	var ax_orig := (gx * (_raw_fundus + _navel) - gx * (_raw_cervix + _navel)).normalized()
	out["axis_deg"] = rad_to_deg(acos(clampf(ax_now.dot(ax_orig), -1.0, 1.0)))
	return out


func _append_surface(msh: Mesh, navel: Vector3, rest: PackedVector3Array, nrm: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array) -> void:
	var arr: Array = msh.surface_get_arrays(0)
	var P: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var N: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var U: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var I: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var T: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT] if arr[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var base := rest.size()
	for i in P.size():
		if T.size() >= (i + 1) * 4:
			_raw_tan.append_array([T[i * 4], T[i * 4 + 1], T[i * 4 + 2], T[i * 4 + 3]])
		else:
			var nn: Vector3 = N[i] if i < N.size() else Vector3.UP
			var tt := nn.cross(Vector3.UP if absf(nn.y) < 0.9 else Vector3.RIGHT).normalized()
			_raw_tan.append_array([tt.x, tt.y, tt.z, 1.0])
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
	_tubes = {}
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
		var c := acc / float(P.size())
		if m.is_inside_tree():
			# 卵巢同样按它真实的全局变换取位置。
			_ovary_rest_ab_cache[side] = _frame.affine_inverse() * (m.global_transform * c)
			_ovary_basis[side] = m.global_transform.basis
		else:
			_ovary_rest_ab_cache[side] = c - _navel


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
		_drag_off = Vector3.ZERO
		_rebase()
		_hide_sources(true)
		_init_particles()
		extract_charge = 1.0
		retracting = false
		organ_active = true
		visible = true
		_has_pull_target = false
		_putback_t = 0.0
		_rebuild_visual()
		_ensure_tubes()
		_ensure_tether_mesh()


func _hide_sources(hide: bool) -> void:
	for mi in _src:
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).visible = not hide
	for mi2 in _adnex_src:
		if mi2 != null and is_instance_valid(mi2):
			(mi2 as MeshInstance3D).visible = not hide


func _rest_world(bi: int) -> Vector3:
	return _frame * _rest_ab[bi] + _drag_off


func _init_particles() -> void:
	var nb := TETHER_N + SEGS
	_x.resize(nb)
	_xq.resize(nb)
	_st.resize(nb)
	var root := root_world()
	for i in TETHER_N:
		_x[i] = root
		_xq[i] = root
		_st[i] = 0
	for b in SEGS:
		var pw := _rest_world(b)
		_x[TETHER_N + b] = pw
		_xq[TETHER_N + b] = pw
		_st[TETHER_N + b] = 0
	_tlen = TETHER_MIN
	_sync_body()
	_bone = []
	_update_bones()


func _sync_body() -> void:
	_p.resize(SEGS)
	_q.resize(SEGS)
	for b in SEGS:
		_p[b] = _x[TETHER_N + b]
		_q[b] = _xq[TETHER_N + b]


func add_charge(strength: float, dt: float) -> void:
	## 无钳子时的「持续拉」：一个虚拟夹点拽着宫底先走向创口、再向外，其余部分靠物理跟上。
	if not organ_active or retracting:
		return
	dt = minf(maxf(dt, 0.0), 0.2)
	var dist := clampf(strength, 0.0, 1.5) * PULL_SPEED * dt
	if dist <= 1e-8:
		return
	if _x.size() != TETHER_N + SEGS:
		_init_particles()
	var cur: Vector3 = _pull_target if _has_pull_target else fundus_world()
	var rel := cur - wound_center
	var outd := rel.dot(outward)
	var desired := cur
	var to_move := dist
	if outd < 0.006:
		var tgt := hang_point() + outward * 0.008
		var d := tgt - cur
		var L := d.length()
		if L > 1e-6:
			var stp := minf(to_move, L)
			desired += d * (stp / L)
			to_move -= stp
	if to_move > 0.0:
		desired += outward * to_move
	_pull_target = _reach_clamp(SEGS - 1, desired, outd >= 0.0)
	_has_pull_target = true


func start_putback() -> void:
	if not organ_active:
		return
	retracting = true
	hold_index = -1
	_has_pull_target = false
	hold_no_feed = false
	_nf_charge = -1.0
	_putback_t = 0.0


func force_reset() -> void:
	extract_charge = 0.0
	retracting = false
	organ_active = false
	hold_index = -1
	_has_pull_target = false
	hold_no_feed = false
	_nf_charge = -1.0
	visible = false
	_hide_sources(false)
	_clear_chains()
	_early = {0: false, 1: false}
	_p = PackedVector3Array()
	_q = PackedVector3Array()
	_x = PackedVector3Array()
	_xq = PackedVector3Array()
	_st = PackedByteArray()
	_tlen = TETHER_MIN
	_drag_off = Vector3.ZERO
	_has_prev_frame = false
	if _tether_node and is_instance_valid(_tether_node):
		_tether_node.queue_free()
	_tether_node = null


func detach_adnexa(side: int) -> bool:
	if kind != "uterus" or not organ_active:
		return false
	side = clampi(side, 0, 1)
	_early[side] = true
	_ensure_tubes()
	var ch: Dictionary = _chains.get(side, {})
	ch["active"] = true
	_chains[side] = ch
	return true


func rebind_adnexa() -> void:
	_clear_chains()
	_early = {0: false, 1: false}
	if organ_active:
		_ensure_tubes()


func _horn_is_out(side: int) -> bool:
	var h := horn_world(side)
	return (h - wound_center).dot(outward) > -0.006


func _ovary_rest_ab(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	return _ovary_rest_ab_cache[side] as Vector3


func ovary_world(side: int) -> Vector3:
	side = clampi(side, 0, 1)
	var tb: Dictionary = _tubes.get(side, {})
	if not tb.is_empty():
		var tp: PackedVector3Array = tb["p"]
		if not tp.is_empty():
			return tp[tp.size() - 1]
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


## 宫底到皮肤 / 创口平面的有符号距离（米，正 = 体外）。
func fundus_skin_distance() -> float:
	var f := fundus_world()
	var sd := (f - wound_center).dot(outward)
	if not skin_p.is_empty() and _st.size() == TETHER_N + SEGS and _st[TETHER_N + SEGS - 1] == 1:
		var sh := _skin_h(f)
		if float(sh[0]) < 1e8:
			return maxf(sd, float(sh[0])) if sd > 0.0 else sd
	return sd


func body_out_count() -> int:
	var c := 0
	for b in SEGS:
		if _st.size() > TETHER_N + b and _st[TETHER_N + b] == 1:
			c += 1
	return c


func node_outside(bi: int) -> bool:
	return _st.size() > TETHER_N + bi and _st[TETHER_N + bi] == 1


func tube_head_gap(side: int) -> float:
	if kind != "uterus":
		return 0.0
	var rope := _chain_node(side)
	if rope == null or not rope.has_method("head"):
		return 0.0
	# t92u：管头（嵌入点）与第一节（表面外点）都要和宫角表面附着点重合。
	var hp := _tube_head_pts(side)
	var tb: Dictionary = _tubes.get(side, {})
	var g := (rope.call("head") as Vector3).distance_to(hp[0])
	if not tb.is_empty() and (tb["p"] as PackedVector3Array).size() >= 2:
		g = maxf(g, (tb["p"] as PackedVector3Array)[1].distance_to(hp[1]))
	return g


## 输卵管当前总长 / 静长。
func tube_stretch(side: int) -> float:
	var tb: Dictionary = _tubes.get(side, {})
	if tb.is_empty():
		return 1.0
	var p: PackedVector3Array = tb["p"]
	var rest: PackedFloat32Array = tb["rest"]
	var L := 0.0
	var R := 0.0
	for k in range(1, p.size() - 1):
		L += p[k].distance_to(p[k + 1])
		R += rest[k]
	return L / maxf(R, 1e-6)


func tube_rest_length(side: int) -> float:
	var tb: Dictionary = _tubes.get(side, {})
	if tb.is_empty():
		return 0.0
	var R := 0.0
	for r in (tb["rest"] as PackedFloat32Array):
		R += r
	return R


func ovary_tip_gap(side: int) -> float:
	var rope := _chain_node(side)
	if rope and rope.has_method("tip"):
		var ch: Dictionary = _chains.get(side, {})
		var ov: MeshInstance3D = ch.get("ovary")
		if ov and is_instance_valid(ov):
			return ov.global_position.distance_to(rope.call("tip"))
	return 0.0


func _chain_node(side: int) -> Node:
	var ch: Variant = _chains.get(clampi(side, 0, 1), null)
	if ch is Dictionary:
		var r = (ch as Dictionary).get("rope")
		if r != null and is_instance_valid(r):
			return r
	return null


# ---------------------------------------------------------------- 输卵管 / 卵巢小链

## t92u：静止姿态 = 宫角表面点 → 沿法线伸出 → 一段向外鼓的弧到卵巢（弧长 = 管静长，管子不再被拉直）。
func _tube_rest_world(side: int, k: int, n: int) -> Vector3:
	var hp := _tube_head_pts(side)
	if k <= 0:
		return hp[0]
	if k == 1:
		return hp[1]
	var p1: Vector3 = hp[1]
	var ovp := _xform_rest(_ovary_rest_ab(side))
	var tk: PackedFloat32Array = _tube_tk[side]
	var t := tk[k] if k < tk.size() else float(k - 1) / float(n - 2)
	return _tube_arc(p1, ovp, horn_normal_world(side), float(_tube_bulge[side]), t)


func _tube_arc(a: Vector3, b: Vector3, nn: Vector3, h: float, t: float) -> Vector3:
	var ax := b - a
	var bd := nn - (ax.normalized() * nn.dot(ax.normalized()) if ax.length_squared() > 1e-10 else Vector3.ZERO)
	if bd.length_squared() < 1e-8:
		bd = Vector3.DOWN
	return a.lerp(b, t) + bd.normalized() * (h * sin(PI * t))


func _arc_len(a: Vector3, b: Vector3, nn: Vector3, h: float, segs: int) -> float:
	var L := 0.0
	var prev := a
	for i in range(1, segs + 1):
		var c := _tube_arc(a, b, nn, h, float(i) / float(segs))
		L += prev.distance_to(c)
		prev = c
	return L


func _ensure_tubes() -> void:
	if kind != "uterus" or not organ_active:
		return
	for side in [0, 1]:
		var rope := _chain_node(side)
		if rope == null:
			rope = AdnexaChain.new()
			rope.name = "AdnexaChain%d" % side
			if _tube_mat:
				rope.use_organ_material(_tube_mat)
			add_child(rope)
			rope.setup_line(horn_world(side), _xform_rest(_ovary_rest_ab(side)), TUBE_PTS)
			rope.set("horn_embed", TUBE_EMBED)
			var ov := _make_ovary_blob(side)
			add_child(ov)
			var ch_old: Dictionary = _chains.get(side, {})
			_chains[side] = {"active": bool(ch_old.get("active", false)), "rope": rope, "ovary": ov}
		if not _tubes.has(side) or (_tubes[side] as Dictionary).is_empty():
			var n := TUBE_PTS
			var p := PackedVector3Array()
			var st := PackedByteArray()
			var rest := PackedFloat32Array()
			# t92u：管更长（直线距离 × TUBE_LEN_MUL），弧高二分求出，使弧长正好等于管静长。
			var hp := _tube_head_pts(side)
			var ovp := _xform_rest(_ovary_rest_ab(side))
			var nn := horn_normal_world(side)
			var straight := (hp[1] as Vector3).distance_to(ovp)
			var want := maxf(straight * TUBE_LEN_MUL, TUBE_LEN_MIN)
			var lo := 0.0
			var hi_h := want
			for _b in 30:
				var mid := (lo + hi_h) * 0.5
				if _arc_len(hp[1], ovp, nn, mid, n - 2) < want:
					lo = mid
				else:
					hi_h = mid
			_tube_bulge[side] = (lo + hi_h) * 0.5
			# 等弧长取样：密采样弧线，按累计弧长给每个点分配参数 t。
			var dense := 96
			var cum := PackedFloat32Array([0.0])
			var prev: Vector3 = hp[1]
			for di in range(1, dense + 1):
				var c := _tube_arc(hp[1], ovp, nn, float(_tube_bulge[side]), float(di) / float(dense))
				cum.append(cum[di - 1] + prev.distance_to(c))
				prev = c
			var tot := cum[dense]
			var tk := PackedFloat32Array([0.0, 0.0])
			var j := 0
			for k1 in range(2, n):
				var target := tot * float(k1 - 1) / float(n - 2)
				while j < dense - 1 and cum[j + 1] < target:
					j += 1
				var seg := maxf(cum[j + 1] - cum[j], 1e-9)
				tk.append((float(j) + clampf((target - cum[j]) / seg, 0.0, 1.0)) / float(dense))
			_tube_tk[side] = tk
			for k in n:
				p.append(_tube_rest_world(side, k, n))
				st.append(0)
			for k2 in n - 1:
				rest.append(p[k2].distance_to(p[k2 + 1]))
			_tubes[side] = {"p": p, "q": p.duplicate(), "st": st, "rest": rest}
		_apply_tube(side)


func _apply_tube(side: int) -> void:
	var tb: Dictionary = _tubes.get(side, {})
	var rope := _chain_node(side)
	if tb.is_empty() or rope == null:
		return
	var p: PackedVector3Array = tb["p"]
	var dir := Vector3.RIGHT
	if p.size() >= 2:
		dir = (p[1] - p[0])
	rope.call("apply_points", p, tb["q"], dir)
	var ch: Dictionary = _chains.get(side, {})
	var ov: MeshInstance3D = ch.get("ovary")
	if ov and is_instance_valid(ov) and not p.is_empty():
		ov.global_transform = Transform3D(_ovary_basis[side] as Basis, p[p.size() - 1])
		ov.visible = true


func _step_tube(side: int, dt: float, kinematic: bool) -> void:
	var tb: Dictionary = _tubes.get(side, {})
	if tb.is_empty():
		return
	var p: PackedVector3Array = tb["p"]
	var q: PackedVector3Array = tb["q"]
	var st: PackedByteArray = tb["st"]
	var rest: PackedFloat32Array = tb["rest"]
	var n := p.size()
	if n < 2:
		return
	var rope := _chain_node(side)
	var hi := int(rope.get("hold_index")) if rope else -1
	if hi == 1:
		hi = 2
	var hp: Vector3 = rope.get("hold_pos") if rope else Vector3.ZERO
	var head := _tube_head_pts(side)
	var h0: Vector3 = head[0]
	var h1: Vector3 = head[1]
	var horn_out := _horn_is_out(side)
	var spring := 0.0 if (horn_out or hi >= 0 or bool(_early.get(side, false))) else TUBE_IN_SPRING
	if kinematic:
		spring = 0.5
	# T-11：夹点不能离宫角比管长还远——否则两端都钉死，中间被拉成细线。
	if hi > 1 and hi < n:
		var arc0 := 0.0
		for a0 in range(1, mini(hi, rest.size())):
			arc0 += rest[a0]
		var reach := arc0 * TUBE_MAX_STRETCH
		var dh := hp - h1
		if dh.length() > reach:
			hp = h1 + dh.normalized() * reach
			if rope:
				rope.set("hold_pos", hp)
	var k60 := dt * 60.0
	for k in range(2, n):
		if k == hi:
			q[k] = p[k]
			p[k] = hp
			continue
		var cur := p[k]
		var out := st[k] == 1
		var v := (cur - q[k]) * (pow(TUBE_AIR_DAMP, k60) if out else DAMP)
		if out:
			v += gravity * dt * dt
		q[k] = cur
		p[k] = cur + v
		if spring > 0.0:
			p[k] = p[k].lerp(_tube_rest_world(side, k, n), spring)
		if p[k].y < floor_y + 0.006:
			p[k].y = floor_y + 0.006
	q[1] = p[1]
	for _it in (TUBE_ITER if (hi >= 0 or hold_index >= 0) else TUBE_ITER_FREE):
		p[0] = h0
		p[1] = h1
		if hi > 0 and hi < n:
			p[hi] = hp
		for k3 in range(1, n - 1):
			var d := p[k3 + 1] - p[k3]
			var L := d.length()
			if L < 1e-8 or L <= rest[k3]:
				continue
			# 软弹簧：只抗拉（松弛时自然下垂），每次只纠正一部分 → 可弹性伸长。
			var corr := (L - rest[k3]) / L * TUBE_STIFF
			var wa := 0.0 if (k3 <= 1 or k3 == hi) else 1.0
			var wb := 0.0 if (k3 + 1 == hi) else 1.0
			var ws := wa + wb
			if ws <= 0.0:
				continue
			p[k3] += d * corr * (wa / ws)
			p[k3 + 1] -= d * corr * (wb / ws)
		for k4 in range(2, n):
			if k4 == hi:
				continue
			var r := _wall(p[k4], st[k4], 0.004)
			p[k4] = r[0]
			st[k4] = int(r[1])
		for k5 in range(1, n - 1):
			_cross_fix_arr(p, st, k5, k5 + 1, 0.0 if k5 == 1 else 1.0, 0.0 if k5 + 1 == hi else 1.0)
	p[0] = h0
	p[1] = h1
	st[1] = 1 if (h1 - wound_center).dot(outward) > 0.0 else st[1]
	if hi > 0 and hi < n:
		p[hi] = hp
	var lim := TUBE_MAX_STRETCH
	if hi <= 1:
		# 松手：上限从当前实际伸长开始逐帧回落（弹性回弹）。
		var cur_s := 1.0
		for ks in range(1, n - 1):
			cur_s = maxf(cur_s, p[ks].distance_to(p[ks + 1]) / maxf(rest[ks], 1e-6))
		lim = clampf(minf(float(_tube_lim[side]), cur_s) - TUBE_RECOIL * dt * 60.0, TUBE_FREE_STRETCH, TUBE_MAX_STRETCH)
	_tube_lim[side] = lim
	_tube_hard_length(p, q, st, rest, hi, lim)
	if hi > 0 and hi < n and rope:
		rope.set("hold_pos", p[hi])
	tb["p"] = p
	tb["q"] = q
	tb["st"] = st
	_tubes[side] = tb
	_apply_tube(side)


## T-11：迭代后再做一遍硬长度上限（宫角 → 卵巢的 FABRIK，夹点固定时再从夹点往回收一遍）。
## 腹壁 / 洞口修正会把段拉长（体外段被宫角带走、体内段卡在壁后），这里让长度优先：
## 被拽到腹壁外侧的点直接记为体外，下一帧不再被推回体内造成反复拉扯。
func _tube_hard_length(p: PackedVector3Array, q: PackedVector3Array, st: PackedByteArray, rest: PackedFloat32Array, hi: int, lim: float = TUBE_MAX_STRETCH) -> void:
	var n := p.size()
	if hi > 1 and hi < n:
		var arc := 0.0
		for a in range(1, hi):
			arc += rest[a]
		var dh := p[hi] - p[1]
		if dh.length() > arc * lim * 0.995:
			p[hi] = p[1] + dh.normalized() * arc * lim * 0.995
			q[hi] = p[hi]
	for k in range(2, n):
		if k == hi:
			continue
		var d := p[k] - p[k - 1]
		var L := d.length()
		var mx := rest[k - 1] * lim
		if L > mx and L > 1e-9:
			var np := p[k - 1] + d * (mx / L)
			q[k] = np
			p[k] = np
	var passes := 4 if (hi > 1 and hi < n) else 0
	for _pass in passes:
		for k2 in range(hi - 1, 1, -1):
			var d2 := p[k2] - p[k2 + 1]
			var L2 := d2.length()
			var mx2 := rest[k2] * lim
			if L2 > mx2 and L2 > 1e-9:
				var np2 := p[k2 + 1] + d2 * (mx2 / L2)
				q[k2] = np2
				p[k2] = np2
		for k3 in range(2, hi):
			var d3 := p[k3] - p[k3 - 1]
			var L3 := d3.length()
			var mx3 := rest[k3 - 1] * lim
			if L3 > mx3 and L3 > 1e-9:
				var np3 := p[k3 - 1] + d3 * (mx3 / L3)
				q[k3] = np3
				p[k3] = np3
	if hi > 1 and hi < n:
		# 仍有余差就让夹点本身让一点（钳子停在管子上，而不是把管子拉长）。
		var d5 := p[hi] - p[hi - 1]
		var mx5 := rest[hi - 1] * lim
		if d5.length() > mx5:
			p[hi] = p[hi - 1] + d5.normalized() * mx5
			q[hi] = p[hi]
		for k6 in range(hi + 1, n):
			var d6 := p[k6] - p[k6 - 1]
			var L6 := d6.length()
			var mx6 := rest[k6 - 1] * lim
			if L6 > mx6 and L6 > 1e-9:
				p[k6] = p[k6 - 1] + d6 * (mx6 / L6)
	for k4 in range(1, n):
		if st[k4] == 0 and (p[k4] - wound_center).dot(outward) > 0.0:
			st[k4] = 1


func _maybe_auto_chain() -> void:
	if kind != "uterus" or not organ_active:
		return
	for side in [0, 1]:
		var ch: Dictionary = _chains.get(side, {})
		if bool(ch.get("active", false)):
			continue
		if _horn_is_out(side) or extract_charge >= float(LEVELS) - 1e-3 or bool(_early.get(side, false)):
			ch["active"] = true
			_chains[side] = ch


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
	_tubes = {}


func rest_cervix_world() -> Vector3:
	return _frame * _cervix_ab + _drag_off


func rest_fundus_world() -> Vector3:
	return _frame * _fundus_ab + _drag_off


func centroid_world() -> Vector3:
	if _p.is_empty():
		return _frame * ((_cervix_ab + _fundus_ab) * 0.5)
	var s := Vector3.ZERO
	for p in _p:
		s += p
	return s / float(_p.size())


func segment_stretch() -> float:
	var m := 1.0
	for i in _seg_rest.size():
		if i + 1 >= _p.size():
			break
		m = maxf(m, _p[i].distance_to(_p[i + 1]) / maxf(float(_seg_rest[i]), 1e-6))
	return m


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
	_has_pull_target = false
	hold_no_feed = false
	_nf_charge = -1.0


## T-11：拿取工具拖动已在体外的宫体节点。只能抓体外节点；能拖到的最远处 = 该节点到
## 「最靠近创口的连续体外节点」的链长 + 那个节点当前离创口的距离（体外系带也算），
## 所以拖、甩都不会把体内部分再拽出来；夹点也不会被推回腹壁内。返回是否抓住。
func hold_particle_swing(i: int, tip: Vector3) -> bool:
	if _p.is_empty() or i < 0 or i >= _p.size() or not node_outside(i):
		return false
	if retracting:
		return false
	var j0 := i
	while j0 > 0 and node_outside(j0 - 1):
		j0 -= 1
	var arc := 0.0
	for b in range(j0, mini(i, _seg_rest.size())):
		arc += float(_seg_rest[b])
	var base := _p[j0].distance_to(wound_center)
	if j0 == 0:
		base = maxf(base, _tlen - _wound_depth())
	_nf_reach = maxf(base + arc, _p[i].distance_to(wound_center)) + 0.002
	hold_particle(i, tip)
	hold_no_feed = true
	_nf_charge = extract_charge
	return true


func _nf_clamp(target: Vector3) -> Vector3:
	var lim := WALL_MARGIN + 0.002
	var d := (target - wound_center).dot(outward)
	if d < lim:
		target += outward * (lim - d)
	var rel := target - wound_center
	if rel.length() > _nf_reach:
		target = wound_center + rel.normalized() * _nf_reach
		var d2 := (target - wound_center).dot(outward)
		if d2 < lim:
			target += outward * (lim - d2)
	var r: Array = _wall(target, 1, BODY_R)
	return r[0]


func chain_ropes() -> Array:
	var out: Array = []
	for side in [0, 1]:
		if tube_chain_active(side):
			out.append((_chains[side] as Dictionary)["rope"])
	return out


func chain_hold(side: int, origin: Vector3, dir: Vector3) -> bool:
	if not tube_chain_active(side):
		detach_adnexa(side)
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
	if idx <= 0:
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


## 外部（腹部软位移 / 互动拖拽）整体带着走：质点、根点、静止姿态都一起平移。
func carry(xf: Transform3D) -> void:
	_carry_points(xf)
	_drag_off = xf * _drag_off if xf.basis.is_equal_approx(Basis.IDENTITY) else _drag_off + xf.origin


func _carry_points(xf: Transform3D) -> void:
	for i in _x.size():
		_x[i] = xf * _x[i]
	for i in _xq.size():
		_xq[i] = xf * _xq[i]
	if hold_index >= 0:
		hold_pos = xf * hold_pos
	if _has_pull_target:
		_pull_target = xf * _pull_target
	wound_center = xf * wound_center
	outward = (xf.basis * outward).normalized()
	for side in [0, 1]:
		var tb: Dictionary = _tubes.get(side, {})
		if not tb.is_empty():
			var p: PackedVector3Array = tb["p"]
			var q: PackedVector3Array = tb["q"]
			for k in p.size():
				p[k] = xf * p[k]
			for k2 in q.size():
				q[k2] = xf * q[k2]
			tb["p"] = p
			tb["q"] = q
			_tubes[side] = tb
		var rope := _chain_node(side)
		if rope and int(rope.get("hold_index")) >= 0:
			rope.set("hold_pos", xf * (rope.get("hold_pos") as Vector3))
	if not _x.is_empty():
		_sync_body()


# ---------------------------------------------------------------- 物理

func _wound_depth() -> float:
	return maxf(root_world().distance_to(hang_point()), 0.02)


## 夹点 / 虚拟拉动目标能到的最远处：系带长度用完就拉不动了（钳子停在器官上）。
func _reach_clamp(bi: int, target: Vector3, is_out: bool) -> Vector3:
	var arc := 0.0
	for i in mini(bi, _seg_rest.size()):
		arc += float(_seg_rest[i])
	var sw := _wound_depth()
	var tmax := sw + OUT_EXTRA
	if is_out:
		var maxd := (tmax - sw) + arc
		var hp := hang_point()
		var d := target - hp
		if d.length() > maxd:
			return hp + d.normalized() * maxd
		return target
	var root := root_world()
	var maxd2 := tmax + arc
	var d2 := target - root
	if d2.length() > maxd2:
		return root + d2.normalized() * maxd2
	return target


## 驱动目标：体内节点要出去只能走创口——目标在腹壁外而路径不经洞口时，先把节点引向洞口。
func _driver_target(ci: int, target: Vector3) -> Vector3:
	if hold_no_feed:
		return _nf_clamp(target)
	var cur := _x[ci]
	var st := _st[ci]
	var bi := ci - TETHER_N
	if st == 0:
		var dt_ := (target - wound_center).dot(outward)
		if dt_ > -WALL_MARGIN:
			var a := cur
			var da := (a - wound_center).dot(outward)
			var cross := target
			if da < dt_ - 1e-6:
				var t := clampf(-da / (dt_ - da), 0.0, 1.0)
				cross = a.lerp(target, t)
			var rel := cross - wound_center
			var radial := rel - outward * rel.dot(outward)
			if radial.length() > HOLE_R:
				# 先朝洞口走（步长不超过钳尖本身的位移）。t91u：去洞口里离穿出点最近的地方，
				# 而不是洞口中心——子宫不再先被抬到创口中心（肚脐一侧）再出来。
				var hole := wound_center + radial.normalized() * (HOLE_R * 0.7) - outward * WALL_MARGIN * 0.5
				var step := maxf(cur.distance_to(target), 0.004)
				var to_h := hole - cur
				if to_h.length() > step:
					to_h = to_h.normalized() * step
				target = cur + to_h
		return _reach_clamp(bi, target, false)
	if bi >= 0 and _body_all_out():
		return _out_clear(_reach_clamp(bi, target, true), bi)
	return _reach_clamp(bi, target, true)


func _wall(p: Vector3, st: int, r_node: float) -> Array:
	var rel := p - wound_center
	var d := rel.dot(outward)
	var radial := rel - outward * d
	var r := radial.length()
	if st == 0:
		if d > 0.0:
			if r <= HOLE_R:
				st = 1
			else:
				p -= outward * (d + WALL_MARGIN)
		elif r > 0.05 and not skin_p.is_empty():
			# 远离创口处：别从体内穿出皮肤。
			var sh := _skin_h(p)
			var h: float = sh[0]
			if h < 1e8 and h > -WALL_MARGIN and h < 0.03:
				p -= (sh[1] as Vector3) * (h + WALL_MARGIN)
	else:
		if d < 0.0 and r <= HOLE_R:
			st = 0
		elif r <= HOLE_R + r_node:
			pass
		elif not skin_p.is_empty() and r > 0.035:
			var sh2 := _skin_h(p)
			var h2: float = sh2[0]
			if h2 < r_node and h2 > -0.05:
				p += (sh2[1] as Vector3) * (r_node - h2)
			elif h2 >= 1e8 and d < WALL_MARGIN:
				p += outward * (WALL_MARGIN - d)
		elif d < WALL_MARGIN:
			p += outward * (WALL_MARGIN - d)
	return [p, st]


func _body_all_out() -> bool:
	if _st.size() != TETHER_N + SEGS:
		return false
	for b in SEGS:
		if _st[TETHER_N + b] != 1:
			return false
	return true


## t82u：整颗宫体都在体外时，按最缺的那个节点把整条宫体（刚体）沿创口法线平移出去，
## 网格不陷进腹腔；整体平移不破坏段长 / 角度，也不和形状匹配打架（不会抖、能正常休眠）。
func _rigid_out_clear() -> void:
	# 被钳子夹着拖时不平移（夹点本身已被限制在体外，其余节点由 FABRIK 刚性跟随），避免与夹点错位拉伸网格。
	if not _body_all_out() or _drv_i >= TETHER_N:
		return
	var deficit := 0.0
	for b in SEGS:
		var ci := TETHER_N + b
		if ci == _drv_i:
			continue
		var p2 := _out_clear(_x[ci], b)
		deficit = maxf(deficit, (p2 - _x[ci]).dot(outward))
	if deficit <= 1e-6:
		return
	for b2 in SEGS:
		var cj := TETHER_N + b2
		if cj == _drv_i:
			continue
		_x[cj] += outward * deficit


## t82u：体外宫体节点离创口平面的最小距离（洞口附近），越过洞口一段后渐隐、交给皮肤碰撞。
func _out_clear(p: Vector3, b: int) -> Vector3:
	var need := CERVIX_CLEAR if b == 0 else BODY_CLEAR
	var rel := p - wound_center
	var d := rel.dot(outward)
	if d >= need:
		return p
	var r := (rel - outward * d).length()
	var r0 := HOLE_R + BODY_R
	var k := 1.0 - clampf((r - r0) / CLEAR_FADE, 0.0, 1.0)
	var want := need * k
	if d < want:
		p += outward * (want - d)
	return p


func _cross_fix_arr(arr: PackedVector3Array, st: PackedByteArray, ia: int, ib: int, wa: float, wb: float) -> void:
	if st[ia] == st[ib]:
		return
	var a := arr[ia]
	var b := arr[ib]
	var da := (a - wound_center).dot(outward)
	var db := (b - wound_center).dot(outward)
	if absf(da - db) < 1e-7:
		return
	var t := clampf(da / (da - db), 0.0, 1.0)
	var x := a.lerp(b, t)
	var rel := x - wound_center
	var radial := rel - outward * rel.dot(outward)
	var r := radial.length()
	if r <= HOLE_R:
		return
	var shift := radial * (1.0 - HOLE_R / r)
	var ws := wa + wb
	if ws <= 0.0:
		return
	# 两端按权重平移，使穿膜点回到洞口内。
	if wa > 0.0 and wb > 0.0:
		arr[ia] = a - shift
		arr[ib] = b - shift
	elif wa > 0.0:
		arr[ia] = a - shift / maxf(1.0 - t, 0.25)
	else:
		arr[ib] = b - shift / maxf(t, 0.25)


func _inv_w(ci: int) -> float:
	if ci == 0 or ci == _drv_i:
		return 0.0
	return BODY_W if ci >= TETHER_N else 1.0


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / SKIN_CELL), floori(p.y / SKIN_CELL), floori(p.z / SKIN_CELL))


func _build_grid() -> void:
	_grid.clear()
	for i in skin_p.size():
		var c := _cell(skin_p[i])
		if _grid.has(c):
			(_grid[c] as PackedInt32Array).append(i)
		else:
			_grid[c] = PackedInt32Array([i])


func _skin_h(p: Vector3) -> Array:
	if skin_p.is_empty() or skin_n.size() != skin_p.size():
		return [1e9, outward]
	var c0 := _cell(p)
	var best := 1e9
	var bi := -1
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var arr = _grid.get(c0 + Vector3i(dx, dy, dz))
				if arr == null:
					continue
				for i in arr:
					var d := p.distance_squared_to(skin_p[i])
					if d < best:
						best = d
						bi = i
	if bi < 0:
		return [1e9, outward]
	var nn: Vector3 = skin_n[bi]
	return [(p - skin_p[bi]).dot(nn), nn]


func step(dt: float, frame: Transform3D, wound: Vector3, out_dir: Vector3) -> void:
	if not organ_active:
		return
	var t0 := Time.get_ticks_usec()
	dt = minf(maxf(dt, 0.0), 1.0 / 30.0)
	var vis_carry := false
	if _has_prev_frame:
		var xf := frame * _prev_frame.affine_inverse()
		if xf.origin.length_squared() > 1e-16 or not xf.basis.is_equal_approx(Basis.IDENTITY):
			var saved_w := wound_center
			var saved_o := outward
			_carry_points(xf)
			wound_center = saved_w
			outward = saved_o
			vis_carry = xf.origin.length_squared() > 4e-10 or not xf.basis.is_equal_approx(Basis.IDENTITY)
	_prev_frame = frame
	_has_prev_frame = true
	_frame = frame
	wound_center = wound
	if out_dir.length_squared() > 1e-8:
		outward = out_dir.normalized()
	if _x.size() != TETHER_N + SEGS:
		_init_particles()
	if retracting:
		_asleep = false
		_sleep_vis_ok = false
		_build_grid()
		_step_putback(dt)
		last_step_usec = Time.get_ticks_usec() - t0
		return
	var root := root_world()
	var nb := TETHER_N + SEGS
	_drv_i = -1
	if hold_index >= 0 and hold_index < SEGS:
		_drv_i = TETHER_N + hold_index
		_drv_pos = _driver_target(_drv_i, hold_pos)
	elif _has_pull_target:
		_drv_i = nb - 1
		_drv_pos = _driver_target(_drv_i, _pull_target)
		_pull_target = _drv_pos
	var driven := _drv_i >= 0
	var any_out := false
	for i0 in nb:
		if _st[i0] == 1:
			any_out = true
			break
	# 没有被拉、也没有任何部分在体外：停在体内原位（与原子宫重合）。
	if not driven and not any_out and _tlen <= TETHER_MIN * 1.5:
		for b0 in SEGS:
			var pw := _rest_world(b0)
			_x[TETHER_N + b0] = pw
			_xq[TETHER_N + b0] = pw
		for t_i in TETHER_N:
			_x[t_i] = root
			_xq[t_i] = root
		_finish_step(dt, true)
		_asleep = true
		last_step_usec = Time.get_ticks_usec() - t0
		return
	# 已取出但已收敛：跳过约束迭代；骨架随腹部坐标系搬运后只在需要时重画网格。
	if not driven:
		var max_v2 := 0.0
		for i_s in nb:
			max_v2 = maxf(max_v2, _x[i_s].distance_squared_to(_xq[i_s]))
		# T-15：松手瞬间速度本来就≈0（慢慢拖出来的），不能立刻休眠——要连续 SLEEP_QUIET 个模拟帧都不动
		# （真的停在平衡位置）才睡，否则会定在松手时的姿势（站姿时横着戳在创口外不往下垂）。
		if max_v2 < 4e-10:
			_quiet_frames += 1
		else:
			_quiet_frames = 0
		if max_v2 < 4e-10 and (_quiet_frames >= SLEEP_QUIET or _asleep):
			if _asleep and _sleep_vis_ok and not vis_carry:
				last_step_usec = Time.get_ticks_usec() - t0
				return
			_asleep = true
			_finish_step(dt, true)
			_sleep_vis_ok = true
			last_step_usec = Time.get_ticks_usec() - t0
			return
		_asleep = false
		_sleep_vis_ok = false
	else:
		_asleep = false
		_sleep_vis_ok = false
		_quiet_frames = 0
	_build_grid()
	var sw := _wound_depth()
	var loose := clampf((_tlen - TETHER_MIN) / maxf(sw * 0.6, 0.01), 0.0, 1.0)
	var k60 := dt * 60.0
	var air := pow(AIR_DAMP, k60)
	# 1) Verlet 积分
	_x[0] = root
	_xq[0] = root
	for i in range(1, nb):
		if i == _drv_i:
			_xq[i] = _x[i]
			_x[i] = _drv_pos
			continue
		var cur := _x[i]
		var out := _st[i] == 1
		var v := (cur - _xq[i]) * (air if out else DAMP)
		var sp := v.length()
		if sp > MAX_SPEED * dt:
			v *= (MAX_SPEED * dt) / maxf(sp, 1e-8)
		if out:
			v += gravity * dt * dt
		_xq[i] = cur
		var np := cur + v
		if not out:
			if i >= TETHER_N:
				# 体内宫体被组织托着回原位；系带越长（已被扯开）托得越弱。
				np = np.lerp(_rest_world(i - TETHER_N), IN_SPRING * (1.0 - loose))
			else:
				var s_i := float(i) * _tlen / float(TETHER_N)
				# 体内系带沿根点 → 悬挂点的直线，停在腹壁内侧（不在洞口平面上来回翻进翻出）。
				var on_line := root + (hang_point() - root).normalized() * minf(s_i, sw - WALL_MARGIN)
				np = np.lerp(on_line, 0.2)
		if np.y < floor_y + 0.008:
			np.y = floor_y + 0.008
		_x[i] = np
	# 2) 被拉时系带跟着伸长（阴道上段 / 韧带被拉开），上限 = 创口深度 + OUT_EXTRA。
	if driven and not hold_no_feed:
		var b0p := _x[TETHER_N]
		var need := root.distance_to(b0p)
		if _st[TETHER_N] == 1:
			need = sw + b0p.distance_to(wound_center)
		if need > _tlen:
			_tlen = minf(need, sw + OUT_EXTRA)
	# 3) 约束迭代
	var seg_t := _tlen / float(TETHER_N)
	for _it in (ITER if driven else ITER_FREE):
		_x[0] = root
		if _drv_i >= 0:
			_x[_drv_i] = _drv_pos
		# 系带：只限最长（绳子，可松弛）
		for k in TETHER_N:
			_solve_link(k, k + 1, seg_t, true)
		# t72u：体外的系带 / 宫颈拴在创口中心附近（短过渡），子宫不会挂得离创口很远。
		var hang := hang_point()
		for kt in range(1, TETHER_N + 1):
			if _st[kt] == 1 and kt != _drv_i:
				var dw := _x[kt] - hang
				if dw.length() > CERVIX_OUT_MAX:
					_x[kt] = hang + dw.normalized() * CERVIX_OUT_MAX
		# 宫体：硬段长
		for b in SEGS - 1:
			_solve_link(TETHER_N + b, TETHER_N + b + 1, float(_seg_rest[b]), false)
		_solve_angles()
		_straighten_body(BODY_STIFF)
		for i2 in range(1, nb):
			if i2 == _drv_i:
				continue
			var was_out := _st[i2] == 1
			var r := _wall(_x[i2], _st[i2], BODY_R if i2 >= TETHER_N else TETHER_R)
			_x[i2] = r[0]
			_st[i2] = int(r[1])
			if i2 >= TETHER_N and (was_out or _st[i2] == 1):
				_st[i2] = 1
		for k2 in nb - 1:
			_cross_fix_arr(_x, _st, k2, k2 + 1, _inv_w(k2), _inv_w(k2 + 1))
	# 最后：角度 + 从驱动点出发的精确段长（FABRIK 一遍），保证宫体不拉伸、不折。
	_straighten_body(BODY_STIFF)
	_fabrik_body()
	_rigid_out_clear()
	_x[0] = root
	if _drv_i >= 0:
		_x[_drv_i] = _drv_pos
		# 驱动节点的状态按实际位置更新
		var was_out_d := _st[_drv_i] == 1
		var rr := _wall(_x[_drv_i], _st[_drv_i], 0.0)
		_st[_drv_i] = int(rr[1])
		if _drv_i >= TETHER_N and was_out_d:
			_st[_drv_i] = 1
		if hold_index >= 0:
			hold_pos = _drv_pos
	for i3 in nb:
		if not _x[i3].is_finite():
			_x[i3] = _rest_world(i3 - TETHER_N) if i3 >= TETHER_N else root
			_xq[i3] = _x[i3]
	_finish_step(dt, false)
	last_step_usec = Time.get_ticks_usec() - t0


func _solve_link(a: int, b: int, rest: float, rope: bool) -> void:
	var d := _x[b] - _x[a]
	var L := d.length()
	if L < 1e-9:
		return
	if rope and L <= rest:
		return
	if not rope and absf(L - rest) < rest * 0.0005:
		return
	var wa := _inv_w(a)
	var wb := _inv_w(b)
	var ws := wa + wb
	if ws <= 0.0:
		return
	var corr := d * ((L - rest) / L)
	_x[a] += corr * (wa / ws)
	_x[b] -= corr * (wb / ws)


## 形状匹配：静止宫体是一条直线，取当前首尾方向，以驱动点（无驱动时取质心）为基准摆回直线。
func _straighten_body(k: float) -> void:
	var a := _x[TETHER_N]
	var b := _x[TETHER_N + SEGS - 1]
	var dir := b - a
	if dir.length_squared() < 1e-10:
		return
	dir = dir.normalized()
	var arc := PackedFloat32Array()
	arc.resize(SEGS)
	arc[0] = 0.0
	for i in range(1, SEGS):
		arc[i] = arc[i - 1] + float(_seg_rest[i - 1])
	var base := Vector3.ZERO
	if _drv_i >= TETHER_N:
		base = _x[_drv_i] - dir * arc[_drv_i - TETHER_N]
	else:
		var c := Vector3.ZERO
		var ca := 0.0
		for j in SEGS:
			c += _x[TETHER_N + j]
			ca += arc[j]
		base = c / float(SEGS) - dir * (ca / float(SEGS))
	for m in SEGS:
		var ci := TETHER_N + m
		if ci == _drv_i:
			continue
		_x[ci] = _x[ci].lerp(base + dir * arc[m], k)


func _fabrik_body() -> void:
	var start := TETHER_N
	if _drv_i >= TETHER_N:
		start = _drv_i
	for i in range(start - 1, TETHER_N - 1, -1):
		var d := _x[i] - _x[i + 1]
		var L := d.length()
		if L > 1e-9:
			_x[i] = _x[i + 1] + d * (float(_seg_rest[i - TETHER_N]) / L)
	for j in range(start, TETHER_N + SEGS - 1):
		var d2 := _x[j + 1] - _x[j]
		var L2 := d2.length()
		if L2 > 1e-9:
			_x[j + 1] = _x[j] + d2 * (float(_seg_rest[j - TETHER_N]) / L2)


func _solve_angles() -> void:
	for b in range(1, SEGS - 1):
		var i := TETHER_N + b
		if i == _drv_i:
			continue
		var a := _x[i] - _x[i - 1]
		var c := _x[i + 1] - _x[i]
		var la := a.length()
		var lc := c.length()
		if la < 1e-6 or lc < 1e-6:
			continue
		var ang := acos(clampf(a.dot(c) / (la * lc), -1.0, 1.0))
		if ang <= MAX_BEND:
			continue
		var mid := (_x[i - 1] + _x[i + 1]) * 0.5
		var t := clampf((ang - MAX_BEND) / maxf(ang, 1e-5), 0.0, 1.0)
		_x[i] = _x[i].lerp(mid, t * 0.85)


func _finish_step(dt: float, kinematic_tubes: bool) -> void:
	_sync_body()
	_update_bones()
	_refresh_charge()
	_maybe_auto_chain()
	for side in [0, 1]:
		_step_tube(side, dt, kinematic_tubes)
	_rebuild_visual()
	_rebuild_tether()


## 放回：所有质点先沿原路退回创口（体外的不能穿腹壁），再回静止位，系带缩短。
func _step_putback(dt: float) -> void:
	_putback_t += dt
	var stp := PUTBACK_SPEED * dt
	var root := root_world()
	var nb := TETHER_N + SEGS
	_drv_i = -1
	_tlen = maxf(TETHER_MIN, _tlen - stp * 1.5)
	var hole_in := hang_point() - outward * 0.012
	for i in nb:
		var tgt: Vector3
		if i < TETHER_N:
			tgt = root
		else:
			tgt = _rest_world(i - TETHER_N)
		if _st[i] == 1:
			tgt = hole_in
		var d := tgt - _x[i]
		var L := d.length()
		if L > stp:
			_x[i] += d * (stp / L)
		else:
			_x[i] = tgt
		var rel := _x[i] - wound_center
		var dd := rel.dot(outward)
		if _st[i] == 1 and dd < 0.0:
			_st[i] = 0
		_xq[i] = _x[i]
	_sync_body()
	_update_bones()
	_refresh_charge()
	if extract_charge < float(TUBE_LEVEL):
		for side_r in [0, 1]:
			var ch_r: Dictionary = _chains.get(side_r, {})
			ch_r["active"] = false
			_chains[side_r] = ch_r
			_early[side_r] = false
	for side in [0, 1]:
		var rope := _chain_node(side)
		if rope:
			rope.set("hold_index", -1)
		_step_tube(side, dt, true)
	_rebuild_visual()
	_rebuild_tether()
	var all_in := true
	for i2 in nb:
		if _st[i2] == 1:
			all_in = false
			break
	if (all_in and _max_rest_offset() < 0.012) or _putback_t > PUTBACK_TIMEOUT:
		force_reset()


func _max_rest_offset() -> float:
	var m := 0.0
	for b in _p.size():
		m = maxf(m, _p[b].distance_to(_rest_world(b)))
	return m


func _refresh_charge() -> void:
	if not organ_active:
		extract_charge = 0.0
		return
	if hold_no_feed and _nf_charge >= 0.0:
		extract_charge = _nf_charge
		return
	var exp := exposed_length()
	var u := clampf(exp / maxf(_rest_len * 0.80, 0.025), 0.0, 1.0)
	extract_charge = 1.0 + 4.0 * u


func _ensure_tether_mesh() -> void:
	if _tether_node and is_instance_valid(_tether_node):
		return
	var t := AdnexaChain.new()
	t.name = "UterusTether"
	# t72u：短而粗的肉色阴道上段过渡（不再用子宫红材质画一根长管）。
	t.set("radius", TRANSITION_R)
	t.set("taper", false)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = _transition_color
	fm.roughness = 0.55
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	t.material_override = fm
	add_child(t)
	_tether_node = t
	t.visible = false


func _rebuild_tether() -> void:
	if _tether_node == null or not is_instance_valid(_tether_node):
		return
	var pts := transition_points()
	var stump := transition_stump_points()
	# 根点埋在阴道顶端里，只在明显被扯长后才显示；外露断端 + 体内段接回体内阴道（t99u）。
	var show := _tlen > 0.012 and stump.size() >= 2 and stump[0].distance_to(stump[stump.size() - 1]) > 0.002
	(_tether_node as Node3D).visible = show
	if show:
		_tether_node.call("apply_points", pts, pts, pts[pts.size() - 1] - pts[0])


func _update_bones() -> void:
	# 沿链平行传输参考向量（时间上也接着上一帧），避免相邻骨骼半圈扭转把网格撕开。
	var up := _frame.basis * _rest_up
	if _bone.size() == SEGS:
		up = (_bone[0] as Transform3D).basis.y
	_bone = []
	if _p.size() != SEGS:
		return
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
		var y := axis.cross(x)
		up = y
		_bone.append(Transform3D(Basis(x, y, axis), _p[i]))


func _xform_rest(p_ab: Vector3) -> Vector3:
	if _bone.is_empty() or _rest_bone.is_empty():
		return _frame * p_ab + _drag_off
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
			out[i] = _frame * _vis_rest[i] + _drag_off
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
	if _vis_rest.is_empty() or _p.is_empty() or _skel == null:
		return
	if _bone.size() != SEGS:
		return
	for b in SEGS:
		var bx: Transform3D = _bone[b]
		if not bx.origin.is_finite():
			continue
		_skel.set_bone_pose(b, bx)


func exposed_length() -> float:
	if not organ_active or _p.is_empty():
		return 0.0
	var best := 0.0
	for i in _p.size():
		if node_outside(i) or (_p[i] - wound_center).dot(outward) > -0.004:
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
	# GPU 蒙皮：检查的是当前骨骼姿态下的顶点。
	var V: PackedVector3Array = _skin_all()
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
		if I[f] >= V.size() or I[f + 1] >= V.size() or I[f + 2] >= V.size():
			continue
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


# ---------------------------------------------------------------- 外部驱动（0.4.12 子宫脱垂）
## 段链由 ProlapseController 解算（经阴道脱出，不走腹部创口）；这里只负责：
## 隐藏原网格、GPU 蒙皮、输卵管/卵巢小链。portal = 阴道外口，portal_out = 外口朝外方向。

var external_drive := false
var adnexa_hide_outside := true


func begin_external(frame: Transform3D, portal: Vector3, portal_out: Vector3) -> void:
	hang_offset = Vector3.ZERO
	_frame = frame
	_prev_frame = frame
	_has_prev_frame = false
	wound_center = portal
	outward = portal_out.normalized() if portal_out.length_squared() > 1e-8 else Vector3.DOWN
	if organ_active:
		return
	_drag_off = Vector3.ZERO
	_rebase()
	_hide_sources(true)
	_init_particles()
	extract_charge = 1.0
	retracting = false
	organ_active = true
	external_drive = true
	visible = true
	_has_pull_target = false
	hold_index = -1
	_rebuild_visual()
	_ensure_tubes()


func end_external() -> void:
	external_drive = false
	force_reset()


func rest_nodes_ab() -> PackedVector3Array:
	return _rest_ab


func seg_rest_lengths() -> PackedFloat32Array:
	return _seg_rest


func node_count() -> int:
	return SEGS


func step_external(dt: float, frame: Transform3D, nodes: PackedVector3Array, portal: Vector3, portal_out: Vector3) -> void:
	if not organ_active or nodes.size() != SEGS:
		return
	var t0 := Time.get_ticks_usec()
	dt = minf(maxf(dt, 0.0), 1.0 / 30.0)
	if _has_prev_frame:
		var xf := frame * _prev_frame.affine_inverse()
		if xf.origin.length_squared() > 1e-16 or not xf.basis.is_equal_approx(Basis.IDENTITY):
			# 只搬输卵管小链；宫体节点由外部直接给出。
			for side in [0, 1]:
				var tb: Dictionary = _tubes.get(side, {})
				if tb.is_empty():
					continue
				var p: PackedVector3Array = tb["p"]
				var q: PackedVector3Array = tb["q"]
				for k in p.size():
					p[k] = xf * p[k]
				for k2 in q.size():
					q[k2] = xf * q[k2]
				tb["p"] = p
				tb["q"] = q
				_tubes[side] = tb
	_prev_frame = frame
	_has_prev_frame = true
	_frame = frame
	wound_center = portal
	if portal_out.length_squared() > 1e-8:
		outward = portal_out.normalized()
	if _x.size() != TETHER_N + SEGS:
		_init_particles()
	for t in TETHER_N:
		_x[t] = nodes[0]
		_xq[t] = nodes[0]
		_st[t] = 0
	for b in SEGS:
		var ci := TETHER_N + b
		_xq[ci] = _x[ci]
		_x[ci] = nodes[b]
		_st[ci] = 1 if (nodes[b] - portal).dot(outward) > 0.0 else 0
	_tlen = TETHER_MIN
	_sync_body()
	_update_bones()
	for side in [0, 1]:
		_step_tube(side, dt, false)
		# 宫角已在体外时，输卵管/卵巢留在外翻的阴道套筒里（不从套筒表面穿出来）。
		var ch: Dictionary = _chains.get(side, {})
		var vis := not (adnexa_hide_outside and _horn_is_out(side))
		var rope = ch.get("rope")
		if rope != null and is_instance_valid(rope):
			(rope as Node3D).visible = vis
		var ov = ch.get("ovary")
		if ov != null and is_instance_valid(ov):
			(ov as Node3D).visible = vis
	_rebuild_visual()
	if _tether_node and is_instance_valid(_tether_node):
		(_tether_node as Node3D).visible = false
	last_step_usec = Time.get_ticks_usec() - t0


## 当前蒙皮后的网格顶点（世界坐标），供脱垂检测穿模 / 套筒包裹。
func skinned_vertices() -> PackedVector3Array:
	return _skin_all()


## 静止网格顶点（校正后的腹部坐标）。
func rest_vertices_ab() -> PackedVector3Array:
	return _vis_rest
