extends Node
## Drive Skeleton3D from web loco-clips.json (same pick/sample/apply as soft-skeleton.ts).
class_name SoftLoco

const CLIPS_PATH := "res://assets/characters/tifa/loco-clips.json"
const LOCO_BONES: PackedStringArray = [
	"C_Hip_a", "C_Spine_a", "C_Spine_b", "C_Spine_c", "C_Spine_d", "C_Neck_a",
	"L_UpperLeg_a", "R_UpperLeg_a", "L_Foreleg_a", "R_Foreleg_a", "L_Foot_a", "R_Foot_a",
	"L_Shoulder_a", "R_Shoulder_a", "L_UpperArm_a", "R_UpperArm_a",
	"L_Forearm_a", "R_Forearm_a", "L_Hand_a", "R_Hand_a",
]

const STAND_IDLE_MOTION := 0.18
const CROUCH_ARM_MOTION := 0.3
## User-requested 0.5s recover from last evaluated pose (web LOCO_STOP_DUR is 0.7).
const LOCO_STOP_DUR := 0.5
const CLIP_BLEND_DUR := 0.5

var skeleton: Skeleton3D
static var _clips_cache: Dictionary = {}
var clips: Dictionary = {} # name -> {dur,n,hipY,bones,stride,fmt}
var bone_idx: Dictionary = {} # name -> int
var rest_local_q: Dictionary = {} # name -> Quaternion
var rest_world_q: Dictionary = {} # name -> Quaternion (bind)
var rest_origin: Dictionary = {} # name -> Vector3
var rest_scale: Dictionary = {} # name -> Vector3
var rest_pos: Dictionary = {} # name -> Vector3 (bind world origin, soft-rig space)

var mode: String = "stand" # stand | crouch | prone
var phase: float = 0.0
var was_air: bool = false
var current_clip: String = "standIdle"
var dance_override: String = "" # dance1..dance8 while set
var breath_t: float = 0.0
var breath_in: float = 0.0
var breath_chest: float = 0.0
var breath_enabled: bool = false  # SoftSecondary owns breath now

var secondary: RefCounted = null  # SoftSecondary
var frozen: bool = false  # 死亡布娃娃期间停止写骨骼姿势

var loco_was_moving: bool = false
var loco_settle: float = 1.0
var clip_blend: float = 1.0
var hold_q: Dictionary = {}
var hold_hip_y: float = 0.0
var last_soft_q: Dictionary = {}
var last_hip_y: float = 0.0
var last_clip_name: String = ""
## 武器 IK 生效时不要再用走跑动画覆盖手臂 / 肩骨，避免开镜移动时手穿枪。
var weapon_ik: bool = false

var _qa := Quaternion.IDENTITY
var _qb := Quaternion.IDENTITY

const SoftSecondaryScript = preload("res://scripts/soft_secondary.gd")


func setup(skel: Skeleton3D) -> bool:
	skeleton = skel
	if skeleton == null:
		push_error("SoftLoco: no skeleton")
		return false
	# 动画 JSON 只解析一次（本体 + 分身共用，只读）
	if _clips_cache.is_empty():
		var f := FileAccess.open(CLIPS_PATH, FileAccess.READ)
		if f == null:
			push_error("SoftLoco: cannot open %s" % CLIPS_PATH)
			return false
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("clips"):
			push_error("SoftLoco: bad clips JSON")
			return false
		_clips_cache = parsed["clips"]
	clips = _clips_cache
	bone_idx.clear()
	rest_local_q.clear()
	rest_world_q.clear()
	rest_origin.clear()
	rest_scale.clear()
	rest_pos.clear()
	# Cache rest local + rest-world for every bone (parents of loco bones may be non-loco).
	var n := skeleton.get_bone_count()
	var world_by_idx: Array = []
	world_by_idx.resize(n)
	var world_xf: Array = []
	world_xf.resize(n)
	for i in n:
		var rest := skeleton.get_bone_rest(i)
		var pname := skeleton.get_bone_name(i)
		rest_local_q[pname] = rest.basis.get_rotation_quaternion()
		rest_origin[pname] = rest.origin
		rest_scale[pname] = rest.basis.get_scale()
		var parent := skeleton.get_bone_parent(i)
		if parent < 0:
			world_by_idx[i] = rest.basis.get_rotation_quaternion()
			world_xf[i] = rest
		else:
			world_by_idx[i] = world_by_idx[parent] * rest.basis.get_rotation_quaternion()
			world_xf[i] = world_xf[parent] * rest
		rest_world_q[pname] = world_by_idx[i]
		rest_pos[pname] = (world_xf[i] as Transform3D).origin
	for name in LOCO_BONES:
		var i := skeleton.find_bone(name)
		if i >= 0:
			bone_idx[name] = i
	print("SoftLoco: loaded %d clips, mapped %d/%d loco bones" % [clips.size(), bone_idx.size(), LOCO_BONES.size()])
	secondary = SoftSecondaryScript.new()
	if secondary.setup(skeleton):
		print("SoftLoco: SoftSecondary attached")
	else:
		push_warning("SoftLoco: SoftSecondary.setup failed")
		secondary = null
	return true


