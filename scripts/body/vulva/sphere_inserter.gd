extends "res://scripts/body/vulva/vulva_inserter.gd"
## 球体（可带圆柱长杆）插入物。外口用球在该平面上的圆截面撑开；
## 球穿过后外口收在杆径上。project_out 按真实球体 + 杆的胶囊推出顶点。
class_name SphereInserter

var _mix := 0.0
var _radius := 0.01
var _shaft := 0.004
var _along := 0.0
var _lateral := Vector3.ZERO
var _axis := Vector3(0, 1, 0)
var _up := Vector3(0, 0, 1)
const RECOIL_TAU := 0.9
var _shown_r := 0.0
var _shown_lat := Vector3.ZERO


func configure(along: float, radius: float, shaft_r: float, axis: Vector3, up: Vector3, mixv: float, lateral: Vector3 = Vector3.ZERO) -> void:
	_along = along
	_radius = maxf(radius, 0.001)
	_shaft = maxf(shaft_r, 0.0)
	_mix = clampf(mixv, 0.0, 1.0)
	_lateral = lateral - axis * lateral.dot(axis) if axis.length_squared() > 1e-8 else lateral
	if axis.length_squared() > 1e-8:
		_axis = axis.normalized()
	var u := up
	if u.length_squared() > 1e-8:
		u = u - _axis * u.dot(_axis)
		if u.length_squared() > 1e-8:
			_up = u.normalized()
	# 扩张立刻跟上当前截面，回缩留给 tick。
	var inst := instant_slice_radius()
	if inst >= _shown_r:
		_shown_r = inst
		_shown_lat = _lateral


func mix() -> float:
	return _mix


func radius() -> float:
	return _radius


func shaft_radius() -> float:
	return _shaft


func along() -> float:
	return _along


## 外口平面上球/杆的瞬时截面半径：球与该平面相交的切片，或球已通过后的杆径。
func instant_slice_radius() -> float:
	if _mix <= 1e-4:
		return 0.0
	if absf(_along) <= _radius:
		return sqrt(maxf(_radius * _radius - _along * _along, 0.0))
	if _along > _radius:
		return _shaft
	return 0.0


## 显示半径（瞬时扩张，回缩按 ~0.9 s 延迟）。
func slice_radius() -> float:
	return _shown_r


func lateral() -> Vector3:
	return _shown_lat


func tick(dt: float) -> void:
	var inst := instant_slice_radius()
	if inst >= _shown_r - 1e-7:
		_shown_r = inst
	else:
		var k := 1.0 - exp(-maxf(dt, 0.0) / RECOIL_TAU)
		_shown_r = lerpf(_shown_r, inst, k)
	var follow := inst > 1e-5 or _mix > 0.02
	if follow:
		_shown_lat = _lateral
	else:
		var k2 := 1.0 - exp(-maxf(dt, 0.0) / RECOIL_TAU)
		_shown_lat = _shown_lat.lerp(Vector3.ZERO, k2)
	if _shown_r < 1e-5:
		_shown_r = 0.0
		_shown_lat = Vector3.ZERO


func is_active() -> bool:
	return _mix > 1e-4 or _shown_r > 1e-5


func envelope() -> Dictionary:
	var r := slice_radius()
	return {"half_x": r, "half_y": r, "blade_sep": 0.0, "axis": _axis, "up": _up, "offset": _shown_lat}


func _center(origin: Vector3, axis: Vector3) -> Vector3:
	var ax := axis if axis.length_squared() > 1e-8 else _axis
	if ax.length_squared() > 1e-8:
		ax = ax.normalized()
	return origin + ax * _along + _shown_lat


func project_out(p: Vector3, origin: Vector3, axis: Vector3, _up: Vector3) -> Vector3:
	if not is_active():
		return p
	var ax := axis if axis.length_squared() > 1e-8 else _axis
	if ax.length_squared() < 1e-8:
		return p
	ax = ax.normalized()
	var c := _center(origin, ax)
	var out := p
	# 球体。
	var d := out - c
	var L := d.length()
	if L < _radius and L > 1e-8:
		out = c + d * (_radius / L)
	elif L <= 1e-8:
		out = c + ax * _radius
	# 杆：从球心沿 -axis（体外）延伸的无限半胶囊，半径 _shaft。
	if _shaft > 1e-5:
		var q := out - c
		var t := minf(q.dot(-ax), 0.2)
		if t > 0.0:
			var axis_p := c + (-ax) * t
			var rd := out - axis_p
			var rl := rd.length()
			if rl < _shaft and rl > 1e-8:
				out = axis_p + rd * (_shaft / rl)
	return out


func penetration(p: Vector3, origin: Vector3, axis: Vector3, _up: Vector3) -> float:
	if not is_active():
		return 0.0
	var ax := axis if axis.length_squared() > 1e-8 else _axis
	if ax.length_squared() < 1e-8:
		return 0.0
	ax = ax.normalized()
	var c := _center(origin, ax)
	var d := p - c
	var pen := _radius - d.length()
	if _shaft > 1e-5:
		var t := minf(d.dot(-ax), 0.2)
		if t > 0.0:
			var axis_p := c + (-ax) * t
			pen = maxf(pen, _shaft - (p - axis_p).length())
	return maxf(pen, 0.0)


func cross_section(_origin: Vector3, _axis: Vector3, _upv: Vector3) -> PackedVector2Array:
	var r := slice_radius()
	if r <= 1e-5:
		return PackedVector2Array()
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * float(i) / 12.0
		pts.append(Vector2(cos(a) * r, sin(a) * r))
	return pts
