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
const ROOM_BED_POS := Vector3(-1.28, 0.0, -1.18)
const ROOM_BED_YAW := 0.0  # length along Z, head toward -Z; beside the furniture bed, further back than 0.2.22
# Last-resort fallback if AirPort_Track cannot be measured this frame.
# Mid is past the white piano-key bars at the building-end threshold, on the
# asphalt, noses toward the helipad end. Prefer live mesh measurement.
const FALLBACK_RUNWAY := Vector3(-824.61, 0.0, 494.28)
const FALLBACK_RUNWAY_YAW := 0.70456  # nose toward the helipad end
const FALLBACK_RUNWAY_AXIS := Vector3(0.64770, 0.0, 0.76189)  # t+ toward threshold
const RUNWAY_LANE := 7.2
const RUNWAY_STANDOFF := 110.0  # metres inward from the mesh end if bars cannot be measured
# 0.2.24: move further up the runway toward mid-strip. 0.2.22/0.2.23 sat
# only ~26 m past the piano keys and still looked jammed on the threshold.
const RUNWAY_PAST_BARS := 84.0
const RUNWAY_FRAC := 0.18  # fraction of the asphalt length from the threshold
const ROAD_CAR_COUNT := 0  # no random roadside fleet; one airport car only
const LANDMARK_GROUND := "^(Boulevard_Ground|Docks_Ground|Island_Ground|AirPort_Track)"
const LANDMARK_ROAD := "^(Boulevard_Ground|Docks_Ground|Island_Ground)$"
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
var _cam_pan: Vector3 = Vector3.ZERO  # 观察/中键平移，沿相机右/上
var _cam_pan_held: bool = false
var vehicle_look_mode: String = "yaw"  # "yaw" | "orbit" — mobile observe button
# Car scissor-door boarding: 1 = just entered (open then close), -1 = exiting
# (open, then step out and close). Plane / exam bed skip this.
var _board_phase: int = 0
var _board_timer: float = 0.0
var _toggle_lock_until_ms: int = 0
const TOGGLE_LOCK_MS := 380
var touch_throttle: float = -1.0  # >=0 overrides plane throttle (0..1)
var touch_steer: Vector2 = Vector2.ZERO
var touch_car_accel: bool = false
var touch_car_brake: bool = false
var touch_yaw: float = 0.0  # -1 left, +1 right (mobile yaw buttons)
var touch_thrust_up: bool = false
var touch_thrust_down: bool = false
var touch_flight_stick: Vector2 = Vector2.ZERO  # +x right (yaw right), +y up (accel)
var _ctrl_was_down: bool = false
var _g_was_down: bool = false
var _city_warming: bool = false
var _packed_car: PackedScene
var _packed_plane: PackedScene
var _packed_bed: PackedScene
var _runway_cache: Dictionary = {}
# Third-person chase cam (Battlefield / Ace Combat / old web project):
# the vehicle is the orbit pivot. Offsets are *relative to the vehicle heading*
# so the default and the recenter pose are always behind the nose, never a
# leftover world or player yaw. Hold LMB / swipe to orbit; release recenters.
var _orbit_held: bool = false
var _pc_orbit_held: bool = false
var _touch_orbit: bool = false
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = -0.18
var _cam_ready: bool = false
var _chase_dir: Vector3 = Vector3.ZERO  # smoothed motion/heading for the chase cam
var _orbit_pivot: Vector3 = Vector3.ZERO  # stable vehicle-centered point used while orbiting
var _chase_basis: Basis = Basis.IDENTITY  # lagged full attitude (plane rolls with this)
var _exam_eye_origin: Vector3 = Vector3.ZERO  # head origin after IK, before look
var _exam_eye_ready: bool = false
const CAM_PITCH_DEFAULT := -0.18
const CAM_PITCH_AIR := -0.12


func setup(g: Node, p: CharacterBody3D) -> void:
	game = g
	player = p
	name = "VehicleSystem"
	preload_vehicle_resources()
	# Room exam bed is available immediately (room is the default map).
	# City map collisions + default vehicles also start during init so the
	# first map open does not hitch on that load.
	call_deferred("_ensure_room_defaults")
	call_deferred("_ensure_city_defaults")


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
	if sm == current_map or sm == "":
		return true
	# City defaults show with the city world, including overhead preview,
	# without changing current_map or hiding the home exam bed.
	if sm == "city" and game and game.has_node("City") and bool(game.get_node("City").visible):
		return true
	return false


func sync_world_visibility() -> void:
	_sync_visibility()


func preload_vehicle_resources() -> void:
	## Load car / plane / bed packed scenes once so first spawn is not a hitch.
	if _packed_car == null and ResourceLoader.exists(CAR_SCENE):
		_packed_car = load(CAR_SCENE) as PackedScene
	if _packed_plane == null and ResourceLoader.exists(PLANE_SCENE):
		_packed_plane = load(PLANE_SCENE) as PackedScene
	if _packed_bed == null and ResourceLoader.exists(BED_SCENE):
		_packed_bed = load(BED_SCENE) as PackedScene


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
	await warmup_city()


