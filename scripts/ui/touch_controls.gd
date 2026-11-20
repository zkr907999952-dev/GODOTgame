extends Control

const TouchLayout := preload("res://scripts/ui/touch_layout.gd")
## 触屏操作（移植网页 scene.tsx 触摸手势 + overlay.tsx 第一人称虚拟摇杆 / 按钮 + fp-control.ts CrouchHold）。
##
## 观察（展示互动）模式：
##   · 单指点/按在角色身上 = 当前互动工具（和鼠标左键同一套）
##   · 双击后按住拖动 = 环绕。单指拖动（包括点在空白处）不再环绕。
##   · 双指 = 平移 + 捏合缩放，第二根手指落下会取消当前工具
## 角色控制（第一人称）模式：
##   · 左下虚拟摇杆（128px，外圈 ≥ 0.72 = 奔跑，径向死区 0.15）
##   · 右下：跳跃 / 下蹲已对调；互动为点按切换保持（不是长按）；开火再下移；武器键再向左；瞄准在开火左上；左侧中间另有一个开火键
##   · 左侧 FOV 竖条只在打开「摄像机」面板时显示
##   · 其余区域拖动 = 转视角（独立的触屏灵敏度）；第一人称下点画面不会触发工具
##   · 两种模式都有「切换」按钮（= Tab），贴在屏幕上边缘（安全区下方）
## 飞机（仅手机 / 触屏）：默认「滑块模式」右侧为加速键 + 长条偏航滑块 + 减速键（左右拖动偏航，松手回中；加速键仍可按住加力）。「摇杆模式」把加减速和偏航合成一个 `flight_stick`。「按键模式」仍是四个独立按键。滑块和摇杆都不得环绕视角。
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
const TAP_MS := 480
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
var flight_stick_vec: Vector2 = Vector2.ZERO  # +x right, +y down (screen); pushed as +y up
var flight_yaw_slider: float = 0.0  # -1 left .. +1 right, spring-returns on release
var _last_tap_t: int = -100000
var _last_tap_pos: Vector2 = Vector2.ZERO
var _two_mid: Vector2 = Vector2.ZERO
var _two_dist: float = 0.0
var _crouch_t0: int = -1
var _crouch_long: bool = false
var _pressed_btn: Dictionary = {}  # id -> true（高亮）
var _font: Font
var _weapon_drag_moved: bool = false
var _weapon_press_pos: Vector2 = Vector2.ZERO
## 最近一次真实 ScreenTouch 的时间戳；这段时间内忽略触摸模拟鼠标，避免同一指被处理两次。
var _screen_touch_until: int = 0
## 自定义按键布局（编辑中的工作副本；空则读 TouchLayout 已保存的布局）。
var layout_edit: bool = false
var layout_selected: String = ""
var layout_working: Dictionary = {}
signal layout_selection_changed(id)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
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
	flight_stick_vec = Vector2.ZERO
	_push_flight_stick()
	flight_yaw_slider = 0.0
	_push_flight_yaw_slider()


func _fp() -> bool:
	return player != null and bool(player.get("first_person"))


func _blocked() -> bool:
	if game and game.get("map_view") and bool(game.get("map_view").get("is_open")):
		return true
	return player == null or bool(player.get("input_locked"))


# ------------------------------------------------------------------ layout
func vp() -> Vector2:
	return get_viewport_rect().size


## 把 ScreenTouch / 模拟鼠标坐标统一到本控件所在的逻辑像素（content_scale 空间）。
## 真机事件有时是窗口物理像素，按钮命中和点身体会整体错位。
## 划屏增量必须和位置用同一套换算：不能只因为 backing 更大就把 relative 一律缩小，
## 否则事件已经是逻辑像素时灵敏度会再被压低一截。
func _pos_is_backing(p: Vector2) -> bool:
	var vis := get_viewport_rect()
	var vp := get_viewport()
	if vp == null:
		return false
	var backing := Vector2(vp.size)
	if backing.x <= vis.size.x * 1.08 or vis.size.x <= 1.0:
		return false
	# 超出逻辑矩形，一定是物理像素
	if p.x > vis.size.x + 24.0 or p.y > vis.size.y + 24.0:
		return true
	# 落在逻辑矩形内时不能单靠位置判断（左上角的物理坐标也会落在里面）。
	# 只有明显更接近 backing 尺度时才当物理像素。
	return false


func _to_logical(p: Vector2) -> Vector2:
	var vis := get_viewport_rect()
	var vp := get_viewport()
	if vp == null or not _pos_is_backing(p):
		return p
	var backing := Vector2(vp.size)
	return Vector2(p.x * vis.size.x / backing.x, p.y * vis.size.y / backing.y)


func _logical_pos(p: Vector2) -> Vector2:
	return _to_logical(p)


func _logical_rel(rel: Vector2, pos: Vector2 = Vector2.ZERO) -> Vector2:
	# 只有位置本身是物理像素、被换算过时，才按同样比例缩放增量。
	if pos != Vector2.ZERO and _pos_is_backing(pos):
		var vis := get_viewport_rect().size
		var vp := get_viewport()
		if vp:
			var backing := Vector2(vp.size)
			if backing.x > 1.0 and vis.x > 1.0:
				return Vector2(rel.x * vis.x / backing.x, rel.y * vis.y / backing.y)
	return rel


func _in_drive() -> bool:
	return player != null and str(player.get("occupancy")) in ["car", "plane"]


func _in_vehicle() -> bool:
	return player != null and str(player.get("occupancy")) != ""


