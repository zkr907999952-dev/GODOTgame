extends RefCounted
## Lithotomy / stirrup exam pose. Drives the character Skeleton3D so the
## torso follows the backrest and both legs rest on the stirrups (legs spread).
## Bone names match SoftLoco (C_Hip_a, C_Spine_*, L/R_UpperLeg_a, Foreleg, Foot).
class_name ExamPose

## Extra local-space rotations (radians, Godot XYZ) added on top of rest pose.
## Tuned to a supine character whose root is already rotated to lie on the table.
## Signs were chosen so thighs abduct and flex toward the stirrups, knees bend,
## feet plantar-flex onto the cups, and the spine slightly extends up the backrest.
const FK := {
	"C_Hip_a": Vector3(0.18, 0.0, 0.0),
	"C_Spine_a": Vector3(0.16, 0.0, 0.0),
	"C_Spine_b": Vector3(0.14, 0.0, 0.0),
	"C_Spine_c": Vector3(0.10, 0.0, 0.0),
	"C_Spine_d": Vector3(0.06, 0.0, 0.0),
	"C_Neck_a": Vector3(-0.08, 0.0, 0.0),
	"C_Head_a": Vector3(-0.04, 0.0, 0.0),
	# Legs: x = flex, y = twist, z = abduct (left / right mirrored).
	"L_UpperLeg_a": Vector3(-0.85, 0.12, 0.72),
	"R_UpperLeg_a": Vector3(-0.85, -0.12, -0.72),
	"L_Foreleg_a": Vector3(1.15, 0.0, 0.0),
	"R_Foreleg_a": Vector3(1.15, 0.0, 0.0),
	"L_Foot_a": Vector3(0.35, 0.15, 0.1),
	"R_Foot_a": Vector3(0.35, -0.15, -0.1),
	# Arms relaxed along the torso / on the belly.
	"L_Shoulder_a": Vector3(0.05, 0.15, 0.2),
	"R_Shoulder_a": Vector3(0.05, -0.15, -0.2),
	"L_UpperArm_a": Vector3(0.25, 0.4, 0.55),
	"R_UpperArm_a": Vector3(0.25, -0.4, -0.55),
	"L_Forearm_a": Vector3(0.45, 0.0, 0.15),
	"R_Forearm_a": Vector3(0.45, 0.0, -0.15),
	"L_Hand_a": Vector3(0.1, 0.0, 0.0),
	"R_Hand_a": Vector3(0.1, 0.0, 0.0),
}


static func apply(skel: Skeleton3D, left_stirrup: Vector3, right_stirrup: Vector3, backrest_angle: float) -> void:
	if skel == null:
		return
	# Reset loco-ish bones to rest, then layer FK, then two-bone IK for the legs.
	for name in FK.keys():
		var i := skel.find_bone(name)
		if i < 0:
			continue
		var rest := skel.get_bone_rest(i)
		skel.set_bone_pose_rotation(i, rest.basis.get_rotation_quaternion())
		skel.set_bone_pose_position(i, rest.origin)
		skel.set_bone_pose_scale(i, rest.basis.get_scale())
	# Spine follows the backrest a little more than the hip (upper body raised).
	var extra := clampf(backrest_angle, 0.0, 0.8)
	for name in FK.keys():
		var i := skel.find_bone(name)
		if i < 0:
			continue
		var rest_q := skel.get_bone_rest(i).basis.get_rotation_quaternion()
		var e: Vector3 = FK[name]
		if str(name).begins_with("C_Spine") or name == "C_Hip_a":
			e.x += extra * (0.35 if name == "C_Hip_a" else 0.2)
		skel.set_bone_pose_rotation(i, rest_q * Quaternion.from_euler(e))
	_ik_leg(skel, true, left_stirrup)
	_ik_leg(skel, false, right_stirrup)
	skel.force_update_transform()