func warmup_city() -> void:
	## Instantiate default city vehicles up front (game init / map preload)
	## without changing current_map. Safe to call while the player is still in
	## the room: city colliders are only enabled briefly for ground rays.
	if _city_ready:
		return
	if _city_warming:
		# Another caller already started init warmup; wait it out so a
		# later await warmup_city() does not return early.
		while _city_warming and not _city_ready:
			if get_tree():
				await get_tree().physics_frame
			else:
				return
		return
	_city_warming = true
	preload_vehicle_resources()
	var city: Node = game.get_node_or_null("City") if game else null
	if city == null:
		_city_warming = false
		return
	if city.has_method("ensure_collisions"):
		city.call("ensure_collisions")
	# City is being shown (overhead preview or a real switch). Enable
	# colliders so ground rays can place vehicles on the pavement.
	if game and game.has_method("set_city_colliders_enabled"):
		game.call("set_city_colliders_enabled", true)
	if get_tree():
		await get_tree().physics_frame
		await get_tree().physics_frame
	_collect_landmarks()
	_spawn_default_planes()
	_spawn_default_cars()
	_city_ready = true
	_city_warming = false
	# If this was only a preview and the city was hidden again, drop colliders.
	if game and game.has_method("set_city_colliders_enabled"):
		var keep: bool = (city != null and bool(city.visible)) or current_map == "city"
		if not keep:
			game.call("set_city_colliders_enabled", false)
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
	## Two fighters side by side on the asphalt past the white piano-key
	## bars at the building-end threshold, noses pointing down the long
	## runway toward the helipad pad. Playtest dots sit inward from the
	## bars, not jammed against them. The MAPS label 「机场跑道（空旷）」
	## at x=-1000, z=300 is the helipad end and is wrong.
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
	if _runway_cache.size() >= 4:
		return _runway_cache
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
	var white_pts: Array[Vector3] = []
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
				var is_white := col.r > 0.78 and col.g > 0.78 and col.b > 0.78 and absf(col.r - col.g) < 0.08 and absf(col.r - col.b) < 0.08
				var is_grass := (not is_yellow) and (not is_white) and col.g >= col.r - 0.03 and col.g > col.b + 0.08 and col.r < 0.71
				if is_white:
					white_pts.append(w)
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
	# Takeoff heading: toward the helipad end. Needed before placing mid.
	var heading := Vector3(helipad.x - threshold.x, 0.0, helipad.z - threshold.z)
	if heading.length_squared() < 1e-6:
		heading = Vector3(-ex, 0.0, -ez) if d_pos <= d_neg else Vector3(ex, 0.0, ez)
	else:
		heading = heading.normalized()
	# Inner edge of the white piano-key bars (wide markings at the threshold),
	# then stand off onto the pavement to the playtest-marked dots.
	var sign_in := 1.0 if hel_t > thr_t else -1.0
	var bars_inner_dist := -1.0
	if white_pts.size() >= 8:
		# Only search the first 40 m — further white is centerline / other marks.
		var key_bins := 16
		var max_t := 40.0
		var bin_w := max_t / float(key_bins)
		var bmin: Array[float] = []
		var bmax: Array[float] = []
		var bcnt: Array[int] = []
		bmin.resize(key_bins)
		bmax.resize(key_bins)
		bcnt.resize(key_bins)
		for i in key_bins:
			bmin[i] = INF
			bmax[i] = -INF
			bcnt[i] = 0
		for wp in white_pts:
			var tt := (wp.x - threshold.x) * heading.x + (wp.z - threshold.z) * heading.z
			var ss := (wp.x - threshold.x) * (-heading.z) + (wp.z - threshold.z) * heading.x
			if tt < 0.0 or tt >= max_t:
				continue
			var bi := clampi(int(tt / bin_w), 0, key_bins - 1)
			bcnt[bi] += 1
			bmin[bi] = minf(bmin[bi], ss)
			bmax[bi] = maxf(bmax[bi], ss)
		# Piano keys: a contiguous wide white band that starts near the
		# threshold. Inner edge = end of that first run.
		var run_start := -1
		var run_end := -1
		for i in key_bins:
			var is_key := bcnt[i] >= 4 and (bmax[i] - bmin[i]) > 28.0
			if is_key:
				if run_start < 0:
					run_start = i
				run_end = i
			elif run_start >= 0:
				break
		if run_start >= 0 and run_start <= 8 and run_end >= run_start:
			bars_inner_dist = (float(run_end) + 1.0) * bin_w
	var strip_len := absf(hel_t - thr_t)
	var stand := RUNWAY_STANDOFF
	if bars_inner_dist >= 8.0 and bars_inner_dist <= 40.0:
		stand = bars_inner_dist + RUNWAY_PAST_BARS
	# Prefer a fraction of the runway so the pair sits mid-width and further
	# up the asphalt, not jammed on the threshold bars.
	if strip_len > 80.0:
		stand = maxf(stand, strip_len * RUNWAY_FRAC)
	var stand_max := strip_len * 0.32 if strip_len > 80.0 else 220.0
	stand = clampf(stand, 80.0, maxf(stand_max, 80.0))
	var mid_t := thr_t + sign_in * stand
	var mid := Vector3(mx + ex * mid_t + sx * center_s, 0.0, mz + ez * mid_t + sz * center_s)
	# yaw such that visual nose (-basis.z) = heading: (-sin y, 0, -cos y) = heading
	var yaw := atan2(-heading.x, -heading.z)
	var across := Vector3(-heading.z, 0.0, heading.x)
	_runway_cache = {
		"mid": mid,
		"yaw": yaw,
		"heading": heading,
		"across": across,
		"lane": RUNWAY_LANE,
		"threshold": threshold,
		"helipad": helipad,
		"bars_inner": bars_inner_dist,
		"standoff": stand,
	}
	return _runway_cache


func _spawn_default_cars() -> void:
	## 0.2.24: only one sports car at the airport. No random roadside fleet.
	## Menu-spawned cars remain a player action.
	var spot := _airport_car_spawn()
	if spot.is_empty():
		return
	_spawn_car(Vector3(spot["x"], spot["y"], spot["z"]), float(spot["yaw"]), true, "city")


func _airport_car_spawn() -> Dictionary:
	## One coupe on the airport apron (Airport_Front / terminal pad), off the
	## runway and clear of the two fighters. AirPort_Track itself is avoided
	## because its AABB includes grassy shoulders.
	var info := _measure_runway()
	var mid: Vector3 = info["mid"]
	var heading: Vector3 = info["heading"]
	var across: Vector3 = info["across"]
	if across.length_squared() < 1e-6:
		across = Vector3(-heading.z, 0.0, heading.x)
	across = across.normalized()
	var yaw := float(info.get("yaw", 0.0))
	var candidates: Array = []
	# Prefer named apron / frontage meshes.
	for k in _landmarks.keys():
		var key := str(k)
		if "Airport_Front" in key or "AirPort_Front" in key or key == "AirPort":
			var b: AABB = _landmarks[k]
			var c := b.get_center()
			candidates.append(Vector2(c.x, c.z))
			candidates.append(Vector2(c.x + 12.0, c.z + 8.0))
			candidates.append(Vector2(c.x - 12.0, c.z + 10.0))
			candidates.append(Vector2(c.x + 8.0, c.z - 10.0))
	# Terminal-side fallback near the airport buildings.
	var bld := Vector3(-831.86, 0.0, 362.89)
	candidates.append(Vector2(bld.x + 22.0, bld.z + 18.0))
	candidates.append(Vector2(bld.x - 18.0, bld.z + 22.0))
	candidates.append(Vector2(bld.x + 30.0, bld.z + 8.0))
	# Last, a pad well off the fighter lane (airport-tolerant ground check).
	for side in [1.0, -1.0]:
		var x: float = mid.x + across.x * (RUNWAY_LANE * 4.2) * side - heading.x * 20.0
		var z: float = mid.z + across.z * (RUNWAY_LANE * 4.2) * side - heading.z * 20.0
		candidates.append(Vector2(x, z))
	for c in candidates:
		var clash := false
		for v in vehicles:
			if not is_instance_valid(v):
				continue
			if Vector2(v.global_position.x - c.x, v.global_position.z - c.y).length() < 16.0:
				clash = true
				break
		if clash:
			continue
		var gy: Variant = _airport_pad_y(c.x, c.y)
		if gy == null:
			continue
		return {"x": c.x, "y": float(gy), "z": c.y, "yaw": yaw}
	return {}


