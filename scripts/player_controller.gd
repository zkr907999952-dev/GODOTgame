extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
const OrganRigScript = preload("res://scripts/organs/organ_rig.gd")
const CharacterLookScript = preload("res://scripts/character_look.gd")
const WeaponSystemScript = preload("res://scripts/weapons/weapon_system.gd")
## 角色控制器：展示互动 / 角色控制 双模式 + SoftLoco 网页 loco 动画驱动 Skeleton3D。
## Web loco bind: mesh faces +Z; Godot move uses -Z forward → visual Body needs π yaw offset.
const BODY_YAW_OFFSET := PI

enum GameMode { DISPLAY, CONTROL }

@export var move_speed: float = 1.65
@export var sprint_speed: float = 4.125  # 1.65 * 2.5 like web
@export var crouch_speed: float = 0.7425  # 1.65 * 0.45
@export var prone_speed: float = 0.462  # 1.65 * 0.28
## 网页 FP_GRAV=20（比 Godot 默认 9.8 更干脆）；跳高保持约 0.9m（6²/(2·20)）。
@export var jump_velocity: float = 6.0
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch: float = -1.55  # ≈ ±89° like web FP_PITCH_LIM
@export var max_pitch: float = 1.55
@export var camera_distance: float = 2.8
@export var camera_height: float = 1.4
@export var first_person: bool = false
## 默认展示互动：第三人称、锁移动、注视相机。Tab / HUD 切换到角色控制（第一人称可移动）。
@export var play_mode: GameMode = GameMode.DISPLAY
@export var fp_eye_height: float = 1.52  # web stand stanceEye.y
@export var fp_fov: float = 62.0
@export var tp_fov: float = 34.0  # 网页 ORBIT_HOME fov 34
@export var camera_distance_min: float = 0.2  # 网页 OrbitControls minDistance 0.12（近裁面原因略放大）
@export var camera_distance_max: float = 6.2  # 网页 maxDistance 6.2
@export var fp_fov_min: float = 50.0
@export var fp_fov_max: float = 90.0

var _yaw: float = 0.0
var _pitch: float = -0.15
var _default_yaw: float = 0.0
var _default_pitch: float = -0.15
var _default_cam_dist: float = 2.8
var _default_cam_height: float = 1.4
var _default_fp_fov: float = 62.0
var _default_tp_fov: float = 34.0

## ---- 观察视角（展示互动 / 第三人称）摄像机：移植网页 OrbitControls ----
## 右键拖 = 环绕；中键拖（或 Shift/Ctrl+右键拖）= 平移目标；滚轮 = 推拉；左键留给腹部互动。
## 阻尼 0.08/帧（≈5/s），俯仰极角 0.08π…0.9π，距离 0.2…6.2，自动旋转 0.45。
const TP_DAMP_RATE := 5.0
const TP_ELEV_MAX := PI * 0.42   # polar 0.08π
const TP_ELEV_MIN := -PI * 0.40  # polar 0.9π
const TP_HOME_DIST := 2.27       # 网页 ORBIT_HOME：相机 (0.28,1.18,2.35) → 目标 (0,1.06,0.1)
const TP_HOME_YAW_OFF := 0.124   # atan(0.28/2.25)
const TP_HOME_ELEV := 0.053
const TP_COLLIDE_RADIUS := 0.12
## 视觉中心（网页 CAM_FOCUS：面部/胸部/腹部/阴部）：骨骼 + 前移 + 距离
const TP_FOCUS := {
	"face": {"bone": "C_Head_a", "fwd": 0.07, "up": 0.04, "dist": 0.72},
	"chest": {"bone": "C_Spine_d", "fwd": 0.09, "up": 0.0, "dist": 0.88},
	"belly": {"bone": "navel", "fwd": -0.01, "up": 0.0, "dist": 1.08},
	"groin": {"bone": "C_Hip_a", "fwd": 0.06, "up": -0.04, "dist": 0.92},
}
var tp_auto_rotate: bool = false
var tp_auto_rotate_speed: float = 0.45
## 目标/当前（平滑）环绕状态。target 为相对角色位置的世界偏移。
var _tp_yaw_goal: float = 0.0
var _tp_elev_goal: float = 0.0
var _tp_dist_goal: float = 2.27
var _tp_target_goal: Vector3 = Vector3(0.0, 1.06, 0.0)
var _tp_yaw: float = 0.0
var _tp_elev: float = 0.0
var _tp_dist: float = 2.27
var _tp_target: Vector3 = Vector3(0.0, 1.06, 0.0)
var _tp_dist_eff: float = 2.27
var _tp_focus: String = ""
var _tp_presets: Array = [null, null, null, null]
var _rmb_down: bool = false
var _mmb_down: bool = false
var _pan_drag: bool = false
## 房间墙内包围盒（由 game_root 设置；城市里为空 → 只做物理碰撞）
var camera_bounds: AABB = AABB()
var _cam_shape: SphereShape3D
## 网页 FP 移动手感（scene.tsx）：加速度 / 摩擦 / 空中加速 / 台阶 / 土狼时间 / 跳跃缓冲
const FP_ACCEL := 12.0
const FP_AIR_ACCEL := 3.4
const FP_FRICTION := 6.4
const FP_MAX_FALL := 58.0
const STEP_HEIGHT := 0.3
const COYOTE_TIME := 0.14
const JUMP_BUFFER := 0.14
var _coyote: float = 0.0
var _jump_buf: float = 0.0
## 台阶上抬后相机眼位平滑（避免瞬间跳一格）
var _step_smooth: float = 0.0
## 俯视地图打开时锁定一切输入（game_root 设置）
var input_locked: bool = false
## CameraPivot 是 top_level：每帧用「插值后的」角色位置 + 偏移摆放（物理插值下相机不抖）
var _pivot_off: Vector3 = Vector3(0.0, 1.4, 0.0)
var _pivot_rot: Vector3 = Vector3.ZERO
var _loco: Node
## 体内脏器 + 腹部透视 + 拖拽/击腹互动（scripts/organs/organ_rig.gd）
var _organs: Node
## 武器模块（scripts/weapons/weapon_system.gd）
var _weapons: Node
var _interact_held: bool = false
var _interact_screen: Vector2 = Vector2.ZERO
var _stance: String = "stand" # stand | crouch | prone
## Capsule bottom ≈ 0 so soles (mesh AABB min.y ≈ 0) sit on the floor.
var _capsule_stand_h: float = 1.1
var _capsule_stand_y: float = 0.55
var _air_time: float = 0.0
## When true, HUD has a panel open — do not auto-capture mouse on click / ignore wheel zoom.
var ui_blocks_capture: bool = false
## Web stanceEye (body-local +Z forward). Stable — no head-nod / walk bob.
const FP_EYE_STAND := Vector3(0.0, 1.52, 0.2)
const FP_EYE_CROUCH := Vector3(0.0, 1.06, 0.5)
const FP_EYE_PRONE := Vector3(0.0, 0.3, 0.74)
## Extra lift if mesh still clips the near plane.
const FP_EYE_LIFT := 0.06
## Web BODY_LOOK_DEAD = π/3: body stays until look diverges ~60° (≈120° total free look), then catches up.
const BODY_LOOK_DEAD := PI / 3.0
## Stand↔crouch (and stance eye/capsule) blend duration — web STANCE_BLEND_DUR.
const STANCE_BLEND_DUR := 0.7
## 第一人称眼位过渡（比身体姿态快，避免下蹲/起身时视点落进脖子）。
const FP_EYE_BLEND_DUR := 0.3
var _fp_eye_from: Vector3 = FP_EYE_STAND
var _fp_eye_to: Vector3 = FP_EYE_STAND
var _fp_eye_blend: float = 1.0  # 0..1 smoothstep like web stanceU
var _fp_eye_cur: Vector3 = FP_EYE_STAND
## FP body yaw in camera/logic space (without BODY_YAW_OFFSET). Lag behind look when idle.
var _body_logic_yaw: float = 0.0
## Capsule / TP camera height stance blend.
var _stance_blend: float = 1.0
var _cap_h_from: float = 1.1
var _cap_h_to: float = 1.1
var _cap_r_from: float = 0.3
var _cap_r_to: float = 0.3
var _cap_y_from: float = 0.55
var _cap_y_to: float = 0.55
var _cam_h_from: float = 1.4
var _cam_h_to: float = 1.4

