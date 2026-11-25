extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
const OrganRigScript = preload("res://scripts/organs/organ_rig.gd")
const SurgerySystemScript = preload("res://scripts/surgery/surgery_system.gd")
const CharacterLookScript = preload("res://scripts/character_look.gd")
const WeaponSystemScript = preload("res://scripts/weapons/weapon_system.gd")
const CharacterHealthScript = preload("res://scripts/character_health.gd")
const RagdollSystemScript = preload("res://scripts/ragdoll_system.gd")
const HitReactionScript = preload("res://scripts/hit_reaction.gd")
const CharacterActionsScript = preload("res://scripts/body/character_actions.gd")
const CorpseDragScript = preload("res://scripts/corpse_drag.gd")
const CombatDamage := preload("res://scripts/combat_damage.gd")
const CharacterHitboxesScript := preload("res://scripts/character_hitboxes.gd")
const GetupBlendScript := preload("res://scripts/getup_blend.gd")
## 角色控制器：展示互动 / 角色控制 双模式 + SoftLoco 网页 loco 动画驱动 Skeleton3D。
## Web loco bind: mesh faces +Z; Godot move uses -Z forward → visual Body needs π yaw offset.
const BODY_YAW_OFFSET := PI

enum GameMode { DISPLAY, CONTROL }

@export var move_speed: float = 1.06  # walk clip stride/dur ≈ 1.489/1.4
@export var sprint_speed: float = 5.0  # run clip ≈ 2.865/0.533
@export var crouch_speed: float = 0.85  # crouchWalk ≈ 1.05/1.233
@export var prone_speed: float = 0.24  # proneWalk ≈ 0.549/2.333
@export var ads_speed: float = 0.78  # 开镜慢步，仍用 walk 步幅
## 网页 FP_GRAV=20（比 Godot 默认 9.8 更干脆）；跳高保持约 0.9m（6²/(2·20)）。
@export var jump_velocity: float = 6.0
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.0025
@export var touch_look_sensitivity: float = 0.014
## 举枪瞄准：true=切换，false=长按。手机默认切换；PC 右键同样遵守。
var ads_toggle: bool = true
var _rmb_drag_owned: bool = false
## 最近一次请求的屏幕方向（测试 / 调试）
var screen_orientation_request: String = "sensor"
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
## 0.3.9：检查床观察视角的中键平移量（目标点每帧跟随身体焦点，平移量叠加在焦点上）。
var _bed_pan: Vector3 = Vector3.ZERO
var _pan_drag: bool = false
var _fp_pan: Vector3 = Vector3.ZERO
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
## Set by VehicleSystem while the player is in a car / plane / exam bed.
var occupancy: String = ""
var occupier: Node = null
## CameraPivot 是 top_level：每帧用「插值后的」角色位置 + 偏移摆放（物理插值下相机不抖）
var _pivot_off: Vector3 = Vector3(0.0, 1.4, 0.0)
var _pivot_rot: Vector3 = Vector3.ZERO
var _loco: Node
## 体内脏器 + 腹部透视 + 拖拽/击腹互动（scripts/organs/organ_rig.gd）
var _organs: Node
var _surgery: Node = null
## 武器模块（scripts/weapons/weapon_system.gd）
var _weapons: Node
var _health: Node
var _ragdoll: Node
var _hit_react: Node
var actions = CharacterActionsScript.new()
var _corpse_drag: Node
var _hitboxes: Node = null
var _getup: RefCounted = null
## 0.3.8：胶囊移动体的「脚底支撑」——胶囊圆底在台阶边缘会滑落，用一块扁圆柱探测脚下地面，
## 在台阶边缘 / 下楼梯时保持站稳，表现与旧圆柱一致。
var _ledge_support: bool = false
var _was_grounded: bool = false
var _col_layer_live: int = 2
var _col_mask_live: int = 1
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
const FP_EYE_LIFT := 0.02
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
	add_to_group("health_body")
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
	# 0.4.0 拖影根因：Godot 4.5+ 的场景树物理插值里，关闭插值的子节点仍跟随「已插值」的父节点。
	# Body 每帧已手动加上「插值原点 − 物理原点」偏移，若 Player 本身再被引擎插值，偏移就被加了两次，
	# 身体比镜头多落后最多一个物理步、且随插值分数来回跳 → 走跑时快速闪烁的重影。
	# 所以 Player 根节点不再走引擎插值，渲染位置完全由 _body_interp_apply / 器官 _process 摆放决定。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	_surgery = SurgerySystemScript.new()
	_surgery.name = "SurgerySystem"
	add_child(_surgery)
	if skel:
		_surgery.call("setup", self, skel, _organs)
	_weapons = WeaponSystemScript.new()
	_weapons.name = "Weapons"
	add_child(_weapons)
	_weapons.call("setup", self, _camera, skel)
	_health = CharacterHealthScript.new()
	_health.name = "Health"
	add_child(_health)
	# 控制角色默认 1000 血；分身仍是 100。
	_health.max_hp = 1000.0
	_health.reset(1000.0)
	_health.died.connect(_on_character_died)
	_health.revived.connect(_on_character_revived)
	_health.hp_changed.connect(func(_h, _m): pass)
	_ragdoll = RagdollSystemScript.new()
	_ragdoll.name = "Ragdoll"
	add_child(_ragdoll)
	if skel:
		_ragdoll.call("setup", skel, self)
	_hit_react = HitReactionScript.new()
	_hit_react.name = "HitReaction"
	add_child(_hit_react)
	if skel:
		_hit_react.call("setup", skel, self)
	_corpse_drag = CorpseDragScript.new()
	_corpse_drag.name = "CorpseDrag"
	add_child(_corpse_drag)
	_corpse_drag.call("setup", self, skel)
	if skel:
		_hitboxes = CharacterHitboxesScript.new()
		add_child(_hitboxes)
		_hitboxes.call("setup", skel, self)
		for hb in _hitboxes.call("bodies"):
			add_collision_exception_with(hb)
	# 角色胶囊互相碰撞，并与布娃娃骨骼碰撞。Godot 碰撞是双向 AND：
	# 双方 layer/mask 都要能对上。布娃娃骨骼 mask 现已含角色层，同体骨骼用 exception 防自碰。
	collision_layer = 2
	collision_mask = 1 | 2
	_col_layer_live = collision_layer
	_col_mask_live = collision_mask
	if _col.shape is CapsuleShape3D or _col.shape is CylinderShape3D:
		_capsule_stand_h = _shape_h()
		_capsule_stand_y = _col.position.y
		_cap_h_from = _capsule_stand_h
		_cap_h_to = _capsule_stand_h
		_cap_r_from = _shape_r()
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
	return first_person and weapon_drawn()


## 任意视角下枪是否在手上（收枪 / 观察点击射击 / 捂腹判断用，不要求第一人称）
func weapon_drawn() -> bool:
	return _weapons != null and bool(_weapons.call("is_armed"))


func get_surgery() -> Node:
	return _surgery


func active_surgery() -> Node:
	var g := get_parent()
	if g and g.has_method("surgery_system_of"):
		var s: Node = g.call("surgery_system_of")
		if s:
			return s
	return _surgery


func surgery_look_locked() -> bool:
	var s := active_surgery()
	if s == null or not s.has_method("look_locked"):
		return false
	# 观察模式：工具只用左键，右键环绕 / 中键平移保持可用。
	if is_display_mode():
		return false
	return bool(s.call("look_locked"))


func surgery_look_enabled() -> bool:
	var s := active_surgery()
	if s == null or not s.has_method("look_enabled"):
		return false
	return bool(s.call("look_enabled"))


func get_organs() -> Node:
	return _organs


func get_health() -> Node:
	return _health


func get_hp() -> float:
	return float(_health.hp) if _health else 100.0


func get_max_hp() -> float:
	return float(_health.max_hp) if _health else 100.0


func is_dead() -> bool:
	return _health != null and bool(_health.dead)


func apply_damage(amount: float, info: Dictionary = {}) -> float:
	if _health == null:
		return 0.0
	var taken := float(_health.call("apply_damage", amount, info))
	if taken > 0.0 and not is_dead() and _hit_react:
		_hit_react.call("apply_from_info", info, taken)
	return taken


func apply_hit_reaction(info: Dictionary) -> void:
	if is_dead() or _hit_react == null:
		return
	# ballistics 已先 apply_damage；这里避免同一发再叠一次，只在尚未记录时补。
	if _hit_react.get("last_amp") > 0.0 and _hit_react.is_active():
		return
	_hit_react.call("apply_from_info", info, float(info.get("damage", 20.0)))


func get_hit_reaction() -> Node:
	return _hit_react



func get_actions():
	return actions


func is_ragdoll() -> bool:
	return _ragdoll != null and bool(_ragdoll.get("active"))


func get_corpse_drag() -> Node:
	return _corpse_drag


func toggle_corpse_drag() -> bool:
	if _corpse_drag == null:
		return false
	return bool(_corpse_drag.call("toggle"))


func revive(to: float = -1.0) -> void:
	if _health:
		_health.call("revive", to)


func get_ragdoll() -> Node:
	return _ragdoll


func get_head_world_position() -> Vector3:
	if is_dead() and _ragdoll and _ragdoll.has_method("get_follow_point"):
		var pb = _ragdoll.get("bones").get("C_Head_a") if _ragdoll.get("bones") else null
		if pb and is_instance_valid(pb):
			return (pb as Node3D).global_position + Vector3.UP * 0.16
	var skel := get_skeleton()
	if skel:
		var i := skel.find_bone("C_Head_a")
		if i >= 0:
			return (skel.global_transform * skel.get_bone_global_pose(i)).origin + Vector3.UP * 0.16
	return global_position + Vector3.UP * 1.62


func _set_pose_drivers_frozen(on: bool) -> void:
	if _loco:
		_loco.set("frozen", on)
	var sec := get_secondary()
	if sec:
		sec.set("corpse_mode", on)
		if on:
			sec.set("breath_enabled", false)
			sec.set("blink_enabled", false)
	if _organs:
		_organs.set("frozen", on)
	if _weapons:
		_weapons.set("weapon_ik", false)
		if _loco:
			_loco.set("weapon_ik", false)


