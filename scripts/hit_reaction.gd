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
	var dir: Vector3 = info.get("dir", Vector3.FORWARD)
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
		var pt: Vector3 = info.get("entry", info.get("hit", info.get("pos", Vector3.ZERO)))
		if pt == Vector3.ZERO:
			pt = _bone_world(bone)
		start_cover(pt)


func _bone_from_info(info: Dictionary) -> String:
	var col = info.get("collider")
	if col is PhysicalBone3D:
		var bn := str((col as PhysicalBone3D).bone_name)
		if bn != "":
			return bn
	var hit: Vector3 = info.get("entry", info.get("hit", info.get("pos", Vector3.ZERO)))
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
	if point == Vector3.ZERO:
		return
	if not _host_unarmed():
		return
	cover_point = point
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
	# 自然捂腹：微微鞠躬，两手叠在伤口前方，肘向外略向前绕过肚子，不穿躯干。不转锁骨。
	_cover_hunch(cover_weight)
	_cover_arm("L", cover_point, cover_weight)
	_cover_arm("R", cover_point, cover_weight)
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
	var fwd := Vector3.FORWARD
	var body := skeleton.get_parent()
	if body is Node3D:
		# 网格朝向为 Body +Z
		fwd = (body as Node3D).global_transform.basis.z
		fwd = (fwd - up * fwd.dot(up))
		if fwd.length_squared() < 1e-6:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
	var right := up.cross(fwd)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	fwd = right.cross(up).normalized()
	return {"hip": hip, "up": up, "fwd": fwd, "right": right}


func _front_of_torso(target: Vector3, fr: Dictionary) -> Vector3:
	# 把受击点推到腹前表面，手按在肚子上而不是插进体内。
	var hip: Vector3 = fr["hip"]
	var fwd: Vector3 = fr["fwd"]
	var up: Vector3 = fr["up"]
	var rel := target - hip
	var height := clampf(rel.dot(up), 0.15, 0.55)
	var depth := rel.dot(fwd)
	# 腹前大约在躯干中心前方 0.13–0.16m
	var front := 0.15
	if depth < front:
		target = target + fwd * (front - depth)
	# 高度不够时按在小腹
	var want_h := hip + up * height + fwd * maxf(depth, front)
	return want_h


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
	var goal := _front_of_torso(target, fr)
	# 双手叠按：左手略偏左、右手叠在上面略偏右，掌心向内。
	var side_sign := -1.0 if side == "L" else 1.0
	goal += right * (0.035 * side_sign)
	goal += up * (0.0 if side == "L" else 0.03)
	goal += fwd * 0.01
	var span := l1 + l2 - 0.02
	if p0.distance_to(goal) > span:
		goal = p0 + (goal - p0).normalized() * span
	# 肘在体侧略向前，绕过肚子，不要走躯干内部的捷径。
	var mid := (p0 + goal) * 0.5
	var elbow_hint: Vector3 = mid + right * (0.32 * side_sign) + fwd * 0.18 - up * 0.05
	# 保证肘在躯干圆柱外、略向前
	var hip: Vector3 = fr["hip"]
	var rel_e := elbow_hint - hip
	var radial := rel_e - up * rel_e.dot(up)
	if radial.length() < 0.28:
		elbow_hint += (radial.normalized() if radial.length_squared() > 1e-6 else right * side_sign) * (0.28 - radial.length())
	if (elbow_hint - hip).dot(fwd) < 0.08:
		elbow_hint += fwd * (0.08 - (elbow_hint - hip).dot(fwd))
	# 解析两骨：肩到肘、肘到手，保持骨长
	var d_el := elbow_hint - p0
	if d_el.length_squared() < 1e-6:
		d_el = right * side_sign
	elbow_hint = p0 + d_el.normalized() * l1
	var d_h := goal - elbow_hint
	if d_h.length_squared() < 1e-6:
		d_h = fwd
	# 若手目标与肘距离不等于前臂长，把肘在「外侧+前方」平面上再微调
	var want := goal
	var to_goal := want - p0
	var dist := clampf(to_goal.length(), 0.06, span)
	want = p0 + to_goal.normalized() * dist
	var dir := (want - p0).normalized()
	var x := clampf((dist * dist + l1 * l1 - l2 * l2) / (2.0 * dist * l1), -1.0, 1.0)
	var elbow_ang := acos(x)
	var along := p0 + dir * (cos(elbow_ang) * l1)
	var pole := (right * side_sign + fwd * 0.55).normalized()
	var nrm := dir.cross(pole)
	if nrm.length_squared() < 1e-8:
		nrm = (right * side_sign).cross(dir)
	if nrm.length_squared() < 1e-8:
		nrm = Vector3.RIGHT
	nrm = nrm.normalized()
	# 让肘落在体外侧、略向前的那一侧
	if nrm.dot(right * side_sign + fwd * 0.3) < 0.0:
		nrm = -nrm
	var elbow_pos := along + nrm * sin(elbow_ang) * l1
	# 再向外推一次，防止前臂弦穿过躯干
	var rel2 := elbow_pos - hip
	var rad2 := rel2 - up * rel2.dot(up)
	if rad2.length() < 0.26:
		elbow_pos += (rad2.normalized() if rad2.length_squared() > 1e-6 else right * side_sign) * (0.26 - rad2.length())
		elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
	if (elbow_pos - hip).dot(fwd) < 0.06:
		elbow_pos += fwd * (0.06 - (elbow_pos - hip).dot(fwd))
		elbow_pos = p0 + (elbow_pos - p0).normalized() * l1
	_aim_bone(ua, p0, elbow_pos, w)
	_aim_bone(fa, elbow_pos, want, w)


func cover_debug() -> Dictionary:
	# 测试用：双手、两肘与受击点的世界坐标，以及前臂是否明显穿过躯干圆柱。
	var fr := _torso_frame() if skeleton else {"hip": Vector3.ZERO, "up": Vector3.UP, "fwd": Vector3.FORWARD, "right": Vector3.RIGHT}
	var out := {"point": cover_point, "weight": cover_weight, "hip": fr["hip"], "fwd": fr["fwd"]}
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
		if radial.length() < 0.09 or (depth < -0.02 and radial.length() < 0.16):
			return true
	return false


func _aim_bone(bi: int, from: Vector3, to: Vector3, w: float) -> void:
	if bi < 0 or from.distance_to(to) < 1e-5:
		return
	var rest := skeleton.get_bone_global_pose(bi)
	# 骨骼自身 +Y 大致指向子骨（Mixamo / 蒂法骨架）。把 +Y 转向目标。
	var cur_y := (skeleton.global_transform.basis * rest.basis.y).normalized()
	var want := (to - from).normalized()
	var axis := cur_y.cross(want)
	if axis.length_squared() < 1e-8:
		return
	axis = axis.normalized()
	# 转到骨骼局部
	var local_axis := (skeleton.global_transform * rest).basis.inverse() * axis
	if local_axis.length_squared() < 1e-8:
		return
	local_axis = local_axis.normalized()
	var ang := cur_y.angle_to(want) * w
	var q := Quaternion(local_axis, ang)
	var now := skeleton.get_bone_pose_rotation(bi)
	skeleton.set_bone_pose_rotation(bi, (now * q).normalized())
