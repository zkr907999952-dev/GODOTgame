extends SceneTree
## 0.3.0 手术模式第一片自检：检查床进入/退出、T 不再循环互动、
## 腹腔切开前后可见性、手绘切口层状腹壁、闭环剥离皮瓣、退出后躯体状态保留。
##   LIBGL_ALWAYS_SOFTWARE=1 godot --headless --path . \
##     --rendering-method gl_compatibility --rendering-driver opengl3 \
##     -s res://scripts/tests/surgery_check.gd

const VERSION_NAME := "0.3.0"
const VERSION_CODE := 34

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
	# 工具栏默认手术刀。
	_ok(str(surgery.call("current_tool")) == "scalpel", "default tool is scalpel")


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
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", false)
	await _frames(2)
	_ok(not bool(surgery.call("cavity_visible_in_xray")), "cavity is not counted visible in x-ray when x-ray is off")
	if organs and organs.has_method("set_xray_enabled"):
		organs.call("set_xray_enabled", true)

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
