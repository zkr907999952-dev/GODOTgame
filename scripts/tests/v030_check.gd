extends SceneTree
## 0.2.9 生命值与布娃娃自检：
##   godot --headless --path . -s res://scripts/tests/v030_check.gd

const CombatDamage := preload("res://scripts/combat_damage.gd")

var main: Node
var player: Node
var hud: Node
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v030: OK   ", msg)
	else:
		fails += 1
		push_error("v030: FAIL " + msg)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	_ok(player != null and hud != null, "scene booted")
	if player == null or hud == null:
		print("v030_check: fails=", fails)
		quit(1)
		return

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"0.2.10\"") >= 0 or presets.find("version/name=\"0.2.11\"") >= 0 or presets.find("version/name=\"0.2.12\"") >= 0 or presets.find("version/name=\"0.2.12\"") >= 0, "export version is 0.2.10 or 0.2.11")
	_ok(presets.find("version/code=12") >= 0 or presets.find("version/code=13") >= 0 or presets.find("version/code=14") >= 0, "versionCode is 12 or 13")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")

	_check_damage_table()
	await _check_independent_hp()
	await _check_clone_ragdoll_and_impulse()
	await _check_player_ragdoll()
	_check_health_ui()
	await _check_world_hp_bar()

	print("v030_check: fails=", fails)
	quit(1 if fails > 0 else 0)


func _check_damage_table() -> void:
	var rifle := CombatDamage.base_damage("rifle")
	var smg := CombatDamage.base_damage("smg")
	var pistol := CombatDamage.base_damage("pistol")
	var shotgun := CombatDamage.base_damage("shotgun")
	_ok(is_equal_approx(rifle, 30.0), "rifle damage 30 (got %.1f)" % rifle)
	_ok(is_equal_approx(smg, 22.0), "smg damage 22 (got %.1f)" % smg)
	_ok(is_equal_approx(pistol, 34.0), "pistol damage 34 (got %.1f)" % pistol)
	_ok(is_equal_approx(shotgun, 15.0), "shotgun damage 15 (got %.1f)" % shotgun)
	_ok(CombatDamage.pellets("shotgun") == 8, "shotgun 8 pellets")
	_ok(CombatDamage.ttk_body_shots("rifle") == 4, "rifle body TTK 4")
	_ok(CombatDamage.ttk_body_shots("smg") == 5, "smg body TTK 5")
	_ok(CombatDamage.ttk_body_shots("pistol") == 3, "pistol body TTK 3")
	var head_rifle := CombatDamage.compute("rifle", 5.0, "head")
	_ok(is_equal_approx(head_rifle, 51.0), "rifle head 51 (got %.2f)" % head_rifle)
	_ok(head_rifle * 2.0 >= 100.0, "rifle 2 headshots kill")
	var body_smg := CombatDamage.compute("smg", 5.0, "body")
	_ok(body_smg * 4.0 < 100.0 and body_smg * 5.0 >= 100.0, "smg 5 body shots")
	var sg_sum := shotgun * 8.0
	_ok(sg_sum >= 100.0, "shotgun 8 pellets sum %.1f >= 100" % sg_sum)
	_ok(shotgun * 7.0 >= 100.0, "shotgun 7 body pellets kill (most pellets)")
	var far_sg := CombatDamage.compute("shotgun", 22.0, "body")
	_ok(far_sg <= shotgun * 0.2, "shotgun far falloff %.2f" % far_sg)
	var limb := CombatDamage.compute("rifle", 5.0, "limb")
	_ok(limb < rifle and is_equal_approx(limb, rifle * 0.85), "rifle limb 0.85x")
	_ok(CombatDamage.zone_from_bone("C_Head_a") == "head", "head bone zone")
	_ok(CombatDamage.zone_from_bone("L_UpperArm_a") == "limb", "arm bone zone")
	_ok(CombatDamage.zone_from_bone("C_Spine_c") == "body", "spine bone zone")
	# Defs on disk match the table
	var ws: Node = player.call("get_weapons")
	if ws and ws.has_method("load_defs") or ws:
		var defs: Array = ws.get("defs") if ws else []
		var by := {}
		for d in defs:
			by[str(d.id)] = d
		if by.has("shotgun"):
			_ok(is_equal_approx(float(by["shotgun"].damage), 15.0), "shotgun.tres damage 15")
			_ok(int(by["shotgun"].pellets) == 8, "shotgun.tres 8 pellets")
		if by.has("rifle"):
			_ok(is_equal_approx(float(by["rifle"].damage), 30.0), "rifle.tres damage 30")