func _airport_pad_y(x: float, z: float) -> Variant:
	## Solid airport pavement: allow apron / frontage, reject sea and grass.
	var g: Variant = _road_ground(x, z)
	if g == null:
		return null
	var gy: Vector3 = g
	if gy.y <= 0.04 or gy.y >= 8.0:
		return null
	if _hit_is_non_pavement(x, z, true):
		return null
	for d in [Vector2(1.6, 0.0), Vector2(-1.6, 0.0), Vector2(0.0, 1.6), Vector2(0.0, -1.6)]:
		var n: Variant = _road_ground(x + d.x, z + d.y)
		if n == null:
			return null
		var ny: Vector3 = n
		if ny.y <= 0.04 or absf(ny.y - gy.y) > 0.8:
			return null
		if _hit_is_non_pavement(x + d.x, z + d.y, true):
			return null
	return gy.y


func _sample_road_points(count: int, avoid: Array) -> Array:
	## Port of world-map.ts sampleRoadPoints, but only on real road meshes
	## (Boulevard / Docks / Island). AirPort_Track is excluded — its AABB
	## includes grass shoulders and was parking a car in the grass.
	var grounds: Array = []  # [AABB]
	var re := RegEx.new()
	re.compile(LANDMARK_ROAD)
	for k in _landmarks.keys():
		if re.search(str(k)) != null:
			grounds.append(_landmarks[k])
	var out: Array = []
	if grounds.is_empty():
		return out
	var guard := 0
	while out.size() < count and guard < count * 48:
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
		var gy: Variant = _pavement_y(x, z)
		if gy == null:
			continue
		var along_x := b.size.x > b.size.z
		out.append({"x": x, "y": float(gy), "z": z, "yaw": (-PI * 0.5) if along_x else 0.0})
	return out


func _road_ground(x: float, z: float) -> Variant:
	## Like _ground, but ignores vehicles so a parked car is not its own ground.
	var exclude: Array = []
	if player:
		exclude.append(player.get_rid())
	for v in vehicles:
		if v is CollisionObject3D and is_instance_valid(v):
			exclude.append((v as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 4.0, z), Vector3(x, -2.0, z), 1)
	q.exclude = exclude
	if not is_inside_tree():
		return null
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else hit["position"]


func _pavement_y(x: float, z: float) -> Variant:
	## Ground Y only if the point and a small ring sit on road-height pavement,
	## not grass, water, or a cliff edge.
	var g: Variant = _road_ground(x, z)
	if g == null:
		return null
	var gy: Vector3 = g
	if gy.y <= 0.04 or gy.y >= 2.2:
		return null
	if _hit_is_non_pavement(x, z):
		return null
	for d in [Vector2(1.6, 0.0), Vector2(-1.6, 0.0), Vector2(0.0, 1.6), Vector2(0.0, -1.6)]:
		var n: Variant = _road_ground(x + d.x, z + d.y)
		if n == null:
			return null
		var ny: Vector3 = n
		if ny.y <= 0.04 or absf(ny.y - gy.y) > 0.55:
			return null
		if _hit_is_non_pavement(x + d.x, z + d.y):
			return null
	return gy.y


func _hit_is_non_pavement(x: float, z: float, allow_airport_pad: bool = false) -> bool:
	## Reject sea / grass / sidewalk names under a downward ray.
	var exclude: Array = []
	if player:
		exclude.append(player.get_rid())
	for v in vehicles:
		if v is CollisionObject3D and is_instance_valid(v):
			exclude.append((v as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 4.0, z), Vector3(x, -2.0, z), 1)
	q.exclude = exclude
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var n := hit.get("collider") as Node
	var parts := ""
	while n:
		parts += " " + str(n.name)
		n = n.get_parent()
	var low := parts.to_lower()
	if "sea" in low or "ocean" in low or "water" in low:
		return true
	if "grass" in low or "lawn" in low:
		return true
	# AirPort_Track shoulders are grass even when the mesh name is the track.
	# Apron / frontage spawns may opt into airport pads (not the runway mesh).
	if "airport_track" in low and not allow_airport_pad:
		return true
	if allow_airport_pad and "airport_track" in low:
		# Still reject if we clearly landed on a grass-looking name.
		if "grass" in low or "shoulder" in low:
			return true
	return false


func is_default_car_on_pavement(v: Node) -> bool:
	if v == null:
		return false
	var n := v as Node3D
	if n == null:
		return false
	var x := n.global_position.x
	var z := n.global_position.z
	# The single airport default car sits on the apron, which is not a city road.
	if _airport_pad_y(x, z) != null:
		return true
	return _pavement_y(x, z) != null


