extends Node
## 子宫脱垂系统（中央控制器）。
##
## 状态：连续的脱垂量（宫颈沿阴道下移的距离 descent，0..descent_max，amount = 0..1），按宫颈相对
## 外口（处女膜）的位置分 0–IV 度；状态机 none / driven / hanging / reducing。
##
## 解剖：子宫沿阴道往下（不是从腹部创口）。阴道在着色器里简化处理（prolapse_offset4）：通道被压短到
## 宫颈当前位置、被脱出物撑开，不再做双层内翻折叠，也不再有体外外翻套筒（t68u 性能重做）。
## 外口 / 阴唇由 ProlapseMassInserter（VulvaInserter）按脱出物截面从里往外撑开，通道半径跟着下移。
##
## 模型：脱垂期间原子宫 / 宫颈 / 内膜 / 输卵管 / 卵巢网格隐藏，换成专用的低面数 ProlapseUterusModel
## （宫颈 + 宫体 + IV 度时的细颈；整段统一用阴道黏膜材质，再染成更红润湿润的肉色）。
## 体外节点与细颈对跟随大腿骨骼的廉价胶囊做推出，避免卡进腿里。
## 物理：简化为 params.nodes（默认 5）个节点：
## 仍在体内的节点沿「外口 → 宫颈 → 子宫静止轴」的路径运动学放置；已出外口的节点是带惯性、重力的
## Verlet 链，锚在外口，关节限角（柔性悬挂），可被拖拽 / 甩动。
##
## 触发源可插拔：register_trigger(ProlapseTrigger)；try_trigger(id, ctx) 满足条件就开始驱动。
## 触发 #1 = 长柄金属球（BallRodProlapseTrigger）。
class_name ProlapseController

signal grade_changed(grade: int)
signal state_changed(state: String)
signal triggered(source: String)

const ModelScript := preload("res://scripts/body/prolapse/prolapse_uterus_model.gd")
const ParamsScript := preload("res://scripts/body/prolapse/prolapse_params.gd")
const InserterScript := preload("res://scripts/body/prolapse/prolapse_mass_inserter.gd")
const BallRodTriggerScript := preload("res://scripts/body/prolapse/ball_rod_trigger.gd")

const STATE_NONE := "none"
const STATE_DRIVEN := "driven"
const STATE_HANGING := "hanging"
const STATE_REDUCING := "reducing"
const GRADE_NAMES := ["0", "I", "II", "III", "IV"]
const PROF_N := 8
const GRAVITY := Vector3(0, -9.8, 0)

var organs: Node
var params: Resource
var descent: float = 0.0
var state: String = STATE_NONE
var grade: int = 0
var gravity: Vector3 = GRAVITY
var floor_y: float = -1e9
var last_step_usec: int = 0
var drive_source: String = ""

var _model: MeshInstance3D = null
var _src_body_mat: Material = null
var _src_cervix_mat: Material = null
## 每帧各部分开销（微秒）：sim / model / introitus / deform。
var prof_us: Dictionary = {}
var _geo_ok := false
var _n := 6
var _sigma := PackedFloat32Array()      # 各节点的静止路径坐标（外口 = 0，向里为正）
var _seg := PackedFloat32Array()
var _x := PackedVector3Array()
var _q := PackedVector3Array()
var _out := PackedByteArray()
var _rest_ab := PackedVector3Array()
var _prof := PackedFloat32Array()       # 截面半径，从宫颈端到宫底均分 PROF_N 份
var _U := 0.06
var _triggers: Dictionary = {}
var _drive_active := false
var _drive_node := 0
var _drive_target := Vector3.ZERO
var _drive_reduce := true
var _drive_feed := true
var _frame := Transform3D.IDENTITY
var _prev_frame := Transform3D.IDENTITY
var _has_prev := false
var _O := Vector3.ZERO                  # 外口（世界）
var _Ain := Vector3.UP                  # 外口 → 宫颈（世界，朝里）
var _up := Vector3.FORWARD
var _canal_L := 0.05                    # 外口到宫颈（posed 阴道中线）
var _inserter: RefCounted = null
var _owns_introitus := false
var _vel_hist: Array = []
var _skel: Skeleton3D = null
var _thigh_bi := PackedInt32Array()   # L_Upper, L_Fore, R_Upper, R_Fore
var _thigh_caps: Array = []           # [{a, b, r}]，每步刷新一次



func _init() -> void:
	params = ParamsScript.new()
	register_trigger(BallRodTriggerScript.new())


func setup(p_organs: Node) -> void:
	organs = p_organs
	set_physics_process(true)


# ------------------------------------------------------------------ 公共查询

func is_active() -> bool:
	return state != STATE_NONE


func amount() -> float:
	var dm := descent_max()
	return clampf(descent / dm, 0.0, 1.0) if dm > 1e-5 else 0.0


func descent_max() -> float:
	_ensure_geometry()
	if _sigma.is_empty():
		return 0.15
	return float(_sigma[_n - 1]) + float(params.fundus_out_max)


func grade_name() -> String:
	return GRADE_NAMES[clampi(grade, 0, 4)]


## 各度起点对应的 descent / amount（自检与 UI 共用）。
func grade_thresholds() -> Dictionary:
	_ensure_geometry()
	var dm := descent_max()
	var s0 := float(_sigma[0]) if not _sigma.is_empty() else 0.05
	var s5 := float(_sigma[_n - 1]) if not _sigma.is_empty() else 0.11
	var h := float(params.hymen_band)
	var d := {1: float(params.grade1_min), 2: s0 - h, 3: s0 + h, 4: s5}
	var a := {}
	for g in d.keys():
		a[g] = float(d[g]) / dm
	return {"descent": d, "amount": a, "descent_max": dm}


func grade_for_descent(dd: float) -> int:
	_ensure_geometry()
	if _sigma.is_empty() or dd < float(params.grade1_min):
		return 0
	var s_c := float(_sigma[0]) - dd
	if float(_sigma[_n - 1]) - dd <= 0.0:
		return 4
	var h := float(params.hymen_band)
	if s_c < -h:
		return 3
	if s_c <= h:
		return 2
	return 1


## 宫颈（最前端）相对外口的有符号距离：正 = 仍在阴道内（沿路径），负 = 已露出（直线距离）。
func cervix_signed_distance() -> float:
	if _x.is_empty():
		return float(_sigma[0]) - descent if not _sigma.is_empty() else 0.0
	var tip := _x[0]
	var sp := float(_sigma[0]) - descent
	if sp >= 0.0:
		return sp
	return -tip.distance_to(_O)


func fundus_signed_distance() -> float:
	if _sigma.is_empty():
		return 0.1
	var sp := float(_sigma[_n - 1]) - descent
	if sp >= 0.0 or _x.is_empty():
		return sp
	return -_x[_n - 1].distance_to(_O)


func introitus_world() -> Vector3:
	return _O


func canal_axis_world() -> Vector3:
	return _Ain


func node_positions() -> PackedVector3Array:
	return _x


func node_outside(i: int) -> bool:
	return i >= 0 and i < _out.size() and _out[i] == 1


func outside_count() -> int:
	var c := 0
	for v in _out:
		c += int(v)
	return c


