extends RigidBody3D
## Rewritten 0.2.22 aerodynamic flight model on a Jolt RigidBody3D.
## Primary reference: rouchangmoniqi3 src/lib/vehicle-sim.ts stepPlane
## (thrust along the nose, lift vs AoA, drag, and a velocity-alignment
## term so the flight path follows attitude with lag).
## Also: NASA lift/drag (L,D = 0.5 ρ V² S C), fbcosentino/godot-simplified-flightsim
## (aft-applied drag for weathercock / tail stability), and
## brihernandez/ArcadeJetFlightExample (directional drag keeps velocity
## aligned with the jet — otherwise the fuselage can rotate without flying).
## Control rates follow the old project's Ace Combat-like agility
## (responsive pitch/roll, milder yaw). Hold-to-afterburner lives in the
## input layer. Visuals are driven by PlaneVisuals.
class_name PlaneController

const KIND := "plane"
const ENTER_RADIUS := 8.4
const MASS_KG := 14000.0
const WING_AREA := 78.0  # m², F-22 class
const WING_SPAN := 13.6
const MAC := 5.7  # mean aerodynamic chord
const THRUST_DRY := 680000.0  # N, 0.2.24 punch (~4.9 g dry)
const THRUST_AB := 1120000.0  # ~8.1 g with hold-to-afterburner
const CD0 := 0.028
const K_INDUCED := 0.11
const CL_ALPHA := 4.4  # per radian
const CL_MAX := 1.15
const ALPHA_STALL := 0.28  # rad ≈ 16°
# Speed stall (arcade-realistic): below this airspeed the jet loses authority
# and the nose drops. Decelerating above this quickly raises pitch/roll agility.
const STALL_SPEED := 52.0  # m/s ≈ 187 km/h
# Short-window pitch boost while (and briefly after) decelerating. Peak is
# a large snap / aerial-drift, then it settles; a stall still happens if
# airspeed bleeds below STALL_SPEED.
const DECEL_AGILITY := 2.85
const DECEL_BOOST_HOLD := 0.85  # seconds at peak while held
const DECEL_BOOST_FADE := 0.32  # seconds of leftover boost after release
const DECEL_YAW_COUPLE := 0.62
const RHO_SL := 1.225
# Gear-down parasite drag. Raised a little so a hanging gear is noticeable
# (Ace Combat / old web project: gear adds measurable drag).
const GEAR_DRAG := 0.032
# Auto-retract once clearly off the pavement. Same 3.4 m AGL threshold as
# rouchangmoniqi3 src/lib/vehicle-sim.ts (agl > 3.4). Never retract while
# the weight is still on the wheels.
const GEAR_AUTO_RETRACT_AGL := 3.4
const GEAR_AUTO_EXTEND_AGL := 2.6
const BRAKE_DRAG := 0.05
# Flight-path alignment (vehicle-sim.ts `track`, ArcadeJetFlightExample drag).
# Without this, pitching only spins the mesh; translation lags or never turns.
const TRACK_K0 := 0.28
const TRACK_K_SPD := 0.014
const TRACK_BLEND := 0.62
const ROTATE_SPEED := 42.0  # m/s, ~150 km/h — taxi then pull stick to rotate
const TAXI_THRUST_SCALE := 0.42  # keep ground roll usable with the stronger dry thrust
const GEAR_TRAVEL := 0.32
const GEAR_STIFF := 420000.0
const GEAR_DAMP := 56000.0

signal occupied_changed(on: bool)

var vehicle_id: String = ""
var is_default: bool = false
var is_menu_spawned: bool = false
var occupied: bool = false
var spawn_map: String = "city"
var door: float = 0.0
var door_target: float = 0.0
var thrust: float = 0.0  # 0..1 (0.8 = mil, 1.0 = AB)
var ctrl_pitch: float = 0.0
var ctrl_roll: float = 0.0
var ctrl_yaw: float = 0.0
var speed_brake: float = 0.0
var gear: float = 1.0  # 1 down, 0 up
var gear_want: float = 1.0
var airborne: bool = false
var steer_angle: float = 0.0
var wheel_spin: float = 0.0
var stall_amount: float = 0.0
var aoa: float = 0.0
var airspeed: float = 0.0
var g_load: float = 1.0  # body-up load factor, ~1 on the runway
var _decel_boost: float = 0.0  # 0..1 short-window decel pitch boost
var _decel_hold_t: float = 0.0
var visuals: PlaneVisuals
var _vis_spin: float = 0.0
var _gear_rays: Array[Vector3] = [
	Vector3(0.0, 0.0, -4.1),
	Vector3(-1.85, 0.0, 1.4),
	Vector3(1.85, 0.0, 1.4),
]
var _on_wheels: bool = true
var _agl: float = 0.0
var _gear_setup: Array = []  # {start, rest, radius} in body space
var _prev_vel: Vector3 = Vector3.ZERO
var _prev_vel_ok: bool = false


