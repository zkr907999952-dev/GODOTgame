extends Node
class_name HitReaction
const CombatDamage := preload("res://scripts/combat_damage.gd")
## 活体受击反馈：在命中部位叠加短暂的局部骨骼抖动，再回弹到动画姿势。
## 不是完整布娃娃，不会让肢体一直软掉。不旋转锁骨，避免再次出现肩臂拧坏。

const SKIP_BONES := ["L_Shoulder_a", "R_Shoulder_a"]
const CHAIN := {
	"head": ["C_Head_a", "C_Neck_a", "C_Spine_d"],
	"neck": ["C_Neck_a", "C_Head_a", "C_Spine_d"],
	"body": ["C_Spine_c", "C_Spine_d", "C_Spine_a", "C_Hip_a"],
	"limb": [],
}

const LIMB_OF := {
	"L_UpperArm_a": ["L_UpperArm_a", "L_Forearm_a", "L_Hand_a"],
	"R_UpperArm_a": ["R_UpperArm_a", "R_Forearm_a", "R_Hand_a"],
	"L_Forearm_a": ["L_Forearm_a", "L_Hand_a", "L_UpperArm_a"],
	"R_Forearm_a": ["R_Forearm_a", "R_Hand_a", "R_UpperArm_a"],
	"L_Hand_a": ["L_Hand_a", "L_Forearm_a"],
	"R_Hand_a": ["R_Hand_a", "R_Forearm_a"],
	"L_UpperLeg_a": ["L_UpperLeg_a", "L_Foreleg_a", "L_Foot_a"],
	"R_UpperLeg_a": ["R_UpperLeg_a", "R_Foreleg_a", "R_Foot_a"],
	"L_Foreleg_a": ["L_Foreleg_a", "L_Foot_a", "L_UpperLeg_a"],
	"R_Foreleg_a": ["R_Foreleg_a", "R_Foot_a", "R_UpperLeg_a"],
	"L_Foot_a": ["L_Foot_a", "L_Foreleg_a"],
	"R_Foot_a": ["R_Foot_a", "R_Foreleg_a"],
}

const OMEGA := 16.0
const MAX_ANG := 0.38
const LIFE := 0.45

var skeleton: Skeleton3D
var _host: Node = null
## name -> {q: Quaternion, w: Vector3, t: float, amp: float}
var _jolt: Dictionary = {}
var last_bone: String = ""
var last_amp: float = 0.0
var last_zone: String = ""
var trigger_count: int = 0
## 空手捂住内脏受击点（分身；无新受击后约 2.2 秒收回）。
const COVER_LIFE := 2.2
var cover_point: Vector3 = Vector3.ZERO
var cover_life: float = 0.0
var cover_weight: float = 0.0
var last_cover: bool = false


func setup(skel: Skeleton3D, host: Node = null) -> bool:
	skeleton = skel
	_host = host
	_jolt.clear()
	return skeleton != null


func is_active() -> bool:
	return not _jolt.is_empty()


func peak_angle() -> float:
	var m := 0.0
	for rec in _jolt.values():
		var q: Quaternion = rec["q"]
		m = maxf(m, 2.0 * acos(clampf(absf(q.w), 0.0, 1.0)))
	return m


func clear() -> void:
	_jolt.clear()
	last_amp = 0.0
	last_bone = ""


func apply_from_info(info: Dictionary, amount: float = 20.0) -> void:
	if skeleton == null:
		return
	var dir: Vector3 = CombatDamage.vec3_of(info, ["dir"], Vector3.FORWARD)
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var bone := _bone_from_info(info)
	var zone := str(info.get("zone", CombatDamage.zone_from_bone(bone) if bone != "" else "body"))
	var strength := clampf((0.35 + amount / 50.0) * (1.15 if zone == "head" else 1.0), 0.2, 1.35)
	_start_jolt(bone, zone, dir, strength)
	last_bone = bone
	last_amp = strength
	last_zone = zone
	trigger_count += 1
	if _is_organ_hit(info) and _host_unarmed():
		var pt: Vector3 = CombatDamage.vec3_of(info, ["entry", "hit", "pos"], Vector3.ZERO)
		if pt == Vector3.ZERO:
			pt = _bone_world(bone)
		start_cover(pt)


