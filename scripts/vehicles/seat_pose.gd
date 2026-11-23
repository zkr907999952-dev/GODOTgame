extends RefCounted
## 0.4.07 驾驶坐姿：跑车 / 战斗机驾驶位。FK 弯髋屈膝 + 手臂 IK 握方向盘 / 操纵杆与油门。
## Body 网格的朝向与位置由 VehicleSystem 按座舱眼位（cockpit_offset）摆放：头部眼点对齐驾驶视角。
## 骨骼约定同 ExamPose：UpperLeg x<0 = 屈髋（大腿向前），Foreleg x>0 = 屈膝，Spine x>0 = 后仰。

const ExamPoseScript := preload("res://scripts/vehicles/exam_pose.gd")

const CAR := {
	"recline": 0.30,  # 跑车座椅后仰（弧度，绕身体左右轴）
	"fk": {
		"C_Hip_a": Vector3(0.0, 0.0, 0.0),
		"C_Spine_a": Vector3(-0.06, 0.0, 0.0),
		"C_Spine_b": Vector3(-0.04, 0.0, 0.0),
		"C_Neck_a": Vector3(0.10, 0.0, 0.0),
		"C_Head_a": Vector3(0.10, 0.0, 0.0),
		"L_UpperLeg_a": Vector3(-1.30, 0.03, 0.07),
		"R_UpperLeg_a": Vector3(-1.30, -0.03, -0.07),
		"L_Foreleg_a": Vector3(0.75, 0.0, 0.0),
		"R_Foreleg_a": Vector3(0.75, 0.0, 0.0),
		"L_Foot_a": Vector3(-0.25, 0.0, 0.0),
		"R_Foot_a": Vector3(-0.25, 0.0, 0.0),
	},
}

const PLANE := {
	"recline": 0.38,  # 战斗机弹射座椅后仰更大
	"fk": {
		"C_Hip_a": Vector3(0.0, 0.0, 0.0),
		"C_Spine_a": Vector3(-0.05, 0.0, 0.0),
		"C_Spine_b": Vector3(-0.03, 0.0, 0.0),
		"C_Neck_a": Vector3(0.14, 0.0, 0.0),
		"C_Head_a": Vector3(0.12, 0.0, 0.0),
		"L_UpperLeg_a": Vector3(-1.20, 0.03, 0.10),
		"R_UpperLeg_a": Vector3(-1.20, -0.03, -0.10),
		"L_Foreleg_a": Vector3(1.05, 0.0, 0.0),
		"R_Foreleg_a": Vector3(1.05, 0.0, 0.0),
		"L_Foot_a": Vector3(-0.30, 0.0, 0.0),
		"R_Foot_a": Vector3(-0.30, 0.0, 0.0),
	},
}

const ARM_BONES := ["L_Shoulder_a", "R_Shoulder_a", "L_UpperArm_a", "R_UpperArm_a", "L_Forearm_a", "R_Forearm_a", "L_Hand_a", "R_Hand_a"]


static func def_of(kind: String) -> Dictionary:
	return PLANE if kind == "plane" else CAR


static func clear(skel: Skeleton3D) -> void:
	if skel == null:
		return
	var names: Array = []
	names.append_array((CAR["fk"] as Dictionary).keys())
	names.append_array(ARM_BONES)
	names.append_array(["C_Spine_c", "C_Spine_d"])
	for n in names:
		var i := skel.find_bone(str(n))
		if i < 0:
			continue
		var rest := skel.get_bone_rest(i)
		skel.set_bone_pose_rotation(i, rest.basis.get_rotation_quaternion())
		skel.set_bone_pose_position(i, rest.origin)
	skel.force_update_transform()


## 只摆下半身 + 躯干（FK）。手臂另由 apply_hands 在 Body 摆好位置后再做 IK。
static func apply_body(skel: Skeleton3D, kind: String) -> void:
	if skel == null:
		return
	clear(skel)
	var fk: Dictionary = def_of(kind)["fk"]
	for n in fk.keys():
		var i := skel.find_bone(str(n))
		if i < 0:
			continue
		var rest_q := skel.get_bone_rest(i).basis.get_rotation_quaternion()
		skel.set_bone_pose_rotation(i, rest_q * Quaternion.from_euler(fk[n]))
	skel.force_update_transform()


static func apply_hands(skel: Skeleton3D, hand_l: Vector3, hand_r: Vector3) -> void:
	if skel == null:
		return
	if hand_l.is_finite() and hand_l.length_squared() > 1e-8:
		ExamPoseScript._ik_arm(skel, true, hand_l)
	if hand_r.is_finite() and hand_r.length_squared() > 1e-8:
		ExamPoseScript._ik_arm(skel, false, hand_r)
	skel.force_update_transform()


static func bone_world(skel: Skeleton3D, name: String) -> Vector3:
	var i := skel.find_bone(name)
	if i < 0:
		return Vector3.ZERO
	return skel.global_transform * skel.get_bone_global_pose(i).origin
