extends Node
## 体内脏器 + 腹壁透视 + 软组织互动（移植自网页 rouchangmoniqi3 figure.tsx）。
##
## - 资源：tools/bake_organs.py 把网页的 intestines.glb / pelvis.glb 按网页同款流程摆进腹腔，
##   并烘好蒙皮权重（C_Hip_a / C_Spine_a..d）与肠蠕动参数，输出 assets/organs/organs_mesh.bin。
## - 透视：躯干皮肤换成 skin_xray（挖孔）+ skin_xray_fade（半透明覆盖层），与网页 attachXray 一致。
## - 互动：拖拽（setTissueDrag）/ 击腹（BellyStrike + 肠蠕动兴奋）。其余模式（拳头/刺刀/肚脐）仍为占位。

const PACK_PATH := "res://assets/organs/organs_mesh.bin"
const META_PATH := "res://assets/organs/organs_meta.json"
const SKIN_SHADER := preload("res://shaders/skin_xray.gdshader")
const SKIN_FADE_SHADER := preload("res://shaders/skin_xray_fade.gdshader")
const ORGAN_SHADER := preload("res://shaders/organ.gdshader")
const RING_SHADER := preload("res://shaders/fx_ring.gdshader")
const TEX := {
	0: ["res://assets/organs/colon_albedo.jpg", "res://assets/organs/colon_normal.jpg"],
	1: ["res://assets/organs/small_albedo.jpg", "res://assets/organs/small_normal.jpg"],
}
## 网页默认 abdomenXray = 0.38（X 键在 0 / 0.38 间切换）
const XRAY_DEFAULT := 0.38
## 光照层：腹内补光只照脏器
const ORGAN_LIGHT_LAYER := 1 << 19
const STRIKE_LIFE := 3.6
const InsertTools := preload("res://scripts/organs/insert_tools.gd")
const PropMeshes := preload("res://scripts/organs/prop_meshes.gd")
const SKIN_DECAL_LAYER := 1 << 14  # 伤口贴花只投到躯干皮肤（Decal.cull_mask）
## 网页 findCrotch / findAnus 在本模型上的结果（骨架静止空间）
const CROTCH_REST := Vector3(0.0, 0.9024, 0.105)
const ANUS_REST := Vector3(0.0, 0.8969, -0.0021)

# --- 公共状态（HUD 读写）
var xray_enabled: bool = true
var xray_amount: float = XRAY_DEFAULT
var show_organs: bool = true
var interact_mode: String = "drag"
var strike_force: float = 0.52
var strike_range: float = 0.32
var strike_rebound: float = 0.72
## 肠蠕动参数（HUD 透视区可调，网页 gutAmp / gutSpeed + Godot 版额外的波密度 / 分节）
const PERI_DEFAULTS := {"gut_amp": 0.3, "gut_speed": 0.5, "peri_waves": 1.55, "peri_seg": 1.0}
var gut_amp: float = 0.3  # 蠕动幅度 0..1
var gut_speed: float = 0.5  # 蠕动速度 0..1
var peri_waves: float = 1.55  # 沿肠管同时存在的蠕动波数（波长 = 1/波数）
var peri_seg: float = 1.0  # 分节收缩（结肠袋 / 混合运动）强度倍数 0..2
var peristalsis_on: bool = true
var _peri_clock: Vector3 = Vector3.ZERO

var ready_ok: bool = false
var meta: Dictionary = {}
var organ_meshes: Array[MeshInstance3D] = []
var skin_meshes: Array[MeshInstance3D] = []

var _skel: Skeleton3D
var _spine_i: int = -1
var _navel_rest: Vector3 = Vector3(0.0, 1.06, 0.114)
var _skin_mats: Array[ShaderMaterial] = []
var _organ_mats: Array[ShaderMaterial] = []
var _all_mats: Array[ShaderMaterial] = []
var _time: float = 0.0
var _gut_exc: float = 0.0
var _waves: Array = []  # {p: Vector3 (ab-local), t, force, range, rebound}
var _drag_active: bool = false
var _drag_grab: Vector3 = Vector3.ZERO
var _drag_target: Vector3 = Vector3.ZERO
var _drag_off: Vector3 = Vector3.ZERO
var _drag_vel: Vector3 = Vector3.ZERO
var _frame: Transform3D = Transform3D.IDENTITY  # ab-local → world (orthonormal)
var _ellipsoid_c: Vector3 = Vector3(0.0, -0.03, -0.1)
var _ellipsoid_r: Vector3 = Vector3(0.13, 0.19, 0.1)
var _ring: MeshInstance3D
var _poke: MeshInstance3D
var _ring_mat: ShaderMaterial
var _poke_mat: ShaderMaterial
var _light: OmniLight3D
## 拳交 / 刺刀 / 长刺刀（insert_tools.gd：网页 FistPlay + BayonetPlay）
var tools: InsertTools = InsertTools.new()
var _tool_grab: bool = false
var _tool_plane_n: Vector3 = Vector3.FORWARD
var _tool_plane_p: Vector3 = Vector3.ZERO
var _arm: MeshInstance3D
var _knife: MeshInstance3D
var _knife_long: MeshInstance3D
var _marker: MeshInstance3D
var _marker_mat: ShaderMaterial
var _decals: Array[Decal] = []
var _colon_end_rest: Variant = null
## 网页 GutHealth：肠道「受损」度 0..1（伤口越多越红，组织更软）
var gut_health: float = 0.0
## 拳交兴奋 → 呼吸加深（网页 arousal → breath boost）；由本体 / 分身设置
var secondary: RefCounted = null
## 由分身 / 本体按 RefCounted 共享的已解析脏器网格缓存
static var _organ_cache: Array = []
static var _organ_bones: Array = []
static var _colon_cache: Variant = null


