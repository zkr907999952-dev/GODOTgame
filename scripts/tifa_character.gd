extends Node3D
## Tifa 角色根节点。
## 资源来自网页项目 rouchangmoniqi3 的 public/models/tifa.glb，
## 并用 nude-rig-data.json 的 185 骨软骨骼权重烘成带蒙皮的 GLB。

@onready var _body: Node3D = $Body


func _ready() -> void:
	if is_instance_valid(_body):
		_body.visible = true
		print("tifa: web-skinned body ready, children=", _body.get_child_count())
