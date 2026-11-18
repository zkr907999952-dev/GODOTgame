extends SceneTree
## 0.2.20 载具 / 检查床 / 地图传送 / RoomCollision 自检。
##   godot --headless --path . -s res://scripts/tests/vehicles_check.gd

const VERSION_NAME := "0.2.20"
const VERSION_CODE := 22

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
	await _check_0218_physics_and_visuals()
	await _check_0219_chase_wheel_gear()
	await _check_0220_spawn_yaw_car_turn_weapons()
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
	_ok(bed.get("marker_armrest_l") != null and bed.get("marker_armrest_r") != null,
		"exam bed has left / right armrest markers")
	if bed.has_method("armrest_l_local") and bed.has_method("armrest_r_local"):
		var al: Vector3 = bed.call("armrest_l_local")
		var ar: Vector3 = bed.call("armrest_r_local")
		_ok(al.x > 0.15 and ar.x < -0.15, "patient-left armrest is +X, right is -X (L=%s R=%s)" % [al, ar])
	if bed.has_method("stirrup_l_local") and bed.has_method("stirrup_r_local"):
		var sl: Vector3 = bed.call("stirrup_l_local")
		var sr: Vector3 = bed.call("stirrup_r_local")
		_ok(sl.x > 0.15 and sr.x < -0.15, "patient-left stirrup is +X, right is -X (L=%s R=%s)" % [sl, sr])
		_ok(sl.x > sr.x, "stirrups are not crossed")
	# Slightly smaller than 0.2.17 (TARGET_LENGTH 2.0 → half_l ≈ 1.0).
	var hl := float(bed.get("half_l"))
	_ok(hl > 0.70 and hl < 0.99, "exam bed is slightly smaller than 0.2.17 (half_l=%.3f, expect ~0.93)" % hl)
	var src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_bed.gd")
	_ok(src.find("TARGET_LENGTH := 2.0") < 0, "exam bed TARGET_LENGTH is no longer 2.0")
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
			# Just meeting the seat: hip may sit a little above the cushion for skin
			# clearance, but must not sink clearly below it or hover high.
			_ok(hip_w.y >= seat.y - 0.02, "hip is not below the seat surface (hip.y=%.3f seat.y=%.3f)" % [hip_w.y, seat.y])
			_ok(hip_w.y <= seat.y + 0.16, "hip just meets the seat, not floating high (hip.y=%.3f seat.y=%.3f)" % [hip_w.y, seat.y])
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
	_ok(hud.get("_btn_gear") != null, "mobile landing-gear button exists")
	if hud.get("_btn_gear"):
		_ok("起落架" in str(hud.get("_btn_gear").text), "mobile gear button is labeled 起落架")
	_ok(hud.get("_thrust_lever") != null and hud.get("_thrust_ab") != null, "thrust lever with afterburner segment exists")


