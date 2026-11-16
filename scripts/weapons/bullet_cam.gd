extends Node3D
## 狙击精英式弹道特写：判定本发将命中肠道 / 子宫后，慢动作从枪口跟随弹头，
## 弹头进入人体后相机停在受击点附近环绕，并以局部球形透视观察弹道与脏器受击。
## 同时只播一段；连发不会叠加或重开；点击 / 触摸 / 按键可跳过；结束后恢复时间与相机。

signal started
signal finished

const SLOW := 0.045  # 比 0.2.10 的 0.08 更慢
const WALL_MAX := 18.5  # 只作故障兜底，须覆盖跟随 + 穿过 + 穿出后继续飞 + 4 秒停留
## t27u：弹头穿出人体后继续沿弹道飞（墙钟视速），直到撞到世界表面 / 最远距离 / 最长时间，再进入 4 秒停留。
const THROUGH_SPEED := 3.2
const THROUGH_MAX_SEC := 1.6
const THROUGH_MAX_DIST := 14.0
const FLY_SPEED := 4.0  # 特写里弹头在空气中的视速（米/秒，墙钟）；比 0.2.10 的 8.5 更慢
const PARK_PASS_MIN := 0.55  # 体内穿过最短墙钟
const HOLD_SEC := 4.0  # 穿过后在环绕受击点停留的墙钟秒数
const COOLDOWN_SEC := 0.9
const SPHERE_R := 0.36  # 特写透视范围加大，绕射时仍能看见弹道与脏器
## 透视强度（不是半径）：留一点皮肤轮廓，脏器仍可见。原先 0.95 会把皮肤完全挖空。
const XRAY_K := 0.48
const JELLO_RAD := 0.011
const JELLO_STRENGTH := 0.38
const ORBIT_SPEED := 0.32  # 比 0.2.12 的 0.55 更慢
const SMOKE_FADE := 0.75
const SMOKE_DELAY := 0.05
const SMOKE_WIDTH := 0.012

var settings: Node
var player: Node
var playing: bool = false
var last_triggered: bool = false
var last_reason: PackedStringArray = PackedStringArray()
## 测试：>= 0 时替代 randf()
var debug_roll: float = -1.0
## 测试/截图：follow / park / idle
var debug_phase: String = "idle"

var _cam: Camera3D
var _prev: Camera3D
var _prev_xray: Dictionary = {}  # organs -> {on, amount, show}
var _bullet: Dictionary = {}
var _muzzle: Vector3
var _entry: Vector3
var _exit: Vector3
var _dir: Vector3
var _t: float = 0.0
var _wall: float = 0.0
var _park_t: float = 0.0
var _hold_t: float = 0.0
var _through_t: float = 0.0
## 每发弹头的穿出后飞行：{rec, from, dir, len}
var _through: Array = []
var _phase: String = "idle"
var _saved_scale: float = 1.0
var _organs: Node
var _skip_dt: bool = false
var _hud_hidden: CanvasLayer
var _cooldown: float = 0.0
var _burst_lock: bool = false
var _park_eye0: Vector3 = Vector3.ZERO
## t28u：环绕受击区域的累计时间（穿过体内 → 弹头穿出继续飞 → 4 秒停留 连续累加），
## 镜头始终绕受击点转，不跟弹头出去，也不在阶段切换时跳回起始角度。
var _orbit_t: float = 0.0
var _smoke_pts: Array = []  # 兼容：所有弹道点的扁平视图
var _smoke_trails: Array = []  # 每发弹头一条 {pts: Array[{p, age}], wait: float}
var _smoke_mi: MeshInstance3D
var _smoke_mesh: ImmediateMesh
var _smoke_wait: float = 0.0
## 同一发射出的全部弹头（霰弹多弹头一起飞）。
var _pellets: Array = []


func setup(p: Node, s: Node) -> void:
	player = p
	settings = s
	_cam = Camera3D.new()
	_cam.name = "BulletCam"
	_cam.current = false
	_cam.fov = 42.0
	_cam.near = 0.02
	_cam.far = 80.0
	add_child(_cam)
	_build_smoke()
	set_process(true)
	set_process_unhandled_input(true)


func is_playing() -> bool:
	return playing


func has_smoke_trail() -> bool:
	return _smoke_mi != null and is_instance_valid(_smoke_mi)


func smoke_point_count() -> int:
	_flatten_smoke_pts()
	return _smoke_pts.size()


func smoke_trail_count() -> int:
	# 至少有 2 个点、能画出轨迹线的弹道数量。
	var n := 0
	for tr in _smoke_trails:
		if not (tr is Dictionary):
			continue
		var pts: Array = tr.get("pts", [])
		if pts.size() >= 2:
			n += 1
	return n


