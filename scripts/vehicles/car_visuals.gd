extends Node3D
## Sports-car visual rig. Wheels and steering wheel follow the raycast-car
## controller state. Facing/scale match the web prototype (target length 4.82 m).
class_name CarVisuals

const MODEL_PATH := "res://assets/vehicles/car.glb"
const TARGET_LEN := 4.82
const ORIGIN_Y := 0.48

var wrap: Node3D
var wheels: Array = []
var steer_wheel: Dictionary = {}
var cockpit: Dictionary = {"x": -0.38, "y": 0.42, "z": 0.22}
var half_l: float = 2.38
var half_w: float = 1.08
var height: float = 1.18
var wheel_r: float = 0.34
var ready_ok: bool = false
var _nitro_fx: Array = []  # MeshInstance3D flames at the exhausts
var doors: Array = []  # VehicleHinge scissor doors (open upward about A-pillar)


func setup() -> bool:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		push_error("CarVisuals: missing %s" % MODEL_PATH)
		return false
	var root := packed.instantiate() as Node3D
	if root == null:
		return false
	wrap = Node3D.new()
	wrap.name = "CarVisual"
	add_child(wrap)
	wrap.add_child(root)
	VehicleCommon.normalize_facing(
		root, TARGET_LEN,
		"Exhaust_1$|Tail_light$|Rear_part_1$",
		"Hood|Front_part_1$|Daylight$|Headlight$")
	wrap.force_update_transform()
	wheels = _mount_wheels("^Wheel_F|^Wheel_B")
	if wheels.is_empty():
		wheels = _mount_wheels("Wheel_")
	cockpit = _measure_cockpit()
	VehicleCommon.lift_origin(wrap, ORIGIN_Y)
	wrap.force_update_transform()
	for w in wheels:
		var hub: Node3D = w["root"]
		w["offset"] = hub.position
		w["rest_pos"] = hub.position
		w["rest_quat"] = hub.quaternion
		w["steer"] = hub.position.z < 0.0
	var steer := VehicleCommon.first_named(wrap, "^Steering_wheel$")
	if steer == null:
		steer = VehicleCommon.first_named(wrap, "Steering_wheel")
	if steer is Node3D:
		steer_wheel = {
			"obj": steer,
			"rest": (steer as Node3D).quaternion,
			"axis": VehicleCommon.local_thin_axis(steer as Node3D),
		}
	VehicleCommon.make_glass(wrap, "glass|Glass|window|Window", 0.18)
	_make_scissor_doors()
	_attach_nitro_flames()
	var box := VehicleCommon.world_aabb(wrap)
	var mn := wrap.to_local(box.position)
	var mx := wrap.to_local(box.position + box.size)
	half_l = maxf(absf(mn.z), absf(mx.z))
	half_w = maxf(absf(mn.x), absf(mx.x))
	height = maxf(mx.y, 0.6) - minf(mn.y, 0.0)
	if wheels.size():
		var a := VehicleCommon.world_aabb(wheels[0]["root"])
		wheel_r = maxf(a.size.y, a.size.x) * 0.5
		if wheel_r < 0.2:
			wheel_r = 0.34
	ready_ok = true
	return true