func _in_surgery() -> bool:
	if player and player.has_method("get_surgery"):
		var s: Node = player.call("get_surgery")
		return s != null and bool(s.call("is_active"))
	return hud != null and hud.has_method("is_surgery_active") and bool(hud.call("is_surgery_active"))


func _surgery_tool() -> String:
	if player and player.has_method("get_surgery"):
		var s: Node = player.call("get_surgery")
		if s:
			return str(s.call("current_tool"))
	return ""


func _map_open() -> bool:
	return hud != null and hud.has_method("is_map_open") and bool(hud.call("is_map_open"))


func _show_stick() -> bool:
	if layout_edit:
		return true
	if _map_open() or _in_surgery():
		return false
	return _fp() or _in_drive()


func _flight_control_mode() -> String:
	if hud:
		var s = hud.call("_settings") if hud.has_method("_settings") else null
		if s and "flight_control_mode" in s:
			var m := str(s.get("flight_control_mode"))
			if m in ["slider", "stick", "buttons"]:
				return m
	return "slider"  # default is 滑块模式


func _flight_stick_mode() -> bool:
	return _flight_control_mode() == "stick"


func _flight_slider_mode() -> bool:
	return _flight_control_mode() == "slider"


func _in_plane() -> bool:
	if hud and hud.get("_vehicle_system"):
		var vs = hud.get("_vehicle_system")
		var occ = vs.get("occupied") if vs else null
		if occ and vs.has_method("kind_of"):
			return str(vs.call("kind_of", occ)) == "plane"
	return false


func _show_flight_stick() -> bool:
	if layout_edit:
		return true
	if _map_open() or not _flight_stick_mode():
		return false
	return _in_drive() and _in_plane()


func _show_flight_yaw_slider() -> bool:
	if layout_edit:
		return true
	if _map_open() or not _flight_slider_mode():
		return false
	return _in_drive() and _in_plane()


func flight_stick_center() -> Vector2:
	var it := _default_item("flight_stick")
	return _layout_center("flight_stick", it["center"])


func flight_stick_radius() -> float:
	return STICK_SIZE * 0.5 * _layout_scale("flight_stick")


func flight_yaw_slider_item() -> Dictionary:
	return _default_item("flight_yaw_slider")


func flight_yaw_slider_rect() -> Rect2:
	var it := flight_yaw_slider_item()
	var sz: Vector2 = it["size"] * _layout_scale("flight_yaw_slider")
	var c := _layout_center("flight_yaw_slider", it["center"])
	return Rect2(c - sz * 0.5, sz)

func _thrust_bar_default_center(right: float, by: float, bs: Vector2) -> Vector2:
	## Sit immediately left of the active right-side flight cluster, with a
	## 10 px gap. On PC (no on-screen buttons) use a comparable lower-right slot.
	var gap := 10.0
	var mode := _flight_control_mode()
	if mode == "slider":
		var sl := Vector2(200, 52)
		var sl_left := right - sl.x
		return Vector2(sl_left - gap - bs.x * 0.5, by - 110.0)
	if mode == "stick":
		var fs := Vector2(STICK_SIZE, STICK_SIZE)
		var fsc := Vector2(right - fs.x * 0.5 - 8.0, by - 200.0 + fs.y * 0.5)
		var fs_left := fsc.x - fs.x * 0.5
		return Vector2(fs_left - gap - bs.x * 0.5, fsc.y)
	if mode == "buttons":
		# Left of the interactive thrust lever, which itself sits left of the buttons.
		var lever_x := right - 88.0 - 12.0 - 40.0
		return Vector2(lever_x - gap - bs.x * 0.5, by - 200.0 + bs.y * 0.5)
	# PC / no touch cluster: lower-right HUD slot.
	return Vector2(right - 16.0 - bs.x * 0.5, by - 200.0 + bs.y * 0.5)


func _usable() -> Rect2:
	return TouchLayout.usable_rect(vp(), safe)


func _layout_dict() -> Dictionary:
	if layout_edit:
		return layout_working
	return TouchLayout.current()


func _layout_center(id: String, default_c: Vector2) -> Vector2:
	var data := _layout_dict()
	if not data.has(id):
		return default_c
	var e: Dictionary = data[id]
	var u := _usable()
	return Vector2(
		u.position.x + clampf(float(e.get("x", 0.5)), 0.0, 1.0) * u.size.x,
		u.position.y + clampf(float(e.get("y", 0.5)), 0.0, 1.0) * u.size.y
	)


func _layout_scale(id: String) -> float:
	var data := _layout_dict()
	if not data.has(id):
		return 1.0
	return clampf(float(data[id].get("s", 1.0)), TouchLayout.SCALE_MIN, TouchLayout.SCALE_MAX)


func _rect_from(id: String, default_pos: Vector2, default_size: Vector2) -> Rect2:
	var sc := _layout_scale(id)
	var sz := default_size * sc
	var c := _layout_center(id, default_pos + default_size * 0.5)
	return Rect2(c - sz * 0.5, sz)


func stick_center() -> Vector2:
	var raw := Vector2(safe.x + EDGE_X + STICK_SIZE * 0.5, vp().y - safe.w - EDGE_B - STICK_SIZE * 0.5)
	return _layout_center("stick", raw)


func stick_radius() -> float:
	return STICK_SIZE * 0.5 * _layout_scale("stick")


func begin_layout_edit() -> void:
	layout_edit = true
	layout_working = TouchLayout.current().duplicate(true)
	layout_selected = ""
	queue_redraw()