func pellet_trail_ready() -> bool:
	# 特写里每一发弹头都有自己的白色弹道。
	if not playing:
		return false
	var need := maxi(1, _pellets.size())
	return smoke_trail_count() >= need


func debug_reset() -> void:
	if playing:
		_stop()
	_cooldown = 0.0
	_burst_lock = false
	debug_phase = "idle"


func skip() -> void:
	if playing:
		_stop()


func _unhandled_input(event: InputEvent) -> void:
	if not playing:
		return
	var go := false
	if event is InputEventKey and event.pressed and not event.echo:
		go = true
	elif event is InputEventMouseButton and event.pressed:
		go = true
	elif event is InputEventScreenTouch and event.pressed:
		go = true
	if go:
		_stop()
		get_viewport().set_input_as_handled()


func consider(info: Dictionary, projectile: Dictionary = {}) -> bool:
	last_triggered = false
	last_reason = PackedStringArray()
	if playing:
		return false
	# 连发：特写进行中或刚结束（扳机还按着 / 冷却）不再开下一段。调试 roll 可绕过冷却以便自检。
	if debug_roll < 0.0 and (_cooldown > 0.0 or _burst_lock):
		return false
	if settings == null or not bool(settings.get("bullet_cam_enabled")):
		return false
	# 观察模式与第一人称一样：命中肠道/子宫（或尸体腹部路径）即可开特写。
	var gut := bool(info.get("gut", false))
	var ut := bool(info.get("uterus", false))
	var body = info.get("body")
	var corpse := false
	if body != null and body is Node and (body as Node).has_method("is_dead"):
		corpse = bool(body.call("is_dead"))
	var corpse_path := bool(info.get("corpse_path", false)) or (corpse and bool(info.get("hit", false)))
	if not gut and not ut:
		if corpse_path:
			last_reason.append("corpse")
		else:
			return false
	if gut:
		last_reason.append("gut")
	if ut:
		last_reason.append("uterus")
	var roll := debug_roll if debug_roll >= 0.0 else randf()
	var chance := float(settings.get("bullet_cam_chance"))
	if roll >= chance:
		return false
	_start(info, projectile)
	return true


func _start(info: Dictionary, projectile: Dictionary) -> void:
	playing = true
	last_triggered = true
	_burst_lock = true
	_organs = info.get("organs")
	_prev = get_viewport().get_camera_3d()
	_dir = info.get("dir", Vector3.FORWARD)
	if _dir.length_squared() < 1e-8:
		_dir = Vector3.FORWARD
	_dir = _dir.normalized()
	_entry = _as_vec3(info.get("entry"), _as_vec3(info.get("pos"), Vector3.ZERO))
	var exit_v = info.get("exit")
	if exit_v is Vector3 and (exit_v as Vector3).is_finite():
		_exit = exit_v
	else:
		_exit = _entry + _dir * 0.28
	# 从枪口开始跟随：优先弹头/查询里的 origin，否则从入射点往回退一段。
	var muz = info.get("origin", info.get("muzzle", null))
	if muz is Vector3 and (muz as Vector3).is_finite() and (_entry - muz).length() > 0.05:
		_muzzle = muz
	elif not projectile.is_empty() and projectile.get("origin") is Vector3 and (projectile["origin"] as Vector3).is_finite():
		_muzzle = projectile["origin"]
	else:
		_muzzle = _entry - _dir * 0.85
	_t = 0.0
	_wall = 0.0
	_park_t = 0.0
	_hold_t = 0.0
	_through_t = 0.0
	_through.clear()
	_phase = "follow"
	debug_phase = "follow"
	_skip_dt = true
	_saved_scale = Engine.time_scale if Engine.time_scale > 0.01 else 1.0
	Engine.time_scale = SLOW
	_prev_xray.clear()
	if _organs and is_instance_valid(_organs):
		_prev_xray["on"] = bool(_organs.get("xray_enabled"))
		_prev_xray["amount"] = float(_organs.get("xray_amount"))
		_prev_xray["show"] = bool(_organs.get("show_organs")) if _organs.get("show_organs") != null else true
		if _organs.has_method("set_show_organs") and not bool(_prev_xray["show"]):
			_organs.call("set_show_organs", true)
		# 用局部球透视，不打开全身透视窗；结束时清球并恢复原状态。
		if _organs.has_method("set_xray_sphere_world"):
			_organs.call("set_xray_sphere_world", _muzzle, SPHERE_R, XRAY_K)
	_bullet = projectile
	_pellets = _collect_pellets(projectile)
	if not _bullet.is_empty():
		_bullet["cinematic"] = true
		_bullet["pos"] = _muzzle
	_smoke_pts.clear()
	_smoke_wait = 0.0
	_reset_smoke_trails()
	_cam.current = true
	_place_follow(_muzzle)
	var hud := get_parent().get_node_or_null("HUD")
	if hud is CanvasLayer:
		_hud_hidden = hud
		hud.visible = false
	started.emit()


