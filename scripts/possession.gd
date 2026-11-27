extends Node
## 0.4.07 附身：分身清单、选中高亮、附身（交换身体，镜头过渡到新视角）、第一人称瞄准分身即可附身。
##
## 生命值按「角色身份」定义而不是按身体：
##   受控角色（Player 节点上的 CharacterHealth）max_hp = CONTROLLED_MAX_HP（1000）；
##   分身（CloneDoll 上的 CharacterHealth）max_hp = CLONE_MAX_HP（100）。
## 附身时两具身体互换，各自的血量按百分比换算到新身份的上限（例：分身 50/100 → 被附身后 500/1000）。
##
## 「身体」= Body 网格骨架 + SoftLoco + OrganRig + SurgerySystem + Ragdoll + HitReaction + Hitboxes，
## 这些节点整体在 Player 与分身之间换挂，所以切口 / 外露肠子 / 弹孔 / 脏器形变等全部原样保留；
## 检查床、蹲 / 趴、持枪由这里额外交接。

signal selection_changed(clone: Node)
signal possessed(clone: Node)

const CONTROLLED_MAX_HP := 1000.0
const CLONE_MAX_HP := 100.0
const TRANSITION_SEC := 0.65
const OUTLINE_COLOR := Color(0.35, 0.95, 1.0, 1.0)
const OUTLINE_WIDTH := 0.006
const AIM_RANGE := 25.0

var game: Node
var player: Node
var selected: Node = null
var aimed: Node = null
var last_message: String = ""
var possess_count: int = 0

var _outline_mat: StandardMaterial3D
var _outlined: Array[MeshInstance3D] = []
var _cam: Camera3D = null
var _cam_from: Transform3D
var _fov_from: float = 60.0
var _cam_t: float = 1.0


func setup(g: Node, p: Node) -> void:
	game = g
	player = p
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	_outline_mat.grow = true
	_outline_mat.grow_amount = OUTLINE_WIDTH
	_outline_mat.albedo_color = OUTLINE_COLOR
	_outline_mat.disable_receive_shadows = true
	_outline_mat.no_depth_test = false


# ------------------------------------------------------------------ 清单 / 状态

func clones() -> Array:
	if game and game.has_method("get_clones"):
		return game.call("get_clones")
	return []


func clone_label(c: Node) -> String:
	var i := clones().find(c)
	return "分身 %d" % (i + 1) if i >= 0 else "分身"


func clone_status(c: Node) -> String:
	if c == null or not is_instance_valid(c):
		return ""
	if bool(c.call("is_dead")):
		return "死亡（布娃娃）"
	var tags: PackedStringArray = []
	if c.has_method("is_on_exam_bed") and bool(c.call("is_on_exam_bed")):
		tags.append("检查床")
	var s: Node = c.call("get_surgery") if c.has_method("get_surgery") else null
	if s:
		if bool(s.call("is_active")):
			tags.append("手术中")
		elif bool(s.get("cut_open")) or bool(s.get("flap_peeled")) or int(s.get("bullet_holes")) > 0:
			tags.append("有手术切口")
	if str(c.get("held_weapon")) != "":
		tags.append("持枪")
	var st := str(c.call("get_stance")) if c.has_method("get_stance") else "stand"
	if c.has_method("is_getting_up") and bool(c.call("is_getting_up")):
		tags.append("起身中")
	elif st == "crouch":
		tags.append("蹲下")
	elif st == "prone":
		tags.append("趴下")
	elif not tags.has("检查床"):
		tags.append("站立")
	return "、".join(tags)


func clone_line(c: Node) -> String:
	return "%s · %d/%d · %s" % [clone_label(c), int(ceil(float(c.call("get_hp")))), int(float(c.call("get_max_hp"))), clone_status(c)]


func can_possess(c: Node) -> bool:
	return _possess_block_reason(c) == ""


