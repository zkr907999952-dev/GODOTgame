extends Node
class_name RagdollSystem
## Godot 4 PhysicalBoneSimulator3D 布娃娃：运行时按蒂法骨架生成胶囊 / 盒子碰撞，
## 死亡时启动模拟，尸体不despawn，子弹命中对对应骨骼施加冲量。
## 关节角度在物理步后钳制（Jolt 下 Cone/Hinge 的 bias/softness 往往不生效，钳制才能真正挡住反曲）。

## 物理层：角色层 2 可被弹道（mask 1|2）打中。
## 骨骼 mask 含世界 + 角色，才能和玩家胶囊、冲击球发生接触（Godot 碰撞是双向 AND）。
## 同一具布娃娃的骨骼之间加 collision exception，避免自碰抖动。
const LAYER_WORLD := 1
const LAYER_CHAR := 2

const BONES := [
	{"name": "C_Hip_a", "joint": PhysicalBone3D.JOINT_TYPE_NONE, "mass": 5.0, "radius": 0.12, "kind": "box", "child": "C_Spine_a", "box": Vector3(0.26, 0.14, 0.16), "len_min": 0.14},
	{"name": "C_Spine_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 2.9, "radius": 0.10, "kind": "capsule", "child": "C_Spine_b", "swing": 18.0, "twist": 12.0},
	{"name": "C_Spine_c", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 5.4, "radius": 0.11, "kind": "capsule", "child": "C_Spine_d", "swing": 16.0, "twist": 10.0, "len_min": 0.14},
	{"name": "C_Spine_d", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 3.8, "radius": 0.11, "kind": "capsule", "child": "C_Neck_a", "swing": 14.0, "twist": 10.0},
	{"name": "C_Neck_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.0, "radius": 0.04, "kind": "capsule", "child": "C_Head_a", "swing": 30.0, "twist": 20.0, "len_min": 0.09},
	{"name": "C_Head_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 3.2, "radius": 0.09, "kind": "capsule", "child": "", "length": 0.18, "swing": 28.0, "twist": 24.0},
	{"name": "L_Shoulder_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.0, "radius": 0.045, "kind": "capsule", "child": "L_UpperArm_a", "swing": 40.0, "twist": 25.0},
	{"name": "R_Shoulder_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.0, "radius": 0.045, "kind": "capsule", "child": "R_UpperArm_a", "swing": 40.0, "twist": 25.0},
	{"name": "L_UpperArm_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.5, "radius": 0.045, "kind": "capsule", "child": "L_Forearm_a", "swing": 55.0, "twist": 30.0},
	{"name": "R_UpperArm_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 1.5, "radius": 0.045, "kind": "capsule", "child": "R_Forearm_a", "swing": 55.0, "twist": 30.0},
	{"name": "L_Forearm_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.9, "radius": 0.038, "kind": "capsule", "child": "L_Hand_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "R_Forearm_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.9, "radius": 0.038, "kind": "capsule", "child": "R_Hand_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "L_Hand_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 0.35, "radius": 0.035, "kind": "capsule", "child": "L_Middle_a", "swing": 35.0, "twist": 25.0, "len_min": 0.08},
	{"name": "R_Hand_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 0.35, "radius": 0.035, "kind": "capsule", "child": "R_Middle_a", "swing": 35.0, "twist": 25.0, "len_min": 0.08},
	{"name": "L_UpperLeg_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 4.0, "radius": 0.07, "kind": "capsule", "child": "L_Foreleg_a", "swing": 45.0, "twist": 20.0},
	{"name": "R_UpperLeg_a", "joint": PhysicalBone3D.JOINT_TYPE_CONE, "mass": 4.0, "radius": 0.07, "kind": "capsule", "child": "R_Foreleg_a", "swing": 45.0, "twist": 20.0},
	{"name": "L_Foreleg_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 2.0, "radius": 0.05, "kind": "capsule", "child": "L_Foot_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "R_Foreleg_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 2.0, "radius": 0.05, "kind": "capsule", "child": "R_Foot_a", "hinge_lo": 0.0, "hinge_hi": 130.0},
	{"name": "L_Foot_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.55, "radius": 0.04, "kind": "capsule", "child": "L_Toe_a", "hinge_lo": -25.0, "hinge_hi": 35.0},
	{"name": "R_Foot_a", "joint": PhysicalBone3D.JOINT_TYPE_HINGE, "mass": 0.55, "radius": 0.04, "kind": "capsule", "child": "R_Toe_a", "hinge_lo": -25.0, "hinge_hi": 35.0},
]

## 子弹冲量系数：乘以 ballistics 的 impulse(0..1)，再乘设置里的受击力度。
## 0.2.12 默认比 0.2.11 更强，步枪/霰弹能明显推动尸体，但速度仍有上限，不会飞出地图。
const IMPULSE_SCALE := 22.0
const SPHERE_RADIUS := 0.036
const SPHERE_LIFE := 0.16
const MAX_BONE_SPEED := 14.0
const MAX_BONE_ANG := 22.0

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var bones: Dictionary = {}  # name -> PhysicalBone3D
var ready_ok: bool = false
var active: bool = false
var last_impulse: Vector3 = Vector3.ZERO
var last_impulse_bone: String = ""
var last_impulse_speed: float = 0.0
var impulse_count: int = 0
var last_sphere_speed: float = 0.0
var last_sphere_mass: float = 0.0
var sphere_count: int = 0
var _host: Node = null
var _map_frozen: bool = false
var _spheres: Array = []
var _clamp_t: float = 0.0
var _joint_limits: Array = []  # {name, parent, kind, axis, rest, lo, hi, swing, twist}


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
	_build_joint_limits()
	_add_bone_exceptions()
	ready_ok = bones.size() >= 10
	if ready_ok:
		print("RagdollSystem: built ", bones.size(), " physical bones, joint limits=", _joint_limits.size())
	else:
		push_warning("RagdollSystem: failed to build physical bones")
	return ready_ok


func is_active() -> bool:
	return active and simulator != null and simulator.is_simulating_physics()


func _add_bone_exceptions() -> void:
	# 同体骨骼互不理，才能把角色层写进 mask 而不自碰。
	var arr: Array = bones.values()
	for i in arr.size():
		var a = arr[i]
		if not (a is PhysicalBone3D):
			continue
		for j in range(i + 1, arr.size()):
			var b = arr[j]
			if b is PhysicalBone3D:
				(a as PhysicalBone3D).add_collision_exception_with(b)
				(b as PhysicalBone3D).add_collision_exception_with(a)


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
	pb.linear_damp = 0.55
	pb.angular_damp = 2.0
	pb.can_sleep = true
	pb.gravity_scale = 0.8
	pb.collision_layer = LAYER_CHAR
	# 含角色层才能被玩家胶囊 / 冲击球推动（碰撞是双向 AND）。
	pb.collision_mask = LAYER_WORLD | LAYER_CHAR
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


func _parent_phys_name(bone_name: String) -> String:
	if skeleton == null:
		return ""
	var i := skeleton.find_bone(bone_name)
	while i >= 0:
		var p := skeleton.get_bone_parent(i)
		if p < 0:
			return ""
		var pn := skeleton.get_bone_name(p)
		if bones.has(pn):
			return pn
		i = p
	return ""


func _bone_world(pb: PhysicalBone3D) -> Transform3D:
	return pb.global_transform * pb.body_offset.affine_inverse()


func _set_bone_world(pb: PhysicalBone3D, xf: Transform3D) -> void:
	pb.global_transform = xf * pb.body_offset


func _skel_bone_world(bone_name: String, use_rest: bool = true) -> Transform3D:
	var i := skeleton.find_bone(bone_name)
	if i < 0:
		return Transform3D.IDENTITY
	var local := skeleton.get_bone_global_rest(i) if use_rest else skeleton.get_bone_global_pose(i)
	return skeleton.global_transform * local


func _character_back_from(hip_xf: Transform3D) -> Vector3:
	# 蒂法骨架局部 +Z 多为前向；取反作为身体后方，用于判断膝/肘屈曲方向。
	var fwd := hip_xf.basis.z
	if fwd.length_squared() < 1e-8:
		fwd = Vector3.FORWARD
	return -fwd.normalized()


func _build_joint_limits() -> void:
	# 必须用骨架绑定/当前姿势，而不是尚未进入模拟的 PhysicalBone 变换。
	_joint_limits.clear()
	if skeleton == null:
		return
	var hip_xf := _skel_bone_world("C_Hip_a")
	if hip_xf == Transform3D.IDENTITY:
		hip_xf = _skel_bone_world("C_Spine_a")
	var back := _character_back_from(hip_xf)
	for def in BONES:
		var name := str(def["name"])
		if not bones.has(name):
			continue
		var jt := int(def.get("joint", PhysicalBone3D.JOINT_TYPE_NONE))
		if jt == PhysicalBone3D.JOINT_TYPE_NONE:
			continue
		var parent_n := _parent_phys_name(name)
		if parent_n == "" or not bones.has(parent_n):
			continue
		var pw := _skel_bone_world(parent_n)
		var cw := _skel_bone_world(name)
		var py := pw.basis.y.normalized()
		var cy := cw.basis.y.normalized()
		var rec := {
			"name": name,
			"parent": parent_n,
			"kind": "hinge" if jt == PhysicalBone3D.JOINT_TYPE_HINGE else "cone",
			"axis": Vector3.RIGHT,
			"rest": 0.0,
			"lo": float(def.get("hinge_lo", 0.0)),
			"hi": float(def.get("hinge_hi", 130.0)),
			"swing": float(def.get("swing", 25.0)),
			"twist": float(def.get("twist", 15.0)),
		}
		# 略放宽关节下限，允许极小的生理过伸，但膝关节绝不能明显反曲。
		if rec["kind"] == "hinge" and (name.ends_with("Foreleg_a") or name.ends_with("Forearm_a")):
			rec["lo"] = -8.0
			rec["hi"] = 140.0 if name.ends_with("Forearm_a") else 135.0
		var axis := py.cross(cy)
		if axis.length_squared() < 0.0025:
			# 近似伸直：用身体侧向或父骨 X 作为铰链轴。
			axis = pw.basis.x
			if absf(axis.dot(py)) > 0.85:
				axis = pw.basis.z
		axis = axis.normalized()
		# 膝/肘：让屈曲（小腿向后、前臂向身体）为正角度。
		if name.ends_with("Foreleg_a") or name.ends_with("Forearm_a"):
			var flex := py.cross(back)
			if flex.length_squared() > 1e-6:
				flex = flex.normalized()
				if axis.dot(flex) < 0.0:
					axis = -axis
		rec["axis"] = pw.basis.inverse() * axis
		rec["rest"] = _hinge_angle_world(pw, cw, axis)
		_joint_limits.append(rec)


func _hinge_angle_world(pw: Transform3D, cw: Transform3D, axis_w: Vector3) -> float:
	if axis_w.length_squared() < 1e-8:
		return 0.0
	axis_w = axis_w.normalized()
	var py := (pw.basis.y - axis_w * pw.basis.y.dot(axis_w))
	var cy := (cw.basis.y - axis_w * cw.basis.y.dot(axis_w))
	if py.length_squared() < 1e-8 or cy.length_squared() < 1e-8:
		return 0.0
	py = py.normalized()
	cy = cy.normalized()
	return rad_to_deg(atan2(py.cross(cy).dot(axis_w), py.dot(cy)))


func _limit_axis_world(rec: Dictionary, parent_pb: PhysicalBone3D) -> Vector3:
	var pw := _bone_world(parent_pb)
	var ax: Vector3 = rec.get("axis", Vector3.RIGHT)
	var w := (pw.basis * ax)
	if w.length_squared() < 1e-8:
		w = pw.basis.x
	return w.normalized()


func _clamp_joint_angles() -> void:
	if not active:
		return
	for rec in _joint_limits:
		var pb: PhysicalBone3D = bones.get(str(rec["name"]))
		var parent_pb: PhysicalBone3D = bones.get(str(rec["parent"]))
		if pb == null or parent_pb == null or not is_instance_valid(pb) or not is_instance_valid(parent_pb):
			continue
		# 只钳制铰链（膝 / 肘 / 踝）。锥形关节（脊柱 / 髋 / 肩）在 Jolt 下
		# 用错误的休息轴做逐步钳制会把躯干拧坏，因此只保留 PhysicalBone 自带限位。
		if str(rec.get("kind", "cone")) == "hinge":
			_clamp_hinge(rec, pb, parent_pb)


func _clamp_hinge(rec: Dictionary, pb: PhysicalBone3D, parent_pb: PhysicalBone3D) -> void:
	var axis_w := _limit_axis_world(rec, parent_pb)
	var pw := _bone_world(parent_pb)
	var cw := _bone_world(pb)
	var ang := _hinge_angle_world(pw, cw, axis_w)
	var rest := float(rec.get("rest", 0.0))
	var lo := rest + float(rec.get("lo", 0.0))
	var hi := rest + float(rec.get("hi", 130.0))
	var clamped := clampf(ang, lo, hi)
	if absf(clamped - ang) < 0.35:
		# 靠近极限时去掉继续越界的角速度
		var w := pb.angular_velocity
		var wa := w.dot(axis_w)
		if (ang <= lo + 1.0 and wa < 0.0) or (ang >= hi - 1.0 and wa > 0.0):
			pb.angular_velocity = w - axis_w * wa
		return
	var delta := deg_to_rad(clamped - ang)
	var rot := Basis(axis_w, delta)
	var joint := cw.origin
	var new_xf := Transform3D(rot * cw.basis, joint)
	_set_bone_world(pb, new_xf)
	var w2 := pb.angular_velocity
	var wa2 := w2.dot(axis_w)
	# 越界方向的角速度清掉；偏差很大时整骨刹住，避免下一物理步再次甩开。
	if absf(clamped - ang) > 20.0:
		pb.angular_velocity = Vector3.ZERO
	elif (clamped <= lo + 0.01 and wa2 < 0.0) or (clamped >= hi - 0.01 and wa2 > 0.0):
		pb.angular_velocity = (w2 - axis_w * wa2) * 0.35
	else:
		pb.angular_velocity = w2 * 0.5


func _clamp_cone(rec: Dictionary, pb: PhysicalBone3D, parent_pb: PhysicalBone3D) -> void:
	var pw := _bone_world(parent_pb)
	var cw := _bone_world(pb)
	var py := pw.basis.y.normalized()
	var cy := cw.basis.y.normalized()
	var swing := rad_to_deg(py.angle_to(cy))
	var span := float(rec.get("swing", 25.0))
	if swing > span + 0.5:
		var axis := py.cross(cy)
		if axis.length_squared() < 1e-8:
			return
		axis = axis.normalized()
		var delta := deg_to_rad(span - swing)
		var rot := Basis(axis, delta)
		var new_xf := Transform3D(rot * cw.basis, cw.origin)
		_set_bone_world(pb, new_xf)
		if swing > span + 20.0:
			pb.angular_velocity = Vector3.ZERO
		else:
			pb.angular_velocity *= 0.4
	# 扭转：把子骨 X 投到垂直于子骨 Y 的平面，与父骨参考比较
	cw = _bone_world(pb)
	cy = cw.basis.y.normalized()
	var px := (pw.basis.x - cy * pw.basis.x.dot(cy))
	var cx := (cw.basis.x - cy * cw.basis.x.dot(cy))
	if px.length_squared() < 1e-8 or cx.length_squared() < 1e-8:
		return
	px = px.normalized()
	cx = cx.normalized()
	var twist := rad_to_deg(atan2(px.cross(cx).dot(cy), px.dot(cx)))
	var tspan := float(rec.get("twist", 15.0))
	if absf(twist) > tspan + 0.5:
		var tdelta := deg_to_rad(clampf(twist, -tspan, tspan) - twist)
		var rot2 := Basis(cy, tdelta)
		_set_bone_world(pb, Transform3D(rot2 * cw.basis, cw.origin))
		pb.angular_velocity *= 0.6


func debug_joint_angles() -> Dictionary:
	var out := {"ok": true, "knees": {}, "elbows": {}, "other": {}, "worst": 0.0}
	for rec in _joint_limits:
		var pb: PhysicalBone3D = bones.get(str(rec["name"]))
		var parent_pb: PhysicalBone3D = bones.get(str(rec["parent"]))
		if pb == null or parent_pb == null or not is_instance_valid(pb) or not is_instance_valid(parent_pb):
			continue
		var name := str(rec["name"])
		var info := {"name": name, "kind": rec.get("kind", ""), "angle": 0.0, "lo": 0.0, "hi": 0.0, "over": 0.0}
		if str(rec.get("kind", "")) == "hinge":
			var axis_w := _limit_axis_world(rec, parent_pb)
			var ang := _hinge_angle_world(_bone_world(parent_pb), _bone_world(pb), axis_w)
			var rest := float(rec.get("rest", 0.0))
			var lo := rest + float(rec.get("lo", 0.0))
			var hi := rest + float(rec.get("hi", 130.0))
			info["angle"] = ang
			info["rest"] = rest
			info["lo"] = lo
			info["hi"] = hi
			var over := 0.0
			if ang < lo:
				over = lo - ang
			elif ang > hi:
				over = ang - hi
			info["over"] = over
			info["hyperextended"] = ang < lo - 1.0
		else:
			var py := _bone_world(parent_pb).basis.y.normalized()
			var cy := _bone_world(pb).basis.y.normalized()
			var swing := rad_to_deg(py.angle_to(cy))
			info["angle"] = swing
			info["hi"] = float(rec.get("swing", 25.0))
			info["over"] = maxf(0.0, swing - float(rec.get("swing", 25.0)))
		if float(info["over"]) >= float(out["worst"]):
			out["worst"] = float(info["over"])
			out["worst_name"] = name
		if info["over"] > 2.5:
			out["ok"] = false
		if "Foreleg" in name:
			out["knees"][name] = info
		elif "Forearm" in name:
			out["elbows"][name] = info
		else:
			out["other"][name] = info
	return out


func debug_force_knee_hyperextension(degrees: float = -80.0) -> void:
	## 测试：把小腿绕铰链轴转到明显反曲的位置，随后应由钳制拉回。
	for rec in _joint_limits:
		var name := str(rec["name"])
		if not name.ends_with("Foreleg_a"):
			continue
		var pb: PhysicalBone3D = bones.get(name)
		var parent_pb: PhysicalBone3D = bones.get(str(rec["parent"]))
		if pb == null or parent_pb == null:
			continue
		var axis_w := _limit_axis_world(rec, parent_pb)
		var pw := _bone_world(parent_pb)
		var cw := _bone_world(pb)
		var ang := _hinge_angle_world(pw, cw, axis_w)
		var target := float(rec.get("rest", 0.0)) + degrees
		var rot := Basis(axis_w, deg_to_rad(target - ang))
		_set_bone_world(pb, Transform3D(rot * cw.basis, cw.origin))
		pb.angular_velocity = axis_w * deg_to_rad(-180.0)


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
				(pb as PhysicalBone3D).collision_mask = LAYER_WORLD | LAYER_CHAR
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
	# 球体承担主要撞击；再给骨骼一截冲量。position 必须是相对质心的偏移，不能传世界坐标。
	var residual := impulse * 0.8
	if hit == Vector3.ZERO:
		pb.apply_central_impulse(residual)
	else:
		pb.apply_impulse(residual, hit - pb.global_position)
	# 少量把冲量传给相邻躯干，避免单肢被拉开
	var torso: PhysicalBone3D = bones.get("C_Spine_c", bones.get("C_Hip_a"))
	if torso and torso != pb:
		torso.apply_central_impulse(residual * 0.4)
	var dir := impulse.normalized() if impulse.length_squared() > 1e-8 else Vector3.FORWARD
	var hit_p := hit if hit != Vector3.ZERO else pb.global_position
	spawn_impact_sphere(hit_p, dir, impulse.length(), str(pb.bone_name))
	last_impulse = impulse
	last_impulse_bone = str(pb.bone_name)
	last_impulse_speed = pb.linear_velocity.length()
	impulse_count += 1
	_clamp_t = 0.28
	_clamp_speeds()


func hit_force_scale() -> float:
	var st := _settings()
	if st:
		return clampf(float(st.get("hit_force")), 0.35, 2.0)
	return 1.0


func _settings() -> Node:
	var n: Node = _host if _host else self
	var tree := n.get_tree() if n else get_tree()
	if tree == null:
		return null
	return tree.root.find_child("GameSettings", true, false)


func impulse_from_ballistics(par: Dictionary, dir: Vector3) -> Vector3:
	var imp := float(par.get("impulse", 0.5))
	var cat := str(par.get("category", ""))
	var scale := IMPULSE_SCALE * hit_force_scale()
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


func spawn_impact_sphere(hit: Vector3, dir: Vector3, impulse_len: float, _bone: String = "") -> RigidBody3D:
	if not active or dir.length_squared() < 1e-8:
		return null
	dir = dir.normalized()
	# 球体质量和速度受设置「受击力度」影响；默认比 0.2.11 更重更快。
	var hf := hit_force_scale()
	var mass := clampf((0.22 + impulse_len * 0.02) * hf, 0.16, 0.55)
	var speed := clampf((70.0 + impulse_len * 6.5) * (0.7 + 0.35 * hf), 64.0, 160.0)
	var body := RigidBody3D.new()
	body.name = "BulletImpactSphere"
	body.mass = mass
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 6
	body.gravity_scale = 0.2
	body.linear_damp = 0.4
	body.angular_damp = 1.0
	# 放在角色层，骨骼 mask 含角色层，双向 AND 才能撞上。
	body.collision_layer = LAYER_CHAR
	body.collision_mask = LAYER_CHAR
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = SPHERE_RADIUS
	cs.shape = sph
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.85, 0.35, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.75, 0.2)
	mat.emission_energy_multiplier = 1.6
	mesh.material = mat
	mi.mesh = mesh
	body.add_child(mi)
	var parent: Node = _host if _host != null else self
	parent.add_child(body)
	body.global_position = hit - dir * (SPHERE_RADIUS + 0.04)
	body.linear_velocity = dir * speed
	_spheres.append({"n": body, "t": SPHERE_LIFE})
	last_sphere_speed = speed
	last_sphere_mass = mass
	sphere_count += 1
	return body


func _physics_process(delta: float) -> void:
	if active:
		_clamp_speeds()
		_clamp_joint_angles()
		_clamp_joint_angles()
	if _spheres.is_empty() and _clamp_t <= 0.0:
		return
	var keep: Array = []
	for s in _spheres:
		s["t"] = float(s["t"]) - delta
		var n: Node = s["n"]
		if not is_instance_valid(n) or float(s["t"]) <= 0.0:
			if is_instance_valid(n):
				n.queue_free()
			continue
		keep.append(s)
	_spheres = keep
	if _clamp_t > 0.0:
		_clamp_t = maxf(0.0, _clamp_t - delta)
		_clamp_speeds()


func _clamp_speeds() -> void:
	if not active:
		return
	for pb in bones.values():
		if not is_instance_valid(pb):
			continue
		var b: PhysicalBone3D = pb
		var v := b.linear_velocity
		if v.length() > MAX_BONE_SPEED:
			b.linear_velocity = v.normalized() * MAX_BONE_SPEED
		var w := b.angular_velocity
		if w.length() > MAX_BONE_ANG:
			b.angular_velocity = w.normalized() * MAX_BONE_ANG


func apply_stomp(at: Vector3, push: Vector3) -> void:
	if not active or push.length_squared() < 1e-8:
		return
	var pb := _closest_bone(at)
	if pb == null:
		return
	var j := push * 3.2
	if j.length() > 10.0:
		j = j.normalized() * 10.0
	pb.apply_impulse(j, at - pb.global_position)
	var torso: PhysicalBone3D = bones.get("C_Spine_c", bones.get("C_Hip_a"))
	if torso and torso != pb:
		torso.apply_central_impulse(j * 0.55)
	# 再给髋部一点水平挤开，角色踩上去能把尸体挪开。
	var hip: PhysicalBone3D = bones.get("C_Hip_a")
	if hip and hip != pb and hip != torso:
		hip.apply_central_impulse(j * 0.35)
	_clamp_t = maxf(_clamp_t, 0.12)
	# 踩踏后不要立刻把速度钳死，让这一下先作用出去。


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
