extends RefCounted
## 武器菜单（HUD 面板 / 手机抽屉）+ 第一人称右下角弹药 HUD。图标 = 素材包自带的武器剪影 PNG。

const CAT_NAMES := {"pistol": "手枪", "rifle": "步枪", "smg": "冲锋枪", "shotgun": "霰弹枪", "sniper": "狙击枪", "melee": "近战"}
const MODE_NAMES := {"semi": "半自动", "auto": "全自动", "pump": "泵动", "melee": "近战"}

var hud: Node
var weapons: Node
var panel: PanelContainer
var cards: Dictionary = {}  # id -> {btn, ammo}
var ammo_box: PanelContainer
var _ammo_icon: TextureRect
var _ammo_name: Label
var _ammo_num: Label
var _ammo_mode: Label
var _status: Label


func _init(h: Node) -> void:
	hud = h


func build_panel() -> PanelContainer:
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(240, 0)
	hud.call("_style_panel", panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(v)
	var title := Label.new()
	title.text = "武器"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	v.add_child(title)
	var hint := Label.new()
	hint.text = "角色控制模式使用：1–9 选枪（再按收枪）· G 收枪 / 取枪 · 按住 Q 武器轮盘 · 滚轮切枪 · 左键射击 · R 换弹 · 右键开镜"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(200, 0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	v.add_child(hint)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.95, 0.9, 0.86))
	v.add_child(_status)
	var list := VBoxContainer.new()
	list.name = "WeaponList"
	list.add_theme_constant_override("separation", 6)
	v.add_child(list)
	var b := Button.new()
	b.text = "收枪（空手）"
	b.custom_minimum_size = Vector2(100, 30)
	hud.call("_style_button", b, false)
	b.pressed.connect(_on_holster)
	v.add_child(b)
	return panel


## 武器列表（按类别分组）；武器数据变化时重建
func rebuild() -> void:
	if panel == null or weapons == null:
		return
	var list: VBoxContainer = panel.find_child("WeaponList", true, false)
	for c in list.get_children():
		c.queue_free()
	cards.clear()
	for cat in weapons.categories():
		var l := Label.new()
		l.text = CAT_NAMES.get(cat, cat)
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color", Color(0.95, 0.9, 0.86))
		list.add_child(l)
		for w in weapons.defs:
			if w.category != cat:
				continue
			list.add_child(_card(w))
	hud.call("_no_focus", list)
	refresh()


func _card(w: Resource) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(228, 70)
	b.text = "%d  %s" % [weapons.defs.find(w) + 1, w.display_name.get_slice("（", 0)]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	b.add_theme_font_size_override("font_size", 13)
	b.clip_text = true
	hud.call("_style_button", b, false)
	var ic := TextureRect.new()
	ic.texture = w.icon
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ic.offset_left = 96
	ic.offset_top = 6
	ic.offset_right = -8
	ic.offset_bottom = -20
	ic.modulate = Color(1, 1, 1, 0.9)
	b.add_child(ic)
	var am := Label.new()
	am.add_theme_font_size_override("font_size", 13)
	am.mouse_filter = Control.MOUSE_FILTER_IGNORE
	am.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	am.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	am.grow_vertical = Control.GROW_DIRECTION_BEGIN
	am.offset_right = -8
	am.offset_bottom = -4
	b.add_child(am)
	var mode := Label.new()
	mode.text = MODE_NAMES.get(w.fire_mode, w.fire_mode)
	mode.add_theme_font_size_override("font_size", 11)
	mode.add_theme_color_override("font_color", Color(0.75, 0.78, 0.84))
	mode.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	mode.grow_vertical = Control.GROW_DIRECTION_BEGIN
	mode.offset_left = 10
	mode.offset_bottom = -4
	b.add_child(mode)
	var id: String = w.id
	b.pressed.connect(_on_pick.bind(id))
	cards[id] = {"btn": b, "ammo": am}
	return b


func _on_holster() -> void:
	if weapons:
		weapons.holster()


func _on_pick(id: String) -> void:
	if weapons:
		weapons.select(id)