func cancel_layout_edit() -> void:
	layout_edit = false
	layout_working = {}
	layout_selected = ""
	queue_redraw()


func commit_layout_edit() -> void:
	TouchLayout.set_layout(layout_working, true)
	layout_edit = false
	layout_selected = ""
	queue_redraw()


func apply_layout_code(code: String) -> bool:
	var parsed := TouchLayout.decode(code)
	if parsed.is_empty() and not TouchLayout.is_valid_code(code):
		return false
	# 空载荷也是合法的「全部默认」。
	if not code.strip_edges().begins_with("TYL"):
		return false
	if TouchLayout.decode(code.strip_edges()) == {} and "." not in code:
		return false
	var check := code.strip_edges().replace(" ", "")
	if not check.begins_with("TYL1."):
		# 仍允许 decode 成功的其他 TYL 版本。
		if parsed.is_empty() and not check.begins_with("TYL"):
			return false
	layout_working = parsed
	if not layout_edit:
		TouchLayout.set_layout(parsed, true)
	queue_redraw()
	if hud and hud.has_method("_refresh_vehicle_touch"):
		hud.call("_refresh_vehicle_touch")
	return true


func current_layout_code() -> String:
	return TouchLayout.encode(layout_working if layout_edit else TouchLayout.current())


func set_selected_scale(s: float) -> void:
	if layout_selected == "":
		return
	var u := _usable()
	var item := _default_item(layout_selected)
	var c: Vector2 = item["center"]
	var data := _layout_dict()
	if data.has(layout_selected):
		c = _layout_center(layout_selected, c)
	if not layout_edit:
		layout_working = TouchLayout.current().duplicate(true)
	layout_working[layout_selected] = TouchLayout.pack_entry(c, s, u)
	queue_redraw()


func selected_scale() -> float:
	return _layout_scale(layout_selected) if layout_selected != "" else 1.0


