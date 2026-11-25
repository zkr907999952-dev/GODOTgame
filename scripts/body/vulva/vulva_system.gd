extends "res://scripts/body/vulva_flaps.gd"
## 外阴 / 阴道入口子系统。OrganRig 只通过本类对话。
## 网格、顶点组、开合骨骼、通用插入物接口都挂在这里，方便以后加阴蒂、小阴唇细分或新道具。
class_name VulvaSystem

const ParamsScript := preload("res://scripts/body/vulva/vulva_params.gd")
const EnvelopeInserter := preload("res://scripts/body/vulva/envelope_inserter.gd")

var params: Resource
var inserter: RefCounted
## 命名顶点组 → 局部顶点索引。皮瓣组用 [side, index]；前庭组用线性下标。
var groups: Dictionary = {}


func _init() -> void:
	params = ParamsScript.new()


func build(dress: MeshInstance3D, vulva_point: Vector3, canal_opening: Vector3, mouth_loop: PackedVector3Array = PackedVector3Array()) -> bool:
	if params:
		# 与皮瓣脚本里的常量对齐（构建前写入，build 使用脚本常量；细分/圈数已在父类常量中）。
		pass
	var okb := super.build(dress, vulva_point, canal_opening, mouth_loop)
	if okb:
		_rebuild_groups()
	return okb


func set_inserter(ins: RefCounted) -> void:
	inserter = ins
	_inserter = ins
	if ins == null or not bool(ins.call("is_active")):
		_inserter = null
		set_introitus_open(0.0, 0.0, 0.0)
		return
	var env: Dictionary = ins.call("envelope")
	var hx := float(env.get("half_x", 0.0))
	var hy := float(env.get("half_y", 0.0))
	var sep := float(env.get("blade_sep", 0.0))
	var ax: Vector3 = env.get("axis", Vector3(0, 1, 0))
	var up: Vector3 = env.get("up", Vector3(0, 0, 1))
	set_introitus_open(hx, hy, float(ins.call("mix")), ax, up, 0.0, sep)
	_custom_ins = _inserter != null and not _inserter.has_method("configure") and _inserter.has_method("project_out") and _inserter.has_method("penetration")
	_active_inserter = ins


func set_capsule_insert(origin: Vector3, axis: Vector3, radius: float, mixv: float, up: Vector3 = Vector3.ZERO) -> void:
	## 手指 / 玩具 / 钳杆：一节胶囊在外口平面上就是圆截面。
	var ins = EnvelopeInserter.new()
	var u := up if up.length_squared() > 1e-8 else Vector3(0, 0, 1)
	ins.configure(radius, radius, mixv, axis, u, 0.0, params.along_range if params else 0.028)
	# origin 由外口中心承担；胶囊只提供半径。调用方可先把 origin 传到 set_introitus。
	set_inserter(ins)


func group_indices(name: String) -> Array:
	return groups.get(name, [])


func _rebuild_groups() -> void:
	groups.clear()
	groups["labia_majora_l"] = []
	groups["labia_majora_r"] = []
	groups["labia_minora_l"] = []
	groups["labia_minora_r"] = []
	groups["clitoral_hood"] = []
	groups["introitus_ring"] = []
	groups["body_seam"] = []
	for si in 2:
		var P: PackedVector3Array = (_arrays[si] as Array)[Mesh.ARRAY_VERTEX] if not (_arrays[si] as Array).is_empty() else PackedVector3Array()
		var w: PackedFloat32Array = _w[si]
		var pin: PackedByteArray = _pin[si] if _pin.size() > si else PackedByteArray()
		for i in P.size():
			var rec := [si, i]
			var wx := clampf(1.0 - absf(P[i].x) / maxf(params.region_half_x if params else 0.017, 1e-5), 0.0, 1.0)
			if i < pin.size() and pin[i] != 0:
				(groups["body_seam"] as Array).append(rec)
			if wx > 0.55:
				if si == 0:
					(groups["labia_minora_l"] as Array).append(rec)
				else:
					(groups["labia_minora_r"] as Array).append(rec)
			else:
				if si == 0:
					(groups["labia_majora_l"] as Array).append(rec)
				else:
					(groups["labia_majora_r"] as Array).append(rec)
			# 前联合附近、靠头侧 = 阴蒂包皮预留组。
			if wx > 0.35 and P[i].dot(slit_dir) > 0.0 and P[i].z >= vulva.z - 0.002:
				(groups["clitoral_hood"] as Array).append(rec)
	for e in _rim:
		(groups["introitus_ring"] as Array).append(e)
	# 前庭按深度分段，以后可单独做通道段变形。
	for r in VEST_ROWS + 1:
		var key := "canal_seg_%d" % r
		groups[key] = []
		for k in VEST_N:
			(groups[key] as Array).append(r * VEST_N + k)


var _active_inserter: RefCounted
