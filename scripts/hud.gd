extends CanvasLayer
## 中文 HUD：设置 / 互动 / 摄像机 面板（对齐网页 overlay 结构，精简版）。

enum PanelId { NONE, SETTINGS, INTERACT, CAMERA, MAP, WEAPON, VEHICLE }

const INTERACT_MODES := [
	{"id": "drag", "label": "拖拽"},
	{"id": "strike", "label": "打击"},
	{"id": "fist", "label": "拳交"},
	{"id": "bayonet", "label": "刺刀"},
	{"id": "bayonet_long", "label": "长刺刀"},
	{"id": "navel", "label": "肚脐"},
]

var _player: Node = null
var _open: PanelId = PanelId.NONE
var _interact_mode: String = "drag"
var _show_help: bool = true

var _btn_settings: Button
var _btn_interact: Button
var _btn_camera: Button
var _btn_xray: Button
var _panel_settings: PanelContainer
var _panel_interact: PanelContainer
var _panel_camera: PanelContainer
var _status: Label
var _help_label: Label
var _chk_breath: CheckButton
var _chk_blink: CheckButton
var _chk_hair: CheckButton
var _sens_slider: HSlider
var _touch_sens_slider: HSlider
var _chk_ads_toggle: CheckButton
var _chk_infinite_reserve: CheckButton
var _chk_no_reload: CheckButton
var _res_option: OptionButton
var _cam_sens_slider: HSlider
var _btn_fp: Button
var _btn_play_mode: Button
var _interact_status: Label
var _mode_buttons: Dictionary = {}  # id -> Button
var _chk_xray: CheckButton
var _xray_slider: HSlider
var _xray_value: Label
var _chk_organs: CheckButton
var _chk_peri: CheckButton
var _chk_breast: CheckButton
var _breast_slider: HSlider
var _breast_value: Label
var _tp_box: VBoxContainer
var _fist_box: VBoxContainer
var _blade_box: VBoxContainer
var _navel_box: VBoxContainer
var _clone_status: Label
var _tool_depth_sl: Array = []
var _focus_buttons: Dictionary = {}
var _zoom_slider: HSlider
var _zoom_value: Label
var _chk_autorot: CheckButton
var _preset_buttons: Array = []
var _root_ui: Control
var _ui_hidden: bool = false
var _btn_map: Button
var _btn_vehicle: Button
var _panel_vehicle: PanelContainer
var _vehicle_system: Node
var _btn_enter_exit: Button
var _plane_throttle: VSlider
var _plane_throttle_box: Control
var _btn_vehicle_cam: Button
var _btn_car_accel: Button
var _btn_car_brake: Button
var _btn_thrust_up: Button
var _btn_thrust_down: Button
var _btn_yaw_l: Button
var _btn_yaw_r: Button
var _thrust_lever: Control
var _thrust_fill: ColorRect
var _thrust_ab: ColorRect
var _thrust_label: Label
var _panel_map: PanelContainer
var _map_list: VBoxContainer
var _map_current: Label
var _peri_sliders: Dictionary = {}  # key -> [HSlider, Label]
var _overhead_ui: Control
var _overhead_info: Label
var _overhead_clear: Button
var _overhead_go: Button
var _map_sidebar: Control
var _map_sidebar_panel: Control
var _map_sidebar_arrow: Button
var _map_sidebar_list: VBoxContainer
var _map_sidebar_open: bool = false
## 触屏 / 手机布局
const TouchControlsScript := preload("res://scripts/ui/touch_controls.gd")
const WeaponUIScript := preload("res://scripts/ui/weapon_ui.gd")
const WeaponWheelScript := preload("res://scripts/ui/weapon_wheel.gd")
var _wui: RefCounted
var _btn_weapon: Button
var _panel_weapon: PanelContainer
var wheel: Control
var touch_ui: bool = false
var compact: bool = false
var _touch: Control
var _chk_touch: CheckButton
var _chk_bullet_cam: CheckButton
var _cam_chance_slider: HSlider
var _cam_chance_value: Label
var _hit_force_slider: HSlider
var _hit_force_value: Label
var _pull_force_slider: HSlider
var _pull_force_value: Label
var _btn_sheet_close: Button
var _safe: Vector4 = Vector4.ZERO  # 逻辑像素：左 上 右 下
var _debug_safe: Variant = null
var _mobile_scale: float = 0.0  # > 0：按 DPI 设置界面缩放（手机）

var _hp_box: Control
var _hp_bar: ColorRect
var _hp_bar_bg: ColorRect
var _hp_num: Label
var _hp_revive: Button
var _world_hp: Control
var _world_hp_bar: ColorRect
var _world_hp_bar_bg: ColorRect
var _world_hp_num: Label
var _world_hp_target: Node = null
var _world_hp_hide_t: float = 0.0
var _world_hp_alpha: float = 0.0
var debug_world_hp_visible: bool = false
var _drag_btn: Button
var debug_drag_btn_visible: bool = false
var _reticle: Control


func setup(player: Node) -> void:
	_player = player
	_bind_weapons()
	_sync_bullet_cam_ui()
	_sync_hit_force_ui()
	_sync_pull_force_ui()
	_sync_render_scale_ui()
	if _touch:
		_touch.call("setup", player, self, get_parent())
		set_touch_ui(is_touch_device())
	_sync_from_systems()


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_close_all_panels()
	# Late bind if game_root wired after add_child
	call_deferred("_try_auto_bind")


func _try_auto_bind() -> void:
	if _player != null:
		_sync_from_systems()
		return
	var main := get_parent()
	if main and main.has_node("Player"):
		setup(main.get_node("Player"))


func _build_ui() -> void:
	var root := Control.new()
	root.name = "HudRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root_ui = root

	# Top-left: 设置
	_btn_settings = _make_chrome_button("设置")
	_btn_settings.position = Vector2(16, 16)
	_btn_settings.pressed.connect(func(): _toggle_panel(PanelId.SETTINGS))
	root.add_child(_btn_settings)

	# 网页左上角「地图」按钮（M）
	_btn_map = _make_chrome_button("地图")
	_btn_map.position = Vector2(104, 16)
	_btn_map.pressed.connect(func(): toggle_map_panel())
	root.add_child(_btn_map)

	_btn_vehicle = _make_chrome_button("载具")
	_btn_vehicle.position = Vector2(192, 16)
	_btn_vehicle.pressed.connect(func(): _toggle_panel(PanelId.VEHICLE))
	root.add_child(_btn_vehicle)

	# Top-right chrome: 摄像机 + 互动
	var right_bar := HBoxContainer.new()
	right_bar.add_theme_constant_override("separation", 8)
	right_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right_bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right_bar.offset_left = -320
	right_bar.offset_right = -16
	right_bar.offset_top = 16
	right_bar.offset_bottom = 48
	root.add_child(right_bar)

	_btn_weapon = _make_chrome_button("武器")
	_btn_weapon.pressed.connect(func(): _toggle_panel(PanelId.WEAPON))
	# 武器菜单已并入「互动」，顶栏不再单独显示武器按钮。
	_btn_weapon.visible = false
	_btn_weapon.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_btn_xray = _make_chrome_button("透视")
	_btn_xray.name = "XrayButton"
	_btn_xray.toggle_mode = true
	_btn_xray.toggled.connect(_on_chrome_xray)
	right_bar.add_child(_btn_xray)

	_btn_camera = _make_chrome_button("摄像机")
	_btn_camera.pressed.connect(func(): _toggle_panel(PanelId.CAMERA))
	right_bar.add_child(_btn_camera)

	_btn_interact = _make_chrome_button("互动")
	_btn_interact.pressed.connect(func(): _toggle_panel(PanelId.INTERACT))
	right_bar.add_child(_btn_interact)

	_status = Label.new()
	_status.text = "Tab 切换模式 · 右键环绕 · 中键平移 · 滚轮缩放 · 左键互动"
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92, 0.85))
	_status.position = Vector2(16, 56)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_status)

	_panel_settings = _build_settings_panel()
	_panel_settings.position = Vector2(16, 88)
	root.add_child(_panel_settings)

	_panel_interact = _build_interact_panel()
	_panel_interact.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel_interact.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel_interact.offset_left = -280
	_panel_interact.offset_right = -16
	_panel_interact.offset_top = 88
	root.add_child(_panel_interact)

	_panel_map = _build_map_panel()
	_panel_map.position = Vector2(16, 88)
	root.add_child(_panel_map)

	_panel_vehicle = _build_vehicle_panel()
	_panel_vehicle.position = Vector2(16, 88)
	root.add_child(_panel_vehicle)
	_build_vehicle_touch(root)

	_overhead_ui = _build_overhead_ui()
	root.add_child(_overhead_ui)

	_panel_camera = _build_camera_panel()
	_panel_camera.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel_camera.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel_camera.offset_left = -280
	_panel_camera.offset_right = -16
	_panel_camera.offset_top = 88
	root.add_child(_panel_camera)
	_wui = WeaponUIScript.new(self)
	_panel_weapon = _wui.call("build_panel")
	_panel_weapon.visible = false
	_panel_weapon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel_weapon)
	var interact_body: Control = _panel_interact.find_child("InteractBody", true, false) if _panel_interact else null
	if interact_body:
		_wui.call("build_into", interact_body)
	_wui.call("build_ammo_hud", root)
	_build_health_ui(root)
	_build_reticle(root)
	_wrap_scroll(_panel_settings)
	_wrap_scroll(_panel_map)
	_wrap_scroll(_panel_weapon)
	_wrap_scroll(_panel_vehicle)
	# 手机底部抽屉的「收起」把手
	_btn_sheet_close = Button.new()
	_btn_sheet_close.text = "收起 ▾"
	_btn_sheet_close.custom_minimum_size = Vector2(96, 44)
	_btn_sheet_close.add_theme_font_size_override("font_size", 15)
	_style_button(_btn_sheet_close, false)
	_btn_sheet_close.visible = false
	_btn_sheet_close.pressed.connect(func(): close_panels())
	root.add_child(_btn_sheet_close)
	wheel = WeaponWheelScript.new()
	wheel.name = "WeaponWheel"
	root.add_child(wheel)
	_no_focus(root)
	_touch = TouchControlsScript.new()
	_touch.name = "TouchControls"
	add_child(_touch)
	move_child(_touch, 0)  # 画在 HUD 面板下面
	get_viewport().size_changed.connect(_apply_layout)
	call_deferred("_apply_layout")


## 所有 HUD 控件都不拿键盘焦点：否则点过的按钮会吃掉空格 / 回车（ui_accept → 再次按下
## 按钮 → 面板开关），Tab（ui_focus_next）和方向键也会被 GUI 焦点导航吞掉。
func _build_health_ui(root: Control) -> void:
	# 玩家生命值：屏幕底端中央、武器信息卡下方，数字 + 动态颜色条（绿→黄→红）。
	_hp_box = Control.new()
	_hp_box.name = "PlayerHealth"
	_hp_box.custom_minimum_size = Vector2(220, 52)
	_hp_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hp_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hp_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(_hp_box)
	var title := Label.new()
	title.text = "HP"
	title.position = Vector2(0, 0)
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92, 0.9))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.add_child(title)
	_hp_num = Label.new()
	_hp_num.name = "HpNumber"
	_hp_num.text = "100"
	_hp_num.position = Vector2(28, -4)
	_hp_num.custom_minimum_size = Vector2(90, 32)
	_hp_num.add_theme_font_size_override("font_size", 26)
	_hp_num.add_theme_color_override("font_color", Color(0.55, 0.95, 0.45))
	_hp_num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.add_child(_hp_num)
	_hp_bar_bg = ColorRect.new()
	_hp_bar_bg.color = Color(0.05, 0.06, 0.07, 0.7)
	_hp_bar_bg.position = Vector2(0, 30)
	_hp_bar_bg.size = Vector2(200, 14)
	_hp_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.add_child(_hp_bar_bg)
	var border := ColorRect.new()
	border.color = Color(1, 1, 1, 0.18)
	border.position = Vector2(-1, 29)
	border.size = Vector2(202, 16)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.add_child(border)
	_hp_box.move_child(border, _hp_bar_bg.get_index())
	_hp_bar = ColorRect.new()
	_hp_bar.name = "HpBar"
	_hp_bar.color = Color(0.35, 0.9, 0.35)
	_hp_bar.position = Vector2(0, 30)
	_hp_bar.size = Vector2(200, 14)
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_box.add_child(_hp_bar)
	_hp_revive = Button.new()
	_hp_revive.name = "ReviveButton"
	_hp_revive.text = "复活"
	_hp_revive.visible = false
	_hp_revive.custom_minimum_size = Vector2(88, 36)
	_hp_revive.position = Vector2(108, -4)
	_hp_revive.focus_mode = Control.FOCUS_NONE
	_hp_revive.pressed.connect(func():
		if _player and _player.has_method("revive"):
			_player.call("revive")
			_refresh_player_hp()
	)
	_style_button(_hp_revive, true)
	_hp_box.add_child(_hp_revive)

	# 准星指向的目标头顶血条（默认隐藏）
	_world_hp = Control.new()
	_world_hp.name = "WorldHealth"
	_world_hp.visible = false
	_world_hp.custom_minimum_size = Vector2(140, 32)
	_world_hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_hp.modulate.a = 0.0
	root.add_child(_world_hp)
	_world_hp_bar_bg = ColorRect.new()
	_world_hp_bar_bg.color = Color(0.05, 0.06, 0.07, 0.75)
	_world_hp_bar_bg.position = Vector2(0, 16)
	_world_hp_bar_bg.size = Vector2(140, 10)
	_world_hp_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_hp.add_child(_world_hp_bar_bg)
	_world_hp_bar = ColorRect.new()
	_world_hp_bar.name = "WorldHpBar"
	_world_hp_bar.color = Color(0.35, 0.9, 0.35)
	_world_hp_bar.position = Vector2(0, 16)
	_world_hp_bar.size = Vector2(140, 10)
	_world_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_hp.add_child(_world_hp_bar)
	_world_hp_num = Label.new()
	_world_hp_num.name = "WorldHpNumber"
	_world_hp_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_world_hp_num.position = Vector2(0, -4)
	_world_hp_num.size = Vector2(140, 20)
	_world_hp_num.add_theme_font_size_override("font_size", 14)
	_world_hp_num.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_world_hp_num.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_world_hp_num.add_theme_constant_override("outline_size", 4)
	_world_hp_num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_hp.add_child(_world_hp_num)

	_drag_btn = Button.new()
	_drag_btn.name = "CorpseDragButton"
	_drag_btn.text = "拖拽"
	_drag_btn.visible = false
	_drag_btn.focus_mode = Control.FOCUS_NONE
	_drag_btn.custom_minimum_size = Vector2(92, 40)
	_drag_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_btn.pressed.connect(_on_corpse_drag_pressed)
	_style_button(_drag_btn, false)
	root.add_child(_drag_btn)

	_refresh_player_hp()


