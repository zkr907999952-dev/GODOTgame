extends VehicleBody3D
## Sports-car physics using Godot's VehicleBody3D + VehicleWheel3D (Jolt).
## Wheel / grip / suspension values follow the official Truck Town demo
## (godotengine/godot-demo-projects 3d/truck_town, Godot 4.6 + Jolt):
##   wheel_friction_slip = 1.0, suspension_stiffness = 40, damping_compression
##   = 0.88, chassis PhysicsMaterial friction 0.5. Engine force is scaled for
##   this 1420 kg mass from the demo's "engine_force_value" pattern (including
##   the low-speed launch boost), not a raw Newton torque that overpowers the
##   tyres and spins the car out uncommanded.
class_name CarController

const KIND := "car"
const ENTER_RADIUS := 4.2
const MASS_KG := 1420.0
const MAX_STEER := 0.42  # rad, Truck Town uses 0.4
const STEER_SPEED := 1.8
const BRAKE_FORCE := 18.0
const HANDBRAKE_FORCE := 28.0
const IDLE_RPM := 900.0
const REDLINE_RPM := 8200.0
const PEAK_RPM := 5200.0
const FINAL_DRIVE := 3.54
const GEAR_RATIOS := [0.0, 3.21, 2.11, 1.47, 1.14, 0.92, 0.74]  # index 0 unused (neutral)
# Official demo uses ~40 force at a light body. Scale for 1420 kg so 0–100 km/h
# is sports-car quick but the tyres (friction_slip 1.0) can actually hold it.
const ENGINE_FORCE := 4200.0
const ENGINE_FORCE_NITRO := 5600.0
const ENGINE_FORCE_REV := 2800.0
const WHEEL_FRICTION := 1.0  # Truck Town / docs: 1.0 is normal grip
const WHEEL_FRICTION_FRONT := 1.15
const WHEEL_FRICTION_REAR := 1.0
const WHEEL_FRICTION_HB := 0.35  # rear slip under handbrake / drift
const SUSP_STIFFNESS := 40.0
const SUSP_MAX_FORCE := 9000.0
const SUSP_TRAVEL := 0.13
const DAMP_COMP := 0.88
const DAMP_REL := 0.92

signal occupied_changed(on: bool)

var vehicle_id: String = ""
var is_default: bool = false  ## city / room default spawn (not menu-spawned)
var is_menu_spawned: bool = false
var occupied: bool = false
var door: float = 0.0
var door_target: float = 0.0
var throttle_in: float = 0.0
var steer_in: float = 0.0
var brake_in: float = 0.0
var handbrake: bool = false
var nitro: bool = false
var gear: int = 1
var rpm: float = IDLE_RPM
var steer_angle: float = 0.0
var wheel_spin: float = 0.0
var visuals: CarVisuals
var _wheels: Array[VehicleWheel3D] = []
var _wheel_rest: Array[Vector3] = []
var _vis_spin: float = 0.0
var spawn_map: String = "city"


func _ready() -> void:
	mass = MASS_KG
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -0.22, 0.08)  # low and slightly rearward, planted
	gravity_scale = 1.0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	collision_layer = 1
	collision_mask = 1  # world only; player uses a proximity test to enter
	can_sleep = true
	linear_damp = 0.04
	angular_damp = 0.35  # helps the chassis track straight when no steer input
	if physics_material_override == null:
		var mat := PhysicsMaterial.new()
		# Truck Town uses 0.5; keep the hull from yawing the car if it kisses the ground.
		mat.friction = 0.15
		mat.bounce = 0.0
		physics_material_override = mat
	# Jolt + FREEZE_MODE_STATIC zeros VehicleWheel3D local positions, so the
	# car ends up spinning on a single point under the chassis.
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	visuals = CarVisuals.new()
	visuals.name = "Visuals"
	add_child(visuals)
	if not visuals.setup():
		push_error("CarController: visual setup failed")
		return
	_build_wheels()
	_build_collision()
	_freeze_parked(true)
	call_deferred("_restore_wheel_positions")


