extends Node3D
## 主场景：地图（房间 / 城市大地图）切换、俯视地图传送、统一按键路由。
##
## 按键只在这里处理一次（_unhandled_input）。HUD 控件全部 FOCUS_NONE，不会因为
## 空格 / 回车（ui_accept）、Tab（ui_focus_next）、方向键（ui_left…）抢走按键。
## 持续动作（WASD/方向键、Shift、空格、Ctrl/C）由 player_controller 在 _physics_process
## 里按 InputMap 轮询，且只在「角色控制」模式下生效。

const MapViewScript = preload("res://scripts/map_view.gd")
const LightingRigScript = preload("res://scripts/lighting_rig.gd")
const CloneDollScript = preload("res://scripts/clone_doll.gd")
const GameSettingsScript = preload("res://scripts/game_settings.gd")
const BulletCamScript = preload("res://scripts/weapons/bullet_cam.gd")
const VehicleSystemScript = preload("res://scripts/vehicles/vehicle_system.gd")
## 分身上限（每个分身 = 一套蒙皮网格 + 脏器 + 物理；共享网格 / 贴图资源）
const CLONE_MAX := 8

@onready var _room: Node3D = $Room
@onready var _room_col: Node = $RoomCollision
@onready var _room_mirror: Node3D = $RoomMirror
@onready var _city: Node3D = $City
@onready var _player: CharacterBody3D = $Player
@onready var _hud: CanvasLayer = $HUD
@onready var _lighting: Node3D = $Lighting

const ROOM_SPAWN := Vector3(-0.2, 0.0, 0.3)
## 出生朝向（逻辑 yaw，0 = 面向 -Z）：背对镜子、面向房间，观察相机在房间内正面。
const ROOM_SPAWN_YAW := 0.0
## 房间墙内空间（相机碰撞用，网页 pullCameraOutOfWalls 同款盒子）；+Z 面是镜子。
const ROOM_CAMERA_BOUNDS := AABB(Vector3(-1.98, 0.05, -3.30), Vector3(5.5, 2.27, 4.25))

## 地图与出生点（城市 = 网页 city.glb 大地图，3000m×3000m）。y 由向下射线求地面。
const MAPS := [
	{"id": "room", "label": "房间（家）", "spawns": [
		{"label": "卧室", "x": -0.2, "z": 0.3, "yaw": 0.0},
	]},
	{"id": "city", "label": "城市大地图", "spawns": [
		{"label": "出生点（网页同款）", "x": 42.5, "z": 40.2, "yaw": PI},
		{"label": "林荫大道", "x": 30.0, "z": 120.0, "yaw": PI},
		{"label": "跨海大桥（坡道）", "x": -110.0, "z": 240.0, "yaw": PI * 0.5},
		{"label": "码头栈桥", "x": 290.0, "z": 249.0, "yaw": -PI * 0.5},
		{"label": "机场跑道（空旷）", "x": -1000.0, "z": 300.0, "yaw": 0.0},
	]},
]

## 每个模式的离散按键（与网页 overlay / FP 键位一致）。持续动作见文件头。
const KEYMAP := {
	"common": {
		KEY_TAB: "toggle_mode", KEY_M: "map_menu", KEY_ESCAPE: "escape", KEY_H: "hide_ui",
		KEY_X: "xray", KEY_B: "breath", KEY_T: "interact_mode", KEY_R: "reset",
		KEY_1: "dance", KEY_2: "dance", KEY_3: "dance", KEY_4: "dance",
		KEY_5: "dance", KEY_6: "dance", KEY_7: "dance", KEY_8: "dance",
		KEY_9: "dance_clear", KEY_0: "dance_clear",
	},
	"display": {KEY_F: "focus", KEY_E: "corpse_drag"},
	"control": {KEY_Z: "prone", KEY_G: "holster", KEY_Q: "weapon_wheel", KEY_E: "corpse_drag",
		KEY_1: "weapon_slot", KEY_2: "weapon_slot", KEY_3: "weapon_slot", KEY_4: "weapon_slot", KEY_5: "weapon_slot",
		KEY_6: "weapon_slot", KEY_7: "weapon_slot", KEY_8: "weapon_slot", KEY_9: "weapon_slot"},
	## 俯视地图打开时只响应这两个
	"overhead": {KEY_M: "overhead_close", KEY_ESCAPE: "overhead_close"},
}

