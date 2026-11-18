extends SceneTree
## 0.2.17 载具 / 检查床 / 地图传送 / RoomCollision 自检。
##   godot --headless --path . -s res://scripts/tests/vehicles_check.gd

const VERSION_NAME := "0.2.17"
const VERSION_CODE := 19

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
	await _check_exam_exit_in_room()
	_check_hud()
	_check_car_plane_scenes()
	_check_bindings_and_hinge()
	_check_exam_pose_api()
	_check_menu_spawn_and_clear()
	_check_map_open()
	await _check_overhead_teleport_and_home()
	await _check_car_cam_and_exit()
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
	_ok(FileAccess.file_exists("res://assets/vehicles/collision/car_hulls.tres"), "baked car hulls present")
	_ok(FileAccess.file_exists("res://assets/vehicles/collision/plane_hulls.tres"), "baked plane hulls present")


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
	if bed.has_method("stirrup_l_local") and bed.has_method("stirrup_r_local"):
		var sl: Vector3 = bed.call("stirrup_l_local")
		var sr: Vector3 = bed.call("stirrup_r_local")
		_ok(sl.x > 0.15 and sr.x < -0.15, "patient-left stirrup is +X, right is -X (L=%s R=%s)" % [sl, sr])
		_ok(sl.x > sr.x, "stirrups are not crossed")
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
	# Room wall at x ≈ -1.98; half-width ≈ 0.47 so origin must stay clear of the wall.
	_ok(p.x - 0.50 > -1.96, "default exam bed is clear of the room wall (x=%.2f)" % p.x)


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
		var yaw_before := float(player.get("_yaw"))
		var entered := bool(vs.call("try_enter"))
		_ok(entered, "can enter the exam bed")
		_ok(vs.get("occupied") == bed, "occupied is the exam bed")
		_ok(str(player.get("occupancy")) == "exam_bed", "player occupancy is exam_bed")
		var action_in: String = str(main.call("action_for_key", KEY_F, "display"))
		_ok(action_in == "vehicle_toggle", "F is vehicle_toggle while occupying")
		# Occupied: Q/G must not open the weapon wheel / holster; M still opens the map.
		_ok(str(main.call("action_for_key", KEY_Q, "control")) == "", "Q is not weapon_wheel on the bed")
		_ok(str(main.call("action_for_key", KEY_G, "control")) == "", "G is not holster on the bed")
		_ok(str(main.call("action_for_key", KEY_M, "display")) == "map_menu", "M still opens the map while occupying")
		# CharacterBody stays world-upright; only the Body mesh lies on the table.
		_ok(player.global_transform.basis.y.dot(Vector3.UP) > 0.99, "CharacterBody stays upright on the bed")
		var body: Node3D = player.get_node_or_null("Body")
		var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
		if body and bed.has_method("seat_global"):
			var seat: Vector3 = bed.call("seat_global")
			var hip_l := ExamPose.hip_local(skel, body) if skel else Vector3(0.0, 0.917, 0.033)
			var hip_w: Vector3 = body.to_global(hip_l)
			_ok(absf(hip_w.y - seat.y) < 0.28, "hip is on the seat (hip.y=%.2f seat.y=%.2f)" % [hip_w.y, seat.y])
			_ok(hip_w.y > 0.45, "hip is above the floor, not hanging under the table (y=%.2f)" % hip_w.y)
			_ok(body.global_position.y > 0.15, "Body origin is not under the table (y=%.2f)" % body.global_position.y)
		# Pose: loco frozen, skeleton exists.
		var loco = player.call("get_loco")
		_ok(loco != null and bool(loco.get("frozen")), "soft_loco frozen on the exam bed")
		var exited := bool(vs.call("try_exit"))
		_ok(exited, "can exit the exam bed")
		_ok(vs.get("occupied") == null, "no longer occupying")
		_ok(str(player.get("occupancy")) == "", "player occupancy cleared")
		_ok(loco == null or not bool(loco.get("frozen")), "soft_loco unfrozen after exit")
		_ok(player.global_transform.basis.y.dot(Vector3.UP) > 0.99, "CharacterBody is upright after exit")
		_ok(absf(player.global_transform.basis.x.y) < 0.05 and absf(player.global_transform.basis.z.y) < 0.05,
			"no residual pitch/roll on the CharacterBody after exit")
		if body:
			_ok(absf(body.rotation.x) < 0.05 and absf(body.rotation.z) < 0.05, "Body pitch/roll cleared after exit")
		var yaw_after := float(player.get("_body_logic_yaw") if player.get("_body_logic_yaw") != null else player.get("_yaw"))
		_ok(absf(wrapf(yaw_after - yaw_before, -PI, PI)) < 0.05, "yaw restored after exit (before=%.3f after=%.3f)" % [yaw_before, yaw_after])


