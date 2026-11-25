extends "res://scripts/tests/v0411_check.gd"
## Headless script-cost profiler for the T-13 performance pass.
##   godot --headless --path . -s res://scripts/tests/perf_profile.gd
## Optional: PERF_OUT=/tmp/perf_before.txt

var _rows: Array = []


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	hud = main.get_node("HUD")

	# 1. Standing / normal play (not on the bed).
	await _sample("idle_standing", 90)

	if not await _enter_bed():
		_write_out()
		quit(1)
		return
	player.call("set_play_mode", 0)
	await _frames(4)
	await _sample("observe_bed", 90)

	# 2. Surgery, wound open, uterus extracted.
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _sample("surgery_idle", 60)
	await _open_wound()
	await _sample("surgery_wound", 60)
	if s.has_method("debug_begin_extract"):
		s.call("debug_begin_extract", "uterus")
		s.call("debug_forceps_end")
		s.call("_update_guts", 1.0 / 60.0)
		var so = s.call("soft_organ", "uterus") if s.has_method("soft_organ") else null
		if so:
			var cage: PackedVector3Array = so.get("_p")
			var outv: Vector3 = (s.call("_cavity_outward") as Vector3).normalized()
			var aim: Vector3 = cage[cage.size() - 1]
			var cam_o := aim + outv * 0.12
			if bool(s.call("debug_forceps_begin", cam_o, (aim - cam_o).normalized())):
				var tip: Vector3 = so.get("hold_pos")
				for i in 40:
					tip = tip + outv * 0.004
					s.call("debug_forceps_drag_to", tip)
					s.call("debug_forceps_tick", 1.0 / 60.0)
					await _phys(1)
				s.call("debug_forceps_end")
		await _frames(8)
	await _sample("surgery_uterus_out", 90)

	# 3. Vagina mode: speculum, then ball rod + PiP.
	if bool(s.call("is_active")):
		s.call("exit_surgery")
		await _frames(3)
	var vm = player.call("get_vagina_mode")
	player.call("set_play_mode", 0)
	if vm:
		vm.call("enter")
		await _frames(3)
		vm.call("set_tool", "speculum")
		if s and not bool(s.call("is_speculum_inserted")):
			s.call("set_tool", "speculum")
			if s.has_method("debug_finish_speculum_anim"):
				s.call("debug_finish_speculum_anim")
			await _frames(3)
		if s:
			s.call("set_speculum_angle", 22.0)
		await _frames(4)
		await _sample("vagina_speculum", 90)

		vm.call("set_tool", "ball_rod")
		await _frames(4)
		var ctl = vm.call("tool_controller")
		if ctl and ctl.has_method("debug_set_depth"):
			var opening: Vector3 = vm.call("introitus_world")
			var cerv: Vector3 = vm.call("cervix_world")
			ctl.call("debug_set_depth", opening.distance_to(cerv) * 0.5)
		await _frames(2)
		await _sample("vagina_ball_rod_pip", 90)

		# 4. Prolapse swinging.
		var org = player.call("get_organs")
		var pc = org.call("prolapse") if org else null
		if pc:
			pc.call("set_amount", 0.97)
			await _phys(40)
			var n := int(pc.get("_n"))
			var nodes: PackedVector3Array = pc.call("node_positions")
			var f0 := nodes[n - 1]
			var side: Vector3 = (pc.call("canal_axis_world") as Vector3).cross(Vector3.UP).normalized()
			pc.call("begin_drive", "perf", n - 1, f0, true)
			for i in 8:
				pc.call("drive_to", f0 + side * 0.05 * float(i + 1) / 8.0)
				await _phys(1)
			pc.call("end_drive")
			await _sample("prolapse_swing", 90)
			pc.call("reset")
		if vm.has_method("exit"):
			vm.call("exit")
		await _frames(2)

	# 5. Ragdoll (kill the player on the bed, then off the bed if needed).
	if player.has_method("apply_damage"):
		player.call("apply_damage", 9999.0, {"src": "perf"})
		await _phys(8)
		await _sample("ragdoll", 90)
		if player.has_method("restore_body"):
			player.call("restore_body")
			await _phys(4)

	_write_out()
	quit(0)


