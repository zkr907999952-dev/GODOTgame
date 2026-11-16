extends Node
class_name CorpseDrag
## 第一人称尸体拖拽：收起武器且准星指向尸体时，在原开火键位置显示切换按钮；E 同样切换。
## 选择范围大于手臂长；确认后手伸向抓取点，点和手拉到重合后才进入拖拽。
## 一旦拖拽成功开始，不再因走出选择范围或持握距离而自动放开；只能手动切换放下。手臂仍把持握点限制在够得到的位置。
## 抓取点可以是准星下的皮肤表面，物理拉力作用在最近的布娃娃骨骼上。

const AIM_DIST := 4.8
const PICK_EXTRA := 2.2
const DROP_SLACK := 0.18
const REACH_SNAP := 0.12
const REACH_MAX := 0.75
const SKIN_RADIUS := 0.16

var player: Node
var skeleton: Skeleton3D
var dragging: bool = false
var reaching: bool = false
var _reach_t: float = 0.0
var aimed_body: Node = null
var aimed_bone: String = ""
var aimed_point: Vector3 = Vector3.ZERO
var grabbed_body: Node = null
var grabbed_bone: String = ""
var grabbed_pb: PhysicalBone3D = null
var _anchor: AnimatableBody3D
var _joint: PinJoint3D
var _local_grab: Vector3 = Vector3.ZERO
var _hold_local: Vector3 = Vector3.ZERO
var _has_hold: bool = false
var _exceptions: Array = []
var last_toggle_ok: bool = false
var last_drop_reason: String = ""
var toggle_count: int = 0


func setup(p: Node, skel: Skeleton3D) -> void:
	player = p
	skeleton = skel
	_ensure_anchor()


func arm_length() -> float:
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws and ws.has_method("left_arm_reach"):
			var r := float(ws.call("left_arm_reach"))
			if r > 0.2:
				return r
	if skeleton:
		var sh := skeleton.find_bone("L_UpperArm_a")
		var ha := skeleton.find_bone("L_Hand_a")
		if sh >= 0 and ha >= 0:
			var a := skeleton.get_bone_global_rest(sh).origin
			var b := skeleton.get_bone_global_rest(ha).origin
			var d := a.distance_to(b)
			if d > 0.2:
				return d
	return 0.62


func pick_range() -> float:
	# 选择可以比手臂长一截，方便在稍远处点到尸体。
	return arm_length() + _bend_extra() + PICK_EXTRA


