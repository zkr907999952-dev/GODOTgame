extends Control
## 触屏操作（移植网页 scene.tsx 触摸手势 + overlay.tsx 第一人称虚拟摇杆 / 按钮 + fp-control.ts CrouchHold）。
##
## 观察（展示互动）模式：
##   · 单指点/按在角色身上 = 当前互动工具（和鼠标左键同一套）
##   · 双击后按住拖动 = 环绕。单指拖动（包括点在空白处）不再环绕。
##   · 双指 = 平移 + 捏合缩放，第二根手指落下会取消当前工具
## 角色控制（第一人称）模式：
##   · 左下虚拟摇杆（128px，外圈 ≥ 0.72 = 奔跑，径向死区 0.15）
##   · 右下：跳跃 / 下蹲已对调；开火下移；武器键靠下向中间；新增瞄准键（默认切换）
##   · 左侧 FOV 竖条只在打开「摄像机」面板时显示
##   · 其余区域拖动 = 转视角（独立的触屏灵敏度）；第一人称下点画面不会触发工具
##   · 两种模式都有「切换」按钮（= Tab），贴在屏幕上边缘（安全区下方）
## 每根手指按 index 单独跟踪角色（摇杆 / 视角 / 按钮 / 工具 / 环绕 / 双指），互不干扰。
## 落在 HUD 面板 / 按钮上的手指交给 GUI（触摸模拟鼠标），这里不处理。

const STICK_SIZE := 128.0
const STICK_MAX := STICK_SIZE * 0.32
const KNOB := 48.0
const BTN := 64.0
const GAP := 12.0
const EDGE_X := 20.0
const EDGE_B := 32.0
const STICK_SPRINT := 0.72
const DEADZONE := 0.15
const TAP_MS := 340
const TAP_PX := 38.0
const HOLD_MS := 280
const CROUCH_LONG_MS := 500

var player: Node = null
var hud: Node = null
var game: Node = null
var enabled: bool = false
## 安全区边距（逻辑像素）：x = 左，y = 上，z = 右，w = 下
var safe: Vector4 = Vector4.ZERO

var fingers: Dictionary = {}  # index -> {role, start, pos, t0}
var stick_vec: Vector2 = Vector2.ZERO
var _last_tap_t: int = -100000
var _last_tap_pos: Vector2 = Vector2.ZERO
var _two_mid: Vector2 = Vector2.ZERO
var _two_dist: float = 0.0
var _crouch_t0: int = -1
var _crouch_long: bool = false
var _pressed_btn: Dictionary = {}  # id -> true（高亮）
var _font: Font
var _weapon_drag_moved: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	visible = false


func setup(p: Node, h: Node, g: Node) -> void:
	player = p
	hud = h
	game = g


func set_enabled(on: bool) -> void:
	enabled = on
	visible = on
	if player:
		player.set("touch_active", on)
	_release_all()
	queue_redraw()


func _release_all() -> void:
	for idx in fingers.keys():
		_end_finger(idx, fingers[idx]["pos"])
	fingers.clear()
	stick_vec = Vector2.ZERO
	_push_stick()


func _fp() -> bool:
	return player != null and bool(player.get("first_person"))


func _blocked() -> bool:
	if game and game.get("map_view") and bool(game.get("map_view").get("is_open")):
		return true
	return player == null or bool(player.get("input_locked"))


# ------------------------------------------------------------------ layout
func vp() -> Vector2:
	return get_viewport_rect().size


func stick_center() -> Vector2:
	return Vector2(safe.x + EDGE_X + STICK_SIZE * 0.5, vp().y - safe.w - EDGE_B - STICK_SIZE * 0.5)


## 按钮布局：id -> [Rect2, 文字]
func buttons() -> Dictionary:
	var out := {}
	var v := vp()
	var x := v.x - safe.z - EDGE_X - BTN
	var y := v.y - safe.w - EDGE_B - BTN
	var mode_txt := "观察" if _fp() else "控制"
	# 贴上边缘（状态栏 / 安全区下方），不再落在屏幕中部。
	var top := safe.y + 6.0
	out["mode"] = [Rect2(Vector2(v.x * 0.5 - 56.0, top), Vector2(112, 44)), "切换·" + mode_txt]
	if _fp():
		# 下蹲与跳跃对调：跳跃占用原来的下蹲位（上），下蹲占用原来的跳跃位（右下）。
		var crouch_txt := "匍匐" if str(player.call("get_stance")) == "prone" else "下蹲"
		out["crouch"] = [Rect2(Vector2(x, y), Vector2(BTN, BTN)), crouch_txt]
		out["jump"] = [Rect2(Vector2(x, y - BTN - GAP), Vector2(BTN, BTN)), "跳跃"]
		out["interact"] = [Rect2(Vector2(x, y - 2.0 * (BTN + GAP)), Vector2(BTN, BTN)), "互动"]
		var x2 := x - BTN - GAP
		# 武器键靠下并向中间收一点，避开右边缘和开火。
		out["weapon"] = [Rect2(Vector2(x2 - 36.0, y), Vector2(BTN, BTN)), "武器"]
		if _armed():
			# 开火下移，但与下方武器键留出间隙；瞄准在开火左侧。
			var fire := Rect2(Vector2(x2 - 8.0, y - (BTN + 16.0) - 12.0), Vector2(BTN + 16.0, BTN + 16.0))
			out["fire"] = [fire, "开火"]
			out["ads"] = [Rect2(Vector2(fire.position.x - BTN - GAP - 10.0, fire.position.y + 8.0), Vector2(BTN, BTN)), "瞄准"]
			out["reload"] = [Rect2(Vector2(x2, y - 2.0 * (BTN + GAP) - 8.0), Vector2(BTN, BTN)), "换弹"]
	return out


