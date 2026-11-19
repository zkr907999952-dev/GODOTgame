extends RefCounted
## 触屏按键布局：位置 / 缩放的保存、默认值，以及可复制的布局码。
##
## 布局码格式（稳定，供以后把调好的布局设成默认）：
##   TYL1.<id=x,y,s;...>.<crc16>
##   - 前缀 TYL1 是版本，以后改字段必须升到 TYL2，旧码仍可解码
##   - 每个按键一段 id=x,y,s
##       id  短名（见 IDS）
##       x,y 按键中心，相对「去掉安全区后的可用区域」，范围 0..1
##           （0,0）= 可用区左上，（1,1）= 右下
##       s   缩放，0.50..2.00
##   - 数值四舍五入：x/y 四位小数，s 三位小数
##   - crc16 是载荷的 CRC-16/IBM（大写十六进制四位），防止粘贴残缺
## 缺省的键表示用内置默认位置。空载荷（TYL1..XXXX 或未保存）= 全部默认。
## 把调好的码填到 DEFAULT_CODE 即可成为内置默认（仍可被 user:// 覆盖）。
## 0.2.29 新增 id `flight_stick`（飞机摇杆模式：左右偏航、上推加速、下拉减速）。
## 缺省该键时用内置默认位置；旧 TYL1 布局没有这一段也不会坏，只是用默认。
class_name TouchLayout

const VERSION := 1
const PREFIX := "TYL1."
const SAVE_PATH := "user://touch_layout.cfg"
## 内置默认布局码。空字符串 = 使用代码里的原始位置。主人调好后把码填在这里。
const DEFAULT_CODE := ""
const SCALE_MIN := 0.50
const SCALE_MAX := 2.00

## 可自定义的按键。短名用于布局码，保持稳定不要改。
const IDS := {
	"stick": "摇杆",
	"mode": "切换",
	"jump": "跳跃",
	"crouch": "下蹲",
	"interact": "互动",
	"weapon": "武器",
	"fire": "开火",
	"fire_left": "左开火",
	"ads": "瞄准",
	"reload": "换弹",
	"drag": "拖拽",
	"enter": "上下载具",
	"vcam": "载具视角",
	"observe": "观察",
	"accel": "加速",
	"brake": "手刹",
	"thrust_up": "飞机加速",
	"thrust_down": "飞机减速",
	"yaw_l": "左偏航",
	"yaw_r": "右偏航",
	"gear": "起落架",
	"thrust": "推力条",
	"flight_stick": "飞机摇杆",
}

static var _cache: Dictionary = {}
static var _loaded: bool = false


static func reset_cache() -> void:
	_loaded = false
	_cache = {}


static func current() -> Dictionary:
	if not _loaded:
		_loaded = true
		_cache = _load_file()
	return _cache


static func entry(id: String) -> Dictionary:
	var cur := current()
	if cur.has(id):
		return cur[id]
	return {}


static func apply_to_center(id: String, default_center: Vector2, usable: Rect2) -> Vector2:
	var e := entry(id)
	if e.is_empty():
		return default_center
	return Vector2(
		usable.position.x + clampf(float(e.get("x", 0.5)), 0.0, 1.0) * usable.size.x,
		usable.position.y + clampf(float(e.get("y", 0.5)), 0.0, 1.0) * usable.size.y
	)


static func scale_of(id: String) -> float:
	var e := entry(id)
	if e.is_empty():
		return 1.0
	return clampf(float(e.get("s", 1.0)), SCALE_MIN, SCALE_MAX)


static func usable_rect(vp: Vector2, safe: Vector4) -> Rect2:
	var p := Vector2(safe.x, safe.y)
	var s := Vector2(maxf(1.0, vp.x - safe.x - safe.z), maxf(1.0, vp.y - safe.y - safe.w))
	return Rect2(p, s)


static func pack_entry(center: Vector2, scale: float, usable: Rect2) -> Dictionary:
	var x := 0.5
	var y := 0.5
	if usable.size.x > 1.0:
		x = clampf((center.x - usable.position.x) / usable.size.x, 0.0, 1.0)
	if usable.size.y > 1.0:
		y = clampf((center.y - usable.position.y) / usable.size.y, 0.0, 1.0)
	return {"x": x, "y": y, "s": clampf(scale, SCALE_MIN, SCALE_MAX)}