func cervix_world() -> Vector3:
	return _x[0] if not _x.is_empty() else _O


func fundus_world() -> Vector3:
	return _x[_n - 1] if _x.size() >= _n else _O


## 脱垂专用子宫模型（断面小窗等拿去做拷贝）。旧接口名保留。
func soft_organ() -> Node:
	return _model


func model() -> MeshInstance3D:
	return _model


## t68u：外翻套筒已移除，恒为 null（旧调用方兼容）。
func sleeve() -> MeshInstance3D:
	return null


func inserter() -> RefCounted:
	return _inserter


func owns_introitus() -> bool:
	return _owns_introitus and is_active()


func profile() -> PackedFloat32Array:
	return _prof


func uterus_length() -> float:
	return _U


## 子宫截面半径（米），a = 从宫颈尖沿子宫轴往宫底的距离。a < 0 是宫颈前端的圆顶。
func mass_radius_at(a: float) -> float:
	if _prof.is_empty():
		return 0.0
	var r0 := float(_prof[0])
	if a < 0.0:
		var t := clampf(-a / maxf(r0, 1e-4), 0.0, 1.0)
		return r0 * sqrt(maxf(1.0 - t * t, 0.0))
	if a >= _U:
		return 0.0
	var f := a / _U * float(PROF_N - 1)
	var i := clampi(int(floor(f)), 0, PROF_N - 2)
	return lerpf(float(_prof[i]), float(_prof[i + 1]), clampf(f - float(i), 0.0, 1.0))



## 点是否落在脱垂宫体内部（沿中线的截面半径内，且在宫颈→宫底这一侧）。
func point_in_prolapse_cavity(p: Vector3) -> Dictionary:
	var out := {"inside": false, "along": -1.0, "radial": 99.0, "radius": 0.0, "toward_fundus": false}
	if _x.size() < 2:
		return out
	var best_d := 1e9
	var best_a := 0.0
	var acc := 0.0
	for i in _x.size() - 1:
		var a: Vector3 = _x[i]
		var b: Vector3 = _x[i + 1]
		var ab := b - a
		var L := ab.length()
		if L < 1e-8:
			continue
		var tt := clampf((p - a).dot(ab) / (L * L), 0.0, 1.0)
		var q := a + ab * tt
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			best_a = acc + L * tt
		acc += L
	var r := mass_radius_at(best_a)
	out["along"] = best_a
	out["radial"] = best_d
	out["radius"] = r
	out["toward_fundus"] = best_a > 0.001
	out["inside"] = best_a > 0.001 and best_a < maxf(_U, 0.002) and best_d < r + 0.0015
	return out


## 外口处（路径坐标 0）当前穿过的截面半径：宫颈 / 宫体截面 + 阴道壁；IV 度后为细颈。
func portal_radius() -> float:
	if _sigma.is_empty() or descent <= 0.0:
		return 0.0
	var a := descent - float(_sigma[0])   # 外口处对应的子宫弧长
	var w := float(params.wall)
	# 与阴道撑开一致：截面半径 + 壁 + 4 mm 余量，外口不比管腔更紧。
	var margin := 0.004
	if _prof.is_empty() or a < -float(_prof[0]):
		return 0.0
	if a >= _U * 0.92:
		return maxf(float(params.neck_r), mass_radius_at(_U * 0.92)) + w + margin
	return mass_radius_at(a) + w * 2.0 + margin


# ------------------------------------------------------------------ 触发源

func register_trigger(t: RefCounted) -> void:
	if t == null or not t.has_method("id"):
		return
	_triggers[str(t.call("id"))] = t


func trigger(tid: String) -> RefCounted:
	return _triggers.get(tid, null)


func trigger_ids() -> Array:
	return _triggers.keys()


## 触发源报告情况；条件满足则开始驱动（drive_node 由触发源决定）。返回是否触发。
func try_trigger(tid: String, ctx: Dictionary) -> bool:
	var t: RefCounted = _triggers.get(tid, null)
	if t == null:
		return false
	# 子宫已经被手术从创口扯出时不能再脱垂。
	if organs and bool(organs.get_meta("uterus_extracted", false)):
		return false
	if not bool(t.call("evaluate", ctx, params)):
		return false
	_ensure_active()
	if not _geo_ok:
		return false
	begin_drive(tid, int(t.call("drive_node")), ctx.get("target", cervix_world()), bool(t.call("allows_reduce")))
	triggered.emit(tid)
	return true


# ------------------------------------------------------------------ 驱动 / 拖拽

## 开始牵拉某个节点（触发源 / 手 / 钳子）。目标为世界坐标。
## allow_feed = false（T-11 手术拿取工具）：只拖动 / 甩动体外部分，不加重也不复位脱垂。
func begin_drive(src: String, node_i: int, target: Vector3, allow_reduce: bool = true, allow_feed: bool = true) -> void:
	_ensure_active()
	if not _geo_ok:
		return
	drive_source = src
	_drive_active = true
	_drive_node = clampi(node_i, 0, _n - 1)
	_drive_target = target
	_drive_reduce = allow_reduce and bool(params.hand_reduce)
	_drive_feed = allow_feed
	_set_state(STATE_DRIVEN)


func drive_to(target: Vector3) -> void:
	if _drive_active and target.is_finite():
		_drive_target = target


func end_drive() -> void:
	if not _drive_active:
		return
	_drive_active = false
	drive_source = ""
	if descent > 1e-5:
		_set_state(STATE_HANGING)


func is_driving() -> bool:
	return _drive_active


func drive_node() -> int:
	return _drive_node if _drive_active else -1


## 拾取体外脱出物：返回 {node, point, dist}，没命中返回 {}。
func ray_pick(origin: Vector3, dir: Vector3, max_perp: float = 0.0) -> Dictionary:
	if not is_active() or _x.is_empty():
		return {}
	var d := dir.normalized()
	var best := {}
	var best_t := 1e9
	for i in _n:
		if _out[i] == 0:
			continue
		var p := _x[i]
		var t := (p - origin).dot(d)
		if t <= 0.0:
			continue
		var perp := (origin + d * t).distance_to(p)
		var lim := max_perp if max_perp > 0.0 else mass_radius_at(_arc_of(i)) + float(params.wall) + 0.004
		if perp <= lim and t < best_t:
			best_t = t
			best = {"node": i, "point": origin + d * t, "dist": perp}
	return best


## 手术：经腹部创口向外拉时按拉出量复位脱垂（先复位，后才进入创口扯出）。返回剩余 descent。
func surgery_reduce(pull_dist: float, dt: float) -> float:
	if not is_active():
		return 0.0
	if pull_dist > 0.0:
		var stp := minf(pull_dist * float(params.surgery_reduce_gain), float(params.surgery_reduce_speed_max) * maxf(dt, 1e-3))
		descent = maxf(descent - stp, 0.0)
		_set_state(STATE_REDUCING)
	return descent


## 手术钳经创口夹住体内的子宫部分：进入复位状态（descent 由 surgery_reduce 按拉出量减少）。
func begin_surgery_reduce() -> void:
	if not is_active():
		return
	_drive_active = false
	drive_source = "surgery"
	_set_state(STATE_REDUCING)