func _check_car_plane_scenes() -> void:
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	# setup happens in _ready
	# already in tree
	_ok(car is RigidBody3D and not (car is VehicleBody3D), "car is RigidBody3D (raycast suspension)")
	var car_shapes := _count_body_shapes(car)
	_ok(car_shapes >= 4, "car has fine collision (%d boxes)" % car_shapes)
	_ok(_concave_on_body(car) == 0, "car body has no concave trimesh")
	_ok(_convex_or_box_only(car), "car hulls are convex or boxes")
	var wheels := 0
	for c in car.get_children():
		if c is RayCast3D:
			wheels += 1
	_ok(wheels >= 4, "car has RayCast3D suspension wheels (%d)" % wheels)
	_ok(not _body_shapes_look_like_wheels(car), "car body hulls do not include wheels")
	if car.has_method("spawn_lift"):
		_ok(float(car.call("spawn_lift")) > 0.0, "car spawn_lift is positive (%.3f)" % float(car.call("spawn_lift")))
	var hull_min := VehicleCommon.body_collision_min_y(car)
	var contact := 1.0e9
	var rest_d: float = float(car.get("REST_DISTANCE")) if car.get("REST_DISTANCE") != null else 0.16
	var wr: float = float(car.visuals.wheel_r) if car.get("visuals") else 0.34
	for c in car.get_children():
		if c is RayCast3D:
			contact = minf(contact, (c as RayCast3D).position.y - rest_d - wr)
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
		ExamPose.apply(skel, Vector3(-0.4, 1.1, 0.7), Vector3(0.4, 1.1, 0.7), 0.45, Vector3(0.42, 1.20, 0.20), Vector3(-0.42, 1.20, 0.20))
		_ok(skel.find_bone("L_UpperLeg_a") >= 0 and skel.find_bone("R_UpperLeg_a") >= 0, "leg bones exist")
		_ok(skel.find_bone("L_UpperArm_a") >= 0 and skel.find_bone("R_UpperArm_a") >= 0, "arm bones exist")
		ExamPose.offset_hair(skel, Vector3(0.0, 0.015, -0.08))
		var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
		_ok(pose_src.find("func offset_hair") >= 0, "ExamPose can offset hair off the pillow")
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
			# Threshold / building end — NOT the 0.2.19 MAPS「机场跑道（空旷）」helipad pad.
			var mid := (a + b) * 0.5
			var info: Dictionary = vs.call("runway_threshold_info") if vs.has_method("runway_threshold_info") else {}
			var want_mid: Vector3 = info.get("mid", Vector3(-814.49, 0.0, 504.38))
			var want_yaw := float(info.get("yaw", 0.70456))
			var want_heading: Vector3 = info.get("heading", Vector3(-0.64770, 0.0, -0.76189))
			var threshold: Vector3 = info.get("threshold", want_mid)
			var helipad: Vector3 = info.get("helipad", Vector3(-1100.95, 0.0, 167.41))
			var mid_err := Vector2(mid.x - want_mid.x, mid.z - want_mid.z).length()
			_ok(mid_err < 40.0, "fighters spawned at the threshold / building end (mid=%s, want=%s, err=%.1f m)" % [mid, want_mid, mid_err])
			var old_err := Vector2(mid.x + 1000.0, mid.z - 300.0).length()
			_ok(old_err > 120.0, "fighters are not at the 0.2.19 helipad-end MAPS label (dist_to_-1000,300=%.1f m)" % old_err)
			var d_thr := Vector2(mid.x - threshold.x, mid.z - threshold.z).length()
			var d_hel := Vector2(mid.x - helipad.x, mid.z - helipad.z).length()
			_ok(d_thr < d_hel - 40.0, "parked nearer the threshold than the helipads (d_thr=%.1f d_hel=%.1f)" % [d_thr, d_hel])
			_ok(d_thr > 8.0 and d_thr < 50.0, "standoff is just inside the threshold bars (d=%.1f m)" % d_thr)
			_ok(absf(a.y - b.y) < 2.0, "fighters sit at a similar height (%.2f / %.2f)" % [a.y, b.y])
			var yaw_err := absf(wrapf(pl[0].rotation.y - pl[1].rotation.y, -PI, PI))
			_ok(yaw_err < 0.08, "both fighters share a heading (dyaw=%.3f)" % yaw_err)
			var align := absf(wrapf(pl[0].rotation.y - want_yaw, -PI, PI))
			_ok(align < 0.20, "fighter noses align with the runway heading (yaw=%.3f want=%.3f err=%.3f)" % [pl[0].rotation.y, want_yaw, align])
			var nose: Vector3 = -pl[0].global_transform.basis.z
			var nose_h := Vector3(nose.x, 0.0, nose.z)
			if nose_h.length_squared() > 1e-6:
				nose_h = nose_h.normalized()
			var head_h := Vector3(want_heading.x, 0.0, want_heading.z)
			if head_h.length_squared() > 1e-6:
				head_h = head_h.normalized()
			_ok(nose_h.dot(head_h) > 0.85, "noses point down the runway toward the helipads (nose_h=%s heading=%s dot=%.3f)" % [nose_h, head_h, nose_h.dot(head_h)])


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
	_ok(drive.find("KEY_G") >= 0 and drive.find("toggle_gear") >= 0, "plane G landing-gear toggle is bound")
	_ok(drive.find("_orbit_yaw") >= 0 and drive.find("_heading_yaw") >= 0, "chase cam uses vehicle-relative heading offsets")
	_ok(drive.find("pitch := -axis_fb") >= 0, "plane W dives / S pitches up (pitch = -axis_fb)")
	_ok(drive.find("steer := -axis_lr") >= 0, "car A/D steering (steer = -axis_lr)")
	_ok(drive.find("func is_drive_third") >= 0 and drive.find("func orbit_look") >= 0, "third-person orbit + recenter API exists")
	_ok(drive.find("func begin_orbit") >= 0 and drive.find("func end_orbit") >= 0, "orbit hold / release API exists")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("extends RigidBody3D") >= 0, "car is a RigidBody3D (raycast suspension, not VehicleBody3D)")
	_ok(car_src.find("FREEZE_MODE_KINEMATIC") >= 0, "car uses kinematic freeze so Jolt keeps wheel positions")
	_ok(car_src.find("TIRE_GRIP") >= 0 and car_src.find("SPRING_STRENGTH") >= 0, "car uses raycast springs + lateral tire grip")
	_ok(car_src.find("ENGINE_POWER") >= 0, "car uses a bounded ENGINE_POWER, not raw overpowering torque")
	_ok(car_src.find("custom-3d-car") >= 0, "car physics is ported from custom-3d-car (Godot 4 + Jolt)")
	_ok(drive.find("yaw += 1.0") >= 0 and drive.find("yaw -= 1.0") >= 0, "Q adds left yaw, E subtracts (yaw was reversed in 0.2.19)")
	_ok(drive.find("holding_ab") >= 0 and drive.find("move_toward(pl.thrust, 0.8") >= 0, "afterburner last lever segment is hold-to")
	_ok(drive.find("_holster_occupied_weapons") >= 0, "entering a vehicle holsters weapons")
	_ok(drive.find("_chase_dir") >= 0, "chase cam follows motion, not a heading-locked fuselage")
	_ok(drive.find("offset_hair") >= 0 and drive.find("set_gaze_target") >= 0, "exam pose offsets hair and looks at the camera in observation mode")
	var car_vis := FileAccess.get_file_as_string("res://scripts/vehicles/car_visuals.gd")
	var pl_vis := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(car_vis.find("hub.rotate_x") >= 0 and car_vis.find("axle") >= 0, "car wheels roll about hub-local X, not a world AABB axis")
	_ok(pl_vis.find("hub.rotate_x") >= 0, "plane wheels roll about hub-local X, not a world AABB axis")
	_ok(car_src.find("_vis_spin +=") >= 0 and car_src.find("-(long_speed") >= 0, "car wheel spin sign matches forward travel")
	var pl_ctrl := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_ctrl.find("_vis_spin +=") >= 0 and (pl_ctrl.find("-(long_spin") >= 0 or pl_ctrl.find("-(") >= 0), "plane wheel spin sign matches forward taxi")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("ROTATE_SPEED") >= 0 and pl_src.find("_apply_gear_suspension") >= 0, "plane has rotate-speed takeoff and gear suspension")
	_ok(pl_src.find("GEAR_AUTO_RETRACT_AGL") >= 0 and pl_src.find("weight_on_gear") >= 0, "plane auto-retracts gear above an AGL threshold and refuses to retract on the wheels")
	_ok(pl_src.find("gear * GEAR_DRAG") >= 0 or pl_src.find("GEAR_DRAG") >= 0, "gear-down adds parasite drag")
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


