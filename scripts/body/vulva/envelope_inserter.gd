extends "res://scripts/body/vulva/vulva_inserter.gd"
## 两叶 / 椭圆 / 胶囊都可表示的通用截面插入物。
## 扩张器：两个上下椭圆（blade_sep>0）；手指 / 棒状：blade_sep=0 的单椭圆或圆。

var _mix := 0.0
var _hx := 0.0
var _hy := 0.0
var _sep := 0.0
var _axis := Vector3(0, 1, 0)
var _up := Vector3(0, 0, 1)
var _along := 0.028


func configure(half_x: float, half_y: float, mixv: float, axis: Vector3, up: Vector3, blade_sep: float = 0.0, along_range: float = 0.028) -> void:
	_hx = maxf(half_x, 0.0)
	_hy = maxf(half_y, 0.0)
	_mix = clampf(mixv, 0.0, 1.0)
	_sep = maxf(blade_sep, 0.0)
	_along = maxf(along_range, 0.008)
	if axis.length_squared() > 1e-8:
		_axis = axis.normalized()
	var u := up
	if u.length_squared() > 1e-8:
		u = (u - _axis * u.dot(_axis))
		if u.length_squared() > 1e-8:
			_up = u.normalized()


func mix() -> float:
	return _mix


func envelope() -> Dictionary:
	return {"half_x": _hx, "half_y": _hy, "blade_sep": _sep, "axis": _axis, "up": _up}


func _basis_side() -> Vector3:
	var s := _axis.cross(_up)
	return s.normalized() if s.length_squared() > 1e-8 else Vector3(1, 0, 0)


func _ell_k(x: float, y: float, hx: float, hh: float) -> float:
	return (x * x) / maxf(hx * hx, 1e-8) + (y * y) / maxf(hh * hh, 1e-8)


func _hull(x: float, y: float) -> Vector2:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cy := _sep
	if cy < 1e-5:
		var e := (x * x) / (hx * hx) + (y * y) / (hy * hy)
		if e <= 1e-8:
			return Vector2(0.0, hy)
		var k := 1.0 / sqrt(e)
		return Vector2(x * k, y * k)
	var hh := maxf(hy - cy, 0.002)
	var L := sqrt(x * x + y * y)
	if L < 1e-8:
		return Vector2(0.0, hy)
	var dx := x / L
	var dy := y / L
	if absf(dx) > 1e-6:
		var t_side := hx / absf(dx)
		if absf(t_side * dy) <= cy + 1e-6:
			return Vector2(dx * t_side, dy * t_side)
	var sy := 1.0 if dy >= 0.0 else -1.0
	var A := (dx * dx) / (hx * hx) + (dy * dy) / (hh * hh)
	var B := -2.0 * dy * sy * cy / (hh * hh)
	var C := (cy * cy) / (hh * hh) - 1.0
	var disc := B * B - 4.0 * A * C
	if disc < 0.0 or A < 1e-12:
		return Vector2(dx * hx, dy * hy)
	var t := (-B + sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		t = (-B - sqrt(disc)) / (2.0 * A)
	return Vector2(dx * maxf(t, 0.0), dy * maxf(t, 0.0))


func _out_metal(x: float, y: float) -> Vector2:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cy := _sep
	var hh := maxf(hy - cy, 0.002)
	var margin := 1.016
	if cy < 1e-5:
		var e := _ell_k(x, y, hx, hy)
		if e < 1e-8:
			return Vector2(0.0, hy * margin)
		var s := margin / sqrt(e)
		return Vector2(x * s, y * s)
	var ku := _ell_k(x, y - cy, hx, hh)
	var kl := _ell_k(x, y + cy, hx, hh)
	if ku <= kl:
		if ku < 1e-8:
			return Vector2(0.0, cy + hh * margin)
		var s2 := margin / sqrt(ku)
		return Vector2(x * s2, cy + (y - cy) * s2)
	if kl < 1e-8:
		return Vector2(0.0, -(cy + hh * margin))
	var s3 := margin / sqrt(kl)
	return Vector2(x * s3, -cy + (y + cy) * s3)


func _inside_metal(x: float, y: float) -> bool:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cy := _sep
	var hh := maxf(hy - cy, 0.002)
	if cy < 1e-5:
		return _ell_k(x, y, hx, hy) < 1.0
	return _ell_k(x, y - cy, hx, hh) < 1.0 or _ell_k(x, y + cy, hx, hh) < 1.0


func project_out(p: Vector3, origin: Vector3, axis: Vector3, up: Vector3) -> Vector3:
	if _mix < 1e-4 or _hx < 1e-5 or _hy < 1e-5:
		return p
	var ax := axis if axis.length_squared() > 1e-8 else _axis
	var u := up if up.length_squared() > 1e-8 else _up
	ax = ax.normalized()
	u = (u - ax * u.dot(ax))
	if u.length_squared() < 1e-8:
		return p
	u = u.normalized()
	var side := ax.cross(u)
	if side.length_squared() < 1e-8:
		return p
	side = side.normalized()
	var r := p - origin
	var along := r.dot(ax)
	if absf(along) > _along:
		return p
	var x := r.dot(side)
	var y := r.dot(u)
	if _inside_metal(x, y):
		var o := _out_metal(x, y)
		return origin + side * o.x + u * o.y + ax * along
	return p


func penetration(p: Vector3, origin: Vector3, axis: Vector3, up: Vector3) -> float:
	if _mix < 1e-4 or _hx < 1e-5:
		return 0.0
	var ax := axis if axis.length_squared() > 1e-8 else _axis
	var u := up if up.length_squared() > 1e-8 else _up
	ax = ax.normalized()
	u = (u - ax * u.dot(ax))
	if u.length_squared() < 1e-8:
		return 0.0
	u = u.normalized()
	var side := ax.cross(u)
	if side.length_squared() < 1e-8:
		return 0.0
	side = side.normalized()
	var r := p - origin
	if absf(r.dot(ax)) > _along:
		return 0.0
	var x := r.dot(side)
	var y := r.dot(u)
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cy := _sep
	var hh := maxf(hy - cy, 0.002)
	var k := 2.0
	if cy < 1e-5:
		k = _ell_k(x, y, hx, hy)
		if k < 1.0:
			return (1.0 - sqrt(maxf(k, 0.0))) * minf(hx, hy)
	else:
		k = minf(_ell_k(x, y - cy, hx, hh), _ell_k(x, y + cy, hx, hh))
		if k < 1.0:
			return (1.0 - sqrt(maxf(k, 0.0))) * minf(hx, hh)
	return 0.0