func _bone_from_info(info: Dictionary) -> String:
	var col = info.get("collider")
	if col is PhysicalBone3D:
		var bn := str((col as PhysicalBone3D).bone_name)
		if bn != "":
			return bn
	var hit: Vector3 = CombatDamage.vec3_of(info, ["entry", "hit", "pos"], Vector3.ZERO)
	if hit != Vector3.ZERO and skeleton:
		var nearest := "C_Spine_c"
		var best := 0.35
		for n in ["C_Head_a", "C_Neck_a", "C_Spine_d", "C_Spine_c", "C_Spine_a", "C_Hip_a",
				"L_UpperArm_a", "R_UpperArm_a", "L_Forearm_a", "R_Forearm_a",
				"L_UpperLeg_a", "R_UpperLeg_a", "L_Foreleg_a", "R_Foreleg_a"]:
			var i := skeleton.find_bone(n)
			if i < 0:
				continue
			var p := (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin
			var d := p.distance_to(hit)
			if d < best:
				best = d
				nearest = n
		return nearest
	return "C_Spine_c"


func _start_jolt(bone: String, zone: String, dir: Vector3, strength: float) -> void:
	var names: Array = []
	if LIMB_OF.has(bone):
		names = LIMB_OF[bone]
	elif CHAIN.has(zone):
		names = CHAIN[zone]
	else:
		names = CHAIN["body"]
	if names.is_empty():
		names = ["C_Spine_c", "C_Spine_d"]
	# 始终带一点躯干反馈，四肢命中时身体也会晃一下。
	if zone == "limb":
		for n in ["C_Spine_c", "C_Hip_a"]:
			if not names.has(n):
				names.append(n)
	var i0 := 0
	for name in names:
		if SKIP_BONES.has(name):
			continue
		var bi := skeleton.find_bone(name) if skeleton else -1
		if bi < 0:
			continue
		var g := skeleton.global_transform * skeleton.get_bone_global_pose(bi)
		var axis := dir.cross(g.basis.y)
		if axis.length_squared() < 1e-8:
			axis = dir.cross(Vector3.RIGHT)
		if axis.length_squared() < 1e-8:
			axis = Vector3.FORWARD
		axis = (g.basis.inverse() * axis.normalized()).normalized()
		var fall := 1.0 if i0 == 0 else (0.62 if i0 == 1 else 0.38)
		i0 += 1
		var ang := clampf(strength * 0.42 * fall, 0.04, MAX_ANG)
		var add := Quaternion(axis, ang)
		var rec: Dictionary = _jolt.get(name, {"q": Quaternion.IDENTITY, "w": Vector3.ZERO, "t": LIFE, "amp": 0.0})
		rec["q"] = ((rec["q"] as Quaternion) * add).normalized()
		rec["t"] = LIFE
		rec["amp"] = maxf(float(rec["amp"]), ang)
		# 角速度让它先往外甩再回弹
		rec["w"] = axis * (ang * OMEGA * 0.85)
		_jolt[name] = rec


func apply_to_skeleton(delta: float, skip: PackedStringArray = PackedStringArray()) -> void:
	if skeleton == null or _jolt.is_empty():
		return
	var gone: PackedStringArray = PackedStringArray()
	for name in _jolt.keys():
		if SKIP_BONES.has(name) or skip.has(name):
			continue
		var bi := skeleton.find_bone(name)
		if bi < 0:
			gone.append(name)
			continue
		var rec: Dictionary = _jolt[name]
		var q: Quaternion = rec["q"]
		var w: Vector3 = rec["w"]
		var t: float = float(rec["t"]) - delta
		# 弹簧-阻尼：拉回单位四元数
		var ang := 2.0 * acos(clampf(absf(q.w), 0.0, 1.0))
		var axis := Vector3(q.x, q.y, q.z)
		if axis.length_squared() > 1e-10:
			axis = axis.normalized()
			# 把符号统一到最短路径
			if q.w < 0.0:
				axis = -axis
				ang = -ang
			w += -OMEGA * OMEGA * axis * ang * delta
			w *= exp(-2.0 * 0.86 * OMEGA * delta)
			var step := w.length() * delta
			if step > 1e-6:
				q = (Quaternion(w / maxf(w.length(), 1e-8), step) * q).normalized()
			else:
				q = q.slerp(Quaternion.IDENTITY, clampf(8.0 * delta, 0.0, 1.0))
		else:
			q = Quaternion.IDENTITY
			w = Vector3.ZERO
		rec["q"] = q
		rec["w"] = w
		rec["t"] = t
		_jolt[name] = rec
		# 叠在当前动画/IK 姿势之上
		var now := skeleton.get_bone_pose_rotation(bi)
		skeleton.set_bone_pose_rotation(bi, (now * q).normalized())
		if t <= 0.0 or (ang < 0.008 and w.length() < 0.15):
			gone.append(name)
	for n in gone:
		_jolt.erase(n)


func _is_organ_hit(info: Dictionary) -> bool:
	if bool(info.get("gut", false)) or bool(info.get("uterus", false)):
		return true
	var q = info.get("qinfo")
	if q is Dictionary and (bool(q.get("gut", false)) or bool(q.get("uterus", false))):
		return true
	return false


func _host_unarmed() -> bool:
	if _host == null:
		return true
	if _host.has_method("weapon_drawn"):
		return not bool(_host.call("weapon_drawn"))
	if _host.has_method("get_weapons"):
		var ws: Node = _host.call("get_weapons")
		if ws and ws.has_method("is_armed"):
			return not bool(ws.call("is_armed"))
	if _host.has_method("weapon_armed"):
		return not bool(_host.call("weapon_armed"))
	# 分身没有武器系统，视为空手。
	return true


func _bone_world(bone: String) -> Vector3:
	if skeleton == null:
		return Vector3.ZERO
	var i := skeleton.find_bone(bone if bone != "" else "C_Spine_c")
	if i < 0:
		i = skeleton.find_bone("C_Spine_c")
	if i >= 0:
		return (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin
	return skeleton.global_position


func start_cover(point: Vector3) -> void:
	if point == Vector3.ZERO or not point.is_finite():
		return
	if not _host_unarmed():
		return
	# 捂在受击处的皮肤表面，不要捂体内脏器点。
	cover_point = _skin_cover_point(point)
	cover_life = COVER_LIFE
	last_cover = true


func is_covering() -> bool:
	return cover_life > 0.0 and cover_weight > 0.05


func apply_cover(delta: float) -> void:
	if skeleton == null:
		return
	if not _host_unarmed():
		cover_life = 0.0
		cover_weight = 0.0
		last_cover = false
		return
	if cover_life > 0.0:
		cover_life = maxf(0.0, cover_life - delta)
	var want := 1.0 if cover_life > 0.25 else (cover_life / 0.25 if cover_life > 0.0 else 0.0)
	cover_weight = move_toward(cover_weight, want, delta * (6.0 if want > cover_weight else 3.2))
	if cover_weight <= 0.01:
		cover_weight = 0.0
		last_cover = cover_life > 0.0
		return
	# 自然捂腹：微微鞠躬，两手按在腹前皮肤上（不交叉、不反手），肘向外绕过肚子。不转锁骨。
	_cover_hunch(cover_weight)
	var skin := _skin_cover_point(cover_point)
	cover_point = skin
	_cover_arm("L", skin, cover_weight)
	_cover_arm("R", skin, cover_weight)
	last_cover = true


func _torso_frame() -> Dictionary:
	var sk := skeleton.global_transform
	var hip_i := skeleton.find_bone("C_Hip_a")
	var sp_i := skeleton.find_bone("C_Spine_c")
	var hip := sk.origin
	var up := Vector3.UP
	if hip_i >= 0:
		hip = (sk * skeleton.get_bone_global_pose(hip_i)).origin
	if sp_i >= 0:
		var sp: Vector3 = (sk * skeleton.get_bone_global_pose(sp_i)).origin
		up = (sp - hip).normalized() if sp.distance_to(hip) > 0.04 else Vector3.UP
	# 左右必须以左右肩的世界位置为准，不能单靠腹壁帧的 +X（轴反了就会双手交叉/反手）。
	var lsh_i := skeleton.find_bone("L_UpperArm_a")
	var rsh_i := skeleton.find_bone("R_UpperArm_a")
	var right := Vector3.RIGHT
	if lsh_i >= 0 and rsh_i >= 0:
		var lsh: Vector3 = (sk * skeleton.get_bone_global_pose(lsh_i)).origin
		var rsh: Vector3 = (sk * skeleton.get_bone_global_pose(rsh_i)).origin
		right = rsh - lsh
		right = right - up * right.dot(up)
	if right.length_squared() < 1e-6:
		var body := skeleton.get_parent()
		if body is Node3D:
			right = (body as Node3D).global_transform.basis.x
		right = right - up * right.dot(up)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	var fwd := up.cross(right)
	# 前向尽量与腹壁 +Z / 身体 +Z 同侧，手按在肚子前面。
	var hint := Vector3.ZERO
	if _host and _host.has_method("get_organs"):
		var org: Node = _host.call("get_organs")
		if org and org.has_method("abdomen_frame"):
			hint = (org.call("abdomen_frame") as Transform3D).basis.z
	if hint.length_squared() < 1e-8:
		var body2 := skeleton.get_parent()
		if body2 is Node3D:
			hint = (body2 as Node3D).global_transform.basis.z
	hint = hint - up * hint.dot(up)
	if fwd.length_squared() < 1e-8:
		fwd = hint if hint.length_squared() > 1e-8 else Vector3.FORWARD
	fwd = fwd.normalized()
	if hint.length_squared() > 1e-8 and fwd.dot(hint.normalized()) < 0.0:
		fwd = -fwd
		right = -right
	right = up.cross(fwd)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT
	right = right.normalized()
	fwd = right.cross(up).normalized()
	# 再核对一次：右肩应落在 +right 一侧。
	if lsh_i >= 0 and rsh_i >= 0:
		var l2: Vector3 = (sk * skeleton.get_bone_global_pose(lsh_i)).origin
		var r2: Vector3 = (sk * skeleton.get_bone_global_pose(rsh_i)).origin
		if (r2 - hip).dot(right) < (l2 - hip).dot(right):
			right = -right
			fwd = -fwd
			right = up.cross(fwd).normalized()
			fwd = right.cross(up).normalized()
	return {"hip": hip, "up": up, "fwd": fwd, "right": right}


func _skin_cover_point(point: Vector3) -> Vector3:
	# 优先用腹壁椭球把体内点投到前腹皮肤；没有脏器模块时退回到躯干前表面。
	if _host and _host.has_method("get_organs"):
		var org: Node = _host.call("get_organs")
		if org and org.has_method("project_skin"):
			var p = org.call("project_skin", point)
			if p is Vector3 and (p as Vector3).is_finite():
				return p
	return _front_of_torso(point, _torso_frame())


func _front_of_torso(target: Vector3, fr: Dictionary) -> Vector3:
	# 把受击点推到腹前皮肤，手按在肚子上而不是插进体内。
	var hip: Vector3 = fr["hip"]
	var fwd: Vector3 = fr["fwd"]
	var up: Vector3 = fr["up"]
	var right: Vector3 = fr["right"]
	var rel := target - hip
	var height := clampf(rel.dot(up), 0.16, 0.48)
	var side := clampf(rel.dot(right), -0.08, 0.08)
	# 腹前皮肤大约在髋骨前方 0.16–0.20m，再略向外免得陷进网格。
	var front := 0.19
	return hip + up * height + right * side + fwd * front


func _cover_hunch(w: float) -> void:
	# 轻微含胸前倾，参考捂肚子时的佝偻，不转锁骨。
	var fr := _torso_frame()
	var fwd: Vector3 = fr["fwd"]
	for rec in [["C_Spine_a", 0.10], ["C_Spine_c", 0.16], ["C_Spine_d", 0.07]]:
		var bi := skeleton.find_bone(str(rec[0]))
		if bi < 0:
			continue
		var rest := skeleton.get_bone_global_pose(bi)
		var origin := (skeleton.global_transform * rest).origin
		_aim_bone(bi, origin, origin + fwd * 0.2 - fr["up"] * 0.05, float(rec[1]) * w * 0.35)


func _cover_arm(side: String, target: Vector3, w: float) -> void:
	var ua_n := "%s_UpperArm_a" % side
	var fa_n := "%s_Forearm_a" % side
	var ha_n := "%s_Hand_a" % side
	var ua := skeleton.find_bone(ua_n)
	var fa := skeleton.find_bone(fa_n)
	var ha := skeleton.find_bone(ha_n)
	if ua < 0 or fa < 0 or ha < 0:
		return
	var sk := skeleton.global_transform
	var p0: Vector3 = (sk * skeleton.get_bone_global_pose(ua)).origin
	var p1: Vector3 = (sk * skeleton.get_bone_global_pose(fa)).origin
	var p2: Vector3 = (sk * skeleton.get_bone_global_pose(ha)).origin
	var l1 := p0.distance_to(p1)
	var l2 := p1.distance_to(p2)
	if l1 < 0.05 or l2 < 0.05:
		return
	var fr := _torso_frame()
	var fwd: Vector3 = fr["fwd"]
	var right: Vector3 = fr["right"]
	var up: Vector3 = fr["up"]
	var hip: Vector3 = fr["hip"]
	# 手按在受击皮肤两侧：左手明确在左、右手在右，中间留缝，互不交叉。
	var side_sign := -1.0 if side == "L" else 1.0
	var goal := _skin_cover_point(target)
	goal += right * (0.115 * side_sign)
	goal += up * (-0.024 if side == "L" else 0.022)
	goal += fwd * 0.020
	# 不允许手越过身体中线太多。
	var mid := _skin_cover_point(target)
	if (goal - mid).dot(right) * side_sign < 0.06:
		goal += right * side_sign * (0.06 - (goal - mid).dot(right) * side_sign)
	var span := l1 + l2 - 0.02
	if p0.distance_to(goal) > span:
		goal = p0 + (goal - p0).normalized() * span
	var want := goal
	var to_goal := want - p0
	var dist := clampf(to_goal.length(), 0.08, span)
	want = p0 + to_goal.normalized() * dist
	# 肘的自然位置：向自己一侧撑开、略向前、低于肩，绕过肚子而不是抄近道穿胸。
	var pole := (right * side_sign * 1.35 + fwd * 0.22 - up * 0.42)
	var elbow_pos := _solve_cover_elbow(p0, want, l1, l2, pole)
	var elbow_h_max := (want - hip).dot(up) + 0.08
	for _k in 4:
		var rel2 := elbow_pos - (hip + up * 0.16)
		var rad2 := rel2 - up * rel2.dot(up)
		var need := 0.34
		if rad2.length() < need:
			var push := (rad2.normalized() if rad2.length_squared() > 1e-6 else right * side_sign)
			if push.dot(right * side_sign) < 0.15:
				push = (push + right * side_sign).normalized()
			elbow_pos += push * (need - rad2.length())
			elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
		if (elbow_pos - hip).dot(fwd) < 0.08:
			elbow_pos += fwd * (0.08 - (elbow_pos - hip).dot(fwd))
			elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
		if (elbow_pos - hip).dot(right) * side_sign < 0.16:
			elbow_pos += right * side_sign * (0.16 - (elbow_pos - hip).dot(right) * side_sign)
			elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
		var eh := (elbow_pos - hip).dot(up)
		if eh > elbow_h_max:
			elbow_pos -= up * (eh - elbow_h_max)
			elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
	# t27u：按解剖肘关节铰链摆臂。旧做法用「肘平面法线」决定上臂滚转，右臂法线符号反了，
	# 肘关节向后反折。现在从 rest 姿势求出「屈肘时前臂朝身体前方转」的铰链轴，
	# 让上臂的铰链轴对准 (上臂方向 × 前臂方向)，屈肘方向永远是自然方向。
	_pose_cover_arm_hinged(ua, fa, side, p0, elbow_pos, want, fwd, w)
	_set_cover_hand(ha, side, want, fwd, right, up, w)
	_share_forearm_twist(fa, ha, w)


func _rest_forward_s(fwd_world: Vector3) -> Vector3:
	## rest 姿势下身体前向（骨架空间），符号与当前身体前向一致。
	var lu := skeleton.find_bone("L_UpperArm_a")
	var ru := skeleton.find_bone("R_UpperArm_a")
	var hp := skeleton.find_bone("C_Hip_a")
	var sp := skeleton.find_bone("C_Spine_c")
	var fs := (skeleton.global_transform.basis.inverse() * fwd_world).normalized()
	if lu < 0 or ru < 0 or hp < 0 or sp < 0:
		return fs
	var r := skeleton.get_bone_global_rest(ru).origin - skeleton.get_bone_global_rest(lu).origin
	var u := skeleton.get_bone_global_rest(sp).origin - skeleton.get_bone_global_rest(hp).origin
	var f := u.cross(r)
	if f.length_squared() < 1e-8:
		return fs
	f = f.normalized()
	return f if f.dot(fs) >= 0.0 else -f


func _elbow_hinge_local(ua: int, fa: int, fwd_world: Vector3) -> Vector3:
	## 上臂局部坐标下的屈肘铰链轴：绕它正向旋转 = 前臂朝身体前方屈曲。
	var ua_rest := skeleton.get_bone_global_rest(ua)
	var arm := skeleton.get_bone_global_rest(fa).origin - ua_rest.origin
	var h := arm.normalized().cross(_rest_forward_s(fwd_world))
	if h.length_squared() < 1e-8:
		return Vector3.RIGHT
	return (ua_rest.basis.orthonormalized().inverse() * h).normalized()


func _pose_cover_arm_hinged(ua: int, fa: int, side: String, p0: Vector3, elbow: Vector3, want: Vector3, fwd: Vector3, w: float) -> void:
	var sk_inv := skeleton.global_transform.affine_inverse()
	var U := (sk_inv.basis * (elbow - p0)).normalized()
	var V := (sk_inv.basis * (want - elbow)).normalized()
	if not U.is_finite() or not V.is_finite() or U.length_squared() < 0.5:
		return
	var a_loc := skeleton.get_bone_rest(fa).origin.normalized()
	var h_loc := _elbow_hinge_local(ua, fa, fwd)
	h_loc = (h_loc - a_loc * h_loc.dot(a_loc)).normalized()
	var h_s := U.cross(V)
	if h_s.length_squared() < 1e-6:
		# 几乎伸直：保持当前铰链朝向
		h_s = skeleton.get_bone_global_pose(ua).basis.orthonormalized() * h_loc
	h_s = (h_s - U * h_s.dot(U)).normalized()
	var Lm := Basis(a_loc, h_loc, a_loc.cross(h_loc)).orthonormalized()
	var Wm := Basis(U, h_s, U.cross(h_s)).orthonormalized()
	var B := (Wm * Lm.inverse()).orthonormalized()
	var par := skeleton.get_bone_parent(ua)
	var par_b := skeleton.get_bone_global_pose(par).basis.orthonormalized() if par >= 0 else Basis.IDENTITY
	var q := (par_b.inverse() * B).get_rotation_quaternion()
	if w < 0.999:
		q = skeleton.get_bone_pose_rotation(ua).slerp(q, clampf(w, 0.0, 1.0))
	skeleton.set_bone_pose_rotation(ua, q)
	# 前臂：在上臂 rest 关系上绕铰链转出屈肘角，再做一次很小的残差校正。
	var Bn := skeleton.get_bone_global_pose(ua).basis.orthonormalized()
	var fa_rest_rel := skeleton.get_bone_rest(fa).basis.orthonormalized()
	var ha_i := skeleton.find_bone("%s_Hand_a" % side)
	var c_loc := skeleton.get_bone_rest(ha_i).origin.normalized() if ha_i >= 0 else Vector3.UP
	var F := Bn * fa_rest_rel
	var cur := (F * c_loc).normalized()
	var hinge_now := (Bn * h_loc).normalized()
	# 绕铰链把前臂从当前方向转到目标方向（屈曲为正）
	var cur_p := (cur - hinge_now * cur.dot(hinge_now)).normalized()
	var V_p := (V - hinge_now * V.dot(hinge_now)).normalized()
	var ang := atan2(cur_p.cross(V_p).dot(hinge_now), cur_p.dot(V_p))
	F = Basis(hinge_now, ang) * F
	var cur2 := (F * c_loc).normalized()
	if cur2.dot(V) < 0.99999:
		F = Basis(Quaternion(cur2, V)) * F
	var qf := (Bn.inverse() * F.orthonormalized()).get_rotation_quaternion()
	if w < 0.999:
		qf = skeleton.get_bone_pose_rotation(fa).slerp(qf, clampf(w, 0.0, 1.0))
	skeleton.set_bone_pose_rotation(fa, qf)


func _share_forearm_twist(fa: int, ha: int, w: float) -> void:
	## 手掌朝向所需的绕前臂轴扭转分一半给前臂，避免手腕拧成麻花。
	if fa < 0 or ha < 0 or w <= 0.0:
		return
	var ax := skeleton.get_bone_rest(ha).origin.normalized()
	var hq := skeleton.get_bone_pose_rotation(ha)
	var proj := Vector3(hq.x, hq.y, hq.z).project(ax)
	var tw := Quaternion(proj.x, proj.y, proj.z, hq.w).normalized()
	var half := Quaternion.IDENTITY.slerp(tw, 0.5)
	skeleton.set_bone_pose_rotation(fa, skeleton.get_bone_pose_rotation(fa) * half)
	skeleton.set_bone_pose_rotation(ha, (half.inverse() * hq).normalized())


## 测试：肘关节是否按自然方向屈曲（>0 自然，<0 反折），以及掌心是否朝向皮肤。
func cover_joint_debug() -> Dictionary:
	var out := {}
	if skeleton == null:
		return out
	var fr := _torso_frame()
	var fwd: Vector3 = fr["fwd"]
	var skx := skeleton.global_transform
	var skin := _skin_cover_point(cover_point) if cover_point != Vector3.ZERO else Vector3.ZERO
	for side in ["L", "R"]:
		var ua := skeleton.find_bone("%s_UpperArm_a" % side)
		var fa := skeleton.find_bone("%s_Forearm_a" % side)
		var ha := skeleton.find_bone("%s_Hand_a" % side)
		var mi := skeleton.find_bone("%s_Middle_a" % side)
		var ii := skeleton.find_bone("%s_Index_a" % side)
		var pi := skeleton.find_bone("%s_Pinky_a" % side)
		if ua < 0 or fa < 0 or ha < 0 or mi < 0 or ii < 0 or pi < 0:
			continue
		var p0 := skx * skeleton.get_bone_global_pose(ua).origin
		var p1 := skx * skeleton.get_bone_global_pose(fa).origin
		var p2 := skx * skeleton.get_bone_global_pose(ha).origin
		var U := (p1 - p0).normalized()
		var V := (p2 - p1).normalized()
		var h_now := skx.basis * (skeleton.get_bone_global_pose(ua).basis.orthonormalized() * _elbow_hinge_local(ua, fa, fwd))
		out[side + "_flex_deg"] = rad_to_deg(U.angle_to(V))
		out[side + "_hinge"] = U.cross(V).normalized().dot(h_now.normalized()) if U.cross(V).length() > 1e-4 else 1.0
		var f: Vector3 = skeleton.get_bone_global_pose(mi).origin - skeleton.get_bone_global_pose(ha).origin
		var tt: Vector3 = skeleton.get_bone_global_pose(ii).origin - skeleton.get_bone_global_pose(pi).origin
		var n := (skx.basis * f.cross(tt)).normalized()
		var palm := n if side == "L" else -n
		out[side + "_palm_in"] = palm.dot(-fwd)
		var pc := (p2 + skx * skeleton.get_bone_global_pose(mi).origin) * 0.5
		out[side + "_palm_to_skin"] = palm.dot((skin - pc).normalized()) if skin != Vector3.ZERO else 0.0
		out[side + "_palm_center"] = pc
	return out


func _solve_cover_elbow(p0: Vector3, want: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var to := want - p0
	var dist := clampf(to.length(), 0.08, l1 + l2 - 0.02)
	var dir := (want - p0)
	if dir.length_squared() < 1e-10:
		dir = pole if pole.length_squared() > 1e-10 else Vector3.RIGHT
	dir = dir.normalized()
	var x := clampf((dist * dist + l1 * l1 - l2 * l2) / maxf(2.0 * dist * l1, 1e-5), -1.0, 1.0)
	var elbow_ang := acos(x)
	var along := p0 + dir * (cos(elbow_ang) * l1)
	var nrm := dir.cross(pole)
	if nrm.length_squared() < 1e-8:
		nrm = dir.cross(Vector3.UP)
	if nrm.length_squared() < 1e-8:
		nrm = Vector3.RIGHT
	# pole 落在 dir 的垂直平面上的分量，指向撑开一侧。
	var lateral := pole - dir * pole.dot(dir)
	if lateral.length_squared() < 1e-8:
		lateral = nrm.cross(dir)
	lateral = lateral.normalized()
	return along + lateral * sin(elbow_ang) * l1


func cover_debug() -> Dictionary:
	# 测试用：双手、两肘与受击点的世界坐标，以及前臂是否明显穿过躯干圆柱。
	var fr := _torso_frame() if skeleton else {"hip": Vector3.ZERO, "up": Vector3.UP, "fwd": Vector3.FORWARD, "right": Vector3.RIGHT}
	var skin := _skin_cover_point(cover_point) if cover_point != Vector3.ZERO and skeleton else cover_point
	var out := {"point": cover_point, "skin": skin, "weight": cover_weight, "hip": fr["hip"], "fwd": fr["fwd"], "right": fr["right"]}
	var sk := skeleton.global_transform if skeleton else Transform3D.IDENTITY
	for side in ["L", "R"]:
		var fa := skeleton.find_bone("%s_Forearm_a" % side) if skeleton else -1
		var ha := skeleton.find_bone("%s_Hand_a" % side) if skeleton else -1
		var elbow := Vector3.ZERO
		var hand := Vector3.ZERO
		if fa >= 0:
			elbow = (sk * skeleton.get_bone_global_pose(fa)).origin
		if ha >= 0:
			hand = (sk * skeleton.get_bone_global_pose(ha)).origin
		out[side + "_elbow"] = elbow
		out[side + "_hand"] = hand
		out[side + "_hand_dist"] = hand.distance_to(cover_point) if cover_point != Vector3.ZERO else 0.0
		out[side + "_arm_through"] = _segment_hits_torso(elbow, hand, fr, 0.12)
		out[side + "_skin_dist"] = hand.distance_to(skin) if skin != Vector3.ZERO else 0.0
	var lh: Vector3 = out.get("L_hand", Vector3.ZERO)
	var rh: Vector3 = out.get("R_hand", Vector3.ZERO)
	var rightv: Vector3 = fr["right"]
	var hip: Vector3 = fr["hip"]
	# 左手应在右手的左侧（允许轻微交叠），明显跑到对侧就算交叉/反手。
	var lside := (lh - hip).dot(rightv)
	var rside := (rh - hip).dot(rightv)
	out["L_side"] = lside
	out["R_side"] = rside
	out["hands_crossed"] = lside > rside + 0.04
	return out


func _segment_hits_torso(a: Vector3, b: Vector3, fr: Dictionary, _radius: float) -> bool:
	# 前臂绕腹前是正常的；只有中段明显钻进躯干内部或绕到背后，才算穿模。
	var hip: Vector3 = fr["hip"]
	var up: Vector3 = fr["up"]
	var fwd: Vector3 = fr["fwd"]
	# 在前臂上取几个点，避开靠近手掌（本来就按在腹面）的一端。
	for s in [0.35, 0.5, 0.65]:
		var p: Vector3 = a.lerp(b, s)
		var rel := p - (hip + up * 0.28)
		var along := rel.dot(up)
		if along < 0.0 or along > 0.55:
			continue
		var radial := rel - up * along
		var depth := radial.dot(fwd)
		# 钻进腹柱中心，或跑到背后穿过身体。
		if radial.length() < 0.10 or (depth < -0.01 and radial.length() < 0.18):
			return true
	return false


func _set_bone_y_roll(bi: int, want_y_world: Vector3, roll_world: Vector3, w: float) -> void:
	# 骨骼 +Y 对准子骨方向，并用肘平面法线固定滚转，防止最短路径把网格拧翻。
	if skeleton == null or bi < 0 or w <= 0.0 or want_y_world.length_squared() < 1e-10:
		return
	var sk_inv := skeleton.global_transform.affine_inverse()
	var y := (sk_inv.basis * want_y_world)
	if y.length_squared() < 1e-10:
		return
	y = y.normalized()
	var hint := sk_inv.basis * roll_world
	var z := y.cross(hint)
	if z.length_squared() < 1e-8:
		var g0 := skeleton.get_bone_global_pose(bi)
		z = y.cross(g0.basis.x)
		if z.length_squared() < 1e-8:
			z = y.cross(Vector3.RIGHT)
	z = z.normalized()
	var x := y.cross(z)
	if x.length_squared() < 1e-8:
		return
	x = x.normalized()
	z = x.cross(y).normalized()
	var new_b := Basis(x, y, z).orthonormalized()
	if new_b.determinant() < 0.0:
		new_b = Basis(-x, y, z).orthonormalized()
	var par := skeleton.get_bone_parent(bi)
	var par_b := Basis.IDENTITY
	if par >= 0:
		par_b = skeleton.get_bone_global_pose(par).basis.orthonormalized()
	var q := (par_b.inverse() * new_b).get_rotation_quaternion()
	if w < 0.999:
		q = skeleton.get_bone_pose_rotation(bi).slerp(q, clampf(w, 0.0, 1.0))
	skeleton.set_bone_pose_rotation(bi, q)


func _hand_sem_local(side: String) -> Basis:
	var ha := skeleton.find_bone("%s_Hand_a" % side)
	var mid := skeleton.find_bone("%s_Middle_a" % side)
	var idx := skeleton.find_bone("%s_Index_a" % side)
	var pnk := skeleton.find_bone("%s_Pinky_a" % side)
	if ha < 0 or mid < 0 or idx < 0 or pnk < 0:
		return Basis.IDENTITY
	var hand_rest := skeleton.get_bone_global_rest(ha)
	var f: Vector3 = skeleton.get_bone_global_rest(mid).origin - hand_rest.origin
	var t: Vector3 = skeleton.get_bone_global_rest(idx).origin - skeleton.get_bone_global_rest(pnk).origin
	if f.length_squared() < 1e-10 or t.length_squared() < 1e-10:
		return Basis.IDENTITY
	var n := f.cross(t)
	if n.length_squared() < 1e-10:
		return Basis.IDENTITY
	n = n.normalized()
	var fh := f.normalized()
	var sem := Basis(fh, n.cross(fh), n).orthonormalized()
	return hand_rest.basis.orthonormalized().inverse() * sem


func _set_cover_hand(ha: int, side: String, want: Vector3, fwd: Vector3, right: Vector3, up: Vector3, w: float) -> void:
	# 掌心按在腹壁上（SEM +Z 指向体内），手指略向内向下收，不要反手或交叉。
	if ha < 0 or w <= 0.0:
		return
	var side_sign := -1.0 if side == "L" else 1.0
	var palm := -fwd + up * 0.08
	if palm.length_squared() < 1e-8:
		palm = -fwd
	palm = palm.normalized()
	var fingers := -right * side_sign * 0.72 - up * 0.42 + fwd * 0.12
	fingers = (fingers - palm * fingers.dot(palm))
	if fingers.length_squared() < 1e-8:
		fingers = -up
	fingers = fingers.normalized()
	# 手的语义 Z（指根×拇指方向）：左手 = 掌心方向，右手 = 手背方向（镜像）。
	# 旧代码两只手都把 Z 当掌心，右手因此用手背捂肚子。
	var sem_z := palm if side == "L" else -palm
	var sem_w := Basis(fingers, sem_z.cross(fingers), sem_z).orthonormalized()
	# SEM 在骨架空间写入手骨
	var sk_inv := skeleton.global_transform.affine_inverse()
	var sem_s := (sk_inv.basis * sem_w).orthonormalized()
	var hand_g := (sem_s * _hand_sem_local(side).inverse()).orthonormalized()
	var par := skeleton.get_bone_parent(ha)
	var par_b := Basis.IDENTITY
	if par >= 0:
		par_b = skeleton.get_bone_global_pose(par).basis.orthonormalized()
	var q := (par_b.inverse() * hand_g).get_rotation_quaternion()
	if w < 0.999:
		q = skeleton.get_bone_pose_rotation(ha).slerp(q, clampf(w, 0.0, 1.0))
	skeleton.set_bone_pose_rotation(ha, q)


func _aim_bone(bi: int, from: Vector3, to: Vector3, w: float) -> void:
	# 把该骨指向子骨的轴转到 from→to，并在父骨空间写入 pose，避免把世界旋转错乘进局部。
	if skeleton == null or bi < 0 or w <= 0.0 or from.distance_to(to) < 1e-5:
		return
	var ch := skeleton.get_bone_children(bi)
	var g := skeleton.get_bone_global_pose(bi)
	var local_dir := Vector3.UP
	if ch.size() > 0:
		var coff: Vector3 = g.affine_inverse() * skeleton.get_bone_global_pose(ch[0]).origin
		if coff.length_squared() > 1e-8:
			local_dir = coff.normalized()
	var gb := g.basis.orthonormalized()
	var cur := (gb * local_dir).normalized()
	var want_s: Vector3 = skeleton.global_transform.affine_inverse().basis * (to - from)
	if want_s.length_squared() < 1e-10:
		return
	want_s = want_s.normalized()
	if cur.dot(want_s) > 0.9999:
		return
	var rot := Quaternion(cur, want_s)
	if w < 0.999:
		rot = Quaternion.IDENTITY.slerp(rot, clampf(w, 0.0, 1.0))
	var new_b := (Basis(rot) * gb).orthonormalized()
	var par := skeleton.get_bone_parent(bi)
	var par_b := Basis.IDENTITY
	if par >= 0:
		par_b = skeleton.get_bone_global_pose(par).basis.orthonormalized()
	skeleton.set_bone_pose_rotation(bi, (par_b.inverse() * new_b).get_rotation_quaternion())
