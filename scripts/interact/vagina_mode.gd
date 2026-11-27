extends Node
## 阴道互动模式：检查床上进入（T-15：观察视角也可以当前站姿直接进入，不上床），镜头飞到外阴，
## 自由环绕 + 两个预设视角，专用工具栏。镜头都按阴道通道当前的世界朝向计算（躺 / 站都对）。
class_name VaginaMode

const RegistryScript := preload("res://scripts/interact/vagina_tool_registry.gd")
const SectionScript := preload("res://scripts/interact/cross_section_view.gd")

signal mode_changed(active: bool)
signal tool_changed(tool_id: String)
signal camera_preset_changed(preset: String)

const PRESET_FREE := "free"
const PRESET_INTROITUS := "introitus"
const PRESET_ABDOMEN := "abdomen"

## t99u：player = 操作者（镜头 / 输入，永远是受控角色节点）；subject = 被互动的身体宿主
## （受控角色自己，或检查床上的分身）。organs / surgery 每次都从 subject 现取，不缓存，
## 附身换身体后不会再作用到旧身体上。会话期间身体变了（附身 / 分身被删 / 离床）会先干净退出。
var player: Node
var subject: Node = null
var organs: Node:
	get:
		return _subject_part("get_organs", _organs_fallback)
	set(v):
		_organs_fallback = v
var surgery: Node:
	get:
		return _subject_part("get_surgery", _surgery_fallback)
	set(v):
		_surgery_fallback = v
var _organs_fallback: Node = null
var _surgery_fallback: Node = null
var _session_subject: Node = null
var _session_organs: Node = null
var registry = null
var active := false
var tool_id := ""
var camera_preset := PRESET_FREE
var last_step_usec := 0

var _resume_play_mode := -1
var _saved_xray := false
var _saved_xray_amount := 0.0
var _xray_pushed := false
var _anchor := Vector3.ZERO
var _controller: Node
var _section: Node
var _view_jolt := Vector3.ZERO


func setup(p: Node, o: Node, s: Node) -> void:
	player = p
	subject = p
	organs = o
	surgery = s
	registry = RegistryScript.new()
	registry.setup_defaults()
	set_process(true)


func is_active() -> bool:
	return active


func _host() -> Node:
	if subject != null and is_instance_valid(subject) and not subject.is_queued_for_deletion():
		return subject
	return player


func _subject_part(getter: String, fallback: Node) -> Node:
	var h := _host()
	if h and h.has_method(getter):
		var n: Node = h.call(getter)
		if n:
			return n
	return fallback if fallback != null and is_instance_valid(fallback) else null


## 互动对象（受控角色自己或检查床上的分身）。会话进行中不换对象。
func get_subject() -> Node:
	return _host()


func is_subject(host: Node) -> bool:
	return host != null and _host() == host


func set_subject(host: Node) -> bool:
	if host == null:
		host = player
	if active and host != _host():
		return false
	subject = host
	return true


func _subject_is_player() -> bool:
	return _host() == player


func current_tool() -> String:
	return tool_id


func current_preset() -> String:
	return camera_preset


func can_enter() -> bool:
	return not active and _on_bed()


## T-15：站姿会话（从观察视角进入，不上检查床）。
var standing_session := false


func _standing_ok() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if not _subject_is_player():
		return false
	if str(player.get("occupancy")) != "":
		return false
	if player.has_method("is_dead") and bool(player.call("is_dead")):
		return false
	if player.has_method("is_display_mode") and not bool(player.call("is_display_mode")):
		return false
	return true


func _mode_ok() -> bool:
	return _on_bed() or (standing_session and _standing_ok())


func enter_standing() -> bool:
	if active:
		return true
	if _on_bed():
		return enter()
	if not _standing_ok():
		return false
	standing_session = true
	if not enter():
		standing_session = false
		return false
	if player.has_method("set_body_mode_hold"):
		player.call("set_body_mode_hold", true)
	return true


