extends CanvasLayer
## 中文 HUD：设置 / 互动 / 摄像机 面板（对齐网页 overlay 结构，精简版）。

enum PanelId { NONE, SETTINGS, INTERACT, CAMERA }

const INTERACT_MODES := [
	{"id": "drag", "label": "拖拽"},
	{"id": "strike", "label": "打击"},
	{"id": "fist", "label": "拳头"},
	{"id": "bayonet", "label": "刺刀"},
	{"id": "navel", "label": "肚脐"},
]

var _player: Node = null
var _open: PanelId = PanelId.NONE
var _interact_mode: String = "drag"
var _show_help: bool = true

var _btn_settings: Button
var _btn_interact: Button
var _btn_camera: Button
var _panel_settings: PanelContainer
var _panel_interact: PanelContainer
var _panel_camera: PanelContainer
var _status: Label
var _help_label: Label
var _chk_breath: CheckButton
var _chk_blink: CheckButton
var _chk_hair: CheckButton
var _sens_slider: HSlider
var _cam_sens_slider: HSlider
var _btn_fp: Button
var _interact_status: Label
var _mode_buttons: Dictionary = {}  # id -> Button


func setup(player: Node) -> void:
	_player = player
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

	# Top-left: 设置
	_btn_settings = _make_chrome_button("设置")
	_btn_settings.position = Vector2(16, 16)
	_btn_settings.pressed.connect(func(): _toggle_panel(PanelId.SETTINGS))
	root.add_child(_btn_settings)

	# Top-right chrome: 摄像机 + 互动
	var right_bar := HBoxContainer.new()
	right_bar.add_theme_constant_override("separation", 8)
	right_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right_bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right_bar.offset_left = -220
	right_bar.offset_right = -16
	right_bar.offset_top = 16
	right_bar.offset_bottom = 48
	root.add_child(right_bar)

	_btn_camera = _make_chrome_button("摄像机")
	_btn_camera.pressed.connect(func(): _toggle_panel(PanelId.CAMERA))
	right_bar.add_child(_btn_camera)

	_btn_interact = _make_chrome_button("互动")
	_btn_interact.pressed.connect(func(): _toggle_panel(PanelId.INTERACT))
	right_bar.add_child(_btn_interact)

	_status = Label.new()
	_status.text = "Esc 释放鼠标 · 打开面板时显示光标"
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

	_panel_camera = _build_camera_panel()
	_panel_camera.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel_camera.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel_camera.offset_left = -280
	_panel_camera.offset_right = -16
	_panel_camera.offset_top = 88
	root.add_child(_panel_camera)


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

	var help_chk := CheckButton.new()
	help_chk.text = "显示本面板说明"
	help_chk.button_pressed = true
	help_chk.toggled.connect(_on_help_toggled)
	v.add_child(help_chk)

	_help_label = Label.new()
	_help_label.text = "开关次级动画与鼠标灵敏度。Esc 关闭面板并释放鼠标。"
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
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)

	var title := Label.new()
	title.text = "互动"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)

	var hint := Label.new()
	hint.text = "模式（部分为占位，后续接线）"
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
	_refresh_interact_status()
	return p


func _build_camera_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(240, 0)
	_style_panel(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)

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

	_btn_fp = Button.new()
	_btn_fp.text = "第三人称"
	_btn_fp.custom_minimum_size = Vector2(200, 32)
	_style_button(_btn_fp, false)
	_btn_fp.pressed.connect(_on_toggle_fp)
	v.add_child(_btn_fp)

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
	_set_mouse_for_ui(true)
	_sync_from_systems()


func _close_all_panels() -> void:
	_open = PanelId.NONE
	if _panel_settings:
		_panel_settings.visible = false
	if _panel_interact:
		_panel_interact.visible = false
	if _panel_camera:
		_panel_camera.visible = false
	_set_mouse_for_ui(false)


func _set_mouse_for_ui(open: bool) -> void:
	if _player != null:
		_player.ui_blocks_capture = open
	if open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# When closing, leave mouse visible so user can click again; Esc / click captures as before.


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if _open != PanelId.NONE:
			_close_all_panels()
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()


func _sync_from_systems() -> void:
	if _player == null:
		return
	if "mouse_sensitivity" in _player:
		var s: float = float(_player.mouse_sensitivity)
		if _sens_slider:
			_sens_slider.value = s
		if _cam_sens_slider:
			_cam_sens_slider.value = s
	if "first_person" in _player and _btn_fp:
		_btn_fp.text = "第一人称" if bool(_player.first_person) else "第三人称"
		_style_button(_btn_fp, bool(_player.first_person))
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


func _on_sens_changed(v: float) -> void:
	if _player and _player.has_method("set_mouse_sensitivity"):
		_player.call("set_mouse_sensitivity", v)
	if _sens_slider and absf(_sens_slider.value - v) > 1e-9:
		_sens_slider.value = v
	if _cam_sens_slider and absf(_cam_sens_slider.value - v) > 1e-9:
		_cam_sens_slider.value = v


func _on_help_toggled(on: bool) -> void:
	_show_help = on
	if _help_label:
		_help_label.visible = on


func _on_mode_pressed(mode_id: String) -> void:
	_interact_mode = mode_id
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
	# Live wiring: none of the soft interact modes are implemented in Godot yet — stub state only.
	_interact_status.text = "当前模式：%s（占位，尚未接入软体互动）" % label


func _on_reset_camera() -> void:
	if _player and _player.has_method("reset_camera"):
		_player.call("reset_camera")


func _on_toggle_fp() -> void:
	if _player and _player.has_method("toggle_first_person"):
		_player.call("toggle_first_person")
		_sync_from_systems()


func _sec() -> RefCounted:
	if _player and _player.has_method("get_secondary"):
		return _player.call("get_secondary")
	return null
