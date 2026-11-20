extends Node
## 少量持久化设置（user://settings.cfg）。
const PATH := "user://settings.cfg"

signal changed

var bullet_cam_enabled: bool = true
var bullet_cam_chance: float = 0.20  # 0..1
## PC 鼠标视角灵敏度（弧度 / 像素）。默认保持原值。
var mouse_sensitivity: float = 0.0025
## 手机划屏视角灵敏度（弧度 / 像素）。默认明显高于鼠标，接近主流手机 FPS。
const TOUCH_LOOK_DEFAULT := 0.014
const TOUCH_LOOK_LEGACY_DEFAULT := 0.009
var touch_look_sensitivity: float = TOUCH_LOOK_DEFAULT
## 举枪瞄准：true = 切换，false = 长按。手机默认切换。
var ads_toggle: bool = true
## 无限备弹：备弹显示为 ∞，弹匣打空后仍需换弹，换弹不消耗备弹。默认开启。
var infinite_reserve: bool = true
## 武器无需换弹：弹匣不会打空，开火不必做换弹动作。与无限备弹独立。
var no_reload: bool = false
## 3D 渲染分辨率倍率（0 = 按平台默认：手机 75%，PC 100%）。只缩放 3D，不影响 HUD 点击。
var render_scale: float = 0.0
## 布娃娃受击力度（0.35..2.0）。1.0 = 0.2.12 默认，比 0.2.11 明显更强，但不会把尸体打飞出地图。
const HIT_FORCE_DEFAULT := 1.0
var hit_force: float = HIT_FORCE_DEFAULT
## 尸体拖拽拉扯力度（0.35..2.5）。1.0 = 加强后的默认拉力，可在设置里再调。
const PULL_FORCE_DEFAULT := 1.0
var pull_force: float = PULL_FORCE_DEFAULT
## 弹孔贯穿：仅在触发弹道特写时冲压柱状网格通道。默认关闭；关闭时特写也只留旧贴花。
var bullet_hole_penetrate: bool = false
## 手机飞机控制： "slider"（滑块，默认）、"stick"（摇杆）或 "buttons"（按键）。仅影响触屏布局。
const FLIGHT_MODE_SLIDER := "slider"
const FLIGHT_MODE_STICK := "stick"
const FLIGHT_MODE_BUTTONS := "buttons"
var flight_control_mode: String = FLIGHT_MODE_SLIDER


func _ready() -> void:
	load_cfg()
	call_deferred("apply_render_scale")


func load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(PATH) != OK:
		return
	bullet_cam_enabled = bool(c.get_value("bullet_cam", "enabled", true))
	bullet_cam_chance = clampf(float(c.get_value("bullet_cam", "chance", 0.20)), 0.0, 1.0)
	mouse_sensitivity = clampf(float(c.get_value("look", "mouse", 0.0025)), 0.0005, 0.02)
	var touch_raw := float(c.get_value("look", "touch", TOUCH_LOOK_DEFAULT))
	# 旧默认 0.009 在真机上偏钝；未手动改过的存档跟到新默认。
	if is_equal_approx(touch_raw, TOUCH_LOOK_LEGACY_DEFAULT):
		touch_raw = TOUCH_LOOK_DEFAULT
	touch_look_sensitivity = clampf(touch_raw, 0.001, 0.04)
	ads_toggle = bool(c.get_value("ads", "toggle", true))
	infinite_reserve = bool(c.get_value("ammo", "infinite_reserve", true))
	no_reload = bool(c.get_value("ammo", "no_reload", false))
	if c.has_section_key("graphics", "render_scale"):
		render_scale = clampf(float(c.get_value("graphics", "render_scale", 0.0)), 0.0, 1.0)
	hit_force = clampf(float(c.get_value("combat", "hit_force", HIT_FORCE_DEFAULT)), 0.35, 2.0)
	pull_force = clampf(float(c.get_value("combat", "pull_force", PULL_FORCE_DEFAULT)), 0.35, 2.5)
	bullet_hole_penetrate = bool(c.get_value("combat", "bullet_hole_penetrate", false))
	var fm := str(c.get_value("controls", "flight_mode", FLIGHT_MODE_SLIDER))
	# Keep a previously saved 摇杆 / 按键 / 滑块 choice. Missing or unknown → 滑块.
	if fm == FLIGHT_MODE_BUTTONS or fm == FLIGHT_MODE_STICK or fm == FLIGHT_MODE_SLIDER:
		flight_control_mode = fm
	else:
		flight_control_mode = FLIGHT_MODE_SLIDER


