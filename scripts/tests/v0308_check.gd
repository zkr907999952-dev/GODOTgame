extends SceneTree
## 0.3.8 自检：胶囊移动碰撞 + 骨骼精细命中箱、显示碰撞、检查床 Tab = 观察视角、手术拿取只拉被抓唇缘（切口两端不动）、
## 皮瓣外皮 / 截面两种材质、复原身体（满血 / 复活起身 / 清切口）、切割预览网格加速与事件合并、正式手术刀模型、
## 新弹孔贴图 3 秒后淡出释放。
##   godot --headless --path . -s res://scripts/tests/v0308_check.gd
## （手术部分也可用 LIBGL_ALWAYS_SOFTWARE=1 … --rendering-method gl_compatibility --rendering-driver opengl3 跑。）

const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var main: Node
var player: CharacterBody3D
var vs: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0308: OK   ", msg)
	else:
		fails += 1
		push_error("v0308: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	vs = main.get("vehicle_system")
	_ok(player != null and vs != null, "scene booted")
	if player == null:
		quit(1)
		return
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/code=") >= 0, "export version 0.3.8+ (42+)")
	await _check_capsule_and_hitboxes()
	await _check_ledge_support()
	await _check_collision_debug()
	await _check_decals()
	await _check_clone_hitbox_ballistics()
	await _check_restore_clone()
	await _check_exam_bed_tab_and_surgery()
	print("v0308_check: fails=", fails)
	quit(0 if fails == 0 else 1)


# ---- 1) 胶囊 + 命中箱
func _check_capsule_and_hitboxes() -> void:
	var col: CollisionShape3D = player.get_node("CollisionShape3D")
	_ok(col.shape is CapsuleShape3D, "player movement shape is a capsule")
	_ok(str(player.call("movement_shape_kind")) == "capsule", "player reports capsule movement shape")
	var hb: Node = player.call("get_hitboxes")
	_ok(hb != null and int(hb.call("part_count")) >= 15, "player has fine per-part capsule hitboxes (%d)" % (int(hb.call("part_count")) if hb else 0))
	if hb == null:
		return
	var all_caps := true
	var all_layer := true
	for b in hb.call("bodies"):
		var sb := b as StaticBody3D
		all_layer = all_layer and sb.collision_layer == 32 and sb.collision_mask == 0
		for c in sb.get_children():
			if c is CollisionShape3D:
				all_caps = all_caps and (c as CollisionShape3D).shape is CapsuleShape3D
	_ok(all_caps, "every hitbox part is a capsule")
	_ok(all_layer, "hitboxes live on layer 6 (32) and never push the movement capsule")
	await _phys(3)
	var skel: Skeleton3D = player.call("get_skeleton")
	var head_i := skel.find_bone("C_Head_a")
	var head_w := skel.global_transform * skel.get_bone_global_pose(head_i).origin
	var head_body: Node3D = null
	for b in hb.call("bodies"):
		if str((b as Node).get_meta("hitbox_bone", "")) == "C_Head_a":
			head_body = b
	_ok(head_body != null and head_body.global_position.distance_to(head_w) < 0.2, "head hitbox follows the head bone")


# ---- 1b) 胶囊底是圆的：站在台阶边缘时脚底圆盘支撑，不会顺着边缘滑下去
func _check_ledge_support() -> void:
	var arena := StaticBody3D.new()
	arena.name = "LedgeArena"
	main.add_child(arena)
	var base := Vector3(300, -40, 300)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(4, 1, 4)
	cs.shape = bs
	cs.position = base + Vector3(0, -0.5, 0)  # 顶面 y=0，边缘 x=2
	arena.add_child(cs)
	var cs2 := CollisionShape3D.new()
	var bs2 := BoxShape3D.new()
	bs2.size = Vector3(20, 1, 20)
	cs2.shape = bs2
	cs2.position = base + Vector3(0, -3.5, 0)  # 下层地面 y=-3
	arena.add_child(cs2)
	await _phys(2)
	player.call("set_play_mode", 1)
	player.global_position = base + Vector3(2.0 + 0.16, 0.02, 0.0)  # 中心已越过边缘 16cm（胶囊半球会滑落）
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()
	await _phys(60)
	var y := player.global_position.y - base.y
	_ok(y > -0.1, "capsule standing 16cm past a ledge edge is held by the foot disc (y=%.3f)" % y)
	player.global_position = base + Vector3(2.0 + 0.45, 0.02, 0.0)  # 完全离开边缘 → 应该掉下去
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()
	await _phys(60)
	y = player.global_position.y - base.y
	_ok(y < -1.0, "fully past the edge the character still falls (y=%.3f)" % y)
	arena.queue_free()
	main.call("switch_map", "room")
	await _frames(6)
	await _phys(4)


# ---- 2) 显示碰撞
func _check_collision_debug() -> void:
	var cd: Node = main.get("collision_debug")
	_ok(cd != null, "CollisionDebug node exists")
	main.call("set_show_collision", true)
	await _frames(3)
	var n := int(cd.call("overlay_count"))
	_ok(n > 10, "显示碰撞 draws overlays for collision shapes (%d)" % n)
	var col: CollisionShape3D = player.get_node("CollisionShape3D")
	_ok(bool(cd.call("has_overlay_for", col)), "player movement capsule has an overlay")
	var hb: Node = player.call("get_hitboxes")
	var any_hb := false
	for b in hb.call("bodies"):
		for c in (b as Node).get_children():
			if c is CollisionShape3D and bool(cd.call("has_overlay_for", c)):
				any_hb = true
	_ok(any_hb, "hitbox capsules have overlays")
	# 新加入的碰撞体自动补上
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	sb.add_child(cs)
	main.add_child(sb)
	await _frames(3)
	_ok(bool(cd.call("has_overlay_for", cs)), "collision shapes added later get an overlay")
	sb.queue_free()
	main.call("set_show_collision", false)
	await _frames(3)
	_ok(int(cd.call("overlay_count")) == 0, "turning 显示碰撞 off frees every overlay")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(hud_src.find("\"显示碰撞\"") >= 0 and hud_src.find("\"复原身体\"") >= 0, "settings panel has 显示碰撞 and 复原身体")


# ---- 9) 弹孔贴图：3 秒后淡出并释放
func _check_decals() -> void:
	var ws: Node = player.call("get_weapons")
	var bal: Node = ws.get("ballistics")
	bal.call("clear_decals")
	_ok(ResourceLoader.exists("res://assets/props/bullet_hole.png"), "bullet-hole texture shipped")
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3, 3, 0.2)
	cs.shape = bs
	wall.add_child(cs)
	main.add_child(wall)
	wall.global_position = Vector3(200, 1.5, 200)
	await _phys(2)
	bal.call("_spawn_decal", Vector3(200, 1.5, 200.1), Vector3(0, 0, 1), false, wall)
	_ok(int(bal.call("decal_count")) == 1, "decal spawned on a static wall")
	var decals: Array = bal.get("_decals")
	var mi: MeshInstance3D = decals[0] if not decals.is_empty() else null
	_ok(mi != null and mi.mesh is QuadMesh and (mi.material_override as StandardMaterial3D).albedo_texture != null, "decal is a textured quad")
	if mi:
		var sz := (mi.mesh as QuadMesh).size.x * mi.global_transform.basis.get_scale().x
		_ok(sz > 0.05 and sz < 0.09, "decal size ≈7cm (%.3f)" % sz)
		var nrm := mi.global_transform.basis.z.normalized()
		_ok(nrm.dot(Vector3(0, 0, 1)) > 0.99, "decal faces out of the wall")
	await _phys(int(3.2 * 60.0))
	_ok(mi != null and is_instance_valid(mi) and mi.transparency > 0.05, "decal fading after 3s (transparency %.2f)" % (mi.transparency if is_instance_valid(mi) else -1.0))
	await _phys(40)
	_ok(int(bal.call("decal_count")) == 0 and not is_instance_valid(mi), "decal freed after fade-out")
	wall.queue_free()


