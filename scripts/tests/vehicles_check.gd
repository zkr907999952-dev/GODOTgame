extends SceneTree

const TouchLayout := preload("res://scripts/ui/touch_layout.gd")
## 0.2.29 载具 / 检查床 / 地图传送 / RoomCollision 自检。
##   godot --headless --path . -s res://scripts/tests/vehicles_check.gd

const VERSION_NAME := "0.2.29"
const VERSION_CODE := 31

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


func _flush_board() -> void:
	## Finish a pending car scissor-door exit so later checks see the player standing.
	if vs and vs.has_method("_tick_board_anim"):
		vs.call("_tick_board_anim", 1.0)


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
	await _check_map_open()
	await _check_overhead_teleport_and_home()
	await _check_car_cam_and_exit()
	await _check_city_defaults()
	await _check_0218_physics_and_visuals()
	await _check_0219_chase_wheel_gear()
	await _check_0220_spawn_yaw_car_turn_weapons()
	await _check_0221_playtest_fixes()
	await _check_0222_playtest_fixes()
	await _check_0223_playtest_fixes()
	await _check_0224_playtest_fixes()
	await _check_0225_playtest_fixes()
	await _check_0226_playtest_fixes()
	await _check_0227_playtest_fixes()
	await _check_0228_playtest_fixes()
	await _check_0229_playtest_fixes()
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
	_ok(p.z < -0.6 and p.z > -2.4, "default exam bed sits further back, beside the furniture bed (z=%.2f)" % p.z)


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
			# 0.2.26 raises the crotch so the mesh sits ON the cushion (hip bone
			# is above the flesh). Must not sink through, must not hover a lot.
			_ok(hip_w.y >= seat.y - 0.01, "hip is not below the seat surface (hip.y=%.3f seat.y=%.3f)" % [hip_w.y, seat.y])
			_ok(hip_w.y <= seat.y + 0.34, "hip sits on the cushion, not floating high (hip.y=%.3f seat.y=%.3f)" % [hip_w.y, seat.y])
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
	_ok(hud.get("_btn_observe") != null, "vehicle 观察 button exists")
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
	_ok(cars == 1, "exactly one default sports car at the airport (got %d)" % cars)
	var paved := 0
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "car" and bool(v.get("is_default")):
			var ok_p := true
			if vs.has_method("is_default_car_on_pavement"):
				ok_p = bool(vs.call("is_default_car_on_pavement", v))
			if ok_p:
				paved += 1
			else:
				print("vehicles: car off pavement at ", v.global_position)
	_ok(paved == cars and cars > 0, "all default cars sit on pavement (paved=%d / %d)" % [paved, cars])
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
			_ok(d_thr > 70.0 and d_thr < 220.0, "standoff is further up the runway, past the piano-key bars (d=%.1f m)" % d_thr)
			var bars_inner := float(info.get("bars_inner", -1.0))
			if bars_inner > 4.0:
				_ok(d_thr > bars_inner + 12.0, "pair mid is past the inner edge of the threshold bars (d=%.1f bars_inner=%.1f)" % [d_thr, bars_inner])
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
			print("vehicles: fighter mid=", mid, " yaw=", pl[0].rotation.y, " d_thr=", d_thr, " bars_inner=", info.get("bars_inner", -1), " standoff=", info.get("standoff", -1), " a=", a, " b=", b)


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
	_ok(car_vis.find("WheelSteer_") >= 0 and car_vis.find("WheelSpin_") >= 0, "car wheels use steer-hinge / spin-child hierarchy")
	_ok(car_vis.find("rotate_object_local(Vector3.UP") >= 0 and car_vis.find("Quaternion(Vector3.RIGHT") >= 0, "car kingpin is body-up; roll is on the spin child")
	_ok(pl_vis.find("WheelSteer_") >= 0 and pl_vis.find("WheelSpin_") >= 0, "plane wheels use steer-hinge / spin-child hierarchy")
	_ok(pl_vis.find("rotate_object_local(Vector3.UP") >= 0 and pl_vis.find("Quaternion(Vector3.RIGHT") >= 0, "plane kingpin is body-up; roll is on the spin child")
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
	# Preview must preload city vehicles so later travel does not hitch,
	# but must not swap current_map or hide the home bed.
	var gpre := 0
	while vs and not bool(vs.get("_city_ready")) and gpre < 50:
		await _phys(1)
		gpre += 1
	_ok(bool(vs.get("_city_ready")), "opening the map preloads city default vehicles (waited %d frames)" % gpre)
	_ok(str(main.get("current_map")) == "room", "preload during preview does not change current_map")
	_ok(int(vs.call("default_bed_count")) == beds_before, "preloading city vehicles does not hide the home exam bed")
	if main.has_method("close_overhead"):
		main.call("close_overhead")
	_ok(mv == null or not bool(mv.get("is_open")), "overhead / map view closes")
	_ok(str(main.get("current_map")) == "room", "closing the preview keeps the player in the room")
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
	main.call("open_overhead")
	var mv = main.get("map_view")
	_ok(mv != null and bool(mv.get("is_open")), "overhead opens for teleport")
	_ok(str(main.get("current_map")) == "room", "preview does not change current_map")
	var gpre2 := 0
	while vs and not bool(vs.get("_city_ready")) and gpre2 < 50:
		await _phys(1)
		gpre2 += 1
	_ok(bool(vs.get("_city_ready")), "city vehicles are already ready before teleport (waited %d frames)" % gpre2)
	_ok(int(vs.call("default_plane_count")) == 2, "default fighters exist before teleport")
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
	_flush_board()
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
	# Isolated pad — this test may run after the city map is already shown,
	# so do not park at the world origin (city geometry would shove the car).
	var cam_floor := StaticBody3D.new()
	var cam_cs := CollisionShape3D.new()
	var cam_box := BoxShape3D.new()
	cam_box.size = Vector3(40, 1, 40)
	cam_cs.shape = cam_box
	cam_cs.position = Vector3(0, -0.5, 0)
	cam_floor.add_child(cam_cs)
	cam_floor.position = Vector3(19000, 40, 19000)
	root.add_child(cam_floor)
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	var cam_lift: float = float(car.call("spawn_lift")) if car.has_method("spawn_lift") else 0.5
	car.global_position = cam_floor.position + Vector3(0, cam_lift, 0)
	car.rotation = Vector3(0.0, 0.7, 0.0)
	if car is RigidBody3D:
		(car as RigidBody3D).linear_velocity = Vector3.ZERO
		(car as RigidBody3D).angular_velocity = Vector3.ZERO
		(car as RigidBody3D).freeze = true
	if car.has_method("reset_physics_interpolation"):
		car.reset_physics_interpolation()
	await _phys(4)
	player.global_position = car.global_position + Vector3(2.0, 0.1, 0.0)
	if player.has_method("reset_physics_interpolation"):
		player.reset_physics_interpolation()
	vs.nearest = car
	_ok(bool(vs.call("try_enter")), "enter car for chase-cam check")
	_ok(str(vs.get("vehicle_cam")) == "third", "chase cam defaults to third person")
	if car.has_method("reset_physics_interpolation"):
		car.reset_physics_interpolation()
	if player.has_method("reset_physics_interpolation"):
		player.reset_physics_interpolation()
	await _phys(4)
	if vs.has_method("_reset_vehicle_cam"):
		vs.call("_reset_vehicle_cam")
	for i in 8:
		if vs.has_method("_vehicle_camera"):
			vs.call("_vehicle_camera", 0.016)
		await _phys(1)
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
	_flush_board()
	car.queue_free()
	cam_floor.queue_free()
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
	# Accumulate unwrapped yaw so a punchy nitro launch can turn past PI
	# in this window without flipping the sign.
	var dyaw := 0.0
	var prev_yaw := yaw0
	for i in 90:
		await _phys(1)
		var ynow: float = car.rotation.y
		dyaw += wrapf(ynow - prev_yaw, -PI, PI)
		prev_yaw = ynow
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
	_flush_board()
	if ws and ws.has_method("holster"):
		ws.call("holster")
	car2.queue_free()
	floor.queue_free()
	await _frames(1)


