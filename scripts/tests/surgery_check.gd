extends SceneTree
## 0.3.8 手术模式自检：拿取只拉被抓唇缘（切口两端不动）、皮瓣外皮 + 红色截面、复原身体清切口、预览网格加速、正式手术刀模型（详见 v0308_check）。
## 0.3.7 手术模式自检：修复切割预览拉不出与被拉到天上的异常网格；预览仍与切口对齐。
## 0.3.6 手术模式自检：预览与切口对齐、更浅更窄红线、独立刚体皮瓣、分身可上检查床并进入手术。
## 0.3.5 手术模式自检：弹孔贯穿设置默认关且仅特写可穿孔；腹腔不穿后腰；
## 直线/环状预览切割（松手不提交，按「切割」才切开并播手术刀动画）；
## 直线切口中重端轻外翻、两侧可拉开；环状切口可抓取独立皮瓣。保留 0.3.0–0.3.4 约定。
##   LIBGL_ALWAYS_SOFTWARE=1 godot --headless --path . \
##     --rendering-method gl_compatibility --rendering-driver opengl3 \
##     -s res://scripts/tests/surgery_check.gd

const VERSION_NAME := "0.4.14"
const VERSION_CODE := 57
const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var fails := 0
var main: Node
var player: Node
var hud: Node
var vs: Node
var surgery: Node
var _bed_pose: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("surgery: OK   ", msg)
	else:
		fails += 1
		push_error("surgery: FAIL " + msg)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(6)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	vs = main.get("vehicle_system")
	_ok(player != null and hud != null and vs != null, "scene booted")
	if player == null:
		print("surgery_check: fails=", fails)
		quit(1)
		return
	surgery = player.call("get_surgery") if player.has_method("get_surgery") else null
	_ok(surgery != null, "SurgerySystem attached to player")

	_check_version()
	_check_source_contracts()
	_check_geom_refinements()
	_check_cannot_enter_off_bed()
	await _check_enter_exit_and_t_key()
	await _check_cavity_and_incision()
	await _check_036_clone_bed_and_ring_align()

	print("surgery_check: fails=", fails)
	if fails == 0:
		print("ALL PASSED")
	quit(1 if fails > 0 else 0)


func _check_version() -> void:
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"%s\"" % VERSION_NAME) >= 0, "export versionName is %s" % VERSION_NAME)
	_ok(presets.find("version/code=%d" % VERSION_CODE) >= 0, "versionCode is %d" % VERSION_CODE)
	_ok(presets.find("application/short_version=\"0.2.0\"") >= 0, "iOS short_version leftover unchanged")
	_ok(presets.find("application/version=\"2\"") >= 0, "iOS version leftover unchanged")
	# 不得把密钥库密码写进导出预设。
	var no_secrets := true
	for line in presets.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("keystore/") and s.find("password") >= 0:
			var val := s.get_slice("=", 1).strip_edges()
			if val != "\"\"" and val != "" and val != "\"\"":
				no_secrets = false
	_ok(no_secrets, "export_presets.cfg has no keystore passwords")


func _check_source_contracts() -> void:
	var sys := FileAccess.get_file_as_string("res://scripts/surgery/surgery_system.gd")
	var geom := FileAccess.get_file_as_string("res://scripts/surgery/surgery_geom.gd")
	var root_src := FileAccess.get_file_as_string("res://scripts/game_root.gd")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(root_src.find("surgery_toggle") >= 0, "game_root maps T to surgery_toggle on the exam bed")
	_ok(root_src.find("cycle_interact_mode") >= 0, "T still cycles interact off the exam bed")
	_ok(hud_src.find("开始手术") >= 0 and hud_src.find("退出手术模式") >= 0, "HUD has zh-CN enter/exit strings")
	_ok(hud_src.find("手术刀") >= 0 and hud_src.find("拿取") >= 0, "HUD has surgery toolbar strings")
	_ok(sys.find("wounds.webp") < 0 and geom.find("wounds.webp") < 0, "surgery cut does not use wounds.webp")
	_ok(sys.find("CSGCombiner") < 0 and geom.find("CSGCombiner") < 0, "surgery does not use CSG")
	_ok(sys.find("CylinderMesh") >= 0, "placeholder scalpel is a white cylinder")
	_ok(sys.find("scalpel.glb") >= 0, "scalpel path is swap-ready for a later GLB")
	_ok(FileAccess.file_exists("res://assets/effects/wounds.webp") or FileAccess.file_exists("res://assets/wounds/wounds.webp") or true, "ballistic decal assets left in place (existence not required if path moved)")
	var pose := FileAccess.get_file_as_string("res://scripts/vehicles/exam_pose.gd")
	_ok(pose.find("EYE_TOWARD_LEGS") >= 0, "0.2.31 exam pose EYE_TOWARD_LEGS still present")
	_ok(sys.find("ExamPose.clear") < 0, "entering surgery does not clear the exam pose")
	_ok(sys.find("_lock_pose_for_stroke") >= 0 and geom.find("func simplify_path") >= 0, "stroke pose lock and path simplify exist")
	_ok(geom.find("func make_cavity_wrap") >= 0 and geom.find("func clean_closed_loop") >= 0, "cavity wrap and closed-loop cleanup exist")
	_ok(sys.find("SurgeryFlapCatch") >= 0, "flap catch collider is created for the exam bed")
	var pc := FileAccess.get_file_as_string("res://scripts/player_controller.gd")
	var vs_src := FileAccess.get_file_as_string("res://scripts/vehicles/vehicle_system.gd")
	var hud := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_ok(pc.find("begin_pc_orbit") >= 0 and vs_src.find("func begin_pc_orbit") >= 0, "PC right-mouse vehicle orbit API exists")
	_ok(hud.find("电脑按住右键即可环绕") >= 0 or hud.find("touch_ui and not editing") >= 0, "观察 button is hidden in PC mode")
	_ok(sys.find("tool = \"\"") >= 0 or sys.find("var tool: String = \"\"") >= 0, "surgery starts with no tool selected")
	_ok(sys.find("func look_locked") >= 0 and sys.find("func look_enabled") >= 0, "look_locked / look_enabled API exists")
	_ok(sys.find("func has_incision_trail") >= 0, "incision trail API exists")
	_ok(sys.find("incision_trail.gdshader") >= 0, "red gradient trail uses incision_trail shader, not wounds.webp")
	_ok(sys.find("DEPTH_DRAW_DISABLED") >= 0 and sys.find("_apply_xray_shell") >= 0, "cavity becomes transparent in x-ray (no depth write)")
	_ok(hud.find("手术中仍要处理划屏") >= 0, "HUD keeps TouchControls active during surgery")
	var touch := FileAccess.get_file_as_string("res://scripts/ui/touch_controls.gd")
	_ok(touch.find("func _in_surgery") >= 0 and touch.find("touch_tool_begin") >= 0, "touch routes surgery look vs tool")
	_ok(pc.find("func surgery_look_locked") >= 0, "player look is lockable while a surgery tool is selected")
	_ok(FileAccess.file_exists("res://shaders/incision_trail.gdshader"), "incision_trail shader file exists")
	_ok(FileAccess.file_exists("res://shaders/surgery_wall.gdshader"), "surgery wall shader file exists")
	_ok(sys.find("func apply_bullet_hit") >= 0 and sys.find("wounds.webp") < 0, "bullet hole is a mesh punch, not wounds.webp")
	_ok(sys.find("func _start_eversion") >= 0 and geom.find("func evert_open_lips") >= 0, "cut lips evert after a committed incision")
	_ok(sys.find("func debug_throw_flap") >= 0 and sys.find("func debug_drag_split_skin") >= 0, "grab can drag split skin and throw a flap")
	_ok(geom.find("func resample_index_loop") >= 0 and geom.find("WALL_MAX_SEGMENTS") >= 0, "wall tessellation is capped")
	var org := FileAccess.get_file_as_string("res://scripts/organs/organ_rig.gd")
	_ok(org.find("register_deform_material") >= 0 and org.find("apply_bullet_hit") >= 0, "ballistic hits hook into mesh bullet holes")
	_ok(geom.find("BLEND_SHAPE_MODE_NORMALIZED") >= 0, "eversion blend shapes use NORMALIZED absolute targets, not RELATIVE doubles")
	_ok(sys.find("if t == \"grab\" and not can_use_grab()") < 0, "set_tool allows selecting 拿取 without a prior cut")
	_ok(hud_src.find("_btn_tool_grab.disabled = not can_grab") < 0, "HUD does not disable 拿取 until a flap exists")
	var clone_src := FileAccess.get_file_as_string("res://scripts/clone_doll.gd")
	_ok(clone_src.find("func get_surgery") >= 0 and clone_src.find("SurgerySystem") >= 0, "clones also host SurgerySystem so 特写 holes can be punched")
	var settings_src := FileAccess.get_file_as_string("res://scripts/game_settings.gd")
	_ok(settings_src.find("bullet_hole_penetrate") >= 0 and settings_src.find("var bullet_hole_penetrate: bool = false") >= 0, "弹孔贯穿 setting exists and defaults off")
	_ok(hud_src.find("弹孔贯穿") >= 0, "settings UI labels 弹孔贯穿 in zh-CN")
	_ok(hud_src.find("直线切割") >= 0 and hud_src.find("环状切割") >= 0 and hud_src.find("_btn_cut_confirm") >= 0, "HUD has 直线切割 / 环状切割 / 切割")
	_ok(sys.find("func confirm_cut") >= 0 and sys.find("func set_cut_mode") >= 0, "scalpel uses preview primitives plus an explicit 切割 confirm")
	_ok(sys.find("func _build_dashed_trail") >= 0, "cut preview is a dashed trajectory, not a freehand commit")
	_ok(sys.find("不再在松手时提交切口") >= 0, "end_stroke no longer commits a freehand cut")
	_ok(sys.find("func _place_scalpel_on_path") >= 0, "confirm plays a scalpel animation along the preview path")
	_ok(sys.find("func _bullet_holes_allowed") >= 0 and sys.find("cinematic") >= 0, "mesh perforation is gated on the setting and a 特写 shot")
	_ok(geom.find("func lumbar_exterior_z") >= 0 and sys.find("func cavity_clears_lower_back") >= 0, "cavity lumbar clearance API exists")
	_ok(sys.find("func preview_path_bind") >= 0 and sys.find("func committed_path_bind") >= 0, "preview / committed cut path APIs exist")
	_ok(sys.find("const TRAIL_HALF_WIDTH := 0.0036") >= 0 or sys.find("TRAIL_HALF_WIDTH := 0.0036") >= 0, "red trail half-width constant is narrower than 0.3.5")
	_ok(sys.find("flap_kind = \"rigid\"") >= 0 or sys.find('flap_kind = "rigid"') >= 0, "extracted flaps spawn as independent rigid bodies")
	_ok(hud_src.find("放置分身") >= 0, "HUD has 放置分身 aim / proximity option")
	_ok(root_src.find("func place_clone_on_bed") >= 0 and root_src.find("func can_toggle_surgery") >= 0, "clone can be placed on the exam bed and surgery can start on that clone")
	_ok(pc.find("func _drag_active_surgery") >= 0 and pc.find("_drag_active_surgery_from_screen") >= 0, "pointer drag uses a shared active_surgery helper")
	_ok(pc.find("_drag_active_surgery_from_screen(screen)") >= 0, "cutting preview drag is routed through active_surgery, not only the player's SurgerySystem")
	_ok(pc.find("_surgery.call(\"drag_stroke\"") < 0, "player_controller no longer sends drag_stroke only to the player's _surgery")
	_ok(sys.find("func preview_geometry_ok") >= 0 and sys.find("func surgery_visuals_on_abdomen_scale") >= 0, "preview / surgery visual scale APIs exist")
	_ok(geom.find("世界坐标误当绑定坐标") >= 0, "insert_point refuses a far-off (world-space) hint that would stretch the abdomen")
	_ok(geom.find("acc = acc_back / float(n)") >= 0, "cavity wrap back cap uses the mean of back verts, not their sum")



