extends CanvasLayer
## 断面图辅助小窗。默认在选中长柄金属球时于右上角打开。
## 纵向（沿阴道轴线的矢状面）和横向（过球心、垂直轴线的切片），可切换或并排。
## 用第二摄像机 + 剖切面着色器 + 背面填充，直播身体变形，尽量便宜。
class_name CrossSectionView

const CUT_SHADER := preload("res://shaders/section_cut.gdshader")
const CAP_SHADER := preload("res://shaders/section_cap.gdshader")
const SECTION_LAYER := 1 << 18
const MODE_BOTH := "both"
const MODE_LONG := "long"
const MODE_TRANS := "trans"

var mode: Node
var organs: Node
var player: Node
var visible_on := false
var view_mode := MODE_BOTH
var follow_ball := true
var trans_depth := 0.0
var last_step_usec := 0

var _panel: PanelContainer
var _row: HBoxContainer
var _long_vp: SubViewport
var _trans_vp: SubViewport
var _long_box: SubViewportContainer
var _trans_box: SubViewportContainer
var _long_cam: Camera3D
var _trans_cam: Camera3D
var _btn_toggle: Button
var _btn_long: Button
var _btn_trans: Button
var _btn_both: Button
var _copies: Array = []
var _env: Environment
var _built := false


func setup(p_mode: Node, p_organs: Node, p_player: Node) -> void:
	mode = p_mode
	organs = p_organs
	player = p_player
	layer = 20
	_ensure_ui()
	set_process(true)
	set_visible_on(false)


func set_visible_on(on: bool) -> void:
	visible_on = on
	if _panel:
		_panel.visible = on
	_set_copies_visible(on)
	if _btn_toggle:
		_btn_toggle.set_pressed_no_signal(on)
		_style_toggle(_btn_toggle, on)


func toggle() -> void:
	set_visible_on(not visible_on)


func set_view_mode(m: String) -> void:
	if m != MODE_LONG and m != MODE_TRANS and m != MODE_BOTH:
		m = MODE_BOTH
	view_mode = m
	_layout_views()


func longitudinal_plane() -> Plane:
	var pl := _planes()
	return pl["long"]


func transverse_plane() -> Plane:
	var pl := _planes()
	return pl["trans"]


func section_center() -> Vector3:
	return _ball_world()


func _ensure_ui() -> void:
	if _built:
		return
	_built = true
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.12, 0.09, 0.10, 1.0)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.9, 0.88, 0.85)
	_env.ambient_light_energy = 1.0
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	_panel = PanelContainer.new()
	_panel.name = "CrossSectionPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.07, 0.08, 0.92)
	style.border_color = Color(0.2, 0.18, 0.18, 1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	col.add_child(bar)
	var title := Label.new()
	title.text = "断面图"
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.92))
	bar.add_child(title)
	_btn_long = _chip("纵向", func(): set_view_mode(MODE_LONG))
	_btn_trans = _chip("横向", func(): set_view_mode(MODE_TRANS))
	_btn_both = _chip("并排", func(): set_view_mode(MODE_BOTH))
	bar.add_child(_btn_long)
	bar.add_child(_btn_trans)
	bar.add_child(_btn_both)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	col.add_child(_row)
	_long_box = _make_view("LongSection", true)
	_trans_box = _make_view("TransSection", false)
	_row.add_child(_long_box)
	_row.add_child(_trans_box)
	# 挂到 HUD 根上，和其它工具条同一层。
	var hud := _hud()
	var host: Node = hud
	if hud:
		var root := hud.get_node_or_null("Root")
		if root == null:
			for c in hud.get_children():
				if c is Control and c.name.to_lower().find("root") >= 0:
					root = c
					break
		if root:
			host = root
	if host:
		host.add_child(_panel)
	else:
		add_child(_panel)
	_layout_views()
	_rebuild_copies()
	# 工具栏上的开关（若 HUD 还没有，就做一个浮动钮）。
	_ensure_toggle_button()


