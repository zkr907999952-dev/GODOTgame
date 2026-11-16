extends Node
const CombatDamage := preload("res://scripts/combat_damage.gd")
## 弹道：真实弹头网格按速度 / 重力 / 阻力飞行，扫掠检测避免高速穿透。
## 命中世界留下弹痕；命中人体交给 OrganRig.apply_ballistic_hit。保留 hit / shot 信号。

signal hit(position: Vector3, normal: Vector3, collider: Object, weapon_id: String)
signal body_hit(info: Dictionary)
signal organ_path(info: Dictionary)

const PROJ_SCENE := preload("res://assets/weapons/shared/projectiles.scn")
## 弹头网格在离摄像机这么远之后才绘制，避免第一人称贴脸巨大弹头。拖尾不受影响。
const MESH_CAM_DIST := 0.85
const MAX_LIVE := 64
const MAX_DECALS := 48
const STEP_MAX := 0.08  # 每子步最大行程（米），防止穿墙
const G := Vector3(0, -9.8, 0)

## 各武器默认弹道（可被 WeaponDef 覆盖）
const BALL := {
	"pistol": {"v0": 350.0, "drag": 0.0009, "mass": 0.008, "energy": 0.45, "overpen": 0.35, "impulse": 0.40, "proj": "9mm_Projectile", "scale": 1.0, "radius": 0.004},
	"rifle": {"v0": 850.0, "drag": 0.00022, "mass": 0.004, "energy": 1.0, "overpen": 0.85, "impulse": 0.82, "proj": "5_56mm_Projectile", "scale": 1.0, "radius": 0.0035},
	"smg": {"v0": 400.0, "drag": 0.0007, "mass": 0.008, "energy": 0.58, "overpen": 0.45, "impulse": 0.52, "proj": "9mm_Projectile", "scale": 1.0, "radius": 0.004},
	"shotgun": {"v0": 400.0, "drag": 0.0038, "mass": 0.0035, "energy": 0.70, "overpen": 0.12, "impulse": 0.70, "proj": "pellet_sphere", "scale": 1.0, "radius": 0.0045},
}

var exclude: Array[RID] = []
## 观察模式点击射击时为 true：弹道可以命中玩家本体。
var hit_owner: bool = false
## 下一发弹头是否忽略对发射者的排除（由 fire_along_ray 在生成前设置）。
var next_hit_owner: bool = false
## 同一扣扳机发出的多弹头共用 shot_id，特写时一起飞。
var next_shot_id: int = 0
var _shot_seq: int = 0
## 同一 shot_id 的全部弹头（含已结束的），供霰弹特写在部分弹头已回收后仍能成组跟随。
var _shot_groups: Dictionary = {}
var _shot_hit_owner: bool = false
var last_hit: Dictionary = {}
var last_body: Dictionary = {}
var last_organ: Dictionary = {}
## 测试可注入 0..1；< 0 则用 randf()
var debug_roll: float = -1.0

var _meshes: Dictionary = {}
var _live: Array = []  # Dictionary
var _pool: Array[MeshInstance3D] = []
var _decals: Array = []
var _spent: Array = []  # 短暂留在命中点的弹头
var _decal_mesh: SphereMesh
var _decal_mat: StandardMaterial3D
var _spark_mat: StandardMaterial3D
var _tracer_mat: StandardMaterial3D
var _host: Node
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	var root := PROJ_SCENE.instantiate()
	for c in root.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh:
			_meshes[str(c.name)] = (c as MeshInstance3D).mesh
	root.free()
	_decal_mesh = SphereMesh.new()
	_decal_mesh.radius = 0.012
	_decal_mesh.height = 0.008
	_decal_mesh.radial_segments = 8
	_decal_mesh.rings = 4
	_decal_mat = StandardMaterial3D.new()
	_decal_mat.albedo_color = Color(0.12, 0.08, 0.06)
	_decal_mat.roughness = 0.9
	_decal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_spark_mat = StandardMaterial3D.new()
	_spark_mat.albedo_color = Color(1.0, 0.75, 0.35)
	_spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_mat.emission_enabled = true
	_spark_mat.emission = Color(1.0, 0.7, 0.3)
	_spark_mat.emission_energy_multiplier = 2.5
	_tracer_mat = StandardMaterial3D.new()
	_tracer_mat.albedo_color = Color(1.0, 0.85, 0.4, 0.65)
	_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tracer_mat.emission_enabled = true
	_tracer_mat.emission = Color(1.0, 0.8, 0.35)
	_tracer_mat.emission_energy_multiplier = 1.8
	set_physics_process(true)


