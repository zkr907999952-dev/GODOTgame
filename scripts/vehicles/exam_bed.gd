extends StaticBody3D
## Gynecological exam table. Default-spawned in the room, also spawnable
## from the 载具 menu. Entering applies a lithotomy / stirrup pose:
## hips on the seat, torso along the raised backrest, head toward the
## headrest, left/right legs on the matching stirrups (not crossed).
class_name ExamBed

const KIND := "exam_bed"
const ENTER_RADIUS := 2.6
const MODEL_PATH := "res://assets/vehicles/exam_bed/exam_bed.glb"
const RAW_SIZE := Vector3(27.43, 50.476, 58.818)
const TARGET_LENGTH := 1.86

signal occupied_changed(on: bool)

var vehicle_id: String = ""
var is_default: bool = false
var is_menu_spawned: bool = false
var occupied: bool = false
var spawn_map: String = "room"
var scale_factor: float = 1.0
var backrest_angle: float = 0.45
var marker_seat: Marker3D
var marker_back: Marker3D
var marker_head: Marker3D
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
	wrap = Node3D.new()
	wrap.name = "ExamBedVisual"
	add_child(wrap)
	wrap.add_child(root)
	root.force_update_transform()
	var box := VehicleCommon.world_aabb(root)
	var center := box.position + box.size * 0.5
	root.position -= Vector3(center.x, box.position.y, center.z)
	root.force_update_transform()
	_identify_markers()
	_build_collision()
	var wa := VehicleCommon.world_aabb(wrap)
	var mn := to_local(wa.position)
	var mx := to_local(wa.position + wa.size)
	half_l = maxf(absf(mn.z), absf(mx.z))
	half_w = maxf(absf(mn.x), absf(mx.x))
	height = maxf(maxf(mn.y, mx.y), 0.8)
	ready_ok = true


func _identify_markers() -> void:
	## Classify generic Object_* meshes from wrap-local AABBs.
	var seat_c := Vector3(0.0, 0.836, 0.35)
	var head_c := Vector3(0.0, 1.53, -0.78)
	var bar_l := Vector3(0.35, 1.185, 0.71)
	var bar_r := Vector3(-0.35, 1.185, 0.71)
	var found_seat := false
	var found_head := false
	var found_bar := false
	for mi in VehicleCommon.mesh_instances(wrap):
		var a := VehicleCommon.aabb_in(wrap, mi)
		if a.get("empty", false):
			continue
		var s: Vector3 = a["max"] - a["min"]
		var c := Vector3(a["cx"], a["cy"], a["cz"])
		# Compact mid cushion = seat (hips).
		if s.x < 0.65 and s.y < 0.28 and s.z < 0.32 and c.y > 0.55 and c.y < 1.05 and c.z > 0.15 and c.z < 0.6:
			seat_c = Vector3(c.x, a["maxY"], c.z)
			found_seat = true
		# High, compact, at the head end (-Z) = headrest.
		if s.x > 0.4 and s.y < 0.28 and s.z < 0.25 and c.y > 1.35 and c.z < -0.55:
			head_c = Vector3(c.x, a["maxY"], a["minZ"] * 0.35 + a["maxZ"] * 0.65)
			found_head = true
		# Wide, elevated bar at the foot end = stirrup bar.
		if s.x > 0.75 and s.y < 0.25 and c.y > 0.95 and c.y < 1.35 and c.z > 0.4:
			var y_top: float = a["maxY"]
			var z_mid: float = c.z
			# Patient's left is +X when lying head toward -Z, face up.
			bar_l = Vector3(a["maxX"] - 0.08, y_top, z_mid)
			bar_r = Vector3(a["minX"] + 0.08, y_top, z_mid)
			found_bar = true
	if not found_seat:
		seat_c = Vector3(0.0, 0.836, 0.35)
	if not found_head:
		head_c = Vector3(0.0, 1.622, -0.777)
	if not found_bar:
		bar_l = Vector3(0.39, 1.185, 0.707)
		bar_r = Vector3(-0.39, 1.185, 0.707)
	var back_c := (seat_c + head_c) * 0.5
	_add_marker("Seat", seat_c)
	_add_marker("Backrest", back_c)
	_add_marker("Headrest", head_c)
	_add_marker("StirrupL", bar_l)
	_add_marker("StirrupR", bar_r)
	marker_seat = wrap.get_node("Seat") as Marker3D
	marker_back = wrap.get_node("Backrest") as Marker3D
	marker_head = wrap.get_node("Headrest") as Marker3D
	marker_stirrup_l = wrap.get_node("StirrupL") as Marker3D
	marker_stirrup_r = wrap.get_node("StirrupR") as Marker3D
	var d: Vector3 = head_c - seat_c
	backrest_angle = atan2(d.y, maxf(absf(d.z), 0.05))