func _default_item(id: String) -> Dictionary:
	var v := vp()
	var x := v.x - safe.z - EDGE_X - BTN
	var y := v.y - safe.w - EDGE_B - BTN
	var top := safe.y + 6.0
	var right := v.x - safe.z - 16.0
	var by := v.y - safe.w
	match id:
		"stick":
			var c := Vector2(safe.x + EDGE_X + STICK_SIZE * 0.5, v.y - safe.w - EDGE_B - STICK_SIZE * 0.5)
			return {"center": c, "size": Vector2(STICK_SIZE, STICK_SIZE), "label": "摇杆"}
		"mode":
			var label := "切换·观察" if _fp() else "切换·控制"
			return {"center": Vector2(v.x * 0.5, top + 22.0), "size": Vector2(112, 44), "label": label}
		"vcam":
			var first := false
			if hud and hud.get("_vehicle_system"):
				first = str(hud.get("_vehicle_system").get("vehicle_cam")) == "first"
			return {"center": Vector2(v.x * 0.5, top + 22.0), "size": Vector2(128, 40), "label": "切换·第三人称" if first else "切换·第一人称"}
		"crouch":
			return {"center": Vector2(x + 8.0, y + 8.0) + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "下蹲"}
		"jump":
			return {"center": Vector2(x, y - BTN - GAP) + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "跳跃"}
		"interact":
			return {"center": Vector2(x, y - 2.0 * (BTN + GAP)) + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "互动"}
		"weapon":
			var x2 := x - BTN - GAP
			return {"center": Vector2(x2, y - 2.0 * (BTN + GAP) - 8.0) + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "武器"}
		"fire", "drag":
			var fire_pos := Vector2(x - BTN - GAP - 8.0, y - 20.0)
			var fire_sz := Vector2(BTN + 16.0, BTN + 16.0)
			return {"center": fire_pos + fire_sz * 0.5, "size": fire_sz, "label": "开火" if id == "fire" else "拖拽"}
		"ads":
			var fire_pos2 := Vector2(x - BTN - GAP - 8.0, y - 20.0)
			var ads_pos := Vector2(fire_pos2.x - BTN - GAP - 10.0, y - (BTN + GAP) - 8.0)
			return {"center": ads_pos + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "瞄准"}
		"reload":
			var x2r := x - BTN - GAP
			return {"center": Vector2(x2r - 128.0, y) + Vector2(BTN, BTN) * 0.5, "size": Vector2(BTN, BTN), "label": "换弹"}
		"fire_left":
			var fire_sz2 := Vector2(BTN + 16.0, BTN + 16.0)
			var lx := safe.x + EDGE_X
			var ly := v.y * 0.5 - fire_sz2.y * 0.5
			return {"center": Vector2(lx, ly) + fire_sz2 * 0.5, "size": fire_sz2, "label": "左开火"}
		"enter":
			var enter_sz := Vector2(108, 48)
			var gear_sz := Vector2(100, 48)
			var enter_x := right - enter_sz.x - 8.0 - gear_sz.x
			return {"center": Vector2(enter_x + enter_sz.x * 0.5, safe.y + 72.0 + 24.0), "size": enter_sz, "label": "上下载具"}
		"observe":
			var orbit := false
			if hud and hud.get("_vehicle_system"):
				orbit = str(hud.get("_vehicle_system").get("vehicle_look_mode")) == "orbit"
			# Top of the screen, immediately left of 透视 (chrome xray).
			# Match the 透视 button size so the two no longer overlap.
			var obs_sz := Vector2(80, 32)
			if hud and hud.get("_btn_xray"):
				var xr: Rect2 = hud.get("_btn_xray").get_global_rect()
				if xr.size.x > 8.0 and xr.size.y > 8.0:
					obs_sz = xr.size
				var obs_c2 := Vector2(xr.position.x - 8.0 - obs_sz.x * 0.5, xr.position.y + obs_sz.y * 0.5)
				return {"center": obs_c2, "size": obs_sz, "label": "观察·开" if orbit else "观察"}
			var obs_c := Vector2(right - obs_sz.x * 0.5, safe.y + 16.0 + obs_sz.y * 0.5)
			return {"center": obs_c, "size": obs_sz, "label": "观察·开" if orbit else "观察"}
		"flight_stick":
			var fs := Vector2(STICK_SIZE, STICK_SIZE)
			var fsc := Vector2(right - fs.x * 0.5 - 8.0, by - 200.0 + fs.y * 0.5)
			return {"center": fsc, "size": fs, "label": "飞控摇杆"}
		"flight_yaw_slider":
			# Long horizontal yaw bar; accel sits above, decel below.
			var sl := Vector2(200, 52)
			var slc := Vector2(right - sl.x * 0.5, by - 110.0)
			return {"center": slc, "size": sl, "label": "偏航"}
		"thrust_bar":
			# Current thrust percentage, immediately left of the right-side cluster.
			var bs := Vector2(28, 150)
			var bc := _thrust_bar_default_center(right, by, bs)
			return {"center": bc, "size": bs, "label": "推力"}
		"accel":
			return {"center": Vector2(right - 44.0, by - 180.0 + 26.0), "size": Vector2(88, 52), "label": "加速"}
		"brake":
			return {"center": Vector2(right - 44.0, by - 122.0 + 26.0), "size": Vector2(88, 52), "label": "手刹"}
		"thrust_up":
			if _flight_slider_mode():
				var sl_up := Vector2(200, 52)
				var slc_up := Vector2(right - sl_up.x * 0.5, by - 110.0)
				return {"center": Vector2(slc_up.x, slc_up.y - sl_up.y * 0.5 - 8.0 - 24.0), "size": Vector2(88, 48), "label": "加速"}
			return {"center": Vector2(right - 44.0, by - 200.0 + 24.0), "size": Vector2(88, 48), "label": "加速"}
		"thrust_down":
			if _flight_slider_mode():
				var sl_dn := Vector2(200, 52)
				var slc_dn := Vector2(right - sl_dn.x * 0.5, by - 110.0)
				return {"center": Vector2(slc_dn.x, slc_dn.y + sl_dn.y * 0.5 + 8.0 + 24.0), "size": Vector2(88, 48), "label": "减速"}
			return {"center": Vector2(right - 44.0, by - 146.0 + 24.0), "size": Vector2(88, 48), "label": "减速"}
		"yaw_l":
			return {"center": Vector2(right - 132.0 + 32.0, by - 250.0 + 20.0), "size": Vector2(64, 40), "label": "Q 偏航"}
		"yaw_r":
			return {"center": Vector2(right - 64.0 + 32.0, by - 250.0 + 20.0), "size": Vector2(64, 40), "label": "E 偏航"}
		"gear":
			var gear_sz := Vector2(100, 48)
			return {"center": Vector2(right - gear_sz.x * 0.5, safe.y + 72.0 + 24.0), "size": gear_sz, "label": "起落架"}
		"thrust":
			return {"center": Vector2(right - 88.0 - 32.0, by - 200.0 + 90.0), "size": Vector2(40, 180), "label": "油门"}
		_:
			return {"center": v * 0.5, "size": Vector2(BTN, BTN), "label": id}


## 按钮布局：id -> [Rect2, 文字]
func buttons() -> Dictionary:
	var out := {}
	if _in_surgery() and not layout_edit:
		# 手术中摇杆和无关触控按钮隐藏，划屏手势仍由本控件处理。
		return out
	if _map_open() and not layout_edit:
		# 打开地图时不显示角色交互按键，地图 UI 自己可用。
		return out
	var item_mode := _default_item("mode")
	# Walking: 切换 is play-mode. In a vehicle, the top view-switch (vcam)
	# toggles first/third person and is shown instead of play-mode 切换.
	if layout_edit or not _in_drive():
		out["mode"] = [_rect_from("mode", item_mode["center"] - item_mode["size"] * 0.5, item_mode["size"]), item_mode["label"]]
	var walk := layout_edit or (_fp() and not _in_drive())
	if walk:
		var crouch_txt := "下蹲"
		if player and player.has_method("get_stance"):
			crouch_txt = "匍匐" if str(player.call("get_stance")) == "prone" else "下蹲"
		for id in ["crouch", "jump", "interact", "weapon"]:
			var it := _default_item(id)
			var label: String = it["label"]
			if id == "crouch":
				label = crouch_txt
			out[id] = [_rect_from(id, it["center"] - it["size"] * 0.5, it["size"]), label]
		if layout_edit or _armed():
			for id in ["fire", "ads", "reload", "fire_left"]:
				var it := _default_item(id)
				out[id] = [_rect_from(id, it["center"] - it["size"] * 0.5, it["size"]), it["label"]]
		elif _drag_available():
			var it := _default_item("drag")
			out["drag"] = [_rect_from("drag", it["center"] - it["size"] * 0.5, it["size"]), "放下" if _drag_holding() else "拖拽"]
	if layout_edit:
		# 载具按键也画出来，方便一次编好行走和载具两套位置。
		for id in ["enter", "vcam", "observe", "accel", "brake", "thrust_up", "thrust_down", "yaw_l", "yaw_r", "gear", "thrust", "flight_stick", "flight_yaw_slider", "thrust_bar"]:
			var it := _default_item(id)
			out[id] = [_rect_from(id, it["center"] - it["size"] * 0.5, it["size"]), it["label"]]
	return out