func _on_character_died(info: Dictionary) -> void:
	_set_pose_drivers_frozen(true)
	_getup = null
	if _hitboxes:
		_hitboxes.call("set_enabled", false)
	if _col:
		_col.disabled = true
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	if _weapons and _weapons.has_method("holster") and bool(_weapons.call("is_armed")):
		_weapons.call("holster")
	var dir: Vector3 = CombatDamage.vec3_of(info, ["dir"], Vector3.FORWARD)
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	else:
		dir = dir.normalized()
	var hit: Vector3 = CombatDamage.vec3_of(info, ["entry", "hit", "pos"], Vector3.ZERO)
	var par: Dictionary = info.get("par", {})
	var col = info.get("collider")
	var imp := Vector3.ZERO
	if _ragdoll and _ragdoll.has_method("impulse_from_ballistics") and not par.is_empty():
		imp = _ragdoll.call("impulse_from_ballistics", par, dir)
	elif dir.length_squared() > 1e-8:
		imp = dir.normalized() * 6.0
	if _ragdoll:
		_ragdoll.call("start", imp, hit, col)
	# 切到观察相机并跟随尸体，菜单仍可用；不允许再进第一人称走动。
	if first_person:
		set_play_mode(GameMode.DISPLAY)
	if has_method("set_tp_view"):
		var yaw := float(_yaw)
		call("set_tp_view", yaw + 0.6, 0.28, 2.4, false)
	print("player: died, ragdoll started")


func _on_character_revived() -> void:
	# 把原点移到尸体骨盆投影的地面，再关掉布娃娃、恢复站立胶囊。
	# 0.3.8：从布娃娃姿态平滑过渡到蹲下，再站起（GetupBlend）。
	var skel := get_skeleton()
	var snap: Array[Transform3D] = []
	if _ragdoll and bool(_ragdoll.get("active")) and skel:
		snap = GetupBlendScript.capture_world(skel)
	var feet := global_position
	if _ragdoll and _ragdoll.has_method("get_pelvis_point"):
		var p: Vector3 = _ragdoll.call("get_pelvis_point")
		var space := get_world_3d().direct_space_state if get_world_3d() else null
		if space:
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.8, p + Vector3.DOWN * 3.0, 1)
			var hit := space.intersect_ray(q)
			feet = hit["position"] if not hit.is_empty() else Vector3(p.x, global_position.y, p.z)
		else:
			feet = Vector3(p.x, global_position.y, p.z)
	if _ragdoll:
		_ragdoll.call("stop")
	_set_pose_drivers_frozen(false)
	var sec := get_secondary()
	if sec:
		sec.set("breath_enabled", true)
		sec.set("blink_enabled", true)
		sec.set("hair_enabled", true)
	if _col:
		_col.disabled = false
	collision_layer = _col_layer_live
	collision_mask = _col_mask_live
	if _hitboxes:
		_hitboxes.call("set_enabled", true)
	_set_stance("crouch" if not snap.is_empty() else "stand")
	global_position = feet
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	_getup = null
	if not snap.is_empty():
		_getup = GetupBlendScript.new()
		_getup.call("begin", skel, snap)
	if _loco and _loco.has_method("apply_pose"):
		_loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)
	print("player: revived at ", feet)



func _after_pose_feedback(delta: float) -> void:
	var skip := PackedStringArray(["L_Shoulder_a", "R_Shoulder_a"])
	if _weapons and bool(_weapons.call("is_armed")) and float(_weapons.get("_ik_w")) > 0.2:
		for n in ["R_UpperArm_a", "R_Forearm_a", "R_Hand_a"]:
			skip.append(n)
		if _corpse_drag and _corpse_drag.call("is_dragging"):
			pass
		else:
			for n in ["L_UpperArm_a", "L_Forearm_a", "L_Hand_a"]:
				skip.append(n)
	if _hit_react:
		_hit_react.call("apply_to_skeleton", delta, skip)
		if _hit_react.has_method("apply_cover") and not weapon_drawn():
			_hit_react.call("apply_cover", delta)
	# 检查床上的动作由 VehicleSystem 在坐姿之后套用，避免打两遍。
	if actions and occupancy != "exam_bed":
		var org: Node = get_organs()
		var sk: Skeleton3D = get_skeleton()
		actions.step(delta, org)
		actions.apply_pose(sk, org)
	if _corpse_drag:
		if _corpse_drag.call("is_dragging"):
			_corpse_drag.call("apply_left_hand")
			_corpse_drag.call("physics_tick", delta)
	_tick_getup(delta)


## 起身过渡：动画写完骨骼后再混入布娃娃姿态；蹲够了自动站起。
func _tick_getup(delta: float) -> void:
	if _getup == null:
		return
	if bool(_getup.call("apply", delta)):
		if not _set_stance("stand"):
			pass  # 头顶空间不足时保持蹲姿
	if not bool(_getup.call("is_active")):
		_getup = null


func is_getting_up() -> bool:
	return _getup != null


## 0.3.8「复原身体」：满血；死亡则复活并从布娃娃过渡到蹲下再站起；清除伤口、弹孔和手术切口。
func restore_body() -> void:
	if _health == null:
		return
	if is_dead():
		_health.call("revive", float(_health.get("max_hp")))
	else:
		_health.call("reset", float(_health.get("max_hp")))
	if _organs and _organs.has_method("reset_interaction"):
		_organs.call("reset_interaction")
	if _organs and _organs.has_method("clear_wounds"):
		_organs.call("clear_wounds")
	if _hit_react and _hit_react.has_method("clear"):
		_hit_react.call("clear")
	if _surgery and _surgery.has_method("restore_body"):
		_surgery.call("restore_body")


func _update_corpse_drag_aim() -> void:
	if _corpse_drag == null:
		return
	if is_dead():
		if _corpse_drag.call("is_dragging"):
			_corpse_drag.call("drop", "dead")
		return
	var cam := get_camera()
	if cam == null:
		return
	var ex: Array[RID] = []
	ex.append(get_rid())
	_corpse_drag.call("update_aim", cam.global_position, -cam.global_transform.basis.z, ex)


func _stomp_ragdolls(delta: float) -> void:
	# 踩踏：角色胶囊（已与布娃娃碰撞）再给脚下的尸体一个向下/挤开的冲量，走上去会被物理挤开。
	if is_dead() or input_locked:
		return
	var w3 := get_world_3d()
	if w3 == null:
		return
	var feet := global_position + Vector3(0, 0.12, 0)
	var sph := SphereShape3D.new()
	sph.radius = 0.28
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sph
	q.transform = Transform3D(Basis.IDENTITY, feet)
	q.collision_mask = 2
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	var hits := w3.direct_space_state.intersect_shape(q, 8)
	if hits.is_empty():
		return
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var seen := {}
	for h in hits:
		var col = h.get("collider")
		if not (col is PhysicalBone3D):
			continue
		var host: Node = col
		while host:
			if host.has_method("is_dead") and host.has_method("get_ragdoll") and bool(host.call("is_dead")):
				break
			host = host.get_parent()
		if host == null or host == self:
			continue
		# 正在拖这具尸体时不要再踩飞。
		if _corpse_drag and _corpse_drag.call("is_dragging") and _corpse_drag.get("grabbed_body") == host:
			continue
		if seen.has(host):
			continue
		seen[host] = true
		var rag: Node = host.call("get_ragdoll")
		if rag == null or not rag.has_method("apply_stomp"):
			continue
		var at: Vector3 = (col as Node3D).global_position
		var sideways := hv * 2.8
		if sideways.length() < 2.2:
			# 即使站着不动，踩上去也要能把尸体挤开一点。
			var away: Vector3 = at - global_position
			away.y = 0.0
			if away.length_squared() < 1e-6:
				away = Vector3.RIGHT
			sideways = away.normalized() * maxf(sideways.length(), 2.6)
		var down := Vector3(0, -8.5 - minf(6.0, absf(velocity.y) * 2.0), 0)
		rag.call("apply_stomp", at, sideways + down)
	# 踩在尸体上时取消布娃娃对角色的向上反推，避免把人弹飞。
	_cancel_ragdoll_launch(not seen.is_empty())


func _cancel_ragdoll_launch(stomping: bool = false) -> void:
	# 只抑制布娃娃反推，活着的角色胶囊互撞不在这里处理，以免两个人一起被弹开。
	var hit_bone := stomping
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c == null:
			continue
		var col = c.get_collider()
		if col is PhysicalBone3D:
			hit_bone = true
			# 把向上的分离速度清掉，水平速度保留。
			var n: Vector3 = c.get_normal()
			if n.y > 0.35 and velocity.y > 0.0:
				velocity.y = 0.0
	if hit_bone and velocity.y > 0.0:
		velocity.y = 0.0
	if hit_bone and is_on_floor():
		# 贴地踩尸，不要被挤离地面。
		velocity.y = minf(velocity.y, 0.0)


## 观察模式：在点击位置沿视线垂直向内打一发（与互动同一套屏幕坐标），可触发特写。
## 不要求点中人物；拖视不像开火。
func observe_tap_fire(screen: Vector2) -> bool:
	if first_person or not weapon_drawn() or is_dead() or input_locked:
		return false
	if _weapons == null:
		return false
	var cam := get_camera()
	if cam == null:
		return false
	# 与互动相同：把逻辑坐标换到 project_ray 用的视口像素，避免手机 DPI 缩放送偏。
	var ray := _screen_ray(screen)
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	if dir.length_squared() < 1e-10:
		return false
	dir = dir.normalized()
	# 观察模式要能打中角色本体（第一人称排除自己，避免从相机里打到自己的胶囊）。
	if _weapons.has_method("fire_along_ray"):
		return bool(_weapons.call("fire_along_ray", from, dir, true))
	if _weapons.has_method("fire_at_point"):
		return bool(_weapons.call("fire_at_point", from + dir * 8.0))
	return false


func _collect_collision_rids(n: Node, out: Array[RID]) -> void:
	if n is CollisionObject3D:
		out.append((n as CollisionObject3D).get_rid())
	for ch in n.get_children():
		_collect_collision_rids(ch, out)


func _wound_body_of(n: Node) -> Node:
	while n:
		if n.is_in_group("wound_body") or n.has_method("get_organs") or n.has_method("get_hp"):
			return n
		n = n.get_parent()
	return null