func end_surgery_reduce() -> void:
	if drive_source == "surgery":
		drive_source = ""
	if is_active() and descent > 1e-5:
		_set_state(STATE_HANGING)


## 子宫静止时宫底的世界位置（手术从创口点选用）。
func rest_fundus_world() -> Vector3:
	if _rest_ab.size() < _n:
		return _O
	return _frame * _rest_ab[_n - 1]


## 其它系统把子宫 / 附件重新显示后调用：脱垂中原网格继续隐藏。
func rehide_sources() -> void:
	if not is_active() or organs == null:
		return
	for k in ["uterus", "uterus_cavity", "tube", "ovary"]:
		organs.call("set_kind_visible", k, false)


## 直接设定脱垂量（0..1）：预设 / 自检 / 读档。体外部分先沿通道方向伸直，再交给物理摆下去。
func set_amount(a: float) -> void:
	var target := clampf(a, 0.0, 1.0)
	if target <= 0.0:
		reset()
		return
	_ensure_active()
	if not _geo_ok:
		return
	descent = target * descent_max()
	_refresh_path()
	for i in _n:
		var sp := float(_sigma[i]) - descent
		_x[i] = _path(sp)
		_q[i] = _x[i]
		_out[i] = 1 if sp < 0.0 else 0
	if not _drive_active:
		_set_state(STATE_HANGING)
	_finish(0.0)


## 复原：脱垂完全回位（「复原」/「放回内脏」/ 退出前清理）。
func reset() -> void:
	_drive_active = false
	drive_source = ""
	descent = 0.0
	if state != STATE_NONE:
		_deactivate()


# ------------------------------------------------------------------ 内部：几何

func _ensure_geometry() -> void:
	if _geo_ok or organs == null:
		return
	if not organs.has_method("viscera_meshes"):
		return
	var ut: Array = organs.call("viscera_meshes", "uterus")
	if ut.is_empty():
		return
	var src: MeshInstance3D = null
	for m in ut:
		if m is MeshInstance3D and (m as MeshInstance3D).mesh != null:
			src = m
			break
	if src == null or not src.is_inside_tree():
		return
	_update_frame()
	var canal: Dictionary = organs.call("vagina_canal")
	if canal.is_empty():
		return
	# 子宫主轴：网格顶点 PCA；靠近阴道宫颈端的一头 = 宫颈。
	var P: PackedVector3Array = PackedVector3Array()
	for m2 in ut:
		var mi := m2 as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		P.append_array(arr[Mesh.ARRAY_VERTEX])
	if P.size() < 16:
		return
	var c := Vector3.ZERO
	for p in P:
		c += p
	c /= float(P.size())
	var cov := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var xx := 0.0
	var xy := 0.0
	var xz := 0.0
	var yy := 0.0
	var yz := 0.0
	var zz := 0.0
	for p2 in P:
		var v := p2 - c
		xx += v.x * v.x
		xy += v.x * v.y
		xz += v.x * v.z
		yy += v.y * v.y
		yz += v.y * v.z
		zz += v.z * v.z
	var ax := Vector3(0.3, 1.0, 0.2).normalized()
	for _it in 40:
		var nv := Vector3(xx * ax.x + xy * ax.y + xz * ax.z, xy * ax.x + yy * ax.y + yz * ax.z, xz * ax.x + yz * ax.y + zz * ax.z)
		if nv.length_squared() < 1e-20:
			break
		ax = nv.normalized()
	var ts: Array = []
	for p3 in P:
		ts.append((p3 - c).dot(ax))
	ts.sort()
	var t_lo := float(ts[int(ts.size() * 0.01)])
	var t_hi := float(ts[int(ts.size() * 0.99)])
	var end_a := c + ax * t_lo
	var end_b := c + ax * t_hi
	var gx := src.global_transform
	var cerv_w: Vector3 = canal.get("cervix_world", gx * end_a)
	var cerv_raw := end_a
	var fund_raw := end_b
	if (gx * end_b).distance_to(cerv_w) < (gx * end_a).distance_to(cerv_w):
		cerv_raw = end_b
		fund_raw = end_a
	# t68u：不再借用 SoftOrgan（3839 顶点蒙皮 + 输卵管卵巢），直接在腹部坐标里放 N 个节点。
	var inv := _frame.affine_inverse()
	var cw := gx * cerv_raw
	var fw := gx * fund_raw
	_n = clampi(int(params.nodes), 3, 8)
	_rest_ab = PackedVector3Array()
	for i in _n:
		_rest_ab.append(inv * cw.lerp(fw, float(i) / float(_n - 1)))
	_seg = PackedFloat32Array()
	for i1 in _n - 1:
		_seg.append(_rest_ab[i1].distance_to(_rest_ab[i1 + 1]))
	_U = 0.0
	for sg in _seg:
		_U += float(sg)
	var V := PackedVector3Array()
	var xf := inv * gx
	for p4 in P:
		V.append(xf * p4)
	_build_profile(V)
	# 材质：整段（宫体 + 宫颈 + 细颈）都用原阴道黏膜材质，再染成更红润、更湿润的肉色。
	# 贴图细节保留；宫颈只比宫体略深，没有子宫红 / 阴道粉的硬边。
	_src_body_mat = _dup_mat((src as MeshInstance3D).material_override)
	var vag_mat: Material = null
	var vg: Array = organs.call("viscera_meshes", "vagina")
	for m5 in vg:
		var mi5 := m5 as MeshInstance3D
		if mi5 and mi5.material_override:
			vag_mat = mi5.material_override
			break
	if vag_mat:
		_src_body_mat = _tint_mucosa(_dup_mat(vag_mat), false)
		_src_cervix_mat = _tint_mucosa(_dup_mat(vag_mat), true)
	else:
		_src_body_mat = _tint_mucosa(_src_body_mat, false)
		_src_cervix_mat = _tint_mucosa(_src_body_mat, true)
	_x.resize(_n)
	_q.resize(_n)
	_out.resize(_n)
	_geo_ok = true
	_refresh_path()
	for i2 in _n:
		_x[i2] = _frame * _rest_ab[i2]
		_q[i2] = _x[i2]
		_out[i2] = 0


func _dup_mat(m: Material) -> Material:
	if m == null:
		return null
	var d := m.duplicate() as Material
	if d is ShaderMaterial:
		var sm := d as ShaderMaterial
		sm.set_shader_parameter("is_uterus", false)
		sm.set_shader_parameter("is_gut", false)
		sm.set_shader_parameter("prol_o", Vector4.ZERO)
		sm.set_shader_parameter("uterus_phys_on", 0.0)
		sm.set_meta("prolapse_model", true)
	return d


func _tint_mucosa(m: Material, cervix: bool) -> Material:
	if m == null:
		return null
	if not (m is ShaderMaterial):
		return m
	var sm := m as ShaderMaterial
	var use_tex := bool(sm.get_shader_parameter("use_tex"))
	if cervix:
		sm.set_shader_parameter("base_color", params.cervix_tex_tint if use_tex else params.cervix_solid)
	else:
		sm.set_shader_parameter("base_color", params.mucosa_tex_tint if use_tex else params.mucosa_solid)
	sm.set_shader_parameter("wet", float(params.mucosa_wet))
	sm.set_shader_parameter("roughness", float(params.mucosa_roughness))
	return sm