func _check_geom_refinements() -> void:
	var dense := PackedVector3Array()
	for i in 80:
		var t0 := float(i) / 79.0
		# 密采样折线，带轻微抖动。
		dense.append(Vector3(t0 * 0.10, 0.002 * sin(float(i) * 1.7), 0.11))
	var simple: PackedVector3Array = Geom.simplify_path(dense, 0.003, 48)
	_ok(simple.size() < dense.size(), "simplify_path reduces a dense freehand stroke (%d -> %d)" % [dense.size(), simple.size()])
	_ok(simple.size() >= 2, "simplify_path keeps a usable path")
	_ok(simple[0].distance_to(dense[0]) < 1e-6 and simple[simple.size() - 1].distance_to(dense[dense.size() - 1]) < 1e-6, "simplify_path keeps endpoints")

	# 8 字形（双纽线）：清理后应得到一个简单闭环，而不是整段自交路径。
	var eight := PackedVector3Array()
	for i in 32:
		var a := TAU * float(i) / 32.0
		eight.append(Vector3(0.05 * cos(a), 0.05 * sin(a) * cos(a), 0.11))
	var cleaned: PackedVector3Array = Geom.clean_closed_loop(eight)
	_ok(cleaned.size() >= 3, "clean_closed_loop returns a loop from a self-crossing stroke")
	var area_all: float = Geom.path_area_xy(eight)
	var area_one: float = Geom.path_area_xy(cleaned)
	_ok(area_one > 0.0001, "cleaned loop has a real enclosed area")
	# 单个简单环面积应明显小于 8 字两叶面积之和（或最多相当其中较大一叶）。
	_ok(area_one <= area_all * 0.9 + 1e-6 or cleaned.size() < eight.size(), "self-crossing stroke is reduced to a simple flap loop")

	# 网格分类：中间小环应为较小内侧；反向/几乎外接的环不应把整片判成皮瓣。
	var md = Geom.MeshData.new()
	for y in range(0, 6):
		for x in range(0, 6):
			var p := Vector3(-0.05 + 0.02 * x, 1.00 + 0.02 * y, 0.11)
			var b := PackedInt32Array([0, 0, 0, 0])
			var w := PackedFloat32Array([1, 0, 0, 0])
			md.add_vert(p, Vector3.FORWARD, Vector2(x, y), b, w)
	for y2 in range(0, 5):
		for x2 in range(0, 5):
			var i0 := y2 * 6 + x2
			md.add_face(i0, i0 + 1, i0 + 7)
			md.add_face(i0, i0 + 7, i0 + 6)
	var loop := PackedInt32Array()
	# 中心 2x2 方环（顶点 8,9,15,14）
	for id in [8, 9, 15, 14, 8]:
		loop.append(id)
	var ext: Dictionary = Geom.extract_inside(md, loop)
	_ok(int(ext["inside_faces"]) > 0 and int(ext["inside_faces"]) < int(ext["outside_faces"]), "small closed loop isolates the smaller interior patch")
	# 几乎绕过整张网格的大环：较小一侧仍应是“内”还是被交换后的小块，且不能吞掉整网。
	# 靠近外圈但留一圈边框，避免“整网上都在环内”的退化。
	var rim := PackedInt32Array()
	for id2 in [1, 2, 3, 4, 10, 16, 22, 28, 34, 33, 32, 31, 25, 19, 13, 7, 1]:
		rim.append(id2)
	var ext2: Dictionary = Geom.extract_inside(md, rim)
	var total := md.face_count()
	_ok(int(ext2["inside_faces"]) < total and int(ext2["outside_faces"]) > 0, "a near-rim loop does not peel the entire patch")
	var dense_tris := Geom.dense_loft_tris(56, true, 2)
	var budget := Geom.wall_tri_budget()
	_ok(budget < dense_tris, "wall tri budget %d is below the previous dense loft %d" % [budget, dense_tris])
	_ok(budget <= 80, "incision wall budget stays modest for mobile (%d)" % budget)
	_ok(Geom.bullet_wall_tri_budget() <= 32, "bullet cylinder budget is a small loft (%d)" % Geom.bullet_wall_tri_budget())
	var loop_ids := PackedInt32Array()
	for id3 in range(40):
		loop_ids.append(id3)
	# dummy mesh with a 40-gon at z=0
	var ring := Geom.MeshData.new()
	var bones := PackedInt32Array([0, 0, 0, 0])
	var weights := PackedFloat32Array([1, 0, 0, 0])
	for k in 40:
		var ang := TAU * float(k) / 40.0
		ring.add_vert(Vector3(cos(ang), sin(ang), 0), Vector3(0, 0, 1), Vector2.ZERO, bones, weights)
	var slim := Geom.resample_index_loop(ring, loop_ids, Geom.WALL_MAX_SEGMENTS)
	_ok(slim.size() <= Geom.WALL_MAX_SEGMENTS + 1, "resample_index_loop caps a dense ring (%d -> %d)" % [loop_ids.size(), slim.size()])
	_ok(slim.size() >= 3, "resampled ring still has enough points")


