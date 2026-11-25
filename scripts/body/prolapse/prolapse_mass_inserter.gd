extends "res://scripts/body/vulva/vulva_inserter.gd"
## 脱出物（外翻阴道包着的宫颈 / 子宫）从里往外穿过外口：VulvaInserter 实现。
## 外口平面上是圆截面；project_out 按一段胶囊（沿脱出物在外口处的走向）把外阴顶点推出去。
## 注意：没有 configure() 方法，外阴走通用接口路径（不走椭圆热路径）。
class_name ProlapseMassInserter

var _mix := 0.0
var _radius := 0.0
var _dir := Vector3(0, -1, 0)    # 外口处脱出物朝外的方向（与网格同一空间）
var _axis := Vector3(0, 1, 0)    # 阴道轴（朝里）
var _up := Vector3(0, 0, 1)
var _offset := Vector3.ZERO      # 截面中心相对外口中心的偏移
var reach_in := 0.008
var reach_out := 0.035


func setup_mass(radius: float, axis_in: Vector3, up: Vector3, out_dir: Vector3, offset: Vector3, mixv: float) -> void:
	_radius = maxf(radius, 0.0)
	_mix = clampf(mixv, 0.0, 1.0)
	if axis_in.length_squared() > 1e-8:
		_axis = axis_in.normalized()
	var u := up - _axis * up.dot(_axis)
	if u.length_squared() > 1e-8:
		_up = u.normalized()
	if out_dir.length_squared() > 1e-8:
		_dir = out_dir.normalized()
	else:
		_dir = -_axis
	_offset = offset


func mix() -> float:
	return _mix if _radius > 1e-4 else 0.0


func radius() -> float:
	return _radius


func envelope() -> Dictionary:
	return {"half_x": _radius, "half_y": _radius, "blade_sep": 0.0, "axis": _axis, "up": _up}


func _closest_on_axis(p: Vector3, c: Vector3) -> Vector3:
	# 胶囊：从外口里面 reach_in（沿阴道轴）到外面 reach_out（沿脱出方向）的折线，取最近点。
	var a := c + _axis * reach_in
	var b := c
	var e := c + _dir * reach_out
	var q1 := _seg_closest(p, a, b)
	var q2 := _seg_closest(p, b, e)
	return q1 if p.distance_squared_to(q1) < p.distance_squared_to(q2) else q2


func _seg_closest(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-12:
		return a
	return a + ab * clampf((p - a).dot(ab) / l2, 0.0, 1.0)


func project_out(p: Vector3, origin: Vector3, _axis_in: Vector3, _upv: Vector3) -> Vector3:
	if mix() <= 1e-4:
		return p
	var c := origin + _offset
	var q := _closest_on_axis(p, c)
	var d := p - q
	var L := d.length()
	var R := _radius * 1.012
	if L >= R:
		return p
	if L < 1e-7:
		var side := _axis.cross(_up)
		return q + (side if side.length_squared() > 1e-8 else Vector3.RIGHT).normalized() * R
	return q + d * (R / L)


func penetration(p: Vector3, origin: Vector3, _axis_in: Vector3, _upv: Vector3) -> float:
	if mix() <= 1e-4:
		return 0.0
	var c := origin + _offset
	var q := _closest_on_axis(p, c)
	return maxf(_radius - p.distance_to(q), 0.0)


func cross_section(_origin: Vector3, _axis_in: Vector3, _upv: Vector3) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if mix() <= 1e-4:
		return pts
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(Vector2(cos(a), sin(a)) * _radius)
	return pts