static func set_layout(data: Dictionary, persist: bool = true) -> void:
	_cache = data.duplicate(true)
	_loaded = true
	if persist:
		_save_file(_cache)


static func clear_saved() -> void:
	_cache = _from_code(DEFAULT_CODE)
	_loaded = true
	if FileAccess.file_exists(SAVE_PATH):
		var d := DirAccess.open("user://")
		if d:
			d.remove("touch_layout.cfg")


static func encode(data: Dictionary = {}) -> String:
	if data.is_empty():
		data = current()
	return _to_code(data)


static func decode(code: String) -> Dictionary:
	return _from_code(code)


static func is_valid_code(code: String) -> bool:
	var c := code.strip_edges()
	if c.is_empty():
		return false
	# 允许无 CRC 的残码在 decode 时失败；这里要求完整前缀。
	return c.begins_with("TYL1.") or c.begins_with("TYL")


static func _load_file() -> Dictionary:
	var c := ConfigFile.new()
	if c.load(SAVE_PATH) == OK:
		var code := str(c.get_value("layout", "code", ""))
		var parsed := _from_code(code)
		if not parsed.is_empty() or code.strip_edges().begins_with("TYL1."):
			return parsed
	return _from_code(DEFAULT_CODE)


static func _save_file(data: Dictionary) -> void:
	var c := ConfigFile.new()
	c.set_value("layout", "code", _to_code(data))
	c.set_value("layout", "version", VERSION)
	c.save(SAVE_PATH)


static func _to_code(data: Dictionary) -> String:
	var keys: Array = []
	for id in IDS.keys():
		if data.has(id):
			keys.append(id)
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for id in keys:
		var e: Dictionary = data[id]
		var x := snappedf(clampf(float(e.get("x", 0.5)), 0.0, 1.0), 0.0001)
		var y := snappedf(clampf(float(e.get("y", 0.5)), 0.0, 1.0), 0.0001)
		var s := snappedf(clampf(float(e.get("s", 1.0)), SCALE_MIN, SCALE_MAX), 0.001)
		parts.append("%s=%.4f,%.4f,%.3f" % [id, x, y, s])
	var payload := ";".join(parts)
	return PREFIX + payload + "." + _crc16_hex(payload)


static func _from_code(code: String) -> Dictionary:
	var raw := code.strip_edges().replace("\n", "").replace(" ", "")
	if raw.is_empty():
		return {}
	if not raw.begins_with("TYL"):
		return {}
	# TYL1.<payload>.<crc>
	var body := raw
	var dot := raw.find(".")
	if dot < 0:
		return {}
	var ver := raw.substr(0, dot)
	if ver != "TYL1":
		# 未知版本：仍然尝试按 v1 字段解析，方便以后兼容。
		if not ver.begins_with("TYL"):
			return {}
	body = raw.substr(dot + 1)
	var crc_at := body.rfind(".")
	var payload := body
	var crc := ""
	if crc_at >= 0:
		payload = body.substr(0, crc_at)
		crc = body.substr(crc_at + 1).to_upper()
	if crc != "" and crc != _crc16_hex(payload):
		return {}
	var out := {}
	if payload.is_empty():
		return out
	for piece in payload.split(";", false):
		var eq := piece.find("=")
		if eq <= 0:
			continue
		var id := piece.substr(0, eq)
		# vcam is its own 1st/3rd toggle again (0.2.24 briefly aliased it to observe).
		if not IDS.has(id):
			continue
		var nums := piece.substr(eq + 1).split(",")
		if nums.size() < 2:
			continue
		var x := clampf(float(nums[0]), 0.0, 1.0)
		var y := clampf(float(nums[1]), 0.0, 1.0)
		var s := 1.0
		if nums.size() >= 3:
			s = clampf(float(nums[2]), SCALE_MIN, SCALE_MAX)
		out[id] = {"x": x, "y": y, "s": s}
	return out


static func _crc16_hex(s: String) -> String:
	var crc := 0xFFFF
	var buf := s.to_utf8_buffer()
	for b in buf:
		crc ^= int(b)
		for _i in 8:
			if crc & 1:
				crc = (crc >> 1) ^ 0xA001
			else:
				crc >>= 1
	return "%04X" % (crc & 0xFFFF)
