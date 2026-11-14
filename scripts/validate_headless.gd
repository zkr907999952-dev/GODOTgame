extends SceneTree
## Headless self-check: load main, sample walk, exercise blink + hair Verlet.

const SoftLocoScript = preload("res://scripts/soft_loco.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("validate: loading main...")
	var packed := load("res://scenes/main.tscn")
	if packed == null:
		push_error("validate: failed to load main.tscn")
		quit(1)
		return
	var main: Node = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var player := main.get_node_or_null("Player")
	if player == null:
		push_error("validate: no Player")
		quit(1)
		return

	var skel: Skeleton3D = null
	for n in player.find_children("*", "Skeleton3D", true, false):
		skel = n
		break
	if skel == null:
		push_error("validate: no Skeleton3D")
		quit(1)
		return
	print("validate: bones=", skel.get_bone_count())

	var loco: Node = null
	for c in player.get_children():
		if c.get_script() == SoftLocoScript:
			loco = c
			break
	if loco == null:
		push_error("validate: SoftLoco missing on Player")
		quit(1)
		return

	var diag: Dictionary = loco.call("debug_sample_walk")
	print("validate: walk sample ok=", diag.get("ok"), " clip=", diag.get("clip"))
	var bones: Dictionary = diag.get("bones", {})
	var non_id := 0
	for name in bones.keys():
		var info: Dictionary = bones[name]
		var ang: float = float(info.get("delta_angle", 0.0))
		print("validate: bone ", name, " delta_angle=", snappedf(ang, 0.0001), " rad")
		if ang > 0.02:
			non_id += 1
	if non_id < 2:
		push_error("validate: expected several non-identity loco bone deltas, got %d" % non_id)
		quit(1)
		return
	print("validate: non-identity loco bones=", non_id)

	var sec: RefCounted = loco.get("secondary")
	if sec == null:
		push_error("validate: SoftSecondary missing")
		quit(1)
		return
	var snap0: Dictionary = sec.call("debug_snapshot")
	print(
		"validate: secondary hair=", snap0.get("hair_count"),
		" lids=", snap0.get("lid_count"),
		" blink_amt=", snappedf(float(snap0.get("blink_amt", 0.0)), 0.0001)
	)
	if int(snap0.get("hair_count", 0)) < 3:
		push_error("validate: expected hair chain >=3, got %s" % snap0.get("hair_count"))
		quit(1)
		return
	if int(snap0.get("lid_count", 0)) < 8:
		push_error("validate: expected lid bones >=8, got %s" % snap0.get("lid_count"))
		quit(1)
		return

	# Force a blink and step until blink_amt rises then falls (or peaks).
	sec.call("blink_now")
	var saw_open := false
	var saw_close := false
	var peak := 0.0
	for _i in 90:
		sec.call("update", 0.016, false)
		var s: Dictionary = sec.call("debug_snapshot")
		var a: float = float(s.get("blink_amt", 0.0))
		peak = maxf(peak, a)
		if a > 0.85:
			saw_close = true
		if saw_close and a < 0.15:
			saw_open = true
			break
	print("validate: blink peak=", snappedf(peak, 0.0001), " closed=", saw_close, " reopened=", saw_open)
	if peak < 0.5 or not saw_close:
		push_error("validate: blinkAmt did not cycle (peak=%s)" % peak)
		quit(1)
		return

	# Hair: init with a few frames, jerk root, ensure tip particle moves.
	for _j in 5:
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
	var before: Dictionary = sec.call("debug_snapshot")
	var tip_before: Array = before.get("hair_p_tip", [0, 0, 0])
	# 头皮相连的头发（头顶 y>1.50）蒙皮后相对头骨必须不动；发尾必须甩。
	var hs := _hair_samples(skel)
	if hs.is_empty():
		push_error("validate: hair mesh not found for scalp check")
		quit(1)
		return
	var scalp0 := _skinned_rel_head(skel, hs, "scalp")
	var tips0 := _skinned_rel_head(skel, hs, "tips")
	var scalp_max := 0.0
	var tips_max := 0.0
	sec.call("debug_jerk_root", Vector3(0.15, 0.0, 0.0))
	for _k in 12:
		sec.call("update", 0.016, false)
		var sc := _skinned_rel_head(skel, hs, "scalp")
		var tc := _skinned_rel_head(skel, hs, "tips")
		for q in sc.size():
			scalp_max = maxf(scalp_max, sc[q].distance_to(scalp0[q]))
		for q2 in tc.size():
			tips_max = maxf(tips_max, tc[q2].distance_to(tips0[q2]))
	print(
		"validate: hair swing scalp verts=", (hs["scalp"] as PackedInt32Array).size(),
		" max_move_rel_head=", snappedf(scalp_max, 0.00001),
		" tips max_move=", snappedf(tips_max, 0.0001)
	)
	if scalp_max > 0.001 or tips_max < 0.02:
		push_error("validate: scalp hair must stay on head (<1mm, got %s) while tips swing (>2cm, got %s)" % [scalp_max, tips_max])
		quit(1)
		return
	var after: Dictionary = sec.call("debug_snapshot")
	var tip_after: Array = after.get("hair_p_tip", [0, 0, 0])
	var dx := absf(float(tip_after[0]) - float(tip_before[0]))
	var dy := absf(float(tip_after[1]) - float(tip_before[1]))
	var dz := absf(float(tip_after[2]) - float(tip_before[2]))
	var moved := sqrt(dx * dx + dy * dy + dz * dz)
	print(
		"validate: hair tip before=", tip_before,
		" after=", tip_after,
		" moved=", snappedf(moved, 0.0001)
	)
	if moved < 0.01:
		push_error("validate: hair tip did not move after root jerk (moved=%s)" % moved)
		quit(1)
		return

	# Breath should be non-zero after a second of updates.
	var breath_peak := 0.0
	for _b in 90:
		sec.call("update", 0.016, false)
		var sb: Dictionary = sec.call("debug_snapshot")
		breath_peak = maxf(breath_peak, float(sb.get("breath_in", 0.0)))
		breath_peak = maxf(breath_peak, float(sb.get("breath_chest", 0.0)))
	print("validate: breath peak=", snappedf(breath_peak, 0.0001))
	if breath_peak < 0.2:
		push_error("validate: breath wave stayed near zero")
		quit(1)
		return

	# CRITICAL: breath scale must stay near rest (~1) after many seconds — no exponential growth.
	# Drive through SoftLoco.apply_pose so loco resets scale each frame, then secondary applies breath.
	var max_scale := 0.0
	var min_scale := 999.0
	for _s in 600:  # ~9.6s at 60fps
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
		var ss: Dictionary = sec.call("debug_snapshot")
		var scales: Dictionary = ss.get("spine_scales", {})
		for sn in scales.keys():
			var arr: Array = scales[sn]
			for v in arr:
				var fv := float(v)
				max_scale = maxf(max_scale, fv)
				min_scale = minf(min_scale, fv)
	print(
		"validate: breath scale after ~10s min=", snappedf(min_scale, 0.0001),
		" max=", snappedf(max_scale, 0.0001)
	)
	# Quiet breath: peak expand should be ~1–2% (web ~1cm inflate), not ~10%.
	if max_scale > 1.025 or min_scale < 0.97:
		push_error(
			"validate: breath bone scale too strong/drifted (min=%s max=%s) — want max < ~1.02"
			% [min_scale, max_scale]
		)
		quit(1)
		return
	print("validate: breath scale quiet OK (max < 1.025)")

	# Breath must NOT pitch-lean the spine (web uses tissue inflate, not bone X rotation).
	var max_spine_pitch := 0.0
	for _p in 120:
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
		var sp: Dictionary = sec.call("debug_snapshot")
		var eulers: Dictionary = sp.get("spine_euler_x", {})
		for sn in eulers.keys():
			max_spine_pitch = maxf(max_spine_pitch, absf(float(eulers[sn])))
	print("validate: breath spine |eulerX| max=", snappedf(max_spine_pitch, 0.0001))
	if max_spine_pitch > 0.08:
		push_error(
			"validate: breath applied spine pitch lean (max |X|=%s) — should be scale-only"
			% max_spine_pitch
		)
		quit(1)
		return
	print("validate: breath no-pitch OK")

	# Hair pin: after tip motion, HairRoot + Hair_1 must stay at rest (identity soft).
	var pin_snap: Dictionary = sec.call("debug_snapshot")
	var pin_max := int(pin_snap.get("hair_pin_max", -1))
	var pin_deltas: Dictionary = pin_snap.get("hair_pin_deltas", {})
	print("validate: hair_pin_max=", pin_max, " deltas=", pin_deltas)
	if pin_max != 1:
		push_error("validate: expected hair_pin_max=1, got %s" % pin_max)
		quit(1)
		return
	for pn in pin_deltas.keys():
		var info: Dictionary = pin_deltas[pn]
		if float(info.get("angle", 99.0)) > 0.02 or float(info.get("pos", 99.0)) > 0.002:
			push_error("validate: pinned hair bone %s drifted %s" % [pn, info])
			quit(1)
			return
	print("validate: hair pins OK (k<=1 rest-follow)")

	# Idle arms-back: upper arms should differ from rest after standIdle nudge.
	var idle: Dictionary = loco.call("debug_sample_idle_arms")
	print("validate: idle arms ok=", idle.get("ok"), " clip=", idle.get("clip"))
	var arms: Dictionary = idle.get("arms", {})
	var arm_moved := 0
	for aname in ["L_UpperArm_a", "R_UpperArm_a"]:
		if not arms.has(aname):
			continue
		var ainfo: Dictionary = arms[aname]
		var ang: float = float(ainfo.get("delta_angle", 0.0))
		var cz = ainfo.get("child_dir_z", null)
		print(
			"validate: idle ", aname,
			" delta_angle=", snappedf(ang, 0.0001),
			" child_dir_z=", cz
		)
		if ang > 0.02:
			arm_moved += 1
	if arm_moved < 2:
		push_error("validate: expected both upper arms nudged back, moved=%d" % arm_moved)
		quit(1)
		return
	print("validate: idle arms-back OK")

	# Feet / capsule: mesh AABB min.y ≈ 0 and capsule bottom ≈ 0.
	var aabb_min_y := 999.0
	var aabb_max_y := -999.0
	for mi in player.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null or mesh_i.mesh == null:
			continue
		var local := mesh_i.mesh.get_aabb()
		var xf := mesh_i.global_transform
		for i in 8:
			var corner := local.position + Vector3(
				local.size.x if (i & 1) else 0.0,
				local.size.y if (i & 2) else 0.0,
				local.size.z if (i & 4) else 0.0
			)
			var wy: float = (xf * corner).y - player.global_position.y
			aabb_min_y = minf(aabb_min_y, wy)
			aabb_max_y = maxf(aabb_max_y, wy)
	var col: CollisionShape3D = player.get_node("CollisionShape3D")
	var cap_bottom := 0.0
	if col.shape is CapsuleShape3D:
		cap_bottom = col.position.y - (col.shape as CapsuleShape3D).height * 0.5
	print(
		"validate: feet AABB min.y=", snappedf(aabb_min_y, 0.0001),
		" max.y=", snappedf(aabb_max_y, 0.0001),
		" capsule_bottom=", snappedf(cap_bottom, 0.0001)
	)
	if absf(cap_bottom) > 0.05:
		push_error("validate: capsule bottom should be ≈0, got %s" % cap_bottom)
		quit(1)
		return
	if aabb_min_y < -0.08 or aabb_min_y > 0.08:
		push_error("validate: mesh feet should be ≈0, got min.y=%s" % aabb_min_y)
		quit(1)
		return
	print("validate: feet/capsule OK")

	# FP stance eye heights (web stanceEye.y + lift 0.06).
	for stance_name in ["stand", "crouch", "prone"]:
		var ey: float = float(player.call("debug_fp_eye_y", stance_name))
		print("validate: FP eye y ", stance_name, "=", snappedf(ey, 0.0001))
	var ey_stand: float = float(player.call("debug_fp_eye_y", "stand"))
	var ey_crouch: float = float(player.call("debug_fp_eye_y", "crouch"))
	var ey_prone: float = float(player.call("debug_fp_eye_y", "prone"))
	if absf(ey_stand - 1.58) > 0.02:
		push_error("validate: stand FP eye y expected ~1.58, got %s" % ey_stand)
		quit(1)
		return
	if absf(ey_crouch - 1.12) > 0.02:
		push_error("validate: crouch FP eye y expected ~1.12, got %s" % ey_crouch)
		quit(1)
		return
	if absf(ey_prone - 0.36) > 0.02:
		push_error("validate: prone FP eye y expected ~0.36, got %s" % ey_prone)
		quit(1)
		return
	print("validate: FP eye heights OK")

	# Loco pick_clip samples: W/S/A/D + crouch + sprint (fwd=local.z, side=-local.x).
	var samples: Array = [
		{"label": "W walk", "mode": "stand", "fwd": 1.0, "side": 0.0, "mag": 1.0, "sprint": false, "want": "walk"},
		{"label": "S walkBack", "mode": "stand", "fwd": -1.0, "side": 0.0, "mag": 1.0, "sprint": false, "want": "walkBack"},
		{"label": "A walkLeft", "mode": "stand", "fwd": 0.0, "side": -1.0, "mag": 1.0, "sprint": false, "want": "walkLeft"},
		{"label": "D walkRight", "mode": "stand", "fwd": 0.0, "side": 1.0, "mag": 1.0, "sprint": false, "want": "walkRight"},
		{"label": "W sprint", "mode": "stand", "fwd": 1.0, "side": 0.0, "mag": 1.0, "sprint": true, "want": "run"},
		{"label": "S sprint", "mode": "stand", "fwd": -1.0, "side": 0.0, "mag": 1.0, "sprint": true, "want": "runBack"},
		{"label": "A sprint", "mode": "stand", "fwd": 0.0, "side": -1.0, "mag": 1.0, "sprint": true, "want": "runLeft"},
		{"label": "D sprint", "mode": "stand", "fwd": 0.0, "side": 1.0, "mag": 1.0, "sprint": true, "want": "runRight"},
		{"label": "W crouch", "mode": "crouch", "fwd": 1.0, "side": 0.0, "mag": 1.0, "sprint": false, "want": "crouchWalk"},
		{"label": "S crouch", "mode": "crouch", "fwd": -1.0, "side": 0.0, "mag": 1.0, "sprint": false, "want": "crouchBack"},
		{"label": "A crouch", "mode": "crouch", "fwd": 0.0, "side": -1.0, "mag": 1.0, "sprint": false, "want": "crouchLeft"},
		{"label": "D crouch", "mode": "crouch", "fwd": 0.0, "side": 1.0, "mag": 1.0, "sprint": false, "want": "crouchRight"},
		{"label": "idle crouch", "mode": "crouch", "fwd": 0.0, "side": 0.0, "mag": 0.0, "sprint": false, "want": "crouchIdle"},
		{"label": "W prone", "mode": "prone", "fwd": 1.0, "side": 0.0, "mag": 1.0, "sprint": false, "want": "proneWalk"},
	]
	for s in samples:
		loco.call("set_mode", s["mode"])
		var got: String = str(loco.call("pick_clip", s["fwd"], s["side"], s["mag"], false, s["sprint"]))
		print(
			"validate: pick_clip ", s["label"],
			" mode=", s["mode"],
			" fwd=", s["fwd"], " side=", s["side"],
			" sprint=", s["sprint"],
			" -> ", got
		)
		if got != s["want"]:
			push_error("validate: pick_clip %s expected %s got %s" % [s["label"], s["want"], got])
			quit(1)
			return
	print("validate: pick_clip samples OK")

	# Play modes: start DISPLAY; toggle to CONTROL (FP+move); back recentres TP.
	if not player.has_method("set_play_mode"):
		push_error("validate: set_play_mode missing")
		quit(1)
		return
	# Enum order: DISPLAY=0, CONTROL=1
	player.call("set_play_mode", 0)
	await process_frame
	if bool(player.first_person) or not bool(player.call("is_display_mode")):
		push_error("validate: expected DISPLAY (TP, not FP) on start path")
		quit(1)
		return
	# Head meshes should be visible in DISPLAY.
	var head_hidden := 0
	var head_total := 0
	for mi in player.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i == null:
			continue
		var low := mesh_i.name.to_lower()
		var is_head := ("_head_" in low or "hair" in low or "_eye_" in low or "_007_" in mesh_i.name)
		if not is_head:
			continue
		head_total += 1
		if not mesh_i.visible:
			head_hidden += 1
	print("validate: DISPLAY head meshes total=", head_total, " hidden=", head_hidden)
	if head_total > 0 and head_hidden > 0:
		push_error("validate: DISPLAY should show head/hair/eyes, hidden=%d" % head_hidden)
		quit(1)
		return
	player.call("set_play_mode", 1)  # CONTROL
	await process_frame
	if not bool(player.first_person) or bool(player.call("is_display_mode")):
		push_error("validate: CONTROL should be first_person")
		quit(1)
		return
	# FP hides head via render layer 19 (main cam culls it; mirror cam still renders the face).
	var fp_cam: Camera3D = player.get_node("CameraPivot/Camera3D")
	if (fp_cam.cull_mask & (1 << 18)) != 0:
		push_error("validate: FP camera should cull head layer 19")
		quit(1)
		return
	print("validate: FP head layer culled by main camera OK")
	var pos_before: Vector3 = player.global_position
	player.global_position = pos_before + Vector3(0.4, 0.0, -0.3)
	player.call("set_play_mode", 0)  # back to DISPLAY — orbit pivot follows character
	await process_frame
	var pivot: Node3D = player.get_node("CameraPivot")
	var pivot_world: Vector3 = pivot.global_position
	var dist_xz := Vector2(pivot_world.x - player.global_position.x, pivot_world.z - player.global_position.z).length()
	print(
		"validate: DISPLAY recenter pivot_xz_dist=", snappedf(dist_xz, 0.0001),
		" player=", player.global_position
	)
	if dist_xz > 0.25:
		push_error("validate: TP pivot should be on character after switch to DISPLAY")
		quit(1)
		return
	print("validate: play modes OK")
	# 观察相机：默认在房间内、正对角色；任意环绕/拉远都不出墙。
	player.global_position = pos_before
	player.call("tp_home", true)
	var bounds: AABB = player.get("camera_bounds")
	var cam3d: Camera3D = player.get_node("CameraPivot/Camera3D")
	var home_cam := cam3d.global_position
	var to_cam: Vector3 = home_cam - (player as Node3D).global_position
	var body_fwd: Vector3 = player.call("_body_forward")
	print("validate: TP home cam=", home_cam, " bounds=", bounds, " facing_dot=", snappedf(to_cam.normalized().dot(body_fwd), 0.001))
	if bounds.size == Vector3.ZERO or not bounds.grow(0.01).has_point(home_cam) or to_cam.normalized().dot(body_fwd) < 0.7:
		push_error("validate: TP home camera must be inside room and in front of character")
		quit(1)
		return
	var worst := 0.0
	for yi in 12:
		for el in [-0.3, 0.2, 1.0]:
			player.call("set_tp_view", TAU * yi / 12.0, el, 6.0)
			var cp := cam3d.global_position
			if not bounds.grow(0.01).has_point(cp):
				worst = maxf(worst, 1.0)
				print("validate: camera escaped room at yaw ", yi, " elev ", el, " cam=", cp)
	if worst > 0.0:
		push_error("validate: TP camera left room bounds")
		quit(1)
		return
	player.call("tp_home", true)
	print("validate: TP camera inside room OK")

	# Room mirror present on main.
	var mirror := main.get_node_or_null("RoomMirror")
	if mirror == null:
		push_error("validate: RoomMirror missing from main")
		quit(1)
		return
	print("validate: RoomMirror at ", mirror.global_position)
	if mirror.global_position.distance_to(Vector3(-0.035, 1.2, 0.965)) > 0.05:
		push_error("validate: RoomMirror position mismatch")
		quit(1)
		return
	print("validate: RoomMirror OK")

	# Loco → idle 0.5s blend (no snap from mid-walk arms).
	var stopb: Dictionary = loco.call("debug_sample_stop_blend")
	print(
		"validate: stop blend ok=", stopb.get("ok"),
		" first=", snappedf(float(stopb.get("first_ang_from_walk", -1.0)), 0.0001),
		" end=", snappedf(float(stopb.get("end_ang_from_walk", -1.0)), 0.0001),
		" settle=", stopb.get("settle"),
		" dur=", stopb.get("dur")
	)
	if not bool(stopb.get("ok", false)):
		push_error("validate: stop blend sample failed")
		quit(1)
		return
	var first_ang := float(stopb.get("first_ang_from_walk", 99.0))
	var end_ang := float(stopb.get("end_ang_from_walk", 0.0))
	if first_ang > 0.22:
		push_error("validate: loco→idle snapped (first_ang=%s)" % first_ang)
		quit(1)
		return
	if end_ang < first_ang + 0.08:
		push_error("validate: loco→idle did not blend toward idle (end=%s first=%s)" % [end_ang, first_ang])
		quit(1)
		return
	print("validate: loco stop blend OK")

	# Body yaw: moving snaps to camera; idle keeps ±60° deadzone.
	var y_move: float = player.call("debug_next_body_yaw", 1.0, 0.0, true)
	var y_idle: float = player.call("debug_next_body_yaw", 0.4, 0.0, false)
	var y_catch: float = player.call("debug_next_body_yaw", 1.2, 0.0, false)
	print(
		"validate: body yaw move=", snappedf(y_move, 0.0001),
		" idle=", snappedf(y_idle, 0.0001),
		" catch=", snappedf(y_catch, 0.0001)
	)
	if absf(y_move - 1.0) > 0.001:
		push_error("validate: moving body yaw should equal camera yaw")
		quit(1)
		return
	if absf(y_idle) > 0.001:
		push_error("validate: idle look inside deadzone should not turn body")
		quit(1)
		return
	var expect_catch := 1.2 - PI / 3.0
	if absf(y_catch - expect_catch) > 0.01:
		push_error("validate: idle look past deadzone should clamp to ±60° (got %s want %s)" % [y_catch, expect_catch])
		quit(1)
		return
	print("validate: body yaw rules OK")

	# Mirror optics: reflect eye across wall plane (n = local +Z after yaw=π → world -Z).
	if mirror.has_method("debug_reflect_eye"):
		var eye := Vector3(0.0, 1.12, 0.0)
		var refl: Dictionary = mirror.call("debug_reflect_eye", eye)
		var n: Vector3 = refl.get("normal", Vector3.ZERO)
		var mir: Vector3 = refl.get("mirrored", Vector3.ZERO)
		print("validate: mirror n=", n, " mirrored=", mir, " dist=", refl.get("dist"))
		if n.dot(Vector3(0.0, 0.0, -1.0)) < 0.98:
			push_error("validate: mirror normal should face room (-Z)")
			quit(1)
			return
		if mir.distance_to(Vector3(0.0, 1.12, 1.93)) > 0.05:
			push_error("validate: reflected eye mismatch %s" % mir)
			quit(1)
			return
		print("validate: mirror reflect math OK")

	# Gaze stability: head is NOT a loco bone — look must not accumulate/spin.
	sec.call("clear_body_look")
	var cam_pos: Vector3 = player.global_position + Vector3(0.0, 1.4, 2.8)
	sec.call("set_gaze_target", cam_pos)
	var head_i := skel.find_bone("C_Head_a")
	if head_i < 0:
		push_error("validate: C_Head_a missing")
		quit(1)
		return
	var max_head_delta := 0.0
	var prev_q := skel.get_bone_pose_rotation(head_i)
	for _g in 90:
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
		# Re-assert gaze each frame like DISPLAY mode.
		sec.call("set_gaze_target", cam_pos)
		var q := skel.get_bone_pose_rotation(head_i)
		var dq := prev_q.inverse() * q
		var dang := 2.0 * acos(clampf(absf(dq.w), 0.0, 1.0))
		max_head_delta = maxf(max_head_delta, dang)
		prev_q = q
	# Absolute look from rest should stay within ~1.2 rad of identity, and
	# frame-to-frame delta should settle (not keep growing).
	var final_q := skel.get_bone_pose_rotation(head_i)
	var rest_q := skel.get_bone_rest(head_i).basis.get_rotation_quaternion()
	var from_rest := rest_q.inverse() * final_q
	var from_rest_ang := 2.0 * acos(clampf(absf(from_rest.w), 0.0, 1.0))
	print(
		"validate: gaze head from_rest_ang=", snappedf(from_rest_ang, 0.0001),
		" max_frame_delta=", snappedf(max_head_delta, 0.0001)
	)
	if from_rest_ang > 1.6:
		push_error("validate: gaze head spun away from rest (ang=%s)" % from_rest_ang)
		quit(1)
		return
	if max_head_delta > 0.85:
		push_error("validate: gaze head frame delta too large (spin?) delta=%s" % max_head_delta)
		quit(1)
		return
	sec.call("clear_gaze")
	print("validate: gaze stability OK")

	# Organs + abdomen x-ray (web figure.tsx port).
	var organs: Node = player.call("get_organs") if player.has_method("get_organs") else null
	if organs == null or not bool(organs.get("ready_ok")):
		push_error("validate: OrganRig missing / not ready")
		quit(1)
		return
	if not bool(organs.get("xray_enabled")) or absf(float(organs.call("effective_xray")) - 0.38) > 1e-4:
		push_error("validate: abdomen x-ray should default ON at 0.38")
		quit(1)
		return
	var om: Array = organs.get("organ_meshes")
	var n_gut := 0
	var n_pelvis := 0
	for o in om:
		var omi := o as MeshInstance3D
		if omi.get_parent() != skel or omi.skin == null or omi.get_node_or_null(omi.skeleton) != skel:
			push_error("validate: organ %s not skinned to Tifa skeleton" % omi.name)
			quit(1)
			return
		if str(omi.get_meta("organ_group")) == "gut":
			n_gut += 1
		else:
			n_pelvis += 1
	var has_uterus := false
	for o in om:
		if "uterus" in str((o as MeshInstance3D).get_meta("organ_material")).to_lower():
			has_uterus = true
	print("validate: organs gut=", n_gut, " pelvis=", n_pelvis, " uterus=", has_uterus)
	if n_gut < 3 or n_pelvis < 3 or not has_uterus:
		push_error("validate: expected intestines (3) + pelvis pack incl. uterus")
		quit(1)
		return
	var sk_meshes: Array = organs.get("skin_meshes")
	if sk_meshes.size() < 2:
		push_error("validate: torso skin x-ray materials not installed")
		quit(1)
		return
	var smat := (sk_meshes[0] as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
	if smat == null or smat.next_pass == null:
		push_error("validate: skin x-ray punch+fade materials missing")
		quit(1)
		return
	# Navel frame sits on the belly (inside body AABB, in front of spine).
	organs.call("step", 0.016)
	var nav: Vector3 = organs.call("navel_world")
	var nav_local: Vector3 = (player as Node3D).to_local(nav)
	print("validate: navel world=", nav, " local=", nav_local)
	if nav_local.y < 0.95 or nav_local.y > 1.15:
		push_error("validate: navel frame height off %s" % nav_local)
		quit(1)
		return
	# Ray from in front hits belly ellipsoid.
	var fr: Transform3D = organs.call("abdomen_frame")
	var ro := fr.origin + fr.basis.z * 0.8
	var hit_v: Variant = organs.call("ray_hit_belly", ro, -fr.basis.z)
	if hit_v == null:
		push_error("validate: belly ray hit failed")
		quit(1)
		return
	var hit_p: Vector3 = hit_v
	print("validate: belly hit dist from navel=", snappedf(hit_p.distance_to(fr.origin), 0.0001))
	# Toggle x-ray off/on.
	organs.call("toggle_xray")
	if float(organs.call("effective_xray")) != 0.0:
		push_error("validate: toggle_xray did not turn off")
		quit(1)
		return
	organs.call("toggle_xray")
	# Drag: deforms, then springs back after release.
	organs.call("set_interact_mode", "drag")
	organs.call("begin_drag", hit_p)
	organs.call("update_drag", hit_p + fr.basis.x * 0.06 + fr.basis.z * 0.03)
	for _d in 30:
		organs.call("step", 0.016)
	var d_on: float = organs.call("drag_offset_length")
	organs.call("end_drag")
	var d_peak := d_on
	for _d2 in 120:
		organs.call("step", 0.016)
		d_peak = maxf(d_peak, float(organs.call("drag_offset_length")))
	var d_off: float = organs.call("drag_offset_length")
	print("validate: drag offset held=", snappedf(d_on, 0.0001), " after release=", snappedf(d_off, 0.00001))
	if d_on < 0.03 or d_off > 0.002:
		push_error("validate: drag should deform (>3cm) then recover (<2mm); got %s / %s" % [d_on, d_off])
		quit(1)
		return
	# Strike: wave deforms guts, then fades out.
	organs.call("set_interact_mode", "strike")
	organs.call("strike_at", hit_p)
	for _s in 8:
		organs.call("step", 0.016)
	var probe := fr.affine_inverse() * hit_p + Vector3(0.0, 0.0, -0.03)
	var s_on: float = organs.call("debug_strike_displacement", probe)
	for _s2 in 240:
		organs.call("step", 0.016)
	var waves_left: int = organs.call("active_waves")
	print("validate: strike disp=", snappedf(s_on, 0.0001), " waves after 4s=", waves_left)
	if s_on < 0.01 or waves_left != 0:
		push_error("validate: strike should dent guts then recover")
		quit(1)
		return
	print("validate: organs / x-ray OK")

	# 内脏布局：整体质心在肚脐下方、小肠团不顶到胸下、子宫在耻骨后方，且全部在皮肤内 / X 光窗口内。
	var mt: Dictionary = organs.get("meta")
	var navy: float = (mt["navel"] as Array)[1]
	var prof: Dictionary = mt["profile"]
	var xr: Dictionary = mt["xray"]
	var sum := Vector3.ZERO
	var cnt := 0
	var out_skin := 0
	var out_win := 0
	var gut_top := -1e9
	for omi in organs.get("organ_meshes"):
		var arr: Array = (omi as MeshInstance3D).mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for vi in range(0, vs.size(), 3):
			var v: Vector3 = vs[vi]
			sum += v
			cnt += 1
			var pr := _prof_at(prof, v.y)
			if v.z > pr.y - 0.001 or absf(v.x) > pr.x:
				out_skin += 1
			if v.y < navy + float(xr["y0"]) or v.y > navy + float(xr["y1"]):
				out_win += 1
			if String(omi.name).to_lower().contains("tunntarm"):
				gut_top = maxf(gut_top, v.y)
	var cen := sum / maxf(1.0, cnt)
	var ut: Dictionary = mt["uterus"]
	var ut_top: float = (ut["max"] as Array)[1]
	print(
		"validate: organs centroid=", cen, " navel_y=", navy, " small-int top=", snappedf(gut_top, 0.001),
		" uterus_top=", snappedf(ut_top, 0.001), " out_skin=", out_skin, "/", cnt, " out_xray=", out_win
	)
	if cen.y > navy - 0.01 or gut_top > navy + 0.13 or ut_top > navy - 0.08 or out_skin > 0 or out_win > 0:
		push_error("validate: organ layout off (centroid must be below navel, inside skin and x-ray window)")
		quit(1)
		return
	print("validate: organ layout OK")

	# 乳摇：弹簧-阻尼受冲击后摆动，3 秒内稳定回静止。
	var br: RefCounted = sec.get("breasts")
	if br == null:
		push_error("validate: BreastPhysics missing")
		quit(1)
		return
	br.set("enabled", true)
	br.set("strength", 0.5)
	for _w in 60:
		br.call("update", 1.0 / 60.0)
	br.call("debug_kick", Vector3(0.0, -0.9, 0.25))
	var jpeak := 0.0
	var cross := 0
	var last_sign := 0.0
	for _w2 in 40:
		br.call("update", 1.0 / 60.0)
		var st: Dictionary = (br.call("debug_state") as Dictionary)["L"]
		jpeak = maxf(jpeak, float(st["disp"]))
		var sg := signf(float(st["disp_y"]))
		if last_sign != 0.0 and sg != 0.0 and sg != last_sign:
			cross += 1
		if sg != 0.0:
			last_sign = sg
	for _w3 in 180:
		br.call("update", 1.0 / 60.0)
	var fin: Dictionary = br.call("debug_state")
	var fin_l: Dictionary = fin["L"]
	print(
		"validate: jiggle peak=", snappedf(jpeak, 0.0001), " zero-crossings=", cross,
		" after 3s disp=", snappedf(float(fin_l["disp"]), 0.00001), " speed=", snappedf(float(fin_l["speed"]), 0.00001)
	)
	if jpeak < 0.008 or cross < 1 or float(fin_l["disp"]) > 0.0015 or float(fin_l["speed"]) > 0.002:
		push_error("validate: breast spring should swing then settle")
		quit(1)
		return
	print("validate: breast jiggle OK")

	print("validate: OK")
	quit(0)


## 头发蒙皮采样：scalp = 头顶（静止 y>1.50），tips = 发尾（y<1.0）。
func _hair_samples(skel: Skeleton3D) -> Dictionary:
	var mi: MeshInstance3D = null
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		if String(n.name).contains("PC0002_01_007"):
			mi = n
			break
	if mi == null or mi.skin == null:
		return {}
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var wts: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var scalp := PackedInt32Array()
	var tips := PackedInt32Array()
	for i in vs.size():
		if vs[i].y > 1.50 and i % 7 == 0:
			scalp.append(i)
		elif vs[i].y < 1.0 and i % 23 == 0:
			tips.append(i)
	var bind_bone := PackedInt32Array()
	for b in mi.skin.get_bind_count():
		var bi := mi.skin.get_bind_bone(b)
		if bi < 0:
			bi = skel.find_bone(mi.skin.get_bind_name(b))
		bind_bone.append(bi)
	return {
		"mi": mi, "vs": vs, "bones": bones, "wts": wts, "stride": bones.size() / maxi(1, vs.size()),
		"scalp": scalp, "tips": tips, "bind_bone": bind_bone, "head": skel.find_bone("C_Head_a"),
	}


func _skinned_rel_head(skel: Skeleton3D, hs: Dictionary, key: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	var mi: MeshInstance3D = hs["mi"]
	var vs: PackedVector3Array = hs["vs"]
	var bones: PackedInt32Array = hs["bones"]
	var wts: PackedFloat32Array = hs["wts"]
	var stride: int = hs["stride"]
	var bb: PackedInt32Array = hs["bind_bone"]
	var head_inv := skel.get_bone_global_pose(int(hs["head"])).affine_inverse()
	for i in (hs[key] as PackedInt32Array):
		var p := Vector3.ZERO
		for j in stride:
			var w := wts[i * stride + j]
			if w <= 0.0:
				continue
			var b := bones[i * stride + j]
			var m := skel.get_bone_global_pose(bb[b]) * mi.skin.get_bind_pose(b)
			p += (m * vs[i]) * w
		out.append(head_inv * p)
	return out


## 躯干轮廓插值：返回 (half_x, z_front)
func _prof_at(prof: Dictionary, y: float) -> Vector2:
	var ys: Array = prof["y"]
	var hx: Array = prof["half_x"]
	var zf: Array = prof["z_front"]
	if y <= float(ys[0]):
		return Vector2(hx[0], zf[0])
	for i in range(1, ys.size()):
		if y <= float(ys[i]):
			var t := (y - float(ys[i - 1])) / maxf(1e-6, float(ys[i]) - float(ys[i - 1]))
			return Vector2(lerpf(hx[i - 1], hx[i], t), lerpf(zf[i - 1], zf[i], t))
	return Vector2(hx[ys.size() - 1], zf[ys.size() - 1])
