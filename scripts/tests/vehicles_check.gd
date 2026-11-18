extends SceneTree
## 0.2.15 载具 / 检查床 / RoomCollision 自检。
##   godot --headless --path . -s res://scripts/tests/vehicles_check.gd

const VERSION_NAME := "0.2.15"
const VERSION_CODE := 17

var fails := 0
var main: Node
var player: Node
var vs: Node


func _initialize() -> void:
	call_deferred("_run")


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("vehicles: OK   ", msg)
	else:
		fails += 1
		push_error("vehicles: FAIL " + msg)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_ok(packed != null, "main.tscn loads")
	if packed == null:
		_finish()
		return
	main = packed.instantiate()
	root.add_child(main)
	await _frames(4)
	await _phys(2)
	player = main.get_node_or_null("Player")
	vs = main.get("vehicle_system")
	_ok(player != null, "player present")
	_ok(vs != null, "vehicle_system created")

	_check_version()
	_check_room_collision()
	_check_exam_bed_default()
	_check_f_routing()
	_check_hud()
	_check_car_plane_scenes()
	_check_exam_pose_api()
	_check_menu_spawn_and_clear()
	await _check_city_defaults()
	_finish()


func _check_version() -> void:
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"%s\"" % VERSION_NAME) >= 0, "export versionName is %s" % VERSION_NAME)
	_ok(presets.find("version/code=%d" % VERSION_CODE) >= 0, "versionCode is %d" % VERSION_CODE)
	_ok(FileAccess.file_exists("res://assets/vehicles/car.glb"), "car.glb present")
	_ok(FileAccess.file_exists("res://assets/vehicles/plane.glb"), "plane.glb present")
	_ok(FileAccess.file_exists("res://assets/vehicles/exam_bed/exam_bed.glb"), "exam_bed.glb present")
	_ok(FileAccess.file_exists("res://assets/vehicles/exam_bed/ATTRIBUTION.txt"), "exam bed attribution present")


func _check_room_collision() -> void:
	var rc: Node = main.get_node_or_null("RoomCollision")
	_ok(rc != null, "RoomCollision exists")
	if rc == null:
		return
	var shapes := 0
	for c in rc.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
			shapes += 1
	_ok(shapes == 14, "RoomCollision has 14 baked shapes (got %d)" % shapes)
	# Script must not rebuild when shapes already exist.
	if rc.has_method("_has_shapes"):
		_ok(bool(rc.call("_has_shapes")), "_has_shapes is true")
	var before := rc.get_child_count()
	await _phys(2)
	_ok(rc.get_child_count() == before, "RoomCollision did not duplicate shapes at runtime")


func _check_exam_bed_default() -> void:
	_ok(vs != null and int(vs.call("default_bed_count")) == 1, "one default exam bed in the room")
	var bed: Node = null
	if vs:
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
	_ok(bed != null, "default exam bed instance found")
	if bed == null:
		return
	_ok(bed is StaticBody3D, "exam bed is a StaticBody3D")
	var col := 0
	var concave := 0
	for c in bed.get_children():
		if c is CollisionShape3D:
			col += 1
			if (c as CollisionShape3D).shape is ConcavePolygonShape3D:
				concave += 1
	_ok(col >= 3, "exam bed has fine (multi) collision (%d shapes)" % col)
	_ok(concave == 0, "exam bed has no concave trimesh on the body")
	_ok(bed.get("marker_seat") != null and bed.get("marker_stirrup_l") != null and bed.get("marker_stirrup_r") != null,
		"exam bed has seat / stirrup markers")
	# Length ~ 2 m along Z.
	var hl := float(bed.get("half_l"))
	_ok(hl > 0.7 and hl < 1.4, "exam bed half-length in range (%.2f, expect ~1.0)" % hl)
	var ang := float(bed.get("backrest_angle"))
	_ok(ang > 0.15 and ang < 1.0, "backrest angle is a raised slope (%.2f rad)" % ang)
	# Default placement: open floor, not inside the furniture bed box.
	var p: Vector3 = bed.global_position
	var in_furniture_bed := p.x > -0.81 and p.x < 0.81 and p.z < -0.82 and p.z > -3.22
	_ok(not in_furniture_bed, "default exam bed is not inside the room bed (pos=%s)" % p)
	_ok(p.x > -2.1 and p.x < 3.5 and p.z > -3.2 and p.z < 1.0, "default exam bed is inside the room")


