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
