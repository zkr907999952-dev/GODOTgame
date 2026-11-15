extends Node
class_name CorpseDrag
## 第一人称尸体拖拽：准星指向已死亡布娃娃时显示切换按钮，E 键同样切换。
## 左手抓住准星选中的拖拽点，距离上限为手臂长；走出范围自动放下。

const AIM_DIST := 2.4
const DROP_SLACK := 0.12

var player: Node
var skeleton: Skeleton3D
var dragging: bool = false
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


func can_start() -> bool:
	return (not dragging) and is_instance_valid(aimed_body) and aimed_bone != "" and _in_reach(aimed_point)


func _bend_extra() -> float:
	# 高蹲时肩部仍约 0.9m，48cm 手臂够不到地面。蹲/趴时允许折腰探身。
	if player and player.has_method("get_stance"):
		var st := str(player.call("get_stance"))
		if st == "crouch":
			return 0.65
		if st == "prone":
			return 0.22
	return 0.0


func _in_reach(pt: Vector3, slack: float = 0.0) -> bool:
	# 开始拖拽：站立时肩到点不超过手臂长；蹲/趴另加折腰距离，才能捡起地上的尸体。
	var origin := shoulder_world()
	if origin == Vector3.ZERO:
		return false
	return origin.distance_to(pt) <= arm_length() + _bend_extra() + slack


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
	_clear_joint()
	dragging = false
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
	var space := _space()
	if space == null:
		return
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * AIM_DIST, 1 | 2)
	q.collide_with_areas = false
	q.exclude = exclude
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var col = hit.get("collider")
	var body := _dead_host(col)
	if body == null:
		return
	var rag: Node = body.call("get_ragdoll") if body.has_method("get_ragdoll") else null
	if rag == null or not bool(rag.call("is_active")):
		return
	var bname := ""
	var pb: PhysicalBone3D = null
	if col is PhysicalBone3D:
		bname = str((col as PhysicalBone3D).bone_name)
		pb = col
	if bname == "" or pb == null:
		pb = rag.call("_closest_bone", hit["position"])
		if pb:
			bname = str(pb.bone_name)
	if bname == "":
		bname = "C_Spine_c"
	aimed_body = body
	aimed_bone = bname
	aimed_point = hit["position"]


func physics_tick(delta: float) -> void:
	if not dragging:
		return
	if not is_instance_valid(grabbed_pb) or not is_instance_valid(grabbed_body):
		drop("invalid")
		return
	if grabbed_body.has_method("is_dead") and not bool(grabbed_body.call("is_dead")):
		drop("not_dead")
		return
	var pt := current_grab_point()
	if _walked_too_far(pt):
		drop("range")
		return
	var hold := hold_world()
	_sync_anchor(hold)
	# Jolt 下 PinJoint3D 连 PhysicalBone3D 会把骨头弹飞，改用有上限的弹簧把抓取点拉向左手持握点。
	var pull := hold - pt
	var v: Vector3 = grabbed_pb.linear_velocity
	var impulse := pull * 28.0 - v * 10.0
	# 重力补偿，避免一松手尸体就掉出持握点
	impulse += Vector3.UP * 6.0
	var max_j := 1.6
	if impulse.length() > max_j:
		impulse = impulse.normalized() * max_j
	if impulse.length_squared() > 1e-8:
		grabbed_pb.apply_central_impulse(impulse)


func apply_left_hand() -> void:
	if not is_dragging():
		return
	if player and player.has_method("get_weapons"):
		var ws: Node = player.call("get_weapons")
		if ws and ws.has_method("apply_left_hand_grab"):
			ws.call("apply_left_hand_grab", hold_world())


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
	if not _in_reach(aimed_point):
		last_drop_reason = "out_of_range"
		return false
	_ensure_anchor()
	grabbed_body = body
	grabbed_bone = bname
	grabbed_pb = pb
	_local_grab = pb.to_local(aimed_point)
	capture_hold(aimed_point)
	dragging = true
	last_drop_reason = ""
	last_toggle_ok = true
	toggle_count += 1
	apply_left_hand()
	_sync_anchor(hold_world())
	# 不创建 PinJoint3D：Jolt + PhysicalBone3D 上约束会把尸体弹飞。
	return true


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