func params_of(weapon_id: String, w: Resource = null) -> Dictionary:
	var cat := "rifle"
	if w:
		cat = str(w.category)
	elif BALL.has(weapon_id):
		cat = weapon_id
	var p: Dictionary = BALL.get(cat, BALL["rifle"]).duplicate()
	if w:
		if float(w.muzzle_velocity) > 1.0:
			p["v0"] = float(w.muzzle_velocity)
		if float(w.drag) > 0.0:
			p["drag"] = float(w.drag)
		if str(w.projectile) != "":
			p["proj"] = str(w.projectile)
		if float(w.impact) > 0.0:
			p["impulse"] = float(w.impact)
			p["energy"] = float(w.impact)
		if float(w.penetration) > 0.0:
			p["overpen"] = float(w.penetration)
	p["category"] = cat
	p["weapon_id"] = weapon_id
	if w:
		if "damage" in w:
			p["damage"] = float(w.damage)
		if "range_m" in w:
			p["range_m"] = float(w.range_m)
	# 霰弹必须是黑色小球，忽略资源里可能残留的弹壳网格名
	if cat == "shotgun":
		p["proj"] = "pellet_sphere"
		p["scale"] = 1.0
	return p


func live_count() -> int:
	return _live.size()


func live_projectiles() -> Array:
	return _live


func begin_shot() -> int:
	_shot_seq += 1
	next_shot_id = _shot_seq
	_shot_hit_owner = hit_owner or next_hit_owner
	if not _shot_groups.has(next_shot_id):
		_shot_groups[next_shot_id] = []
	# 只保留最近若干组，避免字典无限增长。
	if _shot_groups.size() > 16:
		var keys: Array = _shot_groups.keys()
		keys.sort()
		for i in range(keys.size() - 16):
			_shot_groups.erase(keys[i])
	return next_shot_id


func end_shot() -> void:
	next_shot_id = 0
	next_hit_owner = false
	_shot_hit_owner = false


func projectiles_for_shot(sid: int) -> Array:
	if sid == 0:
		return []
	var out: Array = _shot_groups.get(sid, [])
	return out if out is Array else []


func best_shot_cluster() -> Array:
	# 优先最新的、数量最多的一组（霰弹特写不要被上一发残留的单发散弹带走）。
	var best: Array = []
	var best_id := 0
	for k in _shot_groups.keys():
		var g = _shot_groups[k]
		if not (g is Array):
			continue
		var sid := int(k)
		if (g as Array).size() > best.size() or ((g as Array).size() == best.size() and sid > best_id):
			best = g
			best_id = sid
	return best


func clear_all() -> void:
	for p in _live:
		_park(p)
	_live.clear()
	for s in _spent:
		if is_instance_valid(s["n"]):
			(s["n"] as Node).queue_free()
	_spent.clear()
	clear_decals()


