extends RefCounted
class_name SoftSecondary
## Hair Verlet + eyelid blink + chest/belly breath (from soft-skeleton.ts).
## Call update() AFTER SoftLoco.apply_pose each frame.

const RIG_PATH := "res://assets/characters/tifa/soft_rig_bones.json"
const LID_RE := "^(L|R)_(U|D)lid_([A-E])$"

var hair_enabled: bool = true
var hair_damp: float = 0.01
var hair_inertia: float = 0.55
var hair_gravity: float = -1.4
var hair_wind: float = 0.0

var blink_enabled: bool = true
var blink_rate: float = 38.0
var blink_speed: float = 1.0
var eye_open_l: float = 1.0
var eye_open_r: float = 1.0
var debug_blink: float = -1.0

var breath_enabled: bool = true
var breath_amp: float = 0.4
var breath_speed: float = 0.3
var breath_boost: float = 0.0

var skeleton: Skeleton3D

var bone_i: Dictionary = {}
var rest_pos: Dictionary = {}
var rest_world_q: Dictionary = {}
var rest_local_q: Dictionary = {}
var rest_origin: Dictionary = {}
var bone_parent: Dictionary = {}

var hair_names: PackedStringArray = []
var hair_p: Array = []
var hair_prev: Array = []
var hair_len: PackedFloat32Array = []
var hair_root_prev: Vector3 = Vector3.ZERO
var hair_root_rot_prev: Quaternion = Quaternion.IDENTITY
var hair_root_init: bool = false
var yaw_f: float = 0.0
var pitch_f: float = 0.0
var _yaw_vel: float = 0.0
var _pitch_vel: float = 0.0

var lid_names: PackedStringArray = []
var lid_w: Dictionary = {}
var lid_kind: Dictionary = {}
var blink_t: float = -1.0
var blink_dur: float = 0.28
var next_blink: float = 1.5
var blink_amt: float = 0.0
var close_l: float = 0.0
var close_r: float = 0.0
var eye_l: String = "L_Eye"
var eye_r: String = "R_Eye"

var breath_t: float = 0.0
var breath_in: float = 0.0
var breath_chest: float = 0.0

var _rng := RandomNumberGenerator.new()


