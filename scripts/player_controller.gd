extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
## 第三人称角色控制器：WASD 移动 + SoftLoco 网页 loco 动画驱动 Skeleton3D。
## Web loco bind: mesh faces +Z; Godot move uses -Z forward → visual Body needs π yaw offset.
const BODY_YAW_OFFSET := PI

@export var move_speed: float = 4.5
@export var sprint_speed: float = 7.0
@export var crouch_speed: float = 2.2
@export var prone_speed: float = 0.9
@export var jump_velocity: float = 4.2
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch: float = -1.2
@export var max_pitch: float = 0.4
@export var camera_distance: float = 2.8
@export var camera_height: float = 1.4
@export var first_person: bool = false
@export var fp_eye_height: float = 1.55
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
	_apply_camera()
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
	first_person = enabled
	_apply_fp_mesh_visibility()
	if not first_person:
		var sec := get_secondary()
		if sec:
			sec.call("clear_body_look")
	_apply_camera()


func toggle_first_person() -> void:
	set_first_person(not first_person)


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
			KEY_ESCAPE:
				# HUD handles Esc first via its own _unhandled_input (higher priority when panel open).
				# Fallback: release / re-capture mouse when no UI consuming Esc.
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				elif not ui_blocks_capture:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			KEY_CTRL:
				_toggle_crouch()
			KEY_C, KEY_Z:
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


func _toggle_crouch() -> void:
	if _stance == "prone":
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


func _apply_stance_capsule() -> void:
	if not (_col.shape is CapsuleShape3D):
		return
	var cap := _col.shape as CapsuleShape3D
	# Keep capsule bottom ≈ 0 so feet stay on floor across stances.
	match _stance:
		"crouch":
			cap.height = 0.64
			cap.radius = 0.26
			_col.position.y = cap.height * 0.5
			camera_height = 0.85
			fp_eye_height = 0.95
		"prone":
			cap.height = 0.28
			cap.radius = 0.22
			_col.position.y = cap.height * 0.5
			camera_height = 0.45
			fp_eye_height = 0.35
		_:
			cap.height = _capsule_stand_h
			cap.radius = 0.28
			_col.position.y = _capsule_stand_y
			camera_height = _default_cam_height
			fp_eye_height = 1.55
	_apply_camera()


func _apply_camera() -> void:
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	if first_person:
		_pivot.position = Vector3(0.0, _fp_eye_y(), 0.0)
		# Slight forward along look (-Z of pivot) so near plane clears hidden head mesh.
		_camera.position = Vector3(0.0, 0.0, -0.08)
		_camera.near = 0.03
		_camera.fov = fp_fov
	else:
		_pivot.position = Vector3(0.0, camera_height, 0.0)
		_camera.position = Vector3(0.0, 0.0, camera_distance)
		_camera.near = 0.1
		_camera.fov = tp_fov


## Prefer C_Head_a bone height in character space; fallback fp_eye_height.
func _fp_eye_y() -> float:
	var skel := _find_skeleton(_body)
	if skel:
		var hi := skel.find_bone("C_Head_a")
		if hi < 0:
			hi = skel.find_bone("C_Neck_a")
		if hi >= 0:
			var gp := skel.get_bone_global_pose(hi)
			var world_y: float = (_body.global_transform * gp).origin.y
			return world_y - global_position.y + 0.06
	return fp_eye_height


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()
	if not on_floor:
		velocity.y -= _gravity * delta
		_air_time += delta
	else:
		_air_time = 0.0
		if Input.is_action_just_pressed("jump"):
			if _stance == "prone":
				_stance = "stand"
				_apply_stance_capsule()
			else:
				velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var direction := (basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var sprinting := Input.is_action_pressed("sprint") and _stance == "stand"
	var speed := move_speed
	match _stance:
		"crouch":
			speed = crouch_speed
		"prone":
			speed = prone_speed
		_:
			speed = sprint_speed if sprinting else move_speed

	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	# Visual facing: mesh +Z vs Godot -Z → BODY_YAW_OFFSET (π).
	# FP: lock body yaw to camera yaw every frame; TP: face move dir when walking.
	var face_yaw: float
	if first_person:
		face_yaw = _yaw + BODY_YAW_OFFSET
	elif direction != Vector3.ZERO:
		face_yaw = atan2(-direction.x, -direction.z) + BODY_YAW_OFFSET
	else:
		face_yaw = _body.rotation.y
	if first_person or direction != Vector3.ZERO:
		_body.rotation.y = lerp_angle(
			_body.rotation.y, face_yaw, clampf(14.0 * delta, 0.0, 1.0)
		)

	move_and_slide()

	# FP: set body look BEFORE apply_pose so SoftSecondary applies it same frame.
	if first_person:
		var sec2 := get_secondary()
		if sec2:
			var body_logic_yaw := _body.rotation.y - BODY_YAW_OFFSET
			var rel_yaw := wrapf(_yaw - body_logic_yaw, -PI, PI)
			sec2.call("set_body_look", rel_yaw, _pitch)

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

	# FP: refresh eye height from head bone after pose.
	if first_person:
		_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
		_pivot.position = Vector3(0.0, _fp_eye_y(), 0.0)
