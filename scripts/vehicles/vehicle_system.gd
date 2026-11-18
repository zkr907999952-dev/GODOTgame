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
const ROOM_BED_POS := Vector3(-1.32, 0.0, 0.05)
const ROOM_BED_YAW := 0.0  # length along Z, head toward -Z; clear of the furniture bed and wall
# Last-resort fallback if AirPort_Track cannot be measured this frame.
# These numbers were measured from the city AirPort_Track asphalt at the
# white-threshold / building end (not the helipad pad). Prefer live mesh
# measurement in _measure_runway() over this constant.
const FALLBACK_RUNWAY := Vector3(-814.49, 0.0, 504.38)
const FALLBACK_RUNWAY_YAW := 0.70456  # nose toward the helipad end
const FALLBACK_RUNWAY_AXIS := Vector3(0.64770, 0.0, 0.76189)  # t+ toward threshold
const RUNWAY_LANE := 7.2
const RUNWAY_STANDOFF := 26.0  # metres inward from the asphalt threshold
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
var _chase_dist: float = 9.0
var _player_col_layer: int = 2
var _player_col_mask: int = 3
var vehicle_cam: String = "third"  # "first" | "third" — default third on car/plane
var touch_throttle: float = -1.0  # >=0 overrides plane throttle (0..1)
var touch_steer: Vector2 = Vector2.ZERO
var touch_car_accel: bool = false
var touch_car_brake: bool = false
var touch_yaw: float = 0.0  # -1 left, +1 right (mobile yaw buttons)
var touch_thrust_up: bool = false
var touch_thrust_down: bool = false
var _ctrl_was_down: bool = false
var _g_was_down: bool = false
# Third-person chase cam (Battlefield / Ace Combat / old web project):
# the vehicle is the orbit pivot. Offsets are *relative to the vehicle heading*
# so the default and the recenter pose are always behind the nose, never a
# leftover world or player yaw. Hold LMB / swipe to orbit; release recenters.
var _orbit_held: bool = false
var _touch_orbit: bool = false
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = -0.18
var _cam_ready: bool = false
var _chase_dir: Vector3 = Vector3.ZERO  # smoothed motion/heading for the chase cam
const CAM_PITCH_DEFAULT := -0.18
const CAM_PITCH_AIR := -0.12


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
	# Leaving a map while occupying a vehicle on that map: detach, but do
	# not stand beside the (now hidden) vehicle — the map switch places
	# the player at the destination.
	if occupied and not _vehicle_visible(occupied):
		release_occupancy()


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
		var across := Vector3(-FALLBACK_RUNWAY_AXIS.z, 0.0, FALLBACK_RUNWAY_AXIS.x)
		spots = [
			{"x": FALLBACK_RUNWAY.x - across.x * RUNWAY_LANE, "y": y, "z": FALLBACK_RUNWAY.z - across.z * RUNWAY_LANE, "yaw": FALLBACK_RUNWAY_YAW},
			{"x": FALLBACK_RUNWAY.x + across.x * RUNWAY_LANE, "y": y, "z": FALLBACK_RUNWAY.z + across.z * RUNWAY_LANE, "yaw": FALLBACK_RUNWAY_YAW},
		]
	for i in spots.size():
		var s: Dictionary = spots[i]
		_spawn_plane(Vector3(s["x"], s["y"], s["z"]), float(s["yaw"]), true, "city")


func _airport_plane_spawns() -> Array:
	## Two fighters side by side on the pavement just inside the white
	## threshold bars (the building / blue-roof end), noses pointing down
	## the long runway toward the helipad pad. The MAPS label
	## 「机场跑道（空旷）」 at x=-1000, z=300 is the helipad end and is wrong.
	## Position and heading come from a live AirPort_Track mesh measurement.
	var info := _measure_runway()
	var mid: Vector3 = info["mid"]
	var yaw: float = float(info["yaw"])
	var across: Vector3 = info["across"]
	var lane: float = float(info["lane"])
	var out: Array = []
	for side in [-1.0, 1.0]:
		var x: float = mid.x + across.x * lane * side
		var z: float = mid.z + across.z * lane * side
		var g: Variant = _ground(x, z)
		var y: float = (g as Vector3).y if g != null else mid.y
		out.append({"x": x, "y": y, "z": z, "yaw": yaw})
	return out


func runway_threshold_info() -> Dictionary:
	## Public for tests / HUD: measured threshold-end spawn and takeoff heading.
	return _measure_runway()


func _runway_heading_at(_start: Vector3) -> Dictionary:
	## Kept for callers; heading is the takeoff direction (toward the helipads),
	## measured from AirPort_Track — not from an AABB, which is square on this
	## ~50° diagonal strip.
	var info := _measure_runway()
	return {"yaw": info["yaw"], "lane": info["lane"], "along_x": false, "heading": info["heading"], "mid": info["mid"]}