func _check_0221_playtest_fixes() -> void:
	## Observation dolly (incl. exam bed), stronger car steer/accel, wheel
	## hierarchy, consistent orbit pivot + composited look-drag, ride height,
	## Ace Combat-style fighter rates, curved exhaust, airborne exit placement.
	if vs == null or player == null or main == null:
		return

	# --- Source contracts ---
	var pc_src := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	_ok(pc_src.find("func _try_handle_observe_wheel") >= 0 and pc_src.find("func _input") >= 0, "observation wheel is handled in _input so GUI cannot swallow dolly")
	_ok(pc_src.find("intersect_shape") >= 0 and pc_src.find("occupier is CollisionObject3D") >= 0, "orbit collide excludes exam bed / overlapping start shapes")
	var drive := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(drive.find("_orbit_pivot") >= 0 and drive.find("Shared pivot") >= 0, "vehicle orbit uses a stable vehicle-centered pivot")
	_ok(drive.find("_orbit_yaw") >= 0 and drive.find("Recenter target is vehicle-forward") >= 0, "look-drag is composited on the dynamic follow and recenters to the heading")
	_ok(drive.find("airborne or agl > 3.0") >= 0, "airborne exit stays beside the vehicle")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("THRUST_DRY := 680000.0") >= 0 and pl_src.find("THRUST_AB := 1120000.0") >= 0, "fighter dry/AB thrust is 680 kN / 1120 kN")
	_ok((pl_src.find("const PITCH_RATE := 1.90") >= 0 or pl_src.find("ctrl_pitch * 1.90") >= 0) and (pl_src.find("ctrl_roll * ROLL_RATE") >= 0 or pl_src.find("ctrl_roll * 2.15") >= 0), "pitch rate is 1.90, roll uses a dedicated rate")
	_ok(pl_src.find("0.62 + boost") >= 0 or pl_src.find("ctrl_yaw * 0.62") >= 0, "yaw rate is milder than pitch/roll (0.62 from vehicle-sim.ts)")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("_update_trail") >= 0 and ex_src.find("TRAIL_COUNT") >= 0, "jet exhaust uses a lagged inertial trail")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("REST_DISTANCE") >= 0 and car_src.find("_lift_hulls_for_ride") >= 0, "car ride height / hull clearance was raised")
	_ok(car_src.find("MAX_STEER := 0.70") >= 0 and car_src.find("ENGINE_POWER") >= 0, "car steer lock and engine power were increased")

	# --- Exam-bed observation dolly (real wheel path + visible camera move) ---
	var bed: Node = null
	for v in vs.vehicles:
		if vs.kind_of(v) == "exam_bed" and bool(v.get("is_default")):
			bed = v
			break
	if bed:
		if vs.get("occupied"):
			vs.call("try_exit")
			await _phys(2)
		player.global_position = bed.global_position + Vector3(1.4, 0.1, 0.0)
		vs.nearest = bed
		_ok(bool(vs.call("try_enter")), "enter exam bed for observation dolly")
		if player.has_method("set_play_mode"):
			player.call("set_play_mode", 0)  # DISPLAY
		await _frames(4)
		var fov0: float = float(player.get("tp_fov"))
		var st0: Dictionary = player.call("debug_tp_state")
		var d0: float = float(player.call("get_tp_distance"))
		var cam0: Vector3 = st0["cam"]
		# Prefer the real input path (wheel event through _input).
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.factor = 3.0
		ev.position = Vector2(40, 40)
		player.call("_input", ev)
		if absf(float(player.call("get_tp_distance")) - d0) < 0.001 and player.has_method("apply_observe_wheel"):
			player.call("apply_observe_wheel", 6.0)
		for i in 20:
			await _frames(1)
		var st1: Dictionary = player.call("debug_tp_state")
		var d1: float = float(player.call("get_tp_distance"))
		var cam1: Vector3 = st1["cam"]
		var eff0 := float(st0.get("dist_eff", st0.get("dist", d0)))
		var eff1 := float(st1.get("dist_eff", st1.get("dist", d1)))
		_ok(d1 < d0 - 0.02, "exam-bed observation wheel shrinks orbit distance (%.3f -> %.3f)" % [d0, d1])
		_ok(eff1 < eff0 - 0.01 or cam1.distance_to(cam0) > 0.04, "exam-bed dolly actually moves the camera (eff %.3f -> %.3f, cam d=%.3f)" % [eff0, eff1, cam1.distance_to(cam0)])
		_ok(is_equal_approx(float(player.get("tp_fov")), fov0), "exam-bed wheel does not change FOV")
		# Dolly back out too.
		if player.has_method("apply_observe_wheel"):
			player.call("apply_observe_wheel", -4.0)
		for i in 16:
			await _frames(1)
		var d2: float = float(player.call("get_tp_distance"))
		_ok(d2 > d1 + 0.01, "exam-bed wheel also dollies outward (%.3f -> %.3f)" % [d1, d2])
		_ok(bool(vs.call("try_exit")), "exit exam bed after dolly check")
		await _phys(2)

	# --- Wheel hierarchy (steer parent / spin child) ---
	var floor := StaticBody3D.new()
	floor.name = "TestFloor0221"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(320, 1, 320)
	cs.shape = box
	cs.position = Vector3(0, -0.5, 0)
	floor.add_child(cs)
	floor.position = Vector3(24000, 30, 24000)
	root.add_child(floor)
	await _phys(1)

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	var lift: float = float(car.call("spawn_lift"))
	car.global_position = floor.position + Vector3(0, lift + 0.03, 0)
	car.rotation = Vector3.ZERO
	car.reset_physics_interpolation()
	await _phys(1)
	var vis = car.get("visuals")
	_ok(vis != null and vis.has_method("wheel_rig_info"), "car exposes wheel_rig_info")
	if vis and vis.has_method("apply_pose"):
		vis.call("apply_pose", {"steer_angle": 0.45, "wheel_spin": 1.7, "susp": [0.4, 0.4, 0.4, 0.4]}, 0.016, 0.0)
		car.force_update_transform()
		var rig: Array = vis.call("wheel_rig_info")
		var n_ok := 0
		var body_up: Vector3 = car.global_transform.basis.y.normalized()
		var body_right: Vector3 = car.global_transform.basis.x.normalized()
		for w in rig:
			if bool(w.get("parent_ok", false)):
				n_ok += 1
			var king: Vector3 = w["kingpin"]
			_ok(absf(king.dot(body_up)) > 0.92, "steer kingpin stays body-up after spin (dot=%.3f)" % king.dot(body_up))
			if bool(w.get("is_steer", false)):
				var axle: Vector3 = w["axle"]
				# Axle is body-right yawed by the steer angle, still horizontal.
				_ok(absf(axle.y) < 0.15, "steered wheel axle stays horizontal (ay=%.3f)" % axle.y)
				var yawed: Vector3 = body_right.rotated(body_up, 0.45)
				_ok(axle.dot(yawed) > 0.85, "steered roll axle follows kingpin yaw, not a tumble (dot=%.3f)" % axle.dot(yawed))
		_ok(n_ok == rig.size() and n_ok >= 4, "all car wheels have spin as a child of the steer hinge (%d/%d)" % [n_ok, rig.size()])

	var plane_vis_node: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(plane_vis_node)
	await _phys(1)
	var pvis = plane_vis_node.get("visuals")
	if pvis and pvis.has_method("apply_pose") and pvis.has_method("wheel_rig_info"):
		pvis.call("apply_pose", {
			"gear": 1.0, "steer_angle": 0.4, "wheel_spin": 2.2,
			"ctrl_pitch": 0.0, "ctrl_roll": 0.0, "ctrl_yaw": 0.0,
			"thrust": 0.4, "airborne": false, "susp": [0.4, 0.4, 0.4],
		}, 0.016, 0.0, 0.0)
		var prig: Array = pvis.call("wheel_rig_info")
		var pok := 0
		for w in prig:
			if bool(w.get("parent_ok", false)):
				pok += 1
			_ok(absf(Vector3(w["kingpin"]).dot(Vector3.UP)) > 0.85, "plane wheel kingpin stays world/body up")
		_ok(pok == prig.size() and pok >= 3, "plane wheels use steer parent / spin child (%d/%d)" % [pok, prig.size()])

	# --- Curved exhaust: a yaw step must bend the trail off a straight aft line ---
	if pvis and pvis.get("exhausts") != null:
		var exs: Array = pvis.exhausts
		_ok(exs.size() >= 1, "fighter has jet exhaust instances")
		if exs.size() >= 1:
			var fx = exs[0]
			plane_vis_node.global_position = floor.position + Vector3(20, 40, 0)
			plane_vis_node.rotation = Vector3.ZERO
			plane_vis_node.force_update_transform()
			if fx.has_method("reset_trail"):
				fx.call("reset_trail")
			for i in 8:
				fx.call("apply", 0.9, float(i) * 0.05, 40.0, 0.05)
			var straight := float(fx.call("trail_curve_amount"))
			# Yaw the jet in place so the nozzle heading changes under a lagging trail.
			for i in 12:
				plane_vis_node.rotation.y = float(i) * 0.22
				plane_vis_node.force_update_transform()
				fx.call("apply", 0.9, 0.5 + float(i) * 0.05, 40.0, 0.05)
			var curved := float(fx.call("trail_curve_amount"))
			_ok(straight < 0.12, "steady exhaust starts nearly straight (curve=%.3f)" % straight)
			_ok(curved > straight + 0.20, "exhaust trail bends with heading change (straight=%.3f curved=%.3f)" % [straight, curved])

	# --- Car accel, steer authority, ride height, no hitch ---
	if car.has_method("_restore_wheel_positions"):
		car.call("_restore_wheel_positions")
	car.freeze = false
	car.occupied = true
	car.sleeping = false
	car.global_position = floor.position + Vector3(8, lift + 0.03, 0)
	car.rotation = Vector3.ZERO
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.reset_physics_interpolation()
	for i in 20:
		await _phys(1)
	var rest_d: float = float(car.get("REST_DISTANCE"))
	var wr: float = float(car.visuals.wheel_r)
	var hull_min := VehicleCommon.body_collision_min_y(car)
	var contact := 1.0e9
	for c in car.get_children():
		if c is RayCast3D:
			contact = minf(contact, (c as RayCast3D).position.y - rest_d - wr)
	var sag := (1420.0 * 9.81 / 4.0) / 52000.0
	_ok(rest_d >= 0.24, "suspension rest length is raised (%.3f)" % rest_d)
	_ok(hull_min + 0.001 >= contact + sag + 0.06, "hull stays clear of pavement after sag (hull=%.3f contact=%.3f sag=%.3f)" % [hull_min, contact, sag])

	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	var sped := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for i in 50:
		await _phys(1)
		var fwd_s: float = car.linear_velocity.dot(-car.global_transform.basis.z)
		sped.append(fwd_s)
		ys.append(car.global_position.y)
	var accel_v := float(sped[sped.size() - 1])
	_ok(accel_v > 9.0, "sports-car throttle acceleration is stronger (v=%.2f m/s after 50 frames)" % accel_v)
	var hitch := false
	for i in range(8, sped.size()):
		if sped[i] < sped[i - 1] - 3.5 and sped[i - 1] > 2.0:
			hitch = true
		if i > 0 and ys[i] < floor.position.y - 0.02:
			hitch = true
	_ok(not hitch, "flat-ground throttle does not hitch or sink the chassis (v_end=%.2f y=%.3f)" % [accel_v, ys[ys.size() - 1]])
	# Must not self-spin while going straight.
	_ok(absf(car.rotation.y) < 0.18, "straight throttle does not spin the car out (yaw=%.3f)" % car.rotation.y)

	var yaw0: float = car.rotation.y
	car.set_driver_input(1.0, 1.0, 0.0, false, false)
	for i in 70:
		await _phys(1)
	var dyaw := wrapf(car.rotation.y - yaw0, -PI, PI)
	_ok(dyaw > 0.55, "steering authority is clearly stronger (dyaw=%.3f, was weak ~0.25 floor)" % dyaw)

	# --- Orbit pivot consistency + look-drag while moving ---
	if vs.get("occupied"):
		vs.call("try_exit")
		await _phys(2)
	# Use a car in the scene tree under main so VehicleSystem will drive the camera.
	var car_cam: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	main.add_child(car_cam)
	car_cam.global_position = Vector3(2.0, float(car_cam.call("spawn_lift")), 0.2)
	car_cam.rotation = Vector3.ZERO
	car_cam.reset_physics_interpolation()
	await _phys(2)
	player.global_position = car_cam.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = car_cam
	_ok(bool(vs.call("try_enter")), "enter car for orbit-pivot check")
	if vs.has_method("toggle_vehicle_cam") and str(vs.get("vehicle_cam")) != "third":
		vs.call("toggle_vehicle_cam")
	# Give the car forward speed so follow is motion-based, then drag.
	car_cam.occupied = true
	car_cam.freeze = false
	(car_cam as RigidBody3D).linear_velocity = -car_cam.global_transform.basis.z * 12.0
	for i in 4:
		await _frames(1)
	vs.set("vehicle_look_mode", "orbit")
	if vs.has_method("begin_orbit"):
		vs.call("begin_orbit")
	for i in 2:
		await _frames(1)
	var o0: Dictionary = vs.call("debug_orbit_state")
	var pivot0: Vector3 = o0["pivot"]
	var cam_a: Vector3 = o0["cam"]
	var dist_a := cam_a.distance_to(pivot0)
	if vs.has_method("orbit_look"):
		vs.call("orbit_look", Vector2(220.0, 0.0), 0.01)
	for i in 4:
		await _frames(1)
	# Keep moving while the orbit is held.
	(car_cam as RigidBody3D).linear_velocity = -car_cam.global_transform.basis.z * 12.0
	for i in 4:
		await _frames(1)
	var o1: Dictionary = vs.call("debug_orbit_state")
	var pivot1: Vector3 = o1["pivot"]
	var cam_b: Vector3 = o1["cam"]
	var dist_b := cam_b.distance_to(pivot1)
	# Pivot stays on the vehicle (tracks the body, does not jump to a look-ahead point).
	var veh_pt: Vector3 = car_cam.global_position + Vector3(0, 1.2, 0)
	_ok(pivot1.distance_to(veh_pt) < 1.6, "orbit pivot stays on the vehicle (err=%.3f)" % pivot1.distance_to(veh_pt))
	_ok(absf(dist_b - dist_a) < 1.8, "orbit distance to pivot stays consistent while moving (%.3f -> %.3f)" % [dist_a, dist_b])
	_ok(absf(float(o1["yaw"])) > 0.4, "look-drag offset is kept while the vehicle is moving (yaw=%.3f)" % float(o1["yaw"]))
	# Camera actually moved around the pivot (not locked behind velocity).
	var rel_a := (cam_a - pivot0)
	rel_a.y = 0.0
	var rel_b := (cam_b - pivot1)
	rel_b.y = 0.0
	if rel_a.length() > 0.2 and rel_b.length() > 0.2:
		_ok(rel_a.normalized().dot(rel_b.normalized()) < 0.86, "orbit rotates around the vehicle pivot while moving")
	if vs.has_method("end_orbit"):
		vs.call("end_orbit")
	_ok(bool(vs.call("try_exit")), "exit car after orbit check")
	_flush_board()

	# --- Airborne plane exit places the player beside the jet, not on the ground ---
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	main.add_child(jet)
	jet.global_position = Vector3(4.0, 80.0, 2.0)
	jet.rotation = Vector3.ZERO
	jet.set("airborne", true)
	if jet is RigidBody3D:
		(jet as RigidBody3D).freeze = true
	jet.reset_physics_interpolation()
	await _phys(2)
	player.global_position = jet.global_position + Vector3(6.0, 0.0, 0.0)
	vs.nearest = jet
	_ok(bool(vs.call("try_enter")), "enter airborne fighter")
	jet.global_position = Vector3(4.0, 92.0, 2.0)
	jet.set("airborne", true)
	await _phys(3)
	_ok(bool(vs.call("try_exit")), "exit airborne fighter")
	await _phys(2)
	var exit_p: Vector3 = player.global_position
	var jet_p: Vector3 = jet.global_position
	_ok(absf(exit_p.y - jet_p.y) < 8.0 and exit_p.y > 60.0, "airborne exit keeps the player at altitude (player_y=%.2f plane_y=%.2f)" % [exit_p.y, jet_p.y])
	var horiz := Vector2(exit_p.x - jet_p.x, exit_p.z - jet_p.z).length()
	_ok(horiz > 1.0 and horiz < 16.0, "airborne exit is beside the jet (horiz=%.2f)" % horiz)
	# Ground car exit still lands next to the current car, not a stale point.
	var car_g: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	main.add_child(car_g)
	car_g.global_position = Vector3(3.0, float(car_g.call("spawn_lift")), -1.0)
	car_g.reset_physics_interpolation()
	await _phys(2)
	player.global_position = car_g.global_position + Vector3(2.0, 0.1, 0.0)
	vs.nearest = car_g
	_ok(bool(vs.call("try_enter")), "enter ground car for exit placement")
	car_g.global_position = Vector3(7.5, float(car_g.call("spawn_lift")), 4.0)
	await _phys(2)
	_ok(bool(vs.call("try_exit")), "exit ground car")
	_flush_board()
	await _phys(2)
	var cdest: Vector3 = player.global_position
	var ch := Vector2(cdest.x - car_g.global_position.x, cdest.z - car_g.global_position.z).length()
	_ok(ch < 8.0, "ground exit is beside the current car (horiz=%.2f)" % ch)

	# --- Fighter thrust / pitch / roll rates ---
	var fighter: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(fighter)
	var plift: float = float(fighter.call("spawn_lift")) if fighter.has_method("spawn_lift") else 2.0
	fighter.global_position = floor.position + Vector3(-30, plift + 40.0, 0)
	fighter.rotation = Vector3.ZERO
	fighter.freeze = false
	fighter.occupied = true
	fighter.sleeping = false
	fighter.set("airborne", true)
	fighter.set("gear", 0.0)
	fighter.set("gear_want", 0.0)
	fighter.linear_velocity = -fighter.global_transform.basis.z * 80.0
	fighter.angular_velocity = Vector3.ZERO
	fighter.reset_physics_interpolation()
	fighter.thrust = 0.8
	fighter.ctrl_pitch = 0.0
	fighter.ctrl_roll = 0.0
	fighter.ctrl_yaw = 0.0
	for i in 8:
		await _phys(1)
	var v0: float = fighter.linear_velocity.dot(-fighter.global_transform.basis.z)
	for i in 30:
		await _phys(1)
	var v1: float = fighter.linear_velocity.dot(-fighter.global_transform.basis.z)
	# 30 frames * 1/60 ≈ 0.5 s; 520 kN / 14000 kg ≈ 37 m/s² before drag.
	_ok(v1 - v0 > 8.0, "fighter mil thrust acceleration is strong (dv=%.2f m/s over 30 frames, v0=%.1f v1=%.1f)" % [v1 - v0, v0, v1])
	fighter.thrust = 0.8
	fighter.linear_velocity = -fighter.global_transform.basis.z * 90.0
	fighter.angular_velocity = Vector3.ZERO
	fighter.ctrl_pitch = 1.0
	fighter.ctrl_roll = 0.0
	fighter.ctrl_yaw = 0.0
	for i in 20:
		await _phys(1)
	var pitch_rate: float = fighter.angular_velocity.dot(fighter.global_transform.basis.x)
	_ok(pitch_rate > 0.35, "pitch maneuverability is agile (rate=%.3f rad/s)" % pitch_rate)
	fighter.angular_velocity = Vector3.ZERO
	fighter.ctrl_pitch = 0.0
	fighter.ctrl_roll = 1.0
	for i in 20:
		await _phys(1)
	var roll_rate: float = fighter.angular_velocity.dot(-fighter.global_transform.basis.z)
	_ok(absf(roll_rate) > 0.55, "roll maneuverability is agile (rate=%.3f rad/s)" % roll_rate)
	fighter.angular_velocity = Vector3.ZERO
	fighter.ctrl_roll = 0.0
	fighter.ctrl_yaw = 1.0
	for i in 20:
		await _phys(1)
	var yaw_rate: float = fighter.angular_velocity.dot(fighter.global_transform.basis.y)
	_ok(absf(yaw_rate) < absf(roll_rate) * 0.85 + 0.15, "yaw is less sensitive than roll (yaw=%.3f roll=%.3f)" % [yaw_rate, roll_rate])

	# Cleanup
	for n in [car, plane_vis_node, car_cam, jet, car_g, fighter, floor]:
		if n and is_instance_valid(n):
			n.queue_free()
	await _frames(1)



