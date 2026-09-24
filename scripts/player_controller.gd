extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
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
@export var tp_fov: float = 55.0
@export var camera_distance_min: float = 1.2
@export var camera_distance_max: float = 6.0
@export var fp_fov_min: float = 50.0
@export var fp_fov_max: float = 90.0

var _yaw: float = 0.0
var _pitch: float = -0.15
var _default_yaw: float = 0.0
var _default_pitch: float = -0.15
var _default_cam_dist: float = 2.8
var _default_cam_height: float = 1.4
var _default_fp_fov: float = 62.0
var _default_tp_fov: float = 55.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _loco: Node
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
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_align_capsule_to_feet()
	_print_body_info()
	_loco = SoftLocoScript.new()
	add_child(_loco)
	var skel := _find_skeleton(_body)
	if skel and _loco.setup(skel):
		print("player: SoftLoco ready")
	else:
		push_warning("player: SoftLoco failed to init")
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
	# Start in Display/Interact (TP, no move, gaze→camera).
	set_play_mode(GameMode.DISPLAY)


func get_loco() -> Node:
	return _loco


func get_secondary() -> RefCounted:
	if _loco == null:
		return null
	return _loco.get("secondary")


func reset_camera() -> void:
	_yaw = _default_yaw
	_pitch = _default_pitch
	camera_distance = _default_cam_dist
	fp_fov = _default_fp_fov
	tp_fov = _default_tp_fov
	if _stance == "stand":
		camera_height = _default_cam_height
	_apply_camera()


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
		# Recentre TP orbit on character (CameraPivot is child — already follows).
		# Keep current yaw/pitch/distance so the view does not jump wildly from FP.
		_pivot.position = Vector3(0.0, camera_height, 0.0)
		var sec := get_secondary()
		if sec:
			sec.call("clear_body_look")
	else:
		var sec2 := get_secondary()
		if sec2:
			sec2.call("clear_gaze")
		# Sync body lag yaw to current look so FP does not snap-spin on mode switch.
		_body_logic_yaw = _yaw
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


## FP: hide only head / hair / eye / mouth to reduce camera clip; keep torso/arms/legs.
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


func _apply_fp_mesh_visibility() -> void:
	for mi in _body.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null:
			continue
		if first_person and _fp_should_hide_mesh(mesh_i):
			mesh_i.visible = false
		else:
			mesh_i.visible = true


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
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, min_pitch, max_pitch)
		_apply_camera()
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if (
			mb.button_index == MOUSE_BUTTON_WHEEL_UP
			or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
		):
			if ui_blocks_capture:
				return
			var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			if first_person:
				# Wheel up = zoom in = narrower FOV.
				fp_fov = clampf(fp_fov - dir * 3.0, fp_fov_min, fp_fov_max)
			else:
				camera_distance = clampf(
					camera_distance - dir * 0.25, camera_distance_min, camera_distance_max
				)
			_apply_camera()
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			if not ui_blocks_capture:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				toggle_play_mode()
			KEY_ESCAPE:
				# HUD handles Esc first via its own _unhandled_input (higher priority when panel open).
				# Fallback: release / re-capture mouse when no UI consuming Esc.
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				elif not ui_blocks_capture:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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
		_pivot.position = Vector3(0.0, camera_height, 0.0)
		_camera.position = Vector3(0.0, 0.0, camera_distance)
		_camera.near = 0.1
		_camera.fov = tp_fov


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
