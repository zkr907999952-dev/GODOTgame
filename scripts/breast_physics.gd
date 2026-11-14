extends RefCounted
class_name BreastPhysics
## 真实物理乳摇：每侧一个「质点 + 弹簧阻尼」（主体）+ 一个跟随主体的高频「乳尖」弹簧（形变/甩动）。
##
## 网页 soft-skeleton.ts stepBreasts 的思路：用胸椎 C_Spine_d 的世界加速度反向驱动两级弹簧，
## 再旋转 L/R_Breast_a/b_Phy。Godot 这里只有 *_Breast_a_Phy 带蒙皮权重（b 无权重），所以：
##   - 主体位移 → a_Phy 的平移（权重在胸根处渐弱，等于软组织平滑形变）
##   - 乳尖相对主体的滞后 → 绕乳房中心的小角度倾斜（上下甩时乳尖先滞后再回弹）
## 物理全部在世界空间积分（锚点 = 胸骨上乳头静止点随 C_Spine_d 运动），因此走/跑的身体起伏、
## 起跳/落地（失重 → 上浮，落地 → 下坠）、蹲/匍匐过渡、转身（切向加速度）、呼吸都会自然驱动；
## 镜子渲染同一骨架，所以镜中一致。
## 固定 240Hz 子步积分，锚点在帧内线性插值 → 低帧率也不会抖或发散。

const SUBSTEP := 1.0 / 240.0
const MAX_SUBSTEPS := 24
const GRAVITY := Vector3(0.0, -9.8, 0.0)

var enabled: bool = true
## 0..1，HUD「乳摇强度」。0.5 ≈ 自然；1 = 夸张。
var strength: float = 0.5

## 主体弹簧：频率(Hz)/阻尼比。竖直方向更软（乳房悬韧带）。
var freq_vert: float = 2.1
var freq_horiz: float = 2.6
var damping: float = 0.16
## 乳尖二级弹簧
var tip_freq: float = 4.8
var tip_damping: float = 0.22
## 静止时额外的重力下垂（米，世界向下），很小，只为让「失重上浮 / 落地下坠」有参照。
var static_sag: float = 0.003

var skeleton: Skeleton3D
var _spine_i: int = -1
var _sides: Array = []  # Array[Dictionary]
var _acc: float = 0.0
var _inited: bool = false


func setup(skel: Skeleton3D) -> bool:
	skeleton = skel
	_sides.clear()
	_spine_i = skel.find_bone("C_Spine_d")
	if _spine_i < 0:
		return false
	var spine_rest := skel.get_bone_global_rest(_spine_i)
	for side in ["L", "R"]:
		var a := skel.find_bone("%s_Breast_a_Phy" % side)
		var b := skel.find_bone("%s_Breast_b_Phy" % side)
		if a < 0 or b < 0:
			continue
		var par := skel.get_bone_parent(a)
		var a_rest := skel.get_bone_global_rest(a)
		var nip: Vector3 = skel.get_bone_global_rest(b).origin
		var par_rest := skel.get_bone_global_rest(par)
		# 乳房中心：乳头往胸壁方向约 4.5cm
		var center: Vector3 = nip + Vector3(0.0, -0.01, -0.045)
		_sides.append({
			"bone": a,
			"parent": par,
			"rest_q": skel.get_bone_rest(a).basis.get_rotation_quaternion(),
			"rest_o": skel.get_bone_rest(a).origin,
			"rest_s": skel.get_bone_rest(a).basis.get_scale(),
			# 锚点在 C_Spine_d 静止局部空间中的位置（乳头静止点）
			"anchor_local": spine_rest.affine_inverse() * nip,
			# 乳房中心相对 a_Phy 原点，在父骨骼(Spo)静止空间下
			"center_p": par_rest.basis.inverse() * (center - a_rest.origin),
			"fscale": 1.0 if side == "L" else 1.06,  # 左右略不同 → 自然相位差
			"p": Vector3.ZERO, "v": Vector3.ZERO,       # 主体质点（世界）
			"tp": Vector3.ZERO, "tv": Vector3.ZERO,     # 乳尖相对主体的位移/速度
			"a_prev": Vector3.ZERO,
			"disp": Vector3.ZERO,                        # 最近一次输出位移（世界，已限幅）
			"tilt": Vector3.ZERO,
			"rv": Vector3.ZERO,
		})
	_inited = false
	return _sides.size() == 2


func reset() -> void:
	_inited = false
	if skeleton == null:
		return
	for s in _sides:
		var i: int = s["bone"]
		skeleton.set_bone_pose_rotation(i, s["rest_q"])
		skeleton.set_bone_pose_position(i, s["rest_o"])
		s["disp"] = Vector3.ZERO
		s["tilt"] = Vector3.ZERO


func _anchor_world(s: Dictionary) -> Vector3:
	var spine := skeleton.get_bone_global_pose(_spine_i)
	return skeleton.global_transform * (spine * (s["anchor_local"] as Vector3))


func _equilibrium_offset(fs: float) -> Vector3:
	# 弹簧静止点抬高 g/k，使静止时质点只下垂 static_sag：失重时会上浮 g/k（再被限幅）。
	var wv := TAU * freq_vert * fs
	return Vector3(0.0, -static_sag, 0.0) - GRAVITY / (wv * wv)