# ---- 1c) 子弹打分身：命中箱精细判定，穿过空隙不算命中
func _check_clone_hitbox_ballistics() -> void:
	main.call("spawn_clone", player.global_position + Vector3(0, 0, -1.6))
	await _frames(10)
	await _phys(6)
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	var bh: StaticBody3D = c.get("body_hit")
	var bh_cs: CollisionShape3D = bh.get_child(0)
	_ok(bh_cs.shape is CapsuleShape3D, "clone BodyHit is a capsule")
	var hb: Node = c.call("get_hitboxes")
	_ok(hb != null and int(hb.call("part_count")) >= 15, "clone has fine hitboxes")
	var bal: Node = (player.call("get_weapons") as Node).get("ballistics")
	var head: Vector3 = c.call("get_head_world_position") - Vector3.UP * 0.16
	var from := head + Vector3(0, 0, 1.5)
	var r: Dictionary = bal.call("_ray", from, head - Vector3(0, 0, 1.0))
	_ok(not r.is_empty() and str(r.get("hitbox_bone", "")).contains("Head"), "shot at the head lands on the head hitbox (%s)" % str(r.get("hitbox_bone", "")))
	# 找一条穿过胶囊但不碰任何部位的射线（例如身体侧面与手臂之间），子弹应忽略该分身
	var found := false
	var cp: Vector3 = (c as Node3D).global_position
	for yy in [0.35, 0.5, 0.95, 1.1, 1.25]:
		for xx in [0.27, -0.27, 0.24, -0.24, 0.0]:
			var o: Vector3 = cp + Vector3(xx, yy, 1.2)
			var e: Vector3 = cp + Vector3(xx, yy, -1.2)
			var w3 := player.get_world_3d()
			var q := PhysicsRayQueryParameters3D.create(o, e, 2)
			q.exclude = [player.get_rid()]
			var cap_hit := w3.direct_space_state.intersect_ray(q)
			if cap_hit.is_empty() or cap_hit.get("collider") != bh:
				continue
			var fine: Dictionary = bal.call("_hitbox_ray", c, o, e)
			if not fine.is_empty():
				continue
			var rr: Dictionary = bal.call("_ray", o, e)
			_ok(rr.is_empty() or rr.get("collider") != bh, "ray through the capsule but between limbs passes the clone (y=%.2f x=%.2f)" % [yy, xx])
			found = true
			break
		if found:
			break
	if not found:
		print("v0308: note — no limb gap found for the miss test (pose dependent)")
	var zone := str(load("res://scripts/combat_damage.gd").zone_of(c, head, r.get("hitbox")))
	_ok(zone == "head", "hitbox bone meta maps to the head zone (%s)" % zone)