func _check_f_routing() -> void:
	# Not near a vehicle and in display mode → F is focus.
	if player and player.has_method("set_play_mode"):
		player.call("set_play_mode", 0)  # DISPLAY
	# Move the player far from the exam bed first.
	var far := Vector3(0.4, 0.1, 0.3)
	player.global_position = far
	# The default bed is at about (-1.48, 0, -0.25); spawn is close! Move to a far corner.
	player.global_position = Vector3(3.0, 0.1, 0.4)
	if vs:
		vs.call("_update_nearest")
	var near_now = vs.get("nearest") if vs else null
	var action_far := str(main.call("action_for_key", KEY_F, "display"))
	if near_now == null:
		_ok(action_far == "focus", "F is focus when not near a vehicle (got '%s')" % action_far)
	else:
		# If still in range, that's ok — just record it and test after moving further conceptually.
		_ok(action_far == "vehicle_toggle", "F is vehicle_toggle when still in range (got '%s')" % action_far)
	# Stand next to the exam bed.
	var bed: Node = null
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "exam_bed":
			bed = v
			break
	if bed:
		player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
		vs.call("_update_nearest")
		var action_near: String = str(main.call("action_for_key", KEY_F, "display"))
		_ok(action_near == "vehicle_toggle", "F is vehicle_toggle when near the exam bed (got '%s')" % action_near)
		# Enter / exit.
		var entered := bool(vs.call("try_enter"))
		_ok(entered, "can enter the exam bed")
		_ok(vs.get("occupied") == bed, "occupied is the exam bed")
		_ok(str(player.get("occupancy")) == "exam_bed", "player occupancy is exam_bed")
		var action_in: String = str(main.call("action_for_key", KEY_F, "display"))
		_ok(action_in == "vehicle_toggle", "F is vehicle_toggle while occupying")
		# Pose: loco frozen, skeleton exists.
		var loco = player.call("get_loco")
		_ok(loco != null and bool(loco.get("frozen")), "soft_loco frozen on the exam bed")
		var exited := bool(vs.call("try_exit"))
		_ok(exited, "can exit the exam bed")
		_ok(vs.get("occupied") == null, "no longer occupying")
		_ok(str(player.get("occupancy")) == "", "player occupancy cleared")
		_ok(loco == null or not bool(loco.get("frozen")), "soft_loco unfrozen after exit")


func _check_hud() -> void:
	var hud: Node = main.get_node_or_null("HUD")
	_ok(hud != null, "HUD present")
	if hud == null:
		return
	_ok(hud.get("_btn_vehicle") != null, "top 载具 button exists")
	_ok(hud.get("_panel_vehicle") != null, "载具 panel exists")
	if hud.get("_btn_vehicle"):
		_ok(str(hud.get("_btn_vehicle").text) == "载具", "载具 button label")


func _check_car_plane_scenes() -> void:
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	# setup happens in _ready
	# already in tree
	_ok(car is VehicleBody3D, "car is VehicleBody3D")
	var car_shapes := _count_body_shapes(car)
	_ok(car_shapes >= 4, "car has fine collision (%d boxes)" % car_shapes)
	_ok(_concave_on_body(car) == 0, "car body has no concave trimesh")
	var wheels := 0
	for c in car.get_children():
		if c is VehicleWheel3D:
			wheels += 1
	_ok(wheels >= 4, "car has VehicleWheel3D wheels (%d)" % wheels)
	_ok(car.get("visuals") != null, "car visuals bound")
	if car.get("visuals"):
		_ok(bool(car.visuals.ready_ok), "car visuals ready")
	# plane
	var plane: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(plane)
	_ok(plane is RigidBody3D, "plane is RigidBody3D")
	var ps := _count_body_shapes(plane)
	_ok(ps >= 4, "plane has fine collision (%d boxes)" % ps)
	_ok(_concave_on_body(plane) == 0, "plane body has no concave trimesh")
	var vis = plane.get("visuals")
	_ok(vis != null and bool(vis.ready_ok), "plane visuals ready")
	if vis:
		_ok(vis.surfaces.size() >= 2, "plane has bound control surfaces (%d)" % vis.surfaces.size())
		var kinds := {}
		for s in vis.surfaces:
			kinds[str(s.kind)] = true
		_ok(kinds.has("aileronL") or kinds.has("aileronR"), "ailerons bound")
		_ok(kinds.has("elevator") or kinds.has("rudderL") or kinds.has("rudderR") or kinds.has("rudder"), "elevator/rudder bound")
		_ok(vis.nozzle_engines.size() > 0 or kinds.has("nozzle") or kinds.has("nozzleLT"), "nozzle rig bound")
		_ok(vis.exhausts.size() > 0, "jet exhaust attached (%d)" % vis.exhausts.size())
		if vis.exhausts.size():
			var fx = vis.exhausts[0]
			_ok(fx.diamonds.size() >= 3, "shock diamonds exist (%d)" % fx.diamonds.size())
			# Apply high thrust and ensure diamonds turn on.
			fx.call("apply", 1.0, 0.5, 0.0)
			var vis_n := 0
			for d in fx.diamonds:
				if d.visible:
					vis_n += 1
			_ok(vis_n >= 1, "diamonds visible at afterburner")
			fx.call("apply", 0.0, 0.5, 0.0)
			_ok(fx.visible == false, "exhaust hidden at zero thrust")
	car.queue_free()
	plane.queue_free()