func _ground(x: float, z: float, top: float = 320.0, ignore: Node = null) -> Variant:
	var exclude: Array = []
	if player:
		exclude.append(player.get_rid())
	if ignore is CollisionObject3D:
		exclude.append((ignore as CollisionObject3D).get_rid())
	if game and game.has_method("ground_at") and ignore == null:
		return game.call("ground_at", x, z, top)
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -60, z), 1)
	q.exclude = exclude
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
	preload_vehicle_resources()
	var v: Node = (_packed_car if _packed_car else load(CAR_SCENE)).instantiate()
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
	preload_vehicle_resources()
	var v: Node = (_packed_plane if _packed_plane else load(PLANE_SCENE)).instantiate()
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
	preload_vehicle_resources()
	var v: Node = (_packed_bed if _packed_bed else load(BED_SCENE)).instantiate()
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
	## One physical tap must not both board and immediately exit after the
	## occupied flag flips (or after a touch + emulated-mouse double event).
	var now := Time.get_ticks_msec()
	if now < _toggle_lock_until_ms:
		return false
	var ok := try_exit() if occupied else try_enter()
	if ok:
		_toggle_lock_until_ms = now + TOGGLE_LOCK_MS
	return ok


func try_enter() -> bool:
	# If a car door-exit is in progress, finish it so we can board another vehicle.
	if occupied and _board_phase < 0:
		var leaving := occupied
		var dest := _exit_stand_dest(leaving)
		_finish_exit(dest, true)
		if is_instance_valid(leaving) and leaving.get("door_target") != null:
			leaving.set("door_target", 0.0)
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
		# Start the first-person look at the default (toward the feet) so
		# the head and camera share a common zero.
		player.set("_yaw", 0.0)
		player.set("_pitch", 0.0)
		_apply_exam_pose()
	else:
		# Cars / planes default to third person. V and the mobile 视角
		# button toggle 1st/3rd. The 观察 button switches yaw swipe vs orbit.
		vehicle_cam = "third"
		vehicle_look_mode = "yaw"
		_reset_vehicle_cam()
		_sync_vehicle_look_from_heading()
		_hide_player_body(true)
		if k == "car":
			_begin_board_anim(1)
	occupancy_changed.emit(v)
	proximity_changed.emit(v, true)
	return true


func try_exit() -> bool:
	if occupied == null or player == null:
		return false
	if _board_phase < 0:
		return true  # already opening the door to step out
	if kind_of(occupied) == "car":
		_begin_board_anim(-1)
		return true
	var dest := _exit_stand_dest(occupied)
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
	_board_phase = 0
	_board_timer = 0.0
	occupancy_changed.emit(null)
	_update_nearest()
	proximity_changed.emit(nearest, false)
	return true


func _exit_stand_dest(v: Node) -> Vector3:
	## Stand beside the *current* vehicle transform — never a stale
	## spawn/ground point. Airborne exits stay next to the aircraft.
	## Leaving the home exam bed still stands inside the room with facing restored.
	var xf := _vehicle_visual_xf(v)
	var off: Vector3 = v.call("exit_offset") if v.has_method("exit_offset") else xf.basis.x * 2.0
	var dest: Vector3 = xf.origin + off
	var k := kind_of(v)
	var in_room := str(game.get("current_map") if game else current_map) == "room" \
		or str(v.get("spawn_map")) == "room"
	if in_room and k == "exam_bed":
		dest = _safe_room_stand(v, dest)
		# Cast from just above standing height — a sky-high ray hits the
		# room roof first (its top face is a valid floor).
		var top: float = dest.y + 1.85
		var g_bed: Variant = _ground(dest.x, dest.z, top, v)
		if g_bed != null:
			dest.y = (g_bed as Vector3).y + 0.04
		else:
			dest.y = xf.origin.y
		# If a ceiling was somehow still chosen, fall back to the room spawn.
		if dest.y > 1.6:
			dest = _room_spawn_floor()
		return dest
	# High / airborne: keep the player beside the live vehicle, do not snap
	# down to the pavement under the flight path.
	var g: Variant = _ground(dest.x, dest.z, maxf(xf.origin.y + 8.0, 8.0), v)
	var ground_y := (g as Vector3).y if g != null else (xf.origin.y - 1000.0)
	var agl := xf.origin.y - ground_y
	var airborne := k == "plane" and bool(v.get("airborne"))
	if airborne or agl > 3.0:
		var lateral := Vector3(off.x, 0.0, off.z)
		if lateral.length_squared() < 0.04:
			var side := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z)
			if side.length_squared() < 1e-6:
				side = Vector3.RIGHT
			lateral = side.normalized() * 3.2
		dest = xf.origin + lateral
		dest.y = xf.origin.y
		return dest
	# Ground vehicles: beside the current body, feet on the pavement.
	if g != null:
		dest.y = ground_y + 0.04
	else:
		dest.y = xf.origin.y
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


func _begin_board_anim(phase: int) -> void:
	## phase 1: just boarded — open scissor doors, then auto-close.
	## phase -1: exiting — open, then step out and close.
	_board_phase = phase
	_board_timer = 0.72 if phase > 0 else 0.52
	if occupied and occupied.get("door_target") != null:
		occupied.set("door_target", 1.0)


func _tick_board_anim(delta: float) -> void:
	if _board_phase == 0:
		return
	_board_timer -= delta
	if _board_timer > 0.0:
		return
	if _board_phase > 0:
		if is_instance_valid(occupied) and occupied.get("door_target") != null:
			occupied.set("door_target", 0.0)
		_board_phase = 0
		_board_timer = 0.0
		return
	# Finished opening for exit: step out, then close the doors behind us.
	var v := occupied
	_board_phase = 0
	_board_timer = 0.0
	if is_instance_valid(v):
		var dest := _exit_stand_dest(v)
		_finish_exit(dest, true)
		if is_instance_valid(v) and v.get("door_target") != null:
			v.set("door_target", 0.0)


func toggle_vehicle_cam() -> String:
	vehicle_cam = "first" if vehicle_cam != "first" else "third"
	if vehicle_cam == "third":
		_reset_vehicle_cam()
	else:
		_sync_vehicle_look_from_heading()
	return vehicle_cam


func toggle_observe_mode() -> String:
	## Mobile 观察: first press = look drag orbits (release recenters onto
	## the vehicle heading); press again = right-side horizontal swipe is
	## yaw. Works in first- and third-person. Default is yaw.
	vehicle_look_mode = "orbit" if vehicle_look_mode != "orbit" else "yaw"
	if vehicle_look_mode == "yaw":
		end_orbit()
	return vehicle_look_mode


