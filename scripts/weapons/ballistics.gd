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
	var d := dir.normalized()
	var pos := origin + d * 0.04
	var pr := _make_visual(str(par["proj"]), float(par["scale"]))
	pr.global_position = pos
	_look_along(pr, d)
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
	}
	_live.append(rec)
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
		var to := from + travel
		var hitd := _ray(from, to, p.get("skip", []))
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
	qinfo["entry"] = qinfo.get("entry", hp)
	qinfo["normal"] = hn
	qinfo["speed"] = speed
	qinfo["dir"] = dir
	qinfo["collider"] = col
	qinfo["origin"] = p.get("origin", hp)
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
		if qinfo.get("exit") == null:
			qinfo["exit"] = _body_exit(body, hp, dir, qinfo)
		organ_path.emit(qinfo)
	if organs and organs.has_method("apply_ballistic_hit"):
		organs.call("apply_ballistic_hit", hp - dir * 0.05, dir, par, qinfo)
	hit.emit(hp, hn, body, str(p["id"]))
	_apply_combat_hit(p, body, hp, dir, col, qinfo)
	# 肉体必须贯穿：先结算伤口，弹头沿原方向继续，绝不把网格停在入弹皮肤上。
	# 特写期间由 bullet_cam 摆放弹头，这里只记下出口，不冻结在入射点。
	if p.get("cinematic", false):
		if qinfo.get("exit") != null:
			# 让特写路径能走到出口以外
			pass
		_place(p)
		return true
	var exit_p := _body_exit(body, hp, dir, qinfo)
	# 同一具身体不再二次拦截（角色胶囊往往比腹截面大，出口后还会再撞上）
	var skip: Array = p.get("skip", [])
	if body is CollisionObject3D:
		skip.append((body as CollisionObject3D).get_rid())
	p["skip"] = skip
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


func _ray(from: Vector3, to: Vector3, extra: Array = []) -> Dictionary:
	var w3 := _world()
	if w3 == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var ex: Array[RID] = []
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
	_look_along(n, d)
	n.visible = _mesh_far_enough(p["pos"])
	var tr: MeshInstance3D = p.get("tracer")
	if tr and is_instance_valid(tr):
		var len := clampf(vel.length() * 0.0025, 0.04, 0.55)
		tr.visible = true
		tr.global_position = p["pos"] - d * len * 0.5
		_look_along(tr, d)
		tr.scale = Vector3(len, 1, 1)


func _look_along(n: Node3D, d: Vector3) -> void:
	# 弹头网格沿 +X 向前
	if d.length_squared() < 1e-10:
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
	var n: MeshInstance3D = p.get("node")
	if leave_spent and n and is_instance_valid(n):
		n.global_position = at - dir * 0.004
		_look_along(n, dir)
		n.visible = true
		_spent.append({"n": n, "t": 2.0})
		p["node"] = null
	_park(p)


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
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	mi.global_transform = Transform3D(Basis.looking_at(-n, up), p + n * 0.003)
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
