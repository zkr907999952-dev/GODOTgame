extends StaticBody3D
## 房间简化碰撞（替代逐网格 trimesh）。
## 旧做法把地毯（1cm 厚）、被子、枕头、台灯都做成凹多边形碰撞：胶囊走到地毯边缘就被
## 1cm 的台阶卡住（is_on_wall=false、速度不为 0 却不动），+Z 镜子一侧没有墙会掉出房间。
## 这里只保留盒子：地面 / 天花 / 四面墙（镜面也是一面隐形墙）/ 隔断柱 / 床 / 床头柜 / 椅子 / 矮柜。
## 尺寸取自 room.glb 的世界坐标包围盒（房间节点已缩放 0.7、旋转 180°）。

## [min, max]（世界坐标，米）
const BOXES := [
	["floor", Vector3(-2.3, -0.3, -3.6), Vector3(3.9, 0.0, 1.25)],
	["ceiling", Vector3(-2.3, 2.4, -3.6), Vector3(3.9, 2.7, 1.25)],
	["wall_left", Vector3(-2.3, 0.0, -3.6), Vector3(-2.035, 2.4, 1.25)],
	["wall_right", Vector3(3.635, 0.0, -3.6), Vector3(3.9, 2.4, 1.25)],
	["wall_back", Vector3(-2.3, 0.0, -3.6), Vector3(3.9, 2.4, -3.22)],
	["wall_mirror", Vector3(-2.3, 0.0, 0.965), Vector3(3.9, 2.4, 1.25)],
	["pillar_back", Vector3(1.97, 0.0, -3.22), Vector3(2.02, 2.4, -2.62)],
	["pillar_front", Vector3(1.97, 0.0, 0.49), Vector3(2.02, 2.4, 0.965)],
	["beam", Vector3(1.94, 2.2, -3.22), Vector3(2.04, 2.4, 0.965)],
	["bed", Vector3(-0.81, 0.0, -3.22), Vector3(0.81, 0.62, -0.82)],
	["end_table_l", Vector3(-1.9, 0.0, -3.22), Vector3(-1.27, 0.35, -2.42)],
	["end_table_r", Vector3(1.27, 0.0, -3.22), Vector3(1.9, 0.35, -2.42)],
	["chair", Vector3(2.43, 0.0, -2.59), Vector3(3.12, 0.56, -1.88)],
	["cabinets", Vector3(3.44, 0.0, -2.42), Vector3(3.635, 0.67, 0.29)],
]


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	if _has_shapes():
		return
	rebuild_shapes()


func _has_shapes() -> bool:
	for c in get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
			return true
	return false


func rebuild_shapes() -> void:
	for c in get_children():
		if c is CollisionShape3D:
			c.queue_free()
	for b in BOXES:
		var mn: Vector3 = b[1]
		var mx: Vector3 = b[2]
		var cs := CollisionShape3D.new()
		cs.name = str(b[0])
		var box := BoxShape3D.new()
		box.size = mx - mn
		cs.shape = box
		cs.position = (mn + mx) * 0.5
		add_child(cs)
