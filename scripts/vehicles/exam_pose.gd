extends RefCounted
## Lithotomy / stirrup exam pose. The Body mesh is already rotated to lie
## on the table (hips on the seat, spine along the backrest). This then
## spreads the legs onto the left/right stirrups and rests the arms on the armrests.
## Bone names match SoftLoco (C_Hip_a, C_Spine_*, L/R_UpperLeg_a, Foreleg, Foot).
class_name ExamPose

## Extra local-space rotations (radians, Godot XYZ) added on top of rest pose.
## Signs: thighs flex and abduct (apart, not crossed), knees bend, feet into the
## stirrup cups, spine slightly extended along the already-aligned backrest,
## arms relaxed on the belly / along the torso.
const FK := {
	"C_Hip_a": Vector3(0.06, 0.0, 0.0),
	"C_Spine_a": Vector3(0.04, 0.0, 0.0),
	"C_Spine_b": Vector3(0.03, 0.0, 0.0),
	"C_Spine_c": Vector3(0.02, 0.0, 0.0),
	"C_Spine_d": Vector3(0.02, 0.0, 0.0),
	"C_Neck_a": Vector3(-0.10, 0.0, 0.0),
	"C_Head_a": Vector3(-0.06, 0.0, 0.0),
	# Legs: x = flex, y = twist, z = abduct. 0.2.23: tighter thigh abduction
	# than 0.2.22's 0.40 rad; IK plants the calves on the stirrup pads.
	"L_UpperLeg_a": Vector3(-0.50, 0.05, 0.24),
	"R_UpperLeg_a": Vector3(-0.50, -0.05, -0.24),
	"L_Foreleg_a": Vector3(0.88, 0.0, 0.04),
	"R_Foreleg_a": Vector3(0.88, 0.0, -0.04),
	"L_Foot_a": Vector3(0.22, 0.10, 0.06),
	"R_Foot_a": Vector3(0.22, -0.10, -0.06),
	# Arms: smoother arc to the armrests, less shrugged / kinked shoulders.
	"L_Shoulder_a": Vector3(0.02, 0.06, 0.10),
	"R_Shoulder_a": Vector3(0.02, -0.06, -0.10),
	"L_UpperArm_a": Vector3(0.16, 0.22, 0.32),
	"R_UpperArm_a": Vector3(0.16, -0.22, -0.32),
	"L_Forearm_a": Vector3(0.28, 0.0, 0.08),
	"R_Forearm_a": Vector3(0.28, 0.0, -0.08),
	"L_Hand_a": Vector3(0.08, 0.0, 0.0),
	"R_Hand_a": Vector3(0.08, 0.0, 0.0),
}


static func hip_local(skel: Skeleton3D, body: Node3D) -> Vector3:
	## Hip in Body space at the current (typically rest / standing) pose.
	if skel == null or body == null:
		return Vector3(0.0, 0.92, 0.03)
	var i := skel.find_bone("C_Hip_a")
	if i < 0:
		return Vector3(0.0, 0.92, 0.03)
	var w: Vector3 = skel.global_transform * skel.get_bone_global_pose(i).origin
	return body.to_local(w)


static func clear(skel: Skeleton3D) -> void:
	if skel == null:
		return
	for name in FK.keys():
		var i := skel.find_bone(name)
		if i < 0:
			continue
		var rest := skel.get_bone_rest(i)
		skel.set_bone_pose_rotation(i, rest.basis.get_rotation_quaternion())
		skel.set_bone_pose_position(i, rest.origin)
		skel.set_bone_pose_scale(i, rest.basis.get_scale())
	skel.force_update_transform()


static func apply(skel: Skeleton3D, left_stirrup: Vector3, right_stirrup: Vector3, _backrest_angle: float = 0.0, left_armrest: Vector3 = Vector3.ZERO, right_armrest: Vector3 = Vector3.ZERO) -> void:
	if skel == null:
		return
	clear(skel)
	for name in FK.keys():
		var i := skel.find_bone(name)
		if i < 0:
			continue
		var rest_q := skel.get_bone_rest(i).basis.get_rotation_quaternion()
		var e: Vector3 = FK[name]
		skel.set_bone_pose_rotation(i, rest_q * Quaternion.from_euler(e))
	skel.force_update_transform()
	_ik_leg(skel, true, left_stirrup)
	_ik_leg(skel, false, right_stirrup)
	if left_armrest.length_squared() > 1e-6:
		_ik_arm(skel, true, left_armrest)
	if right_armrest.length_squared() > 1e-6:
		_ik_arm(skel, false, right_armrest)
	skel.force_update_transform()