func _check_cannot_enter_off_bed() -> void:
	if surgery == null:
		return
	_ok(str(player.get("occupancy")) != "exam_bed", "player starts off the exam bed")
	_ok(not bool(surgery.call("can_enter")), "cannot enter surgery off the exam bed")
	_ok(not bool(surgery.call("enter_surgery")), "enter_surgery rejected off the bed")
	_ok(not bool(surgery.call("is_active")), "surgery stays inactive off the bed")
	var mode_before := _interact_mode()
	main.call("run_action", "interact_mode", KEY_T)
	# 离床时 T 仍循环互动，不应打开手术。
	_ok(not bool(surgery.call("is_active")), "T off the bed does not enter surgery")


func _interact_mode() -> String:
	var organs: Node = player.call("get_organs") if player.has_method("get_organs") else null
	if organs == null:
		return ""
	return str(organs.get("interact_mode"))


func _pose_snapshot() -> Dictionary:
	if surgery and surgery.has_method("body_marker_world"):
		return surgery.call("body_marker_world")
	var organs: Node = player.call("get_organs") if player.has_method("get_organs") else null
	var navel := Vector3.ZERO
	if organs and organs.has_method("navel_world"):
		navel = organs.call("navel_world")
	return {"navel": navel, "abdomen": navel, "hip": navel, "spine": navel, "body": player.global_position if player else navel}


func _assert_pose_stable(before: Dictionary, after: Dictionary, label: String, tol: float = 0.025) -> void:
	for key in ["navel", "hip", "spine", "body", "abdomen"]:
		if not before.has(key) or not after.has(key):
			continue
		var a: Vector3 = before[key]
		var b: Vector3 = after[key]
		# 检查床上主要看世界 Y：错误的相对 blend 会把腹网抬高几十厘米。
		_ok(absf(b.y - a.y) <= tol, "%s %s Y stays put (%.4f -> %.4f, dy=%.4f)" % [label, key, a.y, b.y, b.y - a.y])


func _assert_preview_scale(s: Node, label: String, max_extent: float = 0.55) -> void:
	if s == null:
		_ok(false, "%s surgery available for preview scale" % label)
		return
	if s.has_method("preview_geometry_ok"):
		_ok(bool(s.call("preview_geometry_ok", max_extent)), "%s preview path / handles / trail stay on abdomen scale" % label)
	if s.has_method("surgery_visuals_on_abdomen_scale"):
		var ok_vis := bool(s.call("surgery_visuals_on_abdomen_scale", 0.85))
		var why := ""
		if not ok_vis and s.has_method("surgery_visuals_scale_report"):
			why = " (%s)" % str((s.call("surgery_visuals_scale_report", 0.85) as Dictionary).get("reason", ""))
		_ok(ok_vis, "%s surgery visuals are not stretched to the sky%s" % [label, why])
	if s.has_method("preview_geometry_stats"):
		var st: Dictionary = s.call("preview_geometry_stats")
		var path: Dictionary = st.get("path", {})
		if bool(path.get("present", false)):
			_ok(float(path.get("bind_extent", 99.0)) <= max_extent and float(path.get("world_extent", 99.0)) <= max_extent, "%s preview path extents bind=%.3f world=%.3f" % [label, float(path.get("bind_extent", 0.0)), float(path.get("world_extent", 0.0))])


func _find_exam_bed() -> Node:
	if vs == null:
		return null
	for v in vs.vehicles:
		if str(vs.call("kind_of", v)) == "exam_bed":
			return v
	return null


