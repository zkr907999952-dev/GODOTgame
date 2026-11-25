extends SceneTree
## T-17：安卓触屏 HUD 在常见分辨率 / 模式下，可见可点控件不得重叠，且须落在安全区内。
##   godot --headless --path . -s res://scripts/tests/v0423_hud_overlap_check.gd
## 不截图，只做无头断言。本次不打包、不改版本号。


const PHONE_SAFE := Vector4(48, 0, 24, 24)
const TABLET_SAFE := Vector4(20, 20, 20, 20)

## 物理分辨率 + 典型 DPI 缩放（逻辑尺寸 = 窗口 / scale）。
const RESOLUTIONS := [
	{"name": "2400x1080", "w": 2400, "h": 1080, "scale": 2.75, "safe": PHONE_SAFE},
	{"name": "2340x1080", "w": 2340, "h": 1080, "scale": 2.75, "safe": PHONE_SAFE},
	{"name": "1920x1080", "w": 1920, "h": 1080, "scale": 2.50, "safe": PHONE_SAFE},
	{"name": "1600x720", "w": 1600, "h": 720, "scale": 2.00, "safe": PHONE_SAFE},
	{"name": "2560x1440", "w": 2560, "h": 1440, "scale": 3.50, "safe": PHONE_SAFE},
	{"name": "2048x1536", "w": 2048, "h": 1536, "scale": 2.00, "safe": TABLET_SAFE},
]

const MODES := [
	"play_fp_unarmed",
	"play_fp_armed",
	"observe",
	"observe_bed",
	"exam_bed",
	"surgery",
	"surgery_scalpel",
	"surgery_forceps",
	"vagina",
	"vagina_speculum",
	"vagina_ball",
	"car",
	"plane_slider",
	"plane_stick",
	"plane_buttons",
	"map",
	"settings",
]


var fails := 0
var hud: CanvasLayer
var game: Node
var player: Node
var surgery: Node
var vagina: Node
var vehicles: Node
var weapons: Node
var pip_panel: Control