func _measure_runway() -> Dictionary:
	## PCA-fit the AirPort_Track asphalt, pick the end closer to the AirPort
	## buildings as the threshold, stand off onto the pavement, nose toward
	## the opposite (helipad) end.
	var empty := {
		"mid": FALLBACK_RUNWAY,
		"yaw": FALLBACK_RUNWAY_YAW,
		"heading": Vector3(-FALLBACK_RUNWAY_AXIS.x, 0.0, -FALLBACK_RUNWAY_AXIS.z),
		"across": Vector3(-FALLBACK_RUNWAY_AXIS.z, 0.0, FALLBACK_RUNWAY_AXIS.x),
		"lane": RUNWAY_LANE,
		"threshold": FALLBACK_RUNWAY,
		"helipad": Vector3(-1100.95, 0.0, 167.41),
	}
	if game == null or not game.has_node("City"):
		return empty
	var city: Node = game.get_node("City")
	var track: MeshInstance3D = null
	for mi in city.find_children("AirPort_Track_MAT_Airport_0", "MeshInstance3D", true, false):
		track = mi as MeshInstance3D
		break
	if track == null or track.mesh == null:
		for mi in city.find_children("*", "MeshInstance3D", true, false):
			if "AirPort_Track" in str(mi.name) and mi.mesh:
				track = mi as MeshInstance3D
				break
	if track == null or track.mesh == null:
		return empty
	var pts: Array[Vector3] = []
	var grass_ok := false
	var img: Image = null
	var mat := track.get_active_material(0)
	if mat == null:
		mat = track.mesh.surface_get_material(0)
	if mat is BaseMaterial3D:
		var tex: Texture2D = (mat as BaseMaterial3D).albedo_texture
		if tex:
			img = tex.get_image()
			if img and img.is_compressed():
				img.decompress()
			grass_ok = img != null
	var xf := track.global_transform
	var tw := 0
	var th := 0
	if img:
		tw = img.get_width()
		th = img.get_height()
	for s in track.mesh.get_surface_count():
		var arr := track.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		for i in verts.size():
			var w: Vector3 = xf * verts[i]
			if w.y < -1.0:
				continue
			if grass_ok and i < uvs.size():
				var uv: Vector2 = uvs[i]
				var px := clampi(int(uv.x * tw), 0, tw - 1)
				var py := clampi(int(uv.y * th), 0, th - 1)
				var col := img.get_pixel(px, py)
				# Olive / green shoulder (atlas tile), not yellow markings.
				var is_yellow := col.r > 0.7 and col.g > 0.45 and col.b < 0.4 and col.r > col.g + 0.05
				var is_grass := (not is_yellow) and col.g >= col.r - 0.03 and col.g > col.b + 0.08 and col.r < 0.71
				if is_grass:
					continue
			pts.append(w)
	if pts.size() < 32:
		return empty
	var mx := 0.0
	var mz := 0.0
	for p in pts:
		mx += p.x
		mz += p.z
	mx /= float(pts.size())
	mz /= float(pts.size())
	var cxx := 0.0
	var czz := 0.0
	var cxz := 0.0
	for p in pts:
		var dx := p.x - mx
		var dz := p.z - mz
		cxx += dx * dx
		czz += dz * dz
		cxz += dx * dz
	var tr := cxx + czz
	var det := cxx * czz - cxz * cxz
	var disc := sqrt(maxf(0.0, tr * tr * 0.25 - det))
	var l1 := tr * 0.5 + disc
	var ex := l1 - czz
	var ez := cxz
	if absf(ex) + absf(ez) < 1e-8:
		ex = cxz
		ez = l1 - cxx
	var elen := sqrt(ex * ex + ez * ez)
	if elen < 1e-6:
		return empty
	ex /= elen
	ez /= elen
	# Project.
	var tmin := INF
	var tmax := -INF
	var samples: Array = []  # {t, s}
	for p in pts:
		var tt := (p.x - mx) * ex + (p.z - mz) * ez
		var ss := -(p.x - mx) * ez + (p.z - mz) * ex
		tmin = minf(tmin, tt)
		tmax = maxf(tmax, tt)
		samples.append(Vector2(tt, ss))
	# Typical-width bins give the main strip centre (ignore helipad pad / apron).
	var bins := 40
	var span := tmax - tmin
	if span < 20.0:
		return empty
	var typ_s: Array[float] = []
	var typ_w: Array[float] = []
	for bi in bins:
		var a := tmin + span * float(bi) / float(bins)
		var b := tmin + span * float(bi + 1) / float(bins)
		var slist: Array[float] = []
		for sm in samples:
			if sm.x >= a and sm.x < b:
				slist.append(sm.y)
		if slist.size() < 4:
			continue
		slist.sort()
		var w := slist[slist.size() - 1] - slist[0]
		# Main strip is the narrower cluster (~80–110 m including shoulders).
		# Helipad / terminal aprons are wider (~135–155 m).
		if w > 30.0 and w < 120.0:
			typ_s.append(slist[slist.size() / 2])
			typ_w.append(w)
	var center_s := 0.0
	var width := 90.0
	if typ_s.size():
		var mid_i := typ_s.size() / 2
		var scopy: Array[float] = typ_s.duplicate()
		scopy.sort()
		center_s = scopy[mid_i]
		var wcopy: Array[float] = typ_w.duplicate()
		wcopy.sort()
		width = wcopy[wcopy.size() / 2]
	# Asphalt along the centreline.
	var half := maxf(width * 0.35, 12.0)
	var tmin_c := INF
	var tmax_c := -INF
	for sm in samples:
		if absf(sm.y - center_s) < half:
			tmin_c = minf(tmin_c, sm.x)
			tmax_c = maxf(tmax_c, sm.x)
	if tmin_c > tmax_c:
		tmin_c = tmin
		tmax_c = tmax
	var sx := -ez
	var sz := ex
	var end_pos := Vector3(mx + ex * tmax_c + sx * center_s, 0.0, mz + ez * tmax_c + sz * center_s)
	var end_neg := Vector3(mx + ex * tmin_c + sx * center_s, 0.0, mz + ez * tmin_c + sz * center_s)
	# Threshold = the end closer to the grey airport buildings.
	var bld_c := Vector3(-831.86, 0.0, 362.89)
	for mi in city.find_children("AirPort_MAT_Airport_0", "MeshInstance3D", true, false):
		var bld := mi as MeshInstance3D
		if bld and bld.mesh:
			bld_c = bld.global_transform * bld.mesh.get_aabb().get_center()
			bld_c.y = 0.0
		break
	var d_pos := Vector2(end_pos.x - bld_c.x, end_pos.z - bld_c.z).length()
	var d_neg := Vector2(end_neg.x - bld_c.x, end_neg.z - bld_c.z).length()
	var thr_t: float
	var hel_t: float
	var threshold: Vector3
	var helipad: Vector3
	if d_pos <= d_neg:
		thr_t = tmax_c
		hel_t = tmin_c
		threshold = end_pos
		helipad = end_neg
	else:
		thr_t = tmin_c
		hel_t = tmax_c
		threshold = end_neg
		helipad = end_pos
	# Park just inside the threshold bars, not past them off the pavement.
	var sign_in := 1.0 if hel_t > thr_t else -1.0
	var mid_t := thr_t + sign_in * RUNWAY_STANDOFF
	var mid := Vector3(mx + ex * mid_t + sx * center_s, 0.0, mz + ez * mid_t + sz * center_s)
	# Takeoff heading: toward the helipad end.
	var heading := Vector3(helipad.x - threshold.x, 0.0, helipad.z - threshold.z)
	if heading.length_squared() < 1e-6:
		heading = Vector3(-ex, 0.0, -ez) if d_pos <= d_neg else Vector3(ex, 0.0, ez)
	else:
		heading = heading.normalized()
	# yaw such that visual nose (-basis.z) = heading: (-sin y, 0, -cos y) = heading
	var yaw := atan2(-heading.x, -heading.z)
	var across := Vector3(-heading.z, 0.0, heading.x)
	return {
		"mid": mid,
		"yaw": yaw,
		"heading": heading,
		"across": across,
		"lane": RUNWAY_LANE,
		"threshold": threshold,
		"helipad": helipad,
	}


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


