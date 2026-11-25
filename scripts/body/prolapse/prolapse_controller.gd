extends Node
## 子宫脱垂系统（中央控制器）。
##
## 状态：连续的脱垂量（宫颈沿阴道下移的距离 descent，0..descent_max，amount = 0..1），按宫颈相对
## 外口（处女膜）的位置分 0–IV 度；状态机 none / driven / hanging / reducing。
##
## 解剖：子宫沿阴道往下（不是从腹部创口）。阴道上段内翻并被带出：体内为双层折叠
## （着色器 prolapse_offset），体外为包住脱出物的外翻套筒（ProlapseSleeve，黏膜朝外），宫颈在最外端露出。
## 外口 / 阴唇由 ProlapseMassInserter（VulvaInserter）按脱出物截面从里往外撑开，通道半径跟着下移。
##
## 物理：沿用 SoftOrgan 的子宫网格与 GPU 蒙皮（external_drive），这里解算 6 个节点：
## 仍在体内的节点沿「外口 → 宫颈 → 子宫静止轴」的路径运动学放置；已出外口的节点是带惯性、重力的
## Verlet 链，锚在外口，关节限角（柔性悬挂），可被拖拽 / 甩动。
##
## 触发源可插拔：register_trigger(ProlapseTrigger)；try_trigger(id, ctx) 满足条件就开始驱动。
## 触发 #1 = 长柄金属球（BallRodProlapseTrigger）。
class_name ProlapseController

signal grade_changed(grade: int)
signal state_changed(state: String)
signal triggered(source: String)

const SoftOrganScript := preload("res://scripts/surgery/soft_organ.gd")
const ParamsScript := preload("res://scripts/body/prolapse/prolapse_params.gd")
const InserterScript := preload("res://scripts/body/prolapse/prolapse_mass_inserter.gd")
const SleeveScript := preload("res://scripts/body/prolapse/prolapse_sleeve.gd")
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

var _so: Node = null
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
var _sleeve: MeshInstance3D = null
var _inserter: RefCounted = null
var _owns_introitus := false
var _vel_hist: Array = []


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


func soft_organ() -> Node:
	return _so


func sleeve() -> MeshInstance3D:
	return _sleeve


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


## 外口处（路径坐标 0）当前穿过的截面半径：宫颈 / 宫体截面 + 外翻阴道壁；IV 度后为套筒颈部。
func portal_radius() -> float:
	if _sigma.is_empty() or descent <= 0.0:
		return 0.0
	var a := descent - float(_sigma[0])   # 外口处对应的子宫弧长
	var w := float(params.wall)
	if _prof.is_empty() or a < -float(_prof[0]):
		return 0.0
	if a >= _U * 0.92:
		return maxf(float(params.neck_r), mass_radius_at(_U * 0.92)) + w
	return mass_radius_at(a) + w * 2.0


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
	var navel: Vector3 = organs.get("_navel_rest")
	if _so == null or not is_instance_valid(_so):
		_so = SoftOrganScript.new()
		_so.name = "ProlapseUterus"
		add_child(_so)
	var adnex: Array = []
	for k in ["tube", "ovary"]:
		for m3 in organs.call("viscera_meshes", k):
			adnex.append(m3)
	var horns: Array = [navel, navel]
	var meta: Dictionary = organs.get("meta")
	if meta.has("tubes") and meta["tubes"] is Array:
		var tb: Array = meta["tubes"]
		for i in mini(2, tb.size()):
			var h: Array = (tb[i] as Dictionary).get("horn", [])
			if h.size() >= 3:
				horns[i] = Vector3(float(h[0]), float(h[1]), float(h[2]))
	_so.call("setup", "uterus", _frame, navel, ut, adnex, cerv_raw, fund_raw, horns)
	var extra: Array = organs.call("viscera_meshes", "uterus_cavity")
	if not extra.is_empty():
		_so.call("add_hide_meshes", extra)
	_rest_ab = _so.call("rest_nodes_ab")
	_seg = _so.call("seg_rest_lengths")
	_n = int(_so.call("node_count"))
	if _rest_ab.size() != _n:
		return
	_U = 0.0
	for s in _seg:
		_U += float(s)
	_build_profile()
	_x.resize(_n)
	_q.resize(_n)
	_out.resize(_n)
	_geo_ok = true
	_refresh_path()
	for i2 in _n:
		_x[i2] = _frame * _rest_ab[i2]
		_q[i2] = _x[i2]
		_out[i2] = 0