func is_drive_occupied() -> bool:
	var k := kind_of(occupied)
	return occupied != null and (k == "car" or k == "plane")


func is_observe_orbit() -> bool:
	## 观察 mode on a car/plane, in first- or third-person. Mobile only.
	return is_drive_occupied() and vehicle_look_mode == "orbit"


func is_pc_orbit_held() -> bool:
	return is_drive_occupied() and _pc_orbit_held


func pan_look(rel: Vector2, sensitivity: float = 0.002) -> void:
	## 观察视角下双指或中键平移摄像机（只平移，不环绕）。
	var k := maxf(sensitivity, 0.0002)
	_cam_pan.x -= rel.x * k
	_cam_pan.y += rel.y * k
	var lim := 2.8 if vehicle_cam != "first" else 0.55
	_cam_pan.x = clampf(_cam_pan.x, -lim, lim)
	_cam_pan.y = clampf(_cam_pan.y, -lim * 0.7, lim * 0.7)


func reset_cam_pan() -> void:
	_cam_pan = Vector3.ZERO
	_cam_pan_held = false


func cam_pan_offset() -> Vector3:
	return _cam_pan


func begin_pc_orbit() -> void:
	## PC：按住右键即可环绕观察，不必先切到「观察」模式。
	if not is_drive_occupied():
		return
	_pc_orbit_held = true
	_orbit_held = true


func end_pc_orbit() -> void:
	_pc_orbit_held = false
	_orbit_held = false


func _fp_default_pitch() -> float:
	# Plane: look along the visual nose so the view origin sits in the HUD box.
	return 0.0 if kind_of(occupied) == "plane" else -0.06


func _sync_vehicle_look_from_heading() -> void:
	## First-person inside a vehicle is cockpit-aligned: look lives in
	## vehicle space (visual nose -Z). Do not store an absolute world yaw
	## on the player — that is what kept the view from rolling/yawing
	## with the vehicle.
	if player == null or occupied == null:
		return
	_orbit_yaw = 0.0
	_orbit_pitch = _fp_default_pitch() if vehicle_cam == "first" else CAM_PITCH_DEFAULT
	# Keep player look extras at zero; the vehicle camera composes its own
	# offsets in the vehicle basis and does not read _yaw/_pitch.
	player.set("_yaw", 0.0)
	player.set("_pitch", _orbit_pitch)


func is_drive_third() -> bool:
	return is_drive_occupied() and vehicle_cam == "third"


func begin_orbit() -> void:
	if not is_observe_orbit() and not _pc_orbit_held:
		return
	_orbit_held = true
	if is_observe_orbit():
		_touch_orbit = true


func end_orbit() -> void:
	_orbit_held = false
	_touch_orbit = false
	# 不在这里清掉 PC 右键状态：PC 松开由 end_pc_orbit 负责。


func orbit_look(rel: Vector2, sens: float = 0.004) -> void:
	if not is_observe_orbit() and not _pc_orbit_held:
		return
	_orbit_held = true
	_orbit_yaw -= rel.x * sens
	var pmin := -1.25
	var pmax := 0.85 if vehicle_cam == "first" else 0.55
	_orbit_pitch = clampf(_orbit_pitch - rel.y * sens, pmin, pmax)


func _reset_vehicle_cam() -> void:
	_cam_pan = Vector3.ZERO
	_cam_ready = false
	_orbit_held = false
	_touch_orbit = false
	_pc_orbit_held = false
	_orbit_yaw = 0.0
	_orbit_pitch = CAM_PITCH_DEFAULT
	_chase_dir = Vector3.ZERO
	_orbit_pivot = Vector3.ZERO
	_chase_basis = Basis.IDENTITY


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


func debug_orbit_state() -> Dictionary:
	var cam_pos := Vector3.ZERO
	if player and player.has_node("CameraPivot/Camera3D"):
		cam_pos = (player.get_node("CameraPivot/Camera3D") as Camera3D).global_position
	return {
		"held": _orbit_held,
		"yaw": _orbit_yaw,
		"pitch": _orbit_pitch,
		"pivot": _orbit_pivot,
		"cam": cam_pos,
		"chase": _chase_dir,
		"basis_up": _chase_basis.y,
	}


