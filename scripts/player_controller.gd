extends CharacterBody3D
## 第三人称角色控制器：WASD/方向键移动、鼠标环视、重力、与地图碰撞。

@export var move_speed: float = 4.5
@export var sprint_speed: float = 7.0
@export var jump_velocity: float = 4.2
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch: float = -1.2
@export var max_pitch: float = 0.4
@export var camera_distance: float = 2.8
@export var camera_height: float = 1.4

var _yaw: float = 0.0
var _pitch: float = -0.15
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var _pivot: Node3D = $CameraPivot
@onready var _camera: Camera3D = $CameraPivot/Camera3D
@onready var _body: Node3D = $Body


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_camera()
	_print_body_info()


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
		# 粗略用原点变换后的 AABB（足够用于诊断）
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
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _apply_camera() -> void:
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3(0.0, camera_height * 0.15, camera_distance)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var direction := (basis_yaw * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else move_speed

	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		# 角色朝向移动方向
		var look := atan2(-direction.x, -direction.z)
		_body.rotation.y = lerp_angle(_body.rotation.y, look, clampf(12.0 * delta, 0.0, 1.0))
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()