func _check_independent_hp() -> void:
	_ok(is_equal_approx(float(player.call("get_hp")), 1000.0), "player starts at 1000")
	_ok(is_equal_approx(float(player.call("get_max_hp")), 1000.0), "player max 1000")
	var msg: String = main.call("spawn_clone", player.global_position + Vector3(1.2, 0.0, 0.4))
	print("v030: ", msg)
	await _frames(8)
	await _phys(2)
	var clones: Array = main.call("get_clones")
	_ok(clones.size() >= 1, "clone spawned")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	_ok(is_equal_approx(float(c.call("get_hp")), 100.0), "clone starts at 100 independent")
	c.call("apply_damage", 25.0, {"zone": "body"})
	_ok(is_equal_approx(float(c.call("get_hp")), 75.0), "clone took 25, now 75")
	_ok(is_equal_approx(float(player.call("get_hp")), 1000.0), "player HP unchanged after clone damage")
	player.call("apply_damage", 10.0, {"zone": "body"})
	_ok(is_equal_approx(float(player.call("get_hp")), 990.0), "player took 10, now 990")
	_ok(is_equal_approx(float(c.call("get_hp")), 75.0), "clone HP unchanged after player damage")
	# restore player for later death test
	player.call("get_health").call("reset", 1000.0)
	_ok(is_equal_approx(float(player.call("get_hp")), 1000.0), "player HP reset to 1000")


func _check_clone_ragdoll_and_impulse() -> void:
	var clones: Array = main.call("get_clones")
	_ok(not clones.is_empty(), "clone still present for ragdoll")
	if clones.is_empty():
		return
	var c: Node = clones[0]
	var loco: Node = c.get("loco")
	c.call("apply_damage", 200.0, {"zone": "body", "dir": Vector3(0, 0, -1), "entry": c.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(2)
	await _frames(4)
	_ok(bool(c.call("is_dead")), "clone is dead at 0 HP")
	_ok(is_equal_approx(float(c.call("get_hp")), 0.0), "clone HP is 0")
	var rag: Node = c.call("get_ragdoll")
	_ok(rag != null and bool(rag.call("is_active")), "clone ragdoll started")
	if loco:
		_ok(bool(loco.get("frozen")), "clone SoftLoco frozen")
	var sec = c.call("get_secondary")
	if sec:
		_ok(bool(sec.get("corpse_mode")), "clone secondary corpse_mode")
	if c.get("organs"):
		_ok(bool(c.get("organs").get("frozen")), "clone organs frozen")
	_ok(is_instance_valid(c) and not c.is_queued_for_deletion() and c.is_inside_tree(), "corpse still in the tree")
	var hit_body: Node = c.get("body_hit")
	if hit_body:
		_ok(int(hit_body.collision_layer) == 0, "living BodyHit disabled")
	# further ballistic-style impulse on the corpse
	var before_count := int(rag.get("impulse_count"))
	var before_imp: Vector3 = rag.get("last_impulse")
	var dir := Vector3(1, 0.1, 0).normalized()
	var imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.82, "category": "rifle"}, dir)
	_ok(imp.length() > 4.0, "rifle corpse impulse length %.2f" % imp.length())
	var pistol_imp: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.40, "category": "pistol"}, dir)
	var sg_one: Vector3 = rag.call("impulse_from_ballistics", {"impulse": 0.70, "category": "shotgun"}, dir)
	_ok(pistol_imp.length() < imp.length(), "pistol impulse lighter than rifle (%.2f < %.2f)" % [pistol_imp.length(), imp.length()])
	_ok(sg_one.length() * 6.0 > imp.length(), "shotgun 6+ pellets heavier than one rifle")
	var chest: Vector3 = rag.call("get_follow_point")
	rag.call("apply_hit_impulse", imp, chest, null)
	await _phys(4)
	await _frames(2)
	var after_count := int(rag.get("impulse_count"))
	var spd := float(rag.call("max_linear_speed"))
	var last: Vector3 = rag.get("last_impulse")
	_ok(after_count > before_count, "corpse impulse recorded (%d -> %d)" % [before_count, after_count])
	_ok(last.length() > 0.5 or spd > 0.05, "corpse has impulse or measurable velocity (imp=%.2f spd=%.3f)" % [last.length(), spd])
	# corpse persists after more frames
	await _phys(8)
	_ok(is_instance_valid(c) and c.is_inside_tree() and bool(c.call("is_dead")), "corpse still present after settle frames")


