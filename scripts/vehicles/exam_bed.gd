extends StaticBody3D
## Special "vehicle": gynecological exam table. Default-spawned in the room,
## also spawnable from the 载具 menu. Entering applies a lithotomy / stirrup
## pose (upper body raised to the backrest, legs on both stirrups, legs spread).
class_name ExamBed

const KIND := "exam_bed"
const ENTER_RADIUS := 2.6
const MODEL_PATH := "res://assets/vehicles/exam_bed/exam_bed.glb"
## Raw model AABB (metres of authoring units) from the GLB.
const RAW_SIZE := Vector3(27.43, 50.476, 58.818)
const TARGET_LENGTH := 2.0  # metres along Z (head-to-foot)
## Authoring-unit markers, identified from mesh bounds:
##  - backrest / head end around Object_5 (z≈-22.8, y≈45)
##  - seat cushion Object_7 (z≈11.5, y≈22)
##  - stirrup bar Object_4 (z≈20.8, y≈32.9, x±13.7)
const RAW_SEAT := Vector3(0.0, 22.17, 11.48)
const RAW_BACK := Vector3(0.0, 38.0, -18.0)  # mid backrest surface
const RAW_STIRRUP_L := Vector3(-11.5, 32.86, 20.81)
const RAW_STIRRUP_R := Vector3(11.5, 32.86, 20.81)
const RAW_HEAD := Vector3(0.0, 45.04, -22.84)

signal occupied_changed(on: bool)

var vehicle_id: String = ""
var is_default: bool = false
var is_menu_spawned: bool = false
var occupied: bool = false
var spawn_map: String = "room"
var scale_factor: float = 1.0
var backrest_angle: float = 0.45  # rad, ~26°
var marker_seat: Marker3D
var marker_back: Marker3D
var marker_stirrup_l: Marker3D
var marker_stirrup_r: Marker3D
var wrap: Node3D
var ready_ok: bool = false
var half_l: float = 1.0
var half_w: float = 0.47
var height: float = 1.7


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	_setup_model()


func _setup_model() -> void:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		push_error("ExamBed: missing %s" % MODEL_PATH)
		return
	var root := packed.instantiate() as Node3D
	if root == null:
		return
	scale_factor = TARGET_LENGTH / RAW_SIZE.z
	root.scale = Vector3.ONE * scale_factor
	# Head at -Z, feet / stirrups at +Z, y-min on the floor, xz centered.
	wrap = Node3D.new()
	wrap.name = "ExamBedVisual"
	add_child(wrap)
	wrap.add_child(root)
	root.force_update_transform()
	# After uniform scale, shift so AABB sits on y=0 and is xz-centered in wrap.
	var box := VehicleCommon.world_aabb(root)
	var center := box.position + box.size * 0.5
	# Convert world to wrap local (wrap is at identity here).
	root.position -= Vector3(center.x, box.position.y, center.z)
	root.force_update_transform()
	_add_marker("Seat", RAW_SEAT)
	_add_marker("Backrest", RAW_BACK)
	_add_marker("StirrupL", RAW_STIRRUP_L)
	_add_marker("StirrupR", RAW_STIRRUP_R)
	marker_seat = wrap.get_node("Seat") as Marker3D
	marker_back = wrap.get_node("Backrest") as Marker3D
	marker_stirrup_l = wrap.get_node("StirrupL") as Marker3D
	marker_stirrup_r = wrap.get_node("StirrupR") as Marker3D
	# Backrest angle from seat → mid-backrest, relative to horizontal.
	var seat_p := marker_seat.position
	var back_p := marker_back.position
	var d := back_p - seat_p
	backrest_angle = atan2(d.y, maxf(absf(d.z), 0.05))
	_build_collision()
	var wa := VehicleCommon.world_aabb(wrap)
	var mn := to_local(wa.position)
	var mx := to_local(wa.position + wa.size)
	half_l = maxf(absf(mn.z), absf(mx.z))
	half_w = maxf(absf(mn.x), absf(mx.x))
	height = maxf(mx.y, 0.8)
	ready_ok = true
	# Markers live in wrap space; RAW_* is in authoring units with origin at
	# the model's original origin (center of RAW aabb is (0, 25.228, 0), y-min ≈ 0).
	# After we shift root by -center.xz and -y_min, wrap-local = (raw - (0, 0, 0))*scale
	# minus (center.x, y_min, center.z). RAW overall center xz is 0, y_min is ~0,
	# so wrap-local ≈ raw * scale_factor. The markers are added that way.


func _add_marker(name: String, raw: Vector3) -> void:
	var m := Marker3D.new()
	m.name = name
	# RAW overall min y ≈ 0, center xz ≈ 0, so after the shift above,
	# wrap-local ≈ raw * scale_factor.
	m.position = raw * scale_factor
	wrap.add_child(m)


func _build_collision() -> void:
	# Several boxes: base, seat, backrest, stirrup bar. No concave trimesh.
	var s := scale_factor
	# Base / column
	VehicleCommon.add_box_shape(self, "base", Vector3(0.0, 0.25, 0.0), Vector3(0.7, 0.5, 0.9))
	# Seat (Object_7-ish)
	var seat := RAW_SEAT * s
	VehicleCommon.add_box_shape(self, "seat", Vector3(0.0, seat.y * 0.5, seat.z), Vector3(0.72, seat.y, 0.42))
	# Backrest slab, rotated to the backrest angle, from seat toward -Z.
	var back := RAW_BACK * s
	var mid := (Vector3(0, seat.y, seat.z) + back) * 0.5
	var basis := Basis.from_euler(Vector3(-backrest_angle, 0, 0))
	VehicleCommon.add_box_shape(self, "backrest", mid, Vector3(0.7, 0.12, 0.85), basis)
	# Stirrup bar
	var st := RAW_STIRRUP_L * s
	VehicleCommon.add_box_shape(self, "stirrup_bar", Vector3(0.0, st.y, st.z), Vector3(0.95, 0.12, 0.28))
	# Foot end base
	VehicleCommon.add_box_shape(self, "foot_base", Vector3(0.0, 0.18, 0.75), Vector3(0.65, 0.36, 0.45))


func seat_global() -> Vector3:
	return marker_seat.global_position if marker_seat else global_position + Vector3(0, 0.75, 0.39)


func backrest_global() -> Vector3:
	return marker_back.global_position if marker_back else global_position + Vector3(0, 1.3, -0.6)


func stirrup_l_global() -> Vector3:
	return marker_stirrup_l.global_position if marker_stirrup_l else global_position + Vector3(-0.39, 1.12, 0.71)


func stirrup_r_global() -> Vector3:
	return marker_stirrup_r.global_position if marker_stirrup_r else global_position + Vector3(0.39, 1.12, 0.71)


func lie_basis() -> Basis:
	## Maps a standing character (head +Y, face +Z) onto the table:
	## head toward table -Z, face toward +Y (supine). That is Rx(-90°) in table space.
	return global_transform.basis * Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0))


func exit_offset() -> Vector3:
	# Stand beside the table, toward +X (right side of the bed).
	return global_transform.basis * Vector3(half_w + 0.65, 0.0, 0.1)


func on_enter() -> void:
	occupied = true
	occupied_changed.emit(true)


func on_exit() -> void:
	occupied = false
	occupied_changed.emit(false)
