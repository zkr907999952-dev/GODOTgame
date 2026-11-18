extends RigidBody3D
## Sports-car physics: RigidBody3D + per-wheel RayCast3D suspension, ported
## from the mature Godot 4.6 + Jolt project simonfruehauf/custom-3d-car
## (https://github.com/simonfruehauf/custom-3d-car) and retuned for this
## 1420 kg coupe (shorter travel, stiffer springs, nitro, existing W/S A/D
## Shift/Space binds). Lateral tire force is what lets the car actually turn.
class_name CarController

const CarSkidMarksScript := preload("res://scripts/vehicles/car_skids.gd")

const KIND := "car"
const ENTER_RADIUS := 4.2
const MASS_KG := 1420.0
const MAX_STEER := 0.70  # rad (~40°); more lock at low and driving speeds
const STEER_SPEED := 5.2
const IDLE_RPM := 900.0
const REDLINE_RPM := 8200.0
const PEAK_RPM := 5200.0
const FINAL_DRIVE := 3.54
const GEAR_RATIOS := [0.0, 3.21, 2.11, 1.47, 1.14, 0.92, 0.74]
# custom-3d-car: ENGINE_POWER = 15 * HP at ~1000 kg. Scale ~1.42 for this mass.
# 0.2.23: base power raised (9800 → 11800) because 0.2.22 still felt weak.
# Auto-nitro engages above NITRO_SPEED while accelerating; Shift still punches it.
# Auto nitro uses ENGINE_POWER_NITRO; Shift on top can hold it even below the
# speed gate. Combined (Shift + already auto) stays on the nitro curve.
const ENGINE_POWER := 11800.0
const ENGINE_POWER_NITRO := 17800.0
const ENGINE_POWER_REV := 6200.0
# Auto-nitro gate: 24 m/s ≈ 86 km/h. Feels like the second-stage rush after
# the first few gears; drops out 3 m/s below so it doesn't chatter.
const NITRO_SPEED := 24.0
const NITRO_SPEED_DROP := 21.0
const BRAKE_FORCE_MULT := 1.5
const HANDBRAKE_MULT := 3.0
# Suspension: weight/wheel ≈ 3480 N. 0.2.23 raises the rest length again
# (0.30 → 0.36) so the wheels sit clear of the body instead of sinking in.
const SPRING_STRENGTH := 50000.0
const SPRING_DAMP := 3300.0
const REST_DISTANCE := 0.36
const TIRE_GRIP := 7400.0
const GRIP_FALLOFF := 0.032
const MAX_LATERAL_FORCE := 14500.0
const ROLLING_FRICTION := 24.0
const HULL_CLEARANCE := 0.12

signal occupied_changed(on: bool)

var vehicle_id: String = ""
var is_default: bool = false
var is_menu_spawned: bool = false
var occupied: bool = false
var door: float = 0.0
var door_target: float = 0.0
var throttle_in: float = 0.0
var steer_in: float = 0.0
var brake_in: float = 0.0
var handbrake: bool = false
var nitro: bool = false
var nitro_auto: bool = false
var nitro_active: bool = false
var _skids: Node
var _wheel_slip: PackedFloat32Array = PackedFloat32Array()
var _wheel_hit_pos: PackedVector3Array = PackedVector3Array()
var _wheel_hit_n: PackedVector3Array = PackedVector3Array()
var _wheel_side: PackedVector3Array = PackedVector3Array()
var gear: int = 1
var rpm: float = IDLE_RPM
var steer_angle: float = 0.0
var wheel_spin: float = 0.0
var visuals: CarVisuals
var _wheels: Array[RayCast3D] = []
var _wheel_rest: Array[Vector3] = []
var _wheel_steer: Array[bool] = []
var _wheel_drive: Array[bool] = []
var _wheel_prev_len: PackedFloat32Array = PackedFloat32Array()
var _wheel_in_contact: Array[bool] = []
var _vis_spin: float = 0.0
var spawn_map: String = "city"


