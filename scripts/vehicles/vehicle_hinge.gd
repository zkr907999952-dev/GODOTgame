extends RefCounted
## Pivot / hinge bind, ported from the web prototype vehicles.tsx
## (mountHinge, mountCantedHinge, applyPivot).
## t in [-1, 1] is applied as rest * Euler(sign * max * clamp(t)).
class_name VehicleHinge

var obj: Node3D
var rest: Quaternion = Quaternion.IDENTITY
var axis: String = "x"  # "x" | "y" | "z"
var sign: float = 1.0
var max_angle: float = 0.4
var kind: String = ""


static func mount(
	wrap: Node3D,
	target: Node3D,
	hinge: Vector3,
	axis: String,
	sign: float,
	max_angle: float,
	kind: String,
	extras: Array = [],
	parent: Node3D = null,
) -> VehicleHinge:
	if parent == null:
		parent = wrap
	var hub := Node3D.new()
	hub.name = "Hinge_%s_%s" % [kind, target.name]
	parent.add_child(hub)
	var hp := hinge
	if parent != wrap:
		hp = parent.to_local(wrap.to_global(hinge))
	hub.position = hp
	hub.quaternion = Quaternion.IDENTITY
	hub.scale = Vector3.ONE
	VehicleCommon.reparent_keep_global(target, hub)
	for ex in extras:
		if ex == null or ex == target or not (ex is Node3D):
			continue
		VehicleCommon.reparent_keep_global(ex as Node3D, hub)
	var b := VehicleHinge.new()
	b.obj = hub
	b.rest = hub.quaternion
	b.axis = axis
	b.sign = sign
	b.max_angle = max_angle
	b.kind = kind
	return b


static func mount_canted(
	wrap: Node3D,
	target: Node3D,
	hinge: Vector3,
	tip: Vector3,
	sign: float,
	max_angle: float,
	kind: String,
) -> VehicleHinge:
	var hub := Node3D.new()
	hub.name = "Hinge_%s_%s" % [kind, target.name]
	wrap.add_child(hub)
	hub.position = hinge
	var d := tip - hinge
	if d.length_squared() < 1e-6:
		d = Vector3.UP
	else:
		d = d.normalized()
	hub.quaternion = Quaternion(Vector3.UP, d)
	VehicleCommon.reparent_keep_global(target, hub)
	var b := VehicleHinge.new()
	b.obj = hub
	b.rest = hub.quaternion
	b.axis = "y"
	b.sign = sign
	b.max_angle = max_angle
	b.kind = kind
	return b


func apply(t: float) -> void:
	if obj == null:
		return
	# Axis-angle in the hub's local frame. Uses +X/+Y/+Z (same as Three.js XYZ
	# single-axis pivots). Godot from_euler is YXZ and is easy to get wrong
	# on canted hubs when more than one component is involved.
	var a := sign * max_angle * clampf(t, -1.0, 1.0)
	var ax := Vector3(1.0, 0.0, 0.0)
	if axis == "y":
		ax = Vector3(0.0, 1.0, 0.0)
	elif axis == "z":
		ax = Vector3(0.0, 0.0, 1.0)
	obj.quaternion = rest * Quaternion(ax, a)