func get_camera() -> Camera3D:
	return _camera


## 0.4.07 附身：当前身体的全部「随身体走」的节点（网格骨架 + 走跑 + 脏器 + 手术 + 布娃娃 + 受击 + 命中盒）。
func rig_nodes() -> Dictionary:
	return {"body": _body, "loco": _loco, "organs": _organs, "surgery": _surgery,
		"ragdoll": _ragdoll, "hit_react": _hit_react, "hitboxes": _hitboxes}


## 交出身体前：去掉第一人称专用的头部图层 / 只投影副本，让它作为分身被正常看见。
func release_rig_visuals() -> void:
	for px in _fp_shadow_proxies:
		if is_instance_valid(px):
			px.queue_free()
	_fp_shadow_proxies.clear()
	if _body:
		for mi in _body.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m and m.layers == FP_HEAD_LAYER:
				m.layers = 1 | CHAR_LIGHT_LAYER
	if _hitboxes:
		for hb in _hitboxes.call("bodies"):
			if is_instance_valid(hb):
				remove_collision_exception_with(hb)


## 接管新身体（节点已由 Possession 挂到本节点下）。
func adopt_rig(r: Dictionary) -> void:
	_body = r["body"]
	_loco = r["loco"]
	_organs = r["organs"]
	_surgery = r["surgery"]
	_ragdoll = r["ragdoll"]
	_hit_react = r["hit_react"]
	_hitboxes = r["hitboxes"]
	var skel := _find_skeleton(_body)
	if _surgery:
		_surgery.set("player", self)
	if _ragdoll:
		_ragdoll.set("_host", self)
	if _hit_react:
		_hit_react.set("_host", self)
	if _hitboxes:
		_hitboxes.set("host", self)
		for hb in _hitboxes.call("bodies"):
			if is_instance_valid(hb):
				(hb as Node).set_meta("hitbox_host", self)
				add_collision_exception_with(hb)
	if _weapons:
		_weapons.set("skeleton", skel)
		_weapons.set("_ik_w", 0.0)
	if _corpse_drag:
		_corpse_drag.call("setup", self, skel)
	if _loco:
		_loco.set("frozen", false)
		_loco.set("weapon_ik", false)
	var sec := get_secondary()
	if sec:
		sec.set("corpse_mode", false)
	if _organs:
		_organs.set("frozen", false)
	_getup = null
	_body.position = Vector3.ZERO
	_body.rotation = Vector3(0.0, _body_logic_yaw + BODY_YAW_OFFSET, 0.0)
	_body.visible = true
	_body_rest_pos = Vector3.ZERO
	_body_interp_ready = false
	_apply_fp_mesh_visibility()


## 附身后立即换姿态（不受头顶空间检查之外的限制）。
func force_stance(st: String) -> void:
	if st == "" or st == _stance:
		return
	if not _set_stance(st):
		_set_stance("crouch" if st == "prone" else "stand")


func fp_view_transform() -> Transform3D:
	# 第一人称视线变换，观察视角下也按 yaw/pitch/眼位构造，不用环绕相机。
	# 尸体拖拽的持握点跟这条视线走，转视角才会把尸体拉起来。
	var off := _fp_eye_pivot_pos() - Vector3(0.0, _step_smooth, 0.0)
	return Transform3D(Basis.from_euler(Vector3(_pitch, _yaw, 0.0)), _base_origin() + off)


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
## t27u：身体网格（Body）不再交给引擎物理插值，而是每个渲染帧用与镜头完全相同的插值位置摆放
## （物理帧开始时归位）。这样身体、手臂 IK、挂在镜头上的枪三者用同一个插值结果，
## 走跑/跳跃时不再出现「枪按插值平滑、身体按物理帧跳」造成的手晃、穿模和虚影。
var _body_rest_pos := Vector3.ZERO
var _body_interp_ready := false


func _body_interp_reset() -> void:
	if occupancy != "":
		return
	if _body and _body_interp_ready:
		_body.position = _body_rest_pos + _fp_body_off


func _body_interp_apply() -> void:
	if occupancy != "":
		return
	if _body == null:
		return
	if not _body_interp_ready:
		_body_rest_pos = _body.position
		_body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_body_interp_ready = true
	if is_dead():
		_body.position = _body_rest_pos
		return
	var off := _base_origin() - global_position
	if not off.is_finite() or off.length() > 1.0:
		off = Vector3.ZERO
	# 0.4.08：保留第一人称的「身体后退」偏移（_fp_body_off）。0.4.07 的插值写回把它每个渲染帧
	# 冲掉 → 奔跑时身体回到眼点下方，相机切进自己的脖子（validate 的 fp clip）。
	_body.position = _body_rest_pos + _fp_body_off + global_transform.basis.inverse() * off


## 0.4.08：坐在跑车 / 战斗机里时返回载具（插值后）的世界变换，乳摇与外露肠管据此在载具局部系里模拟；否则 null。
func vehicle_carrier() -> Variant:
	if occupancy != "car" and occupancy != "plane":
		return null
	var vs0: Node = get_parent().get("vehicle_system") if get_parent() else null
	if vs0 == null or not vs0.has_method("seat_carrier_xf"):
		return null
	return vs0.call("seat_carrier_xf")


## 自检：身体渲染偏移（米）与镜头插值偏移之差，应为 0。
func debug_body_interp_error() -> float:
	if _body == null:
		return 99.0
	var want := _base_origin() - global_position
	var got := (_body.global_position - global_position) - global_transform.basis * (_body_rest_pos + _fp_body_off)
	return got.distance_to(want)


## 自检（0.4.0）：引擎实际渲染的 Body 位置与镜头插值原点推出的期望位置之差（米），应≈0。
func debug_body_render_error() -> float:
	if _body == null:
		return 99.0
	var want := _base_origin() + global_transform.basis * (_body_rest_pos + _fp_body_off)
	# Player 与 Body 都不走引擎插值 → 渲染变换就是 global_transform（若 Player 走插值，这里会再叠一层插值偏移）。
	var got := _body.global_position
	if physics_interpolation_mode != Node.PHYSICS_INTERPOLATION_MODE_OFF and is_physics_interpolated_and_enabled():
		got += get_global_transform_interpolated().origin - global_position
	return got.distance_to(want)


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


