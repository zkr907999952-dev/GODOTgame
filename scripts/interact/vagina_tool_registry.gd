extends RefCounted
## 数据驱动的阴道互动工具表。模式只认 id，具体工具由资源描述。
class_name VaginaToolRegistry

const ToolScript := preload("res://scripts/interact/vagina_tool.gd")

var _items: Array = []
var _by_id := {}


func setup_defaults() -> void:
	_items.clear()
	_by_id.clear()
	register(_make("speculum", "阴道扩张器", false, "speculum_angle"))
	# 球杆在下一阶段挂上；这里先占位，避免工具栏以后挪位。
	register(_make("ball_rod", "长柄金属球", true, "ball_diameter"))
	register(_make("reserved_2", "预留", true, ""))
	register(_make("reserved_3", "预留", true, ""))


func _make(id: String, title: String, reserved: bool, settings: String):
	var t = ToolScript.new()
	t.id = id
	t.display_name = title
	t.reserved = reserved
	t.settings_kind = settings
	return t


func register(tool) -> void:
	if tool == null or str(tool.id).is_empty():
		return
	if _by_id.has(tool.id):
		for i in _items.size():
			if str(_items[i].id) == str(tool.id):
				_items[i] = tool
				break
	else:
		_items.append(tool)
	_by_id[tool.id] = tool


func all_tools() -> Array:
	return _items.duplicate()


func usable_tools() -> Array:
	var out: Array = []
	for t in _items:
		if t and bool(t.is_usable()):
			out.append(t)
	return out


func get_tool(id: String):
	return _by_id.get(id, null)


func has_tool(id: String) -> bool:
	return _by_id.has(id)
