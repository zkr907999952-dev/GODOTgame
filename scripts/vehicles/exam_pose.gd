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
	# Soft waist flex (negative X = crunch toward the belly) so first-person
	# can see the stomach. Keep it gentle — CharacterBody stays upright.
	"C_Hip_a": Vector3(-0.05, 0.0, 0.0),
	"C_Spine_a": Vector3(-0.10, 0.0, 0.0),
	"C_Spine_b": Vector3(-0.07, 0.0, 0.0),
	"C_Spine_c": Vector3(-0.04, 0.0, 0.0),
	"C_Spine_d": Vector3(-0.02, 0.0, 0.0),
	# Slight forward neck / head bow so first-person at the true eye can
	# look down the body more naturally. CharacterBody stays upright.
	"C_Neck_a": Vector3(-0.18, 0.0, 0.0),
	"C_Head_a": Vector3(-0.12, 0.0, 0.0),
	# Legs: x = flex, y = twist, z = abduct. 0.2.26: slightly less hip flex
	# and a flatter shin so the calves rest along the stirrup pads instead
	# of plunging through them.
	"L_UpperLeg_a": Vector3(-0.28, 0.04, 0.46),
	"R_UpperLeg_a": Vector3(-0.28, -0.04, -0.46),
	"L_Foreleg_a": Vector3(0.18, 0.0, 0.02),
	"R_Foreleg_a": Vector3(0.18, 0.0, -0.02),
	"L_Foot_a": Vector3(0.10, 0.06, 0.03),
	"R_Foot_a": Vector3(0.10, -0.06, -0.03),
	# Arms: flatter, more gradual upper-arm angle; forearms reach forward
	# along the armrests rather than tucking in at the elbow.
	"L_Shoulder_a": Vector3(0.00, 0.02, 0.03),
	"R_Shoulder_a": Vector3(0.00, -0.02, -0.03),
	"L_UpperArm_a": Vector3(0.02, 0.06, 0.16),
	"R_UpperArm_a": Vector3(0.02, -0.06, -0.16),
	"L_Forearm_a": Vector3(0.04, 0.0, 0.02),
	"R_Forearm_a": Vector3(0.04, 0.0, -0.02),
	"L_Hand_a": Vector3(0.04, 0.0, 0.0),
	"R_Hand_a": Vector3(0.04, 0.0, 0.0),
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


static func apply(skel: Skeleton3D, left_stirrup: Vector3, right_stirrup: Vector3, _backrest_angle: float = 0.0, left_armrest: Vector3 = Vector3.ZERO, right_armrest: Vector3 = Vector3.ZERO, rail_axis: Vector3 = Vector3.ZERO, rail_up: Vector3 = Vector3.ZERO) -> void:
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
		if rail_axis.length_squared() > 1e-6:
			_ik_arm_on_rail(skel, true, left_armrest, rail_axis, rail_up)
		else:
			_ik_arm(skel, true, left_armrest)
	if right_armrest.length_squared() > 1e-6:
		if rail_axis.length_squared() > 1e-6:
			_ik_arm_on_rail(skel, false, right_armrest, rail_axis, rail_up)
		else:
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
	# A little more side so the shin stays coaxial with the outward stirrup pad.
	var pole := Vector3(0.55 if left else -0.55, 0.02, 0.62)
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
	# Pole: slightly out and up (face +Z while lying) so the elbow is a
	# little raised while the forearm still rests along the armrest.
	var pole := Vector3(0.08 if left else -0.08, -0.14, 0.08)
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