func setup(skel: Skeleton3D) -> bool:
	skeleton = skel
	if skeleton == null:
		return false
	_rng.randomize()
	bone_i.clear()
	rest_pos.clear()
	rest_world_q.clear()
	rest_local_q.clear()
	rest_origin.clear()
	bone_parent.clear()

	var n := skeleton.get_bone_count()
	var world_xf: Array = []
	world_xf.resize(n)
	for i in n:
		var rest := skeleton.get_bone_rest(i)
		var nm := skeleton.get_bone_name(i)
		bone_i[nm] = i
		rest_local_q[nm] = rest.basis.get_rotation_quaternion()
		rest_origin[nm] = rest.origin
		var p := skeleton.get_bone_parent(i)
		if p < 0:
			world_xf[i] = rest
			bone_parent[nm] = ""
		else:
			world_xf[i] = world_xf[p] * rest
			bone_parent[nm] = skeleton.get_bone_name(p)
		var xf: Transform3D = world_xf[i]
		rest_pos[nm] = xf.origin
		rest_world_q[nm] = xf.basis.get_rotation_quaternion()

	hair_names = PackedStringArray()
	var f := FileAccess.open(RIG_PATH, FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			for b in parsed.get("bones", []):
				if str(b.get("group", "")) == "hair" and bone_i.has(str(b["name"])):
					hair_names.append(str(b["name"]))
	if hair_names.is_empty():
		var ordered := PackedStringArray()
		if bone_i.has("HairRoot"):
			ordered.append("HairRoot")
		for k in range(1, 16):
			var hn := "Hair_%d" % k
			if bone_i.has(hn):
				ordered.append(hn)
		hair_names = ordered

	hair_p.clear()
	hair_prev.clear()
	hair_len = PackedFloat32Array()
	hair_len.resize(hair_names.size())
	for k in hair_names.size():
		var nm2: String = hair_names[k]
		var rp: Vector3 = rest_pos[nm2]
		hair_p.append(rp)
		hair_prev.append(rp)
		if k == 0:
			hair_len[k] = 0.0
		else:
			hair_len[k] = rp.distance_to(rest_pos[hair_names[k - 1]])
	hair_root_init = false

	lid_names = PackedStringArray()
	lid_w.clear()
	lid_kind.clear()
	var cre := RegEx.new()
	cre.compile(LID_RE)
	for nm3 in bone_i.keys():
		var m := cre.search(str(nm3))
		if m == null:
			continue
		var sname := str(nm3)
		lid_names.append(sname)
		var letter := m.get_string(3)
		var w := 0.52
		match letter:
			"C":
				w = 1.0
			"B":
				w = 0.92
			"D":
				w = 0.8
			"A":
				w = 0.66
			"E":
				w = 0.52
		lid_w[sname] = w
		lid_kind[sname] = 1 if m.get_string(2) == "U" else -1

	next_blink = 0.8 + _rng.randf() * 1.4
	blink_t = -1.0
	blink_amt = 0.0
	print(
		"SoftSecondary: hair=%d lids=%d (hair+blink+breath enabled)"
		% [hair_names.size(), lid_names.size()]
	)
	return true


func set_breath_boost(v: float) -> void:
	breath_boost = clampf(v, 0.0, 1.0)


func blink_now() -> void:
	debug_blink = -1.0
	blink_t = 0.0
	blink_dur = 0.28
	next_blink = 0.0


func update(delta: float, sprint: bool = false) -> void:
	if skeleton == null:
		return
	var d := minf(delta, 0.04)
	if sprint:
		breath_boost = maxf(breath_boost, 0.35)
	else:
		breath_boost = maxf(0.0, breath_boost - d * 1.2)

	_update_breath(d)
	_apply_breath()

	_update_blink(d)
	close_l = clampf(1.0 - eye_open_l * (1.0 - blink_amt), 0.0, 1.0)
	close_r = clampf(1.0 - eye_open_r * (1.0 - blink_amt), 0.0, 1.0)
	_apply_blink()

	if hair_enabled and hair_names.size() >= 2:
		_step_hair(d)


func _update_breath(d: float) -> void:
	var boost := clampf(breath_boost, 0.0, 1.0)
	var freq := (0.72 + breath_speed * 1.65) * (1.0 + boost * 0.5)
	breath_t += d * freq
	var follow := 1.0 - exp(-10.0 * d)
	if not breath_enabled:
		breath_in += (0.0 - breath_in) * follow
		breath_chest += (0.0 - breath_chest) * follow
		return
	breath_in += (_breath_wave(breath_t) - breath_in) * follow
	breath_chest += (_breath_wave(breath_t - 0.72) - breath_chest) * (1.0 - exp(-8.0 * d))


func _breath_wave(phase: float) -> float:
	var p := phase / (PI * 2.0)
	p -= floor(p)
	if p < 0.0:
		p += 1.0
	if p < 0.36:
		var u := p / 0.36
		return u * u * (3.0 - 2.0 * u)
	if p < 0.44:
		return 1.0
	var u2 := (p - 0.44) / 0.56
	return 1.0 - u2 * u2 * (3.0 - 2.0 * u2)


func _breath_amp_now() -> float:
	return (0.007 + breath_amp * 0.015) * (1.0 + clampf(breath_boost, 0.0, 1.0) * 0.4)


func _apply_breath() -> void:
	if not breath_enabled and breath_in < 0.001 and breath_chest < 0.001:
		return
	var amp := _breath_amp_now()
	var belly_w := amp * (0.12 + 0.88 * breath_in)
	var chest_w := amp * (0.12 + 0.88 * breath_chest)
	_nudge_spine("C_Spine_a", belly_w * 1.6, belly_w * 0.55, 0.0)
	_nudge_spine("C_Spine_b", belly_w * 0.45 + chest_w * 0.35, belly_w * 0.2 + chest_w * 0.15, 0.0)
	_nudge_spine("C_Spine_c", chest_w * 1.1, chest_w * 0.35, chest_w * 0.08)
	_nudge_spine("C_Spine_d", chest_w * 0.55, chest_w * 0.18, chest_w * 0.04)


func _nudge_spine(name: String, z_off: float, pitch: float, scale_xz: float) -> void:
	if not bone_i.has(name):
		return
	var i: int = bone_i[name]
	var cur_q := skeleton.get_bone_pose_rotation(i)
	var cur_p := skeleton.get_bone_pose_position(i)
	var cur_s := skeleton.get_bone_pose_scale(i)
	if absf(pitch) > 1e-6:
		var soft_q := _quat_euler_xyz(pitch, 0.0, 0.0)
		cur_q = (_soft_delta(name, soft_q) * cur_q).normalized()
	if absf(z_off) > 1e-7:
		var parent: String = bone_parent.get(name, "")
		var rest_w_p := Quaternion.IDENTITY
		if parent != "" and rest_world_q.has(parent):
			rest_w_p = rest_world_q[parent]
		cur_p += rest_w_p.inverse() * Vector3(0.0, 0.0, z_off)
	if scale_xz > 1e-7:
		cur_s.x *= 1.0 + scale_xz * 4.0
		cur_s.z *= 1.0 + scale_xz * 2.5
	skeleton.set_bone_pose_rotation(i, cur_q)
	skeleton.set_bone_pose_position(i, cur_p)
	skeleton.set_bone_pose_scale(i, cur_s)


func _update_blink(d: float) -> void:
	if debug_blink >= 0.0:
		blink_amt = clampf(debug_blink, 0.0, 1.0)
		return
	if not blink_enabled:
		blink_amt = maxf(0.0, blink_amt - d * 14.0)
		blink_t = -1.0
		return
	if blink_t < 0.0:
		next_blink -= d
		if blink_amt > 0.0:
			blink_amt = maxf(0.0, blink_amt - d * 18.0)
		if next_blink > 0.0:
			return
		blink_t = 0.0
		var dur := lerpf(0.48, 0.14, clampf(blink_speed, 0.0, 1.0))
		blink_dur = dur * (0.92 + _rng.randf() * 0.16)
		return
	blink_t += d
	var u := blink_t / maxf(0.12, blink_dur)
	if u >= 1.0:
		blink_t = -1.0
		blink_amt = 0.0
		var gap := 60.0 / maxf(4.0, blink_rate)
		if _rng.randf() < 0.13:
			next_blink = 0.12 + _rng.randf() * 0.12
		else:
			next_blink = gap * (0.7 + _rng.randf() * 0.6)
		return
	if u < 0.22:
		var x := u / 0.22
		blink_amt = x * x * (3.0 - 2.0 * x)
	elif u < 0.34:
		blink_amt = 1.0
	else:
		var x2 := (u - 0.34) / 0.66
		blink_amt = 1.0 - x2 * x2 * (3.0 - 2.0 * x2)


func _close_lid_pos(x: float, y: float, z: float, upper: bool, t: float) -> Vector3:
	var ei_name := eye_l if x >= 0.0 else eye_r
	if t <= 0.0 or not rest_pos.has(ei_name):
		return Vector3(x, y, z)
	var er: Vector3 = rest_pos[ei_name]
	var dx := x - er.x
	var dy := y - er.y
	var dz := z - er.z
	var r: float = sqrt((dy) * (dy) + (dz) * (dz))
	if r < 0.002:
		return Vector3(x, y, z)
	var phi := atan2(dy, dz)
	var nx := dx / 0.018
	var t_corner := clampf(absf(nx), 0.0, 1.0)
	var t_use := (minf(1.0, t) if upper else t * 0.2) * (1.0 - 0.48 * t_corner * t_corner)
	var slit := -0.62 if upper else -0.4
	var phi2 := phi + (slit - phi) * t_use
	var wrap: float = r + 0.0024 * t_use
	return Vector3(er.x + dx, er.y + wrap * sin(phi2), er.z + wrap * cos(phi2) + 0.002 * t_use)


func _apply_blink() -> void:
	if lid_names.is_empty():
		return
	if close_l < 0.001 and close_r < 0.001:
		for nm in lid_names:
			var i: int = bone_i[nm]
			skeleton.set_bone_pose_rotation(i, rest_local_q[nm])
			skeleton.set_bone_pose_position(i, rest_origin[nm])
		return
	for nm2 in lid_names:
		var i2: int = bone_i[nm2]
		var rp: Vector3 = rest_pos[nm2]
		var kind: int = lid_kind[nm2]
		var w: float = lid_w[nm2]
		var close := (close_l if rp.x >= 0.0 else close_r) * w
		var closed := _close_lid_pos(rp.x, rp.y, rp.z, kind > 0, close)
		var soft_off := closed - rp
		var soft_q := Quaternion.IDENTITY
		var ei_name := eye_l if rp.x >= 0.0 else eye_r
		if rest_pos.has(ei_name):
			var er: Vector3 = rest_pos[ei_name]
			var phi0 := atan2(rp.y - er.y, rp.z - er.z)
			var phi1 := atan2(closed.y - er.y, closed.z - er.z)
			soft_q = _quat_euler_yxz(phi1 - phi0, 0.0, 0.0)
		skeleton.set_bone_pose_rotation(i2, _soft_to_godot(nm2, soft_q))
		var parent: String = bone_parent.get(nm2, "")
		var local_pos: Vector3 = rest_origin[nm2]
		if parent != "" and rest_world_q.has(parent):
			local_pos = rest_origin[nm2] + (rest_world_q[parent] as Quaternion).inverse() * soft_off
		skeleton.set_bone_pose_position(i2, local_pos)


func _soft_pose(name: String) -> Array:
	var i: int = bone_i[name]
	var g := skeleton.get_bone_global_pose(i)
	var soft_pos := g.origin
	var soft_rot := g.basis.get_rotation_quaternion() * (rest_world_q[name] as Quaternion).inverse()
	return [soft_pos, soft_rot]


func _step_hair(d: float) -> void:
	var n := hair_names.size()
	var root_name: String = hair_names[0]
	var root_pose := _soft_pose(root_name)
	var rp: Vector3 = root_pose[0]
	var rq: Quaternion = root_pose[1]

	if hair_root_init:
		var dq := rq * hair_root_rot_prev.inverse()
		var e := _quat_to_euler_yxz(dq)
		_yaw_vel = e.y / maxf(d, 1e-4)
		_pitch_vel = e.x / maxf(d, 1e-4)
	var follow := 1.0 - exp(-7.0 * d)
	yaw_f += (_yaw_vel - yaw_f) * follow
	pitch_f += (_pitch_vel - pitch_f) * follow
	_yaw_vel *= exp(-4.0 * d)
	_pitch_vel *= exp(-4.0 * d)

	if not hair_root_init:
		hair_root_prev = rp
		hair_root_rot_prev = rq
		hair_root_init = true
		for k in n:
			var gp: Array = _soft_pose(hair_names[k])
			hair_p[k] = gp[0]
			hair_prev[k] = gp[0]
	else:
		var dq2 := rq * hair_root_rot_prev.inverse()
		for k2 in range(1, n):
			hair_p[k2] = rp + dq2 * ((hair_p[k2] as Vector3) - hair_root_prev)
			hair_prev[k2] = rp + dq2 * ((hair_prev[k2] as Vector3) - hair_root_prev)

	hair_root_prev = rp
	hair_root_rot_prev = rq

	var neck_cut := 1.38
	if bone_i.has("C_Neck_a"):
		neck_cut = skeleton.get_bone_global_pose(bone_i["C_Neck_a"]).origin.y - 0.02
	elif rest_pos.has("C_Neck_a"):
		neck_cut = (rest_pos["C_Neck_a"] as Vector3).y - 0.02

	hair_p[0] = rp
	hair_prev[0] = rp
	var dt2 := d * d
	var g := hair_gravity * 1.8
	var hd := clampf(hair_damp, 0.0, 1.0)
	var hi := clampf(hair_inertia, 0.0, 1.0)
	var keep := 0.92 + hi * 0.07 - hd * 0.16
	var shape := 0.05 + hd * 0.07 - hi * 0.035
	var max_step := 0.02 + hi * 0.04

	for k3 in range(1, n):
		if k3 <= 1:
			var gp2: Array = _soft_pose(hair_names[k3])
			hair_p[k3] = gp2[0]
			hair_prev[k3] = gp2[0]
			continue
		var p: Vector3 = hair_p[k3]
		var prev: Vector3 = hair_prev[k3]
		var vel := (p - prev) * keep
		var spd := vel.length()
		if spd > max_step:
			vel *= max_step / spd
		if spd < 0.00018:
			vel = Vector3.ZERO
		var u := maxf(0.0, float(k3 - 1) / maxf(1.0, float(n - 2)))
		hair_prev[k3] = p
		p += vel
		p.x += (-yaw_f * 0.22 * u * hi + hair_wind * 0.5 * u) * dt2 * 60.0
		p.y += g * dt2
		p.z += pitch_f * 0.12 * u * hi * dt2 * 60.0
		var i_nm: String = hair_names[k3]
		var to: Vector3 = rq * ((rest_pos[i_nm] as Vector3) - (rest_pos[root_name] as Vector3)) + rp
		p.x += (to.x - p.x) * shape
		p.y += (to.y - p.y) * shape * 0.75
		p.z += (to.z - p.z) * shape
		if p.y < to.y - 0.1:
			p.y = to.y - 0.1
		if p.z > to.z + 0.03:
			p.z = to.z + 0.03
		if p.y < neck_cut:
			var cx := p.x
			var cz := p.z - 0.03
			var rad: float = sqrt((cx) * (cx) + (cz) * (cz))
			if rad < 0.118:
				var s2 := 0.118 / maxf(rad, 1e-6)
				p.x = cx * s2
				p.z = 0.03 + cz * s2
				if p.z > to.z:
					p.z = to.z
		hair_p[k3] = p

	for _iter in 3:
		hair_p[0] = rp
		for k4 in range(1, n):
			if k4 <= 1:
				hair_p[k4] = _soft_pose(hair_names[k4])[0]
				continue
			var a: Vector3 = hair_p[k4 - 1]
			var b: Vector3 = hair_p[k4]
			var from := b - a
			var lenv := maxf(from.length(), 1e-8)
			var rest_l: float = hair_len[k4] if hair_len[k4] > 0.0 else lenv
			hair_p[k4] = b - from * (((lenv - rest_l) / lenv) * 0.85)

	for k5 in n:
		var nm: String = hair_names[k5]
		var bi: int = bone_i[nm]
		if k5 <= 1:
			skeleton.set_bone_pose_rotation(bi, rest_local_q[nm])
			skeleton.set_bone_pose_position(bi, rest_origin[nm])
			continue

		var soft_off := Vector3.ZERO
		var par_name: String = bone_parent.get(nm, "")
		if k5 > 0 and (k5 - 1) <= 1 and par_name != "":
			var par_pose: Array = _soft_pose(par_name)
			var rest_delta: Vector3 = rest_pos[nm] - rest_pos[par_name]
			var to2: Vector3 = (par_pose[1] as Quaternion).inverse() * (
				(hair_p[k5] as Vector3) - (par_pose[0] as Vector3)
			)
			soft_off = to2 - rest_delta

		var soft_q := Quaternion.IDENTITY
		if k5 < n - 1:
			var c_nm: String = hair_names[k5 + 1]
			var from3: Vector3 = (rest_pos[c_nm] as Vector3) - (rest_pos[nm] as Vector3)
			var to3: Vector3 = (hair_p[k5 + 1] as Vector3) - (hair_p[k5] as Vector3)
			if from3.length_squared() > 1e-10 and to3.length_squared() > 1e-10:
				from3 = from3.normalized()
				to3 = to3.normalized()
				if par_name != "":
					to3 = (_soft_pose(par_name)[1] as Quaternion).inverse() * to3
				if from3.dot(to3) > 0.9995:
					soft_q = soft_q.slerp(Quaternion.IDENTITY, 0.22)
				else:
					soft_q = Quaternion.IDENTITY.slerp(_quat_from_unit_vectors(from3, to3), 0.4)
			else:
				soft_q = soft_q.slerp(Quaternion.IDENTITY, 0.3)
		else:
			soft_q = soft_q.slerp(Quaternion.IDENTITY, 0.3)

		skeleton.set_bone_pose_rotation(bi, _soft_to_godot(nm, soft_q))
		if soft_off.length_squared() > 1e-12 and par_name != "":
			skeleton.set_bone_pose_position(
				bi, rest_origin[nm] + (rest_world_q[par_name] as Quaternion).inverse() * soft_off
			)
		else:
			skeleton.set_bone_pose_position(bi, rest_origin[nm])


func debug_jerk_root(offset: Vector3) -> void:
	if not hair_root_init:
		return
	hair_root_prev += offset
	for k in hair_p.size():
		hair_p[k] = (hair_p[k] as Vector3) + offset
		hair_prev[k] = (hair_prev[k] as Vector3) + offset


func debug_snapshot() -> Dictionary:
	var tip := Vector3.ZERO
	var tip_rest := Vector3.ZERO
	var tip_p := Vector3.ZERO
	if hair_names.size() > 0:
		var tn: String = hair_names[hair_names.size() - 1]
		tip_rest = rest_pos.get(tn, Vector3.ZERO)
		if bone_i.has(tn):
			tip = skeleton.get_bone_global_pose(bone_i[tn]).origin
		if hair_p.size() > 0:
			tip_p = hair_p[hair_p.size() - 1]
	return {
		"blink_amt": blink_amt,
		"blink_t": blink_t,
		"next_blink": next_blink,
		"close_l": close_l,
		"close_r": close_r,
		"breath_in": breath_in,
		"breath_chest": breath_chest,
		"hair_count": hair_names.size(),
		"lid_count": lid_names.size(),
		"hair_tip": [tip.x, tip.y, tip.z],
		"hair_tip_rest": [tip_rest.x, tip_rest.y, tip_rest.z],
		"hair_p_tip": [tip_p.x, tip_p.y, tip_p.z],
	}


func _quat_euler_xyz(ex: float, ey: float, ez: float) -> Quaternion:
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


func _quat_euler_yxz(ex: float, ey: float, ez: float) -> Quaternion:
	var c1 := cos(ey * 0.5)
	var c2 := cos(ex * 0.5)
	var c3 := cos(ez * 0.5)
	var s1 := sin(ey * 0.5)
	var s2 := sin(ex * 0.5)
	var s3 := sin(ez * 0.5)
	return Quaternion(
		s2 * c1 * c3 + c2 * s1 * s3,
		c2 * s1 * c3 - s2 * c1 * s3,
		c2 * c1 * s3 - s2 * s1 * c3,
		c2 * c1 * c3 + s2 * s1 * s3
	)


func _quat_to_euler_yxz(q: Quaternion) -> Vector3:
	var sinp := 2.0 * (q.w * q.x - q.y * q.z)
	var pitch: float
	if absf(sinp) >= 1.0:
		pitch = signf(sinp) * PI * 0.5
	else:
		pitch = asin(sinp)
	var yaw := atan2(2.0 * (q.w * q.y + q.z * q.x), 1.0 - 2.0 * (q.x * q.x + q.y * q.y))
	return Vector3(pitch, yaw, 0.0)


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


func _soft_to_godot(bone_name: String, soft_q: Quaternion) -> Quaternion:
	var rest_q: Quaternion = rest_local_q.get(bone_name, Quaternion.IDENTITY)
	var parent: String = bone_parent.get(bone_name, "")
	var rest_w_p := Quaternion.IDENTITY
	if parent != "" and rest_world_q.has(parent):
		rest_w_p = rest_world_q[parent]
	return (rest_w_p.inverse() * soft_q * rest_w_p) * rest_q


func _soft_delta(bone_name: String, soft_q: Quaternion) -> Quaternion:
	var parent: String = bone_parent.get(bone_name, "")
	var rest_w_p := Quaternion.IDENTITY
	if parent != "" and rest_world_q.has(parent):
		rest_w_p = rest_world_q[parent]
	return rest_w_p.inverse() * soft_q * rest_w_p