func _build_profile() -> void:
	# 截面：静止网格顶点到子宫轴的径向距离，按轴向分箱取分位数。
	_prof.resize(PROF_N)
	var V: PackedVector3Array = _so.call("rest_vertices_ab")
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
func _refresh_path() -> void:
	if organs == null:
		return
	var canal: Dictionary = organs.call("vagina_canal")
	if not canal.is_empty():
		_O = canal["opening_world"]
		var cw: Vector3 = canal["cervix_world"]
		_canal_L = maxf(_O.distance_to(cw), 0.02)
		var up_ab: Vector3 = canal.get("up_ab", Vector3(0, 0, 1))
		_up = (_frame.basis * up_ab).normalized()
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
	_refresh_path()
	_so.call("begin_external", _frame, _O, -_Ain)
	for k in ["uterus", "uterus_cavity", "tube", "ovary"]:
		organs.call("set_kind_visible", k, false)
	for i in _n:
		_x[i] = _frame * _rest_ab[i]
		_q[i] = _x[i]
		_out[i] = 0
	_prev_frame = _frame
	_has_prev = true
	_ensure_sleeve()
	_set_state(STATE_HANGING)


func _deactivate() -> void:
	if _so and is_instance_valid(_so):
		_so.call("end_external")
	if organs:
		for k in ["uterus", "uterus_cavity", "tube", "ovary"]:
			organs.call("set_kind_visible", k, true)
		if organs.has_method("clear_prolapse_deform"):
			organs.call("clear_prolapse_deform")
		if _owns_introitus and organs.get("vulva") != null and organs.vulva.has_method("set_inserter"):
			organs.vulva.call("set_inserter", null)
	_owns_introitus = false
	if _sleeve:
		_sleeve.visible = false
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


func _ensure_sleeve() -> void:
	if _sleeve and is_instance_valid(_sleeve):
		return
	_sleeve = SleeveScript.new()
	_sleeve.name = "ProlapseSleeve"
	add_child(_sleeve)
	var vg: Array = organs.call("viscera_meshes", "vagina")
	for m in vg:
		var mi := m as MeshInstance3D
		if mi and mi.material_override is ShaderMaterial:
			var mat := (mi.material_override as ShaderMaterial).duplicate() as ShaderMaterial
			mat.set_shader_parameter("prol_o", Vector4.ZERO)
			mat.set_shader_parameter("is_uterus", false)
			_sleeve.material_override = mat
			break
	_sleeve.visible = false


# ------------------------------------------------------------------ 每帧

func _physics_process(dt: float) -> void:
	step(dt)


func step(dt: float) -> void:
	if state == STATE_NONE or not _geo_ok:
		return
	var t0 := Time.get_ticks_usec()
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
	_simulate(dt)
	_finish(dt)
	# 完全回位且没人抓着 → 退出（抓着时即使推回到 0 也保持，便于继续拉）。
	if descent <= 1e-5 and not _drive_active and state != STATE_REDUCING:
		_deactivate()
	last_step_usec = int(Time.get_ticks_usec() - t0)


func _drive_pulling() -> bool:
	if not _drive_active:
		return false
	var rel := _drive_target - _O
	return rel.dot(_Ain) < float(_sigma[_drive_node]) - 0.003


func _simulate(dt: float) -> void:
	var k60 := dt * 60.0
	var air := pow(float(params.air_damp), k60)
	var vmax := float(params.max_speed) * dt
	var drv := _drive_node if _drive_active else -1
	var portal_out := -_Ain
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
		# 不能回到会阴平面以内；不低于地面。
		for b2 in k:
			if b2 == drv:
				continue
			var rel2 := _x[b2] - _O
			var dn := rel2.dot(portal_out)
			if dn < 0.0:
				_x[b2] -= portal_out * dn
			if _x[b2].y < floor_y + 0.012:
				_x[b2].y = floor_y + 0.012
		if hold != Vector3.INF:
			_x[drv] = hold
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


func _finish(dt: float) -> void:
	_so.call("set", "floor_y", floor_y)
	_so.call("step_external", maxf(dt, 1e-4), _frame, _x, _O, -_Ain)
	_update_sleeve()
	_update_introitus()
	_push_deform()
	var g := grade_for_descent(descent)
	if g != grade:
		grade = g
		grade_changed.emit(g)
	if not _drive_active and state == STATE_REDUCING and descent > 1e-5:
		pass