var current_map: String = "room"
var map_view: Node3D
var _overhead_preview: bool = false
var _busy: bool = false
var _clones_root: Node3D
var settings: Node
var bullet_cam: Node
var vehicle_system: Node


func _ready() -> void:
	map_view = MapViewScript.new()
	map_view.name = "MapView"
	add_child(map_view)
	_clones_root = Node3D.new()
	_clones_root.name = "Clones"
	add_child(_clones_root)
	LightingRigScript.tune_room_shadows(_room)
	_apply_map_visibility("room")
	_place_player(ROOM_SPAWN, ROOM_SPAWN_YAW)
	settings = GameSettingsScript.new()
	settings.name = "GameSettings"
	add_child(settings)
	if _player and _player.has_method("apply_saved_look_settings"):
		_player.call("apply_saved_look_settings")
		_player.call("apply_screen_orientation")
	bullet_cam = BulletCamScript.new()
	bullet_cam.name = "BulletCam"
	add_child(bullet_cam)
	if _hud and _hud.has_method("setup"):
		_hud.call("setup", _player)
	vehicle_system = VehicleSystemScript.new()
	vehicle_system.name = "VehicleSystem"
	# After the player so occupancy cameras run later in the tree.
	add_child(vehicle_system)
	# Lower than the player (0) so occupancy cameras run AFTER the player camera.
	vehicle_system.process_priority = -20
	vehicle_system.call("setup", self, _player)
	if _hud and _hud.has_method("setup_vehicles"):
		_hud.call("setup_vehicles", vehicle_system)
	call_deferred("_bind_ballistics")
	print("game_root: ready — Tab 模式 · WASD/Shift/空格 · Ctrl/C 蹲 · Z 匍匐 · E 拖尸体 · M 地图 · H 界面 · X 透视")


func _bind_ballistics() -> void:
	if bullet_cam and bullet_cam.has_method("setup"):
		bullet_cam.call("setup", _player, settings)
		if not bullet_cam.is_connected("started", _on_bullet_cam_started):
			bullet_cam.connect("started", _on_bullet_cam_started)
	if _player == null or not _player.has_method("get_weapons"):
		return
	var ws: Node = _player.call("get_weapons")
	if ws == null:
		return
	var bal: Node = ws.get("ballistics")
	if bal and not bal.is_connected("organ_path", _on_organ_path):
		bal.connect("organ_path", _on_organ_path)


func _on_organ_path(info: Dictionary) -> void:
	if bullet_cam:
		bullet_cam.call("consider", info, info.get("projectile", {}))


func _on_bullet_cam_started() -> void:
	if _player and _player.has_method("get_weapons"):
		var ws: Node = _player.call("get_weapons")
		if ws and ws.has_method("interrupt_for_bullet_cam"):
			ws.call("interrupt_for_bullet_cam")


# ------------------------------------------------------------------ input

func key_of(event: InputEventKey) -> int:
	return int(event.physical_keycode) if event.physical_keycode != 0 else int(event.keycode)


func mode_name() -> String:
	if map_view and map_view.is_open:
		return "overhead"
	return "display" if bool(_player.call("is_display_mode")) else "control"


## 当前模式下某个键对应的动作（"" = 无）。测试 / HUD 说明也用它。
func action_for_key(key: int, mode: String = "") -> String:
	var m := mode if mode != "" else mode_name()
	if m == "overhead":
		return str(KEYMAP["overhead"].get(key, ""))
	# F: enter/exit a nearby (or occupied) vehicle; otherwise keep display-mode focus.
	if key == KEY_F and vehicle_system and vehicle_system.has_method("can_toggle") and bool(vehicle_system.call("can_toggle")):
		return "vehicle_toggle"
	var in_veh := vehicle_system != null and vehicle_system.get("occupied") != null
	if in_veh and key == KEY_V:
		return "vehicle_cam"
	var a: String = str(KEYMAP[m].get(key, ""))
	if a == "":
		a = str(KEYMAP["common"].get(key, ""))
	# While driving / on the exam bed, don't steal Q (yaw) or G (holster) from the vehicle.
	if in_veh and a in ["weapon_wheel", "holster", "weapon_slot", "prone"]:
		return ""
	return a