func _chip(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(48, 24)
	b.pressed.connect(cb)
	return b


func _make_view(nm: String, is_long: bool) -> SubViewportContainer:
	var box := SubViewportContainer.new()
	box.name = nm + "Box"
	box.stretch = true
	box.custom_minimum_size = Vector2(170, 168)
	var vp := SubViewport.new()
	vp.name = nm
	vp.size = Vector2i(170, 168)
	vp.transparent_bg = false
	vp.handle_input_locally = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	# 无头自检不跑第二路 3D 绘制，避免共享主世界时卡住；参数和节点仍创建。
	if DisplayServer.get_name() == "headless":
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	box.add_child(vp)
	var cam := Camera3D.new()
	cam.name = nm + "Cam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.18 if is_long else 0.09
	cam.near = 0.01
	cam.far = 0.8
	cam.cull_mask = SECTION_LAYER
	cam.environment = _env
	cam.current = true
	vp.add_child(cam)
	if is_long:
		_long_vp = vp
		_long_cam = cam
	else:
		_trans_vp = vp
		_trans_cam = cam
	return box


func _hud() -> Node:
	if player:
		var p := player.get_parent()
		if p:
			var h := p.get_node_or_null("HUD")
			if h:
				return h
	return null


func _ensure_toggle_button() -> void:
	var hud := _hud()
	if hud and hud.get("_btn_section") != null:
		_btn_toggle = hud.get("_btn_section")
		return
	_btn_toggle = Button.new()
	_btn_toggle.name = "VaginaSectionToggle"
	_btn_toggle.text = "断面图"
	_btn_toggle.toggle_mode = true
	_btn_toggle.focus_mode = Control.FOCUS_NONE
	_btn_toggle.custom_minimum_size = Vector2(72, 28)
	_btn_toggle.pressed.connect(func(): toggle())
	var hudn := _hud()
	if hudn and hudn.has_method("_make_chrome_button"):
		# 已经用普通按钮；放进面板附近即可，位置由 _process 里跟随右上角。
		pass
	if _panel and _panel.get_parent():
		_panel.get_parent().add_child(_btn_toggle)
	else:
		add_child(_btn_toggle)


func _style_toggle(b: Button, on: bool) -> void:
	if b:
		b.set_pressed_no_signal(on)


func _layout_views() -> void:
	if _long_box:
		_long_box.visible = view_mode == MODE_LONG or view_mode == MODE_BOTH
	if _trans_box:
		_trans_box.visible = view_mode == MODE_TRANS or view_mode == MODE_BOTH
	if _btn_long:
		_btn_long.set_pressed_no_signal(view_mode == MODE_LONG)
	if _btn_trans:
		_btn_trans.set_pressed_no_signal(view_mode == MODE_TRANS)
	if _btn_both:
		_btn_both.set_pressed_no_signal(view_mode == MODE_BOTH)
	var live := DisplayServer.get_name() != "headless"
	if _long_vp:
		_long_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if (live and _long_box and _long_box.visible and visible_on) else SubViewport.UPDATE_DISABLED
	if _trans_vp:
		_trans_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if (live and _trans_box and _trans_box.visible and visible_on) else SubViewport.UPDATE_DISABLED


func _bind_worlds() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var main_vp := get_viewport()
	if main_vp == null and player:
		main_vp = player.get_viewport()
	if main_vp == null:
		return
	var w: World3D = main_vp.world_3d
	if w == null:
		return
	for vp in [_long_vp, _trans_vp]:
		if vp:
			vp.world_3d = w


func _rebuild_copies() -> void:
	_clear_copies()
	if organs == null:
		return
	# 子宫、宫腔、阴道、外阴前庭、金属球。
	if organs.has_method("viscera_meshes"):
		for kind in ["vagina", "uterus", "uterus_cavity"]:
			var arr: Array = organs.call("viscera_meshes", kind)
			for mi in arr:
				if mi is MeshInstance3D:
					_add_copy(mi, _tissue_of(kind, mi))
	if organs.get("vulva") != null:
		var v = organs.vulva
		if v.get("vest_mi") is MeshInstance3D:
			_add_copy(v.vest_mi, 3)
		if v.get("flaps_mi") is MeshInstance3D:
			_add_copy(v.flaps_mi, 0)
	# 0.4.12 子宫脱垂：脱垂柔体子宫（子宫壁）与体外外翻套筒（黏膜，不分层）。
	var pc := _prolapse_ctl()
	if pc:
		var so = pc.call("soft_organ")
		if so is MeshInstance3D:
			_add_copy(so, 4)
			(_copies[_copies.size() - 1] as Dictionary)["no_deform"] = true
		var sl = pc.call("sleeve")
		if sl is MeshInstance3D:
			_add_copy(sl, 3)
			var rec: Dictionary = _copies[_copies.size() - 1]
			rec["no_deform"] = true
			for m in [rec["cut"], rec["cap"]]:
				(m as ShaderMaterial).set_shader_parameter("stylize_layers", 0.0)
	_prol_built = pc != null
	# 金属球（工具节点在 organs 下）。
	var rod := organs.get_node_or_null("BallRod")
	if rod:
		for n in [rod.get_node_or_null("Tip"), rod.get_node_or_null("Shaft")]:
			if n is MeshInstance3D:
				_add_copy(n, 6)
	for rec2 in _copies:
		var sm = rec2["src"]
		rec2["kind"] = str((sm as Node).get_meta("organ_kind", "")) if is_instance_valid(sm) else ""
	_set_copies_visible(visible_on)


var _prol_built := false


func _prolapse_ctl() -> Node:
	if organs == null or not organs.has_method("has_prolapse") or not bool(organs.call("has_prolapse")):
		return null
	return organs.call("prolapse")


## 断面拷贝的脱垂参数：阴道拷贝用和阴道网格同一组 prol_*，其它拷贝关闭。
func _apply_prolapse_uniforms(rec: Dictionary) -> void:
	var u: Dictionary = organs.call("prolapse_uniforms") if organs and organs.has_method("prolapse_uniforms") else {}
	var is_vag := str(rec.get("kind", "")) == "vagina"
	for m in [rec["cut"], rec["cap"]]:
		var sm := m as ShaderMaterial
		if is_vag and not u.is_empty():
			for k in u.keys():
				sm.set_shader_parameter(k, u[k])
		else:
			sm.set_shader_parameter("prol_o", Vector4.ZERO)


func _tissue_of(kind: String, mi: MeshInstance3D) -> int:
	if kind == "uterus_cavity" or bool(mi.get_meta("is_cavity", false)):
		return 5
	if kind == "uterus":
		return 4
	if kind == "vagina":
		return 3
	return 3


func _add_copy(src: MeshInstance3D, tissue: int) -> void:
	if src == null or src.mesh == null:
		return
	var copy := MeshInstance3D.new()
	copy.name = "Section_" + src.name
	copy.mesh = src.mesh
	copy.skin = src.skin
	copy.skeleton = src.skeleton
	copy.layers = SECTION_LAYER
	copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	copy.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var cut := ShaderMaterial.new()
	cut.shader = CUT_SHADER
	cut.set_shader_parameter("tissue", tissue)
	cut.set_shader_parameter("stylize_layers", 1.0 if tissue == 3 else 0.0)
	var cap := ShaderMaterial.new()
	cap.shader = CAP_SHADER
	cap.set_shader_parameter("tissue", tissue)
	cap.set_shader_parameter("stylize_layers", 1.0 if tissue == 3 else 0.0)
	cut.next_pass = cap
	copy.material_override = cut
	src.add_child(copy)
	# 与源网格同骨架、同变换；只给断面摄像机看。骨架路径相对拷贝自己重算（拷贝是源的子节点）。
	if src.skeleton != NodePath():
		var sk := src.get_node_or_null(src.skeleton)
		if sk:
			copy.skeleton = copy.get_path_to(sk)
	_copies.append({"copy": copy, "src": src, "cut": cut, "cap": cap, "tissue": tissue})


func _clear_copies() -> void:
	for rec in _copies:
		var c = rec["copy"]
		if is_instance_valid(c):
			c.queue_free()
	_copies.clear()


func _set_copies_visible(on: bool) -> void:
	for rec in _copies:
		var c = rec["copy"]
		if is_instance_valid(c):
			c.visible = on


func _ball_world() -> Vector3:
	if mode and mode.has_method("tool_controller"):
		var ctl = mode.call("tool_controller")
		if ctl and ctl.has_method("tip_world"):
			return ctl.call("tip_world")
	if organs:
		var rod := organs.get_node_or_null("BallRod")
		if rod is Node3D:
			return (rod as Node3D).global_position
	if mode and mode.has_method("introitus_world"):
		return mode.call("introitus_world")
	return Vector3.ZERO


func _canal() -> Dictionary:
	if mode and mode.has_method("canal_frame"):
		return mode.call("canal_frame")
	if organs and organs.has_method("vagina_canal"):
		return organs.call("vagina_canal")
	return {}


func _planes() -> Dictionary:
	var opening := Vector3.ZERO
	var axis := Vector3(0, 1, 0)
	var up := Vector3.UP
	if mode:
		if mode.has_method("introitus_world"):
			opening = mode.call("introitus_world")
		if mode.has_method("canal_axis_world"):
			axis = mode.call("canal_axis_world")
		if mode.has_method("canal_up_world"):
			up = mode.call("canal_up_world")
	if axis.length_squared() < 1e-8:
		axis = Vector3(0, 1, 0)
	else:
		axis = axis.normalized()
	up = up - axis * up.dot(axis)
	if up.length_squared() < 1e-8:
		up = Vector3.UP - axis * Vector3.UP.dot(axis)
	if up.length_squared() < 1e-8:
		up = Vector3(0, 0, 1)
	up = up.normalized()
	var side := axis.cross(up)
	if side.length_squared() < 1e-8:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	# 纵向：包含轴线和腹侧朝向的平面，法线朝向体侧。
	var long_n := side
	var long_p := opening.lerp(_ball_world(), 0.55)
	# 横向：过球心（或指定深度），法线即轴线。
	var depth := trans_depth
	var tip := _ball_world()
	var trans_p := tip
	var pc := _prolapse_ctl()
	var caught := false
	if mode and mode.has_method("tool_controller"):
		var ctl = mode.call("tool_controller")
		caught = ctl != null and ctl.has_method("is_caught") and bool(ctl.call("is_caught"))
	if pc and not caught:
		# 脱垂中横切面放在外口：看外口被脱出物撑开的一圈。
		trans_p = opening
	if not follow_ball:
		trans_p = opening + axis * depth
	var long_pl := Plane(long_n, long_n.dot(long_p))
	var trans_pl := Plane(axis, axis.dot(trans_p))
	return {
		"long": long_pl,
		"trans": trans_pl,
		"opening": opening,
		"axis": axis,
		"up": up,
		"side": side,
		"long_p": long_p,
		"trans_p": trans_p,
	}


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not visible_on:
		_place_panel()
		last_step_usec = int(Time.get_ticks_usec() - t0)
		return
	_bind_worlds()
	# 工具刚生成时补拷贝；脱垂开始 / 结束时也重建（加上 / 去掉脱垂柔体和套筒）。
	if _copies.is_empty() or not _copies_alive() or _prol_built != (_prolapse_ctl() != null):
		_rebuild_copies()
	var pl := _planes()
	_sync_materials(pl)
	_place_cameras(pl)
	_place_panel()
	last_step_usec = int(Time.get_ticks_usec() - t0)


func _copies_alive() -> bool:
	for rec in _copies:
		if rec["copy"] == null or not is_instance_valid(rec["copy"]):
			return false
	return true


func _sync_materials(pl: Dictionary) -> void:
	# 把活体变形 uniforms 从源材质拷到断面材质，并写入当前剖切面。
	var src_params: ShaderMaterial = null
	if organs and organs.get("_all_mats") is Array and (organs.get("_all_mats") as Array).size() > 0:
		src_params = organs.get("_all_mats")[0]
	var canal := _canal()
	var open_ab: Vector3 = canal.get("opening_ab", Vector3.ZERO)
	var axis_ab: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
	for rec in _copies:
		var cut: ShaderMaterial = rec["cut"]
		var cap: ShaderMaterial = rec["cap"]
		var is_long := true
		# 每个拷贝只有一份材质；两路摄像机会看到同一剖切面。分视口要不同平面，
		# 所以按视口拆成两套拷贝太贵。做法：材质先写纵向，横向视口用第二套拷贝。
		# 为保持便宜，同一套拷贝用当前「主」平面，并排时给两路各备一份过重。
		# 这里用材质的 section_* 只服务一个平面；并排时对每个源做 long/trans 各一份。
		_apply_shared_deform(cut, cap, src_params, bool(rec.get("no_deform", false)))
		_apply_prolapse_uniforms(rec)
		# 默认先写纵向；_ensure_split_copies 会给横向单独的拷贝。
		var plane: Plane = pl["long"] if rec.get("which", "long") == "long" else pl["trans"]
		var pnt: Vector3 = pl["long_p"] if rec.get("which", "long") == "long" else pl["trans_p"]
		for m in [cut, cap]:
			m.set_shader_parameter("section_on", 1.0)
			m.set_shader_parameter("section_point", pnt)
			m.set_shader_parameter("section_normal", plane.normal)
			m.set_shader_parameter("canal_open_ab", open_ab)
			m.set_shader_parameter("canal_axis_ab", axis_ab)
	_ensure_trans_copies(pl, src_params, open_ab, axis_ab)


func _plane_point(pl: Plane) -> Vector3:
	# Godot Plane: ax+by+cz = d, point = normal * d (if normal is unit).
	return pl.normal * pl.d


func _apply_shared_deform(cut: ShaderMaterial, cap: ShaderMaterial, src: ShaderMaterial, frame_only: bool = false) -> void:
	if src == null:
		return
	# frame_only：自带最终形状的网格（脱垂柔体 / 套筒）只要腹部坐标系，不叠加通道 / 宫腔变形。
	var keys: Array = ["ab_navel", "ab_right", "ab_up", "ab_fwd"] if frame_only else ["spec_o", "spec_d", "spec_u", "spec_m", "dilate_o", "dilate_d", "dilate_p", "uter_ball", "uter_ball_p", "ab_navel", "ab_right", "ab_up", "ab_fwd"]
	for key in keys:
		# 名称以 organ_common 实际 uniforms 为准，拷不到就跳过。
		if src.get_shader_parameter(key) != null:
			var v = src.get_shader_parameter(key)
			cut.set_shader_parameter(key, v)
			cap.set_shader_parameter(key, v)


func _ensure_trans_copies(pl: Dictionary, src_params: ShaderMaterial, open_ab: Vector3, axis_ab: Vector3) -> void:
	# 若还没有横向专用拷贝，从纵向拷贝再克隆一份并打 which=trans。
	var has_trans := false
	for rec in _copies:
		if rec.get("which", "long") == "trans":
			has_trans = true
			_write_plane(rec, pl["trans"], pl["trans_p"], src_params, open_ab, axis_ab)
	if has_trans:
		return
	if view_mode == MODE_LONG:
		return
	var extras: Array = []
	for rec in _copies:
		if rec.get("which", "long") != "long":
			continue
		var srcv = rec["src"]
		if not is_instance_valid(srcv):
			continue
		var src: MeshInstance3D = srcv
		var copy := MeshInstance3D.new()
		copy.name = "SectionT_" + src.name
		copy.mesh = src.mesh
		copy.skin = src.skin
		copy.skeleton = src.skeleton
		copy.layers = SECTION_LAYER
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cut := ShaderMaterial.new()
		cut.shader = CUT_SHADER
		cut.set_shader_parameter("tissue", rec["tissue"])
		cut.set_shader_parameter("stylize_layers", 1.0 if int(rec["tissue"]) == 3 else 0.0)
		var cap := ShaderMaterial.new()
		cap.shader = CAP_SHADER
		cap.set_shader_parameter("tissue", rec["tissue"])
		cap.set_shader_parameter("stylize_layers", 1.0 if int(rec["tissue"]) == 3 else 0.0)
		cut.next_pass = cap
		copy.material_override = cut
		src.add_child(copy)
		if src.skeleton != NodePath():
			var sk2 := src.get_node_or_null(src.skeleton)
			if sk2:
				copy.skeleton = copy.get_path_to(sk2)
		if int(rec["tissue"]) == 3 and bool(rec.get("no_deform", false)):
			cut.set_shader_parameter("stylize_layers", 0.0)
			cap.set_shader_parameter("stylize_layers", 0.0)
		var nrec := {"copy": copy, "src": src, "cut": cut, "cap": cap, "tissue": rec["tissue"], "which": "trans", "no_deform": rec.get("no_deform", false), "kind": rec.get("kind", "")}
		extras.append(nrec)
		_write_plane(nrec, pl["trans"], pl["trans_p"], src_params, open_ab, axis_ab)
	for e in extras:
		_copies.append(e)


func _write_plane(rec: Dictionary, plane: Plane, pnt: Vector3, src_params: ShaderMaterial, open_ab: Vector3, axis_ab: Vector3) -> void:
	_apply_shared_deform(rec["cut"], rec["cap"], src_params, bool(rec.get("no_deform", false)))
	_apply_prolapse_uniforms(rec)
	for m in [rec["cut"], rec["cap"]]:
		m.set_shader_parameter("section_on", 1.0)
		m.set_shader_parameter("section_point", pnt)
		m.set_shader_parameter("section_normal", plane.normal)
		m.set_shader_parameter("canal_open_ab", open_ab)
		m.set_shader_parameter("canal_axis_ab", axis_ab)


func _place_cameras(pl: Dictionary) -> void:
	var axis: Vector3 = pl["axis"]
	var up: Vector3 = pl["up"]
	var side: Vector3 = pl["side"]
	# 纵向摄像机沿体侧看向矢状面，正交，看到外口到子宫的整体。
	if _long_cam and (view_mode == MODE_LONG or view_mode == MODE_BOTH):
		var c: Vector3 = pl["long_p"]
		var size := 0.20
		var pc := _prolapse_ctl()
		if pc:
			# 脱垂：框住阴道上端到体外最远的脱出物。
			var opening: Vector3 = pl["opening"]
			var pts: Array = [opening + axis * 0.05, opening]
			for q in pc.call("node_positions"):
				pts.append(q)
			var lo := Vector2(1e9, 1e9)
			var hi := Vector2(-1e9, -1e9)
			var fwd := up.cross(side).normalized()
			for q2 in pts:
				var r := Vector2((q2 - opening).dot(fwd), (q2 - opening).dot(up))
				lo = Vector2(minf(lo.x, r.x), minf(lo.y, r.y))
				hi = Vector2(maxf(hi.x, r.x), maxf(hi.y, r.y))
			var mid := (lo + hi) * 0.5
			c = opening + fwd * mid.x + up * mid.y + side * (c - opening).dot(side)
			size = clampf(maxf(hi.x - lo.x, hi.y - lo.y) * 1.3, 0.20, 0.34)
		var from := side * 0.22
		_long_cam.global_transform = Transform3D(Basis().looking_at(-from, up), c + from)
		_long_cam.size = size
		# 让剖切面朝向摄像机：法线与 from 同向。
	# 横向摄像机沿轴线看向过球的横切面。
	if _trans_cam and (view_mode == MODE_TRANS or view_mode == MODE_BOTH):
		var c2: Vector3 = pl["trans_p"]
		var from2 := -axis * 0.14
		var tup := up
		if absf(from2.normalized().dot(up)) > 0.92:
			tup = side
		_trans_cam.global_transform = Transform3D(Basis().looking_at(-from2, tup), c2 + from2)
		_trans_cam.size = 0.09
	# 两路摄像机都在各自 SubViewport 里，world_3d 已指向主世界。
	# 需要把摄像机放到主世界空间：作为 SubViewport 子节点时 global_transform 仍可设。
	if _long_cam:
		_flip_plane_to_camera(_long_cam, "long")
	if _trans_cam:
		_flip_plane_to_camera(_trans_cam, "trans")


func _flip_plane_to_camera(cam: Camera3D, which: String) -> void:
	# 保证剖切面法线指向相机，裁掉相机这一侧以外的？我们 discard s<0，
	# s = dot(p - point, n)。希望保留「切面靠里」的组织，让切面正对相机。
	# 令 n 指向相机，则相机一侧 s>0 被保留……不对：点在相机一侧 (p-point)·n > 0 若 n 朝相机。
	# 我们想看到切面后面的组织截面，应丢掉相机与切面之间的组织，即丢掉 s>0？
	# 当前 shader 丢掉 s<0。因此 n 应指向被丢掉的一侧 = 远离相机 = -to_cam。
	var pl := _planes()
	var plane: Plane = pl[which]
	var pnt: Vector3 = pl[which + "_p"]
	var to_cam := (cam.global_position - pnt)
	if to_cam.dot(plane.normal) > 0.0:
		# 法线已朝向相机；改成反向，使 s<0 正好是相机这一侧。
		# 在下一帧 _sync 里写 uniforms 前，把平面法线翻过来。
		# 这里直接改材质。
		var want := -plane.normal
		for rec in _copies:
			if rec.get("which", "long") != which:
				continue
			for m in [rec["cut"], rec["cap"]]:
				m.set_shader_parameter("section_normal", want)


func _place_panel() -> void:
	if _panel == null:
		return
	var vp := _panel.get_viewport()
	var vis := vp.get_visible_rect().size if vp else Vector2(1280, 720)
	var w := 360.0 if view_mode == MODE_BOTH else 188.0
	var h := 210.0
	_panel.position = Vector2(vis.x - w - 16.0, 16.0)
	_panel.size = Vector2(w, h)
	if _btn_toggle:
		_btn_toggle.visible = mode != null and bool(mode.call("is_active")) if mode and mode.has_method("is_active") else false
		var tool := str(mode.call("current_tool")) if mode and mode.has_method("current_tool") else ""
		# 只在阴道互动里显示入口；位置在小窗下方或工具栏右侧。
		_btn_toggle.position = Vector2(vis.x - 88.0, (16.0 + h + 8.0) if visible_on else 16.0)
		_btn_toggle.visible = _btn_toggle.visible and (tool == "ball_rod" or visible_on)


func deactivate() -> void:
	set_visible_on(false)
	_clear_copies()
	if _btn_toggle:
		_btn_toggle.visible = false


func _exit_tree() -> void:
	_clear_copies()
	if _panel and is_instance_valid(_panel):
		_panel.queue_free()
	if _btn_toggle and is_instance_valid(_btn_toggle) and _btn_toggle.get_parent() != self:
		_btn_toggle.queue_free()