func setup(skel: Skeleton3D) -> bool:
	_skel = skel
	add_to_group("organ_rigs")
	if _skel == null:
		push_warning("organs: no skeleton")
		return false
	_spine_i = _skel.find_bone("C_Spine_a")
	if _spine_i < 0:
		_spine_i = _skel.find_bone("C_Hip_a")
	meta = _load_meta()
	if meta.has("navel"):
		var n: Array = meta["navel"]
		_navel_rest = Vector3(n[0], n[1], n[2])
	_fit_hit_ellipsoid()
	_install_skin_xray()
	if not _build_organs():
		return false
	_build_fx()
	_setup_tools()
	ready_ok = true
	_update_frame()
	# Park hidden FX quads at the navel (tiny) so body AABB checks stay valid.
	for q in [_ring, _poke, _marker, _arm, _knife, _knife_long]:
		q.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.01), _frame.origin)
	_push_uniforms()
	print("organs: ready meshes=", organ_meshes.size(), " skin=", skin_meshes.size(), " navel=", _navel_rest)
	return true


# ------------------------------------------------------------------ public API
func reset_peristalsis() -> void:
	for k in PERI_DEFAULTS.keys():
		set(k, PERI_DEFAULTS[k])
	peristalsis_on = true


func set_xray_enabled(on: bool) -> void:
	xray_enabled = on


func toggle_xray() -> void:
	xray_enabled = not xray_enabled


func set_xray_amount(v: float) -> void:
	xray_amount = clampf(v, 0.0, 1.0)


func effective_xray() -> float:
	return xray_amount if xray_enabled else 0.0


## 第一人称近裁球（世界坐标 + 半径，0 = 关闭）：皮肤 shader 只对隐藏头部图层的相机（第一人称主相机）丢弃。
func set_fp_clip(eye_w: Vector3, radius: float) -> void:
	for m in _skin_mats:
		m.set_shader_parameter("fp_eye_w", eye_w)
		m.set_shader_parameter("fp_clip_r", radius)


func set_show_organs(on: bool) -> void:
	show_organs = on
	for mi in organ_meshes:
		mi.visible = on


func set_interact_mode(m: String) -> void:
	if m == "bayonet_long":
		tools.set_kind("long")
		m = "bayonet"
	elif m == "bayonet_short":
		tools.set_kind("short")
		m = "bayonet"
	interact_mode = m
	if m != "drag":
		end_drag()
	tools.set_fist_enabled(m == "fist")
	tools.set_blade_enabled(m == "bayonet")
	if m != "fist" and m != "bayonet":
		_tool_grab = false


## 该模式是否已接入脏器互动（网页：拖拽 / 击腹 / 拳交 / 刺刀）
func mode_is_live(m: String = "") -> bool:
	var k := interact_mode if m == "" else m
	return k in ["drag", "strike", "fist", "bayonet", "bayonet_long", "bayonet_short"]


func is_tool_mode() -> bool:
	return interact_mode == "fist" or interact_mode == "bayonet"


## 工具模式下点击（射线：世界坐标）。返回 true = 已开始按住拖动。
## 拳交：任意命中腹部 / 下身的点击都抓住拳头（网页 FistPlay.drag）。
## 刺刀：还没选入口 → 命中腹部的点作为入口（刀悬停在体外）；已选 → 抓住刀柄推拉。
func tool_begin(origin: Vector3, dir: Vector3, cam_fwd: Vector3) -> bool:
	_update_frame()
	var inv := _frame.affine_inverse()
	if interact_mode == "fist":
		var tipw := _frame * tools.fist_tip
		var hit: Variant = ray_hit_belly(origin, dir)
		var near := _ray_point_dist(origin, dir, tipw) < 0.3
		if hit == null and not near:
			return false
		tools.set_fist_enabled(true)
		_tool_plane_n = cam_fwd.normalized()
		_tool_plane_p = tipw
		_tool_grab = true
		return true
	if interact_mode == "bayonet":
		tools.set_blade_enabled(true)
		if not tools.has_entry:
			var hit2: Variant = ray_hit_belly(origin, dir)
			if hit2 == null:
				return false
			var l: Vector3 = inv * (hit2 as Vector3)
			var nrm := ((l - _ellipsoid_c) / (_ellipsoid_r * _ellipsoid_r)).normalized()
			tools.blade_pick(l, nrm)
			return false
		var hw := _frame * tools.handle
		if _ray_point_dist(origin, dir, _frame * tools.entry) > 0.35 and _ray_point_dist(origin, dir, hw) > 0.2:
			return false
		_tool_plane_n = cam_fwd.normalized()
		_tool_plane_p = hw
		_tool_grab = true
		return true
	return false


func tool_drag(origin: Vector3, dir: Vector3) -> void:
	if not _tool_grab:
		return
	var den := _tool_plane_n.dot(dir)
	if absf(den) < 1e-5:
		return
	var t := _tool_plane_n.dot(_tool_plane_p - origin) / den
	if t < 0.0:
		return
	var wp := origin + dir * t
	_update_frame()
	var l := _frame.affine_inverse() * wp
	if interact_mode == "fist":
		tools.fist_drag_to(l)
	elif interact_mode == "bayonet":
		tools.blade_drag_to(l)


func tool_end() -> void:
	_tool_grab = false


func is_tool_grabbing() -> bool:
	return _tool_grab


## 测试 / HUD：直接设置深度（0..1）。拳交 = 伸入深度；刺刀 = 推入量（自动选默认入口）。
func tool_set_depth01(t: float) -> void:
	if interact_mode == "fist":
		tools.set_fist_enabled(true)
		tools.fist_set_depth01(t)
	elif interact_mode == "bayonet":
		tools.set_blade_enabled(true)
		if not tools.has_entry:
			var l := Vector3(0.0, -0.02, _profile_at(-0.02).y)
			tools.blade_pick(l, Vector3(0, 0, 1))
		tools.set_pen01(t)


func tool_depth01() -> float:
	if interact_mode == "fist":
		return tools.fist_depth01()
	if interact_mode == "bayonet":
		return tools.pen01()
	return 0.0