func _hp_color(ratio: float) -> Color:
	var r := clampf(ratio, 0.0, 1.0)
	if r > 0.5:
		return Color(0.35, 0.88, 0.32).lerp(Color(0.95, 0.86, 0.22), 1.0 - (r - 0.5) / 0.5)
	return Color(0.95, 0.86, 0.22).lerp(Color(0.92, 0.18, 0.16), 1.0 - r / 0.5)


func _refresh_player_hp() -> void:
	if _hp_box == null or _player == null:
		return
	var hp := 100.0
	var mx := 100.0
	if _player.has_method("get_hp"):
		hp = float(_player.call("get_hp"))
		mx = float(_player.call("get_max_hp"))
	var ratio := 0.0 if mx <= 0.0 else clampf(hp / mx, 0.0, 1.0)
	if _hp_num:
		_hp_num.text = str(int(round(hp)))
		_hp_num.add_theme_color_override("font_color", _hp_color(ratio))
	if _hp_bar:
		_hp_bar.size = Vector2(200.0 * ratio, 14)
		_hp_bar.color = _hp_color(ratio)
	if _hp_revive:
		_hp_revive.visible = _player.has_method("is_dead") and bool(_player.call("is_dead"))


func _aim_health_target() -> Node:
	if _player == null:
		return null
	var cam: Camera3D = _player.call("get_camera") if _player.has_method("get_camera") else get_viewport().get_camera_3d()
	if cam == null:
		return null
	var w3 := cam.get_world_3d()
	if w3 == null:
		return null
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * 80.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 | 2
	q.collide_with_areas = false
	var ex: Array[RID] = []
	if _player is CollisionObject3D:
		ex.append((_player as CollisionObject3D).get_rid())
	q.exclude = ex
	var hit := w3.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var n: Node = hit.get("collider") as Node
	while n:
		if n != _player and n.has_method("get_hp") and n.has_method("is_dead") and not bool(n.call("is_dead")):
			return n
		n = n.get_parent()
	return null


func _refresh_world_hp(delta: float) -> void:
	if _world_hp == null:
		return
	var tgt := _aim_health_target()
	if tgt:
		_world_hp_target = tgt
		_world_hp_hide_t = 0.7
	else:
		_world_hp_hide_t = maxf(0.0, _world_hp_hide_t - delta)
		if _world_hp_hide_t <= 0.0:
			_world_hp_target = null
	var show := _world_hp_target != null and is_instance_valid(_world_hp_target)
	var want := 1.0 if show else 0.0
	_world_hp_alpha = move_toward(_world_hp_alpha, want, delta * (8.0 if show else 5.0))
	debug_world_hp_visible = show and _world_hp_alpha > 0.15
	_world_hp.visible = _world_hp_alpha > 0.02
	_world_hp.modulate.a = _world_hp_alpha
	if not show or not is_instance_valid(_world_hp_target):
		return
	var body: Node = _world_hp_target
	var hp := float(body.call("get_hp"))
	var mx := float(body.call("get_max_hp"))
	var ratio := 0.0 if mx <= 0.0 else clampf(hp / mx, 0.0, 1.0)
	_world_hp_num.text = "%d / %d" % [int(round(hp)), int(round(mx))]
	_world_hp_bar.size = Vector2(140.0 * ratio, 10)
	_world_hp_bar.color = _hp_color(ratio)
	var world_p: Vector3 = body.global_position + Vector3.UP * 1.7
	if body.has_method("get_head_world_position"):
		world_p = (body.call("get_head_world_position") as Vector3) + Vector3.UP * 0.08
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(world_p):
		_world_hp.visible = false
		debug_world_hp_visible = false
		return
	var sp := cam.unproject_position(world_p)
	_world_hp.position = sp - Vector2(70, 36)


func _on_corpse_drag_pressed() -> void:
	if _player and _player.has_method("toggle_corpse_drag"):
		_player.call("toggle_corpse_drag")
		_refresh_corpse_drag_btn()


func _refresh_corpse_drag_btn() -> void:
	if _drag_btn == null:
		return
	var drag = _player.call("get_corpse_drag") if _player and _player.has_method("get_corpse_drag") else null
	var dragging := false
	var can := false
	var grab_pt := Vector3.ZERO
	if drag:
		dragging = bool(drag.call("is_dragging"))
		can = bool(drag.call("can_start"))
		if dragging and drag.has_method("current_grab_point"):
			grab_pt = drag.call("current_grab_point")
		elif can:
			grab_pt = drag.get("aimed_point")
	var hide_for_ui := false
	if has_method("is_wheel_open") and bool(call("is_wheel_open")):
		hide_for_ui = true
	var g := get_parent()
	if g and g.get("map_view") and bool(g.get("map_view").get("is_open")):
		hide_for_ui = true
	# 第一人称优先；观察视角只要瞄到尸体也可以显示，方便按 E / 点按钮。
	var show := (not hide_for_ui) and drag != null and (dragging or can)
	debug_drag_btn_visible = show
	_drag_btn.visible = show
	_drag_btn.mouse_filter = Control.MOUSE_FILTER_STOP if show else Control.MOUSE_FILTER_IGNORE
	if not show:
		return
	_drag_btn.text = "放下" if dragging else "拖拽"
	_style_button(_drag_btn, dragging)
	# 触屏：拖拽键画在原开火键位置（touch_controls），这里不再叠一个准星上方的按钮。
	if touch_ui:
		_drag_btn.visible = false
		_drag_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	var slot := Rect2()
	if _touch and _touch.has_method("fire_slot_rect"):
		slot = _touch.call("fire_slot_rect")
	var vp := get_viewport().get_visible_rect().size
	var pos: Vector2
	var sz := Vector2(80, 80)
	if slot.size.x > 1.0:
		pos = slot.position
		sz = slot.size
	else:
		pos = Vector2(vp.x - _safe.z - 20.0 - 80.0 - 76.0, vp.y - _safe.w - 32.0 - 80.0 - 20.0)
	_drag_btn.position = pos
	_drag_btn.size = sz
	_drag_btn.custom_minimum_size = sz


func _layout_health_ui(safe: Vector4, touch: bool) -> void:
	if _hp_box == null:
		return
	# 底端中央、武器信息卡下方。不要再放左下，避免和摇杆重叠。
	_hp_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hp_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hp_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var bar_w := 200.0
	var box_h := 52.0
	if touch:
		_hp_num.add_theme_font_size_override("font_size", 20)
		_hp_bar_bg.size = Vector2(180, 11)
		_hp_bar.size.y = 11
		bar_w = 180.0
		box_h = 48.0
	else:
		_hp_num.add_theme_font_size_override("font_size", 24)
		_hp_bar_bg.size = Vector2(200, 13)
		_hp_bar.size.y = 13
	var gap := 6.0
	var bottom := safe.w + gap
	_hp_box.offset_left = -bar_w * 0.5 - 10.0
	_hp_box.offset_right = bar_w * 0.5 + 10.0
	_hp_box.offset_top = -(bottom + box_h)
	_hp_box.offset_bottom = -bottom
	# 复活键跟在血条右侧，死亡时仍能点到。
	if _hp_revive:
		_hp_revive.position = Vector2(bar_w * 0.5 + 16.0, 8.0)
		_hp_revive.custom_minimum_size = Vector2(80, 32)
	_refresh_player_hp()


func _no_focus(n: Node) -> void:
	if n is Control:
		(n as Control).focus_mode = Control.FOCUS_NONE
	for c in n.get_children():
		_no_focus(c)


func _slider_row(parent: Control, label: String, lo: float, hi: float, step: float, value: float, cb: Callable) -> Array:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	row.add_child(l)
	var vl := Label.new()
	vl.text = "%.2f" % value
	vl.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	row.add_child(vl)
	parent.add_child(row)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.value = value
	sl.custom_minimum_size = Vector2(200, 18)
	sl.value_changed.connect(func(v: float):
		vl.text = "%.2f" % v
		cb.call(v))
	parent.add_child(sl)
	return [sl, vl]


func _build_map_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(260, 0)
	_style_panel(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	var title := Label.new()
	title.text = "地图（M）"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)
	_map_current = Label.new()
	_map_current.add_theme_font_size_override("font_size", 12)
	_map_current.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(_map_current)
	_map_list = VBoxContainer.new()
	_map_list.add_theme_constant_override("separation", 4)
	v.add_child(_map_list)
	var ov := Button.new()
	ov.text = "俯视地图 · 选点传送"
	ov.custom_minimum_size = Vector2(230, 32)
	_style_button(ov, true)
	ov.pressed.connect(func():
		_close_all_panels()
		var g := _game()
		if g:
			g.call("open_overhead"))
	v.add_child(ov)
	var hint := Label.new()
	hint.text = "切换地图保持当前模式。大地图里按 Tab 进角色控制测试移动物理；镜子只在房间。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(230, 0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(hint)
	return p


func _game() -> Node:
	var g := get_parent()
	return g if g and g.has_method("switch_map") else null


func _rebuild_map_list() -> void:
	if _map_list == null:
		return
	for c in _map_list.get_children():
		c.queue_free()
	var g := _game()
	if g == null:
		return
	var cur := str(g.get("current_map"))
	for m in g.call("get_maps"):
		var l := Label.new()
		l.text = str(m["label"]) + ("  ← 当前" if str(m["id"]) == cur else "")
		l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
		_map_list.add_child(l)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		_map_list.add_child(grid)
		var spawns: Array = m["spawns"]
		for i in spawns.size():
			var b := Button.new()
			b.text = str(spawns[i]["label"])
			b.custom_minimum_size = Vector2(112, 28)
			b.add_theme_font_size_override("font_size", 12)
			b.focus_mode = Control.FOCUS_NONE
			_style_button(b, false)
			b.pressed.connect(_on_map_spawn.bind(str(m["id"]), i))
			grid.add_child(b)
	if _map_current:
		_map_current.text = "当前：%s" % ("房间" if cur == "room" else "城市大地图")


func _on_map_spawn(id: String, i: int) -> void:
	_close_all_panels()
	var g := _game()
	if g:
		if g.get("map_view") and bool(g.get("map_view").get("is_open")):
			g.call("close_overhead", false)
		g.call("switch_map", id, i)


## 网页 CityMapPanel：顶部（标题 / 回家 / 关闭）+ 底部（坐标 / 清除 / 传送）
func _build_overhead_ui() -> Control:
	var ui := Control.new()
	ui.name = "OverheadUI"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.visible = false
	var catcher := Control.new()
	catcher.name = "MapInputCatcher"
	catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(_on_map_catcher_gui)
	ui.add_child(catcher)
	var top := PanelContainer.new()
	_style_panel(top)
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.offset_left = -270
	top.offset_right = 270
	top.offset_top = 16
	ui.add_child(top)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 10)
	top.add_child(th)
	var tv := VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	th.add_child(tv)
	var t := Label.new()
	t.text = "城市俯视"
	t.add_theme_font_size_override("font_size", 17)
	tv.add_child(t)
	var t2 := Label.new()
	t2.text = "左键拖动平移 · 滚轮缩放 · 单击选点 · M / Esc 关闭"
	t2.add_theme_font_size_override("font_size", 11)
	t2.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	tv.add_child(t2)
	var home := Button.new()
	home.text = "回家"
	home.custom_minimum_size = Vector2(72, 34)
	_style_button(home, true)
	home.pressed.connect(func():
		var g := _game()
		if g:
			g.call("overhead_go_home"))
	th.add_child(home)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(60, 34)
	_style_button(close, false)
	close.pressed.connect(func():
		var g := _game()
		if g:
			g.call("close_overhead"))
	th.add_child(close)
	var bot := PanelContainer.new()
	_style_panel(bot)
	bot.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bot.offset_left = -270
	bot.offset_right = 270
	bot.offset_top = -66
	bot.offset_bottom = -16
	ui.add_child(bot)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 8)
	bot.add_child(bh)
	_overhead_info = Label.new()
	_overhead_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overhead_info.add_theme_font_size_override("font_size", 12)
	_overhead_info.add_theme_color_override("font_color", Color(0.8, 0.84, 0.9))
	bh.add_child(_overhead_info)
	_overhead_clear = Button.new()
	_overhead_clear.text = "清除"
	_overhead_clear.custom_minimum_size = Vector2(56, 32)
	_style_button(_overhead_clear, false)
	_overhead_clear.pressed.connect(func():
		var g := _game()
		if g:
			g.get("map_view").call("set_marker", null))
	bh.add_child(_overhead_clear)
	_overhead_go = Button.new()
	_overhead_go.text = "传送"
	_overhead_go.custom_minimum_size = Vector2(80, 32)
	_style_button(_overhead_go, true)
	_overhead_go.pressed.connect(func():
		var g := _game()
		if g:
			g.call("overhead_teleport"))
	bh.add_child(_overhead_go)
	_build_map_sidebar(ui)
	return ui


