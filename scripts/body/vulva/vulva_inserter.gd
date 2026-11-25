extends RefCounted
## 通用「插入物」接口。扩张器、钳子、手指、玩具只要提供截面 / 碰撞，外阴就会按真实外形撑开。
## 不要在外阴脚本里为每种道具写特殊分支；实现本接口再 set_inserter 即可。
class_name VulvaInserter

func is_active() -> bool:
	return mix() > 1e-4

func mix() -> float:
	return 0.0

## 外口平面上的包络：{half_x, half_y, blade_sep, axis, up}。axis / up 与网格同一空间。
func envelope() -> Dictionary:
	return {}

## 把绑定空间点推出插入物体内部。already_out 原样返回。
func project_out(p: Vector3, origin: Vector3, axis: Vector3, up: Vector3) -> Vector3:
	return p

## 点在插入物体内的深度（米）。0 = 未进入。
func penetration(p: Vector3, origin: Vector3, axis: Vector3, up: Vector3) -> float:
	return 0.0

## 可选：外口平面上的多边形截面（凸包或精确轮廓），供以后更精细的投影使用。
func cross_section(_origin: Vector3, _axis: Vector3, _up: Vector3) -> PackedVector2Array:
	return PackedVector2Array()