func _weapons() -> Node:
	return player.call("get_weapons") if player and player.has_method("get_weapons") else null


func _armed() -> bool:
	var w := _weapons()
	return w != null and bool(w.call("is_armed"))


func zoom_visible() -> bool:
	return _fp() and hud != null and hud.has_method("camera_panel_open") and bool(hud.call("camera_panel_open"))


func zoom_rect() -> Rect2:
	if not zoom_visible():
		return Rect2()
	var v := vp()
	var top := v.y * 0.18
	if hud and hud.has_method("touch_top_y"):
		top = maxf(top, float(hud.call("touch_top_y")) + 52.0)
	return Rect2(Vector2(safe.x + 12.0, top), Vector2(36.0, maxf(160.0, v.y * 0.34)))


func _hit_button(p: Vector2) -> String:
	var b := buttons()
	for id in b.keys():
		if (b[id][0] as Rect2).grow(6.0).has_point(p):
			return id
	return ""


# ------------------------------------------------------------------ input
func _input(event: InputEvent) -> void:
	if not enabled or not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_on_down(st.index, st.position)
		else:
			_on_up(st.index, st.position)
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_on_drag(sd.index, sd.position, sd.relative)


func _on_down(idx: int, p: Vector2) -> void:
	if fingers.has(idx):
		_on_up(idx, p)
	var f := {"role": "none", "start": p, "pos": p, "t0": Time.get_ticks_msec()}
	fingers[idx] = f
	if hud and hud.has_method("point_over_ui") and bool(hud.call("point_over_ui", p)):
		f["role"] = "ui"
		return
	if _blocked():
		return
	var bid := _hit_button(p)
	if bid != "":
		f["role"] = "btn:" + bid
		_button(bid, true)
		get_viewport().set_input_as_handled()
		return
	if _fp():
		if p.distance_to(stick_center()) <= STICK_SIZE * 0.5 + 8.0 and not _has_role("stick"):
			f["role"] = "stick"
			_stick_to(p)
		elif zoom_visible() and zoom_rect().grow(8.0).has_point(p):
			f["role"] = "zoom"
			_zoom_to(p)
		else:
			f["role"] = "look"
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	# ---- 观察模式
	var scene_fingers := _scene_fingers()
	if scene_fingers.size() >= 2:
		# 第二根手指：取消工具 / 环绕，进入双指平移 + 捏合（网页 touchStart）
		player.call("touch_tool_end")
		for k in scene_fingers:
			fingers[k]["role"] = "two"
		_two_reset()
		get_viewport().set_input_as_handled()
		return
	var now := Time.get_ticks_msec()
	var is_double := now - _last_tap_t < TAP_MS and p.distance_to(_last_tap_pos) < TAP_PX
	if is_double:
		_last_tap_t = -100000
		f["role"] = "orbit"
		player.call("touch_tool_end")
	elif bool(player.call("touch_tool_begin", p)):
		f["role"] = "tool"
	else:
		# 单指点空白或拖动不再环绕；环绕只走双击后拖动。
		f["role"] = "none"
	get_viewport().set_input_as_handled()


func _on_drag(idx: int, p: Vector2, rel: Vector2) -> void:
	if not fingers.has(idx):
		return
	var f: Dictionary = fingers[idx]
	f["pos"] = p
	match str(f["role"]):
		"stick":
			_stick_to(p)
		"look":
			player.call("touch_look", rel)
		"zoom":
			_zoom_to(p)
		"tool":
			player.call("touch_tool_drag", p)
		"btn:weapon":
			# 手指直接拖到轮盘格子上（轮盘以屏幕中心为圆心）
			if hud and hud.has_method("weapon_wheel_point") and p.distance_to(f["start"]) > TAP_PX * 0.6:
				f["moved"] = true
				hud.call("weapon_wheel_point", p)
		"btn:fire":
			player.call("touch_look", rel)
		"orbit":
			player.call("touch_orbit", rel)
		"two":
			_two_move()
		_:
			return
	get_viewport().set_input_as_handled()