var _fill_light: OmniLight3D
@onready var _pivot: Node3D = $CameraPivot
@onready var _camera: Camera3D = $CameraPivot/Camera3D
@onready var _body: Node3D = $Body
@onready var _col: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	add_to_group("wound_body")
	_default_yaw = _yaw
	_default_pitch = _pitch
	_default_cam_dist = camera_distance
	_default_cam_height = camera_height
	_default_fp_fov = fp_fov
	_default_tp_fov = tp_fov
	# 展示（观察）模式光标可见：左键留给腹部互动，右键环绕（网页 OrbitControls）。
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 相机由 _process 每帧摆放（鼠标视角零延迟），不参与物理插值；角色本体参与插值。
	_fti_prev = global_position
	_fti_cur = global_position
	_pivot.top_level = true
	_pivot.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = -10
	_setup_body_params()
	_cam_shape = SphereShape3D.new()
	_cam_shape.radius = TP_COLLIDE_RADIUS
	_align_capsule_to_feet()
	_print_body_info()
	CharacterLookScript.apply(_body)
	# 网页 BodyFillLight：只在第一人称开、跟随相机的弱暖色补光（#e6d4c6，距离 2.6，不投影）。
	# 只照角色（CHAR_LIGHT_LAYER），不会在墙上打出光斑；无高光，不会把皮肤打平。
	_fill_light = OmniLight3D.new()
	_fill_light.name = "CameraFill"
	_fill_light.light_color = Color("#e6d4c6")
	_fill_light.omni_range = 2.6
	# 衰减 0.6（原 2.0 ≈ 平方反比）：光源就在眼睛处，离胸口/肩/手只有 0.15–0.4m，平方反比会把
	# 近处皮肤打成一片白（第一人称低头、蹲下时最明显）。
	_fill_light.omni_attenuation = 0.6
	_fill_light.shadow_enabled = false
	_fill_light.light_specular = 0.0
	_fill_light.light_cull_mask = CHAR_LIGHT_LAYER
	_fill_light.position = Vector3.ZERO
	_camera.add_child(_fill_light)
	_loco = SoftLocoScript.new()
	add_child(_loco)
	var skel := _find_skeleton(_body)
	if skel and _loco.setup(skel):
		print("player: SoftLoco ready")
	else:
		push_warning("player: SoftLoco failed to init")
	_organs = OrganRigScript.new()
	_organs.name = "OrganRig"
	add_child(_organs)
	if skel == null or not _organs.setup(skel):
		push_warning("player: organs failed to init")
	_organs.set("secondary", _loco.get("secondary"))
	_weapons = WeaponSystemScript.new()
	_weapons.name = "Weapons"
	add_child(_weapons)
	_weapons.call("setup", self, _camera, skel)
	if _col.shape is CylinderShape3D:
		_capsule_stand_h = (_col.shape as CylinderShape3D).height
		_capsule_stand_y = _col.position.y
		_cap_h_from = _capsule_stand_h
		_cap_h_to = _capsule_stand_h
		_cap_r_from = (_col.shape as CylinderShape3D).radius
		_cap_r_to = _cap_r_from
		_cap_y_from = _capsule_stand_y
		_cap_y_to = _capsule_stand_y
		_cam_h_from = camera_height
		_cam_h_to = camera_height
	_body_logic_yaw = _yaw
	_body.rotation.y = _body_logic_yaw + BODY_YAW_OFFSET
	# Start in Display/Interact (TP, no move, gaze→camera).
	set_play_mode(GameMode.DISPLAY)
	tp_home(true)


func get_loco() -> Node:
	return _loco


func get_weapons() -> Node:
	return _weapons


## 第一人称且持枪（左键射击、右键开镜、滚轮切枪；身体随视线转）
func weapon_armed() -> bool:
	return first_person and _weapons != null and bool(_weapons.call("is_armed"))


func get_organs() -> Node:
	return _organs


func get_camera() -> Camera3D:
	return _camera


## CharacterBody3D 参数：防卡边 / 贴地 / 贴墙滑动。
func _setup_body_params() -> void:
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.32  # 下台阶 / 下坡不腾空
	floor_constant_speed = true  # 上下坡速度一致
	floor_stop_on_slope = true
	floor_block_on_wall = true
	wall_min_slide_angle = deg_to_rad(5.0)  # 斜着撞墙也沿墙滑，不会停住
	max_slides = 6
	safe_margin = 0.004
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED


## 相机用的角色位置：与引擎物理插值同一公式（上一 / 当前物理帧位置按插值系数混合）。
## 自己记录而不是用 get_global_transform_interpolated()：后者在物理帧外传送时要等下一个
## 物理帧才更新；这里检测到位置被直接改写（传送）就立即对齐。
var _fti_prev: Vector3 = Vector3.ZERO
var _fti_cur: Vector3 = Vector3.ZERO


func _fti_tick() -> void:
	_fti_prev = _fti_cur
	_fti_cur = global_position


func _base_origin() -> Vector3:
	if not _fti_cur.is_equal_approx(global_position):
		_fti_prev = global_position
		_fti_cur = global_position
	if not is_inside_tree() or not get_tree().physics_interpolation or Engine.is_in_physics_frame():
		return _fti_cur
	return _fti_prev.lerp(_fti_cur, Engine.get_physics_interpolation_fraction())


func _sync_pivot() -> void:
	if _pivot == null:
		return
	_pivot.global_transform = Transform3D(Basis.from_euler(_pivot_rot), _base_origin() + _pivot_off)


func _organs_live() -> bool:
	return _organs != null and bool(_organs.get("ready_ok")) and bool(_organs.call("mode_is_live", ""))


## 屏幕点 → 世界射线（捕获鼠标时用屏幕中心）
func _screen_ray(screen: Vector2) -> Array:
	return [_camera.project_ray_origin(screen), _camera.project_ray_normal(screen)]


func _interact_point(ev_pos: Vector2) -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return get_viewport().get_visible_rect().size * 0.5
	return ev_pos


## 当前互动的角色（本体或某个分身）的 OrganRig
var _interact_target: Node = null


func get_interact_target_rig() -> Node:
	return _interact_target if is_instance_valid(_interact_target) and _interact_target.is_inside_tree() else _organs



## 射线挑选互动目标：本体 + 所有分身（组 organ_rigs）里射线最先命中的那个。
func pick_interact_rig(origin: Vector3, dir: Vector3) -> Node:
	var best: Node = null
	var best_t := INF
	for r in get_tree().get_nodes_in_group("organ_rigs"):
		if not bool(r.get("ready_ok")):
			continue
		var t: float = r.call("ray_pick_distance", origin, dir)
		if t < best_t:
			best_t = t
			best = r
	return best


## 左键按下：拖拽=抓住腹壁 / 击腹=释放冲击 / 拳交=抓住拳头 / 刺刀=选入口或推拉刀柄。
## 目标可以是本体或任意分身（第一人称下用准星射线）。
func _try_begin_interact(screen: Vector2) -> bool:
	if not _organs_live():
		return false
	var ray := _screen_ray(screen)
	var rig := pick_interact_rig(ray[0], ray[1])
	if rig == null:
		return false
	_interact_target = rig
	var mode := str(_organs.get("interact_mode"))
	if mode == "fist" or mode == "bayonet" or mode == "navel":
		if rig.get("interact_mode") != mode:
			rig.call("copy_settings_from", _organs)
		var cam_fwd := -_camera.global_transform.basis.z
		if rig.call("tool_begin", ray[0], ray[1], cam_fwd):
			_interact_held = true
			_interact_screen = screen
		return true
	var hit: Variant = rig.call("ray_hit_belly", ray[0], ray[1])
	if hit == null:
		return false
	if mode == "strike":
		rig.call("strike_at", hit)
	elif mode == "drag":
		rig.call("begin_drag", hit)
		_interact_held = true
		_interact_screen = screen
	return true