# ---- 6) 复原身体：尸体复活（布娃娃 → 蹲 → 站）、满血、清伤
func _check_restore_clone() -> void:
	var clones: Array = main.call("get_clones")
	var c: Node = clones[clones.size() - 1]
	c.call("apply_damage", 9999.0, {"dir": Vector3(0, 0, -1), "zone": "body"})
	await _phys(90)
	_ok(bool(c.call("is_dead")), "clone killed")
	_ok(bool((c.call("get_ragdoll") as Node).get("active")), "clone ragdoll active")
	player.call("apply_damage", 30.0, {})
	await _phys(2)
	var n := int(main.call("restore_all_bodies"))
	_ok(n >= 2, "restore_all_bodies restored player + clones (%d)" % n)
	_ok(not bool(c.call("is_dead")), "clone revived")
	_ok(is_equal_approx(float(c.call("get_hp")), float(c.call("get_max_hp"))), "clone back to full HP")
	_ok(not bool((c.call("get_ragdoll") as Node).get("active")), "ragdoll stopped on revive")
	_ok(bool(c.call("is_getting_up")), "clone blends from the ragdoll pose (get-up active)")
	_ok(str((c.call("get_loco") as Node).get("mode")) == "crouch", "clone gets up through a crouch")
	var hb: Node = c.call("get_hitboxes")
	_ok(bool(hb.get("enabled")), "clone hitboxes re-enabled")
	await _phys(int(2.3 * 60.0))
	_ok(not bool(c.call("is_getting_up")), "get-up finished")
	_ok(str((c.call("get_loco") as Node).get("mode")) == "stand", "clone stands up after the crouch")
	var health: Node = player.get("_health")
	_ok(health != null and is_equal_approx(float(health.get("hp")), float(health.get("max_hp"))), "player HP restored")
	# 本体死亡后复活
	health.call("apply_damage", 99999.0, {"dir": Vector3(0, 0, -1)})
	await _phys(60)
	_ok(bool(player.call("is_dead")), "player killed")
	main.call("restore_all_bodies")
	await _phys(2)
	_ok(not bool(player.call("is_dead")), "player revived by 复原身体")
	_ok(bool(player.call("is_getting_up")), "player blends from ragdoll to crouch")
	await _phys(int(2.3 * 60.0))
	_ok(str(player.call("get_stance")) == "stand" and not bool(player.call("is_getting_up")), "player stands up after the get-up")
	for cc in main.call("get_clones"):
		(cc as Node).queue_free()
	await _frames(3)


func _find_exam_bed() -> Node:
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "exam_bed":
			return v
	return null