func is_standing() -> bool:
	return active and standing_session


func _on_bed() -> bool:
	var h := _host()
	if h == null:
		return false
	if h != player:
		# 分身：在床上、活着，操作者也活着。
		if h.has_method("is_dead") and bool(h.call("is_dead")):
			return false
		if player and player.has_method("is_dead") and bool(player.call("is_dead")):
			return false
		return h.has_method("is_on_exam_bed") and bool(h.call("is_on_exam_bed"))
	if str(h.get("occupancy")) == "exam_bed":
		return true
	if h.has_method("is_on_exam_bed"):
		return bool(h.call("is_on_exam_bed"))
	return false


func enter() -> bool:
	if active:
		return true
	if not _mode_ok():
		return false
	# 与手术互斥：先进互动就退出手术。
	if surgery and surgery.has_method("is_active") and bool(surgery.call("is_active")):
		if surgery.has_method("exit_surgery"):
			surgery.call("exit_surgery")
	_resume_play_mode = -1
	if player and "play_mode" in player:
		_resume_play_mode = int(player.play_mode)
	# 用观察环绕镜头，不强迫第一人称。
	if player and player.has_method("set_play_mode"):
		player.call("set_play_mode", 0)
	active = true
	_session_subject = _host()
	_session_organs = organs
	tool_id = ""
	camera_preset = PRESET_FREE
	_push_abdomen_xray(false)
	fly_to_genitals(true)
	mode_changed.emit(true)
	tool_changed.emit(tool_id)
	camera_preset_changed.emit(camera_preset)
	return true


func exit() -> void:
	if not active:
		return
	active = false
	_teardown_controller()
	_teardown_section()
	tool_id = ""
	camera_preset = PRESET_FREE
	_restore_xray()
	_view_jolt = Vector3.ZERO
	if player and player.has_method("clear_orbit_anchor"):
		player.call("clear_orbit_anchor")
	if standing_session:
		standing_session = false
		if player and player.has_method("set_body_mode_hold"):
			player.call("set_body_mode_hold", false)
		if player and player.has_method("tp_home") and str(player.get("occupancy")) == "":
			player.call("tp_home", false)
	if _resume_play_mode >= 0 and player and player.has_method("set_play_mode"):
		if int(player.get("play_mode")) != _resume_play_mode:
			player.call("set_play_mode", _resume_play_mode)
	_resume_play_mode = -1
	_session_subject = null
	_session_organs = null
	# 下一次默认回到受控角色自己；分身会话由 GameRoot 在进入前重新指定。
	subject = player
	mode_changed.emit(false)
	tool_changed.emit(tool_id)


## 会话绑定的身体是否还在：附身换了身体 / 分身被清除 / 宿主换了 OrganRig 都算失效。
func _session_valid() -> bool:
	if _session_subject == null or not is_instance_valid(_session_subject) or _session_subject.is_queued_for_deletion():
		return false
	if _session_organs == null or not is_instance_valid(_session_organs):
		return false
	if _host() != _session_subject:
		return false
	return organs == _session_organs


func toggle() -> void:
	if active:
		exit()
	else:
		enter()


func set_tool(id: String) -> void:
	if not active:
		return
	var next := id
	if next == tool_id:
		# 再点一次取消选择。扩张器已取出则重新插入。
		if next == "speculum" and surgery and surgery.has_method("is_speculum_present") and not bool(surgery.call("is_speculum_present")):
			_activate_speculum()
			tool_changed.emit(tool_id)
			return
		_teardown_controller()
		tool_id = ""
		_sync_section()
		tool_changed.emit(tool_id)
		return
	if registry and not registry.has_tool(next):
		next = ""
	elif registry:
		var t = registry.get_tool(next)
		if t and bool(t.reserved):
			return
	_teardown_controller()
	tool_id = next
	if tool_id == "speculum":
		_activate_speculum()
	elif tool_id != "":
		_activate_controller(tool_id)
	_sync_section()
	tool_changed.emit(tool_id)