func _ready() -> void:
	mass = MASS_KG
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -0.22, 0.08)
	gravity_scale = 1.0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	collision_layer = 1
	collision_mask = 1
	can_sleep = true
	linear_damp = 0.03
	angular_damp = 0.08
	if physics_material_override == null:
		var mat := PhysicsMaterial.new()
		mat.friction = 0.12
		mat.bounce = 0.0
		physics_material_override = mat
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
	_skids = CarSkidMarksScript.new()
	add_child(_skids)
	_skids.setup()
	_wheel_slip.resize(4)
	_wheel_hit_pos.resize(4)
	_wheel_hit_n.resize(4)
	_wheel_side.resize(4)
	call_deferred("_restore_wheel_positions")


func _build_collision() -> void:
	var n := 0
	var baked := false
	if visuals and visuals.wrap:
		n = VehicleCommon.apply_baked_hulls(self, VehicleCommon.CAR_HULLS_PATH)
		baked = n >= 2
		if not baked:
			n = VehicleCommon.add_convexes_from_visual(self, visuals.wrap, VehicleCommon.WHEELISH_RE, 0.05)
	if n < 2:
		var wr: float = visuals.wheel_r if visuals else 0.34
		var hl: float = visuals.half_l if visuals else 2.4
		var hw: float = minf(visuals.half_w if visuals else 1.0, 0.85)
		var h: float = visuals.height if visuals else 1.2
		var bottom := wr + 0.06
		VehicleCommon.add_box_shape(self, "body", Vector3(0.0, bottom + (h - bottom) * 0.38, 0.05), Vector3(hw * 1.7, (h - bottom) * 0.7, hl * 1.55))
		VehicleCommon.add_box_shape(self, "cabin", Vector3(0.0, bottom + (h - bottom) * 0.7, 0.05), Vector3(hw * 1.25, (h - bottom) * 0.5, hl * 0.8))
	# Always keep hulls above the equilibrium contact + sag, including baked
	# or fallback shapes — otherwise the chassis snags the road after sag.
	_lift_hulls_for_ride()


func _build_wheels() -> void:
	var layout: Array = visuals.wheel_layout() if visuals else []
	if layout.is_empty():
		layout = [
			{"x": -0.92, "y": 0.34, "z": -1.42, "steer": true},
			{"x": 0.92, "y": 0.34, "z": -1.42, "steer": true},
			{"x": -0.95, "y": 0.34, "z": 1.38, "steer": false},
			{"x": 0.95, "y": 0.34, "z": 1.38, "steer": false},
		]
	var r := visuals.wheel_r if visuals else 0.34
	_wheel_prev_len.resize(layout.size())
	for i in layout.size():
		var w: Dictionary = layout[i]
		var ray := RayCast3D.new()
		ray.name = "Wheel_%d" % i
		add_child(ray)
		# Attachment sits REST_DISTANCE above the visual wheel centre so the
		# ray (down through the rest length + radius) sits on the pavement
		# at rest, matching custom-3d-car's RayCast3D layout.
		var wy := float(w["y"])
		ray.position = Vector3(float(w["x"]), wy + REST_DISTANCE, float(w["z"]))
		ray.target_position = Vector3(0.0, -(REST_DISTANCE + r + 0.08), 0.0)
		ray.collision_mask = 1
		ray.exclude_parent = true
		ray.enabled = true
		ray.hit_from_inside = true
		_wheels.append(ray)
		_wheel_rest.append(ray.position)
		var is_steer := bool(w["steer"])
		_wheel_steer.append(is_steer)
		# Rear-wheel drive (custom-3d-car default) with light front help off the line.
		_wheel_drive.append(not is_steer)
		_wheel_in_contact.append(false)
		_wheel_prev_len[i] = REST_DISTANCE