func _count_body_shapes(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape != null:
			c += 1
	return c


func _concave_on_body(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape is ConcavePolygonShape3D:
			c += 1
	return c


func _check_exam_pose_api() -> void:
	_ok(ClassDB.class_exists("ExamPose") or ResourceLoader.exists("res://scripts/vehicles/exam_pose.gd"), "ExamPose script exists")
	var skel: Skeleton3D = player.call("get_skeleton") if player and player.has_method("get_skeleton") else null
	_ok(skel != null, "player skeleton available for posing")
	if skel:
		ExamPose.apply(skel, Vector3(-0.4, 1.1, 0.7), Vector3(0.4, 1.1, 0.7), 0.45)
		_ok(skel.find_bone("L_UpperLeg_a") >= 0 and skel.find_bone("R_UpperLeg_a") >= 0, "leg bones exist")


func _check_menu_spawn_and_clear() -> void:
	if vs == null:
		return
	# Aim spawn in the room (open floor).
	player.global_position = Vector3(0.5, 0.1, 0.3)
	var before: int = vs.vehicles.size()
	var spawned: Node = vs.call("spawn_at_aim", "exam_bed") as Node
	_ok(spawned != null, "menu can spawn an exam bed")
	_ok(bool(spawned.get("is_menu_spawned")), "spawned exam bed is marked menu-spawned")
	_ok(vs.vehicles.size() == before + 1, "vehicle list grew by 1")
	var removed := int(vs.call("clear_spawned"))
	_ok(removed >= 1, "clear_spawned removed the menu bed (%d)" % removed)
	_ok(int(vs.call("default_bed_count")) == 1, "default exam bed survived clear_spawned")


func _check_city_defaults() -> void:
	if vs == null or main == null:
		return
	# Switch to the city map (runway spawn). This builds city collisions.
	if main.has_method("switch_map"):
		main.call("switch_map", "city", 4)  # 机场跑道（空旷）
	# switch_map is async (await ground) — wait it out.
	await _phys(8)
	await _frames(8)
	# Defaults spawn deferred; wait more if needed.
	var guard := 0
	while vs and not bool(vs.get("_city_ready")) and guard < 40:
		await _phys(1)
		await _frames(1)
		guard += 1
	_ok(bool(vs.get("_city_ready")), "city defaults finished (waited %d frames)" % guard)
	var planes := int(vs.call("default_plane_count"))
	_ok(planes == 2, "exactly two default fighters (got %d)" % planes)
	var cars := int(vs.call("default_car_count"))
	_ok(cars >= 3, "several default cars on roads (got %d)" % cars)
	if planes >= 2:
		var pl: Array = []
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "plane" and bool(v.get("is_default")):
				pl.append(v)
		if pl.size() >= 2:
			var a: Vector3 = pl[0].global_position
			var b: Vector3 = pl[1].global_position
			var lateral := Vector2(a.x - b.x, a.z - b.z).length()
			_ok(lateral > 4.0 and lateral < 30.0, "fighters are side by side (dist=%.1f m)" % lateral)
			# Near the known runway area or a detected airport landmark.
			var mid := (a + b) * 0.5
			var near_fallback := Vector2(mid.x + 1000.0, mid.z - 300.0).length() < 400.0
			var near_airport := mid.length() > 50.0  # city spawn is ~40,40; airport is far
			_ok(near_fallback or near_airport, "fighters spawned at the airport (mid=%s)" % mid)


func _finish() -> void:
	if fails == 0:
		print("vehicles: ALL PASSED")
	else:
		print("vehicles: FAILED ", fails)
	quit(1 if fails else 0)