func mucosa_look() -> Dictionary:
	var body := _src_body_mat as ShaderMaterial
	var cerv := _src_cervix_mat as ShaderMaterial
	return {
		"body": body,
		"cervix": cerv,
		"body_color": body.get_shader_parameter("base_color") if body else Color.BLACK,
		"cervix_color": cerv.get_shader_parameter("base_color") if cerv else Color.BLACK,
		"wet": body.get_shader_parameter("wet") if body else 0.0,
		"roughness": body.get_shader_parameter("roughness") if body else 1.0,
		"use_tex": bool(body.get_shader_parameter("use_tex")) if body else false,
		"tex": body.get_shader_parameter("albedo_tex") if body else null,
		"shader": body.shader if body else null,
	}


func _build_profile(V: PackedVector3Array) -> void:
	# 截面：静止网格顶点到子宫轴的径向距离，按轴向分箱取分位数。
	_prof.resize(PROF_N)
	var a0 := _rest_ab[0]
	var a1 := _rest_ab[_n - 1]
	var ax := (a1 - a0)
	var L := maxf(ax.length(), 1e-4)
	ax /= L
	var bins: Array = []
	for b in PROF_N:
		bins.append([])
	for v in V:
		var t := (v - a0).dot(ax)
		var b2 := clampi(int(round(t / L * float(PROF_N - 1))), 0, PROF_N - 1)
		(bins[b2] as Array).append(((v - a0) - ax * t).length())
	var q := clampf(float(params.radius_quantile), 0.1, 1.0)
	for b3 in PROF_N:
		var arr: Array = bins[b3]
		if arr.is_empty():
			_prof[b3] = 0.0
			continue
		arr.sort()
		_prof[b3] = float(arr[clampi(int(arr.size() * q), 0, arr.size() - 1)]) * float(params.radius_scale)
	# 空箱用邻居补；宫颈端不小于 8 mm。
	for b4 in PROF_N:
		if _prof[b4] <= 1e-4:
			_prof[b4] = _prof[b4 - 1] if b4 > 0 else 0.010
	_prof[0] = maxf(_prof[0], 0.008)


func _update_frame() -> void:
	if organs and organs.has_method("abdomen_frame"):
		_frame = organs.call("abdomen_frame")


## 外口、通道方向与各节点静止路径坐标。路径：外口 → 宫颈尖（节点 0 静止位）→ 子宫静止轴。
var _canal_ab := {}
var _canal_cool := 0


## 阴道通道（外口 / 宫颈 / 朝上）在腹部坐标里缓存，每 CANAL_REFRESH 个物理帧才重新拟合一次
## （拟合要 CPU 蒙皮整根阴道，以前每帧都做）。
const CANAL_REFRESH := 20


func _refresh_path(force: bool = false) -> void:
	if organs == null:
		return
	_canal_cool -= 1
	if force or _canal_ab.is_empty() or _canal_cool <= 0:
		var canal: Dictionary = organs.call("vagina_canal")
		if not canal.is_empty():
			var inv := _frame.affine_inverse()
			_canal_ab = {"o": inv * (canal["opening_world"] as Vector3), "c": inv * (canal["cervix_world"] as Vector3), "up": canal.get("up_ab", Vector3(0, 0, 1))}
		_canal_cool = CANAL_REFRESH
	if not _canal_ab.is_empty():
		_O = _frame * (_canal_ab["o"] as Vector3)
		var cw: Vector3 = _frame * (_canal_ab["c"] as Vector3)
		_canal_L = maxf(_O.distance_to(cw), 0.02)
		_up = (_frame.basis * (_canal_ab["up"] as Vector3)).normalized()
	if not _geo_ok:
		return
	var r0 := _frame * _rest_ab[0]
	_Ain = (r0 - _O)
	if _Ain.length_squared() < 1e-8:
		_Ain = Vector3.UP
	_Ain = _Ain.normalized()
	_sigma.resize(_n)
	_sigma[0] = _O.distance_to(r0)
	for i in range(1, _n):
		_sigma[i] = float(_sigma[i - 1]) + float(_seg[i - 1])


## 路径坐标 → 世界点。σ < 0（体外）沿通道方向直线外延，只用于新出外口节点的初值。
func _path(sp: float) -> Vector3:
	if sp <= float(_sigma[0]):
		return _O + _Ain * sp
	for i in range(1, _n):
		if sp <= float(_sigma[i]):
			var a := _frame * _rest_ab[i - 1]
			var b := _frame * _rest_ab[i]
			var t := (sp - float(_sigma[i - 1])) / maxf(float(_seg[i - 1]), 1e-6)
			return a.lerp(b, t)
	var last := _frame * _rest_ab[_n - 1]
	var prev := _frame * _rest_ab[_n - 2]
	return last + (last - prev).normalized() * (sp - float(_sigma[_n - 1]))


func _arc_of(i: int) -> float:
	var a := 0.0
	for k in mini(i, _seg.size()):
		a += float(_seg[k])
	return a


# ------------------------------------------------------------------ 内部：状态

func _ensure_active() -> void:
	_ensure_geometry()
	if not _geo_ok or state != STATE_NONE:
		return
	_update_frame()
	_refresh_path(true)
	_ensure_model()
	_model.call("invalidate")
	for k in ["uterus", "uterus_cavity", "tube", "ovary"]:
		organs.call("set_kind_visible", k, false)
	for i in _n:
		_x[i] = _frame * _rest_ab[i]
		_q[i] = _x[i]
		_out[i] = 0
	_prev_frame = _frame
	_has_prev = true
	_deform_sig = Vector4(-1, -1, -1, -1)
	_set_state(STATE_HANGING)


func _deactivate() -> void:
	if _model and is_instance_valid(_model):
		_model.visible = false
	if organs:
		for k in ["uterus", "uterus_cavity", "tube", "ovary"]:
			organs.call("set_kind_visible", k, true)
		if organs.has_method("clear_prolapse_deform"):
			organs.call("clear_prolapse_deform")
		if _owns_introitus and organs.get("vulva") != null and organs.vulva.has_method("set_inserter"):
			organs.vulva.call("set_inserter", null)
	_owns_introitus = false
	descent = 0.0
	_drive_active = false
	drive_source = ""
	_has_prev = false
	var g0 := grade
	grade = 0
	_set_state(STATE_NONE)
	if g0 != 0:
		grade_changed.emit(0)


func _set_state(s: String) -> void:
	if s == state:
		return
	state = s
	state_changed.emit(s)


func _ensure_model() -> void:
	if _model and is_instance_valid(_model):
		return
	_model = ModelScript.new()
	_model.name = "ProlapseUterusModel"
	add_child(_model)
	_model.call("set_materials", _src_body_mat, _src_cervix_mat)
	_model.visible = false


# ------------------------------------------------------------------ 每帧

func _physics_process(dt: float) -> void:
	step(dt)