func _process(dt: float) -> void:
	# 冷却按墙钟走，即使没在播放也要减完，避免连发刚结束又立刻开下一段。
	var wall := dt / maxf(Engine.time_scale, 1e-6)
	wall = minf(wall, 0.05)
	if not playing:
		if _cooldown > 0.0:
			_cooldown = maxf(0.0, _cooldown - wall)
		_update_burst_lock()
		return
	if _skip_dt:
		_skip_dt = false
		_place_follow(_muzzle)
		if not _cam.current:
			_cam.current = true
		return
	_tick(wall)


## 测试：按墙钟推进特写（不受单帧 0.05 上限影响，内部仍分步）。
func debug_advance(wall_sec: float) -> void:
	if _skip_dt:
		_skip_dt = false
		_place_follow(_muzzle)
	var left := wall_sec
	while playing and left > 1e-6:
		var step := minf(left, 0.05)
		_tick(step)
		left -= step


func _tick(wall: float) -> void:
	if not playing:
		return
	_wall += wall
	if _phase == "follow":
		var span := maxf(0.15, _muzzle.distance_to(_entry))
		var dur := maxf(0.40, span / FLY_SPEED)
		_t = minf(1.0, _t + wall / dur)
		var pos := _muzzle.lerp(_entry, _t)
		_place_all_pellets(_t)
		_place_follow(_pellet_centroid(_t, pos))
		_push_all_trails(_t, wall)
		_set_sphere(pos)
		if _t >= 1.0:
			_enter_park()
	elif _phase == "park":
		_park_t += wall
		# 弹头在体内走完通道，相机停在受击点环绕；穿过后再进入 4 秒停留。
		var in_span := maxf(0.08, _entry.distance_to(_exit))
		var pass_dur := maxf(PARK_PASS_MIN, in_span / 0.28)
		var in_u := clampf(_park_t / pass_dur, 0.0, 1.0)
		var bpos := _entry.lerp(_exit + _dir * 0.04, in_u)
		_place_all_pellets(1.0 + in_u)
		_place_bullet(bpos, _dir)
		_push_all_trails(1.0 + in_u, wall)
		_set_sphere(_entry.lerp(bpos, 0.45))
		_update_organ_jello(in_u, 0.0, wall)
		_orbit_t += wall
		_place_park(_orbit_t)
		if in_u >= 1.0:
			_enter_through()
	elif _phase == "through":
		_through_t += wall
		var all_done := _step_through(_through_t, wall)
		# 弹头继续往前飞，镜头仍环绕受击区域（不跟随弹头）。
		_orbit_t += wall
		_place_park(_orbit_t)
		_update_organ_jello(1.0, clampf(_through_t / maxf(HOLD_SEC, 0.01), 0.0, 1.0) * 0.3, wall)
		if all_done or _through_t >= THROUGH_MAX_SEC:
			_finish_through()
			_enter_hold()
	elif _phase == "hold":
		_hold_t += wall
		_orbit_t += wall
		_place_park(_orbit_t)
		var settle := clampf(_hold_t / maxf(HOLD_SEC, 0.01), 0.0, 1.0)
		_update_organ_jello(1.0, settle, wall)
		if _hold_t >= HOLD_SEC:
			_stop()
	if playing and not _cam.current:
		_cam.current = true
	# 故障兜底：不应在正常的跟随 + 穿过 + 4 秒停留之前切断。
	if _wall >= WALL_MAX and playing:
		_stop()


func _enter_through() -> void:
	_phase = "through"
	debug_phase = "through"
	_through_t = 0.0
	_through.clear()
	var recs: Array = []
	if _single_mode():
		if not _bullet.is_empty():
			recs.append(_bullet)
		elif not _pellets.is_empty():
			recs.append(_pellets[0])
	else:
		recs = _pellets.duplicate()
		if not _bullet.is_empty() and _bullet not in recs:
			recs.append(_bullet)
	for rec in recs:
		if not (rec is Dictionary):
			continue
		var d: Vector3 = _dir if _single_mode() else _as_vec3(rec.get("dir"), _dir)
		if d.length_squared() < 1e-10:
			d = _dir
		d = d.normalized()
		var from: Vector3 = _as_vec3(rec.get("pos"), _exit + _dir * 0.04)
		var len := _through_len(from, d)
		_through.append({"rec": rec, "from": from, "dir": d, "len": len, "done": false})