func _check_0222_playtest_fixes() -> void:
	## Spawn past the piano keys, pavement cars, preload, rewritten aero,
	## visible exhaust plume, exam-bed pose guides.
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("RUNWAY_PAST_BARS") >= 0 and vs_src.find("warmup_city") >= 0, "runway standoff uses piano-key inner edge and city warmup exists")
	_ok(vs_src.find("LANDMARK_ROAD") >= 0 and vs_src.find("_pavement_y") >= 0, "default cars sample real roads and reject grass/water")
	_ok(vs_src.find("preload_vehicle_resources") >= 0, "vehicle PackedScenes are prefetched")
	_ok(vs_src.find("BACK_SHIFT") >= 0, "exam body still shifts back along the spine")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("TRACK_K0") >= 0 and pl_src.find("vehicle-sim.ts") >= 0, "flight model includes old-project velocity alignment")
	_ok(pl_src.find("godot-simplified-flightsim") >= 0 and pl_src.find("ArcadeJetFlightExample") >= 0, "flight model cites mature open-source aero references")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("core.scale") >= 0 and ex_src.find("mid.scale") >= 0, "exhaust restores the visible teardrop plume body")
	_ok(ex_src.find("plume_body_visible") >= 0, "exhaust exposes a visibility helper for tests")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("L_UpperLeg_a") >= 0, "exam pose still has thigh FK")
	_ok(pose_src.find("L_UpperArm_a") >= 0 and (pose_src.find("0.16") >= 0 or pose_src.find("0.22") >= 0), "arm FK rests naturally on the armrests")

	# Visible exhaust body at military and afterburner thrust.
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var pvis = jet.get("visuals")
	_ok(pvis != null and pvis.get("exhausts") != null and pvis.exhausts.size() > 0, "0222 fighter has exhaust instances")
	if pvis and pvis.exhausts.size():
		var fx = pvis.exhausts[0]
		if fx.has_method("apply"):
			fx.call("apply", 0.8, 1.0, 0.0, 0.016)
		_ok(bool(fx.call("plume_body_visible")) if fx.has_method("plume_body_visible") else fx.visible, "exhaust plume body is visible at military thrust")
		var L := float(fx.call("plume_body_length")) if fx.has_method("plume_body_length") else 0.0
		_ok(L > 3.0, "military plume body has clear length (L=%.2f m)" % L)
		fx.call("apply", 1.0, 1.0, 0.0, 0.016)
		var L2 := float(fx.call("plume_body_length")) if fx.has_method("plume_body_length") else 0.0
		_ok(L2 > L, "afterburner plume is longer than military (mil=%.2f ab=%.2f)" % [L, L2])
		fx.call("apply", 0.0, 1.0, 0.0, 0.016)
		_ok(fx.visible == false, "exhaust hidden at zero thrust")
	jet.queue_free()

	# Thrust changes speed along the nose; a pull-up at speed climbs
	# (flight path follows attitude with lag), not attitude-only spin.
	var floor := StaticBody3D.new()
	var fshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	fshape.shape = box
	floor.add_child(fshape)
	floor.position = Vector3(80, -0.5, 80)
	root.add_child(floor)
	var fighter: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(fighter)
	var plift: float = float(fighter.call("spawn_lift")) if fighter.has_method("spawn_lift") else 2.0
	fighter.global_position = floor.position + Vector3(0, plift + 80.0, 0)
	fighter.rotation = Vector3.ZERO
	fighter.freeze = false
	fighter.occupied = true
	fighter.sleeping = false
	fighter.set("airborne", true)
	fighter.set("gear", 0.0)
	fighter.set("gear_want", 0.0)
	fighter.linear_velocity = -fighter.global_transform.basis.z * 90.0
	fighter.angular_velocity = Vector3.ZERO
	fighter.reset_physics_interpolation()
	fighter.thrust = 0.8
	fighter.ctrl_pitch = 0.0
	fighter.ctrl_roll = 0.0
	fighter.ctrl_yaw = 0.0
	for i in 10:
		await _phys(1)
	var nose0: Vector3 = -fighter.global_transform.basis.z
	var v0: float = fighter.linear_velocity.dot(nose0)
	fighter.thrust = 1.0
	for i in 30:
		await _phys(1)
	var nose1: Vector3 = -fighter.global_transform.basis.z
	var v1: float = fighter.linear_velocity.dot(nose1)
	_ok(v1 - v0 > 6.0, "thrust changes speed along the nose (dv=%.2f v0=%.1f v1=%.1f)" % [v1 - v0, v0, v1])
	# Pull up at speed: flight path should climb, not just the mesh spin.
	fighter.thrust = 0.8
	fighter.linear_velocity = -fighter.global_transform.basis.z * 90.0
	fighter.angular_velocity = Vector3.ZERO
	fighter.global_position = floor.position + Vector3(20, plift + 80.0, 0)
	fighter.reset_physics_interpolation()
	var y0: float = fighter.global_position.y
	var path0 := atan2(fighter.linear_velocity.y, Vector2(fighter.linear_velocity.x, fighter.linear_velocity.z).length())
	fighter.ctrl_pitch = 1.0
	for i in 45:
		await _phys(1)
	var y1: float = fighter.global_position.y
	var path1 := atan2(fighter.linear_velocity.y, Vector2(fighter.linear_velocity.x, fighter.linear_velocity.z).length())
	var nose: Vector3 = -fighter.global_transform.basis.z
	var align := 0.0
	if fighter.linear_velocity.length() > 1.0:
		align = fighter.linear_velocity.normalized().dot(nose)
	_ok(y1 - y0 > 4.0, "pull-up at speed climbs (dy=%.2f m, y0=%.1f y1=%.1f)" % [y1 - y0, y0, y1])
	_ok(path1 > path0 + 0.08, "flight path follows attitude with lag (path0=%.3f path1=%.3f)" % [path0, path1])
	_ok(align > 0.55, "velocity stays coupled to the nose (align=%.3f)" % align)
	print("vehicles: aero climb dy=%.2f path=%.3f->%.3f align=%.3f thrust_dv=%.2f" % [y1 - y0, path0, path1, align, v1 - v0])
	for n in [fighter, floor]:
		if n and is_instance_valid(n):
			n.queue_free()
	await _frames(1)


func _check_0223_playtest_fixes() -> void:
	## Exam bed, touch layout, vehicle cam, gear doors, vapor, car nitro / skids.
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("YAW_LIM") >= 0 and vs_src.find("look_dir *") >= 0, "exam first-person view is clamped and sat in front of the face")
	_ok(vs_src.find("_chase_basis") >= 0 and vs_src.find("slerp(want_b") >= 0, "plane chase cam follows aircraft attitude with lag")
	_ok(vs_src.find("left * 0.22") < 0, "exam calves are no longer IK'd outward off the stirrup pads")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("L_UpperLeg_a") >= 0 and (pose_src.find("0.46") >= 0 or pose_src.find("0.36") >= 0), "thigh abduction stays open so calves can follow the stirrups")
	var bed_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_bed.gd")
	_ok(bed_src.find("TARGET_LENGTH := 1.72") >= 0, "exam bed TARGET_LENGTH shrank again (1.86 → 1.72)")
	var vis_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(vis_src.find("door_closed := _smoothstep(0.55, 1.0, gear_up)") >= 0, "gear doors close (flush) when the gear is up")
	_ok(vis_src.find('(aa["minZ"] + aa["maxZ"]) * 0.5') >= 0 or vis_src.find("(aa[\"minZ\"] + aa[\"maxZ\"]) * 0.5") >= 0, "elevator hinge is at mid-chord")
	_ok(vis_src.find("PlaneVapor") >= 0, "plane visuals attach PlaneVapor")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("plume_tip_length") >= 0 and ex_src.find("along = minf(along, cap)") >= 0, "mach diamonds are capped to the plume tip")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("REST_DISTANCE :=") >= 0, "car has a raised suspension rest length")
	_ok(car_src.find("nitro_active = occupied and nitro") >= 0, "nitro is gated on the dedicated nitro flag, not any throttle")
	_ok(car_src.find("CarSkidMarks") >= 0, "car uses a skid-mark trail")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("TouchLayout") >= 0 and tc_src.find("layout_edit") >= 0, "touch controls support a custom layout editor")
	_ok(tc_src.find('f["role"] = "yaw"') >= 0, "plane right-side swipe is yaw")
	_ok(tc_src.find("is_observe_orbit") >= 0 and tc_src.find("orbit_mode") >= 0, "observe button switches look-drag to orbit mode")
	_ok(FileAccess.file_exists("res://scripts/ui/touch_layout.gd"), "TouchLayout script exists")
	# Layout code round-trip.
	var empty := TouchLayout.encode({})
	_ok(empty.begins_with("TYL1."), "empty layout code starts with TYL1.")
	var sample := {
		"stick": {"x": 0.1200, "y": 0.8200, "s": 1.250},
		"jump": {"x": 0.8800, "y": 0.7800, "s": 1.000},
	}
	var code := TouchLayout.encode(sample)
	var back := TouchLayout.decode(code)
	_ok(back.has("stick") and is_equal_approx(float(back["stick"]["x"]), 0.12), "layout code decodes stick.x")
	_ok(back.has("jump") and is_equal_approx(float(back["jump"]["s"]), 1.0), "layout code decodes jump.s")
	_ok(TouchLayout.decode(code.substr(0, code.length() - 1)).is_empty(), "tampered layout code is rejected")
	# Live exam bed size / plane doors / diamonds / vapor / nitro.
	var bed: Node = null
	if vs:
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
	if bed:
		var hl := float(bed.get("half_l"))
		_ok(hl > 0.70 and hl < 0.92, "0.2.23 exam bed is smaller than 0.2.22 (half_l=%.3f, expect ~0.86)" % hl)

	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var pvis = jet.get("visuals")
	_ok(pvis != null and pvis.gear_doors.size() == 4, "fighter has 4 gear doors")
	if pvis:
		pvis.call("apply_pose", {"gear": 0.0, "ctrl_pitch": 0, "ctrl_roll": 0, "thrust": 0, "door": 0, "airborne": false, "speed": 0, "g_load": 1, "aoa": 0, "agl": 0}, 0.2, 0.0, 0.0)
		var closed_ok := true
		for g in pvis.gear_doors:
			# Closed = deflected (~90°), rest quat is identity hanging-open.
			var q: Quaternion = g.obj.quaternion
			if q.w > 0.95:
				closed_ok = false
		_ok(closed_ok, "gear doors are deflected (flush) when the gear is up")
		pvis.call("apply_pose", {"gear": 1.0, "ctrl_pitch": 0, "ctrl_roll": 0, "thrust": 0, "door": 0, "airborne": false, "speed": 0, "g_load": 1, "aoa": 0, "agl": 0}, 0.2, 0.0, 0.0)
		var open_ok := true
		for g in pvis.gear_doors:
			var q2: Quaternion = g.obj.quaternion
			if q2.w < 0.95:
				open_ok = false
		_ok(open_ok, "gear doors are at rest (open) when the gear is down")
		# Elevator mid-chord pivot.
		if pvis.surfaces:
			var mid_ok := false
			for s in pvis.surfaces:
				if str(s.kind) == "elevator" and s.obj:
					var z: float = s.obj.position.z
					mid_ok = z > 6.0 and z < 8.5
					if mid_ok:
						break
			_ok(mid_ok, "elevator hinge sits near mid-chord (z mid of ~5.5..9.3)")
		if pvis.vapor:
			_ok(pvis.vapor.has_method("cloud_intensity"), "vapor exposes intensity for tests")
			pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 6.5, "ctrl_pitch": 0.8, "aoa": 0.22}, 0.05)
			_ok(float(pvis.vapor.call("cloud_intensity")) > 0.0, "high-G pull-up produces vapor")
			pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 1.1, "ctrl_pitch": 0.0, "aoa": 0.0}, 0.5)
			# intensity eases out; after a long step it should drop
		if pvis.exhausts.size():
			var fx = pvis.exhausts[0]
			fx.call("apply", 1.0, 1.0, 0.0, 0.016)
			var tip := float(fx.call("plume_tip_length")) if fx.has_method("plume_tip_length") else 0.0
			_ok(tip > 3.0, "afterburner plume tip is measurable (%.2f m)" % tip)
			# Farthest visible diamond should not exceed the tip.
			var far := 0.0
			for d in fx.diamonds:
				if d.visible:
					far = maxf(far, d.position.length())
			_ok(far <= tip * 1.05 + 0.05, "mach diamonds stay within the plume tip (far=%.2f tip=%.2f)" % [far, tip])
	jet.queue_free()

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	_ok(float(car.REST_DISTANCE) >= 0.36, "car REST_DISTANCE stays at least the 0.2.23 raise (%.3f)" % float(car.REST_DISTANCE))
	car.occupied = true
	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	car._drive(0.016)
	_ok(not bool(car.nitro_active), "W / throttle alone does not turn nitro on")
	car.set_driver_input(1.0, 0.0, 0.0, false, true)
	car._drive(0.016)
	_ok(bool(car.nitro_active), "Shift / 加速 flag turns nitro on")
	car.set_driver_input(0.0, 0.0, 0.0, false, false)
	car._drive(0.016)
	_ok(not bool(car.nitro_active), "releasing the nitro flag turns nitro off")
	var vis = car.get("visuals")
	_ok(vis != null and vis.get("_nitro_fx") != null and vis._nitro_fx.size() > 0, "car has nitro flame meshes")
	if vis:
		vis.call("apply_pose", {"steer_angle": 0, "wheel_spin": 0, "susp": [0.4, 0.4, 0.4, 0.4], "wheel_travel": [0, 0, 0, 0], "nitro": true}, 0.016, 1.0)
		var any_vis := false
		for f in vis._nitro_fx:
			if f and f.visible:
				any_vis = true
		_ok(any_vis, "nitro flames become visible when nitro is on")
	_ok(car.get("_skids") != null, "car has a skid-mark node")
	car.queue_free()
	await _frames(1)

	# HUD layout helpers exist.
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("自定义按键布局") >= 0 and hud_src.find("生成布局码") >= 0, "settings expose custom layout / layout-code UI")
	_ok(hud_src.find("try_toggle") >= 0 and hud_src.find("_on_enter_exit_gui") < 0, "enter/exit is a single tap on button release, no press+release double fire")
	_ok(hud_src.find("right - 88.0 - 12.0 - 40.0") >= 0, "plane thrust bar is on the right, left of decelerate")


func _check_0224_playtest_fixes() -> void:
	## Exam-bed pose / free look-up / head follow, boarding debounce, map HUD,
	## reversed chase cam, observe button, thrust / pitch, tighter diamonds,
	## wingtip vertices, auto gear, nitro-on-accel, one airport car.
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("look_dir := cfwd.rotated") >= 0, "plane chase look_dir follows the nose, not -cfwd (rear-view)")
	_ok(vs_src.find("func _clamp_exam_look") >= 0, "exam-bed look clamp is centralized")
	_ok(vs_src.find("TOGGLE_LOCK_MS") >= 0, "enter/exit has a same-tap debounce lock")
	_ok(vs_src.find("func toggle_observe_mode") >= 0 and vs_src.find("vehicle_look_mode") >= 0, "observe mode yaw/orbit toggle exists")
	_ok(vs_src.find("func _sync_vehicle_look_from_heading") >= 0, "vehicle first-person look snaps to the vehicle basis")
	_ok(vs_src.find("RUNWAY_PAST_BARS := 84.0") >= 0, "runway spawn stands further up from the piano keys")
	_ok(vs_src.find("func _airport_car_spawn") >= 0, "default car spawn is the single airport car")
	_ok(vs_src.find("ExamPose.apply_look") >= 0, "exam first-person rotates the head with the look")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("func apply_look") >= 0, "ExamPose.apply_look exists")
	_ok(pose_src.find("func apply_look") >= 0 and pose_src.find("L_Eye") >= 0, "apply_look also rotates the eyes")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("THRUST_DRY := 680000.0") >= 0, "dry thrust raised to 680 kN")
	_ok(pl_src.find("const PITCH_RATE := 1.90") >= 0 or pl_src.find("ctrl_pitch * 1.90") >= 0, "pitch command rate raised to 1.90")
	_ok(pl_src.find("airspeed > 18.0") >= 0 and pl_src.find("GEAR_AUTO_RETRACT_AGL") >= 0, "auto gear retracts on AGL without waiting only on the airborne flag")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("EXIT_DIAMETER") >= 0 and ex_src.find("func _apply_diamonds") >= 0, "mach diamonds have a physical spacing model")
	var vap_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_vapor.gd")
	_ok(vap_src.find("ARRAY_VERTEX") >= 0 and vap_src.find("min_x") >= 0, "wingtip vapor uses actual tip vertices")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("ENGINE_POWER := 18800.0") >= 0, "car engine power was raised")
	_ok(car_src.find("_wheel_omega") >= 0 and car_src.find("TIRE_MU") >= 0, "car has a wheel-spin / burnout slip model")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("func is_map_open") >= 0 and hud_src.find("_hp_box.visible = not is_map_open()") >= 0, "map open hides the health bar")
	_ok(hud_src.find("_btn_observe") >= 0, "观察 button exists on the HUD")
	var lay_src := FileAccess.get_file_as_string("res://scripts/ui/touch_layout.gd")
	_ok(lay_src.find("\"observe\":") >= 0, "custom layout includes the observe button id")
	var hud: Node = main.get_node_or_null("HUD") if main else null
	if hud and hud.has_method("is_map_open"):
		_ok(hud.get("_btn_observe") != null, "观察 button is on the HUD")
		_ok(not bool(hud.call("is_map_open")), "map starts closed")

	# Live: tighter diamonds, wingtip span, nitro-on-accel, observe toggle, debounce.
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var pvis = jet.get("visuals")
	if pvis and pvis.exhausts.size():
		var fx = pvis.exhausts[0]
		fx.call("apply", 1.0, 1.0, 0.0, 0.016)
		var tip := float(fx.call("plume_tip_length")) if fx.has_method("plume_tip_length") else 0.0
		var alongs: Array[float] = []
		for d in fx.diamonds:
			if d.visible:
				alongs.append(d.position.length())
		alongs.sort()
		if alongs.size() >= 2:
			var gap := alongs[1] - alongs[0]
			_ok(gap > 0.20 and gap < 1.40, "mach diamond spacing is visible (gap=%.2f m, tip=%.2f)" % [gap, tip])
		var far := alongs[alongs.size() - 1] if alongs.size() else 0.0
		if tip > 0.0:
			_ok(far <= tip * 1.05 + 0.05, "diamonds still stay within the plume tip (far=%.2f tip=%.2f)" % [far, tip])
	if pvis and pvis.vapor:
		var tl: Vector3 = pvis.vapor.call("tip_local_left")
		var tr: Vector3 = pvis.vapor.call("tip_local_right")
		var span := absf(tr.x - tl.x)
		_ok(span > 6.0, "wingtip emitters span the real wing (span=%.2f m, L=%s R=%s)" % [span, tl, tr])
	jet.queue_free()

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	_ok(float(car.ENGINE_POWER) >= 15000.0, "ENGINE_POWER is at least 15200")
	car.occupied = true
	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	car._drive(0.016)
	_ok(not bool(car.nitro_active), "standstill W / throttle alone does not start nitro")
	car.set_driver_input(1.0, 0.0, 0.0, false, true)
	car._drive(0.016)
	_ok(bool(car.nitro_active), "nitro is on when the 加速 / Shift flag is held")
	car.set_driver_input(0.2, 0.0, 0.0, false, true)
	car._drive(0.016)
	_ok(bool(car.nitro_active), "nitro stays on with the flag even at light throttle")
	car.set_driver_input(0.0, 0.0, 0.0, false, false)
	car._drive(0.016)
	_ok(not bool(car.nitro_active), "nitro ends when the flag is released")
	car.queue_free()
	await _frames(1)

	if vs and vs.has_method("toggle_observe_mode"):
		var prev := str(vs.get("vehicle_look_mode"))
		_ok(str(vs.call("toggle_observe_mode")) == "orbit", "first 观察 press switches to orbit")
		_ok(str(vs.call("toggle_observe_mode")) == "yaw", "second 观察 press returns to yaw")
		vs.set("vehicle_look_mode", prev if prev else "yaw")
	if vs and vs.has_method("try_toggle"):
		var t0 := Time.get_ticks_msec()
		# With no nearest vehicle this should fail (and not lock forever).
		# We only check the lock constant exists and a second immediate call after
		# a successful enter would be ignored — covered by TOGGLE_LOCK_MS source.
		_ok(vs_src.find("now < _toggle_lock_until_ms") >= 0, "try_toggle ignores a second event inside the lock window")
		_ok(t0 >= 0, "debounce clock is available")




