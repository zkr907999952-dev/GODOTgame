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
var _xray_sphere_ab: Vector3 = Vector3.ZERO
var _xray_sphere_r: float = 0.0
var _xray_sphere_k: float = 1.0
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
var frozen: bool = false  # 死亡后停止呼吸式蠕动 / 肚脐驱动，网格仍跟随骨骼
var meta: Dictionary = {}
var organ_meshes: Array[MeshInstance3D] = []
var skin_meshes: Array[MeshInstance3D] = []

var _skel: Skeleton3D
var _spine_i: int = -1
var _navel_rest: Vector3 = Vector3(0.0, 1.06, 0.114)
var _prof_tex: ImageTexture
var _skin_mats: Array[ShaderMaterial] = []
var _organ_mats: Array[ShaderMaterial] = []
var _all_mats: Array[ShaderMaterial] = []
var _time: float = 0.0
var _gut_exc: float = 0.0
var _waves: Array = []  # {p: Vector3 (ab-local), t, force, range, rebound}
## 弹道通道（ab-local）：{a, d, len, rad}
var _ball_ch: Array = []
const BALL_MAX := 4
var _gut_aabb: AABB = AABB()
var _uterus_aabb: AABB = AABB()

# 拳交脏器软体（弹簧）：杆参数与子宫位移滞后于拳头
var _rod_reach_s: float = 0.0
var _rod_dir_s: Vector3 = Vector3(0, 1, 0)
var _rod_tip_s: float = 0.0
var _rod_shaft_s: float = 0.0
var _rod_mix_s: float = 0.0
var _uter_off: Vector3 = Vector3.ZERO
var _uter_off_v: Vector3 = Vector3.ZERO
var _uter_tilt: float = 0.0
var _uter_tilt_v: float = 0.0
var _uter_tilt_ax: Vector3 = Vector3.RIGHT
var _uter_sq: float = 0.0
var _uter_sq_v: float = 0.0
var _uter_sq_ax: Vector3 = Vector3.FORWARD
var _uter_press: float = 0.0
var _fist_depth_prev: float = 0.0
var _fist_depth_vel: float = 0.0
var last_ballistic: Dictionary = {}
var _drag_active: bool = false
var _drag_grab: Vector3 = Vector3.ZERO
var _drag_target: Vector3 = Vector3.ZERO
var _drag_off: Vector3 = Vector3.ZERO
var _drag_vel: Vector3 = Vector3.ZERO
var _frame: Transform3D = Transform3D.IDENTITY  # ab-local → world (orthonormal)
var _ellipsoid_c: Vector3 = Vector3(0.0, -0.03, -0.1)
## 透视窗口椭球（腹前壁，肚脐空间）。与拖拽碰撞体分开，保证开孔在看得见的腹部。
var _hole_c: Vector3 = Vector3(0.0, -0.02, 0.03)
var _hole_r: Vector3 = Vector3(0.10, 0.16, 0.10)
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
static var _navel_plane_cache: Variant = null

## 肚脐互动（网页 interactMode "navel" + pose "navelPoke" + navel-morph.ts）：
## 角色自己的右手食指插入肚脐；插入量 0..1（0.5 = 指尖刚接触），深度比例决定肚脐被撑深 / 撑大多少。
const NAVEL_CONTACT_T := 0.5
const NAVEL_DEPTH_BASE := 0.06
const NAVEL_DIA_BASE := 0.42
var navel_insert: float = 0.0
var navel_depth_ratio: float = 0.7
var navel_thrust: bool = false
var navel_stir: bool = false
var navel_thrust_speed: float = 0.45
var navel_thrust_start: float = 0.5
var navel_stir_speed: float = 0.55
var navel_stir_radius: float = 0.4
var navel_live: float = 0.0
var navel_stir_off: Vector2 = Vector2.ZERO
var _navel_thrust_phase: float = 0.0
var _navel_thrust_on: bool = false
var _navel_stir_phase: float = 0.0
var _navel_grab: bool = false
var _navel_t0: float = 0.0
var _navel_o: Vector3 = Vector3.ZERO
var _navel_plane_z: float = 0.006


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
	_build_organ_aabbs()
	_install_skin_xray()
	if not _build_organs():
		return false
	_build_fx()
	_setup_tools()
	_navel_plane_z = _compute_navel_plane()
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


## 弹道特写局部透视球（世界坐标）。radius<=0 关闭。不改动腹部透视开关。
func set_xray_sphere_world(world_pos: Vector3, radius: float, amount: float = 1.0) -> void:
	if radius <= 0.001:
		clear_xray_sphere()
		return
	_xray_sphere_ab = _frame.affine_inverse() * world_pos
	_xray_sphere_r = radius
	_xray_sphere_k = clampf(amount, 0.0, 1.0)


func clear_xray_sphere() -> void:
	_xray_sphere_ab = Vector3.ZERO
	_xray_sphere_r = 0.0
	_xray_sphere_k = 1.0


func has_xray_sphere() -> bool:
	return _xray_sphere_r > 0.001


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
	var entering_navel := m == "navel" and interact_mode != "navel"
	var leaving_navel := interact_mode == "navel" and m != "navel"
	interact_mode = m
	if entering_navel:
		navel_insert = 0.0
	if leaving_navel:
		navel_insert = 0.0
		navel_thrust = false
		navel_stir = false
		_navel_grab = false
	if m != "drag":
		end_drag()
	tools.set_fist_enabled(m == "fist")
	tools.set_blade_enabled(m == "bayonet")
	if m != "fist" and m != "bayonet":
		_tool_grab = false