func step(dt: float) -> void:
	if state == STATE_NONE or not _geo_ok:
		return
	var t0 := Time.get_ticks_usec()
	var t_sim := 0
	dt = clampf(dt, 0.0, 1.0 / 30.0)
	_update_frame()
	if _has_prev:
		var xf := _frame * _prev_frame.affine_inverse()
		if xf.origin.length_squared() > 1e-16 or not xf.basis.is_equal_approx(Basis.IDENTITY):
			for i in _n:
				_x[i] = xf * _x[i]
				_q[i] = xf * _q[i]
			if _drive_active:
				_drive_target = xf * _drive_target
	_prev_frame = _frame
	_has_prev = true
	_refresh_path()
	var dmax := descent_max()
	# 1) 牵拉 → 下移 / 往回推 → 手法复位
	if _drive_active and dt > 0.0:
		var h := _drive_node
		var sp_h := float(_sigma[h]) - descent
		var rel := _drive_target - _O
		var s_t := rel.dot(_Ain)
		if s_t < 0.0:
			s_t = -rel.length()
		var e := sp_h - s_t
		if e > 0.0 and _drive_feed:
			descent += minf(e * float(params.feed_gain) * dt, float(params.feed_speed_max) * dt)
		elif _drive_reduce and -e > float(params.reduce_deadband):
			descent -= minf((-e - float(params.reduce_deadband)) * float(params.feed_gain) * dt, float(params.reduce_speed_max) * dt)
	descent = clampf(descent, 0.0, dmax)
	var ts := Time.get_ticks_usec()
	_simulate(dt)
	t_sim = Time.get_ticks_usec() - ts
	_finish(dt)
	prof_us["sim"] = t_sim
	# 完全回位且没人抓着 → 退出（抓着时即使推回到 0 也保持，便于继续拉）。
	if descent <= 1e-5 and not _drive_active and state != STATE_REDUCING:
		_deactivate()
	last_step_usec = int(Time.get_ticks_usec() - t0)


func _drive_pulling() -> bool:
	if not _drive_active:
		return false
	var rel := _drive_target - _O
	return rel.dot(_Ain) < float(_sigma[_drive_node]) - 0.003



func _apply_collision_corr(i: int, corr: Vector3, stiff: float = -1.0) -> void:
	if i < 0 or i >= _n:
		return
	if not corr.is_finite() or corr.length_squared() < 1e-16:
		return
	var m := float(params.collision_impulse_max)
	if m > 1e-8 and corr.length() > m:
		corr = corr.normalized() * m
	var s := float(params.collision_push) if stiff < 0.0 else stiff
	corr *= clampf(s, 0.0, 1.0)
	_x[i] += corr
	_q[i] += corr * clampf(float(params.collision_vel_absorb), 0.0, 1.0)


func _apply_collision_to(i: int, new_p: Vector3, stiff: float = -1.0) -> void:
	if i < 0 or i >= _n:
		return
	_apply_collision_corr(i, new_p - _x[i], stiff)

func _simulate(dt: float) -> void:
	var k60 := dt * 60.0
	var air := pow(float(params.air_damp), k60)
	var vmax := float(params.max_speed) * dt
	var drv := _drive_node if _drive_active else -1
	var portal_out := -_Ain
	_refresh_thigh_caps()
	for i in _n:
		var sp := float(_sigma[i]) - descent
		if sp >= 0.0:
			var p := _path(sp)
			_q[i] = p
			_x[i] = p
			_out[i] = 0
			continue
		if _out[i] == 0:
			# 刚出外口：沿通道方向接出去（不要从体内那一侧被链接约束拉回去）。
			_x[i] = _path(sp)
			_q[i] = _x[i]
			_out[i] = 1
			continue
		var cur := _x[i]
		var v := (cur - _q[i]) * air
		if v.length() > vmax:
			v = v.normalized() * vmax
		v += gravity * dt * dt
		_q[i] = cur
		_x[i] = cur + v
	var k := 0
	while k < _n and _out[k] == 1:
		k += 1
	if k == 0:
		return
	# 牵拉节点：贴着目标，但不超过可用长度。
	var hold := Vector3.INF
	if drv >= 0 and drv < k:
		var avail := descent - float(_sigma[drv])
		var rel := _drive_target - _O
		if rel.length() > avail + 0.002:
			rel = rel.normalized() * (avail + 0.002)
		hold = _O + rel
		_x[drv] = hold
	var iters := int(params.iterations)
	var inside_pt := _O + _Ain * 0.012
	for _it in iters:
		# 外口锚：节点 k-1 到外口的材料长度。
		var ia := k - 1
		var la := descent - float(_sigma[ia])
		var d0 := _x[ia] - _O
		var L0 := d0.length()
		if L0 < 1e-7:
			d0 = portal_out
			L0 = 1.0
		if ia != drv:
			if k < _n:
				_x[ia] = _O + d0 / L0 * la
			elif L0 > la:
				_x[ia] = _O + d0 / L0 * la
		# 宫体段长
		for b in range(k - 1, 0, -1):
			_link(b, b - 1, float(_seg[b - 1]), drv)
		# 外口折角、关节限角（从锚往外，只动远端）
		_limit_angle(inside_pt, _O, ia, float(params.max_portal_bend), drv)
		for j in range(k - 1, 0, -1):
			var a_pt := _O if j == k - 1 else _x[j + 1]
			_limit_angle(a_pt, _x[j], j - 1, float(params.max_joint_bend), drv)
		# 不能回到会阴平面以内；不低于地面；不穿进大腿。推出要吸收进 _q，避免轻飘乱抽。
		for b2 in k:
			if b2 == drv:
				continue
			var rel2 := _x[b2] - _O
			var dn := rel2.dot(portal_out)
			if dn < 0.0:
				_apply_collision_corr(b2, -portal_out * dn)
			if _x[b2].y < floor_y + 0.012:
				_apply_collision_corr(b2, Vector3(0.0, floor_y + 0.012 - _x[b2].y, 0.0))
			_apply_collision_to(b2, _push_out_thighs(_x[b2], _node_radius(b2)))
		# 整段体外管（宫体段 + 宫底到外口的细颈）对大腿做胶囊-胶囊推出。
		if hold != Vector3.INF:
			hold = _push_out_thighs(hold, _node_radius(drv))
			_x[drv] = hold
		_resolve_tube_thighs(k)
		if drv >= 0 and drv < k:
			_apply_collision_to(drv, _push_out_thighs(_x[drv], _node_radius(drv)))
			if hold != Vector3.INF:
				hold = _x[drv]
	# 迭代后若仍陷入，再略硬地推一次，同样吸收速度。
	var still_in := false
	for b3 in k:
		if _point_thigh_clearance(_x[b3], _node_radius(b3)) < -1e-5:
			still_in = true
			break
	if still_in:
		for b4 in k:
			_apply_collision_to(b4, _push_out_thighs(_x[b4], _node_radius(b4)), 0.85)
		_resolve_tube_thighs(k)
	for i3 in _n:
		if not _x[i3].is_finite():
			_x[i3] = _path(float(_sigma[i3]) - descent)
			_q[i3] = _x[i3]