func _build_collision() -> void:
	# Convex hulls that follow the body shell, excluding wheels.
	# No concave trimesh on a moving VehicleBody (Jolt misbehaves).
	# Prefer pre-baked hulls — Mesh.create_convex_shape at runtime stalls
	# the main thread for many seconds per vehicle (map teleport "卡死").
	var n := 0
	var baked := false
	if visuals and visuals.wrap:
		n = VehicleCommon.apply_baked_hulls(self, VehicleCommon.CAR_HULLS_PATH)
		baked = n >= 2
		if not baked:
			n = VehicleCommon.add_convexes_from_visual(self, visuals.wrap, VehicleCommon.WHEELISH_RE, 0.05)
	# Keep generated hulls clear of the wheel volume so suspension can work.
	# Baked resources are already trimmed.
	if not baked:
		_trim_hulls_above_wheels()
	if n < 2:
		# Fallback boxes that stay above the wheel tops.
		var wr: float = visuals.wheel_r if visuals else 0.34
		var hl: float = visuals.half_l if visuals else 2.4
		var hw: float = minf(visuals.half_w if visuals else 1.0, 0.85)
		var h: float = visuals.height if visuals else 1.2
		var bottom := wr + 0.06
		VehicleCommon.add_box_shape(self, "body", Vector3(0.0, bottom + (h - bottom) * 0.38, 0.05), Vector3(hw * 1.7, (h - bottom) * 0.7, hl * 1.55))
		VehicleCommon.add_box_shape(self, "cabin", Vector3(0.0, bottom + (h - bottom) * 0.7, 0.05), Vector3(hw * 1.25, (h - bottom) * 0.5, hl * 0.8))


func _build_wheels() -> void:
	var layout: Array = visuals.wheel_layout()
	if layout.is_empty():
		# Fallback sports-car wheel layout (web makeCar).
		layout = [
			{"x": -0.92, "y": 0.34, "z": -1.42, "steer": true},
			{"x": 0.92, "y": 0.34, "z": -1.42, "steer": true},
			{"x": -0.95, "y": 0.34, "z": 1.38, "steer": false},
			{"x": 0.95, "y": 0.34, "z": 1.38, "steer": false},
		]
	var r := visuals.wheel_r
	for i in layout.size():
		var w: Dictionary = layout[i]
		var wh := VehicleWheel3D.new()
		wh.name = "Wheel_%d" % i
		add_child(wh)
		# VehicleWheel3D position is the wheel center in body space.
		# Visuals were lifted by ORIGIN_Y, so wheel y in body space is offset.y
		# (already relative to the lifted wrap, i.e. body origin).
		# Node origin is the suspension attachment (Godot 4). Place it
		# rest_length above the visual wheel centre so the physics wheel
		# sits on the visual at rest, not buried in the pavement.
		var wy := float(w["y"])
		wh.position = Vector3(float(w["x"]), wy + SUSP_TRAVEL, float(w["z"]))
		wh.wheel_radius = r
		wh.wheel_rest_length = SUSP_TRAVEL
		wh.suspension_stiffness = SUSP_STIFFNESS
		wh.suspension_max_force = SUSP_MAX_FORCE
		wh.damping_compression = DAMP_COMP
		wh.damping_relaxation = DAMP_REL
		wh.wheel_friction_slip = WHEEL_FRICTION_FRONT if bool(w["steer"]) else WHEEL_FRICTION_REAR
		wh.wheel_roll_influence = 0.1  # VehicleWheel3D default; Truck Town uses 0.4 (truck)
		wh.use_as_steering = bool(w["steer"])
		# Driven wheels: rear always, front lightly (AWD launch, RWD feel).
		wh.use_as_traction = true
		_wheels.append(wh)
		_wheel_rest.append(wh.position)