## 该模式是否已接入脏器互动（网页：拖拽 / 击腹 / 拳交 / 刺刀）
func mode_is_live(m: String = "") -> bool:
	var k := interact_mode if m == "" else m
	return k in ["drag", "strike", "fist", "bayonet", "bayonet_long", "bayonet_short", "navel"]


func is_tool_mode() -> bool:
	return interact_mode == "fist" or interact_mode == "bayonet" or interact_mode == "navel"


## 网页 navelInsertMorph：插入量 → {u, depth, diameter, squeeze}
static func navel_insert_morph(insert: float, ratio: float) -> Dictionary:
	var t := clampf(insert, 0.0, 1.0)
	var r := clampf(ratio, 0.0, 1.2)
	var u := 0.0 if t <= NAVEL_CONTACT_T else (t - NAVEL_CONTACT_T) / (1.0 - NAVEL_CONTACT_T)
	return {"u": u, "depth": NAVEL_DEPTH_BASE + u * r, "diameter": NAVEL_DIA_BASE + u * r * 0.5, "squeeze": u * minf(1.0, r * 0.72)}


## 插肚脐姿势：给 SoftLoco 的插入量（< 0 = 不在肚脐模式）
func navel_pose_t() -> float:
	return navel_live if interact_mode == "navel" else -1.0


## 网页 buildNavelMorph planeZ：肚脐周围 1–2.6cm 环上皮肤顶点的平均 z（相对肚脐）
func _compute_navel_plane() -> float:
	if _navel_plane_cache != null:
		return float(_navel_plane_cache)
	var nz := _navel_rest.z
	var sum := 0.0
	var cnt := 0
	for mi in skin_meshes:
		for si in mi.mesh.get_surface_count():
			var v: PackedVector3Array = mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			for p in v:
				if p.z < nz - 0.04:
					continue
				var r := Vector2(p.x - _navel_rest.x, p.y - _navel_rest.y).length()
				if r > 0.01 and r < 0.026:
					sum += p.z
					cnt += 1
	var pz := (sum / cnt - nz) if cnt > 6 else 0.006
	_navel_plane_cache = pz
	return pz


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
	if interact_mode == "navel":
		var hitn: Variant = ray_hit_belly(origin, dir)
		if hitn == null and _ray_point_dist(origin, dir, _frame.origin) > 0.15:
			return false
		# 网页：过肚脐、法线 = up × 相机方向 的竖直平面；沿身体 z 的拖动量 / 0.09 = 插入量变化
		var n := Vector3.UP.cross(cam_fwd)
		n = Vector3.RIGHT if n.length_squared() < 1e-6 else n.normalized()
		_tool_plane_n = n
		_tool_plane_p = _frame.origin
		var den0 := n.dot(dir)
		var o_w := _frame.origin
		if absf(den0) > 1e-5:
			var t0 := n.dot(_frame.origin - origin) / den0
			if t0 > 0.0:
				o_w = origin + dir * t0
		_navel_o = inv * o_w
		_navel_t0 = navel_insert
		_navel_grab = true
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
	elif interact_mode == "navel" and _navel_grab:
		navel_insert = clampf(_navel_t0 + (_navel_o.z - l.z) / 0.09, 0.0, 1.0)
		_navel_target = l


var _navel_target: Variant = null


func tool_end() -> void:
	_tool_grab = false
	_navel_grab = false
	_navel_target = null


func is_tool_grabbing() -> bool:
	return _tool_grab


## 测试 / HUD：直接设置深度（0..1）。拳交 = 伸入深度；刺刀 = 推入量（自动选默认入口）。
func tool_set_depth01(t: float) -> void:
	if interact_mode == "navel":
		navel_insert = clampf(t, 0.0, 1.0)
		return
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
	if interact_mode == "navel":
		return navel_insert
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
	elif interact_mode == "navel" and _ray_point_dist(origin, dir, _frame.origin) < 0.15:
		best = minf(best, (_frame.origin - origin).dot(dir))
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
	for k in ["navel_depth_ratio", "navel_thrust", "navel_stir", "navel_thrust_speed", "navel_thrust_start", "navel_stir_speed", "navel_stir_radius"]:
		set(k, o.get(k))
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

func _build_organ_aabbs() -> void:
	_gut_aabb = _aabb_from_meta("guts")
	_uterus_aabb = _aabb_from_meta("uterus")


func _aabb_from_meta(key: String) -> AABB:
	if not meta.has(key):
		return AABB()
	var d: Dictionary = meta[key]
	var mn: Array = d["min"]
	var mx: Array = d["max"]
	var a := Vector3(float(mn[0]), float(mn[1]), float(mn[2])) - _navel_rest
	var b := Vector3(float(mx[0]), float(mx[1]), float(mx[2])) - _navel_rest
	return AABB(a, b - a).grow(0.008)


func _seg_aabb(o: Vector3, d: Vector3, length: float, box: AABB) -> bool:
	if box.size == Vector3.ZERO:
		return false
	# 标准 slab
	var inv := Vector3(
		1.0 / d.x if absf(d.x) > 1e-8 else 1e16,
		1.0 / d.y if absf(d.y) > 1e-8 else 1e16,
		1.0 / d.z if absf(d.z) > 1e-8 else 1e16)
	var t0 := (box.position - o) * inv
	var t1 := (box.position + box.size - o) * inv
	var tmin := maxf(0.0, maxf(minf(t0.x, t1.x), maxf(minf(t0.y, t1.y), minf(t0.z, t1.z))))
	var tmax := minf(length, minf(maxf(t0.x, t1.x), minf(maxf(t0.y, t1.y), maxf(t0.z, t1.z))))
	return tmax >= tmin


