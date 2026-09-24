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

var skeleton: Skeleton3D
var clips: Dictionary = {} # name -> {dur,n,hipY,bones,stride,fmt}
var bone_idx: Dictionary = {} # name -> int
var rest_local_q: Dictionary = {} # name -> Quaternion
var rest_world_q: Dictionary = {} # name -> Quaternion (bind)
var rest_origin: Dictionary = {} # name -> Vector3

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

var _qa := Quaternion.IDENTITY
var _qb := Quaternion.IDENTITY

const SoftSecondaryScript = preload("res://scripts/soft_secondary.gd")


func setup(skel: Skeleton3D) -> bool:
	skeleton = skel
	if skeleton == null:
		push_error("SoftLoco: no skeleton")
		return false
	var f := FileAccess.open(CLIPS_PATH, FileAccess.READ)
	if f == null:
		push_error("SoftLoco: cannot open %s" % CLIPS_PATH)
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("clips"):
		push_error("SoftLoco: bad clips JSON")
		return false
	clips = parsed["clips"]
	bone_idx.clear()
	rest_local_q.clear()
	rest_world_q.clear()
	rest_origin.clear()
	# Cache rest local + rest-world for every bone (parents of loco bones may be non-loco).
	var n := skeleton.get_bone_count()
	var world_by_idx: Array = []
	world_by_idx.resize(n)
	for i in n:
		var rest := skeleton.get_bone_rest(i)
		var pname := skeleton.get_bone_name(i)
		rest_local_q[pname] = rest.basis.get_rotation_quaternion()
		rest_origin[pname] = rest.origin
		var parent := skeleton.get_bone_parent(i)
		if parent < 0:
			world_by_idx[i] = rest.basis.get_rotation_quaternion()
		else:
			world_by_idx[i] = world_by_idx[parent] * rest.basis.get_rotation_quaternion()
		rest_world_q[pname] = world_by_idx[i]
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
	if skeleton == null or clips.is_empty():
		return
	var clip_name := pick_clip(fwd, side, mag, airborne, sprint)
	current_clip = clip_name
	var clip: Dictionary = clips.get(clip_name, {})
	var dance := dance_override != "" and clip_name.begins_with("dance")

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
			var dist := maxf(0.08, speed_mps) * mag * delta
			phase += dist / maxf(0.28, stride)
		else:
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

	var hip_y0: float = float(rest_s["hipY"]) if rest_s != null else 0.0
	var hip_y1: float = float(move["hipY"]) if move != null else hip_y0
	var hip_y: float = hip_y0 + (hip_y1 - hip_y0) * t_blend
	if mode == "crouch":
		hip_y += 0.04
	if airborne or clip_name == "jump":
		hip_y *= 0.18

	# Reset loco bones to rest, then apply.
	for name in bone_idx.keys():
		var i: int = bone_idx[name]
		skeleton.set_bone_pose_rotation(i, rest_local_q[name])
		skeleton.set_bone_pose_position(i, rest_origin[name])

	for name in final_q.keys():
		if not bone_idx.has(name):
			continue
		var soft_q: Quaternion = final_q[name]
		var pose_q := _soft_to_godot_pose(name, soft_q)
		skeleton.set_bone_pose_rotation(bone_idx[name], pose_q)

	if bone_idx.has("C_Hip_a"):
		var hip_i: int = bone_idx["C_Hip_a"]
		var o: Vector3 = rest_origin["C_Hip_a"]
		# hipY is character-space Y offset (same as web poseOff.y)
		skeleton.set_bone_pose_position(hip_i, o + Vector3(0.0, hip_y, 0.0))

	# Secondary: hair Verlet + blink + full breath (after loco pose)
	if secondary != null:
		secondary.update(delta, sprint)


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


## Apply one walk frame for headless validation; returns diagnostic dict.
func debug_sample_walk() -> Dictionary:
	if not clips.has("walk"):
		return {"ok": false}
	phase = 0.25
	mode = "stand"
	dance_override = ""
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