## 发射一发。返回弹头字典（也进 _live）。
func fire_projectile(origin: Vector3, dir: Vector3, weapon_id: String, w: Resource = null, extra: Dictionary = {}) -> Dictionary:
	var par := params_of(weapon_id, w)
	for k in extra.keys():
		par[k] = extra[k]
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-10:
		return {}
	var d := dir.normalized()
	var pos := origin + d * 0.04
	var pr := _make_visual(str(par["proj"]), float(par["scale"]))
	pr.global_position = pos
	look_along(pr, d)
	var rec := {
		"pos": pos,
		"origin": pos,
		"vel": d * float(par["v0"]),
		"dir": d,
		"par": par,
		"id": weapon_id,
		"node": pr,
		"tracer": _make_tracer() if bool(par.get("tracer", true)) else null,
		"alive": true,
		"age": 0.0,
		"hit_body": false,
		"cinfo": {},
		"cinematic": false,
		"hit_owner": hit_owner or next_hit_owner or _shot_hit_owner,
		"shot_id": next_shot_id,
		"ballistics": self,
	}
	# 整组霰弹共用 next_hit_owner；单发（没有 begin_shot）仍在此清掉。
	if next_shot_id == 0:
		next_hit_owner = false
	_live.append(rec)
	if rec["shot_id"] != 0:
		if not _shot_groups.has(rec["shot_id"]):
			_shot_groups[rec["shot_id"]] = []
		(_shot_groups[rec["shot_id"]] as Array).append(rec)
	while _live.size() > MAX_LIVE:
		_end(_live[0], false)
	return rec


## 保留旧接口：立即沿方向扫一条射线（测试或备援），不生成弹头网格。
func fire_ray(origin: Vector3, dir: Vector3, range_m: float, weapon_id: String) -> Dictionary:
	var w3 := _world()
	if w3 == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * range_m)
	q.exclude = exclude
	q.collide_with_areas = false
	q.collision_mask = 1 | 2
	var r := w3.direct_space_state.intersect_ray(q)
	last_hit = r
	if r.is_empty():
		return r
	hit.emit(r["position"], r["normal"], r["collider"], weapon_id)
	_spawn_decal(r["position"], r["normal"], false)
	return r


func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	var i := 0
	while i < _live.size():
		var p: Dictionary = _live[i]
		if p.get("cinematic", false):
			p["age"] = float(p["age"]) + dt
			i += 1
			continue
		if not _step(p, dt):
			continue
		i += 1
	_step_spent(dt)


func _step(p: Dictionary, dt: float) -> bool:
	var par: Dictionary = p["par"]
	var drag: float = par["drag"]
	var remain := dt
	var guard := 0
	while remain > 1e-5 and guard < 48:
		guard += 1
		var vel: Vector3 = p["vel"]
		var speed := vel.length()
		if speed < 8.0 or float(p["age"]) > 6.0:
			_end(p, false)
			return false
		var dir := vel / speed
		var step_t := minf(remain, STEP_MAX / maxf(speed, 1.0))
		# 本子步末速度（半隐式：先加速再移动）
		var vel2 := (vel + G * step_t) * exp(-drag * speed * step_t)
		var mid := (vel + vel2) * 0.5
		var mid_s := mid.length()
		var travel := mid * step_t
		var tlen := travel.length()
		if tlen < 1e-6:
			p["vel"] = vel2
			remain = 0.0
			break
		var from: Vector3 = p["pos"]
		if not from.is_finite() or not travel.is_finite():
			_end(p, false)
			return false
		# 超远弹道直接结束，避免非法 look_at / 精度炸掉错误。
		if from.distance_squared_to(p.get("origin", from)) > 400.0 * 400.0:
			_end(p, false)
			return false
		var to := from + travel
		var allow_owner := bool(p.get("hit_owner", false))
		var saved_owner := hit_owner
		hit_owner = allow_owner
		var hitd := _ray(from, to, p.get("skip", []))
		var chit := _character_segment_hit(from, to, p.get("skip", []), p.get("skip_bodies", []))
		hit_owner = saved_owner
		if not chit.is_empty():
			if hitd.is_empty() or from.distance_to(chit["position"]) + 0.0005 < from.distance_to(hitd["position"]):
				hitd = chit
		if hitd.is_empty():
			p["pos"] = to
			p["vel"] = vel2
			remain -= step_t
			continue
		var hp: Vector3 = hitd["position"]
		var hn: Vector3 = hitd["normal"]
		var col = hitd["collider"]
		p["pos"] = hp
		p["vel"] = vel2
		var body := _body_of(col)
		if body:
			return _on_body(p, body, hp, hn, dir, mid_s, col)
		# 世界
		last_hit = hitd
		hit.emit(hp, hn, col, str(p["id"]))
		_spawn_decal(hp, hn, true)
		_end(p, true, hp, dir)
		return false
	p["age"] = float(p["age"]) + dt
	_place(p)
	return true