func tool_release() -> void:
	tools.release_entry()
	_tool_grab = false


func arousal() -> float:
	return tools.fist_arousal


## 互动目标挑选：射线到本角色的距离（腹部椭球命中，或工具模式下靠近拳头 / 刀的位置），未命中 = INF。
func ray_pick_distance(origin: Vector3, dir: Vector3) -> float:
	if not ready_ok:
		return INF
	var hit: Variant = ray_hit_belly(origin, dir)
	var best := INF
	if hit != null:
		best = origin.distance_to(hit)
	if interact_mode == "fist" and tools.fist_enabled:
		var tw := _frame * tools.fist_tip
		if _ray_point_dist(origin, dir, tw) < 0.3:
			best = minf(best, (tw - origin).dot(dir))
	elif interact_mode == "bayonet" and tools.has_entry:
		var ew := _frame * tools.entry
		var hw := _frame * tools.handle
		if _ray_point_dist(origin, dir, ew) < 0.35 or _ray_point_dist(origin, dir, hw) < 0.2:
			best = minf(best, (ew - origin).dot(dir))
	return best


func _ray_point_dist(o: Vector3, d: Vector3, p: Vector3) -> float:
	var t := maxf(0.0, (p - o).dot(d))
	return (o + d * t).distance_to(p)


## 分身：同步本体的显示 / 互动参数（工具参数全局共享，伤口 / 深度各自独立）
func copy_settings_from(o: Node) -> void:
	if o == null or o == self:
		return
	xray_enabled = o.xray_enabled
	xray_amount = o.xray_amount
	if show_organs != o.show_organs:
		set_show_organs(o.show_organs)
	strike_force = o.strike_force
	strike_range = o.strike_range
	strike_rebound = o.strike_rebound
	for k in PERI_DEFAULTS.keys():
		set(k, o.get(k))
	peristalsis_on = o.peristalsis_on
	var ot: InsertTools = o.tools
	for k in ["fist_bulge", "fist_spread", "fist_gut", "fist_lever", "fist_max_depth", "fist_rise", "fist_thrust", "fist_stir", "fist_thrust_speed", "fist_stir_speed", "fist_stir_radius", "bayonet_auto", "bayonet_pump"]:
		tools.set(k, ot.get(k))
	if tools.bayonet_kind != ot.bayonet_kind:
		tools.set_kind(ot.bayonet_kind)
	if interact_mode != o.interact_mode:
		set_interact_mode(o.interact_mode)


## 网页 fireStrike：在世界坐标点释放一次击腹冲击
func strike_at(world_p: Vector3, force: float = -1.0, rng: float = -1.0) -> void:
	_update_frame()
	var f := strike_force if force < 0.0 else force
	var r := strike_range if rng < 0.0 else rng
	_waves.append({
		"p": _frame.affine_inverse() * world_p,
		"t": 0.0,
		"force": clampf(f, 0.08, 1.0),
		"range": clampf(r, 0.05, 1.0),
		"rebound": strike_rebound,
	})
	if _waves.size() > 4:
		_waves.pop_front()
	_gut_exc = minf(0.35, _gut_exc + 0.08 + f * 0.14)


func begin_drag(world_p: Vector3) -> void:
	_update_frame()
	_drag_active = true
	_drag_grab = _frame.affine_inverse() * world_p
	_drag_target = _drag_grab
	_drag_off = Vector3.ZERO
	_drag_vel = Vector3.ZERO


func update_drag(world_target: Vector3) -> void:
	if not _drag_active:
		return
	_drag_target = _frame.affine_inverse() * world_target


func end_drag() -> void:
	_drag_active = false


## R 键：清掉拖拽 / 打击形变（网页 resetSim 的腹部部分）。
func reset_interaction() -> void:
	_drag_active = false
	_drag_off = Vector3.ZERO
	_drag_vel = Vector3.ZERO
	_waves.clear()
	_tool_grab = false
	tools.fist_reset()
	tools.release_entry()
	tools.clear_marks()
	gut_health = 0.0


func is_dragging() -> bool:
	return _drag_active


func drag_grab_world() -> Vector3:
	return _frame * _drag_grab


func drag_offset_length() -> float:
	return _drag_off.length()


func active_waves() -> int:
	return _waves.size()


## 网页 strike 波对一个 ab-local 点的位移（用于自检）
func debug_strike_displacement(local_p: Vector3) -> float:
	var q := local_p
	for w in _waves:
		var t: float = w["t"]
		var force: float = w["force"]
		var rng: float = w["range"]
		var reb: float = w["rebound"]
		var p0: Vector3 = w["p"]
		var rec := 1.05 + (1.0 - clampf(reb, 0.0, 1.0)) * 2.4
		var decay := 0.28 + reb * 0.85
		var dx := q.x - p0.x
		var dy := q.y - p0.y
		var r := sqrt(dx * dx + dy * dy)
		var span := 0.055 + rng * 0.13
		var ring_r := t * (0.18 + rng * 0.15)
		var width := 0.03 + rng * 0.024
		var life := maxf(0.0, 1.0 - t / rec)
		var fade := life * life * (3.0 - 2.0 * life)
		var rr := (r - ring_r) / width
		var ring := exp(-rr * rr)
		var hole := exp(-(r * r) / (span * span * 0.55)) * exp(-t * decay)
		var amp := force * fade
		var inv := 0.0 if r < 1e-4 else 1.0 / r
		var push := amp * (0.03 * ring + 0.026 * hole)
		var crush := amp * (0.062 * hole + 0.018 * ring)
		q.x += dx * inv * push
		q.y += dy * inv * push * 0.7
		q.z -= crush
	return (q - local_p).length()


## 校验用：冲击环 / 拖拽标记在腹部局部平面内的半轴长（世界米）
func debug_fx_axes() -> Dictionary:
	var out := {}
	for pair in [["ring", _ring], ["poke", _poke]]:
		var mi: MeshInstance3D = pair[1]
		var bb := mi.global_transform.basis
		out[pair[0]] = Vector3((bb * Vector3.RIGHT).length(), (bb * Vector3.UP).length(), (_frame.basis.z.dot((bb * Vector3.RIGHT).normalized())))
	return out