## 拖拽中：鼠标射线与「过抓取点、法线=相机前向」平面求交（网页 grab plane）
func _update_interact_drag(screen: Vector2) -> void:
	var rig := _interact_target if is_instance_valid(_interact_target) else _organs
	var ray := _screen_ray(screen)
	if rig.call("is_tool_mode"):
		rig.call("tool_drag", ray[0], ray[1])
		return
	var grab: Vector3 = rig.call("drag_grab_world")
	var n := -_camera.global_transform.basis.z
	var plane := Plane(n, grab)
	var hit: Variant = plane.intersects_ray(ray[0], ray[1])
	if hit != null:
		rig.call("update_drag", hit)


func _end_interact() -> void:
	var rig := _interact_target if is_instance_valid(_interact_target) else _organs
	if _interact_held and rig:
		rig.call("end_drag")
		rig.call("tool_end")
	_interact_held = false


func get_secondary() -> RefCounted:
	if _loco == null:
		return null
	return _loco.get("secondary")


func reset_camera() -> void:
	fp_fov = _default_fp_fov
	tp_fov = _default_tp_fov
	if first_person:
		_pitch = 0.0
		_yaw = _body_logic_yaw
	else:
		tp_home(false)
	_apply_camera()


## 让角色朝向某个逻辑 yaw（0 = 面向 -Z）。出生 / 传送时用。
func set_facing(logic_yaw: float) -> void:
	_body_logic_yaw = wrapf(logic_yaw, -PI, PI)
	_yaw = _body_logic_yaw
	_pitch = 0.0
	_body.rotation.y = _body_logic_yaw + BODY_YAW_OFFSET
	if not first_person:
		tp_home(true)
	_apply_camera()


# ---------------------------------------------------------------- 观察视角（第三人称）

## 角色胸前方向（世界水平）。网格朝 Body +Z。
func _body_forward() -> Vector3:
	var f := _body.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 1e-6 else Vector3(0.0, 0.0, -1.0)


func _bone_world(bone: String) -> Variant:
	var skel := _find_skeleton(_body)
	if skel == null:
		return null
	var i := skel.find_bone(bone)
	if i < 0:
		return null
	return (skel.global_transform * skel.get_bone_global_pose(i)).origin


## 视觉中心点（世界）：face / chest / belly / groin（随蹲、匍匐等姿态）。
func focus_point(focus: String) -> Vector3:
	var spec: Dictionary = TP_FOCUS.get(focus, TP_FOCUS["belly"])
	var fwd := _body_forward()
	var p: Variant = null
	if str(spec["bone"]) == "navel":
		# 肚脐：静止位置 (0,1.06,0.114) 随 C_Spine_a 实时姿态（不用内脏模块缓存的帧，传送后也准确）。
		var skel := _find_skeleton(_body)
		var si := skel.find_bone("C_Spine_a") if skel else -1
		if si >= 0:
			var live := skel.get_bone_global_pose(si) * skel.get_bone_global_rest(si).affine_inverse()
			p = skel.global_transform * (live * Vector3(0.0, 1.06, 0.114))
	else:
		p = _bone_world(str(spec["bone"]) if str(spec["bone"]) != "navel" else "C_Spine_a")
	if p == null:
		p = global_position + Vector3(0.0, 1.06, 0.0)
	return (p as Vector3) + fwd * float(spec["fwd"]) + Vector3.UP * float(spec["up"])


## 网页 ORBIT_HOME：正面略偏右、略俯视，看向腹部，距离 2.27，fov 34。
func tp_home(snap: bool = false) -> void:
	var fwd := _body_forward()
	var face_yaw := atan2(fwd.x, fwd.z)
	_tp_yaw_goal = _tp_yaw + wrapf(face_yaw + TP_HOME_YAW_OFF - _tp_yaw, -PI, PI)
	_tp_elev_goal = TP_HOME_ELEV
	_tp_dist_goal = TP_HOME_DIST
	_tp_target_goal = focus_point("belly") - global_position
	_tp_focus = ""
	tp_fov = _default_tp_fov
	if snap:
		_tp_snap_to_goal()
	if not first_person:
		_update_tp_camera(0.0, snap)


## 脚本/测试用：直接设定观察相机（yaw：相机相对目标的水平方位，0 = 位于 +Z 侧）。
func set_tp_view(yaw: float, elev: float, dist: float, snap: bool = true) -> void:
	_tp_yaw_goal = yaw
	_tp_elev_goal = clampf(elev, TP_ELEV_MIN, TP_ELEV_MAX)
	_tp_dist_goal = clampf(dist, camera_distance_min, camera_distance_max)
	if snap:
		_tp_snap_to_goal()
		_update_tp_camera(0.0, true)


func _tp_snap_to_goal() -> void:
	_tp_yaw = _tp_yaw_goal
	_tp_elev = _tp_elev_goal
	_tp_dist = _tp_dist_goal
	_tp_target = _tp_target_goal
	_tp_dist_eff = _tp_dist


## 网页「视觉中心」按钮：目标移到部位、保持当前环绕方向、距离改为预设。
func set_tp_focus(focus: String) -> void:
	if not TP_FOCUS.has(focus):
		return
	_tp_focus = focus
	_tp_target_goal = focus_point(focus) - global_position
	_tp_dist_goal = float(TP_FOCUS[focus]["dist"])


func get_tp_focus() -> String:
	return _tp_focus


func set_tp_distance(d: float) -> void:
	_tp_dist_goal = clampf(d, camera_distance_min, camera_distance_max)


func get_tp_distance() -> float:
	return _tp_dist_goal


## 网页摄像机面板方向键：沿屏幕右/上/前平移（米）。
func tp_pan_step(dx: float, dy: float, dz: float = 0.0) -> void:
	var b := _camera.global_transform.basis
	_tp_target_goal += b.x * dx + b.y * dy - b.z * dz
	_tp_clamp_target()


func _tp_pan_pixels(rel: Vector2) -> void:
	var vh := maxf(1.0, get_viewport().get_visible_rect().size.y)
	var h := 2.0 * _tp_dist * tan(deg_to_rad(tp_fov) * 0.5)
	var per_px := h / vh
	var b := _camera.global_transform.basis
	_tp_target_goal += (-b.x * rel.x + b.y * rel.y) * per_px
	_tp_clamp_target()


func _tp_orbit_pixels(rel: Vector2) -> void:
	var rate := mouse_sensitivity * 2.2  # 默认 0.0055 rad/px（网页 rotateBy 0.0055）
	_tp_yaw_goal -= rel.x * rate
	_tp_elev_goal = clampf(_tp_elev_goal + rel.y * rate, TP_ELEV_MIN, TP_ELEV_MAX)
	_tp_focus = ""


func _tp_dolly(steps: float) -> void:
	# 网页 OrbitControls zoom：每格 ×0.95；这里每格 ×0.92（滚轮一格更明显）。
	_tp_dist_goal = clampf(_tp_dist_goal * pow(0.92, steps), camera_distance_min, camera_distance_max)


## 目标点不离开角色太远，也不出房间。
func _tp_clamp_target() -> void:
	var off := _tp_target_goal
	var flat := Vector2(off.x, off.z)
	if flat.length() > 1.6:
		flat = flat.normalized() * 1.6
	_tp_target_goal = Vector3(flat.x, clampf(off.y, 0.05, 2.2), flat.y)
	if camera_bounds.size != Vector3.ZERO:
		var inner := camera_bounds.grow(-0.2)
		var w := global_position + _tp_target_goal
		w = w.clamp(inner.position, inner.end)
		_tp_target_goal = w - global_position


func save_tp_preset(i: int) -> void:
	if i < 0 or i >= _tp_presets.size():
		return
	_tp_presets[i] = {
		"yaw": _tp_yaw_goal, "elev": _tp_elev_goal, "dist": _tp_dist_goal,
		"target": _tp_target_goal, "fov": tp_fov,
	}


func apply_tp_preset(i: int) -> bool:
	if i < 0 or i >= _tp_presets.size() or _tp_presets[i] == null:
		return false
	var p: Dictionary = _tp_presets[i]
	_tp_yaw_goal = _tp_yaw + wrapf(float(p["yaw"]) - _tp_yaw, -PI, PI)
	_tp_elev_goal = float(p["elev"])
	_tp_dist_goal = float(p["dist"])
	_tp_target_goal = p["target"]
	tp_fov = float(p["fov"])
	_tp_focus = ""
	return true