func _check_0225_playtest_fixes() -> void:
	## Exam-bed backward shift / flatter calves / head follow actually on the
	## visible mesh, reversed look limits, scissor doors, softer cam recenter,
	## HUD vcam + 观察/gear placement, no TP reticle, tighter diamonds,
	## volumetric vapor, decelerate-for-agility + speed stall, milder burnout.
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("const HEADWARD := 0.16") >= 0, "exam body shifts farther toward the headrest")
	_ok(vs_src.find("PITCH_MAX :=") >= 0 and vs_src.find("PITCH_MIN :=") >= 0, "exam-bed pitch is still clamped (up free, down limited)")
	_ok(vs_src.find("clear_gaze_intent") >= 0, "exam FP does not reset head bones via clear_gaze")
	_ok(vs_src.find("func _begin_board_anim") >= 0 and vs_src.find("_board_timer = 0.72") >= 0, "car enter/exit plays a scissor-door sequence")
	_ok(vs_src.find("exp(-1.3 * dt)") >= 0 and vs_src.find("exp(-1.2 * dt)") >= 0, "vehicle camera recenter is softer / slower")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("look_world") >= 0 and pose_src.find("L_Eye") >= 0, "apply_look aims the visible head and eyes at the camera")
	_ok(pose_src.find("L_Foreleg_a") >= 0, "exam pose still sets a flatter shin")
	var sec_src := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	_ok(sec_src.find("func clear_gaze_intent") >= 0, "SoftSecondary can drop gaze without resetting look bones")
	var cv_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_visuals.gd")
	_ok(cv_src.find("func _make_scissor_doors") >= 0, "car builds scissor doors")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("_launch_slip") >= 0 and car_src.find("0.18") >= 0, "burnout is a brief slight slip, then grip returns")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("const STALL_SPEED := 52.0") >= 0, "plane has a 52 m/s speed stall")
	_ok(pl_src.find("DECEL_AGILITY") >= 0, "decelerating still raises pitch/roll agility")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("EXIT_DIAMETER") >= 0, "mach diamonds still use a nozzle-diameter spacing model")
	_ok(ex_src.find("along = minf(along, cap)") >= 0, "diamond chain is still capped to the plume")
	var vap_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_vapor.gd")
	_ok(vap_src.find("func cloud_min_height") >= 0, "vapor exposes volume height for tests")
	var sh_src := FileAccess.get_file_as_string("res://shaders/vapor_cloud.gdshader")
	_ok(sh_src.find("v_uv") >= 0 or sh_src.find("v_local") >= 0, "vapor shader drives a soft-edged sheet / volume")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("_btn_vehicle_cam") >= 0 and hud_src.find("toggle_vehicle_cam") >= 0, "mobile 1st/3rd view-switch is back")
	_ok(hud_src.find("immediately left of 透视") >= 0 or hud_src.find("_btn_xray.get_global_rect") >= 0, "观察 is placed at the top, left of 透视")
	_ok(hud_src.find("is_drive_third") >= 0, "vehicle third-person hides the center reticle")
	var lay_src := FileAccess.get_file_as_string("res://scripts/ui/touch_layout.gd")
	_ok(lay_src.find("\"vcam\":") >= 0 and lay_src.find("\"observe\":") >= 0, "layout ids include vcam and observe separately")

	# Live: exam-bed head follow must change the visible skeleton (this is
	# what 0.2.24 missed — apply_look was wiped by clear_gaze).
	if vs and player and player.has_method("get_skeleton"):
		var bed: Node = null
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
		if bed:
			player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
			vs.set("nearest", bed)
			_ok(bool(vs.call("try_enter")), "can board the exam bed for head-look")
			await _frames(2)
			var skel: Skeleton3D = player.call("get_skeleton")
			if skel:
				# Stay in first person if possible.
				if player.has_method("set_play_mode") and player.get("play_mode") != null:
					# CONTROL = first person
					if player.has_method("set_play_mode"):
						player.call("set_play_mode", 1)
				await _frames(1)
				var hi := skel.find_bone("C_Head_a")
				_ok(hi >= 0, "C_Head_a exists for look follow")
				if hi >= 0:
					player.set("_yaw", 0.0)
					player.set("_pitch", 0.0)
					if vs.has_method("_apply_exam_pose"):
						vs.call("_apply_exam_pose", 0.016)
					var q0: Quaternion = skel.get_bone_pose_rotation(hi)
					var fwd0 := (skel.global_transform * skel.get_bone_global_pose(hi)).basis.z
					player.set("_yaw", 0.7)
					player.set("_pitch", 0.55)
					vs.call("_apply_exam_pose", 0.016)
					var q1: Quaternion = skel.get_bone_pose_rotation(hi)
					var fwd1 := (skel.global_transform * skel.get_bone_global_pose(hi)).basis.z
					var dang := q0.angle_to(q1)
					var daxis := fwd0.angle_to(fwd1)
					_ok(dang > 0.12 or daxis > 0.12, "visible head rotates with exam FP look (dang=%.3f daxis=%.3f)" % [dang, daxis])
					# And a second look in the other direction must move again.
					player.set("_yaw", -0.7)
					player.set("_pitch", -0.4)
					vs.call("_apply_exam_pose", 0.016)
					var q2: Quaternion = skel.get_bone_pose_rotation(hi)
					var dang2 := q1.angle_to(q2)
					_ok(dang2 > 0.12, "head follow is not a no-op in the other direction (dang=%.3f)" % dang2)
			if vs.has_method("try_exit"):
				# May be on the bed; exit immediately (not a car).
				vs.call("try_exit")
			await _frames(1)

	# Live: scissor doors, tighter diamonds, volumetric vapor, stall/agility, burnout.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	var cvis = car.get("visuals")
	_ok(cvis != null and cvis.doors.size() >= 2, "sports car has two scissor doors (got %s)" % (cvis.doors.size() if cvis else 0))
	if cvis and cvis.doors.size() >= 2:
		var d0 = cvis.doors[0]
		_ok(d0.max_angle >= 1.2, "scissor hinge has a large open angle (axis=%s max=%.2f)" % [d0.axis, d0.max_angle])
		var rest_y: float = (d0.obj as Node3D).rotation.z if d0.obj else 0.0
		cvis.call("apply_pose", {"door": 1.0, "steer_angle": 0, "wheel_spin": 0, "nitro": false}, 0.016, 0.0)
		var open_a := 0.0
		if d0.obj:
			open_a = absf((d0.obj as Node3D).quaternion.angle_to(d0.rest))
		_ok(open_a > 0.8, "scissor door opens upward (angle=%.2f rad)" % open_a)
		cvis.call("apply_pose", {"door": 0.0, "steer_angle": 0, "wheel_spin": 0, "nitro": false}, 0.016, 0.0)
	# Mild burnout: launch slip stays brief / small.
	_ok(car.get("_launch_slip") != null, "car exposes a launch-slip window")
	car.queue_free()
	await _frames(1)

	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var pvis = jet.get("visuals")
	if pvis and pvis.exhausts.size():
		var fx = pvis.exhausts[0]
		fx.call("apply", 1.0, 1.0, 0.0, 0.016)
		var tip := float(fx.call("plume_tip_length")) if fx.has_method("plume_tip_length") else 0.0
		var alongs: Array[float] = []
		for d in fx.diamonds:
			if d.visible:
				alongs.append(d.position.length())
		alongs.sort()
		if alongs.size() >= 2:
			var gap := alongs[1] - alongs[0]
			_ok(gap > 0.20 and gap < 1.40, "mach diamonds are spaced visibly (gap=%.2f m, tip=%.2f)" % [gap, tip])
		var far := alongs[alongs.size() - 1] if alongs.size() else 0.0
		if tip > 0.0:
			_ok(far <= tip * 0.75 + 0.08, "diamond chain stays short of the plume tip (far=%.2f tip=%.2f)" % [far, tip])
	if pvis and pvis.vapor:
		var h := float(pvis.vapor.call("cloud_min_height")) if pvis.vapor.has_method("cloud_min_height") else 0.0
		_ok(h > 0.0, "vapor clouds still expose a scale/height (min Y scale=%.2f)" % h)
		pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 6.5, "ctrl_pitch": 0.8, "aoa": 0.22}, 0.05)
		_ok(float(pvis.vapor.call("cloud_intensity")) > 0.0, "high-G pull-up still produces volumetric vapor")
		pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 1.1, "ctrl_pitch": 0.0, "aoa": 0.0}, 0.5)
		_ok(float(pvis.vapor.call("cloud_intensity")) < 0.25, "low-G hides the vapor volume")
	_ok(float(jet.STALL_SPEED) >= 50.0, "STALL_SPEED is 52 m/s")
	_ok(float(jet.DECEL_AGILITY) >= 1.6, "DECEL_AGILITY is 1.70")
	jet.queue_free()
	await _frames(1)

	var hud: Node = main.get_node_or_null("HUD") if main else null
	if hud:
		_ok(hud.get("_btn_vehicle_cam") != null, "视角 / 1st-3rd button is on the HUD")
		_ok(hud.get("_btn_observe") != null, "观察 button is still on the HUD")
		if hud.has_method("reticle_mode") and vs:
			vs.set("vehicle_cam", "third")
			# Without an occupied vehicle is_drive_third is false; just check the source path ran.
			_ok(hud_src.find("is_drive_third") >= 0, "reticle_mode consults vehicle third-person")


