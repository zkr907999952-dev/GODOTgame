extends CharacterBody3D

const SoftLocoScript = preload("res://scripts/soft_loco.gd")
## 第三人称角色控制器：WASD 移动 + SoftLoco 网页 loco 动画驱动 Skeleton3D。

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

var _yaw: float = 0.0
var _pitch: float = -0.15
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _loco: Node
var _stance: String = "stand" # stand | crouch | prone
var _capsule_stand_h: float = 1.1
var _capsule_stand_y: float = 0.83
var _air_time: float = 0.0

@onready var _pivot: Node3D = $CameraPivot
@onready var _camera: Camera3D = $CameraPivot/Camera3D
@onready var _body: Node3D = $Body
@onready var _col: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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


func _print_body_info() -> void:
	var skel := _find_skeleton(_body)
	if skel:
		print("player: skeleton bones=", skel.get_bone_count())
	var aabb := _calc_aabb(_body)
	print("player: body AABB ", aabb, " feet≈", aabb.position.y, " height≈", aabb.size.y)


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
		var world := AABB(xf * local.position, xf.basis * local.size)
		if first:
			result = world
			first = false
		else:
			result = result.merge(world)
	return result


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, min_pitch, max_pitch)
		_apply_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
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
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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
	# Match web approx: stand h≈1.64 r0.3 → our stand 1.1; crouch 0.94; prone 0.42
	match _stance:
		"crouch":
			cap.height = 0.64
			cap.radius = 0.26
			_col.position.y = 0.52
			camera_height = 0.85
		"prone":
			cap.height = 0.28
			cap.radius = 0.22
			_col.position.y = 0.28
			camera_height = 0.45
		_:
			cap.height = _capsule_stand_h
			cap.radius = 0.28
			_col.position.y = _capsule_stand_y
			camera_height = 1.4
	_apply_camera()


func _apply_camera() -> void:
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3(0.0, camera_height * 0.15, camera_distance)


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
		var look := atan2(-direction.x, -direction.z)
		_body.rotation.y = lerp_angle(_body.rotation.y, look, clampf(12.0 * delta, 0.0, 1.0))
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()

	if _loco:
		# Movement relative to body facing: +fwd = character forward (-Z local after yaw).
		var local_vel := _body.global_transform.basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)
		var fwd := clampf(-local_vel.z / maxf(speed, 0.01), -1.0, 1.0)
		var side := clampf(local_vel.x / maxf(speed, 0.01), -1.0, 1.0)
		var mag := clampf(Vector2(velocity.x, velocity.z).length() / maxf(speed, 0.01), 0.0, 1.0)
		if input_dir != Vector2.ZERO:
			# Prefer input axes in body space for clip pick (matches web fwd/side).
			var local_in := _body.global_transform.basis.inverse() * (basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y))
			fwd = clampf(-local_in.z, -1.0, 1.0)
			side = clampf(local_in.x, -1.0, 1.0)
			mag = clampf(input_dir.length(), 0.0, 1.0)
		var airborne := not on_floor
		if airborne and str(_loco.get("current_clip")) != "jump":
			_loco.set("phase", 0.28)
		_loco.call("set_mode", _stance)
		_loco.call("apply_pose", fwd, side, mag, airborne, sprinting, delta, speed)