func ensure_tool(id: String) -> void:
	if tool_id != id:
		set_tool(id)


func _activate_speculum() -> void:
	# 扩张器实现仍在手术系统里，行为不变，只是改由本模式的工具栏选择。
	if surgery == null:
		return
	if surgery.has_method("ensure_tool"):
		surgery.call("ensure_tool", "speculum")
	elif surgery.has_method("set_tool"):
		surgery.call("set_tool", "speculum")


func _activate_controller(id: String) -> void:
	if registry == null:
		return
	var ttool = registry.get_tool(id)
	if ttool == null:
		return
	var path := str(ttool.controller_script) if "controller_script" in ttool else ""
	if path.is_empty():
		return
	var scr := load(path)
	if scr == null:
		return
	_controller = scr.new()
	_controller.name = "Tool_" + id
	add_child(_controller)
	if _controller.has_method("setup"):
		_controller.call("setup", self, organs, player)
	if _controller.has_method("activate"):
		_controller.call("activate")


func _teardown_controller() -> void:
	if _controller == null:
		return
	if is_instance_valid(_controller):
		if _controller.has_method("deactivate"):
			_controller.call("deactivate")
		_controller.queue_free()
	_controller = null


func tool_controller() -> Node:
	return _controller if is_instance_valid(_controller) else null


func begin_tool_drag(screen: Vector2, origin: Vector3, dir: Vector3) -> bool:
	if not active:
		return false
	_prol_drag = false
	# 0.4.12：球卡在宫颈里时先交给球杆（拖球 = 拖子宫）；否则点中体外脱出物 = 用手拖子宫。
	var caught := _controller != null and is_instance_valid(_controller) and _controller.has_method("is_caught") and bool(_controller.call("is_caught"))
	if not caught and begin_prolapse_drag(origin, dir):
		return true
	if _controller == null or not is_instance_valid(_controller):
		return false
	if _controller.has_method("begin_drag"):
		return bool(_controller.call("begin_drag", screen, origin, dir))
	return false


func update_tool_drag(screen: Vector2, origin: Vector3, dir: Vector3) -> void:
	if _prol_drag:
		update_prolapse_drag(origin, dir)
		return
	if _controller and is_instance_valid(_controller) and _controller.has_method("update_drag"):
		_controller.call("update_drag", screen, origin, dir)


func end_tool_drag() -> void:
	if _prol_drag:
		end_prolapse_drag()
		return
	if _controller and is_instance_valid(_controller) and _controller.has_method("end_drag"):
		_controller.call("end_drag")


# ------------------------------------------------------------------ 0.4.12 用手拖脱出的子宫
var _prol_drag := false
var _prol_plane_p := Vector3.ZERO
var _prol_grab_off := Vector3.ZERO


func _prolapse_ctl() -> Node:
	if organs == null or not organs.has_method("has_prolapse") or not bool(organs.call("has_prolapse")):
		return null
	return organs.call("prolapse")


## 点中体外的脱出物就开始拖（物理子宫跟手，可甩；往回推可复位）。返回是否点中。
func begin_prolapse_drag(origin: Vector3, dir: Vector3) -> bool:
	var pc := _prolapse_ctl()
	if pc == null:
		return false
	var hit: Dictionary = pc.call("ray_pick", origin, dir)
	if hit.is_empty():
		return false
	var node_i := int(hit["node"])
	var nodes: PackedVector3Array = pc.call("node_positions")
	_prol_plane_p = hit["point"]
	_prol_grab_off = nodes[node_i] - _prol_plane_p
	pc.call("begin_drive", "hand", node_i, nodes[node_i], true)
	_prol_drag = true
	return true