func set_mode(m: String) -> void:
	if m == "stand" or m == "crouch" or m == "prone":
		mode = m


func set_dance(clip_name: String) -> void:
	dance_override = clip_name


func clear_dance() -> void:
	dance_override = ""


func pick_clip(fwd: float, side: float, mag: float, airborne: bool, sprint: bool) -> String:
	if dance_override != "" and clips.has(dance_override):
		return dance_override
	if airborne:
		return "jump"
	var moving := mag > 0.07
	var af := absf(fwd)
	var as_ := absf(side)
	if mode == "prone":
		return "proneWalk" if moving else "proneIdle"
	if mode == "crouch":
		if not moving:
			return "crouchIdle"
		if af >= as_:
			return "crouchWalk" if fwd >= 0.0 else "crouchBack"
		return "crouchRight" if side >= 0.0 else "crouchLeft"
	if not moving:
		return "standIdle"
	var run := sprint and clips.has("run")
	if af >= as_:
		if fwd >= 0.0:
			return "run" if run else "walk"
		return "runBack" if run and clips.has("runBack") else "walkBack"
	if run:
		if side >= 0.0:
			return "runRight" if clips.has("runRight") else "walkRight"
		return "runLeft" if clips.has("runLeft") else "walkLeft"
	return "walkRight" if side >= 0.0 else "walkLeft"


func _quat_from_euler_xyz(ex: float, ey: float, ez: float) -> Quaternion:
	# Match THREE.Euler order "XYZ" → Quaternion (same formulas as Three.js).
	var c1 := cos(ex * 0.5)
	var c2 := cos(ey * 0.5)
	var c3 := cos(ez * 0.5)
	var s1 := sin(ex * 0.5)
	var s2 := sin(ey * 0.5)
	var s3 := sin(ez * 0.5)
	return Quaternion(
		s1 * c2 * c3 + c1 * s2 * s3,
		c1 * s2 * c3 - s1 * c2 * s3,
		c1 * c2 * s3 + s1 * s2 * c3,
		c1 * c2 * c3 - s1 * s2 * s3
	)


func _frame_to_quat(frame: Array) -> Quaternion:
	if frame.size() >= 4:
		return Quaternion(float(frame[0]), float(frame[1]), float(frame[2]), float(frame[3])).normalized()
	return _quat_from_euler_xyz(float(frame[0]), float(frame[1]), float(frame[2]))


func sample_clip(clip: Dictionary, u: float, loop: bool) -> Dictionary:
	var n: int = int(clip["n"])
	var wrapped: float
	if loop:
		wrapped = fposmod(u, 1.0)
	else:
		wrapped = clampf(u, 0.0, 0.999)
	var x: float = wrapped * float(n)
	var i: int = int(floor(x)) % n
	var j: int
	if loop:
		j = (i + 1) % n
	else:
		j = mini(n - 1, i + 1)
	var t: float = x - floor(x)
	var hip_arr: Array = clip["hipY"]
	var hip_y: float = float(hip_arr[i]) + (float(hip_arr[j]) - float(hip_arr[i])) * t
	var pose_q: Dictionary = {}
	var bones: Dictionary = clip["bones"]
	for name in bones.keys():
		var frames: Array = bones[name]
		var a: Array = frames[i]
		var b: Array = frames[j]
		var qa := _frame_to_quat(a)
		var qb := _frame_to_quat(b)
		if qa.dot(qb) < 0.0:
			qb = Quaternion(-qb.x, -qb.y, -qb.z, -qb.w)
		pose_q[name] = qa.slerp(qb, t)
	return {"hipY": hip_y, "poseQ": pose_q}


func _dampen_toward(live: Dictionary, still: Dictionary, k: float, arm_only: bool) -> void:
	live["hipY"] = float(still["hipY"]) + (float(live["hipY"]) - float(still["hipY"])) * k
	var live_q: Dictionary = live["poseQ"]
	var still_q: Dictionary = still["poseQ"]
	for name in live_q.keys():
		if arm_only and not _is_arm_bone(name):
			continue
		if not still_q.has(name):
			continue
		var a: Quaternion = still_q[name]
		var b: Quaternion = live_q[name]
		var bb := b
		if a.dot(bb) < 0.0:
			bb = Quaternion(-bb.x, -bb.y, -bb.z, -bb.w)
		live_q[name] = a.slerp(bb, k)