func _on_body(p: Dictionary, body: Node, hp: Vector3, hn: Vector3, dir: Vector3, speed: float, col: Object = null) -> bool:
	var par: Dictionary = p["par"]
	var organs: Node = body.get_organs() if body.has_method("get_organs") else null
	var qinfo := {}
	if organs and organs.has_method("ballistic_query"):
		qinfo = organs.call("ballistic_query", hp - dir * 0.05, dir, par)
	qinfo["body"] = body
	qinfo["organs"] = organs
	qinfo["weapon_id"] = p["id"]
	qinfo["par"] = par
	qinfo["entry"] = _as_vec3(qinfo.get("entry"), hp)
	qinfo["normal"] = _as_vec3(qinfo.get("normal"), hn)
	if qinfo.get("exit") != null and not (qinfo.get("exit") is Vector3):
		qinfo["exit"] = null
	qinfo["speed"] = speed
	qinfo["dir"] = dir
	qinfo["collider"] = col
	qinfo["origin"] = _as_vec3(p.get("origin"), hp)
	last_body = qinfo
	last_organ = qinfo
	p["hit_body"] = true
	p["cinfo"] = qinfo
	qinfo["projectile"] = p
	body_hit.emit(qinfo)
	var organ_hit := bool(qinfo.get("gut", false)) or bool(qinfo.get("uterus", false))
	var corpse := body.has_method("is_dead") and bool(body.call("is_dead"))
	if organ_hit:
		organ_path.emit(qinfo)
	elif corpse and (bool(qinfo.get("hit", false)) or _is_torso_collider(col)):
		# 尸体也可触发特写：命中腹部椭球或躯干骨、弹道能穿过身体。
		qinfo["corpse_path"] = true
		if not (qinfo.get("exit") is Vector3):
			qinfo["exit"] = _body_exit(body, hp, dir, qinfo)
		organ_path.emit(qinfo)
	# 特写：腹部受击特效等到可见弹头网格真正碰到人体再播，不要在逻辑命中/开镜时就出现。
	if p.get("cinematic", false):
		p["pending_impact"] = {"body": body, "hp": hp, "dir": dir, "par": par, "qinfo": qinfo, "col": col, "organs": organs}
		p["ballistics"] = self
		p["impact_applied"] = false
		_place(p)
		return true
	_commit_impact(p, body, hp, dir, col, par, qinfo, organs)
	var exit_p := _body_exit(body, hp, dir, qinfo)
	# 同一具身体不再二次拦截（角色胶囊往往比腹截面大，出口后还会再撞上）
	var skip: Array = []
	var prev_skip = p.get("skip")
	if prev_skip is Array:
		skip = (prev_skip as Array).duplicate()
	if body is CollisionObject3D:
		skip.append((body as CollisionObject3D).get_rid())
	p["skip"] = skip
	var skip_bodies: Array = []
	var prev_bodies = p.get("skip_bodies")
	if prev_bodies is Array:
		skip_bodies = (prev_bodies as Array).duplicate()
	skip_bodies.append(body)
	p["skip_bodies"] = skip_bodies
	var residual := clampf(0.32 + float(par.get("overpen", 0.3)) * 0.45, 0.18, 0.85)
	if qinfo.get("thick") != null:
		residual *= clampf(1.0 - float(qinfo["thick"]) * 0.7, 0.18, 1.0)
	var v2 := speed * residual
	if v2 < 18.0:
		# 动能耗尽：在出口外侧消失，不留弹头在皮肤上
		_end(p, false)
		return false
	p["pos"] = exit_p
	p["vel"] = dir * v2
	_spawn_decal(exit_p - dir * 0.01, -hn, false)
	_place(p)
	return true