func _possess_block_reason(c: Node) -> String:
	if c == null or not is_instance_valid(c) or c.is_queued_for_deletion():
		return "请先选择一个分身"
	if bool(c.call("is_dead")):
		return "死亡的布娃娃分身暂时无法附身，可先「复原」"
	if player == null or bool(player.call("is_dead")):
		return "当前身体已死亡，先复原再附身"
	var occ := str(player.get("occupancy"))
	if occ == "car" or occ == "plane":
		return "驾驶载具时不能附身，先下车"
	if _cam != null:
		return "附身过渡中"
	return ""


# ------------------------------------------------------------------ 选择 + 高亮

func select(c: Node) -> void:
	if c != null and not is_instance_valid(c):
		c = null
	if c == selected:
		_refresh_outline()
		return
	selected = c
	_refresh_outline()
	selection_changed.emit(selected)


func is_outlined(c: Node) -> bool:
	return c != null and c == selected and not _outlined.is_empty()


func outlined_mesh_count() -> int:
	var n := 0
	for m in _outlined:
		if is_instance_valid(m) and m.material_overlay == _outline_mat:
			n += 1
	return n


func _clear_outline() -> void:
	for m in _outlined:
		if is_instance_valid(m) and m.material_overlay == _outline_mat:
			m.material_overlay = null
	_outlined.clear()


func _refresh_outline() -> void:
	_clear_outline()
	if selected == null or not is_instance_valid(selected):
		return
	var b: Node = selected.get("body")
	if b == null:
		return
	for n in b.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if m == null or m.mesh == null or m.name.ends_with("_ShadowProxy"):
			continue
		if m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			continue
		if (m.layers & (1 << 19)) != 0:
			continue  # 脏器（ORGAN_LIGHT_LAYER）不描边
		if m.material_overlay != null:
			continue
		m.material_overlay = _outline_mat
		_outlined.append(m)


# ------------------------------------------------------------------ 复原

func restore_selected() -> String:
	var c := selected
	if c == null or not is_instance_valid(c):
		return "请先选择一个分身"
	c.call("restore_body")
	last_message = "%s 已复原" % clone_label(c)
	return last_message


# ------------------------------------------------------------------ 附身

func possess_selected() -> String:
	return possess(selected)