func _is_arm_bone(name: String) -> bool:
	return name.contains("UpperArm") or name.contains("Forearm") or name.contains("Hand") or name.contains("Shoulder")


func _nudge_idle_upright(pose_q: Dictionary) -> void:
	var keep := {
		"C_Hip_a": 0.06, "C_Spine_a": 0.4, "C_Spine_b": 0.28, "C_Spine_c": 0.16, "C_Neck_a": 0.2,
		"L_UpperLeg_a": 0.35, "R_UpperLeg_a": 0.35, "L_Foreleg_a": 0.1, "R_Foreleg_a": 0.1,
		"L_Foot_a": 0.22, "R_Foot_a": 0.22,
	}
	for name in keep.keys():
		if not pose_q.has(name):
			continue
		var q: Quaternion = pose_q[name]
		var e := _quat_to_euler_xyz(q)
		e.x *= float(keep[name])
		pose_q[name] = _quat_from_euler_xyz(e.x, e.y, e.z)


## Hang idle arms at sides, slightly behind torso (web nudgeIdleArmsBack, z pull -0.22).
func _nudge_idle_arms_back(pose_q: Dictionary) -> void:
	_pull_arm_back(pose_q, "L_UpperArm_a", "L_Forearm_a")
	_pull_arm_back(pose_q, "R_UpperArm_a", "R_Forearm_a")


func _pull_arm_back(pose_q: Dictionary, arm: String, child: String) -> void:
	if not pose_q.has(arm):
		return
	if not rest_pos.has(arm) or not rest_pos.has(child):
		return
	var from: Vector3 = (rest_pos[child] as Vector3) - (rest_pos[arm] as Vector3)
	if from.length_squared() < 1e-8:
		return
	from = from.normalized()
	var q: Quaternion = pose_q[arm]
	var to := q * from
	var v := Vector3(to.x, to.y, minf(to.z - 0.22, 0.04))
	if v.length_squared() < 1e-8:
		return
	v = v.normalized()
	var dq := _quat_from_unit_vectors(to, v)
	pose_q[arm] = (dq * q).normalized()


func _quat_from_unit_vectors(from: Vector3, to: Vector3) -> Quaternion:
	var v_from := from.normalized()
	var v_to := to.normalized()
	var r := v_from.dot(v_to) + 1.0
	var qx: float
	var qy: float
	var qz: float
	var qw: float
	if r < 1e-6:
		r = 0.0
		if absf(v_from.x) > absf(v_from.z):
			qx = -v_from.y
			qy = v_from.x
			qz = 0.0
			qw = r
		else:
			qx = 0.0
			qy = -v_from.z
			qz = v_from.y
			qw = r
	else:
		var c := v_from.cross(v_to)
		qx = c.x
		qy = c.y
		qz = c.z
		qw = r
	return Quaternion(qx, qy, qz, qw).normalized()


func _quat_to_euler_xyz(q: Quaternion) -> Vector3:
	# THREE.js Quaternion → Euler XYZ
	var sinr_cosp := 2.0 * (q.w * q.x + q.y * q.z)
	var cosr_cosp := 1.0 - 2.0 * (q.x * q.x + q.y * q.y)
	var x := atan2(sinr_cosp, cosr_cosp)
	var sinp := 2.0 * (q.w * q.y - q.z * q.x)
	var y: float
	if absf(sinp) >= 1.0:
		y = signf(sinp) * PI * 0.5
	else:
		y = asin(sinp)
	var siny_cosp := 2.0 * (q.w * q.z + q.x * q.y)
	var cosy_cosp := 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
	var z := atan2(siny_cosp, cosy_cosp)
	return Vector3(x, y, z)


func _soft_to_godot_pose(bone_name: String, soft_q: Quaternion) -> Quaternion:
	# Godot4 pose = full local transform (defaults to rest).
	# soft_q is soft-rig parent-local (identity rest). Convert:
	# pose = R_rest_world_parent^{-1} * soft_q * R_rest_world_parent * rest_local
	var rest_q: Quaternion = rest_local_q.get(bone_name, Quaternion.IDENTITY)
	var i: int = bone_idx[bone_name]
	var parent := skeleton.get_bone_parent(i)
	var rest_w_p := Quaternion.IDENTITY
	if parent >= 0:
		var pname := skeleton.get_bone_name(parent)
		rest_w_p = rest_world_q.get(pname, Quaternion.IDENTITY)
	return (rest_w_p.inverse() * soft_q * rest_w_p) * rest_q