func _ground(x: float, z: float, top: float = 320.0) -> Variant:
	if game and game.has_method("ground_at"):
		return game.call("ground_at", x, z, top)
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -60, z), 1)
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
	var lift := float(v.call("spawn_lift")) if v.has_method("spawn_lift") else 0.5
	v.global_position = pos + Vector3(0, lift, 0)
	v.rotation = Vector3(0.0, yaw, 0.0)
	if v is VehicleBody3D:
		(v as VehicleBody3D).linear_velocity = Vector3.ZERO
		(v as VehicleBody3D).angular_velocity = Vector3.ZERO
	if v.has_method("reset_physics_interpolation"):
		v.reset_physics_interpolation()
	return v


func _spawn_plane(pos: Vector3, yaw: float, defaulted: bool, map_id: String, menu: bool = false) -> Node:
	var v: Node = load(PLANE_SCENE).instantiate()
	_register(v, _next_id("plane", defaulted), defaulted, menu, map_id)
	var lift := float(v.call("spawn_lift")) if v.has_method("spawn_lift") else 1.32
	v.global_position = pos + Vector3(0, lift, 0)
	v.rotation = Vector3(0.0, yaw, 0.0)
	if v is RigidBody3D:
		(v as RigidBody3D).linear_velocity = Vector3.ZERO
		(v as RigidBody3D).angular_velocity = Vector3.ZERO
	if v.has_method("reset_physics_interpolation"):
		v.reset_physics_interpolation()
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


func _holster_occupied_weapons() -> void:
	## Boarding any vehicle (car / plane / exam bed) forces empty hands.
	## Occupied Q is not the weapon wheel; occupied G is landing gear.
	if player == null or not player.has_method("get_weapons"):
		return
	var ws: Node = player.call("get_weapons")
	if ws and ws.has_method("holster"):
		ws.call("holster")


func try_toggle() -> bool:
	if occupied:
		return try_exit()
	return try_enter()