func _body_exit(body: Node, entry: Vector3, dir: Vector3, qinfo: Dictionary) -> Vector3:
	var ex: Variant = qinfo.get("exit")
	var best: Vector3 = entry + dir * 0.25
	if ex is Vector3:
		best = ex
	# 再沿弹道穿过该身体的碰撞体，确保弹头离开胶囊而不是停在表皮
	var p := entry + dir * 0.008
	var last := best
	for _i in 20:
		var hit := _ray(p, p + dir * 1.4)
		if hit.is_empty():
			break
		var b := _body_of(hit.get("collider"))
		if b != body:
			break
		last = hit["position"]
		p = last + dir * 0.012
	return last + dir * 0.02


func _is_torso_collider(col: Object) -> bool:
	if col is PhysicalBone3D:
		var n := str((col as PhysicalBone3D).bone_name)
		return n.begins_with("C_Spine") or n.begins_with("C_Hip") or n.begins_with("C_Neck")
	return false


func _body_of(n: Object) -> Node:
	var x := n as Node
	while x:
		if x.is_in_group("wound_body"):
			return x
		if x.has_method("get_organs") and x != self:
			return x
		x = x.get_parent()
	return null


func _character_segment_hit(from: Vector3, to: Vector3, extra: Array = [], skip_bodies: Array = []) -> Dictionary:
	# 物理胶囊以外：腹壁椭球 + 皮肤网格包围盒，保证观察点击打在可视身体上也能命中。
	var tree := get_tree()
	if tree == null or not from.is_finite() or not to.is_finite():
		return {}
	var delta := to - from
	var seglen := delta.length()
	if seglen < 1e-5:
		return {}
	var dir := delta / seglen
	var best: Dictionary = {}
	var best_t := seglen
	for n in tree.get_nodes_in_group("wound_body"):
		if n == null or not is_instance_valid(n) or n in skip_bodies:
			continue
		if n is CollisionObject3D:
			var rid: RID = (n as CollisionObject3D).get_rid()
			if (not hit_owner and rid in exclude) or rid in extra:
				continue
		# 分身的 BodyHit 圆柱也被排除列表盖住时跳过（观察模式 hit_owner 时仍可打到本体）
		var blocked := false
		if (not hit_owner) and n.get("body_hit") is CollisionObject3D:
			var br: RID = (n.get("body_hit") as CollisionObject3D).get_rid()
			if br in exclude or br in extra:
				blocked = true
		# 即使圆柱在排除里，观察模式仍要用网格/腹壁（hit_owner 时 exclude 已空）
		var organs: Node = n.call("get_organs") if n.has_method("get_organs") else null
		if organs and organs.has_method("ray_hit_belly"):
			var hp = organs.call("ray_hit_belly", from, dir)
			if hp is Vector3 and (hp as Vector3).is_finite():
				var t: float = ((hp as Vector3) - from).dot(dir)
				if t > 0.002 and t <= best_t:
					var nrm := -dir
					if organs.has_method("project_skin"):
						var skin = organs.call("project_skin", hp)
						if skin is Vector3:
							var nn: Vector3 = (skin - (n.global_position if n is Node3D else hp))
							# 用入射方向的反方向即可
							nrm = -dir
					best_t = t
					best = {"position": from + dir * t, "normal": nrm, "collider": n}
		if blocked:
			if not best.is_empty() and best.get("collider") == n:
				pass
		# 皮肤网格 AABB（可见身体，不含头发/眼睛/武器/独立脏器展示）
		if n is Node3D:
			for mi in n.find_children("*", "MeshInstance3D", true, false):
				var mesh: MeshInstance3D = mi
				if mesh == null or mesh.mesh == null or not mesh.visible:
					continue
				var low := mesh.name.to_lower()
				if "hair" in low or "eye" in low or "weapon" in low or "gun" in low:
					continue
				if "intestine" in low or "uterus" in low or "organ" in low or "colon" in low:
					continue
				var xf := mesh.global_transform
				var aabb: AABB = mesh.get_aabb().grow(0.02)
				var inv := xf.affine_inverse()
				var ro: Vector3 = inv * from
				var rd: Vector3 = (inv.basis * dir)
				if rd.length_squared() < 1e-12:
					continue
				rd = rd.normalized()
				var ht := _aabb_ray_t(aabb, ro, rd, seglen)
				if ht < 0.0:
					continue
				var world_p: Vector3 = xf * (ro + rd * ht)
				var t2 := (world_p - from).dot(dir)
				if t2 > 0.002 and t2 <= best_t:
					best_t = t2
					var nrm2 := (xf.basis * aabb.get_center() - world_p)
					# 更稳：用射线反方向作法线
					best = {"position": from + dir * t2, "normal": -dir, "collider": n}
	return best


