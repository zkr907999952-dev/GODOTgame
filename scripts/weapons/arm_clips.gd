extends RefCounted
## 烘焙后的 Kuptchi 手臂动画采样器。
## 每帧数据（相机空间，Godot 相机坐标 -Z 前 / +Y 上 / +X 右）：
##   枪根 pos(3) quat(4) | 右手：腕 pos(3) 腕→中指根长(1) 手掌朝向 quat(4) 肘(3) 手指弯曲 15 | 左手同右
## 手掌朝向 = 正交基 (f=腕→中指根, n=f×(食指根-小指根), n×f)，与我们角色手骨同样定义 → 直接映射到自己的手。

const HAND := 26
const FINGERS := ["Index", "Middle", "Ring", "Pinky", "Thumb"]

var clips: Dictionary = {}


func _init(res: Resource = null) -> void:
	if res and res.has_meta("clips"):
		clips = res.get_meta("clips")


func has(name: String) -> bool:
	return clips.has(name)


func length(name: String) -> float:
	return float(clips[name]["len"]) if clips.has(name) else 0.0


static func _read_hand(d: PackedFloat32Array, o: int) -> Dictionary:
	var curls := PackedFloat32Array()
	curls.resize(15)
	for i in 15:
		curls[i] = d[o + 11 + i]
	return {
		"wrist": Vector3(d[o], d[o + 1], d[o + 2]),
		"flen": d[o + 3],
		"q": Quaternion(d[o + 4], d[o + 5], d[o + 6], d[o + 7]).normalized(),
		"elbow": Vector3(d[o + 8], d[o + 9], d[o + 10]),
		"curls": curls,
	}


func _frame(c: Dictionary, i: int) -> Dictionary:
	var d: PackedFloat32Array = c["data"]
	var st: int = int(c["stride"])
	var o: int = clampi(i, 0, int(c["n"]) - 1) * st
	return {
		"gun": Transform3D(Basis(Quaternion(d[o + 3], d[o + 4], d[o + 5], d[o + 6]).normalized()), Vector3(d[o], d[o + 1], d[o + 2])),
		"R": _read_hand(d, o + 7),
		"L": _read_hand(d, o + 7 + HAND),
	}


## t 秒处的姿势（帧间线性插值）；loop = 循环
func sample(name: String, t: float, loop: bool = false) -> Dictionary:
	if not clips.has(name):
		return {}
	var c: Dictionary = clips[name]
	var n: int = int(c["n"])
	var fps: float = float(c["fps"])
	var ft := t * fps
	if loop and n > 1:
		ft = fposmod(ft, float(n - 1))
	ft = clampf(ft, 0.0, float(n - 1))
	var i0 := int(floor(ft))
	return blend(_frame(c, i0), _frame(c, mini(i0 + 1, n - 1)), ft - float(i0))


static func _blend_hand(a: Dictionary, b: Dictionary, k: float) -> Dictionary:
	var curls := PackedFloat32Array()
	curls.resize(15)
	var ca: PackedFloat32Array = a["curls"]
	var cb: PackedFloat32Array = b["curls"]
	for i in 15:
		curls[i] = lerpf(ca[i], cb[i], k)
	return {
		"wrist": (a["wrist"] as Vector3).lerp(b["wrist"], k),
		"flen": lerpf(a["flen"], b["flen"], k),
		"q": (a["q"] as Quaternion).slerp(b["q"], k),
		"elbow": (a["elbow"] as Vector3).lerp(b["elbow"], k),
		"curls": curls,
	}


static func blend(a: Dictionary, b: Dictionary, k: float) -> Dictionary:
	if a.is_empty():
		return b
	if b.is_empty() or k <= 0.0:
		return a
	if k >= 1.0:
		return b
	var ga: Transform3D = a["gun"]
	var gb: Transform3D = b["gun"]
	return {
		"gun": Transform3D(Basis(ga.basis.get_rotation_quaternion().slerp(gb.basis.get_rotation_quaternion(), k)), ga.origin.lerp(gb.origin, k)),
		"R": _blend_hand(a["R"], b["R"], k),
		"L": _blend_hand(a["L"], b["L"], k),
	}