## 把输入/控件逻辑坐标转换成 Camera3D.project_ray_* 用的视口像素。
## 手机上 HUD 会按 DPI 设置 Window.content_scale_size，2D 逻辑尺寸 ≠ 3D 视口像素；
## 若不换算，点在肚子上的射线会打到画面边角，观察模式单击互动和双击环绕都会失效。
func to_camera_pixel(p: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return p
	var backing := Vector2(vp.size)
	var vis := vp.get_visible_rect().size
	if backing.x > 1.0 and vis.x > 1.0 and (absf(backing.x - vis.x) > 0.5 or absf(backing.y - vis.y) > 0.5):
		return Vector2(p.x * backing.x / vis.x, p.y * backing.y / vis.y)
	return p


## 真机事件坐标可能是逻辑像素、物理 backing，或还带窗口变换。穷举几种解释，避免只在一种约定下自检通过。
func pointer_variants(p: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var seen := {}
	var add := func(q: Vector2) -> void:
		var k := Vector2i(int(round(q.x)), int(round(q.y)))
		if seen.has(k):
			return
		seen[k] = true
		out.append(q)
	add.call(p)
	add.call(to_camera_pixel(p))
	var vp := get_viewport()
	if vp:
		var backing := Vector2(vp.size)
		var vr := vp.get_visible_rect()
		var vis := vr.size
		if backing.x > 1.0 and vis.x > 1.0:
			# 逻辑 ↔ 物理 backing；visible_rect 可能有偏移（刘海/扩展拉伸）
			add.call(Vector2(p.x * vis.x / backing.x, p.y * vis.y / backing.y))
			add.call(Vector2(p.x * backing.x / vis.x, p.y * backing.y / vis.y))
			var local := p - vr.position
			add.call(local)
			add.call(Vector2(local.x * backing.x / vis.x, local.y * backing.y / vis.y))
			add.call(Vector2(p.x * backing.x / vis.x, p.y * backing.y / vis.y) + vr.position)
		var xf := vp.get_final_transform()
		add.call(xf * p)
		add.call(xf.affine_inverse() * p)
		var win := get_window()
		if win and win.content_scale_factor > 0.0 and absf(win.content_scale_factor - 1.0) > 0.01:
			add.call(p * win.content_scale_factor)
			add.call(p / win.content_scale_factor)
		# scaling_3d_scale 不应影响 project_ray 坐标系，但仍穷举，避免驱动/导出差异
		var s3 := vp.scaling_3d_scale
		if s3 > 0.05 and absf(s3 - 1.0) > 0.01:
			add.call(p * s3)
			add.call(p / s3)
	return out


## 屏幕点 → 世界射线（捕获鼠标时用屏幕中心）
func _hover_surgery_tool() -> void:
	var s := active_surgery()
	if s == null or not bool(s.call("is_active")) or not s.has_method("hover_tool"):
		return
	var tool := str(s.call("current_tool"))
	if tool != "retractor" and tool != "forceps":
		return
	var screen := Vector2.ZERO
	if get_viewport():
		screen = _interact_point(get_viewport().get_mouse_position())
	var ray: Array = _screen_ray(screen)
	s.call("hover_tool", ray[0], ray[1])


func _screen_ray(screen: Vector2) -> Array:
	var p := to_camera_pixel(screen)
	if _ptr_mode >= 0:
		var vs := pointer_variants(screen)
		if _ptr_mode < vs.size():
			p = vs[_ptr_mode]
	return [_camera.project_ray_origin(p), _camera.project_ray_normal(p)]


func _interact_point(ev_pos: Vector2) -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var vp := get_viewport()
		return Vector2(vp.get_visible_rect().size) * 0.5 if vp else ev_pos
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
	_last_interact_via_navel = false
	var surg := active_surgery()
	if surg and bool(surg.call("is_active")):
		if not bool(surg.call("has_tool")):
			return false
		# 触屏走独立路径（多坐标解释 + 像素容差）；鼠标仍用原来的单射线，避免回归。
		if _touch_surgery:
			return _try_begin_surgery_touch(screen, surg)
		if surg.has_method("set_touch_pick"):
			surg.call("set_touch_pick", false)
		var ray: Array = _screen_ray(screen)
		if bool(surg.call("begin_stroke", ray[0], ray[1])):
			_interact_held = true
			_interact_screen = screen
			return true
		return false
	if not _organs_live():
		return false
	var variants := pointer_variants(screen)
	# 若已经锁定过一种坐标解释，先试它，再试其余
	if _ptr_mode >= 0 and _ptr_mode < variants.size():
		var pref: Vector2 = variants[_ptr_mode]
		variants.remove_at(_ptr_mode)
		variants.insert(0, pref)
	var mode := str(_organs.get("interact_mode"))
	if mode == "" or mode == "none":
		mode = "drag"
	var is_tool := mode == "fist" or mode == "bayonet" or mode == "navel"
	# 优先用正确换算后的主坐标。其他坐标解释只在主射线打空时作候选，
	# 并用「命中点投回屏幕后与实际点击的距离」评分，避免错误空间擦到肚脐后被锁死。
	var primary := to_camera_pixel(screen)
	var best_i := -1
	var best_score := INF
	var best_rig: Node = null
	var best_hit: Variant = null
	var best_origin := Vector3.ZERO
	var best_dir := Vector3.ZERO
	var primary_i := variants.find(primary)
	if primary_i < 0:
		variants.insert(0, primary)
		primary_i = 0
	for i in variants.size():
		var p: Vector2 = variants[i]
		var origin: Vector3 = _camera.project_ray_origin(p)
		var dir: Vector3 = _camera.project_ray_normal(p)
		var rig := pick_interact_rig(origin, dir)
		if rig == null:
			continue
		var hit: Variant = null
		if not is_tool:
			hit = rig.call("ray_hit_belly", origin, dir)
			if hit == null:
				continue
		var world: Vector3 = hit if hit is Vector3 else (origin + dir * float(rig.call("ray_pick_distance", origin, dir)))
		if _camera.is_position_behind(world):
			continue
		var proj: Vector2 = _camera.unproject_position(world)
		# 屏幕误差：实际点击应落在命中点附近。主坐标额外加权。
		var screen_err := minf(proj.distance_to(screen), proj.distance_to(primary))
		var score := screen_err
		if i == primary_i:
			score *= 0.65
		if score < best_score:
			best_score = score
			best_i = i
			best_rig = rig
			best_hit = hit
			best_origin = origin
			best_dir = dir
	# 屏幕误差过大说明只是错误空间擦到了身体，不当作命中。
	if best_i >= 0 and best_rig != null and best_score <= 90.0:
		if is_tool:
			if best_rig.get("interact_mode") != mode:
				best_rig.call("copy_settings_from", _organs)
			var cam_fwd := -_camera.global_transform.basis.z
			if not bool(best_rig.call("tool_begin", best_origin, best_dir, cam_fwd)):
				var near_vs: Array[Vector2] = [primary, screen]
				return _try_begin_interact_near(screen, near_vs)
			_interact_target = best_rig
			_interact_held = true
			_interact_screen = screen
			_ptr_mode = best_i
			_last_interact_via_navel = false
			return true
		_interact_target = best_rig
		if mode == "strike":
			best_rig.call("strike_at", best_hit)
		elif mode == "drag":
			best_rig.call("begin_drag", best_hit)
			_interact_held = true
			_interact_screen = screen
		_ptr_mode = best_i
		_last_interact_via_navel = false
		return true
	# 精确射线都未命中：仅当实际点击靠近肚脐投影时才兜底，绝不把远处点击吸到肚脐。
	var near_vs: Array[Vector2] = [primary, screen]
	return _try_begin_interact_near(screen, near_vs)


## 拖拽中：鼠标射线与「过抓取点、法线=相机前向」平面求交（网页 grab plane）

func _pointer_to_navel_dist(p: Vector2, navel: Vector3) -> float:
	var sp: Vector2 = _camera.unproject_position(navel)
	var vp := get_viewport()
	var backing := Vector2(vp.size) if vp else Vector2(1280, 720)
	var vis := vp.get_visible_rect().size if vp else backing
	var sp_log := Vector2(sp.x * vis.x / backing.x, sp.y * vis.y / backing.y) if backing.x > 1.0 and backing.y > 1.0 else sp
	return minf(p.distance_to(sp), p.distance_to(sp_log))


func _tap_near_limit() -> float:
	# 只接受确实点在肚脐附近的点击；不再用屏幕短边 28% 的大圆把任意点击吸过去。
	return 56.0


func _try_begin_surgery_touch(screen: Vector2, surg: Node) -> bool:
	if _camera == null:
		return false
	if surg.has_method("set_touch_pick"):
		surg.call("set_touch_pick", true)
	var tried := {}
	var try_px := func(px: Vector2) -> bool:
		var k := Vector2i(int(round(px.x)), int(round(px.y)))
		if tried.has(k):
			return false
		tried[k] = true
		var origin: Vector3 = _camera.project_ray_origin(px)
		var dir: Vector3 = _camera.project_ray_normal(px)
		if bool(surg.call("begin_stroke", origin, dir)):
			_interact_held = true
			_interact_screen = screen
			return true
		# 拉钩没有命中时仍更新幽灵预览（手指没有鼠标悬停）
		if str(surg.call("current_tool")) in ["retractor", "forceps"] and surg.has_method("hover_tool"):
			surg.call("hover_tool", origin, dir)
		return false
	for p in pointer_variants(screen):
		if try_px.call(p):
			return true
	var prim := to_camera_pixel(screen)
	# 指尖像素容差：绕点击点再试一圈，应对胖手指 / DPI 偏差
	for off in [Vector2(20, 0), Vector2(-20, 0), Vector2(0, 20), Vector2(0, -20),
			Vector2(16, 16), Vector2(-16, 16), Vector2(16, -16), Vector2(-16, -16),
			Vector2(28, 0), Vector2(-28, 0), Vector2(0, 28), Vector2(0, -28)]:
		if try_px.call(prim + off):
			return true
	return false


func _try_begin_interact_near(screen: Vector2, variants: Array[Vector2]) -> bool:
	if _camera == null or not _organs_live():
		return false
	var lim := _tap_near_limit()
	var best_rig: Node = null
	var best_d := INF
	var best_p := Vector2.ZERO
	for r in get_tree().get_nodes_in_group("organ_rigs"):
		if not bool(r.get("ready_ok")):
			continue
		var navel: Vector3 = (r.call("abdomen_frame") as Transform3D).origin
		if _camera.is_position_behind(navel):
			continue
		for p in variants:
			var d := _pointer_to_navel_dist(p, navel)
			if d < best_d:
				best_d = d
				best_rig = r
				best_p = p
	if best_rig == null or best_d > lim:
		return false
	_last_interact_via_navel = true
	var origin: Vector3 = _camera.project_ray_origin(best_p)
	var navel: Vector3 = (best_rig.call("abdomen_frame") as Transform3D).origin
	var dir: Vector3 = (navel - origin)
	if dir.length_squared() < 1e-8:
		dir = _camera.project_ray_normal(best_p)
	else:
		dir = dir.normalized()
	var mode := str(_organs.get("interact_mode"))
	if mode == "" or mode == "none":
		mode = "drag"
	if mode == "fist" or mode == "bayonet" or mode == "navel":
		if best_rig.get("interact_mode") != mode:
			best_rig.call("copy_settings_from", _organs)
		var cam_fwd := -_camera.global_transform.basis.z
		if not bool(best_rig.call("tool_begin", origin, dir, cam_fwd)):
			return false
		_interact_target = best_rig
		_interact_held = true
		_interact_screen = screen
		return true
	var hit: Variant = best_rig.call("ray_hit_belly", origin, dir)
	if hit == null:
		hit = navel
	_interact_target = best_rig
	if mode == "strike":
		best_rig.call("strike_at", hit)
	else:
		# 默认拖拽：无需先打开互动面板选工具
		best_rig.call("begin_drag", hit)
		_interact_held = true
		_interact_screen = screen
	return true


func _drag_active_surgery_from_screen(screen: Vector2) -> bool:
	var ray: Array = _screen_ray(screen)
	return _drag_active_surgery(ray[0], ray[1])


func _drag_active_surgery(origin: Vector3, dir: Vector3) -> bool:
	var surg := active_surgery()
	if surg == null or not bool(surg.call("is_active")):
		return false
	surg.call("drag_stroke", origin, dir)
	return true


func debug_drag_active_surgery(origin: Vector3, dir: Vector3) -> bool:
	## 测试用：与屏幕拖拽同一条 active_surgery 路由，便于在世界射线下回归。
	return _drag_active_surgery(origin, dir)


func _update_interact_drag(screen: Vector2) -> void:
	# 必须走 active_surgery：分身在检查床上手术时，本体的 _surgery 并未激活，
	# 若把拖拽发给本体，切割预览会停在起点拉不出来。
	if _drag_active_surgery_from_screen(screen):
		return
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
	var surg_end := active_surgery()
	if surg_end and bool(surg_end.call("is_active")):
		surg_end.call("end_stroke")
		_interact_held = false
		return
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
	_bed_pan = Vector3.ZERO
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
	var d := (-b.x * rel.x + b.y * rel.y) * per_px
	if occupancy == "exam_bed" and play_mode == GameMode.DISPLAY:
		_bed_pan += d
		if _bed_pan.length() > 0.6:
			_bed_pan = _bed_pan.normalized() * 0.6
		return
	_tp_target_goal += d
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
## 自检：镜头碰撞排除列表是否包含某个碰撞体。
func debug_camera_ignores(co: CollisionObject3D) -> bool:
	for n in get_tree().get_nodes_in_group("camera_ignore"):
		if n == co or (n is Node and (n as Node).is_ancestor_of(co)):
			return true
	return false


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
		var space := get_world_3d().direct_space_state
		var exclude: Array = [get_rid()]
		if occupier is CollisionObject3D:
			exclude.append((occupier as CollisionObject3D).get_rid())
		# 0.4.02：被切下 / 拖走的皮瓣、外露肠子、拉钩不触发镜头避让。
		for n in get_tree().get_nodes_in_group("camera_ignore"):
			if n is CollisionObject3D and is_instance_valid(n):
				exclude.append((n as CollisionObject3D).get_rid())
			if n is Node:
				for c in (n as Node).find_children("*", "CollisionObject3D", true, false):
					exclude.append((c as CollisionObject3D).get_rid())
		# A focus point inside the exam bed / character would otherwise make
		# cast_motion return 0 and freeze dolly at the 0.12 m floor.
		var overlap := PhysicsShapeQueryParameters3D.new()
		overlap.shape = _cam_shape
		overlap.transform = Transform3D(Basis.IDENTITY, origin)
		overlap.collision_mask = 1
		overlap.exclude = exclude
		for hit in space.intersect_shape(overlap, 16):
			var rid: Variant = hit.get("rid")
			if rid:
				exclude.append(rid)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = _cam_shape
		q.transform = Transform3D(Basis.IDENTITY, origin)
		q.motion = dir * d
		q.collision_mask = 1
		q.exclude = exclude
		var res := space.cast_motion(q)
		if res.size() >= 1 and res[0] < 1.0:
			d *= res[0]
	return maxf(d, 0.12)


func _update_tp_camera(delta: float, snap: bool = false) -> void:
	# On the exam bed the orbit center is the posed body (belly / current
	# focus). Following it every frame keeps dolly and orbit usable, instead
	# of leaving the target inside the table collision from a standing offset.
	if occupancy == "exam_bed" and play_mode == GameMode.DISPLAY:
		var focus := _tp_focus if _tp_focus != "" else "belly"
		if TP_FOCUS.has(focus):
			_tp_target_goal = focus_point(focus) + _bed_pan - _base_origin()
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
	_body_interp_apply()
	if occupancy != "":
		# Exam bed in observation mode: keep the orbit camera. Everything else
		# (lying FP, car/plane chase or cockpit) is written by VehicleSystem
		# after this node (process_priority 20, player is -10).
		if occupancy == "exam_bed" and play_mode == GameMode.DISPLAY:
			_update_tp_camera(delta)
			_push_view_spin(delta)
		elif occupancy == "car" or occupancy == "plane":
			# 0.4.08：驾驶坐姿在渲染帧里按载具「插值后」的变换摆放，且在本节点（-10）里先于
			# 子节点（脏器 / 手术肠管）执行 → 身体与载具网格每帧刚性同步，不再闪烁 / 拖影。
			var vs0: Node = get_parent().get("vehicle_system") if get_parent() else null
			if vs0 and vs0.has_method("seat_process"):
				vs0.call("seat_process", delta)
		_hover_surgery_tool()
		return
	# 在面板上松开按键时收不到 release → 以实际按键状态为准。
	if _rmb_down and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_rmb_down = false
	if _rmb_drag_owned and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		set_rmb_corpse_drag(false)
	if _mmb_down and not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_mmb_down = false
	if is_dead() and _ragdoll:
		var follow: Vector3 = _ragdoll.call("get_follow_point")
		_tp_target_goal = follow - _base_origin()
		_tp_target = _tp_target_goal
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
	if is_dead() and mode == GameMode.CONTROL:
		mode = GameMode.DISPLAY
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
	apply_screen_orientation()
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
	var s := _game_settings()
	if s and s.has_method("set_mouse_sensitivity"):
		s.call("set_mouse_sensitivity", mouse_sensitivity)


func set_touch_look_sensitivity(v: float) -> void:
	touch_look_sensitivity = clampf(v, 0.001, 0.04)
	var s := _game_settings()
	if s and s.has_method("set_touch_look_sensitivity"):
		s.call("set_touch_look_sensitivity", touch_look_sensitivity)


func ads_is_toggle() -> bool:
	# 手机/触屏界面：点按切换瞄准；电脑：按住瞄准、松开取消。
	if get_parent():
		var hud := get_parent().get_node_or_null("HUD")
		if hud and bool(hud.get("touch_ui")):
			return true
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.get_name() == "Android":
		return true
	return false


func set_rmb_corpse_drag(pressed: bool) -> bool:
	# 电脑：按住右键拖尸体，松开放下。与 E 切换共存；右键只放下由它自己开始的拖拽。
	if _corpse_drag == null:
		return false
	if pressed:
		if bool(_corpse_drag.call("is_dragging")) or bool(_corpse_drag.get("reaching")):
			return true
		var ok := bool(_corpse_drag.call("try_begin"))
		_rmb_drag_owned = ok
		return ok
	if _rmb_drag_owned:
		if bool(_corpse_drag.call("is_dragging")) or bool(_corpse_drag.get("reaching")):
			_corpse_drag.call("drop", "rmb")
		_rmb_drag_owned = false
	return true


func set_ads_toggle(on: bool) -> void:
	ads_toggle = on
	var s := _game_settings()
	if s and s.has_method("set_ads_toggle"):
		s.call("set_ads_toggle", ads_toggle)


func _game_settings() -> Node:
	var n: Node = get_parent()
	while n:
		var s := n.get_node_or_null("GameSettings")
		if s:
			return s
		n = n.get_parent()
	return null


func apply_saved_look_settings() -> void:
	var s := _game_settings()
	if s == null:
		return
	mouse_sensitivity = clampf(float(s.get("mouse_sensitivity")), 0.0005, 0.02)
	touch_look_sensitivity = clampf(float(s.get("touch_look_sensitivity")), 0.001, 0.04)
	# 与 GameSettings 同步后再校正一次（旧默认 0.009）
	if is_equal_approx(touch_look_sensitivity, 0.009):
		touch_look_sensitivity = 0.014
	ads_toggle = bool(s.get("ads_toggle"))


func apply_screen_orientation() -> void:
	# 手机：角色控制（第一人称）强制横屏；观察模式允许竖屏或横屏。
	if first_person:
		screen_orientation_request = "landscape"
		DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR_LANDSCAPE)
	else:
		screen_orientation_request = "sensor"
		DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR)