func _link(a: int, b: int, rest: float, drv: int) -> void:
	# a 靠锚一侧，b 远端。被牵拉节点不动。
	var d := _x[b] - _x[a]
	var L := d.length()
	if L < 1e-9:
		return
	var corr := d * ((L - rest) / L)
	var wa := 0.0 if a == drv else 0.35
	var wb := 0.0 if b == drv else 1.0
	var ws := wa + wb
	if ws <= 0.0:
		return
	_x[a] += corr * (wa / ws)
	_x[b] -= corr * (wb / ws)


func _limit_angle(a: Vector3, b: Vector3, ci: int, max_ang: float, drv: int) -> void:
	if ci < 0 or ci == drv:
		return
	var din := b - a
	var dout := _x[ci] - b
	var li := din.length()
	var lo := dout.length()
	if li < 1e-7 or lo < 1e-7:
		return
	din /= li
	var dn := dout / lo
	var ang := acos(clampf(din.dot(dn), -1.0, 1.0))
	if ang <= max_ang:
		return
	var axis := din.cross(dn)
	if axis.length_squared() < 1e-12:
		axis = din.cross(Vector3.RIGHT if absf(din.x) < 0.9 else Vector3.UP)
	axis = axis.normalized()
	var nd := din.rotated(axis, max_ang)
	_x[ci] = b + nd * lo


func _node_radius(i: int) -> float:
	# 宫底端点截面会收到 0，碰撞用靠近宫底的体半径，避免只把细尖推出、宫体还陷在腿里。
	var a := _arc_of(i)
	var a_hi := _U * 0.90
	var a0 := clampf(a - 0.010, 0.0, a_hi)
	var a1 := clampf(a, 0.0, a_hi)
	var a2 := clampf(a + 0.010, 0.0, a_hi)
	return maxf(maxf(mass_radius_at(a0), mass_radius_at(a1)), maxf(mass_radius_at(a2), 0.008))


func _ensure_skel() -> Skeleton3D:
	if _skel != null and is_instance_valid(_skel):
		return _skel
	_skel = null
	_thigh_bi = PackedInt32Array()
	if organs == null:
		return null
	var s = organs.get("_skel")
	if s is Skeleton3D:
		_skel = s
	else:
		var n: Node = organs.get_parent()
		while n:
			if n is Skeleton3D:
				_skel = n
				break
			if n.has_method("get_skeleton"):
				var g = n.call("get_skeleton")
				if g is Skeleton3D:
					_skel = g
					break
			n = n.get_parent()
	if _skel:
		_thigh_bi = PackedInt32Array([
			_skel.find_bone("L_UpperLeg_a"),
			_skel.find_bone("L_Foreleg_a"),
			_skel.find_bone("R_UpperLeg_a"),
			_skel.find_bone("R_Foreleg_a"),
		])
	return _skel


func _refresh_thigh_caps() -> void:
	_thigh_caps = []
	var sk := _ensure_skel()
	if sk == null or _thigh_bi.size() < 4:
		return
	var xf := sk.global_transform
	var r := float(params.thigh_r)
	var inset := float(params.thigh_hip_inset)
	var off := float(params.thigh_lateral_offset)
	var hips := PackedVector3Array()
	var knees := PackedVector3Array()
	var names: Array = []
	for s in 2:
		var ia := int(_thigh_bi[s * 2])
		var ib := int(_thigh_bi[s * 2 + 1])
		if ia < 0 or ib < 0:
			continue
		hips.append(xf * sk.get_bone_global_pose(ia).origin)
		knees.append(xf * sk.get_bone_global_pose(ib).origin)
		names.append("L" if s == 0 else "R")
	var mid := Vector3.ZERO
	if hips.size() == 2:
		mid = (hips[0] + hips[1]) * 0.5
	for i in hips.size():
		var hip: Vector3 = hips[i]
		var knee: Vector3 = knees[i]
		var axis := knee - hip
		var alen := axis.length()
		if alen > 1e-6:
			axis /= alen
		else:
			axis = Vector3.DOWN
		var a: Vector3 = hip
		if inset > 0.0 and alen > 1e-4:
			a = hip + axis * minf(inset, alen * 0.35)
		# 左右方向用骨盆髋关节连线（内缩前），不要用内缩后的点，避免检查床屈髋时把胶囊偏进悬垂通道。
		var side := hip - mid
		side -= axis * side.dot(axis)
		if side.length_squared() < 1e-8:
			side = axis.cross(_frame.basis.x if _frame.basis.x.length_squared() > 1e-8 else Vector3.RIGHT)
		if side.length_squared() < 1e-8:
			side = Vector3.RIGHT
		side = side.normalized()
		# 保证 side 指向这一侧的外侧（离开正中面）。
		if hips.size() == 2 and side.dot(hip - mid) < 0.0:
			side = -side
		var b: Vector3 = knee
		if off != 0.0 and hips.size() == 2:
			a += side * off
			b += side * off
		_thigh_caps.append({"a": a, "b": b, "r": r, "name": names[i], "axis": axis, "side": side})


func thigh_capsules() -> Array:
	if _thigh_caps.is_empty():
		_refresh_thigh_caps()
	return _thigh_caps


## 体外节点（含截面半径）相对大腿胶囊的最小间隙：正 = 在外，负 = 陷入。
func thigh_clearance() -> float:
	if _thigh_caps.is_empty():
		_refresh_thigh_caps()
	if _thigh_caps.is_empty() or _x.is_empty():
		return 1.0
	var best := 1.0
	for i in _n:
		if _out.size() <= i or _out[i] == 0:
			continue
		best = minf(best, _point_thigh_clearance(_x[i], _node_radius(i)))
	# 细颈靠宫底的一半：靠近外口的一段必须回到两腿之间，不计入“卡进腿里”。
	if not _sigma.is_empty() and float(_sigma[_n - 1]) - descent < 0.0:
		var fund := _x[_n - 1]
		for t in 2:
			var u := float(t + 1) / 6.0
			best = minf(best, _point_thigh_clearance(fund.lerp(_O, u), float(params.neck_r)))
	return best


func _point_thigh_clearance(p: Vector3, rad: float) -> float:
	# 与推出一致：按开口圆柱（垂直腿轴的径向距离）量间隙，髋端球面帽不算在内，
	# 否则悬在两腿之间会被帽顶判成“陷入”。
	var best := 1.0
	var extra := rad + float(params.thigh_margin)
	for cap in _thigh_caps:
		best = minf(best, _cyl_clearance(p, cap) - extra)
	return best


func _cyl_clearance(p: Vector3, cap: Dictionary) -> float:
	var hit: Dictionary = _shaft_proj(p, cap)
	if not bool(hit["hit"]):
		return 1.0
	return float(hit["dist"]) - float(cap["r"])