func _aabb_ray_t(aabb: AABB, ro: Vector3, rd: Vector3, max_t: float) -> float:
	var tmin := 0.0
	var tmax := max_t
	for i in 3:
		var o := ro[i]
		var d := rd[i]
		var mn := aabb.position[i]
		var mx := aabb.end[i]
		if absf(d) < 1e-8:
			if o < mn or o > mx:
				return -1.0
			continue
		var t1 := (mn - o) / d
		var t2 := (mx - o) / d
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmax < tmin:
			return -1.0
	return tmin if tmin <= max_t and tmin >= 0.0 else -1.0


func _ray(from: Vector3, to: Vector3, extra: Array = []) -> Dictionary:
	var w3 := _world()
	if w3 == null or not from.is_finite() or not to.is_finite() or from.distance_squared_to(to) < 1e-12:
		return {}
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var ex: Array[RID] = []
	if not hit_owner:
		ex.assign(exclude)
	for r in extra:
		if r is RID:
			ex.append(r)
	q.exclude = ex
	q.collide_with_areas = false
	q.collision_mask = 1 | 2
	return w3.direct_space_state.intersect_ray(q)


func _mesh_far_enough(pos: Vector3) -> bool:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam == null:
		return true
	return cam.global_position.distance_to(pos) >= MESH_CAM_DIST


func _place(p: Dictionary) -> void:
	var n: MeshInstance3D = p.get("node")
	if n == null or not is_instance_valid(n):
		return
	var vel: Vector3 = p["vel"]
	var d := vel.normalized() if vel.length_squared() > 1e-6 else (p["dir"] as Vector3)
	n.global_position = p["pos"]
	look_along(n, d)
	n.visible = _mesh_far_enough(p["pos"])
	var tr: MeshInstance3D = p.get("tracer")
	if tr and is_instance_valid(tr):
		var len := clampf(vel.length() * 0.0025, 0.04, 0.55)
		tr.visible = true
		tr.global_position = p["pos"] - d * len * 0.5
		look_along(tr, d)
		tr.scale = Vector3(len, 1, 1)


func _as_vec3(v, fallback: Vector3) -> Vector3:
	if v is Vector3 and (v as Vector3).is_finite():
		return v
	return fallback


func safe_basis_looking_at(dir: Vector3, up: Vector3 = Vector3.UP) -> Basis:
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


func _commit_impact(p: Dictionary, body: Node, hp: Vector3, dir: Vector3, col: Object, par: Dictionary, qinfo: Dictionary, organs: Node) -> void:
	if p.get("impact_applied", false):
		return
	p["impact_applied"] = true
	p["pending_impact"] = {}
	if is_instance_valid(organs) and organs.has_method("apply_ballistic_hit"):
		organs.call("apply_ballistic_hit", hp - dir * 0.05, dir, par, qinfo)
	hit.emit(hp, _as_vec3(qinfo.get("normal"), -dir if dir.length_squared() > 1e-8 else Vector3.UP), body, str(p.get("id", "")))
	_apply_combat_hit(p, body, hp, dir, col, qinfo)


func apply_deferred_impact(p: Dictionary) -> void:
	if p == null or p.is_empty() or p.get("impact_applied", false):
		return
	var rec = p.get("pending_impact")
	if not (rec is Dictionary) or rec.is_empty():
		return
	var body = rec.get("body")
	var qinfo: Dictionary = rec.get("qinfo", {})
	if not (qinfo is Dictionary):
		qinfo = {}
	var hp: Vector3 = _as_vec3(rec.get("hp"), _as_vec3(qinfo.get("entry"), Vector3.ZERO))
	var dir: Vector3 = _as_vec3(rec.get("dir"), _as_vec3(qinfo.get("dir"), Vector3.FORWARD))
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	else:
		dir = dir.normalized()
	var par: Dictionary = rec.get("par", {})
	if not (par is Dictionary):
		par = {}
	var col = rec.get("col")
	var organs = rec.get("organs")
	if organs == null and body != null and is_instance_valid(body) and body.has_method("get_organs"):
		organs = body.call("get_organs")
	_commit_impact(p, body, hp, dir, col, par, qinfo, organs)