## 穿出后的飞行长度：沿弹道找第一块世界表面（跳过人体、冲击球等 ballistics_ignore），否则按最远距离。
func _through_len(from: Vector3, d: Vector3) -> float:
	var w3 := get_world_3d()
	if w3 == null or w3.direct_space_state == null or not from.is_finite():
		return THROUGH_MAX_DIST
	var exclude: Array[RID] = []
	var start := from
	for _i in 8:
		var q := PhysicsRayQueryParameters3D.create(start, from + d * THROUGH_MAX_DIST)
		q.collide_with_areas = false
		q.collision_mask = 1 | 2
		q.exclude = exclude
		var hit := w3.direct_space_state.intersect_ray(q)
		if hit.is_empty():
			return THROUGH_MAX_DIST
		var col = hit.get("collider")
		if _is_pass_through(col):
			if hit.get("rid") is RID:
				exclude.append(hit["rid"])
			start = (hit["position"] as Vector3) + d * 0.002
			continue
		return maxf(0.0, from.distance_to(hit["position"]) - 0.02)
	return THROUGH_MAX_DIST


func _is_pass_through(col: Object) -> bool:
	var n := col as Node
	if n == null:
		return true
	if n.is_in_group("ballistics_ignore") or n is PhysicalBone3D or n is CharacterBody3D:
		return true
	var x := n
	while x:
		if x.has_method("get_organs") or x.is_in_group("wound_body"):
			return true
		x = x.get_parent()
	return false


## 推进穿出后的弹头；全部到达终点返回 true。到终点（撞墙 / 最远距离）的弹头隐藏。
func _step_through(t: float, wall: float) -> bool:
	var all_done := true
	var push_trails := not _single_mode()
	var i := 0
	for tr in _through:
		var rec: Dictionary = tr["rec"]
		var d: Vector3 = tr["dir"]
		var dist := minf(float(tr["len"]), THROUGH_SPEED * t)
		var pos: Vector3 = (tr["from"] as Vector3) + d * dist
		rec["pos"] = pos
		rec["cinematic"] = true
		var reached := dist >= float(tr["len"]) - 1e-4
		tr["done"] = reached
		if not reached:
			all_done = false
		var nd = rec.get("node")
		if nd and is_instance_valid(nd):
			(nd as Node3D).visible = not reached
			(nd as Node3D).global_position = pos
			_orient_projectile(nd, d)
		if push_trails and i < _smoke_trails.size() and not reached:
			_accumulate_trail(_smoke_trails[i], pos, wall)
		elif _single_mode() and i == 0 and not reached and not _smoke_trails.is_empty():
			_accumulate_trail(_smoke_trails[0], pos, wall)
		i += 1
	_flatten_smoke_pts()
	_rebuild_smoke()
	return all_done


func _finish_through() -> void:
	# 时间到仍未撞墙的弹头：停在当前位置并隐藏，结束后由弹道系统从这里继续真实飞行。
	for tr in _through:
		var nd = (tr["rec"] as Dictionary).get("node")
		if nd and is_instance_valid(nd):
			(nd as Node3D).visible = false


## 自检：镜头与受击点的关系。dist = 镜头到入射点距离，look_err = 视线偏离受击点的角度（度），
## bullet_dist = 镜头到最远穿出弹头的距离（弹头飞远时应变大，镜头不跟）。
func debug_cam_focus() -> Dictionary:
	if not playing or _cam == null:
		return {"ok": false}
	var eye := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	var to := _entry - eye
	var err := rad_to_deg(fwd.angle_to(to.normalized())) if to.length() > 1e-5 else 0.0
	var bd := 0.0
	for tr in _through:
		var pos: Vector3 = _as_vec3((tr["rec"] as Dictionary).get("pos"), tr["from"])
		bd = maxf(bd, eye.distance_to(pos))
	return {"ok": true, "dist": to.length(), "look_err": err, "bullet_dist": bd, "eye": eye, "entry": _entry, "orbit_t": _orbit_t, "phase": _phase}


## 自检：穿出后飞行的最远位移（米）与弹头数。
func debug_through() -> Dictionary:
	var best := 0.0
	var vis := 0
	for tr in _through:
		var rec: Dictionary = tr["rec"]
		var pos: Vector3 = _as_vec3(rec.get("pos"), tr["from"])
		best = maxf(best, pos.distance_to(_exit))
		var nd = rec.get("node")
		if nd and is_instance_valid(nd) and (nd as Node3D).visible:
			vis += 1
	return {"count": _through.size(), "max_beyond_exit": best, "visible": vis, "t": _through_t}


func _enter_hold() -> void:
	_phase = "hold"
	debug_phase = "hold"
	_hold_t = 0.0


