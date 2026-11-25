extends RefCounted
## 触屏 HUD 统一布局：安全区内登记矩形，避免可点控件互相重叠。
## PC / 桌面布局不走这里，以免回归。
class_name HudLayout

const GAP := 8.0
const EDGE := 16.0
const EPS := 1.0
const CHROME_H_TOUCH := 48.0
const CHROME_H_PC := 32.0
const CHROME_W_TOUCH := 72.0
const CHROME_W_COMPACT := 60.0
const CHROME_W_PC := 80.0
const TOOL_H_TOUCH := 48.0
const ENTER_H_TOUCH := 40.0
const MODE_SIZE := Vector2(112, 44)
const VCAM_SIZE := Vector2(128, 40)

var vp: Vector2 = Vector2(1280, 720)
var safe: Vector4 = Vector4.ZERO
var touch: bool = false
var compact: bool = false
## {id: String, rect: Rect2, interactive: bool}
var claims: Array = []


func begin(viewport: Vector2, safe_px: Vector4, is_touch: bool) -> void:
	vp = viewport
	safe = safe_px
	touch = is_touch
	compact = is_touch and viewport.x < 640.0
	claims.clear()


func usable() -> Rect2:
	var p := Vector2(safe.x, safe.y)
	var s := Vector2(maxf(1.0, vp.x - safe.x - safe.z), maxf(1.0, vp.y - safe.y - safe.w))
	return Rect2(p, s)


func chrome_size() -> Vector2:
	if not touch:
		return Vector2(CHROME_W_PC, CHROME_H_PC)
	return Vector2(CHROME_W_COMPACT if compact else CHROME_W_TOUCH, CHROME_H_TOUCH)


func top_y() -> float:
	return safe.y + EDGE


func left_x() -> float:
	return safe.x + EDGE


func right_x() -> float:
	return vp.x - safe.z - EDGE


func bottom_y() -> float:
	return vp.y - safe.w - EDGE


func second_row_y() -> float:
	return top_y() + chrome_size().y + GAP


func claim(id: String, rect: Rect2, interactive: bool = true, resolve: bool = true) -> Rect2:
	var r := rect
	if r.size.x < 1.0 or r.size.y < 1.0:
		return r
	if resolve:
		r = resolve_rect(r)
	r = clamp_to_usable(r)
	claims.append({"id": id, "rect": r, "interactive": interactive})
	return r


func clamp_to_usable(rect: Rect2) -> Rect2:
	var u := usable()
	var p := rect.position
	var s := rect.size
	if s.x > u.size.x:
		s.x = u.size.x
	if s.y > u.size.y:
		s.y = u.size.y
	p.x = clampf(p.x, u.position.x, u.end.x - s.x)
	p.y = clampf(p.y, u.position.y, u.end.y - s.y)
	return Rect2(p, s)


func overlaps_rect(a: Rect2, b: Rect2) -> bool:
	if a.size.x < 1.0 or a.size.y < 1.0 or b.size.x < 1.0 or b.size.y < 1.0:
		return false
	# 允许共边，1 像素内的贴合不算重叠。
	return a.grow(-EPS).intersects(b)


func first_overlap(rect: Rect2, ignore_id: String = "") -> int:
	for i in claims.size():
		var c: Dictionary = claims[i]
		if ignore_id != "" and str(c.get("id", "")) == ignore_id:
			continue
		if not bool(c.get("interactive", true)):
			continue
		if overlaps_rect(rect, c["rect"]):
			return i
	return -1


func resolve_rect(rect: Rect2) -> Rect2:
	var r := rect
	var u := usable()
	for _try in 16:
		var hit := first_overlap(r)
		if hit < 0:
			return r
		var other: Rect2 = claims[hit]["rect"]
		# 优先下移到对方下方；不行再右移 / 左移。
		var down := Rect2(Vector2(r.position.x, other.end.y + GAP), r.size)
		if down.end.y <= u.end.y + EPS and first_overlap(down) < 0:
			r = down
			continue
		var right := Rect2(Vector2(other.end.x + GAP, r.position.y), r.size)
		if right.end.x <= u.end.x + EPS and first_overlap(right) < 0:
			r = right
			continue
		var left := Rect2(Vector2(other.position.x - GAP - r.size.x, r.position.y), r.size)
		if left.position.x >= u.position.x - EPS and first_overlap(left) < 0:
			r = left
			continue
		# 再试：下移并夹进可用区。
		r = clamp_to_usable(down)
		if first_overlap(r) < 0:
			return r
		# 最后：稍微再往下推一步，避免死循环。
		r.position.y = minf(u.end.y - r.size.y, r.position.y + maxf(GAP, other.end.y - r.position.y + GAP))
		r = clamp_to_usable(r)
	return clamp_to_usable(r)