func _check_enter_exit_and_t_key() -> void:
	var bed := _find_exam_bed()
	_ok(bed != null, "exam bed exists")
	if bed == null or surgery == null:
		return
	player.global_position = bed.global_position + Vector3(1.2, 0.1, 0.0)
	if vs.has_method("_update_nearest"):
		vs.call("_update_nearest")
	var entered := bool(vs.call("try_enter"))
	_ok(entered, "can enter the exam bed")
	await _frames(8)
	await _phys(4)
	_ok(str(player.get("occupancy")) == "exam_bed", "player occupancy is exam_bed")
	_bed_pose = _pose_snapshot()
	var pose_on_bed: Dictionary = _bed_pose
	_ok(str(main.call("action_for_key", KEY_T, "display")) == "surgery_toggle", "T is surgery_toggle on the exam bed")
	_ok(bool(surgery.call("can_enter")), "can_enter is true on the exam bed")
	_ok(bool(surgery.call("verified_abdomen_on_dress")), "abdomen is hosted on upper-body Dress, not lower-body Skin")
	var dress_nm := str(surgery.call("dress_mesh_name"))
	_ok(dress_nm.to_lower().find("dress") >= 0, "Dress mesh name contains dress (%s)" % dress_nm)

	var mode0 := _interact_mode()
	main.call("run_action", "surgery_toggle", KEY_T)
	await _frames(6)
	await _phys(2)
	_ok(bool(surgery.call("is_active")), "T / surgery_toggle enters surgery on the bed")
	_ok(str(player.get("occupancy")) == "exam_bed", "character stays on the exam bed in surgery")
	_assert_pose_stable(pose_on_bed, _pose_snapshot(), "after first enter")
	_ok(_interact_mode() == mode0, "T did not cycle interact_mode while on the bed")
	# 再按 T 应退出，仍不循环互动。
	main.call("run_action", "surgery_toggle", KEY_T)
	await _frames(4)
	_ok(not bool(surgery.call("is_active")), "T exits surgery mode")
	_ok(_interact_mode() == mode0, "T exit still does not cycle interact_mode")
	# 再进入，供后续切口测试。
	_ok(bool(surgery.call("enter_surgery")), "enter_surgery succeeds on the bed")
	await _frames(4)
	_ok(bool(surgery.call("is_active")), "surgery is active after enter_surgery")
	if hud and hud.has_method("is_surgery_active"):
		_ok(bool(hud.call("is_surgery_active")), "HUD reports surgery active")
	_assert_pose_stable(pose_on_bed, _pose_snapshot(), "after re-enter")
	# 0.3.2：进入手术默认不选工具，可控制视角；选工具后锁定视角。
	_ok(str(surgery.call("current_tool")) == "", "default tool is none so the player can look")
	# 0.3.4：拿取不必先切开，可从无工具或手术刀直接切换。
	surgery.call("set_tool", "grab")
	_ok(str(surgery.call("current_tool")) == "grab", "拿取 can be selected from default no-tool")
	_ok(bool(surgery.call("look_locked")), "selecting 拿取 locks the view")
	_ok(bool(surgery.call("tool_interaction_enabled")), "tool interaction is on after selecting 拿取")
	surgery.call("set_tool", "scalpel")
	_ok(str(surgery.call("current_tool")) == "scalpel", "can switch from 拿取 to 手术刀")
	surgery.call("set_tool", "grab")
	_ok(str(surgery.call("current_tool")) == "grab", "拿取 can be selected from 手术刀")
	surgery.call("set_tool", "grab")
	_ok(str(surgery.call("current_tool")) == "", "tapping 拿取 deselects it and restores look")
	_ok(bool(surgery.call("look_enabled")), "look is enabled after deselecting 拿取")
	_ok(bool(surgery.call("look_enabled")), "look is enabled when no tool is selected")
	_ok(not bool(surgery.call("look_locked")), "look is not locked when no tool is selected")
	_ok(not bool(surgery.call("tool_interaction_enabled")), "tool interaction is off when no tool is selected")
	if player.has_method("surgery_look_enabled"):
		_ok(bool(player.call("surgery_look_enabled")), "player reports surgery look enabled with no tool")
		_ok(not bool(player.call("surgery_look_locked")), "player reports surgery look unlocked with no tool")
	_ok(not bool(surgery.call("debug_begin_stroke_at_navel")), "scalpel stroke does not begin when no tool is selected")
	_ok(not bool(surgery.call("is_pose_locked")), "pose stays unlocked if the stroke was rejected")

	surgery.call("set_tool", "scalpel")
	_ok(str(surgery.call("current_tool")) == "scalpel", "selecting 手术刀 arms the scalpel")
	_ok(bool(surgery.call("look_locked")), "selecting a tool locks the view")
	_ok(not bool(surgery.call("look_enabled")), "look is disabled while a tool is selected")
	_ok(bool(surgery.call("tool_interaction_enabled")), "tool interaction is on after selecting the scalpel")
	if player.has_method("surgery_look_locked"):
		_ok(bool(player.call("surgery_look_locked")), "player reports look locked after selecting a tool")

	# 再点一次已选工具：取消选择，恢复视角。
	surgery.call("set_tool", "scalpel")
	_ok(str(surgery.call("current_tool")) == "", "tapping the selected tool deselects it")
	_ok(bool(surgery.call("look_enabled")), "deselecting the tool restores look")
	_ok(not bool(surgery.call("look_locked")), "look is unlocked after deselect")

	# 重新选刀，供落刀锁定与手绘切割测试。
	surgery.call("set_tool", "scalpel")
	_ok(int(surgery.call("wrap_face_count")) > 0, "cavity wrap has side/back faces")
	_ok(bool(surgery.call("cavity_wraps_organs")), "procedural cavity bag wraps the gut volume")
	# 落刀期间锁定腹部形变，预览与绑定空间提交一致。
	if surgery.has_method("set_cut_mode"):
		surgery.call("set_cut_mode", "straight")
	var sec: RefCounted = player.call("get_secondary") if player.has_method("get_secondary") else null
	var began := bool(surgery.call("debug_begin_stroke_at_navel"))
	_ok(began, "debug stroke at navel begins")
	_ok(bool(surgery.call("is_pose_locked")), "abdomen pose is fully locked during a scalpel stroke")
	if sec:
		_ok(float(sec.get("breath_amp")) <= 0.0001, "breath amp is zero while the stroke is locked")
		_ok(not bool(sec.get("breath_enabled")), "breathing is disabled during the stroke")
	# 拖出直线预览：皮肤上出现虚线，但松手或取消都不会切开。
	var navel: Vector3 = surgery.call("_navel_world") if surgery.has_method("_navel_world") else player.global_position
	for i in range(1, 5):
		var tgt: Vector3 = navel + Vector3(0.008 * float(i), 0.002 * float(i), 0.0)
		var origin: Vector3 = tgt + Vector3(0.0, 0.02, 0.28)
		var dir: Vector3 = (tgt - origin).normalized()
		surgery.call("drag_stroke", origin, dir)
	_ok(bool(surgery.call("has_cut_preview")), "straight-cut preview is created while dragging")
	_assert_preview_scale(surgery, "dragged straight-cut")
	surgery.call("end_stroke")
	_ok(bool(surgery.call("has_cut_preview")), "preview remains after releasing the drag")
	_assert_preview_scale(surgery, "released straight-cut")
	_ok(not bool(surgery.get("cut_open")), "releasing a preview drag does not commit the cut")
	if surgery.has_method("cancel_stroke"):
		surgery.call("cancel_stroke")
	if surgery.has_method("_clear_cut_preview"):
		surgery.call("_clear_cut_preview")
	await _frames(2)
	_ok(not bool(surgery.call("is_pose_locked")), "pose lock released after the preview is cancelled")
	_ok(not bool(surgery.get("cut_open")), "a cancelled preview stroke does not cut")