func _freeze_parked(on: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = on and not occupied
	if freeze:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true
	_restore_wheel_positions()


func _restore_wheel_positions() -> void:
	## Jolt has been seen to clear wheel local origins; put them back.
	for i in _wheels.size():
		if i < _wheel_rest.size() and _wheel_rest[i].length_squared() > 0.01:
			if _wheels[i].position.distance_squared_to(_wheel_rest[i]) > 0.0001:
				_wheels[i].position = _wheel_rest[i]
				_wheels[i].reset_physics_interpolation()


func _trim_hulls_above_wheels() -> void:
	var floor_y := -1.0e9
	for w in _wheels if _wheels else []:
		# Wheel contact in body space: attachment.y - rest - radius.
		floor_y = maxf(floor_y, w.position.y - w.wheel_rest_length - w.wheel_radius)
	if floor_y < -1.0e8:
		# Wheels not built yet — use visual wheel bottoms.
		if visuals:
			for w in visuals.wheel_layout():
				floor_y = maxf(floor_y, float(w["y"]) - visuals.wheel_r)
	var min_keep := floor_y + 0.04
	for c in get_children():
		if not (c is CollisionShape3D):
			continue
		var cs := c as CollisionShape3D
		var y := VehicleCommon.shape_lowest_y(cs)
		if y < min_keep:
			if cs.shape is BoxShape3D:
				var box := cs.shape as BoxShape3D
				var lift := min_keep - y
				cs.position.y += lift * 0.5
				box.size.y = maxf(0.08, box.size.y - lift)
			else:
				# Convex under-wheel leftovers would jolt the chassis; drop them.
				cs.queue_free()


func spawn_lift() -> float:
	## Body-origin height above the ground so the wheels rest on the pavement.
	var contact := 1.0e9
	if _wheels:
		for w in _wheels:
			contact = minf(contact, w.position.y - w.wheel_rest_length - w.wheel_radius)
	elif visuals:
		for w in visuals.wheel_layout():
			contact = minf(contact, float(w["y"]) - visuals.wheel_r)
	if contact > 1.0e8:
		contact = -0.48
	return -contact + 0.02


func set_driver_input(throttle: float, steer: float, brake: float, hb: bool, nt: bool) -> void:
	throttle_in = clampf(throttle, -1.0, 1.0)
	steer_in = clampf(steer, -1.0, 1.0)
	brake_in = clampf(brake, 0.0, 1.0)
	handbrake = hb
	nitro = nt


func _physics_process(delta: float) -> void:
	_restore_wheel_positions()
	door += (door_target - door) * (1.0 - exp(-8.0 * delta))
	if not occupied:
		engine_force = 0.0
		brake = BRAKE_FORCE * 0.35
		steering = 0.0
		_apply_visuals(delta)
		return
	_drive(delta)
	_apply_visuals(delta)


func _drive(delta: float) -> void:
	var speed := linear_velocity.length()
	var fwd := -global_transform.basis.z
	var long_speed := linear_velocity.dot(fwd)  # + = forward
	# Steering: slower at speed (Ackermann-ish reduction).
	var steer_limit := MAX_STEER / (1.0 + speed * 0.05)
	var steer_target := steer_in * steer_limit
	steer_angle = move_toward(steer_angle, steer_target, STEER_SPEED * delta)
	steering = steer_angle
	# Automatic gearbox is visual / RPM only; force follows Truck Town.
	var wheel_r := visuals.wheel_r if visuals else 0.34
	_update_gear(long_speed, wheel_r)
	var ratio: float = GEAR_RATIOS[gear] * FINAL_DRIVE
	var wheel_rad_s := (long_speed / maxf(wheel_r, 0.2))
	var shaft_rpm := absf(wheel_rad_s) * ratio * 60.0 / TAU
	var want_rpm := maxf(IDLE_RPM, shaft_rpm)
	if absf(throttle_in) > 0.05 and absf(long_speed) < 1.0:
		want_rpm = lerpf(want_rpm, lerpf(IDLE_RPM, REDLINE_RPM, absf(throttle_in)), 0.55)
	rpm = move_toward(rpm, clampf(want_rpm, IDLE_RPM, REDLINE_RPM), 6000.0 * delta)
	# Truck Town: engine_force_value, with a low-speed launch boost, capped.
	# Visual nose is -Z; VehicleBody3D applies +engine_force along +Z, so flip.
	var cap := ENGINE_FORCE_NITRO if (nitro and throttle_in > 0.1) else ENGINE_FORCE
	if throttle_in < -0.02:
		cap = ENGINE_FORCE_REV
	var force := cap * throttle_in
	var spd := absf(long_speed)
	if spd < 5.0 and absf(throttle_in) > 0.02 and not is_zero_approx(spd):
		force = signf(throttle_in) * clampf(cap * 5.0 / maxf(spd, 0.35), 0.0, cap * 1.6)
	elif spd < 5.0 and absf(throttle_in) > 0.02:
		force = signf(throttle_in) * cap * 1.35
	engine_force = -force
	# Per-wheel brake / handbrake (rear bias on HB) and grip for drift.
	var br := brake_in * BRAKE_FORCE
	if handbrake:
		br = HANDBRAKE_FORCE
	brake = br
	for i in _wheels.size():
		var w := _wheels[i]
		if w.use_as_steering:
			w.wheel_friction_slip = WHEEL_FRICTION_FRONT
			w.brake = br * 0.7
		elif handbrake:
			w.wheel_friction_slip = WHEEL_FRICTION_HB
			w.brake = HANDBRAKE_FORCE
			w.engine_force = 0.0
		else:
			w.wheel_friction_slip = WHEEL_FRICTION_REAR
			w.brake = br
	# Keep the body awake while driving.
	if absf(throttle_in) > 0.02 or absf(steer_in) > 0.02 or speed > 0.4:
		sleeping = false


func _update_gear(long_speed: float, wheel_r: float) -> void:
	if long_speed < -0.6 and throttle_in < -0.1:
		gear = 1
		return
	# Pick the gear whose rpm sits in the meat of the curve.
	var best := gear
	var best_score := 1e9
	for g in range(1, GEAR_RATIOS.size()):
		var ratio: float = GEAR_RATIOS[g] * FINAL_DRIVE
		var r := absf(long_speed / maxf(wheel_r, 0.2)) * ratio * 60.0 / TAU
		if r < IDLE_RPM * 0.8 or r > REDLINE_RPM * 1.05:
			continue
		var score := absf(r - PEAK_RPM)
		if score < best_score:
			best_score = score
			best = g
	# Don't skip-shift too fast; allow 1 gear at a time.
	if best > gear:
		gear = mini(gear + 1, best)
	elif best < gear:
		gear = maxi(gear - 1, best)
	gear = clampi(gear, 1, GEAR_RATIOS.size() - 1)


func _apply_visuals(delta: float) -> void:
	if visuals == null or not visuals.ready_ok:
		return
	var fwd := -global_transform.basis.z
	var long_speed := linear_velocity.dot(fwd)
	_vis_spin += (long_speed / maxf(visuals.wheel_r, 0.2)) * delta
	var susp: Array = []
	for w in _wheels:
		# Map compression to the 0–1 "susp" the web visuals used (0.4 rest).
		var k := 0.4
		if w.has_method("get_suspension_travel"):  # not always present
			pass
		# VehicleWheel3D: get_contact_count / is_in_contact. Approximate sag from position.
		k = 0.4 + (0.08 if w.is_in_contact() else -0.15)
		susp.append(k)
	visuals.apply_pose({
		"steer_angle": steer_angle,
		"wheel_spin": _vis_spin,
		"susp": susp,
	}, delta, Time.get_ticks_msec() * 0.001)


func pose_state() -> Dictionary:
	return {
		"kind": KIND,
		"steer_angle": steer_angle,
		"wheel_spin": _vis_spin,
		"speed": linear_velocity.length(),
		"gear": float(gear),
		"rpm": rpm,
		"door": door,
	}


func cockpit_offset() -> Vector3:
	if visuals:
		return Vector3(float(visuals.cockpit["x"]), float(visuals.cockpit["y"]), float(visuals.cockpit["z"]))
	return Vector3(-0.38, 0.42, 0.22)


func exit_offset() -> Vector3:
	# Stand beside the left door.
	return global_transform.basis * Vector3(-(visuals.half_w if visuals else 1.1) - 0.7, 0.0, 0.0)


func on_enter() -> void:
	occupied = true
	door_target = 1.0
	_freeze_parked(false)
	sleeping = false
	occupied_changed.emit(true)


func on_exit() -> void:
	occupied = false
	door_target = 0.0
	throttle_in = 0.0
	steer_in = 0.0
	brake_in = 1.0
	handbrake = false
	nitro = false
	engine_force = 0.0
	brake = BRAKE_FORCE
	# Settle, then freeze once almost still so parked cars don't creep.
	occupied_changed.emit(false)
	get_tree().create_timer(0.8).timeout.connect(func():
		if not occupied and linear_velocity.length() < 0.6:
			_freeze_parked(true)
	)