## 从左到右排，宽度不够就换行。返回 {id: Rect2, height: float, end: Vector2}
func pack_row(items: Array, origin: Vector2, max_width: float, gap: float = GAP) -> Dictionary:
	var out := {}
	var x := origin.x
	var y := origin.y
	var row_h := 0.0
	var total_h := 0.0
	var max_x := origin.x
	var start_x := origin.x
	var limit := origin.x + maxf(1.0, max_width)
	for it in items:
		var id := str(it.get("id", ""))
		var sz: Vector2 = it.get("size", Vector2(80, 40))
		if sz.x > max_width:
			sz.x = max_width
		if x > start_x and x + sz.x > limit + EPS:
			x = start_x
			y += row_h + gap
			row_h = 0.0
		var r := Rect2(Vector2(x, y), sz)
		r = claim(id, r, bool(it.get("interactive", true)), true)
		out[id] = r
		x = r.end.x + gap
		row_h = maxf(row_h, r.size.y)
		total_h = (r.end.y - origin.y)
		max_x = maxf(max_x, r.end.x)
	return {"rects": out, "height": maxf(total_h, row_h), "end": Vector2(max_x, origin.y + maxf(total_h, row_h))}


func apply_to_control(c: Control, rect: Rect2) -> void:
	if c == null:
		return
	c.position = rect.position
	c.size = rect.size
	c.custom_minimum_size = rect.size


func control_rect(c: Control) -> Rect2:
	if c == null:
		return Rect2()
	var r := c.get_global_rect()
	if r.size.x < 2.0 or r.size.y < 2.0:
		r.size = Vector2(maxf(r.size.x, c.custom_minimum_size.x), maxf(r.size.y, c.custom_minimum_size.y))
	return r


func interactive_overlaps() -> Array:
	var hits: Array = []
	var n := claims.size()
	for i in n:
		var a: Dictionary = claims[i]
		if not bool(a.get("interactive", true)):
			continue
		for j in range(i + 1, n):
			var b: Dictionary = claims[j]
			if not bool(b.get("interactive", true)):
				continue
			if overlaps_rect(a["rect"], b["rect"]):
				hits.append([str(a["id"]), str(b["id"]), a["rect"], b["rect"]])
	return hits


func out_of_safe() -> Array:
	var u := usable()
	var hits: Array = []
	for c in claims:
		var r: Rect2 = c["rect"]
		if r.size.x < 1.0 or r.size.y < 1.0:
			continue
		if r.position.x < u.position.x - EPS or r.position.y < u.position.y - EPS \
				or r.end.x > u.end.x + EPS or r.end.y > u.end.y + EPS:
			hits.append([str(c["id"]), r, u])
	return hits


## 在右上角为断面小窗预留矩形。top 是小窗顶边（通常在第二行或顶栏下方）。
func pip_rect(top: float, both: bool = true) -> Rect2:
	var u := usable()
	var w := 360.0 if both else 188.0
	var h := 210.0
	# 矮屏缩小，避免占掉大半画面和底部按键。
	h = minf(h, maxf(96.0, u.size.y * 0.42))
	w = minf(w, maxf(120.0, u.size.x * 0.40))
	if not both:
		w = minf(w, 188.0)
	var p := Vector2(u.end.x - w, maxf(top, u.position.y))
	if p.y + h > u.end.y:
		h = maxf(80.0, u.end.y - p.y)
	return clamp_to_usable(Rect2(p, Vector2(w, h)))


func chrome_gap_rect(left_end: float, right_start: float, y: float, size: Vector2) -> Rect2:
	var mid := (left_end + right_start) * 0.5
	var x := mid - size.x * 0.5
	if x < left_end + GAP or x + size.x > right_start - GAP:
		return Rect2()  # 放不下
	return Rect2(Vector2(x, y), size)
