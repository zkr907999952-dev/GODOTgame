extends Control
## 武器轮盘：按住 Q（或触屏「武器」按钮）打开，往某个方向拖 / 移动鼠标，松开即选中。
## 武器多于 8 把时分页（滚轮 / 点中心翻页），每格：武器剪影图标 + 名称 + 右下角弹药（弹匣 / 备弹）。

signal picked(id: String)

const PER_PAGE := 8
const DEAD := 34.0

var weapons: Node  # weapon_system
var is_open: bool = false
var page: int = 0
var hover: int = -1  # 本页序号；-1 = 无；HOLSTER = 收枪格
var _origin: Vector2 = Vector2.ZERO
var _vec: Vector2 = Vector2.ZERO
var _font: Font
const HOLSTER := 99


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_font = ThemeDB.fallback_font


func _items() -> Array:
	return weapons.defs if weapons else []


func pages() -> int:
	return maxi(1, int(ceil(float(_items().size()) / PER_PAGE)))


func _page_items() -> Array:
	var all := _items()
	return all.slice(page * PER_PAGE, mini(all.size(), (page + 1) * PER_PAGE))


func open(origin: Variant = null) -> void:
	if weapons == null or weapons.defs.is_empty():
		return
	is_open = true
	visible = true
	hover = -1
	_vec = Vector2.ZERO
	_origin = origin if origin is Vector2 else size * 0.5
	# 打开时停在当前武器所在页
	var ids: PackedStringArray = weapons.weapon_ids()
	var ci := ids.find(weapons.current)
	page = ci / PER_PAGE if ci >= 0 else 0
	queue_redraw()


## 关闭；apply = 选中悬停的格子。返回选中的 id（"" = 收枪，null = 没选）
func close(apply: bool = true) -> Variant:
	if not is_open:
		return null
	is_open = false
	visible = false
	var out: Variant = null
	if apply:
		if hover == HOLSTER:
			out = ""
		elif hover >= 0:
			var it := _page_items()
			if hover < it.size():
				out = it[hover].id
	if out != null:
		picked.emit(out)
	return out


func center() -> Vector2:
	return size * 0.5


func radius() -> float:
	return clampf(minf(size.x, size.y) * 0.34, 120.0, 260.0)


## 指针绝对位置（触屏 / 未捕获鼠标）
func point_at(p: Vector2) -> void:
	_vec = p - _origin
	_update_hover()


## 指针相对移动（捕获鼠标）
func move_by(rel: Vector2) -> void:
	_vec = (_vec + rel).limit_length(radius())
	_update_hover()


func _slot_dir(i: int, n: int) -> Vector2:
	var a := -PI * 0.5 + TAU * float(i) / float(n)
	return Vector2(cos(a), sin(a))


func _update_hover() -> void:
	var n := _page_items().size()
	if _vec.length() < DEAD:
		hover = HOLSTER  # 中心 = 收枪
	else:
		var best := -1
		var bd := -2.0
		for i in n:
			var d := _slot_dir(i, n).dot(_vec.normalized())
			if d > bd:
				bd = d
				best = i
		hover = best
	queue_redraw()


func next_page(dir: int = 1) -> void:
	page = wrapi(page + dir, 0, pages())
	_update_hover()


func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).device != InputEvent.DEVICE_ID_EMULATION:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			move_by((event as InputEventMouseMotion).relative)
		else:
			point_at((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			next_page(-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
			get_viewport().set_input_as_handled()


func slot_rect(i: int, n: int) -> Rect2:
	var c := center() + _slot_dir(i, n) * radius()
	var sz := Vector2(clampf(radius() * 0.78, 110.0, 170.0), clampf(radius() * 0.46, 64.0, 96.0))
	return Rect2(c - sz * 0.5, sz)


func _draw() -> void:
	if not is_open:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var c := center()
	var r := radius()
	draw_circle(c, r + 70.0, Color(0.08, 0.09, 0.11, 0.55))
	draw_arc(c, r + 70.0, 0.0, TAU, 96, Color(1, 1, 1, 0.18), 2.0, true)
	var accent := Color(0.93, 0.55, 0.42)
	var it := _page_items()
	var n := it.size()
	for i in n:
		var w: Resource = it[i]
		var rc := slot_rect(i, n)
		var on := i == hover
		var cur: bool = weapons.current == w.id
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.93, 0.55, 0.42, 0.35) if on else Color(0.12, 0.13, 0.16, 0.8)
		sb.border_color = accent if (on or cur) else Color(1, 1, 1, 0.25)
		sb.set_border_width_all(2 if on else 1)
		sb.set_corner_radius_all(10)
		draw_style_box(sb, rc)
		if w.icon:
			var ts: Vector2 = w.icon.get_size()
			var box := rc.grow(-10.0)
			box.size.y -= 16.0
			var k := minf(box.size.x / ts.x, box.size.y / ts.y)
			var dsz := ts * k
			draw_texture_rect(w.icon, Rect2(box.get_center() - dsz * 0.5, dsz), false, Color(1, 1, 1, 0.95) if on else Color(0.85, 0.87, 0.9, 0.8))
		_text(w.display_name.get_slice("（", 0), rc.position + Vector2(8, rc.size.y - 8), 12, Color(0.92, 0.93, 0.95))
		var a: Vector2i = weapons.ammo_of(w.id)
		var at := "%d/%d" % [a.x, a.y]
		var aw := _font.get_string_size(at, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		_text(at, rc.end - Vector2(aw + 8, 8), 13, accent if a.x == 0 else Color(1, 1, 1))
	# 中心：收枪 / 翻页
	var hc := hover == HOLSTER
	draw_circle(c, DEAD + 6.0, Color(0.93, 0.55, 0.42, 0.4) if hc else Color(0.12, 0.13, 0.16, 0.85))
	draw_arc(c, DEAD + 6.0, 0.0, TAU, 48, Color(1, 1, 1, 0.3), 1.5, true)
	_text_c("收枪", c + Vector2(0, -4), 14, Color(1, 1, 1))
	if pages() > 1:
		_text_c("%d/%d 滚轮翻页" % [page + 1, pages()], c + Vector2(0, 16), 10, Color(0.8, 0.82, 0.86))
	if _vec.length() > 2.0:
		draw_line(c, c + _vec.limit_length(r), Color(1, 1, 1, 0.35), 2.0)


func _text(t: String, p: Vector2, s: int, col: Color) -> void:
	draw_string(_font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, s, col)


func _text_c(t: String, p: Vector2, s: int, col: Color) -> void:
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x
	draw_string(_font, p + Vector2(-w * 0.5, s * 0.35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, s, col)