func has_tp_preset(i: int) -> bool:
	return i >= 0 and i < _tp_presets.size() and _tp_presets[i] != null


func _tp_dir(yaw: float, elev: float) -> Vector3:
	return Vector3(sin(yaw) * cos(elev), sin(elev), cos(yaw) * cos(elev))


## 相机碰撞：房间内用墙内包围盒（网页 pullCameraOutOfWalls），另外对世界碰撞体做球体扫掠。
func _tp_collide(origin: Vector3, dir: Vector3, dist: float) -> float:
	var d := dist
	if camera_bounds.size != Vector3.ZERO:
		var b := camera_bounds.grow(-(TP_COLLIDE_RADIUS + 0.04))
		if b.has_point(origin):
			for ax in 3:
				var c := dir[ax]
				if absf(c) < 1e-6:
					continue
				var plane := b.end[ax] if c > 0.0 else b.position[ax]
				d = minf(d, maxf(0.0, (plane - origin[ax]) / c))
	if is_inside_tree() and _cam_shape != null:
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = _cam_shape
		q.transform = Transform3D(Basis.IDENTITY, origin)
		q.motion = dir * d
		q.collision_mask = 1
		q.exclude = [get_rid()]
		var res := get_world_3d().direct_space_state.cast_motion(q)
		if res.size() >= 1 and res[0] < 1.0:
			d *= res[0]
	return maxf(d, 0.12)


func _update_tp_camera(delta: float, snap: bool = false) -> void:
	if tp_auto_rotate and not _rmb_down:
		_tp_yaw_goal += tp_auto_rotate_speed * TAU / 60.0 * delta
	var k := 1.0 if snap else 1.0 - exp(-TP_DAMP_RATE * delta)
	_tp_yaw += (_tp_yaw_goal - _tp_yaw) * k
	_tp_elev += (_tp_elev_goal - _tp_elev) * k
	_tp_dist = exp(lerpf(log(maxf(_tp_dist, 0.01)), log(maxf(_tp_dist_goal, 0.01)), k))
	_tp_target = _tp_target.lerp(_tp_target_goal, k)
	var target_w := _base_origin() + _tp_target
	var dir := _tp_dir(_tp_yaw, _tp_elev)
	var want := _tp_collide(target_w, dir, _tp_dist)
	if snap or want < _tp_dist_eff:
		_tp_dist_eff = want  # 撞墙立刻收回，不穿模
	else:
		_tp_dist_eff += (want - _tp_dist_eff) * (1.0 - exp(-8.0 * delta))
	_pivot_off = _tp_target
	_pivot_rot = Vector3(-_tp_elev, _tp_yaw, 0.0)
	_sync_pivot()
	_camera.position = Vector3(0.0, 0.0, _tp_dist_eff)
	_camera.near = clampf(_tp_dist_eff * 0.15, 0.02, 0.1)
	_camera.fov = tp_fov
	camera_distance = _tp_dist_eff


## 校验用：当前第三人称相机状态
func debug_tp_state() -> Dictionary:
	return {
		"yaw": _tp_yaw, "elev": _tp_elev, "dist": _tp_dist, "dist_eff": _tp_dist_eff,
		"target": global_position + _tp_target, "cam": _camera.global_position,
		"goal_dist": _tp_dist_goal, "focus": _tp_focus,
	}


func _process(delta: float) -> void:
	# 在面板上松开按键时收不到 release → 以实际按键状态为准。
	if _rmb_down and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_rmb_down = false
	if _mmb_down and not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_mmb_down = false
	if not first_person:
		_update_tp_camera(delta)
		_push_view_spin(delta)
	else:
		_push_view_spin(0.0)
		_step_smooth *= exp(-14.0 * delta)
		_pivot_rot = Vector3(_pitch, _yaw, 0.0)
		_pivot_off = _fp_eye_pivot_pos() - Vector3(0.0, _step_smooth, 0.0)
		_sync_pivot()
		_camera.near = 0.1 if camera_bounds.size == Vector3.ZERO else 0.04
	if _touch_interact and _interact_held:
		_update_interact_drag(get_viewport().get_visible_rect().size * 0.5)
	if _organs and _organs.has_method("set_fp_clip"):
		_organs.call("set_fp_clip", _camera.global_position, (FP_CLIP_RADIUS_BLEND if is_stance_blending() else FP_CLIP_RADIUS) if first_person else 0.0)
	if _fill_light:
		# 网页：观察模式关闭；第一人称 房间 0.18 / 城市 0.06，移动时 ×0.45。
		var city := camera_bounds.size == Vector3.ZERO
		var moving := Vector2(velocity.x, velocity.z).length() > 0.2
		var base := (0.06 if city else 0.18) * (0.45 if moving else 1.0)
		_fill_light.visible = first_person
		_fill_light.light_energy = base * 1.2


## 观察模式：相机环绕角速度 → 乳摇（网页 pushViewSpin）。第一人称不推（身体转动本身已驱动）。
var _spin_prev: Vector2 = Vector2.ZERO
var _spin_has_prev: bool = false


func _push_view_spin(delta: float) -> void:
	var sec := get_secondary()
	var br: RefCounted = sec.get("breasts") if sec else null
	if br == null:
		return
	if delta <= 0.0:
		_spin_has_prev = false
		br.call("push_view_spin", 0.0, 0.0)
		return
	var cur := Vector2(_tp_yaw, _tp_elev)
	if not _spin_has_prev:
		_spin_prev = cur
		_spin_has_prev = true
	var inv := 1.0 / maxf(delta, 1e-4)
	var yaw_v := wrapf(cur.x - _spin_prev.x, -PI, PI) * inv
	var pitch_v := (cur.y - _spin_prev.y) * inv
	_spin_prev = cur
	br.call("push_view_spin", clampf(yaw_v, -14.0, 14.0), clampf(pitch_v, -10.0, 10.0))


func set_first_person(enabled: bool) -> void:
	# Prefer set_play_mode; kept for HUD backward-compat → maps to CONTROL/DISPLAY.
	set_play_mode(GameMode.CONTROL if enabled else GameMode.DISPLAY)


func toggle_first_person() -> void:
	toggle_play_mode()


func get_play_mode() -> GameMode:
	return play_mode


func is_display_mode() -> bool:
	return play_mode == GameMode.DISPLAY


func set_play_mode(mode: GameMode) -> void:
	var prev := play_mode
	play_mode = mode
	first_person = mode == GameMode.CONTROL
	if mode == GameMode.DISPLAY:
		# 观察视角以「当前角色」为中心：相机从第一人称眼位平滑飞出到正面展示位。
		var from_cam := _camera.global_position
		_rmb_down = false
		_mmb_down = false
		tp_home(false)
		if prev != mode:
			var off := from_cam - (global_position + _tp_target_goal)
			var dl := maxf(off.length(), 0.05)
			_tp_target = _tp_target_goal
			_tp_dist = dl
			_tp_dist_eff = dl
			_tp_yaw = _tp_yaw_goal + wrapf(atan2(off.x, off.z) - _tp_yaw_goal, -PI, PI)
			_tp_elev = clampf(asin(clampf(off.y / dl, -1.0, 1.0)), TP_ELEV_MIN, TP_ELEV_MAX)
		var sec := get_secondary()
		if sec:
			sec.call("clear_body_look")
		if not ui_blocks_capture:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		var sec2 := get_secondary()
		if sec2:
			sec2.call("clear_gaze")
		# 第一人称视线 = 身体当前朝向，避免切换时身体被甩。
		if prev != mode:
			_yaw = _body_logic_yaw
			_pitch = 0.0
		if not ui_blocks_capture:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_fp_mesh_visibility()
	_apply_camera()
	if prev != mode:
		print(
			"player: play_mode=",
			"DISPLAY" if mode == GameMode.DISPLAY else "CONTROL"
		)


func toggle_play_mode() -> void:
	set_play_mode(
		GameMode.CONTROL if play_mode == GameMode.DISPLAY else GameMode.DISPLAY
	)


func set_mouse_sensitivity(v: float) -> void:
	mouse_sensitivity = clampf(v, 0.0005, 0.02)