func _weapons() -> Node:
	return player.call("get_weapons") if player and player.has_method("get_weapons") else null


func _armed() -> bool:
	var w := _weapons()
	return w != null and bool(w.call("is_armed"))


func _drag_holding() -> bool:
	if player and player.has_method("get_corpse_drag"):
		var d = player.call("get_corpse_drag")
		return d != null and bool(d.call("is_dragging"))
	return false


func _drag_available() -> bool:
	if player == null or not player.has_method("get_corpse_drag"):
		return false
	var d = player.call("get_corpse_drag")
	if d == null:
		return false
	return bool(d.call("is_dragging")) or bool(d.call("can_start"))


func fire_slot_rect() -> Rect2:
	# 给 HUD 对齐：原右侧开火键位置。
	var b := buttons()
	if b.has("fire"):
		return b["fire"][0]
	if b.has("drag"):
		return b["drag"][0]
	var v := vp()
	var x := v.x - safe.z - EDGE_X - BTN
	var y := v.y - safe.w - EDGE_B - BTN
	var x2 := x - BTN - GAP
	return Rect2(Vector2(x2 - 8.0, y - 20.0), Vector2(BTN + 16.0, BTN + 16.0))


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
		_screen_touch_until = Time.get_ticks_msec() + 120
		var st := event as InputEventScreenTouch
		if st.pressed:
			_on_down(st.index, _logical_pos(st.position))
		else:
			_on_up(st.index, _logical_pos(st.position))
	elif event is InputEventScreenDrag:
		_screen_touch_until = Time.get_ticks_msec() + 120
		var sd := event as InputEventScreenDrag
		_on_drag(sd.index, _logical_pos(sd.position), _logical_rel(sd.relative, sd.position))
	elif event is InputEventMouseButton and event.device == InputEvent.DEVICE_ID_EMULATION:
		# 真机若同时派发 ScreenTouch 与模拟鼠标：模拟鼠标常晚一帧到达，
		# 会把已经开始的单击工具结束并误判成双击环绕。刚收到 ScreenTouch 则忽略。
		if Time.get_ticks_msec() < _screen_touch_until:
			return
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_on_down(0, _logical_pos(mb.position))
		else:
			_on_up(0, _logical_pos(mb.position))
	elif event is InputEventMouseMotion and event.device == InputEvent.DEVICE_ID_EMULATION:
		if Time.get_ticks_msec() < _screen_touch_until or not fingers.has(0):
			return
		var mm := event as InputEventMouseMotion
		_on_drag(0, _logical_pos(mm.position), _logical_rel(mm.relative, mm.position))