func update_prolapse_drag(origin: Vector3, dir: Vector3) -> void:
	var pc := _prolapse_ctl()
	if pc == null:
		_prol_drag = false
		return
	var d := dir.normalized()
	var n := d
	if player and player.has_method("get_camera"):
		var cam: Camera3D = player.call("get_camera")
		if cam:
			n = -cam.global_transform.basis.z
	var den := d.dot(n)
	if absf(den) < 1e-5:
		return
	var t := clampf((_prol_plane_p - origin).dot(n) / den, 0.02, 2.0)
	pc.call("drive_to", origin + d * t + _prol_grab_off)


func end_prolapse_drag() -> void:
	_prol_drag = false
	var pc := _prolapse_ctl()
	if pc:
		pc.call("end_drive")


func is_prolapse_dragging() -> bool:
	return _prol_drag


func add_view_jolt(v: Vector3) -> void:
	_view_jolt = v



func _sync_section() -> void:
	# 选中长柄金属球时默认打开右上角断面图；关掉或换工具则隐藏。
	if tool_id == "ball_rod":
		_ensure_section()
		if _section and _section.has_method("set_visible_on"):
			_section.call("set_visible_on", true)
	elif _section and _section.has_method("set_visible_on"):
		_section.call("set_visible_on", false)


func _ensure_section() -> void:
	if _section != null and is_instance_valid(_section):
		return
	_section = SectionScript.new()
	_section.name = "CrossSectionView"
	add_child(_section)
	if _section.has_method("setup"):
		_section.call("setup", self, organs, player)


func _teardown_section() -> void:
	if _section == null:
		return
	if is_instance_valid(_section):
		if _section.has_method("deactivate"):
			_section.call("deactivate")
		_section.queue_free()
	_section = null


func cross_section() -> Node:
	return _section if is_instance_valid(_section) else null


func set_camera_preset(preset: String, snap: bool = false) -> void:
	if not active:
		return
	if preset != PRESET_FREE and preset != PRESET_INTROITUS and preset != PRESET_ABDOMEN:
		preset = PRESET_FREE
	camera_preset = preset
	if preset == PRESET_ABDOMEN:
		_push_abdomen_xray(true)
	else:
		_restore_xray()
	_apply_preset(snap)
	camera_preset_changed.emit(camera_preset)


func fly_to_genitals(snap: bool = false) -> void:
	camera_preset = PRESET_FREE
	_apply_preset(snap)
	camera_preset_changed.emit(camera_preset)


func canal_frame() -> Dictionary:
	if organs == null or not organs.has_method("vagina_canal"):
		return {}
	var d: Dictionary = organs.call("vagina_canal")
	return d if d else {}


func introitus_world() -> Vector3:
	var d := canal_frame()
	if d.has("opening_world"):
		return d["opening_world"]
	return Vector3.ZERO


func cervix_world() -> Vector3:
	var d := canal_frame()
	if d.has("cervix_world"):
		return d["cervix_world"]
	return Vector3.ZERO


func canal_axis_world() -> Vector3:
	var d := canal_frame()
	if d.has("opening_world") and d.has("cervix_world"):
		var a: Vector3 = d["cervix_world"] - d["opening_world"]
		if a.length_squared() > 1e-8:
			return a.normalized()
	if d.has("axis_ab") and organs and organs.get("_frame") != null:
		var xf: Transform3D = organs.get("_frame")
		return (xf.basis * (d["axis_ab"] as Vector3)).normalized()
	return Vector3(0, 1, 0)


func canal_up_world() -> Vector3:
	var axis := canal_axis_world()
	var d := canal_frame()
	var up := Vector3.ZERO
	if d.has("up_ab") and organs and organs.get("_frame") != null:
		var xf: Transform3D = organs.get("_frame")
		up = xf.basis * (d["up_ab"] as Vector3)
		up = up - axis * up.dot(axis)
	if up.length_squared() < 1e-8:
		up = Vector3.UP - axis * Vector3.UP.dot(axis)
	if up.length_squared() < 1e-8:
		up = Vector3(0, 0, 1) - axis * axis.z
	return up.normalized()