## FP: hide only head / hair / eye / mouth (layer-culled) to reduce camera clip; keep torso/arms/legs.
func _fp_should_hide_mesh(mi: MeshInstance3D) -> bool:
	var n := mi.name
	var low := n.to_lower()
	if "_eye_" in low or low.ends_with("_eye_0"):
		return true
	if "_head_" in low or "head_0" in low:
		return true
	if "mouth" in low:
		return true
	if "hair" in low or "头发" in n:
		return true
	# Baked hair mesh is PC0002_01_007_* (garbled unicode name).
	if "_007_" in n:
		return true
	return false


## Render layer 19: head/hair/eyes. FP main camera culls it; the room mirror camera still
## renders it, so the full face shows in the mirror in first person.
const FP_HEAD_LAYER := 1 << 18
## 只照角色的补光层（lighting_rig.CHAR_LIGHT_LAYER）。第一人称隐藏的头部网格不加这一层
## （层是「任一位命中即可见」，加了会让主相机重新看到头）。
const CHAR_LIGHT_LAYER := 1 << 17


func _apply_fp_mesh_visibility() -> void:
	for mi in _body.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null or mesh_i.name.ends_with("_ShadowProxy"):
			continue
		mesh_i.visible = true
		if _fp_should_hide_mesh(mesh_i):
			mesh_i.layers = FP_HEAD_LAYER
		else:
			mesh_i.layers |= CHAR_LIGHT_LAYER
	if first_person:
		_camera.cull_mask &= ~FP_HEAD_LAYER
	else:
		_camera.cull_mask |= FP_HEAD_LAYER
	_sync_fp_shadow_proxies()


## 第一人称时头/发/眼在主相机被图层剔除，Godot 的平行光阴影也随相机可见层一起剔除，
## 影子里就没了头。给每个隐藏网格挂一个「只投影」副本（同网格/同蒙皮/同骨架，图层 1，
## SHADOWS_ONLY）：主相机看不见它本体，但它进入阴影图。只在第一人称打开。
var _fp_shadow_proxies: Array[MeshInstance3D] = []


func _sync_fp_shadow_proxies() -> void:
	if _fp_shadow_proxies.is_empty() and first_person:
		for mi in _body.find_children("*", "MeshInstance3D", true, false):
			var src := mi as MeshInstance3D
			if src == null or not _fp_should_hide_mesh(src) or src.name.ends_with("_ShadowProxy"):
				continue
			if src.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				continue
			var px := MeshInstance3D.new()
			px.name = String(src.name) + "_ShadowProxy"
			px.mesh = src.mesh
			px.skin = src.skin
			px.transform = src.transform
			for si in src.get_surface_override_material_count():
				px.set_surface_override_material(si, src.get_active_material(si))
			px.material_override = src.material_override
			px.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			px.layers = 1
			src.get_parent().add_child(px)
			px.skeleton = px.get_path_to(src.get_node(src.skeleton)) if src.skeleton != NodePath() else NodePath()
			_fp_shadow_proxies.append(px)
	for px in _fp_shadow_proxies:
		if is_instance_valid(px):
			px.visible = first_person


## 自检：头部（含只投影副本）在当前模式下是否投影。
func debug_head_shadow_state() -> Dictionary:
	var heads := 0
	var casting := 0
	for mi in _body.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m == null or not _fp_should_hide_mesh(m) or m.name.ends_with("_ShadowProxy"):
			continue
		heads += 1
		var ok := m.visible and m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and (m.layers & _camera.cull_mask) != 0
		if not ok:
			for px in _fp_shadow_proxies:
				if is_instance_valid(px) and px.visible and px.mesh == m.mesh and (px.layers & _camera.cull_mask) != 0 \
						and px.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
					ok = true
		if ok:
			casting += 1
	return {"heads": heads, "casting": casting}


## Place capsule so its bottom matches mesh soles (AABB min.y ≈ 0 in character space).
func _align_capsule_to_feet() -> void:
	if not (_col.shape is CylinderShape3D):
		return
	var cap := _col.shape as CylinderShape3D
	# Mesh feet are at y≈0 (skinned GLB fitStanding). Old capsule bottom was ~0.28 → feet sank.
	_col.position.y = cap.height * 0.5
	_capsule_stand_h = cap.height
	_capsule_stand_y = _col.position.y
	print(
		"player: capsule aligned bottom≈0 (h=%.3f y=%.3f)"
		% [cap.height, _col.position.y]
	)


func _print_body_info() -> void:
	var skel := _find_skeleton(_body)
	if skel:
		print("player: skeleton bones=", skel.get_bone_count())
	var aabb := _calc_aabb(_body)
	var cap_bottom := 0.0
	if _col.shape is CylinderShape3D:
		cap_bottom = _col.position.y - (_col.shape as CylinderShape3D).height * 0.5
	print(
		"player: body AABB ", aabb,
		" feet≈", aabb.position.y,
		" height≈", aabb.size.y,
		" capsule_bottom≈", cap_bottom
	)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _calc_aabb(n: Node) -> AABB:
	var result := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null or mesh_i.mesh == null:
			continue
		var local := mesh_i.mesh.get_aabb()
		var xf := mesh_i.global_transform
		var merged := AABB()
		var init := true
		for i in 8:
			var corner := local.position + Vector3(
				local.size.x if (i & 1) else 0.0,
				local.size.y if (i & 2) else 0.0,
				local.size.z if (i & 4) else 0.0
			)
			var w := xf * corner
			if init:
				merged = AABB(w, Vector3.ZERO)
				init = false
			else:
				merged = merged.expand(w)
		# Express relative to this CharacterBody3D origin.
		merged.position -= global_position
		if first:
			result = merged
			first = false
		else:
			result = result.merge(merged)
	return result


# ------------------------------------------------------------------ 触屏（touch_controls.gd 调用）
## 触屏操作开启时，触摸模拟出来的鼠标事件（device = DEVICE_ID_EMULATION）只给 GUI 用，
## 这里不再处理，避免与 touch_controls 的手指逻辑重复（同一次点按 = 两次互动）。
var touch_active: bool = false
var touch_move: Vector2 = Vector2.ZERO  # 虚拟摇杆（x 右，y 下 = 后退），已去死区
var touch_sprint: bool = false
var touch_jump_req: bool = false
var _touch_interact: bool = false
## 网页 FP_TOUCH_SENS 0.00305 rad/px × fpLookSpeed 0.9（随灵敏度设置等比例缩放）
const FP_TOUCH_SENS := 0.00305 * 0.9


func touch_look(rel: Vector2) -> void:
	var k := FP_TOUCH_SENS * (mouse_sensitivity / 0.0025)
	_yaw -= rel.x * k
	_pitch = clampf(_pitch - rel.y * k, min_pitch, max_pitch)
	_apply_camera()


func touch_orbit(rel: Vector2) -> void:
	_tp_orbit_pixels(rel)


func touch_pan(rel: Vector2) -> void:
	_tp_pan_pixels(rel)


## 双指捏合：scale = 旧间距 / 新间距（网页 dollyCam）
func touch_dolly(scale: float) -> void:
	_tp_dist_goal = clampf(_tp_dist_goal * scale, camera_distance_min, camera_distance_max)


func touch_set_fov(v: float) -> void:
	fp_fov = clampf(v, fp_fov_min, fp_fov_max)
	_apply_camera()


## 观察视角：手指按在角色身上 = 当前工具（与鼠标左键同一套逻辑）
func touch_tool_begin(screen: Vector2) -> bool:
	if _interact_held:
		_end_interact()
	return _try_begin_interact(screen)


func touch_tool_drag(screen: Vector2) -> void:
	if _interact_held:
		_interact_screen = screen
		_update_interact_drag(screen)


func touch_tool_end() -> void:
	if _interact_held:
		_end_interact()


func touch_tool_active() -> bool:
	return _interact_held


## 第一人称「互动」按钮（网页 tapFpInteract：屏幕中心射线按下）；按住时视线移动 = 拖动工具
func touch_interact(pressed: bool) -> void:
	var c := get_viewport().get_visible_rect().size * 0.5
	if pressed:
		_touch_interact = true
		touch_tool_begin(c)
	else:
		_touch_interact = false
		touch_tool_end()