func _process_occupied(delta: float) -> void:
	if not is_instance_valid(occupied) or player == null:
		return
	_tick_board_anim(delta)
	# If the exit animation just finished, occupancy may already be cleared.
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
	# on (not in) the cushion and the backrest. Shift toward the headrest
	# (patient +Y / spine) so the torso sits farther back, per playtest guides.
	# Raise the ischial contact off the cushion (0.2.22 sat too low and clipped)
	# without floating: a thicker seat skin and a slight hip lift.
	const BUTTOCK := Vector3(0.0, 0.03, -0.08)
	const SEAT_SKIN := 0.10
	# Face-up (lie.z) is the backrest normal, not world-up, so a seat-skin
	# offset alone still lets the crotch sink through the horizontal cushion.
	# 0.2.26: lift along the bed/world up so the ischia sit ON the pad.
	const HIP_LIFT := 0.085
	# A little along the spine plus a horizontal slide toward the headrest
	# (bed -Z) so the torso sits farther back without lifting the hips off
	# the cushion (playtest "身体向后一些").
	# The first-person eye offset is still derived from the head bone, so it
	# travels with the body (do not retune the eye independently).
	const BACK_SHIFT := 0.05
	const HEADWARD := 0.16
	var sit := hip_local + BUTTOCK
	var headward := -bed.global_transform.basis.z * HEADWARD
	headward.y = 0.0
	var hip_up := bed.global_transform.basis.y.normalized() * HIP_LIFT
	body.global_transform = Transform3D(lie, seat - lie * sit + lie.z * SEAT_SKIN + lie.y * BACK_SHIFT + headward + hip_up)
	if skel:
		var al: Vector3 = bed.armrest_l_global() if bed.has_method("armrest_l_global") else bed.stirrup_l_global()
		var ar: Vector3 = bed.armrest_r_global() if bed.has_method("armrest_r_global") else bed.stirrup_r_global()
		# Place the hands on the armrest pads and the feet so the calves
		# rest along the stirrup tops. Offsets are derived from the actual
		# pad AABBs (not guessed) so the forearm stays parallel on the rail
		# and the shin does not overshoot the stirrup sideways.
		var left := lie.x
		var feet := -lie.y
		var bed_up := bed.global_transform.basis.y.normalized()
		var arm_geom: Dictionary = bed.armrest_geometry() if bed.has_method("armrest_geometry") else {}
		var leg_geom: Dictionary = bed.stirrup_geometry() if bed.has_method("stirrup_geometry") else {}
		var arm_half: float = float(arm_geom.get("half_len", 0.166))
		# Raise the forearm a little so it sits flush / level with the armrest.
		var arm_skin := 0.044
		# Hand near the foot-end of the pad, on top, slightly inward of the lip.
		# Do not overshoot the rail (0.2.27 used 0.22 m and crossed the end).
		var hand_along := clampf(arm_half * 0.72, 0.08, arm_half - 0.02)
		al = al + feet * hand_along + bed_up * arm_skin - left * 0.035
		ar = ar + feet * hand_along + bed_up * arm_skin + left * 0.035
		# Mid-calf stays on the pad; lift a little more so the shin does not
		# clip through the stirrup bar. The foot extends past the pad along
		# the shin (outward a little, mostly toward the feet).
		var stir_half: float = float(leg_geom.get("half_len", 0.142))
		var stir_half_w: float = float(leg_geom.get("half_wid", 0.080))
		var calf_out := clampf(stir_half_w * 0.45, 0.02, 0.055)
		var foot_along := stir_half + 0.10
		var sl: Vector3 = bed.stirrup_l_global() + left * calf_out + feet * foot_along + bed_up * 0.052
		var sr: Vector3 = bed.stirrup_r_global() - left * calf_out + feet * foot_along + bed_up * 0.052
		ExamPose.apply(skel, sl, sr, bed.backrest_angle, al, ar, feet, bed_up)
		# Alive: subtle chest / belly breath after the static pose, before
		# head-follow, so it does not fight IK or the waist flex. Skip this
		# in observation mode — that path calls update() after set_gaze_target.
		var display_now := player.has_method("is_display_mode") and bool(player.call("is_display_mode"))
		if (not display_now) and player.has_method("get_secondary"):
			var life = player.call("get_secondary")
			if life:
				if life.has_method("clear_body_look"):
					life.call("clear_body_look")
				if life.has_method("clear_gaze_intent"):
					life.call("clear_gaze_intent")
				if life.has_method("update"):
					life.call("update", delta, false)
		# Capture the eye from the posed head *before* look rotation, so
		# turning the view cannot hitch the camera origin. Use the true
		# eye height (in front of the face), not a torso-biased offset.
		var eye_xf := ExamPose.eye_world(skel)
		_exam_eye_origin = eye_xf.origin
		_exam_eye_ready = true
		# First-person: the visible head follows the camera look (after IK
		# and breath). Aim at the same world-forward the camera uses.
		var fp_now := bool(player.get("first_person")) and not (player.has_method("is_display_mode") and bool(player.call("is_display_mode")))
		if fp_now:
			var yp := _clamp_exam_look()
			var look_dir := -lie.y * 0.80 - lie.z * 0.48
			if look_dir.length_squared() < 1e-6:
				look_dir = Vector3(0, 0, 1)
			look_dir = look_dir.normalized()
			var look_b := _exam_look_basis(look_dir, yp.x, yp.y)
			ExamPose.apply_look(skel, yp.x, yp.y, -look_b.z, look_b.y)
		ExamPose.offset_hair(skel, Vector3(0.0, 0.02, -0.10))
		# Observation mode: head / eyes look at the orbit camera.
		if player.has_method("is_display_mode") and bool(player.call("is_display_mode")) and player.has_method("get_secondary"):
			var sec = player.call("get_secondary")
			if sec and player.has_node("CameraPivot/Camera3D"):
				var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
				if sec.has_method("set_gaze_target"):
					sec.call("set_gaze_target", cam.global_position)
				if sec.has_method("update"):
					sec.call("update", delta, false)
				ExamPose.offset_hair(skel, Vector3(0.0, 0.02, -0.10))
				if sec.has_method("snap_hair_to_pose"):
					sec.call("snap_hair_to_pose")
		elif player.has_method("get_secondary"):
			var sec2 = player.call("get_secondary")
			# Only clear the gaze *intent*. Never reset look bones to rest
			# here — that would wipe ExamPose.apply_look on the visible head.
			# (Intent was already cleared before apply_look.)
			if sec2 and sec2.has_method("snap_hair_to_pose"):
				sec2.call("snap_hair_to_pose")


func _exam_camera(_delta: float) -> void:
	if player == null:
		return
	if _map_view_open():
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
	var bed := occupied as ExamBed
	if bed == null:
		return
	var lie := bed.patient_basis()
	# Default: from the head, look toward the feet / abdomen so the belly
	# sits in the lower field of view (soft, not staring straight down).
	var look_dir := -lie.y * 0.80 - lie.z * 0.48
	if look_dir.length_squared() < 1e-6:
		look_dir = bed.global_transform.basis.z
	look_dir = look_dir.normalized()
	# 0.2.24 had the pitch signs backwards. In this project positive _pitch
	# looks UP (Godot camera X / the standing FP convention). Looking up is
	# unrestricted; looking down is limited a little so the neck stump is
	# not the main view.
	var yp := _clamp_exam_look()
	var yaw := yp.x
	var pitch := yp.y
	# Eye comes from the IK head, captured before apply_look, so rotating
	# the neck cannot hitch the camera origin mid-swing.
	# Eye sits at the head / eyes, in front of the face — not lowered toward
	# the torso to "see the belly". Default look still biases slightly toward
	# the abdomen so the belly is in the lower FOV.
	var eye := _exam_eye_origin if _exam_eye_ready else ExamPose.eye_world(skel).origin
	var look := _exam_look_basis(look_dir, yaw, pitch)
	cam.global_transform = Transform3D(look, eye)
	cam.fov = float(player.get("fp_fov"))
	cam.near = 0.08
	cam.current = true


