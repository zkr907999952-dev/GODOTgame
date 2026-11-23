extends Node3D
## 分身人偶：与本体同一模型（网格 / 贴图 / 动画 JSON / 脏器网格全部共享资源），站立待机、
## 呼吸 / 眨眼 / 头发 / 胸部物理、视线跟随当前相机，并带独立的 OrganRig（透视 / 脏器 / 拖拽 / 击腹 /
## 拳交 / 刺刀都能对它单独操作，伤口和形变各自独立；显示 / 工具参数跟随本体的设置）。
## 生命值与布娃娃各自独立；被击杀后进入布娃娃且尸体不消失。

const BODY_SCENE := preload("res://assets/characters/tifa/Tifa_Web_Skinned.glb")
const SoftLocoScript := preload("res://scripts/soft_loco.gd")
const OrganRigScript := preload("res://scripts/organs/organ_rig.gd")
const SurgerySystemScript := preload("res://scripts/surgery/surgery_system.gd")
const CharacterLookScript := preload("res://scripts/character_look.gd")
const CharacterHealthScript := preload("res://scripts/character_health.gd")
const RagdollSystemScript := preload("res://scripts/ragdoll_system.gd")
const HitReactionScript := preload("res://scripts/hit_reaction.gd")
const CharacterActionsScript := preload("res://scripts/body/character_actions.gd")
const CombatDamage := preload("res://scripts/combat_damage.gd")
const CharacterHitboxesScript := preload("res://scripts/character_hitboxes.gd")
const GetupBlendScript := preload("res://scripts/getup_blend.gd")
const CHAR_LIGHT_LAYER := 1 << 17
const SEC_SYNC := ["hair_enabled", "hair_damp", "hair_inertia", "hair_gravity", "hair_wind", "blink_enabled", "breath_enabled", "breath_amp", "breath_speed"]

var source_player: Node = null
var body: Node3D
var skeleton: Skeleton3D
var loco: Node
var organs: Node
var surgery: Node
var health: Node
var ragdoll: Node
var hit_react: Node
var actions
var body_hit: StaticBody3D
var spawn_map: String = "room"
var _map_visible: bool = true
var on_exam_bed: Node = null
var occupancy: String = ""
var hitboxes: Node3D
var _getup: RefCounted = null


func _ready() -> void:
	add_to_group("wound_body")
	add_to_group("health_body")
	add_to_group("clone_dolls")
	var hit := StaticBody3D.new()
	hit.name = "BodyHit"
	hit.collision_layer = 2
	hit.collision_mask = 1 | 2
	var cs := CollisionShape3D.new()
	# 0.3.8：与本体一致改为胶囊；精细命中由 CharacterHitboxes（第 6 层）负责。
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.64
	cs.shape = cap
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
	# 特写弹孔走与本体相同的手术腹网冲压，分身也要挂 SurgerySystem。
	surgery = SurgerySystemScript.new()
	surgery.name = "SurgerySystem"
	add_child(surgery)
	if skeleton:
		surgery.call("setup", self, skeleton, organs)
	health = CharacterHealthScript.new()
	health.name = "Health"
	add_child(health)
	health.died.connect(_on_character_died)
	ragdoll = RagdollSystemScript.new()
	ragdoll.name = "Ragdoll"
	add_child(ragdoll)
	if skeleton:
		ragdoll.call("setup", skeleton, self)
	if skeleton:
		hitboxes = CharacterHitboxesScript.new()
		hitboxes.name = "Hitboxes"
		add_child(hitboxes)
		hitboxes.call("setup", skeleton, self)
	health.revived.connect(_on_character_revived)
	hit_react = HitReactionScript.new()
	hit_react.name = "HitReaction"
	add_child(hit_react)
	if skeleton:
		hit_react.call("setup", skeleton, self)
	actions = CharacterActionsScript.new()
	_sync_from_source()
	organs.call("set_interact_mode", organs.get("interact_mode"))


## 0.4.07 附身：分身的持枪外观（离开持枪的身体时保留），以及与本体交换的身体节点。
var held_weapon: String = ""
var _held_visual: Node3D = null
const MAX_HP := 100.0


func rig_nodes() -> Dictionary:
	return {"body": body, "loco": loco, "organs": organs, "surgery": surgery,
		"ragdoll": ragdoll, "hit_react": hit_react, "hitboxes": hitboxes}