func apply_pose(fwd: float, side: float, mag: float, airborne: bool, sprint: bool, delta: float, speed_mps: float = 1.65) -> void:
	if frozen:
		if secondary and secondary.has_method("update"):
			secondary.set("corpse_mode", true)
			secondary.update(delta, false)
		return
	if skeleton == null or clips.is_empty():
		return
	var clip_name := pick_clip(fwd, side, mag, airborne, sprint)
	var clip: Dictionary = clips.get(clip_name, {})
	var dance := dance_override != "" and clip_name.begins_with("dance")
	var active := dance or airborne or mag > 0.07
	var clip_changed := last_clip_name != "" and clip_name != last_clip_name
	var stopped := loco_was_moving and not active
	if (stopped or clip_changed) and not last_soft_q.is_empty():
		_capture_loco_hold()
		if stopped:
			loco_settle = 0.0
			clip_blend = 1.0
		else:
			clip_blend = 0.0
	if active:
		loco_settle = 1.0
	current_clip = clip_name

	# Phase advance (mirrors soft-skeleton tickLocomotion).
	if dance:
		var dur: float = float(clip.get("dur", 4.0))
		phase += delta / maxf(0.8, dur)
	elif airborne:
		# Approximate jump phase from air time handled by caller via mag; keep climbing phase.
		phase = clampf(phase + delta * 0.4, 0.0, 0.999)
		if not was_air:
			phase = 0.28
	else:
		if was_air:
			phase = 0.0
		if mag > 0.05:
			var stride: float = float(clip.get("stride", 1.45))
			if mode == "prone":
				stride = float(clip.get("stride", 0.55))
			elif mode == "crouch":
				stride = float(clip.get("stride", 0.72))
			# speed_mps = 实际水平速度（米/秒），不要再乘输入幅度，否则加速阶段会滑步。
			var dist := maxf(0.0, speed_mps) * delta
			phase += dist / maxf(0.28, stride)
		elif loco_settle >= 1.0:
			var idle_slow := 2.4 if clip_name == "standIdle" else 1.0
			phase += delta / maxf(0.8, float(clip.get("dur", 4.0)) * idle_slow)
	was_air = airborne

	var stance_name := ""
	if not airborne and not dance:
		if mode == "crouch":
			stance_name = "crouchIdle"
		elif mode == "prone":
			stance_name = "proneIdle"
		else:
			stance_name = "standIdle"

	var loop := clip_name != "jump"
	var u: float = fposmod(phase, 1.0) if loop else clampf(phase, 0.0, 0.999)
	var move: Variant = sample_clip(clip, u, loop) if not clip.is_empty() else null
	var rest_s: Variant = null
	if stance_name != "" and clips.has(stance_name):
		rest_s = sample_clip(clips[stance_name], u, true)

	if clips.has("standIdle"):
		var still = sample_clip(clips["standIdle"], 0.0, true)
		if move != null and clip_name == "standIdle":
			_dampen_toward(move, still, STAND_IDLE_MOTION, false)
		if rest_s != null and stance_name == "standIdle":
			_dampen_toward(rest_s, still, STAND_IDLE_MOTION, false)
	if move != null and rest_s != null and mode == "crouch" and clip_name != "crouchIdle":
		_dampen_toward(move, rest_s, CROUCH_ARM_MOTION, true)

	var k: float = smoothstep(0.04, 0.22, clampf(mag, 0.0, 1.0))
	var t_blend: float = 0.0
	if move != null and rest_s != null and clip_name != stance_name:
		t_blend = k
	elif move != null:
		t_blend = 1.0
	elif rest_s != null:
		t_blend = 1.0

	var names: Dictionary = {}
	if move != null:
		for n in move["poseQ"].keys():
			names[n] = true
	if rest_s != null:
		for n in rest_s["poseQ"].keys():
			names[n] = true

	var final_q: Dictionary = {}
	for name in names.keys():
		var q_move = move["poseQ"].get(name) if move != null else null
		var q_rest = rest_s["poseQ"].get(name) if rest_s != null else null
		if q_move != null and q_rest != null and t_blend < 1.0:
			var a: Quaternion = q_rest
			var b: Quaternion = q_move
			if a.dot(b) < 0.0:
				b = Quaternion(-b.x, -b.y, -b.z, -b.w)
			final_q[name] = a.slerp(b, t_blend)
		elif q_move != null:
			final_q[name] = q_move
		elif q_rest != null:
			final_q[name] = q_rest

	if clip_name == "standIdle":
		_nudge_idle_upright(final_q)
		_nudge_idle_arms_back(final_q)

	var hip_y0: float = float(rest_s["hipY"]) if rest_s != null else 0.0
	var hip_y1: float = float(move["hipY"]) if move != null else hip_y0
	var hip_y: float = hip_y0 + (hip_y1 - hip_y0) * t_blend
	if mode == "crouch":
		hip_y += 0.04
	if airborne or clip_name == "jump":
		hip_y *= 0.18

	# Crossfade last evaluated pose → target (loco→idle 0.5s; other clip changes 0.5s).
	var blend_u := 1.0
	if clip_blend < 1.0:
		clip_blend = minf(1.0, clip_blend + delta / CLIP_BLEND_DUR)
		blend_u = clip_blend * clip_blend * (3.0 - 2.0 * clip_blend)
	elif not active and loco_settle < 1.0:
		loco_settle = minf(1.0, loco_settle + delta / LOCO_STOP_DUR)
		blend_u = loco_settle * loco_settle * (3.0 - 2.0 * loco_settle)
	if blend_u < 1.0 and not hold_q.is_empty():
		hip_y = _apply_loco_settle(final_q, hip_y, blend_u)

	# Reset loco bones to rest (incl. scale), then apply — prevents dirty scale from breath.
	# 持枪 IK 时保留上一帧手臂，交给 weapon_system 覆写，避免走跑动画把手当成腿一起摆。
	for name in bone_idx.keys():
		if weapon_ik and _is_arm_bone(name):
			continue
		var i: int = bone_idx[name]
		skeleton.set_bone_pose_rotation(i, rest_local_q[name])
		skeleton.set_bone_pose_position(i, rest_origin[name])
		skeleton.set_bone_pose_scale(i, rest_scale.get(name, Vector3.ONE))

	for name in final_q.keys():
		if not bone_idx.has(name):
			continue
		if weapon_ik and _is_arm_bone(name):
			continue
		var soft_q: Quaternion = final_q[name]
		var pose_q := _soft_to_godot_pose(name, soft_q)
		skeleton.set_bone_pose_rotation(bone_idx[name], pose_q)

	if bone_idx.has("C_Hip_a"):
		var hip_i: int = bone_idx["C_Hip_a"]
		var o: Vector3 = rest_origin["C_Hip_a"]
		# hipY is character-space Y offset (same as web poseOff.y)
		skeleton.set_bone_pose_position(hip_i, o + Vector3(0.0, hip_y, 0.0))

	last_soft_q.clear()
	for name in final_q.keys():
		last_soft_q[name] = final_q[name]
	last_hip_y = hip_y
	last_clip_name = clip_name
	loco_was_moving = active

	_apply_navel_pose()

	# Secondary: hair Verlet + blink + full breath (after loco pose)
	if secondary != null:
		secondary.update(delta, sprint)