func _enter_park() -> void:
	_phase = "park"
	debug_phase = "park"
	_park_t = 0.0
	_orbit_t = 0.0
	# 可见弹头刚到达体表：这时才播出腹部受击特效，并开始内脏果冻挤开。
	_flush_impact()
	_update_organ_jello(0.0, 0.0, 0.0)
	var up := Vector3.UP
	if absf(_dir.dot(up)) > 0.9:
		up = Vector3.RIGHT
	var side := _dir.cross(up).normalized()
	up = side.cross(_dir).normalized()
	# 停在入射点侧后上方，离身体更远，旋转时不容易穿进网格。
	_park_eye0 = _entry - _dir * 0.38 + up * 0.16 + side * 0.22
	_park_eye0 = _avoid_mesh_clip(_park_eye0, _entry)


func _place_follow(pos: Vector3) -> void:
	if not pos.is_finite() or not _dir.is_finite() or _dir.length_squared() < 1e-10:
		return
	var up := Vector3.UP
	if absf(_dir.dot(up)) > 0.9:
		up = Vector3.RIGHT
	var side := _dir.cross(up)
	if side.length_squared() < 1e-8:
		side = Vector3.RIGHT
	side = side.normalized()
	up = side.cross(_dir).normalized()
	var eye := pos - _dir * 0.14 + up * 0.05 + side * 0.035
	_cam.global_transform = Transform3D(_safe_looking_at(_dir, up), eye)


func _place_park(t: float) -> void:
	var up := Vector3.UP
	var rel: Vector3 = _park_eye0 - _entry
	var ang := t * ORBIT_SPEED
	var rot := Basis(up, ang)
	var eye: Vector3 = _entry + rot * rel
	eye = _avoid_mesh_clip(eye, _entry)
	var look := (_entry - eye)
	if not look.is_finite() or look.length_squared() < 1e-8:
		look = _dir if _dir.length_squared() > 1e-8 else Vector3.FORWARD
	_cam.global_transform = Transform3D(_safe_looking_at(look.normalized(), up), eye)


func cinematic_pellet_count() -> int:
	return maxi(1, _pellets.size()) if playing else 0


func orbit_speed() -> float:
	return ORBIT_SPEED


func xray_sphere_radius() -> float:
	return SPHERE_R


func cinematic_xray_amount() -> float:
	return XRAY_K


static func is_cluster_shot(lead: Dictionary) -> bool:
	if lead.is_empty():
		return false
	var par = lead.get("par")
	if par is Dictionary and str((par as Dictionary).get("category", "")) == "shotgun":
		return true
	return false


## 测试：特写镜头到弹头的距离，以及弹头偏离镜头视线中心的角度（度）。
func debug_track_error() -> Dictionary:
	var out := {"ok": false}
	if not playing or _cam == null or _pellets.is_empty():
		return out
	var rec: Dictionary = _pellets[0]
	var bp: Vector3 = _as_vec3(rec.get("pos"), _muzzle)
	if not _single_mode():
		bp = _pellet_centroid(_t, bp)
	var eye := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	out["dist"] = eye.distance_to(bp)
	out["angle"] = rad_to_deg(fwd.angle_to((bp - eye).normalized())) if eye.distance_to(bp) > 1e-4 else 0.0
	out["phase"] = _phase
	out["ok"] = true
	return out


## 当前特写模式："cluster" = 霰弹多弹头，"single" = 单发跟随，"" = 未播放。
func cinematic_mode() -> String:
	if not playing:
		return ""
	return "cluster" if _pellets.size() > 1 else "single"


func _collect_pellets(lead: Dictionary) -> Array:
	var out: Array = []
	var sid := int(lead.get("shot_id", 0)) if not lead.is_empty() else 0
	var bal = lead.get("ballistics") if not lead.is_empty() else null
	if bal == null and player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws:
			bal = ws.get("ballistics")
	# 只有霰弹才走多弹头成组特写。步枪/手枪/冲锋枪始终单发跟随，绝不借用别的弹组
	# （0.2.12 t24u 的回退曾把上一发霰弹残留的弹组塞给步枪特写，导致所有武器都变成霰弹特写、追踪错乱）。
	if not is_cluster_shot(lead):
		if not lead.is_empty():
			lead["cinematic"] = true
			out.append(lead)
		return out
	var group: Array = []
	if bal and sid != 0 and bal.has_method("projectiles_for_shot"):
		var got = bal.call("projectiles_for_shot", sid)
		if got is Array:
			group = got
	if group.is_empty() and bal and bal.has_method("live_projectiles") and sid != 0:
		group = bal.call("live_projectiles")
	for p in group:
		if not (p is Dictionary):
			continue
		var rec: Dictionary = p
		if sid != 0 and int(rec.get("shot_id", 0)) != sid:
			continue
		rec["cinematic"] = true
		if rec not in out:
			out.append(rec)
	if out.is_empty() and not lead.is_empty():
		lead["cinematic"] = true
		out.append(lead)
	elif not lead.is_empty() and lead not in out:
		lead["cinematic"] = true
		out.insert(0, lead)
	return out