static func offset_hair(skel: Skeleton3D, local_off: Vector3) -> void:
	## Shift HairRoot in its parent (head) space so the hair sits back
	## off the pillow / skull instead of clipping through them.
	if skel == null:
		return
	var i := skel.find_bone("HairRoot")
	if i < 0:
		i = skel.find_bone("Hair_1")
	if i < 0:
		return
	var rest := skel.get_bone_rest(i)
	skel.set_bone_pose_position(i, rest.origin + local_off)
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
	# Pole: out to the patient's side (mesh +X is left) and slightly "up" (face).
	# In skeleton/Body space after lying: +X = left, +Y = toward head, +Z = face/up.
	# Pole slightly out and face-up, less side pull so the shin stays on the pad.
	var pole := Vector3(0.28 if left else -0.28, 0.06, 0.82)
	var pole_n := pole - axis_dir * pole.dot(axis_dir)
	if pole_n.length_squared() < 1e-6:
		pole_n = Vector3(0, 0, 1)
	else:
		pole_n = pole_n.normalized()
	var cos_knee := clampf((len1 * len1 + len2 * len2 - dist * dist) / (2.0 * len1 * len2), -1.0, 1.0)
	var cos_hip := clampf((len1 * len1 + dist * dist - len2 * len2) / (2.0 * len1 * dist), -1.0, 1.0)
	var hip_bend := acos(cos_hip)
	var rot_axis := axis_dir.cross(pole_n)
	if rot_axis.length_squared() < 1e-8:
		rot_axis = Vector3(1, 0, 0)
	else:
		rot_axis = rot_axis.normalized()
	var thigh_dir := axis_dir.rotated(rot_axis, hip_bend)
	_aim_bone(skel, i_th, thigh_dir)
	var knee := p_th + thigh_dir * len1
	var shin_dir := (tgt - knee)
	if shin_dir.length_squared() < 1e-8:
		return
	_aim_bone(skel, i_sh, shin_dir.normalized())


static func _ik_arm(skel: Skeleton3D, left: bool, target: Vector3) -> void:
	var ua_n := "L_UpperArm_a" if left else "R_UpperArm_a"
	var fa_n := "L_Forearm_a" if left else "R_Forearm_a"
	var ha_n := "L_Hand_a" if left else "R_Hand_a"
	var i_ua := skel.find_bone(ua_n)
	var i_fa := skel.find_bone(fa_n)
	var i_ha := skel.find_bone(ha_n)
	if i_ua < 0 or i_fa < 0 or i_ha < 0:
		return
	var skel_inv := skel.global_transform.affine_inverse()
	var p_ua := skel_inv * _bone_world_pos(skel, i_ua)
	var p_fa := skel_inv * _bone_world_pos(skel, i_fa)
	var p_ha := skel_inv * _bone_world_pos(skel, i_ha)
	var tgt := skel_inv * target
	var len1 := p_ua.distance_to(p_fa)
	var len2 := p_fa.distance_to(p_ha)
	if len1 < 1e-4 or len2 < 1e-4:
		return
	var to_t := tgt - p_ua
	var dist := clampf(to_t.length(), 0.06, len1 + len2 - 0.015)
	if to_t.length_squared() < 1e-8:
		return
	var axis_dir := to_t.normalized()
	# Pole: slightly out and toward the feet so the arm flows to the
	# armrest in a smooth arc instead of a hiked, kinked elbow.
	var pole := Vector3(0.48 if left else -0.48, -0.22, 0.18)
	var pole_n := pole - axis_dir * pole.dot(axis_dir)
	if pole_n.length_squared() < 1e-6:
		pole_n = Vector3(0, 0, 1)
	else:
		pole_n = pole_n.normalized()
	var cos_el := clampf((len1 * len1 + len2 * len2 - dist * dist) / (2.0 * len1 * len2), -1.0, 1.0)
	var cos_sh := clampf((len1 * len1 + dist * dist - len2 * len2) / (2.0 * len1 * dist), -1.0, 1.0)
	var sh_bend := acos(cos_sh)
	var rot_axis := axis_dir.cross(pole_n)
	if rot_axis.length_squared() < 1e-8:
		rot_axis = Vector3(1, 0, 0)
	else:
		rot_axis = rot_axis.normalized()
	var ua_dir := axis_dir.rotated(rot_axis, sh_bend)
	_aim_bone(skel, i_ua, ua_dir)
	var elbow := p_ua + ua_dir * len1
	var fa_dir := (tgt - elbow)
	if fa_dir.length_squared() < 1e-8:
		return
	_aim_bone(skel, i_fa, fa_dir.normalized())


static func _bone_world_pos(skel: Skeleton3D, idx: int) -> Vector3:
	return skel.global_transform * skel.get_bone_global_pose(idx).origin


static func _aim_bone(skel: Skeleton3D, idx: int, dir_skel: Vector3) -> void:
	if dir_skel.length_squared() < 1e-8:
		return
	dir_skel = dir_skel.normalized()
	var parent := skel.get_bone_parent(idx)
	var child := _first_child_bone(skel, idx)
	var cur_dir := Vector3(0, -1, 0)
	if child >= 0:
		var a := (skel.global_transform * skel.get_bone_global_pose(idx)).origin
		var b := (skel.global_transform * skel.get_bone_global_pose(child)).origin
		cur_dir = (skel.global_transform.affine_inverse().basis * (b - a))
		if cur_dir.length_squared() < 1e-8:
			return
		cur_dir = cur_dir.normalized()
	var q_delta := Quaternion(cur_dir, dir_skel)
	var parent_basis := Basis.IDENTITY
	if parent >= 0:
		parent_basis = skel.get_bone_global_pose(parent).basis
	var local_delta := parent_basis.inverse() * Basis(q_delta) * parent_basis
	var cur := skel.get_bone_pose_rotation(idx)
	skel.set_bone_pose_rotation(idx, (local_delta * Basis(cur)).get_rotation_quaternion())
	skel.force_update_transform()


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
