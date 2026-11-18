extends Node3D
## Vehicle manager: city/room default spawns, menu spawn/clear, enter/exit,
## PC F + mobile buttons, and camera while occupying. Created by game_root.
##
## Clear rules:
##   clear_spawned()  — remove menu-spawned vehicles only (keeps runway pair + home exam bed)
##   reset_defaults() — delete default vehicles and respawn them on the current map
##   clear_all()      — remove everything except the occupied vehicle (if any)
class_name VehicleSystem

const CAR_SCENE := "res://scenes/vehicles/car.tscn"
const PLANE_SCENE := "res://scenes/vehicles/plane.tscn"
const BED_SCENE := "res://scenes/vehicles/exam_bed.tscn"
const ROOM_BED_POS := Vector3(-1.48, 0.0, -0.25)
const ROOM_BED_YAW := 0.0  # length along Z, head toward -Z / the furniture bed
const FALLBACK_RUNWAY := Vector3(-1000.0, 0.0, 300.0)
const ROAD_CAR_COUNT := 5
const LANDMARK_GROUND := "^(Boulevard_Ground|Docks_Ground|Island_Ground|AirPort_Track)"
const LANDMARK_AIRPORT := "^(AirPort_Track|Airport_Front|AirPort)$"

signal proximity_changed(vehicle: Node, occupying: bool)
signal occupancy_changed(vehicle: Node)

var player: CharacterBody3D
var game: Node
var current_map: String = "room"
var vehicles: Array[Node] = []
var occupied: Node = null
var nearest: Node = null
var _seq: int = 0
var _city_ready: bool = false
var _room_ready: bool = false
var _landmarks: Dictionary = {}  # name -> AABB (world)
var _saved_player: Dictionary = {}
var _cam_yaw: float = 0.0
var _cam_pitch: float = 0.15
var _chase_dist: float = 9.0
var _player_col_layer: int = 2
var _player_col_mask: int = 3
var touch_throttle: float = -1.0  # >=0 overrides plane throttle (0..1)
var touch_steer: Vector2 = Vector2.ZERO  # reused from move stick when occupying


func setup(g: Node, p: CharacterBody3D) -> void:
	game = g
	player = p
	name = "VehicleSystem"
	# Room exam bed is available immediately (room is the default map).
	call_deferred("_ensure_room_defaults")


func _ensure_room_defaults() -> void:
	if _room_ready:
		return
	_spawn_exam_bed(ROOM_BED_POS, ROOM_BED_YAW, true, "room")
	_room_ready = true
	_sync_visibility()


func notify_map(map_id: String) -> void:
	current_map = map_id
	if map_id == "city":
		call_deferred("_ensure_city_defaults")
	_sync_visibility()
	# Leaving a map while occupying a vehicle on that map: exit first.
	if occupied and str(occupied.get("spawn_map")) != map_id and str(occupied.get("KIND")) != "":
		# Exam bed is room-only by default; cars/planes are city. Exit if hidden.
		if not _vehicle_visible(occupied):
			try_exit()


func _vehicle_visible(v: Node) -> bool:
	if v == null:
		return false
	var sm := str(v.get("spawn_map"))
	return sm == current_map or sm == ""


func _sync_visibility() -> void:
	for v in vehicles:
		if not is_instance_valid(v):
			continue
		var on := _vehicle_visible(v)
		v.visible = on
		if v is CollisionObject3D:
			(v as CollisionObject3D).collision_layer = 1 if on else 0
			(v as CollisionObject3D).collision_mask = (1 if on else 0) if (v is RigidBody3D or v is VehicleBody3D) else 0


func _ensure_city_defaults() -> void:
	if _city_ready:
		return
	# City trimesh is built in map_collision.ensure_collisions, which game_root
	# calls when showing the city. Wait a couple of physics frames so rays work.
	if game and game.has_method("ground_at"):
		await get_tree().physics_frame
		await get_tree().physics_frame
	_collect_landmarks()
	_spawn_default_planes()
	_spawn_default_cars()
	_city_ready = true
	_sync_visibility()
	print("vehicle_system: city defaults ready  vehicles=", vehicles.size())


