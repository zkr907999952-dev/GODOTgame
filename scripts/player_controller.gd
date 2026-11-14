extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
const OrganRigScript = preload("res://scripts/organs/organ_rig.gd")
const CharacterLookScript = preload("res://scripts/character_look.gd")
## 角色控制器：展示互动 / 角色控制 双模式 + SoftLoco 网页 loco 动画驱动 Skeleton3D。
## Web loco bind: mesh faces +Z; Godot move uses -Z forward → visual Body needs π yaw offset.
const BODY_YAW_OFFSET := PI

enum GameMode { DISPLAY, CONTROL }

@export var move_speed: float = 1.65
@export var sprint_speed: float = 4.125  # 1.65 * 2.5 like web
@export var crouch_speed: float = 0.7425  # 1.65 * 0.45
@export var prone_speed: float = 0.462  # 1.65 * 0.28
@export var jump_velocity: float = 4.2
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
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _loco: Node
## 体内脏器 + 腹部透视 + 拖拽/击腹互动（scripts/organs/organ_rig.gd）
var _organs: Node
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
	_default_yaw = _yaw
	_default_pitch = _pitch
	_default_cam_dist = camera_distance
	_default_cam_height = camera_height
	_default_fp_fov = fp_fov
	_default_tp_fov = tp_fov
	# 展示（观察）模式光标可见：左键留给腹部互动，右键环绕（网页 OrbitControls）。
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_cam_shape = SphereShape3D.new()
	_cam_shape.radius = TP_COLLIDE_RADIUS
	_align_capsule_to_feet()
	_print_body_info()
	CharacterLookScript.apply(_body)
	# 网页 BodyFillLight：跟随相机的暖色补光，避免逆光时正面全黑（不投影）。
	_fill_light = OmniLight3D.new()
	_fill_light.name = "CameraFill"
	_fill_light.light_color = Color(0.95, 0.86, 0.79)
	_fill_light.omni_range = 4.0
	_fill_light.omni_attenuation = 1.6
	_fill_light.shadow_enabled = false
	_fill_light.light_specular = 0.25
	_fill_light.position = Vector3(0.0, 0.25, 0.0)
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
	if _col.shape is CapsuleShape3D:
		_capsule_stand_h = (_col.shape as CapsuleShape3D).height
		_capsule_stand_y = _col.position.y
		_cap_h_from = _capsule_stand_h
		_cap_h_to = _capsule_stand_h
		_cap_r_from = (_col.shape as CapsuleShape3D).radius
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


func get_organs() -> Node:
	return _organs


func get_camera() -> Camera3D:
	return _camera


func _organs_live() -> bool:
	return _organs != null and bool(_organs.get("ready_ok")) and bool(_organs.call("mode_is_live", ""))


## 屏幕点 → 世界射线（捕获鼠标时用屏幕中心）
func _screen_ray(screen: Vector2) -> Array:
	return [_camera.project_ray_origin(screen), _camera.project_ray_normal(screen)]


func _interact_point() -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_mouse_position()


## 左键按下：拖拽=抓住腹壁 / 击腹=释放冲击。命中腹部返回 true。
func _try_begin_interact(screen: Vector2) -> bool:
	if not _organs_live():
		return false
	var ray := _screen_ray(screen)
	var hit: Variant = _organs.call("ray_hit_belly", ray[0], ray[1])
	if hit == null:
		return false
	var mode := str(_organs.get("interact_mode"))
	if mode == "strike":
		_organs.call("strike_at", hit)
	elif mode == "drag":
		_organs.call("begin_drag", hit)
		_interact_held = true
		_interact_screen = screen
	return true


## 拖拽中：鼠标射线与「过抓取点、法线=相机前向」平面求交（网页 grab plane）
func _update_interact_drag(screen: Vector2) -> void:
	var ray := _screen_ray(screen)
	var grab: Vector3 = _organs.call("drag_grab_world")
	var n := -_camera.global_transform.basis.z
	var plane := Plane(n, grab)
	var hit: Variant = plane.intersects_ray(ray[0], ray[1])
	if hit != null:
		_organs.call("update_drag", hit)


