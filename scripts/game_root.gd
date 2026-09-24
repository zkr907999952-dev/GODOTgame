extends Node3D
## 主场景：默认在房间，按 M 切换城市。挂载中文 HUD。

@onready var _room: Node3D = $Room
@onready var _room_mirror: Node3D = $RoomMirror
@onready var _city: Node3D = $City
@onready var _player: CharacterBody3D = $Player
@onready var _hud: CanvasLayer = $HUD

const ROOM_SPAWN := Vector3(-0.2, 0.1, 0.3)
const CITY_SPAWN := Vector3(42.5, 2.0, 40.2)

var _in_city: bool = false


func _ready() -> void:
	_show_home()
	if _hud and _hud.has_method("setup"):
		_hud.call("setup", _player)
	print("game_root: ready — Tab 模式, WASD+Shift+Space, hold Ctrl/C crouch, Z prone, 1-8 dance, M map, HUD 设置/互动/摄像机")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			if _in_city:
				_show_home()
			else:
				_show_city()


func _show_home() -> void:
	_in_city = false
	_room.visible = true
	if _room_mirror:
		_room_mirror.visible = true
	_city.visible = false
	_set_colliders_enabled(_city, false)
	_set_colliders_enabled(_room, true)
	_player.global_position = ROOM_SPAWN
	_player.velocity = Vector3.ZERO
	print("game_root: home (room)")


func _show_city() -> void:
	_in_city = true
	_room.visible = false
	if _room_mirror:
		_room_mirror.visible = false
	_city.visible = true
	if _city.has_method("ensure_collisions"):
		_city.ensure_collisions()
	_set_colliders_enabled(_room, false)
	_set_colliders_enabled(_city, true)
	_player.global_position = CITY_SPAWN
	_player.velocity = Vector3.ZERO
	print("game_root: city")


func _set_colliders_enabled(root: Node, enabled: bool) -> void:
	for body in root.find_children("*", "StaticBody3D", true, false):
		for cs in body.get_children():
			if cs is CollisionShape3D:
				(cs as CollisionShape3D).disabled = not enabled