func shoulder_world() -> Vector3:
	if skeleton:
		var i := skeleton.find_bone("L_UpperArm_a")
		if i < 0:
			i = skeleton.find_bone("L_Shoulder_a")
		if i >= 0:
			return (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin
	if player is Node3D:
		return (player as Node3D).global_position + Vector3(-0.12, 1.25, 0.05)
	return Vector3.ZERO


func left_hand_world() -> Vector3:
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws and ws.has_method("left_hand_world"):
			var p: Vector3 = ws.call("left_hand_world")
			if p != Vector3.ZERO:
				return p
	if skeleton:
		var i := skeleton.find_bone("L_Hand_a")
		if i >= 0:
			return (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin
	if player is Node3D:
		return (player as Node3D).global_position + Vector3(0.15, 1.15, 0.2)
	return Vector3.ZERO


func _view_xform() -> Transform3D:
	if player and player.has_method("fp_view_transform"):
		return player.call("fp_view_transform")
	if player is Node3D:
		return (player as Node3D).global_transform
	return Transform3D.IDENTITY


func hold_world() -> Vector3:
	# 抓取时记在第一人称视点空间里的点；转视角时跟着视线走，手把尸体拉过去。
	var p := aimed_point
	if _has_hold:
		p = _view_xform() * _hold_local
	var sh := shoulder_world()
	var reach := arm_length()
	if sh != Vector3.ZERO and sh.distance_to(p) > reach:
		p = sh + (p - sh).normalized() * reach
	return p


func capture_hold(pt: Vector3) -> void:
	_hold_local = _view_xform().affine_inverse() * pt
	_has_hold = true


func is_dragging() -> bool:
	return dragging and is_instance_valid(grabbed_pb)


func is_holstered() -> bool:
	if player == null:
		return true
	# 用「枪是否在手上」，不要用 weapon_armed()（它还要求第一人称）。
	if player.has_method("weapon_drawn"):
		return not bool(player.call("weapon_drawn"))
	if player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws and ws.has_method("is_armed"):
			return not bool(ws.call("is_armed"))
	if player.has_method("weapon_armed"):
		return not bool(player.call("weapon_armed"))
	return true


func can_start() -> bool:
	if dragging or not is_holstered():
		return false
	return is_instance_valid(aimed_body) and aimed_bone != "" and _in_pick_range(aimed_point)


func _bend_extra() -> float:
	# 高蹲时肩部仍约 0.9m，48cm 手臂够不到地面。蹲/趴时允许折腰探身。
	if player and player.has_method("get_stance"):
		var st := str(player.call("get_stance"))
		if st == "crouch":
			return 0.65
		if st == "prone":
			return 0.22
	return 0.0


func _in_pick_range(pt: Vector3, slack: float = 0.0) -> bool:
	var origin := shoulder_world()
	if origin == Vector3.ZERO:
		return false
	return origin.distance_to(pt) <= pick_range() + slack


func _walked_too_far(pt: Vector3) -> bool:
	# 拖拽中只看水平走离。尸体下坠或转视角拉扯不应当作「走太远」。
	var origin := shoulder_world()
	if origin == Vector3.ZERO:
		return true
	var horiz := Vector2(origin.x - pt.x, origin.z - pt.z).length()
	return horiz > arm_length() + DROP_SLACK


func toggle() -> bool:
	last_toggle_ok = false
	if dragging:
		drop("toggle")
		last_toggle_ok = true
		toggle_count += 1
		return true
	if not is_holstered():
		last_drop_reason = "armed"
		return false
	if not can_start():
		last_drop_reason = "out_of_range" if is_instance_valid(aimed_body) else "no_target"
		return false
	return _begin()


func debug_aim(body: Node, bone_name: String, hit: Vector3 = Vector3.ZERO) -> void:
	aimed_body = body
	aimed_bone = bone_name
	if hit != Vector3.ZERO:
		aimed_point = hit
	elif body and body.has_method("get_ragdoll"):
		var rag: Node = body.call("get_ragdoll")
		var pb: PhysicalBone3D = rag.get("bones").get(bone_name) if rag else null
		aimed_point = pb.global_position if pb else (body as Node3D).global_position + Vector3.UP
	else:
		aimed_point = (body as Node3D).global_position if body is Node3D else Vector3.ZERO


func drop(reason: String = "toggle") -> void:
	last_drop_reason = reason
	_clear_exceptions()
	_clear_joint()
	dragging = false
	reaching = false
	grabbed_body = null
	grabbed_bone = ""
	grabbed_pb = null
	_local_grab = Vector3.ZERO
	_hold_local = Vector3.ZERO
	_has_hold = false


func current_grab_point() -> Vector3:
	if not is_instance_valid(grabbed_pb):
		return aimed_point
	return grabbed_pb.to_global(_local_grab)


func update_aim(from: Vector3, dir: Vector3, exclude: Array[RID] = []) -> void:
	if dragging:
		return
	aimed_body = null
	aimed_bone = ""
	aimed_point = Vector3.ZERO
	if dir.length_squared() < 1e-8:
		return
	dir = dir.normalized()
	var hit := _pick_corpse(from, dir, exclude)
	if hit.is_empty():
		return
	aimed_body = hit["body"]
	aimed_bone = str(hit["bone"])
	aimed_point = hit["point"]


func physics_tick(delta: float) -> void:
	if not dragging:
		return
	if not is_instance_valid(grabbed_pb) or not is_instance_valid(grabbed_body):
		drop("invalid")
		return
	if grabbed_body.has_method("is_dead") and not bool(grabbed_body.call("is_dead")):
		drop("not_dead")
		return
	if not is_holstered():
		drop("armed")
		return
	var pt := current_grab_point()
	# 范围只用于开始选择。一旦抓住，走出原选择/持握距离也不自动放开。
	if reaching:
		_tick_reach(delta, pt)
		return
	var hold := hold_world()
	_sync_anchor(hold)
	var pr := pull_params()
	_pull_toward(hold, pt, float(pr["k"]), float(pr["damp"]), float(pr["max_j"]))


func apply_left_hand() -> void:
	if not is_dragging():
		return
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws and ws.has_method("apply_left_hand_grab"):
			var target := left_hand_world()
			if reaching:
				target = _reach_hand_target()
			else:
				target = hold_world()
			ws.call("apply_left_hand_grab", target)


func _reach_goal() -> Vector3:
	# 手能伸到的最远点：超过臂长时停在臂长处，尸体要被拉到这里才算抓住。
	var sh := shoulder_world()
	var hand := left_hand_world()
	var pt := current_grab_point()
	var origin := sh if sh != Vector3.ZERO else hand
	var reach := arm_length()
	if origin != Vector3.ZERO and origin.distance_to(pt) > reach:
		return origin + (pt - origin).normalized() * reach
	return pt


func _reach_hand_target() -> Vector3:
	var hand := left_hand_world()
	var want := _reach_goal()
	# 手从当前位置伸向目标，逐步靠拢。
	if hand != Vector3.ZERO:
		return hand.lerp(want, 0.55)
	return want


func _tick_reach(delta: float, pt: Vector3) -> void:
	_reach_t += delta
	var goal := _reach_goal()
	_sync_anchor(goal)
	# 选择距离可以比对长，但抓住前先把点和手拉到重合。拉得更紧，避免一直停在伸出阶段。
	var pr := pull_params()
	_pull_toward(goal, pt, float(pr["k_reach"]), float(pr["damp_reach"]), float(pr["max_j_reach"]))
	var d := current_grab_point().distance_to(goal)
	if d <= REACH_SNAP or _reach_t >= REACH_MAX:
		reaching = false
		capture_hold(goal if d <= 0.35 else current_grab_point().lerp(goal, 0.7))
		_sync_anchor(hold_world())


func pull_force_scale() -> float:
	if player and player.get_tree():
		var st: Node = player.get_tree().root.get_node_or_null("Main/GameSettings")
		if st == null:
			st = player.get_tree().root.find_child("GameSettings", true, false)
		if st and st.get("pull_force") != null:
			return clampf(float(st.get("pull_force")), 0.35, 2.5)
	return 1.0


## 默认拉力已比 0.2.12 明显加大；再乘设置里的「拉扯力度」。
func pull_params() -> Dictionary:
	var s := pull_force_scale()
	return {
		"k": 95.0 * s,
		"damp": 16.0,
		"max_j": 11.0 * s,
		"k_reach": 140.0 * s,
		"damp_reach": 18.0,
		"max_j_reach": 16.0 * s,
		"scale": s,
	}


func _pull_toward(hold: Vector3, pt: Vector3, k: float, damp: float, max_j: float) -> void:
	# Jolt 下 PinJoint3D 连 PhysicalBone3D 会把骨头弹飞，改用有上限的弹簧把抓取点拉向持握点。
	var pull := hold - pt
	var v: Vector3 = grabbed_pb.linear_velocity
	var impulse := pull * k - v * damp
	impulse += Vector3.UP * 7.0
	if impulse.length() > max_j:
		impulse = impulse.normalized() * max_j
	if impulse.length_squared() > 1e-8:
		# 作用在抓取点（皮肤局部坐标），不是只推骨骼原点。
		grabbed_pb.apply_impulse(impulse, grabbed_pb.to_global(_local_grab) - grabbed_pb.global_position)


func _begin() -> bool:
	var body := aimed_body
	var bname := aimed_bone
	if body == null or bname == "":
		return false
	var rag: Node = body.call("get_ragdoll") if body.has_method("get_ragdoll") else null
	if rag == null:
		return false
	var pb: PhysicalBone3D = rag.get("bones").get(bname)
	if pb == null or not is_instance_valid(pb):
		return false
	if not _in_pick_range(aimed_point):
		last_drop_reason = "out_of_range"
		return false
	_ensure_anchor()
	grabbed_body = body
	grabbed_bone = bname
	grabbed_pb = pb
	_local_grab = pb.to_local(aimed_point)
	_has_hold = false
	dragging = true
	reaching = true
	_reach_t = 0.0
	last_drop_reason = ""
	last_toggle_ok = true
	toggle_count += 1
	_add_exceptions(rag)
	apply_left_hand()
	_sync_anchor(_reach_hand_target())
	# 不创建 PinJoint3D：Jolt + PhysicalBone3D 上约束会把尸体弹飞。
	return true


func _add_exceptions(rag: Node) -> void:
	_clear_exceptions()
	if player == null or not (player is CollisionObject3D) or rag == null:
		return
	var bones: Dictionary = rag.get("bones") if rag.get("bones") is Dictionary else {}
	for pb in bones.values():
		if pb is PhysicalBone3D and is_instance_valid(pb):
			(player as CollisionObject3D).add_collision_exception_with(pb)
			_exceptions.append(pb)


func _clear_exceptions() -> void:
	if player is CollisionObject3D:
		for pb in _exceptions:
			if is_instance_valid(pb):
				(player as CollisionObject3D).remove_collision_exception_with(pb)
	_exceptions.clear()


func _pick_corpse(from: Vector3, dir: Vector3, exclude: Array[RID]) -> Dictionary:
	var space := _space()
	if space == null:
		return {}
	var best: Dictionary = {}
	var best_s := AIM_DIST + 0.01
	# 1) 细射线：命中布娃娃骨骼碰撞（靠近骨骼的皮肤点）。
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * AIM_DIST, 1 | 2)
	q.collide_with_areas = false
	q.exclude = exclude
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		var rec := _from_collider(hit.get("collider"), hit.get("position", Vector3.ZERO), from, dir)
		if not rec.is_empty():
			best = rec
			best_s = float(rec.get("s", best_s))
	# 2) 粗球体扫描：抓取范围扩大到皮肤表面，不只是骨骼原点。
	var sph := SphereShape3D.new()
	sph.radius = SKIN_RADIUS
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = sph
	sq.collision_mask = 2
	sq.collide_with_areas = false
	sq.exclude = exclude
	var steps := 10
	for i in steps:
		var t := (float(i) + 0.5) / float(steps) * AIM_DIST
		if t >= best_s:
			break
		sq.transform = Transform3D(Basis.IDENTITY, from + dir * t)
		var hits := space.intersect_shape(sq, 8)
		for h in hits:
			var rec2 := _from_collider(h.get("collider"), from + dir * t, from, dir)
			if rec2.is_empty():
				continue
			# 把抓取点收到「瞄准射线与骨骼膨胀皮肤」最近的位置。
			var pb: PhysicalBone3D = rec2.get("pb")
			if pb:
				var skin_pt := _skin_point_on_bone(pb, from, dir)
				if skin_pt != Vector3.ZERO:
					rec2["point"] = skin_pt
					rec2["s"] = from.distance_to(skin_pt)
			if float(rec2["s"]) < best_s:
				best = rec2
				best_s = float(rec2["s"])
	# 3) 再对可见皮肤网格做一次包围盒拾取，补上骨骼缝隙里的腹部/大腿。
	var mesh_hit := _mesh_skin_hit(from, dir, best_s)
	if not mesh_hit.is_empty() and float(mesh_hit.get("s", AIM_DIST)) < best_s:
		best = mesh_hit
	return best


func _from_collider(col: Object, point: Vector3, from: Vector3, dir: Vector3) -> Dictionary:
	var body := _dead_host(col)
	if body == null:
		return {}
	var rag: Node = body.call("get_ragdoll") if body.has_method("get_ragdoll") else null
	if rag == null or not bool(rag.call("is_active")):
		return {}
	var bname := ""
	var pb: PhysicalBone3D = null
	if col is PhysicalBone3D:
		bname = str((col as PhysicalBone3D).bone_name)
		pb = col
	if bname == "" or pb == null:
		pb = rag.call("_closest_bone", point)
		if pb:
			bname = str(pb.bone_name)
	if bname == "":
		bname = "C_Spine_c"
	var s := (point - from).dot(dir)
	return {"body": body, "bone": bname, "point": point, "s": s, "pb": pb}


func _skin_point_on_bone(pb: PhysicalBone3D, from: Vector3, dir: Vector3) -> Vector3:
	# 把瞄准射线投到骨骼碰撞的外壳上，作为「皮肤」抓取点。
	var c := pb.global_position
	var w := from - c
	var a := dir.dot(dir)
	var b := 2.0 * w.dot(dir)
	var rad := SKIN_RADIUS * 0.85
	var cst := w.dot(w) - rad * rad
	var disc := b * b - 4.0 * a * cst
	if disc < 0.0:
		# 射线没穿过膨胀球，取球面上最近点。
		var t := clampf(-w.dot(dir), 0.0, AIM_DIST)
		var p := from + dir * t
		if p.distance_to(c) < 1e-5:
			return c + dir * rad
		return c + (p - c).normalized() * rad
	var t0 := (-b - sqrt(disc)) / (2.0 * a)
	if t0 >= 0.0 and t0 <= AIM_DIST:
		return from + dir * t0
	var t1 := (-b + sqrt(disc)) / (2.0 * a)
	if t1 >= 0.0 and t1 <= AIM_DIST:
		return from + dir * t1
	return Vector3.ZERO


func _mesh_skin_hit(from: Vector3, dir: Vector3, max_s: float) -> Dictionary:
	var best: Dictionary = {}
	var best_s := max_s
	for n in get_tree().get_nodes_in_group("wound_body"):
		if n == player or not (n is Node3D):
			continue
		if not n.has_method("is_dead") or not bool(n.call("is_dead")):
			continue
		if not n.has_method("get_ragdoll"):
			continue
		var rag: Node = n.call("get_ragdoll")
		if rag == null or not bool(rag.call("is_active")):
			continue
		for mi in n.find_children("*", "MeshInstance3D", true, false):
			var mesh: MeshInstance3D = mi
			if mesh == null or mesh.mesh == null or not mesh.visible:
				continue
			var low := mesh.name.to_lower()
			if "hair" in low or "eye" in low or "weapon" in low or "gun" in low:
				continue
			var xf := mesh.global_transform
			var aabb: AABB = mesh.get_aabb()
			# 略放大，把贴在网格外的皮肤厚度算进去。
			aabb = aabb.grow(0.04)
			var inv := xf.affine_inverse()
			var ro: Vector3 = inv * from
			var rd: Vector3 = (inv.basis * dir).normalized()
			var hit_t := _aabb_ray(aabb, ro, rd)
			if hit_t < 0.0:
				continue
			var world_p: Vector3 = xf * (ro + rd * hit_t)
			var s := (world_p - from).dot(dir)
			if s < 0.02 or s >= best_s:
				continue
			var pb: PhysicalBone3D = rag.call("_closest_bone", world_p)
			var bname := str(pb.bone_name) if pb else "C_Spine_c"
			best = {"body": n, "bone": bname, "point": world_p, "s": s, "pb": pb}
			best_s = s
	return best


func _aabb_ray(aabb: AABB, ro: Vector3, rd: Vector3) -> float:
	var tmin := 0.0
	var tmax := AIM_DIST
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
	return tmin if tmin <= AIM_DIST else -1.0


func _ensure_anchor() -> void:
	if _anchor and is_instance_valid(_anchor):
		return
	_anchor = AnimatableBody3D.new()
	_anchor.name = "DragHandAnchor"
	_anchor.collision_layer = 0
	_anchor.collision_mask = 0
	_anchor.sync_to_physics = true
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.03
	cs.shape = sph
	# 形状要启用，否则 Jolt 里这个运动体可能进不了求解岛，关节等于没连上。
	# layer/mask 仍为 0，不会和世界或角色碰撞。
	cs.disabled = false
	_anchor.add_child(cs)
	add_child(_anchor)


func _sync_anchor(p: Vector3) -> void:
	if _anchor == null:
		return
	_anchor.global_position = p


func _make_joint(pb: PhysicalBone3D) -> void:
	_clear_joint()
	if _anchor == null or pb == null:
		return
	_joint = PinJoint3D.new()
	_joint.name = "CorpseDragJoint"
	add_child(_joint)
	_joint.global_position = hold_world() if _has_hold else pb.global_position
	_joint.node_a = _anchor.get_path()
	_joint.node_b = pb.get_path()


func _clear_joint() -> void:
	if _joint and is_instance_valid(_joint):
		_joint.queue_free()
	_joint = null


func _dead_host(col: Object) -> Node:
	var n: Node = col as Node
	while n:
		if n != player and n.has_method("is_dead") and n.has_method("get_ragdoll") and bool(n.call("is_dead")):
			return n
		n = n.get_parent()
	return null


func _space() -> PhysicsDirectSpaceState3D:
	if player is Node3D and (player as Node3D).get_world_3d():
		return (player as Node3D).get_world_3d().direct_space_state
	return null