func _build_map_sidebar(ui: Control) -> void:
	_map_sidebar = Control.new()
	_map_sidebar.name = "MapSidebar"
	_map_sidebar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_map_sidebar.offset_left = 0
	_map_sidebar.offset_right = 280
	_map_sidebar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_map_sidebar)
	_map_sidebar_panel = PanelContainer.new()
	_map_sidebar_panel.name = "MapSidebarPanel"
	_style_panel(_map_sidebar_panel)
	_map_sidebar_panel.visible = false
	_map_sidebar_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_sidebar_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_map_sidebar_panel.offset_left = 8
	_map_sidebar_panel.offset_right = 258
	_map_sidebar_panel.offset_top = 88
	_map_sidebar_panel.offset_bottom = -80
	_map_sidebar.add_child(_map_sidebar_panel)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_sidebar_panel.add_child(sc)
	_map_sidebar_list = VBoxContainer.new()
	_map_sidebar_list.name = "MapSidebarList"
	_map_sidebar_list.add_theme_constant_override("separation", 4)
	_map_sidebar_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_map_sidebar_list)
	_map_sidebar_arrow = Button.new()
	_map_sidebar_arrow.name = "MapSidebarArrow"
	_map_sidebar_arrow.text = ">"
	_map_sidebar_arrow.focus_mode = Control.FOCUS_NONE
	_map_sidebar_arrow.custom_minimum_size = Vector2(28, 72)
	_style_button(_map_sidebar_arrow, true)
	_map_sidebar_arrow.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_map_sidebar_arrow.grow_vertical = Control.GROW_DIRECTION_BOTH
	_map_sidebar_arrow.offset_left = 0
	_map_sidebar_arrow.offset_right = 28
	_map_sidebar_arrow.offset_top = -36
	_map_sidebar_arrow.offset_bottom = 36
	_map_sidebar_arrow.pressed.connect(toggle_map_sidebar)
	_map_sidebar.add_child(_map_sidebar_arrow)
	_set_map_sidebar_open(false)


func is_map_sidebar_open() -> bool:
	return _map_sidebar_open


func toggle_map_sidebar() -> void:
	_set_map_sidebar_open(not _map_sidebar_open)


func _set_map_sidebar_open(on: bool) -> void:
	_map_sidebar_open = on
	if _map_sidebar_panel:
		_map_sidebar_panel.visible = on
	if _map_sidebar_arrow:
		_map_sidebar_arrow.text = "<" if on else ">"
		# 收起时贴在左缘；展开时贴在侧栏右沿。
		if on:
			_map_sidebar_arrow.offset_left = 258
			_map_sidebar_arrow.offset_right = 286
		else:
			_map_sidebar_arrow.offset_left = 0
			_map_sidebar_arrow.offset_right = 28


func _rebuild_map_sidebar() -> void:
	if _map_sidebar_list == null:
		return
	for c in _map_sidebar_list.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "传送点"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	_map_sidebar_list.add_child(title)
	var g := _game()
	if g == null:
		return
	var cur := str(g.get("current_map"))
	for m in g.call("get_maps"):
		var l := Label.new()
		l.text = str(m["label"]) + ("  ← 当前" if str(m["id"]) == cur else "")
		l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_map_sidebar_list.add_child(l)
		var grid := GridContainer.new()
		grid.columns = 1
		grid.add_theme_constant_override("v_separation", 4)
		_map_sidebar_list.add_child(grid)
		var spawns: Array = m["spawns"]
		for i in spawns.size():
			var b := Button.new()
			b.text = str(spawns[i]["label"])
			b.custom_minimum_size = Vector2(200, 32)
			b.add_theme_font_size_override("font_size", 13)
			b.focus_mode = Control.FOCUS_NONE
			_style_button(b, false)
			b.pressed.connect(_on_map_spawn.bind(str(m["id"]), i))
			grid.add_child(b)


## game_root 调用：俯视地图开 / 关
func set_overhead(on: bool) -> void:
	if _overhead_ui == null:
		return
	_overhead_ui.visible = on
	for c in [_btn_settings, _btn_map, _btn_vehicle, _btn_xray, _btn_camera, _btn_interact, _status]:
		if c:
			c.visible = not on
	if _btn_weapon:
		_btn_weapon.visible = false
	if on:
		_close_all_panels()
		_set_map_sidebar_open(false)
		_rebuild_map_sidebar()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		var g := _game()
		if g:
			var mv: Node = g.get("map_view")
			if not mv.is_connected("marker_changed", _on_overhead_marker):
				mv.connect("marker_changed", _on_overhead_marker)
		_on_overhead_marker(null)


func _on_overhead_marker(m: Variant) -> void:
	var g := _game()
	var h := 120.0
	if g:
		h = float(g.get("map_view").get("height"))
	if _overhead_info:
		if m == null:
			_overhead_info.text = "点击地面选择传送点 · 高度 %dm" % int(round(h))
		else:
			var p: Vector3 = m
			_overhead_info.text = "选点 %.1f , %.1f · 高度 %dm" % [p.x, p.z, int(round(h))]
	if _overhead_clear:
		_overhead_clear.visible = m != null
	if _overhead_go:
		_overhead_go.disabled = m == null



func setup_vehicles(vs: Node) -> void:
	_vehicle_system = vs
	if vs and vs.has_signal("proximity_changed") and not vs.is_connected("proximity_changed", _on_vehicle_proximity):
		vs.connect("proximity_changed", _on_vehicle_proximity)
	if vs and vs.has_signal("occupancy_changed") and not vs.is_connected("occupancy_changed", _on_vehicle_occupancy):
		vs.connect("occupancy_changed", _on_vehicle_occupancy)
	_refresh_vehicle_touch()


func _build_vehicle_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "VehiclePanel"
	p.visible = false
	p.custom_minimum_size = Vector2(260, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.92)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	p.add_child(col)
	var title := Label.new()
	title.text = "载具"
	title.add_theme_font_size_override("font_size", 16)
	col.add_child(title)
	var hint := Label.new()
	hint.text = "在准星 / 指针指向的地面生成。PC 靠近按 F 上下车；手机用屏幕按钮。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82, 0.9))
	col.add_child(hint)
	for item in [["跑车", "car"], ["战斗机", "plane"], ["检查床", "exam_bed"]]:
		var b := Button.new()
		b.text = "生成%s" % item[0]
		b.custom_minimum_size = Vector2(0, 36)
		b.focus_mode = Control.FOCUS_NONE
		_style_button(b, false)
		b.pressed.connect(_on_spawn_vehicle.bind(item[1]))
		col.add_child(b)
	var clr := Button.new()
	clr.text = "清除生成的载具"
	clr.custom_minimum_size = Vector2(0, 36)
	clr.focus_mode = Control.FOCUS_NONE
	_style_button(clr, false)
	clr.pressed.connect(func():
		if _vehicle_system:
			_vehicle_system.call("clear_spawned")
	)
	col.add_child(clr)
	var rst := Button.new()
	rst.text = "重置默认载具"
	rst.custom_minimum_size = Vector2(0, 36)
	rst.focus_mode = Control.FOCUS_NONE
	_style_button(rst, false)
	rst.pressed.connect(func():
		if _vehicle_system:
			_vehicle_system.call("reset_defaults")
	)
	col.add_child(rst)
	var note := Label.new()
	note.text = "「清除生成的载具」只删菜单生成的，不拆跑道默认飞机和家里的检查床。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.65, 0.68, 0.72, 0.85))
	col.add_child(note)
	return p


func _build_vehicle_touch(root: Control) -> void:
	_btn_enter_exit = _veh_btn("上载具", Vector2(108, 48), 16)
	_btn_enter_exit.visible = false
	_btn_enter_exit.pressed.connect(func():
		var g := _game()
		if g and g.get("vehicle_system"):
			g.get("vehicle_system").call("try_toggle")
		_refresh_vehicle_touch()
	)
	root.add_child(_btn_enter_exit)

	_btn_vehicle_cam = _veh_btn("第三人称", Vector2(108, 40), 14)
	_btn_vehicle_cam.visible = false
	_btn_vehicle_cam.pressed.connect(func():
		if _vehicle_system and _vehicle_system.has_method("toggle_vehicle_cam"):
			_vehicle_system.call("toggle_vehicle_cam")
		_refresh_vehicle_touch()
	)
	root.add_child(_btn_vehicle_cam)

	_btn_car_accel = _veh_btn("加速", Vector2(88, 52), 16)
	_btn_car_brake = _veh_btn("手刹", Vector2(88, 52), 16)
	_hold_btn(_btn_car_accel, "touch_car_accel")
	_hold_btn(_btn_car_brake, "touch_car_brake")
	root.add_child(_btn_car_accel)
	root.add_child(_btn_car_brake)

	_btn_thrust_up = _veh_btn("加速", Vector2(88, 48), 15)
	_btn_thrust_down = _veh_btn("减速", Vector2(88, 48), 15)
	_btn_yaw_l = _veh_btn("Q 偏航", Vector2(64, 40), 13)
	_btn_yaw_r = _veh_btn("E 偏航", Vector2(64, 40), 13)
	_hold_btn(_btn_thrust_up, "touch_thrust_up")
	_hold_btn(_btn_thrust_down, "touch_thrust_down")
	_btn_yaw_l.button_down.connect(func(): _set_vs("touch_yaw", -1.0))
	_btn_yaw_l.button_up.connect(func(): _set_vs("touch_yaw", 0.0))
	_btn_yaw_r.button_down.connect(func(): _set_vs("touch_yaw", 1.0))
	_btn_yaw_r.button_up.connect(func(): _set_vs("touch_yaw", 0.0))
	for b in [_btn_thrust_up, _btn_thrust_down, _btn_yaw_l, _btn_yaw_r]:
		root.add_child(b)

	_thrust_lever = Control.new()
	_thrust_lever.name = "ThrustLever"
	_thrust_lever.custom_minimum_size = Vector2(40, 180)
	_thrust_lever.visible = false
	_thrust_lever.gui_input.connect(_on_thrust_lever_gui)
	var track := ColorRect.new()
	track.color = Color(0.12, 0.13, 0.16, 0.85)
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	_thrust_lever.add_child(track)
	_thrust_fill = ColorRect.new()
	_thrust_fill.color = Color(0.35, 0.75, 0.95, 0.9)
	_thrust_fill.position = Vector2(6, 6)
	_thrust_fill.size = Vector2(28, 0)
	_thrust_lever.add_child(_thrust_fill)
	_thrust_ab = ColorRect.new()
	_thrust_ab.color = Color(1.0, 0.45, 0.15, 0.35)
	_thrust_ab.position = Vector2(4, 6)
	_thrust_ab.size = Vector2(32, 34)
	_thrust_lever.add_child(_thrust_ab)
	_thrust_lever.move_child(_thrust_ab, 1)
	_thrust_label = Label.new()
	_thrust_label.text = "油门"
	_thrust_label.position = Vector2(-2, 182)
	_thrust_label.add_theme_font_size_override("font_size", 11)
	_thrust_lever.add_child(_thrust_label)
	root.add_child(_thrust_lever)

	_plane_throttle_box = Control.new()
	_plane_throttle_box.name = "PlaneThrottle"
	_plane_throttle_box.visible = false
	_plane_throttle = VSlider.new()
	_plane_throttle.min_value = 0.0
	_plane_throttle.max_value = 1.0
	_plane_throttle.step = 0.01
	_plane_throttle.visible = false
	_plane_throttle_box.add_child(_plane_throttle)
	root.add_child(_plane_throttle_box)