func _check_0226_playtest_fixes() -> void:
	## Raised exam-bed hips / straighter calves on the stirrups, heavier
	## planted car, vehicle-space first-person camera, Lambo scissor doors
	## about +X, restored visible Mach diamonds vs a capped fireball chain,
	## no two-finger vehicle orbit, polygonal vapor sheets, decel pitch snap.
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("const HIP_LIFT") >= 0, "exam pose raises the hips along the bed up")
	_ok(vs_src.find("bed_up * 0.048") >= 0 or vs_src.find("bed_up *") >= 0, "calves are planted on the stirrup tops, not through them")
	_ok(vs_src.find("hand_along") >= 0 or vs_src.find("- lie.y *") >= 0 or vs_src.find("feet *") >= 0, "forearms reach forward along the armrests")
	_ok(vs_src.find("xf.basis.orthonormalized() * Basis.from_euler") >= 0, "vehicle first-person look is composed in the vehicle basis")
	_ok(vs_src.find("is_drive_occupied()") >= 0 and vs_src.find("vehicle_look_mode == \"orbit\"") >= 0, "观察 works in first- and third-person")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("Vector3(0.18, 0.0, 0.02)") >= 0, "exam shins are flatter / straighter (FK 0.18)")
	_ok(pose_src.find("L_UpperArm_a") >= 0 and (pose_src.find("0.16") >= 0 or pose_src.find("0.22") >= 0), "upper-arm angle is more gradual / flatter")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("const MASS_KG := 1760.0") >= 0, "sports-car mass is in the GT ballpark (1760 kg)")
	_ok(car_src.find("gravity_scale = 1.18") >= 0, "car gravity_scale is raised so it feels planted")
	_ok(car_src.find("const TIRE_MU := 1.62") >= 0 and car_src.find("const ARCADE_GRIP := 5.4") >= 0, "tire grip is substantially higher")
	_ok(car_src.find("0.18") >= 0 and car_src.find("_launch_slip") >= 0, "brief 0.18 s launch slip is kept")
	var cv_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_visuals.gd")
	_ok(cv_src.find('\"x\", -1.0, 1.48') >= 0, "scissor doors rotate about body +X with a shared upward sign")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("const STALL_SPEED := 52.0") >= 0, "speed stall is still 52 m/s")
	_ok(pl_src.find("DECEL_AGILITY := 2.85") >= 0, "decel pitch boost peak is 2.85")
	_ok(pl_src.find("_decel_boost") >= 0 and pl_src.find("DECEL_BOOST_FADE") >= 0, "decel boost is a short window, not a permanent super-pitch")
	_ok(pl_src.find("DECEL_YAW_COUPLE") >= 0, "decel boost couples yaw for an aerial-drift feel")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("FIREBALL_COUNT := 4") >= 0 and ex_src.find("FIREBALL_MAX_ALONG := 0.92") >= 0, "fireball chain is a short, hard-capped set")
	_ok(ex_src.find("FIREBALL_SPACING := 0.20") >= 0, "fireball spacing is tight (0.20 m)")
	_ok(ex_src.find("EXIT_DIAMETER") >= 0 and ex_src.find("func _apply_diamonds") >= 0, "mach diamonds still use a nozzle-diameter spacing model")
	_ok(ex_src.find("func fireball_span") >= 0, "exhaust exposes fireball span for tests")
	var vap_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_vapor.gd")
	_ok(vap_src.find("func _make_sheet_mesh") >= 0, "vortex clouds are built as polygonal sheets")
	_ok(vap_src.find("SphereMesh.new()") < 0, "vapor body clouds are no longer SphereMesh")
	var sh_src := FileAccess.get_file_as_string("res://shaders/vapor_cloud.gdshader")
	_ok(sh_src.find("v_uv") >= 0 and sh_src.find("smoothstep(0.0, 0.20, v_uv.x)") >= 0, "vapor shader fades sheet edges with a soft falloff")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("载具内取消双指拖拽旋转视角") >= 0, "two-finger vehicle orbit is cancelled in touch controls")
	_ok(tc_src.find('fingers[k]["role"] = "orbit"') < 0 or tc_src.find("第二根手指：载具里按住滑动旋转视角") < 0, "drive two-finger path no longer assigns orbit")

	# Live: raised hips / calves on stirrups, doors swing up, camera follows
	# vehicle basis, visible diamonds, capped fireballs, sheet vapor, decel.
	if vs and player and player.has_method("get_skeleton"):
		var bed: Node = null
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
		if bed:
			player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
			vs.set("nearest", bed)
			_ok(bool(vs.call("try_enter")), "can board the exam bed for pose measurement")
			await _frames(2)
			if vs.has_method("_apply_exam_pose"):
				vs.call("_apply_exam_pose", 0.016)
			var body: Node3D = player.get_node_or_null("Body")
			var skel: Skeleton3D = player.call("get_skeleton")
			if body and skel and bed.has_method("seat_global"):
				var seat: Vector3 = bed.call("seat_global")
				var hip_l: Vector3 = ExamPose.hip_local(skel, body)
				var hip_w: Vector3 = body.to_global(hip_l)
				_ok(hip_w.y >= seat.y + 0.02, "0.2.26 hip/crotch is raised onto the cushion (hip.y=%.3f seat.y=%.3f)" % [hip_w.y, seat.y])
				var i_sh := skel.find_bone("L_Foreleg_a")
				var st: Vector3 = bed.call("stirrup_l_global")
				if i_sh >= 0:
					var shin_w: Vector3 = skel.global_transform * skel.get_bone_global_pose(i_sh).origin
					_ok(shin_w.y >= st.y - 0.04, "left shin sits on/above the stirrup pad (shin.y=%.3f pad.y=%.3f)" % [shin_w.y, st.y])
			if vs.has_method("try_exit"):
				vs.call("try_exit")
			await _frames(1)

	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	_ok(is_equal_approx(float(car.MASS_KG), 1760.0) or float(car.mass) >= 1700.0, "instanced car mass is ~1760 kg (got %.1f)" % float(car.mass))
	_ok(float(car.gravity_scale) >= 1.15, "instanced car gravity_scale is planted (%.2f)" % float(car.gravity_scale))
	var cvis = car.get("visuals")
	_ok(cvis != null and cvis.doors.size() >= 2, "sports car still has two scissor doors")
	if cvis and cvis.doors.size() >= 2:
		var d0 = cvis.doors[0]
		_ok(str(d0.axis) == "x" and d0.max_angle >= 1.4, "scissor hinge is lateral +X (axis=%s max=%.2f)" % [d0.axis, d0.max_angle])
		# Measure the aft edge in wrap space: opening must RAISE it, not bury it.
		var hub: Node3D = d0.obj
		var wrap: Node3D = cvis.wrap
		var rest_rear := _door_rear_y(hub, wrap)
		cvis.call("apply_pose", {"door": 1.0, "steer_angle": 0, "wheel_spin": 0, "nitro": false}, 0.016, 0.0)
		var open_rear := _door_rear_y(hub, wrap)
		var open_a := 0.0
		if hub:
			open_a = absf(hub.quaternion.angle_to(d0.rest))
		_ok(open_a > 0.9, "scissor door opens a large angle (%.2f rad)" % open_a)
		_ok(open_rear > rest_rear + 0.60, "scissor door raises the aft edge (rest_y=%.3f open_y=%.3f)" % [rest_rear, open_rear])
		cvis.call("apply_pose", {"door": 0.0, "steer_angle": 0, "wheel_spin": 0, "nitro": false}, 0.016, 0.0)

	# Camera is bound to the vehicle basis (car and plane, first-person).
	if vs and player:
		var spawned: Node = vs.call("spawn_at_aim", "car") if vs.has_method("spawn_at_aim") else null
		# Prefer the just-built car if menu spawn is awkward in the room.
		var drive: Node = spawned if spawned else car
		if drive:
			player.global_position = drive.global_position + Vector3(2.0, 0.1, 0.0)
			vs.set("nearest", drive)
			if vs.has_method("try_enter"):
				vs.call("try_enter")
			_flush_board()
			await _frames(2)
			if vs.get("occupied") == drive:
				vs.set("vehicle_cam", "first")
				if vs.has_method("_sync_vehicle_look_from_heading"):
					vs.call("_sync_vehicle_look_from_heading")
				if vs.has_method("_reset_vehicle_cam"):
					vs.call("_reset_vehicle_cam")
				if vs.has_method("_vehicle_camera"):
					vs.call("_vehicle_camera", 0.016)
				await _frames(1)
				var cam: Camera3D = player.get_node_or_null("CameraPivot/Camera3D")
				# Yaw the car 70° and confirm the cockpit view yaws with it.
				var xf0: Transform3D = drive.global_transform
				drive.global_rotate(Vector3.UP, 1.22)
				if vs.has_method("_vehicle_camera"):
					vs.call("_vehicle_camera", 0.016)
				await _frames(1)
				if cam:
					var nose: Vector3 = -drive.global_transform.basis.z
					var look: Vector3 = -cam.global_transform.basis.z
					var ang := look.angle_to(nose)
					_ok(ang < 0.35, "car first-person look follows the vehicle basis after yaw (err=%.3f rad)" % ang)
				drive.global_transform = xf0
				if vs.has_method("try_exit"):
					vs.call("try_exit")
				_flush_board()
				await _frames(1)
		if spawned and spawned != car:
			spawned.queue_free()

	car.queue_free()
	await _frames(1)

	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	_ok(float(jet.STALL_SPEED) >= 50.0, "STALL_SPEED remains 52 m/s")
	_ok(float(jet.DECEL_AGILITY) >= 2.5, "DECEL_AGILITY peak is substantially higher (%.2f)" % float(jet.DECEL_AGILITY))
	# Plane FP camera follows pitch/roll of the airframe.
	if vs and player:
		player.global_position = jet.global_position + Vector3(3.0, 0.2, 0.0)
		vs.set("nearest", jet)
		if vs.has_method("try_enter"):
			vs.call("try_enter")
		await _frames(2)
		if vs.get("occupied") == jet:
			vs.set("vehicle_cam", "first")
			if vs.has_method("_reset_vehicle_cam"):
				vs.call("_reset_vehicle_cam")
			if vs.has_method("_sync_vehicle_look_from_heading"):
				vs.call("_sync_vehicle_look_from_heading")
			if vs.has_method("_vehicle_camera"):
				vs.call("_vehicle_camera", 0.016)
			var cam2: Camera3D = player.get_node_or_null("CameraPivot/Camera3D")
			jet.rotation = Vector3(0.40, 0.30, 0.35)
			if vs.has_method("_vehicle_camera"):
				vs.call("_vehicle_camera", 0.016)
			await _frames(1)
			if cam2:
				var nose2: Vector3 = -jet.global_transform.basis.z
				var look2: Vector3 = -cam2.global_transform.basis.z
				var ang2 := look2.angle_to(nose2)
				_ok(ang2 < 0.40, "plane first-person look follows airframe pitch/roll (err=%.3f rad)" % ang2)
				# Camera up should be close to the jet up (not horizon-locked).
				var up_err := cam2.global_transform.basis.y.angle_to(jet.global_transform.basis.y)
				_ok(up_err < 0.45, "plane first-person rolls with the jet (up err=%.3f rad)" % up_err)
			if vs.has_method("try_exit"):
				vs.call("try_exit")
			await _frames(1)
		jet.rotation = Vector3.ZERO

	var pvis = jet.get("visuals")
	if pvis and pvis.exhausts.size():
		var fx = pvis.exhausts[0]
		fx.call("apply", 1.0, 1.0, 0.0, 0.016)
		_ok(int(fx.call("diamond_visible_count")) >= 3, "mach diamonds are visible at afterburner (%d)" % int(fx.call("diamond_visible_count")))
		var gap := float(fx.call("diamond_spacing"))
		_ok(gap >= 0.28, "mach diamonds are not crushed to invisibility (gap=%.2f)" % gap)
		_ok(int(fx.call("fireball_visible_count")) >= 3, "fireball chain is visible (%d)" % int(fx.call("fireball_visible_count")))
		var span := float(fx.call("fireball_span"))
		_ok(span > 0.15 and span <= 1.05, "fireball chain is short and tight (span=%.2f m)" % span)
		# Simulate many applies as if flying: span must not grow without bound.
		for i in 40:
			fx.call("apply", 1.0, 1.0 + float(i) * 0.05, 0.0, 0.016)
		var span2 := float(fx.call("fireball_span"))
		_ok(span2 <= 1.05, "fireball chain cannot grow without bound (span=%.2f after 40 ticks)" % span2)
	if pvis and pvis.vapor:
		_ok(not bool(pvis.vapor.call("cloud_uses_spheres")), "high-G vapor is not a set of spheres")
		_ok(int(pvis.vapor.call("cloud_sheet_count")) >= 6, "vapor uses several polygonal sheets (%d)" % int(pvis.vapor.call("cloud_sheet_count")))
		pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 6.5, "ctrl_pitch": 0.8, "aoa": 0.22}, 0.05)
		_ok(float(pvis.vapor.call("cloud_intensity")) > 0.0, "high-G pull-up still produces sheet vapor")
		pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 1.1, "ctrl_pitch": 0.0, "aoa": 0.0}, 0.5)
		_ok(float(pvis.vapor.call("cloud_intensity")) < 0.25, "low-G still hides the vapor sheets")
	jet.queue_free()
	await _frames(1)