func try_enter() -> bool:
	if occupied or nearest == null or player == null:
		return false
	var v := nearest
	occupied = v
	var body: Node3D = player.get_node_or_null("Body")
	_saved_player = {
		"col_layer": player.collision_layer,
		"col_mask": player.collision_mask,
		"pos": player.global_position,
		"xform": player.global_transform,
		"mode": player.get("play_mode"),
		"yaw": float(player.get("_yaw")),
		"pitch": float(player.get("_pitch")),
		"body_logic_yaw": float(player.get("_body_logic_yaw")),
		"body_pos": body.position if body else Vector3.ZERO,
		"body_rot": body.rotation if body else Vector3.ZERO,
	}
	_player_col_layer = player.collision_layer
	_player_col_mask = player.collision_mask
	player.collision_layer = 0
	player.collision_mask = 0
	player.velocity = Vector3.ZERO
	# Never tilt the CharacterBody3D — yaw lives on Body / the camera.
	player.global_transform = Transform3D(Basis.IDENTITY, player.global_position)
	player.set("occupancy", kind_of(v))
	player.set("occupier", v)
	_holster_occupied_weapons()
	if v.has_method("on_enter"):
		v.call("on_enter")
	var k := kind_of(v)
	if k == "exam_bed":
		# Keep the current play mode. Observation must keep the pose.
		_apply_exam_pose()
	else:
		# Cars / planes default to third person; the player can toggle 1st/3rd.
		vehicle_cam = "third"
		_reset_vehicle_cam()
		_hide_player_body(true)
	occupancy_changed.emit(v)
	proximity_changed.emit(v, true)
	return true


func try_exit() -> bool:
	if occupied == null or player == null:
		return false
	var v := occupied
	var dest := _exit_stand_dest(v)
	return _finish_exit(dest, true)


func release_occupancy() -> void:
	## Detach from a vehicle / exam bed without walking to the exit offset.
	## Used when a map switch is about to place the player somewhere else.
	if occupied == null or player == null:
		return
	_finish_exit(player.global_position, false)


func _finish_exit(dest: Vector3, restore_collision: bool) -> bool:
	var v := occupied
	if v and v.has_method("on_exit"):
		v.call("on_exit")
	_hide_player_body(false)
	_restore_standing(dest)
	if restore_collision:
		player.collision_layer = int(_saved_player.get("col_layer", _player_col_layer))
		player.collision_mask = int(_saved_player.get("col_mask", _player_col_mask))
	else:
		# Caller (map teleport / switch) will re-enable after placing.
		player.collision_layer = 0
		player.collision_mask = 0
	player.set("occupancy", "")
	player.set("occupier", null)
	player.reset_physics_interpolation()
	occupied = null
	occupancy_changed.emit(null)
	_update_nearest()
	proximity_changed.emit(nearest, false)
	return true


func _exit_stand_dest(v: Node) -> Vector3:
	## Stand beside the vehicle on the real floor (not the ceiling) and,
	## when leaving the home exam bed, stay inside the room.
	var off: Vector3 = v.call("exit_offset") if v.has_method("exit_offset") else v.global_transform.basis.x * 2.0
	var dest: Vector3 = v.global_position + off
	var in_room := str(game.get("current_map") if game else current_map) == "room" 		or str(v.get("spawn_map")) == "room"
	if in_room and kind_of(v) == "exam_bed":
		dest = _safe_room_stand(v, dest)
	# Cast from just above standing height — a sky-high ray hits the
	# room roof first (its top face is a valid floor).
	var top: float = dest.y + 1.85
	var g: Variant = _ground(dest.x, dest.z, top)
	if g != null:
		dest.y = (g as Vector3).y + 0.04
	else:
		dest.y = v.global_position.y
	# If a ceiling was somehow still chosen, fall back to the room spawn.
	if in_room and dest.y > 1.6:
		dest = _room_spawn_floor()
	return dest


func _room_stand_bounds() -> AABB:
	## Inset of the room walls, with a standing-height ceiling so a roof
	## snap cannot count as "inside".
	return AABB(Vector3(-1.58, 0.0, -2.90), Vector3(4.70, 1.70, 3.45))


func _room_spawn_floor() -> Vector3:
	var spawn := Vector3(-0.2, 0.0, 0.3)
	if game and game.get("ROOM_SPAWN") != null:
		spawn = game.get("ROOM_SPAWN")
	var g: Variant = _ground(spawn.x, spawn.z, 1.85)
	if g != null:
		spawn.y = (g as Vector3).y + 0.04
	return spawn


func _safe_room_stand(v: Node, dest: Vector3) -> Vector3:
	var bounds := _room_stand_bounds()
	var candidates: Array[Vector3] = [dest]
	if v.has_method("exit_offset"):
		# Opposite side of the table, in case the default side is blocked.
		var off: Vector3 = v.call("exit_offset")
		candidates.append(v.global_position - Vector3(off.x, 0.0, 0.0))
	candidates.append(_room_spawn_floor())
	for c in candidates:
		var p := Vector3(c.x, 0.2, c.z)
		if bounds.has_point(p):
			return c
	return _room_spawn_floor()


func _hide_player_body(hide: bool) -> void:
	if player == null or not player.has_node("Body"):
		return
	var body: Node3D = player.get_node("Body")
	if kind_of(occupied) == "exam_bed":
		body.visible = true
		return
	body.visible = not hide