## 查询弹道是否穿过腹部 / 肠道 / 子宫（不改状态）。origin、dir 为世界坐标。
func ballistic_query(origin: Vector3, dir: Vector3, par: Dictionary = {}) -> Dictionary:
	_update_frame()
	var d := dir.normalized()
	var inv := _frame.affine_inverse()
	var o_ab: Vector3 = inv * origin
	var d_ab: Vector3 = (inv.basis * d).normalized()
	var seg := _ray_ellipsoid_ab(o_ab, d_ab)
	var out := {
		"hit": false, "gut": false, "uterus": false, "overpen": false,
		"entry": null, "exit": null, "thickness": 0.0,
		"entry_ab": Vector3.ZERO, "exit_ab": Vector3.ZERO, "dir_ab": d_ab,
	}
	if seg.is_empty():
		# 没打中腹部椭球：仍报告未击中软组织（身体圆柱由弹道层判定）
		last_ballistic = out
		return out
	var t0: float = seg["t0"]
	var t1: float = seg["t1"]
	var entry_ab: Vector3 = o_ab + d_ab * t0
	var exit_ab: Vector3 = o_ab + d_ab * t1
	var thick := t1 - t0
	out["hit"] = true
	out["entry"] = _frame * entry_ab
	out["exit"] = _frame * exit_ab
	out["entry_ab"] = entry_ab
	out["exit_ab"] = exit_ab
	out["thickness"] = thick
	out["normal_in"] = (_frame.basis * _ellipsoid_normal(entry_ab)).normalized()
	out["normal_out"] = -(_frame.basis * _ellipsoid_normal(exit_ab)).normalized()
	var path_len := thick + 0.02
	out["gut"] = _seg_aabb(entry_ab, d_ab, path_len, _gut_aabb)
	out["uterus"] = _seg_aabb(entry_ab, d_ab, path_len, _uterus_aabb)
	# 贯穿：步枪更容易；手枪看体厚；霰弹丸通常留下
	var over := float(par.get("overpen", 0.4))
	var cat := str(par.get("category", ""))
	if cat == "shotgun":
		out["overpen"] = thick < 0.10 and over > 0.2
	else:
		out["overpen"] = over >= clampf(thick / 0.32, 0.25, 1.15)
	last_ballistic = out
	return out


func _ray_ellipsoid_ab(o: Vector3, d: Vector3) -> Dictionary:
	var on := (o - _ellipsoid_c) / _ellipsoid_r
	var dn := d / _ellipsoid_r
	var a := dn.dot(dn)
	var b := 2.0 * on.dot(dn)
	var c := on.dot(on) - 1.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0 or a < 1e-9:
		return {}
	var sq := sqrt(disc)
	var t0 := (-b - sq) / (2.0 * a)
	var t1 := (-b + sq) / (2.0 * a)
	if t1 < t0:
		var tmp := t0
		t0 = t1
		t1 = tmp
	if t1 < 0.0:
		return {}
	if t0 < 0.0:
		t0 = 0.0
	return {"t0": t0, "t1": t1}


func _ellipsoid_normal(p_ab: Vector3) -> Vector3:
	var q := (p_ab - _ellipsoid_c) / _ellipsoid_r
	return (q / _ellipsoid_r).normalized()


## 施加第一层弹道毁伤：创口贴花、通道、冲击波、肠道/子宫发红与撕裂。
func apply_ballistic_hit(origin: Vector3, dir: Vector3, par: Dictionary = {}, pre: Dictionary = {}) -> Dictionary:
	var info: Dictionary = pre if not pre.is_empty() else ballistic_query(origin, dir, par)
	if not bool(info.get("hit", false)):
		# 打在身上但不在腹部：仍给一次弱冲击（若有世界命中点）
		if origin != Vector3.ZERO:
			strike_at(origin, clampf(float(par.get("impulse", 0.3)) * 0.45, 0.12, 0.4), 0.16)
		last_ballistic = info
		return info
	var energy := float(par.get("energy", 0.5))
	var impulse := float(par.get("impulse", 0.5))
	var entry_ab: Vector3 = info["entry_ab"]
	var exit_ab: Vector3 = info["exit_ab"]
	var d_ab: Vector3 = info["dir_ab"]
	var thick: float = info["thickness"]
	var rad := clampf(0.0045 + energy * 0.007, 0.005, 0.014)
	var wsize := clampf(0.012 + energy * 0.018, 0.014, 0.032)
	var n_in: Vector3 = info.get("normal_in", -d_ab)
	tools.add_wound(entry_ab, n_in, wsize, wsize * 1.15, d_ab)
	if bool(info.get("overpen", false)):
		var n_out: Vector3 = info.get("normal_out", d_ab)
		tools.add_wound(exit_ab, n_out, wsize * 1.15, wsize * 1.3, d_ab)
	_ball_ch.append({"a": entry_ab, "d": d_ab, "len": thick, "rad": rad})
	while _ball_ch.size() > BALL_MAX:
		_ball_ch.pop_front()
	strike_at(info["entry"], clampf(impulse, 0.16, 1.0), clampf(0.14 + impulse * 0.16, 0.14, 0.36))
	# 沿通道再推一下脏器（步枪更明显）
	if bool(info.get("gut", false)) or bool(info.get("uterus", false)):
		var mid: Vector3 = info["entry"].lerp(info["exit"], 0.5)
		strike_at(mid, clampf(impulse * 0.7, 0.14, 0.85), clampf(0.1 + impulse * 0.1, 0.1, 0.28))
		var dmg := clampf(0.28 + energy * 0.55, 0.3, 1.0)
		var steps := maxi(2, int(thick / 0.03))
		for i in steps + 1:
			var t := float(i) / float(steps)
			var p: Vector3 = entry_ab.lerp(exit_ab, t)
			var hit_o := (bool(info["gut"]) and _gut_aabb.grow(0.01).has_point(p)) or (bool(info["uterus"]) and _uterus_aabb.grow(0.01).has_point(p))
			if hit_o:
				tools.add_damage(p, dmg)
	last_ballistic = info
	return info