func _ready() -> void:
	mass = MASS_KG
	# Slightly nose-forward inertia; custom inertia keeps pitch/roll from feeling floaty.
	inertia = Vector3(28000.0, 52000.0, 22000.0)  # Ixx pitch, Iyy yaw, Izz roll (approx)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, 0.05, 0.35)
	gravity_scale = 1.0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 12
	collision_layer = 1
	collision_mask = 1
	linear_damp = 0.0
	angular_damp = 0.08  # residual; most damping comes from aero
	can_sleep = true
	visuals = PlaneVisuals.new()
	visuals.name = "Visuals"
	add_child(visuals)
	if not visuals.setup():
		push_error("PlaneController: visual setup failed")
		return
	if visuals.wheels.size() >= 3:
		_gear_rays.clear()
		for w in visuals.wheels:
			var off: Vector3 = w["offset"]
			_gear_rays.append(off)
	_build_collision()
	# Re-apply after shapes exist so Jolt keeps the authored inertia (pitch/yaw/roll).
	inertia = Vector3(28000.0, 52000.0, 22000.0)
	_build_gear_setup()
	_freeze_parked(true)


var gear_manual: bool = false


func _build_collision() -> void:
	# Convex hulls matching the airframe, excluding landing-gear wheels.
	# No concave trimesh on a moving RigidBody. Prefer pre-baked hulls
	# so city default spawns (map teleport) do not stall the main thread.
	var n := 0
	if visuals and visuals.wrap:
		n = VehicleCommon.apply_baked_hulls(self, VehicleCommon.PLANE_HULLS_PATH)
		if n < 3:
			n = VehicleCommon.add_convexes_from_visual(self, visuals.wrap, VehicleCommon.PLANE_GEAR_RE, 0.08)
	if n < 3:
		var hl: float = visuals.half_l if visuals else 8.6
		VehicleCommon.add_box_shape(self, "fuse", Vector3(0.0, 0.25, 0.4), Vector3(2.2, 1.6, hl * 1.35))
		VehicleCommon.add_box_shape(self, "wing", Vector3(0.0, 0.15, 0.6), Vector3(13.0, 0.22, 4.4))
		VehicleCommon.add_box_shape(self, "vstab", Vector3(0.0, 1.2, hl * 0.7), Vector3(0.22, 1.8, 1.8))
	# Keep hulls above typical wheel contact (~ origin_y below body origin).
	var min_keep := -0.95
	if visuals:
		for w in visuals.wheels:
			var off: Vector3 = w.get("offset", Vector3.ZERO)
			min_keep = minf(min_keep, off.y + 0.15)
	for c in get_children():
		if c is CollisionShape3D:
			var y := VehicleCommon.shape_lowest_y(c as CollisionShape3D)
			if y < min_keep and (c as CollisionShape3D).shape is BoxShape3D:
				var box := (c as CollisionShape3D).shape as BoxShape3D
				var lift := min_keep - y
				c.position.y += lift * 0.5
				box.size.y = maxf(0.08, box.size.y - lift)
	# Airframe hulls must not pin the jet to the pavement; wheels carry the weight.
	if physics_material_override == null:
		var mat := PhysicsMaterial.new()
		mat.friction = 0.04
		mat.bounce = 0.0
		physics_material_override = mat


func _build_gear_setup() -> void:
	## One spring per visual wheel. Rest lengths are chosen so every leg
	## carries load at spawn_lift (main-gear visuals sit a little higher
	## than the nose, so they are virtually extended to the pavement).
	_gear_setup.clear()
	var wr: float = visuals.wheel_r if visuals else 0.42
	var lift := spawn_lift()
	var sag := 0.10
	for off in _gear_rays:
		var start := off + Vector3(0.0, 1.15, 0.0)
		# World dist from start to the runway when the body is at spawn height.
		var dist_at_spawn := lift + start.y
		var rest := dist_at_spawn + sag
		_gear_setup.append({"start": start, "rest": rest, "radius": wr})