func organ_group_center() -> Vector3:
	# 子宫 + 阴道口 + 卵巢，给小腹视角当目标。
	var acc := cervix_world() + introitus_world()
	var n := 2
	if organs and organs.has_method("viscera_meshes"):
		for kind in ["uterus", "ovary"]:
			var arr: Array = organs.call("viscera_meshes", kind)
			for mi in arr:
				if mi is MeshInstance3D and (mi as MeshInstance3D).mesh:
					var xf: Transform3D = (mi as MeshInstance3D).global_transform
					var ab: AABB = (mi as MeshInstance3D).mesh.get_aabb()
					acc += xf * ab.get_center()
					n += 1
	return acc / float(maxi(n, 1))


func camera_alignment_error() -> float:
	# 预设目标方向与当前相机前向的夹角（弧度）。自由视角返回 0。
	if camera_preset == PRESET_FREE:
		return 0.0
	var fwd := _camera_forward()
	var want := _preset_forward()
	if fwd.length_squared() < 1e-8 or want.length_squared() < 1e-8:
		return PI
	return acos(clampf(fwd.normalized().dot(want.normalized()), -1.0, 1.0))


func camera_axis_angle() -> float:
	# 相机前向与阴道轴线的夹角（0 = 平行，π/2 = 垂直）。
	var fwd := _camera_forward()
	var ax := canal_axis_world()
	if fwd.length_squared() < 1e-8 or ax.length_squared() < 1e-8:
		return PI
	return acos(clampf(absf(fwd.normalized().dot(ax.normalized())), 0.0, 1.0))


## 阴道口视角：相机从外口外侧沿轴线看进去。站着时轴线几乎竖直（相机会在两腿之间贴近地面、仰看），
## 改为从前下方斜看进去（仍对准外口、沿通道方向偏 ~45°）。
func _introitus_from() -> Vector3:
	var axis := canal_axis_world()
	if absf(axis.y) > 0.6:
		var f := -axis * 0.62 + canal_up_world() * 0.78
		if f.length_squared() > 1e-8:
			return f.normalized()
	return -axis


func _preset_forward() -> Vector3:
	if camera_preset == PRESET_INTROITUS:
		return -_introitus_from()
	if camera_preset == PRESET_ABDOMEN:
		return -canal_up_world()
	return _camera_forward()


func _camera_forward() -> Vector3:
	if player and player.has_method("get_camera"):
		var cam: Camera3D = player.call("get_camera")
		if cam:
			return -cam.global_transform.basis.z
	return Vector3(0, 0, -1)


func _apply_preset(snap: bool) -> void:
	var t0 := Time.get_ticks_usec()
	var opening := introitus_world()
	var axis := canal_axis_world()
	var up := canal_up_world()
	if opening.length_squared() < 1e-12:
		last_step_usec = int(Time.get_ticks_usec() - t0)
		return
	var target := opening
	var from_target := Vector3(0, 0, 1)
	var dist := 0.62
	if camera_preset == PRESET_INTROITUS:
		# 在外口外侧，沿轴线看进去。
		target = opening + axis * 0.012
		from_target = _introitus_from()
		dist = 0.26
	elif camera_preset == PRESET_ABDOMEN:
		target = organ_group_center()
		from_target = up
		dist = 0.46
	else:
		# 自由视角：以下体（外口略内侧）为中心，斜侧方看过去。
		target = opening.lerp(cervix_world(), 0.35)
		# 站姿（通道近乎竖直）时 -axis 朝下，改成略高于外口的侧前方。
		var ax_k := -0.25 if absf(axis.y) < 0.6 else 0.12
		from_target = (up * 0.55 + axis * ax_k)
		var side := up.cross(axis)
		if side.length_squared() > 1e-8:
			from_target += side.normalized() * 0.80
		if from_target.length_squared() < 1e-8:
			from_target = up
		from_target = from_target.normalized()
		dist = 0.68
	_anchor = target
	if _view_jolt.length_squared() > 1e-8:
		target += _view_jolt
		_view_jolt *= 0.72
		if _view_jolt.length_squared() < 1e-6:
			_view_jolt = Vector3.ZERO
	if player and player.has_method("apply_orbit_pose"):
		player.call("apply_orbit_pose", target, from_target, dist, snap)
	last_step_usec = int(Time.get_ticks_usec() - t0)