func reset_interaction() -> void:
	_drag_active = false
	_drag_off = Vector3.ZERO
	_drag_vel = Vector3.ZERO
	_waves.clear()
	_tool_grab = false
	tools.fist_reset()
	tools.release_entry()
	tools.clear_marks()
	_ball_ch.clear()
	last_ballistic = {}
	_reset_fist_soft(true)
	gut_health = 0.0
	navel_insert = 0.0
	navel_live = 0.0
	_navel_grab = false


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
		"navel_insert": navel_insert,
		"navel_live": navel_live,
		"navel_plane_z": _navel_plane_z,
		"fist_colon_open": _rod_tip_s + (0.01 if _rod_reach_s > 0.02 else 0.0),
		"fist_uterus_off": _uter_off.length(),
	}


# ------------------------------------------------------------------ frame
func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if not ready_ok:
		return
	var dt := minf(delta, 0.05)
	if frozen:
		for mi in organ_meshes:
			mi.visible = show_organs
		_update_frame()
		_push_uniforms()
		_update_fx()
		_update_props()
		return
	_time += dt
	for w in _waves:
		w["t"] = float(w["t"]) + dt
	_waves = _waves.filter(func(w): return float(w["t"]) < STRIKE_LIFE)
	_gut_exc += (0.0 - _gut_exc) * (1.0 - exp(-0.42 * dt))
	var s_eff := clampf(gut_speed * (1.0 + _gut_exc * 0.3), 0.0, 1.0)
	_peri_clock += Vector3(0.03 + s_eff * 0.2, 0.45 + s_eff * 0.9, 0.25 + s_eff * 0.5) * dt
	_step_drag(dt)
	_step_tools(dt)
	_step_navel(dt)
	for mi in organ_meshes:
		mi.visible = show_organs
	_update_frame()
	_push_uniforms()
	_update_fx()
	_update_props()


## 网页 figure.tsx 每帧肚脐段：自动抽插（thrust）/ 搅动（stir）
func _step_navel(dt: float) -> void:
	var play := interact_mode == "navel"
	var t := navel_insert
	var sx := 0.0
	var sy := 0.0
	if play and not _navel_grab:
		if navel_thrust:
			if not _navel_thrust_on:
				_navel_thrust_phase = PI
			_navel_thrust_on = true
			_navel_thrust_phase += dt * (0.55 + navel_thrust_speed * 2.2)
			var wave := 0.5 - 0.5 * cos(_navel_thrust_phase)
			var start := clampf(navel_thrust_start, 0.0, 0.98)
			var deep := t if t > start + 0.04 else 1.0
			t = start + (deep - start) * wave
		else:
			_navel_thrust_on = false
		if navel_stir:
			_navel_stir_phase += dt * (0.45 + navel_stir_speed * 2.5)
			var u0: float = navel_insert_morph(t, navel_depth_ratio)["u"]
			var r := (0.004 + navel_stir_radius * 0.014) * u0
			sx = cos(_navel_stir_phase) * r
			sy = sin(_navel_stir_phase) * r
		else:
			_navel_stir_phase = 0.0
	elif not play:
		_navel_thrust_phase = 0.0
		_navel_stir_phase = 0.0
	navel_live = t if play else 0.0
	navel_stir_off = Vector2(sx, sy)
	if secondary != null and play and navel_live > NAVEL_CONTACT_T:
		var u1: float = navel_insert_morph(navel_live, navel_depth_ratio)["u"]
		secondary.set("breath_boost", maxf(float(secondary.get("breath_boost")), u1 * 0.4))


func _step_tools(dt: float) -> void:
	tools.fist_step(dt)
	var gut := clampf(tools.fist_gut, 0.0, 2.0)
	tools.blade_step(dt, _tool_grab, gut)
	_step_fist_soft(dt)
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



func _reset_fist_soft(snap: bool = true) -> void:
	_rod_reach_s = 0.0
	_rod_tip_s = 0.0
	_rod_shaft_s = 0.0
	_rod_mix_s = 0.0
	_uter_off = Vector3.ZERO
	_uter_off_v = Vector3.ZERO
	_uter_tilt = 0.0
	_uter_tilt_v = 0.0
	_uter_sq = 0.0
	_uter_sq_v = 0.0
	_uter_press = 0.0
	_fist_depth_vel = 0.0
	_fist_depth_prev = tools.fist_depth if tools else 0.0
	if snap:
		pass


func _fist_rod_smoothed() -> Array:
	if _rod_reach_s <= 0.02:
		return []
	var d := _rod_dir_s
	if d.length_squared() < 1e-8:
		d = tools.fist_dir
	return [tools.anus, d.normalized(), _rod_reach_s, _rod_tip_s, _rod_mix_s, 0.0, _rod_shaft_s]


func _ellip_r(he: Vector3, n: Vector3) -> float:
	var q := Vector3(n.x / maxf(he.x, 1e-4), n.y / maxf(he.y, 1e-4), n.z / maxf(he.z, 1e-4))
	return 1.0 / maxf(q.length(), 1e-4)