func _on_up(idx: int, p: Vector2) -> void:
	if not fingers.has(idx):
		return
	var f: Dictionary = fingers[idx]
	_end_finger(idx, p)
	fingers.erase(idx)
	var role := str(f["role"])
	if role == "ui" or role == "none":
		return
	# 网页 up：短按且没怎么动 = 一次点按（用于双击判定）
	if not _fp() and (role == "tool" or role == "orbit"):
		var dt := Time.get_ticks_msec() - int(f["t0"])
		if dt < HOLD_MS and p.distance_to(f["start"]) < TAP_PX:
			_last_tap_t = Time.get_ticks_msec()
			_last_tap_pos = p
		else:
			_last_tap_t = -100000
	if role == "two":
		var rest := _scene_fingers()
		if rest.size() >= 2:
			_two_reset()
		else:
			for k in rest:
				fingers[k]["role"] = "none"
	get_viewport().set_input_as_handled()


func _end_finger(idx: int, _p: Vector2) -> void:
	if not fingers.has(idx):
		return
	var role := str(fingers[idx]["role"])
	if role == "stick":
		stick_vec = Vector2.ZERO
		_push_stick()
	elif role == "tool":
		if player:
			player.call("touch_tool_end")
	elif role.begins_with("btn:"):
		if role == "btn:weapon":
			_weapon_drag_moved = bool(fingers[idx].get("moved", false))
		_button(role.substr(4), false)
	queue_redraw()


func _has_role(r: String) -> bool:
	for k in fingers.keys():
		if fingers[k]["role"] == r:
			return true
	return false


func _scene_fingers() -> Array:
	var out: Array = []
	for k in fingers.keys():
		var r := str(fingers[k]["role"])
		if r != "ui" and not r.begins_with("btn:"):
			out.append(k)
	return out


func _two_pos() -> Array:
	var ks := _scene_fingers()
	if ks.size() < 2:
		return []
	var a: Vector2 = fingers[ks[0]]["pos"]
	var b: Vector2 = fingers[ks[1]]["pos"]
	return [(a + b) * 0.5, a.distance_to(b)]


func _two_reset() -> void:
	var tp := _two_pos()
	if tp.is_empty():
		return
	_two_mid = tp[0]
	_two_dist = tp[1]


## 网页 touchMove：中点位移 = 平移；间距变化 > 10px = 捏合缩放（scale = 旧 / 新）
func _two_move() -> void:
	var tp := _two_pos()
	if tp.is_empty():
		return
	var m: Vector2 = tp[0]
	var d: float = tp[1]
	player.call("touch_pan", m - _two_mid)
	if absf(d - _two_dist) > 10.0 and _two_dist > 8.0 and d > 8.0:
		player.call("touch_dolly", _two_dist / d)
		_two_dist = d
	_two_mid = m


func _stick_to(p: Vector2) -> void:
	var d := p - stick_center()
	if d.length() > STICK_MAX:
		d = d.normalized() * STICK_MAX
	stick_vec = d / STICK_MAX
	_push_stick()
	queue_redraw()


func _push_stick() -> void:
	if player == null:
		return
	var v := stick_vec
	var m := v.length()
	if m < DEADZONE:
		v = Vector2.ZERO
	else:
		v = v * ((m - DEADZONE) / (1.0 - DEADZONE) / m)
	player.set("touch_move", v)
	player.set("touch_sprint", stick_vec.length() >= STICK_SPRINT)


func _zoom_to(p: Vector2) -> void:
	var r := zoom_rect()
	var t := clampf(1.0 - (p.y - r.position.y) / r.size.y, 0.0, 1.0)  # 上 = 放大
	var lo: float = player.get("fp_fov_min")
	var hi: float = player.get("fp_fov_max")
	player.call("touch_set_fov", hi + (lo - hi) * t)
	queue_redraw()