func navel_world() -> Vector3:
	return _frame.origin


func abdomen_frame() -> Transform3D:
	return _frame


## 射线 vs 腹部椭球（ab-local），命中返回世界坐标点，否则返回 null
func ray_hit_belly(origin: Vector3, dir: Vector3) -> Variant:
	_update_frame()
	var inv := _frame.affine_inverse()
	var o := inv * origin - _ellipsoid_c
	var d := inv.basis * dir
	var on := o / _ellipsoid_r
	var dn := d / _ellipsoid_r
	var a := dn.dot(dn)
	var b := 2.0 * on.dot(dn)
	var c := on.dot(on) - 1.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0 or a < 1e-9:
		return null
	var sq := sqrt(disc)
	var t := (-b - sq) / (2.0 * a)
	if t < 0.0:
		t = (-b + sq) / (2.0 * a)
	if t < 0.0:
		return null
	return origin + dir * t


func debug_snapshot() -> Dictionary:
	return {
		"ready": ready_ok,
		"xray": effective_xray(),
		"xray_enabled": xray_enabled,
		"organs": organ_meshes.size(),
		"skin": skin_meshes.size(),
		"waves": _waves.size(),
		"drag_off": _drag_off.length(),
		"gut_exc": _gut_exc,
		"navel_w": _frame.origin,
		"mode": interact_mode,
		"fist_depth": tools.fist_depth,
		"blade_pen": tools.penetration,
		"punctured": tools.punctured,
		"wounds": tools.wounds.size(),
		"damage": tools.damage.size(),
	}


# ------------------------------------------------------------------ frame
func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if not ready_ok:
		return
	var dt := minf(delta, 0.05)
	_time += dt
	for w in _waves:
		w["t"] = float(w["t"]) + dt
	_waves = _waves.filter(func(w): return float(w["t"]) < STRIKE_LIFE)
	_gut_exc += (0.0 - _gut_exc) * (1.0 - exp(-0.42 * dt))
	var s_eff := clampf(gut_speed * (1.0 + _gut_exc * 0.3), 0.0, 1.0)
	_peri_clock += Vector3(0.03 + s_eff * 0.2, 0.45 + s_eff * 0.9, 0.25 + s_eff * 0.5) * dt
	_step_drag(dt)
	_step_tools(dt)
	for mi in organ_meshes:
		mi.visible = show_organs
	_update_frame()
	_push_uniforms()
	_update_fx()
	_update_props()


func _step_tools(dt: float) -> void:
	tools.fist_step(dt)
	var gut := clampf(tools.fist_gut, 0.0, 2.0)
	tools.blade_step(dt, _tool_grab, gut)
	if tools.puncture_event:
		tools.puncture_event = false
		# 网页 puncture：一次无圆环的冲击 + 肠道兴奋
		_waves.append({"p": tools.entry, "t": 0.0, "force": 0.45, "range": 0.22, "rebound": strike_rebound, "ring": false})
		if _waves.size() > 4:
			_waves.pop_front()
		_gut_exc = minf(0.35, _gut_exc + 0.12)
	if tools.auto_released:
		tools.auto_released = false
	var h := 0.0
	for d in tools.damage:
		h += (d as Vector4).w
	gut_health = clampf(h / 6.0, 0.0, 1.0)
	if tools.fist_enabled and tools.fist_depth > 0.03:
		_gut_exc = maxf(_gut_exc, tools.fist_arousal * 0.3)
	if secondary != null and tools.fist_arousal > 0.01:
		secondary.set("breath_boost", maxf(float(secondary.get("breath_boost")), clampf(tools.fist_arousal * 0.9, 0.0, 1.0)))


func _step_drag(dt: float) -> void:
	var target := Vector3.ZERO
	var k := 140.0
	var zeta := 0.32
	if _drag_active:
		target = _drag_target - _drag_grab
		if target.length() > 0.08:
			target = target.normalized() * 0.08
		k = 260.0
		zeta = 0.8
	var c := 2.0 * sqrt(k) * zeta
	# semi-implicit Euler, substeps for stability
	var n := 4
	var h := dt / float(n)
	for _i in n:
		var acc := (target - _drag_off) * k - _drag_vel * c
		_drag_vel += acc * h
		_drag_off += _drag_vel * h
	if not _drag_active and _drag_off.length() < 1e-5 and _drag_vel.length() < 1e-4:
		_drag_off = Vector3.ZERO
		_drag_vel = Vector3.ZERO


func _update_frame() -> void:
	if _skel == null or _spine_i < 0:
		return
	# 用插值后的骨架变换：物理插值开启时与渲染出的皮肤一致（透视窗口 / 互动不抖）
	var m := _skel.get_global_transform_interpolated() * _skel.get_bone_global_pose(_spine_i) * _skel.get_bone_global_rest(_spine_i).affine_inverse()
	var o := m * _navel_rest
	var right := (m.basis * Vector3.RIGHT).normalized()
	var up := (m.basis * Vector3.UP).normalized()
	var fwd := right.cross(up).normalized()
	up = fwd.cross(right).normalized()
	_frame = Transform3D(Basis(right, up, fwd), o)


