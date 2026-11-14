extends CanvasLayer
## 中文 HUD：设置 / 互动 / 摄像机 面板（对齐网页 overlay 结构，精简版）。

enum PanelId { NONE, SETTINGS, INTERACT, CAMERA, MAP }

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
var _focus_buttons: Dictionary = {}
var _zoom_slider: HSlider
var _zoom_value: Label
var _chk_autorot: CheckButton
var _preset_buttons: Array = []
var _root_ui: Control
var _ui_hidden: bool = false
var _btn_map: Button
var _panel_map: PanelContainer
var _map_list: VBoxContainer
var _map_current: Label
var _peri_sliders: Dictionary = {}  # key -> [HSlider, Label]
var _overhead_ui: Control
var _overhead_info: Label
var _overhead_clear: Button
var _overhead_go: Button


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
	_root_ui = root

	# Top-left: 设置
	_btn_settings = _make_chrome_button("设置")
	_btn_settings.position = Vector2(16, 16)
	_btn_settings.pressed.connect(func(): _toggle_panel(PanelId.SETTINGS))
	root.add_child(_btn_settings)

	# 网页左上角「地图」按钮（M）
	_btn_map = _make_chrome_button("地图")
	_btn_map.position = Vector2(104, 16)
	_btn_map.pressed.connect(func(): _toggle_panel(PanelId.MAP))
	root.add_child(_btn_map)

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

	_overhead_ui = _build_overhead_ui()
	root.add_child(_overhead_ui)

	_panel_camera = _build_camera_panel()
	_panel_camera.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel_camera.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel_camera.offset_left = -280
	_panel_camera.offset_right = -16
	_panel_camera.offset_top = 88
	root.add_child(_panel_camera)
	_no_focus(root)


## 所有 HUD 控件都不拿键盘焦点：否则点过的按钮会吃掉空格 / 回车（ui_accept → 再次按下
## 按钮 → 面板开关），Tab（ui_focus_next）和方向键也会被 GUI 焦点导航吞掉。
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
		g.call("switch_map", id, i)


## 网页 CityMapPanel：顶部（标题 / 回家 / 关闭）+ 底部（坐标 / 清除 / 传送）
func _build_overhead_ui() -> Control:
	var ui := Control.new()
	ui.name = "OverheadUI"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.visible = false
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
	return ui


## game_root 调用：俯视地图开 / 关
func set_overhead(on: bool) -> void:
	if _overhead_ui == null:
		return
	_overhead_ui.visible = on
	for c in [_btn_settings, _btn_map, _btn_camera, _btn_interact, _status]:
		if c:
			c.visible = not on
	if on:
		_close_all_panels()
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

	var help_chk := CheckButton.new()
	help_chk.text = "显示本面板说明"
	help_chk.button_pressed = true
	help_chk.toggled.connect(_on_help_toggled)
	v.add_child(help_chk)

	_help_label = Label.new()
	_help_label.text = "开关次级动画（呼吸 B / 眨眼 / 头发 / 乳摇）与鼠标灵敏度。Esc 关闭面板，H 隐藏界面。"
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
	hint.text = "左键点腹部：拖拽=按住拖动软组织，打击=点击释放环状冲击。观察视角直接用光标点；第一人称以屏幕中心为准。T 循环模式。拳头/刺刀/肚脐暂为占位。"
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
	_refresh_interact_status()
	return p


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
	if id == PanelId.MAP:
		_rebuild_map_list()
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
	if _panel_map:
		_panel_map.visible = false
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
	_toggle_panel(PanelId.MAP)


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


func _org() -> Node:
	if _player and _player.has_method("get_organs"):
		return _player.call("get_organs")
	return null


func _on_xray_toggled(on: bool) -> void:
	var o := _org()
	if o:
		o.call("set_xray_enabled", on)


func _on_xray_amount(v: float) -> void:
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


func _process(_delta: float) -> void:
	# 模式由任何途径改变（Tab / 按钮 / 脚本）都刷新状态栏
	if _player and "play_mode" in _player and int(_player.play_mode) != _last_mode:
		_last_mode = int(_player.play_mode)
		_sync_from_systems()
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


func _on_help_toggled(on: bool) -> void:
	_show_help = on
	if _help_label:
		_help_label.visible = on


func _on_mode_pressed(mode_id: String) -> void:
	_interact_mode = mode_id
	var o := _org()
	if o:
		o.call("set_interact_mode", mode_id)
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
	if _interact_mode == "drag" or _interact_mode == "strike":
		_interact_status.text = "当前模式：%s（已接入：腹壁 + 体内肠道/子宫随之形变并回弹）" % label
	else:
		_interact_status.text = "当前模式：%s（占位，尚未接入）" % label


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