func _clamp_exam_look() -> Vector2:
	## Returns (yaw, pitch). Positive pitch looks UP. Looking down is limited.
	const YAW_LIM := 1.55
	# Looking down is only limited enough to keep the neck stump off-screen;
	# mid and down angles are otherwise free. Looking up stays unrestricted.
	const PITCH_MIN := -1.05
	const PITCH_MAX := 1.65
	var yaw := clampf(float(player.get("_yaw")), -YAW_LIM, YAW_LIM)
	var pitch := clampf(float(player.get("_pitch")), PITCH_MIN, PITCH_MAX)
	player.set("_yaw", yaw)
	player.set("_pitch", pitch)
	return Vector2(yaw, pitch)


func _exam_look_forward(yaw: float, pitch: float, lie: Basis) -> Vector3:
	## Same composition as _exam_camera: default look toward the feet / abdomen,
	## then the player's yaw/pitch extras, world-up, no roll.
	var look_dir := -lie.y * 0.80 - lie.z * 0.48
	if look_dir.length_squared() < 1e-6:
		look_dir = Vector3(0, 0, 1)
	look_dir = look_dir.normalized()
	var fwd := -_exam_look_basis(look_dir, yaw, pitch).z
	if fwd.length_squared() < 1e-8:
		return look_dir
	return fwd.normalized()


func _exam_look_basis(look_dir: Vector3, yaw: float, pitch: float) -> Basis:
	## Continuous first-person look: yaw about world-up, then pitch about the
	## resulting right vector. No looking_at rebuild and no up-vector switch
	## that used to hitch around mid angles / near-vertical looks.
	if look_dir.length_squared() < 1e-8:
		look_dir = Vector3(0, 0, 1)
	else:
		look_dir = look_dir.normalized()
	var world_up := Vector3.UP
	# right = forward × up (not up × forward). The 0.2.27 cross was flipped,
	# which inverted pitch (and made the camera feel direction-reversed).
	var base_right := look_dir.cross(world_up)
	if base_right.length_squared() < 1e-8:
		base_right = Vector3.RIGHT
	base_right = base_right.normalized()
	var fwd := look_dir.rotated(world_up, yaw)
	var right := base_right.rotated(world_up, yaw)
	if right.length_squared() < 1e-8:
		right = fwd.cross(world_up)
		if right.length_squared() < 1e-8:
			right = Vector3.RIGHT
		right = right.normalized()
	else:
		right = right.normalized()
	# Positive pitch looks UP (rotate forward toward world-up about right).
	fwd = fwd.rotated(right, pitch)
	if fwd.length_squared() < 1e-8:
		fwd = look_dir
	else:
		fwd = fwd.normalized()
	var up := right.cross(fwd)
	if up.length_squared() < 1e-8:
		up = world_up
	else:
		up = up.normalized()
	right = fwd.cross(up).normalized()
	return Basis(right, up, -fwd).orthonormalized()


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
		# Nitro is ONLY the on-screen 加速 button and/or Shift. W and the
		# movement joystick never start it.
		var nt := Input.is_key_pressed(KEY_SHIFT) or touch_car_accel
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
		# Flight stick (mobile 摇杆模式): +x right = yaw right, +y up = accel.
		# Full-up lights afterburner the same way holding 加速 does.
		var fs := touch_flight_stick
		if absf(fs.x) > 0.08:
			# touch_yaw is -1 left / +1 right; invert so left is + ctrl_yaw.
			yaw += -fs.x
		if Input.is_key_pressed(KEY_Q):
			yaw += 1.0
		if Input.is_key_pressed(KEY_E):
			yaw -= 1.0
		yaw = clampf(yaw, -1.0, 1.0)
		var td := 0.0
		var decelerating := false
		var stick_ab := fs.y >= 0.82
		var stick_up := fs.y > 0.12
		var stick_dn := fs.y < -0.12
		var holding_ab := Input.is_key_pressed(KEY_SHIFT) or touch_thrust_up or stick_ab
		if holding_ab:
			td += delta * 0.45
		elif stick_up:
			td += delta * 0.45 * clampf(fs.y, 0.0, 1.0)
		if Input.is_key_pressed(KEY_C) or touch_thrust_down or stick_dn:
			td -= delta * 0.45 * (1.0 if (Input.is_key_pressed(KEY_C) or touch_thrust_down) else clampf(-fs.y, 0.0, 1.0))
			decelerating = true
		if touch_throttle >= 0.0 and not touch_thrust_up and not touch_thrust_down and fs.length_squared() < 0.02:
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


func _map_view_open() -> bool:
	var g := get_parent()
	if g and g.get("map_view"):
		return bool(g.get("map_view").get("is_open"))
	return false


