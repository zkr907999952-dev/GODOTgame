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
	sec.call("debug_jerk_root", Vector3(0.15, 0.0, 0.0))
	for _k in 12:
		sec.call("update", 0.016, false)
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
	if max_scale > 1.35 or min_scale < 0.7:
		push_error(
			"validate: breath bone scale drifted (min=%s max=%s) — compounding bug?"
			% [min_scale, max_scale]
		)
		quit(1)
		return

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

	print("validate: OK")
	quit(0)