func possess(c: Node) -> String:
	var why := _possess_block_reason(c)
	if why != "":
		last_message = why
		return why
	var vs: Node = game.get("vehicle_system") if game else null
	var cam_now := get_viewport().get_camera_3d()
	if cam_now:
		_cam_from = cam_now.global_transform
		_fov_from = cam_now.fov
	# 0) t99u：先结束手上的拖拽 / 抓取，并退出阴道互动会话（工具在原来那具身体上收尾：
	#    扩张 / 宫底顶起 / 卡住的宫颈都释放到那具身体自己，脱垂等持久状态留在那具身体上）。
	if player.has_method("_end_interact"):
		player.call("_end_interact")
	var pvm: Node = player.call("get_vagina_mode") if player.has_method("get_vagina_mode") else null
	if pvm and bool(pvm.call("is_active")):
		pvm.call("exit")
	# 1) 进行中的手术先退出（切口保留，persist）
	for s in [player.call("get_surgery"), c.call("get_surgery")]:
		if s and bool(s.call("is_active")):
			s.call("exit_surgery")
	if game and game.has_method("surgery_system_of"):
		var ss: Node = game.call("surgery_system_of")
		if ss and bool(ss.call("is_active")):
			ss.call("exit_surgery")
	# 2) 记录两边状态
	var p_body: Node3D = player.get("_body")
	var p_feet: Vector3 = player.global_position
	var p_fwd := _flat(p_body.global_basis.z if p_body else Vector3.BACK)
	var p_stance := str(player.call("get_stance"))
	var p_bed: Node = null
	if vs and str(player.get("occupancy")) == "exam_bed":
		p_bed = vs.get("occupied")
	var p_ratio := clampf(float(player.call("get_hp")) / maxf(1.0, float(player.call("get_max_hp"))), 0.01, 1.0)
	var c_feet: Vector3 = (c as Node3D).global_position
	var c_fwd := _flat((c as Node3D).global_basis.z)
	var c_stance := str(c.call("get_stance"))
	var c_bed: Node = c.get("on_exam_bed") if bool(c.call("is_on_exam_bed")) else null
	var c_ratio := clampf(float(c.call("get_hp")) / maxf(1.0, float(c.call("get_max_hp"))), 0.01, 1.0)
	# 3) 放下手里的枪（分身保留持枪外观）；离开检查床
	var ws: Node = player.call("get_weapons")
	var p_gun: Dictionary = ws.call("possession_release") if ws and ws.has_method("possession_release") else {}
	var c_gun := str(c.call("drop_weapon_visual"))
	if p_bed and vs:
		vs.call("_finish_exit", p_feet, true)
		p_feet = Vector3(p_feet.x, p_feet.y, p_feet.z)
	if c_bed:
		c.call("leave_exam_bed")
		var exit_p: Vector3 = vs.call("_exit_stand_dest", c_bed) if vs and vs.has_method("_exit_stand_dest") else c_feet
		c_feet = exit_p
	for hr in [player.call("get_hit_reaction"), c.call("get_hit_reaction")]:
		if hr and hr.has_method("clear"):
			hr.call("clear")
	# 4) 交换身体节点
	player.call("release_rig_visuals")
	var pr: Dictionary = player.call("rig_nodes")
	var cr: Dictionary = c.call("rig_nodes")
	_swap_nodes(pr, cr, player, c)
	player.call("adopt_rig", cr)
	c.call("adopt_rig", pr)
	# 「动作」（掰开小穴等）的进度属于身体：随身体一起换。
	var pa = player.call("get_actions") if player.has_method("get_actions") else null
	var ca = c.call("get_actions") if c.has_method("get_actions") else null
	if pa and ca and pa != ca and pa.has_method("swap_state_with"):
		pa.call("swap_state_with", ca)
	# 5) 位置 / 朝向
	(c as Node3D).global_transform = Transform3D(Basis(Vector3.UP, atan2(p_fwd.x, p_fwd.z)), p_feet)
	(c as Node3D).force_update_transform()
	var bh: Node3D = c.get("body_hit")
	if bh:
		bh.force_update_transform()
	player.global_transform = Transform3D(Basis.IDENTITY, c_feet)
	player.force_update_transform()
	player.set("velocity", Vector3.ZERO)
	player.call("set_facing", atan2(-c_fwd.x, -c_fwd.z))
	player.call("reset_physics_interpolation")
	# 6) 姿态 / 检查床 / 枪
	c.call("set_stance", p_stance)
	player.call("force_stance", c_stance)
	if p_bed:
		c.call("place_on_exam_bed", p_bed)
	if not p_gun.is_empty():
		c.call("hold_weapon_visual", str(p_gun.get("id", "")), p_gun.get("scene"), p_gun.get("xf", Transform3D.IDENTITY))
	if c_bed and vs:
		vs.set("nearest", c_bed)
		vs.call("try_enter")
	if c_gun != "" and ws and not c_bed:
		ws.call("select", c_gun)
	# 7) 生命值换算到新身份的上限
	var ph: Node = player.call("get_health")
	var chh: Node = c.call("get_health")
	if ph:
		ph.set("max_hp", CONTROLLED_MAX_HP)
		ph.call("reset", CONTROLLED_MAX_HP * c_ratio)
	if chh:
		chh.set("max_hp", CLONE_MAX_HP)
		chh.call("reset", CLONE_MAX_HP * p_ratio)
	# 8) HUD 重新绑定手术信号；高亮转到「刚离开的身体」
	var hud: Node = game.get_node_or_null("HUD") if game else null
	if hud and hud.has_method("_bind_surgery"):
		hud.call("_bind_surgery")
	if vs and vs.has_method("_update_nearest"):
		vs.call("_update_nearest")
	possess_count += 1
	select(c)
	_begin_transition()
	last_message = "已附身，原来的身体成为 %s" % clone_label(c)
	possessed.emit(c)
	return last_message


