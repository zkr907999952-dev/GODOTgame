extends RefCounted
## 角色「动作」注册表（可扩展）：互动菜单「动作」栏与检查床「动作」按钮共用。
##
## 新动作：在 ACTIONS 里加一项 {id, label, stop_label}，在 is_action_available() 里写出现条件，
## 并在 apply_pose() 里按 id 摆姿势。每个角色（本体 / 分身）各有一份实例。
## 第一项「掰开小穴」（spread_vulva）：双手 IK 伸到外阴，食指 / 中指指腹落在左右大阴唇靠裂隙一侧，
## 手到位后把 OrganRig.set_vulva_spread 从 0 推到 1。再点一次或选「停止」：先合拢再收手。
##
## 姿势按解剖尺寸计算（躯干前表面轮廓、外阴皮瓣顶点、手骨链长度）。站立 / 载具 / 检查床都可用。

const ACTIONS := [
	{"id": "spread_vulva", "label": "掰开小穴", "stop_label": "停止掰开"},
]

const HAND_IN_SEC := 0.7
const SPREAD_SEC := 0.55
const FINGER_SKIN := 0.0075   # 指腹中心离皮肤（米），略抬以免陷入阴唇
const PALM_SKIN := 0.028      # 手腕离小腹皮肤

var active_id: String = ""
var hand_u: float = 0.0       # 0 = 手在扶手，1 = 手在外阴
var spread_u: float = 0.0     # 驱动 set_vulva_spread
var last_tip_err: Array = [0.0, 0.0]
var last_wrist_clear: float = 1.0
var last_hand_world: Array = [Vector3.ZERO, Vector3.ZERO]
var last_tip_world: Array = [Vector3.ZERO, Vector3.ZERO]
var _rig: Node = null


func list(host: Node = null) -> Array:
	var out: Array = []
	for a in ACTIONS:
		var d: Dictionary = (a as Dictionary).duplicate()
		d["active"] = active_id == str(a["id"])
		d["available"] = true if host == null else is_action_available(host, str(a["id"]))
		out.append(d)
	return out


## 当前角色是否能开始（或继续）这个动作。注册表预留：按 id 分支即可。
func is_action_available(host: Node, id: String = "") -> bool:
	if host == null or not is_instance_valid(host):
		return false
	if host.has_method("is_dead") and bool(host.call("is_dead")):
		return false
	if _host_ragdoll(host):
		return false
	var surg: Node = host.call("get_surgery") if host.has_method("get_surgery") else null
	if surg and surg.has_method("is_active") and bool(surg.call("is_active")):
		return false
	if host.has_method("weapon_drawn") and bool(host.call("weapon_drawn")):
		return false
	var organs: Node = host.call("get_organs") if host.has_method("get_organs") else null
	if organs == null or not organs.has_method("vulva_flaps"):
		return false
	var vf = organs.call("vulva_flaps")
	if vf == null or not bool(vf.ok):
		return false
	if id == "" or id == "spread_vulva":
		return true
	return false


func _host_ragdoll(host: Node) -> bool:
	if host.has_method("is_ragdoll"):
		return bool(host.call("is_ragdoll"))
	var rd = host.get("ragdoll") if "ragdoll" in host else (host.get("_ragdoll") if "_ragdoll" in host else null)
	return rd != null and bool(rd.get("active"))


## 对指定角色切换动作（互动栏用）。进行中的同一动作再点 = 停止。
func toggle_on(host: Node, id: String) -> bool:
	if active_id == id:
		stop()
		return false
	if not is_action_available(host, id):
		return false
	if host and host.has_method("get_hit_reaction"):
		var hr: Node = host.call("get_hit_reaction")
		if hr and hr.has_method("clear_cover"):
			hr.call("clear_cover")
		elif hr:
			hr.set("cover_life", 0.0)
			hr.set("cover_weight", 0.0)
	return toggle(id)


func is_active(id: String = "") -> bool:
	return active_id != "" if id == "" else active_id == id


## 切换：没在做 → 开始；正在做同一个 → 停止；正在做另一个 → 换成这个。
func toggle(id: String) -> bool:
	if active_id == id:
		stop()
		return false
	for a in ACTIONS:
		if str(a["id"]) == id:
			active_id = id
			return true
	return false


