extends SceneTree
## 未发布（t102u）：设置「UI缩放」滑块。通过 Window.content_scale_factor
## 统一缩放 HUD 按钮、菜单和断面图窗口，不影响 3D 分辨率；写入 settings.cfg。
##   godot --headless --path . -s res://scripts/tests/v0429_ui_scale_check.gd

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_BAK := "user://settings.cfg.ui_scale_bak"

var main: Node
var player: Node
var hud: Node
var settings: Node
var fails := 0
var _saved_ui_scale: float = 0.0
var _saved_factor: float = 1.0


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0429: OK   ", msg)
	else:
		fails += 1
		push_error("v0429: FAIL " + msg)


func _backup_settings() -> void:
	if FileAccess.file_exists(SETTINGS_BAK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_BAK))
	if FileAccess.file_exists(SETTINGS_PATH):
		var src := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		var txt := src.get_as_text() if src else ""
		if src:
			src.close()
		var dst := FileAccess.open(SETTINGS_BAK, FileAccess.WRITE)
		if dst:
			dst.store_string(txt)
			dst.close()
		# 清掉旧存档里的 ui_scale，避免污染默认值测试。
		var c := ConfigFile.new()
		if c.load(SETTINGS_PATH) == OK and c.has_section_key("graphics", "ui_scale"):
			c.erase_section_key("graphics", "ui_scale")
			c.save(SETTINGS_PATH)


func _restore_settings() -> void:
	if FileAccess.file_exists(SETTINGS_BAK):
		var src := FileAccess.open(SETTINGS_BAK, FileAccess.READ)
		var txt := src.get_as_text() if src else ""
		if src:
			src.close()
		var dst := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
		if dst:
			dst.store_string(txt)
			dst.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_BAK))
	if settings and is_instance_valid(settings):
		settings.set("ui_scale", _saved_ui_scale)
		if settings.has_method("apply_ui_scale"):
			settings.call("apply_ui_scale")
	var win := root as Window
	if win:
		win.content_scale_factor = _saved_factor


func _canvas_scale(c: Control) -> float:
	if c == null:
		return 0.0
	return c.get_global_transform_with_canvas().get_scale().x


func _screen_size(c: Control) -> Vector2:
	if c == null or c.get_viewport() == null:
		return Vector2.ZERO
	var vis := c.get_viewport().get_visible_rect().size
	var win := Vector2(c.get_window().size) if c.get_window() else vis
	var r := c.get_global_rect().size
	if vis.x < 1.0 or vis.y < 1.0:
		return r
	return Vector2(r.x * win.x / vis.x, r.y * win.y / vis.y)


func _section_panel() -> Control:
	if hud == null:
		return null
	return hud.find_child("CrossSectionPanel", true, false) as Control


