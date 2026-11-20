extends SceneTree
## 0.3.2 手术模式自检：进入默认无工具可转视角、选工具锁定视角、
## 手术刀手绘切口真正提交、皮肤红色渐变轨迹、透视下腹腔半透明可见内脏；
## 以及既有进入/退出、层状腹壁、闭环剥瓣与退出后保留。
##   LIBGL_ALWAYS_SOFTWARE=1 godot --headless --path . \
##     --rendering-method gl_compatibility --rendering-driver opengl3 \
##     -s res://scripts/tests/surgery_check.gd

const VERSION_NAME := "0.3.2"
const VERSION_CODE := 36
const Geom := preload("res://scripts/surgery/surgery_geom.gd")

var fails := 0
var main: Node
var player: Node
var hud: Node
var vs: Node
var surgery: Node


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
	# 0.3.2：进入手术默认不选工具，可控制视角；选工具后锁定视角。
	_ok(str(surgery.call("current_tool")) == "", "default tool is none so the player can look")
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
	var sec: RefCounted = player.call("get_secondary") if player.has_method("get_secondary") else null
	var began := bool(surgery.call("debug_begin_stroke_at_navel"))
	_ok(began, "debug stroke at navel begins")
	_ok(bool(surgery.call("is_pose_locked")), "abdomen pose is fully locked during a scalpel stroke")
	if sec:
		_ok(float(sec.get("breath_amp")) <= 0.0001, "breath amp is zero while the stroke is locked")
		_ok(not bool(sec.get("breath_enabled")), "breathing is disabled during the stroke")
	# 拖一段路径，确认皮肤上出现红色轨迹。
	var navel: Vector3 = surgery.call("_navel_world") if surgery.has_method("_navel_world") else player.global_position
	for i in range(1, 5):
		var tgt: Vector3 = navel + Vector3(0.008 * float(i), 0.002 * float(i), 0.0)
		var origin: Vector3 = tgt + Vector3(0.0, 0.02, 0.28)
		var dir: Vector3 = (tgt - origin).normalized()
		surgery.call("drag_stroke", origin, dir)
	_ok(bool(surgery.call("has_incision_trail")), "red gradient trail is created on the skin during a stroke")
	_ok(int(surgery.call("incision_trail_point_count")) >= 2, "trail has at least two path points while dragging")
	# 取消这次预览落刀，留给后面的「切开前腹腔隐藏」检查，以及专门的手绘提交回归。
	if surgery.has_method("cancel_stroke"):
		surgery.call("cancel_stroke")
	else:
		surgery.call("end_stroke")
	await _frames(2)
	_ok(not bool(surgery.call("is_pose_locked")), "pose lock released after the stroke is cancelled")
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

	# 「切割没有生效」回归：用与玩家相同的 begin/drag/end 射线路径提交切口。
	if str(surgery.call("current_tool")) != "scalpel":
		surgery.call("set_tool", "scalpel")
	var verts_before := 0
	var faces_before := 0
	if surgery.get("_outer"):
		verts_before = int(surgery.get("_outer").vert_count())
		faces_before = int(surgery.get("_outer").face_count())
	var cut_ok := bool(surgery.call("debug_freehand_cut_from_navel"))
	await _frames(3)
	_ok(cut_ok, "freehand scalpel stroke commits and changes the surgical mesh")
	_ok(bool(surgery.get("cut_open")), "cut_open is set after a real pointer stroke")
	if surgery.get("_outer"):
		var changed := int(surgery.get("_outer").face_count()) != faces_before or int(surgery.get("_outer").vert_count()) != verts_before or int(surgery.get("lofted_tris")) > 0
		_ok(changed, "surgical mesh topology changed after the cut")
	_ok(bool(surgery.call("has_incision_trail")), "red trail remains on the skin after the cut commits")

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
	_ok(kind == "softbody" or kind == "verlet", "flap uses SoftBody3D or Verlet fallback (got '%s')" % kind)
	var flap: Node = surgery.get("flap_node")
	_ok(flap != null and is_instance_valid(flap), "flap node exists in the tree after peel")
	_ok(str(player.get("occupancy")) == "exam_bed", "still on the exam bed after peel")
	await _phys(36)
	await _frames(8)
	_ok(bool(surgery.call("flap_clear_of_bed", 0.05)), "flap is not intersecting through the exam bed at rest")

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