func _on_down(idx: int, p: Vector2) -> void:
	if fingers.has(idx):
		var prev: Dictionary = fingers[idx]
		# 同一指的重复按下（ScreenTouch + 模拟鼠标）不要先抬起再开始，否则单击会被当成双击环绕。
		if p.distance_to(prev["pos"]) < 64.0 and Time.get_ticks_msec() - int(prev["t0"]) < 500:
			return
		_on_up(idx, p)
	var f := {"role": "none", "start": p, "pos": p, "t0": Time.get_ticks_msec()}
	fingers[idx] = f
	if layout_edit:
		# 选中并拖拽按键 / 摇杆，不触发原来的功能。
		var bid := _hit_button(p)
		if bid == "" and p.distance_to(stick_center()) <= stick_radius() + 10.0:
			bid = "stick"
		if bid == "" and p.distance_to(flight_stick_center()) <= flight_stick_radius() + 10.0:
			bid = "flight_stick"
		if bid == "" and flight_yaw_slider_rect().grow(10.0).has_point(p):
			bid = "flight_yaw_slider"
		if bid != "":
			layout_selected = bid
			f["role"] = "layout:" + bid
			layout_selection_changed.emit(bid)
			queue_redraw()
		get_viewport().set_input_as_handled()
		return
	if hud and hud.has_method("point_over_ui") and bool(hud.call("point_over_ui", p)):
		f["role"] = "ui"
		return
	if _blocked():
		return
	var bid := _hit_button(p)
	if bid != "":
		f["role"] = "btn:" + bid
		if bid == "weapon":
			# 轮盘画在屏幕中央；记下按下点，拖动位移作用在中心轮盘上。
			_weapon_press_pos = p
		_button(bid, true)
		get_viewport().set_input_as_handled()
		return
	# 摇杆优先：只要点在摇杆上，就只开车杆，绝不转视角。
	if _show_stick() and p.distance_to(stick_center()) <= stick_radius() + 8.0 and not _has_role("stick"):
		f["role"] = "stick"
		_stick_to(p)
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	if _show_flight_stick() and p.distance_to(flight_stick_center()) <= flight_stick_radius() + 8.0 and not _has_role("flight_stick"):
		f["role"] = "flight_stick"
		_flight_stick_to(p)
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	if _show_flight_yaw_slider() and flight_yaw_slider_rect().grow(8.0).has_point(p) and not _has_role("flight_yaw_slider"):
		f["role"] = "flight_yaw_slider"
		_flight_yaw_slider_to(p)
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	if _in_surgery():
		# 未选工具：划屏控制检查床视角。选了工具：落在身上则走手术刀/拿取，视角锁定。
		# 观察视角下双指拖拽只平移摄像机，不环绕。
		var stool := _surgery_tool()
		var scene_fingers := _scene_fingers()
		if (stool == "" or stool == "none") and scene_fingers.size() >= 2:
			player.call("touch_tool_end")
			f["role"] = "two"
			for k in scene_fingers:
				fingers[k]["role"] = "two"
			_two_reset()
			get_viewport().set_input_as_handled()
			queue_redraw()
			return
		if stool == "" or stool == "none":
			f["role"] = "look" if _fp() else "orbit"
		elif bool(player.call("touch_tool_begin", p)):
			f["role"] = "tool"
		else:
			f["role"] = "none"
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	if _fp() and not _in_drive():
		if zoom_visible() and zoom_rect().grow(8.0).has_point(p):
			f["role"] = "zoom"
			_zoom_to(p)
		else:
			f["role"] = "look"
		get_viewport().set_input_as_handled()
		queue_redraw()
		return
	if _in_drive():
		# 载具内取消双指拖拽旋转视角，避免和右侧划屏偏航冲突。
		# 观察键打开时，单指拖动旋转、松手回正；双指拖拽只平移摄像机，绝不环绕。
		var orbit_mode := false
		if hud and hud.get("_vehicle_system") and hud.get("_vehicle_system").has_method("is_observe_orbit"):
			orbit_mode = bool(hud.get("_vehicle_system").call("is_observe_orbit"))
		var scene_fingers := _scene_fingers()
		if scene_fingers.size() >= 2:
			# Second finger must not convert an existing yaw/look into orbit.
			if orbit_mode:
				f["role"] = "two"
				for k in scene_fingers:
					fingers[k]["role"] = "two"
				_two_reset()
			else:
				f["role"] = "none"
			get_viewport().set_input_as_handled()
			return
		if orbit_mode:
			# 观察键打开：单指拖动旋转视角，松手回正（第一/第三人称都如此）。
			f["role"] = "orbit"
		elif str(player.get("occupancy")) == "plane" and p.x >= vp().x * 0.55:
			# 飞机：屏幕右侧左右划屏控制偏航幅度。
			f["role"] = "yaw"
		else:
			f["role"] = "none"
		get_viewport().set_input_as_handled()
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
	elif _armed():
		# 观察模式持枪：单击人物开火，拖动不射击。不要开始腹部互动。
		f["role"] = "obs_fire"
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
	var role := str(f["role"])
	if role.begins_with("layout:"):
		_drag_layout(role.substr(7), p)
		get_viewport().set_input_as_handled()
		return
	if role == "yaw":
		# Horizontal swipe: left = yaw left (touch_yaw -1), right = +1.
		# Distance from the press start sets magnitude; vertical is ignored.
		var dx: float = p.x - float(f["start"].x)
		var mag := clampf(dx / 90.0, -1.0, 1.0)
		if hud and hud.has_method("_set_vs"):
			hud.call("_set_vs", "touch_yaw", mag)
		elif player and player.get_parent() and player.get_parent().get("vehicle_system"):
			player.get_parent().get("vehicle_system").set("touch_yaw", mag)
		get_viewport().set_input_as_handled()
		return
	if role == "orbit":
		# Two-finger (or later orbit role) already handled below.
		pass
	match role:
		"stick":
			_stick_to(p)
		"flight_stick":
			_flight_stick_to(p)
		"flight_yaw_slider":
			_flight_yaw_slider_to(p)
		"look":
			player.call("touch_look", rel)
		"zoom":
			_zoom_to(p)
		"tool":
			player.call("touch_tool_drag", p)
		"btn:weapon":
			# 相对按下点的位移拉选正中央的轮盘，而不是从按钮位置展开。
			if hud and p.distance_to(f["start"]) > TAP_PX * 0.6:
				f["moved"] = true
				if hud.has_method("weapon_wheel_drag"):
					hud.call("weapon_wheel_drag", p - f["start"])
				elif hud.has_method("weapon_wheel_point"):
					hud.call("weapon_wheel_point", p)
		"btn:fire", "btn:fire_left":
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
	if role == "look" or role == "orbit":
		if player and player.has_method("touch_look_end"):
			player.call("touch_look_end")
	if role == "yaw":
		if hud and hud.has_method("_set_vs"):
			hud.call("_set_vs", "touch_yaw", 0.0)
		elif player and player.get_parent() and player.get_parent().get("vehicle_system"):
			player.get_parent().get("vehicle_system").set("touch_yaw", 0.0)
	if role == "ui" or role.begins_with("btn:"):
		return
	# 短按且没怎么动 = 一次点按（用于双击环绕）。
	# 含 role=none：单击没打中身体时也要记下，否则双击永远无法开始环绕。
	if not _fp() and role == "obs_fire":
		var dt2 := Time.get_ticks_msec() - int(f["t0"])
		if dt2 < HOLD_MS and p.distance_to(f["start"]) < TAP_PX and player and player.has_method("observe_tap_fire"):
			player.call("observe_tap_fire", p)
		if dt2 < HOLD_MS and p.distance_to(f["start"]) < TAP_PX:
			_last_tap_t = Time.get_ticks_msec()
			_last_tap_pos = p
		else:
			_last_tap_t = -100000
	if not _fp() and (role == "tool" or role == "orbit" or role == "none"):
		var dt := Time.get_ticks_msec() - int(f["t0"])
		if dt < HOLD_MS and p.distance_to(f["start"]) < TAP_PX:
			_last_tap_t = Time.get_ticks_msec()
			_last_tap_pos = p
		elif role != "none":
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
	elif role == "flight_stick":
		flight_stick_vec = Vector2.ZERO
		_push_flight_stick()
	elif role == "flight_yaw_slider":
		flight_yaw_slider = 0.0
		_push_flight_yaw_slider()
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
	# 观察视角双指拖拽只平移。手术无工具、载具「观察」不捏合缩放，以免和地图捏合或载具环绕混淆。
	player.call("touch_pan", m - _two_mid)
	var observe_pan_only := _in_surgery() or _in_drive()
	if not observe_pan_only and absf(d - _two_dist) > 10.0 and _two_dist > 8.0 and d > 8.0:
		if player and player.has_method("touch_dolly"):
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