func _unhandled_input(event: InputEvent) -> void:
	if map_view.is_open and (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):
		if map_view.handle_input(event):
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	# 松开 Q：轮盘选中
	if not ke.pressed and key_of(ke) == KEY_Q and _hud.call("is_wheel_open"):
		_hud.call("close_weapon_wheel", true)
		get_viewport().set_input_as_handled()
		return
	if not ke.pressed or ke.echo:
		return
	var k := key_of(ke)
	var action := action_for_key(k)
	if action == "":
		return
	run_action(action, k)
	get_viewport().set_input_as_handled()


func run_action(action: String, key: int = 0) -> void:
	match action:
		"toggle_mode":
			_player.call("toggle_play_mode")
		"map_menu":
			_hud.call("toggle_map_panel")
		"escape":
			if _hud.call("close_panels"):
				pass
			else:
				_player.call("escape_mouse")
		"hide_ui":
			_hud.call("toggle_ui_hidden")
		"xray":
			toggle_xray()
		"breath":
			var sec: RefCounted = _player.call("get_secondary")
			if sec:
				sec.set("breath_enabled", not bool(sec.get("breath_enabled")))
		"interact_mode":
			_hud.call("cycle_interact_mode")
		"reset":
			# 角色控制 + 持枪：R = 换弹；否则 R = 复位视角 / 腹部形变（网页 R）
			if _player.call("weapon_armed"):
				_player.call("get_weapons").call("reload")
			else:
				_player.call("reset_view_and_belly")
		"weapon_slot":
			_player.call("get_weapons").call("select_slot", key - KEY_1)
		"holster":
			var ws: Node = _player.call("get_weapons")
			if ws.call("is_armed"):
				ws.call("holster")
			elif ws.get("defs").size() > 0:
				ws.call("select", ws.get("last_id") if str(ws.get("last_id")) != "" else ws.get("defs")[0].id)
		"weapon_wheel":
			_hud.call("open_weapon_wheel")
		"focus":
			_player.call("cycle_tp_focus")
		"prone":
			_player.call("toggle_prone")
		"dance":
			_player.call("dance", key - KEY_0)
		"dance_clear":
			_player.call("dance", 0)
		"overhead_close":
			close_overhead()
		"corpse_drag":
			# E：切换拖拽尸体。T 仍是腹部互动模式循环，两者并存。
			if _player and _player.has_method("toggle_corpse_drag"):
				_player.call("toggle_corpse_drag")
		"vehicle_toggle":
			if vehicle_system and vehicle_system.has_method("try_toggle"):
				vehicle_system.call("try_toggle")
		"vehicle_cam":
			if vehicle_system and vehicle_system.has_method("toggle_vehicle_cam"):
				vehicle_system.call("toggle_vehicle_cam")
	_hud.call("sync")


# ------------------------------------------------------------------ maps

func get_maps() -> Array:
	return MAPS


func _map_def(id: String) -> Dictionary:
	for m in MAPS:
		if str(m["id"]) == id:
			return m
	return MAPS[0]


func _apply_map_visibility(id: String, notify_vehicles: bool = true) -> void:
	var in_room := id == "room"
	_room.visible = in_room
	if _room_mirror:
		_room_mirror.visible = in_room  # 镜子只在房间
	_city.visible = not in_room
	if not in_room and _city.has_method("ensure_collisions"):
		_city.call("ensure_collisions")
	_set_colliders_enabled(_city, not in_room)
	_set_colliders_enabled(_room_col, in_room)
	_player.set("camera_bounds", ROOM_CAMERA_BOUNDS if in_room else AABB())
	_set_city_env(not in_room)
	# Overhead preview from the room must NOT notify the vehicle system —
	# that was hiding the home exam bed and spawning city vehicles mid-map-open.
	if notify_vehicles and vehicle_system and vehicle_system.has_method("notify_map"):
		vehicle_system.call("notify_map", id)


