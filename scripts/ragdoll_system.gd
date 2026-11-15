extends Node
class_name RagdollSystem
## Godot 4 PhysicalBoneSimulator3D 布娃娃：运行时按蒂法骨架生成胶囊 / 盒子碰撞，
## 死亡时启动模拟，尸体不despawn，子弹命中对对应骨骼施加冲量。

## 物理层：角色层 2 可被弹道（mask 1|2）打中；mask 只撞世界层 1，避免骨骼互撞抖动。
## Jolt 的碰撞是双向 OR，两边都不把对方层写进 mask，就不会自碰。
const LAYER_WORLD := 1
const LAYER_CHAR := 2

const BONES := [
	{"name": "C_Hip_a", "joint": PhysicalBone3D.JOINT_TYPE_NONE, "mass": 8.0, "radius": 0.12, "kind": "box", "child": "C_Spine_a", "box": Vector3(0.26, 0.14, 0.16), "len_min": 0.14},
	{"name": "C_Spine_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 4.5, "radius": 0.10, "kind": "capsule", "child": "C_Spine_b", "swing": 18.0, "twist": 12.0},
	{"name": "C_Spine_c", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 8.5, "radius": 0.11, "kind": "capsule", "child": "C_Spine_d", "swing": 16.0, "twist": 10.0, "len_min": 0.14},
	{"name": "C_Spine_d", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 6.0, "radius": 0.11, "kind": "capsule", "child": "C_Neck_a", "swing": 14.0, "twist": 10.0},
	{"name": "C_Neck_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.4, "radius": 0.04, "kind": "capsule", "child": "C_Head_a", "swing": 30.0, "twist": 20.0, "len_min": 0.09},
	{"name": "C_Head_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 5.0, "radius": 0.09, "kind": "capsule", "child": "", "length": 0.18, "swing": 28.0, "twist": 24.0},
	{"name": "L_Shoulder_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.4, "radius": 0.045, "kind": "capsule", "child": "L_UpperArm_a", "swing": 40.0, "twist": 25.0},
	{"name": "R_Shoulder_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.4, "radius": 0.045, "kind": "capsule", "child": "R_UpperArm_a", "swing": 40.0, "twist": 25.0},
	{"name": "L_UpperArm_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 2.2, "radius": 0.045, "kind": "capsule", "child": "L_Forearm_a", "swing": 55.0, "twist": 30.0},
	{"name": "R_UpperArm_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 2.2, "radius": 0.045, "kind": "capsule", "child": "R_Forearm_a", "swing": 55.0, "twist": 30.0},
	{"name": "L_Forearm_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 1.3, "radius": 0.038, "kind": "capsule", "child": "L_Hand_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "R_Forearm_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 1.3, "radius": 0.038, "kind": "capsule", "child": "R_Hand_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "L_Hand_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 0.45, "radius": 0.035, "kind": "capsule", "child": "L_Middle_a", "swing": 35.0, "twist": 25.0, "len_min": 0.08},
	{"name": "R_Hand_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 0.45, "radius": 0.035, "kind": "capsule", "child": "R_Middle_a", "swing": 35.0, "twist": 25.0, "len_min": 0.08},
	{"name": "L_UpperLeg_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 6.2, "radius": 0.07, "kind": "capsule", "child": "L_Foreleg_a", "swing": 45.0, "twist": 20.0},
	{"name": "R_UpperLeg_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 6.2, "radius": 0.07, "kind": "capsule", "child": "R_Foreleg_a", "swing": 45.0, "twist": 20.0},
	{"name": "L_Foreleg_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 3.0, "radius": 0.05, "kind": "capsule", "child": "L_Foot_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "R_Foreleg_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 3.0, "radius": 0.05, "kind": "capsule", "child": "R_Foot_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "L_Foot_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.8, "radius": 0.04, "kind": "capsule", "child": "L_Toe_a", "hinge_lo": -25.0, "hinge_hi": 35.0},
	{"name": "R_Foot_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.8, "radius": 0.04, "kind": "capsule", "child": "R_Toe_a", "hinge_lo": -25.0, "hinge_hi": 35.0},
]

## 子弹冲量系数：乘以 ballistics 的 impulse(0..1)。步枪应能明显推动躯干/肢体，霰弹更重，手枪更轻。
const IMPULSE_SCALE := 8.5

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var bones: Dictionary = {}  # name -> PhysicalBone3D
var ready_ok: bool = false
var active: bool = false
var last_impulse: Vector3 = Vector3.ZERO
var last_impulse_bone: String = ""
var last_impulse_speed: float = 0.0
var impulse_count: int = 0
var _host: Node = null
var _map_frozen: bool = false


func setup(skel: Skeleton3D, host: Node = null) -> bool:
	skeleton = skel
	_host = host
	if skeleton == null:
		return false
	if simulator and is_instance_valid(simulator):
		simulator.queue_free()
	bones.clear()
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "PhysicalBoneSimulator3D"
	simulator.active = false
	skeleton.add_child(simulator)
	for def in BONES:
		var pb := _make_bone(def)
		if pb:
			bones[str(def["name"])] = pb
	ready_ok = bones.size() >= 10
	if ready_ok:
		print("RagdollSystem: built ", bones.size(), " physical bones")
	else:
		push_warning("RagdollSystem: failed to build physical bones")
	return ready_ok


func is_active() -> bool:
	return active and simulator != null and simulator.is_simulating_physics()


func _make_bone(def: Dictionary) -> PhysicalBone3D:
	var name := str(def["name"])
	var i := skeleton.find_bone(name)
	if i < 0:
		push_warning("RagdollSystem: missing bone " + name)
		return null
	var length := _bone_length(def)
	var radius := float(def.get("radius", 0.05))
	var pb := PhysicalBone3D.new()
	pb.name = "PhysicalBone_" + name
	pb.bone_name = StringName(name)
	pb.mass = float(def.get("mass", 1.0))
	pb.friction = 0.85
	pb.bounce = 0.0
	pb.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	pb.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	pb.linear_damp = 1.2
	pb.angular_damp = 3.2
	pb.can_sleep = true
	pb.gravity_scale = 1.0
	pb.collision_layer = LAYER_CHAR
	pb.collision_mask = LAYER_WORLD
	pb.joint_type = int(def.get("joint", PhysicalBone3D.JOINT_TYPE_NONE))
	_apply_joint_limits(pb, def)
	var mid := Vector3(0.0, length * 0.5, 0.0)
	pb.body_offset = Transform3D(Basis(), mid)
	if pb.joint_type != PhysicalBone3D.JOINT_TYPE_NONE:
		pb.joint_offset = Transform3D(Basis(), -mid)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	if str(def.get("kind", "capsule")) == "box":
		var box := BoxShape3D.new()
		var sz: Vector3 = def.get("box", Vector3(0.22, length, 0.14))
		sz.y = maxf(sz.y, length)
		box.size = sz
		cs.shape = box
	else:
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = maxf(length, radius * 2.05)
		cs.shape = cap
	cs.position = Vector3.ZERO
	pb.add_child(cs)
	simulator.add_child(pb)
	return pb


func _bone_length(def: Dictionary) -> float:
	var forced := float(def.get("length", 0.0))
	var mn := float(def.get("len_min", 0.06))
	var child := str(def.get("child", ""))
	var i := skeleton.find_bone(str(def["name"]))
	var length := forced
	if child != "" and i >= 0:
		var ci := skeleton.find_bone(child)
		if ci >= 0:
			var a := skeleton.get_bone_global_rest(i).origin
			var b := skeleton.get_bone_global_rest(ci).origin
			length = a.distance_to(b)
	if length <= 0.01:
		length = mn
	return maxf(length, mn)


func _apply_joint_limits(pb: PhysicalBone3D, def: Dictionary) -> void:
	match int(pb.joint_type):
		PhysicalBone3D.JOINT_TYPE_CONE:
			pb.set("joint_constraints/swing_span", float(def.get("swing", 25.0)))
			pb.set("joint_constraints/twist_span", float(def.get("twist", 15.0)))
			pb.set("joint_constraints/bias", 0.3)
			pb.set("joint_constraints/relaxation", 1.0)
		PhysicalBone3D.JOINT_TYPE_HINGE:
			pb.set("joint_constraints/angular_limit_enabled", true)
			pb.set("joint_constraints/angular_limit_lower", float(def.get("hinge_lo", 0.0)))
			pb.set("joint_constraints/angular_limit_upper", float(def.get("hinge_hi", 120.0)))
			pb.set("joint_constraints/angular_limit_bias", 0.3)
			pb.set("joint_constraints/angular_limit_relaxation", 1.0)


func start(impulse: Vector3 = Vector3.ZERO, hit: Vector3 = Vector3.ZERO, collider: Object = null) -> void:
	if not ready_ok or simulator == null:
		return
	if active:
		if impulse.length_squared() > 1e-6:
			apply_hit_impulse(impulse, hit, collider)
		return
	active = true
	simulator.active = true
	simulator.physical_bones_start_simulation()
	if impulse.length_squared() > 1e-6:
		# 物理体刚启动，推迟一帧再施加击杀冲量，避免部分刚体尚未进入空间。
		call_deferred("apply_hit_impulse", impulse, hit, collider)


func stop() -> void:
	if simulator == null:
		return
	if simulator.is_simulating_physics():
		simulator.physical_bones_stop_simulation()
	simulator.active = false
	active = false
	last_impulse = Vector3.ZERO
	last_impulse_bone = ""
	last_impulse_speed = 0.0


func set_map_frozen(on: bool) -> void:
	_map_frozen = on
	if not active or simulator == null:
		return
	if on:
		if simulator.is_simulating_physics():
			simulator.physical_bones_stop_simulation()
		for pb in bones.values():
			if is_instance_valid(pb):
				(pb as PhysicalBone3D).collision_layer = 0
				(pb as PhysicalBone3D).collision_mask = 0
	else:
		for pb in bones.values():
			if is_instance_valid(pb):
				(pb as PhysicalBone3D).collision_layer = LAYER_CHAR
				(pb as PhysicalBone3D).collision_mask = LAYER_WORLD
		simulator.active = true
		if not simulator.is_simulating_physics():
			simulator.physical_bones_start_simulation()


func apply_hit_impulse(impulse: Vector3, hit: Vector3 = Vector3.ZERO, collider: Object = null) -> void:
	if impulse.length_squared() < 1e-8:
		return
	if not active:
		return
	var pb: PhysicalBone3D = null
	if collider is PhysicalBone3D and bones.values().has(collider):
		pb = collider
	elif collider is PhysicalBone3D:
		var bn := str((collider as PhysicalBone3D).bone_name)
		pb = bones.get(bn)
	if pb == null:
		pb = _closest_bone(hit)
	if pb == null:
		return
	if hit == Vector3.ZERO:
		pb.apply_central_impulse(impulse)
	else:
		pb.apply_impulse(impulse, hit)
	# 少量把冲量传给相邻躯干，避免单肢被拉开
	var torso: PhysicalBone3D = bones.get("C_Spine_c", bones.get("C_Hip_a"))
	if torso and torso != pb:
		torso.apply_central_impulse(impulse * 0.28)
	last_impulse = impulse
	last_impulse_bone = str(pb.bone_name)
	last_impulse_speed = pb.linear_velocity.length()
	impulse_count += 1


func impulse_from_ballistics(par: Dictionary, dir: Vector3) -> Vector3:
	var imp := float(par.get("impulse", 0.5))
	var cat := str(par.get("category", ""))
	var scale := IMPULSE_SCALE
	if cat == "shotgun":
		scale *= 0.85  # 单丸略收，8 丸合计仍明显重于步枪
	elif cat == "pistol":
		scale *= 0.9
	elif cat == "rifle":
		scale *= 1.05
	var d := dir.normalized() if dir.length_squared() > 1e-8 else Vector3.FORWARD
	# 略向上，避免完全贴地推滑
	d = (d + Vector3.UP * 0.12).normalized()
	return d * (0.22 + imp) * scale


func _closest_bone(hit: Vector3) -> PhysicalBone3D:
	var best: PhysicalBone3D = null
	var best_d := 1.0e9
	for pb in bones.values():
		if not is_instance_valid(pb):
			continue
		var d := (pb as PhysicalBone3D).global_position.distance_to(hit)
		if d < best_d:
			best_d = d
			best = pb
	return best


func get_follow_point() -> Vector3:
	for n in ["C_Spine_c", "C_Spine_d", "C_Hip_a", "C_Spine_a"]:
		var pb: PhysicalBone3D = bones.get(n)
		if pb and is_instance_valid(pb):
			return pb.global_position
	if skeleton:
		return skeleton.global_position
	return Vector3.ZERO


func get_pelvis_point() -> Vector3:
	var pb: PhysicalBone3D = bones.get("C_Hip_a")
	if pb and is_instance_valid(pb):
		return pb.global_position
	return get_follow_point()


func max_linear_speed() -> float:
	var m := 0.0
	for pb in bones.values():
		if is_instance_valid(pb):
			m = maxf(m, (pb as PhysicalBone3D).linear_velocity.length())
	return m


func bone_names() -> PackedStringArray:
	return PackedStringArray(bones.keys())