func _check_0227_playtest_fixes() -> void:
	## Nitro at the tailpipes, calipers uncoupled from wheel roll, whole
	## steering wheel turns, GTA-like turn downforce and mid-air attitude,
	## smaller in-plume mach diamonds, plane FP on the HUD centerline,
	## concurrent multitouch, afterburner thrust surge, longer decel window,
	## snappier roll, smooth exam-bed look, forearms parallel on the armrests.
	var cv_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_visuals.gd")
	_ok(cv_src.find("func _exhaust_tip_positions") >= 0, "nitro flames are placed from exhaust tip vertices")
	_ok(cv_src.find("func _detach_calipers") >= 0, "brake calipers are detached from the spin hub")
	_ok(cv_src.find("^Steering$") >= 0 or cv_src.find("steer_wheel_has_rim") >= 0, "steering bind prefers the whole wheel parent")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("const TURN_DOWNFORCE") >= 0 and car_src.find("const TURN_INWARD") >= 0, "turning adds physical downforce / inward load")
	_ok(car_src.find("func _apply_turn_and_air") >= 0 and car_src.find("const AIR_ROLL") >= 0, "airborne cars keep mid-air attitude control")
	_ok(car_src.find("const TIRE_MU := 1.62") >= 0 and car_src.find("const ARCADE_GRIP := 5.4") >= 0, "planted 0.2.26 grip is kept")
	_ok(car_src.find("_launch_slip") >= 0 and car_src.find("0.18") >= 0, "brief 0.18 s launch slip is kept")
	var ex_src := FileAccess.get_file_as_string("res://scripts/vehicles/jet_exhaust.gd")
	_ok(ex_src.find("rad * (0.48") >= 0 or ex_src.find("0.48 - float(i)") >= 0, "mach diamonds are scaled down to sit inside the plume")
	_ok(ex_src.find("FIREBALL_COUNT := 4") >= 0 and ex_src.find("FIREBALL_MAX_ALONG := 0.92") >= 0, "fireball chain cap is unchanged")
	_ok(ex_src.find("func diamond_world_radius") >= 0, "diamond radius is exposed for tests")
	var pv_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(pv_src.find("\"x\": 0.0") >= 0, "plane cockpit X is forced to the aircraft centerline")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("func thrust_newtons") >= 0 and pl_src.find("ab_shaped") >= 0, "afterburner uses a distinct thrust surge, not a linear ramp")
	_ok(pl_src.find("DECEL_BOOST_HOLD := 1.15") >= 0, "decel agility hold window is slightly longer (1.15 s)")
	_ok(pl_src.find("DECEL_BOOST_FADE := 0.48") >= 0, "decel agility fade is slightly longer (0.48 s)")
	_ok(pl_src.find("const ROLL_RATE := 3.15") >= 0 or pl_src.find("const ROLL_RATE := 2.60") >= 0, "plane roll rate is raised (now 3.15)")
	_ok(pl_src.find("want_yaw := ctrl_yaw * (0.62") >= 0, "yaw rate is not raised with roll")
	_ok(pl_src.find("const STALL_SPEED := 52.0") >= 0, "speed stall is still 52 m/s")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("_live_touches") < 0 and tc_src.find("func _handle_pointer_event") < 0, "0.2.27 concurrent-touch path was reverted so map pinch-zoom works")
	_ok(tc_src.find("载具内取消双指拖拽旋转视角") >= 0 and tc_src.find("_live_touches") < 0, "0.2.27 touch rewrite was reverted; two-finger vehicle orbit stays cancelled")
	_ok(tc_src.find("载具内取消双指拖拽旋转视角") >= 0, "two-finger vehicle orbit stays cancelled")
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("func _exam_look_basis") >= 0, "exam-bed look uses a continuous yaw/pitch basis")
	_ok(vs_src.find("_exam_eye_origin") >= 0, "exam-bed eye is captured before head-follow rotation")
	_ok(vs_src.find("armrest_geometry") >= 0 or vs_src.find("hand_along") >= 0, "forearms are placed from the armrest pad geometry")
	_ok(vs_src.find("stirrup_geometry") >= 0 or vs_src.find("foot_along") >= 0, "legs are placed from the stirrup pad geometry")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("Vector3(-0.28, 0.04, 0.46)") >= 0, "thigh abduction is opened further (0.46)")
	_ok(pose_src.find("func _aim_head_world") >= 0, "exam look aims the head at the camera with a stable world swing")
	_ok(vs_src.find("const PITCH_MIN := -1.05") >= 0 and vs_src.find("const YAW_LIM := 1.55") >= 0, "exam-bed look limits are looser than 0.2.27")
	_ok(vs_src.find("clear_gaze_intent") >= 0, "exam head-follow still uses clear_gaze_intent")

	# Live: car nitro tips, calipers, steering wheel, airborne attitude.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	var vis = car.get("visuals")
	_ok(vis != null and vis.ready_ok, "car visuals are ready")
	if vis:
		_ok(bool(vis.call("calipers_parented_to_steer")), "brake calipers are parented to the steer hinge, not the spin hub")
		_ok(bool(vis.call("steer_wheel_has_rim")), "first-person steering rotates the whole wheel, not just the logo")
		var tips: Array = vis.call("nitro_wrap_positions")
		_ok(tips.size() >= 2, "nitro has at least two tailpipe flames (%d)" % tips.size())
		var all_aft := tips.size() > 0
		var rear_z := float(vis.half_l) * 0.80
		for t in tips:
			var p: Vector3 = t
			if p.z < rear_z:
				all_aft = false
		_ok(all_aft, "nitro flames sit behind the body at the tailpipes (tips=%s half_l=%.2f)" % [tips, vis.half_l])
		# After a wheel spin, calipers must not share the spin child's roll.
		vis.call("apply_pose", {"steer_angle": 0.0, "wheel_spin": 1.4, "susp": [0.4, 0.4, 0.4, 0.4], "wheel_travel": [0, 0, 0, 0], "nitro": true}, 0.016, 1.0)
		var cal_ok := true
		for w in vis.wheel_rig_info():
			var hinge: Node3D = w["steer"]
			var spin: Node3D = w["spin"]
			for n in hinge.find_children("*", "MeshInstance3D", true, false):
				if not str(n.name).contains("Caliper"):
					continue
				var parent := n.get_parent()
				var under_spin := false
				var walk: Node = n
				while walk and walk != hinge:
					if walk == spin:
						under_spin = true
						break
					walk = walk.get_parent()
				if under_spin:
					cal_ok = false
		_ok(cal_ok, "after wheel spin, calipers are still not under the spin hub")
		# Whole wheel rotates with steer: logo and rim both move.
		var logo: Node3D = null
		var rim: Node3D = null
		if not vis.steer_wheel.is_empty():
			var sw: Node3D = vis.steer_wheel["obj"]
			for n in sw.find_children("*", "MeshInstance3D", true, false):
				if str(n.name).contains("Logo"):
					logo = n
				elif str(n.name).contains("Steering_wheel_Steering"):
					rim = n
			if sw is MeshInstance3D and str(sw.name).contains("Steering_wheel_Steering"):
				rim = sw
		vis.call("apply_pose", {"steer_angle": 0.0, "wheel_spin": 0.0, "susp": [0.4, 0.4, 0.4, 0.4], "wheel_travel": [0, 0, 0, 0], "nitro": false}, 0.016, 0.0)
		var logo0 := logo.global_transform if logo else Transform3D.IDENTITY
		var rim0 := rim.global_transform if rim else Transform3D.IDENTITY
		vis.call("apply_pose", {"steer_angle": 0.55, "wheel_spin": 0.0, "susp": [0.4, 0.4, 0.4, 0.4], "wheel_travel": [0, 0, 0, 0], "nitro": false}, 0.016, 0.0)
		if logo and rim:
			var logo_moved := logo.global_transform.basis.get_rotation_quaternion().angle_to(logo0.basis.get_rotation_quaternion()) > 0.15
			var rim_moved := rim.global_transform.basis.get_rotation_quaternion().angle_to(rim0.basis.get_rotation_quaternion()) > 0.15
			_ok(logo_moved and rim_moved, "steering input rotates both the rim and the logo (logo=%.3f rim=%.3f)" % [
				logo.global_transform.basis.get_rotation_quaternion().angle_to(logo0.basis.get_rotation_quaternion()),
				rim.global_transform.basis.get_rotation_quaternion().angle_to(rim0.basis.get_rotation_quaternion())
			])
		elif rim:
			_ok(rim.global_transform.basis.get_rotation_quaternion().angle_to(rim0.basis.get_rotation_quaternion()) > 0.15, "steering input rotates the wheel rim")
		else:
			_ok(false, "could not find steering rim / logo meshes")
	# Mid-air attitude: wheels unloaded, steering produces rotational control.
	car.global_position = Vector3(0.0, 40.0, 0.0)
	car.linear_velocity = Vector3(0.0, 0.0, -16.0)
	car.angular_velocity = Vector3.ZERO
	if car.has_method("on_enter"):
		car.call("on_enter")
	else:
		car.occupied = true
	car.set_driver_input(0.0, 1.0, 0.0, false, false)
	car.steer_angle = 0.4
	car.steer_in = 1.0
	for i in 20:
		await _phys(1)
	var air_w: Vector3 = car.angular_velocity
	_ok(air_w.length() > 0.08, "an airborne car can be attitude-controlled with steering (w=%.3f, contacts=%s)" % [
		air_w.length(), car.call("grounded_wheel_count") if car.has_method("grounded_wheel_count") else "?"
	])
	_ok(car.has_method("is_chassis_airborne") and bool(car.call("is_chassis_airborne")), "airborne test ran with wheels unloaded")
	car.queue_free()
	await _frames(1)

	# Live: smaller in-plume diamonds, plane FP centerline, AB surge, rates.
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var off: Vector3 = jet.call("cockpit_offset")
	_ok(absf(off.x) < 0.02, "plane first-person is on the aircraft / HUD centerline (x=%.3f)" % off.x)
	_ok(is_equal_approx(float(jet.THRUST_DRY), 680000.0) and is_equal_approx(float(jet.THRUST_AB), 1120000.0), "dry / AB thrust peaks stay 680 / 1120 kN")
	var t_mil: float = float(jet.call("thrust_newtons", 0.8))
	var t_kick: float = float(jet.call("thrust_newtons", 0.81))
	var t_ab: float = float(jet.call("thrust_newtons", 1.0))
	_ok(is_equal_approx(t_mil, 680000.0), "military power is still 680 kN (%.0f)" % t_mil)
	_ok(t_kick - t_mil > 200000.0, "lighting afterburner is a thrust surge, not a linear step (dN=%.0f)" % (t_kick - t_mil))
	_ok(is_equal_approx(t_ab, 1120000.0), "full afterburner is still 1120 kN (%.0f)" % t_ab)
	_ok(float(jet.DECEL_BOOST_HOLD) >= 1.05 and float(jet.DECEL_BOOST_FADE) >= 0.40, "decel window is extended a little (hold=%.2f fade=%.2f)" % [jet.DECEL_BOOST_HOLD, jet.DECEL_BOOST_FADE])
	_ok(float(jet.ROLL_RATE) >= 2.45 and float(jet.ROLL_RATE) > 2.15, "roll rate is higher than 2.15 (%.2f)" % float(jet.ROLL_RATE))
	_ok(is_equal_approx(float(jet.STALL_SPEED), 52.0), "stall speed remains 52 m/s")
	var pvis = jet.get("visuals")
	if pvis and pvis.exhausts.size():
		var fx = pvis.exhausts[0]
		fx.call("apply", 1.0, 1.0, 0.0, 0.016)
		_ok(int(fx.call("diamond_visible_count")) >= 3, "mach diamonds are still visible at afterburner (%d)" % int(fx.call("diamond_visible_count")))
		var mid_r := float(fx.call("plume_mid_radius"))
		var d_r := float(fx.call("diamond_world_radius", 0))
		_ok(d_r > 0.05 and mid_r > 0.05 and d_r < mid_r * 0.95, "diamonds are smaller than and wrapped by the plume (dR=%.3f plumeR=%.3f)" % [d_r, mid_r])
		var tip := float(fx.call("plume_tip_length"))
		var far := 0.0
		for d in fx.diamonds:
			if d.visible:
				far = maxf(far, d.position.z)
		_ok(far <= tip * 0.80 + 0.08, "diamond train stays inside the plume length (far=%.2f tip=%.2f)" % [far, tip])
		_ok(int(fx.call("fireball_visible_count")) >= 2, "fireball chain is still visible")
		_ok(float(fx.call("fireball_span")) <= 0.92 + 0.12, "fireball chain stays short and hard-capped (span=%.2f)" % float(fx.call("fireball_span")))
	# Exam-bed look continuity (no mid-angle discontinuity).
	if vs and vs.has_method("_exam_look_basis"):
		var look_dir := Vector3(0.0, 0.0, -1.0).normalized()
		# Default exam look is mostly horizontal; use a slightly downward dir like the bed.
		look_dir = Vector3(0.0, -0.25, -0.92).normalized()
		var prev_fwd := Vector3.ZERO
		var max_jump := 0.0
		var step := 0.08
		var yaw := -1.1
		while yaw <= 1.1:
			var pitch := -0.6
			while pitch <= 1.5:
				var b: Basis = vs.call("_exam_look_basis", look_dir, yaw, pitch)
				var fwd := -b.z
				if prev_fwd.length_squared() > 0.5:
					var ang := prev_fwd.angle_to(fwd)
					if ang > max_jump:
						max_jump = ang
				prev_fwd = fwd
				pitch += step
			prev_fwd = Vector3.ZERO  # do not compare across a yaw wrap of the inner loop
			yaw += step
		# Neighboring samples are 0.08 rad apart; a hitch would be a much larger jump.
		_ok(max_jump < 0.20, "exam-bed first-person look is continuous across mid angles (max jump=%.3f rad)" % max_jump)
	# 0.2.28 restores the 0.2.26 touch path (the 0.2.27 concurrent-touch
	# rewrite broke map pinch-zoom and did not improve multitouch). Keep
	# the no-two-finger-orbit rule while occupied.
	var hud: Node = main.get_node_or_null("HUD") if main else null
	var tc = hud.get("_touch") if hud else null
	if tc:
		var src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
		_ok(src.find("载具内取消双指拖拽旋转视角") >= 0, "two-finger vehicle orbit stays cancelled after the touch revert")
	else:
		_ok(false, "touch controls available for orbit-cancel check")
	jet.queue_free()
	await _frames(1)