func _step_fist_soft(dt: float) -> void:
	var dnow := tools.fist_depth if tools.fist_enabled else 0.0
	var raw_v := (dnow - _fist_depth_prev) / maxf(dt, 1e-4)
	_fist_depth_vel += (raw_v - _fist_depth_vel) * (1.0 - exp(-18.0 * dt))
	_fist_depth_prev = dnow
	var tgt_reach := 0.0
	var tgt_dir := _rod_dir_s if _rod_dir_s.length_squared() > 1e-8 else tools.fist_dir
	var tgt_tip := 0.0
	var tgt_shaft := 0.0
	var tgt_mix := 0.0
	var rod: Array = tools.fist_rod()
	if not rod.is_empty():
		tgt_dir = (rod[1] as Vector3).normalized()
		tgt_reach = float(rod[2])
		tgt_tip = float(rod[3])
		tgt_mix = float(rod[4])
		tgt_shaft = float(rod[6]) if rod.size() > 6 else tgt_tip
	var k := 70.0
	var fade := 1.0 - exp(-k * dt)
	_rod_reach_s = lerpf(_rod_reach_s, tgt_reach, fade)
	_rod_tip_s = lerpf(_rod_tip_s, tgt_tip, fade)
	_rod_shaft_s = lerpf(_rod_shaft_s, tgt_shaft, fade)
	_rod_mix_s = lerpf(_rod_mix_s, tgt_mix, fade)
	if tgt_dir.length_squared() > 1e-8:
		var nd := _rod_dir_s.lerp(tgt_dir, fade * 0.85)
		if nd.length_squared() > 1e-8:
			_rod_dir_s = nd.normalized()
	var tgt_off := Vector3.ZERO
	var tgt_tilt := 0.0
	var tgt_tilt_ax := _uter_tilt_ax
	var tgt_sq := 0.0
	var tgt_sq_ax := _uter_sq_ax
	_uter_press = 0.0
	if tools.fist_enabled and tgt_reach > 0.02 and _uterus_aabb.size.length() > 1e-4:
		var a: Vector3 = tools.anus
		var d: Vector3 = tgt_dir
		var uc := _uterus_aabb.get_center()
		var he := _uterus_aabb.size * 0.5
		var s := clampf((uc - a).dot(d), 0.0, tgt_reach + 0.02)
		var c := a + d * s
		var delta := uc - c
		var ln := delta.length()
		var n := delta / maxf(ln, 1e-6)
		var r_org := _ellip_r(he, n)
		var tt := clampf(s / maxf(tgt_reach, 1e-4), 0.0, 1.0)
		var rad := lerpf(tgt_shaft, tgt_tip, tt)
		var clearance := ln - r_org - rad
		if clearance < 0.02:
			var press := 0.02 - clearance
			var past := clampf((tgt_reach - s) / 0.18, 0.0, 1.0)
			press *= 0.75 + 0.45 * past
			press *= 1.0 + clampf(absf(_fist_depth_vel) * 1.2, 0.0, 0.4)
			var gut := clampf(tools.fist_gut, 0.0, 2.0)
			tgt_off = n * press * (0.62 + 0.28 * gut)
			if tgt_off.length() > 0.05:
				tgt_off = tgt_off.normalized() * 0.05
			var tax := d.cross(n)
			if tax.length_squared() < 1e-8:
				tax = Vector3.RIGHT
			tgt_tilt_ax = tax.normalized()
			tgt_tilt = clampf(press * 8.5, 0.0, 0.42)
			tgt_sq_ax = n
			tgt_sq = clampf(press / maxf(0.035, he.length()), 0.0, 0.38)
			_uter_press = press
	var uk := 55.0
	var uz := 0.82
	var cd := 2.0 * sqrt(uk) * uz
	var nsub := 3
	var h := dt / float(nsub)
	for _i in nsub:
		var acc := (tgt_off - _uter_off) * uk - _uter_off_v * cd
		_uter_off_v += acc * h
		_uter_off += _uter_off_v * h
		_uter_tilt_v += ((tgt_tilt - _uter_tilt) * uk - _uter_tilt_v * cd) * h
		_uter_tilt += _uter_tilt_v * h
		_uter_sq_v += ((tgt_sq - _uter_sq) * uk - _uter_sq_v * cd) * h
		_uter_sq += _uter_sq_v * h
	var uf := 1.0 - exp(-uk * 0.4 * dt)
	if tgt_tilt_ax.length_squared() > 1e-8:
		var ax := _uter_tilt_ax.lerp(tgt_tilt_ax, uf)
		if ax.length_squared() > 1e-8:
			_uter_tilt_ax = ax.normalized()
	if tgt_sq_ax.length_squared() > 1e-8:
		var sax := _uter_sq_ax.lerp(tgt_sq_ax, uf)
		if sax.length_squared() > 1e-8:
			_uter_sq_ax = sax.normalized()
	if tgt_reach <= 0.02 and _uter_off.length() < 2e-4 and absf(_uter_tilt) < 1e-4:
		_uter_off = Vector3.ZERO
		_uter_off_v = Vector3.ZERO
		_uter_tilt = 0.0
		_uter_tilt_v = 0.0
		_uter_sq = 0.0
		_uter_sq_v = 0.0


## 自检 / 对照网页公式：当前杆半径、通道长度、子宫位移。
func fist_deform_debug() -> Dictionary:
	var web := float(tools.call("fist_rod_web_radius"))
	var phys: Vector2 = tools.call("fist_physical_radii")
	var rod: Array = tools.fist_rod()
	return {
		"enabled": tools.fist_enabled,
		"depth": tools.fist_depth,
		"gut": tools.fist_gut,
		"web_rad": web,
		"web_mix": float(tools.call("fist_rod_mix")),
		"tip_rad": phys.x,
		"shaft_rad": phys.y,
		"reach": float(rod[2]) if not rod.is_empty() else 0.0,
		"rod_reach_s": _rod_reach_s,
		"rod_tip_s": _rod_tip_s,
		"colon_open": (_rod_tip_s + 0.01) if _rod_reach_s > 0.02 else 0.0,
		"uterus_off": _uter_off.length(),
		"uterus_off_vec": _uter_off,
		"uterus_press": _uter_press,
		"uterus_tilt": _uter_tilt,
		"uterus_sq": _uter_sq,
		"fist_speed": _fist_depth_vel,
		"dir": _rod_dir_s,
	}