func _initialize() -> void:
	call_deferred("_run")


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("ok  ", msg)
	else:
		fails += 1
		print("FAIL  ", msg)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _run() -> void:
	_build_harness()
	await _frames(4)
	_ok(hud != null and hud.get("_root_ui") != null, "HUD built")
	# PC 布局冒烟：1280x720 关闭触屏，不得报错，顶栏按钮仍可见。
	await _resize(1280, 720, 1.0, Vector4.ZERO, false)
	_apply_mode("play_fp_unarmed")
	await _frames(2)
	_ok(hud.get("_btn_settings") != null and (hud.get("_btn_settings") as Control).visible, "PC chrome settings stays visible")
	_ok(hud.get("touch_ui") == false, "PC layout does not force touch_ui")

	for res in RESOLUTIONS:
		await _resize(int(res["w"]), int(res["h"]), float(res["scale"]), res["safe"], true)
		var vis := hud.get_viewport().get_visible_rect().size
		print("v0423: res %s scale=%s logical=%.0fx%.0f safe=%s" % [
			res["name"], res["scale"], vis.x, vis.y, res["safe"]
		])
		_ok(vis.x >= 320.0 and vis.y >= 240.0, "%s logical viewport is usable (%.0fx%.0f)" % [res["name"], vis.x, vis.y])
		for mode in MODES:
			_apply_mode(mode)
			await _frames(2)
			if hud.has_method("_apply_layout"):
				hud.call("_apply_layout")
			await _frames(2)
			_assert_no_overlap(str(res["name"]), mode)
	print("v0423_hud_overlap_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _build_harness() -> void:
	game = Node.new()
	game.name = "Game"
	game.set_script(FakeGame)
	root.add_child(game)
	player = Node.new()
	player.name = "Player"
	player.set_script(FakePlayer)
	game.add_child(player)
	surgery = Node.new()
	surgery.name = "Surgery"
	surgery.set_script(FakeSurgery)
	game.add_child(surgery)
	vagina = Node.new()
	vagina.name = "Vagina"
	vagina.set_script(FakeVagina)
	game.add_child(vagina)
	vehicles = Node.new()
	vehicles.name = "Vehicles"
	vehicles.set_script(FakeVehicles)
	game.add_child(vehicles)
	weapons = Node.new()
	weapons.name = "Weapons"
	weapons.set_script(FakeWeapons)
	player.add_child(weapons)
	game.set("player", player)
	game.set("surgery", surgery)
	game.set("vagina", vagina)
	game.set("vehicle_system", vehicles)
	var settings := Node.new()
	settings.name = "GameSettings"
	settings.set_script(FakeSettings)
	game.add_child(settings)
	game.set("settings", settings)
	player.set("surgery", surgery)
	player.set("vagina", vagina)
	player.set("weapons", weapons)
	var packed: Script = load("res://scripts/hud.gd")
	hud = CanvasLayer.new()
	hud.set_script(packed)
	hud.name = "HUD"
	game.add_child(hud)
	# wait _ready
	# setup after first frames in _run
	# bind here deferred via setup once tree is ready


func _resize(w: int, h: int, scale: float, safe: Vector4, touch: bool) -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(w, h)
	var win := hud.get_window()
	if win:
		win.size = Vector2i(w, h)
	DisplayServer.window_set_size(Vector2i(w, h))
	await _frames(1)
	if not hud.get("_player"):
		hud.call("setup", player)
		hud.call("setup_vehicles", vehicles)
	if touch:
		hud.call("debug_force_mobile", scale, safe)
	else:
		hud.set("_mobile_scale", 0.0)
		hud.set("_debug_safe", null)
		hud.call("set_touch_ui", false)
		if win:
			win.content_scale_size = Vector2i(w, h)
	await _frames(2)


func _apply_mode(mode: String) -> void:
	# reset
	player.set("first_person", true)
	player.set("play_mode", 1)
	player.set("occupancy", "")
	surgery.set("active", false)
	surgery.set("tool", "none")
	surgery.set("cut_mode", "straight")
	surgery.set("can_cut", false)
	surgery.set("forceps_mode", "pull")
	surgery.set("retr_sel", -1)
	surgery.set("spec_in", false)
	surgery.set("spec_ready", false)
	surgery.set("spec_ang", 0.0)
	surgery.set("organ_label", "")
	vagina.set("active", false)
	vagina.set("tool", "none")
	vagina.set("preset", "free")
	vehicles.set("occupied", null)
	vehicles.set("nearest", null)
	vehicles.set("place_clone", false)
	vehicles.set("bed_avail", false)
	weapons.set("armed", false)
	var settings = game.get_node_or_null("GameSettings")
	if settings:
		settings.set("flight_control_mode", "slider")
	game.set("observe_ok", false)
	game.set("on_bed", false)
	game.set("map_open", false)
	game.set("map_view", null)
	if hud.get("_overhead_ui"):
		(hud.get("_overhead_ui") as Control).visible = false
	if hud.has_method("close_panels"):
		hud.call("close_panels")
	if pip_panel and is_instance_valid(pip_panel):
		pip_panel.visible = false

	match mode:
		"play_fp_unarmed":
			pass
		"play_fp_armed":
			weapons.set("armed", true)
		"observe":
			player.set("first_person", false)
			player.set("play_mode", 0)
			game.set("observe_ok", true)
		"observe_bed":
			player.set("first_person", false)
			player.set("play_mode", 0)
			player.set("occupancy", "exam_bed")
			game.set("observe_ok", false)
			game.set("on_bed", true)
			vehicles.set("bed_avail", true)
			var bed := Node.new()
			bed.set_meta("kind", "exam_bed")
			vehicles.set("occupied", bed)
			vehicles.set("nearest", bed)
		"exam_bed":
			player.set("first_person", false)
			player.set("occupancy", "exam_bed")
			game.set("on_bed", true)
			vehicles.set("bed_avail", true)
			var bed2 := Node.new()
			bed2.set_meta("kind", "exam_bed")
			vehicles.set("occupied", bed2)
		"surgery", "surgery_scalpel", "surgery_forceps":
			player.set("first_person", false)
			player.set("occupancy", "exam_bed")
			game.set("on_bed", true)
			surgery.set("active", true)
			if mode == "surgery_scalpel":
				surgery.set("tool", "scalpel")
				surgery.set("can_cut", true)
			elif mode == "surgery_forceps":
				surgery.set("tool", "forceps")
				surgery.set("organ_label", "子宫")
		"vagina", "vagina_speculum", "vagina_ball":
			player.set("first_person", false)
			player.set("occupancy", "exam_bed")
			game.set("on_bed", true)
			vagina.set("active", true)
			if mode == "vagina_speculum":
				vagina.set("tool", "speculum")
				surgery.set("spec_in", true)
				surgery.set("spec_ready", true)
				surgery.set("spec_ang", 18.0)
			elif mode == "vagina_ball":
				vagina.set("tool", "ball_rod")
				_ensure_pip()
		"car":
			player.set("occupancy", "car")
			var car := Node.new()
			car.set_meta("kind", "car")
			vehicles.set("occupied", car)
			vehicles.set("vehicle_cam", "first")
			vehicles.set("vehicle_look_mode", "look")
		"plane_slider", "plane_stick", "plane_buttons":
			player.set("occupancy", "plane")
			var plane := Node.new()
			plane.set_meta("kind", "plane")
			plane.set("thrust", 0.4)
			plane.set("gear", 1.0)
			plane.set("gear_want", 1.0)
			vehicles.set("occupied", plane)
			var fm := "slider"
			if mode == "plane_stick":
				fm = "stick"
			elif mode == "plane_buttons":
				fm = "buttons"
			if settings:
				settings.set("flight_control_mode", fm)
		"map":
			var mv := Node.new()
			mv.set("is_open", true)
			game.set("map_view", mv)
			if hud.get("_overhead_ui"):
				(hud.get("_overhead_ui") as Control).visible = true
		"settings":
			if hud.has_method("toggle_settings") or hud.has_method("_toggle_panel"):
				# PanelId.SETTINGS = 1
				hud.call("_toggle_panel", 1)

	# 载具 kind_of 读 meta
	if hud.has_method("_refresh_vehicle_touch"):
		hud.call("_refresh_vehicle_touch")
	if hud.has_method("_refresh_surgery_ui"):
		hud.call("_refresh_surgery_ui")
	if hud.has_method("_refresh_bed_actions"):
		hud.call("_refresh_bed_actions")


func _ensure_pip() -> void:
	if pip_panel == null or not is_instance_valid(pip_panel):
		pip_panel = PanelContainer.new()
		pip_panel.name = "CrossSectionPanel"
		pip_panel.custom_minimum_size = Vector2(200, 160)
		pip_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		var inner := Button.new()
		inner.text = "断面"
		inner.custom_minimum_size = Vector2(80, 28)
		pip_panel.add_child(inner)
		(hud.get("_root_ui") as Control).add_child(pip_panel)
	pip_panel.visible = true
	if hud.get("_btn_section"):
		(hud.get("_btn_section") as Button).button_pressed = true
	if hud.has_method("layout_section_pip"):
		hud.call("layout_section_pip", pip_panel, hud.get("_btn_section"), true)


func _assert_no_overlap(res_name: String, mode: String) -> void:
	if not hud.has_method("debug_collect_interactive_rects"):
		_ok(false, "%s/%s missing debug_collect_interactive_rects" % [res_name, mode])
		return
	var d: Dictionary = hud.call("debug_collect_interactive_rects")
	var overlaps: Array = d.get("overlaps", [])
	var oos: Array = d.get("out_of_safe", [])
	# 过滤明显的父子重复登记（同一按钮被工具栏和树遍历各记一次，矩形几乎相同）。
	overlaps = _filter_duplicate_claims(overlaps)
	oos = _filter_ignore_oos(oos, mode)
	if overlaps.is_empty() and oos.is_empty():
		print("ok  %s/%s no overlap (%d rects)" % [res_name, mode, (d.get("rects", []) as Array).size()])
		return
	for hit in overlaps:
		fails += 1
		print("FAIL  %s/%s overlap %s x %s  a=%s b=%s" % [res_name, mode, hit[0], hit[1], hit[2], hit[3]])
	for hit in oos:
		fails += 1
		print("FAIL  %s/%s out_of_safe %s rect=%s" % [res_name, mode, hit[0], hit[1]])


func _filter_duplicate_claims(overlaps: Array) -> Array:
	var out: Array = []
	for hit in overlaps:
		var ia := str(hit[0])
		var ib := str(hit[1])
		# 同一滚动面板内部的控件互相重叠不计入（菜单列表自己的排版，不是触屏 HUD 按键叠钮）。
		if "ScrollContainer" in ia and "ScrollContainer" in ib:
			continue
		var a: Rect2 = hit[2]
		var b: Rect2 = hit[3]
		# 几乎同一矩形（重复登记）忽略。
		if a.position.distance_to(b.position) < 2.0 and a.size.distance_to(b.size) < 2.0:
			continue
		# 一个完全包含另一个且中心接近：多半是容器与子按钮，忽略面积大很多的那对。
		if a.encloses(b) or b.encloses(a):
			var ra := a.get_area()
			var rb := b.get_area()
			if maxf(ra, rb) > minf(ra, rb) * 1.8:
				continue
		out.append(hit)
	return out


func _filter_ignore_oos(oos: Array, _mode: String) -> Array:
	var out: Array = []
	for hit in oos:
		var r: Rect2 = hit[1]
		# 1px 以内的越界已经在 helper 里容差；这里再忽略完全退化的矩形。
		if r.size.x < 2.0 or r.size.y < 2.0:
			continue
		out.append(hit)
	return out


# ---- stubs ----
class FakeGame extends Node:
	var player: Node
	var surgery: Node
	var vagina: Node
	var vehicle_system: Node
	var observe_ok: bool = false
	var on_bed: bool = false
	var map_open: bool = false
	var current_map: String = "home"
	var map_view = null
	var settings: Node = null

	func switch_map(_id = null) -> void:
		pass

	func get_maps() -> Array:
		return []

	func surgery_system_of(_p = null) -> Node:
		return surgery

	func vagina_mode_of(_p = null) -> Node:
		return vagina

	func can_enter_body_mode_from_observe() -> bool:
		return observe_ok

	func can_toggle_surgery() -> bool:
		return on_bed

	func can_toggle_vagina() -> bool:
		return on_bed


class FakePlayer extends Node:
	var first_person: bool = true
	var play_mode: int = 1
	var occupancy: String = ""
	var mouse_sensitivity: float = 1.0
	var touch_look_sensitivity: float = 1.0
	var ads_toggle: bool = false
	var surgery: Node
	var vagina: Node
	var weapons: Node
	var input_locked: bool = false
	var ui_blocks_capture: bool = false
	var tp_auto_rotate: bool = false

	func is_display_mode() -> bool:
		return play_mode == 0

	func get_surgery() -> Node:
		return surgery

	func get_vagina_mode() -> Node:
		return vagina

	func get_weapons() -> Node:
		return weapons

	func get_stance() -> String:
		return "stand"

	func get_organs() -> Node:
		return null

	func get_corpse_drag() -> Node:
		return null

	func active_surgery() -> Node:
		return surgery if surgery and bool(surgery.call("is_active")) else null

	func get_tp_distance() -> float:
		return 1.6

	func get_tp_focus() -> String:
		return "body"

	func has_tp_preset(_i: int) -> bool:
		return false


class FakeSurgery extends Node:
	var active: bool = false
	var tool: String = "none"
	var cut_mode: String = "straight"
	var can_cut: bool = false
	var forceps_mode: String = "pull"
	var retr_sel: int = -1
	var spec_in: bool = false
	var spec_ready: bool = false
	var spec_ang: float = 0.0
	var organ_label: String = ""

	func is_active() -> bool:
		return active

	func current_tool() -> String:
		return tool

	func current_cut_mode() -> String:
		return cut_mode

	func can_confirm_cut() -> bool:
		return can_cut

	func selected_retractor() -> int:
		return retr_sel

	func is_speculum_present() -> bool:
		return spec_in

	func is_speculum_inserted() -> bool:
		return spec_ready

	func speculum_angle() -> float:
		return spec_ang

	func get_organ_target_label() -> String:
		return organ_label


class FakeVagina extends Node:
	var active: bool = false
	var tool: String = "none"
	var preset: String = "free"

	func is_active() -> bool:
		return active

	func current_tool() -> String:
		return tool

	func current_preset() -> String:
		return preset

	func tool_controller() -> Node:
		return null


class FakeVehicles extends Node:
	var occupied: Node = null
	var nearest: Node = null
	var vehicle_look_mode: String = "look"
	var vehicle_cam: String = "first"
	var place_clone: bool = false
	var bed_avail: bool = false
	var bed_actions = null

	func kind_of(v: Node) -> String:
		if v == null:
			return ""
		if v.has_meta("kind"):
			return str(v.get_meta("kind"))
		return ""

	func can_place_clone_on_bed(_n) -> bool:
		return place_clone

	func exam_bed_with_clone(_n) -> Node:
		return null

	func bed_actions_available() -> bool:
		return bed_avail and occupied != null and kind_of(occupied) == "exam_bed"

	func bed_action_list() -> Array:
		return []


class FakeWeapons extends Node:
	signal weapon_changed
	signal ammo_changed
	signal reloaded
	var armed: bool = false
	var state: String = "holstered"
	var hidden_by_mode: bool = false
	var ads: bool = false

	func is_armed() -> bool:
		return armed

	func categories() -> Array:
		return []

	func cur_def():
		return null

	func ammo_of(_id) -> Vector2i:
		return Vector2i.ZERO


class FakeSettings extends Node:
	var flight_control_mode: String = "slider"
	var infinite_reserve: bool = false
	var no_reload: bool = false
	var bullet_cam_enabled: bool = false
	var bullet_cam_chance: float = 0.0
	var bullet_hole_penetrate: bool = false
	var hit_force: float = 1.0
	var pull_force: float = 1.0

	func is_flight_slider_mode() -> bool:
		return flight_control_mode == "slider"

	func is_flight_stick_mode() -> bool:
		return flight_control_mode == "stick"

	func effective_render_scale() -> float:
		return 1.0