func _sample(name: String, frames: int) -> void:
	var acc := {}
	var keys := ["frame_us", "proc_us", "phys_us", "organ", "vulva", "surgery_gut", "soft_uterus", "prolapse", "ball_rod", "pip", "vagina"]
	for k in keys:
		acc[k] = 0
	var n := 0
	var worst_frame := 0
	for _w in 8:
		await process_frame
	for i in frames:
		var t0 := Time.get_ticks_usec()
		await process_frame
		var fu := int(Time.get_ticks_usec() - t0)
		acc["frame_us"] = int(acc["frame_us"]) + fu
		worst_frame = maxi(worst_frame, fu)
		acc["proc_us"] = int(acc["proc_us"]) + int(Performance.get_monitor(Performance.TIME_PROCESS) * 1e6)
		acc["phys_us"] = int(acc["phys_us"]) + int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1e6)
		var rig = player.call("get_organs") if player and player.has_method("get_organs") else null
		if rig:
			acc["organ"] = int(acc["organ"]) + int(rig.get("last_step_usec"))
			if rig.get("vulva"):
				var vf = rig.vulva
				var vu := 0
				if vf.has_method("step_usec_this_frame"):
					vu = int(vf.call("step_usec_this_frame"))
				else:
					vu = int(vf.get("last_commit_usec")) if vf.get("last_commit_usec") != null else int(vf.get("last_step_usec"))
				acc["vulva"] = int(acc["vulva"]) + vu
		if s:
			acc["surgery_gut"] = int(acc["surgery_gut"]) + int(s.get("gut_update_usec"))
			var so = s.call("soft_organ", "uterus") if s.has_method("soft_organ") else null
			if so:
				acc["soft_uterus"] = int(acc["soft_uterus"]) + int(so.get("last_step_usec"))
		if rig and rig.has_method("prolapse"):
			var pc = rig.call("prolapse")
			if pc:
				acc["prolapse"] = int(acc["prolapse"]) + int(pc.get("last_step_usec"))
		var vm = player.call("get_vagina_mode") if player and player.has_method("get_vagina_mode") else null
		if vm:
			acc["vagina"] = int(acc["vagina"]) + int(vm.get("last_step_usec"))
			if vm.has_method("tool_controller"):
				var ctl = vm.call("tool_controller")
				if ctl:
					acc["ball_rod"] = int(acc["ball_rod"]) + int(ctl.get("last_step_usec"))
			if vm.has_method("cross_section"):
				var sec = vm.call("cross_section")
				if sec:
					acc["pip"] = int(acc["pip"]) + int(sec.get("last_step_usec"))
		n += 1
	var rec := {"name": name, "n": n, "worst_frame": worst_frame}
	for k in keys:
		rec[k] = int(round(float(acc[k]) / float(maxi(n, 1))))
	_rows.append(rec)
	print("PERF %s n=%d frame=%dµs (worst %d) proc=%d phys=%d organ=%d vulva=%d gut=%d soft_ut=%d prol=%d rod=%d pip=%d vag=%d" % [
		name, n, rec["frame_us"], worst_frame, rec["proc_us"], rec["phys_us"],
		rec["organ"], rec["vulva"], rec["surgery_gut"], rec["soft_uterus"],
		rec["prolapse"], rec["ball_rod"], rec["pip"], rec["vagina"],
	])


func _write_out() -> void:
	var lines := PackedStringArray()
	lines.append("scenario\tn\tframe_us\tworst_us\tproc_us\tphys_us\torgan\tvulva\tgut\tsoft_ut\tprolapse\trod\tpip\tvagina")
	for r in _rows:
		lines.append("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d" % [
			r["name"], r["n"], r["frame_us"], r["worst_frame"], r["proc_us"], r["phys_us"],
			r["organ"], r["vulva"], r["surgery_gut"], r["soft_uterus"],
			r["prolapse"], r["ball_rod"], r["pip"], r["vagina"],
		])
	var text := "\n".join(lines) + "\n"
	print(text)
	var path := OS.get_environment("PERF_OUT")
	if path == "":
		path = "/tmp/perf_profile.tsv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		print("wrote ", path)
