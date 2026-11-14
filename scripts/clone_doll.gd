extends Node3D
## 分身人偶：与本体同一模型（网格 / 贴图 / 动画 JSON / 脏器网格全部共享资源），站立待机、
## 呼吸 / 眨眼 / 头发 / 胸部物理、视线跟随当前相机，并带独立的 OrganRig（透视 / 脏器 / 拖拽 / 击腹 /
## 拳交 / 刺刀都能对它单独操作，伤口和形变各自独立；显示 / 工具参数跟随本体的设置）。

const BODY_SCENE := preload("res://assets/characters/tifa/Tifa_Web_Skinned.glb")
const SoftLocoScript := preload("res://scripts/soft_loco.gd")
const OrganRigScript := preload("res://scripts/organs/organ_rig.gd")
const CharacterLookScript := preload("res://scripts/character_look.gd")
const CHAR_LIGHT_LAYER := 1 << 17
const SEC_SYNC := ["hair_enabled", "hair_damp", "hair_inertia", "hair_gravity", "hair_wind", "blink_enabled", "breath_enabled", "breath_amp", "breath_speed"]

var source_player: Node = null
var body: Node3D
var skeleton: Skeleton3D
var loco: Node
var organs: Node


func _ready() -> void:
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
	_sync_from_source()
	organs.call("set_interact_mode", organs.get("interact_mode"))


func get_organs() -> Node:
	return organs


func get_secondary() -> RefCounted:
	return loco.get("secondary") if loco else null


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _sync_from_source() -> void:
	if not is_instance_valid(source_player):
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