# ------------------------------------------------------------------ 插肚脐（网页 pose "navelPoke"）
## 网页 soft-skeleton setPose("navelPoke") + applyNavelFingerInsert：右手食指从肚脐前 ~5cm（park）
## 插到 ~5cm 深（ins），只用肩 / 肘 / 腕 / 指根 FK；手势 "point"（中 / 无名 / 小指弯曲）。
const NAVEL_PARK := {
	"R_Shoulder_a": Vector3(-0.232, 0.327, -0.098),
	"R_UpperArm_a": Vector3(-1.12, -0.726, 0.367),
	"R_Forearm_a": Vector3(1.07, -0.431, 0.617),
	"R_Hand_a": Vector3(1.096, -0.72, 0.438),
	"R_Index_a": Vector3(0.413, -0.363, -0.009),
}
const NAVEL_INS := {
	"R_Shoulder_a": Vector3(-0.232, 0.328, -0.108),
	"R_UpperArm_a": Vector3(-0.989, -0.732, 0.443),
	"R_Forearm_a": Vector3(1.415, -0.438, 0.791),
	"R_Hand_a": Vector3(0.792, -0.614, 0.244),
	"R_Index_a": Vector3(0.306, -0.281, -0.044),
}
const NAVEL_TORSO := ["C_Spine_a", "C_Spine_b", "C_Spine_c", "C_Spine_d"]
const NAVEL_HEAD := {"C_Neck_a": Vector3(0.2, 0.03, 0.0), "C_Head_a": Vector3(0.14, 0.05, 0.0)}
## 插入量 0..1（< 0 = 关闭姿势）与搅动偏移（网页 stirX / stirY）
var navel_t: float = -1.0
var navel_stir: Vector2 = Vector2.ZERO
var _navel_was_on: bool = false
var _point_q: Dictionary = {}  # bone → soft-space quat（右手 point 手势）