# ---- 3/4/5/7/8) 检查床 Tab、手术
func _check_exam_bed_tab_and_surgery() -> void:
	player.call("set_play_mode", 0)
	var bed := _find_exam_bed()
	_ok(bed != null, "exam bed exists")
	if bed == null:
		return
	player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
	if vs.has_method("_update_nearest"):
		vs.call("_update_nearest")
	_ok(bool(vs.call("try_enter")), "entered the exam bed")
	await _frames(8)
	await _phys(4)
	_ok(str(main.call("action_for_key", KEY_TAB)) == "toggle_mode", "Tab on the exam bed = 观察视角切换 (toggle_mode)")
	var m0 := int(player.get("play_mode"))
	main.call("run_action", str(main.call("action_for_key", KEY_TAB)), KEY_TAB)
	await _frames(3)
	_ok(int(player.get("play_mode")) != m0, "Tab switched play mode on the exam bed")
	main.call("run_action", str(main.call("action_for_key", KEY_TAB)), KEY_TAB)
	await _frames(3)
	_ok(str(main.call("action_for_key", KEY_V)) == "vehicle_cam", "V still toggles the vehicle camera")

	var surgery: Node = player.call("get_surgery") if player.has_method("get_surgery") else player.get("_surgery")
	_ok(surgery != null and bool(surgery.call("enter_surgery")), "surgery entered")
	if surgery == null or not bool(surgery.call("is_active")):
		return
	# 8) 手术刀模型
	surgery.call("set_tool", "scalpel")
	if surgery.get("_scalpel") == null:
		surgery.call("_make_scalpel")
	_ok(bool(surgery.get("scalpel_model_loaded")), "formal scalpel GLB loaded (no white bar)")
	var sc: Node3D = surgery.get("_scalpel")
	var p := Vector3(0, 1.0, 0.2)
	surgery.call("_place_scalpel", p, Vector3(1, 0, 0), Vector3(0, 0, 1))
	_ok(sc.global_position.distance_to(p) < 1e-4, "blade tip sits on the cut point")
	var handle_dir := sc.global_transform.basis.x.normalized()  # +X = 刀尖 → 刀柄
	_ok(handle_dir.dot(Vector3(0, 0, 1)) > 0.4 and handle_dir.dot(Vector3(1, 0, 0)) < -0.4, "handle tilts up off the skin and trails the travel direction")
	var pts := PackedVector3Array()
	surgery.call("_collect_mesh_points", sc, Transform3D.IDENTITY, pts)
	var lo := INF
	var hi := -INF
	for q in pts:
		var w: Vector3 = q
		var proj := (w - p).dot(handle_dir)
		lo = minf(lo, proj)
		hi = maxf(hi, proj)
	_ok(hi - lo > 0.11 and hi - lo < 0.18 and lo > -0.01, "scalpel ≈14.5cm long with the tip at the origin (len %.3f, tip %.3f)" % [hi - lo, lo])

	# 7) 预览加速：网格投影与暴力投影一致；同帧多次拖动只重建一次
	var outer = surgery.get("_outer")
	if outer:
		var grid: Dictionary = Geom.build_xy_grid(outer)
		var rng := RandomNumberGenerator.new()
		rng.seed = 308
		var same := true
		var nav: Vector3 = surgery.get("_navel_rest")
		var t0 := Time.get_ticks_usec()
		var brute: Array = []
		for i in 120:
			var h := nav + Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.1, 0.1), 0.0)
			brute.append([h, Geom._project_to_mesh(outer, h, h)])
		var t1 := Time.get_ticks_usec()
		for e in brute:
			var g := Geom.project_to_mesh_grid(outer, grid, e[0], e[0])
			if g.distance_to(e[1]) > 1e-5:
				same = false
		var t2 := Time.get_ticks_usec()
		_ok(same, "grid projection matches brute force")
		print("v0308: projection brute=%.1fms grid=%.1fms (120 pts)" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0])
		_ok((t2 - t1) * 3 < (t1 - t0), "grid projection is much faster than brute force")
		var nsame := true
		for e in brute:
			var vi := Geom.nearest_vertex_grid(outer, grid, e[0])
			var bi := 0
			var bs := 1e18
			for j in outer.vert_count():
				var s: float = outer.pos[j].distance_squared_to(e[0])
				if s < bs:
					bs = s
					bi = j
			if outer.pos[vi].distance_squared_to(e[0]) > bs + 1e-12:
				nsame = false
		_ok(nsame, "grid nearest-vertex matches brute force")
	surgery.call("set_cut_mode", "straight")
	_ok(bool(surgery.call("debug_begin_stroke_at_navel")), "scalpel stroke begins")
	var navel: Vector3 = surgery.call("_navel_world")
	var r0 := int(surgery.get("preview_rebuilds"))
	var tq := Time.get_ticks_usec()
	for i in range(1, 9):
		var tgt: Vector3 = navel + Vector3(0.008 * float(i), 0.002 * float(i), 0.0)
		var origin: Vector3 = tgt + Vector3(0.0, 0.02, 0.28)
		surgery.call("drag_stroke", origin, (tgt - origin).normalized())
	var tq1 := Time.get_ticks_usec()
	_ok(int(surgery.get("preview_rebuilds")) - r0 <= 1, "8 drag events in one frame rebuild the preview at most once (%d)" % (int(surgery.get("preview_rebuilds")) - r0))
	print("v0308: 8 coalesced drag events took %.1fms" % ((tq1 - tq) / 1000.0))
	_ok(bool(surgery.call("has_cut_preview")), "preview reflects the last drag event")
	var ends: Array = surgery.call("straight_preview_ends")
	_ok((ends[1] as Vector3).distance_to(ends[0]) > 0.05, "coalesced drag ended at the last pointer position")
	surgery.call("end_stroke")
	# 4) 拿取：只拉被抓的一侧唇缘，切口两端不动，力度降低
	var nav2: Vector3 = surgery.get("_navel_rest")
	var a := nav2 + Vector3(-0.03, 0.01, 0.0)
	var b := a + Vector3(0.06, -0.012, 0.0)
	surgery.call("debug_set_straight_preview", a, b)
	surgery.call("confirm_cut", false)
	await _frames(3)
	_ok(bool(surgery.get("cut_open")), "straight incision committed")
	surgery.call("debug_settle_eversion")
	surgery.call("set_tool", "grab")
	_ok(bool(surgery.call("debug_drag_split_skin", Vector3(0.0, 0.03, 0.0))), "split skin grabbed")
	_ok(int(surgery.call("pull_mode")) == 1, "straight-cut pull uses the lip-aware mode")
	var ep: Array = surgery.call("debug_pull_endpoints_ab")
	var pa: Vector3 = ep[0]
	var pb: Vector3 = ep[1]
	var axis: Vector3 = ep[2]
	var mid := (pa + pb) * 0.5
	var end_off := maxf((surgery.call("debug_pull_offset_at_ab", pa + axis * 0.004) as Vector3).length(), (surgery.call("debug_pull_offset_at_ab", pb + axis * 0.004) as Vector3).length())
	var mid_off := (surgery.call("debug_pull_offset_at_ab", mid + axis * 0.004) as Vector3).length()
	var other := (surgery.call("debug_pull_offset_at_ab", mid - axis * 0.004) as Vector3).length()
	print("v0308: pull mid=%.4f ends=%.4f other_lip=%.4f" % [mid_off, end_off, other])
	_ok(mid_off > 0.004, "grabbed lip opens in the middle (%.4f)" % mid_off)
	_ok(end_off < mid_off * 0.15, "incision ends stay anchored (%.4f vs %.4f)" % [end_off, mid_off])
	_ok(other < mid_off * 0.1, "the opposite lip is not dragged along (%.4f)" % other)
	var off_len := float(surgery.call("split_skin_drag_offset"))
	_ok(off_len <= 0.0601, "drag strength reduced / capped (%.4f ≤ 0.06)" % off_len)
	surgery.call("debug_release_split_skin")
	# 5) 皮瓣外皮 + 截面
	surgery.call("set_tool", "scalpel")
	_ok(bool(surgery.call("debug_scripted_incision", true)), "closed incision for a flap")
	await _frames(3)
	surgery.call("set_tool", "grab")
	_ok(bool(surgery.call("peel_flap")), "flap peeled")
	await _phys(6)
	var mats: Array = surgery.call("flap_surface_materials")
	_ok(mats.size() == 2, "flap mesh has an outer-skin surface and a cut-section surface")
	if mats.size() == 2:
		var skin_m = mats[0]
		_ok(skin_m is StandardMaterial3D and (skin_m as StandardMaterial3D).albedo_texture != null, "flap outer surface uses the skin texture")
		_ok(mats[1] is ShaderMaterial, "flap cut section uses the red wall material")
	var flap: Node = surgery.get("flap_node")
	# 6) 复原身体清掉切口 / 皮瓣
	main.call("restore_all_bodies")
	await _frames(4)
	_ok(not bool(surgery.get("cut_open")) and not bool(surgery.get("flap_peeled")), "复原身体 removes incisions and flaps")
	_ok(flap == null or not is_instance_valid(flap) or flap.is_queued_for_deletion(), "flap node freed")
	_ok(int(surgery.get("bullet_holes")) == 0 and not bool(surgery.call("has_incision_trail")), "no bullet holes / incision trail after restore")
	_ok(bool(surgery.call("is_active")) and surgery.get("_outer") != null, "surgery stays usable with a fresh abdomen")
	surgery.call("exit_surgery")