func _single_mode() -> bool:
	return _pellets.size() <= 1


func _single_pos(u: float) -> Vector3:
	## 单发跟随：弹头严格沿 枪口 → 入射点 飞行，镜头始终锁在弹头上（不再用弹头记录里的相机原点/偏差方向）。
	if u <= 1.0:
		return _muzzle.lerp(_entry, clampf(u, 0.0, 1.0))
	var span := maxf(0.15, _muzzle.distance_to(_entry))
	return _entry + _dir * span * (minf(u, 2.2) - 1.0)


func _pellet_centroid(u: float, fallback: Vector3) -> Vector3:
	if _pellets.is_empty() or _single_mode():
		return _single_pos(u) if not _pellets.is_empty() else fallback
	var acc := Vector3.ZERO
	var n := 0
	var span := maxf(0.15, _muzzle.distance_to(_entry))
	for rec in _pellets:
		if not (rec is Dictionary):
			continue
		var o: Vector3 = _as_vec3(rec.get("origin"), _muzzle)
		var d: Vector3 = _as_vec3(rec.get("dir"), _dir)
		if d.length_squared() < 1e-10:
			d = _dir
		d = d.normalized()
		# u<=1 在空气中飞向入射距离；u>1 继续沿自身方向穿过。
		var dist := span * clampf(u, 0.0, 2.2)
		acc += o + d * dist
		n += 1
	if n <= 0:
		return fallback
	return acc / float(n)


func _place_all_pellets(u: float) -> void:
	var span := maxf(0.15, _muzzle.distance_to(_entry))
	var single := _single_mode()
	for rec in _pellets:
		if not (rec is Dictionary):
			continue
		var o: Vector3 = _as_vec3(rec.get("origin"), _muzzle)
		var d: Vector3 = _as_vec3(rec.get("dir"), _dir)
		if d.length_squared() < 1e-10:
			d = _dir
		d = d.normalized()
		var pos := o + d * (span * clampf(u, 0.0, 2.2))
		if single:
			pos = _single_pos(u)
			d = _dir
		rec["pos"] = pos
		rec["cinematic"] = true
		if rec.get("node") and is_instance_valid(rec["node"]):
			var n: Node3D = rec["node"]
			n.visible = true
			n.global_position = pos
			_orient_projectile(n, d)


func _avoid_mesh_clip(eye: Vector3, look_at: Vector3) -> Vector3:
	# 从受击点向外探到目标机位：若中间撞到身体，就把相机停在体表外侧。
	if not eye.is_finite() or not look_at.is_finite():
		return eye
	var w3 := get_world_3d()
	if w3 == null or w3.direct_space_state == null:
		return eye
	var rel := eye - look_at
	var dist := rel.length()
	if dist < 0.08:
		return eye
	var dir := rel / dist
	var start := look_at + dir * 0.04
	var q := PhysicsRayQueryParameters3D.create(start, eye)
	q.collide_with_areas = false
	q.collision_mask = 1 | 2
	var hit := w3.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		# 仍保证一个最小观察距离，避免近裁面切进皮肤。
		if dist < 0.20:
			return look_at + dir * 0.20
		return eye
	var hp: Vector3 = hit["position"]
	var nrm: Vector3 = hit.get("normal", -dir)
	if not (nrm is Vector3) or (nrm as Vector3).length_squared() < 1e-8:
		nrm = -dir
	else:
		nrm = (nrm as Vector3).normalized()
		if nrm.dot(dir) > 0.0:
			nrm = -nrm
	var safe: Vector3 = hp + nrm * 0.10
	if safe.distance_to(look_at) < 0.18:
		safe = look_at + (safe - look_at).normalized() * 0.18
	return safe


func _place_bullet(pos: Vector3, dir: Vector3) -> void:
	if _bullet.is_empty():
		return
	_bullet["pos"] = pos
	_bullet["vel"] = dir * FLY_SPEED
	if _bullet.get("node") and is_instance_valid(_bullet["node"]):
		var n: Node3D = _bullet["node"]
		n.visible = true
		n.global_position = pos
		_orient_projectile(n, dir)


func _orient_projectile(n: Node3D, d: Vector3) -> void:
	# 弹头网格沿 +X 向前。look_at 会把 -Z 对准路径，特写里看起来像横着飞。
	if n == null or d.length_squared() < 1e-10:
		return
	d = d.normalized()
	var up := Vector3.UP
	if absf(d.dot(up)) > 0.95:
		up = Vector3.FORWARD
	var z := d.cross(up)
	if z.length_squared() < 1e-8:
		z = d.cross(Vector3.RIGHT)
	z = z.normalized()
	var y := z.cross(d).normalized()
	var xf := n.global_transform
	xf.basis = Basis(d, y, z).orthonormalized()
	n.global_transform = xf