func _push_uniforms() -> void:
	var b := _frame.basis
	var sp: Array = []
	var spar: Array = []
	for i in 4:
		if i < _waves.size():
			var w: Dictionary = _waves[i]
			var p: Vector3 = w["p"]
			sp.append(Vector4(p.x, p.y, p.z, float(w["t"])))
			spar.append(Vector4(float(w["force"]), float(w["range"]), float(w["rebound"]), 0.0))
		else:
			sp.append(Vector4(0, 0, 0, -1))
			spar.append(Vector4(0, 0, 0, 0))
	var xr := effective_xray()
	var g := _gut_exc
	for m in _all_mats:
		m.set_shader_parameter("ab_navel", _frame.origin)
		m.set_shader_parameter("ab_right", b.x)
		m.set_shader_parameter("ab_up", b.y)
		m.set_shader_parameter("ab_fwd", b.z)
		m.set_shader_parameter("strike_pos", sp)
		m.set_shader_parameter("strike_par", spar)
		m.set_shader_parameter("drag_grab", _drag_grab)
		m.set_shader_parameter("drag_off", _drag_off)
	var sq := tools.squeeze_target()
	for m in _all_mats:
		if sq.is_empty():
			m.set_shader_parameter("dent", Vector4.ZERO)
		else:
			var g0: Vector3 = sq[0]
			m.set_shader_parameter("dent", Vector4(g0.x, g0.y, g0.z, float(sq[2])))
			m.set_shader_parameter("dent_off", (sq[1] as Vector3) - g0)
	var fb := tools.fist_bulge_params()
	var fpar := Vector4(tools.fist_bulge, tools.fist_spread, tools.fist_rise, tools.fist_lever)
	for m in _skin_mats:
		m.set_shader_parameter("xray", xr)
		m.set_shader_parameter("fist_bulge", fb[0])
		m.set_shader_parameter("fist_lean", fb[1])
		m.set_shader_parameter("fist_par", fpar)
	var ra: Array = []
	var rd: Array = []
	var rm: Array = []
	for r in [tools.fist_rod(), tools.blade_rod(clampf(tools.fist_gut, 0.0, 2.0))]:
		if r.is_empty():
			ra.append(Vector4(0, 0, 0, -1))
			rd.append(Vector4(0, 0, 1, 0))
			rm.append(Vector4.ZERO)
		else:
			var a: Vector3 = r[0]
			var d: Vector3 = r[1]
			ra.append(Vector4(a.x, a.y, a.z, float(r[2])))
			rd.append(Vector4(d.x, d.y, d.z, float(r[3])))
			rm.append(Vector4(float(r[4]), float(r[5]), 0, 0))
	var dm: Array = []
	for i in 12:
		dm.append(tools.damage[i] if i < tools.damage.size() else Vector4.ZERO)
	for m in _organ_mats:
		m.set_shader_parameter("peri_amp", clampf(gut_amp * (1.0 + g * 0.38), 0.0, 1.0))
		m.set_shader_parameter("peri_on", 1.0 if peristalsis_on else 0.0)
		m.set_shader_parameter("peri_waves", peri_waves)
		m.set_shader_parameter("peri_clock", _peri_clock)
		m.set_shader_parameter("peri_seg", peri_seg)
		m.set_shader_parameter("rod_a", ra)
		m.set_shader_parameter("rod_d", rd)
		m.set_shader_parameter("rod_m", rm)
		m.set_shader_parameter("dmg", dm)
	if _light:
		_light.global_position = _frame.origin - b.z * 0.04
		_light.light_energy = (0.05 + xr * 0.06) * 8.0 if (show_organs and xr > 0.08) else 0.0


# ------------------------------------------------------------------ build
func _load_meta() -> Dictionary:
	var f := FileAccess.open(META_PATH, FileAccess.READ)
	if f == null:
		push_warning("organs: meta missing")
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


func _fit_hit_ellipsoid() -> void:
	if not meta.has("profile"):
		return
	var prof: Dictionary = meta["profile"]
	var ys: Array = prof["y"]
	var hx: Array = prof["half_x"]
	var zf: Array = prof["z_front"]
	var zb: Array = prof["z_back"]
	var y := _navel_rest.y
	var best := 0
	for i in ys.size():
		if absf(float(ys[i]) - y) < absf(float(ys[best]) - y):
			best = i
	var rx := maxf(0.1, float(hx[best]) * 0.95)
	var front := float(zf[best])
	var back := float(zb[best])
	_ellipsoid_r = Vector3(rx, 0.2, maxf(0.06, (front - back) * 0.5))
	_ellipsoid_c = Vector3(0.0, -0.03, (front + back) * 0.5 - _navel_rest.z)


func _is_torso_skin(mi: MeshInstance3D) -> bool:
	var low := mi.name.to_lower()
	if "hair" in low or "_007_" in mi.name or "_eye" in low or "mouth" in low or "head" in low or "charm" in low:
		return false
	return "dress" in low or "skin" in low


func _install_skin_xray() -> void:
	var xr: Dictionary = meta.get("xray", {})
	for n in _skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or not _is_torso_skin(mi) or mi.mesh == null:
			continue
		var src := mi.get_active_material(0) as BaseMaterial3D
		var base := ShaderMaterial.new()
		base.shader = SKIN_SHADER
		var fade := ShaderMaterial.new()
		fade.shader = SKIN_FADE_SHADER
		for m in [base, fade]:
			_copy_skin_params(src, m)
			m.set_shader_parameter("xray_y0", float(xr.get("y0", -0.2)))
			m.set_shader_parameter("xray_y1", float(xr.get("y1", 0.145)))
			m.set_shader_parameter("xray_xmax", float(xr.get("x_max", 0.12)))
			m.set_shader_parameter("xray_zfront", float(xr.get("z_front", -0.01)))
			_set_profile_params(m)
			_skin_mats.append(m)
			_all_mats.append(m)
		base.next_pass = fade
		mi.set_surface_override_material(0, base)
		mi.layers |= SKIN_DECAL_LAYER
		skin_meshes.append(mi)


