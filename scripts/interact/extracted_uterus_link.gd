extends RefCounted
## 0.4.17（t5u）：手术把子宫从腹部创口扯出体外后，阴道互动模式插入长柄钢球。
##
## 物理解释（可视为一根「管道」：阴道 → 被拉长的阴道上段过渡管 → 创口 → 宫颈 → 宫腔）：
## - 插入：球沿阴道走，阴道顶端不再被系带拉歪（阴道被杆捋直）；过渡管从下垂的弧被拉成
##   「阴道顶端 → 创口 → 宫颈」的直线；球接近宫颈时，悬挂在体外的子宫被转到同一条线上
##   （宫颈朝创口、宫底沿杆向外），球可以穿过宫颈进到体外子宫的宫腔里（宫体按球径向撑开包住球）。
## - 带回：球在宫腔里且大到宫颈卡得住（与脱垂触发 #1 同一阈值）时往外拉，宫颈卡住球，
##   子宫跟着球沿原路退回：先整颗经创口回到腹腔（沿杆线），再平滑回到盆腔静止位；
##   到达静止位的那一帧结束手术柔体、显示原子宫，并以同一颗卡在宫颈里的球直接接上普通子宫脱垂
##   （descent 从 0 开始，继续往外拉就是正常的脱垂）。
## 球中途缩小到卡不住：子宫还有部分在体外 → 交还给悬挂物理；已全部回到体内 → 就地放回（不脱垂）。

const TRANSITION_IN := 0.012     # 与 SoftOrgan.TRANSITION_IN 相同：创口入口在悬挂点内侧
const CONDUIT_N := 22            # 阴道顶端 → 宫颈的采样点数
const K_RATE := 3.0              # 捋直跟随速度（1/s）
const KU_RATE := 2.4
const DIR_OUT_MIN := 0.85        # 体外宫体方向至少这么朝外（创口边缘像滑轮，宫体不贴着腹壁）
const BASE_OFF := 0.022          # 对齐时宫颈节点在悬挂点外这么远
const TUBE_WALL := 0.003         # 过渡管壁厚
const TUBE_MIN_R := 0.0105       # = SoftOrgan.TRANSITION_R
const UT_WALL_MIN := 0.0035
const REEL_SPEED := 0.45         # 带回时子宫跟球的最大速度（m/s）
const IN_MARGIN := 0.02          # 宫底退进创口内侧这么深才开始回静止位
const SHAFT_C := 0.0065          # = BallRodTool.SHAFT_CLEARANCE

var tool: Node = null
var k := 0.0                     # 阴道 + 过渡管捋直程度
var ku := 0.0                    # 体外宫体对齐程度
var reeling := false
var reel_u := 0.0                # 0..1 带回进度（只读）
var handoff_count := 0
var last_handoff_jump := -1.0    # 交接瞬间球心跳变（米，自检用）
var path := PackedVector3Array()
var arcs := PackedFloat32Array()
var s_vault := 0.0
var s_entry := 0.0
var s_cervix := 0.0
var s_fundus := 0.0
var exit_dir := Vector3.ZERO
var _was_active := false
# 带回阶段（冻结的路径 / 位姿）
var _P := PackedVector3Array()
var _A := PackedFloat32Array()
var _node_s0 := PackedFloat32Array()
var _sigma_max := 0.0
var _d2 := 0.05
var _s_g0 := 0.0
var _off0 := 0.0
var _pulled := 0.0
var _pulled_goal := 0.0
var _stage1_end := PackedVector3Array()
var _ball_end := Vector3.ZERO
var _last_frame := -1
var _soft_ball_end := Vector3.ZERO


func _init(p_tool: Node) -> void:
	tool = p_tool


# ------------------------------------------------------------------ 查询

func surgery() -> Node:
	if tool == null:
		return null
	var m = tool.get("mode")
	var s = m.get("surgery") if m != null else null
	if s == null:
		var pl = tool.get("player")
		if pl != null and pl.has_method("get_surgery"):
			s = pl.call("get_surgery")
	return s


func soft() -> Node:
	var s := surgery()
	if s == null or not s.has_method("soft_organ"):
		return null
	var so: Node = s.call("soft_organ", "uterus")
	if so == null or not is_instance_valid(so):
		return null
	if not bool(so.call("is_extracted")) or bool(so.get("retracting")) or bool(so.get("external_drive")):
		return null
	return so


func active() -> bool:
	return reeling or soft() != null


# ------------------------------------------------------------------ 路径

static func _arcs_of(pts: PackedVector3Array) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(pts.size())
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i - 1].distance_to(pts[i])
		a[i] = acc
	return a


