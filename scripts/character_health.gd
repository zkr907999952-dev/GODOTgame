extends Node
class_name CharacterHealth
## 独立生命值。默认 100。归零时发出 died，由宿主启动布娃娃。

signal damaged(amount: float, hp: float, info: Dictionary)
signal died(info: Dictionary)
signal revived()
signal hp_changed(hp: float, max_hp: float)

const DEFAULT_MAX := 100.0

var max_hp: float = DEFAULT_MAX
var hp: float = DEFAULT_MAX
var dead: bool = false
var last_damage: Dictionary = {}
var last_amount: float = 0.0


func _ready() -> void:
	reset()


func reset(to: float = -1.0) -> void:
	if to < 0.0:
		to = max_hp
	max_hp = maxf(1.0, max_hp)
	hp = clampf(to, 0.0, max_hp)
	dead = hp <= 0.0
	hp_changed.emit(hp, max_hp)


func is_dead() -> bool:
	return dead


func apply_damage(amount: float, info: Dictionary = {}) -> float:
	if amount <= 0.0 or dead:
		last_amount = 0.0
		last_damage = info
		return 0.0
	var taken := minf(amount, hp)
	hp = maxf(0.0, hp - amount)
	last_amount = taken
	last_damage = info
	hp_changed.emit(hp, max_hp)
	damaged.emit(taken, hp, info)
	if hp <= 0.0 and not dead:
		dead = true
		died.emit(info)
	return taken


func revive(to: float = -1.0) -> void:
	dead = false
	reset(to if to >= 0.0 else max_hp)
	revived.emit()