func _set_soft_any(name: String, soft_q: Quaternion) -> void:
	var i := skeleton.find_bone(name)
	if i < 0:
		return
	var rest_q: Quaternion = rest_local_q.get(name, Quaternion.IDENTITY)
	var parent := skeleton.get_bone_parent(i)
	var rest_w_p := Quaternion.IDENTITY
	if parent >= 0:
		rest_w_p = rest_world_q.get(skeleton.get_bone_name(parent), Quaternion.IDENTITY)
	skeleton.set_bone_pose_rotation(i, (rest_w_p.inverse() * soft_q * rest_w_p) * rest_q)


func _reset_bone(name: String) -> void:
	var i := skeleton.find_bone(name)
	if i >= 0:
		skeleton.set_bone_pose_rotation(i, rest_local_q.get(name, Quaternion.IDENTITY))


func _apply_navel_pose() -> void:
	if navel_t < 0.0:
		if _navel_was_on:
			_navel_was_on = false
			for n in ["C_Head_a", "R_Index_a"] + _point_q.keys():
				_reset_bone(n)
		return
	_navel_was_on = true
	if _point_q.is_empty():
		_point_q = _build_point_gesture()
	var k := clampf(navel_t, 0.0, 1.0)
	# 网页 navelPoke 其余骨骼为静止姿势：躯干摆正，手臂相对肚脐的位置才与网页一致
	for n in NAVEL_TORSO:
		_set_soft_any(n, Quaternion.IDENTITY)
	for n in NAVEL_HEAD.keys():
		var e: Vector3 = NAVEL_HEAD[n]
		_set_soft_any(n, _quat_from_euler_xyz(e.x, e.y, e.z))
	for n in NAVEL_PARK.keys():
		var a: Vector3 = NAVEL_PARK[n]
		var b: Vector3 = NAVEL_INS[n]
		var q := _quat_from_euler_xyz(a.x, a.y, a.z).slerp(_quat_from_euler_xyz(b.x, b.y, b.z), k)
		if navel_stir.length() > 1e-5:
			var sx := navel_stir.x
			var sy := navel_stir.y
			if n == "R_Forearm_a":
				q = q * _quat_from_euler_xyz(sy * 5.5, sx * 4.2, 0.0)
			elif n == "R_Hand_a":
				q = q * _quat_from_euler_xyz(sy * 9.5, sx * 7.5, sx * 2.2)
			elif n == "R_Index_a":
				q = q * _quat_from_euler_xyz(sy * 3.5, sx * 2.8, 0.0)
		_set_soft_any(n, q * (_point_q.get(n, Quaternion.IDENTITY) as Quaternion))
	for n in _point_q.keys():
		if not NAVEL_PARK.has(n):
			_set_soft_any(n, _point_q[n])