func refresh() -> void:
	if weapons == null:
		return
	# 只在菜单可见时更新卡片；文字 / 样式没变就不动（避免每发子弹都触发界面重排）
	var panel_vis: bool = cards.size() > 0 and (cards.values()[0]["btn"] as Control).is_visible_in_tree()
	if panel_vis:
		for id in cards.keys():
			var c: Dictionary = cards[id]
			var a: Vector2i = weapons.ammo_of(id)
			var lbl := c["ammo"] as Label
			var txt := "%d / %d" % [a.x, a.y]
			if lbl.text != txt:
				lbl.text = txt
			var empty := a.x == 0
			if c.get("empty", null) != empty:
				c["empty"] = empty
				lbl.add_theme_color_override("font_color", Color(0.95, 0.5, 0.4) if empty else Color(1, 1, 1))
			var act: bool = id == weapons.current and weapons.state != "holstered"
			if c.get("active", null) != act:
				c["active"] = act
				hud.call("_style_button", c["btn"], act)
		if _status:
			var w: Resource = weapons.cur_def()
			var st: String = ("当前：" + w.display_name) if w else "当前：空手"
			if _status.text != st:
				_status.text = st
	_refresh_ammo_hud()


# ------------------------------------------------------------------ 弹药 HUD（右下角）
func build_ammo_hud(root: Control) -> void:
	ammo_box = PanelContainer.new()
	ammo_box.name = "AmmoHud"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.55)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	ammo_box.add_theme_stylebox_override("panel", sb)
	ammo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	ammo_box.add_child(h)
	_ammo_icon = TextureRect.new()
	_ammo_icon.custom_minimum_size = Vector2(72, 32)
	_ammo_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ammo_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	h.add_child(_ammo_icon)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	h.add_child(v)
	_ammo_name = Label.new()
	_ammo_name.add_theme_font_size_override("font_size", 12)
	_ammo_name.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	v.add_child(_ammo_name)
	_ammo_num = Label.new()
	_ammo_num.add_theme_font_size_override("font_size", 26)
	v.add_child(_ammo_num)
	_ammo_mode = Label.new()
	_ammo_mode.add_theme_font_size_override("font_size", 11)
	_ammo_mode.add_theme_color_override("font_color", Color(0.75, 0.78, 0.84))
	v.add_child(_ammo_mode)
	ammo_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ammo_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ammo_box.visible = false
	root.add_child(ammo_box)


func layout_ammo(safe: Vector4, touch: bool) -> void:
	if ammo_box == null:
		return
	if touch:
		# 缩小后放到屏幕下边缘正中央，避开右侧动作键。
		ammo_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		ammo_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
		ammo_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
		if _ammo_icon:
			_ammo_icon.custom_minimum_size = Vector2(52, 24)
		if _ammo_num:
			_ammo_num.add_theme_font_size_override("font_size", 18)
		if _ammo_name:
			_ammo_name.add_theme_font_size_override("font_size", 10)
		if _ammo_mode:
			_ammo_mode.add_theme_font_size_override("font_size", 9)
		ammo_box.offset_left = -86.0
		ammo_box.offset_right = 86.0
		ammo_box.offset_top = -(safe.w + 6.0 + 44.0)
		ammo_box.offset_bottom = -(safe.w + 6.0)
	else:
		ammo_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		ammo_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		ammo_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
		if _ammo_icon:
			_ammo_icon.custom_minimum_size = Vector2(72, 32)
		if _ammo_num:
			_ammo_num.add_theme_font_size_override("font_size", 22)
		ammo_box.offset_left = 0.0
		ammo_box.offset_top = 0.0
		ammo_box.offset_right = -(safe.z + 16.0)
		ammo_box.offset_bottom = -(safe.w + 16.0)


func _refresh_ammo_hud() -> void:
	if ammo_box == null or weapons == null:
		return
	var w: Resource = weapons.cur_def()
	var show: bool = w != null and weapons.state != "holstered" and not weapons.hidden_by_mode
	ammo_box.visible = show
	if not show:
		return
	var a: Vector2i = weapons.ammo_of(w.id)
	if _ammo_icon.texture != w.icon:
		_ammo_icon.texture = w.icon
	_set_text(_ammo_name, w.display_name.get_slice("（", 0))
	_set_text(_ammo_num, "%d / %d" % [a.x, a.y])
	var col := Color(0.95, 0.45, 0.35) if a.x == 0 else (Color(1.0, 0.8, 0.5) if a.x <= maxi(1, w.mag_size / 4) else Color(1, 1, 1))
	if _ammo_col != col:
		_ammo_col = col
		_ammo_num.add_theme_color_override("font_color", col)
	var st := ""
	match str(weapons.state):
		"reloading":
			st = " · 换弹中"
		"drawing":
			st = " · 取枪"
		"holstering":
			st = " · 收枪"
	_set_text(_ammo_mode, MODE_NAMES.get(w.fire_mode, w.fire_mode) + st + ("" if a.x > 0 else ("  按 R 换弹" if a.y > 0 else "  没有备弹")))


var _ammo_col := Color(0, 0, 0, 0)


func _set_text(l: Label, t: String) -> void:
	if l.text != t:
		l.text = t