func touch_crouch_tap() -> void:
	if play_mode != GameMode.CONTROL:
		return
	_set_stance("stand" if (_stance == "crouch" or _stance == "prone") else "crouch")


func _unhandled_input(event: InputEvent) -> void:
	# 只处理鼠标；离散按键统一由 game_root.run_action 路由（每个键只在一处处理）。
	if input_locked:
		return
	if touch_active and event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	# 脏器互动：左键（捕获鼠标时取屏幕中心，否则取光标）。HUD 面板打开时也可以互动——
	# 面板本身吃掉落在面板矩形内的点击，面板外的点击会走到这里。
	# 武器：左键射击 / 右键开镜 / 滚轮切枪（第一人称持枪时代替身体互动）
	if event is InputEventMouseButton and _weapons:
		var wb := event as InputEventMouseButton
		if wb.button_index == MOUSE_BUTTON_LEFT and not wb.pressed:
			_weapons.call("set_trigger", false)
		if wb.button_index == MOUSE_BUTTON_RIGHT and not wb.pressed:
			_weapons.call("set_ads", false)
		if weapon_armed() and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or touch_active):
			if wb.button_index == MOUSE_BUTTON_LEFT:
				_weapons.call("set_trigger", wb.pressed)
				get_viewport().set_input_as_handled()
				return
			if wb.button_index == MOUSE_BUTTON_RIGHT:
				_weapons.call("set_ads", wb.pressed)
				get_viewport().set_input_as_handled()
				return
			if wb.pressed and (wb.button_index == MOUSE_BUTTON_WHEEL_UP or wb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				_weapons.call("cycle", -1 if wb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
				get_viewport().set_input_as_handled()
				return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var lb := event as InputEventMouseButton
		if lb.pressed:
			if _try_begin_interact(_interact_point(lb.position)):
				get_viewport().set_input_as_handled()
				return
		elif _interact_held:
			_end_interact()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and _interact_held:
		var mmd := event as InputEventMouseMotion
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_interact_screen += mmd.relative
		else:
			_interact_screen = mmd.position
		_update_interact_drag(_interact_screen)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if first_person:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				_yaw -= mm.relative.x * mouse_sensitivity
				_pitch -= mm.relative.y * mouse_sensitivity
				_pitch = clampf(_pitch, min_pitch, max_pitch)
				_apply_camera()
		else:
			# 观察视角（网页 OrbitControls）：右键环绕，中键 / Shift·Ctrl+右键 平移。
			if _mmb_down or (_rmb_down and _pan_drag):
				_tp_pan_pixels(mm.relative)
				get_viewport().set_input_as_handled()
			elif _rmb_down:
				_tp_orbit_pixels(mm.relative)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var wheel := mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
		if wheel:
			if not mb.pressed:
				return
			var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			var steps := dir * maxf(1.0, mb.factor if mb.factor > 0.0 else 1.0)
			if first_person:
				# Wheel up = zoom in = narrower FOV.
				fp_fov = clampf(fp_fov - steps * 3.0, fp_fov_min, fp_fov_max)
				_apply_camera()
			else:
				_tp_dolly(steps)
			get_viewport().set_input_as_handled()
			return
		if not first_person:
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				_rmb_down = mb.pressed
				_pan_drag = mb.pressed and (mb.shift_pressed or mb.ctrl_pressed or mb.meta_pressed)
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_MIDDLE:
				_mmb_down = mb.pressed
				get_viewport().set_input_as_handled()
		elif mb.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			# 第一人称：点画面捕获鼠标（面板打开时不捕获，光标留给面板 / 腹部互动）
			if not ui_blocks_capture:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Esc（面板都关着时）：第一人称释放 / 重新捕获鼠标。
func escape_mouse() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif first_person and not ui_blocks_capture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## R：复位视角 + 腹部形变（网页 R）。
func reset_view_and_belly() -> void:
	reset_camera()
	# 本体 + 所有分身的腹部形变 / 工具 / 伤口一起复位
	for r in get_tree().get_nodes_in_group("organ_rigs"):
		r.call("reset_interaction")


## F（仅观察视角）：视觉中心 面部→胸部→腹部→阴部
func cycle_tp_focus() -> void:
	if first_person:
		return
	var order := ["face", "chest", "belly", "groin"]
	var i := order.find(_tp_focus)
	set_tp_focus(order[(i + 1) % order.size()])


## 1–8 舞蹈；0 = 取消
func dance(n: int) -> void:
	if _loco == null:
		return
	if n <= 0:
		_loco.call("clear_dance")
	else:
		_loco.call("set_dance", "dance%d" % n)


func get_stance() -> String:
	return _stance


## Crouch is toggle (Ctrl / C press). Release must NOT force stand. Prone stays Z toggle.
func _update_crouch_toggle() -> void:
	if not Input.is_action_just_pressed("crouch"):
		return
	if _stance == "crouch" or _stance == "prone":
		# 蹲 / 匍匐中按一下 → 站起（网页：轻按退出匍匐）
		_set_stance("stand")
	else:
		_set_stance("crouch")


## Z：切换匍匐（仅角色控制模式，由 game_root 路由）
func toggle_prone() -> void:
	if play_mode != GameMode.CONTROL:
		return
	_set_stance("stand" if _stance == "prone" else "prone")


## 姿态胶囊（网页 FP 胶囊：站 1.64/0.3、蹲 0.94/0.26、匍匐 0.42/0.22）
const STANCE_CAPSULE := {
	"stand": Vector2(1.64, 0.3),
	"crouch": Vector2(0.94, 0.26),
	"prone": Vector2(0.42, 0.22),
}


## 头顶空间检查：目标姿态的胶囊放在当前位置是否会与世界重叠（床下 / 桌下不能站起）。
func can_fit_stance(stance: String) -> bool:
	if not is_inside_tree():
		return true
	var hr: Vector2 = STANCE_CAPSULE.get(stance, STANCE_CAPSULE["stand"])
	if stance == "stand":
		hr.x = _capsule_stand_h
	var cur := (_col.shape as CylinderShape3D) if _col.shape is CylinderShape3D else null
	if cur and hr.x <= cur.height + 0.001:
		return true  # 变矮永远可以
	var shape := CylinderShape3D.new()
	shape.radius = maxf(0.05, hr.y - 0.02)
	shape.height = maxf(0.1, hr.x - 0.06)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	# 底部抬高 4cm，避免与地面接触算重叠
	q.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0.0, 0.04 + shape.height * 0.5, 0.0))
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _set_stance(stance: String) -> bool:
	if stance == _stance:
		return true
	if not can_fit_stance(stance):
		print("player: 头顶空间不足，保持 ", _stance)
		return false
	_stance = stance
	_apply_stance_capsule()
	print("player: stance=", _stance)
	return true


func _stance_eye_target(stance: String) -> Vector3:
	match stance:
		"crouch":
			return FP_EYE_CROUCH
		"prone":
			return FP_EYE_PRONE
		_:
			return FP_EYE_STAND


func _begin_fp_eye_blend(new_stance: String) -> void:
	_fp_eye_from = _fp_eye_cur
	_fp_eye_to = _stance_eye_target(new_stance)
	_fp_eye_blend = 0.0


func _apply_stance_capsule() -> void:
	if not (_col.shape is CylinderShape3D):
		return
	var cap := _col.shape as CylinderShape3D
	# Web FP capsule approx: stand 1.64/0.3, crouch 0.94/0.26, prone 0.42/0.22.
	# Blend height/radius/eye over STANCE_BLEND_DUR (0.7s). Bottom stays ≈ 0.
	_begin_fp_eye_blend(_stance)
	_cap_h_from = cap.height
	_cap_r_from = cap.radius
	_cap_y_from = _col.position.y
	_cam_h_from = camera_height
	match _stance:
		"crouch":
			_cap_h_to = 0.94
			_cap_r_to = 0.26
			_cap_y_to = 0.94 * 0.5
			_cam_h_to = 0.95
			fp_eye_height = FP_EYE_CROUCH.y + FP_EYE_LIFT
		"prone":
			_cap_h_to = 0.42
			_cap_r_to = 0.22
			_cap_y_to = 0.42 * 0.5
			_cam_h_to = 0.4
			fp_eye_height = FP_EYE_PRONE.y + FP_EYE_LIFT
		_:
			_cap_h_to = _capsule_stand_h
			_cap_r_to = 0.3
			_cap_y_to = _capsule_stand_y
			_cam_h_to = _default_cam_height
			fp_eye_height = FP_EYE_STAND.y + FP_EYE_LIFT
	_stance_blend = 0.0
	_apply_camera()