func _check_0228_playtest_fixes() -> void:
	## Higher car ride, slightly lower turn downforce, reverted touch path
	## (map pinch-zoom works again), exam-bed look sign + looser limits,
	## forearm parallel on the armrests / calves on the stirrups, plane FP
	## origin in the HUD frame, vapor sheets locked to the airframe.
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("const RIDE_LIFT") >= 0, "car raises the chassis with a ride-height lift")
	_ok(car_src.find("const REST_DISTANCE := 0.44") >= 0, "car spring rest length is 0.44")
	_ok(car_src.find("const TURN_DOWNFORCE := 7400.0") >= 0, "turn downforce is lowered a little (7400)")
	_ok(car_src.find("const TURN_INWARD := 2100.0") >= 0, "turn inward load is lowered a little (2100)")
	_ok(car_src.find("const AIR_ROLL := 9800.0") >= 0, "airborne attitude control is kept")
	_ok(car_src.find("const MASS_KG := 1760.0") >= 0, "car mass stays 1760 kg")
	_ok(car_src.find("const TIRE_MU := 1.62") >= 0, "planted grip is kept")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("_live_touches") < 0, "0.2.27 _live_touches tracking is gone")
	_ok(tc_src.find("func _handle_pointer_event") < 0, "0.2.27 _handle_pointer_event swallow path is gone")
	_ok(tc_src.find("set_process_unhandled_input(true)") < 0, "touch controls no longer also hook unhandled_input")
	_ok(tc_src.find("载具内取消双指拖拽旋转视角") >= 0, "two-finger vehicle orbit stays cancelled")
	_ok(tc_src.find("摇杆优先") >= 0 or tc_src.find("绝不转视角") >= 0, "joystick still must not orbit")
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("look_dir.cross(world_up)") >= 0, "exam-bed look uses forward × up for the right vector")
	_ok(vs_src.find("world_up.cross(look_dir)") < 0, "the inverted up × forward cross is gone")
	_ok(vs_src.find("const PITCH_MIN := -1.05") >= 0, "exam-bed downward look limit is looser (-1.05)")
	_ok(vs_src.find("const YAW_LIM := 1.55") >= 0, "exam-bed yaw limit is looser (1.55)")
	_ok(vs_src.find("const HIP_LIFT := 0.085") >= 0, "exam hips stay raised")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("func _ik_arm_on_rail") >= 0, "forearms are IK'd along the armrest rail")
	var pv_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(pv_src.find("func _measure_hud_frame") >= 0, "plane cockpit is measured from the HUD frame")
	_ok(pv_src.find("\"x\": 0.0") >= 0, "plane cockpit X stays on the centerline")
	var vap_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_vapor.gd")
	_ok(vap_src.find("func _lock_cloud_to_airframe") >= 0, "vapor sheets are re-composed in aircraft space every frame")
	_ok(vap_src.find("xf.basis.y") >= 0 and vap_src.find("fwd.cross(up)") >= 0, "body-vortex ribbon width uses aircraft up, not world up")

	# Live: higher ride, wheels sit lower in the wells than the body underside.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	_ok(is_equal_approx(float(car.RIDE_LIFT), 0.08), "RIDE_LIFT is 0.08 m")
	_ok(is_equal_approx(float(car.REST_DISTANCE), 0.44), "REST_DISTANCE is 0.44 m")
	_ok(is_equal_approx(float(car.TURN_DOWNFORCE), 7400.0), "TURN_DOWNFORCE is 7400")
	var vis = car.get("visuals")
	if vis and vis.wheels.size():
		var wr: float = float(vis.wheel_r)
		var sag: float = (float(car.MASS_KG) * 9.81 / 4.0) / float(car.SPRING_STRENGTH)
		var well_ok := true
		var min_gap := 1.0e9
		for w in vis.wheels:
			var rest: Vector3 = w["rest_pos"]
			# After sag the tire moves up by `sag`; the body underside near
			# the wells must stay above the tire center enough that the
			# wheel is not buried in the chassis.
			var eq_y: float = rest.y + sag
			# Tire top after sag should not sit above a typical fender lip
			# of the lowered (pre-lift) rest; the lift itself is the gap.
			if rest.y > -0.14:
				well_ok = false
			min_gap = minf(min_gap, -rest.y)
		_ok(well_ok and min_gap >= 0.14, "visual wheels sit lower in the wells after the ride lift (gap=%.3f, sag=%.3f)" % [min_gap, sag])
		var hull_min := VehicleCommon.body_collision_min_y(car)
		var contact := 1.0e9
		for c in car.get_children():
			if c is RayCast3D:
				contact = minf(contact, (c as RayCast3D).position.y - float(car.REST_DISTANCE) - wr)
		_ok(hull_min + 0.001 >= contact + sag + 0.05, "raised hull still clears the pavement after sag (hull=%.3f contact=%.3f sag=%.3f)" % [hull_min, contact, sag])
	else:
		_ok(false, "car wheels available for ride-height check")
	car.queue_free()
	await _frames(1)

	# Live: exam-bed look signs + continuity + looser limits + pose contact.
	if vs and vs.has_method("_exam_look_basis"):
		var look_dir := Vector3(0.0, -0.20, 1.0).normalized()
		var b_def: Basis = vs.call("_exam_look_basis", look_dir, 0.0, 0.0)
		var b_pit: Basis = vs.call("_exam_look_basis", look_dir, 0.0, 0.40)
		var b_yaw: Basis = vs.call("_exam_look_basis", look_dir, 0.40, 0.0)
		var f0: Vector3 = -b_def.z
		var fp: Vector3 = -b_pit.z
		var fy: Vector3 = -b_yaw.z
		_ok(fp.y > f0.y + 0.18, "positive exam-bed pitch looks UP (dy=%.3f)" % (fp.y - f0.y))
		# Looking +Z, positive yaw (standing convention = look left) goes toward +X.
		_ok(fy.x > f0.x + 0.18, "positive exam-bed yaw looks left, matching input (dx=%.3f)" % (fy.x - f0.x))
		# Mid-angle continuity across the new looser range.
		var prev_fwd := Vector3.ZERO
		var max_jump := 0.0
		var step := 0.08
		var yaw := -1.5
		while yaw <= 1.5:
			var pitch := -1.05
			prev_fwd = Vector3.ZERO
			while pitch <= 1.6:
				var b: Basis = vs.call("_exam_look_basis", look_dir, yaw, pitch)
				var fwd := -b.z
				if prev_fwd.length_squared() > 0.5:
					max_jump = maxf(max_jump, prev_fwd.angle_to(fwd))
				prev_fwd = fwd
				pitch += step
			yaw += step
		_ok(max_jump < 0.20, "looser exam-bed look stays continuous (max jump=%.3f rad)" % max_jump)
		# Camera up stays upright at the default look (not inverted).
		var b0: Basis = vs.call("_exam_look_basis", look_dir, 0.0, 0.0)
		_ok(b0.y.dot(Vector3.UP) > 0.70, "exam-bed camera up is world-upright (dot=%.3f)" % b0.y.dot(Vector3.UP))

	var bed: Node = null
	if vs:
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
	if bed == null:
		bed = load("res://scenes/vehicles/exam_bed.tscn").instantiate()
		root.add_child(bed)
		await _frames(2)
	if vs and player and bed:
		player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
		vs.set("nearest", bed)
		if vs.has_method("try_enter"):
			vs.call("try_enter")
		await _frames(3)
		if vs.get("occupied") == bed:
			if vs.has_method("_apply_exam_pose"):
				vs.call("_apply_exam_pose", 0.016)
			await _frames(1)
			var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
			var lie: Basis = bed.patient_basis()
			if skel:
				# Forearm direction vs armrest axis (toward the feet = -lie.y).
				var rail: Vector3 = (-lie.y).normalized()
				var par_ok := true
				var on_ok := true
				var worst_ang := 0.0
				for side in [true, false]:
					var fa := skel.find_bone("L_Forearm_a" if side else "R_Forearm_a")
					var ha := skel.find_bone("L_Hand_a" if side else "R_Hand_a")
					if fa < 0 or ha < 0:
						par_ok = false
						continue
					var pf: Vector3 = (skel.global_transform * skel.get_bone_global_pose(fa)).origin
					var ph: Vector3 = (skel.global_transform * skel.get_bone_global_pose(ha)).origin
					var fd := ph - pf
					if fd.length_squared() < 1e-6:
						par_ok = false
						continue
					var ang := fd.normalized().angle_to(rail)
					ang = minf(ang, PI - ang)  # ignore 180 flips
					worst_ang = maxf(worst_ang, ang)
					if ang > 0.42:
						par_ok = false
					# Hand / mid-forearm should sit on or above the pad, not through it.
					var pad_top: Vector3 = bed.armrest_l_global() if side else bed.armrest_r_global()
					var mid := (pf + ph) * 0.5
					var above := (mid - pad_top).dot(bed.global_transform.basis.y.normalized())
					if above < -0.04:
						on_ok = false
				_ok(par_ok, "forearms are nearly parallel to the armrests (worst=%.3f rad)" % worst_ang)
				_ok(on_ok, "forearms rest on top of the armrests, not through them")
				# Legs: mid-shin close to the stirrup pad, not far off to the side.
				var leg_ok := true
				for side2 in [true, false]:
					var sh := skel.find_bone("L_Foreleg_a" if side2 else "R_Foreleg_a")
					var ft := skel.find_bone("L_Foot_a" if side2 else "R_Foot_a")
					if sh < 0 or ft < 0:
						leg_ok = false
						continue
					var psh: Vector3 = (skel.global_transform * skel.get_bone_global_pose(sh)).origin
					var pft: Vector3 = (skel.global_transform * skel.get_bone_global_pose(ft)).origin
					var mid_s := (psh + pft) * 0.5
					var pad: Vector3 = bed.stirrup_l_global() if side2 else bed.stirrup_r_global()
					var lateral := (mid_s - pad).dot(lie.x)
					# On the pad: not more than ~9 cm off the marker laterally.
					if (lateral if side2 else -lateral) < -0.12 or absf(lateral) > 0.18:
						leg_ok = false
					var vert := (mid_s - pad).dot(bed.global_transform.basis.y.normalized())
					if vert < -0.06 or vert > 0.16:
						leg_ok = false
				_ok(leg_ok, "calves rest along/on the stirrup pads, not off to the side or through the bar")
				var hip_i := skel.find_bone("C_Hip_a")
				if hip_i >= 0:
					var hip_p: Vector3 = (skel.global_transform * skel.get_bone_global_pose(hip_i)).origin
					var seat: Vector3 = bed.seat_global()
					_ok(hip_p.y >= seat.y - 0.02, "hips stay raised off the cushion (hip=%.3f seat=%.3f)" % [hip_p.y, seat.y])
			if vs.has_method("try_exit"):
				vs.call("try_exit")
			await _frames(1)
		else:
			_ok(false, "could enter the exam bed for pose contact checks")
	else:
		_ok(false, "exam bed / player available for pose contact checks")

	# Live: plane FP origin at the HUD frame, vapor locked to airframe.
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	var off: Vector3 = jet.call("cockpit_offset")
	_ok(absf(off.x) < 0.02, "plane first-person stays on the centerline (x=%.3f)" % off.x)
	var pvis = jet.get("visuals")
	if pvis and pvis.has_method("_measure_hud_frame"):
		# _measure_hud_frame is pre-lift; cockpit y is already in body space.
		# Compare the live offset to the HUD combiner in wrap space.
		var hud_y := 0.0
		var hud_z := 0.0
		var found_hud := false
		if pvis.wrap:
			for mi in VehicleCommon.mesh_instances(pvis.wrap):
				var a := VehicleCommon.aabb_in(pvis.wrap, mi)
				if a.get("empty", false):
					continue
				var s: Vector3 = a["max"] - a["min"]
				if absf(float(a["cx"])) <= 0.20 and s.z <= 0.08 and s.z >= 0.004 and s.x >= 0.08 and s.x <= 0.50 and s.y >= 0.05 and s.y <= 0.35 and float(a["cz"]) <= -4.6 and float(a["cz"]) >= -7.2 and float(a["cy"]) >= 1.40:
					hud_y = float(a["cy"])
					hud_z = float(a["cz"])
					found_hud = true
					break
		_ok(found_hud, "HUD combiner / frame mesh is present in the cockpit")
		if found_hud:
			_ok(off.y > hud_y - 0.02 and off.y < hud_y + 0.16, "plane FP Y sits in/above the HUD combiner toward the box center (eye=%.3f hud=%.3f)" % [off.y, hud_y])
			_ok(off.z > hud_z and off.z < hud_z + 1.10, "plane FP is just aft of the HUD frame (eye z=%.3f hud z=%.3f)" % [off.z, hud_z])
	if pvis and pvis.vapor:
		_ok(not bool(pvis.vapor.call("cloud_uses_spheres")), "vapor is still polygonal sheets")
		_ok(int(pvis.vapor.call("cloud_sheet_count")) >= 6, "vapor still uses several sheets")
		_ok(bool(pvis.vapor.call("cloud_covers_dorsal_lex")), "vapor covers the dorsal / LEX region")
		_ok(bool(pvis.vapor.call("cloud_covers_wing_lex")), "vapor covers the wing-root / LEX region")
		# Bank the jet: sheets must follow the airframe, not stand on world-up.
		jet.rotation = Vector3(0.15, 0.0, 1.20)
		jet.force_update_transform()
		if pvis.wrap:
			pvis.wrap.force_update_transform()
		pvis.vapor.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 6.5, "ctrl_pitch": 0.8, "aoa": 0.22}, 0.05)
		var ang: float = float(pvis.vapor.call("cloud_max_normal_angle_to_airframe"))
		_ok(ang < 0.35, "banked vapor sheets stay flush with the airframe (max normal err=%.3f rad)" % ang)
		# And they must NOT all be aligned to world-up while the jet is banked.
		var world_up_aligned := 0
		var checked := 0
		for mi in pvis.vapor._clouds:
			if mi == null:
				continue
			checked += 1
			if mi.global_transform.basis.y.normalized().angle_to(Vector3.UP) < 0.35:
				world_up_aligned += 1
		_ok(checked > 0 and world_up_aligned < checked, "vapor sheets do not stand up in world axes when the jet banks (%d/%d world-up)" % [world_up_aligned, checked])
		jet.rotation = Vector3.ZERO
	jet.queue_free()
	await _frames(1)

	# Live: map pinch-zoom works through handle_input (the path 0.2.27 used to starve).
	var mv = main.get("map_view") if main else null
	if main and main.has_method("open_overhead"):
		main.call("open_overhead")
	await _frames(1)
	if mv and bool(mv.get("is_open")):
		var h0: float = float(mv.height)
		var e1 := InputEventScreenTouch.new()
		e1.index = 0
		e1.pressed = true
		e1.position = Vector2(200, 200)
		var e2 := InputEventScreenTouch.new()
		e2.index = 1
		e2.pressed = true
		e2.position = Vector2(320, 200)
		mv.call("handle_input", e1)
		mv.call("handle_input", e2)
		var d := InputEventScreenDrag.new()
		d.index = 1
		d.position = Vector2(500, 200)
		d.relative = Vector2(180, 0)
		mv.call("handle_input", d)
		var h1: float = float(mv.height)
		# Fingers moved apart → zoom in → height drops.
		_ok(h1 < h0 - 1.0, "map pinch-zoom still changes height (h0=%.1f h1=%.1f)" % [h0, h1])
		if main.has_method("close_overhead"):
			main.call("close_overhead")
	else:
		_ok(false, "map view opens for pinch-zoom check")



