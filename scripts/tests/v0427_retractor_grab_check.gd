extends "res://scripts/tests/v0411_check.gd"
## 未发布（t104u）：拿取工具（以及普通互动工具 / 手术里空手的 HangGrab 路径）可以拿起已放好的拉钩：
## 沿创缘拖动把拉钩挪到新位置（旧位置的拉开撤回、新位置拉开），往外拉 / 往回推改变拉开程度，松手留在新位置；
## 拉钩工具放置 / 移除不受影响。
##   godot --headless --path . -s res://scripts/tests/v0427_retractor_grab_check.gd

const V := Vector3(0.0, 0.97, 0.24)


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
	if not await _enter_bed():
		print("v0427_retractor_grab_check: fails=", fails)
		quit(1)
		return
	s = player.call("get_surgery")
	s.call("enter_surgery")
	await _frames(4)
	await _check_straight()
	await _check_ring()
	print("v0427_retractor_grab_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _nearest(outer, pts: PackedInt32Array, p: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var bd := 1e9
	for w in pts:
		var d: float = (outer.pos[w] as Vector3).distance_to(p)
		if d < bd:
			bd = d
			best = outer.pos[w]
	return best


func _gap(vid: int, other: PackedInt32Array) -> float:
	var outer = s.get("_outer")
	return (outer.pos[vid] as Vector3).distance_to(_nearest(outer, other, outer.pos[vid]))


func _rec(i: int) -> Dictionary:
	return (s.get("_retractors") as Array)[i]


func _node(i: int) -> Node3D:
	return _rec(i)["node"]


func _hook(i: int) -> Vector3:
	return s.call("_retr_hook_world", i)


## 指针射线：从目标点 T 上方沿 V 往下看（拖动平面法线 = 射线方向，命中点 ≈ T）。
func _ray_to(t: Vector3) -> Array:
	var v := V.normalized()
	return [t + v * 0.3, -v]


func _grab_tool_drag(i: int, off: Vector3, steps: int = 12) -> bool:
	s.call("ensure_tool", "grab")
	var h := _hook(i)
	var aim := _node(i).global_position
	var r0 := _ray_to(aim)
	if not bool(s.call("begin_stroke", r0[0], r0[1])):
		print("  begin_stroke failed: hits retractor ", s.call("_ray_hits_retractor", r0[0], r0[1]), " grab_active ", s.get("_grab_active"), " kind ", s.get("_grab_kind"), " tool ", s.get("tool"), " stroke ", s.get("stroke_active"))
		return false
	var ok := bool(s.get("_grab_active")) and str(s.get("_grab_kind")) == "retractor" and bool(s.get("_retr_slide"))
	var ref: Vector3 = s.get("_retr_ref")
	for k in steps:
		var r := _ray_to(ref + off * (float(k + 1) / float(steps)))
		s.call("drag_stroke", r[0], r[1])
		await _frames(1)
	s.call("end_stroke")
	await _frames(2)
	return ok and h.is_finite()


func _check_straight() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	_ok(_straight(nav + Vector3(-0.045, -0.05, 0), nav + Vector3(0.045, -0.055, 0)), "straight cut")
	var lr: Array = s.call("cut_lips", 0)
	var left: PackedInt32Array = lr[0]
	var right: PackedInt32Array = lr[1]
	var gap_rest := {}
	for v in left:
		gap_rest[v] = _gap(v, right)
	var vid0 := left[left.size() / 2]
	_ok(bool(s.call("place_retractor", vid0)), "retractor placed with the retractor-tool API")
	await _frames(2)
	var g_place := _gap(vid0, right)
	var handle := -_node(0).global_transform.basis.z.normalized()
	# A. 拿取工具往外拉：拉开更多，拉钩不动位置。
	_ok(await _grab_tool_drag(0, handle * 0.012), "grab tool picks up the placed retractor (not the skin / an organ)")
	var g_pull := _gap(int(_rec(0)["vid"]), right)
	print("RGRAB straight pull: vid %d → %d, lip gap rest %.1f, placed %.1f, after pull %.1f mm" % [vid0, int(_rec(0)["vid"]), float(gap_rest[vid0]) * 1000, g_place * 1000, g_pull * 1000])
	_ok(int(s.call("retractor_count")) == 1 and int(_rec(0)["vid"]) == vid0, "pulling outward keeps the retractor on its spot")
	_ok(g_pull > g_place + 0.001, "pulling it outward holds the incision open wider (%.1f → %.1f mm)" % [g_place * 1000, g_pull * 1000])
	_ok(not bool(s.get("_grab_active")) and _node(0).visible, "released: the retractor stays placed")
	# B. 沿创缘拖：挪到新顶点，旧位置撤回、新位置拉开。
	var tx := _node(0).global_transform.basis.x.normalized()
	var h0 := _hook(0)
	var moved0 := int(s.get("retractor_moved"))
	_ok(await _grab_tool_drag(0, tx * 0.016, 16), "grab tool picks it up again")
	var vid1 := int(_rec(0)["vid"])
	var h1 := _hook(0)
	var g_old := _gap(vid0, right)
	var g_new := _gap(vid1, right)
	var along := (h1 - h0).dot(tx)
	print("RGRAB straight slide: vid %d → %d (%d moves), hook moved %.1f mm along the rim, old spot gap %.1f mm (rest %.1f), new spot gap %.1f mm (rest %.1f)" % [vid0, vid1, int(s.get("retractor_moved")) - moved0, absf(along) * 1000, g_old * 1000, float(gap_rest[vid0]) * 1000, g_new * 1000, float(gap_rest.get(vid1, 0.0)) * 1000])
	_ok(vid1 != vid0 and left.has(vid1), "sliding along the rim moves the hook to another vertex of the same lip")
	_ok(absf(along) >= 0.006 and (h1 - h0).length() < 0.03, "the retractor followed along the wound rim (%.1f mm)" % (absf(along) * 1000))
	_ok(g_old < g_pull - 0.001, "the old spot is no longer held open (%.1f mm, was %.1f mm)" % [g_old * 1000, g_pull * 1000])
	_ok(g_new > float(gap_rest.get(vid1, 0.0)) + 0.002, "the new spot is held open (%.1f mm vs %.1f mm at rest)" % [g_new * 1000, float(gap_rest.get(vid1, 0.0)) * 1000])
	var h_after := -_node(0).global_transform.basis.z.normalized()
	var pw: Vector3 = s.call("_approx_world_bind", s.get("_outer").pos[vid1])
	var nw: Vector3 = s.call("_approx_world_bind", _nearest(s.get("_outer"), right, s.get("_outer").pos[vid1]))
	_ok(h_after.dot((pw - nw).normalized()) > 0.3, "at the new spot the handle still points away from the incision (incision geometry rule)")
	await _frames(4)
	_ok(int(_rec(0)["vid"]) == vid1 and int(s.call("retractor_count")) == 1, "released: it stays at the new spot")
	# C. 普通互动工具 / 空手（HangGrab）也能拿。
	var aim := _hook(0)
	var cam: Camera3D = player.call("get_camera")
	var cf := (-cam.global_transform.basis.z).normalized()
	var r0 := [aim - cf * 0.3, cf]
	var g_c0 := _gap(vid1, right)
	_ok(bool(player.call("debug_begin_hang_grab", r0[0], r0[1])) and player.call("hang_grab_organ") == s, "the normal interaction hand (HangGrab) grabs the retractor")
	var ref: Vector3 = s.get("_retr_ref")
	var hand := -_node(0).global_transform.basis.z.normalized()
	for k in 10:
		var tg := ref + hand * (0.012 * float(k + 1) / 10.0)
		player.call("debug_update_hang_grab", tg - cf * 0.3, cf)
		await _frames(1)
	player.call("debug_end_hang_grab")
	await _frames(2)
	var g_c1 := _gap(int(_rec(0)["vid"]), right)
	print("RGRAB HangGrab pull: gap %.1f → %.1f mm" % [g_c0 * 1000, g_c1 * 1000])
	_ok(g_c1 > g_c0 + 0.0005 and not bool(s.get("_grab_active")), "HangGrab drag changes the opening and releases cleanly")
	# D. 拉钩工具照旧：点中已有拉钩 = 原来的拉动（不挪位），右键 / 移除，点唇缘放置。
	s.call("ensure_tool", "retractor")
	var r1 := _ray_to(_node(0).global_position)
	_ok(bool(s.call("begin_stroke", r1[0], r1[1])) and str(s.get("_grab_kind")) == "retractor" and not bool(s.get("_retr_slide")), "retractor tool still picks a placed retractor with its own drag")
	s.call("end_stroke")
	_ok(bool(s.call("remove_retractor", 0)) and int(s.call("retractor_count")) == 0, "retractor tool removal still works")
	for k in 40:
		await _phys(1)
	var pv := left[left.size() / 3]
	var vw: Vector3 = s.call("_vert_world", pv)
	var ro := vw + Vector3(0, 0.3, 0.02)
	_ok(bool(s.call("begin_stroke", ro, (vw - ro).normalized())), "retractor tool begins placing on the lip")
	s.call("end_stroke")
	_ok(int(s.call("retractor_count")) == 1, "retractor tool places a new retractor")


func _check_ring() -> void:
	await _restart()
	var nav: Vector3 = s.get("_navel_rest")
	s.call("set_cut_mode", "ring")
	_ok(bool(s.call("debug_set_ring_preview", nav + Vector3(0.0, 0.035, 0.0), 0.03, 0.022)) and bool(s.call("confirm_cut", false)), "ring cut")
	s.call("debug_finish_cut_anim")
	s.call("debug_settle_eversion")
	var cands: PackedInt32Array = s.call("_lip_candidates")
	_ok(cands.size() > 8, "ring rim has lip vertices")
	if cands.size() <= 8:
		return
	var vid0 := cands[cands.size() / 4]
	_ok(bool(s.call("place_retractor", vid0)), "ring: retractor placed")
	await _frames(2)
	var tx := _node(0).global_transform.basis.x.normalized()
	var h0 := _hook(0)
	_ok(await _grab_tool_drag(0, tx * 0.014, 14), "ring: grab tool picks up the retractor")
	var vid1 := int(_rec(0)["vid"])
	print("RGRAB ring slide: vid %d → %d, hook moved %.1f mm" % [vid0, vid1, (_hook(0) - h0).length() * 1000])
	_ok(vid1 != vid0 and cands.has(vid1) and (_hook(0) - h0).length() >= 0.005, "ring: sliding moves it along the hole rim")
	_ok(int(s.call("retractor_count")) == 1 and _node(0).visible, "ring: still one placed retractor")