## 光照 / 环境 / 雾按地图切换（scripts/lighting_rig.gd：房间 = 网页 StudioLights，城市 = CityLights + WorldClip 雾）。
func _set_city_env(on: bool) -> void:
	if _lighting and _lighting.has_method("set_map"):
		_lighting.call("set_map", "city" if on else "room")


## 切换地图并传送到出生点。保持当前模式（展示互动 / 角色控制）。
func switch_map(id: String, spawn_i: int = 0) -> void:
	var m := _map_def(id)
	var spawns: Array = m["spawns"]
	var s: Dictionary = spawns[clampi(spawn_i, 0, spawns.size() - 1)]
	close_overhead(false)
	# 活着的分身仍随地图清掉；已死亡的布娃娃尸体整局保留，只在非当前地图时冻结隐藏。
	_clear_living_clones()
	current_map = str(m["id"])
	_apply_map_visibility(current_map)
	_sync_corpse_maps()
	if current_map == "room":
		_place_player(Vector3(float(s["x"]), 0.0, float(s["z"])), float(s["yaw"]))
	else:
		await _place_on_ground(float(s["x"]), float(s["z"]), float(s["yaw"]))
	print("game_root: map=", current_map, " spawn=", s["label"], " pos=", _player.global_position)
	_hud.call("sync")


func _place_player(p: Vector3, yaw: float) -> void:
	_player.global_position = p
	_player.velocity = Vector3.ZERO
	_player.call("set_facing", yaw)
	_player.reset_physics_interpolation()


## 向下射线找地面（城市）。新建 / 刚启用的碰撞体要等一个物理帧才进入空间。
func ground_at(x: float, z: float, top: float = 320.0) -> Variant:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -60.0, z), 1)
	q.exclude = [_player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else hit["position"]


func _place_on_ground(x: float, z: float, yaw: float, top: float = 320.0) -> void:
	_busy = true
	_player.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var g: Variant = ground_at(x, z, top)
	var y: float = (g as Vector3).y if g != null else 2.0
	_place_player(Vector3(x, y + 0.02, z), yaw)
	_player.set_physics_process(true)
	_busy = false


# ------------------------------------------------------------------ overhead map（网页 CityMapPanel）

func open_overhead() -> void:
	if map_view.is_open:
		return
	if current_map == "room":
		# 网页：在家打开地图时显示城市、以城市出生点为中心
		_overhead_preview = true
		_apply_map_visibility("city", false)
	var s: Dictionary = _map_def("city")["spawns"][0]
	var center := _player.global_position if current_map == "city" else Vector3(float(s["x"]), 0.0, float(s["z"]))
	_player.set("input_locked", true)
	_player.set_physics_process(false)
	map_view.open(center, _player.global_position if current_map == "city" else center)
	_hud.call("set_overhead", true)


func close_overhead(restore: bool = true) -> void:
	if not map_view.is_open:
		return
	map_view.close()
	map_view.set_marker(null)
	if _overhead_preview and restore:
		_apply_map_visibility("room", false)
	_overhead_preview = false
	_player.set("input_locked", false)
	_player.set_physics_process(true)
	_hud.call("set_overhead", false)


## 网页「传送」：到选点（城市）。
func overhead_teleport() -> void:
	if not map_view.is_open or map_view.marker == null:
		return
	var p: Vector3 = map_view.marker
	_overhead_preview = false
	close_overhead(false)
	current_map = "city"
	_apply_map_visibility("city")
	await _place_on_ground(p.x, p.z, float(_player.get("_body_logic_yaw")), p.y + 3.0)
	_hud.call("sync")


## 网页「回家」
func overhead_go_home() -> void:
	close_overhead(false)
	switch_map("room", 0)


func _set_colliders_enabled(root: Node, enabled: bool) -> void:
	var bodies: Array = root.find_children("*", "StaticBody3D", true, false)
	if root is StaticBody3D:
		bodies.append(root)
	for body in bodies:
		for cs in body.get_children():
			if cs is CollisionShape3D:
				(cs as CollisionShape3D).disabled = not enabled


# ------------------------------------------------------------------ 分身

func clone_count() -> int:
	var n := 0
	for c in _clones_root.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func get_clones() -> Array:
	return _clones_root.get_children().filter(func(c): return not c.is_queued_for_deletion())


func all_organ_rigs() -> Array:
	var out: Array = []
	if _player and _player.has_method("get_organs"):
		var po: Node = _player.call("get_organs")
		if po:
			out.append(po)
	for c in get_clones():
		if c and c.has_method("get_organs"):
			var co: Node = c.call("get_organs")
			if co:
				out.append(co)
	return out


func apply_xray_enabled(on: bool) -> void:
	for o in all_organ_rigs():
		if o and o.has_method("set_xray_enabled"):
			o.call("set_xray_enabled", on)


func apply_xray_amount(v: float) -> void:
	for o in all_organ_rigs():
		if o and o.has_method("set_xray_amount"):
			o.call("set_xray_amount", v)


func apply_show_organs(on: bool) -> void:
	for o in all_organ_rigs():
		if o and o.has_method("set_show_organs"):
			o.call("set_show_organs", on)


func toggle_xray() -> void:
	var org: Node = _player.call("get_organs") if _player and _player.has_method("get_organs") else null
	if org == null:
		return
	org.call("toggle_xray")
	# 尸体分身不再从本体逐帧同步，这里把透视开关同步到所有脏器（含布娃娃尸体）。
	apply_xray_enabled(bool(org.get("xray_enabled")))
	apply_xray_amount(float(org.get("xray_amount")))
	if org.get("show_organs") != null:
		apply_show_organs(bool(org.get("show_organs")))


## 视线（当前相机中心射线）所指的地面位置；没打到东西就取前方 3m 再向下找地面。
func clone_spawn_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	var o := cam.global_position
	var d := -cam.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(o, o + d * 40.0, 1)
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)
	var p: Vector3 = o + d * 3.0
	if not hit.is_empty():
		p = hit["position"]
		var n: Vector3 = hit["normal"]
		if n.y < 0.6:
			# 打到墙：退回到墙前 0.35m
			p += n * 0.35
	# 向下找地面
	var q2 := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.5, p + Vector3.DOWN * 30.0, 1)
	q2.exclude = [_player.get_rid()]
	var g := space.intersect_ray(q2)
	if not g.is_empty():
		p = g["position"]
	else:
		p.y = _player.global_position.y
	return p