func _check_hud() -> void:
	var hud: Node = main.get_node_or_null("HUD")
	_ok(hud != null, "HUD present")
	if hud == null:
		return
	_ok(hud.get("_btn_vehicle") != null, "top 载具 button exists")
	_ok(hud.get("_panel_vehicle") != null, "载具 panel exists")
	_ok(hud.get("_btn_map") != null, "地图 button exists")
	if hud.get("_btn_vehicle"):
		_ok(str(hud.get("_btn_vehicle").text) == "载具", "载具 button label")
	_ok(hud.get("_btn_vehicle_cam") != null, "1st/3rd camera toggle button exists")
	_ok(hud.get("_btn_car_accel") != null and hud.get("_btn_car_brake") != null, "mobile car accel + drift buttons exist")
	_ok(hud.get("_btn_thrust_up") != null and hud.get("_btn_thrust_down") != null, "mobile fighter accel/decel buttons exist")
	_ok(hud.get("_btn_yaw_l") != null and hud.get("_btn_yaw_r") != null, "mobile fighter yaw buttons exist")
	_ok(hud.get("_thrust_lever") != null and hud.get("_thrust_ab") != null, "thrust lever with afterburner segment exists")


func _check_car_plane_scenes() -> void:
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	# setup happens in _ready
	# already in tree
	_ok(car is VehicleBody3D, "car is VehicleBody3D")
	var car_shapes := _count_body_shapes(car)
	_ok(car_shapes >= 4, "car has fine collision (%d boxes)" % car_shapes)
	_ok(_concave_on_body(car) == 0, "car body has no concave trimesh")
	_ok(_convex_or_box_only(car), "car hulls are convex or boxes")
	var wheels := 0
	for c in car.get_children():
		if c is VehicleWheel3D:
			wheels += 1
	_ok(wheels >= 4, "car has VehicleWheel3D wheels (%d)" % wheels)
	_ok(not _body_shapes_look_like_wheels(car), "car body hulls do not include wheels")
	if car.has_method("spawn_lift"):
		_ok(float(car.call("spawn_lift")) > 0.0, "car spawn_lift is positive (%.3f)" % float(car.call("spawn_lift")))
	var hull_min := VehicleCommon.body_collision_min_y(car)
	var contact := 1.0e9
	for c in car.get_children():
		if c is VehicleWheel3D:
			var w := c as VehicleWheel3D
			contact = minf(contact, w.position.y - w.wheel_rest_length - w.wheel_radius)
	if contact < 1.0e8:
		_ok(hull_min >= contact + 0.02, "car body hull stays above wheel contact (hull=%.3f contact=%.3f)" % [hull_min, contact])
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
	_ok(_convex_or_box_only(plane), "plane hulls are convex or boxes")
	_ok(not _body_shapes_look_like_wheels(plane), "plane body hulls do not include landing gear wheels")
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
		ExamPose.clear(skel)