func _mount_wheels(regex: String) -> Array:
	var out: Array = []
	# Prefer the parent Wheel_FL / Wheel_FR groups, not every Tire/Rim child.
	var seen := {}
	for obj in VehicleCommon.find_named(wrap, regex):
		if not (obj is Node3D):
			continue
		var n := obj as Node3D
		# Skip mesh children (Wheel_FR_Tire_0 etc.) — bind the Wheel_FR group.
		if n.name.contains("_Tire") or n.name.contains("_Rim") or n.name.contains("_Caliper") \
				or n.name.contains("_Brake") or n.name.contains("_Logo"):
			continue
		if seen.has(n.get_instance_id()):
			continue
		seen[n.get_instance_id()] = true
		if n.get_parent() and (str(n.get_parent().name).begins_with("WheelHub") \
				or str(n.get_parent().name).begins_with("WheelSteer") \
				or str(n.get_parent().name).begins_with("WheelSpin")):
			continue
		var world_pos := n.global_position
		# Chassis → steer hinge (yaw about body-up / kingpin, fixed to the
		# body) → spin hub (roll about the axle). Spin must not carry the
		# steer axis with it, or a turned wheel looks like it is tumbling.
		var steer := Node3D.new()
		steer.name = "WheelSteer_%s" % n.name
		wrap.add_child(steer)
		steer.global_position = world_pos
		steer.quaternion = Quaternion.IDENTITY
		var spin := Node3D.new()
		spin.name = "WheelSpin_%s" % n.name
		steer.add_child(spin)
		spin.position = Vector3.ZERO
		spin.quaternion = Quaternion.IDENTITY
		VehicleCommon.reparent_keep_global(n, spin)
		var off := steer.position
		out.append({
			"root": steer, "spin": spin, "rest_pos": off, "rest_quat": steer.quaternion,
			"steer": off.z < 0.0, "axle": "x", "spin_sign": 1.0, "offset": off,
		})
	out.sort_custom(func(a, b):
		return a["offset"].z < b["offset"].z or (is_equal_approx(a["offset"].z, b["offset"].z) and a["offset"].x < b["offset"].x)
	)
	return out


func _measure_cockpit() -> Dictionary:
	var x := -0.34
	var y := 1.08
	var z := 0.08
	var wheel := VehicleCommon.first_named(wrap, "^Steering_wheel$")
	var wheel_p: Variant = null
	if wheel is Node3D:
		var a := VehicleCommon.aabb_in(wrap, wheel as Node3D)
		wheel_p = Vector3(a["cx"], a["cy"], a["cz"])
		x = a["cx"]
		y = a["cy"] + 0.12
		z = a["cz"] + 0.2
	var seat := VehicleCommon.first_named(wrap, "^Seat$")
	if seat is Node3D:
		var a := VehicleCommon.aabb_in(wrap, seat as Node3D)
		y = minf(y, a["cy"] + 0.28)
		if wheel_p != null:
			z = lerpf((wheel_p as Vector3).z + 0.18, a["cz"], 0.38)
		else:
			z = a["cz"] + 0.06
	return {"x": x, "y": clampf(y - ORIGIN_Y, 0.5, 0.7), "z": z}


func apply_pose(st: Dictionary, _delta: float, _time: float) -> void:
	if not ready_ok:
		return
	var steer_angle := float(st.get("steer_angle", 0.0))
	var wheel_spin := float(st.get("wheel_spin", 0.0))
	var susp: Array = st.get("susp", [])
	var travels: Array = st.get("wheel_travel", [])
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var hinge: Node3D = w["root"]
		var spin: Node3D = w["spin"] if w.has("spin") else hinge
		# Visual travel follows the ray spring so the tire stays on the
		# pavement when the chassis sits higher on the longer rest length.
		var y_off := 0.0
		if i < travels.size():
			y_off = float(travels[i])
		elif i < susp.size():
			y_off = (float(susp[i]) - 0.4) * 0.2
		hinge.position = w["rest_pos"] + Vector3(0.0, y_off, 0.0)
		# Kingpin is body-up, applied only on the steer parent.
		hinge.quaternion = w["rest_quat"]
		if w["steer"]:
			hinge.rotate_object_local(Vector3.UP, steer_angle)
		# Roll lives on the child, about the (already steered) axle.
		if spin != hinge:
			spin.quaternion = Quaternion(Vector3.RIGHT, wheel_spin * float(w.get("spin_sign", 1.0)))
		else:
			spin.rotate_object_local(Vector3.RIGHT, wheel_spin * float(w.get("spin_sign", 1.0)))
	if not steer_wheel.is_empty():
		var sw: Node3D = steer_wheel["obj"]
		var axis := str(steer_wheel.get("axis", "z"))
		var e := Vector3.ZERO
		var ang := -steer_angle * 2.6
		match axis:
			"x":
				e.x = ang
			"y":
				e.y = ang
			_:
				e.z = ang
		sw.quaternion = steer_wheel["rest"] * Quaternion.from_euler(e)
	_apply_nitro(bool(st.get("nitro", false)), _time)
	var door_t := float(st.get("door", 0.0))
	for d in doors:
		(d as VehicleHinge).apply(door_t)