func eye_aim_transform() -> Transform3D:
	## 第一人称持枪空间：眼位为原点，朝向角色正面（网格 +Z）。
	var origin := global_transform * (_body.transform * (_fp_eye_cur + Vector3(0.0, 0.06, 0.0)))
	var fwd := _body_forward()
	if fwd.length_squared() < 1e-6:
		fwd = -global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
	# 相机约定看向 -Z，所以 -Z 应对准角色正面。
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), origin)


func get_skeleton() -> Skeleton3D:
	return _find_skeleton(_body)


func _cheek_weld_amount() -> float:
	# 长枪抵肩时微微低头，让脸颊贴上枪托，而不是把枪抬到视线。手枪不加。
	# 不用 weapon_armed()：那个还要求第一人称，观察模式也会低头抵肩。
	if _weapons == null or not bool(_weapons.call("is_armed")):
		return 0.0
	var w = _weapons.call("cur_def") if _weapons.has_method("cur_def") else null
	if w == null or str(w.category) == "pistol":
		return 0.0
	if first_person:
		var ads_k := float(_weapons.get("_ads_k")) if _weapons else 0.0
		return lerpf(0.28, 0.70, clampf(ads_k, 0.0, 1.0))
	return 0.85


## 第三人称抵肩持枪空间：原点在持枪侧腋窝（右腋），不要顶在胸口/胸骨。
func shoulder_aim_transform() -> Transform3D:
	var fwd := _body_forward()
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(0, 0, -1)
	var up := Vector3.UP
	var sh: Variant = _bone_world("R_Shoulder_a")
	var ua: Variant = _bone_world("R_UpperArm_a")
	var chest: Variant = _bone_world("C_Spine_c")
	var origin: Vector3
	if sh is Vector3:
		origin = sh
		# 腋窝在肩关节下方、略向内，并略偏向身后，形成枪托口袋；不要沿肩-胸连线拉到胸口。
		if ua is Vector3:
			origin = sh.lerp(ua, 0.42)
		else:
			origin += Vector3(0.0, -0.08, 0.0)
		if chest is Vector3:
			var inward: Vector3 = chest - sh
			inward.y = 0.0
			if inward.length_squared() > 1e-6:
				origin += inward.normalized() * 0.02
		origin += Vector3(0.0, -0.025, 0.0) + fwd * -0.015
	else:
		origin = global_transform * (_body.transform * (_fp_eye_cur + Vector3(0.16, -0.12, 0.0)))
	return Transform3D(Basis.looking_at(fwd, up), origin)


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
	if not (_col.shape is CapsuleShape3D or _col.shape is CylinderShape3D):
		return
	# Mesh feet are at y≈0 (skinned GLB fitStanding). Old capsule bottom was ~0.28 → feet sank.
	_col.position.y = _shape_h() * 0.5
	_capsule_stand_h = _shape_h()
	_capsule_stand_y = _col.position.y
	print(
		"player: capsule aligned bottom≈0 (h=%.3f y=%.3f)"
		% [_shape_h(), _col.position.y]
	)


## 移动碰撞体高度 / 半径（0.3.8 起为 CapsuleShape3D；height 含两端半球）。
func _shape_h() -> float:
	if _col.shape is CapsuleShape3D:
		return (_col.shape as CapsuleShape3D).height
	if _col.shape is CylinderShape3D:
		return (_col.shape as CylinderShape3D).height
	return 1.64


func _shape_r() -> float:
	if _col.shape is CapsuleShape3D:
		return (_col.shape as CapsuleShape3D).radius
	if _col.shape is CylinderShape3D:
		return (_col.shape as CylinderShape3D).radius
	return 0.3


func _set_shape_hr(h: float, r: float) -> void:
	if _col.shape is CapsuleShape3D:
		var cap := _col.shape as CapsuleShape3D
		var rr := minf(r, h * 0.5)
		if h >= cap.height:
			cap.height = h
			cap.radius = rr
		else:
			cap.radius = rr
			cap.height = h
	elif _col.shape is CylinderShape3D:
		(_col.shape as CylinderShape3D).height = h
		(_col.shape as CylinderShape3D).radius = r


func get_hitboxes() -> Node:
	return _hitboxes


func movement_shape_kind() -> String:
	if _col == null or _col.shape == null:
		return ""
	if _col.shape is CapsuleShape3D:
		return "capsule"
	if _col.shape is CylinderShape3D:
		return "cylinder"
	return _col.shape.get_class()