func _set_sphere(pos: Vector3) -> void:
	if _organs and is_instance_valid(_organs) and _organs.has_method("set_xray_sphere_world"):
		_organs.call("set_xray_sphere_world", pos, SPHERE_R, XRAY_K)


func _update_burst_lock() -> void:
	if not _burst_lock:
		return
	var trig := false
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws:
			trig = bool(ws.get("trigger"))
	if not trig:
		_burst_lock = false


func _stop() -> void:
	if not playing:
		return
	playing = false
	_phase = "idle"
	debug_phase = "idle"
	_cooldown = COOLDOWN_SEC
	if _hud_hidden and is_instance_valid(_hud_hidden):
		_hud_hidden.visible = true
	_hud_hidden = null
	Engine.time_scale = _saved_scale if _saved_scale > 0.01 else 1.0
	if _organs and is_instance_valid(_organs):
		if _organs.has_method("clear_xray_sphere"):
			_organs.call("clear_xray_sphere")
		if not _prev_xray.is_empty():
			_organs.call("set_xray_enabled", bool(_prev_xray.get("on", false)))
			_organs.call("set_xray_amount", float(_prev_xray.get("amount", 0.38)))
			if _organs.has_method("set_show_organs") and _prev_xray.has("show"):
				_organs.call("set_show_organs", bool(_prev_xray["show"]))
	_prev_xray.clear()
	# 跳过或结束特写时，若还没播受击特效，现在补上，避免伤口丢失。
	_flush_impact()
	if not _bullet.is_empty():
		_bullet["cinematic"] = false
	for rec in _pellets:
		if rec is Dictionary:
			rec["cinematic"] = false
	_pellets = []
	_bullet = {}
	_through.clear()
	_smoke_pts.clear()
	_smoke_trails.clear()
	_rebuild_smoke()
	if _organs and is_instance_valid(_organs) and _organs.has_method("clear_cinematic_jello"):
		_organs.call("clear_cinematic_jello")
	_cam.current = false
	if _prev and is_instance_valid(_prev):
		_prev.current = true
	elif player and player.has_method("get_camera"):
		var c: Camera3D = player.call("get_camera")
		if c:
			c.current = true
	finished.emit()


func _as_vec3(v, fallback: Vector3) -> Vector3:
	if v is Vector3 and (v as Vector3).is_finite():
		return v
	return fallback


func _safe_looking_at(dir: Vector3, up: Vector3 = Vector3.UP) -> Basis:
	if not dir.is_finite() or dir.length_squared() < 1e-10:
		return Basis.IDENTITY
	dir = dir.normalized()
	var u := up
	if not u.is_finite() or u.length_squared() < 1e-10:
		u = Vector3.UP
	u = u.normalized()
	if absf(dir.dot(u)) > 0.94:
		u = Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.94 else Vector3.UP
	return Basis.looking_at(dir, u)


func _flush_impact() -> void:
	var seen: Array = []
	if not _bullet.is_empty():
		seen.append(_bullet)
	for rec in _pellets:
		if rec is Dictionary and rec not in seen:
			seen.append(rec)
	for rec in seen:
		if rec.get("impact_applied", false):
			continue
		if not (rec.get("pending_impact") is Dictionary):
			continue
		var bal = rec.get("ballistics")
		if bal and is_instance_valid(bal) and bal.has_method("apply_deferred_impact"):
			bal.call("apply_deferred_impact", rec)


func _build_smoke() -> void:
	if _smoke_mi:
		return
	_smoke_mesh = ImmediateMesh.new()
	_smoke_mi = MeshInstance3D.new()
	_smoke_mi.name = "BulletSmokeTrail"
	_smoke_mi.mesh = _smoke_mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.93, 0.94, 0.96, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.86, 0.88, 0.92)
	mat.emission_energy_multiplier = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	_smoke_mi.material_override = mat
	_smoke_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_smoke_mi)


func _reset_smoke_trails() -> void:
	_smoke_trails.clear()
	var n := maxi(1, _pellets.size())
	for _i in n:
		_smoke_trails.append({"pts": [], "wait": 0.0})


func _ensure_smoke_trails() -> void:
	var n := maxi(1, _pellets.size())
	while _smoke_trails.size() < n:
		_smoke_trails.append({"pts": [], "wait": 0.0})
	while _smoke_trails.size() > n:
		_smoke_trails.pop_back()


