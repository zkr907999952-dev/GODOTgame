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
		if n.get_parent() and str(n.get_parent().name).begins_with("WheelHub"):
			continue
		var world_pos := n.global_position
		# Hub is identity in car space. The roll axle is always local X
		# (left-right), measured in wrap space — never a world AABB, which
		# tilts when the car is spawned already yawed.
		var hub := Node3D.new()
		hub.name = "WheelHub_%s" % n.name
		wrap.add_child(hub)
		hub.global_position = world_pos
		hub.quaternion = Quaternion.IDENTITY
		VehicleCommon.reparent_keep_global(n, hub)
		var off := hub.position
		out.append({
			"root": hub, "rest_pos": off, "rest_quat": hub.quaternion,
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
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var hub: Node3D = w["root"]
		var sag := 0.0
		if i < susp.size():
			sag = (float(susp[i]) - 0.4) * 0.2
		hub.position = w["rest_pos"] + Vector3(0.0, sag, 0.0)
		hub.quaternion = w["rest_quat"]
		if w["steer"]:
			hub.rotate_y(steer_angle)
		# Roll about the hub's local X (car right). wheel_spin is already
		# signed so forward motion turns the contact patch backward.
		hub.rotate_x(wheel_spin * float(w.get("spin_sign", 1.0)))
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


func wheel_layout() -> Array:
	var out: Array = []
	for w in wheels:
		var off: Vector3 = w["offset"]
		out.append({"x": off.x, "y": off.y, "z": off.z, "steer": w["steer"]})
	return out