func _add_marker(nm: String, local: Vector3) -> void:
	var m := Marker3D.new()
	m.name = nm
	m.position = local
	wrap.add_child(m)


func _build_collision() -> void:
	# Accurate static collision: convex hulls of compact parts, plus solid
	# support boxes so the character is held on the seat / backrest.
	# No concave trimesh (keeps tests and Jolt behaviour simple).
	var added := VehicleCommon.add_convexes_from_visual(self, wrap, "", 0.04, 2.4)
	var seat := seat_local()
	VehicleCommon.add_box_shape(self, "seat_support", Vector3(0.0, seat.y * 0.5, seat.z), Vector3(0.55, maxf(seat.y, 0.12), 0.32))
	var head := head_local()
	var mid := (Vector3(0.0, seat.y, seat.z) + head) * 0.5
	var basis := Basis.from_euler(Vector3(-backrest_angle, 0.0, 0.0))
	var back_len := Vector3(0.0, seat.y, seat.z).distance_to(head)
	VehicleCommon.add_box_shape(self, "backrest_support", mid, Vector3(0.72, 0.10, maxf(back_len, 0.6)), basis)
	VehicleCommon.add_box_shape(self, "headrest_support", Vector3(0.0, head.y, head.z), Vector3(0.7, 0.12, 0.18))
	var st := stirrup_l_local()
	VehicleCommon.add_box_shape(self, "stirrup_bar", Vector3(0.0, st.y, st.z), Vector3(0.95, 0.10, 0.28))
	VehicleCommon.add_box_shape(self, "base", Vector3(0.0, 0.22, 0.15), Vector3(0.55, 0.44, 0.8))
	if added < 1:
		push_warning("ExamBed: no convex hulls from meshes, using support boxes only")


func seat_local() -> Vector3:
	return marker_seat.position if marker_seat else Vector3(0.0, 0.836, 0.35)


func head_local() -> Vector3:
	return marker_head.position if marker_head else Vector3(0.0, 1.622, -0.777)


func stirrup_l_local() -> Vector3:
	return marker_stirrup_l.position if marker_stirrup_l else Vector3(0.39, 1.185, 0.71)


func stirrup_r_local() -> Vector3:
	return marker_stirrup_r.position if marker_stirrup_r else Vector3(-0.39, 1.185, 0.71)


func seat_global() -> Vector3:
	return marker_seat.global_position if marker_seat else global_position + Vector3(0, 0.836, 0.35)


func backrest_global() -> Vector3:
	return marker_back.global_position if marker_back else global_position + Vector3(0, 1.23, -0.21)


func headrest_global() -> Vector3:
	return marker_head.global_position if marker_head else global_position + Vector3(0, 1.622, -0.777)


func stirrup_l_global() -> Vector3:
	## Patient's left stirrup (bed +X when head is at -Z).
	return marker_stirrup_l.global_position if marker_stirrup_l else global_position + Vector3(0.39, 1.185, 0.71)


func stirrup_r_global() -> Vector3:
	## Patient's right stirrup (bed -X).
	return marker_stirrup_r.global_position if marker_stirrup_r else global_position + Vector3(-0.39, 1.185, 0.71)


func patient_basis() -> Basis:
	## Maps a standing Body (head +Y, face +Z, left +X in mesh space) onto the
	## table: head toward the headrest, face out of the backrest (up), left
	## toward bed +X. CharacterBody stays upright; only the Body mesh uses this.
	var seat := seat_global()
	var head := headrest_global()
	var spine := head - seat
	if spine.length_squared() < 1e-6:
		spine = -global_transform.basis.z + global_transform.basis.y * 0.4
	spine = spine.normalized()
	var bed_right := global_transform.basis.x.normalized()
	var face := bed_right.cross(spine)
	if face.length_squared() < 1e-6:
		face = Vector3.UP
	else:
		face = face.normalized()
	if face.dot(Vector3.UP) < 0.0:
		face = -face
	var left := spine.cross(face)
	if left.length_squared() < 1e-6:
		left = bed_right
	else:
		left = left.normalized()
	# Patient left must point toward bed +X.
	if left.dot(bed_right) < 0.0:
		left = -left
	face = left.cross(spine)
	if face.length_squared() < 1e-6:
		face = Vector3.UP
	else:
		face = face.normalized()
	return Basis(left, spine, face).orthonormalized()


func exit_offset() -> Vector3:
	return global_transform.basis * Vector3(half_w + 0.65, 0.0, 0.1)


func on_enter() -> void:
	occupied = true
	occupied_changed.emit(true)


func on_exit() -> void:
	occupied = false
	occupied_changed.emit(false)