func stop() -> void:
	active_id = ""


## 立即复位（下床 / 附身 / 死亡）：合拢、手不再覆盖。
func reset(rig: Node = null) -> void:
	active_id = ""
	hand_u = 0.0
	spread_u = 0.0
	var r: Node = rig if rig else _rig
	if r and is_instance_valid(r) and r.has_method("set_vulva_spread"):
		r.call("set_vulva_spread", 0.0)
	_rig = null


const _STATE_KEYS := ["active_id", "hand_u", "spread_u", "last_tip_err", "last_wrist_clear", "last_hand_world", "last_tip_world", "_rig"]


## t99u 附身：动作进度属于身体，与另一份实例互换状态（实例本身不换，别处缓存的引用仍有效）。
func swap_state_with(other) -> void:
	if other == null or other == self:
		return
	for k in _STATE_KEYS:
		var a = get(k)
		set(k, other.get(k))
		other.set(k, a)


func busy() -> bool:
	return active_id != "" or hand_u > 0.0 or spread_u > 0.0


## 每个物理帧：推进时间线并把外阴开度写入 OrganRig。
func step(delta: float, rig: Node) -> void:
	if rig != _rig and _rig != null and is_instance_valid(_rig) and _rig.has_method("set_vulva_spread"):
		_rig.call("set_vulva_spread", 0.0)
	_rig = rig
	var want := active_id == "spread_vulva"
	if want:
		hand_u = minf(1.0, hand_u + delta / HAND_IN_SEC)
		if hand_u >= 1.0:
			spread_u = minf(1.0, spread_u + delta / SPREAD_SEC)
	else:
		if spread_u > 0.0:
			spread_u = maxf(0.0, spread_u - delta / SPREAD_SEC)
		else:
			hand_u = maxf(0.0, hand_u - delta / HAND_IN_SEC)
	if rig and rig.has_method("set_vulva_spread"):
		rig.call("set_vulva_spread", _smooth(spread_u))