func _run() -> void:
	_backup_settings()
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	_saved_factor = (root as Window).content_scale_factor if root is Window else 1.0

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	settings = main.get_node_or_null("GameSettings")
	_ok(player != null and hud != null and settings != null, "scene booted with HUD and GameSettings")
	if settings:
		_saved_ui_scale = float(settings.get("ui_scale"))

	# ---- 默认值：未设置时电脑 100%、手机 80%
	var def_sc: float = settings.call("default_ui_scale")
	var want_def := 0.80 if bool(settings.call("is_mobile_os")) else 1.00
	_ok(is_equal_approx(def_sc, want_def), "platform default UI scale is %.0f%% (got %.0f%%)" % [want_def * 100.0, def_sc * 100.0])
	_ok(is_equal_approx(float(settings.get("ui_scale")), 0.0), "unset ui_scale stays 0 (use platform default)")
	_ok(is_equal_approx(float(settings.call("effective_ui_scale")), def_sc), "effective scale uses the platform default when unset")
	_ok(is_equal_approx(settings.call("snap_ui_scale", 0.67), 0.65), "snap 67%% → 65%%")
	_ok(is_equal_approx(settings.call("snap_ui_scale", 0.40), 0.50), "snap below min → 50%%")
	_ok(is_equal_approx(settings.call("snap_ui_scale", 1.62), 1.50), "snap above max → 150%%")
	_ok(is_equal_approx((root as Window).content_scale_factor, def_sc), "window content_scale_factor starts at the default (%.2f)" % (root as Window).content_scale_factor)

	# ---- 设置面板滑块
	var sl: HSlider = hud.get("_ui_scale_slider")
	var lab: Label = hud.get("_ui_scale_value")
	_ok(sl != null and lab != null, "settings panel has UI缩放 slider and value label")
	if sl:
		_ok(is_equal_approx(sl.min_value, 50.0) and is_equal_approx(sl.max_value, 150.0) and is_equal_approx(sl.step, 5.0), "slider range 50–150%%, step 5%%")
		_ok(is_equal_approx(sl.value, def_sc * 100.0), "slider shows the effective default (%.0f%%)" % sl.value)

	# ---- 断面图小窗（挂到 HUD 根上，跟按钮走同一套 content_scale）
	var vm: Node = player.call("get_vagina_mode") if player and player.has_method("get_vagina_mode") else null
	var organs: Node = player.call("get_organs") if player and player.has_method("get_organs") else null
	var sec: Node = null
	if vm and organs:
		sec = load("res://scripts/interact/cross_section_view.gd").new()
		sec.name = "CrossSectionViewUiScaleTest"
		vm.add_child(sec)
		sec.call("setup", vm, organs, player)
		sec.call("set_visible_on", true)
		await _frames(4)
	var panel := _section_panel()
	_ok(panel != null, "cross-section panel is built and parented under the HUD")
	if panel:
		var host := panel.get_parent()
		_ok(host != null and (host == hud or (hud.get("_root_ui") != null and (host == hud.get("_root_ui") or hud.is_ancestor_of(panel)))), "section panel lives under the HUD canvas, so it scales with the buttons")

	var btn: Control = hud.get("_btn_settings")
	_ok(btn != null, "settings chrome button exists")
	var s3_before := root.scaling_3d_scale
	var vp_size_before := Vector2i(root.size)

	# ---- 80% 与 120%：逻辑尺寸不变，屏幕占用随 content_scale_factor 变
	settings.call("set_ui_scale", 0.80)
	if hud.has_method("_apply_layout"):
		hud.call("_apply_layout")
	await _frames(3)
	_ok(is_equal_approx(float(settings.call("effective_ui_scale")), 0.80), "set_ui_scale(0.80) sticks")
	_ok(is_equal_approx((root as Window).content_scale_factor, 0.80), "content_scale_factor is 0.80")
	if sl:
		_ok(is_equal_approx(sl.value, 80.0), "slider follows live 80%%")
	if lab:
		_ok(lab.text == "80%", "value label shows 80%%")
	var vis80 := root.get_visible_rect().size
	var scr_btn_80 := _screen_size(btn)
	var scr_panel_80 := _screen_size(panel)
	var xf_btn_80 := _canvas_scale(btn)
	var xf_panel_80 := _canvas_scale(panel)

	settings.call("set_ui_scale", 1.20)
	if hud.has_method("_apply_layout"):
		hud.call("_apply_layout")
	await _frames(3)
	_ok(is_equal_approx((root as Window).content_scale_factor, 1.20), "content_scale_factor is 1.20")
	if sl:
		_ok(is_equal_approx(sl.value, 120.0), "slider follows live 120%%")
	var vis120 := root.get_visible_rect().size
	var scr_btn_120 := _screen_size(btn)
	var scr_panel_120 := _screen_size(panel)
	_ok(vis80.x > vis120.x * 1.2, "visible logical width grows when UI scale shrinks (80%% vis.x=%.1f, 120%% vis.x=%.1f)" % [vis80.x, vis120.x])
	_ok(scr_btn_80.x > 1.0 and scr_btn_120.x > scr_btn_80.x * 1.3, "HUD button screen size scales up from 80%% to 120%% (%.1f → %.1f)" % [scr_btn_80.x, scr_btn_120.x])
	if panel:
		_ok(scr_panel_80.x > 1.0 and scr_panel_120.x > scr_panel_80.x * 1.3, "section panel screen size scales up from 80%% to 120%% (%.1f → %.1f)" % [scr_panel_80.x, scr_panel_120.x])
		if xf_btn_80 > 0.01 and xf_panel_80 > 0.01:
			_ok(absf(xf_btn_80 / xf_panel_80 - 1.0) < 0.08, "button and section panel share the same canvas scale (btn=%.3f panel=%.3f)" % [xf_btn_80, xf_panel_80])

	# 滑块直接改值也会立刻生效
	if sl:
		sl.value = 70.0
		await _frames(2)
		_ok(is_equal_approx(float(settings.call("effective_ui_scale")), 0.70), "dragging the slider applies 70%% live")
		_ok(is_equal_approx((root as Window).content_scale_factor, 0.70), "slider sets content_scale_factor to 0.70")

	# 3D 分辨率不受影响
	_ok(is_equal_approx(root.scaling_3d_scale, s3_before), "scaling_3d_scale unchanged by UI scale (%.3f)" % root.scaling_3d_scale)
	_ok(Vector2i(root.size) == vp_size_before, "3D / window backing size unchanged (%s)" % str(Vector2i(root.size)))

	# 触屏控件是 HUD CanvasLayer 的子节点，和按钮走同一套 Window.content_scale_factor。
	# get_global_transform_with_canvas() 在 headless 下不包含 content_scale_factor（尺度恒为 1），
	# 所以这里只确认挂载关系；屏幕占用已在上面的按钮 / 断面图上验证。
	var touch: Control = hud.get("_touch") if hud else null
	_ok(touch != null, "TouchControls exists under the HUD")
	if touch:
		_ok(touch.get_parent() == hud, "TouchControls is a child of the HUD CanvasLayer (same content scale)")

	# ---- 持久化
	settings.call("set_ui_scale", 0.65)
	await _frames(1)
	var c := ConfigFile.new()
	_ok(c.load(SETTINGS_PATH) == OK, "settings.cfg readable")
	_ok(is_equal_approx(float(c.get_value("graphics", "ui_scale", 0.0)), 0.65), "settings.cfg stores ui_scale=0.65")
	var fresh: Node = load("res://scripts/game_settings.gd").new()
	fresh.name = "GameSettingsReload"
	main.add_child(fresh)
	fresh.call("load_cfg")
	_ok(is_equal_approx(float(fresh.call("effective_ui_scale")), 0.65), "new GameSettings reloads persisted 65%%")
	fresh.queue_free()

	_restore_settings()
	if sec and is_instance_valid(sec):
		if sec.has_method("set_visible_on"):
			sec.call("set_visible_on", false)
		sec.queue_free()
	print("v0429_ui_scale_check: fails=%d" % fails)
	quit(1 if fails > 0 else 0)