func _vehicle_camera(delta: float) -> void:
	if player == null or not player.has_node("CameraPivot/Camera3D"):
		return
	# Opening the overhead map from a vehicle must not let the chase / cockpit
	# camera steal current from the top-down map camera every frame.
	if _map_view_open():
		return
	var pivot: Node3D = player.get_node("CameraPivot")
	var cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	var k := kind_of(occupied)
	var xf := _vehicle_visual_xf()
	var fp := vehicle_cam == "first"
	var dt := maxf(delta, 0.0001)
	# Observe-mode drag holds the look offset; anything else (including
	# two-finger leftovers) must not orbit. Recenter is always to the
	# vehicle heading (car body forward / plane nose).
	var held := (is_observe_orbit() and (_orbit_held or _touch_orbit)) or _pc_orbit_held
	if is_observe_orbit() and not fp and not bool(player.get("ui_blocks_capture")) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		held = true
	if not is_observe_orbit() and not _pc_orbit_held:
		held = false
	if not _pc_orbit_held:
		_orbit_held = held
	var airborne := k == "plane" and bool(occupied.get("airborne"))
	var want_pitch := _fp_default_pitch() if fp else (CAM_PITCH_AIR if airborne else CAM_PITCH_DEFAULT)
	var just_ready := not _cam_ready
	if just_ready:
		_orbit_yaw = 0.0
		_orbit_pitch = want_pitch
		_chase_dir = Vector3.ZERO
		_chase_basis = xf.basis.orthonormalized()
		_cam_ready = true
	if not held:
		# Soft, slightly slower recenter from a dragged orbit, not a snap
		# (tau ≈ 0.77 s / 0.83 s). Recenter target is vehicle-forward.
		_orbit_yaw += wrapf(0.0 - _orbit_yaw, -PI, PI) * (1.0 - exp(-1.3 * dt))
		_orbit_pitch += (want_pitch - _orbit_pitch) * (1.0 - exp(-1.2 * dt))
	_orbit_pitch = clampf(_orbit_pitch, -1.25, 0.85 if fp else 0.55)
	if fp:
		# Cockpit camera is parented in vehicle space: the eye rides the
		# seat offset, and the basis is the vehicle basis times a look
		# offset (observe drag). Default look is along the visual nose
		# (-Z), so pitch/roll/yaw of the vehicle are followed 1:1.
		var eye_off: Vector3 = occupied.call("cockpit_offset") if occupied.has_method("cockpit_offset") else Vector3(0, 1.2, 0)
		var eye: Vector3 = xf * eye_off
		var look: Basis = xf.basis.orthonormalized() * Basis.from_euler(Vector3(_orbit_pitch, _orbit_yaw, 0.0))
		_apply_vehicle_cam_xform(pivot, cam, Transform3D(look, eye), just_ready)
		cam.fov = float(player.get("fp_fov"))
		cam.near = 0.08
		cam.current = true
		return
	# Third person: the same vehicle-centered pivot is used for the default
	# follow and for drag-to-orbit. For the plane, the camera follows the
	# nose attitude (with a little lag on hard turns) and rolls with the
	# airframe — a hardcore fighter view, not a horizon-locked inertia cam.
	var dist := 8.5 if k == "car" else 16.0
	var height := 2.4 if k == "car" else 4.6
	var look_y_off := 1.2 if k == "car" else 1.8
	var fwd := _vehicle_forward(xf)
	var origin := xf.origin
	# Shared pivot for follow and orbit so the visual center never jumps.
	var pivot_pt := origin + xf.basis.y.normalized() * look_y_off if k == "plane" else origin + Vector3(0.0, look_y_off, 0.0)
	_orbit_pivot = pivot_pt
	var up_ref := Vector3.UP
	var back_dir := -fwd
	if k == "plane":
		# Slerp the full attitude toward the aircraft so a hard turn leaves a
		# small lag, then the view recenters on the nose. Roll is followed,
		# not stripped to the horizon.
		var want_b := xf.basis.orthonormalized()
		if just_ready or _chase_basis.x.length_squared() < 1e-6:
			_chase_basis = want_b
		else:
			# Slightly slower than 1:1 so a sharp break can offset a little.
			var k_follow := 1.0 - exp(-5.4 * dt)
			_chase_basis = _chase_basis.slerp(want_b, k_follow).orthonormalized()
		var cfwd := -_chase_basis.z
		var cup := _chase_basis.y
		if cup.length_squared() < 1e-8:
			cup = Vector3.UP
		else:
			cup = cup.normalized()
		_chase_dir = cfwd
		up_ref = cup
		# Orbit offsets live in the lagged aircraft frame (yaw about up, pitch about right).
		# look_dir is the *view* direction (along the nose). Camera sits behind
		# the jet at pivot - look_dir * dist, looking forward — never a rear-view
		# from in front of the nose. Visual nose is -Z = cfwd.
		var right := _chase_basis.x
		if right.length_squared() < 1e-8:
			right = cfwd.cross(cup)
		right = right.normalized()
		var look_dir := cfwd.rotated(cup, _orbit_yaw).rotated(right, _orbit_pitch)
		if look_dir.length_squared() < 1e-8:
			look_dir = cfwd
		else:
			look_dir = look_dir.normalized()
		var cam_pos: Vector3 = pivot_pt - look_dir * dist + cup * (height * 0.22)
		var look_pt: Vector3 = pivot_pt
		var to_tgt := look_pt - cam_pos
		if to_tgt.length_squared() < 1e-8:
			to_tgt = cfwd
		# looking_at with the aircraft up so the camera rolls with the jet.
		var want_xf := Transform3D(Basis.looking_at(to_tgt, up_ref), cam_pos)
		_apply_vehicle_cam_xform(pivot, cam, want_xf, just_ready)
	else:
		var vel := Vector3.ZERO
		if occupied is RigidBody3D:
			vel = (occupied as RigidBody3D).linear_velocity
		var motion := vel
		motion.y = 0.0
		var motion_dir := fwd
		if motion.length() > 1.4:
			motion_dir = motion.normalized()
			if motion_dir.dot(fwd) < -0.15:
				motion_dir = fwd
		if just_ready or _chase_dir.length_squared() < 1e-6 or motion.length() <= 1.4:
			_chase_dir = motion_dir
		else:
			# Softer heading catch-up after a slide so the view eases back.
			_chase_dir = _chase_dir.slerp(motion_dir, 1.0 - exp(-1.45 * dt)).normalized()
		var chase := _chase_dir
		var yaw := _heading_yaw(chase, _heading_yaw(fwd)) + _orbit_yaw
		var cy := cos(_orbit_pitch)
		var look_dir := Vector3(-sin(yaw) * cy, sin(_orbit_pitch), -cos(yaw) * cy)
		var cam_pos: Vector3 = pivot_pt - look_dir * dist
		cam_pos.y = pivot_pt.y - look_dir.y * dist + height * 0.12
		# Same look target as orbit: the pivot itself (no look-ahead jump).
		var look_pt: Vector3 = pivot_pt
		var to_tgt := look_pt - cam_pos
		if to_tgt.length_squared() < 1e-8:
			to_tgt = chase if chase.length_squared() > 1e-8 else Vector3(0, 0, -1)
		var want_xf := Transform3D(Basis.looking_at(to_tgt, up_ref), cam_pos)
		_apply_vehicle_cam_xform(pivot, cam, want_xf, just_ready)
	cam.fov = 55.0 if k == "car" else 62.0
	cam.near = 0.15
	cam.current = true


func _apply_vehicle_cam_xform(pivot: Node3D, cam: Camera3D, xf: Transform3D, snap: bool = true) -> void:
	if _cam_pan.length_squared() > 1e-8:
		xf.origin += xf.basis.x * _cam_pan.x + xf.basis.y * _cam_pan.y
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
	_city_warming = false
	_room_ready = false
	_runway_cache.clear()
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