## 躯干截面轮廓（相对肚脐）→ 透视窗口只挖前腹壁，不把腰部整个截面挖穿。
func _set_profile_params(m: ShaderMaterial) -> void:
	if not meta.has("profile"):
		return
	var prof: Dictionary = meta["profile"]
	var ys: Array = prof["y"]
	var cnt := mini(ys.size(), 24)
	var py := PackedFloat32Array()
	var phx := PackedFloat32Array()
	var pzf := PackedFloat32Array()
	var pzb := PackedFloat32Array()
	for i in 24:
		var j := mini(i, cnt - 1)
		py.append(float(ys[j]) - _navel_rest.y)
		phx.append(float(prof["half_x"][j]))
		pzf.append(float(prof["z_front"][j]) - _navel_rest.z)
		pzb.append(float(prof["z_back"][j]) - _navel_rest.z)
	m.set_shader_parameter("prof_n", cnt)
	m.set_shader_parameter("prof_y", py)
	m.set_shader_parameter("prof_hx", phx)
	m.set_shader_parameter("prof_zf", pzf)
	m.set_shader_parameter("prof_zb", pzb)


## 校验用：与 shader xray_hole 相同的公式（ab-local 点），xr = 透视强度。
func debug_xray_hole(l: Vector3, xr: float = -1.0) -> float:
	var x := effective_xray() if xr < 0.0 else xr
	var xd: Dictionary = meta.get("xray", {})
	var y0 := float(xd.get("y0", -0.2))
	var y1 := float(xd.get("y1", 0.145))
	var xmax := float(xd.get("x_max", 0.12))
	var zf0 := float(xd.get("z_front", -0.01))
	var pr := _profile_at(l.y)
	var band := smoothstep(y0, y0 + 0.08, l.y) * (1.0 - smoothstep(y1 - 0.04, y1, l.y))
	var w_out := minf(xmax + 0.1, pr.x - 0.015)
	var w_in := minf(xmax * 0.65, w_out - 0.045)
	var torso := 1.0 - smoothstep(w_in, w_out, absf(l.x))
	var front := smoothstep(zf0 - 0.16, zf0 + 0.04, l.z)
	var zmid := 0.5 * (pr.y + pr.z)
	front *= smoothstep(zmid, zmid + 0.035, l.z)
	return clampf(band * torso * front * x, 0.0, 1.0)


## 截面轮廓（相对肚脐）：x = 半宽，y = 前表面 z，z = 后表面 z
func _profile_at(y_rel: float) -> Vector3:
	var prof: Dictionary = meta.get("profile", {})
	if prof.is_empty():
		return Vector3(0.15, 0.01, -0.13)
	var ys: Array = prof["y"]
	var get_v := func(i: int) -> Vector3:
		return Vector3(float(prof["half_x"][i]), float(prof["z_front"][i]) - _navel_rest.z, float(prof["z_back"][i]) - _navel_rest.z)
	if y_rel <= float(ys[0]) - _navel_rest.y:
		return get_v.call(0)
	for i in range(1, ys.size()):
		var yi := float(ys[i]) - _navel_rest.y
		if y_rel <= yi:
			var yp := float(ys[i - 1]) - _navel_rest.y
			return (get_v.call(i - 1) as Vector3).lerp(get_v.call(i), (y_rel - yp) / maxf(1e-5, yi - yp))
	return get_v.call(ys.size() - 1)


func _copy_skin_params(src: BaseMaterial3D, m: ShaderMaterial) -> void:
	if src == null:
		return
	m.set_shader_parameter("albedo_tex", src.albedo_texture)
	m.set_shader_parameter("albedo_color", src.albedo_color)
	m.set_shader_parameter("metallic", src.metallic)
	m.set_shader_parameter("roughness", src.roughness)
	m.set_shader_parameter("specular", src.metallic_specular)
	var orm: Texture2D = src.roughness_texture
	m.set_shader_parameter("has_orm", orm != null)
	if orm:
		m.set_shader_parameter("orm_tex", orm)
	m.set_shader_parameter("has_normal", src.normal_enabled and src.normal_texture != null)
	if src.normal_texture:
		m.set_shader_parameter("normal_tex", src.normal_texture)
	m.set_shader_parameter("normal_scale", src.normal_scale)


func _read_str(buf: PackedByteArray, off: int) -> Array:
	var n := buf.decode_u16(off)
	return [buf.slice(off + 2, off + 2 + n).get_string_from_utf8(), off + 2 + n]