## 菜单「创建分身」：返回 HUD 提示文字。
func spawn_clone(at: Variant = null) -> String:
	if clone_count() >= CLONE_MAX:
		return "分身已达上限（%d 个），先「清除所有分身」" % CLONE_MAX
	var p: Vector3 = at if at != null else clone_spawn_point()
	var c := CloneDollScript.new()
	c.name = "Clone%d" % (Time.get_ticks_msec() % 100000)
	c.set("source_player", _player)
	c.set("spawn_map", current_map)
	_clones_root.add_child(c)
	var cam := get_viewport().get_camera_3d()
	var to := cam.global_position - p if cam else Vector3.BACK
	to.y = 0.0
	var yaw := atan2(to.x, to.z) if to.length_squared() > 1e-6 else 0.0
	c.global_transform = Transform3D(Basis(Vector3.UP, yaw), p)
	var n := clone_count()
	print("game_root: clone #", n, " at ", p)
	return "已创建分身 %d / %d" % [n, CLONE_MAX]


## 菜单「清除所有分身」
func clear_clones() -> String:
	var n := 0
	for c in _clones_root.get_children():
		if c.is_queued_for_deletion():
			continue
		_clones_root.remove_child(c)
		c.queue_free()
		n += 1
	return "已清除 %d 个分身" % n if n > 0 else "当前没有分身"


func _clear_living_clones() -> void:
	if _clones_root == null:
		return
	for c in _clones_root.get_children():
		if c.is_queued_for_deletion():
			continue
		if c.has_method("is_dead") and bool(c.call("is_dead")):
			continue
		_clones_root.remove_child(c)
		c.queue_free()


func _sync_corpse_maps() -> void:
	if _clones_root == null:
		return
	for c in _clones_root.get_children():
		if c.is_queued_for_deletion():
			continue
		if not (c.has_method("is_dead") and bool(c.call("is_dead"))):
			continue
		var on := str(c.get("spawn_map")) == current_map
		if c.has_method("set_map_active"):
			c.call("set_map_active", on)
		else:
			c.visible = on