func _veh_btn(text: String, min_size: Vector2, font: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.add_theme_font_size_override("font_size", font)
	_style_button(b, true)
	b.focus_mode = Control.FOCUS_NONE
	b.visible = false
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	return b


func _hold_btn(b: Button, prop: String) -> void:
	b.button_down.connect(func(): _set_vs(prop, true))
	b.button_up.connect(func(): _set_vs(prop, false))


func _set_vs(prop: String, value: Variant) -> void:
	if _vehicle_system:
		_vehicle_system.set(prop, value)


func _on_thrust_lever_gui(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch or event is InputEventMouseMotion or event is InputEventScreenDrag:
		var pressed := false
		var pos := Vector2.ZERO
		if event is InputEventMouseButton:
			pressed = (event as InputEventMouseButton).pressed or (event as InputEventMouseButton).button_mask != 0
			pos = (event as InputEventMouseButton).position
		elif event is InputEventMouseMotion:
			pressed = (event as InputEventMouseMotion).button_mask != 0
			pos = (event as InputEventMouseMotion).position
		elif event is InputEventScreenTouch:
			pressed = (event as InputEventScreenTouch).pressed
			pos = (event as InputEventScreenTouch).position
		elif event is InputEventScreenDrag:
			pressed = true
			pos = (event as InputEventScreenDrag).position
		if not pressed:
			return
		var h := maxf(_thrust_lever.size.y - 12.0, 1.0)
		var u := clampf(1.0 - (pos.y - 6.0) / h, 0.0, 1.0)
		_set_vs("touch_throttle", u)
		_update_thrust_lever(u)


func _update_thrust_lever(thrust: float) -> void:
	if _thrust_fill == null or _thrust_lever == null:
		return
	var h := maxf(_thrust_lever.size.y - 12.0, 1.0)
	if _thrust_ab:
		_thrust_ab.position = Vector2(4, 6)
		_thrust_ab.size = Vector2(32, h * 0.2)
	var fill := clampf(thrust, 0.0, 1.0) * h
	_thrust_fill.size = Vector2(28, fill)
	_thrust_fill.position = Vector2(6, 6 + h - fill)
	_thrust_fill.color = Color(1.0, 0.45, 0.15, 0.95) if thrust >= 0.8 else Color(0.35, 0.75, 0.95, 0.9)
	if _thrust_label:
		_thrust_label.text = "加力" if thrust >= 0.8 else "油门"


func _on_spawn_vehicle(kind: String) -> void:
	if _vehicle_system and _vehicle_system.has_method("spawn_at_aim"):
		_vehicle_system.call("spawn_at_aim", kind)
	_close_all_panels()


func _on_vehicle_proximity(_v: Node, _occ: bool) -> void:
	_refresh_vehicle_touch()


func _on_vehicle_occupancy(_v: Node) -> void:
	_refresh_vehicle_touch()
	sync()


func _refresh_vehicle_touch() -> void:
	var vs := _vehicle_system
	var occ = vs.get("occupied") if vs else null
	var near = vs.get("nearest") if vs else null
	var kind := str(vs.call("kind_of", occ if occ else near)) if vs and (occ or near) and vs.has_method("kind_of") else ""
	var v := get_viewport().get_visible_rect().size
	var show_enter := occ != null or near != null
	if _btn_enter_exit:
		_btn_enter_exit.visible = show_enter
		if occ:
			_btn_enter_exit.text = "离开检查床" if kind == "exam_bed" else "离开载具"
		elif near:
			_btn_enter_exit.text = "上检查床" if kind == "exam_bed" else "上载具"
		_btn_enter_exit.position = Vector2(v.x - _safe.z - 16.0 - 108.0, _safe.y + 72.0)
	var in_drive := occ != null and kind in ["car", "plane"]
	if _btn_vehicle_cam:
		_btn_vehicle_cam.visible = in_drive
		if in_drive and vs:
			var cam := str(vs.get("vehicle_cam"))
			_btn_vehicle_cam.text = "第一人称" if cam == "first" else "第三人称"
		_btn_vehicle_cam.position = Vector2(v.x - _safe.z - 16.0 - 108.0, _safe.y + 126.0)
	var show_car := touch_ui and occ != null and kind == "car"
	if _btn_car_accel:
		_btn_car_accel.visible = show_car
		_btn_car_accel.position = Vector2(v.x - _safe.z - 16.0 - 88.0, v.y - _safe.w - 180.0)
	if _btn_car_brake:
		_btn_car_brake.visible = show_car
		_btn_car_brake.position = Vector2(v.x - _safe.z - 16.0 - 88.0, v.y - _safe.w - 122.0)
	var show_plane := occ != null and kind == "plane"
	var show_plane_btns := touch_ui and show_plane
	if _thrust_lever:
		_thrust_lever.visible = show_plane
		_thrust_lever.position = Vector2(_safe.x + 16.0, v.y * 0.42)
		_thrust_lever.size = Vector2(40, 180)
		if show_plane and occ:
			var th = occ.get("thrust")
			if th != null:
				_update_thrust_lever(float(th))
	var right := v.x - _safe.z - 16.0
	var by := v.y - _safe.w
	if _btn_thrust_up:
		_btn_thrust_up.visible = show_plane_btns
		_btn_thrust_up.position = Vector2(right - 88.0, by - 200.0)
	if _btn_thrust_down:
		_btn_thrust_down.visible = show_plane_btns
		_btn_thrust_down.position = Vector2(right - 88.0, by - 146.0)
	# Left/right yaw sit side-by-side just above the accelerate button.
	if _btn_yaw_l:
		_btn_yaw_l.visible = show_plane_btns
		_btn_yaw_l.position = Vector2(right - 132.0, by - 250.0)
	if _btn_yaw_r:
		_btn_yaw_r.visible = show_plane_btns
		_btn_yaw_r.position = Vector2(right - 64.0, by - 250.0)
	if _plane_throttle_box:
		_plane_throttle_box.visible = false
	if vs and not show_plane:
		vs.set("touch_throttle", -1.0)
		vs.set("touch_thrust_up", false)
		vs.set("touch_thrust_down", false)
		vs.set("touch_yaw", 0.0)
	if vs and not show_car:
		vs.set("touch_car_accel", false)
		vs.set("touch_car_brake", false)


func _make_chrome_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(80, 32)
	b.add_theme_font_size_override("font_size", 15)
	_style_button(b, false)
	return b


func _style_panel(p: PanelContainer) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.88)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(1, 1, 1, 0.12)
	p.add_theme_stylebox_override("panel", sb)


func _style_button(b: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	if active:
		sb.bg_color = Color(0.28, 0.48, 0.78, 0.95)
	else:
		sb.bg_color = Color(0.14, 0.16, 0.2, 0.92)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	b.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(0.22, 0.36, 0.58, 0.95)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))


func _build_settings_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(260, 0)
	_style_panel(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)

	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)

	_chk_touch = CheckButton.new()
	_chk_touch.text = "触屏操作（摇杆 / 手势）"
	_chk_touch.toggled.connect(func(on: bool): set_touch_ui(on))
	v.add_child(_chk_touch)

	_chk_breath = CheckButton.new()
	_chk_breath.text = "呼吸"
	_chk_breath.button_pressed = true
	_chk_breath.toggled.connect(_on_breath_toggled)
	v.add_child(_chk_breath)

	_chk_blink = CheckButton.new()
	_chk_blink.text = "眨眼"
	_chk_blink.button_pressed = true
	_chk_blink.toggled.connect(_on_blink_toggled)
	v.add_child(_chk_blink)

	_chk_hair = CheckButton.new()
	_chk_hair.text = "头发物理"
	_chk_hair.button_pressed = true
	_chk_hair.toggled.connect(_on_hair_toggled)
	v.add_child(_chk_hair)

	_chk_breast = CheckButton.new()
	_chk_breast.text = "乳摇物理"
	_chk_breast.button_pressed = true
	_chk_breast.toggled.connect(_on_breast_toggled)
	v.add_child(_chk_breast)

	var br_row := HBoxContainer.new()
	var br_l := Label.new()
	br_l.text = "乳摇强度"
	br_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	br_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	br_row.add_child(br_l)
	_breast_value = Label.new()
	_breast_value.text = "0.50"
	_breast_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	br_row.add_child(_breast_value)
	v.add_child(br_row)
	_breast_slider = HSlider.new()
	_breast_slider.min_value = 0.0
	_breast_slider.max_value = 1.0
	_breast_slider.step = 0.01
	_breast_slider.value = 0.5
	_breast_slider.custom_minimum_size = Vector2(220, 18)
	_breast_slider.value_changed.connect(_on_breast_strength)
	v.add_child(_breast_slider)

	var sens_row := HBoxContainer.new()
	var sens_l := Label.new()
	sens_l.text = "鼠标灵敏度"
	sens_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sens_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	sens_row.add_child(sens_l)
	v.add_child(sens_row)

	_sens_slider = HSlider.new()
	_sens_slider.min_value = 0.0005
	_sens_slider.max_value = 0.012
	_sens_slider.step = 0.0001
	_sens_slider.value = 0.0025
	_sens_slider.custom_minimum_size = Vector2(220, 18)
	_sens_slider.value_changed.connect(_on_sens_changed)
	v.add_child(_sens_slider)

	var ts_row := HBoxContainer.new()
	var ts_l := Label.new()
	ts_l.text = "触屏划屏灵敏度"
	ts_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ts_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	ts_row.add_child(ts_l)
	v.add_child(ts_row)
	_touch_sens_slider = HSlider.new()
	_touch_sens_slider.min_value = 0.002
	_touch_sens_slider.max_value = 0.04
	_touch_sens_slider.step = 0.0005
	_touch_sens_slider.value = 0.014
	_touch_sens_slider.custom_minimum_size = Vector2(220, 18)
	_touch_sens_slider.value_changed.connect(_on_touch_sens_changed)
	v.add_child(_touch_sens_slider)

	_chk_ads_toggle = CheckButton.new()
	_chk_ads_toggle.text = "举枪瞄准：切换（关=长按）"
	_chk_ads_toggle.button_pressed = true
	_chk_ads_toggle.toggled.connect(_on_ads_toggle_changed)
	v.add_child(_chk_ads_toggle)

	_chk_infinite_reserve = CheckButton.new()
	_chk_infinite_reserve.text = "无限备弹（显示∞，仍需换弹）"
	_chk_infinite_reserve.button_pressed = true
	_chk_infinite_reserve.toggled.connect(_on_infinite_reserve_changed)
	v.add_child(_chk_infinite_reserve)

	_chk_no_reload = CheckButton.new()
	_chk_no_reload.text = "武器无需换弹"
	_chk_no_reload.button_pressed = false
	_chk_no_reload.toggled.connect(_on_no_reload_changed)
	v.add_child(_chk_no_reload)

	var res_l := Label.new()
	res_l.text = "画面分辨率"
	res_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	v.add_child(res_l)
	_res_option = OptionButton.new()
	_res_option.add_item("100%", 100)
	_res_option.add_item("75%", 75)
	_res_option.add_item("50%", 50)
	_res_option.item_selected.connect(_on_render_scale_selected)
	v.add_child(_res_option)

	_chk_bullet_cam = CheckButton.new()
	_chk_bullet_cam.text = "弹道特写"
	_chk_bullet_cam.button_pressed = true
	_chk_bullet_cam.toggled.connect(_on_bullet_cam_toggled)
	v.add_child(_chk_bullet_cam)

	var ch_row := HBoxContainer.new()
	var ch_l := Label.new()
	ch_l.text = "特写概率"
	ch_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ch_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	ch_row.add_child(ch_l)
	_cam_chance_value = Label.new()
	_cam_chance_value.text = "20%"
	_cam_chance_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	ch_row.add_child(_cam_chance_value)
	v.add_child(ch_row)
	_cam_chance_slider = HSlider.new()
	_cam_chance_slider.min_value = 0.0
	_cam_chance_slider.max_value = 100.0
	_cam_chance_slider.step = 1.0
	_cam_chance_slider.value = 20.0
	_cam_chance_slider.custom_minimum_size = Vector2(220, 18)
	_cam_chance_slider.value_changed.connect(_on_bullet_cam_chance)
	v.add_child(_cam_chance_slider)

	var hf_row := HBoxContainer.new()
	var hf_l := Label.new()
	hf_l.text = "受击力度"
	hf_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hf_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	hf_row.add_child(hf_l)
	_hit_force_value = Label.new()
	_hit_force_value.text = "1.00"
	_hit_force_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	hf_row.add_child(_hit_force_value)
	v.add_child(hf_row)
	_hit_force_slider = HSlider.new()
	_hit_force_slider.min_value = 0.35
	_hit_force_slider.max_value = 2.0
	_hit_force_slider.step = 0.05
	_hit_force_slider.value = 1.0
	_hit_force_slider.custom_minimum_size = Vector2(220, 18)
	_hit_force_slider.value_changed.connect(_on_hit_force_changed)
	v.add_child(_hit_force_slider)

	var pf_row := HBoxContainer.new()
	var pf_l := Label.new()
	pf_l.text = "拉扯力度"
	pf_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pf_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	pf_row.add_child(pf_l)
	_pull_force_value = Label.new()
	_pull_force_value.text = "1.00"
	_pull_force_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	pf_row.add_child(_pull_force_value)
	v.add_child(pf_row)
	_pull_force_slider = HSlider.new()
	_pull_force_slider.min_value = 0.35
	_pull_force_slider.max_value = 2.5
	_pull_force_slider.step = 0.05
	_pull_force_slider.value = 1.0
	_pull_force_slider.custom_minimum_size = Vector2(220, 18)
	_pull_force_slider.value_changed.connect(_on_pull_force_changed)
	v.add_child(_pull_force_slider)

	var help_chk := CheckButton.new()
	help_chk.text = "显示本面板说明"
	help_chk.button_pressed = true
	help_chk.toggled.connect(_on_help_toggled)
	v.add_child(help_chk)

	_help_label = Label.new()
	_help_label.text = "开关次级动画（呼吸 B / 眨眼 / 头发 / 乳摇）、鼠标与触屏灵敏度、举枪瞄准（切换/长按），画面分辨率（只缩放 3D，不影响按钮点击；手机默认 75%），以及弹道特写（默认开，判定将命中肠道/子宫时按概率进入狙击精英式慢动作：从枪口跟随，入体后停在伤口旁环绕，局部球形透视，连发不会叠特写）。受击力度调节子弹对布娃娃的撞击强弱。拉扯力度调节拖拽尸体时的拉力。「武器无需换弹」开启后开火不必换弹，与「无限备弹」独立。电脑瞄准为按住，手机为切换。Esc 关闭面板，H 隐藏界面。点击或触摸可跳过特写。"
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_label.custom_minimum_size = Vector2(230, 0)
	_help_label.add_theme_font_size_override("font_size", 12)
	_help_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(_help_label)

	return p