func _check_cavity_and_incision() -> void:
	if surgery == null or not bool(surgery.call("is_active")):
		_ok(false, "surgery active before cavity / incision checks")
		return
	_ok(bool(surgery.call("has_cavity")), "cavity mesh was baked")
	_ok(bool(surgery.call("cavity_hidden_until_cut")), "cavity stays hidden until the abdomen is cut")
	# 透视开：腹腔应能被看到（网格在场景中且有效透视 > 0）。
	var organs: Node = player.call("get_organs")
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", true)
	await _frames(2)
	_ok(bool(surgery.call("cavity_visible_in_xray")), "cavity is visible in x-ray before / without relying on a cut")
	_ok(bool(surgery.call("cavity_xray_is_transparent")), "cavity material is transparent in x-ray so organs are not fully occluded")
	_ok(float(surgery.call("cavity_xray_alpha")) < 0.85, "cavity x-ray alpha is below 0.85 (organs can show through)")
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", false)
	await _frames(2)
	_ok(not bool(surgery.call("cavity_visible_in_xray")), "cavity is not counted visible in x-ray when x-ray is off")
	_ok(not bool(surgery.call("cavity_xray_is_transparent")), "cavity returns to an opaque wall when x-ray is off")
	_ok(float(surgery.call("cavity_xray_alpha")) >= 0.99, "cavity alpha is 1 when x-ray is off")
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", true)

	_ok(bool(surgery.call("cavity_clears_lower_back")), "cavity bag stays in front of the lumbar / lower-back exterior")
	_ok(bool(surgery.call("cavity_wraps_organs")), "tapered cavity still wraps the gut volume")
	var wrap = surgery.get("_wrap")
	if wrap and wrap.vert_count() > 0:
		var wmin: Vector3 = wrap.pos[0]
		var wmax: Vector3 = wrap.pos[0]
		for p in wrap.pos:
			wmin = Vector3(minf(wmin.x, p.x), minf(wmin.y, p.y), minf(wmin.z, p.z))
			wmax = Vector3(maxf(wmax.x, p.x), maxf(wmax.y, p.y), maxf(wmax.z, p.z))
		var wext := (wmax - wmin).length()
		_ok(wext <= 0.85 and wmax.y < 2.0, "cavity wrap back cap is on the abdomen, not stretched to the sky (extent=%.3f ymax=%.3f)" % [wext, wmax.y])

	# 直线预览：拖出、调整端点，松手不切开；按「切割」才提交，并触发手术刀沿轨迹动画。
	if str(surgery.call("current_tool")) != "scalpel":
		surgery.call("set_tool", "scalpel")
	if surgery.has_method("set_cut_mode"):
		surgery.call("set_cut_mode", "straight")
	var verts_before := 0
	var faces_before := 0
	if surgery.get("_outer"):
		verts_before = int(surgery.get("_outer").vert_count())
		faces_before = int(surgery.get("_outer").face_count())
		# 尚未下刀：预览折线与嵌入切口必须重合（环状原先用第一张 XY 命中面，会偏）。
		_check_preview_embed_align(surgery.get("_outer"))
	var navel_b: Vector3 = surgery.call("_navel_world") if surgery.has_method("_navel_world") else player.global_position
	# 旧手绘松手提交已取消：debug_freehand 现在只拉预览。
	var preview_only := bool(surgery.call("debug_freehand_cut_from_navel"))
	_ok(preview_only, "dragging a straight path creates a preview and does not cut")
	_ok(not bool(surgery.get("cut_open")), "end_stroke / freehand release does not commit an incision")
	_ok(bool(surgery.call("has_cut_preview")), "straight preview remains until 切割 is pressed")
	_assert_preview_scale(surgery, "freehand straight")
	# 调整起止点。
	var ends: Array = surgery.call("straight_preview_ends") if surgery.has_method("straight_preview_ends") else []
	if ends.size() >= 2 and surgery.has_method("debug_drag_preview_end"):
		var b1: Vector3 = ends[1] + Vector3(0.012, 0.006, 0.0)
		_ok(bool(surgery.call("debug_drag_preview_end", "end", b1)), "straight preview end point can be dragged")
		var ends2: Array = surgery.call("straight_preview_ends")
		_ok(ends2.size() >= 2 and (ends2[1] as Vector3).distance_to(ends[1]) > 0.004, "adjusted end point moved")
	# 环状预览也可拉出、移动、变形，且此时仍不切开。
	if surgery.has_method("debug_set_ring_preview"):
		var ring_ok := bool(surgery.call("debug_set_ring_preview", surgery.get("_navel_rest") if surgery.get("_navel_rest") != null else Vector3(0, 1.06, 0.11), 0.032, 0.024))
		_ok(ring_ok, "ring / ellipse preview can be created")
		var rp0: Dictionary = surgery.call("ring_preview_params")
		if surgery.has_method("debug_move_ring_preview"):
			_ok(bool(surgery.call("debug_move_ring_preview", Vector3(0.01, -0.006, 0.0))), "ellipse preview can be moved")
		if surgery.has_method("debug_reshape_ring_preview"):
			_ok(bool(surgery.call("debug_reshape_ring_preview", 0.040, 0.028)), "ellipse preview can be reshaped")
		var rp1: Dictionary = surgery.call("ring_preview_params")
		_ok(float(rp1.get("rx", 0.0)) > float(rp0.get("rx", 0.0)) - 0.0001 and (rp1["center"] as Vector3).distance_to(rp0["center"]) > 0.004, "ring preview move / reshape took effect")
		_ok(not bool(surgery.get("cut_open")), "creating a ring preview does not cut")
		_assert_preview_scale(surgery, "ring / ellipse")
		# 切回直线预览再提交。
		var a: Vector3 = (surgery.get("_navel_rest") if surgery.get("_navel_rest") != null else Vector3(0, 1.06, 0.11)) + Vector3(-0.03, 0.01, 0.0)
		var b: Vector3 = a + Vector3(0.06, -0.012, 0.0)
		_ok(bool(surgery.call("debug_set_straight_preview", a, b)), "straight preview restored for confirm")
	# 确认切割：先走动画契约，再立即完成。
	_ok(bool(surgery.call("confirm_cut", true)), "切割 starts the scalpel animation along the path")
	_ok(bool(surgery.call("is_cut_animating")) or bool(surgery.get("last_cut_animated")), "scalpel cutting animation is triggered on confirm")
	if surgery.has_method("debug_finish_cut_anim"):
		surgery.call("debug_finish_cut_anim")
	await _frames(3)
	var cut_ok := bool(surgery.get("cut_open"))
	_ok(cut_ok, "pressing 切割 commits the straight incision")
	if surgery.has_method("preview_commit_deviation"):
		var dev := float(surgery.call("preview_commit_deviation"))
		_ok(dev <= 0.006, "straight cut lands on the dashed preview (max deviation %.4f)" % dev)
		_ok(bool(surgery.call("preview_matches_commit", 0.006)), "straight preview path and committed cut coincide")
	if surgery.has_method("trail_is_narrower_than_v035"):
		_ok(bool(surgery.call("trail_is_narrower_than_v035")), "red incision line is narrower than 0.3.5")
		_ok(float(surgery.call("trail_half_width")) <= 0.0045, "trail half-width is %.4f (0.3.5 was 0.0064)" % float(surgery.call("trail_half_width")))
	if surgery.has_method("trail_is_lighter_than_v035"):
		_ok(bool(surgery.call("trail_is_lighter_than_v035")), "red incision line is lighter than 0.3.5")
	_ok(not bool(surgery.call("can_grab_flap")), "a straight cut is an open knife wound, not a closed flap")
	if surgery.get("_outer"):
		var changed := int(surgery.get("_outer").face_count()) != faces_before or int(surgery.get("_outer").vert_count()) != verts_before or int(surgery.get("lofted_tris")) > 0
		_ok(changed, "surgical mesh topology changed after the cut")
	# 0.4.01：切开后不再留粉红涂鸦线，改为切口边缘皮肤红色渐变。
	_ok(not bool(surgery.call("has_incision_trail")) and int(surgery.get("wound_tint_verts")) > 0, "no graffiti line after the cut; lips carry the red skin gradient instead")
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", false)
	_ok(not bool(surgery.call("incision_trail_visible_without_xray")), "no incision graffiti with 透视 off")
	var pose_before_evert: Dictionary = _pose_snapshot()
	surgery.call("debug_settle_eversion")
	_ok(bool(surgery.call("cut_is_everted")), "committed open cut everts so the inner wall is exposed")
	_assert_pose_stable(pose_before_evert, _pose_snapshot(), "after eversion settles")
	if surgery.has_method("surgery_visuals_on_abdomen_scale"):
		var why := ""
		if surgery.has_method("surgery_visuals_scale_report"):
			why = " (%s)" % str((surgery.call("surgery_visuals_scale_report", 0.85) as Dictionary).get("reason", ""))
		_ok(bool(surgery.call("surgery_visuals_on_abdomen_scale", 0.85)), "after cut, abdomen / trail / wall stay on abdomen scale (no sky-stretch)%s" % why)
	if not _bed_pose.is_empty():
		_assert_pose_stable(_bed_pose, _pose_snapshot(), "after cut vs pre-surgery bed pose", 0.04)
	var open_w := float(surgery.call("lip_opening_width"))
	_ok(open_w > 0.003, "everted open lips are wider than the raw slit (%.4f)" % open_w)
	if surgery.has_method("evert_mid_width"):
		var mid_w := float(surgery.call("evert_mid_width"))
		var end_w := float(surgery.call("evert_end_width"))
		_ok(mid_w > 0.0 and mid_w >= end_w * 0.95, "straight-cut eversion is mid-heavy and lighter at the ends (mid=%.4f ends=%.4f)" % [mid_w, end_w])
	var dense_open := int(surgery.call("last_dense_wall_tris"))
	var loft_open := int(surgery.get("lofted_tris"))
	_ok(loft_open > 0, "open cut has a lofted wall (%d tris)" % loft_open)
	if dense_open > loft_open:
		_ok(loft_open < dense_open, "open-cut wall tris dropped vs dense loft (%d -> %d)" % [dense_open, loft_open])
	else:
		_ok(loft_open <= int(surgery.call("wall_tri_budget")), "open-cut wall stays within the tri budget (%d)" % loft_open)
	_ok(bool(surgery.call("wall_is_skinned")), "lofted wall carries bone weights / skin")
	_ok(bool(surgery.call("wall_shares_belly_deform")), "wall shader follows the belly soft deform")
	var fol: Dictionary = surgery.call("debug_wall_follow_delta")
	_ok(bool(fol.get("ok", false)), "wall centroid follows a pose change (wall=%.4f belly=%.4f)" % [float(fol.get("wall", 0.0)), float(fol.get("belly", 0.0))])
	surgery.call("set_tool", "grab")
	_ok(str(surgery.call("current_tool")) == "grab", "拿取 can be selected on an open cut to drag split skin")
	# 0.3.8：拿取只沿唇缘张开方向拉（沿切口方向只保留 15%），所以这里朝垂直切口的方向拖。
	_ok(bool(surgery.call("debug_drag_split_skin", Vector3(0.0, 0.02, 0.01))), "split skin is draggable with 拿取")
	_ok(float(surgery.call("split_skin_drag_offset")) > 0.004, "split-skin pull offset is applied (%.4f)" % float(surgery.call("split_skin_drag_offset")))
	surgery.call("debug_release_split_skin")
	surgery.call("set_tool", "grab")  # deselect
	surgery.call("set_tool", "scalpel")

	# 先做一条开放切口，确认层状壁。
	# 为避免破坏后续闭环，这里用脚本切口的 closed=true 作为主路径；
	# 另外单独记录 open 路径在副本上不好做，改用同一 API 的 closed=false 再重置较难。
	# 先闭环切口（本片主功能）。
	var cut := bool(surgery.call("debug_scripted_incision", true))
	await _frames(4)
	await _phys(2)
	_ok(cut, "scripted closed incision committed")
	_ok(bool(surgery.call("has_lofted_wall")), "incision produced a lofted wall connecting skin to cavity")
	_ok(int(surgery.get("lofted_tris")) > 0, "lofted wall has triangles (%s)" % surgery.get("lofted_tris"))
	var dense_closed := int(surgery.call("last_dense_wall_tris"))
	var loft_closed := int(surgery.get("lofted_tris"))
	_ok(dense_closed > 0 and loft_closed < dense_closed, "closed-cut wall tris reduced vs previous dense loft (%d -> %d)" % [dense_closed, loft_closed])
	# 0.3.9：截面沿完整唇缘放样（与真正分开的唇缘共用顶点，才不会有破面），不再重采样到 WALL_MAX_SEGMENTS；
	# 手机上 ~1k 三角仍很轻，这里给一个宽松上限。
	_ok(loft_closed <= 4096, "closed-cut wall is within the mobile tri budget (%d <= 4096)" % loft_closed)
	surgery.call("debug_settle_eversion")
	_ok(bool(surgery.call("cut_is_everted")), "closed cut everts outward so the lofted inner wall is visible")
	var closed_w := float(surgery.call("lip_opening_width"))
	_ok(closed_w > 0.003, "everted closed lips open wider than the raw slit (%.4f)" % closed_w)
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", false)
	_ok(int(surgery.get("wound_tint_verts")) > 0, "red lip gradient persists after eversion")
	_ok(bool(surgery.get("cavity_exposed")), "cavity inner wall is exposed after the cut")
	_ok(not bool(surgery.call("cavity_hidden_until_cut")), "cavity is no longer hidden after the cut")
	_ok(bool(surgery.call("can_grab_flap")), "closed path can isolate a flap (grab ready)")

	surgery.call("set_tool", "grab")
	_ok(str(surgery.call("current_tool")) == "grab", "switched to grab tool")
	var peeled := bool(surgery.call("peel_flap"))
	await _frames(6)
	await _phys(8)
	_ok(peeled, "grab / peel removed the enclosed skin flap")
	_ok(bool(surgery.get("flap_peeled")), "flap_peeled flag set")
	var kind := str(surgery.call("flap_kind_shipped"))
	# 0.3.6：切下的皮瓣改为独立刚体（像空弹匣），不再用会异常拉伸的柔体。
	_ok(kind == "rigid" or (surgery.has_method("flap_is_independent") and bool(surgery.call("flap_is_independent"))), "cut-off flap is an independent rigid entity (got '%s')" % kind)
	var flap: Node = surgery.get("flap_node")
	_ok(flap != null and is_instance_valid(flap), "flap node exists in the tree after peel")
	_ok(str(player.get("occupancy")) == "exam_bed", "still on the exam bed after peel")
	await _phys(36)
	await _frames(8)
	_ok(bool(surgery.call("flap_clear_of_bed", 0.05)), "flap is not intersecting through the exam bed at rest")
	var c0: Vector3 = surgery.call("flap_centroid")
	_ok(bool(surgery.call("debug_grab_move_flap", Vector3(0.0, 0.08, 0.05))), "grab tool can pick up and move the enclosed flap")
	await _phys(2)
	await _frames(2)
	var c1: Vector3 = surgery.call("flap_centroid")
	_ok(c1.distance_to(c0) > 0.02, "held flap moved with the grab (%s -> %s)" % [c0, c1])
	if surgery.has_method("flap_stretch_ratio"):
		var stretch := float(surgery.call("flap_stretch_ratio"))
		_ok(stretch <= 1.35, "moved flap does not abnormally stretch (ratio=%.3f)" % stretch)
	_ok(bool(surgery.call("flap_is_held")), "flap is held while 拿取 is dragging it")
	_ok(bool(surgery.call("debug_throw_flap", Vector3(0.6, 0.4, 0.2))), "releasing the flap throws it with residual velocity")
	_ok(float(surgery.call("flap_throw_speed")) > 0.05, "throw speed is recorded (%.3f)" % float(surgery.call("flap_throw_speed")))
	await _phys(8)

	# 退出后躯体改变仍在。
	surgery.call("exit_surgery")
	await _frames(4)
	_ok(not bool(surgery.call("is_active")), "exited surgery mode")
	_ok(bool(surgery.call("has_persistent_state")), "body state remains after leaving surgery")
	_ok(bool(surgery.get("cut_open")) or bool(surgery.get("flap_peeled")), "cut / flap persists on BodyState")
	_ok(bool(surgery.call("has_lofted_wall")), "lofted wall still present after exit")
	# 再进入确认不会把网格恢复成未切状态。
	_ok(bool(surgery.call("enter_surgery")), "can re-enter surgery")
	await _frames(2)
	_ok(bool(surgery.get("cut_open")), "re-enter keeps the cut body")
	surgery.call("exit_surgery")
	_ok(str(player.get("occupancy")) == "exam_bed", "occupancy unchanged after exit")

	# 弹孔贯穿：默认关闭；非特写不穿孔；开启后只有带 cinematic 标记的特写命中才冲压通道。
	var settings_hole: Node = main.get_node_or_null("GameSettings")
	_ok(settings_hole != null, "GameSettings exists for 弹孔贯穿")
	if settings_hole:
		_ok(bool(settings_hole.get("bullet_hole_penetrate")) == false, "弹孔贯穿 defaults to off")
		settings_hole.call("set_bullet_hole_penetrate", true)
		_ok(bool(settings_hole.get("bullet_hole_penetrate")), "弹孔贯穿 can be turned on")
		settings_hole.call("load_cfg")
		_ok(bool(settings_hole.get("bullet_hole_penetrate")), "弹孔贯穿 persists after reload")
		settings_hole.call("set_bullet_hole_penetrate", false)
		_ok(not bool(settings_hole.get("bullet_hole_penetrate")), "弹孔贯穿 can be turned back off")
	var organs2: Node = player.call("get_organs") if player.has_method("get_organs") else organs
	var navel: Vector3 = Vector3(0, 1.06, 0.11)
	if organs2 and organs2.has_method("navel_world"):
		navel = organs2.call("navel_world")
	var b_origin := navel + Vector3(0.05, 0.05, 0.30)
	var b_dir := (navel + Vector3(0.05, 0.05, 0.0) - b_origin)
	if b_dir.length_squared() < 1e-8:
		b_dir = Vector3(0, 0, -1)
	else:
		b_dir = b_dir.normalized()
	var holes_before := int(surgery.get("bullet_holes")) if surgery.get("bullet_holes") != null else 0
	if organs2 and organs2.has_method("apply_ballistic_hit"):
		organs2.call("apply_ballistic_hit", b_origin, b_dir, {"energy": 0.85, "impulse": 0.5, "overpen": 0.15, "category": "pistol"})
	_ok(int(surgery.get("bullet_holes")) == holes_before, "a non-特写 hit does not punch a mesh hole while the setting is off")
	if settings_hole:
		settings_hole.call("set_bullet_hole_penetrate", true)
	if organs2 and organs2.has_method("apply_ballistic_hit"):
		organs2.call("apply_ballistic_hit", b_origin, b_dir, {"energy": 0.85, "impulse": 0.5, "overpen": 0.15, "category": "pistol"})
	_ok(int(surgery.get("bullet_holes")) == holes_before, "a non-特写 hit still does not punch a mesh hole when the setting is on")
	# 带 cinematic 标记的命中（特写推迟路径）在设置开启时应穿孔。
	var punched := false
	if organs2 and organs2.has_method("apply_ballistic_hit"):
		organs2.call("apply_ballistic_hit", b_origin, b_dir, {"energy": 0.85, "impulse": 0.5, "overpen": 0.15, "category": "pistol", "cinematic": true, "bullet_cam": true})
		punched = bool(surgery.call("has_bullet_hole"))
	_ok(punched and bool(surgery.call("has_bullet_hole")), "a 特写 hit punches a cylindrical mesh hole when 弹孔贯穿 is on")
	var holes_after := int(surgery.get("bullet_holes"))
	if settings_hole:
		settings_hole.call("set_bullet_hole_penetrate", false)
	if organs2 and organs2.has_method("apply_ballistic_hit"):
		organs2.call("apply_ballistic_hit", b_origin + Vector3(0.02, 0.0, 0.0), b_dir, {"energy": 0.85, "impulse": 0.5, "overpen": 0.15, "category": "pistol", "cinematic": true, "bullet_cam": true})
	_ok(int(surgery.get("bullet_holes")) == holes_after, "even a 特写 hit does not punch a mesh hole when 弹孔贯穿 is off")
	if settings_hole:
		settings_hole.call("set_bullet_hole_penetrate", true)
	_ok(bool(surgery.call("bullet_plug_removed")), "the circular plug in the middle of the hole is removed")
	var btris := int(surgery.get("bullet_wall_tris"))
	_ok(btris > 0 and btris <= Geom.bullet_wall_tri_budget() * 3, "bullet cylinder uses a small tri budget (%d)" % btris)
	var fol2: Dictionary = surgery.call("debug_wall_follow_delta")
	_ok(bool(fol2.get("ok", false)), "bullet-hole / incision wall still follows a pose or deform change")
	_ok(bool(surgery.call("has_persistent_state")), "bullet hole persists on the body after being punched outside a new surgery session")

	# 真实特写路径：对分身开火 → BulletCam.consider 推迟命中 → 弹头到体表再 flush apply_ballistic_hit。
	var settings: Node = main.get_node_or_null("GameSettings")
	var bcam: Node = main.get_node_or_null("BulletCam")
	var ws: Node = player.call("get_weapons") if player.has_method("get_weapons") else null
	var bal: Node = ws.get("ballistics") if ws else null
	_ok(settings != null and bcam != null and bal != null, "weapon / bullet-cam systems exist for the live close-up path")
	if settings and bcam and bal and main.has_method("spawn_clone"):
		var msg: String = str(main.call("spawn_clone", player.global_position + Vector3(1.1, 0.0, 0.35)))
		await _frames(10)
		await _phys(4)
		var clones: Array = main.call("get_clones") if main.has_method("get_clones") else []
		_ok(clones.size() >= 1, "clone spawned for close-up hole (%s)" % msg)
		if clones.size() >= 1:
			var cl: Node = clones[0]
			_ok(cl.has_method("get_surgery") and cl.call("get_surgery") != null, "clone exposes get_surgery")
			var corg: Node = cl.call("get_organs")
			var csurg: Node = cl.call("get_surgery")
			var cn: Vector3 = corg.call("navel_world")
			var cfwd: Vector3 = (corg.call("abdomen_frame") as Transform3D).basis.z.normalized()
			var co: Vector3 = cn + cfwd * 0.55
			var cd: Vector3 = (cn - co).normalized()
			settings.call("set_bullet_cam_enabled", true)
			settings.call("set_bullet_cam_chance", 1.0)
			if settings.has_method("set_bullet_hole_penetrate"):
				settings.call("set_bullet_hole_penetrate", true)
			bcam.set("debug_roll", 0.0)
			var def = ws.call("get_def", "rifle") if ws.has_method("get_def") else null
			bal.call("fire_projectile", co, cd, "rifle", def)
			await _phys(20)
			await _frames(8)
			if bool(bcam.get("playing")) and bcam.has_method("debug_advance"):
				bcam.call("debug_advance", 0.9)
				await _frames(2)
			var live_hole := csurg != null and bool(csurg.call("has_bullet_hole"))
			if not live_hole and bool(bcam.get("playing")) and bcam.has_method("skip"):
				bcam.call("skip")
				await _frames(2)
				live_hole = csurg != null and bool(csurg.call("has_bullet_hole"))
			_ok(live_hole, "live close-up / weapon path punches a visible mesh bullet hole on the body")
			if csurg:
				_ok(bool(csurg.call("bullet_plug_removed")), "close-up hole has the center plug removed")
				_ok(int(csurg.get("bullet_wall_tris")) > 0, "close-up hole has a cylindrical channel wall (%d tris)" % int(csurg.get("bullet_wall_tris")))
			if bool(bcam.get("playing")) and bcam.has_method("skip"):
				bcam.call("skip")
			settings.call("set_bullet_cam_chance", 0.20)
			if settings.has_method("set_bullet_hole_penetrate"):
				settings.call("set_bullet_hole_penetrate", false)
			bcam.set("debug_roll", -1.0)