func _restore_standing(dest: Vector3) -> void:
	## Detach pose overrides and put the CharacterBody back upright, original yaw.
	if player == null:
		return
	var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
	if skel:
		ExamPose.clear(skel)
	var loco = player.call("get_loco") if player.has_method("get_loco") else null
	if loco:
		loco.set("frozen", false)
		if loco.has_method("apply_pose"):
			loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)
	# CharacterBody is always world-upright; facing lives on Body + look yaw.
	player.global_transform = Transform3D(Basis.IDENTITY, dest)
	player.velocity = Vector3.ZERO
	var yaw := float(_saved_player.get("body_logic_yaw", _saved_player.get("yaw", 0.0)))
	if player.has_method("set_facing"):
		player.call("set_facing", yaw)
	else:
		player.set("_yaw", yaw)
		player.set("_body_logic_yaw", yaw)
		if player.has_node("Body"):
			var body: Node3D = player.get_node("Body")
			body.position = Vector3.ZERO
			body.rotation = Vector3(0.0, yaw + PI, 0.0)
	if player.has_node("Body"):
		var body2: Node3D = player.get_node("Body")
		body2.position = Vector3.ZERO
		body2.visible = true
		# set_facing already wrote rotation.y; clear any residual pitch/roll.
		body2.rotation = Vector3(0.0, body2.rotation.y, 0.0)
	if "pitch" in _saved_player:
		player.set("_pitch", float(_saved_player["pitch"]))


func toggle_vehicle_cam() -> String:
	vehicle_cam = "first" if vehicle_cam != "first" else "third"
	if vehicle_cam == "third":
		_reset_vehicle_cam()
	return vehicle_cam


func is_drive_third() -> bool:
	var k := kind_of(occupied)
	return occupied != null and (k == "car" or k == "plane") and vehicle_cam == "third"


func begin_orbit() -> void:
	_orbit_held = true
	_touch_orbit = true


func end_orbit() -> void:
	_orbit_held = false
	_touch_orbit = false


func orbit_look(rel: Vector2, sens: float = 0.004) -> void:
	if not is_drive_third():
		return
	_orbit_held = true
	_orbit_yaw -= rel.x * sens
	_orbit_pitch = clampf(_orbit_pitch - rel.y * sens, -1.25, 0.55)


func _reset_vehicle_cam() -> void:
	_cam_ready = false
	_orbit_held = false
	_touch_orbit = false
	_orbit_yaw = 0.0
	_orbit_pitch = CAM_PITCH_DEFAULT
	_chase_dir = Vector3.ZERO


func toggle_occupied_gear() -> void:
	if occupied == null or kind_of(occupied) != "plane":
		return
	if occupied.has_method("toggle_gear"):
		occupied.call("toggle_gear")


func _vehicle_visual_xf(v: Node = null) -> Transform3D:
	## Use the interpolated pose in _process so the chase cam stays planted
	## on the rendered mesh (avoids a smear / ghost when the body steps).
	var n: Node3D = (v if v else occupied) as Node3D
	if n == null:
		return Transform3D.IDENTITY
	if is_inside_tree() and get_tree().physics_interpolation and not Engine.is_in_physics_frame():
		return n.get_global_transform_interpolated()
	return n.global_transform


func _vehicle_forward(xf: Transform3D) -> Vector3:
	return -xf.basis.z  # visual nose (Godot -Z)


func _heading_yaw(fwd: Vector3, fallback: float = 0.0) -> float:
	## Yaw such that (-sin yaw, 0, -cos yaw) is the horizontal nose direction.
	var h := Vector3(fwd.x, 0.0, fwd.z)
	if h.length_squared() < 1e-8:
		return fallback
	h = h.normalized()
	return atan2(-h.x, -h.z)


func chase_heading_error() -> float:
	## Radians between the camera look (flat) and the vehicle heading. Tests use this.
	if occupied == null or not player or not player.has_node("CameraPivot/Camera3D"):
		return 99.0
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var xf := _vehicle_visual_xf()
	var nose_h := Vector3(-xf.basis.z.x, 0.0, -xf.basis.z.z)
	if nose_h.length_squared() < 1e-8:
		return 99.0
	nose_h = nose_h.normalized()
	var look := -cam.global_transform.basis.z
	var look_h := Vector3(look.x, 0.0, look.z)
	if look_h.length_squared() < 1e-8:
		return 99.0
	look_h = look_h.normalized()
	return absf(acos(clampf(look_h.dot(nose_h), -1.0, 1.0)))


func _process_occupied(delta: float) -> void:
	if not is_instance_valid(occupied) or player == null:
		return
	var k := kind_of(occupied)
	# Stay empty-handed for the whole occupancy (boarding with a weapon,
	# or any later attempt to draw, holsters again).
	_holster_occupied_weapons()
	if k == "exam_bed":
		_apply_exam_pose(delta)
		_exam_camera(delta)
		return
	_drive_input(delta)
	_attach_player_to_vehicle()
	_vehicle_camera(delta)