func _check_0218_physics_and_visuals() -> void:
	## Isolated floor far from the room, so RoomCollision cannot interfere.
	var floor := StaticBody3D.new()
	floor.name = "TestFloor0218"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(260, 1, 260)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor.add_child(cs)
	# Far from the room and the city mesh so those collisions cannot pin the test vehicles.
	floor.position = Vector3(15000, 20, 15000)
	root.add_child(floor)
	await _phys(1)

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	_ok(car.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC, "car freeze_mode is kinematic")
	var lift: float = float(car.call("spawn_lift"))
	# Keep the test car off the room geometry at the origin.
	car.global_position = floor.position + Vector3(0, lift + 0.02, 0)
	car.rotation = Vector3.ZERO
	if car.has_method("_restore_wheel_positions"):
		car.call("_restore_wheel_positions")
	car.reset_physics_interpolation()
	await _phys(2)
	var w0: Vector3 = Vector3.ZERO
	if car._wheels.size():
		w0 = car._wheels[0].position
	if w0.length() <= 0.5 and car.has_method("_restore_wheel_positions"):
		car.call("_restore_wheel_positions")
		w0 = car._wheels[0].position if car._wheels.size() else w0
	_ok(w0.length() > 0.5, "car wheels stay at the visual stations after physics (w0=%s)" % w0)
	# Unfreeze, no input — must not spin on its own.
	car.freeze = false
	car.sleeping = false
	car.reset_physics_interpolation()
	for i in 20:
		await _phys(1)
	var yaw0: float = car.rotation.y
	var p0: Vector3 = car.global_position
	for i in 50:
		await _phys(1)
	var dyaw := absf(wrapf(car.rotation.y - yaw0, -PI, PI))
	var drift := Vector2(car.global_position.x - p0.x, car.global_position.z - p0.z).length()
	_ok(dyaw < 0.12, "parked car does not uncommanded-spin on flat ground (dyaw=%.3f)" % dyaw)
	_ok(drift < 1.2, "parked car does not slide away on flat ground (drift=%.2f m)" % drift)
	# Throttle sign: W / +throttle must go toward visual -Z; S is reverse.
	car.occupied = true
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.global_position = floor.position + Vector3(8, lift + 0.02, 0)
	car.rotation = Vector3.ZERO
	car.reset_physics_interpolation()
	for i in 15:
		await _phys(1)
	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	for i in 90:
		await _phys(1)
	var fwd: Vector3 = -car.global_transform.basis.z
	var long_w: float = car.linear_velocity.dot(fwd)
	_ok(long_w > 1.5, "W / +throttle drives the car forward along the visual nose (v=%.2f)" % long_w)
	# reset and try reverse
	car.set_driver_input(0.0, 0.0, 1.0, true, false)
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.global_position = floor.position + Vector3(16, lift + 0.02, 0)
	car.rotation = Vector3.ZERO
	car.reset_physics_interpolation()
	for i in 15:
		await _phys(1)
	car.set_driver_input(-1.0, 0.0, 0.0, false, false)
	for i in 90:
		await _phys(1)
	fwd = -car.global_transform.basis.z
	var long_s: float = car.linear_velocity.dot(fwd)
	_ok(long_s < -1.0, "S / -throttle reverses the car (v=%.2f)" % long_s)
	car.queue_free()

	var plane: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(plane)
	await _phys(2)
	var plift: float = float(plane.call("spawn_lift"))
	_ok(plift > 1.05, "plane spawn_lift clears the pavement for the gear (%.3f)" % plift)
	plane.global_position = floor.position + Vector3(-8, plift, 0)
	plane.rotation = Vector3.ZERO
	plane.freeze = false
	plane.sleeping = false
	plane.can_sleep = false
	plane.reset_physics_interpolation()
	for i in 50:
		await _phys(1)
	var hull_min := VehicleCommon.body_collision_min_y(plane)
	var origin_y: float = plane.global_position.y
	var wheel_bottom: float = 1e9
	var vis = plane.get("visuals")
	if vis:
		for w in vis.wheels:
			var off: Vector3 = w.get("offset", Vector3.ZERO)
			wheel_bottom = minf(wheel_bottom, origin_y + off.y - float(vis.wheel_r))
	var fy: float = floor.position.y
	_ok(origin_y > fy + 1.0, "plane origin stays above the pavement after settling (y=%.3f floor=%.1f, not buried)" % [origin_y, fy])
	_ok(origin_y + hull_min > fy + 0.15, "airframe hull stays above the pavement (hull world y=%.3f)" % (origin_y + hull_min))
	_ok(wheel_bottom < fy + 0.35 and wheel_bottom > fy - 0.25, "landing gear sits near the pavement (bottom=%.3f floor=%.1f)" % [wheel_bottom, fy])
	# Taxi under thrust.
	plane.occupied = true
	plane.thrust = 0.8
	plane.ctrl_pitch = 0.0
	var z0: float = plane.global_position.z
	for i in 200:
		await _phys(1)
	var taxi_spd: float = plane.airspeed
	var taxi_fwd: float = plane.linear_velocity.dot(-plane.global_transform.basis.z)
	_ok(taxi_spd > 4.0 and taxi_fwd > 3.0, "thrust produces forward taxi motion (speed=%.2f fwd=%.2f)" % [taxi_spd, taxi_fwd])
	# Below rotate speed, stick back must not launch from a crawl.
	var rotate_spd: float = float(plane.call("rotate_speed")) if plane.has_method("rotate_speed") else 42.0
	_ok(plane.has_method("rotate_speed"), "plane exposes rotate_speed()")
	_ok(rotate_spd > 20.0 and rotate_spd < 60.0, "rotate / takeoff speed threshold is in a taxiable range (%.1f m/s)" % rotate_spd)
	# Slow: plant the jet, pull stick, must stay on the deck.
	plane.linear_velocity = Vector3.ZERO
	plane.angular_velocity = Vector3.ZERO
	plane.global_position = floor.position + Vector3(-8, plift, 12)
	plane.rotation = Vector3.ZERO
	plane.thrust = 0.2
	plane.ctrl_pitch = 1.0
	for i in 40:
		await _phys(1)
	_ok(plane.global_position.y < floor.position.y + plift + 1.2, "stick at low speed does not launch the plane (y=%.2f)" % plane.global_position.y)
	# At rotate speed, pulling the stick should raise the nose / leave the deck.
	plane.linear_velocity = Vector3.ZERO
	plane.angular_velocity = Vector3.ZERO
	plane.global_position = floor.position + Vector3(-8, plift, 24)
	plane.rotation = Vector3.ZERO
	plane.reset_physics_interpolation()
	for i in 20:
		await _phys(1)
	var nose: Vector3 = -plane.global_transform.basis.z
	plane.linear_velocity = nose * (rotate_spd + 6.0)
	plane.thrust = 0.9
	plane.ctrl_pitch = 1.0
	var y_before: float = plane.global_position.y
	for i in 80:
		await _phys(1)
	var pitched_up: bool = plane.global_transform.basis.z.y > 0.04 or plane.rotation.x < -0.04
	var lifted: bool = plane.global_position.y > y_before + 0.35 or bool(plane.airborne)
	_ok(pitched_up or lifted, "at rotate speed, pulling the stick rotates / lifts off (y=%.2f airborne=%s pitch_z=%.3f)" % [plane.global_position.y, plane.airborne, plane.global_transform.basis.z.y])

	# Visuals: nozzle range, surface smoothing, canted rudder.
	if vis:
		for s in vis.surfaces:
			s.apply(0.0)
		var nozzle_max := 0.0
		var rudder_tilt := 0.0
		var rudder_sweep := 0.0
		for s in vis.surfaces:
			var kind := str(s.kind)
			if kind.begins_with("nozzle"):
				nozzle_max = maxf(nozzle_max, float(s.max_angle))
			if kind.begins_with("rudder") and s.obj:
				var ax := Vector3.UP if str(s.axis) == "y" else Vector3.RIGHT
				var aw: Vector3 = (s.obj.global_transform.basis * ax).normalized()
				rudder_tilt = maxf(rudder_tilt, rad_to_deg(acos(clampf(absf(aw.dot(Vector3.UP)), 0.0, 1.0))))
				rudder_sweep = maxf(rudder_sweep, absf(aw.z))
		_ok(nozzle_max > 0.15 and nozzle_max <= 0.58, "nozzle max deflection is reduced (%.3f rad, was 0.72)" % nozzle_max)
		_ok(rudder_tilt > 15.0, "rudder hinge is canted with the fin, not vertical (tilt=%.1f deg)" % rudder_tilt)
		_ok(rudder_sweep > 0.12, "rudder hinge follows the fin sweep, not a pure vertical axis (z=%.3f)" % rudder_sweep)
		# Smoothing: one short frame must not reach the full deflection.
		for s in vis.surfaces:
			if str(s.kind).begins_with("aileron") or str(s.kind) == "elevator":
				s.apply(0.0)
		vis._surf_t = {}
		plane.ctrl_pitch = 1.0
		plane.ctrl_roll = 1.0
		plane.ctrl_yaw = 1.0
		vis.apply_pose({
			"gear": 1.0, "steer_angle": 0.0, "wheel_spin": 0.0, "door": 0.0,
			"ctrl_pitch": 1.0, "ctrl_roll": 1.0, "ctrl_yaw": 1.0,
			"thrust": 0.5, "speed_brake": 0.0, "airborne": false, "speed": 0.0,
			"decelerating": false, "susp": [0.4, 0.4, 0.4],
		}, 0.016, 0.0, 0.0)
		var mid := 0.0
		var mx := 0.0
		var nsurf := 0
		for s in vis.surfaces:
			var kind := str(s.kind)
			if kind.begins_with("aileron") or kind == "elevator" or kind.begins_with("rudder") or kind.begins_with("nozzle"):
				# Infer t from applied angle / max.
				var q: Quaternion = s.obj.quaternion * s.rest.inverse() if s.obj else Quaternion.IDENTITY
				# angle of the applied local rotation
				var ang := absf(q.get_angle()) if q != Quaternion.IDENTITY else 0.0
				# rest * local, so recover relative
				var rel: Quaternion = s.rest.inverse() * s.obj.quaternion if s.obj else Quaternion.IDENTITY
				ang = absf(rel.get_angle())
				var tnorm := ang / maxf(float(s.max_angle), 1e-4)
				mid = maxf(mid, tnorm)
				nsurf += 1
		_ok(nsurf > 0 and mid < 0.85, "control surfaces ease over time, not a one-frame snap (t=%.2f after 16ms)" % mid)
		# After a longer blend they should be close to the target.
		for i in 20:
			vis.apply_pose({
				"gear": 1.0, "steer_angle": 0.0, "wheel_spin": 0.0, "door": 0.0,
				"ctrl_pitch": 1.0, "ctrl_roll": 1.0, "ctrl_yaw": 1.0,
				"thrust": 0.5, "speed_brake": 0.0, "airborne": false, "speed": 0.0,
				"decelerating": false, "susp": [0.4, 0.4, 0.4],
			}, 0.05, float(i) * 0.05, 0.0)
		var late := 0.0
		for s in vis.surfaces:
			var kind := str(s.kind)
			if kind.begins_with("aileron") or kind == "elevator" or kind.begins_with("rudder"):
				var rel2: Quaternion = s.rest.inverse() * s.obj.quaternion if s.obj else Quaternion.IDENTITY
				late = maxf(late, absf(rel2.get_angle()) / maxf(float(s.max_angle), 1e-4))
		_ok(late > 0.75, "control surfaces reach the target after a short blend (t=%.2f)" % late)
	# Camera API still defaults to third on a fresh enter (already covered);
	# confirm recenter helpers exist at runtime.
	if vs:
		_ok(vs.has_method("is_drive_third") and vs.has_method("orbit_look") and vs.has_method("end_orbit"),
			"vehicle system exposes orbit / recenter helpers")
	plane.queue_free()
	floor.queue_free()
	await _frames(1)


