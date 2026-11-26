extends CanvasLayer
## 断面图辅助小窗。默认在选中长柄金属球时于右上角打开。
## 纵向：身体正中矢状面（过阴道/子宫轴线，解剖坐标，不跟相机、不跟金属棒）。
## 横向：垂直于通道、过宫颈或球心。
## 平扫（冠状）：含通道轴与左右轴、平行于下腹皮肤，同时切开阴道和子宫。
## 同一平面切开体表、阴道、子宫和金属棒。切面用体内/器官内外测试填充
## （腹腔深粉，宫壁/阴道壁实心，管腔中空）；手臂不投影到断面上。
class_name CrossSectionView

const CUT_SHADER := preload("res://shaders/section_cut.gdshader")
const CAP_SHADER := preload("res://shaders/section_cap.gdshader")
const FILL_SHADER := preload("res://shaders/section_fill.gdshader")
# 15 / 16 未被角色补光、第一人称头、脏器补光占用。18 是 FP_HEAD_LAYER。
# 13 同样空闲（14 是皮肤贴花，17 是角色补光）。
# 主相机第三人称看得到，所以以前的断面拷贝白面会漏进主视图。
const SECTION_LAYER_LONG := 1 << 15
const SECTION_LAYER_TRANS := 1 << 16
const SECTION_LAYER_CORONAL := 1 << 13
const SECTION_LAYER := SECTION_LAYER_LONG | SECTION_LAYER_TRANS | SECTION_LAYER_CORONAL
const MODE_BOTH := "both"
const MODE_LONG := "long"
const MODE_TRANS := "trans"
const MODE_CORONAL := "coronal"

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
var _coronal_vp: SubViewport
var _long_box: SubViewportContainer
var _trans_box: SubViewportContainer
var _coronal_box: SubViewportContainer
var _long_cam: Camera3D
var _trans_cam: Camera3D
var _coronal_cam: Camera3D
var _btn_toggle: Button
var _btn_long: Button
var _btn_trans: Button
var _btn_coronal: Button
var _btn_both: Button
var _copies: Array = []
var _env: Environment
var _built := false
var _test_render := false
var _fill_root: Node3D
var _fills: Dictionary = {} # which -> {mi, mat}


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
	if m != MODE_LONG and m != MODE_TRANS and m != MODE_CORONAL and m != MODE_BOTH:
		m = MODE_BOTH
	view_mode = m
	_layout_views()


func longitudinal_plane() -> Plane:
	var pl := _planes()
	return pl["long"]


func transverse_plane() -> Plane:
	var pl := _planes()
	return pl["trans"]


func coronal_plane() -> Plane:
	var pl := _planes()
	return pl["coronal"]


func section_center() -> Vector3:
	var pl := _planes()
	return pl.get("long_look", pl.get("long_p", _ball_world()))


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
	_btn_coronal = _chip("平扫", func(): set_view_mode(MODE_CORONAL))
	_btn_both = _chip("并排", func(): set_view_mode(MODE_BOTH))
	bar.add_child(_btn_long)
	bar.add_child(_btn_trans)
	bar.add_child(_btn_coronal)
	bar.add_child(_btn_both)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	col.add_child(_row)
	_long_box = _make_view("LongSection", SECTION_LAYER_LONG, 0.18)
	_trans_box = _make_view("TransSection", SECTION_LAYER_TRANS, 0.09)
	_coronal_box = _make_view("CoronalSection", SECTION_LAYER_CORONAL, 0.20)
	_row.add_child(_long_box)
	_row.add_child(_trans_box)
	_row.add_child(_coronal_box)
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
	_isolate_main_cameras()
	# 工具栏上的开关（若 HUD 还没有，就做一个浮动钮）。
	_ensure_toggle_button()