func _print_body_info() -> void:
	var skel := _find_skeleton(_body)
	if skel:
		print("player: skeleton bones=", skel.get_bone_count())
	var aabb := _calc_aabb(_body)
	var cap_bottom := 0.0
	if _col.shape is CapsuleShape3D or _col.shape is CylinderShape3D:
		cap_bottom = _col.position.y - _shape_h() * 0.5
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
var _touch_surgery: bool = false
## 已确认的指针坐标解释（-1 = 自动尝试多种）
var _ptr_mode: int = -1
## 最近一次互动是否走了肚脐近距兜底（自检用）
var _last_interact_via_navel: bool = false
var _last_tool_begin: Dictionary = {}
var touch_move: Vector2 = Vector2.ZERO  # 虚拟摇杆（x 右，y 下 = 后退），已去死区
var touch_sprint: bool = false
var _observe_fire_from: Vector2 = Vector2(-999, -999)
var _observe_fire_moved: bool = false
var touch_jump_req: bool = false
var _touch_interact: bool = false
## 手机划屏使用独立的 touch_look_sensitivity，不再跟随鼠标灵敏度。
const FP_TOUCH_SENS_LEGACY := 0.00305 * 0.9


func touch_look(rel: Vector2) -> void:
	if surgery_look_locked():
		return
	var vs := _vehicle_system_node()
	if vs and vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit")):
		vs.call("orbit_look", rel, touch_look_sensitivity)
		if vs.has_method("begin_orbit"):
			vs.call("begin_orbit")
		return
	if occupancy == "car" or occupancy == "plane":
		# Without 观察, look drag must not orbit the vehicle camera
		# (right-side swipe is yaw; the view is bound to the vehicle).
		return
	var k := touch_look_sensitivity
	_yaw -= rel.x * k
	_pitch = clampf(_pitch - rel.y * k, min_pitch, max_pitch)
	_apply_camera()


func touch_orbit(rel: Vector2) -> void:
	if surgery_look_locked():
		return
	var vs := _vehicle_system_node()
	if vs and vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit")):
		vs.call("orbit_look", rel, touch_look_sensitivity)
		if vs.has_method("begin_orbit"):
			vs.call("begin_orbit")
		return
	if occupancy == "car" or occupancy == "plane":
		return
	_tp_orbit_pixels(rel)


func touch_look_end() -> void:
	var vs := _vehicle_system_node()
	if vs and vs.has_method("end_orbit"):
		vs.call("end_orbit")


func _vehicle_system_node() -> Node:
	if get_parent() and get_parent().get("vehicle_system"):
		return get_parent().get("vehicle_system")
	return null


func look_pan_enabled() -> bool:
	# 观察视角、检查床上看、手术中（无论是否选了工具）都允许中键平移摄像机。
	var s := active_surgery()
	if s and s.has_method("is_active") and bool(s.call("is_active")):
		return true
	if occupancy == "exam_bed":
		return true
	if occupancy == "car" or occupancy == "plane":
		var vs := _vehicle_system_node()
		if vs and vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit")):
			return true
		# 电脑载具：中键平移随时可用（与右键环绕分开）。
		if not _is_touch_ui_mode():
			return true
		return false
	if not first_person:
		return true
	return false


func _fp_pan_pixels(rel: Vector2) -> void:
	var vh := maxf(1.0, get_viewport().get_visible_rect().size.y)
	var per_px := 0.0018 * (tp_fov / 50.0) if not first_person else (0.0011)
	_fp_pan.x -= rel.x * per_px
	_fp_pan.y += rel.y * per_px
	_fp_pan.x = clampf(_fp_pan.x, -0.55, 0.55)
	_fp_pan.y = clampf(_fp_pan.y, -0.40, 0.40)
	_apply_camera()


func _look_pan_pixels(rel: Vector2) -> void:
	var vs := _vehicle_system_node()
	if occupancy == "car" or occupancy == "plane":
		if vs and vs.has_method("pan_look"):
			vs.call("pan_look", rel, 0.0025)
		return
	if first_person:
		_fp_pan_pixels(rel)
		return
	_tp_pan_pixels(rel)


func touch_pan(rel: Vector2) -> void:
	_look_pan_pixels(rel)


## 双指捏合：scale = 旧间距 / 新间距（网页 dollyCam）
func touch_dolly(scale: float) -> void:
	var vs := _vehicle_system_node()
	if vs and vs.has_method("is_drive_third") and bool(vs.call("is_drive_third")):
		if vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit")) and vs.has_method("dolly_look"):
			vs.call("dolly_look", scale)
			return
	_tp_dist_goal = clampf(_tp_dist_goal * scale, camera_distance_min, camera_distance_max)


func touch_set_fov(v: float) -> void:
	fp_fov = clampf(v, fp_fov_min, fp_fov_max)
	_apply_camera()


## 观察视角：手指按在角色身上 = 当前工具（与鼠标左键同一套逻辑）
func _set_touch_surgery(on: bool) -> void:
	_touch_surgery = on
	var surg := active_surgery()
	if surg and surg.has_method("set_touch_pick"):
		surg.call("set_touch_pick", on)


func touch_tool_begin(screen: Vector2) -> bool:
	if _interact_held:
		_end_interact()
	var surg0 := active_surgery()
	_set_touch_surgery(surg0 != null and bool(surg0.call("is_active")))
	var ok := _try_begin_interact(screen)
	if not ok:
		_set_touch_surgery(false)
	_last_tool_begin = {
		"ok": ok,
		"screen": screen,
		"ptr_mode": _ptr_mode,
		"variants": pointer_variants(screen).size(),
		"mode": str(_organs.get("interact_mode")) if _organs else "",
		"held": _interact_held,
		"via_navel": _last_interact_via_navel,
	}
	return ok


func debug_last_tool_begin() -> Dictionary:
	return _last_tool_begin


func touch_tool_drag(screen: Vector2) -> void:
	if _interact_held:
		_interact_screen = screen
		_update_interact_drag(screen)


func touch_tool_end() -> void:
	if _interact_held:
		_end_interact()
	_set_touch_surgery(false)


func touch_tool_active() -> bool:
	return _interact_held


## 第一人称「互动」按钮（网页 tapFpInteract：屏幕中心射线）。
## 手机：点一下进入并保持，再点一下退出（不是长按）。PC 鼠标互动仍是按下/松开。
func touch_interact(pressed: bool, toggle: bool = false) -> void:
	var c := get_viewport().get_visible_rect().size * 0.5
	if toggle:
		if not pressed:
			return
		if _touch_interact:
			_touch_interact = false
			touch_tool_end()
		else:
			_touch_interact = true
			touch_tool_begin(c)
		return
	if pressed:
		_touch_interact = true
		touch_tool_begin(c)
	else:
		_touch_interact = false
		touch_tool_end()


func is_touch_interact_on() -> bool:
	return _touch_interact


func touch_crouch_tap() -> void:
	if play_mode != GameMode.CONTROL:
		return
	_set_stance("stand" if (_stance == "crouch" or _stance == "prone") else "crouch")


func _is_touch_ui_mode() -> bool:
	if touch_active:
		return true
	var hud := get_parent().get_node_or_null("HUD") if get_parent() else null
	if hud and "touch_ui" in hud:
		return bool(hud.touch_ui)
	return false


func _handle_vehicle_look(event: InputEvent) -> bool:
	var vs := _vehicle_system_node()
	if vs == null:
		return false
	var third := vs.has_method("is_drive_third") and bool(vs.call("is_drive_third"))
	var observe := vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit"))
	var touch_ui := _is_touch_ui_mode()
	# PC：按住右键即可拖拽转动载具视角，不必先切「观察」。松开后由 VehicleSystem 软回正。
	# 中键拖拽平移载具摄像机，不环绕。
	if not touch_ui:
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
			var mbm := event as InputEventMouseButton
			_mmb_down = mbm.pressed
			get_viewport().set_input_as_handled()
			return true
		if event is InputEventMouseMotion and _mmb_down and ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_MIDDLE):
			_look_pan_pixels((event as InputEventMouseMotion).relative)
			get_viewport().set_input_as_handled()
			return true
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
			var rb := event as InputEventMouseButton
			if rb.pressed:
				vs.call("begin_pc_orbit")
			else:
				vs.call("end_pc_orbit")
			get_viewport().set_input_as_handled()
			return true
		if event is InputEventMouseMotion:
			var mmr := event as InputEventMouseMotion
			var pc_held := vs.has_method("is_pc_orbit_held") and bool(vs.call("is_pc_orbit_held"))
			if pc_held and (mmr.button_mask & MOUSE_BUTTON_MASK_RIGHT):
				vs.call("orbit_look", mmr.relative, mouse_sensitivity)
				get_viewport().set_input_as_handled()
				return true
			# Without a held RMB, first-person stays locked to the vehicle basis.
			return occupancy == "car" or occupancy == "plane"
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if observe:
			if mb.pressed:
				vs.call("begin_orbit")
			else:
				vs.call("end_orbit")
			get_viewport().set_input_as_handled()
			return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if observe and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
			vs.call("orbit_look", mm.relative, mouse_sensitivity)
			get_viewport().set_input_as_handled()
			return true
		# Without 观察, first-person is locked to the vehicle basis;
		# do not accumulate a world-space _yaw/_pitch that would fight it.
		# Don't let the walking camera overwrite the vehicle chase/cockpit cam.
		return occupancy == "car" or occupancy == "plane"
	return false


func _hud_consumes_scroll(pos: Vector2) -> bool:
	var hud := get_parent().get_node_or_null("HUD") if get_parent() else null
	if hud and hud.has_method("gui_consumes_scroll"):
		return bool(hud.call("gui_consumes_scroll", pos))
	return false


func _should_dolly_wheel() -> bool:
	if input_locked:
		return false
	# Armed first-person / captured mouse: wheel cycles weapons.
	if first_person and has_method("weapon_armed") and weapon_armed() \
			and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or touch_active):
		return false
	return true


func apply_observe_wheel(steps: float) -> void:
	_tp_dolly(steps)