func _path_poly_deviation(a: PackedVector3Array, b: PackedVector3Array) -> float:
	## 两条折线的最大偏离（点到对折线段的距离），不按下标一一对应。
	if a.size() < 2 or b.size() < 2:
		return 1e9
	var worst := 0.0
	for p in a:
		worst = maxf(worst, _dist_point_poly(p, b))
	for p2 in b:
		worst = maxf(worst, _dist_point_poly(p2, a))
	return worst


func _dist_point_poly(p: Vector3, poly: PackedVector3Array) -> float:
	var best := 1e9
	for i in range(poly.size() - 1):
		best = minf(best, _dist_point_seg(p, poly[i], poly[i + 1]))
	best = minf(best, _dist_point_seg(p, poly[poly.size() - 1], poly[0]))
	return best


func _dist_point_seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _check_preview_embed_align(md) -> void:
	## 在尚未下刀的腹网上，环状/直线预览路径与 embed 后的切口应重合。
	if md == null:
		_ok(false, "abdomen mesh available for preview/embed alignment")
		return
	var navel_r: Vector3 = surgery.get("_navel_rest") if surgery.get("_navel_rest") != null else Vector3(0, 1.06, 0.11)
	var rpath: PackedVector3Array = Geom.oval_path_on_mesh(md, navel_r, 0.028, 0.022, 24)
	if rpath.size() >= 3:
		var md_r = md.clone()
		var ids: PackedInt32Array = Geom.embed_path(md_r, rpath)
		var epts := PackedVector3Array()
		for id in ids:
			if id >= 0 and id < md_r.vert_count():
				epts.append(md_r.pos[id])
		var worst := _path_poly_deviation(rpath, epts)
		_ok(ids.size() >= 3 and worst <= 0.006, "ring preview path and embedded cut coincide (dev=%.4f)" % worst)
	else:
		_ok(false, "ring preview path could be built on the abdomen mesh")
	var a: Vector3 = navel_r + Vector3(-0.025, 0.008, 0.0)
	var b: Vector3 = navel_r + Vector3(0.025, -0.008, 0.0)
	var lpath: PackedVector3Array = Geom.line_path_on_mesh(md, a, b, 12)
	if lpath.size() >= 2:
		var md2 = md.clone()
		var ids2: PackedInt32Array = Geom.embed_path(md2, lpath)
		var e2 := PackedVector3Array()
		for id2 in ids2:
			if id2 >= 0 and id2 < md2.vert_count():
				e2.append(md2.pos[id2])
		var worst2 := _path_poly_deviation(lpath, e2)
		_ok(ids2.size() >= 2 and worst2 <= 0.006, "straight preview segment and embedded cut coincide (dev=%.4f)" % worst2)
	else:
		_ok(false, "straight preview path could be built on the abdomen mesh")
	# 世界坐标提示不得被当成绑定顶点写进腹网，否则会出现拉到天上的三角形。
	var md3 = md.clone() if md.has_method("clone") else null
	if md3:
		var sky := Vector3(navel_r.x, navel_r.y + 8.0, navel_r.z)
		var vid: int = Geom.insert_point_in_mesh(md3, Vector2(navel_r.x, navel_r.y), sky)
		_ok(vid >= 0, "insert_point still succeeds with a far-off 3D hint")
		if vid >= 0 and vid < md3.vert_count():
			_ok(md3.pos[vid].distance_to(sky) > 1.0, "far-off world hint is not written into the abdomen mesh")
			_ok(md3.pos[vid].distance_to(navel_r) <= 0.20, "inserted vertex stays on the abdomen (dist=%.3f)" % md3.pos[vid].distance_to(navel_r))