func _end_interact() -> void:
	if _interact_held and _organs:
		_organs.call("end_drag")
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
	var target_w := global_position + _tp_target
	var dir := _tp_dir(_tp_yaw, _tp_elev)
	var want := _tp_collide(target_w, dir, _tp_dist)
	if snap or want < _tp_dist_eff:
		_tp_dist_eff = want  # 撞墙立刻收回，不穿模
	else:
		_tp_dist_eff += (want - _tp_dist_eff) * (1.0 - exp(-8.0 * delta))
	_pivot.position = _tp_target
	_pivot.rotation = Vector3(-_tp_elev, _tp_yaw, 0.0)
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
	if _fill_light:
		# 近距离时减弱，避免贴近皮肤过曝（点光源随距离平方衰减）。
		var near_k := clampf(pow(_tp_dist_eff / 2.2, 1.7), 0.05, 1.0)
		_fill_light.light_energy = 0.15 if first_person else 0.55 * near_k


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


func _apply_fp_mesh_visibility() -> void:
	for mi in _body.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null:
			continue
		mesh_i.visible = true
		if _fp_should_hide_mesh(mesh_i):
			mesh_i.layers = FP_HEAD_LAYER
	if first_person:
		_camera.cull_mask &= ~FP_HEAD_LAYER
	else:
		_camera.cull_mask |= FP_HEAD_LAYER


## Place capsule so its bottom matches mesh soles (AABB min.y ≈ 0 in character space).
func _align_capsule_to_feet() -> void:
	if not (_col.shape is CapsuleShape3D):
		return
	var cap := _col.shape as CapsuleShape3D
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
	if _col.shape is CapsuleShape3D:
		cap_bottom = _col.position.y - (_col.shape as CapsuleShape3D).height * 0.5
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


func _unhandled_input(event: InputEvent) -> void:
	# 脏器互动：左键（捕获鼠标时取屏幕中心，否则取光标）
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var lb := event as InputEventMouseButton
		if lb.pressed:
			if not ui_blocks_capture and _try_begin_interact(_interact_point()):
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
				if ui_blocks_capture:
					return
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
			if not ui_blocks_capture:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				toggle_play_mode()
			KEY_ESCAPE:
				# HUD handles Esc first via its own _unhandled_input (higher priority when panel open).
				# 第一人称：释放 / 重新捕获鼠标；观察视角光标一直可见。
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				elif first_person and not ui_blocks_capture:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			KEY_R:
				# 网页 R = 复位；这里复位视角 + 腹部形变。
				reset_camera()
				if _organs and _organs.has_method("reset_interaction"):
					_organs.call("reset_interaction")
			KEY_F:
				# 观察视角：循环视觉中心 面部→胸部→腹部→阴部
				if not first_person:
					var order := ["face", "chest", "belly", "groin"]
					var i := order.find(_tp_focus)
					set_tp_focus(order[(i + 1) % order.size()])
			KEY_X:
				# 网页 X：腹部透视开关
				if _organs:
					_organs.call("toggle_xray")
			KEY_Z:
				# Prone toggle (Z). Crouch is toggle Ctrl/C — handled in physics.
				_toggle_prone()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8:
				if _loco:
					var n: int = int(event.keycode) - KEY_0
					_loco.call("set_dance", "dance%d" % n)
					print("player: dance", n)
			KEY_0, KEY_9:
				if _loco:
					_loco.call("clear_dance")
					print("player: dance cleared")


## Crouch is toggle (Ctrl / C press). Release must NOT force stand. Prone stays Z toggle.
func _update_crouch_toggle() -> void:
	if not Input.is_action_just_pressed("crouch"):
		return
	if _stance == "prone":
		# Tap crouch while prone → stand (web tap exits prone then toggles crouch).
		_stance = "stand"
	elif _stance == "crouch":
		_stance = "stand"
	else:
		_stance = "crouch"
	_apply_stance_capsule()
	print("player: stance=", _stance)


func _toggle_prone() -> void:
	if _stance == "prone":
		_stance = "stand"
	else:
		_stance = "prone"
	_apply_stance_capsule()
	print("player: stance=", _stance)


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
	if not (_col.shape is CapsuleShape3D):
		return
	var cap := _col.shape as CapsuleShape3D
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
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	if first_person:
		_pivot.position = _fp_eye_pivot_pos()
		_camera.position = Vector3.ZERO
		_camera.near = 0.06
		_camera.fov = fp_fov
	else:
		_update_tp_camera(0.0)