func _try_handle_observe_wheel(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if not mb.pressed:
		return false
	if not _should_dolly_wheel():
		return false
	if _hud_consumes_scroll(mb.position):
		return false
	var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
	var steps := dir * maxf(1.0, mb.factor if mb.factor > 0.0 else 1.0)
	# 载具第三人称：滚轮调追逐镜头距离。手机「观察」打开时、电脑第三人称均可。
	# 不得改 FOV，也不要打断地图捏合（地图开着时载具相机本就不接管）。
	var vs := _vehicle_system_node()
	if vs and vs.has_method("is_drive_third") and bool(vs.call("is_drive_third")):
		var observe := vs.has_method("is_observe_orbit") and bool(vs.call("is_observe_orbit"))
		if observe or not _is_touch_ui_mode():
			if vs.has_method("adjust_cam_distance"):
				vs.call("adjust_cam_distance", steps)
				get_viewport().set_input_as_handled()
				return true
	# Wheel always dollies distance to the look-at / follow center.
	# It must not change FOV in observation or character view.
	_tp_dolly(steps)
	get_viewport().set_input_as_handled()
	return true


func _input(event: InputEvent) -> void:
	# Handle the wheel before GUI so an overlay / exam-bed HUD cannot swallow
	# observation dolly. Open scrollable panels still receive it via the HUD check.
	if _try_handle_observe_wheel(event):
		return


func _unhandled_input(event: InputEvent) -> void:
	# 只处理鼠标；离散按键统一由 game_root.run_action 路由（每个键只在一处处理）。
	if input_locked:
		return
	# Touch-emulated mouse must not also orbit the vehicle camera or steal
	# the enter/exit tap — the stick / HUD already owns that finger.
	if touch_active and event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if occupancy == "car" or occupancy == "plane":
		if _handle_vehicle_look(event):
			return
	# 脏器互动：左键（捕获鼠标时取屏幕中心，否则取光标）。HUD 面板打开时也可以互动——
	# 面板本身吃掉落在面板矩形内的点击，面板外的点击会走到这里。
	# 武器：左键射击 / 右键开镜 / 滚轮切枪（第一人称持枪时代替身体互动）
	if event is InputEventMouseButton and _weapons:
		var wb := event as InputEventMouseButton
		if wb.button_index == MOUSE_BUTTON_LEFT and not wb.pressed:
			_weapons.call("set_trigger", false)
		if wb.button_index == MOUSE_BUTTON_RIGHT and not wb.pressed and not ads_is_toggle():
			_weapons.call("set_ads", false)
		if weapon_armed() and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or touch_active):
			if wb.button_index == MOUSE_BUTTON_LEFT:
				_weapons.call("set_trigger", wb.pressed)
				get_viewport().set_input_as_handled()
				return
			if wb.button_index == MOUSE_BUTTON_RIGHT:
				if ads_is_toggle():
					if wb.pressed:
						_weapons.call("set_ads", not bool(_weapons.get("ads")))
				else:
					_weapons.call("set_ads", wb.pressed)
				get_viewport().set_input_as_handled()
				return
			if wb.pressed and (wb.button_index == MOUSE_BUTTON_WHEEL_UP or wb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				_weapons.call("cycle", -1 if wb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
				get_viewport().set_input_as_handled()
				return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var lb := event as InputEventMouseButton
		# 观察模式持枪：单击屏幕点沿视线向内开火，拖动不在这里处理（右键才环绕）。
		if not first_person and weapon_drawn():
			if lb.pressed:
				_observe_fire_from = lb.position
				_observe_fire_moved = false
			else:
				var moved := _observe_fire_moved or lb.position.distance_to(_observe_fire_from) > 14.0
				if not moved and observe_tap_fire(lb.position):
					get_viewport().set_input_as_handled()
					_observe_fire_from = Vector2(-999, -999)
					return
			# 持枪观察时左键不再开始腹部互动，避免和射击抢手势。
			if not _interact_held:
				get_viewport().set_input_as_handled()
				return
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
		if not first_person and weapon_drawn() and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) and _observe_fire_from.x > -900.0:
			if mm.position.distance_to(_observe_fire_from) > 14.0:
				_observe_fire_moved = true
		# 0.3.9：中键拖拽平移在所有观察场景都可用（含检查床、手术中已选工具）——工具只用左键。
		if _mmb_down and look_pan_enabled():
			_look_pan_pixels(mm.relative)
			get_viewport().set_input_as_handled()
			return
		# 0.4.02：拉钩工具悬停在切口边缘时显示放置预览。
		var hs := active_surgery()
		if hs and bool(hs.call("is_active")) and str(hs.call("current_tool")) in ["retractor", "forceps"] and hs.has_method("hover_tool"):
			var hr: Array = _screen_ray(mm.position)
			hs.call("hover_tool", hr[0], hr[1])
		# 手术选了工具后锁定环绕/转视角，指针只留给切割 / 拿取。
		if surgery_look_locked():
			get_viewport().set_input_as_handled()
			return
		if first_person:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				_yaw -= mm.relative.x * mouse_sensitivity
				_pitch -= mm.relative.y * mouse_sensitivity
				_pitch = clampf(_pitch, min_pitch, max_pitch)
				_apply_camera()
		else:
			# 观察视角（网页 OrbitControls）：右键环绕，中键 / Shift·Ctrl+右键 平移。
			if _rmb_down and _pan_drag:
				_tp_pan_pixels(mm.relative)
				get_viewport().set_input_as_handled()
			elif _rmb_down:
				_tp_orbit_pixels(mm.relative)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE and look_pan_enabled():
			_mmb_down = mb.pressed
			get_viewport().set_input_as_handled()
			return
		if surgery_look_locked() and mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb_down = false
			_pan_drag = false
			get_viewport().set_input_as_handled()
			return
		# 电脑第一人称收枪后：按住右键拖尸体，松开放下（与 E 切换共存）。
		if first_person and mb.button_index == MOUSE_BUTTON_RIGHT and not weapon_drawn():
			set_rmb_corpse_drag(mb.pressed)
			get_viewport().set_input_as_handled()
			return
		if _try_handle_observe_wheel(mb):
			return
		if not first_person or look_pan_enabled():
			if mb.button_index == MOUSE_BUTTON_RIGHT and not first_person:
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
	_fp_pan = Vector3.ZERO
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
	if hr.x <= _shape_h() + 0.001:
		return true  # 变矮永远可以
	var shape := CapsuleShape3D.new()
	shape.radius = maxf(0.05, hr.y - 0.02)
	shape.height = maxf(shape.radius * 2.0 + 0.01, hr.x - 0.06)
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
	if not (_col.shape is CapsuleShape3D or _col.shape is CylinderShape3D):
		return
	# Web FP capsule approx: stand 1.64/0.3, crouch 0.94/0.26, prone 0.42/0.21（胶囊半径 ≤ 高度一半）.
	# Blend height/radius/eye over STANCE_BLEND_DUR (0.7s). Bottom stays ≈ 0.
	_begin_fp_eye_blend(_stance)
	_cap_h_from = _shape_h()
	_cap_r_from = _shape_r()
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
			_cap_r_to = 0.21
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
		_camera.position = Vector3(_fp_pan.x, _fp_pan.y, 0.0)
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
	if not (_col.shape is CapsuleShape3D or _col.shape is CylinderShape3D):
		return
	if _stance_blend >= 1.0 and is_equal_approx(_shape_h(), _cap_h_to):
		return  # 0.3.8：过渡结束后不再每帧改形状（物理引擎会重建形状）
	if _stance_blend < 1.0:
		_stance_blend = minf(1.0, _stance_blend + delta / STANCE_BLEND_DUR)
	var t := _stance_blend
	var u := t * t * (3.0 - 2.0 * t)
	_set_shape_hr(lerpf(_cap_h_from, _cap_h_to, u), lerpf(_cap_r_from, _cap_r_to, u))
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
## 0.4.07：实际位移 / 期望位移（平滑），撞墙时趋近 0；用于走跑姿态回落。
var move_ratio: float = 1.0
const RUN_KEEP_RATIO := 0.55
const MOVE_RATIO_FALL := 3.0  # 回落较慢（约 0.3 s）
const MOVE_RATIO_RISE := 10.0


func _update_move_ratio(pos_before: Vector3, want_speed: float, wish_len: float, delta: float) -> void:
	if delta <= 0.0:
		return
	var d := global_position - pos_before
	var actual := Vector2(d.x, d.z).length() / delta
	var target := 1.0
	if wish_len > 1e-3 and want_speed > 0.25:
		target = clampf(actual / want_speed, 0.0, 1.0)
	var rate := MOVE_RATIO_FALL if target < move_ratio else MOVE_RATIO_RISE
	move_ratio += (target - move_ratio) * (1.0 - exp(-rate * delta))


func debug_move_ratio() -> float:
	return move_ratio
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
		_fp_body_off = Vector3.ZERO
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
	_fp_body_off = -Vector3(fwd.x, 0.0, fwd.z).normalized() * _loco_back
	_body.position = _body_rest_pos + _fp_body_off
	var want := _fp_eye_target(moving, sprinting)
	if not _fp_eye_init:
		_fp_eye_smooth = want
		_fp_eye_init = true
	var err := _fp_eye_smooth.distance_to(want)
	var k := 1.0 - exp(-(22.0 if (err > 0.28 or is_stance_blending()) else 12.0) * delta)
	_fp_eye_smooth = _fp_eye_smooth.lerp(want, k)
	_fp_eye_smooth += _fp_neck_clear_push(_fp_eye_smooth)


## 0.4.08：奔跑 / 跳跃时动画把脖子往前带，眼点必须始终在脖子（C_Neck_a）前方 FP_NECK_CLEAR，
## 否则近裁面会切进自己的脖子。只沿身体水平朝向前推，不改高度；平时（已在前方）不起作用。
const FP_NECK_CLEAR := 0.085
const FP_HEAD_CLEAR := 0.075
var fp_neck_push: float = 0.0
var _fp_body_off := Vector3.ZERO


func _fp_neck_clear_push(eye_local: Vector3) -> Vector3:
	var skel := get_skeleton()
	if skel == null:
		return Vector3.ZERO
	var ni := skel.find_bone("C_Neck_a")
	var hi := skel.find_bone("C_Head_a")
	if ni < 0:
		return Vector3.ZERO
	var fwd := _body.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z)
	if fwd.length_squared() < 1e-6:
		return Vector3.ZERO
	fwd = fwd.normalized()
	var base := global_position - Vector3(0.0, _step_smooth, 0.0)
	var eye_w := base + eye_local
	var neck := skel.global_transform * skel.get_bone_global_pose(ni).origin
	var need := FP_NECK_CLEAR - (eye_w - neck).dot(fwd)
	if hi >= 0:
		var head := skel.global_transform * skel.get_bone_global_pose(hi).origin
		var hd := eye_w - head
		var ahead := hd.dot(fwd)
		var lateral := (hd - fwd * ahead).length()
		if lateral < FP_HEAD_CLEAR:
			var want_ahead := sqrt(maxf(0.0, FP_HEAD_CLEAR * FP_HEAD_CLEAR - lateral * lateral))
			need = maxf(need, want_ahead - ahead)
	fp_neck_push = maxf(0.0, need)
	return fwd * fp_neck_push


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