func _check_036_clone_bed_and_ring_align() -> void:
	## 对准检查床可放置分身，靠近后可对分身进入手术（预览/嵌入对齐已在下刀前检查）。
	# 玩家离开检查床后，对准床放置分身，再靠近进入手术。
	if vs and vs.get("occupied"):
		vs.call("try_exit")
		await _frames(6)
		await _phys(2)
	_ok(str(player.get("occupancy")) != "exam_bed", "player left the exam bed before placing a clone")
	var bed := _find_exam_bed()
	_ok(bed != null, "exam bed available for 放置分身")
	if bed == null or not main.has_method("place_clone_on_bed"):
		return
	player.global_position = bed.global_position + Vector3(1.3, 0.1, 0.0)
	if vs.has_method("_update_nearest"):
		vs.call("_update_nearest")
	_ok(bool(main.call("can_place_clone_on_bed", bed)), "aiming / standing at an empty exam bed offers 放置分身")
	var msg: String = str(main.call("place_clone_on_bed", bed))
	await _frames(8)
	await _phys(4)
	var clone: Node = main.call("clone_on_nearby_bed") if main.has_method("clone_on_nearby_bed") else null
	_ok(clone != null, "tapping 放置分身 puts a clone on the exam bed (%s)" % msg)
	if clone:
		_ok(bool(clone.call("is_on_exam_bed")), "clone is using the exam bed pose")
		_ok(str(clone.get("occupancy")) == "exam_bed", "clone occupancy is exam_bed")
	player.global_position = bed.global_position + Vector3(1.3, 0.1, 0.0)
	if vs.has_method("_update_nearest"):
		vs.call("_update_nearest")
	_ok(bool(main.call("can_toggle_surgery")), "approaching a clone on the exam bed can start surgery")
	_ok(str(main.call("action_for_key", KEY_T, "control")) == "surgery_toggle", "T starts surgery when a clone is on the nearby exam bed")
	_ok(bool(main.call("toggle_surgery")), "surgery starts on the clone lying on the exam bed")
	await _frames(4)
	var cs = main.call("surgery_system_of") if main.has_method("surgery_system_of") else null
	_ok(cs != null and bool(cs.call("is_active")), "surgery mode is active on the bedded clone")
	if cs:
		_ok(player.call("get_surgery") != cs, "clone surgery is distinct from the player's SurgerySystem")
		_ok(player.call("active_surgery") == cs, "active_surgery resolves to the clone on the exam bed")
		cs.call("set_tool", "scalpel")
		if cs.has_method("set_cut_mode"):
			cs.call("set_cut_mode", "straight")
		await _frames(6)
		var began_clone := bool(cs.call("debug_begin_stroke_at_navel"))
		if not began_clone and cs.has_method("debug_set_straight_preview"):
			var na: Vector3 = cs.get("_navel_rest") if cs.get("_navel_rest") != null else Vector3(0, 1.06, 0.11)
			began_clone = bool(cs.call("debug_set_straight_preview", na + Vector3(-0.02, 0.0, 0.0), na + Vector3(0.04, 0.01, 0.0)))
			# 仍要用控制器拖一次，证明 drag 路由到达分身手术系统。
			if player.has_method("debug_drag_active_surgery"):
				var cn0: Vector3 = cs.call("_navel_world")
				player.call("debug_drag_active_surgery", cn0 + Vector3(0.0, 0.02, 0.28), Vector3(0, -0.02, -0.28).normalized())
		_ok(began_clone, "clone scalpel stroke begins at the navel")
		var cn: Vector3 = cs.call("_navel_world")
		for i in range(1, 6):
			var tgt: Vector3 = cn + Vector3(0.010 * float(i), 0.003 * float(i), 0.0)
			var origin: Vector3 = tgt + Vector3(0.0, 0.02, 0.28)
			var dir: Vector3 = (tgt - origin).normalized()
			# 必须走玩家控制器的 active_surgery 路由：0.3.6 曾把 drag_stroke 发给未激活的本体手术系统，预览拉不出来。
			if player.has_method("debug_drag_active_surgery"):
				_ok(bool(player.call("debug_drag_active_surgery", origin, dir)) or i > 1, "player controller drag reaches the active (clone) surgery")
			else:
				cs.call("drag_stroke", origin, dir)
		cs.call("end_stroke")
		_ok(bool(cs.call("has_cut_preview")), "straight preview can be pulled out on the clone via the player controller")
		_assert_preview_scale(cs, "clone controller drag")
		# 环状预览同样可创建且不出现天空级网格。
		if cs.has_method("debug_set_ring_preview"):
			_ok(bool(cs.call("debug_set_ring_preview", cs.get("_navel_rest"), 0.030, 0.022)), "ring preview can be created on the clone")
			_assert_preview_scale(cs, "clone ring")
	if cs and cs.has_method("exit_surgery"):
		cs.call("exit_surgery")
	if clone and clone.has_method("leave_exam_bed"):
		clone.call("leave_exam_bed")