func _pellet_pos_at(rec: Dictionary, u: float) -> Vector3:
	if _single_mode():
		return _single_pos(u)
	var span := maxf(0.15, _muzzle.distance_to(_entry))
	var o: Vector3 = _as_vec3(rec.get("origin"), _muzzle)
	var d: Vector3 = _as_vec3(rec.get("dir"), _dir)
	if d.length_squared() < 1e-10:
		d = _dir
	d = d.normalized()
	return o + d * (span * clampf(u, 0.0, 2.2))


func _push_all_trails(u: float, wall: float) -> void:
	_ensure_smoke_trails()
	if _pellets.is_empty():
		var pos := _muzzle.lerp(_entry, clampf(u, 0.0, 1.0))
		if u > 1.0:
			var in_u := clampf(u - 1.0, 0.0, 1.0)
			pos = _entry.lerp(_exit + _dir * 0.04, in_u)
		_accumulate_trail(_smoke_trails[0], pos, wall)
	else:
		var i := 0
		for rec in _pellets:
			if i >= _smoke_trails.size():
				break
			if rec is Dictionary:
				_accumulate_trail(_smoke_trails[i], _pellet_pos_at(rec, u), wall)
			i += 1
	_flatten_smoke_pts()
	_rebuild_smoke()


func _accumulate_trail(tr: Dictionary, pos: Vector3, wall: float) -> void:
	if not pos.is_finite():
		return
	var pts: Array = tr.get("pts", [])
	var wait := float(tr.get("wait", 0.0)) + wall
	# 略微滞后于弹头，形成拖在后面的白烟。每发弹头各自一条。
	if wait >= SMOKE_DELAY or pts.is_empty():
		wait = 0.0
		if pts.is_empty() or pos.distance_to(pts[pts.size() - 1]["p"]) > 0.012:
			pts.append({"p": pos, "age": 0.0})
	var i := 0
	while i < pts.size():
		pts[i]["age"] = float(pts[i]["age"]) + wall
		if float(pts[i]["age"]) > SMOKE_FADE:
			pts.remove_at(i)
		else:
			i += 1
	while pts.size() > 80:
		pts.remove_at(0)
	tr["pts"] = pts
	tr["wait"] = wait


func _flatten_smoke_pts() -> void:
	_smoke_pts.clear()
	for tr in _smoke_trails:
		if not (tr is Dictionary):
			continue
		for rec in tr.get("pts", []):
			_smoke_pts.append(rec)


func _push_smoke(pos: Vector3, wall: float) -> void:
	# 兼容旧接口：没有分弹头时仍可往第一条轨迹加点。
	_ensure_smoke_trails()
	if _smoke_trails.is_empty():
		_reset_smoke_trails()
	_accumulate_trail(_smoke_trails[0], pos, wall)
	_flatten_smoke_pts()
	_rebuild_smoke()


func _update_organ_jello(progress: float, settle: float, wall: float) -> void:
	if _organs == null or not is_instance_valid(_organs):
		return
	if _organs.has_method("set_cinematic_jello"):
		_organs.call("set_cinematic_jello", _entry, _exit, _dir, clampf(progress, 0.0, 1.0), JELLO_RAD, clampf(settle, 0.0, 1.0), JELLO_STRENGTH)
	if wall > 0.0 and _organs.has_method("advance_cinematic_jello"):
		_organs.call("advance_cinematic_jello", wall)


func _rebuild_smoke() -> void:
	if _smoke_mesh == null:
		return
	_smoke_mesh.clear_surfaces()
	for tr in _smoke_trails:
		if not (tr is Dictionary):
			continue
		var pts: Array = tr.get("pts", [])
		if pts.size() < 2:
			continue
		_smoke_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in range(pts.size()):
			var a: Vector3 = pts[i]["p"]
			var nxt: Vector3 = pts[mini(i + 1, pts.size() - 1)]["p"]
			var prv: Vector3 = pts[maxi(i - 1, 0)]["p"]
			var tan: Vector3 = nxt - prv
			if tan.length_squared() < 1e-10:
				tan = _dir
			tan = tan.normalized()
			var side := tan.cross(Vector3.UP)
			if side.length_squared() < 1e-8:
				side = tan.cross(Vector3.RIGHT)
			side = side.normalized() * SMOKE_WIDTH
			var age := float(pts[i]["age"])
			var alpha := clampf(1.0 - age / SMOKE_FADE, 0.0, 1.0)
			alpha *= 0.72
			var col := Color(0.93, 0.95, 0.97, alpha)
			_smoke_mesh.surface_set_color(col)
			_smoke_mesh.surface_add_vertex(a + side)
			_smoke_mesh.surface_set_color(col)
			_smoke_mesh.surface_add_vertex(a - side)
		_smoke_mesh.surface_end()