func _build_interact_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(240, 0)
	_style_panel(p)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(250, 540)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(sc)
	var v := VBoxContainer.new()
	v.name = "InteractBody"
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	var title := Label.new()
	title.text = "互动"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)

	var hint := Label.new()
	hint.text = "左键点腹部：拖拽=按住拖动软组织，打击=点击释放环状冲击；拳交=按住拖动手臂（往里推=深入，左右=倾斜）；刺刀/长刺刀=先点腹部选入口，再按住刀柄往里推；肚脐=按住往里拖让她的手指插入肚脐。观察视角用光标点，第一人称以屏幕中心为准；本体和分身都能互动。T 循环模式，R 复位。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(210, 0)
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)

	_mode_buttons.clear()
	for m in INTERACT_MODES:
		var b := Button.new()
		b.text = str(m["label"])
		b.custom_minimum_size = Vector2(100, 30)
		b.add_theme_font_size_override("font_size", 14)
		var mid: String = str(m["id"])
		_style_button(b, mid == _interact_mode)
		b.pressed.connect(_on_mode_pressed.bind(mid))
		grid.add_child(b)
		_mode_buttons[mid] = b

	_interact_status = Label.new()
	_interact_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_interact_status.custom_minimum_size = Vector2(210, 0)
	_interact_status.add_theme_font_size_override("font_size", 13)
	_interact_status.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	v.add_child(_interact_status)
	_build_tool_boxes(v)
	_build_clone_box(v)
	_refresh_interact_status()
	return p


## 当前互动目标的 OrganRig（最近点过的本体 / 分身）；参数类设置一律写本体（分身每帧同步）。
func _target_org() -> Node:
	if _player and _player.has_method("get_interact_target_rig"):
		var r: Node = _player.call("get_interact_target_rig")
		if r:
			return r
	return _org()


func _tools() -> RefCounted:
	var o := _org()
	return o.get("tools") if o else null


func _set_tool(k: String, v: Variant) -> void:
	var t := _tools()
	if t:
		t.set(k, v)


func _section(v: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.95, 0.9, 0.86))
	v.add_child(l)


func _small_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(100, 28)
	b.add_theme_font_size_override("font_size", 13)
	_style_button(b, false)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _check(parent: Control, text: String, on: bool, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


## 网页 overlay 拳交 / 刺刀参数（studio-store 默认值）
func _build_tool_boxes(v: VBoxContainer) -> void:
	_tool_depth_sl.clear()
	_fist_box = VBoxContainer.new()
	_fist_box.add_theme_constant_override("separation", 4)
	v.add_child(_fist_box)
	_section(_fist_box, "拳交参数")
	_tool_depth_sl.append(_slider_row(_fist_box, "深度", 0.0, 1.0, 0.01, 0.0, func(x: float):
		var o := _target_org()
		if o:
			o.call("tool_set_depth01", x))[0])
	_slider_row(_fist_box, "腹部鼓包", 0.0, 3.0, 0.05, 1.4, func(x: float): _set_tool("fist_bulge", x))
	_slider_row(_fist_box, "鼓包范围", 0.2, 2.0, 0.05, 1.0, func(x: float): _set_tool("fist_spread", x))
	_slider_row(_fist_box, "抬升", 0.0, 1.5, 0.05, 0.7, func(x: float): _set_tool("fist_rise", x))
	_slider_row(_fist_box, "倾斜杠杆", 0.0, 2.0, 0.05, 1.0, func(x: float): _set_tool("fist_lever", x))
	_slider_row(_fist_box, "肠道撑开", 0.0, 2.0, 0.05, 1.0, func(x: float): _set_tool("fist_gut", x))
	_slider_row(_fist_box, "最大深度", 0.5, 1.5, 0.05, 1.0, func(x: float):
		_set_tool("fist_max_depth", x)
		var t := _tools()
		if t:
			t.call("set_fist_max_scale", x))
	_check(_fist_box, "自动抽插", false, func(on: bool): _set_tool("fist_thrust", on))
	_slider_row(_fist_box, "抽插速度", 0.1, 1.0, 0.01, 0.45, func(x: float): _set_tool("fist_thrust_speed", x))
	_check(_fist_box, "搅动", false, func(on: bool): _set_tool("fist_stir", on))
	_slider_row(_fist_box, "搅动速度", 0.1, 1.0, 0.01, 0.55, func(x: float): _set_tool("fist_stir_speed", x))
	_slider_row(_fist_box, "搅动幅度", 0.05, 1.0, 0.01, 0.4, func(x: float): _set_tool("fist_stir_radius", x))

	_blade_box = VBoxContainer.new()
	_blade_box.add_theme_constant_override("separation", 4)
	v.add_child(_blade_box)
	_section(_blade_box, "刺刀参数")
	_tool_depth_sl.append(_slider_row(_blade_box, "刺入深度", 0.0, 1.0, 0.01, 0.0, func(x: float):
		var o := _target_org()
		if o:
			o.call("tool_set_depth01", x))[0])
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 6)
	_blade_box.add_child(g)
	_small_button(g, "自动刺入", func():
		var o := _target_org()
		if o:
			var t: RefCounted = o.get("tools")
			if not bool(t.get("has_entry")):
				o.call("tool_set_depth01", 0.0)
			t.call("begin_auto"))
	_small_button(g, "拔出 / 重选", func():
		var o := _target_org()
		if o:
			o.call("tool_release"))
	_small_button(g, "清除伤口", func():
		var o := _target_org()
		if o:
			(o.get("tools") as RefCounted).call("clear_marks"))
	_check(_blade_box, "连续抽插", false, func(on: bool): _set_tool("bayonet_pump", on))

	# 网页 overlay 肚脐面板：插入深度 / 深度比率 / 抽插 / 搅动（studio-store 默认值）
	_navel_box = VBoxContainer.new()
	_navel_box.add_theme_constant_override("separation", 4)
	v.add_child(_navel_box)
	_section(_navel_box, "肚脐参数")
	_tool_depth_sl.append(_slider_row(_navel_box, "插入深度", 0.0, 1.0, 0.01, 0.0, func(x: float):
		var o := _target_org()
		if o:
			o.set("navel_insert", x))[0])
	_slider_row(_navel_box, "深度比率", 0.0, 1.2, 0.01, 0.7, func(x: float): _set_org("navel_depth_ratio", x))
	_check(_navel_box, "抽插", false, func(on: bool):
		var o := _target_org()
		if on and o and float(o.get("navel_insert")) < 0.55:
			o.set("navel_insert", 1.0)
		_set_org("navel_thrust", on))
	_check(_navel_box, "搅动", false, func(on: bool):
		var o := _target_org()
		if on and o and float(o.get("navel_insert")) < 0.55:
			o.set("navel_insert", 0.85)
		_set_org("navel_stir", on))
	_slider_row(_navel_box, "抽插速度", 0.0, 1.0, 0.01, 0.45, func(x: float): _set_org("navel_thrust_speed", x))
	_slider_row(_navel_box, "抽插起始", 0.0, 0.98, 0.01, 0.5, func(x: float): _set_org("navel_thrust_start", x))
	_slider_row(_navel_box, "搅动速度", 0.0, 1.0, 0.01, 0.55, func(x: float): _set_org("navel_stir_speed", x))
	_slider_row(_navel_box, "搅动半径", 0.0, 1.0, 0.01, 0.4, func(x: float): _set_org("navel_stir_radius", x))


func _set_org(k: String, v: Variant) -> void:
	var o := _org()
	if o:
		o.set(k, v)


func _build_clone_box(v: VBoxContainer) -> void:
	_section(v, "分身")
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 6)
	v.add_child(g)
	_small_button(g, "创建分身", _on_spawn_clone)
	_small_button(g, "清除所有分身", _on_clear_clones)
	_clone_status = Label.new()
	_clone_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_clone_status.custom_minimum_size = Vector2(210, 0)
	_clone_status.add_theme_font_size_override("font_size", 12)
	_clone_status.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	_clone_status.text = "分身站在视线所指的位置，面朝你；最多 %d 个。" % 8
	v.add_child(_clone_status)


func _on_spawn_clone() -> void:
	var g := _game()
	if g and g.has_method("spawn_clone"):
		set_clone_message(str(g.call("spawn_clone")))


func _on_clear_clones() -> void:
	var g := _game()
	if g and g.has_method("clear_clones"):
		set_clone_message(str(g.call("clear_clones")))


func set_clone_message(msg: String) -> void:
	if _clone_status:
		_clone_status.text = msg
	if _status and msg != "":
		_status.text = msg