func wheel_rig_info() -> Array:
	## Test helper: steer parent vs spin child, and their world axes.
	var out: Array = []
	for w in wheels:
		var hinge: Node3D = w["root"]
		var spin: Node3D = w["spin"] if w.has("spin") else hinge
		out.append({
			"steer": hinge,
			"spin": spin,
			"parent_ok": spin.get_parent() == hinge,
			"kingpin": hinge.global_transform.basis.y.normalized(),
			"axle": spin.global_transform.basis.x.normalized(),
			"is_steer": bool(w["steer"]),
		})
	return out


func wheel_layout() -> Array:
	var out: Array = []
	for w in wheels:
		var off: Vector3 = w["offset"]
		out.append({"x": off.x, "y": off.y, "z": off.z, "steer": w["steer"]})
	return out


func _attach_nitro_flames() -> void:
	_nitro_fx.clear()
	var hubs: Array = VehicleCommon.find_named(wrap, "Exhaust")
	if hubs.is_empty():
		hubs = VehicleCommon.find_named(wrap, "exhaust")
	for h in hubs:
		if not (h is Node3D):
			continue
		_nitro_fx.append(_make_flame(h as Node3D))
	if _nitro_fx.is_empty() and wrap:
		# Fallback: two tips at the rear corners of the body.
		for x in [-0.45, 0.45]:
			var hub := Node3D.new()
			hub.name = "NitroHub"
			wrap.add_child(hub)
			hub.position = Vector3(x, 0.28, half_l * 0.92)
			_nitro_fx.append(_make_flame(hub))