func _flight_stick_to(p: Vector2) -> void:
	var d := p - flight_stick_center()
	var cap := STICK_MAX * _layout_scale("flight_stick")
	if d.length() > cap:
		d = d.normalized() * cap
	# Store screen-space like the movement stick; push converts +y to up.
	flight_stick_vec = d / maxf(cap, 0.001)
	_push_flight_stick()
	queue_redraw()


func _push_flight_stick() -> void:
	var v := Vector2(clampf(flight_stick_vec.x, -1.0, 1.0), clampf(-flight_stick_vec.y, -1.0, 1.0))
	if v.length() < DEADZONE:
		v = Vector2.ZERO
	if hud and hud.has_method("_set_vs"):
		hud.call("_set_vs", "touch_flight_stick", v)
	elif player and player.get_parent() and player.get_parent().get("vehicle_system"):
		player.get_parent().get("vehicle_system").set("touch_flight_stick", v)


func _flight_yaw_slider_to(p: Vector2) -> void:
	var r := flight_yaw_slider_rect()
	var half := maxf(r.size.x * 0.5, 1.0)
	# Horizontal travel along the bar; vertical motion is ignored.
	var x := (p.x - r.get_center().x) / (half * 0.90)
	flight_yaw_slider = clampf(x, -1.0, 1.0)
	if absf(flight_yaw_slider) < 0.06:
		flight_yaw_slider = 0.0
	_push_flight_yaw_slider()
	queue_redraw()


func _push_flight_yaw_slider() -> void:
	# touch_yaw is -1 left / +1 right, same as the Q/E buttons.
	var y := clampf(flight_yaw_slider, -1.0, 1.0)
	if hud and hud.has_method("_set_vs"):
		hud.call("_set_vs", "touch_yaw", y)
	elif player and player.get_parent() and player.get_parent().get("vehicle_system"):
		player.get_parent().get("vehicle_system").set("touch_yaw", y)


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
		"vcam":
			if down and hud and hud.get("_vehicle_system") and hud.get("_vehicle_system").has_method("toggle_vehicle_cam"):
				hud.get("_vehicle_system").call("toggle_vehicle_cam")
				queue_redraw()
				if hud.has_method("_refresh_vehicle_touch"):
					hud.call("_refresh_vehicle_touch")
		"jump":
			if down:
				player.set("touch_jump_req", true)
		"interact":
			# 手机：只在按下时切换保持；松开不再退出。
			if down and player:
				player.call("touch_interact", true, true)
		"weapon":
			# 按下 = 打开轮盘；拖到格子上松手 = 选中；原地松手 = 关闭不变
			if hud == null:
				pass
			elif down:
				hud.call("open_weapon_wheel")
			elif bool(hud.call("is_wheel_open")):
				hud.call("close_weapon_wheel", _weapon_drag_moved)
				_weapon_drag_moved = false
		"fire", "fire_left":
			var w := _weapons()
			if w:
				# 任一开火键按住即开火；松开其中一个时，另一个仍按着则继续射击。
				w.call("set_trigger", _pressed_btn.has("fire") or _pressed_btn.has("fire_left"))
		"reload":
			var w2 := _weapons()
			if w2 and down:
				w2.call("reload")
		"ads":
			var w3 := _weapons()
			if w3 == null:
				pass
			elif player and ((player.has_method("ads_is_toggle") and bool(player.call("ads_is_toggle"))) or (not player.has_method("ads_is_toggle") and bool(player.get("ads_toggle")))):
				if down:
					w3.call("set_ads", not bool(w3.get("ads")))
			else:
				w3.call("set_ads", down)
		"drag":
			if down and player and player.has_method("toggle_corpse_drag"):
				player.call("toggle_corpse_drag")
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
	if (not _show_stick() and _has_role("stick")) or (not _show_flight_stick() and _has_role("flight_stick")) or (not _show_flight_yaw_slider() and _has_role("flight_yaw_slider")):
		_release_all_except_buttons()
	queue_redraw()


# ------------------------------------------------------------------ draw
func _drag_layout(id: String, p: Vector2) -> void:
	var u := _usable()
	var s := _layout_scale(id)
	p = Vector2(clampf(p.x, u.position.x, u.end.x), clampf(p.y, u.position.y, u.end.y))
	layout_working[id] = TouchLayout.pack_entry(p, s, u)
	queue_redraw()
	if hud and hud.has_method("_refresh_vehicle_touch"):
		hud.call("_refresh_vehicle_touch")