func _chip(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(44, 24)
	b.pressed.connect(cb)
	return b


func _make_view(nm: String, layer_bit: int, cam_size: float) -> SubViewportContainer:
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
	# 无头自检默认不跑第二路 3D 绘制，避免共享主世界时卡住；像素自检可 set_test_render(true)。
	if DisplayServer.get_name() == "headless" and not _test_render:
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	box.add_child(vp)
	var cam := Camera3D.new()
	cam.name = nm + "Cam"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = cam_size
	cam.near = 0.01
	cam.far = 0.8
	cam.cull_mask = layer_bit
	cam.environment = _env
	cam.current = true
	vp.add_child(cam)
	if layer_bit == SECTION_LAYER_LONG:
		_long_vp = vp
		_long_cam = cam
	elif layer_bit == SECTION_LAYER_TRANS:
		_trans_vp = vp
		_trans_cam = cam
	else:
		_coronal_vp = vp
		_coronal_cam = cam
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
	if _coronal_box:
		_coronal_box.visible = view_mode == MODE_CORONAL or view_mode == MODE_BOTH
	if _btn_long:
		_btn_long.set_pressed_no_signal(view_mode == MODE_LONG)
	if _btn_trans:
		_btn_trans.set_pressed_no_signal(view_mode == MODE_TRANS)
	if _btn_coronal:
		_btn_coronal.set_pressed_no_signal(view_mode == MODE_CORONAL)
	if _btn_both:
		_btn_both.set_pressed_no_signal(view_mode == MODE_BOTH)
	var live := DisplayServer.get_name() != "headless" or _test_render
	if _long_vp:
		_long_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if (live and _long_box and _long_box.visible and visible_on) else SubViewport.UPDATE_DISABLED
	if _trans_vp:
		_trans_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if (live and _trans_box and _trans_box.visible and visible_on) else SubViewport.UPDATE_DISABLED
	if _coronal_vp:
		_coronal_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if (live and _coronal_box and _coronal_box.visible and visible_on) else SubViewport.UPDATE_DISABLED


func _bind_worlds() -> void:
	if DisplayServer.get_name() == "headless" and not _test_render:
		return
	var main_vp := get_viewport()
	if main_vp == null and player:
		main_vp = player.get_viewport()
	if main_vp == null:
		return
	var w: World3D = main_vp.world_3d
	if w == null:
		return
	for vp in [_long_vp, _trans_vp, _coronal_vp]:
		if vp:
			vp.world_3d = w


func _rebuild_copies() -> void:
	_clear_copies()
	if organs == null:
		return
	# 同一剖切面切开：体表（躯干皮肤）、阴道、子宫/宫腔、外阴、金属棒。
	if organs.get("skin_meshes") is Array:
		for mi in organs.skin_meshes:
			if mi is MeshInstance3D and not _is_excluded_skin(mi):
				_add_copy(mi, 0, "skin")
	_ensure_fills()
	if organs.has_method("viscera_meshes"):
		for kind in ["vagina", "uterus", "uterus_cavity"]:
			var arr: Array = organs.call("viscera_meshes", kind)
			for mi in arr:
				if mi is MeshInstance3D:
					# 脱垂时原子宫已隐藏，只拷贝可见网格，避免和脱垂模型叠出残缺切面。
					_add_copy(mi, _tissue_of(kind, mi), kind)
	if organs.get("vulva") != null:
		var v = organs.vulva
		if v.get("vest_mi") is MeshInstance3D:
			_add_copy(v.vest_mi, 3, "vestibule")
		if v.get("flaps_mi") is MeshInstance3D:
			_add_copy(v.flaps_mi, 0, "flaps")
	# 0.4.12 子宫脱垂：脱垂柔体子宫（子宫壁）。套筒接口已移除，保留兼容调用。
	var pc := _prolapse_ctl()
	if pc:
		var so = pc.call("soft_organ")
		if so is MeshInstance3D:
			_add_copy(so, 4, "prolapse_uterus")
			(_copies[_copies.size() - 1] as Dictionary)["no_deform"] = true
		var sl = pc.call("sleeve")
		if sl is MeshInstance3D:
			_add_copy(sl, 3, "sleeve")
			var rec: Dictionary = _copies[_copies.size() - 1]
			rec["no_deform"] = true
			for m in [rec["cut"], rec["cap"]]:
				(m as ShaderMaterial).set_shader_parameter("stylize_layers", 0.0)
	_prol_built = pc != null
	# 金属棒（刚体，不套器官变形；随源节点每帧变换，剖切面不跟着棒走）。
	var rod := organs.get_node_or_null("BallRod")
	if rod:
		for n in [rod.get_node_or_null("Tip"), rod.get_node_or_null("Shaft")]:
			if n is MeshInstance3D:
				_add_copy(n, 6, "rod")
				(_copies[_copies.size() - 1] as Dictionary)["no_deform"] = true
	for rec2 in _copies:
		var sm = rec2["src"]
		if str(rec2.get("kind", "")) == "":
			rec2["kind"] = str((sm as Node).get_meta("organ_kind", "")) if is_instance_valid(sm) else ""
	_set_copies_visible(visible_on)


var _prol_built := false


func _prolapse_ctl() -> Node:
	if organs == null or not organs.has_method("has_prolapse") or not bool(organs.call("has_prolapse")):
		return null
	return organs.call("prolapse")


var _iso_done := false


func _isolate_main_cameras() -> void:
	# 从所有非断面摄像机清掉 15/16 层，主视图就不会画到断面拷贝的白切面。
	var hide := SECTION_LAYER_LONG | SECTION_LAYER_TRANS | SECTION_LAYER_CORONAL
	if _iso_done and player and player.has_method("get_camera"):
		var cam0 = player.get_camera()
		if cam0 is Camera3D and (int(cam0.cull_mask) & hide) == 0:
			return
	_iso_done = true
	if player and player.has_method("get_camera"):
		var cam = player.get_camera()
		if cam is Camera3D:
			cam.cull_mask = cam.cull_mask & ~hide
	var vp: Viewport = null
	if player:
		vp = player.get_viewport()
	if vp == null:
		vp = get_viewport()
	if vp:
		var cam2 := vp.get_camera_3d()
		if cam2 and cam2 != _long_cam and cam2 != _trans_cam and cam2 != _coronal_cam:
			cam2.cull_mask = cam2.cull_mask & ~hide


func debug_isolation() -> Dictionary:
	var hide := SECTION_LAYER_LONG | SECTION_LAYER_TRANS | SECTION_LAYER_CORONAL
	var main_mask := 0
	if player and player.has_method("get_camera"):
		var cam = player.get_camera()
		if cam is Camera3D:
			main_mask = int(cam.cull_mask)
	var src_section_on := 0.0
	var shared := 0
	var long_n := 0
	var trans_n := 0
	var unique := 0
	for rec in _copies:
		var copy = rec.get("copy")
		var src = rec.get("src")
		var cut = rec.get("cut")
		if rec.get("which", "long") == "trans":
			trans_n += 1
		else:
			long_n += 1
		if cut is ShaderMaterial:
			unique += 1
		if src is MeshInstance3D:
			var mat = (src as MeshInstance3D).material_override
			if mat != null and mat == cut:
				shared += 1
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader != CUT_SHADER and (mat as ShaderMaterial).shader != CAP_SHADER:
				var on = (mat as ShaderMaterial).get_shader_parameter("section_on")
				if on != null:
					src_section_on = maxf(src_section_on, float(on))
			# 源材质即使没有 section_on 也算隔离成功（默认 0）。
	return {
		"long_layer": SECTION_LAYER_LONG,
		"trans_layer": SECTION_LAYER_TRANS,
		"main_mask": main_mask,
		"main_sees_section": (main_mask & hide) != 0,
		"long_cam_mask": int(_long_cam.cull_mask) if _long_cam else 0,
		"trans_cam_mask": int(_trans_cam.cull_mask) if _trans_cam else 0,
		"coronal_cam_mask": int(_coronal_cam.cull_mask) if _coronal_cam else 0,
		"coronal_layer": SECTION_LAYER_CORONAL,
		"long_copies": long_n,
		"trans_copies": trans_n,
		"unique_materials": unique,
		"shared_source_material": shared,
		"source_section_on": src_section_on,
		"layers_distinct": _long_cam != null and _trans_cam != null and _coronal_cam != null and (_long_cam.cull_mask & _trans_cam.cull_mask) == 0 and (_long_cam.cull_mask & _coronal_cam.cull_mask) == 0 and (_trans_cam.cull_mask & _coronal_cam.cull_mask) == 0,
	}


## 断面拷贝的脱垂参数：阴道拷贝用和阴道网格同一组 prol_*，其它拷贝关闭。
func debug_section_state() -> Dictionary:
	var pl := _planes()
	var long_pl: Plane = pl["long"]
	var trans_pl: Plane = pl["trans"]
	var kinds := PackedStringArray()
	var rod_n := 0
	var skin_n := 0
	var uter_n := 0
	var vag_n := 0
	for rec in _copies:
		var k := str(rec.get("kind", ""))
		if not (k in kinds):
			kinds.append(k)
		if k == "rod":
			rod_n += 1
		elif k == "skin":
			skin_n += 1
		elif k == "uterus" or k == "uterus_cavity" or k == "prolapse_uterus":
			uter_n += 1
		elif k == "vagina":
			vag_n += 1
	var coronal_pl: Plane = pl["coronal"]
	var long_look_dot := 0.0
	var trans_look_dot := 0.0
	var coronal_look_dot := 0.0
	if _long_cam:
		long_look_dot = absf((-_long_cam.global_transform.basis.z).normalized().dot(long_pl.normal.normalized()))
	if _trans_cam:
		trans_look_dot = absf((-_trans_cam.global_transform.basis.z).normalized().dot(trans_pl.normal.normalized()))
	if _coronal_cam:
		coronal_look_dot = absf((-_coronal_cam.global_transform.basis.z).normalized().dot(coronal_pl.normal.normalized()))
	var limbs: Array = organs.call("limb_exclusion_capsules_world") if organs and organs.has_method("limb_exclusion_capsules_world") else []
	return {
		"long_normal": long_pl.normal,
		"trans_normal": trans_pl.normal,
		"coronal_normal": coronal_pl.normal,
		"long_p": pl["long_p"],
		"long_look": pl.get("long_look", pl["long_p"]),
		"trans_p": pl["trans_p"],
		"coronal_p": pl.get("coronal_p", pl["long_look"]),
		"opening": pl["opening"],
		"cervix": pl.get("cervix", Vector3.ZERO),
		"axis": pl["axis"],
		"side": pl["side"],
		"long_dist_opening": absf(long_pl.distance_to(pl["opening"])),
		"long_dist_cervix": absf(long_pl.distance_to(pl.get("cervix", pl["opening"]))),
		"long_cam_along_normal": long_look_dot,
		"trans_cam_along_normal": trans_look_dot,
		"coronal_cam_along_normal": coronal_look_dot,
		"limb_capsules": limbs.size(),
		"hands_excluded": true,
		"kinds": kinds,
		"rod_copies": rod_n,
		"skin_copies": skin_n,
		"uterus_copies": uter_n,
		"vagina_copies": vag_n,
		"copy_count": _copies.size(),
	}


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


func _cap_thickness_for(tissue: int, kind: String) -> float:
	# 平切填充厚度：薄壁只填切口一圈，实心金属棒要盖过球体半径（最大 16 mm）。
	if tissue == 6 or kind == "rod":
		return 0.040
	if tissue == 4 or kind == "prolapse_uterus" or kind == "uterus":
		return 0.020
	if tissue == 5 or kind == "uterus_cavity":
		return 0.014
	if kind == "skin":
		return 0.008
	if tissue == 3:
		return 0.018
	return 0.010


func _add_copy(src: MeshInstance3D, tissue: int, kind: String = "") -> void:
	if src == null or src.mesh == null:
		return
	if src.name.begins_with("Section_") or src.name.begins_with("SectionT_") or src.name.begins_with("SectionC_") or src.name.begins_with("SectionFill"):
		return
	# 已为该源建过纵向拷贝则跳过。
	for rec0 in _copies:
		if rec0.get("src") == src and rec0.get("which", "long") == "long":
			return
	var copy := MeshInstance3D.new()
	copy.name = "Section_" + src.name
	copy.mesh = src.mesh
	copy.skin = src.skin
	copy.skeleton = src.skeleton
	copy.layers = SECTION_LAYER_LONG
	copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	copy.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var thick := _cap_thickness_for(tissue, kind)
	var cut := ShaderMaterial.new()
	cut.shader = CUT_SHADER
	cut.set_shader_parameter("tissue", tissue)
	# 纵向切面用平涂；横向阴道环仍可分层。
	cut.set_shader_parameter("stylize_layers", 0.0)
	cut.set_shader_parameter("cap_thickness", thick)
	var cap := ShaderMaterial.new()
	cap.shader = CAP_SHADER
	cap.set_shader_parameter("tissue", tissue)
	cap.set_shader_parameter("stylize_layers", 0.0)
	cap.set_shader_parameter("cap_thickness", thick)
	if kind == "skin":
		cut.set_shader_parameter("exclude_limbs", 1.0)
		cap.set_shader_parameter("exclude_limbs", 1.0)
	cut.next_pass = cap
	copy.material_override = cut
	src.add_child(copy)
	# 与源网格同骨架、同变换；只给断面摄像机看。骨架路径相对拷贝自己重算（拷贝是源的子节点）。
	if src.skeleton != NodePath():
		var sk := src.get_node_or_null(src.skeleton)
		if sk:
			copy.skeleton = copy.get_path_to(sk)
	var rec_new := {"copy": copy, "src": src, "cut": cut, "cap": cap, "tissue": tissue, "kind": kind}
	if kind == "rod" or kind == "prolapse_uterus" or kind == "sleeve":
		rec_new["no_deform"] = true
	_copies.append(rec_new)


func _clear_copies() -> void:
	for rec in _copies:
		var c = rec["copy"]
		if is_instance_valid(c):
			c.queue_free()
	_copies.clear()


func _set_copies_visible(on: bool) -> void:
	for rec in _copies:
		var c = rec["copy"]
		var src = rec.get("src")
		if not is_instance_valid(c):
			continue
		# 源被隐藏（例如脱垂时的原子宫）时，断面拷贝也关掉，避免切不全的残片。
		var src_on := true
		if is_instance_valid(src) and src is Node3D:
			src_on = (src as Node3D).visible
		c.visible = on and src_on
	for k in _fills.keys():
		var recf: Dictionary = _fills[k]
		var mi = recf.get("mi")
		if is_instance_valid(mi):
			mi.visible = on


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
	var cervix := Vector3.ZERO
	if mode:
		if mode.has_method("introitus_world"):
			opening = mode.call("introitus_world")
		if mode.has_method("canal_axis_world"):
			axis = mode.call("canal_axis_world")
		if mode.has_method("canal_up_world"):
			up = mode.call("canal_up_world")
		if mode.has_method("cervix_world"):
			cervix = mode.call("cervix_world")
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
	# 纵向：身体正中矢状面。过通道/子宫轴线，法线为体侧（axis × 腹侧）。
	# 锚在解剖轴线上（外口在轴上），不跟金属棒、不跟相机。棒离面时平面不动。
	var long_n := side
	var long_p := opening
	var long_look := opening
	if cervix.length_squared() > 1e-12:
		long_look = opening.lerp(cervix, 0.55)
	else:
		long_look = opening + axis * 0.08
	# 投影回正中面（宫颈本应在轴上；即使稍偏也不把平面带走）。
	long_look = long_look - long_n * long_n.dot(long_look - opening)
	# 横向：垂直于通道。有球且跟随球时过球心（v0419）；否则过宫颈。
	var depth := trans_depth
	var tip := _ball_world()
	var trans_p := tip
	var pc := _prolapse_ctl()
	var caught := false
	if mode and mode.has_method("tool_controller"):
		var ctl = mode.call("tool_controller")
		caught = ctl != null and ctl.has_method("is_caught") and bool(ctl.call("is_caught"))
	if not follow_ball:
		trans_p = opening + axis * depth
	elif pc and not caught:
		# 脱垂且球已脱出：横切面放在宫颈（脱出子宫的颈口），不再钉在外口。
		if pc.has_method("cervix_world"):
			trans_p = pc.call("cervix_world")
		elif cervix.length_squared() > 1e-12:
			trans_p = cervix
		else:
			trans_p = opening
	else:
		trans_p = tip
	var long_pl := Plane(long_n, long_n.dot(long_p))
	var trans_pl := Plane(axis, axis.dot(trans_p))
	# 平扫 / 冠状：面内含通道轴与左右轴，平行于下腹皮肤，过宫颈（从而同时切开阴道与子宫）。
	var cor_n := up
	var cor_p := cervix if cervix.length_squared() > 1e-12 else (opening + axis * 0.06)
	# 投影到轴线上，避免轻微侧偏带走平面。
	var axis_origin := opening
	cor_p = axis_origin + axis * (cor_p - axis_origin).dot(axis)
	var cor_look := opening.lerp(cor_p, 0.55)
	if cervix.length_squared() > 1e-12:
		cor_look = opening.lerp(cervix, 0.62)
	var cor_pl := Plane(cor_n, cor_n.dot(cor_p))
	return {
		"long": long_pl,
		"trans": trans_pl,
		"coronal": cor_pl,
		"opening": opening,
		"cervix": cervix,
		"axis": axis,
		"up": up,
		"side": side,
		"long_p": long_p,
		"long_look": long_look,
		"trans_p": trans_p,
		"coronal_p": cor_p,
		"coronal_look": cor_look,
	}


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not visible_on:
		_place_panel()
		last_step_usec = int(Time.get_ticks_usec() - t0)
		return
	_bind_worlds()
	_isolate_main_cameras()
	# 工具刚生成时补拷贝；脱垂开始 / 结束时也重建（加上 / 去掉脱垂柔体和套筒）。
	if _copies.is_empty() or not _copies_alive() or _prol_built != (_prolapse_ctl() != null) or _copies_stale():
		_rebuild_copies()
	var pl := _planes()
	_sync_materials(pl)
	_set_copies_visible(true)
	_place_cameras(pl)
	_place_panel()
	last_step_usec = int(Time.get_ticks_usec() - t0)


func _copies_alive() -> bool:
	for rec in _copies:
		if rec["copy"] == null or not is_instance_valid(rec["copy"]):
			return false
	return true


func _copies_stale() -> bool:
	# 体表或金属棒晚于首次建拷贝才出现时，补进同一剖切面。
	var has_skin := false
	var has_rod := false
	for rec in _copies:
		if str(rec.get("kind", "")) == "skin":
			has_skin = true
		elif str(rec.get("kind", "")) == "rod":
			has_rod = true
	if organs and organs.get("skin_meshes") is Array and (organs.skin_meshes as Array).size() > 0 and not has_skin:
		return true
	if organs and organs.get_node_or_null("BallRod") != null and not has_rod:
		return true
	return false


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
		_apply_shared_deform(cut, cap, src_params, rec)
		_apply_prolapse_uniforms(rec)
		# 默认先写纵向；_ensure_split_copies 会给横向单独的拷贝。
		var which := str(rec.get("which", "long"))
		var plane: Plane = pl["long"]
		var pnt: Vector3 = pl["long_p"]
		if which == "trans":
			plane = pl["trans"]
			pnt = pl["trans_p"]
		elif which == "coronal":
			plane = pl["coronal"]
			pnt = pl["coronal_p"]
		for m in [cut, cap]:
			m.set_shader_parameter("section_on", 1.0)
			m.set_shader_parameter("section_point", pnt)
			m.set_shader_parameter("section_normal", plane.normal)
			m.set_shader_parameter("canal_open_ab", open_ab)
			m.set_shader_parameter("canal_axis_ab", axis_ab)
		_write_limb_exclusion(cut, cap, rec)
	_ensure_trans_copies(pl, src_params, open_ab, axis_ab)
	_ensure_coronal_copies(pl, src_params, open_ab, axis_ab)
	_sync_fills(pl)


func _plane_point(pl: Plane) -> Vector3:
	# Godot Plane: ax+by+cz = d, point = normal * d (if normal is unit).
	return pl.normal * pl.d


func _deform_keys(rec: Dictionary) -> Array:
	var keys: Array = ["ab_navel", "ab_right", "ab_up", "ab_fwd"]
	if bool(rec.get("no_deform", false)):
		return keys
	if str(rec.get("kind", "")) == "skin":
		# 体表与皮肤着色器一致：骨骼蒙皮已随源网格，这里只补打击/拖拽/按压，不套通道扩张。
		return ["drag_grab", "drag_off", "drag_radius", "dent", "dent_off", "ab_navel", "ab_right", "ab_up", "ab_fwd"]
	return [
		"spec_o", "spec_d", "spec_u", "spec_m",
		"dilate_o", "dilate_d", "dilate_p", "dilate_lat",
		"uter_ball", "uter_ball_p",
		"stir_off", "stir_p",
		"uter_str", "uter_str_pivot", "uter_str_from", "uter_str_to", "uter_str_len",
		"fundus_lift", "fundus_open_ab", "fundus_cerv_ab", "fundus_axis_ab",
		"canal_stretch_on", "canal_os_rest", "canal_os_now", "canal_open_rest",
		"drag_grab", "drag_off", "drag_radius", "dent", "dent_off",
		"ab_navel", "ab_right", "ab_up", "ab_fwd",
	]


func _apply_shared_deform(cut: ShaderMaterial, cap: ShaderMaterial, src: ShaderMaterial, rec: Dictionary = {}) -> void:
	if src == null:
		return
	for key in _deform_keys(rec):
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
		copy.layers = SECTION_LAYER_TRANS
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cut := ShaderMaterial.new()
		cut.shader = CUT_SHADER
		cut.set_shader_parameter("tissue", rec["tissue"])
		cut.set_shader_parameter("stylize_layers", 1.0 if int(rec["tissue"]) == 3 and not bool(rec.get("no_deform", false)) else 0.0)
		var cap := ShaderMaterial.new()
		cap.shader = CAP_SHADER
		cap.set_shader_parameter("tissue", rec["tissue"])
		cap.set_shader_parameter("stylize_layers", 0.0)
		var thick := _cap_thickness_for(int(rec["tissue"]), str(rec.get("kind", "")))
		cut.set_shader_parameter("cap_thickness", thick)
		cap.set_shader_parameter("cap_thickness", thick)
		if str(rec.get("kind", "")) == "skin":
			cut.set_shader_parameter("exclude_limbs", 1.0)
			cap.set_shader_parameter("exclude_limbs", 1.0)
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


func _ensure_coronal_copies(pl: Dictionary, src_params: ShaderMaterial, open_ab: Vector3, axis_ab: Vector3) -> void:
	var has_c := false
	for rec in _copies:
		if rec.get("which", "long") == "coronal":
			has_c = true
			_write_plane(rec, pl["coronal"], pl["coronal_p"], src_params, open_ab, axis_ab)
	if has_c:
		return
	if view_mode != MODE_CORONAL and view_mode != MODE_BOTH:
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
		copy.name = "SectionC_" + src.name
		copy.mesh = src.mesh
		copy.skin = src.skin
		copy.skeleton = src.skeleton
		copy.layers = SECTION_LAYER_CORONAL
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cut := ShaderMaterial.new()
		cut.shader = CUT_SHADER
		cut.set_shader_parameter("tissue", rec["tissue"])
		cut.set_shader_parameter("stylize_layers", 0.0)
		var cap := ShaderMaterial.new()
		cap.shader = CAP_SHADER
		cap.set_shader_parameter("tissue", rec["tissue"])
		cap.set_shader_parameter("stylize_layers", 0.0)
		var thick := _cap_thickness_for(int(rec["tissue"]), str(rec.get("kind", "")))
		cut.set_shader_parameter("cap_thickness", thick)
		cap.set_shader_parameter("cap_thickness", thick)
		if str(rec.get("kind", "")) == "skin":
			cut.set_shader_parameter("exclude_limbs", 1.0)
			cap.set_shader_parameter("exclude_limbs", 1.0)
		cut.next_pass = cap
		copy.material_override = cut
		src.add_child(copy)
		if src.skeleton != NodePath():
			var sk3 := src.get_node_or_null(src.skeleton)
			if sk3:
				copy.skeleton = copy.get_path_to(sk3)
		var nrec := {"copy": copy, "src": src, "cut": cut, "cap": cap, "tissue": rec["tissue"], "which": "coronal", "no_deform": rec.get("no_deform", false), "kind": rec.get("kind", "")}
		extras.append(nrec)
		_write_plane(nrec, pl["coronal"], pl["coronal_p"], src_params, open_ab, axis_ab)
	for e in extras:
		_copies.append(e)


func _write_plane(rec: Dictionary, plane: Plane, pnt: Vector3, src_params: ShaderMaterial, open_ab: Vector3, axis_ab: Vector3) -> void:
	_apply_shared_deform(rec["cut"], rec["cap"], src_params, rec)
	_apply_prolapse_uniforms(rec)
	for m in [rec["cut"], rec["cap"]]:
		m.set_shader_parameter("section_on", 1.0)
		m.set_shader_parameter("section_point", pnt)
		m.set_shader_parameter("section_normal", plane.normal)
		m.set_shader_parameter("canal_open_ab", open_ab)
		m.set_shader_parameter("canal_axis_ab", axis_ab)
	_write_limb_exclusion(rec["cut"], rec["cap"], rec)


func _place_cameras(pl: Dictionary) -> void:
	var axis: Vector3 = pl["axis"]
	var up: Vector3 = pl["up"]
	var side: Vector3 = pl["side"]
	# 纵向正交摄像机沿正中面法线（体侧）正对切面，注视轴线上的点，不跟离面的球走。
	if _long_cam and (view_mode == MODE_LONG or view_mode == MODE_BOTH):
		var c: Vector3 = pl.get("long_look", pl["long_p"])
		var size := 0.22
		var pc := _prolapse_ctl()
		if pc:
			# 脱垂：框住阴道上端到体外最远的脱出物，注视点锁在正中面上。
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
			c = opening + fwd * mid.x + up * mid.y
			size = clampf(maxf(hi.x - lo.x, hi.y - lo.y) * 1.3, 0.20, 0.34)
		var from := side * 0.22
		_long_cam.global_transform = Transform3D(Basis().looking_at(-from, up), c + from)
		_long_cam.size = size
	# 横向正交摄像机沿通道轴线正对横切面。
	if _trans_cam and (view_mode == MODE_TRANS or view_mode == MODE_BOTH):
		var c2: Vector3 = pl["trans_p"]
		var from2 := -axis * 0.14
		var tup := up
		if absf(from2.normalized().dot(up)) > 0.92:
			tup = side
		_trans_cam.global_transform = Transform3D(Basis().looking_at(-from2, tup), c2 + from2)
		_trans_cam.size = 0.09
	# 平扫正交摄像机沿腹侧法线正对冠状切面，框住外口到子宫。
	if _coronal_cam and (view_mode == MODE_CORONAL or view_mode == MODE_BOTH):
		var c3: Vector3 = pl.get("coronal_look", pl["coronal_p"])
		var from3 := up * 0.22
		var cup := axis
		if absf(from3.normalized().dot(axis)) > 0.92:
			cup = side
		_coronal_cam.global_transform = Transform3D(Basis().looking_at(-from3, cup), c3 + from3)
		_coronal_cam.size = 0.22
	# 各路摄像机都在各自 SubViewport 里，world_3d 已指向主世界。
	if _long_cam:
		_flip_plane_to_camera(_long_cam, "long")
	if _trans_cam:
		_flip_plane_to_camera(_trans_cam, "trans")
	if _coronal_cam:
		_flip_plane_to_camera(_coronal_cam, "coronal")


func _flip_plane_to_camera(cam: Camera3D, which: String) -> void:
	# 平面位置保持解剖位置；这里只选定裁剪朝向：着色器丢掉 s<0，
	# 所以法线指向被丢掉的一侧 = 相机这一侧的反方向，切面正对正交相机。
	var pl := _planes()
	var pnt: Vector3 = pl["long_look"]
	if which == "trans":
		pnt = pl["trans_p"]
	elif which == "coronal":
		pnt = pl.get("coronal_look", pl["coronal_p"])
	var to_cam := cam.global_position - pnt
	if to_cam.length_squared() < 1e-10:
		return
	var want := -to_cam.normalized()
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
	var nviews := 3 if view_mode == MODE_BOTH else 1
	var w := 188.0 if nviews == 1 else 546.0
	var h := 210.0
	_panel.position = Vector2(vis.x - w - 16.0, 16.0)
	_panel.size = Vector2(w, h)
	if _btn_toggle:
		_btn_toggle.visible = mode != null and bool(mode.call("is_active")) if mode and mode.has_method("is_active") else false
		var tool := str(mode.call("current_tool")) if mode and mode.has_method("current_tool") else ""
		# 只在阴道互动里显示入口；位置在小窗下方或工具栏右侧。
		_btn_toggle.position = Vector2(vis.x - 88.0, (16.0 + h + 8.0) if visible_on else 16.0)
		_btn_toggle.visible = _btn_toggle.visible and (tool == "ball_rod" or visible_on)



func _is_excluded_skin(mi: MeshInstance3D) -> bool:
	if mi == null:
		return true
	var low := mi.name.to_lower()
	if "fistarm" in low or low == "fistarm":
		return true
	for k in ["hand", "finger", "forearm", "wrist", "thumb", "index", "middle", "ring", "little", "pinky"]:
		if k in low:
			return true
	return false


func _write_limb_exclusion(cut: ShaderMaterial, cap: ShaderMaterial, rec: Dictionary) -> void:
	if str(rec.get("kind", "")) != "skin":
		return
	var caps: Array = organs.call("limb_exclusion_capsules_world") if organs and organs.has_method("limb_exclusion_capsules_world") else []
	var n := mini(caps.size(), 8)
	var a := PackedVector3Array()
	var b := PackedVector3Array()
	var r := PackedFloat32Array()
	a.resize(8)
	b.resize(8)
	r.resize(8)
	for i in 8:
		if i < n:
			a[i] = caps[i]["a"]
			b[i] = caps[i]["b"]
			r[i] = float(caps[i]["r"])
		else:
			a[i] = Vector3.ZERO
			b[i] = Vector3.ZERO
			r[i] = 0.0
	for m2 in [cut, cap]:
		m2.set_shader_parameter("exclude_limbs", 1.0)
		m2.set_shader_parameter("limb_a", a)
		m2.set_shader_parameter("limb_b", b)
		m2.set_shader_parameter("limb_r", r)
		m2.set_shader_parameter("limb_count", n)


func _basis_facing_plane(n: Vector3, up: Vector3) -> Basis:
	# QuadMesh 在 XY 平面，正面朝 +Z，让 +Z 指向相机（-n；n 已是背离相机的切面法线）。
	var z := -n
	if z.length_squared() < 1e-12:
		z = Vector3(0, 0, 1)
	else:
		z = z.normalized()
	var y := up - z * up.dot(z)
	if y.length_squared() < 1e-8:
		y = Vector3.UP - z * Vector3.UP.dot(z)
	if y.length_squared() < 1e-8:
		y = Vector3.RIGHT - z * Vector3.RIGHT.dot(z)
	y = y.normalized()
	var x := y.cross(z).normalized()
	y = z.cross(x).normalized()
	return Basis(x, y, z)


func _ensure_fills() -> void:
	if _fill_root == null or not is_instance_valid(_fill_root):
		_fill_root = Node3D.new()
		_fill_root.name = "SectionFills"
		if organs:
			organs.add_child(_fill_root)
		else:
			add_child(_fill_root)
	for rec in [
		{"which": "long", "layer": SECTION_LAYER_LONG},
		{"which": "trans", "layer": SECTION_LAYER_TRANS},
		{"which": "coronal", "layer": SECTION_LAYER_CORONAL},
	]:
		var w := str(rec["which"])
		if _fills.has(w) and is_instance_valid(_fills[w].get("mi")):
			continue
		var mi := MeshInstance3D.new()
		mi.name = "SectionFill_" + w
		var q := QuadMesh.new()
		q.size = Vector2(0.80, 0.80)
		mi.mesh = q
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.layers = int(rec["layer"])
		var mat := ShaderMaterial.new()
		mat.shader = FILL_SHADER
		mat.render_priority = 2
		mi.material_override = mat
		_fill_root.add_child(mi)
		_fills[w] = {"mi": mi, "mat": mat}


func _sync_fills(pl: Dictionary) -> void:
	_ensure_fills()
	var canal := _canal()
	var open_ab: Vector3 = canal.get("opening_ab", Vector3.ZERO)
	var axis_ab: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
	var cerv_ab: Vector3 = canal.get("cervix_ab", open_ab + axis_ab * 0.05)
	var shape: Dictionary = organs.call("uterus_section_shape") if organs and organs.has_method("uterus_section_shape") else {}
	var prof: Dictionary = organs.call("section_profile_params") if organs and organs.has_method("section_profile_params") else {}
	var xf: Transform3D = organs.call("abdomen_frame") if organs and organs.has_method("abdomen_frame") else Transform3D.IDENTITY
	# 腹部基（给 fill 着色器 to_ab 用）从源材质拷。
	var src: ShaderMaterial = null
	if organs and organs.get("_all_mats") is Array and (organs.get("_all_mats") as Array).size() > 0:
		src = organs.get("_all_mats")[0]
	var vag_lumen := 0.007
	if organs and organs.has_method("canal_dilate_radius_at"):
		var mid_s := open_ab.distance_to(cerv_ab) * 0.45
		vag_lumen = maxf(0.005, float(organs.call("canal_dilate_radius_at", mid_s)) - 0.006)
	var rod_tip := _ball_world()
	var rod_r := 0.0
	var rod_ax: Vector3 = pl["axis"]
	if mode and mode.has_method("tool_controller"):
		var ctl = mode.call("tool_controller")
		if ctl and ctl.has_method("radius"):
			rod_r = float(ctl.call("radius"))
			if ctl.has_method("tip_world"):
				rod_tip = ctl.call("tip_world")
		if ctl and ctl.get("_root") is Node3D:
			rod_ax = (ctl.get("_root") as Node3D).global_transform.basis.z
	var uter_ax: Vector3 = shape.get("axis_ab", axis_ab)
	if uter_ax.length_squared() < 1e-10:
		uter_ax = axis_ab
	var lift := 0.0
	if organs and organs.has_method("fundus_lift"):
		lift = float(organs.call("fundus_lift"))
	var map := {
		"long": [pl["long"], pl.get("long_look", pl["long_p"]), _long_cam],
		"trans": [pl["trans"], pl["trans_p"], _trans_cam],
		"coronal": [pl["coronal"], pl.get("coronal_look", pl["coronal_p"]), _coronal_cam],
	}
	for w in map.keys():
		if not _fills.has(w):
			continue
		var rec: Dictionary = _fills[w]
		var mi: MeshInstance3D = rec["mi"]
		var mat: ShaderMaterial = rec["mat"]
		if not is_instance_valid(mi):
			continue
		var plane: Plane = map[w][0]
		var pnt: Vector3 = map[w][1]
		var cam: Camera3D = map[w][2]
		var n := plane.normal.normalized()
		if cam:
			var to_cam: Vector3 = cam.global_position - pnt
			if to_cam.length_squared() > 1e-10:
				n = -to_cam.normalized()
		# 四边形必须铺在剖切面上。Basis.looking_at(世界点) 会按「从原点看向该点」旋转，
		# 切面四边形会斜着立在阴道中央，看起来像一条斜矩形（t87u）。按法线搭正交基。
		# 再沿视线往相机挪 2 mm，盖住切面破洞，背景不再透出黑色。
		var pos := pnt - n * 0.002
		var up: Vector3 = pl["up"]
		if absf(n.dot(up)) > 0.92:
			up = pl["axis"]
		mi.global_transform = Transform3D(_basis_facing_plane(n, up), pos)
		if cam:
			var half := maxf(cam.size * 1.7, 0.28)
			(mi.mesh as QuadMesh).size = Vector2(half * 2.0 * (170.0 / 168.0), half * 2.0)
		var vis: bool = (w == "long" and (view_mode == MODE_LONG or view_mode == MODE_BOTH))
		vis = vis or (w == "trans" and (view_mode == MODE_TRANS or view_mode == MODE_BOTH))
		vis = vis or (w == "coronal" and (view_mode == MODE_CORONAL or view_mode == MODE_BOTH))
		mi.visible = visible_on and vis
		# 腹部基直接用 organ 框架，不依赖源材质参数是否已写入。
		var xf_ab: Transform3D = organs.call("abdomen_frame") if organs and organs.has_method("abdomen_frame") else xf
		mat.set_shader_parameter("ab_navel", xf_ab.origin)
		mat.set_shader_parameter("ab_right", xf_ab.basis.x)
		mat.set_shader_parameter("ab_up", xf_ab.basis.y)
		mat.set_shader_parameter("ab_fwd", xf_ab.basis.z)
		if src:
			for key in ["ab_navel", "ab_right", "ab_up", "ab_fwd"]:
				if src.get_shader_parameter(key) != null:
					mat.set_shader_parameter(key, src.get_shader_parameter(key))
		mat.set_shader_parameter("fill_on", 1.0 if mi.visible else 0.0)
		mat.set_shader_parameter("section_point", pnt)
		mat.set_shader_parameter("section_normal", n)
		mat.set_shader_parameter("canal_open_ab", open_ab)
		mat.set_shader_parameter("canal_axis_ab", axis_ab)
		mat.set_shader_parameter("canal_cerv_ab", cerv_ab + axis_ab * lift)
		mat.set_shader_parameter("uter_axis_ab", uter_ax)
		mat.set_shader_parameter("uter_len", float(shape.get("len", 0.055)) + lift)
		mat.set_shader_parameter("uter_rad", float(shape.get("rad", 0.022)))
		mat.set_shader_parameter("uter_wall", float(shape.get("wall", 0.006)))
		mat.set_shader_parameter("vag_lumen", vag_lumen)
		mat.set_shader_parameter("vag_wall", 0.009)
		mat.set_shader_parameter("rod_tip_w", rod_tip)
		mat.set_shader_parameter("rod_radius", rod_r)
		mat.set_shader_parameter("rod_axis_w", rod_ax)
		mat.set_shader_parameter("rod_shaft_r", 0.004)
		mat.set_shader_parameter("rod_shaft_len", 0.18)
		if not prof.is_empty():
			if prof.get("prof_tex") != null:
				mat.set_shader_parameter("prof_tex", prof["prof_tex"])
			mat.set_shader_parameter("prof_n", int(prof.get("prof_n", 20)))
			if prof.get("prof_bias") != null:
				mat.set_shader_parameter("prof_bias", prof["prof_bias"])
			if prof.get("prof_scale") != null:
				mat.set_shader_parameter("prof_scale", prof["prof_scale"])


func set_test_render(on: bool) -> void:
	_test_render = on
	if on:
		_bind_worlds()
	_layout_views()


func debug_capture_section(which: String) -> Image:
	# 无头 Dummy 渲染器没有可回读的纹理。
	if DisplayServer.get_name() == "headless":
		return null
	var vp: SubViewport = _vp_of(which)
	if vp == null:
		return null
	var tex := vp.get_texture()
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null or img.get_width() < 2:
		return null
	return img


func debug_section_metrics(which: String) -> Dictionary:
	# CPU 栅格化与填充着色器相同的体内/器官测试，不依赖 GPU，供无头自检。
	var pl := _planes()
	var cam: Camera3D = _cam_of(which)
	var out := {
		"which": which,
		"ok": false,
		"px": 0,
		"silhouette": 0,
		"black_in_sil": 0,
		"black_frac": 1.0,
		"cavity": 0,
		"uter_wall": 0,
		"uter_lumen": 0,
		"vag_wall": 0,
		"vag_lumen": 0,
		"rod": 0,
		"hand_bleed": 0,
		"hand_samples": 0,
	}
	if cam == null:
		return out
	var w := 170
	var h := 168
	var colors := _raster_fill(which, pl, cam, w, h)
	if colors.is_empty():
		return out
	var sil := 0
	var black := 0
	var cavity := 0
	var uw := 0
	var ul := 0
	var vw := 0
	var vl := 0
	var rod := 0
	var palette := {
		"cavity": Color(0.48, 0.20, 0.26),
		"uter_wall": Color(0.70, 0.30, 0.40),
		"uter_lumen": Color(0.45, 0.16, 0.22),
		"vag_wall": Color(0.91, 0.55, 0.60),
		"skin": Color(0.91, 0.75, 0.66),
		"vag_lumen": Color(0.58, 0.24, 0.30),
		"rod": Color(0.78, 0.82, 0.86),
	}
	for i in colors.size():
		var c: Color = colors[i]
		var luma := c.r * 0.3 + c.g * 0.6 + c.b * 0.1
		var is_bg := luma < 0.14 and c.r < 0.18 and c.g < 0.16
		if not is_bg:
			sil += 1
			if c.r < 0.08 and c.g < 0.08 and c.b < 0.08:
				black += 1
			var best := ""
			var best_d := 0.08
			for k in palette.keys():
				var pc: Color = palette[k]
				var d := absf(c.r - pc.r) + absf(c.g - pc.g) + absf(c.b - pc.b)
				if d < best_d:
					best_d = d
					best = str(k)
			if best == "cavity":
				cavity += 1
			elif best == "uter_wall":
				uw += 1
			elif best == "uter_lumen":
				ul += 1
			elif best == "vag_wall":
				vw += 1
			elif best == "vag_lumen":
				vl += 1
			elif best == "rod":
				rod += 1
	out["px"] = colors.size()
	out["silhouette"] = sil
	out["black_in_sil"] = black
	out["black_frac"] = float(black) / float(maxi(sil, 1))
	out["cavity"] = cavity
	out["uter_wall"] = uw
	out["uter_lumen"] = ul
	out["vag_wall"] = vw
	out["vag_lumen"] = vl
	out["rod"] = rod
	# 手臂：胶囊在画面上且在体表轮廓外的采样不得被组织色填上。
	var bleed := 0
	var hs := 0
	var limbs: Array = organs.call("limb_exclusion_capsules_world") if organs and organs.has_method("limb_exclusion_capsules_world") else []
	for li in limbs:
		var a: Vector3 = li["a"]
		var b: Vector3 = li["b"]
		var rr: float = float(li["r"])
		for k in 6:
			var wp: Vector3 = a.lerp(b, float(k) / 5.0)
			var scr := cam.unproject_position(wp)
			if scr.x < 0.0 or scr.y < 0.0 or scr.x >= float(w) or scr.y >= float(h):
				continue
			# 点在体表轮廓外才算“手露在断面里”。
			if _torso_contains_world(wp, 0.0):
				continue
			hs += 1
			var ix := int(scr.x)
			var iy := int(scr.y)
			var c2: Color = colors[iy * w + ix]
			var luma2 := c2.r * 0.3 + c2.g * 0.6 + c2.b * 0.1
			if luma2 >= 0.16:
				bleed += 1
	out["hand_samples"] = hs
	out["hand_bleed"] = bleed
	out["ok"] = sil > 40 and out["black_frac"] < 0.03
	return out


func debug_fill_alignment(which: String) -> Dictionary:
	# t87u：切面填充四边形必须铺在剖切面上。旧代码 looking_at(世界点) 会把它斜着立在阴道中央。
	var out := {"which": which, "ok": false, "plane_dist": 99.0, "facing": 0.0, "visible": false}
	if not _fills.has(which):
		return out
	var mi: MeshInstance3D = _fills[which].get("mi")
	if mi == null or not is_instance_valid(mi):
		return out
	var pl := _planes()
	var key := "long" if which == "long" else ("trans" if which == "trans" else "coronal")
	if not pl.has(key):
		return out
	var plane: Plane = pl[key]
	var n := plane.normal.normalized()
	var z := mi.global_transform.basis.z.normalized()
	out["plane_dist"] = absf(plane.distance_to(mi.global_position))
	out["facing"] = absf(z.dot(n))
	out["visible"] = mi.visible
	out["ok"] = out["plane_dist"] < 0.005 and out["facing"] > 0.95
	return out


func debug_gpu_section_metrics(which: String) -> Dictionary:
	# 真实 GPU 回读小窗像素。无纹理 / Dummy 渲染时 ok=false, renderer 标明原因。
	var out := {
		"which": which,
		"ok": false,
		"renderer": str(RenderingServer.get_current_rendering_method()) if RenderingServer else "",
		"display": str(DisplayServer.get_name()),
		"px": 0,
		"silhouette": 0,
		"black_in_sil": 0,
		"black_frac": 1.0,
		"cavity": 0,
		"uter_wall": 0,
		"uter_lumen": 0,
		"vag_wall": 0,
		"vag_lumen": 0,
		"rod": 0,
		"reason": "",
	}
	var img: Image = debug_capture_section(which)
	if img == null or img.get_width() < 8 or img.get_height() < 8:
		out["reason"] = "no image"
		return out
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var sil := 0
	var black := 0
	var cavity := 0
	var uw := 0
	var ul := 0
	var vw := 0
	var vl := 0
	var rod := 0
	var palette := {
		"cavity": Color(0.48, 0.20, 0.26),
		"uter_wall": Color(0.70, 0.30, 0.40),
		"uter_lumen": Color(0.45, 0.16, 0.22),
		"vag_wall": Color(0.91, 0.55, 0.60),
		"skin": Color(0.91, 0.75, 0.66),
		"vag_lumen": Color(0.58, 0.24, 0.30),
		"rod": Color(0.78, 0.82, 0.86),
	}
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var luma := c.r * 0.3 + c.g * 0.6 + c.b * 0.1
			var is_bg := luma < 0.14 and c.r < 0.18 and c.g < 0.16
			if is_bg:
				continue
			sil += 1
			if c.r < 0.08 and c.g < 0.08 and c.b < 0.08:
				black += 1
			var best := ""
			var best_d := 0.10
			for k in palette.keys():
				var pc: Color = palette[k]
				var d := absf(c.r - pc.r) + absf(c.g - pc.g) + absf(c.b - pc.b)
				if d < best_d:
					best_d = d
					best = str(k)
			if best == "cavity":
				cavity += 1
			elif best == "uter_wall":
				uw += 1
			elif best == "uter_lumen":
				ul += 1
			elif best == "vag_wall":
				vw += 1
			elif best == "vag_lumen":
				vl += 1
			elif best == "rod":
				rod += 1
	out["px"] = w * h
	out["silhouette"] = sil
	out["black_in_sil"] = black
	out["black_frac"] = float(black) / float(maxi(sil, 1))
	out["cavity"] = cavity
	out["uter_wall"] = uw
	out["uter_lumen"] = ul
	out["vag_wall"] = vw
	out["vag_lumen"] = vl
	out["rod"] = rod
	if sil < 30:
		out["reason"] = "empty or dummy renderer"
		return out
	var organ_fill := cavity + uw + ul + vw + vl
	# 平扫小窗有时几乎只切到阴道/子宫，腹腔像素很少；无纯黑且有器官填充即视为成功。
	out["ok"] = out["black_frac"] < 0.05 and organ_fill > 40
	if not out["ok"]:
		out["reason"] = "black_frac=%.4f cavity=%s organ_fill=%s" % [out["black_frac"], cavity, organ_fill]
	return out


func _vp_of(which: String) -> SubViewport:
	if which == "trans":
		return _trans_vp
	if which == "coronal":
		return _coronal_vp
	return _long_vp


func _cam_of(which: String) -> Camera3D:
	if which == "trans":
		return _trans_cam
	if which == "coronal":
		return _coronal_cam
	return _long_cam


func _torso_contains_world(wp: Vector3, inset: float) -> bool:
	if organs == null or not organs.has_method("abdomen_frame") or not organs.has_method("torso_profile_at_ab"):
		return false
	var xf: Transform3D = organs.call("abdomen_frame")
	var l: Vector3 = xf.affine_inverse() * wp
	var pr: Vector3 = organs.call("torso_profile_at_ab", l.y)
	var hx := pr.x - inset
	var zf := pr.y - inset
	var zb := pr.z + inset
	if hx < 0.02:
		return false
	return absf(l.x) <= hx and l.z <= zf and l.z >= zb


func _raster_fill(which: String, pl: Dictionary, cam: Camera3D, w: int, h: int) -> Array:
	var out: Array = []
	out.resize(w * h)
	# 填充逻辑与 section_fill.gdshader 对齐（腹部局部坐标）。
	var canal := _canal()
	var open_ab: Vector3 = canal.get("opening_ab", Vector3.ZERO)
	var axis_ab: Vector3 = canal.get("axis_ab", Vector3(0, 1, 0))
	if axis_ab.length_squared() < 1e-10:
		axis_ab = Vector3(0, 1, 0)
	else:
		axis_ab = axis_ab.normalized()
	var cerv_ab: Vector3 = canal.get("cervix_ab", open_ab + axis_ab * 0.05)
	var lift := 0.0
	if organs and organs.has_method("fundus_lift"):
		lift = float(organs.call("fundus_lift"))
	cerv_ab = cerv_ab + axis_ab * lift
	var shape: Dictionary = organs.call("uterus_section_shape") if organs and organs.has_method("uterus_section_shape") else {}
	var uter_ax: Vector3 = shape.get("axis_ab", axis_ab)
	if uter_ax.length_squared() < 1e-10:
		uter_ax = axis_ab
	else:
		uter_ax = uter_ax.normalized()
	var ulen := float(shape.get("len", 0.055)) + lift
	var ur := float(shape.get("rad", 0.022))
	var uw := float(shape.get("wall", 0.006))
	var vag_lumen := 0.007
	if organs and organs.has_method("canal_dilate_radius_at"):
		vag_lumen = maxf(0.005, float(organs.call("canal_dilate_radius_at", open_ab.distance_to(cerv_ab) * 0.45)) - 0.006)
	var vag_wall := 0.007
	var canal_len := maxf((cerv_ab - open_ab).dot(axis_ab), 0.03)
	var xf: Transform3D = organs.call("abdomen_frame") if organs and organs.has_method("abdomen_frame") else Transform3D.IDENTITY
	var inv := xf.affine_inverse()
	var rod_tip := _ball_world()
	var rod_r := 0.0
	var rod_ax: Vector3 = pl["axis"]
	if mode and mode.has_method("tool_controller"):
		var ctl = mode.call("tool_controller")
		if ctl and ctl.has_method("radius"):
			rod_r = float(ctl.call("radius"))
			if ctl.has_method("tip_world"):
				rod_tip = ctl.call("tip_world")
		if ctl and ctl.get("_root") is Node3D:
			rod_ax = (ctl.get("_root") as Node3D).global_transform.basis.z
	var pnt: Vector3 = pl.get("long_look", pl["long_p"])
	var plane: Plane = pl["long"]
	if which == "trans":
		pnt = pl["trans_p"]
		plane = pl["trans"]
	elif which == "coronal":
		pnt = pl.get("coronal_look", pl["coronal_p"])
		plane = pl["coronal"]
	var n := plane.normal.normalized()
	# 自己做正交反投影，不依赖 SubViewport 是否是当前视口（无头下 project_position 不可靠）。
	var bg := Color(0.12, 0.09, 0.10, 1)
	var aspect := float(w) / float(max(h, 1))
	var half_h := cam.size * 0.5
	var half_w := half_h * aspect
	var origin := cam.global_position
	var right := cam.global_transform.basis.x
	var upv := cam.global_transform.basis.y
	var fwd := -cam.global_transform.basis.z
	if fwd.length_squared() < 1e-12:
		fwd = -n
	else:
		fwd = fwd.normalized()
	for y in h:
		for x in w:
			var sx := ((float(x) + 0.5) / float(w) - 0.5) * 2.0 * half_w
			var sy := (0.5 - (float(y) + 0.5) / float(h)) * 2.0 * half_h
			var wp := origin + right * sx + upv * sy
			var den := fwd.dot(n)
			var hit := wp
			if absf(den) > 1e-6:
				hit = wp + fwd * ((pnt - wp).dot(n) / den)
			var col := _fill_color_at(inv * hit, open_ab, axis_ab, cerv_ab, canal_len, uter_ax, ulen, ur, uw, vag_lumen, vag_wall, inv * rod_tip, rod_r, rod_tip, rod_ax, hit)
			out[y * w + x] = col
	return out


func _fill_color_at(l: Vector3, open_ab: Vector3, ax: Vector3, cerv: Vector3, canal_len: float, uax: Vector3, ulen: float, ur: float, uwall: float, vlumen: float, vwall: float, rod_ab: Vector3, rod_r: float, rod_tip_w: Vector3, rod_ax_w: Vector3, wp: Vector3) -> Color:
	if rod_r > 1e-5 and l.distance_to(rod_ab) <= rod_r + 0.0004:
		return Color(0.78, 0.82, 0.86)
	if rod_r > 1e-5 and rod_ax_w.length_squared() > 1e-10:
		var rd := rod_ax_w.normalized()
		var tsh := clampf(-(wp - rod_tip_w).dot(rd), 0.0, 0.18)
		var dsh := ((wp - rod_tip_w) + rd * tsh).length()
		if dsh <= 0.0043 and tsh > rod_r * 0.35:
			return Color(0.78, 0.82, 0.86)
	var along := (l - open_ab).dot(ax)
	var lat := (l - open_ab) - ax * along
	var pr := lat.length()
	var u0 := cerv + uax * (ulen * 0.52)
	var du := l - u0
	var ua := du.dot(uax)
	var urad := du - uax * ua
	var q_out := (ua * ua) / pow(ulen * 0.52, 2.0) + urad.length_squared() / (ur * ur)
	var rin := maxf(ur - uwall, 0.006)
	var lin := maxf(ulen * 0.52 - uwall, 0.012)
	var q_in := (ua * ua) / (lin * lin) + urad.length_squared() / (rin * rin)
	if q_out <= 1.0 and q_in >= 1.0:
		return Color(0.70, 0.30, 0.40)
	if q_in < 1.0:
		return Color(0.45, 0.16, 0.22)
	var along_vag := along >= -0.012 and along <= canal_len + 0.006
	if along_vag and pr >= vlumen and pr <= vlumen + vwall:
		return Color(0.91, 0.55, 0.60)
	if along_vag and pr < vlumen:
		return Color(0.58, 0.24, 0.30)
	if _torso_contains_ab(l, 0.010):
		return Color(0.48, 0.20, 0.26)
	if _torso_contains_ab(l, 0.0):
		return Color(0.91, 0.75, 0.66)
	return Color(0.12, 0.09, 0.10)


func _torso_contains_ab(l: Vector3, inset: float) -> bool:
	if organs == null or not organs.has_method("torso_profile_at_ab"):
		return false
	if organs.has_method("section_profile_params"):
		var prm: Dictionary = organs.call("section_profile_params")
		if prm.get("prof_bias") != null and prm.get("prof_scale") != null:
			var bias: Vector4 = prm["prof_bias"]
			var scale: Vector4 = prm["prof_scale"]
			var y0 := bias.x - 0.04
			var y1 := bias.x + scale.x + 0.02
			if l.y < y0 or l.y > y1:
				return false
	var pr: Vector3 = organs.call("torso_profile_at_ab", l.y)
	var hx := pr.x - inset
	if hx < 0.02:
		return false
	return absf(l.x) <= hx and l.z <= (pr.y - inset) and l.z >= (pr.z + inset)


func deactivate() -> void:
	set_visible_on(false)
	_clear_copies()
	_clear_fills()
	if _btn_toggle:
		_btn_toggle.visible = false


func _clear_fills() -> void:
	for k in _fills.keys():
		var rec: Dictionary = _fills[k]
		var mi = rec.get("mi")
		if is_instance_valid(mi):
			mi.queue_free()
	_fills.clear()
	if _fill_root and is_instance_valid(_fill_root):
		_fill_root.queue_free()
	_fill_root = null


func _exit_tree() -> void:
	_clear_copies()
	_clear_fills()
	if _panel and is_instance_valid(_panel):
		_panel.queue_free()
	if _btn_toggle and is_instance_valid(_btn_toggle) and _btn_toggle.get_parent() != self:
		_btn_toggle.queue_free()