## Smooth lerp between stance eyes (web stanceU smoothstep over STANCE_BLEND_DUR).
func _update_fp_eye_blend(delta: float) -> void:
	if _fp_eye_blend < 1.0:
		_fp_eye_blend = minf(1.0, _fp_eye_blend + delta / STANCE_BLEND_DUR)
	var t := _fp_eye_blend
	var u := t * t * (3.0 - 2.0 * t)
	_fp_eye_cur = _fp_eye_from.lerp(_fp_eye_to, u)


func _update_stance_capsule_blend(delta: float) -> void:
	if not (_col.shape is CapsuleShape3D):
		return
	if _stance_blend < 1.0:
		_stance_blend = minf(1.0, _stance_blend + delta / STANCE_BLEND_DUR)
	var t := _stance_blend
	var u := t * t * (3.0 - 2.0 * t)
	var cap := _col.shape as CapsuleShape3D
	cap.height = lerpf(_cap_h_from, _cap_h_to, u)
	cap.radius = lerpf(_cap_r_from, _cap_r_to, u)
	_col.position.y = lerpf(_cap_y_from, _cap_y_to, u)
	camera_height = lerpf(_cam_h_from, _cam_h_to, u)


## Body-local stance eye → CharacterBody local (Body has π yaw offset; +Z = facing).
func _fp_eye_pivot_pos() -> Vector3:
	var eye := _fp_eye_cur + Vector3(0.0, FP_EYE_LIFT, 0.0)
	# Body is child at origin with yaw = face + BODY_YAW_OFFSET; map body-local to player space.
	return _body.transform * eye


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


func _physics_process(delta: float) -> void:
	var display := play_mode == GameMode.DISPLAY
	if not display:
		_update_crouch_toggle()
	_update_fp_eye_blend(delta)
	_update_stance_capsule_blend(delta)

	var on_floor := is_on_floor()
	if not on_floor:
		velocity.y -= _gravity * delta
		_air_time += delta
	else:
		_air_time = 0.0
		if not display and Input.is_action_just_pressed("jump"):
			if _stance == "prone":
				_stance = "stand"
				_apply_stance_capsule()
			else:
				velocity.y = jump_velocity

	var input_dir := Vector2.ZERO
	if not display:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var direction := (basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var sprinting := (not display) and Input.is_action_pressed("sprint") and _stance == "stand"
	var speed := move_speed
	match _stance:
		"crouch":
			speed = crouch_speed
		"prone":
			speed = prone_speed
		_:
			speed = sprint_speed if sprinting else move_speed

	if display:
		# Lock locomotion — stand in place for display / tool interaction.
		velocity.x = 0.0
		velocity.z = 0.0
		direction = Vector3.ZERO
		input_dir = Vector2.ZERO
		sprinting = false
	elif direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	# Visual facing: mesh +Z vs Godot -Z → BODY_YAW_OFFSET (π).
	# CONTROL/FP: while moving, body faces camera yaw immediately (no deadzone lag).
	# Idle free-look keeps ±60° / ~120° deadzone; DISPLAY keeps current facing.
	if first_person:
		var look_yaw := _yaw
		var moving := direction != Vector3.ZERO or not on_floor
		_body_logic_yaw = debug_next_body_yaw(look_yaw, _body_logic_yaw, moving)
		_body.rotation.y = _body_logic_yaw + BODY_YAW_OFFSET
	elif direction != Vector3.ZERO:
		var face_yaw := atan2(-direction.x, -direction.z) + BODY_YAW_OFFSET
		_body.rotation.y = lerp_angle(
			_body.rotation.y, face_yaw, clampf(14.0 * delta, 0.0, 1.0)
		)

	move_and_slide()

	# CONTROL/FP: body look BEFORE apply_pose. DISPLAY: gaze at active camera.
	var sec2 := get_secondary()
	if first_person:
		if sec2:
			var rel_yaw := wrapf(_yaw - _body_logic_yaw, -PI, PI)
			sec2.call("set_body_look", rel_yaw, _pitch)
			sec2.call("clear_gaze")
	elif display and sec2:
		sec2.call("clear_body_look")
		sec2.call("set_gaze_target", _camera.global_position)

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
	if first_person:
		_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
		_pivot.position = _fp_eye_pivot_pos()
