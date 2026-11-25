extends "res://scripts/body/vulva/vulva_inserter.gd"
## 截面插入物：blade_sep=0 为单椭圆 / 胶囊；blade_sep>0 时上下两瓣共享同一
## 圆角矩形（stadium）扩张体积——两瓣外壳加上它们之间的空隙，组织贴合此外表面。

var _mix := 0.0
var _hx := 0.0
var _hy := 0.0
var _sep := 0.0
var _axis := Vector3(0, 1, 0)
var _up := Vector3(0, 0, 1)
var _along := 0.028
# 体外一侧（沿轴负向）的影响范围：外口不要被推出体表太远。
var _along_out := 0.008


func configure(half_x: float, half_y: float, mixv: float, axis: Vector3, up: Vector3, blade_sep: float = 0.0, along_range: float = 0.028) -> void:
	_hx = maxf(half_x, 0.0)
	_hy = maxf(half_y, 0.0)
	_mix = clampf(mixv, 0.0, 1.0)
	_sep = maxf(blade_sep, 0.0)
	_along = maxf(along_range, 0.008)
	_along_out = minf(_along, 0.008)
	if axis.length_squared() > 1e-8:
		_axis = axis.normalized()
	var u := up
	if u.length_squared() > 1e-8:
		u = (u - _axis * u.dot(_axis))
		if u.length_squared() > 1e-8:
			_up = u.normalized()


func uses_envelope_configure() -> bool:
	return true


func mix() -> float:
	return _mix


func envelope() -> Dictionary:
	return {
		"half_x": _hx,
		"half_y": _hy,
		"blade_sep": _sep,
		"axis": _axis,
		"up": _up,
		"corner": _corner(),
		"along": _along,
		"along_out": _along_out,
	}


func _corner() -> float:
	# blade_sep>0 时表示圆角矩形的「平直半高」= hy - corner。
	if _sep < 1e-5:
		return 0.0
	return clampf(_hy - _sep, 0.001, minf(_hx, _hy) * 0.95)


func _basis_side() -> Vector3:
	var s := _axis.cross(_up)
	return s.normalized() if s.length_squared() > 1e-8 else Vector3(1, 0, 0)


func _ell_k(x: float, y: float, hx: float, hh: float) -> float:
	return (x * x) / maxf(hx * hx, 1e-8) + (y * y) / maxf(hh * hh, 1e-8)


## 圆角矩形 SDF（与 organ_common.speculum_offset 同一公式）。负值在体内。
static func stadium_sdf(x: float, y: float, hx: float, hy: float, cr: float) -> float:
	var cx := maxf(cr, 0.0005)
	var he := Vector2(maxf(hx, cx + 0.0004), maxf(hy, cx + 0.0004))
	var q := Vector2(absf(x) - (he.x - cx), absf(y) - (he.y - cx))
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - cx


static func stadium_grad(x: float, y: float, hx: float, hy: float, cr: float) -> Vector2:
	var cx := maxf(cr, 0.0005)
	var he := Vector2(maxf(hx, cx + 0.0004), maxf(hy, cx + 0.0004))
	var qx := absf(x) - (he.x - cx)
	var qy := absf(y) - (he.y - cx)
	var sx := 1.0 if x >= 0.0 else -1.0
	var sy := 1.0 if y >= 0.0 else -1.0
	if qx > 0.0 and qy > 0.0:
		var L := Vector2(qx, qy).length()
		if L < 1e-12:
			return Vector2(0.0, sy)
		return Vector2(sx * qx / L, sy * qy / L)
	if qx > qy:
		return Vector2(sx, 0.0)
	return Vector2(0.0, sy)


static func stadium_project(x: float, y: float, hx: float, hy: float, cr: float, margin: float = 1.016) -> Vector2:
	# 从原点沿射线打到圆角矩形外壳。近轴点必须能被推到上下瓣，不能用「最近面」（那会把组织推向左右侧壁，外口高度塌掉）。
	var hx2 := hx * margin
	var hy2 := hy * margin
	var cr2 := maxf(cr * margin, 0.0005)
	cr2 = minf(cr2, minf(hx2, hy2) - 0.0004)
	if absf(x) < 1e-8 and absf(y) < 1e-8:
		return Vector2(0.0, hy2)
	var L := Vector2(x, y).length()
	var dx := x / L
	var dy := y / L
	var flat_x := hx2 - cr2
	var flat_y := hy2 - cr2
	if absf(dx) > 1e-8:
		var t_side := hx2 / absf(dx)
		if absf(t_side * dy) <= flat_y + 1e-6:
			return Vector2(dx * t_side, dy * t_side)
	if absf(dy) > 1e-8:
		var t_tb := hy2 / absf(dy)
		if absf(t_tb * dx) <= flat_x + 1e-6:
			return Vector2(dx * t_tb, dy * t_tb)
	var sx := 1.0 if dx >= 0.0 else -1.0
	var sy := 1.0 if dy >= 0.0 else -1.0
	var cx := sx * flat_x
	var cy := sy * flat_y
	# |t d - c|^2 = cr^2
	var b := -2.0 * (dx * cx + dy * cy)
	var c0 := cx * cx + cy * cy - cr2 * cr2
	var disc := b * b - 4.0 * c0
	if disc < 0.0:
		return Vector2(dx * hx2, dy * hy2)
	var t := (-b + sqrt(disc)) * 0.5
	if t < 0.0:
		t = (-b - sqrt(disc)) * 0.5
	t = maxf(t, 0.0)
	return Vector2(dx * t, dy * t)


func _hull(x: float, y: float) -> Vector2:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cr := _corner()
	if cr < 1e-5:
		var e := (x * x) / (hx * hx) + (y * y) / (hy * hy)
		if e <= 1e-8:
			return Vector2(0.0, hy)
		var k := 1.0 / sqrt(e)
		return Vector2(x * k, y * k)
	return stadium_project(x, y, hx, hy, cr, 1.0)


func _out_metal(x: float, y: float) -> Vector2:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cr := _corner()
	if cr < 1e-5:
		var e := _ell_k(x, y, hx, hy)
		if e < 1e-8:
			return Vector2(0.0, hy * 1.016)
		var s := 1.016 / sqrt(e)
		return Vector2(x * s, y * s)
	return stadium_project(x, y, hx, hy, cr, 1.016)


func _inside_metal(x: float, y: float) -> bool:
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cr := _corner()
	if cr < 1e-5:
		return _ell_k(x, y, hx, hy) < 1.0
	return stadium_sdf(x, y, hx, hy, cr) < 0.0


func is_inside_xy(x: float, y: float) -> bool:
	return _inside_metal(x, y)


func project_xy(x: float, y: float) -> Vector2:
	return _out_metal(x, y)


func hull_xy(x: float, y: float) -> Vector2:
	return _hull(x, y)


func along_limits() -> Vector2:
	return Vector2(_along, _along_out)


func _along_ok(along: float) -> bool:
	return along <= _along and along >= -_along_out


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
	if not _along_ok(along):
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
	if not _along_ok(r.dot(ax)):
		return 0.0
	var x := r.dot(side)
	var y := r.dot(u)
	var hx := maxf(_hx, 1e-5)
	var hy := maxf(_hy, 1e-5)
	var cr := _corner()
	if cr < 1e-5:
		var k := _ell_k(x, y, hx, hy)
		if k < 1.0:
			return (1.0 - sqrt(maxf(k, 0.0))) * minf(hx, hy)
		return 0.0
	var d := stadium_sdf(x, y, hx, hy, cr)
	if d < 0.0:
		return -d
	return 0.0
