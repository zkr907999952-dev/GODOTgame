extends Node3D
## 大地图俯视（移植网页 CityMapRig / CityMapPanel）：
## 正上方俯视相机，左键/单指拖动平移、滚轮缩放（高度 36–1600m，默认 120m）、单击选传送点。
## 手机：双指捏合缩放（间距变大 = 降低高度/放大），双指中点平移。
## 选点优先射线命中碰撞体（城市已建碰撞时），否则取 y=0 平面。

signal marker_changed(marker: Variant)

const H_MIN := 36.0
const H_MAX := 1600.0
const H_DEFAULT := 120.0
const DRAG_PX := 7.0

var is_open: bool = false
var height: float = H_DEFAULT
var pan: Vector2 = Vector2.ZERO  # 世界 x,z
var marker: Variant = null  # Vector3 or null
var bounds: Rect2 = Rect2(-1769.0, -1471.0, 3000.0, 3000.0)
var player_pos: Vector3 = Vector3.ZERO

var _cam: Camera3D
var _prev_cam: Camera3D
var _marker_mi: MeshInstance3D
var _player_mi: MeshInstance3D
var _drag_on: bool = false
var _drag_moved: bool = false
var _drag_from: Vector2 = Vector2.ZERO
## 触屏：index -> 逻辑坐标
var _touches: Dictionary = {}
var _pinch_dist: float = 0.0
var _pinch_mid: Vector2 = Vector2.ZERO
## 刚收到 ScreenTouch 时忽略触摸模拟鼠标，避免同一指被当成「按下+单击选点」。
var _screen_touch_until: int = 0
## 最近一次有效指针（给测试 / 调试看走的是触摸还是 GUI）。
var last_ingest: String = ""
## index -> {t: msec, frame: int}，用来丢掉丢失了抬起事件的残指，避免一直卡在多点模式。
var _touch_meta: Dictionary = {}


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_cam = Camera3D.new()
	_cam.name = "MapCamera"
	_cam.fov = 50.0
	_cam.near = 1.0
	_cam.far = 2400.0
	add_child(_cam)
	_marker_mi = _make_pin(Color(0.95, 0.25, 0.2), 0)
	_player_mi = _make_pin(Color(0.25, 0.6, 1.0), 1)
	_marker_mi.visible = false
	_player_mi.visible = false