func update(delta: float) -> void:
	if skeleton == null or _sides.is_empty():
		return
	if not enabled or strength <= 0.001:
		if _inited:
			reset()
		return
	var anchors: Array = []
	for s in _sides:
		anchors.append(_anchor_world(s))
	if not _inited:
		for k in _sides.size():
			var s0: Dictionary = _sides[k]
			var a0: Vector3 = anchors[k]
			s0["a_prev"] = a0
			s0["p"] = a0 + Vector3(0.0, -static_sag, 0.0)
			s0["v"] = Vector3.ZERO
			s0["tp"] = Vector3.ZERO
			s0["tv"] = Vector3.ZERO
		_inited = true
		_acc = 0.0
	var dt := clampf(delta, 0.0, 0.1)
	_acc += dt
	var steps := int(floor(_acc / SUBSTEP))
	if steps > MAX_SUBSTEPS:
		steps = MAX_SUBSTEPS
		_acc = 0.0
	else:
		_acc -= steps * SUBSTEP
	for k in _sides.size():
		var s: Dictionary = _sides[k]
		var a1: Vector3 = anchors[k]
		var a0: Vector3 = s["a_prev"]
		if a0.distance_to(a1) > 0.6:
			# 传送（换地图）→ 直接复位，避免巨大冲击。
			a0 = a1
			s["p"] = a1 + Vector3(0.0, -static_sag, 0.0)
			s["v"] = Vector3.ZERO
			s["tp"] = Vector3.ZERO
			s["tv"] = Vector3.ZERO
		s["a_prev"] = a1
		if steps > 0:
			_integrate(s, a0, a1, steps)
		_apply(s, a1)


func _integrate(s: Dictionary, a0: Vector3, a1: Vector3, steps: int) -> void:
	var fs: float = s["fscale"]
	var wv := TAU * freq_vert * fs
	var wh := TAU * freq_horiz * fs
	var kv := wv * wv
	var kh := wh * wh
	var cv := 2.0 * damping * wv
	var ch := 2.0 * damping * wh
	var wt := TAU * tip_freq * fs
	var kt := wt * wt
	var ct := 2.0 * tip_damping * wt
	var eq := _equilibrium_offset(fs)
	var span := float(steps) * SUBSTEP
	var va := (a1 - a0) / maxf(span, 1e-5)
	var p: Vector3 = s["p"]
	var v: Vector3 = s["v"]
	var tp: Vector3 = s["tp"]
	var tv: Vector3 = s["tv"]
	for i in steps:
		var a := a0.lerp(a1, float(i + 1) / float(steps))
		var x := p - (a + eq)
		var rv := v - va
		var f := Vector3(-kh * x.x - ch * rv.x, -kv * x.y - cv * rv.y, -kh * x.z - ch * rv.z)
		var acc := f + GRAVITY
		v += acc * SUBSTEP
		p += v * SUBSTEP
		# 乳尖：被主体的加速度甩动（相对坐标），自身高频回弹
		# 主体相对锚点的加速度越大，乳尖滞后越多（惯性），随后高频回弹
		var tacc := -kt * tp - ct * tv - f * 0.6
		tv += tacc * SUBSTEP
		tp += tv * SUBSTEP
	s["p"] = p
	s["v"] = v
	s["tp"] = tp
	s["tv"] = tv
	s["rv"] = v - va


func _apply(s: Dictionary, anchor: Vector3) -> void:
	var gain := lerpf(0.25, 1.7, clampf(strength, 0.0, 1.0))
	var d: Vector3 = ((s["p"] as Vector3) - anchor - Vector3(0.0, -static_sag, 0.0)) * gain
	# 椭球限幅（侧向 / 竖直 / 前后），超过时柔性压缩，不会硬顶。
	var lim := Vector3(0.022, 0.03, 0.018) * lerpf(0.7, 1.35, clampf(strength, 0.0, 1.0))
	var n := Vector3(d.x / lim.x, d.y / lim.y, d.z / lim.z)
	var nl := n.length()
	if nl > 0.75:
		var soft := 0.75 + 0.25 * tanh((nl - 0.75) / 0.25)
		d *= soft / nl
	s["disp"] = d
	var i: int = s["bone"]
	var par: int = s["parent"]
	var par_g := skeleton.get_bone_global_pose(par)
	var to_par := (skeleton.global_transform.basis * par_g.basis).inverse()
	var off_p := to_par * d
	# 乳尖滞后 → 绕乳房中心倾斜（父空间）
	var t_p := to_par * ((s["tp"] as Vector3) * gain)
	var lever := 0.07
	var pitch := clampf(-t_p.y / lever, -0.22, 0.22)
	var yaw := clampf(t_p.x / lever, -0.18, 0.18)
	var rp := Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)
	s["tilt"] = Vector3(pitch, yaw, 0.0)
	var c: Vector3 = s["center_p"]
	skeleton.set_bone_pose_rotation(i, (rp * (s["rest_q"] as Quaternion)).normalized())
	skeleton.set_bone_pose_position(i, (s["rest_o"] as Vector3) + off_p + c - rp * c)


## 调试 / 校验：返回 {L:{disp, tilt, speed}, R:{...}}
func debug_state() -> Dictionary:
	var out := {}
	for k in _sides.size():
		var s: Dictionary = _sides[k]
		out["L" if k == 0 else "R"] = {
			"disp": (s["disp"] as Vector3).length(),
			"disp_y": (s["disp"] as Vector3).y,
			"tilt": (s["tilt"] as Vector3).length(),
			"speed": (s["rv"] as Vector3).length(),
		}
	return out


## 调试 / 校验：给两侧主体一个速度冲量（模拟落地 / 急停）。
func debug_kick(vel: Vector3) -> void:
	for s in _sides:
		s["v"] = (s["v"] as Vector3) + vel