func _build_camera_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(240, 0)
	_style_panel(p)
	# 内容较多：放进滚动容器，矮窗口也能完整操作。
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(250, 520)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(sc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	var title := Label.new()
	title.text = "摄像机"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)

	var reset_b := Button.new()
	reset_b.text = "重置视角"
	reset_b.custom_minimum_size = Vector2(200, 32)
	_style_button(reset_b, false)
	reset_b.pressed.connect(_on_reset_camera)
	v.add_child(reset_b)

	_btn_play_mode = Button.new()
	_btn_play_mode.text = "展示互动模式"
	_btn_play_mode.custom_minimum_size = Vector2(200, 32)
	_style_button(_btn_play_mode, true)
	_btn_play_mode.pressed.connect(_on_toggle_play_mode)
	v.add_child(_btn_play_mode)

	var mode_hint := Label.new()
	mode_hint.text = "Tab 切换 · 展示=第三人称观察（右键环绕 / 中键或 Shift+右键平移 / 滚轮缩放 / 左键互动）· 控制=第一人称移动"
	mode_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mode_hint.custom_minimum_size = Vector2(200, 0)
	mode_hint.add_theme_font_size_override("font_size", 11)
	mode_hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(mode_hint)

	_btn_fp = Button.new()
	_btn_fp.text = "第三人称"
	_btn_fp.custom_minimum_size = Vector2(200, 32)
	_style_button(_btn_fp, false)
	_btn_fp.pressed.connect(_on_toggle_fp)
	_btn_fp.visible = false  # superseded by play mode; keep for sync safety
	v.add_child(_btn_fp)

	# ---- 观察视角控制（网页 CameraMenu：视角预设 / 视觉中心 / 缩放 / 平移）
	_tp_box = VBoxContainer.new()
	_tp_box.add_theme_constant_override("separation", 6)
	v.add_child(_tp_box)
	var fl := Label.new()
	fl.text = "视觉中心（F 循环）"
	fl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	_tp_box.add_child(fl)
	var fg := GridContainer.new()
	fg.columns = 4
	fg.add_theme_constant_override("h_separation", 4)
	_tp_box.add_child(fg)
	_focus_buttons.clear()
	for f in [["face", "面部"], ["chest", "胸部"], ["belly", "腹部"], ["groin", "阴部"]]:
		var fb := Button.new()
		fb.text = f[1]
		fb.custom_minimum_size = Vector2(48, 28)
		fb.add_theme_font_size_override("font_size", 12)
		_style_button(fb, false)
		fb.pressed.connect(_on_focus.bind(f[0]))
		fg.add_child(fb)
		_focus_buttons[f[0]] = fb
	var zr := HBoxContainer.new()
	var zl := Label.new()
	zl.text = "缩放（滚轮）"
	zl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	zr.add_child(zl)
	_zoom_value = Label.new()
	_zoom_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	zr.add_child(_zoom_value)
	_tp_box.add_child(zr)
	_zoom_slider = HSlider.new()
	_zoom_slider.min_value = 0.2
	_zoom_slider.max_value = 6.2
	_zoom_slider.step = 0.01
	_zoom_slider.custom_minimum_size = Vector2(200, 18)
	_zoom_slider.value_changed.connect(_on_zoom)
	_tp_box.add_child(_zoom_slider)
	var pan := GridContainer.new()
	pan.columns = 5
	pan.add_theme_constant_override("h_separation", 4)
	_tp_box.add_child(pan)
	for spec in [["◀", -0.08, 0.0, 0.0], ["▲", 0.0, 0.08, 0.0], ["▼", 0.0, -0.08, 0.0], ["▶", 0.08, 0.0, 0.0], ["近", 0.0, 0.0, 0.08]]:
		var pb := Button.new()
		pb.text = spec[0]
		pb.custom_minimum_size = Vector2(36, 28)
		_style_button(pb, false)
		pb.pressed.connect(_on_pan.bind(spec[1], spec[2], spec[3]))
		pan.add_child(pb)
	_chk_autorot = CheckButton.new()
	_chk_autorot.text = "自动旋转"
	_chk_autorot.toggled.connect(_on_autorot)
	_tp_box.add_child(_chk_autorot)
	var pl := Label.new()
	pl.text = "视角预设（点=调用，右键=保存）"
	pl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	_tp_box.add_child(pl)
	var pg := GridContainer.new()
	pg.columns = 4
	pg.add_theme_constant_override("h_separation", 4)
	_tp_box.add_child(pg)
	_preset_buttons.clear()
	for i in 4:
		var b := Button.new()
		b.text = "预设%d·空" % (i + 1)
		b.custom_minimum_size = Vector2(48, 28)
		b.add_theme_font_size_override("font_size", 11)
		_style_button(b, false)
		b.gui_input.connect(_on_preset_input.bind(i))
		pg.add_child(b)
		_preset_buttons.append(b)

	var xray_title := Label.new()
	xray_title.text = "透视"
	xray_title.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	v.add_child(xray_title)

	_chk_xray = CheckButton.new()
	_chk_xray.text = "腹部透视（X）"
	_chk_xray.button_pressed = true
	_chk_xray.toggled.connect(_on_xray_toggled)
	v.add_child(_chk_xray)

	var xr_row := HBoxContainer.new()
	var xr_l := Label.new()
	xr_l.text = "腹部半透明"
	xr_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xr_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	xr_row.add_child(xr_l)
	_xray_value = Label.new()
	_xray_value.text = "0.38"
	_xray_value.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	xr_row.add_child(_xray_value)
	v.add_child(xr_row)

	_xray_slider = HSlider.new()
	_xray_slider.min_value = 0.0
	_xray_slider.max_value = 1.0
	_xray_slider.step = 0.01
	_xray_slider.value = 0.38
	_xray_slider.custom_minimum_size = Vector2(200, 18)
	_xray_slider.value_changed.connect(_on_xray_amount)
	v.add_child(_xray_slider)

	_chk_organs = CheckButton.new()
	_chk_organs.text = "显示脏器"
	_chk_organs.button_pressed = true
	_chk_organs.toggled.connect(_on_organs_toggled)
	v.add_child(_chk_organs)

	_chk_peri = CheckButton.new()
	_chk_peri.text = "肠蠕动"
	_chk_peri.button_pressed = true
	_chk_peri.toggled.connect(_on_peri_toggled)
	v.add_child(_chk_peri)

	# 肠蠕动参数（实时生效；网页 gutAmp / gutSpeed + 波密度 / 分节）
	_peri_sliders.clear()
	for spec in [
		["gut_amp", "蠕动幅度", 0.0, 1.0, 0.01, 0.3],
		["gut_speed", "蠕动速度", 0.0, 1.0, 0.01, 0.5],
		["peri_waves", "蠕动波密度", 0.4, 4.0, 0.05, 1.55],
		["peri_seg", "分节收缩", 0.0, 2.0, 0.01, 1.0],
	]:
		var key: String = spec[0]
		_peri_sliders[key] = _slider_row(v, spec[1], spec[2], spec[3], spec[4], spec[5], func(val: float):
			var o := _org()
			if o:
				o.set(key, val))
	var peri_reset := Button.new()
	peri_reset.text = "蠕动参数复位"
	peri_reset.custom_minimum_size = Vector2(200, 30)
	_style_button(peri_reset, false)
	peri_reset.pressed.connect(func():
		var o := _org()
		if o:
			o.call("reset_peristalsis")
		_sync_from_systems())
	v.add_child(peri_reset)

	var sens_l := Label.new()
	sens_l.text = "视角灵敏度"
	sens_l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	v.add_child(sens_l)

	_cam_sens_slider = HSlider.new()
	_cam_sens_slider.min_value = 0.0005
	_cam_sens_slider.max_value = 0.012
	_cam_sens_slider.step = 0.0001
	_cam_sens_slider.value = 0.0025
	_cam_sens_slider.custom_minimum_size = Vector2(200, 18)
	_cam_sens_slider.value_changed.connect(_on_sens_changed)
	v.add_child(_cam_sens_slider)

	return p


func _toggle_panel(id: PanelId) -> void:
	if _open == id:
		_close_all_panels()
		return
	_open = id
	_panel_settings.visible = id == PanelId.SETTINGS
	_panel_interact.visible = id == PanelId.INTERACT
	_panel_camera.visible = id == PanelId.CAMERA
	_panel_map.visible = id == PanelId.MAP
	_panel_weapon.visible = id == PanelId.WEAPON
	if _panel_vehicle:
		_panel_vehicle.visible = id == PanelId.VEHICLE
	if id == PanelId.WEAPON:
		_wui.call("rebuild")
		_touchify(_panel_weapon, touch_ui)
	if id == PanelId.MAP:
		_rebuild_map_list()
		_touchify(_panel_map, touch_ui)
	if id == PanelId.VEHICLE:
		_touchify(_panel_vehicle, touch_ui)
	_set_mouse_for_ui(true)
	_apply_layout()
	_sync_from_systems()


func _close_all_panels() -> void:
	_open = PanelId.NONE
	if _panel_settings:
		_panel_settings.visible = false
	if _panel_interact:
		_panel_interact.visible = false
	if _panel_camera:
		_panel_camera.visible = false
	if _panel_map:
		_panel_map.visible = false
	if _panel_weapon:
		_panel_weapon.visible = false
	if _panel_vehicle:
		_panel_vehicle.visible = false
	if _btn_sheet_close:
		_btn_sheet_close.visible = false
	_set_mouse_for_ui(false)


func _set_mouse_for_ui(open: bool) -> void:
	if _player != null:
		_player.ui_blocks_capture = open
	if open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# When closing, leave mouse visible so user can click again; Esc / click captures as before.


# ---- 按键由 game_root 统一路由后调用这些接口（HUD 自己不处理任何按键）

func sync() -> void:
	_sync_from_systems()


## Esc：有面板就关面板（返回 true），否则返回 false 让角色处理鼠标。
func close_panels() -> bool:
	if _open == PanelId.NONE:
		return false
	_close_all_panels()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return true


func is_panel_open() -> bool:
	return _open != PanelId.NONE


func open_panel_name() -> String:
	return str(PanelId.keys()[_open])


func toggle_map_panel() -> void:
	# 地图按钮默认直接进俯视投影；再点（或 M / Esc）关闭。传送点在地图左侧栏。
	var g := _game()
	if g == null:
		return
	var mv = g.get("map_view")
	if mv and bool(mv.get("is_open")):
		g.call("close_overhead")
	else:
		_close_all_panels()
		g.call("open_overhead")


func toggle_ui_hidden() -> void:
	_ui_hidden = not _ui_hidden
	if _root_ui:
		_root_ui.visible = not _ui_hidden


func cycle_interact_mode() -> void:
	var ids: Array = []
	for m in INTERACT_MODES:
		ids.append(str(m["id"]))
	_on_mode_pressed(ids[(ids.find(_interact_mode) + 1) % ids.size()])


func _sync_from_systems() -> void:
	if _player == null:
		return
	if "mouse_sensitivity" in _player:
		var s: float = float(_player.mouse_sensitivity)
		if _sens_slider:
			_sens_slider.value = s
		if _cam_sens_slider:
			_cam_sens_slider.value = s
	if "touch_look_sensitivity" in _player and _touch_sens_slider:
		_touch_sens_slider.value = float(_player.touch_look_sensitivity)
	if "ads_toggle" in _player and _chk_ads_toggle:
		var tog: bool = bool(_player.ads_toggle)
		_chk_ads_toggle.set_pressed_no_signal(tog)
		_chk_ads_toggle.text = "举枪瞄准：切换（关=长按）" if tog else "举枪瞄准：长按（开=切换）"
	var st := _settings()
	if st and _chk_infinite_reserve:
		_chk_infinite_reserve.set_pressed_no_signal(bool(st.get("infinite_reserve")))
	if st and _chk_no_reload:
		_chk_no_reload.set_pressed_no_signal(bool(st.get("no_reload")))
	if "first_person" in _player and _btn_fp:
		_btn_fp.text = "第一人称" if bool(_player.first_person) else "第三人称"
		_style_button(_btn_fp, bool(_player.first_person))
	if _btn_play_mode and _player.has_method("is_display_mode"):
		var disp: bool = bool(_player.call("is_display_mode"))
		_btn_play_mode.text = "展示互动模式" if disp else "角色控制模式"
		_style_button(_btn_play_mode, disp)
		if _status:
			_status.text = (
				("展示互动（观察）· 右键环绕 · 中键/Shift+右键平移 · 滚轮缩放 · 左键互动 · F 视觉中心 · R 复位 · Tab 切换")
				if disp
				else ("角色控制 · 第一人称 · WASD 移动 · Shift 奔跑 · 空格跳 · Ctrl/C 蹲 · Z 匍匐 · Esc 释放鼠标 · M 地图 · Tab 切换")
			)
			if touch_ui:
				_status.text = "触屏观察：单指点身体=互动 · 双击后拖=环绕 · 双指=平移/缩放" if disp else "触屏控制：左下摇杆（外圈奔跑）· 右侧拖动转视角 · 右下 互动/跳跃/下蹲 · 瞄准/开火/武器"
		if _tp_box:
			_tp_box.visible = disp
		if disp and _player.has_method("get_tp_distance"):
			if _zoom_slider:
				_zoom_slider.set_value_no_signal(float(_player.call("get_tp_distance")))
			if _zoom_value:
				_zoom_value.text = "%.2f" % float(_player.call("get_tp_distance"))
			var foc := str(_player.call("get_tp_focus"))
			for k in _focus_buttons.keys():
				_style_button(_focus_buttons[k], k == foc)
			if _chk_autorot:
				_chk_autorot.set_pressed_no_signal(bool(_player.get("tp_auto_rotate")))
			for i in _preset_buttons.size():
				var has := bool(_player.call("has_tp_preset", i))
				(_preset_buttons[i] as Button).text = ("预设%d" % (i + 1)) if has else ("预设%d·空" % (i + 1))
	var org := _org()
	if org != null:
		if _chk_xray:
			_chk_xray.set_pressed_no_signal(bool(org.get("xray_enabled")))
		_sync_xray_chrome()
		if _xray_slider:
			_xray_slider.set_value_no_signal(float(org.get("xray_amount")))
		if _xray_value:
			_xray_value.text = "%.2f" % float(org.get("xray_amount"))
		if _chk_organs:
			_chk_organs.set_pressed_no_signal(bool(org.get("show_organs")))
		if _chk_peri:
			_chk_peri.set_pressed_no_signal(bool(org.get("peristalsis_on")))
		for k in _peri_sliders.keys():
			var pair: Array = _peri_sliders[k]
			var val := float(org.get(k))
			(pair[0] as HSlider).set_value_no_signal(val)
			(pair[1] as Label).text = "%.2f" % val
		org.call("set_interact_mode", _interact_mode)
	var sec: RefCounted = null
	if _player.has_method("get_secondary"):
		sec = _player.call("get_secondary")
	if sec != null:
		if _chk_breath:
			_chk_breath.set_pressed_no_signal(bool(sec.get("breath_enabled")))
		if _chk_blink:
			_chk_blink.set_pressed_no_signal(bool(sec.get("blink_enabled")))
		if _chk_hair:
			_chk_hair.set_pressed_no_signal(bool(sec.get("hair_enabled")))
		var br: RefCounted = sec.get("breasts")
		if br != null:
			if _chk_breast:
				_chk_breast.set_pressed_no_signal(bool(br.get("enabled")))
			if _breast_slider:
				_breast_slider.set_value_no_signal(float(br.get("strength")))
			if _breast_value:
				_breast_value.text = "%.2f" % float(br.get("strength"))
	_sync_bullet_cam_ui()
	_sync_hit_force_ui()
	_sync_pull_force_ui()


func _org() -> Node:
	if _player and _player.has_method("get_organs"):
		return _player.call("get_organs")
	return null


func _on_chrome_xray(on: bool) -> void:
	_on_xray_toggled(on)
	_sync_xray_chrome()


func _sync_xray_chrome() -> void:
	if _btn_xray == null:
		return
	var on := false
	var o := _org()
	if o:
		on = bool(o.get("xray_enabled"))
	_btn_xray.set_pressed_no_signal(on)
	_style_button(_btn_xray, on)


func _on_xray_toggled(on: bool) -> void:
	var g := _game()
	if g and g.has_method("apply_xray_enabled"):
		g.call("apply_xray_enabled", on)
		_sync_xray_chrome()
		return
	var o := _org()
	if o:
		o.call("set_xray_enabled", on)
	_sync_xray_chrome()


func _on_xray_amount(v: float) -> void:
	var g := _game()
	if g and g.has_method("apply_xray_amount"):
		g.call("apply_xray_amount", v)
		var o0 := _org()
		if o0 and v > 0.001 and not bool(o0.get("xray_enabled")):
			if g.has_method("apply_xray_enabled"):
				g.call("apply_xray_enabled", true)
			if _chk_xray:
				_chk_xray.set_pressed_no_signal(true)
	else:
		var o := _org()
		if o:
			o.call("set_xray_amount", v)
			if v > 0.001 and not bool(o.get("xray_enabled")):
				o.call("set_xray_enabled", true)
				if _chk_xray:
					_chk_xray.set_pressed_no_signal(true)
	if _xray_value:
		_xray_value.text = "%.2f" % v