func _flat(v: Vector3) -> Vector3:
	var f := Vector3(v.x, 0.0, v.z)
	return f.normalized() if f.length_squared() > 1e-6 else Vector3.BACK


func _swap_nodes(a: Dictionary, b: Dictionary, pa: Node, pb: Node) -> void:
	# 两边节点同名（Body / OrganRig …），先改临时名再换挂，最后恢复原名。
	var names := {}
	for k in a.keys():
		var na: Node = a[k]
		var nb: Node = b[k]
		if na == null or nb == null:
			continue
		names[k] = [String(na.name), String(nb.name)]
		na.name = "__possA_" + str(k)
		nb.name = "__possB_" + str(k)
	for k in names.keys():
		var na2: Node = a[k]
		var nb2: Node = b[k]
		var ia := na2.get_index()
		var ib := nb2.get_index()
		na2.reparent(pb, false)
		nb2.reparent(pa, false)
		pa.move_child(nb2, mini(ia, pa.get_child_count() - 1))
		pb.move_child(na2, mini(ib, pb.get_child_count() - 1))
	for k in names.keys():
		(b[k] as Node).name = names[k][0]
		(a[k] as Node).name = names[k][1]


# ------------------------------------------------------------------ 镜头过渡

func _begin_transition() -> void:
	var pc: Camera3D = player.call("get_camera")
	if pc == null:
		return
	if _cam and is_instance_valid(_cam):
		_cam.queue_free()
	_cam = Camera3D.new()
	_cam.name = "PossessCam"
	game.add_child(_cam)
	_cam.global_transform = _cam_from
	_cam.fov = _fov_from
	_cam.near = pc.near
	_cam.far = pc.far
	_cam.cull_mask = pc.cull_mask
	_cam.current = true
	_cam_t = 0.0


func is_transitioning() -> bool:
	return _cam != null


func _process(delta: float) -> void:
	_update_aim()
	if selected != null and not is_instance_valid(selected):
		select(null)
	if _cam == null:
		return
	var pc: Camera3D = player.call("get_camera")
	_cam_t = minf(1.0, _cam_t + delta / TRANSITION_SEC)
	var vc := get_viewport().get_camera_3d()
	var target: Transform3D = pc.global_transform
	var u := _cam_t * _cam_t * (3.0 - 2.0 * _cam_t)
	_cam.global_transform = _cam_from.interpolate_with(target, u)
	_cam.fov = lerpf(_fov_from, pc.fov, u)
	_cam.cull_mask = pc.cull_mask
	if _cam_t >= 1.0:
		var veh_cam_active := vc != _cam and vc != null
		if not veh_cam_active:
			pc.current = true
		_cam.queue_free()
		_cam = null


# ------------------------------------------------------------------ 第一人称瞄准分身

func _update_aim() -> void:
	aimed = null
	if player == null or not bool(player.get("first_person")) or _cam != null:
		return
	if str(player.get("occupancy")) != "":
		return
	var cam: Camera3D = player.call("get_camera")
	if cam == null or not cam.is_inside_tree():
		return
	var o := cam.global_position
	var d := -cam.global_transform.basis.z
	var space := cam.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(o, o + d * AIM_RANGE, 1 | 2 | (1 << 5))
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var c := _clone_of(hit.get("collider"))
	if c and not bool(c.call("is_dead")):
		aimed = c


func _clone_of(n: Variant) -> Node:
	if n == null or not (n is Node):
		return null
	var node := n as Node
	if node.has_meta("hitbox_host"):
		var h: Variant = node.get_meta("hitbox_host")
		if h is Node and (h as Node).is_in_group("clone_dolls"):
			return h
	while node:
		if node.is_in_group("clone_dolls"):
			return node
		node = node.get_parent()
	return null


func possess_aimed() -> String:
	if aimed == null:
		return "准星没有对准分身"
	return possess(aimed)