func adopt_rig(r: Dictionary) -> void:
	body = r["body"]
	loco = r["loco"]
	organs = r["organs"]
	surgery = r["surgery"]
	ragdoll = r["ragdoll"]
	hit_react = r["hit_react"]
	hitboxes = r["hitboxes"]
	skeleton = _find_skeleton(body)
	if surgery:
		surgery.set("player", self)
	if ragdoll:
		ragdoll.set("_host", self)
	if hit_react:
		hit_react.set("_host", self)
	if hitboxes:
		hitboxes.set("host", self)
		for hb in hitboxes.call("bodies"):
			if is_instance_valid(hb):
				(hb as Node).set_meta("hitbox_host", self)
		hitboxes.call("set_enabled", _map_visible and not is_dead())
	_getup = null
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	body.visible = true
	if loco:
		loco.set("frozen", false)
		loco.set("weapon_ik", false)
	var sec := get_secondary()
	if sec:
		sec.set("corpse_mode", false)
	if organs:
		organs.set("frozen", false)


func get_stance() -> String:
	return str(loco.get("mode")) if loco else "stand"


func set_stance(st: String) -> void:
	if loco:
		loco.call("set_mode", st if st in ["stand", "crouch", "prone"] else "stand")


## 留下手里那把枪的外观：挂在右手骨骼上，身体姿态冻结在持枪那一刻。
func hold_weapon_visual(id: String, scene: PackedScene, xf: Transform3D) -> void:
	drop_weapon_visual()
	held_weapon = id
	if scene == null or skeleton == null:
		return
	var att := BoneAttachment3D.new()
	att.name = "HeldWeapon"
	att.bone_name = "R_Hand_a"
	skeleton.add_child(att)
	var gun := scene.instantiate() as Node3D
	if gun:
		att.add_child(gun)
		gun.global_transform = xf
	_held_visual = att
	if loco:
		loco.set("frozen", true)


func drop_weapon_visual() -> String:
	var id := held_weapon
	held_weapon = ""
	if _held_visual and is_instance_valid(_held_visual):
		_held_visual.queue_free()
	_held_visual = null
	if loco and not is_on_exam_bed() and not is_dead():
		loco.set("frozen", false)
	var sec := get_secondary()
	if sec and not is_dead():
		sec.set("corpse_mode", false)
	return id


func get_organs() -> Node:
	return organs


func get_surgery() -> Node:
	return surgery


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
	var taken := float(health.call("apply_damage", amount, info))
	if taken > 0.0 and not is_dead() and hit_react:
		hit_react.call("apply_from_info", info, taken)
	return taken


func apply_hit_reaction(info: Dictionary) -> void:
	if is_dead() or hit_react == null:
		return
	if hit_react.get("last_amp") > 0.0 and hit_react.is_active():
		return
	hit_react.call("apply_from_info", info, float(info.get("damage", 20.0)))


func get_actions():
	return actions


func is_ragdoll() -> bool:
	return ragdoll != null and bool(ragdoll.get("active"))


func get_hit_reaction() -> Node:
	return hit_react


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


func get_hitboxes() -> Node3D:
	return hitboxes


func set_map_active(on: bool) -> void:
	_map_visible = on
	visible = on
	if hitboxes:
		hitboxes.call("set_enabled", on and not is_dead())
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
	_getup = null
	if hitboxes:
		hitboxes.call("set_enabled", false)
	_set_pose_drivers_frozen(true)
	if body_hit:
		body_hit.collision_layer = 0
		for c in body_hit.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = true
	var dir: Vector3 = CombatDamage.vec3_of(info, ["dir"], Vector3.FORWARD)
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	else:
		dir = dir.normalized()
	var hit: Vector3 = CombatDamage.vec3_of(info, ["entry", "hit", "pos"], Vector3.ZERO)
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


## 0.3.8「复原身体」：满血；尸体复活；清伤口 / 内脏损伤 / 手术切口 / 腹部弹孔。
func restore_body() -> void:
	if health == null:
		return
	if is_dead():
		health.call("revive", float(health.get("max_hp")))
	else:
		health.call("reset", float(health.get("max_hp")))
	if organs and organs.has_method("reset_interaction"):
		organs.call("reset_interaction")
	if hit_react and hit_react.has_method("clear"):
		hit_react.call("clear")
	if surgery and surgery.has_method("restore_body"):
		surgery.call("restore_body")