## 解析 organs_mesh.bin（只做一次，静态缓存 → 分身共用网格，只各自建材质 / 实例）。
static func _parse_organ_pack() -> bool:
	if not _organ_cache.is_empty():
		return true
	var raw := FileAccess.get_file_as_bytes(PACK_PATH)
	if raw.is_empty():
		push_warning("organs: pack missing " + PACK_PATH)
		return false
	var buf := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if buf.size() < 16 or buf.slice(0, 4).get_string_from_ascii() != "ORGN":
		push_warning("organs: bad pack")
		return false
	var rd := func(o: int) -> Array:
		var n := buf.decode_u16(o)
		return [buf.slice(o + 2, o + 2 + n).get_string_from_utf8(), o + 2 + n]
	var off := 8
	var nb := buf.decode_u32(off)
	off += 4
	var bone_names: Array = []
	for _i in nb:
		var r: Array = rd.call(off)
		bone_names.append(r[0])
		off = r[1]
	var mesh_count := buf.decode_u32(off)
	off += 4
	var entries: Array = []
	# 网页 pickColon：along ≥ 0.9 的顶点平均高度最低的肠管 = 结肠（末端 = 直肠方向）
	var best_y := INF
	var colon: Variant = null
	for _m in mesh_count:
		var r1: Array = rd.call(off)
		var mname: String = r1[0]
		off = r1[1]
		var r2: Array = rd.call(off)
		var matname: String = r2[0]
		off = r2[1]
		var group := buf.decode_u8(off)
		var tex_id := buf.decode_s8(off + 1)
		off += 2
		var col := Color(buf.decode_float(off), buf.decode_float(off + 4), buf.decode_float(off + 8), buf.decode_float(off + 12))
		off += 16
		var vc := buf.decode_u32(off)
		var ic := buf.decode_u32(off + 4)
		off += 8
		var pos_f := buf.slice(off, off + vc * 12).to_float32_array()
		off += vc * 12
		var nrm_f := buf.slice(off, off + vc * 12).to_float32_array()
		off += vc * 12
		var tan_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var uv_f := buf.slice(off, off + vc * 8).to_float32_array()
		off += vc * 8
		var bone_b := buf.slice(off, off + vc * 4)
		off += vc * 4
		var wt_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var cust_f := buf.slice(off, off + vc * 16).to_float32_array()
		off += vc * 16
		var idx_i := buf.slice(off, off + ic * 4).to_int32_array()
		off += ic * 4

		var verts := PackedVector3Array()
		verts.resize(vc)
		var nrms := PackedVector3Array()
		nrms.resize(vc)
		var uvs := PackedVector2Array()
		uvs.resize(vc)
		var bones := PackedInt32Array()
		bones.resize(vc * 4)
		var tail_sum := 0.0
		var tail_n := 0
		var end_c := Vector3.ZERO
		var end_n := 0
		for i in vc:
			var j := i * 3
			verts[i] = Vector3(pos_f[j], pos_f[j + 1], pos_f[j + 2])
			nrms[i] = Vector3(nrm_f[j], nrm_f[j + 1], nrm_f[j + 2])
			uvs[i] = Vector2(uv_f[i * 2], uv_f[i * 2 + 1])
			if group == 0:
				var along := cust_f[i * 4]
				if along >= 0.9:
					tail_sum += verts[i].y
					tail_n += 1
				if along >= 0.88:
					end_c += verts[i]
					end_n += 1
		if group == 0 and tail_n > 20 and end_n > 0 and tail_sum / tail_n < best_y:
			best_y = tail_sum / tail_n
			colon = end_c / float(end_n)
		for i in vc * 4:
			bones[i] = bone_b[i]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = nrms
		arrays[Mesh.ARRAY_TANGENT] = tan_f
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = wt_f
		arrays[Mesh.ARRAY_CUSTOM0] = cust_f
		arrays[Mesh.ARRAY_INDEX] = idx_i
		var am := ArrayMesh.new()
		var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		entries.append({"name": mname, "mat": matname, "group": group, "tex": tex_id, "col": col, "mesh": am})
	_organ_bones = bone_names
	_organ_cache = entries
	_colon_cache = colon
	return true


func _build_organs() -> bool:
	if not _parse_organ_pack():
		return false
	_colon_end_rest = _colon_cache
	# Skin binds copied (by name) from the body's skin so organs share the body's bind space.
	var body_skin: Skin = null
	if not skin_meshes.is_empty():
		body_skin = skin_meshes[0].skin
	var skin := Skin.new()
	for bn in _organ_bones:
		var pose := Transform3D.IDENTITY
		var found := false
		if body_skin:
			for bi in body_skin.get_bind_count():
				if String(body_skin.get_bind_name(bi)) == bn:
					pose = body_skin.get_bind_pose(bi)
					found = true
					break
		if not found:
			var idx := _skel.find_bone(bn)
			if idx >= 0:
				pose = _skel.get_bone_global_rest(idx).affine_inverse()
		skin.add_named_bind(bn, pose)
	var tex_cache := {}
	for e in _organ_cache:
		var mname: String = e["name"]
		var matname: String = e["mat"]
		var group: int = e["group"]
		var tex_id: int = e["tex"]
		var col: Color = e["col"]
		var mat := ShaderMaterial.new()
		mat.shader = ORGAN_SHADER
		var is_gut := group == 0
		mat.set_shader_parameter("is_gut", is_gut)
		if tex_id >= 0 and TEX.has(tex_id):
			if not tex_cache.has(tex_id):
				tex_cache[tex_id] = [load(TEX[tex_id][0]), load(TEX[tex_id][1])]
			mat.set_shader_parameter("use_tex", true)
			mat.set_shader_parameter("albedo_tex", tex_cache[tex_id][0])
			mat.set_shader_parameter("normal_tex", tex_cache[tex_id][1])
			mat.set_shader_parameter("base_color", Color(1, 1, 1, 1))
			mat.set_shader_parameter("roughness", 0.48)
		else:
			# 网页 polishOrgans：无贴图时颜色向 #c4786a 靠 12%
			var c := Color(col.r, col.g, col.b, 1.0).lerp(Color("#c4786a"), 0.12)
			mat.set_shader_parameter("use_tex", false)
			mat.set_shader_parameter("base_color", c)
			mat.set_shader_parameter("roughness", 0.42)
		mat.set_shader_parameter("strike_k", 1.0 if is_gut else 0.4)
		_organ_mats.append(mat)
		_all_mats.append(mat)

		var mi := MeshInstance3D.new()
		mi.name = ("Gut_" if is_gut else "Pelvis_") + mname.validate_node_name().replace(" ", "_")
		mi.mesh = e["mesh"]
		mi.material_override = mat
		mi.skin = skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 1 | ORGAN_LIGHT_LAYER
		mi.extra_cull_margin = 0.2
		mi.set_meta("organ_group", "gut" if is_gut else "pelvis")
		mi.set_meta("organ_material", matname)
		_skel.add_child(mi)
		mi.skeleton = mi.get_path_to(_skel)
		organ_meshes.append(mi)
	return organ_meshes.size() > 0


