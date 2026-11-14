extends Node3D
## 大地图俯视（移植网页 CityMapRig / CityMapPanel）：
## 正上方俯视相机，左键拖动平移、滚轮缩放（高度 36–1600m，默认 120m）、左键单击选传送点。
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
	_update_cam()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_drag_on = false
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


func _vis_half() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var half_h := tan(deg_to_rad(_cam.fov) * 0.5) * height
	return Vector2(half_h * vp.x / maxf(1.0, vp.y), half_h)


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
			if mb.pressed:
				_drag_on = true
				_drag_moved = false
				_drag_from = mb.position
			elif _drag_on:
				_drag_on = false
				if not _drag_moved:
					pick_at(mb.position)
			return true
		return true
	if event is InputEventMouseMotion and _drag_on:
		var mm := event as InputEventMouseMotion
		if not _drag_moved and mm.position.distance_to(_drag_from) > DRAG_PX:
			_drag_moved = true
		if _drag_moved:
			var vp := get_viewport().get_visible_rect().size
			var hv := _vis_half()
			pan.x -= mm.relative.x / maxf(1.0, vp.x) * hv.x * 2.0
			pan.y -= mm.relative.y / maxf(1.0, vp.y) * hv.y * 2.0
			pan.x = clampf(pan.x, bounds.position.x, bounds.end.x)
			pan.y = clampf(pan.y, bounds.position.y, bounds.end.y)
			_update_cam()
		return true
	return event is InputEventMouse


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