func _skel_world_xf() -> Transform3D:
	# 真机上 get_global_transform_interpolated() 偶发停在旧位置或接近单位矩阵，
	# 透视窗口就会钉在世界某个固定点、不跟人物走。离当前变换过远时改用即时变换。
	var live := _skel.global_transform
	var itp := _skel.get_global_transform_interpolated()
	if itp.origin.distance_squared_to(live.origin) > 0.25:
		return live
	return itp


func _update_frame() -> void:
	if _skel == null or _spine_i < 0:
		return
	# 用插值后的骨架变换：物理插值开启时与渲染出的皮肤一致（透视窗口 / 互动不抖）
	var m := _skel_world_xf() * _skel.get_bone_global_pose(_spine_i) * _skel.get_bone_global_rest(_spine_i).affine_inverse()
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
		var ba: Array = []
		var bb: Array = []
		for i in BALL_MAX:
			if i < _ball_ch.size():
				var ch: Dictionary = _ball_ch[i]
				var a: Vector3 = ch["a"]
				var d: Vector3 = ch["d"]
				ba.append(Vector4(a.x, a.y, a.z, float(ch["rad"])))
				bb.append(Vector4(d.x, d.y, d.z, float(ch["len"])))
			else:
				ba.append(Vector4.ZERO)
				bb.append(Vector4.ZERO)
		m.set_shader_parameter("ball_a", ba)
		m.set_shader_parameter("ball_b", bb)
	var sq := tools.squeeze_target()
	for m in _all_mats:
		if sq.is_empty():
			m.set_shader_parameter("dent", Vector4.ZERO)
		else:
			var g0: Vector3 = sq[0]
			m.set_shader_parameter("dent", Vector4(g0.x, g0.y, g0.z, float(sq[2])))
			m.set_shader_parameter("dent_off", (sq[1] as Vector3) - g0)
	var nm := navel_insert_morph(navel_live, navel_depth_ratio)
	var nu: float = nm["u"]
	if interact_mode == "navel" and nu > 0.04:
		for m in _all_mats:
			m.set_shader_parameter("dent", Vector4(0, 0, 0, 0.036))
			m.set_shader_parameter("dent_off", Vector3(navel_stir_off.x, navel_stir_off.y - 0.003 * nu, -0.028 * nu))
	var n_on := interact_mode == "navel"
	var dia := clampf(float(nm["diameter"]), 0.0, 2.2)
	var nhx := 0.0027 + dia * 0.0078
	var nhy := 0.0051 + dia * 0.0135
	var nD := clampf(float(nm["depth"]), 0.0, 1.0) * 0.092
	var ncap := minf(nhy * 0.85, nD * 0.38)
	for m in _skin_mats:
		m.set_shader_parameter("navel_on", 1.0 if n_on else 0.0)
		m.set_shader_parameter("navel_m", Vector4(nhx, nhy, nD, ncap))
		m.set_shader_parameter("navel_s", Vector2(clampf(float(nm["squeeze"]), 0.0, 1.0), _navel_plane_z))
	var fb := tools.fist_bulge_params()
	var fpar := Vector4(tools.fist_bulge, tools.fist_spread, tools.fist_rise, tools.fist_lever)
	for m in _skin_mats:
		m.set_shader_parameter("xray", xr)
		m.set_shader_parameter("xray_sphere_ab", _xray_sphere_ab)
		m.set_shader_parameter("xray_sphere_r", _xray_sphere_r)
		m.set_shader_parameter("xray_sphere_k", _xray_sphere_k)
		m.set_shader_parameter("hole_center", _hole_c)
		m.set_shader_parameter("hole_radius", _hole_r)
		m.set_shader_parameter("fist_bulge", fb[0])
		m.set_shader_parameter("fist_lean", fb[1])
		m.set_shader_parameter("fist_par", fpar)
	var fist_on := tools != null and bool(tools.fist_enabled) and float(tools.fist_depth) > 0.01
	for m in _organ_mats:
		m.set_shader_parameter("organ_contain", 1 if fist_on else 0)
		m.set_shader_parameter("fist_bulge", fb[0])
		m.set_shader_parameter("fist_lean", fb[1])
		m.set_shader_parameter("fist_par", fpar)
		m.set_shader_parameter("contain_margin", 0.008)
	var ra: Array = []
	var rd: Array = []
	var rm: Array = []
	for r in [_fist_rod_smoothed(), tools.blade_rod(clampf(tools.fist_gut, 0.0, 2.0))]:
		if r.is_empty():
			ra.append(Vector4(0, 0, 0, -1))
			rd.append(Vector4(0, 0, 1, 0))
			rm.append(Vector4.ZERO)
		else:
			var a: Vector3 = r[0]
			var d: Vector3 = r[1]
			var shaft := float(r[6]) if r.size() > 6 else 0.0
			ra.append(Vector4(a.x, a.y, a.z, float(r[2])))
			rd.append(Vector4(d.x, d.y, d.z, float(r[3])))
			rm.append(Vector4(float(r[4]), float(r[5]), shaft, 0))
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
		m.set_shader_parameter("uter_pivot", _uterus_aabb.get_center() + Vector3(0, -_uterus_aabb.size.y * 0.28, 0))
		m.set_shader_parameter("uter_off", _uter_off)
		m.set_shader_parameter("uter_rot", Vector4(_uter_tilt_ax.x, _uter_tilt_ax.y, _uter_tilt_ax.z, _uter_tilt))
		m.set_shader_parameter("uter_sq", Vector4(_uter_sq_ax.x, _uter_sq_ax.y, _uter_sq_ax.z, _uter_sq))
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
	if _prof_tex == null:
		_prof_tex = ImageTexture.new()
	# 先收集带符号的剖面，再编码进全平台都支持的 RGBA8（0..1），用 bias/scale 还原。
	var raw: Array[Color] = []
	var mn := Vector4(INF, INF, INF, INF)
	var mx := Vector4(-INF, -INF, -INF, -INF)
	for i in 24:
		var j := mini(i, cnt - 1)
		var c := Color(
			float(ys[j]) - _navel_rest.y,
			float(prof["half_x"][j]),
			float(prof["z_front"][j]) - _navel_rest.z,
			float(prof["z_back"][j]) - _navel_rest.z
		)
		raw.append(c)
		mn = Vector4(minf(mn.x, c.r), minf(mn.y, c.g), minf(mn.z, c.b), minf(mn.w, c.a))
		mx = Vector4(maxf(mx.x, c.r), maxf(mx.y, c.g), maxf(mx.z, c.b), maxf(mx.w, c.a))
	var bias := Vector4(mn.x - 0.02, mn.y - 0.02, mn.z - 0.02, mn.w - 0.02)
	var scale := Vector4(
		maxf(0.04, mx.x - bias.x + 0.02),
		maxf(0.04, mx.y - bias.y + 0.02),
		maxf(0.04, mx.z - bias.z + 0.02),
		maxf(0.04, mx.w - bias.w + 0.02)
	)
	var img := Image.create(24, 1, false, Image.FORMAT_RGBA8)
	for i in 24:
		var c: Color = raw[i]
		img.set_pixel(i, 0, Color(
			clampf((c.r - bias.x) / scale.x, 0.0, 1.0),
			clampf((c.g - bias.y) / scale.y, 0.0, 1.0),
			clampf((c.b - bias.z) / scale.z, 0.0, 1.0),
			clampf((c.a - bias.w) / scale.w, 0.0, 1.0)
		))
	_prof_tex.set_image(img)
	m.set_shader_parameter("prof_n", cnt)
	m.set_shader_parameter("prof_tex", _prof_tex)
	m.set_shader_parameter("prof_bias", Vector4(bias.x, bias.y, bias.z, bias.w))
	m.set_shader_parameter("prof_scale", Vector4(scale.x, scale.y, scale.z, scale.w))
	m.set_shader_parameter("hole_center", _hole_c)
	m.set_shader_parameter("hole_radius", _hole_r)


