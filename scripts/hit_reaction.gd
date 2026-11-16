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
	# 两只手捂向最近一次内脏受击点；不旋转锁骨，避免肩臂拧坏。
	_cover_arm("L", cover_point, cover_weight)
	_cover_arm("R", cover_point, cover_weight)
	last_cover = true


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
	# 左右手略分开放在伤口两侧，掌心朝身体。
	var off := Vector3(-0.04, 0.01, 0.0) if side == "L" else Vector3(0.04, 0.01, 0.0)
	var goal := target + off
	var span := l1 + l2 - 0.02
	if p0.distance_to(goal) > span:
		goal = p0 + (goal - p0).normalized() * span
	var dist := clampf(p0.distance_to(goal), 0.06, span)
	# 解析两骨 IK
	var dir := (goal - p0).normalized()
	var x := clampf((dist * dist + l1 * l1 - l2 * l2) / (2.0 * dist * l1), -1.0, 1.0)
	var elbow_ang := acos(x)
	var mid := p0 + dir * (cos(elbow_ang) * l1)
	var pole := Vector3.FORWARD
	if skeleton.get_parent() is Node3D:
		pole = -(skeleton.get_parent() as Node3D).global_transform.basis.z
	if absf(dir.dot(pole)) > 0.92:
		pole = Vector3.RIGHT
	var nrm := dir.cross(pole)
	if nrm.length_squared() < 1e-8:
		nrm = Vector3.RIGHT
	nrm = nrm.normalized()
	# 肘向外弯
	var elbow_sign := -1.0 if side == "L" else 1.0
	var elbow_pos := mid + nrm * sin(elbow_ang) * l1 * 0.85 * elbow_sign
	_aim_bone(ua, p0, elbow_pos, w)
	_aim_bone(fa, elbow_pos, goal, w)


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