func _push_abdomen_xray(on: bool) -> void:
	var org := organs
	if org == null:
		return
	if on:
		if not _xray_pushed:
			_saved_xray = bool(org.get("xray_enabled")) if "xray_enabled" in org else false
			_saved_xray_amount = float(org.call("effective_xray")) if org.has_method("effective_xray") else 0.0
			_xray_pushed = true
			_xray_org = org
			# t99u：会话临时透视只属于这具身体。分身的设置同步会读这里的「用户值」，
			# 不会把临时透视抄到其它角色，也不会把这具分身的临时透视每帧覆盖掉。
			org.set_meta("xray_session", [_saved_xray, float(org.get("xray_amount")) if "xray_amount" in org else _saved_xray_amount])
		if org.has_method("set_xray_enabled"):
			org.call("set_xray_enabled", true)
		if org.has_method("set_xray_amount"):
			org.call("set_xray_amount", maxf(_saved_xray_amount, 0.42))
		if org.has_method("set_xray_sphere_world"):
			org.call("set_xray_sphere_world", organ_group_center(), 0.18, 1.0)
	else:
		_restore_xray()


var _xray_org: Node = null


func _restore_xray() -> void:
	if not _xray_pushed:
		return
	var org := _xray_org if _xray_org != null and is_instance_valid(_xray_org) else organs
	_restore_xray_on(org)


func _restore_xray_on(org: Node) -> void:
	_xray_pushed = false
	_xray_org = null
	if org == null or not is_instance_valid(org):
		return
	var sv: Variant = org.get_meta("xray_session") if org.has_meta("xray_session") else null
	if org.has_meta("xray_session"):
		org.remove_meta("xray_session")
	if org.has_method("clear_xray_sphere"):
		org.call("clear_xray_sphere")
	if org.has_method("set_xray_enabled"):
		org.call("set_xray_enabled", bool(sv[0]) if sv is Array else _saved_xray)
	if org.has_method("set_xray_amount"):
		org.call("set_xray_amount", float(sv[1]) if sv is Array else _saved_xray_amount)


func _process(_delta: float) -> void:
	if not active or player == null:
		return
	if not _session_valid():
		_exit_stale()
		return
	if not _subject_is_player() and not _on_bed():
		exit()
		return
	# 站姿会话：离开观察视角 / 上了载具 / 死亡 → 退出。
	if standing_session and not _standing_ok():
		exit()
		return
	# 姿态跟着蒙皮中线走，预设方向保持，目标随身体。
	if camera_preset != PRESET_FREE:
		_apply_preset(false)
	else:
		var opening := introitus_world()
		if opening.length_squared() > 1e-12 and player.has_method("set_orbit_anchor_world"):
			var a := opening.lerp(cervix_world(), 0.35)
			if _view_jolt.length_squared() > 1e-8:
				a += _view_jolt
				_view_jolt *= 0.72
				if _view_jolt.length_squared() < 1e-6:
					_view_jolt = Vector3.ZERO
			player.call("set_orbit_anchor_world", a)


## 会话的身体已被换走：工具仍拿着旧 OrganRig，先让它在旧身体上收尾（清扩张 / 宫底顶起 / 放开宫颈），
## 透视恢复写回旧身体，然后正常退出。
func _exit_stale() -> void:
	var old_org := _session_organs
	_teardown_controller()
	_teardown_section()
	if _xray_pushed:
		_restore_xray_on(_xray_org if _xray_org != null and is_instance_valid(_xray_org) else old_org)
	exit()