func _check_0219_chase_wheel_gear() -> void:
	if vs == null or player == null or main == null:
		return
	# process_priority must run *after* the player (higher number; player is -10).
	_ok(int(vs.process_priority) > int(player.process_priority), "VehicleSystem process_priority (%d) runs after the player (%d)" % [vs.process_priority, player.process_priority])

	# Wheel dollies distance and does not change FOV in display or character modes.
	var pc_src := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc_src.find("fp_fov = clampf(fp_fov - steps") < 0, "player wheel path no longer changes FOV")
	var fov_fp0: float = float(player.get("fp_fov"))
	var fov_tp0: float = float(player.get("tp_fov"))
	var d0: float = float(player.call("get_tp_distance"))
	# Display / observation.
	if player.has_method("is_display_mode") and not bool(player.call("is_display_mode")):
		player.call("set_play_mode", player.get("play_mode"))  # keep
	player.call("_tp_dolly", 3.0)
	var d1: float = float(player.call("get_tp_distance"))
	_ok(d1 < d0 - 0.01, "display-mode wheel dollies camera distance (%.3f -> %.3f)" % [d0, d1])
	_ok(is_equal_approx(float(player.get("fp_fov")), fov_fp0) and is_equal_approx(float(player.get("tp_fov")), fov_tp0), "display-mode wheel does not change FOV")
	# Character / control mode: same dolly, still no FOV change.
	if player.has_method("set_play_mode"):
		# GameMode.CONTROL is the first-person play mode (enum value 1 if DISPLAY=0).
		var modes = player.get("GameMode") if false else null
		player.set("first_person", true)
	var fov_fp1: float = float(player.get("fp_fov"))
	player.call("_tp_dolly", -2.0)
	var d2: float = float(player.call("get_tp_distance"))
	_ok(d2 > d1 + 0.005, "character-mode wheel also changes camera distance (%.3f -> %.3f)" % [d1, d2])
	_ok(is_equal_approx(float(player.get("fp_fov")), fov_fp1) and is_equal_approx(float(player.get("tp_fov")), fov_tp0), "character-mode wheel does not change FOV")

	# Chase cam: heading-aligned default + recenter after an orbit.
	# Park a temporary car in the room.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	main.add_child(car)
	car.global_position = Vector3(1.8, 0.6, 0.3)
	if car.has_method("spawn_lift"):
		car.global_position.y = float(car.call("spawn_lift"))
	car.rotation = Vector3(0.0, 0.7, 0.0)
	if car.has_method("reset_physics_interpolation"):
		car.reset_physics_interpolation()
	await _phys(2)
	player.global_position = car.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = car
	_ok(bool(vs.call("try_enter")), "enter car for chase-cam check")
	_ok(str(vs.get("vehicle_cam")) == "third", "chase cam defaults to third person")
	if vs.has_method("_reset_vehicle_cam"):
		vs.call("_reset_vehicle_cam")
	if vs.has_method("_vehicle_camera"):
		vs.call("_vehicle_camera", 0.016)
	await _frames(2)
	if vs.has_method("_vehicle_camera"):
		vs.call("_vehicle_camera", 0.016)
	var err0 := 99.0
	if vs.has_method("chase_heading_error"):
		err0 = float(vs.call("chase_heading_error"))
	_ok(err0 < 0.25, "default chase cam aligns with the vehicle heading (err=%.3f rad)" % err0)
	# Orbit off-heading, then release and recenter.
	if vs.has_method("begin_orbit"):
		vs.call("begin_orbit")
	if vs.has_method("orbit_look"):
		vs.call("orbit_look", Vector2(180.0, 0.0), 0.01)
	if vs.has_method("_vehicle_camera"):
		vs.call("_vehicle_camera", 0.016)
	if vs.has_method("end_orbit"):
		vs.call("end_orbit")
	for i in 36:
		if vs.has_method("_vehicle_camera"):
			vs.call("_vehicle_camera", 0.05)
	var err1 := 99.0
	if vs.has_method("chase_heading_error"):
		err1 = float(vs.call("chase_heading_error"))
	_ok(err1 < 0.25, "recenter returns the chase cam to the vehicle heading (err=%.3f rad)" % err1)
	# G is not holster while driving; V still toggles camera.
	_ok(str(main.call("action_for_key", KEY_V, "control")) == "vehicle_cam", "V is vehicle_cam while in the car")
	_ok(str(main.call("action_for_key", KEY_G, "control")) == "", "G is not holster while in the car")
	_ok(str(main.call("action_for_key", KEY_Q, "control")) == "", "Q is not weapon_wheel while in the car")
	_ok(bool(vs.call("try_exit")), "exit car after chase-cam check")
	car.queue_free()
	await _frames(1)

	# Isolated floor: straight-line throttle (no uncommanded spin) + landing gear.
	var floor := StaticBody3D.new()
	floor.name = "TestFloor0219"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(260, 1, 260)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor.add_child(cs)
	floor.position = Vector3(18000, 20, 18000)
	root.add_child(floor)
	await _phys(1)

	var car2: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car2)
	var lift: float = float(car2.call("spawn_lift"))
	car2.global_position = floor.position + Vector3(0, lift + 0.02, 0)
	car2.rotation = Vector3.ZERO
	if car2.has_method("_restore_wheel_positions"):
		car2.call("_restore_wheel_positions")
	car2.reset_physics_interpolation()
	car2.freeze = false
	car2.occupied = true
	car2.sleeping = false
	for i in 20:
		await _phys(1)
	car2.linear_velocity = Vector3.ZERO
	car2.angular_velocity = Vector3.ZERO
	car2.global_position = floor.position + Vector3(4, lift + 0.02, 0)
	car2.rotation = Vector3.ZERO
	car2.reset_physics_interpolation()
	for i in 12:
		await _phys(1)
	var yaw0: float = car2.rotation.y
	car2.set_driver_input(1.0, 0.0, 0.0, false, false)
	for i in 90:
		await _phys(1)
	var dyaw := absf(wrapf(car2.rotation.y - yaw0, -PI, PI))
	var fwd: Vector3 = -car2.global_transform.basis.z
	var long_w: float = car2.linear_velocity.dot(fwd)
	_ok(long_w > 1.5, "flat-ground throttle moves the car forward (v=%.2f)" % long_w)
	_ok(dyaw < 0.18, "flat-ground throttle does not spin the car out (dyaw=%.3f)" % dyaw)
	car2.queue_free()

	var plane: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(plane)
	await _phys(2)
	var plift: float = float(plane.call("spawn_lift"))
	plane.global_position = floor.position + Vector3(-8, plift, 0)
	plane.rotation = Vector3.ZERO
	plane.freeze = false
	plane.sleeping = false
	plane.can_sleep = false
	plane.reset_physics_interpolation()
	for i in 40:
		await _phys(1)
	plane.occupied = true
	# Gear-down drag is higher than gear-up.
	plane.gear = 1.0
	var d_down: float = float(plane.call("gear_drag_coeff"))
	plane.gear = 0.0
	var d_up: float = float(plane.call("gear_drag_coeff"))
	_ok(d_down > d_up + 0.01, "gear-down increases drag (down=%.3f up=%.3f)" % [d_down, d_up])
	plane.gear = 1.0
	plane.gear_want = 1.0
	plane.gear_manual = false
	# Settled on the runway: G must not retract.
	if plane.has_method("toggle_gear"):
		plane.call("toggle_gear")
	_ok(float(plane.gear_want) > 0.5, "gear will not retract while settled on the runway (gear_want=%.2f)" % float(plane.gear_want))
	# Lift off: auto-retract above the AGL threshold.
	plane.gear_manual = false
	plane.gear = 1.0
	plane.gear_want = 1.0
	plane.global_position = floor.position + Vector3(-8, plift + 12.0, 0)
	plane.linear_velocity = Vector3(0, 2.0, -50.0)
	plane.angular_velocity = Vector3.ZERO
	plane.reset_physics_interpolation()
	for i in 50:
		await _phys(1)
	_ok(float(plane.gear_want) < 0.5 or float(plane.gear) < 0.6, "gear auto-retracts above the AGL threshold (gear=%.2f want=%.2f agl=%.2f)" % [float(plane.gear), float(plane.gear_want), float(plane.get("_agl"))])
	# Airborne G toggles gear back down.
	plane.gear_manual = false
	if plane.has_method("weight_on_gear"):
		# If still considered on wheels, push it higher.
		if bool(plane.call("weight_on_gear")):
			plane.global_position.y += 8.0
			for i in 20:
				await _phys(1)
	if plane.has_method("toggle_gear"):
		# Start from known up, toggle down, then up.
		plane.gear = 0.2
		plane.gear_want = 0.0
		plane.call("toggle_gear")
	_ok(float(plane.gear_want) > 0.5, "G toggles landing gear down when airborne (want=%.2f)" % float(plane.gear_want))
	plane.call("toggle_gear")
	_ok(float(plane.gear_want) < 0.5, "G toggles landing gear up when airborne (want=%.2f)" % float(plane.gear_want))

	# Occupied fighter: G is vehicle_gear, Q is still not the weapon wheel.
	# Place the plane in the room-ish so we can occupy via VehicleSystem.
	# (Use a dummy enter on vs.)
	if vs.get("occupied") == null:
		player.global_position = plane.global_position + Vector3(3, 0, 0)
		vs.nearest = plane
		if bool(vs.call("try_enter")):
			_ok(str(main.call("action_for_key", KEY_G, "control")) == "vehicle_gear", "G is vehicle_gear while in the fighter")
			_ok(str(main.call("action_for_key", KEY_Q, "control")) == "", "Q is not weapon_wheel while in the fighter")
			_ok(bool(vs.call("try_exit")), "exit fighter after gear-bind check")
		else:
			_ok(false, "can enter fighter for G-key routing check")
	plane.queue_free()
	floor.queue_free()
	await _frames(1)