func _make_flame(hub: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "NitroFlame"
	mi.mesh = VehicleCommon.make_teardrop_mesh(0.07)
	mi.rotation.x = PI * 0.5
	mi.position = Vector3(0.0, 0.02, 0.18)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_color = Color(0.25, 0.55, 1.0, 0.0)
	sm.emission_enabled = true
	sm.emission = Color(0.2, 0.55, 1.0)
	sm.emission_energy_multiplier = 2.4
	mi.material_override = sm
	mi.visible = false
	hub.add_child(mi)
	return mi


func _apply_nitro(on: bool, time: float) -> void:
	var flicker := 1.0 + sin(time * 28.0) * 0.08
	for mi in _nitro_fx:
		if mi == null:
			continue
		mi.visible = on
		if not on:
			continue
		mi.scale = Vector3(0.85 * flicker, 1.35 * flicker, 0.85 * flicker)
		var sm := mi.material_override as StandardMaterial3D
		if sm:
			sm.albedo_color = Color(0.3, 0.65, 1.0, 0.55 * flicker)
			sm.emission_energy_multiplier = 2.2 * flicker


func _make_scissor_doors() -> void:
	## Port of rouchangmoniqi3 makeScissorDoors: split Interior_doors / side
	## windows / mirrors / the door-skin region of the hood, and hang each
	## half on a pivot near the A-pillar / front of the roof. The doors
	## rotate upward about local +Z (aft), not a conventional side swing.
	doors.clear()
	if wrap == null:
		return
	wrap.force_update_transform()
	var interior := VehicleCommon.first_named(wrap, "^Interior_doors$")
	var extras: Array = []
	for re in ["^Right&Left_windows$", "^Right&Left_window_2$", "^Mirrors$"]:
		var o := VehicleCommon.first_named(wrap, re)
		if o:
			extras.append(o)
	var hood := VehicleCommon.first_named(wrap, "Hood075_Body_0$")
	if hood == null:
		hood = VehicleCommon.first_named(wrap, "^Hood\\.075_Body_0$")
	if hood == null:
		hood = VehicleCommon.first_named(wrap, "Hood.*Body_0")
	# Door volume in wrap space (fallback matches the web prototype).
	var x_abs := 0.52
	var min_y := 0.14
	var max_y := 0.92
	var min_z := -1.02
	var max_z := 0.42
	if interior:
		var a := VehicleCommon.aabb_in(wrap, interior as Node3D)
		if not bool(a.get("empty", false)):
			x_abs = maxf(0.48, minf(absf(float(a["minX"])), absf(float(a["maxX"]))) * 0.58)
			min_y = float(a["minY"]) - 0.05
			max_y = float(a["maxY"]) + 0.14
			min_z = float(a["minZ"]) - 0.06
			max_z = float(a["maxZ"]) + 0.10
	var in_door := func(c: Vector3) -> bool:
		return absf(c.x) >= x_abs and c.y >= min_y and c.y <= max_y and c.z >= min_z and c.z <= max_z
	var sources: Array = []
	if interior:
		sources.append(interior)
	sources.append_array(extras)
	for side: String in ["L", "R"]:
		var left: bool = side == "L"
		var pred := func(c: Vector3) -> bool:
			return bool(in_door.call(c)) and (c.x < 0.0 if left else c.x >= 0.0)
		var made: Array[MeshInstance3D] = []
		for src in sources:
			if src == null:
				continue
			for mi in VehicleCommon.mesh_instances(src):
				var half := VehicleCommon.split_mesh_by_pred(mi, wrap, pred)
				if half == null:
					continue
				half.name = "%s_%s" % [mi.name, side]
				wrap.add_child(half)
				half.global_transform = mi.global_transform
				made.append(half)
		if hood:
			for mi in VehicleCommon.mesh_instances(hood):
				var half := VehicleCommon.split_mesh_by_pred(mi, wrap, pred)
				if half == null:
					continue
				half.name = "%s_%s" % [mi.name, side]
				wrap.add_child(half)
				half.global_transform = mi.global_transform
				made.append(half)
		if made.is_empty():
			continue
		var mn := Vector3(1e9, 1e9, 1e9)
		var mx := Vector3(-1e9, -1e9, -1e9)
		for half in made:
			var box := VehicleCommon.aabb_in(wrap, half)
			if bool(box.get("empty", false)):
				continue
			mn.x = minf(mn.x, float(box["minX"]))
			mn.y = minf(mn.y, float(box["minY"]))
			mn.z = minf(mn.z, float(box["minZ"]))
			mx.x = maxf(mx.x, float(box["maxX"]))
			mx.y = maxf(mx.y, float(box["maxY"]))
			mx.z = maxf(mx.z, float(box["maxZ"]))
		var outer_x := mn.x if left else mx.x
		var hx := outer_x * 0.72
		var hy := mx.y - 0.02
		var hz := mn.z + 0.08
		var sign := -1.0 if left else 1.0
		# Pivot first half as the hinge target; the rest ride as extras.
		var target: Node3D = made[0]
		var extras_n: Array = []
		for i in range(1, made.size()):
			extras_n.append(made[i])
		doors.append(VehicleHinge.mount(wrap, target, Vector3(hx, hy, hz), "z", sign, 1.35, "scissor", extras_n))
	if doors.size():
		for src in sources:
			if src is Node3D:
				(src as Node3D).visible = false
		if hood:
			for mi in VehicleCommon.mesh_instances(hood):
				VehicleCommon.punch_mesh_by_pred(mi, wrap, in_door)