## 校验：透视窗口中心（肚脐附近前腹壁）投影应落在腹部网格上，而不是旁边。
func debug_profile_tex() -> Dictionary:
	var out := {"ok": false, "format": -1, "n": 0, "roundtrip": 99.0}
	if _prof_tex == null or not meta.has("profile"):
		return out
	var img := _prof_tex.get_image()
	if img == null:
		return out
	out["format"] = int(img.get_format())
	out["n"] = mini((meta["profile"]["y"] as Array).size(), 24)
	# RGBA8 才算移动端安全；RGBAF/RH 在许多真机上不可用
	out["ok"] = img.get_format() == Image.FORMAT_RGBA8 and img.get_width() == 24
	return out


func debug_window_on_belly(cam: Camera3D) -> Dictionary:
	_update_frame()
	var out := {"ok": false, "navel": _frame.origin, "window": Vector3.ZERO, "screen": Vector2.ZERO, "navel_screen": Vector2.ZERO, "dist": 99.0, "px": 999.0}
	if cam == null:
		return out
	var xd: Dictionary = meta.get("xray", {})
	var y0 := float(xd.get("y0", -0.2))
	var y1 := float(xd.get("y1", 0.145))
	var local := Vector3(0.0, 0.5 * (y0 + y1), 0.02)
	var world: Vector3 = _frame * local
	out["window"] = world
	out["navel"] = _frame.origin
	# 窗口中心必须就在肚脐附近（腹局部，不是碰撞胶囊侧面）
	var lateral: Vector3 = world - _frame.origin
	lateral -= _frame.basis.y * lateral.dot(_frame.basis.y)
	out["dist"] = lateral.length()
	if cam.is_position_behind(world) or cam.is_position_behind(_frame.origin):
		out["ok"] = out["dist"] < 0.12
		return out
	out["screen"] = cam.unproject_position(world)
	out["navel_screen"] = cam.unproject_position(_frame.origin)
	out["px"] = out["screen"].distance_to(out["navel_screen"])
	# 物理胶囊半径约 30cm，不能用来判断窗口是否偏到腰侧。用腹局部距离 + 屏幕投影。
	out["ok"] = out["dist"] < 0.12 and out["px"] < 90.0
	return out