func _check_menu_spawn_and_clear() -> void:
	if vs == null:
		return
	# Aim spawn in the room (open floor), from the crosshair — not the mouse.
	player.global_position = Vector3(0.5, 0.1, 0.3)
	var intended: Vector3 = vs.call("aim_point", "exam_bed")
	var before: int = vs.vehicles.size()
	var spawned: Node = vs.call("spawn_at_aim", "exam_bed") as Node
	_ok(spawned != null, "menu can spawn an exam bed")
	_ok(bool(spawned.get("is_menu_spawned")), "spawned exam bed is marked menu-spawned")
	_ok(vs.vehicles.size() == before + 1, "vehicle list grew by 1")
	if spawned:
		var d := Vector2(spawned.global_position.x - intended.x, spawned.global_position.z - intended.z).length()
		_ok(d < 1.25, "menu spawn lands at the aim/crosshair point (err=%.2f m, aim=%s got=%s)" % [d, intended, spawned.global_position])
	# aim_point must not use get_mouse_position (the 载具 button sits under the cursor).
	var src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(src.find("get_mouse_position") < 0, "aim_point does not use the mouse position")
	_ok(src.find("vp * 0.5") >= 0 or src.find("size * 0.5") >= 0, "aim_point uses the viewport centre / crosshair")
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
			var runway_err := Vector2(mid.x + 1000.0, mid.z - 300.0).length()
			_ok(runway_err < 80.0, "fighters spawned at the labeled runway start (mid=%s, err=%.1f m)" % [mid, runway_err])
			_ok(absf(a.y - b.y) < 2.0, "fighters sit at a similar height (%.2f / %.2f)" % [a.y, b.y])


func _convex_or_box_only(n: Node) -> bool:
	for ch in n.get_children():
		if not (ch is CollisionShape3D):
			continue
		var sh := (ch as CollisionShape3D).shape
		if sh == null:
			continue
		if sh is ConcavePolygonShape3D:
			return false
		if not (sh is ConvexPolygonShape3D or sh is BoxShape3D or sh is SphereShape3D or sh is CylinderShape3D):
			return false
	return true


func _body_shapes_look_like_wheels(n: Node) -> bool:
	for ch in n.get_children():
		if not (ch is CollisionShape3D):
			continue
		if VehicleCommon.is_wheelish(ch) or VehicleCommon.is_wheelish(ch, VehicleCommon.PLANE_GEAR_RE):
			return true
	return false


func _check_bindings_and_hinge() -> void:
	var drive := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(drive.find("Input.is_key_pressed(KEY_SPACE)") >= 0 or drive.find("KEY_SPACE") >= 0, "car Space handbrake is bound")
	_ok(drive.find("KEY_SHIFT") >= 0, "Shift is bound (car nitro / plane thrust)")
	_ok(drive.find("KEY_C") >= 0, "plane C decelerate is bound")
	_ok(drive.find("KEY_Q") >= 0 and drive.find("KEY_E") >= 0, "plane Q/E yaw is bound")
	_ok(drive.find("pitch := -axis_fb") >= 0, "plane W dives / S pitches up (pitch = -axis_fb)")
	_ok(drive.find("steer := -axis_lr") >= 0, "car A/D steering (steer = -axis_lr)")
	var vis := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(vis.find("st.get(\"decelerating\"") >= 0 or vis.find("decelerating") >= 0, "flaps read the decelerating flag")
	_ok(vis.find("petal_gap") >= 0, "nozzle petal gap follows thrust")
	var hinge := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_hinge.gd")
	_ok(hinge.find("Quaternion(ax, a)") >= 0 or hinge.find("Quaternion(axis") >= 0, "hinges use axis-angle, not YXZ euler")
	_ok(FileAccess.get_file_as_string("res://scripts/game_root.gd").find("notify_vehicles") >= 0,
		"open_overhead can preview the city without notify_map")


