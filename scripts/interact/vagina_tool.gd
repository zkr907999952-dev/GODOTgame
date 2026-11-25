extends Resource
## 阴道互动工具描述。新工具做成一份资源（名字、图标、设置面板类型、插入物）即可挂上，不必改模式脚本。
class_name VaginaTool

@export var id: String = ""
@export var display_name: String = ""
@export var icon: Texture2D
## 空位预留：工具栏画出格子，但不可用。
@export var reserved: bool = false
## 设置面板种类："" / "speculum_angle" / "ball_diameter"（后续扩展）。
@export var settings_kind: String = ""
## 可选：实现 VulvaInserter 的脚本路径。
@export var inserter_script: String = ""
## 可选：工具控制器（Node 脚本），负责模型、输入和物理。新工具挂上即可。
@export var controller_script: String = ""


func is_usable() -> bool:
	return not reserved and id != ""


func make_inserter():
	if inserter_script.is_empty():
		return null
	var scr := load(inserter_script)
	if scr == null:
		return null
	return scr.new()