func _button(id: String, down: bool) -> void:
	if down:
		_pressed_btn[id] = true
	else:
		_pressed_btn.erase(id)
	match id:
		"mode":
			if down:
				player.call("toggle_play_mode")
				_release_all_except_buttons()
		"jump":
			if down:
				player.set("touch_jump_req", true)
		"interact":
			player.call("touch_interact", down)
		"weapon":
			# 按下 = 打开轮盘；拖到格子上松手 = 选中；原地松手 = 关闭不变
			if hud == null:
				pass
			elif down:
				hud.call("open_weapon_wheel", null)
			elif bool(hud.call("is_wheel_open")):
				hud.call("close_weapon_wheel", _weapon_drag_moved)
				_weapon_drag_moved = false
		"fire":
			var w := _weapons()
			if w:
				w.call("set_trigger", down)
		"reload":
			var w2 := _weapons()
			if w2 and down:
				w2.call("reload")
		"ads":
			var w3 := _weapons()
			if w3 == null:
				pass
			elif player and bool(player.get("ads_toggle")):
				if down:
					w3.call("set_ads", not bool(w3.get("ads")))
			else:
				w3.call("set_ads", down)
		"crouch":
			# 网页 CrouchHold：点按 = 蹲下 / 起身；长按 0.5s = 匍匐（切换）
			if down:
				_crouch_t0 = Time.get_ticks_msec()
				_crouch_long = false
			else:
				if not _crouch_long and _crouch_t0 >= 0:
					player.call("touch_crouch_tap")
				_crouch_t0 = -1
	queue_redraw()


func _release_all_except_buttons() -> void:
	for k in fingers.keys():
		var r := str(fingers[k]["role"])
		if not r.begins_with("btn:") and r != "ui":
			_end_finger(k, fingers[k]["pos"])
			fingers[k]["role"] = "none"


func _process(_dt: float) -> void:
	if not enabled:
		return
	if _crouch_t0 >= 0 and not _crouch_long and Time.get_ticks_msec() - _crouch_t0 >= CROUCH_LONG_MS:
		_crouch_long = true
		player.call("toggle_prone")
	if not _fp() and _has_role("stick"):
		_release_all_except_buttons()
	queue_redraw()


# ------------------------------------------------------------------ draw
func _draw() -> void:
	if not enabled or _blocked():
		return
	var fg := Color(0.95, 0.96, 0.98, 0.9)
	var surf := Color(0.12, 0.13, 0.16, 0.45)
	var line := Color(1, 1, 1, 0.35)
	var accent := Color(0.93, 0.55, 0.42, 0.9)
	var b := buttons()
	for id in b.keys():
		var r: Rect2 = b[id][0]
		var on: bool = _pressed_btn.has(id) or (id == "crouch" and str(player.call("get_stance")) != "stand")
		if id == "ads":
			var wads := _weapons()
			on = on or (wads != null and bool(wads.get("ads")))
		if id == "mode":
			draw_style_box(_box(Color(0.12, 0.13, 0.16, 0.6), line, 22.0), r)
		else:
			draw_circle(r.get_center(), r.size.x * 0.5, accent if on else surf)
			draw_arc(r.get_center(), r.size.x * 0.5, 0.0, TAU, 40, line, 1.5, true)
		_text_center(str(b[id][1]), r.get_center(), 14 if id != "mode" else 13, fg)
	if _fp():
		var c := stick_center()
		var sprint := stick_vec.length() >= STICK_SPRINT
		draw_circle(c, STICK_SIZE * 0.5, Color(0.93, 0.55, 0.42, 0.25) if sprint else surf)
		draw_arc(c, STICK_SIZE * 0.5, 0.0, TAU, 48, accent if sprint else line, 1.5, true)
		draw_arc(c, STICK_SIZE * 0.23, 0.0, TAU, 32, Color(1, 1, 1, 0.25), 1.0, true)
		draw_circle(c + stick_vec * STICK_MAX, KNOB * 0.5, accent)
		_text_center("奔跑" if sprint else "外圈奔跑", c + Vector2(0, STICK_SIZE * 0.5 + 12.0), 11, Color(0.8, 0.82, 0.86, 0.8))
		# 缩放竖条：只在摄像机面板打开时显示
		var zr := zoom_rect()
		if zr.size.y > 1.0:
			draw_style_box(_box(surf, line, 18.0), zr)
			var lo: float = player.get("fp_fov_min")
			var hi: float = player.get("fp_fov_max")
			var t := clampf((hi - float(player.get("fp_fov"))) / maxf(1.0, hi - lo), 0.0, 1.0)
			var ty := zr.position.y + zr.size.y * (1.0 - t)
			draw_circle(Vector2(zr.get_center().x, clampf(ty, zr.position.y + 10.0, zr.end.y - 10.0)), 10.0, fg)
			_text_center("%d°" % int(round(float(player.get("fp_fov")))), Vector2(zr.get_center().x, zr.end.y + 12.0), 11, Color(0.8, 0.82, 0.86, 0.8))
		# 准星（网页 FP 十字）
		var cc := vp() * 0.5
		draw_line(cc - Vector2(8, 0), cc + Vector2(8, 0), Color(1, 1, 1, 0.7), 1.0)
		draw_line(cc - Vector2(0, 8), cc + Vector2(0, 8), Color(1, 1, 1, 0.7), 1.0)


func _box(bg: Color, border: Color, radius: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(radius))
	return sb


func _text_center(t: String, c: Vector2, size: int, col: Color) -> void:
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, c + Vector2(-w * 0.5, size * 0.35), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