func _apply_camera() -> void:
	_pivot_rot = Vector3(_pitch, _yaw, 0.0)
	if first_person:
		_pivot_off = _fp_eye_pivot_pos() - Vector3(0.0, _step_smooth, 0.0)
		_sync_pivot()
		_camera.position = Vector3.ZERO
		# 网页 syncFpProjection：身体视角 near 0.04（城市 0.12，远景精度）；头/发/眼由图层隐藏，
		# 颈部近处由皮肤 shader 的第一人称近裁球处理（只对主相机生效，镜子里完整）。
		_camera.near = 0.1 if camera_bounds.size == Vector3.ZERO else 0.04
		_camera.fov = fp_fov
	else:
		_update_tp_camera(0.0)


## Smooth lerp between stance eyes (web stanceU smoothstep over STANCE_BLEND_DUR).
func _update_fp_eye_blend(delta: float) -> void:
	if _fp_eye_blend < 1.0:
		_fp_eye_blend = minf(1.0, _fp_eye_blend + delta / FP_EYE_BLEND_DUR)
	# 眼位比身体（0.7s）快、ease-out：先到位，让视点始终领先于正在弯曲的脖子/头部。
	var t := _fp_eye_blend
	var u := 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
	_fp_eye_cur = _fp_eye_from.lerp(_fp_eye_to, u)
	# 起身（眼位往后收、靠近身体）时，前后分量跟身体同速（0.7s smoothstep）：先抬高、再后收，
	# 否则视点会先退进正在抬起的胸口/脖子里。
	if _fp_eye_to.z < _fp_eye_from.z:
		var bt := _stance_blend
		_fp_eye_cur.z = lerpf(_fp_eye_from.z, _fp_eye_to.z, bt * bt * (3.0 - 2.0 * bt))


func is_stance_blending() -> bool:
	return _stance_blend < 1.0 or _fp_eye_blend < 1.0


func _update_stance_capsule_blend(delta: float) -> void:
	if not (_col.shape is CylinderShape3D):
		return
	if _stance_blend < 1.0:
		_stance_blend = minf(1.0, _stance_blend + delta / STANCE_BLEND_DUR)
	var t := _stance_blend
	var u := t * t * (3.0 - 2.0 * t)
	var cap := _col.shape as CylinderShape3D
	cap.height = lerpf(_cap_h_from, _cap_h_to, u)
	cap.radius = lerpf(_cap_r_from, _cap_r_to, u)
	_col.position.y = lerpf(_cap_y_from, _cap_y_to, u)
	camera_height = lerpf(_cam_h_from, _cam_h_to, u)


## 第一人称眼位（CharacterBody 本地）。移植网页 figure.tsx bodyOn 分支：
## - 眼位 = 姿态眼位（站/蹲/趴，0.7s 过渡，不跟头骨上下晃）+ 起跳时前探（jumpEyeU：0.1s 进 / 0.2s 出，
##   前移 0.18m + 低头时再多 0.16m、上移 3cm），只用身体朝向旋转、不跟身体平移；
## - 再沿视线水平前推 2.8cm（走 3.5cm、冲刺 5cm）；
## - 身体网格相对相机后移 locoBack（冲刺 0.18m、走 0.06m、静止 0.02m）→ 跑步前倾 / 摆臂时头颈胸不会顶进镜头；
## - 结果做指数平滑（误差 >0.28m 时 22/s，否则 12/s），起跳 / 落地 / 换姿态不会硬跳。
## 第一人称近裁球半径：主相机看不到眼睛周围这么近的皮肤（颈 / 锁骨），镜子里不受影响。
const FP_CLIP_RADIUS := 0.1
## 姿态过渡中近相机皮肤裁切半径放大（脖子/锁骨在 0.7s 内会扫过视点附近）。
const FP_CLIP_RADIUS_BLEND := 0.13
const FP_PUSH_IDLE := 0.028
const FP_PUSH_WALK := 0.035
const FP_PUSH_SPRINT := 0.05
const FP_BACK_IDLE := 0.02
const FP_BACK_WALK := 0.06
const FP_BACK_SPRINT := 0.18
var _loco_back: float = 0.0
var _jump_eye_u: float = 0.0
var _fp_eye_smooth: Vector3 = Vector3(0.0, 1.58, -0.2)
var _fp_eye_init: bool = false


func _fp_eye_target(moving: bool, sprinting: bool) -> Vector3:
	var eye := _fp_eye_cur + Vector3(0.0, FP_EYE_LIFT, 0.0)
	if _jump_eye_u > 0.001:
		var j := _jump_eye_u * _jump_eye_u * (3.0 - 2.0 * _jump_eye_u)
		var down := clampf(-_pitch, 0.0, 1.2)
		eye.z += (0.18 + down * 0.16) * j
		eye.y += 0.03 * j
	var p := _body.transform.basis * eye
	var push := FP_PUSH_SPRINT if sprinting else (FP_PUSH_WALK if moving else FP_PUSH_IDLE)
	return p + Basis(Vector3.UP, _yaw) * Vector3(0.0, 0.0, -push)


## 物理帧里更新：locoBack（身体后移）+ jumpEyeU + 眼位平滑。
func _update_fp_eye(delta: float, moving: bool, sprinting: bool, airborne: bool) -> void:
	if not first_person:
		_loco_back = 0.0
		_jump_eye_u = 0.0
		_fp_eye_init = false
		_body.position = Vector3.ZERO
		return
	if airborne:
		_jump_eye_u = minf(1.0, _jump_eye_u + delta / 0.1)
	else:
		_jump_eye_u = maxf(0.0, _jump_eye_u - delta / 0.2)
	var back := FP_BACK_IDLE
	if sprinting and moving:
		back = FP_BACK_SPRINT
	elif moving and _stance != "prone":
		back = FP_BACK_WALK
	_loco_back += (back - _loco_back) * (1.0 - exp(-10.0 * delta))
	var fwd := _body.transform.basis.z  # 网格 +Z = 面朝方向
	_body.position = -Vector3(fwd.x, 0.0, fwd.z).normalized() * _loco_back
	var want := _fp_eye_target(moving, sprinting)
	if not _fp_eye_init:
		_fp_eye_smooth = want
		_fp_eye_init = true
	var err := _fp_eye_smooth.distance_to(want)
	var k := 1.0 - exp(-(22.0 if (err > 0.28 or is_stance_blending()) else 12.0) * delta)
	_fp_eye_smooth = _fp_eye_smooth.lerp(want, k)


func _fp_eye_pivot_pos() -> Vector3:
	if not _fp_eye_init:
		return _fp_eye_target(false, false)
	return _fp_eye_smooth


## 校验用：第一人称状态
func debug_fp_state() -> Dictionary:
	return {"loco_back": _loco_back, "jump_eye": _jump_eye_u, "eye_local": _fp_eye_smooth,
		"cam": _camera.global_position, "near": _camera.near}


## Debug / validate: current FP eye Y in player space for a stance (instant target).
func debug_fp_eye_y(stance: String = "") -> float:
	var s := stance if stance != "" else _stance
	var eye := _stance_eye_target(s) + Vector3(0.0, FP_EYE_LIFT, 0.0)
	return eye.y


## Moving: snap to camera yaw. Idle: keep ±BODY_LOOK_DEAD (π/3) free-look, then catch up.
func debug_next_body_yaw(look_yaw: float, body_yaw: float, moving: bool) -> float:
	var ang_delta := wrapf(look_yaw - body_yaw, -PI, PI)
	if moving:
		return wrapf(look_yaw, -PI, PI)
	if absf(ang_delta) > BODY_LOOK_DEAD:
		return wrapf(look_yaw - signf(ang_delta) * BODY_LOOK_DEAD, -PI, PI)
	return wrapf(body_yaw, -PI, PI)