## 复活：布娃娃当前姿态 → 平滑过渡到蹲姿 → 站起（GetupBlend），原点移到尸体骨盆下方的地面。
func _on_character_revived() -> void:
	var snap: Array[Transform3D] = []
	if ragdoll and bool(ragdoll.get("active")) and skeleton:
		snap = GetupBlendScript.capture_world(skeleton)
	var feet := global_position
	if ragdoll and bool(ragdoll.get("active")) and ragdoll.has_method("get_pelvis_point"):
		var p: Vector3 = ragdoll.call("get_pelvis_point")
		feet = Vector3(p.x, global_position.y, p.z)
		var w3 := get_world_3d()
		if w3:
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.8, p + Vector3.DOWN * 3.0, 1)
			var hit := w3.direct_space_state.intersect_ray(q)
			if not hit.is_empty():
				feet = hit["position"]
	if ragdoll:
		if not _map_visible:
			ragdoll.call("set_map_frozen", false)
		ragdoll.call("stop")
	_set_pose_drivers_frozen(false)
	var sec := get_secondary()
	if sec:
		sec.set("breath_enabled", true)
		sec.set("blink_enabled", true)
		sec.set("hair_enabled", true)
	if body_hit:
		body_hit.collision_layer = 2
		for c in body_hit.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = false
	if hitboxes:
		hitboxes.call("set_enabled", _map_visible)
	if not is_on_exam_bed():
		global_position = feet
	_getup = null
	if loco:
		loco.call("set_mode", "crouch" if not snap.is_empty() else "stand")
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 0.0)
	if not snap.is_empty() and skeleton and not is_on_exam_bed():
		_getup = GetupBlendScript.new()
		_getup.call("begin", skeleton, snap)
	print("clone: revived (", name, ")")


func is_getting_up() -> bool:
	return _getup != null


func _tick_getup(delta: float) -> void:
	if _getup == null:
		return
	if bool(_getup.call("apply", delta)) and loco:
		loco.call("set_mode", "stand")
	if not bool(_getup.call("is_active")):
		_getup = null


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
	if is_dead():
		# 死后仍跟随全局透视 / 脏器可见性，否则布娃娃尸体透视会掉。
		if src_org and organs:
			organs.set("xray_enabled", src_org.get("xray_enabled"))
			organs.set("xray_amount", src_org.get("xray_amount"))
			if organs.get("show_organs") != src_org.get("show_organs") and organs.has_method("set_show_organs"):
				organs.call("set_show_organs", bool(src_org.get("show_organs")))
		return
	if src_org and organs:
		organs.call("copy_settings_from", src_org)
	var ssec: RefCounted = source_player.call("get_secondary")
	var sec := get_secondary()
	if ssec and sec:
		for k in SEC_SYNC:
			sec.set(k, ssec.get(k))


func is_on_exam_bed() -> bool:
	return on_exam_bed != null and is_instance_valid(on_exam_bed)


func get_loco() -> Node:
	return loco


func place_on_exam_bed(bed: Node) -> bool:
	if bed == null or is_dead():
		return false
	if on_exam_bed and is_instance_valid(on_exam_bed) and on_exam_bed != bed:
		leave_exam_bed()
	on_exam_bed = bed
	occupancy = "exam_bed"
	if bed.has_method("set_patient"):
		bed.call("set_patient", self)
	elif bed.has_method("on_enter"):
		bed.call("on_enter", self)
	_apply_bed_pose(0.016)
	return true


func leave_exam_bed() -> void:
	var bed := on_exam_bed
	on_exam_bed = null
	occupancy = ""
	if bed and is_instance_valid(bed):
		if bed.has_method("on_exit"):
			bed.call("on_exit", self)
		elif bed.get("patient") == self:
			bed.set("patient", null)
			bed.set("occupied", false)
	if loco:
		loco.set("frozen", false)
	if skeleton:
		var ExamPose = preload("res://scripts/vehicles/exam_pose.gd")
		ExamPose.clear(skeleton)
	if has_node("Body"):
		var body: Node3D = get_node("Body")
		body.position = Vector3.ZERO
		body.rotation = Vector3.ZERO


func _vehicle_system() -> Node:
	var n: Node = get_parent()
	while n:
		if n.get("vehicle_system") != null:
			return n.get("vehicle_system")
		n = n.get_parent()
	var tree := get_tree()
	if tree:
		return tree.root.find_child("VehicleSystem", true, false)
	return null


func _apply_bed_pose(delta: float) -> void:
	if not is_on_exam_bed():
		return
	var vs := _vehicle_system()
	if vs and vs.has_method("apply_patient_pose"):
		vs.call("apply_patient_pose", self, on_exam_bed, delta)
	if actions:
		actions.step(delta, organs)
		actions.apply_pose(skeleton, organs)


func _physics_process(delta: float) -> void:
	if is_on_exam_bed() and not is_dead():
		_sync_from_source()
		_apply_bed_pose(delta)
		return
	if is_dead():
		_sync_from_source()
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
		_tick_getup(delta)
		if hit_react:
			var skip := PackedStringArray(["L_Shoulder_a", "R_Shoulder_a"])
			hit_react.call("apply_to_skeleton", delta, skip)
			if hit_react.has_method("apply_cover"):
				hit_react.call("apply_cover", delta)
		if actions:
			actions.step(delta, organs)
			actions.apply_pose(skeleton, organs)