func _apply_exam_pose(delta: float = 0.016) -> void:
	var bed := occupied as ExamBed
	if bed == null or player == null or not player.has_node("Body"):
		return
	var loco = player.call("get_loco") if player.has_method("get_loco") else null
	if loco:
		loco.set("frozen", true)
	var body: Node3D = player.get_node("Body")
	var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
	# Keep CharacterBody upright at the seat xz so exit can restore a standing pose
	# without residual pitch/roll. Only the Body mesh is laid on the table.
	var seat := bed.seat_global()
	player.velocity = Vector3.ZERO
	player.global_transform = Transform3D(Basis.IDENTITY, Vector3(seat.x, 0.0, seat.z))
	body.visible = true
	if skel:
		ExamPose.clear(skel)
	var hip_local := ExamPose.hip_local(skel, body) if skel else Vector3(0.0, 0.917, 0.033)
	var lie := bed.patient_basis()
	# Sit-bones slightly behind the hip; lift the body a little so it sits
	# on (not in) the cushion and the backrest.
	const BUTTOCK := Vector3(0.0, -0.02, -0.10)
	const SEAT_SKIN := 0.055
	var sit := hip_local + BUTTOCK
	body.global_transform = Transform3D(lie, seat - lie * sit + lie.z * SEAT_SKIN)
	if skel:
		var al: Vector3 = bed.armrest_l_global() if bed.has_method("armrest_l_global") else bed.stirrup_l_global()
		var ar: Vector3 = bed.armrest_r_global() if bed.has_method("armrest_r_global") else bed.stirrup_r_global()
		ExamPose.apply(skel, bed.stirrup_l_global(), bed.stirrup_r_global(), bed.backrest_angle, al, ar)
		ExamPose.offset_hair(skel, Vector3(0.0, 0.015, -0.08))
		# Observation mode: head / eyes look at the orbit camera.
		if player.has_method("is_display_mode") and bool(player.call("is_display_mode")) and player.has_method("get_secondary"):
			var sec = player.call("get_secondary")
			if sec and player.has_node("CameraPivot/Camera3D"):
				var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
				if sec.has_method("set_gaze_target"):
					sec.call("set_gaze_target", cam.global_position)
				if sec.has_method("update"):
					sec.call("update", delta, false)
				ExamPose.offset_hair(skel, Vector3(0.0, 0.015, -0.08))
				if sec.has_method("snap_hair_to_pose"):
					sec.call("snap_hair_to_pose")
		elif player.has_method("get_secondary"):
			var sec2 = player.call("get_secondary")
			if sec2 and sec2.has_method("clear_gaze"):
				sec2.call("clear_gaze")
			if sec2 and sec2.has_method("snap_hair_to_pose"):
				sec2.call("snap_hair_to_pose")