static func _resample(pts: PackedVector3Array, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if pts.size() < 2:
		for i in n:
			out.append(pts[0] if pts.size() > 0 else Vector3.ZERO)
		return out
	var a := _arcs_of(pts)
	var tot := a[a.size() - 1]
	for i in n:
		out.append(_at(pts, a, tot * float(i) / float(n - 1)))
	return out


static func _at(pts: PackedVector3Array, a: PackedFloat32Array, s: float) -> Vector3:
	var n := pts.size()
	if n == 0:
		return Vector3.ZERO
	if n == 1:
		return pts[0]
	if s <= a[0]:
		var d0 := (pts[1] - pts[0])
		return pts[0] + (d0.normalized() if d0.length_squared() > 1e-12 else Vector3.ZERO) * (s - a[0])
	for i in range(1, n):
		if s <= a[i]:
			var seg := a[i] - a[i - 1]
			var t := (s - a[i - 1]) / seg if seg > 1e-9 else 0.0
			return pts[i - 1].lerp(pts[i], t)
	var d1 := pts[n - 1] - pts[n - 2]
	return pts[n - 1] + (d1.normalized() if d1.length_squared() > 1e-12 else Vector3.ZERO) * (s - a[n - 1])


static func _tan(pts: PackedVector3Array, a: PackedFloat32Array, s: float) -> Vector3:
	var n := pts.size()
	if n < 2:
		return Vector3.FORWARD
	var h := 0.006
	var d := _at(pts, a, s + h) - _at(pts, a, s - h)
	if d.length_squared() < 1e-12:
		return (pts[n - 1] - pts[0]).normalized()
	return d.normalized()


func point_at(s: float) -> Vector3:
	if reeling:
		return _at(_P, _A, s)
	return _at(path, arcs, s)


func tangent_at(s: float) -> Vector3:
	if reeling:
		return _tan(_P, _A, s)
	return _tan(path, arcs, s)


## 射线与路径（折线）的最近点 → 路径弧长坐标。
func project(origin: Vector3, dir: Vector3) -> float:
	var P := _P if reeling else path
	var A := _A if reeling else arcs
	if P.size() < 2 or dir.length_squared() < 1e-12:
		return 0.0
	var d := dir.normalized()
	var best := 1e9
	var best_s := 0.0
	# 外口外面也延长一段（杆还没进去时）
	var ext0 := P[0] - (P[1] - P[0]).normalized() * 0.12
	var pts := PackedVector3Array([ext0])
	pts.append_array(P)
	var aa := PackedFloat32Array([A[0] - 0.12])
	aa.append_array(A)
	for i in range(1, pts.size()):
		var a0 := pts[i - 1]
		var b0 := pts[i]
		var u := b0 - a0
		var L := u.length()
		if L < 1e-7:
			continue
		u /= L
		var w0 := a0 - origin
		var bdot := u.dot(d)
		var den := 1.0 - bdot * bdot
		var t: float
		if den < 1e-7:
			t = 0.0
		else:
			t = (bdot * w0.dot(d) - w0.dot(u)) / den
		t = clampf(t, 0.0, L)
		var q := a0 + u * t
		var tr := maxf((q - origin).dot(d), 0.0)
		var dist := q.distance_to(origin + d * tr)
		if dist < best - 1e-6:
			best = dist
			best_s = aa[i - 1] + t
	return best_s


func _exit_direction(V: Vector3, E: Vector3, out: Vector3) -> Vector3:
	var d := E - V
	if d.length_squared() < 1e-10:
		d = out
	d = d.normalized()
	var o := out.normalized()
	var c := d.dot(o)
	if c < DIR_OUT_MIN:
		var tng := d - o * c
		if tng.length_squared() < 1e-10:
			return o
		d = tng.normalized() * sqrt(1.0 - DIR_OUT_MIN * DIR_OUT_MIN) + o * DIR_OUT_MIN
	return d.normalized()


func _rebuild_path(so: Node) -> void:
	var O: Vector3 = tool.call("_opening_world")
	var a: Vector3 = tool.call("_axis_world_canal")
	var L: float = tool.call("_canal_length")
	var V := O + a * L
	var out: Vector3 = (so.get("outward") as Vector3).normalized()
	var hang: Vector3 = so.call("hang_point")
	var E := hang - out * TRANSITION_IN
	exit_dir = _exit_direction(V, E, out)
	var cj: Vector3 = so.call("cervix_join_world")
	var straight := PackedVector3Array([V, E, cj])
	var orig: PackedVector3Array = so.call("transition_points")
	if orig.size() < 2:
		orig = straight
	else:
		orig = orig.duplicate()
		orig[0] = V
	var rs := _resample(straight, CONDUIT_N)
	var ro := _resample(orig, CONDUIT_N)
	path = PackedVector3Array([O])
	for i in CONDUIT_N:
		path.append(ro[i].lerp(rs[i], k))
	var n_conduit_end := path.size() - 1
	var nodes: Array = []
	for b in range(1, 6):
		nodes.append(so.call("node_world", b))
	for p in nodes:
		path.append(p)
	var last: Vector3 = nodes[nodes.size() - 1]
	var prev: Vector3 = nodes[nodes.size() - 2]
	path.append(last + (last - prev).normalized() * 0.04)
	arcs = _arcs_of(path)
	s_vault = arcs[1]
	# 入口 E 在直线段上的弧长（近似：直路径时 = V→E）
	s_entry = s_vault + lerpf(_arc_len(ro, E), V.distance_to(E), k)
	s_cervix = arcs[n_conduit_end]
	s_fundus = arcs[n_conduit_end + nodes.size()]


static func _arc_len(pts: PackedVector3Array, target: Vector3) -> float:
	var a := _arcs_of(pts)
	var best := 1e9
	var bs := 0.0
	for i in pts.size():
		var dd := pts[i].distance_to(target)
		if dd < best:
			best = dd
			bs = a[i]
	return bs


# ------------------------------------------------------------------ 插入阶段

## 每帧（未带回时）：更新捋直 / 对齐目标，写给柔体，重建路径。返回是否激活。
func update(dt: float) -> bool:
	if reeling:
		return true
	var so := soft()
	if so == null:
		if _was_active:
			_was_active = false
			# 子宫被手术放回 / 柔体结束：清掉写给柔体的杆数据（放回动画用回原来的过渡管）。
			var so2 := _reel_soft()
			if so2:
				so2.call("rod_clear")
			k = 0.0
			ku = 0.0
			path = PackedVector3Array()
		return false
	_was_active = true
	dt = clampf(dt, 0.0, 0.1)
	var depth := float(tool.get("depth"))
	var L: float = tool.call("_canal_length")
	var r: float = tool.call("radius")
	var kt := _smooth(L * 0.35, L * 0.95, depth)
	var kut := 0.0
	if path.size() >= 2:
		kut = _smooth(s_entry - 0.03, s_cervix - r, depth)
	if bool(tool.get("through_cervix")):
		kut = 1.0
		kt = 1.0
	if depth > L:
		kt = 1.0
	k = move_toward(k, kt, dt * K_RATE) if dt > 0.0 else kt
	ku = move_toward(ku, kut, dt * KU_RATE) if dt > 0.0 else kut
	so.set("rod_vault_k", k)
	so.set("rod_guide_k", ku)
	so.set("rod_straight_k", ku)
	so.set("rod_guide_dir", exit_dir if exit_dir.length_squared() > 0.5 else (so.get("outward") as Vector3))
	so.set("rod_guide_base", (so.call("hang_point") as Vector3) + (exit_dir if exit_dir.length_squared() > 0.5 else (so.get("outward") as Vector3)) * BASE_OFF)
	_rebuild_path(so)
	_write_wrap(so, depth, r)
	return true


static func _smooth(e0: float, e1: float, x: float) -> float:
	if e1 <= e0:
		return 1.0 if x >= e1 else 0.0
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func uterus_wall() -> float:
	var w := UT_WALL_MIN
	var org = tool.get("organs")
	if org != null and org.get("meta") is Dictionary and (org.meta as Dictionary).has("uterus_cavity"):
		var uc = org.meta["uterus_cavity"]
		if uc is Dictionary:
			w = maxf(float(uc.get("wall_m", w)), UT_WALL_MIN)
	return w


## 过渡管 / 宫体包住球和杆（C1 平滑：smooth_push 同款）。
func _write_wrap(so: Node, depth: float, r: float) -> void:
	var shaft_c := SHAFT_C
	# 过渡管：阴道顶端 → 宫颈（略插进宫颈）
	var tube := PackedVector3Array()
	var radii := PackedFloat32Array()
	var n := 40
	var s0 := s_vault - 0.006
	var s1 := s_cervix + 0.004
	for i in n:
		var s := lerpf(s0, s1, float(i) / float(n - 1))
		tube.append(point_at(s))
		var need := TUBE_MIN_R
		if depth > s - r - 0.01:
			# 杆穿过这里（球已经过去）或球就在这里
			var dz := s - depth
			var sphere := 0.0
			if absf(dz) < r + TUBE_WALL:
				var R := r + TUBE_WALL
				sphere = sqrt(maxf(R * R - dz * dz, 0.0))
			var rod := shaft_c + TUBE_WALL if dz < 0.0 else 0.0
			need = maxf(need, _soft_max(sphere, rod))
		radii.append(need)
	so.set("rod_tube_pts", tube)
	so.set("rod_tube_radii", radii)
	# 宫腔
	var inside := depth > s_cervix - r
	if inside:
		so.call("rod_set_ball", true, tool.call("tip_world"), r, point_at(s_cervix - 0.006), shaft_c, uterus_wall())
	else:
		so.call("rod_set_ball", false)


static func _soft_max(a: float, b: float) -> float:
	# 平滑最大值（差 < 2 mm 时圆滑过渡），总是 ≥ max(a, b)
	var w := 0.002
	var d := absf(a - b)
	if d >= w:
		return maxf(a, b)
	return maxf(a, b) + (w - d) * (w - d) / (4.0 * w)


func fundus_contact_depth(r: float) -> float:
	return s_fundus - uterus_wall() - r - 0.003


# ------------------------------------------------------------------ 带回阶段

## 球在宫腔里往外拉、被宫颈挡住：够大 + 拉得够狠（与脱垂触发 #1 同一判据）就卡住开始带回。
func try_catch(ctx: Dictionary) -> bool:
	if reeling:
		return true
	var so := soft()
	if so == null:
		return false
	var pc: Node = tool.call("_prolapse")
	var ok := false
	var t: RefCounted = pc.call("trigger", "ball_rod") if pc and pc.has_method("trigger") else null
	if t != null:
		ok = bool(t.call("evaluate", ctx, pc.get("params")))
	else:
		ok = bool(ctx.get("in_uterus", false)) and float(ctx.get("ball_radius", 0.0)) >= 0.0105 * 1.08 and (float(ctx.get("pull_speed", 0.0)) >= 0.16 or float(ctx.get("pull_force", 0.0)) >= 0.03)
	if not ok:
		return false
	_begin_reel(so)
	return true


func _begin_reel(so: Node) -> void:
	reeling = true
	reel_u = 0.0
	_P = path.duplicate()
	_A = arcs.duplicate()
	var r: float = tool.call("radius")
	# 宫体节点在冻结路径上的弧长
	var na: PackedFloat32Array = so.call("node_arcs")
	var s_c0 := s_cervix - 0.004
	_node_s0 = PackedFloat32Array()
	for b in na.size():
		_node_s0.append(s_c0 + na[b])
	var s_f0 := _node_s0[_node_s0.size() - 1]
	_sigma_max = maxf(s_f0 - (s_entry - IN_MARGIN), 0.0)
	_s_g0 = float(tool.get("depth"))
	_off0 = maxf(_s_g0 - s_c0, r * 0.5)
	_stage1_end = PackedVector3Array()
	for b2 in _node_s0.size():
		_stage1_end.append(_at(_P, _A, _node_s0[b2] - _sigma_max))
	var rest0: Vector3 = so.call("rest_node_world", 0)
	var rest1: Vector3 = so.call("rest_node_world", 1)
	_soft_ball_end = rest0 + (rest1 - rest0).normalized() * (r + 0.003)
	# 交接时普通脱垂会把卡住的球放在它自己的宫颈节点 + 半径处：带回终点直接对准那里，交接不跳。
	_ball_end = _soft_ball_end
	var pc: Node = tool.call("_prolapse")
	if pc and pc.has_method("rest_nodes_world"):
		var pr: PackedVector3Array = pc.call("rest_nodes_world")
		if pr.size() >= 2:
			_ball_end = pr[0] + (pr[1] - pr[0]).normalized() * (r + 0.003)
	var ball_s1 := _stage1_end[0] + (_stage1_end[1] - _stage1_end[0]).normalized() * _off0
	# 第二段长度取「球 / 各节点里走得最远的」× 1.5（smoothstep 最大斜率），每帧位移不超过 REEL_SPEED·dt。
	var far := ball_s1.distance_to(_ball_end)
	for b3 in _stage1_end.size():
		far = maxf(far, _stage1_end[b3].distance_to(so.call("rest_node_world", b3)))
	_d2 = maxf(far * 1.5, 0.02)
	_pulled = 0.0
	_pulled_goal = 0.0
	so.set("rod_guide_k", 0.0)
	so.set("rod_vault_k", 1.0)
	_apply_reel(so)


## 指针给出的期望深度（冻结路径弧长）→ 带回进度（可往回推）。
func reel_to(desired: float, dt: float) -> void:
	if not reeling:
		return
	_pulled_goal = clampf(_s_g0 - desired, 0.0, _sigma_max + _d2 + 0.01)
	step_reel(dt)


func step_reel(dt: float) -> void:
	if not reeling:
		return
	var so := _reel_soft()
	if so == null:
		cancel_reel()
		return
	dt = clampf(dt, 0.0, 0.1)
	# 每个物理帧只前进一次（拖拽回调和物理步进都会调到这里）。
	var fr := Engine.get_physics_frames()
	if fr != _last_frame:
		_last_frame = fr
		var stp := REEL_SPEED * (dt if dt > 0.0 else 0.016)
		_pulled = move_toward(_pulled, _pulled_goal, stp)
	_apply_reel(so)


func _reel_soft() -> Node:
	var s := surgery()
	if s == null:
		return null
	var so: Node = s.call("soft_organ", "uterus")
	return so if so != null and is_instance_valid(so) else null


func reel_total() -> float:
	return _sigma_max + _d2


func _reel_pose(so: Node) -> Array:
	var sigma := minf(_pulled, _sigma_max)
	var tau := clampf((_pulled - _sigma_max) / maxf(_d2, 1e-4), 0.0, 1.0)
	var ts := tau * tau * (3.0 - 2.0 * tau)
	var nodes := PackedVector3Array()
	for b in _node_s0.size():
		var p1 := _at(_P, _A, _node_s0[b] - sigma)
		if tau > 0.0:
			p1 = _stage1_end[b].lerp(so.call("rest_node_world", b), ts)
		nodes.append(p1)
	return [nodes, tau, ts]


func _apply_reel(so: Node) -> void:
	var r: float = tool.call("radius")
	var pose := _reel_pose(so)
	var nodes: PackedVector3Array = pose[0]
	var ts: float = pose[2]
	reel_u = clampf(_pulled / maxf(reel_total(), 1e-4), 0.0, 1.0)
	so.set("rod_nodes", nodes)
	so.set("rod_straight_k", 1.0 - ts)
	var off := lerpf(_off0, r + 0.003, ts)
	var dir01 := (nodes[1] - nodes[0]).normalized()
	var ball := nodes[0] + dir01 * off + (_ball_end - _soft_ball_end) * ts
	tool.call("_link_place_ball", ball, dir01)
	# 过渡管：阴道顶端 → 宫颈（随宫颈退回而变短）
	var O: Vector3 = tool.call("_opening_world")
	var a: Vector3 = tool.call("_axis_world_canal")
	var L: float = tool.call("_canal_length")
	var V := O + a * L
	var cj: Vector3 = nodes[0] + dir01 * 0.004
	var tube := PackedVector3Array()
	var radii := PackedFloat32Array()
	var shaft_c := SHAFT_C
	var vs := V - a * 0.006
	for i in 16:
		var t := float(i) / 15.0
		tube.append(vs.lerp(cj, t))
		radii.append(maxf(TUBE_MIN_R, shaft_c + TUBE_WALL))
	so.set("rod_tube_pts", tube if vs.distance_to(cj) > 0.006 else PackedVector3Array([vs, vs]))
	so.set("rod_tube_radii", radii if vs.distance_to(cj) > 0.006 else PackedFloat32Array())
	so.call("rod_set_ball", true, ball, r, nodes[0] - dir01 * 0.002, shaft_c, uterus_wall())
	if float(pose[1]) >= 1.0 - 1e-5:
		_handoff(so)


## 子宫回到静止位：结束手术柔体，接普通脱垂（球卡在宫颈里）。
func _handoff(so: Node) -> void:
	var before: Vector3 = tool.call("tip_world")
	reeling = false
	_was_active = false
	k = 0.0
	ku = 0.0
	path = PackedVector3Array()
	so.call("rod_clear")
	var s := surgery()
	if s and s.has_method("rod_reinsert_uterus"):
		s.call("rod_reinsert_uterus")
	handoff_count += 1
	tool.call("_link_handoff_to_prolapse")
	var after: Vector3 = tool.call("tip_world")
	last_handoff_jump = before.distance_to(after)


## 球缩小 / 工具收起：带回中断。
func cancel_reel() -> void:
	if not reeling:
		return
	reeling = false
	var so := _reel_soft()
	if so == null:
		return
	var all_in := _pulled >= _sigma_max - 1e-4
	so.call("rod_clear")
	if all_in:
		# 整颗已经回到腹腔：就地放回（不脱垂）。
		so.call("start_putback")
	k = 0.0
	ku = 0.0


func clear() -> void:
	var so := _reel_soft()
	if so:
		so.call("rod_clear")
	reeling = false
	_was_active = false
	k = 0.0
	ku = 0.0
	path = PackedVector3Array()