## 开口圆柱：髋端（a）敞开。投影在髋端之前（会阴 / 悬垂空间）不算碰撞，避免髋端圆盘把子宫托住。
func _shaft_proj(p: Vector3, cap: Dictionary) -> Dictionary:
	var a: Vector3 = cap["a"]
	var b: Vector3 = cap["b"]
	var axis: Vector3 = cap["axis"] if cap.has("axis") else (b - a).normalized()
	var ab := b - a
	var denom := ab.length_squared()
	if denom < 1e-12:
		return {"hit": false, "c": a, "dist": 1.0}
	var t := (p - a).dot(ab) / denom
	if t < 0.0:
		return {"hit": false, "c": a, "dist": 1.0}
	t = minf(t, 1.0)
	var c := a + ab * t
	var d := p - c
	var d_perp := d - axis * d.dot(axis)
	return {"hit": true, "c": c, "d_perp": d_perp, "dist": d_perp.length(), "axis": axis}


func _closest_on_seg(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var denom := ab.length_squared()
	if denom < 1e-12:
		return a
	return a + ab * clampf((p - a).dot(ab) / denom, 0.0, 1.0)


func _push_out_thighs(p: Vector3, rad: float) -> Vector3:
	if _thigh_caps.is_empty():
		return p
	var q := p
	var need_extra := rad + float(params.thigh_margin)
	for _k in 2:
		for cap in _thigh_caps:
			q = _thigh_correction(q, cap, float(cap["r"]) + need_extra)
	# 被两腿同时夹住、侧向推不出去时，顶到腿前面再往下垂；只接触一条腿时只侧向推。
	if _is_thigh_squeeze(q, rad):
		q = _escape_ventral(q, rad)
	return q


func _is_thigh_squeeze(p: Vector3, rad: float) -> bool:
	if _thigh_caps.size() < 2:
		return false
	var extra := rad + float(params.thigh_margin)
	var n := 0
	for cap in _thigh_caps:
		if _cyl_clearance(p, cap) < extra - 1e-5:
			n += 1
	return n >= 2


func _ventral_dir() -> Vector3:
	# 腹前（腹部坐标 +Z）。两腿时取垂直于腿轴和左右连线、朝腹侧的方向。
	var v := _frame.basis.z
	if _thigh_caps.size() == 2:
		var ax: Vector3 = (_thigh_caps[0]["axis"] as Vector3) + (_thigh_caps[1]["axis"] as Vector3)
		if ax.length_squared() > 1e-8:
			ax = ax.normalized()
			var lr: Vector3 = _thigh_caps[1]["a"] - _thigh_caps[0]["a"]
			var n := lr.cross(ax)
			if n.length_squared() > 1e-8:
				n = n.normalized()
				if v.length_squared() > 1e-8 and n.dot(v) < 0.0:
					n = -n
				v = n
	if v.length_squared() < 1e-8:
		v = _up if _up.length_squared() > 1e-8 else Vector3.FORWARD
	return v.normalized()


func _escape_ventral(p: Vector3, rad: float) -> Vector3:
	var v := _ventral_dir()
	var up := Vector3.UP
	if gravity.length_squared() > 1e-8:
		up = -gravity.normalized()
	# 仰卧时腹侧朝上：沿腹侧推等于托起来。去掉逆重力分量，几乎只剩向上则放弃，让器官靠重力落下。
	var lift := v.dot(up)
	if lift > 0.0:
		v -= up * lift
	if v.length() < 0.35:
		return p
	v = v.normalized()
	var extra := rad + float(params.thigh_margin)
	var t_need := 0.0
	for cap in _thigh_caps:
		var need := float(cap["r"]) + extra
		var axis: Vector3 = cap["axis"]
		var c := _closest_on_seg(p, cap["a"], cap["b"])
		var d_perp := (p - c) - axis * (p - c).dot(axis)
		var v_perp := v - axis * v.dot(axis)
		var A := v_perp.length_squared()
		if A < 1e-12:
			continue
		var B := 2.0 * d_perp.dot(v_perp)
		var C := d_perp.length_squared() - need * need
		if C >= -1e-10:
			continue
		var disc := B * B - 4.0 * A * C
		if disc < 0.0:
			continue
		var t := (-B + sqrt(disc)) / (2.0 * A)
		if t > t_need:
			t_need = t
	if t_need <= 0.0:
		return p
	t_need = minf(t_need + 0.001, 0.12)
	return p + v * t_need


## 只沿垂直于腿轴的方向推出（站姿主要是左右），去掉逆重力分量，
## 大腿不能把子宫托起来：可以顺着往下掉，也可以被侧面挤开。
func _thigh_correction(p: Vector3, cap: Dictionary, need: float) -> Vector3:
	var hit: Dictionary = _shaft_proj(p, cap)
	if not bool(hit["hit"]):
		return p
	var dist := float(hit["dist"])
	if dist >= need:
		return p
	var c: Vector3 = hit["c"]
	var d_perp: Vector3 = hit["d_perp"]
	var axis: Vector3 = hit["axis"]
	var n: Vector3
	if dist < 1e-8:
		n = cap["side"] if cap.has("side") else axis.cross(Vector3.UP)
		if n.length_squared() < 1e-10:
			n = Vector3.RIGHT
		n = n.normalized()
	else:
		n = d_perp / dist
	var corr := (c + n * need) - p
	# 无摩擦下滑：修正不得把点往上抬（否则会变成搁板）。
	var up := Vector3.UP
	if gravity.length_squared() > 1e-8:
		up = -gravity.normalized()
	var lift := corr.dot(up)
	if lift > 0.0:
		corr -= up * lift
	return p + corr


func _resolve_tube_thighs(k: int) -> void:
	if _thigh_caps.is_empty() or k < 1:
		return
	# 只处理子宫本体段。IV 度宫底→外口的细颈一头钉在外口，若当刚体去撞腿，
	# 每帧会把宫底硬拽开，悬挂甩动无法衰减。细颈是视觉连接，本体被顶到腿前即可。
	if k < _n:
		_resolve_seg_thighs(k - 1, -1, maxf(_node_radius(k - 1), 0.008))
	for b in range(1, k):
		_resolve_seg_thighs(b - 1, b, maxf(_node_radius(b - 1), _node_radius(b)))


func _resolve_seg_thighs(ia: int, ib: int, rad: float) -> void:
	var pa := _x[ia]
	var pb := _O if ib < 0 else _x[ib]
	var need := rad + float(params.thigh_margin)
	for cap in _thigh_caps:
		var pr: Array = _seg_closest(pa, pb, cap["a"], cap["b"])
		var q := _thigh_correction(pr[0], cap, float(cap["r"]) + need)
		var push: Vector3 = q - pr[0]
		if push.length_squared() < 1e-16:
			continue
		var ab := pb - pa
		var s := 0.5
		if ab.length_squared() > 1e-12:
			s = clampf((pr[0] - pa).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var wa := 1.0 - s
		var wb := 0.0 if ib < 0 else s
		if ib < 0:
			wa = 1.0
		var ws := wa + wb
		if ws <= 1e-6:
			continue
		_apply_collision_corr(ia, push * (wa / ws))
		if ib >= 0:
			_apply_collision_corr(ib, push * (wb / ws))
		pa = _x[ia]
		pb = _O if ib < 0 else _x[ib]


func _seg_closest(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-12 and e <= 1e-12:
		return [p1, p2]
	if a <= 1e-12:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-12:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			if absf(denom) > 1e-12:
				s = clampf((b * f - c * e) / denom, 0.0, 1.0)
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return [p1 + d1 * s, p2 + d2 * t]


func _finish(dt: float) -> void:
	var t1 := Time.get_ticks_usec()
	_update_model()
	var t2 := Time.get_ticks_usec()
	_update_introitus()
	var t3 := Time.get_ticks_usec()
	_push_deform()
	var t4 := Time.get_ticks_usec()
	prof_us["model"] = t2 - t1
	prof_us["introitus"] = t3 - t2
	prof_us["deform"] = t4 - t3
	var g := grade_for_descent(descent)
	if g != grade:
		grade = g
		grade_changed.emit(g)
	if not _drive_active and state == STATE_REDUCING and descent > 1e-5:
		pass


## 专用子宫模型：宫颈尖 → 宫底沿节点（体内节点在阴道路径上，体外节点是悬挂链）；
## IV 度宫底出外口后，接一段从宫底回到外口里面的细颈。
func _update_model() -> void:
	_ensure_model()
	if _model == null:
		return
	var inv := _frame.affine_inverse()
	var arcs := PackedFloat32Array()
	var nodes_ab := PackedVector3Array()
	for i in _n:
		arcs.append(_arc_of(i))
		nodes_ab.append(inv * _x[i])
	var neck := PackedVector3Array()
	if float(_sigma[_n - 1]) - descent < 0.0:
		neck.append(inv * _x[_n - 1])
		neck.append(inv * _O)
		neck.append(inv * (_O + _Ain * 0.008))
	_model.call("rebuild", _frame, nodes_ab, arcs, Callable(self, "mass_radius_at"), _U, float(params.cervix_expose), neck, float(params.neck_r), (inv.basis * _up).normalized())


## 外口：脱出物截面从里往外撑开（VulvaInserter）。
var _ins_last_r := 0.0
var _ins_dir_f := Vector3.ZERO
var _ins_last_dir := Vector3.ZERO
var _ins_last_axis := Vector3.ZERO
var _ins_cool := 0


func _update_introitus() -> void:
	if organs == null or organs.get("vulva") == null:
		return
	var v = organs.vulva
	var r := portal_radius()
	if r <= 1e-4:
		if _owns_introitus:
			v.call("set_inserter", null)
			_owns_introitus = false
		return
	if _inserter == null:
		_inserter = InserterScript.new()
	var inv := _frame.affine_inverse()
	var axis_ab := (inv.basis * _Ain).normalized()
	var up_ab := (inv.basis * _up).normalized()
	# 外口处脱出物朝外的方向：第一个体外节点的方向。
	var out_dir := -_Ain
	var k := 0
	while k < _n and _out[k] == 1:
		k += 1
	if k > 0 and _x[k - 1].distance_to(_O) > 0.004:
		out_dir = (_x[k - 1] - _O).normalized()
	var out_raw := (inv.basis * out_dir).normalized()
	# 走向低通（τ ≈ introitus_dir_tau）：甩动时外口不跟着每一摆重解，只跟平均走向。
	if not _owns_introitus or _ins_dir_f.length_squared() < 0.5:
		_ins_dir_f = out_raw
	else:
		var a := clampf(get_physics_process_delta_time() / maxf(float(params.introitus_dir_tau), 1e-3), 0.0, 1.0)
		_ins_dir_f = _ins_dir_f.lerp(out_raw, a).normalized()
	var out_ab := _ins_dir_f
	# 外阴重解一次约几毫秒（t68u 放宽）：截面变化 ≥ 0.5 mm 或低通后的走向变化 ≥ ~10° 才重解。
	_ins_cool = maxi(_ins_cool - 1, 0)
	if _owns_introitus and absf(r - _ins_last_r) < float(params.introitus_r_step) and out_ab.dot(_ins_last_dir) > float(params.introitus_dir_dot) and axis_ab.dot(_ins_last_axis) > 0.9995:
		return
	# 甩动中最多每 introitus_cooldown 个物理帧重解一次（截面变化 > 1.5 mm 时立即重解，保证不穿模）。
	if _owns_introitus and _ins_cool > 0 and absf(r - _ins_last_r) < 0.0015:
		return
	_ins_cool = int(params.introitus_cooldown)
	_ins_last_axis = axis_ab
	_inserter.call("setup_mass", r, axis_ab, up_ab, out_ab, Vector3.ZERO, 1.0)
	var same_size := _owns_introitus and absf(r - _ins_last_r) < 1e-5
	v.call("set_inserter", _inserter)
	# 只有走向变了时外阴不会自己重解（包络尺寸没变），这里显式刷新。
	if same_size and v.has_method("refresh_insert"):
		v.call("refresh_insert")
	_ins_last_r = r
	_ins_last_dir = out_ab
	_owns_introitus = true


## 阴道着色器：体内内翻折叠 + 通道撑开（只写给阴道网格）。
var _deform_sig := Vector4(-1, -1, -1, -1)


func _push_deform() -> void:
	if organs == null or not organs.has_method("set_prolapse_deform"):
		return
	var inv := _frame.affine_inverse()
	var o_ab := inv * _O
	var a_ab := (inv.basis * _Ain).normalized()
	var tip_sigma := float(_sigma[0]) - descent
	# 参数在腹部坐标里：甩动 / 身体移动时不变，只有下移量或通道变了才重写（以前每帧遍历全部器官材质）。
	var sig := Vector4(descent, o_ab.x + o_ab.y * 3.1 + o_ab.z * 7.3, a_ab.x + a_ab.y * 3.1 + a_ab.z * 7.3, _canal_L)
	var dd := (sig - _deform_sig).abs()
	if maxf(maxf(dd.x, dd.y), maxf(dd.z, dd.w)) < 0.00015:
		return
	_deform_sig = sig
	organs.call("set_prolapse_deform", o_ab, a_ab, _canal_L, descent, tip_sigma, _U, float(params.wall), _prof)


func _fundus_anterior() -> float:
	# 宫底相对两腿中线沿腹侧的有符号距离：正 = 在腿前面。
	if _x.is_empty() or _thigh_caps.size() < 2:
		if _thigh_caps.is_empty():
			_refresh_thigh_caps()
		if _x.is_empty() or _thigh_caps.size() < 2:
			return 0.0
	var mid: Vector3 = (_thigh_caps[0]["a"] + _thigh_caps[1]["a"]) * 0.5
	return (fundus_world() - mid).dot(_ventral_dir())


func debug_state() -> Dictionary:
	return {
		"state": state, "grade": grade, "amount": amount(), "descent": descent, "descent_max": descent_max(),
		"cervix_sd": cervix_signed_distance(), "fundus_sd": fundus_signed_distance(), "out": outside_count(),
		"portal_r": portal_radius(), "canal_L": _canal_L, "sigma0": float(_sigma[0]) if not _sigma.is_empty() else 0.0,
		"U": _U, "prof": _prof, "thigh_clearance": thigh_clearance(),
		"cervix_drop": (_O.y - cervix_world().y) if not _x.is_empty() else 0.0,
		"fundus_drop": (_O.y - fundus_world().y) if not _x.is_empty() else 0.0,
		"fundus_anterior": _fundus_anterior(),
	}
