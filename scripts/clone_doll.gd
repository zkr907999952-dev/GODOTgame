extends Node3D
## 分身人偶：与本体同一模型（网格 / 贴图 / 动画 JSON / 脏器网格全部共享资源），站立待机、
## 呼吸 / 眨眼 / 头发 / 胸部物理、视线跟随当前相机，并带独立的 OrganRig（透视 / 脏器 / 拖拽 / 击腹 /
## 拳交 / 刺刀都能对它单独操作，伤口和形变各自独立；显示 / 工具参数跟随本体的设置）。
## 生命值与布娃娃各自独立；被击杀后进入布娃娃且尸体不消失。

const BODY_SCENE := preload("res://assets/characters/tifa/Tifa_Web_Skinned.glb")
const SoftLocoScript := preload("res://scripts/soft_loco.gd")
const OrganRigScript := preload("res://scripts/organs/organ_rig.gd")
const CharacterLookScript := preload("res://scripts/character_look.gd")
const CharacterHealthScript := preload("res://scripts/character_health.gd")
const RagdollSystemScript := preload("res://scripts/ragdoll_system.gd")
const CHAR_LIGHT_LAYER := 1 << 17
const SEC_SYNC := ["hair_enabled", "hair_damp", "hair_inertia", "hair_gravity", "hair_wind", "blink_enabled", "breath_enabled", "breath_amp", "breath_speed"]

var source_player: Node = null
var body: Node3D
var skeleton: Skeleton3D
var loco: Node
var organs: Node
var health: Node
var ragdoll: Node
var body_hit: StaticBody3D
var spawn_map: String = "room"
var _map_visible: bool = true


func _ready() -> void:
	add_to_group("wound_body")
	add_to_group("health_body")
	var hit := StaticBody3D.new()
	hit.name = "BodyHit"
	hit.collision_layer = 2
	hit.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.64
	cs.shape = cyl
	cs.position = Vector3(0, 0.82, 0)
	hit.add_child(cs)
	add_child(hit)
	body_hit = hit
	body = BODY_SCENE.instantiate() as Node3D
	body.name = "Body"
	add_child(body)
	CharacterLookScript.apply(body)
	for n in body.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).layers |= CHAR_LIGHT_LAYER
	skeleton = _find_skeleton(body)
	loco = SoftLocoScript.new()
	loco.name = "SoftLoco"
	add_child(loco)
	if skeleton == null or not loco.setup(skeleton):
		push_warning("clone: SoftLoco failed")
	organs = OrganRigScript.new()
	organs.name = "OrganRig"
	add_child(organs)
	if skeleton == null or not organs.setup(skeleton):
		push_warning("clone: organs failed")
	organs.set("secondary", loco.get("secondary"))
	health = CharacterHealthScript.new()
	health.name = "Health"
	add_child(health)
	health.died.connect(_on_character_died)
	ragdoll = RagdollSystemScript.new()
	ragdoll.name = "Ragdoll"
	add_child(ragdoll)
	if skeleton:
		ragdoll.call("setup", skeleton, self)
	_sync_from_source()
	organs.call("set_interact_mode", organs.get("interact_mode"))


func get_organs() -> Node:
	return organs


func get_skeleton() -> Skeleton3D:
	return skeleton


func get_health() -> Node:
	return health


func get_hp() -> float:
	return float(health.hp) if health else 100.0


func get_max_hp() -> float:
	return float(health.max_hp) if health else 100.0


func is_dead() -> bool:
	return health != null and bool(health.dead)


func apply_damage(amount: float, info: Dictionary = {}) -> float:
	if health == null:
		return 0.0
	return float(health.call("apply_damage", amount, info))


func get_ragdoll() -> Node:
	return ragdoll


func get_secondary() -> RefCounted:
	return loco.get("secondary") if loco else null


func get_head_world_position() -> Vector3:
	if is_dead() and ragdoll and ragdoll.get("bones"):
		var pb = ragdoll.get("bones").get("C_Head_a")
		if pb and is_instance_valid(pb):
			return (pb as Node3D).global_position + Vector3.UP * 0.16
	if skeleton:
		var i := skeleton.find_bone("C_Head_a")
		if i >= 0:
			return (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin + Vector3.UP * 0.16
	return global_position + Vector3.UP * 1.62


func set_map_active(on: bool) -> void:
	_map_visible = on
	visible = on
	if is_dead() and ragdoll:
		ragdoll.call("set_map_frozen", not on)


func _set_pose_drivers_frozen(on: bool) -> void:
	if loco:
		loco.set("frozen", on)
	var sec := get_secondary()
	if sec:
		sec.set("corpse_mode", on)
		if on:
			sec.set("breath_enabled", false)
			sec.set("blink_enabled", false)
	if organs:
		organs.set("frozen", on)


func _on_character_died(info: Dictionary) -> void:
	_set_pose_drivers_frozen(true)
	if body_hit:
		body_hit.collision_layer = 0
		for c in body_hit.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = true
	var dir: Vector3 = info.get("dir", Vector3.FORWARD)
	var hit: Vector3 = info.get("entry", info.get("hit", Vector3.ZERO))
	var par: Dictionary = info.get("par", {})
	var col = info.get("collider")
	var imp := Vector3.ZERO
	if ragdoll and ragdoll.has_method("impulse_from_ballistics") and not par.is_empty():
		imp = ragdoll.call("impulse_from_ballistics", par, dir)
	elif dir.length_squared() > 1e-8:
		imp = dir.normalized() * 6.0
	if ragdoll:
		ragdoll.call("start", imp, hit, col)
	print("clone: died, ragdoll started (", name, ")")


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _sync_from_source() -> void:
	if not is_instance_valid(source_player) or is_dead():
		return
	var src_org: Node = source_player.call("get_organs")
	if src_org and organs:
		organs.call("copy_settings_from", src_org)
	var ssec: RefCounted = source_player.call("get_secondary")
	var sec := get_secondary()
	if ssec and sec:
		for k in SEC_SYNC:
			sec.set(k, ssec.get(k))


func _physics_process(delta: float) -> void:
	if is_dead():
		if loco:
			loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, delta, 0.0)
		return
	_sync_from_source()
	var sec := get_secondary()
	var cam := get_viewport().get_camera_3d()
	var navel_t: float = organs.call("navel_pose_t") if organs else -1.0
	if sec and cam:
		sec.call("clear_body_look")
		if navel_t >= 0.0:
			sec.call("clear_gaze")
		else:
			sec.call("set_gaze_target", cam.global_position)
	if loco:
		loco.set("navel_t", navel_t)
		loco.set("navel_stir", organs.get("navel_stir_off") if organs else Vector2.ZERO)
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, delta, 1.65)