## 网页 initHandAxes + setHandGesture("point")：用左手静止骨位算弯曲轴，再镜像到右手 (x, -y, -z, w)。
func _build_point_gesture() -> Dictionary:
	var out := {}
	var rp := func(n: String) -> Vector3:
		return rest_pos.get(n, Vector3.ZERO)
	if not (rest_pos.has("L_Hand_a") and rest_pos.has("L_Middle_a") and rest_pos.has("L_Index_a") and rest_pos.has("L_Pinky_a")):
		return out
	var f: Vector3 = ((rp.call("L_Middle_a") as Vector3) - rp.call("L_Hand_a")).normalized()
	var t: Vector3 = (rp.call("L_Index_a") as Vector3) - rp.call("L_Pinky_a")
	var palm := f.cross(t).normalized()
	if palm.x > 0.0:
		palm = -palm
	var curls := {"Index": 0.0, "Middle": 1.0, "Ring": 1.05, "Pinky": 1.1}
	var spread_g := 0.02
	for d in curls.keys():
		var curl: float = curls[d]
		var spread := spread_g if d == "Index" else (-spread_g * 0.9 if d == "Middle" else (-spread_g * 0.12 if d == "Pinky" else 0.0))
		var joints := [["a", 0.1 if curl == 0.0 else 1.32 * curl, spread], ["b", 0.14 if curl == 0.0 else 1.62 * curl, spread * 0.1], ["c", 0.08 if curl == 0.0 else 1.18 * curl, 0.0]]
		for j in joints:
			var nm := "L_%s_%s" % [d, j[0]]
			var bi := skeleton.find_bone(nm)
			if bi < 0:
				continue
			var child := -1
			for c in skeleton.get_bone_children(bi):
				child = c
				break
			var v: Vector3
			if child >= 0:
				v = (rp.call(skeleton.get_bone_name(child)) as Vector3) - rp.call(nm)
			else:
				var par := skeleton.get_bone_parent(bi)
				v = (rp.call(nm) as Vector3) - rp.call(skeleton.get_bone_name(par))
			if v.length_squared() < 1e-10:
				continue
			var curl_ax := v.normalized().cross(palm)
			if curl_ax.length_squared() < 1e-10:
				continue
			curl_ax = curl_ax.normalized()
			var q := Quaternion.IDENTITY
			if absf(float(j[1])) > 0.001:
				q = q * Quaternion(curl_ax, float(j[1]))
			if absf(float(j[2])) > 0.001:
				q = q * Quaternion(palm, float(j[2]))
			out["%s_%s" % [d, j[0]]] = q
	# 拇指（point：flip 0.68，a/b/c 欧拉）
	var th := {"Thumb_a": [Vector3(-0.28, 0.24, 0.1), 0.68], "Thumb_b": [Vector3(0.82, 0.08, 0.0), 0.0], "Thumb_c": [Vector3(0.66, 0.0, 0.0), 0.0]}
	for sfx in th.keys():
		var e: Vector3 = th[sfx][0]
		var flip: float = th[sfx][1]
		var q2 := Quaternion.IDENTITY
		if flip > 0.001:
			q2 = q2 * Quaternion(f, flip)
		q2 = q2 * _quat_from_euler_xyz(e.x, e.y, e.z)
		out[sfx] = q2
	var r := {}
	for sfx in out.keys():
		var q3: Quaternion = out[sfx]
		if skeleton.find_bone("R_" + sfx) >= 0:
			r["R_" + sfx] = Quaternion(q3.x, -q3.y, -q3.z, q3.w)
	return r


func _capture_loco_hold() -> void:
	hold_q.clear()
	for name in last_soft_q.keys():
		hold_q[name] = last_soft_q[name]
	hold_hip_y = last_hip_y


func _apply_loco_settle(pose_q: Dictionary, hip_y: float, u: float) -> float:
	for name in pose_q.keys():
		if not hold_q.has(name):
			continue
		var a: Quaternion = hold_q[name]
		var b: Quaternion = pose_q[name]
		if a.dot(b) < 0.0:
			b = Quaternion(-b.x, -b.y, -b.z, -b.w)
		pose_q[name] = a.slerp(b, u)
	return lerpf(hold_hip_y, hip_y, u)


func _reset_blend_for_debug() -> void:
	loco_was_moving = false
	loco_settle = 1.0
	clip_blend = 1.0
	hold_q.clear()
	last_soft_q.clear()
	last_hip_y = 0.0
	last_clip_name = ""


func _update_breath(delta: float, sprint: bool) -> void:
	var boost := 0.35 if sprint else 0.0
	var freq := (0.72 + 0.55) * (1.0 + boost * 0.5)
	breath_t += delta * freq
	var follow := 1.0 - exp(-10.0 * delta)
	if not breath_enabled:
		breath_in = lerpf(breath_in, 0.0, follow)
		breath_chest = lerpf(breath_chest, 0.0, follow)
		return
	var wave := _breath_wave(breath_t)
	breath_in = lerpf(breath_in, wave, follow)
	breath_chest = lerpf(breath_chest, _breath_wave(breath_t - 0.72), 1.0 - exp(-8.0 * delta))


func _breath_wave(t: float) -> float:
	var p := fposmod(t, 1.0)
	if p < 0.44:
		if p < 0.2:
			var u := p / 0.2
			return u * u * (3.0 - 2.0 * u)
		return 1.0
	var u2 := (p - 0.44) / 0.56
	return 1.0 - u2 * u2 * (3.0 - 2.0 * u2)