func _collect_landmarks() -> void:
	_landmarks.clear()
	if game == null or not game.has_node("City"):
		return
	var city: Node = game.get_node("City")
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		var n := mi as MeshInstance3D
		if n == null or n.mesh == null:
			continue
		var full := _collect_name(n)
		# Store under the node's own name (AirPort_Track etc.).
		var key := str(n.name)
		var wa := VehicleCommon.world_aabb(n)
		if wa.size.length() < 1.0:
			continue
		if not _landmarks.has(key):
			_landmarks[key] = wa
		else:
			_landmarks[key] = (_landmarks[key] as AABB).merge(wa)


func _collect_name(node: Node) -> String:
	var parts: PackedStringArray = []
	var n: Node = node
	while n:
		if not n.name.is_empty():
			parts.append(str(n.name))
		n = n.get_parent()
	return " ".join(parts)


func _landmark_re(regex: String) -> Array:
	var re := RegEx.new()
	re.compile(regex)
	var out: Array = []
	for k in _landmarks.keys():
		if re.search(str(k)) != null:
			out.append(_landmarks[k])
	return out


func _spawn_default_planes() -> void:
	var spots := _airport_plane_spawns()
	# User asked for exactly two fighters, side by side at the runway start.
	if spots.size() > 2:
		spots = spots.slice(0, 2)
	if spots.is_empty():
		var g: Variant = _ground(FALLBACK_RUNWAY.x, FALLBACK_RUNWAY.z)
		var y: float = (g as Vector3).y if g != null else 0.0
		spots = [
			{"x": FALLBACK_RUNWAY.x, "y": y, "z": FALLBACK_RUNWAY.z - 8.0, "yaw": 0.0},
			{"x": FALLBACK_RUNWAY.x, "y": y, "z": FALLBACK_RUNWAY.z + 8.0, "yaw": 0.0},
		]
	for i in spots.size():
		var s: Dictionary = spots[i]
		_spawn_plane(Vector3(s["x"], s["y"], s["z"]), float(s["yaw"]), true, "city")


func _airport_plane_spawns() -> Array:
	## Port of world-map.ts getAirportPlaneSpawns, but only the side-by-side
	## pair at the runway start (the web sim also placed a second pair).
	var tracks: Array = _landmark_re("AirPort_Track")
	if tracks.is_empty():
		tracks = _landmark_re("Airport_Front")
	if tracks.is_empty():
		tracks = _landmark_re("^AirPort$")
	if tracks.is_empty():
		return []
	var track: AABB = tracks[0]
	var terminals: Array = _landmark_re("Airport_Front")
	var term: Variant = terminals[0] if terminals.size() else null
	var box := track
	var along_x := box.size.x > box.size.z
	var tcx: float
	var tcz: float
	if term is AABB:
		var tb: AABB = term
		tcx = tb.position.x + tb.size.x * 0.5
		tcz = tb.position.z + tb.size.z * 0.5
	else:
		tcx = box.position.x + box.size.x * 0.5
		tcz = box.position.z + box.size.z * 0.5
	var out: Array = []
	var place: Callable = func(x: float, z: float, yaw: float) -> void:
		var g: Variant = _ground(x, z)
		if g == null:
			return
		out.append({"x": x, "y": (g as Vector3).y, "z": z, "yaw": yaw})
	if along_x:
		var z_mid := box.position.z + box.size.z * 0.5
		var x_min := box.position.x + 28.0
		var x_max := box.position.x + box.size.x - 28.0
		var use_max := absf(x_max - tcx) <= absf(x_min - tcx)
		var x0 := x_max if use_max else x_min
		var yaw_run := PI * 0.5 if use_max else -PI * 0.5
		var lane := minf(6.4, box.size.z * 0.18)
		place.call(x0, z_mid - lane, yaw_run)
		place.call(x0, z_mid + lane, yaw_run)
	else:
		var x_mid := box.position.x + box.size.x * 0.5
		var z_min := box.position.z + 28.0
		var z_max := box.position.z + box.size.z - 28.0
		var use_max := absf(z_max - tcz) <= absf(z_min - tcz)
		var z0 := z_max if use_max else z_min
		var yaw_run := 0.0 if use_max else PI
		var lane := minf(6.4, box.size.x * 0.18)
		place.call(x_mid - lane, z0, yaw_run)
		place.call(x_mid + lane, z0, yaw_run)
	return out


