extends Node
## 少量持久化设置（user://settings.cfg）。本轮：弹道特写开关与概率。
const PATH := "user://settings.cfg"

signal changed

var bullet_cam_enabled: bool = true
var bullet_cam_chance: float = 0.20  # 0..1


func _ready() -> void:
	load_cfg()


func load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(PATH) != OK:
		return
	bullet_cam_enabled = bool(c.get_value("bullet_cam", "enabled", true))
	bullet_cam_chance = clampf(float(c.get_value("bullet_cam", "chance", 0.20)), 0.0, 1.0)


func save_cfg() -> void:
	var c := ConfigFile.new()
	c.load(PATH)
	c.set_value("bullet_cam", "enabled", bullet_cam_enabled)
	c.set_value("bullet_cam", "chance", bullet_cam_chance)
	c.save(PATH)
	changed.emit()


func set_bullet_cam_enabled(on: bool) -> void:
	if bullet_cam_enabled == on:
		return
	bullet_cam_enabled = on
	save_cfg()


func set_bullet_cam_chance(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(bullet_cam_chance, v):
		return
	bullet_cam_chance = v
	save_cfg()