func _make_pin(c: Color, kind: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m: PrimitiveMesh
	if kind == 0:
		var cy := CylinderMesh.new()
		cy.top_radius = 0.5
		cy.bottom_radius = 0.5
		cy.height = 0.2
		m = cy
	else:
		var cn := CylinderMesh.new()
		cn.top_radius = 0.0
		cn.bottom_radius = 0.6
		cn.height = 0.2
		m = cn
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 10
	m.material = mat
	mi.mesh = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func open(center: Vector3, current_player: Vector3) -> void:
	if is_open:
		return
	is_open = true
	pan = Vector2(center.x, center.z)
	player_pos = current_player
	if height < 50.0 or height > 400.0:
		height = H_DEFAULT
	_prev_cam = get_viewport().get_camera_3d()
	_cam.current = true
	_drag_on = false
	_touches.clear()
	_touch_meta.clear()
	_pinch_dist = 0.0
	set_process_input(true)
	_update_cam()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_drag_on = false
	_touches.clear()
	_touch_meta.clear()
	_pinch_dist = 0.0
	set_process_input(false)
	_marker_mi.visible = false
	_player_mi.visible = false
	if _prev_cam and is_instance_valid(_prev_cam):
		_prev_cam.current = true
	_cam.current = false


func set_marker(m: Variant) -> void:
	marker = m
	marker_changed.emit(marker)
	_update_cam()


func zoom_steps(steps: float) -> void:
	# 网页：h *= exp(deltaY * 0.0016)，一格滚轮 deltaY≈100
	height = clampf(height * exp(-steps * 0.16), H_MIN, H_MAX)
	_update_cam()


func zoom_by(factor: float) -> void:
	# factor < 1 = 放大（相机降低）；与观察模式捏合约定相同：旧间距 / 新间距。
	if factor <= 1e-5:
		return
	height = clampf(height * factor, H_MIN, H_MAX)
	_update_cam()


func _vis_half() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var half_h := tan(deg_to_rad(_cam.fov) * 0.5) * height
	return Vector2(half_h * vp.x / maxf(1.0, vp.y), half_h)


## 把真机可能传来的物理像素换到逻辑像素（和 touch_controls 同一套判断）。
func to_logical(p: Vector2) -> Vector2:
	var vis := get_viewport().get_visible_rect()
	var vp := get_viewport()
	if vp == null:
		return p
	var backing := Vector2(vp.size)
	if backing.x <= vis.size.x * 1.08 or vis.size.x <= 1.0:
		return p
	if p.x > vis.size.x + 24.0 or p.y > vis.size.y + 24.0:
		return Vector2(p.x * vis.size.x / backing.x, p.y * vis.size.y / backing.y)
	return p


func to_logical_rel(rel: Vector2, pos: Vector2) -> Vector2:
	var vis := get_viewport().get_visible_rect()
	var vp := get_viewport()
	if vp == null:
		return rel
	var backing := Vector2(vp.size)
	if backing.x <= vis.size.x * 1.08 or vis.size.x <= 1.0:
		return rel
	if pos.x > vis.size.x + 24.0 or pos.y > vis.size.y + 24.0:
		return Vector2(rel.x * vis.size.x / backing.x, rel.y * vis.size.y / backing.y)
	return rel


## 在 GUI 之前先收到事件。抬起即使落在顶栏/底栏按钮上也不会丢，避免残指卡住多点模式。
func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed:
		var st := event as InputEventScreenTouch
		var pos := to_logical(st.position)
		if _touches.has(st.index):
			_touch_up(st.index, pos)
			# 不 set handled，让顶栏按钮仍能收到这次抬起。


func purge_stale_touches(max_frames: int = 25, max_ms: int = 280) -> int:
	var now := Time.get_ticks_msec()
	var fr := Engine.get_process_frames()
	var dropped := 0
	for idx in _touches.keys():
		var meta: Dictionary = _touch_meta.get(idx, {})
		var age_f := fr - int(meta.get("frame", fr))
		var age_t := now - int(meta.get("t", now))
		if age_f > max_frames or age_t > max_ms:
			_touches.erase(idx)
			_touch_meta.erase(idx)
			dropped += 1
	if _touches.size() < 2:
		_pinch_dist = 0.0
		if _touches.is_empty():
			# 残指清干净后，单指可以重新开始拖/点选。
			pass
	return dropped


func touch_count() -> int:
	return _touches.size()


## GUI 捕捉层（HUD MapInputCatcher）把控件局部坐标转成视口坐标后再交给这里。
## 这是手机上可靠的路径：全屏 STOP 控件走 _gui_input，不再依赖 _unhandled_input。
func handle_gui_event(event: InputEvent, canvas_xform: Transform2D = Transform2D.IDENTITY) -> bool:
	if not is_open:
		return false
	var ev := event
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag:
		ev = event.duplicate()
		if ev is InputEventMouse:
			var m := ev as InputEventMouse
			var gp: Vector2 = canvas_xform * m.position if canvas_xform != Transform2D.IDENTITY else m.position
			m.position = to_logical(gp)
			if ev is InputEventMouseMotion:
				(ev as InputEventMouseMotion).relative = to_logical_rel((event as InputEventMouseMotion).relative, (event as InputEventMouse).position)
		elif ev is InputEventScreenTouch:
			var st := ev as InputEventScreenTouch
			var gp2: Vector2 = canvas_xform * st.position if canvas_xform != Transform2D.IDENTITY else st.position
			st.position = to_logical(gp2)
		elif ev is InputEventScreenDrag:
			var sd := ev as InputEventScreenDrag
			var raw := sd.position
			var gp3: Vector2 = canvas_xform * raw if canvas_xform != Transform2D.IDENTITY else raw
			sd.position = to_logical(gp3)
			sd.relative = to_logical_rel(sd.relative, raw)
	last_ingest = "gui"
	return handle_input(ev)


## 返回 true 表示事件已处理（打开时吞掉所有 3D 视图鼠标事件）
func handle_input(event: InputEvent) -> bool:
	if not is_open:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				zoom_steps(1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# 真机：ScreenTouch 之后常紧跟一条模拟鼠标，不能再开一轮拖/选点。
			if mb.device == InputEvent.DEVICE_ID_EMULATION and Time.get_ticks_msec() < _screen_touch_until:
				return true
			var pos := to_logical(mb.position)
			if mb.pressed:
				_drag_on = true
				_drag_moved = false
				_drag_from = pos
			elif _drag_on:
				_drag_on = false
				if not _drag_moved:
					pick_at(pos)
			return true
		return true
	if event is InputEventMouseMotion and _drag_on:
		if event.device == InputEvent.DEVICE_ID_EMULATION and Time.get_ticks_msec() < _screen_touch_until:
			return true
		var mm := event as InputEventMouseMotion
		var pos := to_logical(mm.position)
		var rel := to_logical_rel(mm.relative, mm.position)
		if not _drag_moved and pos.distance_to(_drag_from) > DRAG_PX:
			_drag_moved = true
		if _drag_moved:
			_pan_by_pixels(rel)
		return true
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		_screen_touch_until = Time.get_ticks_msec() + 160
		var pos := to_logical(st.position)
		if st.pressed:
			purge_stale_touches()
			_touch_down(st.index, pos)
		else:
			_touch_up(st.index, pos)
		return true
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_screen_touch_until = Time.get_ticks_msec() + 160
		var pos := to_logical(sd.position)
		var rel := to_logical_rel(sd.relative, sd.position)
		_touch_move(sd.index, pos, rel)
		return true
	return event is InputEventMouse


func _touch_pts() -> Array:
	var ks: Array = _touches.keys()
	ks.sort()
	var pts: Array = []
	for k in ks:
		pts.append(_touches[k])
	return pts


func _stamp_touch(idx: int, p: Vector2) -> void:
	_touches[idx] = p
	_touch_meta[idx] = {"t": Time.get_ticks_msec(), "frame": Engine.get_process_frames()}


func _touch_down(idx: int, p: Vector2) -> void:
	# 新的按下时再清一次过期残指，避免「多点结束后一直停在双指模式」。
	purge_stale_touches()
	_stamp_touch(idx, p)
	var pts := _touch_pts()
	if pts.size() >= 2:
		_drag_on = false
		_drag_moved = false
		_pinch_mid = (pts[0] + pts[1]) * 0.5
		_pinch_dist = pts[0].distance_to(pts[1])
	else:
		_drag_on = true
		_drag_moved = false
		_drag_from = p
		_pinch_dist = 0.0


func _touch_move(idx: int, p: Vector2, rel: Vector2) -> void:
	_stamp_touch(idx, p)
	var pts := _touch_pts()
	if pts.size() >= 2:
		var mid: Vector2 = (pts[0] + pts[1]) * 0.5
		var dist: float = pts[0].distance_to(pts[1])
		# 双指中点平移
		if _pinch_dist > 0.0:
			var dmid: Vector2 = mid - _pinch_mid
			if dmid.length_squared() > 0.0:
				_pan_by_pixels(dmid)
		# 捏合缩放：间距变大 = 放大 = 降低高度
		if _pinch_dist > 8.0 and dist > 8.0 and absf(dist - _pinch_dist) > 10.0:
			zoom_by(_pinch_dist / dist)
			_pinch_dist = dist
		elif _pinch_dist <= 8.0:
			_pinch_dist = dist
		_pinch_mid = mid
		_drag_on = false
		return
	if _drag_on:
		if not _drag_moved and p.distance_to(_drag_from) > DRAG_PX:
			_drag_moved = true
		if _drag_moved:
			_pan_by_pixels(rel)


func _touch_up(idx: int, p: Vector2) -> void:
	if not _touches.has(idx):
		# 可能已由 _input 处理过同一次抬起，避免重复点选。
		return
	var was_pinch := _touches.size() >= 2
	_touches.erase(idx)
	_touch_meta.erase(idx)
	var pts := _touch_pts()
	if pts.size() >= 2:
		_pinch_mid = (pts[0] + pts[1]) * 0.5
		_pinch_dist = pts[0].distance_to(pts[1])
		return
	_pinch_dist = 0.0
	if pts.size() == 1:
		# 剩下单指：立刻恢复单指平移；不误判为单击选点
		_drag_on = true
		_drag_moved = true
		_drag_from = pts[0]
		return
	if _drag_on:
		_drag_on = false
		if not _drag_moved and not was_pinch:
			pick_at(p)


func _pan_by_pixels(rel: Vector2) -> void:
	var vp := get_viewport().get_visible_rect().size
	var hv := _vis_half()
	pan.x -= rel.x / maxf(1.0, vp.x) * hv.x * 2.0
	pan.y -= rel.y / maxf(1.0, vp.y) * hv.y * 2.0
	pan.x = clampf(pan.x, bounds.position.x, bounds.end.x)
	pan.y = clampf(pan.y, bounds.position.y, bounds.end.y)
	_update_cam()


func pick_at(screen: Vector2) -> void:
	var o := _cam.project_ray_origin(screen)
	var d := _cam.project_ray_normal(screen)
	var q := PhysicsRayQueryParameters3D.create(o, o + d * (height + 900.0), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		set_marker(hit["position"])
		return
	if absf(d.y) < 1e-5:
		return
	var t := -o.y / d.y
	if t > 0.0:
		set_marker(o + d * t)


func _update_cam() -> void:
	if not is_open:
		return
	_cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(pan.x, height, pan.y))
	_cam.far = height + 800.0
	var s := maxf(1.0, height * 0.022)
	_player_mi.visible = true
	_player_mi.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(s, 1.0, s)), player_pos + Vector3(0, 1.5, 0))
	_marker_mi.visible = marker != null
	if marker != null:
		_marker_mi.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(s, 1.0, s)), (marker as Vector3) + Vector3(0, 1.0, 0))