func _spawn_default_cars() -> void:
	var spawn_xz := Vector2(42.5, 40.2)
	if game and game.get("MAPS"):
		var maps: Array = game.get("MAPS")
		for m in maps:
			if str(m.get("id")) == "city" and m.get("spawns"):
				var s: Dictionary = m["spawns"][0]
				spawn_xz = Vector2(float(s["x"]), float(s["z"]))
				break
	var avoid: Array = [{"x": spawn_xz.x, "z": spawn_xz.y, "r": 8.0}]
	# Keep cars off the runway default planes too.
	for v in vehicles:
		if v is PlaneController:
			avoid.append({"x": v.global_position.x, "z": v.global_position.z, "r": 16.0})
	var pts := _sample_road_points(ROAD_CAR_COUNT, avoid)
	if pts.is_empty():
		# Fallback ring around the city spawn, outdoors only.
		var rings := [Vector2(8.4, 3.2), Vector2(10.2, -3.6), Vector2(-8.8, 4.4), Vector2(22.5, 6.2), Vector2(-20.8, 5.4)]
		for d in rings:
			if pts.size() >= ROAD_CAR_COUNT:
				break
			var x: float = spawn_xz.x + d.x
			var z: float = spawn_xz.y + d.y
			var g: Variant = _ground(x, z)
			if g == null:
				continue
			var gy: Vector3 = g
			if gy.y < 0.04 or gy.y > 2.2:
				continue
			pts.append({"x": x, "y": gy.y, "z": z, "yaw": PI})
	for p in pts:
		_spawn_car(Vector3(p["x"], p["y"], p["z"]), float(p["yaw"]), true, "city")


func _sample_road_points(count: int, avoid: Array) -> Array:
	## Port of world-map.ts sampleRoadPoints (deterministic sine sampling).
	var grounds: Array = []  # [AABB]
	var re := RegEx.new()
	re.compile(LANDMARK_GROUND)
	for k in _landmarks.keys():
		if re.search(str(k)) != null:
			grounds.append(_landmarks[k])
	var out: Array = []
	if grounds.is_empty():
		return out
	var guard := 0
	while out.size() < count and guard < count * 36:
		guard += 1
		var b: AABB = grounds[guard % grounds.size()]
		var pad := 8.0
		var x := lerpf(b.position.x + pad, b.position.x + b.size.x - pad, absf(sin(float(guard) * 12.9898 + 0.37 + float(out.size()) * 1.7)))
		var z := lerpf(b.position.z + pad, b.position.z + b.size.z - pad, absf(sin(float(guard) * 78.233 + 1.11 + float(out.size()) * 2.3)))
		var blocked := false
		for a in avoid:
			if (x - float(a["x"])) ** 2 + (z - float(a["z"])) ** 2 < float(a["r"]) * float(a["r"]):
				blocked = true
				break
		if blocked:
			continue
		for p in out:
			if (x - float(p["x"])) ** 2 + (z - float(p["z"])) ** 2 < 14.0 * 14.0:
				blocked = true
				break
		if blocked:
			continue
		var g: Variant = _ground(x, z)
		if g == null:
			continue
		var gy: Vector3 = g
		if gy.y <= 0.04 or gy.y >= 2.2:
			continue
		var along_x := b.size.x > b.size.z
		out.append({"x": x, "y": gy.y, "z": z, "yaw": (-PI * 0.5) if along_x else 0.0})
	return out