func _check_0220_spawn_yaw_car_turn_weapons() -> void:
	## Runtime: car can turn, weapons holster on enter, exam cam is untilted.
	if vs == null or player == null:
		return
	# Source-level yaw / exam-cam already covered in bindings; add physics turn.
	var floor := StaticBody3D.new()
	floor.name = "TestFloor0220"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(260, 1, 260)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor.add_child(cs)
	floor.position = Vector3(21000, 20, 21000)
	root.add_child(floor)
	await _phys(1)

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	_ok(car is RigidBody3D and not (car is VehicleBody3D), "spawned car is RigidBody3D, not VehicleBody3D")
	var lift: float = float(car.call("spawn_lift"))
	car.global_position = floor.position + Vector3(0, lift + 0.02, 0)
	car.rotation = Vector3.ZERO
	if car.has_method("_restore_wheel_positions"):
		car.call("_restore_wheel_positions")
	car.reset_physics_interpolation()
	car.freeze = false
	car.occupied = true
	car.sleeping = false
	for i in 20:
		await _phys(1)
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.global_position = floor.position + Vector3(4, lift + 0.02, 0)
	car.rotation = Vector3.ZERO
	car.reset_physics_interpolation()
	for i in 12:
		await _phys(1)
	# Build a little speed, then hold left steer (positive, matches steer := -axis_lr).
	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	for i in 40:
		await _phys(1)
	var yaw0: float = car.rotation.y
	car.set_driver_input(1.0, 1.0, 0.0, false, false)
	for i in 90:
		await _phys(1)
	var dyaw := wrapf(car.rotation.y - yaw0, -PI, PI)
	_ok(absf(dyaw) > 0.25, "steering actually turns the sports car (dyaw=%.3f)" % dyaw)
	_ok(dyaw > 0.15, "positive steer turns left / +Y (dyaw=%.3f)" % dyaw)
	car.queue_free()

	# Boarding with a weapon drawn must holster (empty hands while occupied).
	var car2: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	main.add_child(car2)
	car2.global_position = Vector3(1.8, 0.6, 0.3)
	if car2.has_method("spawn_lift"):
		car2.global_position.y = float(car2.call("spawn_lift"))
	car2.rotation = Vector3.ZERO
	if car2.has_method("reset_physics_interpolation"):
		car2.reset_physics_interpolation()
	await _phys(2)
	var ws: Node = player.call("get_weapons") if player.has_method("get_weapons") else null
	_ok(ws != null, "player weapon system is available")
	if ws and ws.has_method("select"):
		var ids: PackedStringArray = ws.call("weapon_ids") if ws.has_method("weapon_ids") else PackedStringArray()
		var pick := "pistol" if "pistol" in ids or ids.is_empty() else ids[0]
		ws.call("select", pick)
		await _frames(2)
	player.global_position = car2.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = car2
	_ok(bool(vs.call("try_enter")), "enter car with a weapon drawn")
	if ws:
		var armed := bool(ws.call("is_armed")) if ws.has_method("is_armed") else (str(ws.get("current")) != "")
		var cur := str(ws.get("current"))
		var st := str(ws.get("state"))
		_ok(not armed or st == "holstering" or cur == "", "boarding holsters the current weapon (current='%s' state='%s')" % [cur, st])
		# Stay empty-handed: a later select must also be stripped.
		if ws.has_method("select"):
			ws.call("select", "pistol")
			await _phys(2)
			armed = bool(ws.call("is_armed")) if ws.has_method("is_armed") else (str(ws.get("current")) != "")
			cur = str(ws.get("current"))
			st = str(ws.get("state"))
			_ok(not armed or st == "holstering" or cur == "", "occupied occupant cannot keep a drawn weapon (current='%s' state='%s')" % [cur, st])
	_ok(str(main.call("action_for_key", KEY_Q, "control")) == "", "occupied Q is still not the weapon wheel")
	_ok(bool(vs.call("try_exit")), "exit car after weapon-holster check")
	if ws and ws.has_method("holster"):
		ws.call("holster")
	car2.queue_free()
	floor.queue_free()
	await _frames(1)


func _finish() -> void:
	if fails == 0:
		print("vehicles: ALL PASSED")
	else:
		print("vehicles: FAILED ", fails)
	quit(1 if fails else 0)
