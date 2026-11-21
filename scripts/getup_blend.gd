extends RefCounted
## 0.3.8「复原身体」起身过渡：复活时记下布娃娃当前的全部骨骼世界姿态，
## 之后每帧在程序动画（先蹲下，再站起）写完骨骼后，把骨骼从布娃娃姿态平滑混合到动画姿态。
## 时间线：0 → BLEND_DUR 从布娃娃混到蹲姿；CROUCH_HOLD 后调用方切回站立（soft_loco 自带蹲→站过渡）。

const BLEND_DUR := 0.75
const CROUCH_HOLD := 0.55

var skeleton: Skeleton3D
var t: float = 0.0
var active: bool = false
var stood: bool = false
var _snap_world: Array[Transform3D] = []
var _local_rot: Array[Quaternion] = []
var _local_pos: Array[Vector3] = []
var _base_rot: Array[Quaternion] = []
var _base_pos: Array[Vector3] = []
var _out_rot: Array[Quaternion] = []
var _out_pos: Array[Vector3] = []


## 在关闭布娃娃之前调用：记录每根骨骼的世界变换。
static func capture_world(skel: Skeleton3D) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if skel == null:
		return out
	var sx := skel.global_transform
	for i in skel.get_bone_count():
		out.append(sx * skel.get_bone_global_pose(i))
	return out


## 角色原点已经挪到起身位置后调用：把世界快照换算成相对新骨架的局部姿态。
func begin(skel: Skeleton3D, snap_world: Array[Transform3D]) -> void:
	skeleton = skel
	_snap_world = snap_world
	t = 0.0
	stood = false
	active = skel != null and snap_world.size() == skel.get_bone_count()
	_local_rot.clear()
	_local_pos.clear()
	_base_rot.clear()
	_base_pos.clear()
	_out_rot.clear()
	_out_pos.clear()
	if not active:
		return
	var inv_sx := skeleton.global_transform.affine_inverse()
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		var local: Transform3D
		if parent >= 0:
			local = _snap_world[parent].affine_inverse() * _snap_world[i]
		else:
			local = inv_sx * _snap_world[i]
		_local_rot.append(local.basis.get_rotation_quaternion())
		_local_pos.append(local.origin)
		# 动画不每帧重写的骨骼（手指等）用开始时的姿态作基准，避免混合结果被一帧帧累积到布娃娃姿态。
		_base_rot.append(skeleton.get_bone_pose_rotation(i))
		_base_pos.append(skeleton.get_bone_pose_position(i))
		_out_rot.append(Quaternion(0, 0, 0, 0))
		_out_pos.append(Vector3.INF)


func weight() -> float:
	## 布娃娃姿态权重：1 = 完全布娃娃，0 = 完全动画。
	if not active:
		return 0.0
	var u := clampf(t / BLEND_DUR, 0.0, 1.0)
	u = u * u * (3.0 - 2.0 * u)
	return 1.0 - u


## 每帧在动画写完骨骼之后调用。返回 true 表示该切到站立了（只返回一次）。
func apply(delta: float) -> bool:
	if not active or skeleton == null or not is_instance_valid(skeleton):
		active = false
		return false
	t += delta
	var w := weight()
	if w > 0.0005:
		for i in mini(skeleton.get_bone_count(), _local_rot.size()):
			var cur_q := skeleton.get_bone_pose_rotation(i)
			if cur_q.is_equal_approx(_out_rot[i]):
				cur_q = _base_rot[i]
			var q := cur_q.slerp(_local_rot[i], w)
			skeleton.set_bone_pose_rotation(i, q)
			_out_rot[i] = q
			var cur_p := skeleton.get_bone_pose_position(i)
			if cur_p.is_equal_approx(_out_pos[i]):
				cur_p = _base_pos[i]
			var pp := cur_p.lerp(_local_pos[i], w)
			skeleton.set_bone_pose_position(i, pp)
			_out_pos[i] = pp
	elif not _out_rot.is_empty():
		# 混合结束：没被动画重写的骨骼还原到基准姿态。
		for i in mini(skeleton.get_bone_count(), _out_rot.size()):
			if skeleton.get_bone_pose_rotation(i).is_equal_approx(_out_rot[i]):
				skeleton.set_bone_pose_rotation(i, _base_rot[i])
			if skeleton.get_bone_pose_position(i).is_equal_approx(_out_pos[i]):
				skeleton.set_bone_pose_position(i, _base_pos[i])
		_out_rot.clear()
		_out_pos.clear()
	var want_stand := false
	if not stood and t >= BLEND_DUR + CROUCH_HOLD:
		stood = true
		want_stand = true
	if t >= BLEND_DUR + CROUCH_HOLD + 0.8:
		active = false
	return want_stand


func is_active() -> bool:
	return active