func _draw() -> void:
	if not enabled:
		return
	if _blocked() and not layout_edit:
		return
	# 与 HUD 按钮统一：圆角矩形、深底、选中偏蓝。摇杆仍是圆的。
	var fg := Color(0.95, 0.96, 0.98, 0.95)
	var surf := Color(0.14, 0.16, 0.2, 0.88)
	var line := Color(1, 1, 1, 0.28)
	var accent := Color(0.28, 0.48, 0.78, 0.95)
	var b := buttons()
	for id in b.keys():
		var r: Rect2 = b[id][0]
		var interact_on := false
		if id == "interact" and player and player.has_method("is_touch_interact_on"):
			interact_on = bool(player.call("is_touch_interact_on"))
		var on: bool = _pressed_btn.has(id) or interact_on or (id == "crouch" and player and str(player.call("get_stance")) != "stand") or (id == "drag" and _drag_holding())
		if id == "ads":
			var wads := _weapons()
			on = on or (wads != null and bool(wads.get("ads")))
		var selected: bool = layout_edit and layout_selected == id
		# The yaw slider is drawn as a long bar below, not a rounded button.
		if id == "flight_yaw_slider":
			continue
		var bg := Color(0.28, 0.48, 0.78, 0.95) if (on or selected) else surf
		var rad := 10.0 if id != "thrust" else 8.0
		draw_style_box(_box(bg, Color(0.95, 0.85, 0.35, 0.95) if selected else line, rad), r)
		_text_center(str(b[id][1]), r.get_center(), 14 if id != "mode" else 13, fg)
	if _show_stick():
		var c := stick_center()
		var rads := stick_radius()
		var sprint := stick_vec.length() >= STICK_SPRINT
		var selected_stick: bool = layout_edit and layout_selected == "stick"
		draw_circle(c, rads, Color(0.28, 0.48, 0.78, 0.28) if sprint or selected_stick else Color(0.14, 0.16, 0.2, 0.45))
		draw_arc(c, rads, 0.0, TAU, 48, Color(0.95, 0.85, 0.35, 0.95) if selected_stick else (accent if sprint else line), 2.0 if selected_stick else 1.5, true)
		draw_arc(c, rads * 0.46, 0.0, TAU, 32, Color(1, 1, 1, 0.25), 1.0, true)
		draw_circle(c + stick_vec * (STICK_MAX * _layout_scale("stick")), KNOB * 0.5 * _layout_scale("stick"), accent)
		if not layout_edit:
			_text_center("奔跑" if sprint else "外圈奔跑", c + Vector2(0, rads + 12.0), 11, Color(0.8, 0.82, 0.86, 0.8))
	if _show_flight_stick():
		var fc := flight_stick_center()
		var fr := flight_stick_radius()
		var fsel: bool = layout_edit and layout_selected == "flight_stick"
		draw_circle(fc, fr, Color(0.28, 0.48, 0.78, 0.28) if fsel else Color(0.14, 0.16, 0.2, 0.45))
		draw_arc(fc, fr, 0.0, TAU, 48, Color(0.95, 0.85, 0.35, 0.95) if fsel else line, 2.0 if fsel else 1.5, true)
		draw_arc(fc, fr * 0.46, 0.0, TAU, 32, Color(1, 1, 1, 0.25), 1.0, true)
		draw_circle(fc + flight_stick_vec * (STICK_MAX * _layout_scale("flight_stick")), KNOB * 0.5 * _layout_scale("flight_stick"), accent)
		if not layout_edit:
			_text_center("偏航 / 加减速", fc + Vector2(0, fr + 12.0), 11, Color(0.8, 0.82, 0.86, 0.8))
	if _show_flight_yaw_slider():
		var sr := flight_yaw_slider_rect()
		var ssel: bool = layout_edit and layout_selected == "flight_yaw_slider"
		draw_style_box(_box(Color(0.28, 0.48, 0.78, 0.28) if ssel else Color(0.14, 0.16, 0.2, 0.55), Color(0.95, 0.85, 0.35, 0.95) if ssel else line, 16.0), sr)
		# Center tick and end marks so it reads as a left/right bar, not a stick.
		var mid := sr.get_center()
		draw_line(Vector2(mid.x, sr.position.y + 6.0), Vector2(mid.x, sr.end.y - 6.0), Color(1, 1, 1, 0.35), 2.0, true)
		var travel := maxf(sr.size.x * 0.5 - 18.0, 8.0)
		var knob := mid + Vector2(flight_yaw_slider * travel, 0.0)
		draw_circle(knob, 16.0 * _layout_scale("flight_yaw_slider"), accent)
		_text_center("偏航", mid, 12, Color(0.8, 0.82, 0.86, 0.85))
	# 缩放竖条：只在摄像机面板打开时显示
	var zr := zoom_rect()
	if zr.size.y > 1.0:
		draw_style_box(_box(surf, line, 18.0), zr)
		var lo: float = player.get("fp_fov_min")
		var hi: float = player.get("fp_fov_max")
		var zt := clampf((hi - float(player.get("fp_fov"))) / maxf(1.0, hi - lo), 0.0, 1.0)
		var ty := zr.position.y + zr.size.y * (1.0 - zt)
		draw_circle(Vector2(zr.get_center().x, clampf(ty, zr.position.y + 10.0, zr.end.y - 10.0)), 10.0, fg)
		_text_center("%d°" % int(round(float(player.get("fp_fov")))), Vector2(zr.get_center().x, zr.end.y + 12.0), 11, Color(0.8, 0.82, 0.86, 0.8))
	# 准星改由 HUD Reticle 统一绘制（空手白点 / 髋射十字 / 开镜隐藏）。


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