func save_cfg() -> void:
	var c := ConfigFile.new()
	c.load(PATH)
	c.set_value("bullet_cam", "enabled", bullet_cam_enabled)
	c.set_value("bullet_cam", "chance", bullet_cam_chance)
	c.set_value("look", "mouse", mouse_sensitivity)
	c.set_value("look", "touch", touch_look_sensitivity)
	c.set_value("ads", "toggle", ads_toggle)
	c.set_value("ammo", "infinite_reserve", infinite_reserve)
	c.set_value("ammo", "no_reload", no_reload)
	c.set_value("graphics", "render_scale", render_scale)
	c.set_value("combat", "hit_force", hit_force)
	c.set_value("combat", "pull_force", pull_force)
	c.set_value("combat", "bullet_hole_penetrate", bullet_hole_penetrate)
	c.set_value("controls", "flight_mode", flight_control_mode)
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


func set_infinite_reserve(on: bool) -> void:
	if infinite_reserve == on:
		return
	infinite_reserve = on
	save_cfg()


func set_no_reload(on: bool) -> void:
	if no_reload == on:
		return
	no_reload = on
	save_cfg()


func set_hit_force(v: float) -> void:
	v = clampf(v, 0.35, 2.0)
	if is_equal_approx(hit_force, v):
		return
	hit_force = v
	save_cfg()


func set_pull_force(v: float) -> void:
	v = clampf(v, 0.35, 2.5)
	if is_equal_approx(pull_force, v):
		return
	pull_force = v
	save_cfg()


func set_bullet_hole_penetrate(on: bool) -> void:
	if bullet_hole_penetrate == on:
		return
	bullet_hole_penetrate = on
	save_cfg()


func is_flight_slider_mode() -> bool:
	return flight_control_mode == FLIGHT_MODE_SLIDER


func is_flight_stick_mode() -> bool:
	return flight_control_mode == FLIGHT_MODE_STICK


func is_flight_buttons_mode() -> bool:
	return flight_control_mode == FLIGHT_MODE_BUTTONS


func set_flight_control_mode(mode: String) -> void:
	var m := FLIGHT_MODE_SLIDER
	if mode == FLIGHT_MODE_BUTTONS:
		m = FLIGHT_MODE_BUTTONS
	elif mode == FLIGHT_MODE_STICK:
		m = FLIGHT_MODE_STICK
	elif mode == FLIGHT_MODE_SLIDER:
		m = FLIGHT_MODE_SLIDER
	if flight_control_mode == m:
		return
	flight_control_mode = m
	save_cfg()


func is_mobile_os() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.get_name() == "Android"


func default_render_scale() -> float:
	return 0.75 if is_mobile_os() else 1.0


func effective_render_scale() -> float:
	if render_scale >= 0.49:
		return clampf(render_scale, 0.5, 1.0)
	return default_render_scale()


func apply_render_scale(vp: Viewport = null) -> void:
	if vp == null:
		vp = get_viewport()
	if vp == null:
		return
	vp.scaling_3d_scale = effective_render_scale()


func set_render_scale(v: float) -> void:
	v = clampf(v, 0.5, 1.0)
	if is_equal_approx(render_scale, v):
		apply_render_scale()
		return
	render_scale = v
	apply_render_scale()
	save_cfg()