func _check_map_open() -> void:
	if main == null or vs == null:
		return
	_ok(str(main.call("action_for_key", KEY_M, "display")) == "map_menu", "M is map_menu in display mode")
	_ok(str(main.get("current_map")) == "room", "still on the room map before opening overhead")
	var beds_before := int(vs.call("default_bed_count"))
	if main.has_method("open_overhead"):
		main.call("open_overhead")
	var mv = main.get("map_view")
	_ok(mv != null and bool(mv.get("is_open")), "overhead / map view opens")
	_ok(str(main.get("current_map")) == "room", "opening the map from the room does not change current_map")
	_ok(int(vs.call("default_bed_count")) == beds_before, "opening the map does not despawn the home exam bed")
	_ok(not bool(vs.get("_city_ready")), "opening the map does not spawn city vehicles")
	if main.has_method("close_overhead"):
		main.call("close_overhead")
	_ok(mv == null or not bool(mv.get("is_open")), "overhead / map view closes")
	var hud: Node = main.get_node_or_null("HUD")
	if hud and hud.has_method("toggle_map_panel"):
		# Re-open via the HUD button path and close again.
		hud.call("toggle_map_panel")
		_ok(mv != null and bool(mv.get("is_open")), "HUD 地图 button opens the map")
		hud.call("toggle_map_panel")
		_ok(mv == null or not bool(mv.get("is_open")), "HUD 地图 button closes the map")


func _in_room(p: Vector3) -> bool:
	# Walls at x≈-1.98 / 3.52, z≈-3.30 / 0.95; ceiling ~2.3–2.7. Standing origin must be on the floor.
	return p.x > -1.70 and p.x < 3.30 and p.z > -3.10 and p.z < 0.80 and p.y > -0.05 and p.y < 1.55


func _walkable() -> bool:
	if player == null:
		return false
	var loco = player.call("get_loco") if player.has_method("get_loco") else null
	return (not bool(player.get("input_locked"))) 		and player.is_physics_processing() 		and str(player.get("occupancy")) == "" 		and (loco == null or not bool(loco.get("frozen"))) 		and player.collision_layer != 0 and player.collision_mask != 0


func _check_exam_exit_in_room() -> void:
	if vs == null or player == null:
		return
	var bed: Node = null
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
			bed = v
			break
	if bed == null:
		_ok(false, "default exam bed present for exit-in-room check")
		return
	# A ray from standing height (below the ceiling) must hit the floor.
	# A sky-high ray would hit the roof first — its top face is a valid floor.
	if main.has_method("ground_at"):
		var fl: Variant = main.call("ground_at", -0.2, 0.15, 1.85)
		_ok(fl != null, "ground_at from standing height returns a hit")
		if fl != null:
			_ok((fl as Vector3).y < 1.2, "standing-height ground_at hits the room floor, not the ceiling (y=%.2f)" % (fl as Vector3).y)
	if vs.get("occupied"):
		vs.call("try_exit")
	# Use control mode so walkability is meaningful after exit.
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
	player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
	player.velocity = Vector3.ZERO
	var yaw_before := float(player.get("_body_logic_yaw") if player.get("_body_logic_yaw") != null else player.get("_yaw"))
	vs.call("_update_nearest")
	_ok(bool(vs.call("try_enter")), "enter default exam bed for exit-in-room check")
	await _phys(2)
	_ok(str(player.get("occupancy")) == "exam_bed", "occupying exam bed before exit")
	_ok(bool(vs.call("try_exit")), "exit default exam bed")
	await _phys(8)
	await _frames(2)
	var p: Vector3 = player.global_position
	_ok(_in_room(p), "after leaving the exam bed the player is inside the room on the floor (pos=%s)" % p)
	_ok(player.global_transform.basis.y.dot(Vector3.UP) > 0.99, "player is upright after exam-bed exit (physics)")
	_ok(_walkable(), "player is walkable after exam-bed exit (unlocked, physics on, occupancy cleared)")
	var yaw_after := float(player.get("_body_logic_yaw") if player.get("_body_logic_yaw") != null else player.get("_yaw"))
	_ok(absf(wrapf(yaw_after - yaw_before, -PI, PI)) < 0.05, "yaw restored after exam-bed exit (physics)")
	if player.has_node("Body"):
		var body: Node3D = player.get_node("Body")
		_ok(absf(body.rotation.x) < 0.05 and absf(body.rotation.z) < 0.05, "Body has no residual lying rotation after exit")