## Sample standIdle after upright+arms-back nudges; returns soft quats for arm bones.
func debug_sample_idle_arms() -> Dictionary:
	if not clips.has("standIdle"):
		return {"ok": false}
	phase = 0.0
	mode = "stand"
	dance_override = ""
	_reset_blend_for_debug()
	apply_pose(0.0, 0.0, 0.0, false, false, 0.016, 1.65)
	var out := {"ok": true, "clip": current_clip, "arms": {}}
	for name in ["L_UpperArm_a", "R_UpperArm_a", "L_Forearm_a", "R_Forearm_a"]:
		if not bone_idx.has(name):
			continue
		var i: int = bone_idx[name]
		var q := skeleton.get_bone_pose_rotation(i)
		var rest_q: Quaternion = rest_local_q[name]
		var delta_q := rest_q.inverse() * q
		out["arms"][name] = {
			"pose": [q.x, q.y, q.z, q.w],
			"delta_angle": 2.0 * acos(clampf(absf(delta_q.w), 0.0, 1.0)),
		}
	# Also report soft-space upper-arm z pull via rest child direction
	for arm_child in [["L_UpperArm_a", "L_Forearm_a"], ["R_UpperArm_a", "R_Forearm_a"]]:
		var arm: String = arm_child[0]
		var child: String = arm_child[1]
		if not rest_pos.has(arm) or not rest_pos.has(child) or not bone_idx.has(arm):
			continue
		var from: Vector3 = (rest_pos[child] as Vector3) - (rest_pos[arm] as Vector3)
		if from.length_squared() < 1e-8:
			continue
		from = from.normalized()
		# Reconstruct soft_q from godot pose: soft = R_wp * pose * rest^{-1} * R_wp^{-1}
		var pose_q := skeleton.get_bone_pose_rotation(bone_idx[arm])
		var rest_q2: Quaternion = rest_local_q[arm]
		var i2: int = bone_idx[arm]
		var parent := skeleton.get_bone_parent(i2)
		var rest_w_p := Quaternion.IDENTITY
		if parent >= 0:
			rest_w_p = rest_world_q.get(skeleton.get_bone_name(parent), Quaternion.IDENTITY)
		var soft_q := rest_w_p * pose_q * rest_q2.inverse() * rest_w_p.inverse()
		var to := soft_q * from
		out["arms"][arm]["child_dir_z"] = to.z
	return out


## Apply one walk frame for headless validation; returns diagnostic dict.
func debug_sample_walk() -> Dictionary:
	if not clips.has("walk"):
		return {"ok": false}
	phase = 0.25
	mode = "stand"
	dance_override = ""
	_reset_blend_for_debug()
	apply_pose(1.0, 0.0, 1.0, false, false, 0.016, 1.65)
	var out := {"ok": true, "clip": current_clip, "bones": {}}
	for name in ["C_Hip_a", "L_UpperLeg_a", "R_UpperLeg_a", "L_Foreleg_a", "C_Spine_c"]:
		if not bone_idx.has(name):
			continue
		var i: int = bone_idx[name]
		var q := skeleton.get_bone_pose_rotation(i)
		var rest_q: Quaternion = rest_local_q[name]
		var delta_q := rest_q.inverse() * q
		out["bones"][name] = {
			"pose": [q.x, q.y, q.z, q.w],
			"delta_angle": 2.0 * acos(clampf(absf(delta_q.w), 0.0, 1.0)),
		}
	if secondary != null:
		out["secondary"] = secondary.debug_snapshot()
	return out


## Walk mid-swing then release: first idle frame stays near walk; 0.5s later near idle.
func debug_sample_stop_blend() -> Dictionary:
	if not clips.has("walk") or not bone_idx.has("L_UpperArm_a"):
		return {"ok": false}
	_reset_blend_for_debug()
	phase = 0.25
	mode = "stand"
	dance_override = ""
	apply_pose(1.0, 0.0, 1.0, false, false, 0.016, 1.65)
	var arm_i: int = bone_idx["L_UpperArm_a"]
	var walk_q := skeleton.get_bone_pose_rotation(arm_i)
	apply_pose(0.0, 0.0, 0.0, false, false, 0.016, 1.65)
	var first_q := skeleton.get_bone_pose_rotation(arm_i)
	var first_from_walk := walk_q.inverse() * first_q
	var first_ang := 2.0 * acos(clampf(absf(first_from_walk.w), 0.0, 1.0))
	var tsec := 0.016
	while tsec < LOCO_STOP_DUR + 0.02:
		apply_pose(0.0, 0.0, 0.0, false, false, 0.016, 1.65)
		tsec += 0.016
	var end_q := skeleton.get_bone_pose_rotation(arm_i)
	var end_from_walk := walk_q.inverse() * end_q
	var end_ang := 2.0 * acos(clampf(absf(end_from_walk.w), 0.0, 1.0))
	return {
		"ok": true,
		"clip": current_clip,
		"first_ang_from_walk": first_ang,
		"end_ang_from_walk": end_ang,
		"settle": loco_settle,
		"dur": LOCO_STOP_DUR,
	}