func _on_organs_toggled(on: bool) -> void:
	var g := _game()
	if g and g.has_method("apply_show_organs"):
		g.call("apply_show_organs", on)
		return
	var o := _org()
	if o:
		o.call("set_show_organs", on)


func _on_peri_toggled(on: bool) -> void:
	var o := _org()
	if o:
		o.set("peristalsis_on", on)


func _on_breath_toggled(on: bool) -> void:
	var sec := _sec()
	if sec:
		sec.set("breath_enabled", on)


func _on_blink_toggled(on: bool) -> void:
	var sec := _sec()
	if sec:
		sec.set("blink_enabled", on)


func _on_hair_toggled(on: bool) -> void:
	var sec := _sec()
	if sec:
		sec.set("hair_enabled", on)


func _breasts() -> RefCounted:
	var sec := _sec()
	if sec == null:
		return null
	return sec.get("breasts")


func _on_breast_toggled(on: bool) -> void:
	var br := _breasts()
	if br:
		br.set("enabled", on)


func _on_breast_strength(v: float) -> void:
	var br := _breasts()
	if br:
		br.set("strength", v)
	if _breast_value:
		_breast_value.text = "%.2f" % v


func _on_focus(f: String) -> void:
	if _player and _player.has_method("set_tp_focus"):
		_player.call("set_tp_focus", f)
	_sync_from_systems()


func _on_zoom(v: float) -> void:
	if _player and _player.has_method("set_tp_distance"):
		_player.call("set_tp_distance", v)
	if _zoom_value:
		_zoom_value.text = "%.2f" % v


func _on_pan(dx: float, dy: float, dz: float) -> void:
	if _player and _player.has_method("tp_pan_step"):
		_player.call("tp_pan_step", dx, dy, dz)


func _on_autorot(on: bool) -> void:
	if _player:
		_player.set("tp_auto_rotate", on)


func _on_preset_input(ev: InputEvent, i: int) -> void:
	if not (ev is InputEventMouseButton) or not ev.pressed or _player == null:
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		_player.call("save_tp_preset", i)
	elif mb.button_index == MOUSE_BUTTON_LEFT:
		_player.call("apply_tp_preset", i)
	_sync_from_systems()


var _last_mode: int = -1


func _build_reticle(root: Control) -> void:
	_reticle = Control.new()
	_reticle.name = "Reticle"
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reticle.draw.connect(_draw_reticle)
	root.add_child(_reticle)


func reticle_mode() -> String:
	## hidden / dot / cross。第一人称：空手小白点，持枪髋射十字准星，开镜隐藏（用机瞄）。
	## 手机和电脑同一套逻辑。
	if _player == null or not bool(_player.get("first_person")):
		return "hidden"
	if not _player.has_method("weapon_drawn") or not bool(_player.call("weapon_drawn")):
		return "dot"
	var ws: Node = _player.call("get_weapons") if _player.has_method("get_weapons") else null
	if ws and (bool(ws.get("ads")) or float(ws.get("_ads_k")) > 0.45):
		return "hidden"
	return "cross"


func _draw_reticle() -> void:
	if _reticle == null:
		return
	var mode := reticle_mode()
	if mode == "hidden":
		return
	var cc: Vector2 = _reticle.size * 0.5
	if mode == "dot":
		_reticle.draw_circle(cc, 2.6, Color(1, 1, 1, 0.95))
	elif mode == "cross":
		var col := Color(1, 1, 1, 0.78)
		_reticle.draw_line(cc - Vector2(9, 0), cc + Vector2(9, 0), col, 1.2)
		_reticle.draw_line(cc - Vector2(0, 9), cc + Vector2(0, 9), col, 1.2)


func _process(_delta: float) -> void:
	if _reticle:
		_reticle.queue_redraw()
	if _wui:
		_wui.call("_refresh_ammo_hud")
	_refresh_player_hp()
	_refresh_world_hp(_delta)
	_refresh_corpse_drag_btn()
	# 模式由任何途径改变（Tab / 按钮 / 脚本）都刷新状态栏
	if _player and "play_mode" in _player and int(_player.play_mode) != _last_mode:
		_last_mode = int(_player.play_mode)
		_sync_from_systems()
	if _thrust_lever and _thrust_lever.visible and _vehicle_system:
		var occ = _vehicle_system.get("occupied")
		if occ:
			var th = occ.get("thrust")
			if th != null:
				_update_thrust_lever(float(th))
	# 缩放滑条跟随滚轮
	if _open == PanelId.CAMERA and _player and _zoom_slider and _player.has_method("get_tp_distance"):
		var d := float(_player.call("get_tp_distance"))
		if absf(_zoom_slider.value - d) > 0.005:
			_zoom_slider.set_value_no_signal(d)
			if _zoom_value:
				_zoom_value.text = "%.2f" % d


func _on_sens_changed(v: float) -> void:
	if _player and _player.has_method("set_mouse_sensitivity"):
		_player.call("set_mouse_sensitivity", v)
	if _sens_slider and absf(_sens_slider.value - v) > 1e-9:
		_sens_slider.value = v
	if _cam_sens_slider and absf(_cam_sens_slider.value - v) > 1e-9:
		_cam_sens_slider.value = v


func _on_touch_sens_changed(v: float) -> void:
	if _player and _player.has_method("set_touch_look_sensitivity"):
		_player.call("set_touch_look_sensitivity", v)


func _on_ads_toggle_changed(on: bool) -> void:
	if _player and _player.has_method("set_ads_toggle"):
		_player.call("set_ads_toggle", on)
	if _chk_ads_toggle:
		_chk_ads_toggle.text = "举枪瞄准：切换（关=长按）" if on else "举枪瞄准：长按（开=切换）"


func _on_no_reload_changed(on: bool) -> void:
	var s: Node = _settings()
	if s and s.has_method("set_no_reload"):
		s.call("set_no_reload", on)


func _on_infinite_reserve_changed(on: bool) -> void:
	var s := _settings()
	if s and s.has_method("set_infinite_reserve"):
		s.call("set_infinite_reserve", on)
	if _wui:
		_wui.call("refresh")


func _sync_render_scale_ui() -> void:
	var s := _settings()
	if s == null or _res_option == null:
		return
	var sc := float(s.call("effective_render_scale"))
	var idx := 0
	if sc <= 0.6:
		idx = 2
	elif sc <= 0.85:
		idx = 1
	_res_option.set_block_signals(true)
	_res_option.select(idx)
	_res_option.set_block_signals(false)


func _on_render_scale_selected(idx: int) -> void:
	var s := _settings()
	if s == null:
		return
	var v := 1.0
	if idx == 1:
		v = 0.75
	elif idx == 2:
		v = 0.5
	s.call("set_render_scale", v)


func camera_panel_open() -> bool:
	return _panel_camera != null and _panel_camera.visible


func _on_help_toggled(on: bool) -> void:
	_show_help = on
	if _help_label:
		_help_label.visible = on


func _on_mode_pressed(mode_id: String) -> void:
	_interact_mode = mode_id
	var o := _org()
	if o:
		o.call("set_interact_mode", "bayonet_short" if mode_id == "bayonet" else mode_id)
	# 网页：进入肚脐模式时相机切到腹部近景
	if mode_id == "navel" and _player and _player.has_method("is_display_mode") and bool(_player.call("is_display_mode")):
		_player.call("set_tp_focus", "belly")
	for id in _mode_buttons.keys():
		_style_button(_mode_buttons[id], id == mode_id)
	_refresh_interact_status()


func _refresh_interact_status() -> void:
	if _interact_status == null:
		return
	var label := _interact_mode
	for m in INTERACT_MODES:
		if str(m["id"]) == _interact_mode:
			label = str(m["label"])
			break
	if _fist_box:
		_fist_box.visible = _interact_mode == "fist"
	if _blade_box:
		_blade_box.visible = _interact_mode == "bayonet" or _interact_mode == "bayonet_long"
	if _navel_box:
		_navel_box.visible = _interact_mode == "navel"
	if _interact_mode == "drag" or _interact_mode == "strike":
		_interact_status.text = "当前模式：%s（已接入：腹壁 + 体内肠道/子宫随之形变并回弹）" % label
	elif _interact_mode == "fist":
		_interact_status.text = "当前模式：拳交（按住拖动：往里推深入、左右倾斜；腹部随拳头鼓起，透视可见肠道被撑开）"
	elif _interact_mode == "bayonet" or _interact_mode == "bayonet_long":
		_interact_status.text = "当前模式：%s（点腹部选入口 → 按住刀柄往里推；刺破留伤口、肠道受伤变红%s）" % [label, "，长刀可刺穿背部" if _interact_mode == "bayonet_long" else ""]
	elif _interact_mode == "navel":
		_interact_status.text = "当前模式：肚脐（她用右手食指插入自己的肚脐：按住往里拖=插深，往外=拔出；0.5 处指尖接触，越深肚脐被撑得越深越大）"
	else:
		_interact_status.text = "当前模式：%s" % label


func _on_reset_camera() -> void:
	if _player and _player.has_method("reset_camera"):
		_player.call("reset_camera")


func _on_toggle_fp() -> void:
	if _player and _player.has_method("toggle_play_mode"):
		_player.call("toggle_play_mode")
		_sync_from_systems()
	elif _player and _player.has_method("toggle_first_person"):
		_player.call("toggle_first_person")
		_sync_from_systems()


func _on_toggle_play_mode() -> void:
	if _player and _player.has_method("toggle_play_mode"):
		_player.call("toggle_play_mode")
		_sync_from_systems()


func _sec() -> RefCounted:
	if _player and _player.has_method("get_secondary"):
		return _player.call("get_secondary")
	return null


# ------------------------------------------------------------------ 触屏 / 手机布局
## 网页 touchUi：(pointer: coarse) || maxTouchPoints > 0 || 窄屏。这里：移动平台或有触摸屏。
static func is_touch_device() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios") or DisplayServer.is_touchscreen_available()


static func is_mobile_os() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


func set_touch_ui(on: bool) -> void:
	touch_ui = on
	if _chk_touch and _chk_touch.button_pressed != on:
		_chk_touch.set_pressed_no_signal(on)
	if _touch:
		_touch.call("set_enabled", on)
	_touchify(_root_ui, on)
	_apply_layout()


## 触屏「切换」按钮放在顶部按钮 + 状态提示下面（不遮挡）
func touch_top_y() -> float:
	var y := 0.0
	for c in [_btn_interact, _status]:
		var ctl := c as Control
		if ctl and ctl.is_visible_in_tree():
			y = maxf(y, ctl.get_global_rect().end.y)
	return y + 8.0


func get_touch_controls() -> Control:
	return _touch


## 测试 / 截图：模拟手机（DPI 缩放 + 安全区）
func debug_force_mobile(scale: float, safe_px: Vector4 = Vector4.ZERO) -> void:
	_mobile_scale = scale
	_debug_safe = safe_px
	_apply_ui_scale()
	set_touch_ui(true)


## 手机：按屏幕 DPI 设界面缩放（Android 160dpi = 1x），canvas_items + expand 下逻辑尺寸 = 窗口 / 缩放
func _apply_ui_scale() -> void:
	var win := get_window()
	if win == null:
		return
	var s := _mobile_scale
	if s <= 0.0 and is_mobile_os():
		s = clampf(float(DisplayServer.screen_get_dpi()) / 160.0, 1.0, 4.0)
	if s <= 0.0:
		var base := Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280)), int(ProjectSettings.get_setting("display/window/size/viewport_height", 720)))
		if win.content_scale_size != base:
			win.content_scale_size = base
		return
	var want := Vector2i(maxi(320, int(win.size.x / s)), maxi(320, int(win.size.y / s)))
	if win.content_scale_size != want:
		win.content_scale_size = want


func _compute_safe() -> Vector4:
	if _debug_safe != null:
		return _debug_safe
	if not is_mobile_os():
		return Vector4.ZERO
	var sa := DisplayServer.get_display_safe_area()
	var scr := DisplayServer.screen_get_size()
	var win := get_window()
	var k := float(win.size.x) / maxf(1.0, get_viewport().get_visible_rect().size.x)
	return Vector4(sa.position.x, sa.position.y, scr.x - sa.end.x, scr.y - sa.end.y) / maxf(0.01, k)


## 触屏：按钮略小于旧的 44px，方便按住按钮后拖动滚动菜单；滑条保持可点。
func _touchify(n: Node, on: bool) -> void:
	if n == null:
		return
	if n is BaseButton or n is HSlider:
		var c := n as Control
		if not c.has_meta("min0"):
			c.set_meta("min0", c.custom_minimum_size)
		var m0: Vector2 = c.get_meta("min0")
		if on:
			c.custom_minimum_size = Vector2(m0.x, maxf(m0.y, 30.0 if n is BaseButton else 26.0))
		else:
			c.custom_minimum_size = m0
	for ch in n.get_children():
		_touchify(ch, on)