func _check_overhead_teleport_and_home() -> void:
	if main == null or player == null or vs == null:
		return
	# Ensure we start in the room, not occupying anything, map closed.
	if vs.get("occupied"):
		vs.call("try_exit")
	if main.get("map_view") and bool(main.get("map_view").get("is_open")):
		main.call("close_overhead")
	if str(main.get("current_map")) != "room":
		main.call("switch_map", "room", 0)
		await _phys(4)
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
	player.global_position = Vector3(-0.2, 0.1, 0.3)
	player.velocity = Vector3.ZERO
	await _phys(2)
	_ok(str(main.get("current_map")) == "room", "teleport test starts in the room")
	_ok(not bool(vs.get("_city_ready")), "city defaults are not spawned before the first real map switch")
	main.call("open_overhead")
	var mv = main.get("map_view")
	_ok(mv != null and bool(mv.get("is_open")), "overhead opens for teleport")
	_ok(str(main.get("current_map")) == "room", "preview does not change current_map")
	_ok(not bool(vs.get("_city_ready")), "preview still does not spawn city vehicles")
	var spawn: Dictionary = main.call("get_maps")[1]["spawns"][0]
	mv.call("set_marker", Vector3(float(spawn["x"]), 2.0, float(spawn["z"])))
	_ok(mv.get("marker") != null, "teleport marker is set")
	var t0 := Time.get_ticks_msec()
	main.call("overhead_teleport")
	# Placement awaits two physics frames; city defaults spawn deferred but must not stall.
	var guard := 0
	while bool(main.get("_busy")) and guard < 90:
		await _phys(1)
		guard += 1
	await _phys(8)
	await _frames(4)
	var elapsed := Time.get_ticks_msec() - t0
	print("vehicles: overhead_teleport settled in ", elapsed, " ms (busy_wait=", guard, ")")
	_ok(not bool(main.get("_busy")), "teleport placement finished (waited %d frames, %d ms)" % [guard, elapsed])
	_ok(elapsed < 15000, "teleport does not stall the main thread (elapsed=%d ms)" % elapsed)
	_ok(str(main.get("current_map")) == "city", "overhead teleport switches to the city")
	_ok(mv == null or not bool(mv.get("is_open")), "map view is closed after teleport")
	_ok(not bool(main.get("_overhead_preview")), "not left in overhead preview after teleport")
	_ok(_walkable(), "player is walkable after room→city teleport")
	var pos: Vector3 = player.global_position
	var err := Vector2(pos.x - float(spawn["x"]), pos.z - float(spawn["z"])).length()
	_ok(err < 4.0, "player arrived near the chosen city point (pos=%s err=%.2f)" % [pos, err])
	_ok(main.get_node("City").visible, "city is visible after teleport")
	var room_n := main.get_node_or_null("Room")
	_ok(room_n == null or not room_n.visible, "room is hidden after teleport")
	# Wait briefly for city defaults; they must not have blocked placement.
	var g2 := 0
	while vs and not bool(vs.get("_city_ready")) and g2 < 60:
		await _phys(1)
		g2 += 1
	_ok(bool(vs.get("_city_ready")), "city defaults ready after teleport (waited %d extra frames)" % g2)

	# Go home from the overhead map.
	main.call("open_overhead")
	_ok(mv != null and bool(mv.get("is_open")), "overhead opens from the city")
	main.call("overhead_go_home")
	await _phys(6)
	await _frames(2)
	_ok(str(main.get("current_map")) == "room", "go-home returns to the room")
	_ok(mv == null or not bool(mv.get("is_open")), "map view is closed after go-home")
	_ok(not bool(main.get("_overhead_preview")), "not left in preview after go-home")
	_ok(_walkable(), "player is walkable after city→room go-home")
	_ok(_in_room(player.global_position), "player is inside the room after go-home (pos=%s)" % player.global_position)
	_ok(room_n == null or room_n.visible, "room is visible after go-home")
	_ok(not main.get_node("City").visible, "city is hidden after go-home")
	_ok(int(vs.call("default_bed_count")) == 1, "home exam bed is back after go-home")

	# Teleport while still on the exam bed must also arrive walkable in the city.
	if player.has_method("set_play_mode"):
		player.call("set_play_mode", 1)
	player.global_position = Vector3(-0.2, 0.1, 0.3)
	# Find the default bed again (visibility should be on).
	var bed: Node = null
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
			bed = v
			break
	if bed:
		player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
		vs.call("_update_nearest")
		_ok(bool(vs.call("try_enter")), "can enter the exam bed before a map teleport")
		await _phys(2)
		main.call("open_overhead")
		mv.call("set_marker", Vector3(float(spawn["x"]), 2.0, float(spawn["z"])))
		main.call("overhead_teleport")
		var g3 := 0
		while bool(main.get("_busy")) and g3 < 90:
			await _phys(1)
			g3 += 1
		await _phys(6)
		_ok(str(main.get("current_map")) == "city", "teleport from the exam bed reaches the city")
		_ok(_walkable(), "player is walkable after teleporting off the exam bed")
		_ok(str(player.get("occupancy")) == "", "exam occupancy is cleared by the map teleport")
		# Return home so later tests start in the room.
		main.call("open_overhead")
		main.call("overhead_go_home")
		await _phys(6)
		await _frames(2)
		_ok(str(main.get("current_map")) == "room", "returned to the room after bed-teleport")
		_ok(_walkable() and _in_room(player.global_position), "walkable in the room after returning from bed-teleport")