## 台阶上抬：贴地且水平运动被挡住时，试「上抬 STEP_HEIGHT → 前移 → 下落」，
## 落点是可站立地面就把角色抬到台阶高度（随后 move_and_slide 正常前进）。
func _try_step_up(motion: Vector3) -> bool:
	if motion.length_squared() < 1e-8:
		return false
	var xf := global_transform
	var hit := KinematicCollision3D.new()
	if not test_move(xf, motion, hit, safe_margin):
		return false  # 没被挡
	if hit.get_normal().angle_to(Vector3.UP) <= floor_max_angle:
		return false  # 可走的坡，交给 move_and_slide
	var up := Vector3.UP * STEP_HEIGHT
	var up_col := KinematicCollision3D.new()
	var up_travel := up
	if test_move(xf, up, up_col, safe_margin):
		up_travel = up_col.get_travel()
		if up_travel.y < 0.05:
			return false  # 头顶没空间
	var xf_up := xf.translated(up_travel)
	# 前探至少 radius 的一部分，保证落脚点在台阶上
	var probe := motion.normalized() * maxf(motion.length(), 0.08)
	if test_move(xf_up, probe):
		return false  # 抬高后仍被挡（是墙，不是台阶）
	var xf_fwd := xf_up.translated(probe)
	var down_col := KinematicCollision3D.new()
	if not test_move(xf_fwd, -up_travel - Vector3(0.0, 0.02, 0.0), down_col, safe_margin):
		return false  # 前方悬空
	if down_col.get_normal().angle_to(Vector3.UP) > floor_max_angle:
		return false
	var land_y := xf_fwd.origin.y + down_col.get_travel().y
	var rise := land_y - xf.origin.y
	if rise < 0.01 or rise > STEP_HEIGHT + 0.001:
		return false
	global_position.y += rise
	_step_smooth += rise  # 相机平滑跟上
	return true


func _physics_process(delta: float) -> void:
	var display := play_mode == GameMode.DISPLAY
	var can_act := (not display) and not input_locked
	if can_act:
		_update_crouch_toggle()
	_update_fp_eye_blend(delta)
	_update_stance_capsule_blend(delta)

	var on_floor := is_on_floor()
	# 土狼时间 + 跳跃缓冲（网页 coyote 0.14 / jumpBuf 0.14）
	_coyote = COYOTE_TIME if on_floor else maxf(0.0, _coyote - delta)
	var touch_jump := touch_jump_req
	touch_jump_req = false
	if can_act and (Input.is_action_just_pressed("jump") or touch_jump):
		if _stance == "prone" or _stance == "crouch":
			_set_stance("stand")  # 网页：匍匐中空格 = 站起
		else:
			_jump_buf = JUMP_BUFFER
	else:
		_jump_buf = maxf(0.0, _jump_buf - delta)
	if not on_floor:
		_air_time += delta
	else:
		_air_time = 0.0

	var input_dir := Vector2.ZERO
	if can_act:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if touch_move.length_squared() > 1e-6:
			input_dir = touch_move.limit_length(1.0)
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var wish := basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y)
	var wish_len := minf(1.0, wish.length())
	var direction := wish.normalized() if wish_len > 1e-4 else Vector3.ZERO
	var sprinting := can_act and (Input.is_action_pressed("sprint") or touch_sprint) and _stance == "stand"
	var speed := move_speed
	match _stance:
		"crouch":
			speed = crouch_speed
		"prone":
			speed = prone_speed
		_:
			speed = sprint_speed if sprinting else move_speed

	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if display or input_locked:
		# Lock locomotion — stand in place for display / tool interaction.
		hv = Vector3.ZERO
		direction = Vector3.ZERO
		input_dir = Vector2.ZERO
		sprinting = false
		_jump_buf = 0.0
	else:
		# 网页同款：地面摩擦（指数减速）+ 朝输入方向加速（地面 12、空中 3.4）
		if on_floor:
			var sp := hv.length()
			if sp > 0.05:
				hv *= maxf(0.0, sp - sp * FP_FRICTION * delta) / sp
			elif wish_len < 1e-4:
				hv = Vector3.ZERO
		var wish_speed := speed * wish_len
		if wish_speed > 1e-4:
			var acc := (FP_ACCEL if on_floor else FP_AIR_ACCEL) * wish_speed * delta
			var add := wish_speed - hv.dot(direction)
			if add > 0.0:
				hv += direction * minf(acc, add)
	velocity.x = hv.x
	velocity.z = hv.z

	if _jump_buf > 0.0 and _coyote > 0.0 and can_act:
		velocity.y = jump_velocity
		_jump_buf = 0.0
		_coyote = 0.0
		on_floor = false
	if not on_floor or velocity.y > 0.0:
		velocity.y = maxf(velocity.y - gravity * delta, -FP_MAX_FALL)

	# Visual facing: mesh +Z vs Godot -Z → BODY_YAW_OFFSET (π).
	# CONTROL/FP: while moving, body faces camera yaw immediately (no deadzone lag).
	# Idle free-look keeps ±60° / ~120° deadzone; DISPLAY keeps current facing.
	if first_person:
		var look_yaw := _yaw
		var moving := direction != Vector3.ZERO or not on_floor or weapon_armed()
		_body_logic_yaw = debug_next_body_yaw(look_yaw, _body_logic_yaw, moving)
		_body.rotation.y = _body_logic_yaw + BODY_YAW_OFFSET
	elif direction != Vector3.ZERO:
		var face_yaw := atan2(-direction.x, -direction.z) + BODY_YAW_OFFSET
		_body.rotation.y = lerp_angle(
			_body.rotation.y, face_yaw, clampf(14.0 * delta, 0.0, 1.0)
		)

	if on_floor and velocity.y <= 0.0:
		_try_step_up(Vector3(velocity.x, 0.0, velocity.z) * delta)
	move_and_slide()
	_fti_tick()
	if is_on_floor():
		_coyote = COYOTE_TIME

	# CONTROL/FP: body look BEFORE apply_pose. DISPLAY: gaze at active camera.
	var sec2 := get_secondary()
	if first_person:
		if sec2:
			var rel_yaw := wrapf(_yaw - _body_logic_yaw, -PI, PI)
			sec2.call("set_body_look", rel_yaw, _pitch)
			sec2.call("clear_gaze")
	elif display and sec2:
		sec2.call("clear_body_look")
		if _organs and float(_organs.call("navel_pose_t")) >= 0.0:
			sec2.call("clear_gaze")  # 插肚脐：低头看肚脐（网页 navelPoke 头颈姿势）
		else:
			sec2.call("set_gaze_target", _camera.global_position)
	if _loco and _organs:
		_loco.set("navel_t", _organs.call("navel_pose_t"))
		_loco.set("navel_stir", _organs.get("navel_stir_off"))

	if _loco:
		# After π visual offset, mesh forward = Body +Z. Invert prior -Z fwd/side signs.
		var local_vel := _body.global_transform.basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
		var fwd := clampf(local_vel.z / maxf(speed, 0.01), -1.0, 1.0)
		var side := clampf(-local_vel.x / maxf(speed, 0.01), -1.0, 1.0)
		var mag := clampf(Vector2(velocity.x, velocity.z).length() / maxf(speed, 0.01), 0.0, 1.0)
		if input_dir != Vector2.ZERO:
			var local_in := _body.global_transform.basis.inverse() * (
				basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y)
			)
			fwd = clampf(local_in.z, -1.0, 1.0)
			side = clampf(-local_in.x, -1.0, 1.0)
			mag = clampf(input_dir.length(), 0.0, 1.0)
		var airborne := not on_floor
		if airborne and str(_loco.get("current_clip")) != "jump":
			_loco.set("phase", 0.28)
		_loco.call("set_mode", _stance)
		_loco.call("apply_pose", fwd, side, mag, airborne, sprinting, delta, speed)

	# FP: stable stance eye (no head-bone bob); refresh after body yaw catch-up.
	_update_fp_eye(delta, direction != Vector3.ZERO, sprinting, not on_floor)
	if first_person:
		_pivot_rot = Vector3(_pitch, _yaw, 0.0)
		_pivot_off = _fp_eye_pivot_pos() - Vector3(0.0, _step_smooth, 0.0)
		_sync_pivot()