## 把面板内容放进滚动容器（参数列表长，手机上可滚动）
func _wrap_scroll(p: PanelContainer) -> void:
	if p.get_child_count() == 0 or p.get_child(0) is ScrollContainer:
		return
	var content := p.get_child(0)
	p.remove_child(content)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	p.add_child(sc)
	sc.add_child(content)
	(content as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hook_menu_drag_scroll(sc)


func _panel_scroll(p: PanelContainer) -> ScrollContainer:
	return p.get_child(0) as ScrollContainer if p.get_child_count() > 0 else null


## 触摸点是否落在 HUD 控件上（交给 GUI，不当作场景手势）
func point_over_ui(pos: Vector2) -> bool:
	if _root_ui == null or not _root_ui.visible:
		return false
	return _over(_root_ui, pos, get_viewport().get_visible_rect().size)


func _over(n: Node, pos: Vector2, vp: Vector2) -> bool:
	for ch in n.get_children():
		var c := ch as Control
		if c == null or not c.visible:
			continue
		if c.mouse_filter == Control.MOUSE_FILTER_STOP and c.size.x < vp.x * 0.98 and c.get_global_rect().has_point(pos):
			return true
		if _over(c, pos, vp):
			return true
	return false


## 响应式布局：
##   PC / 横屏：原布局（左上 设置 / 地图，右上 摄像机 / 互动，面板在下方），高度不够时面板内滚动；
##   手机竖屏（触屏且逻辑宽度 < 640，网页 sm 断点）：面板变成底部抽屉（左右铺满，最高半屏，可滚动，「收起」把手）；
##   触屏时顶栏按钮 48px 高；所有位置都加上安全区（刘海 / 圆角 / 手势条）。
func _apply_layout() -> void:
	if _root_ui == null:
		return
	_apply_ui_scale()
	var v := get_viewport().get_visible_rect().size
	_safe = _compute_safe()
	compact = touch_ui and v.x < 640.0
	if _touch:
		_touch.set("safe", _safe)
	var bw := (60.0 if compact else 72.0) if touch_ui else 80.0
	var bh := 48.0 if touch_ui else 32.0
	for b in [_btn_settings, _btn_map, _btn_vehicle, _btn_weapon, _btn_xray, _btn_camera, _btn_interact]:
		if b == null:
			continue
		b.custom_minimum_size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", 16 if touch_ui else 15)
	var sl := _safe.x + 16.0
	var st := _safe.y + 16.0
	var sr := _safe.z + 16.0
	var sb := _safe.w + 16.0
	_btn_settings.position = Vector2(sl, st)
	_btn_map.position = Vector2(sl + bw + 8.0, st)
	if _btn_vehicle:
		_btn_vehicle.position = Vector2(sl + (bw + 8.0) * 2.0, st)
	if has_method("_refresh_vehicle_touch"):
		_refresh_vehicle_touch()
	var right_bar := _btn_camera.get_parent() as Control
	right_bar.offset_right = -sr
	right_bar.offset_left = -sr - (bw * 3.0 + 16.0)
	right_bar.offset_top = st
	right_bar.offset_bottom = st + bh
	_status.position = Vector2(sl, st + bh + 8.0)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if compact else TextServer.AUTOWRAP_OFF
	_status.size = Vector2(v.x - sl - sr, 0) if compact else Vector2.ZERO
	var top := st + bh + 40.0  # PC 默认 = 88
	var open_p: PanelContainer = null
	for p in [_panel_settings, _panel_map, _panel_vehicle, _panel_interact, _panel_camera, _panel_weapon]:
		var panel := p as PanelContainer
		if panel.visible:
			open_p = panel
		var sc := _panel_scroll(panel)
		var content_h := 0.0
		if sc and sc.get_child_count() > 0:
			content_h = (sc.get_child(0) as Control).get_combined_minimum_size().y
		var right_side := panel == _panel_interact or panel == _panel_camera or panel == _panel_weapon
		var base_h := 540.0 if panel == _panel_interact else (520.0 if panel == _panel_camera or panel == _panel_weapon else content_h)
		if compact:
			var h := clampf(content_h + 24.0, 160.0, v.y * 0.5)
			panel.anchor_left = 0.0
			panel.anchor_right = 1.0
			panel.anchor_top = 1.0
			panel.anchor_bottom = 1.0
			panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
			panel.offset_left = _safe.x + 8.0
			panel.offset_right = -(_safe.z + 8.0)
			panel.offset_bottom = -(_safe.w + 8.0)
			panel.offset_top = panel.offset_bottom - h
			if sc:
				sc.custom_minimum_size = Vector2(0, h - 24.0)
		else:
			var h2 := minf(base_h, maxf(160.0, v.y - top - sb))
			panel.grow_vertical = Control.GROW_DIRECTION_END
			if right_side:
				panel.anchor_left = 1.0
				panel.anchor_right = 1.0
				panel.anchor_top = 0.0
				panel.anchor_bottom = 0.0
				panel.offset_left = -sr - 264.0
				panel.offset_right = -sr
				panel.offset_top = top
				panel.offset_bottom = top
			else:
				panel.anchor_left = 0.0
				panel.anchor_right = 0.0
				panel.anchor_top = 0.0
				panel.anchor_bottom = 0.0
				panel.offset_left = sl
				panel.offset_top = top
				panel.offset_right = sl
				panel.offset_bottom = top
			if sc:
				sc.custom_minimum_size = Vector2(250 if right_side else 0, h2)
	if _wui:
		_wui.call("layout_ammo", _safe, touch_ui)
	_layout_health_ui(_safe, touch_ui)
	# 动态重建的按钮也要能「拖菜单不点按」
	for panel in [_panel_settings, _panel_map, _panel_interact, _panel_camera, _panel_weapon]:
		var sc2 := _panel_scroll(panel)
		if sc2:
			_hook_menu_drag_scroll(sc2)
	if _btn_sheet_close:
		_btn_sheet_close.visible = compact and open_p != null
		if _btn_sheet_close.visible:
			_btn_sheet_close.position = Vector2(v.x - _safe.z - 8.0 - 96.0, v.y + open_p.offset_top - 52.0)


# ------------------------------------------------------------------ 武器
func _bind_weapons() -> void:
	if _player == null or not _player.has_method("get_weapons") or _wui == null:
		return
	var ws: Node = _player.call("get_weapons")
	if ws == null or _wui.get("weapons") == ws:
		return
	_wui.set("weapons", ws)
	wheel.set("weapons", ws)
	var cb := func(_a = null, _b = null, _c = null): _wui.call("refresh")
	for sig in ["weapon_changed", "ammo_changed", "reloaded"]:
		ws.connect(sig, cb)
	wheel.connect("picked", func(id: String): ws.call("select", id))
	_wui.call("rebuild")


func toggle_weapon_panel() -> void:
	# 武器菜单已并入互动，不再单独打开顶栏武器面板。
	_toggle_panel(PanelId.INTERACT)


func should_hide_weapon_ui() -> bool:
	# 打开地图菜单或俯视选点时不显示弹药 HUD / 武器界面。
	if _overhead_ui and _overhead_ui.visible:
		return true
	return _open == PanelId.MAP


func _to_wheel_local(p: Vector2) -> Vector2:
	if wheel == null or not wheel.is_inside_tree():
		return p
	var xf := wheel.get_global_transform_with_canvas()
	return xf.affine_inverse() * p


func open_weapon_wheel(origin: Variant = null) -> void:
	if wheel and not _ui_hidden:
		# 轮盘固定在屏幕中央。origin 忽略（兼容旧的按钮按下点调用）。
		wheel.call("open", null)


func close_weapon_wheel(apply: bool = true) -> Variant:
	return wheel.call("close", apply) if wheel else null


func is_wheel_open() -> bool:
	return wheel != null and bool(wheel.get("is_open"))


func weapon_wheel_point(p: Vector2) -> void:
	if wheel:
		wheel.call("point_at", _to_wheel_local(p))


func weapon_wheel_drag(rel_from_press: Vector2) -> void:
	if wheel and wheel.has_method("set_vec"):
		wheel.call("set_vec", rel_from_press)


## 手机菜单：从按钮上按下后拖动应滚动面板，只有几乎没移动的单击才触发按钮。
var _menu_scroll_from: Vector2 = Vector2.ZERO
var _menu_scroll_dragging: bool = false
const MENU_DRAG_PX := 10.0


func _hook_menu_drag_scroll(sc: ScrollContainer) -> void:
	if sc == null:
		return
	_hook_menu_scroll_node(sc, sc)


func _hook_menu_scroll_node(sc: ScrollContainer, n: Node) -> void:
	if n is BaseButton or n is HSlider:
		var c := n as Control
		if not c.has_meta("menu_scroll_hooked"):
			c.set_meta("menu_scroll_hooked", true)
			c.gui_input.connect(_on_menu_scroll_input.bind(sc, c))
	for ch in n.get_children():
		_hook_menu_scroll_node(sc, ch)


func _on_menu_scroll_input(event: InputEvent, sc: ScrollContainer, w: Control) -> void:
	if sc == null or w == null:
		return
	var pos := Vector2.ZERO
	var rel := Vector2.ZERO
	var down := false
	var up := false
	var moving := false
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		pos = st.position
		down = st.pressed
		up = not st.pressed
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		pos = sd.position
		rel = sd.relative
		moving = true
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		pos = mb.position
		down = mb.pressed
		up = not mb.pressed
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		var mm := event as InputEventMouseMotion
		pos = mm.position
		rel = mm.relative
		moving = true
	else:
		return
	if down:
		_menu_scroll_from = pos
		_menu_scroll_dragging = false
		return
	if moving:
		if not _menu_scroll_dragging and pos.distance_to(_menu_scroll_from) > MENU_DRAG_PX:
			# 滑条：水平拖仍调数值；明显的竖向拖才滚菜单。
			if w is HSlider and absf(rel.x) >= absf(rel.y):
				return
			_menu_scroll_dragging = true
		if _menu_scroll_dragging:
			if w is HSlider and absf(rel.x) > absf(rel.y) * 1.15:
				return
			sc.scroll_vertical = sc.scroll_vertical - int(rel.y)
			w.accept_event()
			if w is BaseButton:
				(w as BaseButton).set_pressed_no_signal(false)
		return
	if up and _menu_scroll_dragging:
		w.accept_event()
		if w is BaseButton:
			(w as BaseButton).set_pressed_no_signal(false)
			(w as BaseButton).release_focus()
		_menu_scroll_dragging = false


func _settings() -> Node:
	var g := get_parent()
	return g.get_node_or_null("GameSettings") if g else null


func _sync_bullet_cam_ui() -> void:
	var s := _settings()
	if s == null:
		return
	if _chk_bullet_cam:
		_chk_bullet_cam.set_pressed_no_signal(bool(s.get("bullet_cam_enabled")))
	if _cam_chance_slider:
		_cam_chance_slider.set_value_no_signal(float(s.get("bullet_cam_chance")) * 100.0)
	if _cam_chance_value:
		_cam_chance_value.text = "%d%%" % int(round(float(s.get("bullet_cam_chance")) * 100.0))


func _on_bullet_cam_toggled(on: bool) -> void:
	var s := _settings()
	if s:
		s.call("set_bullet_cam_enabled", on)


func _on_bullet_cam_chance(v: float) -> void:
	if _cam_chance_value:
		_cam_chance_value.text = "%d%%" % int(round(v))
	var s := _settings()
	if s:
		s.call("set_bullet_cam_chance", v / 100.0)


func _on_map_catcher_gui(event: InputEvent) -> void:
	# 手机可靠路径：全屏捕捉层走 GUI，而不是 _unhandled_input（真机触控经常到不了那里）。
	var g := _game()
	if g == null:
		return
	var mv: Node = g.get("map_view")
	if mv == null or not bool(mv.get("is_open")):
		return
	if not (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	var catcher: Control = _overhead_ui.find_child("MapInputCatcher", true, false) if _overhead_ui else null
	var xf := catcher.get_global_transform_with_canvas() if catcher else Transform2D.IDENTITY
	if mv.has_method("handle_gui_event"):
		if bool(mv.call("handle_gui_event", event, xf)):
			if catcher:
				catcher.accept_event()
	elif mv.has_method("handle_input"):
		mv.call("handle_input", event)


func _sync_hit_force_ui() -> void:
	var s := _settings()
	if s == null:
		return
	var v := clampf(float(s.get("hit_force")), 0.35, 2.0)
	if _hit_force_slider:
		_hit_force_slider.set_value_no_signal(v)
	if _hit_force_value:
		_hit_force_value.text = "%.2f" % v


func _on_hit_force_changed(v: float) -> void:
	var s := _settings()
	if s:
		s.call("set_hit_force", v)
	if _hit_force_value:
		_hit_force_value.text = "%.2f" % v


func _sync_pull_force_ui() -> void:
	var s := _settings()
	if s == null:
		return
	var v := clampf(float(s.get("pull_force")), 0.35, 2.5)
	if _pull_force_slider:
		_pull_force_slider.set_value_no_signal(v)
	if _pull_force_value:
		_pull_force_value.text = "%.2f" % v


func _on_pull_force_changed(v: float) -> void:
	var s := _settings()
	if s:
		s.call("set_pull_force", v)
	if _pull_force_value:
		_pull_force_value.text = "%.2f" % v