func _exam_camera(_delta: float) -> void:
	if player == null:
		return
	# Observation / display mode keeps the pose and uses the normal orbit camera.
	if player.has_method("is_display_mode") and bool(player.call("is_display_mode")):
		return
	if not bool(player.get("first_person")):
		return
	var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
	if skel == null or not player.has_node("CameraPivot/Camera3D"):
		return
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var head := ExamPose.head_world(skel)
	var bed := occupied as ExamBed
	if bed == null:
		return
	var lie := bed.patient_basis()
	# Default: from the head, look toward the feet / abdomen, slightly at the body.
	var look_dir := -lie.y * 0.92 - lie.z * 0.25
	if look_dir.length_squared() < 1e-6:
		look_dir = bed.global_transform.basis.z
	look_dir = look_dir.normalized()
	var yaw := float(player.get("_yaw"))
	var pitch := float(player.get("_pitch"))
	# Untilted origin: world-up so the first-person camera has no roll
	# from the lying basis. The CharacterBody stays identity.
	var up_ref := Vector3.UP
	if absf(look_dir.dot(up_ref)) > 0.94:
		up_ref = lie.x if absf(lie.x.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var base := Basis.looking_at(look_dir, up_ref)
	var extra := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var eye := head.origin + Vector3.UP * 0.04 + lie.z * 0.06
	var look := (base * extra).orthonormalized()
	# Strip residual roll: rebuild with world up.
	var fwd2 := -look.z
	var up2 := Vector3.UP
	if absf(fwd2.dot(up2)) > 0.94:
		up2 = look.y
	cam.global_transform = Transform3D(Basis.looking_at(fwd2, up2), eye)
	cam.fov = float(player.get("fp_fov"))
	cam.near = 0.04
	cam.current = true


func _attach_player_to_vehicle() -> void:
	if occupied == null or player == null:
		return
	# Follow the vehicle origin but NEVER copy its pitch/roll onto the CharacterBody.
	player.global_transform = Transform3D(Basis.IDENTITY, occupied.global_position)
	player.velocity = Vector3.ZERO


func _drive_input(delta: float) -> void:
	if player == null:
		return
	if bool(player.get("ui_blocks_capture")) or bool(player.get("input_locked")):
		return
	var k := kind_of(occupied)
	# PC stick: W/S = get_axis(back, forward) → W = +1. A/D = get_axis(left, right) → A = -1, D = +1.
	var axis_fb := Input.get_axis("move_back", "move_forward")
	var axis_lr := Input.get_axis("move_left", "move_right")
	if player.get("touch_move") != null:
		var tm: Vector2 = player.touch_move
		if tm.length_squared() > 1e-4:
			# touch_move: +x right, +y back (same as Input.get_vector).
			axis_lr = tm.x
			axis_fb = -tm.y
	if k == "car" and occupied is CarController:
		var throttle := axis_fb
		if touch_car_accel:
			throttle = maxf(throttle, 1.0)
		# A = steer left (positive Godot steering), D = right.
		var steer := -axis_lr
		var hb := Input.is_key_pressed(KEY_SPACE) or touch_car_brake
		var nt := Input.is_key_pressed(KEY_SHIFT)
		var brake := 1.0 if hb else 0.0
		var car := occupied as CarController
		var fwd_speed := car.linear_velocity.dot(-car.global_transform.basis.z)
		if throttle < -0.05 and fwd_speed > 1.0:
			brake = maxf(brake, -throttle)
		car.set_driver_input(throttle, steer, brake, hb, nt)
	elif k == "plane" and occupied is PlaneController:
		var pl := occupied as PlaneController
		# S = pull up (axis_fb < 0 → pitch +); W = dive (axis_fb > 0 → pitch -).
		var pitch := -axis_fb
		# A = roll left (axis_lr < 0); D = roll right.
		var roll := axis_lr
		# Q / left yaw button = rudder left (positive ctrl_yaw, +Y torque).
		# touch_yaw is stored as -1 left / +1 right; invert so left is +.
		var yaw := -touch_yaw
		if Input.is_key_pressed(KEY_Q):
			yaw += 1.0
		if Input.is_key_pressed(KEY_E):
			yaw -= 1.0
		yaw = clampf(yaw, -1.0, 1.0)
		var td := 0.0
		var decelerating := false
		var holding_ab := Input.is_key_pressed(KEY_SHIFT) or touch_thrust_up
		if holding_ab:
			td += delta * 0.45
		if Input.is_key_pressed(KEY_C) or touch_thrust_down:
			td -= delta * 0.45
			decelerating = true
		if touch_throttle >= 0.0 and not touch_thrust_up and not touch_thrust_down:
			pl.set_throttle(touch_throttle)
			td = 0.0
		# Hold-to-afterburner: the last 0.2 of the lever is AB only while
		# Shift / the accel key is held. Releasing drops thrust back to mil.
		if (not holding_ab) and (not decelerating) and td == 0.0 and pl.thrust > 0.8:
			pl.thrust = move_toward(pl.thrust, 0.8, delta * 0.55)
		var br := 1.0 if decelerating or (Input.is_key_pressed(KEY_Q) and Input.is_key_pressed(KEY_E)) else 0.0
		pl.set_pilot_input(pitch, roll, yaw, td, br, yaw)
		pl.set_meta("decelerating", decelerating)
		# G is the primary gear toggle (also a mobile HUD button). Ctrl remains
		# as an extra bind. Occupied G is not routed as holster (see game_root).
		var ctrl_now := Input.is_physical_key_pressed(KEY_CTRL)
		var g_now := Input.is_physical_key_pressed(KEY_G)
		if ((ctrl_now and not _ctrl_was_down) or (g_now and not _g_was_down)) and pl.has_method("toggle_gear"):
			pl.call("toggle_gear")
		_ctrl_was_down = ctrl_now
		_g_was_down = g_now


func _vehicle_camera(delta: float) -> void:
	if player == null or not player.has_node("CameraPivot/Camera3D"):
		return
	var pivot: Node3D = player.get_node("CameraPivot")
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var k := kind_of(occupied)
	var xf := _vehicle_visual_xf()
	var fp := vehicle_cam == "first"
	if fp:
		var eye_off: Vector3 = occupied.call("cockpit_offset") if occupied.has_method("cockpit_offset") else Vector3(0, 1.2, 0)
		var eye: Vector3 = xf * eye_off
		var yaw := float(player.get("_yaw"))
		var pitch := float(player.get("_pitch"))
		var heading := _heading_yaw(_vehicle_forward(xf))
		var rel_yaw := wrapf(yaw - heading, -PI, PI)
		var look: Basis = xf.basis * Basis.from_euler(Vector3(pitch, rel_yaw, 0.0))
		_apply_vehicle_cam_xform(pivot, cam, Transform3D(look, eye))
		cam.fov = float(player.get("fp_fov"))
		cam.near = 0.08
		cam.current = true
		return
	# Third person: dynamic chase based on motion, not locked to the vehicle
	# heading / roll (custom-3d-car auto-rotate + Ace Combat flight-path chase).
	# Slow or stationary: fall back to the visual nose. Hold LMB / swipe to
	# orbit; release recenters behind the current motion (or heading).
	var dt := maxf(delta, 0.0001)
	var held := _touch_orbit or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if bool(player.get("ui_blocks_capture")):
		held = _touch_orbit
	_orbit_held = held
	var airborne := k == "plane" and bool(occupied.get("airborne"))
	var want_pitch := CAM_PITCH_AIR if airborne else CAM_PITCH_DEFAULT
	if not _cam_ready:
		_orbit_yaw = 0.0
		_orbit_pitch = want_pitch
		_chase_dir = Vector3.ZERO
		_cam_ready = true
	if not held:
		_orbit_yaw += wrapf(0.0 - _orbit_yaw, -PI, PI) * (1.0 - exp(-3.2 * dt))
		_orbit_pitch += (want_pitch - _orbit_pitch) * (1.0 - exp(-2.8 * dt))
	_orbit_pitch = clampf(_orbit_pitch, -1.25, 0.55)
	var dist := 8.5 if k == "car" else 16.0
	var height := 2.4 if k == "car" else 4.6
	var look_y_off := 1.2 if k == "car" else 1.8
	var look_ahead := 5.5 if k == "car" else 14.0
	var fwd := _vehicle_forward(xf)
	var origin := xf.origin
	var vel := Vector3.ZERO
	if occupied is RigidBody3D:
		vel = (occupied as RigidBody3D).linear_velocity
	# Motion direction; at low speed use the nose. Never lock to fuselage roll.
	var motion := vel
	if not airborne:
		motion.y = 0.0
	var motion_dir := fwd
	if motion.length() > (3.5 if airborne else 1.4):
		motion_dir = motion.normalized()
		# Reverse: keep the camera behind the visual nose, not ahead of the boot.
		if motion_dir.dot(fwd) < -0.15:
			motion_dir = fwd
	if _chase_dir.length_squared() < 1e-6:
		_chase_dir = motion_dir
	else:
		_chase_dir = _chase_dir.slerp(motion_dir, 1.0 - exp(-2.6 * dt)).normalized()
	var chase := _chase_dir
	var pivot_pt := origin + Vector3(0.0, look_y_off, 0.0)
	var cam_pos: Vector3
	var look_pt: Vector3
	var up_ref := Vector3.UP
	var yaw := _heading_yaw(chase, _heading_yaw(fwd)) + _orbit_yaw
	var cy := cos(_orbit_pitch)
	var look_dir := Vector3(-sin(yaw) * cy, sin(_orbit_pitch), -cos(yaw) * cy)
	if airborne:
		# Follow the flight path, not the banked fuselage.
		cam_pos = origin - chase * dist + up_ref * (height * 0.55 - look_dir.y * dist * 0.25)
		look_pt = origin + chase * look_ahead + up_ref * 0.4 if not held else pivot_pt
	else:
		cam_pos = origin - look_dir * dist
		cam_pos.y = pivot_pt.y - look_dir.y * dist + height * 0.12
		var fwd_h := Vector3(chase.x, 0.0, chase.z)
		if fwd_h.length_squared() < 1e-8:
			fwd_h = Vector3(fwd.x, 0.0, fwd.z)
		if fwd_h.length_squared() > 1e-8:
			fwd_h = fwd_h.normalized()
		look_pt = pivot_pt if held else (pivot_pt + fwd_h * look_ahead)
	var to_tgt := look_pt - cam_pos
	if to_tgt.length_squared() < 1e-8:
		to_tgt = chase if chase.length_squared() > 1e-8 else Vector3(0, 0, -1)
	var want_xf := Transform3D(Basis.looking_at(to_tgt, up_ref), cam_pos)
	_apply_vehicle_cam_xform(pivot, cam, want_xf, not _cam_ready)
	cam.fov = 55.0 if k == "car" else 62.0
	cam.near = 0.15
	cam.current = true


func _apply_vehicle_cam_xform(pivot: Node3D, cam: Camera3D, xf: Transform3D, snap: bool = true) -> void:
	if pivot:
		pivot.global_transform = xf
		if snap and pivot.has_method("reset_physics_interpolation"):
			pivot.reset_physics_interpolation()
	cam.position = Vector3.ZERO
	cam.rotation = Vector3.ZERO
	cam.global_transform = xf


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
			# Always aim from the crosshair (viewport centre). The mouse is on
			# the 载具 menu button when this is called, so it must not be used.
			var vp := cam.get_viewport().get_visible_rect().size
			dir = cam.project_ray_normal(vp * 0.5)
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
		# Wall or ceiling hits should still place the vehicle on the floor.
		var nrm: Vector3 = hit.get("normal", Vector3.UP)
		if nrm.dot(Vector3.UP) < 0.35:
			var gf: Variant = _ground(p.x, p.z)
			if gf != null:
				p = gf as Vector3
	# Keep menu-spawned vehicles from stacking. Distances are tight in the room
	# (exam bed ~2 m) and looser on the city map.
	var min_d := 22.0 if kind == "plane" else (2.3 if kind == "exam_bed" else 7.0)
	var step := 8.0 if kind == "plane" else (1.6 if kind == "exam_bed" else 4.0)
	var slide := dir.slide(Vector3.UP)
	if slide.length_squared() < 1e-6:
		slide = Vector3(0, 0, -1)
	slide = slide.normalized()
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
		p += slide * step
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