func debug_skin_xray_state() -> Dictionary:
	## 真机排障：当前皮肤是否真的是 skin_xray，以及椭球开孔参数是否非零。
	var out := {"shader": "", "fade": "", "xray": 0.0, "hole_c": Vector3.ZERO, "hole_r": Vector3.ZERO, "prof_n": 0, "mats": 0, "analytic": 0.0, "ok": false}
	out["xray"] = effective_xray()
	out["hole_c"] = _hole_c
	out["hole_r"] = _hole_r
	out["mats"] = _skin_mats.size()
	if _skin_mats.size() > 0:
		var m: ShaderMaterial = _skin_mats[0]
		var sh: Shader = m.shader
		out["shader"] = sh.resource_path if sh else ""
		out["xray"] = float(m.get_shader_parameter("xray"))
		var hc = m.get_shader_parameter("hole_center")
		var hr = m.get_shader_parameter("hole_radius")
		if hc is Vector3:
			out["hole_c"] = hc
		if hr is Vector3:
			out["hole_r"] = hr
		out["prof_n"] = int(m.get_shader_parameter("prof_n"))
		if m.next_pass is ShaderMaterial and (m.next_pass as ShaderMaterial).shader:
			out["fade"] = (m.next_pass as ShaderMaterial).shader.resource_path
	var belly := Vector3(0.0, -0.02, 0.03)
	out["analytic"] = debug_xray_hole(belly)
	out["ok"] = out["shader"].ends_with("skin_xray.gdshader") and float(out["xray"]) > 0.05 and float(out["analytic"]) > 0.07 and (out["hole_r"] as Vector3).length() > 0.05
	return out


func debug_xray_hole(l: Vector3, xr: float = -1.0) -> float:
	var x := effective_xray() if xr < 0.0 else xr
	return clampf(maxf(_debug_hole_profile(l), _debug_hole_analytic(l)) * x, 0.0, 1.0)


func debug_xray_hole_analytic_only(l: Vector3, xr: float = -1.0) -> float:
	var x := effective_xray() if xr < 0.0 else xr
	return clampf(_debug_hole_analytic(l) * x, 0.0, 1.0)


func _debug_hole_analytic(l: Vector3) -> float:
	var c := _hole_c
	var r := _hole_r
	var q := Vector3(
		(l.x - c.x) / maxf(0.02, r.x),
		(l.y - c.y) / maxf(0.02, r.y),
		(l.z - c.z) / maxf(0.02, r.z)
	)
	var ell := 1.0 - smoothstep(0.72, 1.05, q.length())
	var xd: Dictionary = meta.get("xray", {})
	var y0 := float(xd.get("y0", -0.2))
	var y1 := float(xd.get("y1", 0.145))
	var zf0 := float(xd.get("z_front", -0.01))
	var band := smoothstep(y0, y0 + 0.08, l.y) * (1.0 - smoothstep(y1 - 0.04, y1, l.y))
	var front := smoothstep(zf0 - 0.16, zf0 + 0.04, l.z)
	var mid := 1.0 - smoothstep(0.11, 0.16, absf(l.x))
	return clampf(ell * band * front * mid, 0.0, 1.0)


func _debug_hole_profile(l: Vector3) -> float:
	var xd: Dictionary = meta.get("xray", {})
	var y0 := float(xd.get("y0", -0.2))
	var y1 := float(xd.get("y1", 0.145))
	var xmax := float(xd.get("x_max", 0.12))
	var zf0 := float(xd.get("z_front", -0.01))
	var pr := _profile_at(l.y)
	if pr.x < 0.02:
		return 0.0
	var band := smoothstep(y0, y0 + 0.08, l.y) * (1.0 - smoothstep(y1 - 0.04, y1, l.y))
	var w_out := minf(xmax + 0.1, pr.x - 0.015)
	var w_in := minf(xmax * 0.65, w_out - 0.045)
	var torso := 1.0 - smoothstep(w_in, w_out, absf(l.x))
	var front := smoothstep(zf0 - 0.16, zf0 + 0.04, l.z)
	var zmid := 0.5 * (pr.y + pr.z)
	front *= smoothstep(zmid, zmid + 0.035, l.z)
	return clampf(band * torso * front, 0.0, 1.0)


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
		var is_uter := false
		if not is_gut and _uterus_aabb.size.length() > 1e-4:
			var va0: PackedVector3Array = e["mesh"].surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var mn := Vector3(INF, INF, INF)
			var mx := Vector3(-INF, -INF, -INF)
			for p in va0:
				var l: Vector3 = p - _navel_rest
				mn = mn.min(l)
				mx = mx.max(l)
			var ov := AABB(mn, mx - mn).intersection(_uterus_aabb)
			is_uter = ov.has_volume() and ov.get_volume() > 8.0e-5
		mat.set_shader_parameter("is_uterus", is_uter)
		_organ_mats.append(mat)
		_all_mats.append(mat)

		var mi := MeshInstance3D.new()
		mi.name = ("Gut_" if is_gut else "Pelvis_") + mname.validate_node_name().replace(" ", "_")
		mi.mesh = e["mesh"]
		mi.material_override = mat
		mi.skin = skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 1 | ORGAN_LIGHT_LAYER
		mi.extra_cull_margin = 0.5
		mi.set_meta("organ_group", "gut" if is_gut else "pelvis")
		mi.set_meta("organ_material", matname)
		mi.set_meta("is_uterus", bool(mat.get_shader_parameter("is_uterus")))
		_skel.add_child(mi)
		mi.skeleton = mi.get_path_to(_skel)
		organ_meshes.append(mi)
		_set_profile_params(mat)
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
	if _navel_target != null and interact_mode == "navel":
		_poke.global_transform = Transform3D(b * Basis.from_scale(Vector3(0.012, 0.012, 1.0)), _frame * (_navel_target as Vector3))
		_poke.visible = true
	elif _drag_active:
		var tp := _frame * (_drag_grab + _drag_off + Vector3(0, 0, 0.01))
		_poke.global_transform = Transform3D(b * Basis.from_scale(Vector3(0.036, 0.036, 1.0)), tp)
		_poke.visible = true
	else:
		_poke.visible = false