static func _smooth(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 在 ExamPose（手在扶手）之后调用：按 hand_u 把双手从当前位置插值到外阴。
func apply_pose(skel: Skeleton3D, rig: Node) -> void:
	if skel == null or rig == null or hand_u <= 0.0:
		return
	var vf = rig.call("vulva_flaps") if rig.has_method("vulva_flaps") else null
	if vf == null or not bool(vf.ok):
		return
	var meta: Dictionary = rig.get("meta") if rig.get("meta") != null else {}
	var u := _smooth(hand_u)
	var hi := skel.find_bone("C_Hip_a")
	if hi < 0:
		return
	# 绑定空间（Tifa 网格 / meta 坐标）→ 当前姿势世界：外阴区跟髋骨走
	var H: Transform3D = skel.global_transform * skel.get_bone_global_pose(hi) * skel.get_bone_global_rest(hi).affine_inverse()
	for side in [0, 1]:
		var left: bool = side == 0
		var sg := 1.0 if left else -1.0
		var c: Array = vf.contact(side)
		var tip_b: Vector3 = (c[0] as Vector3) + (c[1] as Vector3) * FINGER_SKIN
		# 指向：从小腹（腕）沿阴阜表面往下到指尖；腕离皮肤 PALM_SKIN、略偏外侧。
		var flen := _finger_len(skel, left)
		# 检查床大腿外展时手腕稍偏外；站立并腿时更靠前、少向外，减少穿大腿 / 阴唇。
		var open := _thigh_open(skel)
		var lat := lerpf(0.054, 0.086, open)
		var wrist_b := Vector3(sg * lat, tip_b.y + flen * 0.66, 0.0)
		wrist_b.z = _zfront(meta, wrist_b.y) + PALM_SKIN + lerpf(0.006, 0.0, open)
		var f := (tip_b - wrist_b).normalized()
		for _it in 4:
			wrist_b = tip_b - f * flen
			var need := _zfront(meta, wrist_b.y) + PALM_SKIN - wrist_b.z
			if need <= 0.0:
				break
			f = (tip_b - (wrist_b + Vector3(0.0, 0.0, need))).normalized()
		wrist_b = tip_b - f * flen
		var clr := wrist_b.z - _zfront(meta, wrist_b.y)
		last_wrist_clear = clr if side == 0 else minf(last_wrist_clear, clr)
		var wrist_w: Vector3 = H * wrist_b
		var tip_w: Vector3 = H * tip_b
		# 当前（扶手）手腕位置 → 插值
		var ha := skel.find_bone("L_Hand_a" if left else "R_Hand_a")
		if ha < 0:
			continue
		var cur_w: Vector3 = skel.global_transform * skel.get_bone_global_pose(ha).origin
		var cur_b: Basis = (skel.global_transform.basis * skel.get_bone_global_pose(ha).basis).orthonormalized()
		var goal := cur_w.lerp(wrist_w, u)
		goal = _clear_thighs(skel, goal, 0.090)
		_ik_arm(skel, left, goal, H.basis * Vector3(sg * lerpf(0.12, 0.20, _thigh_open(skel)), 0.04, -0.05))
		# 手掌：手骨 +Y（指向手指）对准指尖，掌心朝向身体（-皮肤法线）
		var n_in_w: Vector3 = -(H.basis * (c[1] as Vector3)).normalized()
		var want_b := _hand_basis(skel, left, (tip_w - wrist_w).normalized(), n_in_w)
		var q := cur_b.get_rotation_quaternion().slerp(want_b.get_rotation_quaternion(), u)
		_set_bone_world_basis(skel, ha, Basis(q))
		_curl_fingers(skel, left, u)
		skel.force_update_transform()
		# 指骨静止朝向与手骨 +Y 并不完全一致（左手偏差尤其大）→ 绕手腕把实际指尖方向转到目标方向。
		for _k in 2:
			var hw: Vector3 = skel.global_transform * skel.get_bone_global_pose(ha).origin
			var tc := (_tip_world(skel, skel.find_bone("L_Middle_c" if left else "R_Middle_c")) + _tip_world(skel, skel.find_bone("L_Index_c" if left else "R_Index_c"))) * 0.5
			var d_cur := tc - hw
			var d_want := tip_w.lerp(cur_w + (tc - hw), 1.0 - u) - hw
			if d_cur.length_squared() < 1e-8 or d_want.length_squared() < 1e-8 or d_cur.normalized().dot(d_want.normalized()) > 0.99999:
				break
			var corr := Quaternion(d_cur.normalized(), d_want.normalized())
			var hb := (skel.global_transform.basis * skel.get_bone_global_pose(ha).basis).orthonormalized()
			_set_bone_world_basis(skel, ha, Basis(corr) * hb)
			skel.force_update_transform()
		var mid_c := skel.find_bone("L_Middle_c" if left else "R_Middle_c")
		var idx_c := skel.find_bone("L_Index_c" if left else "R_Index_c")
		var tips := Vector3.ZERO
		for b in [mid_c, idx_c]:
			tips += _tip_world(skel, b)
		tips *= 0.5
		last_tip_err[side] = tips.distance_to(tip_w)
		last_hand_world[side] = skel.global_transform * skel.get_bone_global_pose(ha).origin
		last_tip_world[side] = tips


## 指尖（末节骨再往外延一节的 0.8 倍）
static func _tip_world(skel: Skeleton3D, c_idx: int) -> Vector3:
	if c_idx < 0:
		return Vector3.ZERO
	var b := skel.get_bone_parent(c_idx)
	var pc := skel.get_bone_global_pose(c_idx).origin
	var pb := skel.get_bone_global_pose(b).origin
	return skel.global_transform * (pc + (pc - pb) * 0.8)


static func _finger_len(skel: Skeleton3D, left: bool) -> float:
	var ha := skel.find_bone("L_Hand_a" if left else "R_Hand_a")
	var mc := skel.find_bone("L_Middle_c" if left else "R_Middle_c")
	var ic := skel.find_bone("L_Index_c" if left else "R_Index_c")
	if ha < 0 or mc < 0:
		return 0.14
	var h := skel.get_bone_global_rest(ha).origin
	var t1 := _rest_tip(skel, mc)
	var t2 := _rest_tip(skel, ic) if ic >= 0 else t1
	return h.distance_to((t1 + t2) * 0.5)


static func _rest_tip(skel: Skeleton3D, c_idx: int) -> Vector3:
	var b := skel.get_bone_parent(c_idx)
	var pc := skel.get_bone_global_rest(c_idx).origin
	var pb := skel.get_bone_global_rest(b).origin
	return pc + (pc - pb) * 0.8


## 0 = 并腿站立，1 = 检查床那样外展。
static func _thigh_open(skel: Skeleton3D) -> float:
	var lu := skel.find_bone("L_UpperLeg_a")
	var ru := skel.find_bone("R_UpperLeg_a")
	var lf := skel.find_bone("L_Foreleg_a")
	var rf := skel.find_bone("R_Foreleg_a")
	if lu < 0 or ru < 0 or lf < 0 or rf < 0:
		return 0.0
	var xf := skel.global_transform
	var l := xf * skel.get_bone_global_pose(lf).origin
	var r := xf * skel.get_bone_global_pose(rf).origin
	var span := l.distance_to(r)
	return clampf((span - 0.22) / 0.45, 0.0, 1.0)


## 把目标点推离大腿骨轴，避免手指 / 手腕陷进大腿。
static func _clear_thighs(skel: Skeleton3D, goal: Vector3, min_d: float) -> Vector3:
	var xf := skel.global_transform
	for pre in ["L_", "R_"]:
		var ua := skel.find_bone(pre + "UpperLeg_a")
		var fa := skel.find_bone(pre + "Foreleg_a")
		if ua < 0 or fa < 0:
			continue
		var a: Vector3 = xf * skel.get_bone_global_pose(ua).origin
		var b: Vector3 = xf * skel.get_bone_global_pose(fa).origin
		var q := Geometry3D.get_closest_point_to_segment(goal, a.lerp(b, 0.15), b)
		var d := goal.distance_to(q)
		if d < min_d and d > 1e-6:
			goal += (goal - q).normalized() * (min_d - d)
	return goal


## 躯干前表面 z（绑定空间，按高度插值 meta.profile）
static func _zfront(meta: Dictionary, y: float) -> float:
	var prof: Dictionary = meta.get("profile", {})
	var ys: Array = prof.get("y", [])
	var zs: Array = prof.get("z_front", [])
	if ys.is_empty():
		return 0.1
	if y <= float(ys[0]):
		return float(zs[0])
	for i in range(1, ys.size()):
		if y <= float(ys[i]):
			var t := (y - float(ys[i - 1])) / maxf(float(ys[i]) - float(ys[i - 1]), 1e-6)
			return lerpf(float(zs[i - 1]), float(zs[i]), t)
	return float(zs[zs.size() - 1])


## 期望手骨世界朝向：+Y = 指向 f；掌心（静止姿势里由手指方向 × 食指→小指横向算出）= n_in。
static func _hand_basis(skel: Skeleton3D, left: bool, f: Vector3, n_in: Vector3) -> Basis:
	var ha := skel.find_bone("L_Hand_a" if left else "R_Hand_a")
	var ia := skel.find_bone("L_Index_a" if left else "R_Index_a")
	var pa := skel.find_bone("L_Pinky_a" if left else "R_Pinky_a")
	var rest := skel.get_bone_global_rest(ha)
	var fing := rest.basis.y.normalized()
	var across := skel.get_bone_global_rest(ia).origin - skel.get_bone_global_rest(pa).origin
	var palm := fing.cross(across).normalized()
	if not left:
		palm = -palm
	# 手骨局部系里的掌心方向
	var rb := rest.basis.orthonormalized()
	var pl := (rb.inverse() * palm)
	pl = (pl - Vector3.UP * pl.dot(Vector3.UP)).normalized()
	var lz := Vector3.UP.cross(pl).normalized()
	var L := Basis(pl, Vector3.UP, lz)     # 列：palm, Y, Y×palm（局部）
	var nw := (n_in - f * n_in.dot(f)).normalized()
	if nw.length_squared() < 1e-6:
		nw = f.cross(Vector3.RIGHT).normalized()
	var wz := f.cross(nw).normalized()
	var W := Basis(nw, f, wz)
	return (W * L.inverse()).orthonormalized()


## 指间关节微屈，指腹贴皮（拇指收在食指旁）
static func _curl_fingers(skel: Skeleton3D, left: bool, u: float) -> void:
	var pre := "L_" if left else "R_"
	var curl := {"Index": [0.08, 0.14], "Middle": [0.08, 0.14], "Ring": [0.20, 0.28], "Pinky": [0.26, 0.32], "Thumb": [0.14, 0.18]}
	for fname in curl.keys():
		var arr: Array = curl[fname]
		for k in 2:
			var seg := "b" if k == 0 else "c"
			var i := skel.find_bone(pre + str(fname) + "_" + seg)
			if i < 0:
				continue
			var rq := skel.get_bone_rest(i).basis.get_rotation_quaternion()
			skel.set_bone_pose_rotation(i, rq * Quaternion(Vector3.RIGHT, float(arr[k]) * u))


static func _set_bone_world_basis(skel: Skeleton3D, idx: int, world_b: Basis) -> void:
	var skel_b := skel.global_transform.basis.orthonormalized()
	var want_skel := skel_b.inverse() * world_b.orthonormalized()
	var parent := skel.get_bone_parent(idx)
	var parent_skel := Basis.IDENTITY
	if parent >= 0:
		parent_skel = skel.get_bone_global_pose(parent).basis.orthonormalized()
	skel.set_bone_pose_rotation(idx, (parent_skel.inverse() * want_skel).get_rotation_quaternion())


## 两骨 IK（与 ExamPose._ik_arm 同算法），肘部朝 pole_w（世界方向）。
static func _ik_arm(skel: Skeleton3D, left: bool, target_w: Vector3, pole_w: Vector3) -> void:
	var i_ua := skel.find_bone("L_UpperArm_a" if left else "R_UpperArm_a")
	var i_fa := skel.find_bone("L_Forearm_a" if left else "R_Forearm_a")
	var i_ha := skel.find_bone("L_Hand_a" if left else "R_Hand_a")
	if i_ua < 0 or i_fa < 0 or i_ha < 0:
		return
	var inv := skel.global_transform.affine_inverse()
	var p_ua := skel.get_bone_global_pose(i_ua).origin
	var p_fa := skel.get_bone_global_pose(i_fa).origin
	var p_ha := skel.get_bone_global_pose(i_ha).origin
	var tgt := inv * target_w
	var len1 := p_ua.distance_to(p_fa)
	var len2 := p_fa.distance_to(p_ha)
	var to_t := tgt - p_ua
	if to_t.length_squared() < 1e-8 or len1 < 1e-4 or len2 < 1e-4:
		return
	var dist := clampf(to_t.length(), 0.06, len1 + len2 - 0.004)
	var axis_dir := to_t.normalized()
	var pole := inv.basis * pole_w
	var pole_n := pole - axis_dir * pole.dot(axis_dir)
	pole_n = pole_n.normalized() if pole_n.length_squared() > 1e-8 else Vector3(0, 0, -1)
	var cos_sh := clampf((len1 * len1 + dist * dist - len2 * len2) / (2.0 * len1 * dist), -1.0, 1.0)
	var rot_axis := axis_dir.cross(pole_n)
	rot_axis = rot_axis.normalized() if rot_axis.length_squared() > 1e-8 else Vector3(1, 0, 0)
	var ua_dir := axis_dir.rotated(rot_axis, acos(cos_sh))
	_aim(skel, i_ua, ua_dir)
	var elbow := p_ua + ua_dir * len1
	var fa_dir := tgt - elbow
	if fa_dir.length_squared() > 1e-8:
		_aim(skel, i_fa, fa_dir.normalized())


## 把骨骼 +Y 对准 dir（骨架空间），保持最小旋转。
static func _aim(skel: Skeleton3D, idx: int, dir: Vector3) -> void:
	skel.force_update_transform()
	var g := skel.get_bone_global_pose(idx)
	var cur := g.basis.y.normalized()
	var q := Quaternion(cur, dir.normalized()) if cur.dot(dir) > -0.9999 else Quaternion(g.basis.x.normalized(), PI)
	var want := Basis(q) * g.basis.orthonormalized()
	var parent := skel.get_bone_parent(idx)
	var pb := skel.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
	skel.set_bone_pose_rotation(idx, (pb.inverse() * want).get_rotation_quaternion())
	skel.force_update_transform()