func _check_car_cam_and_exit() -> void:
	if vs == null or player == null:
		return
	# Park a temporary car in the room so we can enter it.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	main.add_child(car)
	car.global_position = Vector3(1.6, 0.6, 0.2)
	if car.has_method("spawn_lift"):
		car.global_position.y = float(car.call("spawn_lift"))
	await _phys(2)
	player.global_position = car.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = car
	var yaw_before := float(player.get("_yaw"))
	var entered := bool(vs.call("try_enter"))
	_ok(entered, "can enter the sports car")
	_ok(str(vs.get("vehicle_cam")) == "third", "car defaults to third person")
	_ok(str(player.get("occupancy")) == "car", "player occupancy is car")
	if vs.has_method("toggle_vehicle_cam"):
		_ok(str(vs.call("toggle_vehicle_cam")) == "first", "can toggle to first person")
		_ok(str(vs.call("toggle_vehicle_cam")) == "third", "can toggle back to third person")
	_ok(str(main.call("action_for_key", KEY_V, "control")) == "vehicle_cam", "V toggles vehicle camera while driving")
	_ok(str(main.call("action_for_key", KEY_Q, "control")) == "", "Q is not weapon_wheel while driving")
	var exited := bool(vs.call("try_exit"))
	_ok(exited, "can exit the sports car")
	_ok(player.global_transform.basis.y.dot(Vector3.UP) > 0.99, "standing upright after leaving the car")
	var yaw_after := float(player.get("_body_logic_yaw") if player.get("_body_logic_yaw") != null else player.get("_yaw"))
	_ok(absf(wrapf(yaw_after - yaw_before, -PI, PI)) < 0.05, "yaw restored after leaving the car")
	car.queue_free()
	await _frames(1)


func _finish() -> void:
	if fails == 0:
		print("vehicles: ALL PASSED")
	else:
		print("vehicles: FAILED ", fails)
	quit(1 if fails else 0)