func look_along(n: Node3D, d: Vector3) -> void:
	# 弹头网格沿 +X 向前
	if n == null or not d.is_finite() or d.length_squared() < 1e-10:
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


func _end(p: Dictionary, leave_spent: bool, at: Vector3 = Vector3.ZERO, dir: Vector3 = Vector3.FORWARD) -> void:
	_live.erase(p)
	# 不再把弹头/霰弹黑球留在命中点：那会在空中悬浮成小黑点。火花仍由 _spawn_decal 负责。
	# leave_spent 参数保留，以免旧调用点报错，但视觉网格一律回收。
	if leave_spent:
		pass
	if at.is_finite():
		p["end_at"] = at
	if dir.is_finite() and dir.length_squared() > 1e-10:
		p["end_dir"] = dir
	_park(p)


func spent_visible_count() -> int:
	var n := 0
	for s in _spent:
		var mi = s.get("n") if s is Dictionary else null
		if mi is MeshInstance3D and is_instance_valid(mi) and (mi as MeshInstance3D).visible:
			n += 1
	return n


func lingering_visible_shot_meshes() -> Array:
	# 测试：飞行结束后仍可见的弹头/弹丸网格（不含弹痕贴花、火花）。
	var out: Array = []
	for s in _spent:
		var mi = s.get("n") if s is Dictionary else null
		if mi is MeshInstance3D and is_instance_valid(mi) and (mi as MeshInstance3D).visible:
			out.append(mi)
	for p in _live:
		if not (p is Dictionary):
			continue
		var rec: Dictionary = p
		if float(rec.get("age", 0.0)) < 1.6:
			continue
		var mi2: MeshInstance3D = rec.get("node")
		if mi2 and is_instance_valid(mi2) and mi2.visible:
			out.append(mi2)
	return out


func _park(p: Dictionary) -> void:
	var n: MeshInstance3D = p.get("node")
	if n and is_instance_valid(n):
		n.visible = false
		n.position = Vector3(0, -50, 0)
		_pool.append(n)
	var tr: MeshInstance3D = p.get("tracer")
	if tr and is_instance_valid(tr):
		tr.visible = false
		tr.queue_free()
	p["alive"] = false
	p["node"] = null
	p["tracer"] = null


func _pellet_mesh() -> Mesh:
	if _meshes.has("pellet_sphere"):
		return _meshes["pellet_sphere"]
	var sm := SphereMesh.new()
	sm.radius = 0.005
	sm.height = 0.01
	sm.radial_segments = 10
	sm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.04, 0.04)
	mat.roughness = 0.85
	mat.metallic = 0.15
	sm.material = mat
	_meshes["pellet_sphere"] = sm
	return sm


func is_pellet_visual(n: MeshInstance3D) -> bool:
	if n == null or n.mesh == null:
		return false
	var m := n.mesh
	return m is SphereMesh and is_instance_valid(m.material) and (m.material as StandardMaterial3D).albedo_color.r < 0.15


func _make_visual(kind: String, scl: float) -> MeshInstance3D:
	var pellet := kind == "pellet_sphere" or kind == "BuckShot_Projectile" or kind.to_lower().begins_with("buck")
	var mesh: Mesh = _pellet_mesh() if pellet else _meshes.get(kind)
	var mi: MeshInstance3D = null
	if not _pool.is_empty():
		mi = _pool.pop_back()
	else:
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_host_add(mi)
	if mesh:
		mi.mesh = mesh
	mi.material_override = mesh.material if pellet and mesh else null
	mi.scale = Vector3.ONE * (1.0 if pellet else scl)
	mi.visible = true
	return mi