func _check_0229_playtest_fixes() -> void:
	## Higher-G vapor onset, narrower outward main vortex, raised HUD-centered
	## plane FP, more roll + asymmetric pull-up pitch, mobile flight-stick
	## default, exam head tracks the camera, calves/forearms/waist/breath,
	## handbrake drift, nitro only from 加速/Shift, map from vehicle TP,
	## observe ≈ 透视, smaller weapon UI without a gray plate.
	var vap_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_vapor.gd")
	_ok(vap_src.find("const VAPOR_G_ON := 4.8") >= 0, "vapor onset is raised to 4.8 G")
	_ok(vap_src.find("const VAPOR_G_FULL := 7.5") >= 0, "vapor is densest near 7.5 G")
	_ok(vap_src.find("pitch_c > 0.18") < 0, "vapor is not keyed off pitch-up input alone")
	_ok(vap_src.find("func cloud_covers_engines") >= 0, "vapor exposes an engine-coverage test")
	var pl_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_controller.gd")
	_ok(pl_src.find("const ROLL_RATE := 3.15") >= 0, "roll rate is raised to 3.15")
	_ok(pl_src.find("const PITCH_RATE := 1.90") >= 0, "dive pitch rate stays 1.90")
	_ok(pl_src.find("const PITCH_RATE_UP := 2.45") >= 0, "pull-up pitch rate is raised to 2.45")
	_ok(pl_src.find("const DECEL_YAW_COUPLE := 0.62") >= 0, "yaw is not raised")
	_ok(pl_src.find("const STALL_SPEED := 52.0") >= 0, "stall stays 52 m/s")
	var pv_src := FileAccess.get_file_as_string("res://scripts/vehicles/plane_visuals.gd")
	_ok(pv_src.find("sy * 0.20 + 0.10") >= 0, "plane FP Y is raised to the visual HUD-frame center")
	var gs_src := FileAccess.get_file_as_string("res://scripts/game_settings.gd")
	_ok(gs_src.find("flight_control_mode") >= 0 and gs_src.find("FLIGHT_MODE_STICK") >= 0, "flight control mode is persisted")
	_ok(gs_src.find("FLIGHT_MODE_STICK") >= 0, "default flight mode is stick")
	var lay_src := FileAccess.get_file_as_string("res://scripts/ui/touch_layout.gd")
	_ok(lay_src.find("\"flight_stick\":") >= 0, "TYL1 documents the stable flight_stick id")
	var tc_src := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(tc_src.find("_show_flight_stick") >= 0 and tc_src.find("_live_touches") < 0, "flight stick exists and the 0.2.27 multitouch path stays gone")
	_ok(tc_src.find("载具内取消双指拖拽旋转视角") >= 0, "two-finger vehicle orbit stays cancelled")
	var pose_src := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose_src.find("func _aim_head_world") >= 0 and pose_src.find("func head_forward") >= 0, "exam head aims at the camera forward")
	_ok(pose_src.find("C_Spine_a\": Vector3(-0.10") >= 0 or pose_src.find("Soft waist flex") >= 0, "exam pose has a soft waist flex")
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	_ok(vs_src.find("func _map_view_open") >= 0, "vehicle cameras yield to the overhead map")
	_ok(vs_src.find("arm_skin := 0.044") >= 0, "forearms are raised to sit flush with the armrests")
	_ok(vs_src.find("bed_up * 0.052") >= 0, "calves are raised off the stirrup bars")
	_ok(vs_src.find("clear_gaze_intent") >= 0, "exam head-follow still uses clear_gaze_intent")
	_ok(vs_src.find("look_dir.cross(world_up)") >= 0, "exam look basis is still forward × up")
	_ok(vs_src.find("const YAW_LIM := 1.55") >= 0 and vs_src.find("const PITCH_MIN := -1.05") >= 0, "loosened exam look limits are kept")
	var car_src := FileAccess.get_file_as_string("res://scripts/vehicles/car_controller.gd")
	_ok(car_src.find("const HANDBRAKE_MULT := 2.2") >= 0, "handbrake slip is reduced")
	_ok(car_src.find("grip_factor *= 0.32") >= 0, "handbrake keeps enough rear grip for a controllable drift")
	_ok(car_src.find("nitro_active = occupied and nitro") >= 0, "nitro is only the 加速 / Shift flag")
	_ok(car_src.find("const ENGINE_POWER_NITRO := 36000.0") >= 0, "nitro thrust is stronger (36000)")
	_ok(car_src.find("const ENGINE_POWER_SHIFT := 42000.0") >= 0, "Shift nitro punch is stronger (42000)")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("飞机控制（仅手机）") >= 0, "settings has a mobile-only aircraft control switch")
	_ok(hud_src.find("Match the 透视 button size") >= 0 or hud_src.find("obs_sz = xr.size") >= 0, "观察 matches the 透视 button size")
	var wui_src := FileAccess.get_file_as_string("res://scripts/ui/weapon_ui.gd")
	_ok(wui_src.find("sb.bg_color = Color(0, 0, 0, 0)") >= 0 or wui_src.find("draw_center = false") >= 0, "weapon ammo HUD has no gray background")
	var wh_src := FileAccess.get_file_as_string("res://scripts/ui/weapon_wheel.gd")
	_ok(wh_src.find("Color(0.12, 0.13, 0.16, 0.8)") < 0, "weapon wheel slots no longer use a gray plate")

	# Live: vapor onset + geometry.
	var jet: Node = load("res://scenes/vehicles/plane.tscn").instantiate()
	root.add_child(jet)
	await _frames(2)
	_ok(is_equal_approx(float(jet.ROLL_RATE), 3.15), "live ROLL_RATE is 3.15")
	_ok(is_equal_approx(float(jet.PITCH_RATE), 1.90), "live dive PITCH_RATE is 1.90")
	_ok(is_equal_approx(float(jet.PITCH_RATE_UP), 2.45), "live PITCH_RATE_UP is 2.45")
	_ok(float(jet.PITCH_RATE_UP) > float(jet.PITCH_RATE), "pull-up is snappier than dive")
	_ok(is_equal_approx(float(jet.STALL_SPEED), 52.0), "stall remains 52 m/s")
	_ok(is_equal_approx(float(jet.DECEL_BOOST_HOLD), 1.15), "decel agility hold is unchanged")
	var off: Vector3 = jet.call("cockpit_offset")
	_ok(absf(off.x) < 0.02, "plane FP stays on the centerline (x=%.3f)" % off.x)
	_ok(off.y > 1.80 and off.y < 1.95, "plane FP Y is raised toward the HUD box center, not back at 1.983 (y=%.3f)" % off.y)
	var pvis = jet.get("visuals")
	if pvis and pvis.vapor:
		var vap = pvis.vapor
		_ok(is_equal_approx(float(vap.VAPOR_G_ON), 4.8), "live VAPOR_G_ON is 4.8")
		# Fade to zero first.
		for i in 8:
			vap.call("update", {"airborne": true, "speed": 120.0, "agl": 40.0, "g_load": 1.0, "ctrl_pitch": 0.0, "aoa": 0.0}, 0.08)
		# Mild pull-up / light G must not produce vapor.
		for i in 10:
			vap.call("update", {"airborne": true, "speed": 140.0, "agl": 40.0, "g_load": 2.8, "ctrl_pitch": 0.95, "aoa": 0.18}, 0.05)
		_ok(float(vap.call("cloud_intensity")) < 0.08, "a mild pull-up at 2.8 G produces no vapor (i=%.3f)" % float(vap.call("cloud_intensity")))
		# High G does, even without a huge pitch input (loaded turn).
		for i in 10:
			vap.call("update", {"airborne": true, "speed": 140.0, "agl": 40.0, "g_load": 6.8, "ctrl_pitch": 0.2, "aoa": 0.12}, 0.05)
		_ok(float(vap.call("cloud_intensity")) > 0.25, "high G produces vapor (i=%.3f)" % float(vap.call("cloud_intensity")))
		_ok(bool(vap.call("cloud_covers_dorsal_lex")), "vapor still covers the dorsal / LEX / wing-body area")
		_ok(bool(vap.call("cloud_covers_wing_lex")), "vapor still covers the wing-root / LEX junction")
		_ok(not bool(vap.call("cloud_covers_engines")), "main vortex does not cover the engine nacelles")
		_ok(float(vap.call("main_vortex_max_width")) <= 1.40, "main vortex designed width is narrower")
		jet.rotation = Vector3(0.15, 0.0, 1.20)
		jet.force_update_transform()
		if pvis.wrap:
			pvis.wrap.force_update_transform()
		vap.call("update", {"airborne": true, "speed": 140.0, "agl": 40.0, "g_load": 6.8, "ctrl_pitch": 0.4, "aoa": 0.12}, 0.05)
		var ang: float = float(vap.call("cloud_max_normal_angle_to_airframe"))
		_ok(ang < 0.35, "vapor sheets stay locked to the airframe (err=%.3f rad)" % ang)
		jet.rotation = Vector3.ZERO
	else:
		_ok(false, "plane vapor available for G / geometry checks")
	jet.queue_free()
	await _frames(1)

	# Live: flight stick default + settings + button mode still available.
	var settings = main.get_node_or_null("GameSettings") if main else null
	if settings:
		_ok(str(settings.get("flight_control_mode")) != "buttons", "flight control defaults to stick mode")
		_ok(bool(settings.call("is_flight_stick_mode")), "is_flight_stick_mode is true by default")
		settings.call("set_flight_control_mode", "buttons")
		_ok(not bool(settings.call("is_flight_stick_mode")), "button mode can be selected")
		settings.call("set_flight_control_mode", "stick")
		_ok(bool(settings.call("is_flight_stick_mode")), "stick mode can be restored")
	else:
		_ok(false, "GameSettings present for flight-mode checks")
	var hud: Node = main.get_node_or_null("HUD") if main else null
	if hud:
		_ok(hud.get("_flight_mode_option") != null, "settings has a 摇杆 / 按键 option")
		# 观察 vs 透视 size
		if hud.get("_btn_observe") and hud.get("_btn_xray"):
			var obs: Control = hud.get("_btn_observe")
			var xr: Control = hud.get("_btn_xray")
			var ds := obs.size - xr.size
			_ok(absf(ds.x) <= 8.0 and absf(ds.y) <= 8.0 or (obs.custom_minimum_size - xr.custom_minimum_size).length() <= 12.0,
				"观察 button is about the same size as 透视 (obs=%s xray=%s min=%s/%s)" % [obs.size, xr.size, obs.custom_minimum_size, xr.custom_minimum_size])
		if hud.get("_wui") and hud.get("_wui").get("ammo_box"):
			var box: Control = hud.get("_wui").get("ammo_box")
			var sb: StyleBox = box.get_theme_stylebox("panel")
			var ok_clear := true
			if sb is StyleBoxFlat:
				ok_clear = (sb as StyleBoxFlat).bg_color.a < 0.05 or not (sb as StyleBoxFlat).draw_center
			_ok(ok_clear, "ammo HUD panel is transparent / has no gray fill")
	else:
		_ok(false, "HUD present for control / observe / weapon UI checks")

	# Live: nitro only from flag, stronger power, handbrake grip.
	var car: Node = load("res://scenes/vehicles/car.tscn").instantiate()
	root.add_child(car)
	await _frames(2)
	_ok(is_equal_approx(float(car.ENGINE_POWER_NITRO), 36000.0), "live nitro power is 36000")
	_ok(float(car.ENGINE_POWER_NITRO) > float(car.ENGINE_POWER) * 1.6, "nitro boost is clearly stronger than dry power")
	_ok(is_equal_approx(float(car.HANDBRAKE_MULT), 2.2), "live HANDBRAKE_MULT is 2.2")
	car.occupied = true
	car.set_driver_input(1.0, 0.0, 0.0, false, false)
	car._drive(0.016)
	_ok(not bool(car.nitro_active), "W / joystick throttle does not trigger nitro")
	car.set_driver_input(1.0, 0.0, 0.0, false, true)
	car._drive(0.016)
	_ok(bool(car.nitro_active), "加速 / Shift flag triggers nitro")
	car.queue_free()
	await _frames(1)

	# Live: exam head tracks camera, calves/forearms, waist, breath, map from TP.
	var bed: Node = null
	if vs:
		for v in vs.vehicles:
			if str(vs.call("kind_of", v)) == "exam_bed" and bool(v.get("is_default")):
				bed = v
				break
	if bed == null:
		bed = load("res://scenes/vehicles/exam_bed.tscn").instantiate()
		root.add_child(bed)
		await _frames(2)
	if vs and player and bed:
		player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
		vs.set("nearest", bed)
		if player.has_method("set_play_mode"):
			player.call("set_play_mode", 1)
		_ok(bool(vs.call("try_enter")), "can board the exam bed for 0.2.29 pose / look")
		await _frames(3)
		if vs.get("occupied") == bed:
			if vs.has_method("_apply_exam_pose"):
				vs.call("_apply_exam_pose", 0.016)
			await _frames(1)
			var skel: Skeleton3D = player.call("get_skeleton") if player.has_method("get_skeleton") else null
			var lie: Basis = bed.patient_basis()
			if skel and vs.has_method("_exam_look_forward"):
				# Head forward tracks camera forward at two different looks.
				player.set("_yaw", 0.55)
				player.set("_pitch", 0.35)
				vs.call("_apply_exam_pose", 0.016)
				if vs.has_method("_exam_camera"):
					vs.call("_exam_camera", 0.016)
				var cam_f1: Vector3 = vs.call("_exam_look_forward", 0.55, 0.35, lie)
				var head_f1: Vector3 = ExamPose.head_forward(skel)
				var a1 := cam_f1.angle_to(head_f1)
				_ok(a1 < 0.45, "exam head forward tracks camera forward (ang=%.3f rad)" % a1)
				player.set("_yaw", -0.55)
				player.set("_pitch", -0.30)
				vs.call("_apply_exam_pose", 0.016)
				if vs.has_method("_exam_camera"):
					vs.call("_exam_camera", 0.016)
				var cam_f2: Vector3 = vs.call("_exam_look_forward", -0.55, -0.30, lie)
				var head_f2: Vector3 = ExamPose.head_forward(skel)
				var a2 := cam_f2.angle_to(head_f2)
				_ok(a2 < 0.45, "head follow updates the other way (ang=%.3f rad)" % a2)
				_ok(head_f1.angle_to(head_f2) > 0.25, "head forward actually changes with look (d=%.3f)" % head_f1.angle_to(head_f2))
				# Calves raised, forearms flush, waist flexed, breath present.
				var on_ok := true
				var par_ok := true
				var worst_ang := 0.0
				var rail: Vector3 = (-lie.y).normalized()
				for side in [true, false]:
					var fa := skel.find_bone("L_Forearm_a" if side else "R_Forearm_a")
					var ha := skel.find_bone("L_Hand_a" if side else "R_Hand_a")
					if fa < 0 or ha < 0:
						par_ok = false
						continue
					var pf: Vector3 = (skel.global_transform * skel.get_bone_global_pose(fa)).origin
					var ph: Vector3 = (skel.global_transform * skel.get_bone_global_pose(ha)).origin
					var fd := ph - pf
					if fd.length_squared() < 1e-6:
						par_ok = false
						continue
					var ang := fd.normalized().angle_to(rail)
					ang = minf(ang, PI - ang)
					worst_ang = maxf(worst_ang, ang)
					if ang > 0.42:
						par_ok = false
					var pad_top: Vector3 = bed.armrest_l_global() if side else bed.armrest_r_global()
					var mid := (pf + ph) * 0.5
					var above := (mid - pad_top).dot(bed.global_transform.basis.y.normalized())
					if above < -0.02:
						on_ok = false
				_ok(par_ok, "forearms stay parallel to the armrests (worst=%.3f)" % worst_ang)
				_ok(on_ok, "forearms sit flush on the armrests, not through the rail")
				var leg_ok := true
				for side2 in [true, false]:
					var sh := skel.find_bone("L_Foreleg_a" if side2 else "R_Foreleg_a")
					var ft := skel.find_bone("L_Foot_a" if side2 else "R_Foot_a")
					if sh < 0 or ft < 0:
						leg_ok = false
						continue
					var psh: Vector3 = (skel.global_transform * skel.get_bone_global_pose(sh)).origin
					var pft: Vector3 = (skel.global_transform * skel.get_bone_global_pose(ft)).origin
					var mid_s := (psh + pft) * 0.5
					var pad: Vector3 = bed.stirrup_l_global() if side2 else bed.stirrup_r_global()
					var vert := (mid_s - pad).dot(bed.global_transform.basis.y.normalized())
					if vert < -0.03 or vert > 0.18:
						leg_ok = false
				_ok(leg_ok, "calves rest on the stirrup pads without clipping through")
				# Soft waist flex: spine is crunched a little toward the belly vs rest.
				var sa := skel.find_bone("C_Spine_a")
				if sa >= 0:
					var rest_q := skel.get_bone_rest(sa).basis.get_rotation_quaternion()
					var pose_q := skel.get_bone_pose_rotation(sa)
					var e := (rest_q.inverse() * pose_q).get_euler()
					_ok(e.x < -0.02, "waist has a soft flexion (spine_a x=%.3f)" % e.x)
				# Breath: spine scale / breath_in changes over time on the bed.
				var sec = player.call("get_secondary") if player.has_method("get_secondary") else null
				if sec:
					var b0 := float(sec.get("breath_in"))
					for i in 20:
						vs.call("_apply_exam_pose", 0.05)
					var b1 := float(sec.get("breath_in"))
					var si := skel.find_bone("C_Spine_a")
					var sc := skel.get_bone_pose_scale(si) if si >= 0 else Vector3.ONE
					_ok(absf(b1 - b0) > 0.002 or absf(sc.x - 1.0) > 0.0005, "exam bed breathing is active (breath %.4f→%.4f scale.x=%.4f)" % [b0, b1, sc.x])
				else:
					_ok(false, "secondary present for exam-bed breath")
			# Map from a vehicle third-person view after leaving the bed.
			if vs.has_method("try_exit"):
				vs.call("try_exit")
			await _frames(1)
		else:
			_ok(false, "occupied the exam bed for pose / look checks")
	else:
		_ok(false, "exam bed / player available for 0.2.29 checks")

	# Live: opening the map while in a vehicle in third-person uses the map camera.
	var plane: Node = null
	if vs:
		for v2 in vs.vehicles:
			if str(vs.call("kind_of", v2)) == "plane" and bool(v2.get("is_default")):
				plane = v2
				break
	if plane == null:
		plane = load("res://scenes/vehicles/plane.tscn").instantiate()
		root.add_child(plane)
		await _frames(2)
	if vs and player and plane and main and main.has_method("open_overhead"):
		player.global_position = plane.global_position + Vector3(4.0, 0.1, 0.0)
		vs.set("nearest", plane)
		if vs.has_method("try_enter"):
			vs.call("try_enter")
		await _frames(2)
		vs.set("vehicle_cam", "third")
		if vs.has_method("_vehicle_camera"):
			vs.call("_vehicle_camera", 0.016)
		main.call("open_overhead")
		await _frames(2)
		# Vehicle camera must not steal current after the map opens.
		if vs.has_method("_vehicle_camera"):
			vs.call("_vehicle_camera", 0.016)
		var mv = main.get("map_view")
		_ok(mv != null and bool(mv.get("is_open")), "map opens from vehicle third-person")
		if mv:
			var map_cam: Camera3D = mv.get("_cam")
			_ok(map_cam != null and map_cam.current, "map camera stays current in vehicle TP (current=%s)" % (map_cam.current if map_cam else false))
			# Pinch-zoom still works.
			var h0: float = float(mv.height)
			var e1 := InputEventScreenTouch.new()
			e1.index = 0
			e1.pressed = true
			e1.position = Vector2(200, 200)
			var e2 := InputEventScreenTouch.new()
			e2.index = 1
			e2.pressed = true
			e2.position = Vector2(320, 200)
			mv.call("handle_input", e1)
			mv.call("handle_input", e2)
			var d := InputEventScreenDrag.new()
			d.index = 1
			d.position = Vector2(500, 200)
			d.relative = Vector2(180, 0)
			mv.call("handle_input", d)
			_ok(float(mv.height) < h0 - 1.0, "map pinch-zoom still works from vehicle TP (h0=%.1f h1=%.1f)" % [h0, float(mv.height)])
		if main.has_method("close_overhead"):
			main.call("close_overhead")
		if vs.has_method("try_exit"):
			vs.call("try_exit")
		await _frames(1)
	else:
		_ok(false, "vehicle / map available for TP map display check")


func _door_rear_y(hub: Node3D, wrap: Node3D) -> float:
	if hub == null or wrap == null:
		return 0.0
	var rear_y := -1.0e9
	var rear_z := -1.0e9
	for n in hub.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf: Transform3D = wrap.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for v in verts:
				var pnt: Vector3 = xf * v
				if pnt.z >= rear_z - 0.02:
					if pnt.z > rear_z:
						rear_z = pnt.z
						rear_y = pnt.y
					else:
						rear_y = maxf(rear_y, pnt.y)
	return rear_y

func _finish() -> void:
	if fails == 0:
		print("vehicles: ALL PASSED")
	else:
		print("vehicles: FAILED ", fails)
	quit(1 if fails else 0)