## 台阶上抬（0.3.8 胶囊版）：贴地且水平运动被陡面挡住时，用脚底扁圆柱探测前方落脚面，
## 落差 ≤ STEP_HEIGHT 且抬高后能前进（头顶有空间、不是墙）就把角色抬到台阶高度。
## 胶囊圆底落在台阶棱上时法线是斜的，旧的「胶囊下落找地面」会判成悬空，所以改用脚底探测。
func _try_step_up(motion: Vector3) -> bool:
	if motion.length_squared() < 1e-8:
		return false
	var xf := global_transform
	var hit := KinematicCollision3D.new()
	if not test_move(xf, motion, hit, safe_margin):
		return false  # 没被挡
	if hit.get_normal().angle_to(Vector3.UP) <= floor_max_angle:
		return false  # 可走的坡，交给 move_and_slide
	var probe := motion.normalized() * maxf(motion.length(), 0.08)
	var sy := _foot_support_y(xf.origin + probe, STEP_HEIGHT, 0.02)
	if is_nan(sy):
		return false  # 前方没有可站的台面（墙 / 悬空 / 太陡）
	var rise := sy - xf.origin.y
	if rise < 0.01 or rise > STEP_HEIGHT + 0.001:
		return false
	var lift := Vector3.UP * (rise + 0.004)
	if test_move(xf, lift, null, safe_margin):
		return false  # 头顶没空间
	if test_move(xf.translated(lift), probe, null, safe_margin):
		return false  # 抬高后仍被挡（是墙，不是台阶）
	global_position.y += rise
	_step_smooth += rise  # 相机平滑跟上
	return true


var _foot_disc: CylinderShape3D = null
var _foot_q: PhysicsShapeQueryParameters3D = null


## 脚底支撑面高度：在 at 上方 up 处放一块与胶囊同半径的扁圆柱，向下扫 up+down，
## 返回碰到的可站立表面的世界 y；没有 / 起点就重叠 / 太陡返回 NAN。只查世界层（1）。
func _foot_support_y(at: Vector3, up: float, down: float) -> float:
	var w3 := get_world_3d()
	if w3 == null:
		return NAN
	if _foot_disc == null:
		_foot_disc = CylinderShape3D.new()
		_foot_q = PhysicsShapeQueryParameters3D.new()
		_foot_q.shape = _foot_disc
		_foot_q.collision_mask = 1
		_foot_q.collide_with_areas = false
	_foot_disc.radius = maxf(0.08, _shape_r() - 0.01)
	_foot_disc.height = 0.04
	_foot_q.exclude = [get_rid()]
	var span := up + down
	var start := at + Vector3(0.0, up + _foot_disc.height * 0.5, 0.0)
	_foot_q.transform = Transform3D(Basis.IDENTITY, start)
	_foot_q.motion = Vector3(0.0, -span, 0.0)
	var space := w3.direct_space_state
	var r := space.cast_motion(_foot_q)
	if r.size() < 2 or float(r[0]) >= 1.0 or float(r[1]) <= 0.0:
		return NAN  # 范围内没有地面，或一开始就嵌在物体里（墙）
	var travel := span * float(r[0])
	_foot_q.transform = Transform3D(Basis.IDENTITY, start - Vector3(0.0, span * float(r[1]), 0.0))
	_foot_q.motion = Vector3.ZERO
	var info := space.get_rest_info(_foot_q)
	if not info.is_empty():
		var n: Vector3 = info.get("normal", Vector3.UP)
		if n.angle_to(Vector3.UP) > floor_max_angle + 0.02:
			return NAN
	return at.y + up - travel


## 胶囊站在台阶棱上 / 下台阶：move_and_slide 判不出地面时，用脚底支撑把角色托住或贴到下一级。
func _apply_ledge_support(jumped: bool) -> void:
	_ledge_support = false
	if is_on_floor() or jumped or velocity.y > 0.0 or not _was_grounded:
		return
	var sy := _foot_support_y(global_position, 0.25, STEP_HEIGHT)
	if is_nan(sy):
		return
	var rise := sy - global_position.y
	if rise > 0.0005 and test_move(global_transform, Vector3.UP * rise, null, safe_margin):
		return
	global_position.y = sy
	velocity.y = 0.0
	_step_smooth += rise
	_ledge_support = true


## 调试 / 自检：当前是否靠脚底支撑站稳（胶囊不在地面上）。
func debug_ledge_supported() -> bool:
	return _ledge_support


func _physics_process(delta: float) -> void:
	_body_interp_reset()
	if is_dead():
		velocity = Vector3.ZERO
		if occupancy != "" and get_parent() and get_parent().get("vehicle_system"):
			var vs = get_parent().get("vehicle_system")
			if vs and vs.has_method("try_exit"):
				vs.call("try_exit")
		if _corpse_drag and _corpse_drag.call("is_dragging"):
			_corpse_drag.call("drop", "dead")
		if _loco:
			_loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, delta, 0.0)
		return
	if occupancy != "":
		# Occupied: no walking. VehicleSystem places the body, applies the exam pose,
		# and overrides the camera in first person. Observe mode still orbits.
		velocity = Vector3.ZERO
		_update_fp_eye_blend(delta)
		if occupancy != "exam_bed" and _loco and not bool(_loco.get("frozen")):
			_loco.set("frozen", true)
		if play_mode == GameMode.DISPLAY and occupancy == "exam_bed":
			_update_tp_camera(delta)
			_apply_camera()
		return
	var display := play_mode == GameMode.DISPLAY
	var can_act := (not display) and not input_locked
	if can_act:
		_update_crouch_toggle()
	_update_fp_eye_blend(delta)
	_update_stance_capsule_blend(delta)

	var on_floor := is_on_floor() or _ledge_support
	var jumped := false
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
	var aiming := false
	if _weapons and _weapons.has_method("is_armed") and bool(_weapons.call("is_armed")):
		aiming = bool(_weapons.get("ads")) or float(_weapons.get("_ads_k")) > 0.35
	if aiming:
		sprinting = false
	# 奔跑只允许在前方锥角内；横向跑改成走路或把侧向分量压掉。
	if sprinting and wish_len > 1e-4:
		var cam_fwd := basis_yaw * Vector3(0, 0, -1)
		var ang := wish.angle_to(cam_fwd)
		const SPRINT_CONE := 0.698  # 40 deg
		if ang > 1.222:  # 70 deg：纯侧向/后退，不允许奔跑
			sprinting = false
		elif ang > SPRINT_CONE:
			# 压掉侧向，只保留向前的分量再奔跑（必要时略转向输入）。
			var fwd_amt := wish.dot(cam_fwd)
			if fwd_amt > 0.12:
				var flat := (cam_fwd * fwd_amt).normalized()
				wish = flat
				wish_len = minf(1.0, wish.length())
				direction = wish
			else:
				sprinting = false
	var speed := move_speed
	match _stance:
		"crouch":
			speed = crouch_speed
		"prone":
			speed = prone_speed
		_:
			if sprinting:
				speed = sprint_speed
			elif aiming:
				speed = ads_speed
			else:
				speed = move_speed

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
		jumped = true
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
	var _want_hv := Vector2(velocity.x, velocity.z).length()
	var _pos_before := global_position
	move_and_slide()
	_update_move_ratio(_pos_before, _want_hv, wish_len, delta)
	_apply_ledge_support(jumped)
	_was_grounded = is_on_floor() or _ledge_support
	_stomp_ragdolls(delta)
	_fti_tick()
	if _was_grounded:
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
	if sec2 and sec2.has_method("set_cheek_weld"):
		sec2.call("set_cheek_weld", _cheek_weld_amount())
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
			# 0.4.07：撞墙时实际位移很小 → 按实际速度缓慢退回走路/待机（即使一直按 Shift）。
			mag *= move_ratio
		if sprinting and on_floor and move_ratio < RUN_KEEP_RATIO:
			sprinting = false
		var airborne := not on_floor
		if airborne and str(_loco.get("current_clip")) != "jump":
			_loco.set("phase", 0.28)
		_loco.call("set_mode", _stance)
		var actual_spd := Vector2(velocity.x, velocity.z).length()
		_loco.call("apply_pose", fwd, side, mag, airborne, sprinting, delta, actual_spd)
		if _weapons and _weapons.has_method("is_armed"):
			_loco.set("weapon_ik", bool(_weapons.call("is_armed")) and float(_weapons.get("_ik_w")) > 0.2)
		# 走跑刚写完肩臂底姿势，立刻用持枪 IK 覆写，避免节点顺序导致 IK 被冲掉或肩旋转累积。
		if _weapons and _weapons.has_method("apply_ik_after_loco"):
			_weapons.call("apply_ik_after_loco")
		_after_pose_feedback(delta)

	# FP: stable stance eye (no head-bone bob); refresh after body yaw catch-up.
	_update_fp_eye(delta, direction != Vector3.ZERO, sprinting, not on_floor)
	if first_person:
		_pivot_rot = Vector3(_pitch, _yaw, 0.0)
		_pivot_off = _fp_eye_pivot_pos() - Vector3(0.0, _step_smooth, 0.0)
		_sync_pivot()

	_update_corpse_drag_aim()