func _freeze_parked(on: bool) -> void:
	freeze = on and not occupied
	if freeze:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true


func set_pilot_input(pitch: float, roll: float, yaw: float, throttle_delta: float, brake: float, steer: float) -> void:
	ctrl_pitch = clampf(pitch, -1.0, 1.0)
	ctrl_roll = clampf(roll, -1.0, 1.0)
	ctrl_yaw = clampf(yaw, -1.0, 1.0)
	if throttle_delta != 0.0:
		thrust = clampf(thrust + throttle_delta, 0.0, 1.0)
	speed_brake = clampf(brake, 0.0, 1.0)
	steer_angle = clampf(steer, -1.0, 1.0) * 0.55


func set_throttle(t: float) -> void:
	thrust = clampf(t, 0.0, 1.0)


func spawn_lift() -> float:
	## Body-origin height above the ground so the visual gear sits on the runway.
	var contact := 1.0e9
	if visuals:
		for w in visuals.wheels:
			var off: Vector3 = w.get("offset", Vector3.ZERO)
			contact = minf(contact, off.y - visuals.wheel_r)
	if contact > 1.0e8:
		return 1.40
	return -contact + 0.03


func rotate_speed() -> float:
	return ROTATE_SPEED


func gear_drag_coeff() -> float:
	## Extra parasite-drag term from the hanging gear (0 when retracted).
	return gear * GEAR_DRAG


func weight_on_gear() -> bool:
	## True when the jet is settled on the pavement and the legs are carrying load.
	return gear > 0.35 and _on_wheels and _agl < 1.5


func toggle_gear() -> void:
	## G / mobile button / Ctrl. Refuse to retract while settled on the runway
	## so the jet is not left unsupported on the hull.
	gear_manual = true
	# Toggle the *commanded* state so a second G before the legs finish
	# moving still reverses the request (not the in-between visual pose).
	if gear_want > 0.5:
		if weight_on_gear():
			return
		gear_want = 0.0
	else:
		gear_want = 1.0