static func _ik_arm_on_rail(skel: Skeleton3D, left: bool, hand_tgt: Vector3, rail_axis: Vector3, rail_up: Vector3) -> void:
	## Keep the forearm parallel to the armrest and resting on top of it:
	## the hand sits on the pad, the elbow is one forearm-length back along
	## the same rail (same height / same lateral), then the upper arm aims
	## at that elbow.
	var ua_n := "L_UpperArm_a" if left else "R_UpperArm_a"
	var fa_n := "L_Forearm_a" if left else "R_Forearm_a"
	var ha_n := "L_Hand_a" if left else "R_Hand_a"
	var i_ua := skel.find_bone(ua_n)
	var i_fa := skel.find_bone(fa_n)
	var i_ha := skel.find_bone(ha_n)
	if i_ua < 0 or i_fa < 0 or i_ha < 0:
		return
	if rail_axis.length_squared() < 1e-8:
		_ik_arm(skel, left, hand_tgt)
		return
	var axis := rail_axis.normalized()
	var skel_inv := skel.global_transform.affine_inverse()
	var p_ua := skel_inv * _bone_world_pos(skel, i_ua)
	var p_fa := skel_inv * _bone_world_pos(skel, i_fa)
	var p_ha := skel_inv * _bone_world_pos(skel, i_ha)
	var hand := skel_inv * hand_tgt
	var len1 := p_ua.distance_to(p_fa)
	var len2 := p_fa.distance_to(p_ha)
	if len1 < 1e-4 or len2 < 1e-4:
		return
	var axis_s: Vector3 = (skel.global_transform.affine_inverse().basis * axis)
	if axis_s.length_squared() < 1e-8:
		_ik_arm(skel, left, hand_tgt)
		return
	axis_s = axis_s.normalized()
	# Elbow is along the rail, toward the shoulder / head, on the same pad.
	var elbow := hand - axis_s * len2
	var to_el := elbow - p_ua
	var reach := to_el.length()
	if reach > len1 - 0.004:
		# Keep the forearm direction (parallel to the rail) and slide the
		# hand/elbow along the rail until the upper arm can reach.
		var over := reach - (len1 - 0.004)
		elbow += (p_ua - elbow).normalized() * over
		hand = elbow + axis_s * len2
		to_el = elbow - p_ua
		reach = to_el.length()
	if to_el.length_squared() < 1e-8:
		_ik_arm(skel, left, hand_tgt)
		return
	_aim_bone(skel, i_ua, to_el.normalized())
	var fa_dir := hand - elbow
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


static func apply_look(skel: Skeleton3D, yaw: float, pitch: float, look_world: Vector3 = Vector3.ZERO, cam_up: Vector3 = Vector3.UP) -> void:
	## Rotate neck / head / eyes with the first-person look so the face follows
	## the camera — this must be visible in a room mirror. Prefer aiming at
	## look_world (camera forward) by setting the head's world +Z onto that
	## direction. yaw / pitch are the fallback if no world aim is given
	## (positive pitch = look up).
	if skel == null:
		return
	if look_world.length_squared() > 1e-8:
		_aim_head_world(skel, look_world.normalized(), cam_up)
		return
	# Fallback: camera extras. Positive pitch (look up) tilts the head back
	# (negative local X, matching the lithotomy FK extension).
	var neck_y := yaw * 0.42
	var head_y := yaw * 0.62
	var neck_p := -pitch * 0.42
	var head_p := -pitch * 0.62
	_add_local_euler(skel, "C_Neck_a", Vector3(neck_p, neck_y, 0.0))
	_add_local_euler(skel, "C_Head_a", Vector3(head_p, head_y, 0.0))
	_add_local_euler(skel, "L_Eye", Vector3(head_p * 0.35, head_y * 0.35, 0.0))
	_add_local_euler(skel, "R_Eye", Vector3(head_p * 0.35, head_y * 0.35, 0.0))
	skel.force_update_transform()


static func head_forward(skel: Skeleton3D) -> Vector3:
	## Visible face direction (head bone +Z) in world space.
	var xf := head_world(skel)
	var f := xf.basis.z
	if f.length_squared() < 1e-8:
		return Vector3(0, 0, 1)
	return f.normalized()