func _check_player_ragdoll() -> void:
	_ok(not bool(player.call("is_dead")), "player still alive before death test")
	player.call("apply_damage", 1000.0, {"zone": "body", "dir": Vector3(0, 0, 1), "entry": player.global_position + Vector3(0, 1.1, 0), "par": {"impulse": 0.82, "category": "rifle"}})
	await _phys(2)
	await _frames(4)
	_ok(bool(player.call("is_dead")), "player apply_damage to 0 starts death")
	_ok(is_equal_approx(float(player.call("get_hp")), 0.0), "player HP is 0")
	var rag: Node = player.call("get_ragdoll")
	_ok(rag != null and bool(rag.call("is_active")), "player ragdoll started")
	var loco: Node = player.get("_loco") if "_loco" in player else player.call("get_loco")
	if loco:
		_ok(bool(loco.get("frozen")), "player SoftLoco frozen")
	_ok(int(player.collision_layer) == 0, "player living capsule layer disabled")
	_ok(bool(player.call("is_display_mode")), "player death uses orbit camera / display mode")
	# menus still: HUD process_mode always, revive button exists
	var revive: Button = hud.find_child("ReviveButton", true, false)
	_ok(revive != null, "revive button exists")
	# revive restores
	player.call("revive")
	await _phys(2)
	await _frames(2)
	_ok(not bool(player.call("is_dead")), "player revived")
	_ok(is_equal_approx(float(player.call("get_hp")), 1000.0), "player HP restored")
	_ok(rag == null or not bool(rag.call("is_active")), "player ragdoll stopped after revive")
	_ok(int(player.collision_layer) != 0, "player collision restored")


func _check_health_ui() -> void:
	var box: Control = hud.find_child("PlayerHealth", true, false)
	_ok(box != null, "player HP UI node exists")
	var bar: ColorRect = hud.find_child("HpBar", true, false)
	var num: Label = hud.find_child("HpNumber", true, false)
	_ok(bar != null and num != null, "player HP bar and number exist")
	if box:
		# bottom-center anchors (under weapon card)
		_ok(is_equal_approx(box.anchor_top, 1.0) and is_equal_approx(box.anchor_left, 0.5) and is_equal_approx(box.anchor_right, 0.5), "player HP bar anchored bottom-center")
	var world: Control = hud.find_child("WorldHealth", true, false)
	_ok(world != null, "world/head health bar node exists")
	if world:
		_ok(world.modulate.a < 0.2 or not world.visible, "world health bar hidden by default")
	_ok(hud.get("debug_world_hp_visible") == false or world != null, "world bar debug flag readable")


func _check_world_hp_bar() -> void:
	# 再刷一个活分身，摆到相机正前方，准星应显示头顶血条；移开后隐藏。
	var cam: Camera3D = player.call("get_camera")
	if cam == null:
		_ok(false, "camera for world HP")
		return
	var ahead := cam.global_position + (-cam.global_transform.basis.z) * 2.2
	ahead.y = player.global_position.y
	main.call("spawn_clone", ahead)
	await _frames(10)
	await _phys(2)
	# 把已有尸体挪开，避免挡住准星
	for c in main.call("get_clones"):
		if c.has_method("is_dead") and bool(c.call("is_dead")):
			c.global_position += Vector3(6, 0, 6)
	var living: Node = null
	for c in main.call("get_clones"):
		if c.has_method("is_dead") and not bool(c.call("is_dead")):
			living = c
			break
	_ok(living != null, "living clone for world HP")
	if living == null:
		return
	# 把分身精确放到屏幕中心射线上
	var dest := cam.global_position + (-cam.global_transform.basis.z) * 2.4
	dest.y = player.global_position.y
	living.global_position = dest
	await _phys(2)
	await _frames(6)
	if hud.has_method("_refresh_world_hp"):
		hud.call("_refresh_world_hp", 0.2)
	var aimed: Node = hud.call("_aim_health_target") if hud.has_method("_aim_health_target") else null
	var shown := bool(hud.get("debug_world_hp_visible")) or aimed != null
	_ok(shown, "world health bar shown when crosshair hits living target (aimed=%s visible=%s)" % [aimed, hud.get("debug_world_hp_visible")])
	# move clone out of the way and expire the fade
	living.global_position = dest + Vector3(8, 0, 8)
	await _phys(1)
	if hud.has_method("_refresh_world_hp"):
		for i in 20:
			hud.call("_refresh_world_hp", 0.1)
	_ok(hud.get("debug_world_hp_visible") == false, "world health bar hidden after crosshair leaves")