func _physics_process(delta: float) -> void:
	door += (door_target - door) * (1.0 - exp(-8.0 * delta))
	# Auto gear, unless the pilot toggled it (G / Ctrl / mobile).
	# Retract only when the weight is off the wheels and AGL is past the
	# Ace Combat / old-project threshold. Auto-extend again on approach.
	if not gear_manual:
		# Retract once clearly off the pavement (AGL + no weight on the legs).
		# Do not wait on the airborne flag alone — a late flag used to leave
		# the gear hanging after a normal takeoff.
		if (not weight_on_gear()) and _agl > GEAR_AUTO_RETRACT_AGL and airspeed > 18.0:
			gear_want = 0.0
		elif _agl < GEAR_AUTO_EXTEND_AGL or weight_on_gear():
			gear_want = 1.0
	gear = move_toward(gear, gear_want, delta * (1.55 if gear_manual else 0.95))
	# Signed: forward (along the visual nose) spins the contact patch backward.
	var long_spin := linear_velocity.dot(-global_transform.basis.z)
	_vis_spin += -(long_spin / 0.42) * delta * (1.0 if _on_wheels else 0.15)
	wheel_spin = _vis_spin
	if visuals:
		visuals.apply_pose({
			"gear": gear,
			"steer_angle": steer_angle,
			"wheel_spin": wheel_spin,
			"door": door,
			"ctrl_pitch": ctrl_pitch,
			"ctrl_roll": ctrl_roll,
			"ctrl_yaw": ctrl_yaw,
			"thrust": thrust,
			"speed_brake": speed_brake,
			"airborne": airborne,
			"speed": airspeed,
			"aoa": aoa,
			"g_load": g_load,
			"agl": _agl,
			"decelerating": bool(get_meta("decelerating", false)) or speed_brake > 0.15 or thrust < 0.32,
			"susp": [0.4, 0.4, 0.4],
		}, delta, Time.get_ticks_msec() * 0.001, global_position.y)
	if not occupied:
		# Parked: bleed throttle, keep brakes.
		thrust = move_toward(thrust, 0.0, delta * 0.4)
		ctrl_pitch = 0.0
		ctrl_roll = 0.0
		ctrl_yaw = 0.0


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var dt := state.step
	if dt <= 0.0:
		return
	var xf := state.transform
	var basis := xf.basis
	var fwd := -basis.z  # nose
	var up := basis.y
	var right := basis.x
	var vel := state.linear_velocity
	airspeed = vel.length()
	if _prev_vel_ok and dt > 1e-5:
		var acc: Vector3 = (vel - _prev_vel) / dt
		# Accelerometer G along body up (includes gravity). ~1 parked, >1 in a pull-up.
		var g_inst := (acc - Vector3(0.0, -9.81, 0.0)).dot(up) / 9.81
		g_load = lerpf(g_load, clampf(g_inst, -4.0, 12.0), 1.0 - exp(-8.0 * dt))
	else:
		g_load = 1.0
	_prev_vel = vel
	_prev_vel_ok = true
	var alt := xf.origin.y
	var rho := RHO_SL * exp(-maxf(alt, 0.0) / 8500.0)
	# Wheel contact / AGL (ray along body -Y).
	_probe_ground(state, xf)
	# Air-relative axes (if nearly still, fall back to body axes).
	var v_fwd := vel.dot(fwd)
	var v_up := vel.dot(up)
	var v_right := vel.dot(right)
	if airspeed > 4.0:
		aoa = atan2(-v_up, maxf(v_fwd, 4.0))
	else:
		aoa = 0.0
	var beta := 0.0
	if airspeed > 4.0:
		beta = atan2(v_right, maxf(v_fwd, 4.0))
	# Stall blending (smooth, not a cliff). AoA stall plus a low-speed stall
	# so bleeding too much airspeed for agility ends in a buffet / nose drop.
	var stall := clampf((absf(aoa) - ALPHA_STALL) / 0.12, 0.0, 1.0)
	var speed_stall := 0.0
	if airborne:
		speed_stall = clampf((STALL_SPEED - airspeed) / 14.0, 0.0, 1.0)
	stall = maxf(stall, speed_stall)
	stall_amount = stall
	var cl := clampf(CL_ALPHA * aoa, -CL_MAX, CL_MAX) * (1.0 - 0.72 * stall)
	# Flaps at low speed / gear down add a little CL and CD.
	var flap := visuals.flap_t if visuals else 0.0
	cl += flap * 0.35 * (1.0 - stall)
	var cd := CD0 + K_INDUCED * cl * cl + gear * GEAR_DRAG + speed_brake * BRAKE_DRAG + flap * 0.04 + stall * 0.08
	var q := 0.5 * rho * airspeed * airspeed
	var lift := q * WING_AREA * cl
	var drag := q * WING_AREA * cd
	# Force directions: lift perpendicular to velocity in the symmetry plane
	# (standard aero), falling back to body-up at low speed.
	var lift_dir := up
	if airspeed > 8.0:
		var vhat := vel / airspeed
		lift_dir = vhat.cross(right)
		if lift_dir.length_squared() < 1e-6:
			lift_dir = up
		else:
			lift_dir = lift_dir.normalized()
			if lift_dir.dot(up) < 0.0:
				lift_dir = -lift_dir
	var drag_dir := -vel.normalized() if airspeed > 0.3 else -fwd
	# Thrust along nozzle / body forward. Afterburner kicks in above 0.8.
	var mil := clampf(thrust / 0.8, 0.0, 1.0)
	var ab := clampf((thrust - 0.8) / 0.2, 0.0, 1.0)
	var thrust_n := mil * THRUST_DRY + ab * (THRUST_AB - THRUST_DRY)
	if _on_wheels and not airborne:
		thrust_n *= lerpf(TAXI_THRUST_SCALE, 1.0, clampf(airspeed / ROTATE_SPEED, 0.0, 1.0))
	# Extra lift only when rotating at speed — never from a standstill.
	var rotate_t := 0.0
	if _on_wheels and ctrl_pitch > 0.2 and airspeed > ROTATE_SPEED * 0.70:
		rotate_t = clampf((airspeed / ROTATE_SPEED - 0.70) / 0.30, 0.0, 1.0) * clampf(ctrl_pitch, 0.0, 1.0)
		lift += MASS_KG * 9.81 * rotate_t * 0.85
	var force := fwd * thrust_n + lift_dir * lift + drag_dir * drag
	# Velocity-alignment / flight-path tracking (vehicle-sim.ts):
	#   track = 1 - exp(-dt * (0.28 + speed * 0.014))
	#   vel += (fwd * spd - vel) * track * 0.62
	# As a force: m * (fwd*spd - vel) * k * 0.62. Couples attitude to
	# displacement so a pull-up at speed actually climbs.
	if airborne and airspeed > 8.0:
		var track_k := (TRACK_K0 + airspeed * TRACK_K_SPD) * TRACK_BLEND
		# While the decel-boost window is live, loosen path-tracking a little
		# so a hard pull can slide the nose (aerial drift) instead of staying
		# glued to the velocity vector.
		track_k *= lerpf(1.0, 0.62, _decel_boost if airborne else 0.0)
		force += (fwd * airspeed - vel) * track_k * MASS_KG
	# Control: track the old project's desired body rates (Ace Combat agility)
	# with a torque servo, plus stability-derivative damping and weathercock.
	# Rates: pitch 1.45*ctrl, roll 2.15*ctrl, yaw 0.62, with ctrl = clamp(V/42, 0.22, 1.55).
	var ctrl_s := clampf(airspeed / 42.0, 0.22, 1.55) * (1.0 - 0.55 * stall)
	# Decelerate to trade airspeed for a short-window pitch snap / aerial
	# drift. While the brake is held the boost stays high; it then fades
	# quickly so a tap is not a permanent super-pitch. Stall still bites
	# if speed drops too far.
	var decelerating := bool(get_meta("decelerating", false)) or speed_brake > 0.15
	if decelerating and airborne and speed_stall < 0.22:
		_decel_hold_t = minf(_decel_hold_t + dt, DECEL_BOOST_HOLD)
		_decel_boost = 1.0
	else:
		_decel_hold_t = 0.0
		_decel_boost = maxf(_decel_boost - dt / maxf(DECEL_BOOST_FADE, 0.05), 0.0)
	var boost := _decel_boost * (1.0 - clampf(speed_stall / 0.22, 0.0, 1.0)) if airborne else 0.0
	if not airborne and airspeed < ROTATE_SPEED * 0.70:
		ctrl_s *= 0.15
	# Low-speed stall: lose most pitch/roll authority.
	if speed_stall > 0.0:
		ctrl_s *= lerpf(1.0, 0.18, speed_stall)
	var pitch_agi := 1.0 + boost * (DECEL_AGILITY - 1.0)
	var roll_agi := 1.0 + boost * 0.55
	var want_pitch := ctrl_pitch * 1.90 * ctrl_s * pitch_agi
	var want_roll := ctrl_roll * 2.15 * ctrl_s * roll_agi
	var want_yaw := ctrl_yaw * (0.62 + boost * 0.70) * ctrl_s
	# Aerial-drift: a hard pull + decel can slide/yaw the nose a little.
	if boost > 0.05:
		want_yaw += ctrl_roll * DECEL_YAW_COUPLE * boost * ctrl_s * 0.45
		want_yaw += ctrl_yaw * 0.38 * boost * ctrl_s
	# Weathercock / AoA stability (godot-simplified-flightsim tail: drag aft).
	var weather := 1.0 - boost * 0.55
	want_yaw += -beta * 1.15 * weather * clampf(airspeed / 50.0, 0.0, 1.0)
	want_pitch += -aoa * (0.35 + 1.4 * stall) * (1.0 - boost * 0.25)
	# Speed stall: buffet + a nose-down moment so the jet falls off the stall.
	if speed_stall > 0.05:
		want_pitch -= 0.85 * speed_stall
		var buffet := sin(Time.get_ticks_msec() * 0.041) * 0.22 * speed_stall
		want_pitch += buffet
		want_roll += cos(Time.get_ticks_msec() * 0.053) * 0.16 * speed_stall
	var w := state.angular_velocity
	var rate_roll := w.dot(fwd)
	var rate_pitch := w.dot(right)
	var rate_yaw := w.dot(up)
	# Inertia ~ (28000, 52000, 22000) for (pitch, yaw, roll). Gain tracks rates quickly.
	var pitch_t := (want_pitch - rate_pitch) * 42000.0 - rate_pitch * (8000.0 + airspeed * 120.0)
	var roll_t := (want_roll - rate_roll) * 30000.0 - rate_roll * (6000.0 + airspeed * 90.0)
	var yaw_t := (want_yaw - rate_yaw) * 48000.0 - rate_yaw * (14000.0 + airspeed * 180.0)
	var torque := right * pitch_t + fwd * roll_t + up * yaw_t
	# Aft drag lever (simplified-flightsim Drag Point) for residual weathercock.
	if airspeed > 8.0:
		var tail := -fwd * 6.5
		state.apply_force(drag_dir * drag * 0.18, tail)
	# Ground handling: ray-spring gear supports the jet so airframe hulls
	# stay above the pavement (otherwise the fuselage falls in and sticks).
	if gear > 0.35:
		_apply_gear_suspension(state, xf, fwd, up, right, vel)
	if _on_wheels:
		torque += _taxi_torque(state, fwd, up, right, vel)
		force += _taxi_force(state, fwd, vel, thrust_n)
		# Keep from pitching into the pavement at low speed, but allow
		# rotation once taxi speed is high enough and the stick is pulled.
		if airspeed < ROTATE_SPEED * 0.70:
			var sink := minf(0.0, vel.y)
			force += Vector3(0, -sink * MASS_KG * 6.0, 0)
			if ctrl_pitch < 0.0:
				torque -= right * pitch_t * 0.85
		elif ctrl_pitch > 0.2:
			# Rotation / takeoff: help the nose come up after the threshold.
			torque += right * ctrl_pitch * rotate_t * 160000.0
		else:
			if ctrl_pitch < 0.0:
				torque -= right * pitch_t * 0.5
	state.apply_central_force(force)
	state.apply_torque(torque)
	# Leave gravity to the engine (gravity_scale = 1).