static func _aim_head_world(skel: Skeleton3D, want: Vector3, cam_up: Vector3 = Vector3.UP) -> void:
	## Put the head's face axis (+Z) exactly on the camera forward. A limited
	## neck swing shares the motion so the neck is not frozen, but the head
	## is always locked to the camera (no mid-angle XZ atan2).
	if want.length_squared() < 1e-8:
		return
	want = want.normalized()
	var i_neck := skel.find_bone("C_Neck_a")
	var i_head := skel.find_bone("C_Head_a")
	if i_head < 0:
		return
	var cur := head_forward(skel)
	if i_neck >= 0 and cur.length_squared() > 1e-8:
		var swing := Quaternion(cur, want)
		var ang := swing.get_angle()
		if ang > 1e-4 and ang < PI - 1e-4:
			var axis := swing.get_axis()
			if axis.length_squared() > 1e-8:
				# Neck takes a limited share; the head will finish the rest exactly.
				var neck_ang := clampf(ang * 0.42, 0.0, 0.55)
				_set_bone_world_rotate(skel, i_neck, Quaternion(axis.normalized(), neck_ang))
	# Desired head basis: Z = camera forward, Y ≈ camera up (no roll).
	var up := cam_up
	if up.length_squared() < 1e-8:
		up = Vector3.UP
	else:
		up = up.normalized()
	if absf(want.dot(up)) > 0.94:
		up = Vector3.UP if absf(want.dot(Vector3.UP)) < 0.94 else Vector3(0.0, 0.0, 1.0)
	var x := up.cross(want)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := want.cross(x)
	if y.length_squared() < 1e-8:
		y = up
	else:
		y = y.normalized()
	x = y.cross(want).normalized()
	_set_bone_world_basis(skel, i_head, Basis(x, y, want))
	# Eyes take a tiny additional look in the same direction (additive, small).
	var ie_l := skel.find_bone("L_Eye")
	var ie_r := skel.find_bone("R_Eye")
	if ie_l >= 0 or ie_r >= 0:
		var after := head_forward(skel)
		var extra := Quaternion(after if after.length_squared() > 1e-8 else want, want)
		if extra.get_angle() > 1e-4 and extra.get_angle() < 0.4:
			if ie_l >= 0:
				_set_bone_world_rotate(skel, ie_l, Quaternion.IDENTITY.slerp(extra, 0.35))
			if ie_r >= 0:
				_set_bone_world_rotate(skel, ie_r, Quaternion.IDENTITY.slerp(extra, 0.35))
	skel.force_update_transform()


static func _set_bone_world_rotate(skel: Skeleton3D, idx: int, q_world: Quaternion) -> void:
	if idx < 0 or q_world.get_angle() < 1e-6:
		return
	var world_b := (skel.global_transform * skel.get_bone_global_pose(idx)).basis.orthonormalized()
	_set_bone_world_basis(skel, idx, (Basis(q_world) * world_b).orthonormalized())


static func _set_bone_world_basis(skel: Skeleton3D, idx: int, world_b: Basis) -> void:
	if idx < 0:
		return
	world_b = world_b.orthonormalized()
	var skel_b := skel.global_transform.basis.orthonormalized()
	var want_skel := skel_b.inverse() * world_b
	var parent := skel.get_bone_parent(idx)
	var parent_skel := Basis.IDENTITY
	if parent >= 0:
		parent_skel = skel.get_bone_global_pose(parent).basis.orthonormalized()
	var want_local := parent_skel.inverse() * want_skel
	skel.set_bone_pose_rotation(idx, want_local.get_rotation_quaternion())
	skel.force_update_transform()


static func _add_local_euler(skel: Skeleton3D, name: String, e: Vector3) -> void:
	var i := skel.find_bone(name)
	if i < 0:
		return
	var cur := skel.get_bone_pose_rotation(i)
	skel.set_bone_pose_rotation(i, cur * Quaternion.from_euler(e))


static func head_world(skel: Skeleton3D) -> Transform3D:
	var i := skel.find_bone("C_Head_a")
	if i < 0:
		i = skel.find_bone("C_Neck_a")
	if i < 0:
		return skel.global_transform
	return skel.global_transform * skel.get_bone_global_pose(i)


## Metres in front of the eyes along head +Z, so the near plane is not inside the face.
const EYE_FORWARD := 0.10
## Fallback from C_Head_a (skull base) toward the crown / face when eye bones are missing.
const EYE_CROWN := 0.08
const EYE_FACE := 0.04


static func eye_world(skel: Skeleton3D) -> Transform3D:
	## First-person eye: midpoint of L_Eye / R_Eye (or an estimate from the
	## head bone), then pushed forward along the face (+Z). Call this after
	## the static pose / breath and before apply_look, so looking around
	## cannot hitch the camera origin.
	var hw := head_world(skel)
	var b := hw.basis.orthonormalized()
	var origin := hw.origin + b.y * EYE_CROWN + b.z * EYE_FACE
	if skel:
		var il := skel.find_bone("L_Eye")
		var ir := skel.find_bone("R_Eye")
		if il >= 0 and ir >= 0:
			var le: Vector3 = skel.global_transform * skel.get_bone_global_pose(il).origin
			var re: Vector3 = skel.global_transform * skel.get_bone_global_pose(ir).origin
			origin = (le + re) * 0.5
	origin += b.z * EYE_FORWARD
	return Transform3D(b, origin)
