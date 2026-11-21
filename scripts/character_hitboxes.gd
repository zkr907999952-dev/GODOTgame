extends Node3D
class_name CharacterHitboxes
## 0.3.8：跟随骨骼的精细胶囊碰撞箱（头 / 颈 / 胸 / 腹 / 骨盆 / 上臂 / 前臂 / 手 / 大腿 / 小腿 / 脚）。
## 每个部位一个 StaticBody3D + CapsuleShape3D，每个物理帧按骨骼姿态摆放（长度只在 setup 时按骨长算一次，
## 运行中不改形状，避免物理引擎重建）。放在独立的第 6 层（HITBOX_LAYER），角色移动胶囊（第 2 层）
## 不会和自己的碰撞箱互相顶；弹壳等小刚体、子弹精确命中、调试显示都用它。
## 死亡（布娃娃接管）时整体关闭，复活时再打开。

const HITBOX_LAYER := 1 << 5  # 第 6 层（值 32）

## [骨骼, 末端骨骼（"" = 沿骨骼 +Y 取固定长度）, 半径, 固定长度 / 最短长度, 轴 ("seg" | "x")]
const DEFS := [
	["C_Hip_a", "", 0.115, 0.13, "x"],
	["C_Spine_a", "C_Spine_c", 0.105, 0.10, "seg"],
	["C_Spine_c", "C_Neck_a", 0.115, 0.12, "seg"],
	["C_Neck_a", "C_Head_a", 0.045, 0.06, "seg"],
	["C_Head_a", "", 0.095, 0.10, "y"],
	["L_UpperArm_a", "L_Forearm_a", 0.045, 0.18, "seg"],
	["R_UpperArm_a", "R_Forearm_a", 0.045, 0.18, "seg"],
	["L_Forearm_a", "L_Hand_a", 0.038, 0.16, "seg"],
	["R_Forearm_a", "R_Hand_a", 0.038, 0.16, "seg"],
	["L_Hand_a", "L_Middle_a", 0.032, 0.07, "seg"],
	["R_Hand_a", "R_Middle_a", 0.032, 0.07, "seg"],
	["L_UpperLeg_a", "L_Foreleg_a", 0.075, 0.30, "seg"],
	["R_UpperLeg_a", "R_Foreleg_a", 0.075, 0.30, "seg"],
	["L_Foreleg_a", "L_Foot_a", 0.055, 0.30, "seg"],
	["R_Foreleg_a", "R_Foot_a", 0.055, 0.30, "seg"],
	["L_Foot_a", "L_Toe_a", 0.04, 0.10, "seg"],
	["R_Foot_a", "R_Toe_a", 0.04, 0.10, "seg"],
]

var skeleton: Skeleton3D
var host: Node = null
var enabled: bool = true
var _parts: Array = []  # {body, cs, bone, child, len, axis, name}


func setup(skel: Skeleton3D, host_node: Node) -> bool:
	skeleton = skel
	host = host_node
	name = "Hitboxes"
	top_level = true
	if skeleton == null:
		return false
	for d in DEFS:
		var bi := skeleton.find_bone(str(d[0]))
		if bi < 0:
			continue
		var ci := skeleton.find_bone(str(d[1])) if str(d[1]) != "" else -1
		var r: float = float(d[2])
		var length: float = float(d[3])
		var axis: String = str(d[4])
		if ci >= 0 and axis == "seg":
			var a := skeleton.get_bone_global_rest(bi).origin
			var b := skeleton.get_bone_global_rest(ci).origin
			length = maxf(a.distance_to(b), length * 0.5)
		var body := StaticBody3D.new()
		body.name = "HB_" + str(d[0])
		body.collision_layer = HITBOX_LAYER
		body.collision_mask = 0
		body.set_meta("hitbox_bone", str(d[0]))
		body.set_meta("hitbox_host", host)
		body.add_to_group("character_hitbox")
		var cs := CollisionShape3D.new()
		cs.name = "Capsule"
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = length + r * 2.0
		cs.shape = cap
		body.add_child(cs)
		add_child(body)
		_parts.append({"body": body, "cs": cs, "bone": bi, "child": ci, "len": length, "axis": axis, "name": str(d[0])})
	sync()
	return not _parts.is_empty()


func part_count() -> int:
	return _parts.size()


func bodies() -> Array:
	var out: Array = []
	for p in _parts:
		out.append(p["body"])
	return out


func rids() -> Array[RID]:
	var out: Array[RID] = []
	for p in _parts:
		out.append((p["body"] as StaticBody3D).get_rid())
	return out


func owns(col: Object) -> bool:
	if col == null or not (col is Node):
		return false
	return (col as Node).get_parent() == self


func bone_of(col: Object) -> String:
	if col is Node and (col as Node).has_meta("hitbox_bone"):
		return str((col as Node).get_meta("hitbox_bone"))
	return ""


func set_enabled(on: bool) -> void:
	enabled = on
	for p in _parts:
		var body: StaticBody3D = p["body"]
		body.collision_layer = HITBOX_LAYER if on else 0
		(p["cs"] as CollisionShape3D).disabled = not on
	visible = on
	if on:
		sync()


func _physics_process(_delta: float) -> void:
	if enabled:
		sync()


## 按当前骨骼姿态摆放所有胶囊（骨骼空间 → 世界）。
func sync() -> void:
	if skeleton == null or not is_instance_valid(skeleton) or not skeleton.is_inside_tree():
		return
	var sx := skeleton.global_transform
	for p in _parts:
		var bxf: Transform3D = sx * skeleton.get_bone_global_pose(int(p["bone"]))
		var a := bxf.origin
		var dir: Vector3
		var length: float = float(p["len"])
		var axis: String = str(p["axis"])
		var center: Vector3
		if axis == "x":
			dir = bxf.basis.x.normalized()
			center = a
		elif int(p["child"]) >= 0 and axis == "seg":
			var b: Vector3 = (sx * skeleton.get_bone_global_pose(int(p["child"]))).origin
			dir = b - a
			if dir.length_squared() < 1e-8:
				dir = bxf.basis.y
			dir = dir.normalized()
			center = a + dir * (length * 0.5)
		else:
			dir = bxf.basis.y.normalized()
			center = a + dir * (length * 0.5)
		var basis := _basis_y_to(dir, bxf.basis.z)
		(p["body"] as StaticBody3D).global_transform = Transform3D(basis, center)


static func _basis_y_to(y: Vector3, hint_z: Vector3) -> Basis:
	var yy := y.normalized()
	var z := hint_z - yy * hint_z.dot(yy)
	if z.length_squared() < 1e-8:
		z = Vector3.FORWARD if absf(yy.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
		z = z - yy * z.dot(yy)
	z = z.normalized()
	var x := yy.cross(z).normalized()
	return Basis(x, yy, z)