func _apply_gear_suspension(state: PhysicsDirectBodyState3D, xf: Transform3D, _fwd: Vector3, up: Vector3, _right: Vector3, vel: Vector3) -> Vector3:
	var space := state.get_space_state()
	var exclude := [get_rid()]
	var hits := 0
	var agl_min := 1e9
	var wr: float = visuals.wheel_r if visuals else 0.42
	var legs: Array = _gear_setup if _gear_setup else []
	if legs.is_empty():
		for off in _gear_rays:
			legs.append({"start": off + Vector3(0.0, 1.15, 0.0), "rest": 1.25, "radius": wr})
	for g in legs:
		var start_local: Vector3 = g["start"]
		var rest: float = float(g["rest"])
		var start := xf * start_local
		var max_len := rest + 1.2
		var q := PhysicsRayQueryParameters3D.create(start, start + Vector3(0.0, -max_len, 0.0), 1, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			q = PhysicsRayQueryParameters3D.create(start, start - up * max_len, 1, exclude)
			hit = space.intersect_ray(q)
		if hit.is_empty():
			continue
		hits += 1
		var hit_p: Vector3 = hit["position"]
		var dist := start.distance_to(hit_p)
		agl_min = minf(agl_min, dist - (rest - wr))
		var compression := rest - dist
		if compression < -0.04:
			continue
		var nrm: Vector3 = hit.get("normal", Vector3.UP)
		if nrm.length_squared() < 1e-6:
			nrm = Vector3.UP
		else:
			nrm = nrm.normalized()
		var r_arm: Vector3 = hit_p - xf.origin
		var rel_v := (vel + state.angular_velocity.cross(r_arm)).dot(nrm)
		var spring := GEAR_STIFF * maxf(compression, 0.0) - GEAR_DAMP * rel_v
		spring = clampf(spring, -MASS_KG * 12.0, MASS_KG * 18.0)
		state.apply_force(nrm * spring, r_arm)
	# Weight-on-wheels is decided in _probe_ground (which also measures AGL
	# with a long downward ray). Do not overwrite a higher in-flight AGL here.
	if hits >= 1 and gear > 0.35 and agl_min < 1.2:
		_on_wheels = true
	return Vector3.ZERO


func _probe_ground(state: PhysicsDirectBodyState3D, xf: Transform3D) -> void:
	var space := state.get_space_state()
	var up := xf.basis.y
	var hits := 0
	var agl_min := 1e9
	var exclude := [get_rid()]
	for off in _gear_rays:
		var start := xf * (off + Vector3(0, 0.6, 0))
		var end := start - up * (2.4 + (0.0 if gear > 0.4 else 0.2))
		var q := PhysicsRayQueryParameters3D.create(start, end, 1, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			# Also try world-down in case the jet is banked on the ground.
			var q2 := PhysicsRayQueryParameters3D.create(start, start + Vector3(0, -3.2, 0), 1, exclude)
			hit = space.intersect_ray(q2)
		if hit.is_empty():
			continue
		hits += 1
		var d: float = start.distance_to(hit["position"])
		agl_min = minf(agl_min, d)
	_on_wheels = hits >= 1 and gear > 0.35 and agl_min < 2.1
	# Always measure AGL with a long world-down ray so auto-retract works
	# after takeoff even if a short contact ray still grazes.
	var origin := xf.origin + Vector3(0.0, 2.0, 0.0)
	var q3 := PhysicsRayQueryParameters3D.create(origin, origin + Vector3(0.0, -400.0, 0.0), 1, exclude)
	var hit3 := space.intersect_ray(q3)
	if hit3.is_empty():
		_agl = 400.0 if agl_min > 1e8 else maxf(0.0, agl_min - 0.7)
	else:
		_agl = maxf(0.0, origin.distance_to(hit3["position"]) - 2.0)
	# Airborne if not on wheels or clearly climbing with speed.
	airborne = (not _on_wheels) or (_agl > 2.4 and airspeed > ROTATE_SPEED * 0.7)


func _taxi_force(state: PhysicsDirectBodyState3D, fwd: Vector3, vel: Vector3, _thrust_n: float) -> Vector3:
	# Wheel friction: kill sideways slip, rolling resistance, wheel brakes.
	var right := state.transform.basis.x
	var lat := vel.dot(right)
	var long := vel.dot(fwd)
	var f := Vector3.ZERO
	f += -right * lat * MASS_KG * 6.5  # grip
	# Rolling resistance: modest Coulomb + light viscous, so taxi can
	# reach rotate speed under thrust (the old 0.35*m*v cap stalled the jet).
	var roll := MASS_KG * 9.81 * 0.025
	if absf(long) > 0.05:
		f += -fwd * signf(long) * roll
	f += -fwd * long * MASS_KG * 0.04
	if speed_brake > 0.02 or not occupied:
		f += -fwd * long * MASS_KG * (2.8 * maxf(speed_brake, 0.25 if not occupied else 0.0))
	# Nose-wheel steering couples a bit of lateral force already via torque.
	return f


func _taxi_torque(state: PhysicsDirectBodyState3D, fwd: Vector3, up: Vector3, right: Vector3, vel: Vector3) -> Vector3:
	var steer := steer_angle if occupied else 0.0
	if occupied and absf(ctrl_yaw) > absf(steer):
		steer = ctrl_yaw * 0.55
	var long := vel.dot(fwd)
	# Steering torque about up, speed-sensitive (less at high taxi speed).
	# Positive steer / ctrl_yaw is rudder-left. Forward (long > 0) must yaw left.
	var yaw := steer * long * MASS_KG * 0.9
	# Damp roll/pitch on the ground so the jet sits planted.
	var w := state.angular_velocity
	return up * yaw - right * w.dot(right) * 18000.0 - fwd * w.dot(fwd) * 14000.0 - up * w.dot(up) * 8000.0


func cockpit_offset() -> Vector3:
	if visuals:
		return Vector3(float(visuals.cockpit["x"]), float(visuals.cockpit["y"]), float(visuals.cockpit["z"]))
	return Vector3(0.0, 1.28, -5.15)


func exit_offset() -> Vector3:
	return global_transform.basis * Vector3(-(visuals.half_w if visuals else 2.1) - 1.4, 0.0, -1.0)


func on_enter() -> void:
	occupied = true
	door_target = 1.0
	_freeze_parked(false)
	sleeping = false
	can_sleep = false
	# Canopy closes again after boarding.
	get_tree().create_timer(0.8).timeout.connect(func():
		if occupied:
			door_target = 0.0
	)
	occupied_changed.emit(true)


func on_exit() -> void:
	occupied = false
	can_sleep = true
	door_target = 1.0
	ctrl_pitch = 0.0
	ctrl_roll = 0.0
	ctrl_yaw = 0.0
	speed_brake = 1.0
	_decel_boost = 0.0
	_decel_hold_t = 0.0
	get_tree().create_timer(0.9).timeout.connect(func():
		if not occupied:
			door_target = 0.0
			if not airborne and linear_velocity.length() < 1.2:
				_freeze_parked(true)
	)
	occupied_changed.emit(false)
