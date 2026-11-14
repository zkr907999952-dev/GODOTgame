extends Node
## 少量持久化设置（user://settings.cfg）。
const PATH := "user://settings.cfg"

signal changed

var bullet_cam_enabled: bool = true
var bullet_cam_chance: float = 0.20  # 0..1
## PC 鼠标视角灵敏度（弧度 / 像素）。默认保持原值。
var mouse_sensitivity: float = 0.0025
## 手机划屏视角灵敏度（弧度 / 像素）。默认明显高于鼠标，接近主流手机 FPS。
var touch_look_sensitivity: float = 0.009
## 举枪瞄准：true = 切换，false = 长按。手机默认切换。
var ads_toggle: bool = true


func _ready() -> void:
	load_cfg()


func load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(PATH) != OK:
		return
	bullet_cam_enabled = bool(c.get_value("bullet_cam", "enabled", true))
	bullet_cam_chance = clampf(float(c.get_value("bullet_cam", "chance", 0.20)), 0.0, 1.0)
	mouse_sensitivity = clampf(float(c.get_value("look", "mouse", 0.0025)), 0.0005, 0.02)
	touch_look_sensitivity = clampf(float(c.get_value("look", "touch", 0.009)), 0.001, 0.04)
	ads_toggle = bool(c.get_value("ads", "toggle", true))


func save_cfg() -> void:
	var c := ConfigFile.new()
	c.load(PATH)
	c.set_value("bullet_cam", "enabled", bullet_cam_enabled)
	c.set_value("bullet_cam", "chance", bullet_cam_chance)
	c.set_value("look", "mouse", mouse_sensitivity)
	c.set_value("look", "touch", touch_look_sensitivity)
	c.set_value("ads", "toggle", ads_toggle)
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


func set_mouse_sensitivity(v: float) -> void:
	v = clampf(v, 0.0005, 0.02)
	if is_equal_approx(mouse_sensitivity, v):
		return
	mouse_sensitivity = v
	save_cfg()


func set_touch_look_sensitivity(v: float) -> void:
	v = clampf(v, 0.001, 0.04)
	if is_equal_approx(touch_look_sensitivity, v):
		return
	touch_look_sensitivity = v
	save_cfg()


func set_ads_toggle(on: bool) -> void:
	if ads_toggle == on:
		return
	ads_toggle = on
	save_cfg()