# ------------------------------------------------------------------ 拳交 / 刺刀
func _setup_tools() -> void:
	var anus_l := ANUS_REST - _navel_rest
	var colon_l: Variant = null
	if _colon_end_rest != null:
		colon_l = (_colon_end_rest as Vector3) - _navel_rest
	var slices: Array = []
	var prof: Dictionary = meta.get("profile", {})
	if not prof.is_empty():
		for i in (prof["y"] as Array).size():
			slices.append([float(prof["y"][i]) - _navel_rest.y, float(prof["half_x"][i])])
	tools.setup(anus_l, colon_l, slices, _profile_at, CROTCH_REST.y + 0.012 - _navel_rest.y, 0.108)
	_arm = _make_prop(PropMeshes.arm_mesh(), "FistArm")
	_knife = _make_prop(PropMeshes.bayonet_mesh(false), "Bayonet")
	_knife_long = _make_prop(PropMeshes.bayonet_mesh(true), "BayonetLong")
	_marker_mat = ShaderMaterial.new()
	_marker_mat.shader = RING_SHADER
	_marker_mat.set_shader_parameter("color", Color(0.85, 0.25, 0.2, 0.85))
	_marker_mat.set_shader_parameter("inner", 0.6)
	_marker = _make_quad(_marker_mat, "BladeMarker")
	for i in InsertTools.MAX_WOUNDS:
		var d := Decal.new()
		d.name = "Wound%d" % i
		d.top_level = true
		d.visible = false
		d.cull_mask = SKIN_DECAL_LAYER
		d.upper_fade = 0.3
		d.lower_fade = 0.3
		d.normal_fade = 0.35
		d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_skel.add_child(d)
		_decals.append(d)


func _make_prop(mesh: Mesh, nm: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.top_level = true
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.layers = 1
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_skel.add_child(mi)
	return mi


## 道具 / 入口标记 / 伤口贴花：每帧从 ab-local 摆到世界。
func _update_props() -> void:
	if _arm == null:
		return
	var fist_on := interact_mode == "fist" and tools.fist_enabled
	_arm.visible = fist_on and _arm.mesh != null
	if _arm.visible:
		_arm.global_transform = _frame * tools.fist_arm_xform()
	var blade_on := interact_mode == "bayonet" and tools.blade_enabled and tools.has_entry
	var long := tools.bayonet_kind == "long"
	_knife.visible = blade_on and not long and _knife.mesh != null
	_knife_long.visible = blade_on and long and _knife_long.mesh != null
	if blade_on:
		var kx := _frame * tools.blade_xform()
		_knife.global_transform = kx
		_knife_long.global_transform = kx
	_marker.visible = blade_on and not tools.punctured
	if _marker.visible:
		var n := (_frame.basis * tools.entry_normal).normalized()
		var bx := InsertTools._basis_y_to(n)
		# quad 面朝 +Z → 把 Z 对齐法线
		var qb := Basis(bx.z, bx.x, n).orthonormalized() * Basis.from_scale(Vector3(0.016, 0.016, 1.0))
		_marker.global_transform = Transform3D(qb, _frame * (tools.entry + tools.entry_normal * 0.004))
	var tiles: Array = PropMeshes.wound_tiles() if not tools.wounds.is_empty() else []
	for i in _decals.size():
		var d := _decals[i]
		if i >= tools.wounds.size():
			d.visible = false
			continue
		var w: Dictionary = tools.wounds[i]
		var n: Vector3 = (_frame.basis * (w["n"] as Vector3)).normalized()
		var along: Vector3 = _frame.basis * (w["dir"] as Vector3)
		along = (along - n * along.dot(n))
		if along.length_squared() < 1e-6:
			along = _frame.basis.y
		along = along.normalized().rotated(n, float(w["twist"]))
		var xb := n.cross(along).normalized()
		d.global_transform = Transform3D(Basis(xb, n, along), _frame * (w["p"] as Vector3))
		d.size = Vector3(float(w["w"]), 0.05, float(w["h"]))
		d.texture_albedo = tiles[int(w["tile"]) % tiles.size()]
		d.visible = true


func _build_fx() -> void:
	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = RING_SHADER
	_ring_mat.set_shader_parameter("color", Color("#f2efe9"))
	_ring_mat.set_shader_parameter("inner", 0.92)
	_ring = _make_quad(_ring_mat, "StrikeRing")
	_poke_mat = ShaderMaterial.new()
	_poke_mat.shader = RING_SHADER
	_poke_mat.set_shader_parameter("color", Color(0.83, 0.71, 0.63, 0.8))
	_poke_mat.set_shader_parameter("inner", 0.66)
	_poke = _make_quad(_poke_mat, "PokeMarker")
	_light = OmniLight3D.new()
	_light.name = "BellyLight"
	_light.light_color = Color("#a07060")
	_light.omni_range = 0.48
	_light.light_energy = 0.0
	_light.light_cull_mask = ORGAN_LIGHT_LAYER
	_light.shadow_enabled = false
	_skel.add_child(_light)


func _make_quad(mat: ShaderMaterial, nm: String) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = q
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	mi.top_level = true
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # 每帧 _process 摆放
	_skel.add_child(mi)
	return mi


## 冲击环 / 拖拽点标记：缩放必须在腹部局部轴上（b * from_scale）。
## 之前用 Basis.scaled() —— 那是「父空间（世界轴）缩放」，角色朝向与世界轴对齐时（房间出生朝向）看不出来，
## 一旦身体转了任意角度（城市里走动后），圆环就被沿世界 X/Z 拉长、斜切成椭圆。
func _update_fx() -> void:
	var b := _frame.basis
	if _waves.is_empty():
		_ring.visible = false
	else:
		var w: Dictionary = _waves[_waves.size() - 1]
		var t: float = w["t"] if w.get("ring", true) else 99.0
		var rr := maxf(0.02, t * (0.2 + float(w["range"]) * 0.16))
		var op := maxf(0.0, 1.0 - t / 1.2) * 0.85 * float(w["force"])
		var p: Vector3 = w["p"]
		var wp := _frame * (p + Vector3(0, 0, 0.012))
		_ring.global_transform = Transform3D(b * Basis.from_scale(Vector3(rr, rr, 1.0)), wp)
		var c := Color("#f2efe9")
		c.a = op
		_ring_mat.set_shader_parameter("color", c)
		_ring.visible = op > 0.02
	if _drag_active:
		var tp := _frame * (_drag_grab + _drag_off + Vector3(0, 0, 0.01))
		_poke.global_transform = Transform3D(b * Basis.from_scale(Vector3(0.036, 0.036, 1.0)), tp)
		_poke.visible = true
	else:
		_poke.visible = false