func _ground(x: float, z: float) -> Variant:
	if game and game.has_method("ground_at"):
		return game.call("ground_at", x, z, 320.0)
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 320, z), Vector3(x, -60, z), 1)
	if player:
		q.exclude = [player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else hit["position"]


func _next_id(kind: String, defaulted: bool) -> String:
	_seq += 1
	return "%s-%s-%d" % [kind, "def" if defaulted else "user", _seq]


func _register(v: Node, id: String, defaulted: bool, menu: bool, map_id: String) -> void:
	v.set("vehicle_id", id)
	v.set("is_default", defaulted)
	v.set("is_menu_spawned", menu)
	v.set("spawn_map", map_id)
	add_child(v)
	vehicles.append(v)
	_sync_visibility()


func _spawn_car(pos: Vector3, yaw: float, defaulted: bool, map_id: String, menu: bool = false) -> Node:
	var v: Node = load(CAR_SCENE).instantiate()
	_register(v, _next_id("car", defaulted), defaulted, menu, map_id)
	# Place after entering the tree so physics sees the transform.
	v.global_position = pos + Vector3(0, 0.6, 0)
	v.rotation.y = yaw
	return v


func _spawn_plane(pos: Vector3, yaw: float, defaulted: bool, map_id: String, menu: bool = false) -> Node:
	var v: Node = load(PLANE_SCENE).instantiate()
	_register(v, _next_id("plane", defaulted), defaulted, menu, map_id)
	v.global_position = pos + Vector3(0, 1.4, 0)
	v.rotation.y = yaw
	return v


func _spawn_exam_bed(pos: Vector3, yaw: float, defaulted: bool, map_id: String, menu: bool = false) -> Node:
	var v: Node = load(BED_SCENE).instantiate()
	_register(v, _next_id("exam_bed", defaulted), defaulted, menu, map_id)
	v.global_position = pos
	v.rotation.y = yaw
	return v


func kind_of(v: Node) -> String:
	if v == null:
		return ""
	if "KIND" in v:
		return str(v.KIND)
	if v.get("KIND"):
		return str(v.get("KIND"))
	if v is CarController:
		return "car"
	if v is PlaneController:
		return "plane"
	if v is ExamBed:
		return "exam_bed"
	return ""


func enter_radius(v: Node) -> float:
	var k := kind_of(v)
	if k == "plane":
		return 8.4
	if k == "exam_bed":
		return 2.6
	return 4.2


func can_toggle() -> bool:
	return occupied != null or nearest != null


func _physics_process(delta: float) -> void:
	_update_nearest()
	if occupied:
		_process_occupied(delta)


func _process(delta: float) -> void:
	# Re-apply occupancy cameras after the player script writes its own camera.
	if occupied == null or not is_instance_valid(occupied) or player == null:
		return
	if kind_of(occupied) == "exam_bed":
		_exam_camera(delta)
	else:
		_vehicle_camera(delta)


func _update_nearest() -> void:
	var prev := nearest
	nearest = null
	if occupied or player == null:
		if prev != nearest or occupied:
			proximity_changed.emit(occupied if occupied else nearest, occupied != null)
		return
	var p := player.global_position
	var best_d := 1e9
	for v in vehicles:
		if not is_instance_valid(v) or not v.visible:
			continue
		if bool(v.get("occupied")):
			continue
		var r := enter_radius(v)
		var d := p.distance_squared_to(v.global_position)
		# Flatten y a little, like the web sim.
		var dp: Vector3 = p - v.global_position
		d = dp.x * dp.x + dp.z * dp.z + dp.y * dp.y * 0.25
		if d < r * r and d < best_d:
			best_d = d
			nearest = v
	if prev != nearest:
		proximity_changed.emit(nearest, false)


func try_toggle() -> bool:
	if occupied:
		return try_exit()
	return try_enter()


func try_enter() -> bool:
	if occupied or nearest == null or player == null:
		return false
	var v := nearest
	occupied = v
	_saved_player = {
		"col_layer": player.collision_layer,
		"col_mask": player.collision_mask,
		"pos": player.global_position,
		"mode": player.get("play_mode"),
	}
	_player_col_layer = player.collision_layer
	_player_col_mask = player.collision_mask
	player.collision_layer = 0
	player.collision_mask = 0
	player.velocity = Vector3.ZERO
	player.set("occupancy", kind_of(v))
	player.set("occupier", v)
	if v.has_method("on_enter"):
		v.call("on_enter")
	var k := kind_of(v)
	if k == "exam_bed":
		# Default first-person lying on the bed.
		if player.has_method("set_play_mode") and player.get("play_mode") != 1:
			# GameMode.CONTROL = 1
			player.call("set_play_mode", 1)
		_apply_exam_pose()
	else:
		# Driving: switch to control (FP cockpit) if already in control, otherwise
		# stay in the current mode — Tab still toggles cockpit / chase.
		if player.has_method("set_play_mode") and bool(player.call("is_display_mode")):
			# Keep display as chase cam; user can Tab into the cockpit.
			pass
		_hide_player_body(k != "exam_bed")
	occupancy_changed.emit(v)
	proximity_changed.emit(v, true)
	return true


func try_exit() -> bool:
	if occupied == null or player == null:
		return false
	var v := occupied
	var k := kind_of(v)
	if v.has_method("on_exit"):
		v.call("on_exit")
	_hide_player_body(false)
	_restore_player_loco()
	var off: Vector3 = v.call("exit_offset") if v.has_method("exit_offset") else v.global_transform.basis.x * 2.0
	var dest: Vector3 = v.global_position + off
	var g: Variant = _ground(dest.x, dest.z)
	if g != null:
		dest.y = (g as Vector3).y + 0.04
	else:
		dest.y = v.global_position.y
	player.global_position = dest
	player.velocity = Vector3.ZERO
	player.collision_layer = _player_col_layer
	player.collision_mask = _player_col_mask
	player.set("occupancy", "")
	player.set("occupier", null)
	player.reset_physics_interpolation()
	occupied = null
	occupancy_changed.emit(null)
	_update_nearest()
	proximity_changed.emit(nearest, false)
	return true


func _hide_player_body(hide: bool) -> void:
	if player == null or not player.has_node("Body"):
		return
	var body: Node3D = player.get_node("Body")
	# Keep the node processed so the skeleton can still be posed for the exam bed.
	if kind_of(occupied) == "exam_bed":
		body.visible = true
		return
	body.visible = not hide


func _restore_player_loco() -> void:
	if player == null:
		return
	var loco = player.call("get_loco") if player.has_method("get_loco") else null
	if loco:
		loco.set("frozen", false)
	# Un-rotate the body mesh; standing up beside the table.
	if player.has_node("Body"):
		var body: Node3D = player.get_node("Body")
		body.rotation = Vector3(0, body.rotation.y, 0)
		body.position = Vector3.ZERO
	if player.has_method("set_facing") and occupied:
		# Face away from the vehicle.
		pass


func _process_occupied(delta: float) -> void:
	if not is_instance_valid(occupied) or player == null:
		return
	var k := kind_of(occupied)
	if k == "exam_bed":
		_apply_exam_pose()
		_exam_camera(delta)
		return
	_drive_input(delta)
	_attach_player_to_vehicle()
	_vehicle_camera(delta)


func _apply_exam_pose() -> void:
	var bed := occupied as ExamBed
	if bed == null or player == null:
		return
	var loco = player.call("get_loco") if player.has_method("get_loco") else null
	if loco:
		loco.set("frozen", true)
	# Place the character hip at the seat, body lying supine along the table.
	var seat := bed.seat_global()
	var basis := bed.lie_basis()
	# CharacterBody origin is at the feet when standing; shift so the hip (~0.95 m) lands on the seat.
	# After lie_basis, standing +Y (head) is table -Z, so "up the body" is -table.z.
	# We want the hip (about 0.95 m along +Y in standing space) at the seat.
	# In lie space, standing +Y maps to -table Z. Standing origin (feet) is 0.95 m toward +Z (feet end) from the hip.
	var hip_along := 0.95
	# feet origin in table space: seat + (mapped standing -Y) * 0? Easier: put player origin at seat, then offset Body.
	player.global_position = seat
	player.velocity = Vector3.ZERO
	player.global_transform = Transform3D(basis, seat)
	if player.has_node("Body"):
		# Body's local origin is at the feet of the mesh; move it so hip ~ seat.
		# After root rotation, we shift the mesh along local +Y (original head axis, now table -Z)
		# by -hip_along so the hip (0.95 along +Y) sits at the player origin (seat).
		var body: Node3D = player.get_node("Body")
		body.position = Vector3(0.0, -hip_along, 0.0)
		body.rotation = Vector3.ZERO
		body.visible = true
	var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
	if skel:
		ExamPose.apply(skel, bed.stirrup_l_global(), bed.stirrup_r_global(), bed.backrest_angle)


func _exam_camera(_delta: float) -> void:
	if player == null or not bool(player.get("first_person")):
		# Observe / orbit uses the normal third-person camera, pose stays applied.
		return
	var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
	if skel == null or not player.has_node("CameraPivot/Camera3D"):
		return
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var pivot: Node3D = player.get_node("CameraPivot")
	var head := ExamPose.head_world(skel)
	# Default look: from the head toward the feet / abdomen (table +Z, slightly down).
	var yaw := float(player.get("_yaw"))
	var pitch := float(player.get("_pitch"))
	# Remap: standing FP yaw/pitch onto a lying reference looking along +Z of the table,
	# with pitch 0 looking along the body, negative pitch looking toward the belly / legs.
	var bed := occupied as ExamBed
	var look := bed.global_transform.basis
	# Start from a view aimed at the torso (down the body, a little toward the belly).
	var base := look * Basis.from_euler(Vector3(-0.55, 0.0, 0.0))
	var extra := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var xf := Transform3D(base * extra, head.origin + head.basis.y * 0.08)
	# Place pivot + camera so the existing pipeline doesn't fight us next frame:
	# write camera global directly (occupancy hook also runs after player camera).
	cam.global_transform = xf
	cam.fov = float(player.get("fp_fov"))
	cam.near = 0.04
	cam.current = true


func _attach_player_to_vehicle() -> void:
	if occupied == null:
		return
	player.global_position = occupied.global_position
	player.velocity = Vector3.ZERO
	player.global_transform = occupied.global_transform


func _drive_input(delta: float) -> void:
	if player == null:
		return
	# Don't drive while a HUD panel is up.
	if bool(player.get("ui_blocks_capture")) or bool(player.get("input_locked")):
		return
	var k := kind_of(occupied)
	var throttle := Input.get_axis("move_back", "move_forward")
	var steer := Input.get_axis("move_left", "move_right")
	# Mobile stick (player.touch_move is Vector2, +y back? get_vector uses down=+y in Godot
	# but player maps touch_move like input_dir). Reuse touch_move if present.
	if player.get("touch_move") != null:
		var tm: Vector2 = player.touch_move
		if tm.length_squared() > 1e-4:
			steer = tm.x
			throttle = -tm.y if absf(tm.y) > absf(throttle) else throttle
			# Player touch_move uses the same convention as Input.get_vector (y + = back).
			# move_forward is -y in get_vector, so throttle = -touch_move.y? 
			# Input.get_vector("left","right","forward","back"): forward is -y.
			# touch_move is assigned as input_dir equivalent, so y>0 is back, y<0 is forward.
			# throttle forward should be + when moving forward, so throttle = -tm.y.
			throttle = -tm.y
	if k == "car" and occupied is CarController:
		var brake := 1.0 if Input.is_key_pressed(KEY_SPACE) or throttle < -0.05 and (occupied as CarController).linear_velocity.length() > 1.0 and throttle < 0.0 else 0.0
		if throttle < 0.0 and (occupied as CarController).linear_velocity.dot(-(occupied as CarController).global_transform.basis.z) > 1.0:
			# Forward motion + back input = brake, not reverse, until almost stopped.
			brake = maxf(brake, -throttle)
			# Keep a little reverse only when nearly still (handled in controller via throttle).
		var hb := Input.is_key_pressed(KEY_SPACE)
		var nt := Input.is_key_pressed(KEY_SHIFT)
		(occupied as CarController).set_driver_input(throttle, steer, brake, hb, nt)
	elif k == "plane" and occupied is PlaneController:
		var pl := occupied as PlaneController
		var pitch := -throttle  # W / stick forward = nose down (stick convention)
		var roll := steer
		var yaw := 0.0
		if Input.is_key_pressed(KEY_Q):
			yaw -= 1.0
		if Input.is_key_pressed(KEY_E):
			yaw += 1.0
		# Mouse look, when captured, also contributes (Ace Combat-ish).
		# Throttle: Shift up, Ctrl down; or explicit slider from touch.
		var td := 0.0
		if Input.is_key_pressed(KEY_SHIFT):
			td += delta * 0.45
		if Input.is_key_pressed(KEY_CTRL):
			td -= delta * 0.45
		if touch_throttle >= 0.0:
			pl.set_throttle(touch_throttle)
			td = 0.0
		var br := 1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0
		# On the ground, W/S is throttle and A/D is nose-wheel steer.
		if not pl.airborne:
			pl.set_pilot_input(0.0, 0.0, yaw, throttle * delta * 0.5 + td, br, steer)
		else:
			pl.set_pilot_input(pitch, roll, yaw, td, br, steer)


func _vehicle_camera(_delta: float) -> void:
	if player == null or not player.has_node("CameraPivot/Camera3D"):
		return
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var k := kind_of(occupied)
	var fp := bool(player.get("first_person"))
	if fp:
		var eye_off: Vector3 = occupied.call("cockpit_offset") if occupied.has_method("cockpit_offset") else Vector3(0, 1.2, 0)
		var eye: Vector3 = occupied.global_transform * eye_off
		var yaw := float(player.get("_yaw"))
		var pitch := float(player.get("_pitch"))
		var rel_yaw := wrapf(yaw - occupied.rotation.y, -PI, PI)
		var look: Basis = occupied.global_transform.basis * Basis.from_euler(Vector3(pitch, rel_yaw, 0.0))
		cam.global_transform = Transform3D(look, eye)
		cam.fov = float(player.get("fp_fov"))
		cam.near = 0.08
		cam.current = true
	else:
		# Chase camera behind the vehicle.
		var dist := 8.5 if k == "car" else 16.0
		var height := 2.4 if k == "car" else 4.6
		var cam_pos: Vector3 = occupied.global_position + occupied.global_transform.basis.z * dist + Vector3(0, height, 0)
		var look_pt: Vector3 = occupied.global_position + Vector3(0, 1.2 if k == "car" else 1.8, 0)
		cam.global_transform = Transform3D(Basis.looking_at(look_pt - cam_pos, Vector3.UP), cam_pos)
		cam.fov = 55.0 if k == "car" else 62.0
		cam.near = 0.15
		cam.current = true


# ------------------------------------------------------------------ menu

func spawn_at_aim(kind: String) -> Node:
	var pos := aim_point(kind)
	var yaw := 0.0
	if player:
		yaw = float(player.get("_yaw") if player.get("_yaw") != null else 0.0)
	var map_id := current_map
	match kind:
		"car":
			return _spawn_car(pos, yaw, false, map_id, true)
		"plane":
			return _spawn_plane(pos, yaw, false, map_id, true)
		"exam_bed":
			return _spawn_exam_bed(pos, yaw, false, map_id, true)
		_:
			return null


func aim_point(kind: String) -> Vector3:
	var dist := 18.0 if kind == "plane" else (4.0 if kind == "exam_bed" else 7.4)
	var from := player.global_position + Vector3(0, 1.4, 0) if player else Vector3.ZERO
	var dir := Vector3(0, 0, -1)
	if player and player.has_method("get_camera"):
		var cam: Camera3D = player.call("get_camera")
		if cam:
			from = cam.global_position
			var vp := cam.get_viewport().get_visible_rect().size
			var screen := vp * 0.5
			# PC: use mouse if it is on the viewport.
			var mouse := cam.get_viewport().get_mouse_position()
			if mouse.x >= 0.0 and mouse.y >= 0.0 and mouse.x <= vp.x and mouse.y <= vp.y:
				screen = mouse
			dir = cam.project_ray_normal(screen)
	var to := from + dir * 220.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var excl: Array[RID] = []
	if player:
		excl.append(player.get_rid())
	if occupied and occupied is CollisionObject3D:
		excl.append((occupied as CollisionObject3D).get_rid())
	q.exclude = excl
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var p: Vector3
	if hit.is_empty():
		p = from + dir * dist
		var g: Variant = _ground(p.x, p.z)
		if g != null:
			p = g as Vector3
	else:
		p = hit["position"]
	# Keep menu-spawned vehicles from stacking on top of each other.
	var min_d := 22.0 if kind == "plane" else 9.0
	for _i in 8:
		var clash := false
		for v in vehicles:
			if not is_instance_valid(v) or not v.visible:
				continue
			if Vector2(v.global_position.x - p.x, v.global_position.z - p.z).length() < min_d:
				clash = true
				break
		if not clash:
			break
		p += dir.slide(Vector3.UP).normalized() * (8.0 if kind == "plane" else 4.0)
	var g2: Variant = _ground(p.x, p.z)
	if g2 != null:
		p = g2 as Vector3
	return p


func clear_spawned() -> int:
	## Menu-spawned only. Default runway planes and the home exam bed stay.
	return _free_matching(func(v: Node) -> bool:
		return bool(v.get("is_menu_spawned")) and v != occupied
	)


func reset_defaults() -> void:
	_free_matching(func(v: Node) -> bool:
		return bool(v.get("is_default")) and v != occupied
	)
	_city_ready = false
	_room_ready = false
	if current_map == "room" or true:
		_ensure_room_defaults()
	if current_map == "city":
		_ensure_city_defaults()


func clear_all() -> int:
	return _free_matching(func(v: Node) -> bool:
		return v != occupied
	)


func _free_matching(pred: Callable) -> int:
	var n := 0
	var keep: Array[Node] = []
	for v in vehicles:
		if not is_instance_valid(v):
			continue
		if pred.call(v):
			v.queue_free()
			n += 1
		else:
			keep.append(v)
	vehicles = keep
	return n


func default_plane_count() -> int:
	var n := 0
	for v in vehicles:
		if is_instance_valid(v) and kind_of(v) == "plane" and bool(v.get("is_default")):
			n += 1
	return n


func default_car_count() -> int:
	var n := 0
	for v in vehicles:
		if is_instance_valid(v) and kind_of(v) == "car" and bool(v.get("is_default")):
			n += 1
	return n


func default_bed_count() -> int:
	var n := 0
	for v in vehicles:
		if is_instance_valid(v) and kind_of(v) == "exam_bed" and bool(v.get("is_default")):
			n += 1
	return n