func _freeze_parked(on: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = on and not occupied
	if freeze:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true
	_restore_wheel_positions()


func _restore_wheel_positions() -> void:
	for i in _wheels.size():
		if i < _wheel_rest.size() and _wheel_rest[i].length_squared() > 0.01:
			if _wheels[i].position.distance_squared_to(_wheel_rest[i]) > 0.0001:
				_wheels[i].position = _wheel_rest[i]
				_wheels[i].rotation = Vector3(0.0, steer_angle if (i < _wheel_steer.size() and _wheel_steer[i]) else 0.0, 0.0)
				_wheels[i].reset_physics_interpolation()


func _trim_hulls_above_wheels() -> void:
	var floor_y := -1.0e9
	var r := visuals.wheel_r if visuals else 0.34
	for w in _wheels:
		floor_y = maxf(floor_y, w.position.y - REST_DISTANCE - r)
	if floor_y < -1.0e8 and visuals:
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
				cs.queue_free()


func _lift_hulls_for_ride() -> void:
	## Raise collision hulls so they stay clear of the pavement after the
	## springs sag under the car's weight. Uses body-space lowest points.
	var r := visuals.wheel_r if visuals else 0.34
	var contact := 1.0e9
	if _wheels:
		for w in _wheels:
			contact = minf(contact, w.position.y - REST_DISTANCE - r)
	elif visuals:
		for w in visuals.wheel_layout():
			contact = minf(contact, float(w["y"]) - r)
	if contact > 1.0e8:
		contact = -r
	var sag := (MASS_KG * 9.81 / maxf(float(_wheels.size()), 4.0)) / SPRING_STRENGTH
	var min_keep := contact + sag + HULL_CLEARANCE
	for c in get_children():
		if not (c is CollisionShape3D):
			continue
		var cs := c as CollisionShape3D
		var y := VehicleCommon.shape_lowest_y(cs)
		if y >= min_keep - 0.001:
			continue
		var lift := min_keep - y
		if cs.shape is BoxShape3D:
			var box := cs.shape as BoxShape3D
			cs.position.y += lift * 0.5
			box.size.y = maxf(0.08, box.size.y - lift)
		else:
			cs.position.y += lift


func spawn_lift() -> float:
	var r := visuals.wheel_r if visuals else 0.34
	var contact := 1.0e9
	if _wheels:
		for w in _wheels:
			contact = minf(contact, w.position.y - REST_DISTANCE - r)
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
		throttle_in = 0.0
		steer_in = 0.0
		brake_in = 1.0
		nitro = false
		nitro_auto = false
		nitro_active = false
		_apply_visuals(delta)
		return
	_drive(delta)
	_apply_visuals(delta)


func _drive(delta: float) -> void:
	var speed := linear_velocity.length()
	var fwd := -global_transform.basis.z
	var long_speed := linear_velocity.dot(fwd)
	# Auto nitro: after the car has accelerated past NITRO_SPEED while the
	# throttle is in, the boost stays on until speed falls below the drop gate
	# or the driver lifts. Shift is a manual punch that works at any speed.
	if throttle_in > 0.35 and long_speed >= NITRO_SPEED:
		nitro_auto = true
	elif throttle_in < 0.12 or long_speed < NITRO_SPEED_DROP:
		nitro_auto = false
	nitro_active = occupied and throttle_in > 0.12 and (nitro or nitro_auto)
	var steer_limit := MAX_STEER / (1.0 + speed * 0.022)
	var steer_target := steer_in * steer_limit
	steer_angle = move_toward(steer_angle, steer_target, STEER_SPEED * delta)
	var wheel_r := visuals.wheel_r if visuals else 0.34
	_update_gear(long_speed, wheel_r)
	var ratio: float = GEAR_RATIOS[gear] * FINAL_DRIVE
	var wheel_rad_s := long_speed / maxf(wheel_r, 0.2)
	var shaft_rpm := absf(wheel_rad_s) * ratio * 60.0 / TAU
	var want_rpm := maxf(IDLE_RPM, shaft_rpm)
	if absf(throttle_in) > 0.05 and absf(long_speed) < 1.0:
		want_rpm = lerpf(want_rpm, lerpf(IDLE_RPM, REDLINE_RPM, absf(throttle_in)), 0.55)
	rpm = move_toward(rpm, clampf(want_rpm, IDLE_RPM, REDLINE_RPM), 6000.0 * delta)
	if absf(throttle_in) > 0.02 or absf(steer_in) > 0.02 or speed > 0.4:
		sleeping = false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _wheels.is_empty():
		return
	var dt := state.step
	if dt <= 0.0:
		return
	var r := visuals.wheel_r if visuals else 0.34
	var xf := state.transform
	var origin := xf.origin
	var up := xf.basis.y.normalized()
	var fwd := -xf.basis.z
	var power := ENGINE_POWER_NITRO if nitro_active else ENGINE_POWER
	if throttle_in < -0.02:
		power = ENGINE_POWER_REV
	var drive_count := 0
	for d in _wheel_drive:
		if d:
			drive_count += 1
	if drive_count <= 0:
		drive_count = 1
	for i in _wheels.size():
		var ray := _wheels[i]
		var steer := steer_angle if (i < _wheel_steer.size() and _wheel_steer[i]) else 0.0
		ray.rotation = Vector3(0.0, steer, 0.0)
		ray.force_raycast_update()
		var attach: Vector3 = xf * ray.position
		var hit := ray.is_colliding()
		_wheel_in_contact[i] = hit
		if not hit:
			_wheel_prev_len[i] = REST_DISTANCE
			if i < _wheel_slip.size():
				_wheel_slip[i] = 0.0
				_wheel_in_contact[i] = false
			continue
		var point := ray.get_collision_point()
		var dist := attach.distance_to(point)
		var spring_length := clampf(dist - r, 0.0, REST_DISTANCE)
		var spring_force := SPRING_STRENGTH * (REST_DISTANCE - spring_length)
		var spring_vel := (_wheel_prev_len[i] - spring_length) / dt
		var damper := SPRING_DAMP * spring_vel
		_wheel_prev_len[i] = spring_length
		var susp_n := spring_force + damper
		var wheel_up := (xf.basis * ray.basis).y.normalized()
		if wheel_up.dot(up) < 0.0:
			wheel_up = up
		state.apply_force(wheel_up * susp_n, attach - origin)
		var wheel_basis: Basis = (xf.basis * ray.basis).orthonormalized()
		var wheel_fwd := -wheel_basis.z
		var wheel_side := wheel_basis.x
		var vel := state.linear_velocity + state.angular_velocity.cross(point - origin)
		# Lateral grip (custom-3d-car _apply_lateral_force) — this is the turn force.
		var lat_v := vel.dot(wheel_side)
		if i < _wheel_slip.size():
			_wheel_slip[i] = absf(lat_v)
			_wheel_hit_pos[i] = point
			_wheel_hit_n[i] = ray.get_collision_normal()
			_wheel_side[i] = wheel_side
		var desired_lat := -lat_v * TIRE_GRIP
		var spd := state.linear_velocity.length()
		var grip_factor := 1.0 / (1.0 + spd * GRIP_FALLOFF)
		if handbrake and not _wheel_steer[i]:
			grip_factor *= 0.12
		var max_lat := MAX_LATERAL_FORCE * grip_factor
		var lat := clampf(desired_lat, -max_lat, max_lat)
		state.apply_force(wheel_side * lat, point - origin)
		# Rolling resistance and brakes.
		var long_v := vel.dot(wheel_fwd)
		var long_force := -long_v * ROLLING_FRICTION
		if handbrake:
			long_force *= HANDBRAKE_MULT
		elif brake_in > 0.05:
			long_force += -signf(long_v) * brake_in * power * BRAKE_FORCE_MULT / float(maxi(_wheels.size(), 1))
		# Drive: rear wheels, force along the visual nose (-Z). Custom-3d-car
		# used +Z because its mesh faces +Z; ours faces -Z, so no sign flip.
		if occupied and _wheel_drive[i] and not handbrake:
			var mult := power / float(drive_count)
			var ratio: float = GEAR_RATIOS[gear] * FINAL_DRIVE * 0.22
			mult *= maxf(ratio, 0.4)
			if rpm > REDLINE_RPM:
				mult = 0.0
			# Braking if throttle is against current motion.
			if throttle_in * long_v < -0.05 and absf(long_v) > 1.0:
				long_force += -signf(long_v) * absf(throttle_in) * power * BRAKE_FORCE_MULT / float(drive_count)
			else:
				long_force += wheel_fwd.dot(fwd) * throttle_in * mult
		state.apply_force(wheel_fwd * long_force, point - origin)


func _update_gear(long_speed: float, wheel_r: float) -> void:
	if long_speed < -0.6 and throttle_in < -0.1:
		gear = 1
		return
	var best := gear
	var best_score := 1e9
	for g in range(1, GEAR_RATIOS.size()):
		var ratio: float = GEAR_RATIOS[g] * FINAL_DRIVE
		var rv := absf(long_speed / maxf(wheel_r, 0.2)) * ratio * 60.0 / TAU
		if rv < IDLE_RPM * 0.8 or rv > REDLINE_RPM * 1.05:
			continue
		var score := absf(rv - PEAK_RPM)
		if score < best_score:
			best_score = score
			best = g
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
	# Forward motion must spin the wheel so the contact patch travels backward
	# (rotate around local X with a negative sign). See custom-3d-car _wheel_spin.
	_vis_spin += -(long_speed / maxf(visuals.wheel_r, 0.2)) * delta
	var susp: Array = []
	var travels: Array = []
	for i in _wheels.size():
		var k := 0.4
		var travel := 0.0
		if i < _wheel_in_contact.size() and _wheel_in_contact[i]:
			var spring_len := float(_wheel_prev_len[i])
			var sag := (REST_DISTANCE - spring_len) / maxf(REST_DISTANCE, 0.05)
			k = 0.4 + clampf(sag, 0.0, 1.0) * 0.25
			# Body-space wheel centre sits at rest_y + (REST - spring_len) so
			# the tire stays on the pavement when the chassis rides higher.
			travel = REST_DISTANCE - spring_len
		else:
			k = 0.25
			travel = 0.0
		susp.append(k)
		travels.append(travel)
	visuals.apply_pose({
		"steer_angle": steer_angle,
		"wheel_spin": _vis_spin,
		"susp": susp,
		"wheel_travel": travels,
		"nitro": nitro_active,
	}, delta, Time.get_ticks_msec() * 0.001)
	if _skids:
		var marks: Array = []
		for i in _wheels.size():
			var side := Vector3.RIGHT
			if i < _wheel_side.size() and _wheel_side[i].length_squared() > 1e-6:
				side = _wheel_side[i]
			marks.append({
				"pos": _wheel_hit_pos[i] if i < _wheel_hit_pos.size() else global_position,
				"normal": _wheel_hit_n[i] if i < _wheel_hit_n.size() else Vector3.UP,
				"slip": float(_wheel_slip[i]) if i < _wheel_slip.size() else 0.0,
				"contact": bool(_wheel_in_contact[i]) if i < _wheel_in_contact.size() else false,
				"side": side,
			})
		_skids.update(marks, delta)


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
	nitro_auto = false
	nitro_active = false
	occupied_changed.emit(false)
	get_tree().create_timer(0.8).timeout.connect(func():
		if not occupied and linear_velocity.length() < 0.6:
			_freeze_parked(true)
	)