func _make_tracer() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.003, 0.003)
	box.material = _tracer_mat
	mi.mesh = box
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_host_add(mi)
	return mi


func _host_add(n: Node) -> void:
	var h: Node = _host if _host else (get_tree().current_scene if get_tree() else self)
	if h == null:
		h = self
	h.add_child(n)


func _world() -> World3D:
	var vp := get_viewport()
	return vp.world_3d if vp else null


func _spawn_decal(p: Vector3, n: Vector3, spark: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _decal_mesh
	mi.material_override = _decal_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_host_add(mi)
	if not p.is_finite() or not n.is_finite() or n.length_squared() < 1e-10:
		n = Vector3.UP
	var face := -n if n.length_squared() > 1e-10 else Vector3.FORWARD
	mi.global_transform = Transform3D(safe_basis_looking_at(face, Vector3.UP), p + n.normalized() * 0.003)
	_decals.append(mi)
	while _decals.size() > MAX_DECALS:
		var o: Node = _decals.pop_front()
		if is_instance_valid(o):
			o.queue_free()
	if spark:
		var s := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.012
		sph.height = 0.024
		sph.radial_segments = 6
		sph.rings = 3
		s.mesh = sph
		s.material_override = _spark_mat
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_host_add(s)
		s.global_position = p + n * 0.01
		_spent.append({"n": s, "t": 0.08})


func _step_spent(dt: float) -> void:
	var keep: Array = []
	for s in _spent:
		s["t"] = float(s["t"]) - dt
		var n: Node3D = s["n"]
		if not is_instance_valid(n) or float(s["t"]) <= 0.0:
			if is_instance_valid(n):
				n.queue_free()
			continue
		if n is MeshInstance3D and float(s["t"]) < 0.4:
			(n as MeshInstance3D).transparency = 1.0 - float(s["t"]) / 0.4
		keep.append(s)
	_spent = keep


func clear_decals() -> void:
	for d in _decals:
		if is_instance_valid(d):
			d.queue_free()
	_decals.clear()


## 沿当前速度积分 dt 秒后的位置（测试下坠用，不改变状态）
func predict_drop(origin: Vector3, vel: Vector3, drag: float, sec: float, step: float = 0.002) -> Vector3:
	var p := origin
	var v := vel
	var t := 0.0
	while t < sec:
		var dt := minf(step, sec - t)
		var sp := v.length()
		v = (v + G * dt) * exp(-drag * sp * dt)
		p += v * dt
		t += dt
	return p


func _apply_combat_hit(p: Dictionary, body: Node, hp: Vector3, dir: Vector3, col: Object, qinfo: Dictionary) -> void:
	if body == null:
		return
	var par: Dictionary = p.get("par", {})
	var origin: Vector3 = p.get("origin", hp)
	var dist := origin.distance_to(hp)
	var zone := CombatDamage.zone_of(body, hp, col)
	var dmg := float(par.get("damage", CombatDamage.base_damage(str(p.get("id", "")), null)))
	var cat := str(par.get("category", CombatDamage.category_of(str(p.get("id", "")), null)))
	var amount := dmg * CombatDamage.zone_mult(zone) * CombatDamage.falloff_mult(cat, dist)
	qinfo["zone"] = zone
	qinfo["distance"] = dist
	qinfo["damage"] = amount
	var was_dead := body.has_method("is_dead") and bool(body.call("is_dead"))
	if body.has_method("apply_damage") and not was_dead:
		body.call("apply_damage", amount, qinfo)
	var now_dead := body.has_method("is_dead") and bool(body.call("is_dead"))
	if not (was_dead or now_dead):
		if body.has_method("apply_hit_reaction"):
			body.call("apply_hit_reaction", qinfo)
		return
	if not body.has_method("get_ragdoll"):
		return
	var rag: Node = body.call("get_ragdoll")
	if rag == null:
		return
	var imp: Vector3 = rag.call("impulse_from_ballistics", par, dir)
	# 击杀冲量由 died 回调里 start() 施加；已死亡的后续命中在这里推尸体。
	if was_dead:
		rag.call("apply_hit_impulse", imp, hp, col)