static func _ik_leg(skel: Skeleton3D, left: bool, target: Vector3) -> void:
	var thigh_n := "L_UpperLeg_a" if left else "R_UpperLeg_a"
	var shin_n := "L_Foreleg_a" if left else "R_Foreleg_a"
	var foot_n := "L_Foot_a" if left else "R_Foot_a"
	var i_th := skel.find_bone(thigh_n)
	var i_sh := skel.find_bone(shin_n)
	var i_ft := skel.find_bone(foot_n)
	if i_th < 0 or i_sh < 0 or i_ft < 0:
		return
	# Two-bone IK in skeleton space. Target is a world-space stirrup point.
	var skel_inv := skel.global_transform.affine_inverse()
	var p_th := skel_inv * _bone_world_pos(skel, i_th)
	var p_sh := skel_inv * _bone_world_pos(skel, i_sh)
	var p_ft := skel_inv * _bone_world_pos(skel, i_ft)
	var tgt := skel_inv * target
	var len1 := p_th.distance_to(p_sh)
	var len2 := p_sh.distance_to(p_ft)
	if len1 < 1e-4 or len2 < 1e-4:
		return
	var to_t := tgt - p_th
	var dist := clampf(to_t.length(), 0.08, len1 + len2 - 0.02)
	if to_t.length_squared() < 1e-8:
		return
	var axis_dir := to_t.normalized()
	# Pole: out to the side and slightly up, so knees point outward (lithotomy).
	var pole := Vector3(-0.7 if left else 0.7, 0.55, 0.15)
	var pole_n := pole - axis_dir * pole.dot(axis_dir)
	if pole_n.length_squared() < 1e-6:
		pole_n = Vector3.UP
	else:
		pole_n = pole_n.normalized()
	# Law of cosines for knee angle.
	var cos_knee := clampf((len1 * len1 + len2 * len2 - dist * dist) / (2.0 * len1 * len2), -1.0, 1.0)
	var knee_angle := PI - acos(cos_knee)
	var cos_hip := clampf((len1 * len1 + dist * dist - len2 * len2) / (2.0 * len1 * dist), -1.0, 1.0)
	var hip_bend := acos(cos_hip)
	# Desired thigh direction: rotate axis_dir toward the pole by hip_bend.
	var rot_axis := axis_dir.cross(pole_n)
	if rot_axis.length_squared() < 1e-8:
		rot_axis = Vector3.RIGHT
	else:
		rot_axis = rot_axis.normalized()
	var thigh_dir := axis_dir.rotated(rot_axis, hip_bend)
	_aim_bone(skel, i_th, thigh_dir)
	# Shin: from predicted knee to target.
	var knee := p_th + thigh_dir * len1
	var shin_dir := (tgt - knee).normalized()
	_aim_bone(skel, i_sh, shin_dir)
	# Foot: point roughly along the last shin, slight plantar flexion already in FK.


static func _bone_world_pos(skel: Skeleton3D, idx: int) -> Vector3:
	return skel.global_transform * skel.get_bone_global_pose(idx).origin


static func _aim_bone(skel: Skeleton3D, idx: int, dir_skel: Vector3) -> void:
	## Rotate the bone (in parent space) so its rest +Y (typical bone length axis) aims along dir_skel.
	if dir_skel.length_squared() < 1e-8:
		return
	dir_skel = dir_skel.normalized()
	var parent := skel.get_bone_parent(idx)
	var parent_global := skel.global_transform
	if parent >= 0:
		parent_global = skel.global_transform * skel.get_bone_global_pose(parent)
	# Current bone length axis in skeleton space from rest.
	var rest := skel.get_bone_rest(idx)
	# In this character, bones typically extend along their local +Y (or -Y for legs).
	# Use the current vector from this bone to its first child (shin/foot) as the length axis.
	var child := _first_child_bone(skel, idx)
	var cur_dir := Vector3.DOWN
	if child >= 0:
		var a := (skel.global_transform * skel.get_bone_global_pose(idx)).origin
		var b := (skel.global_transform * skel.get_bone_global_pose(child)).origin
		cur_dir = (skel.global_transform.affine_inverse().basis * (b - a)).normalized()
	else:
		# Fall back to rest +Y in skeleton space.
		var rest_y := (skel.global_transform * skel.get_bone_global_pose(idx)).basis.y
		cur_dir = skel.global_transform.affine_inverse().basis * rest_y
		if cur_dir.length_squared() < 1e-8:
			cur_dir = Vector3.DOWN
		else:
			cur_dir = cur_dir.normalized()
	var q_delta := Quaternion(cur_dir, dir_skel)
	# Apply in parent-local space: new_pose = parent_inv * q_delta * parent * pose? 
	# Simpler: convert q_delta (skeleton space) into bone local.
	var parent_basis := Basis.IDENTITY
	if parent >= 0:
		parent_basis = skel.get_bone_global_pose(parent).basis
	var local_delta := parent_basis.inverse() * Basis(q_delta) * parent_basis
	var cur := skel.get_bone_pose_rotation(idx)
	skel.set_bone_pose_rotation(idx, (local_delta * Basis(cur)).get_rotation_quaternion())


static func _first_child_bone(skel: Skeleton3D, idx: int) -> int:
	for i in skel.get_bone_count():
		if skel.get_bone_parent(i) == idx:
			return i
	return -1


static func head_world(skel: Skeleton3D) -> Transform3D:
	var i := skel.find_bone("C_Head_a")
	if i < 0:
		i = skel.find_bone("C_Neck_a")
	if i < 0:
		return skel.global_transform
	return skel.global_transform * skel.get_bone_global_pose(i)