## 外翻套筒：外口里面一点 → 体外段链 → 宫颈（留出 cervix_expose 露在外面）。
func _update_sleeve() -> void:
	if _sleeve == null:
		return
	var X := descent - float(_sigma[0])   # 体外的材料长度（外口到宫颈尖）
	if X <= 0.002:
		_sleeve.visible = false
		return
	var poly := PackedVector3Array()
	var arcs := PackedFloat32Array()     # 每个折线点对应的子宫弧长（宫颈尖 = 0）
	poly.append(_O + _Ain * 0.006)
	arcs.append(X + 0.006)
	poly.append(_O)
	arcs.append(X)
	var k := 0
	while k < _n and _out[k] == 1:
		k += 1
	for i in range(k - 1, -1, -1):
		poly.append(_x[i])
		arcs.append(_arc_of(i))
	# 外口处的折角切圆（Chaikin 两次，端点不动）：粗套筒不会在折角内侧自相穿插。
	for _ci in 2:
		if poly.size() < 3:
			break
		var np := PackedVector3Array([poly[0]])
		var na := PackedFloat32Array([arcs[0]])
		for ci in poly.size() - 1:
			if ci > 0:
				np.append(poly[ci].lerp(poly[ci + 1], 0.25))
				na.append(lerpf(arcs[ci], arcs[ci + 1], 0.25))
			if ci < poly.size() - 2:
				np.append(poly[ci].lerp(poly[ci + 1], 0.75))
				na.append(lerpf(arcs[ci], arcs[ci + 1], 0.75))
		np.append(poly[poly.size() - 1])
		na.append(arcs[arcs.size() - 1])
		poly = np
		arcs = na
	# 宫颈尖之前停在 cervix_expose 处。
	var a_end := float(params.cervix_expose)
	var centers := PackedVector3Array()
	var radii := PackedFloat32Array()
	var total := 0.0
	var seglen := PackedFloat32Array()
	for i2 in poly.size() - 1:
		var l := poly[i2].distance_to(poly[i2 + 1])
		seglen.append(l)
		total += l
	var step_len := clampf(total / 30.0, 0.004, 0.010)
	var w := float(params.wall)
	var neck := float(params.neck_r)
	for i3 in poly.size() - 1:
		var a_s := float(arcs[i3])
		var a_e := float(arcs[i3 + 1])
		var l2 := float(seglen[i3])
		var nsub := maxi(1, int(ceil(l2 / step_len)))
		for s in nsub:
			var t := float(s) / float(nsub)
			var a := lerpf(a_s, a_e, t)
			if a < a_end:
				break
			var r := mass_radius_at(minf(a, _U * 0.999)) if a < _U else 0.0
			if a >= _U * 0.92:
				r = maxf(r, neck)
			centers.append(poly[i3].lerp(poly[i3 + 1], t))
			radii.append(r + w)
			if centers.size() >= SleeveScript.MAX_RINGS - 1:
				break
	# 末端：穹窿附着在宫颈上，收口贴住宫颈（取平滑中线上弧长 = a_end 的点，和前面的环在同一条线上）。
	var end_pos := _x[0] + ((_x[1] - _x[0]).normalized() if _n > 1 else -_Ain) * a_end
	for i4 in poly.size() - 1:
		var a0 := float(arcs[i4])
		var a1 := float(arcs[i4 + 1])
		if (a0 - a_end) * (a1 - a_end) <= 0.0 and absf(a1 - a0) > 1e-7:
			end_pos = poly[i4].lerp(poly[i4 + 1], (a_end - a0) / (a1 - a0))
			break
	if not centers.is_empty() and centers[centers.size() - 1].distance_to(end_pos) < step_len * 0.5 and centers.size() > 2:
		centers.remove_at(centers.size() - 1)
		radii.remove_at(radii.size() - 1)
	centers.append(end_pos)
	radii.append(mass_radius_at(a_end) + w * 0.5)
	_sleeve.call("rebuild", centers, radii, _up)


## 外口：脱出物截面从里往外撑开（VulvaInserter）。
var _ins_last_r := 0.0
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
	var out_ab := (inv.basis * out_dir).normalized()
	# 外阴重解一次约几毫秒：只有截面变化 ≥ 0.25 mm 或走向变化 ≥ ~1.4° 才重解。
	_ins_cool = maxi(_ins_cool - 1, 0)
	if _owns_introitus and absf(r - _ins_last_r) < 0.00025 and out_ab.dot(_ins_last_dir) > 0.9997 and axis_ab.dot(_ins_last_axis) > 0.9999:
		return
	# 甩动中最多每 3 个物理帧重解一次（截面变化 > 1 mm 时立即重解，保证不穿模）。
	if _owns_introitus and _ins_cool > 0 and absf(r - _ins_last_r) < 0.001:
		return
	_ins_cool = 3
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
func _push_deform() -> void:
	if organs == null or not organs.has_method("set_prolapse_deform"):
		return
	var inv := _frame.affine_inverse()
	var o_ab := inv * _O
	var a_ab := (inv.basis * _Ain).normalized()
	var tip_sigma := float(_sigma[0]) - descent
	organs.call("set_prolapse_deform", o_ab, a_ab, _canal_L, descent, tip_sigma, _U, float(params.wall), _prof)


func debug_state() -> Dictionary:
	return {
		"state": state, "grade": grade, "amount": amount(), "descent": descent, "descent_max": descent_max(),
		"cervix_sd": cervix_signed_distance(), "fundus_sd": fundus_signed_distance(), "out": outside_count(),
		"portal_r": portal_radius(), "canal_L": _canal_L, "sigma0": float(_sigma[0]) if not _sigma.is_empty() else 0.0,
		"U": _U, "prof": _prof,
	}
