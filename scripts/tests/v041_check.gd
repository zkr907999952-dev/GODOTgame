extends SceneTree
## 0.2.13 自检 t27u：手枪绕肩俯仰；捂腹不反折、掌心贴腹；散弹特写后不卡（伤口贴图预烘焙，首次命中无长帧）；
## 人体不留黑点弹孔；子弹穿出人体后继续飞行（含特写）；霰弹每发后左手拉泵；手/手指不被拉长；
## 走跑跳跃时枪跟随身体、手与枪同一插值变换。
##   godot --headless --path . -s res://scripts/tests/v041_check.gd

const VERSION_NAME := "0.2.13"
const VERSION_CODE := 15

var main: Node
var player: Node
var ws: Node
var settings: Node
var fails := 0
var spawn := Vector3.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame




## 等到本帧所有节点 _process 之后再测量：挂一个 process_priority 极大的探针节点，
## 它的 _process 最后执行（渲染前的状态）。延迟调用会在下一帧物理步之后刷新，不可靠。
var _late_probe: Node = null


func _late_frame() -> void:
	if _late_probe == null or not is_instance_valid(_late_probe):
		var gd := GDScript.new()
		gd.source_code = "extends Node\nsignal done\nfunc _process(_d):\n\tdone.emit()\n"
		gd.reload()
		_late_probe = Node.new()
		_late_probe.set_script(gd)
		_late_probe.process_priority = 1000000
		get_root().add_child(_late_probe)
	await _late_probe.done


func _phys(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v041: OK   ", msg)
	else:
		fails += 1
		push_error("v041: FAIL " + msg)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


## 测试连开多枪：弹匣打空会让 fire_along_ray 直接返回 false（之前特写 3/4「没播」就是没子弹）。
func _refill() -> void:
	var am: Dictionary = ws.get("ammo")
	var cur := String(ws.get("current"))
	am[cur] = Vector2i(99, 99)


func _home() -> void:
	player.global_position = spawn
	player.velocity = Vector3.ZERO
	player.set("input_locked", false)
	player.set("_yaw", 0.0)
	player.set("_pitch", 0.0)
	player.call("_apply_camera")


func _pose(ads: bool, pitch: float) -> void:
	ws.call("set_ads", ads)
	ws.set("_ads_k", 1.0 if ads else 0.0)
	player.set("_pitch", pitch)
	player.call("_apply_camera")
	await _phys(14)
	await _frames(2)


func _clone(off: Vector3) -> Node:
	main.call("spawn_clone", player.global_position + off)
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	return clones[clones.size() - 1] if not clones.is_empty() else null


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	await _phys(4)
	player = main.get_node("Player")
	ws = player.call("get_weapons")
	settings = main.get_node_or_null("GameSettings")
	_ok(player != null and ws != null, "scene booted")
	if player == null or ws == null:
		print("v041_check: fails=", fails)
		quit(1)
		return
	spawn = player.global_position
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"%s\"" % VERSION_NAME) >= 0, "export versionName is %s" % VERSION_NAME)
	_ok(presets.find("version/code=%d" % VERSION_CODE) >= 0, "versionCode is %d" % VERSION_CODE)
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("keystore/release_password=\"\"") >= 0, "no release password committed")
	_check_sources()
	await _check_wound_tiles_lag()
	await _check_cover_pose()
	await _check_pistol_pivot()
	await _check_hand_proportions()
	await _check_pump()
	await _check_body_follow()
	await _check_no_body_decals()
	await _check_bullet_through()
	await _check_shotgun_cine_baseline()
	print("v041_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(src.find("func _pistol_shoulder_cam") >= 0, "pistol pitch pivots about the shoulder")
	_ok(src.find("apply_ik_after_loco") >= 0, "apply_ik_after_loco kept right after loco apply_pose")
	_ok(src.find("set_bone_pose_position(ha, skeleton.get_bone_rest(ha).origin * ") < 0, "hand bone never translated/scaled by arm stretch")
	_ok(src.find("PHYSICS_INTERPOLATION_MODE_OFF if want_off") < 0, "skeleton no longer drops physics interpolation in FP")
	var sec := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	var fn := sec.find("func _apply_aim_waist")
	if fn >= 0:
		_ok(sec.substr(fn, 500).find("_nudge_look_bone") < 0, "no waist lean")
	var bal := FileAccess.get_file_as_string("res://scripts/weapons/ballistics.gd")
	_ok(bal.find("if col is PhysicalBone3D:\n\t\t_spawn_decal") < 0, "ragdoll-bone exit decal removed")
	var skin := FileAccess.get_file_as_string("res://shaders/skin_xray.gdshader")
	_ok(skin.find("ball_wound(") < 0, "skin shader no longer punches dark bullet holes (ball_wound cut/cavity tint removed)")


# ---- 3) 散弹特写后卡顿：首次伤口不再逐像素生成贴图
func _check_wound_tiles_lag() -> void:
	var PM = load("res://scripts/organs/prop_meshes.gd")
	var t0 := Time.get_ticks_usec()
	var tiles: Array = PM.wound_tiles()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok(tiles.size() == 4, "4 wound tiles available")
	var baked := tiles.size() > 0 and str((tiles[0] as Resource).resource_path).find("wound_tile_0.png") >= 0
	_ok(baked, "wound tiles load from baked PNG assets (%s)" % (str((tiles[0] as Resource).resource_path) if tiles.size() > 0 else "-"))
	_ok(ms < 40.0, "wound tile load is cheap (%.1f ms, was ~115 ms per-pixel bake)" % ms)


# ---- 2) 捂腹：肘不反折，掌心朝腹
func _check_cover_pose() -> void:
	player.call("set_play_mode", 0)
	_home()
	var c: Node = await _clone(Vector3(0.4, 0.0, -0.8))
	_ok(c != null, "clone for cover pose")
	if c == null:
		return
	var hr: Node = c.call("get_hit_reaction")
	var org: Node = c.call("get_organs")
	var inside: Vector3 = (c as Node3D).global_position + Vector3(0, 1.02, 0.0)
	if org and org.has_method("abdomen_frame"):
		inside = (org.call("abdomen_frame") as Transform3D) * Vector3(0, -0.02, -0.02)
	c.call("apply_damage", 12.0, {"zone": "body", "gut": true, "dir": Vector3(0, 0, 1), "entry": inside})
	await _phys(12)
	hr.set("cover_life", 2.2)
	hr.set("cover_weight", 1.0)
	var loco = c.get("loco")
	if loco:
		loco.call("apply_pose", 0.0, 0.0, 0.0, false, false, 0.016, 1.65)
	hr.call("apply_cover", 0.0)
	var j: Dictionary = hr.call("cover_joint_debug")
	var dbg: Dictionary = hr.call("cover_debug")
	for s in ["L", "R"]:
		_ok(float(j.get(s + "_hinge", -1.0)) > 0.5, "%s elbow bends the natural way, no reverse fold (hinge=%.2f, flex %.0f°)" % [s, float(j.get(s + "_hinge", -1.0)), float(j.get(s + "_flex_deg", 0.0))])
		_ok(float(j.get(s + "_palm_in", -1.0)) > 0.6, "%s PALM faces into the belly, not the back of the hand (palm·in=%.2f)" % [s, float(j.get(s + "_palm_in", -1.0))])
		_ok(float(dbg.get(s + "_skin_dist", 9.0)) < 0.2, "%s hand on the belly (%.2f m)" % [s, float(dbg.get(s + "_skin_dist", 9.0))])
		_ok(not bool(dbg.get(s + "_arm_through", true)), "%s arm not through the body" % s)
	_ok(not bool(dbg.get("hands_crossed", true)), "hands not crossed")
	c.queue_free()
	await _frames(2)
	player.call("set_play_mode", 1)


# ---- 1) 手枪绕肩俯仰
func _check_pistol_pivot() -> void:
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun("pistol")
	var d_piv: Array = []
	var hands: Array = []
	var piv_sh: Array = []
	for pitch in [-0.6, 0.0, 0.5]:
		await _pose(false, pitch)
		var sp: Dictionary = ws.call("debug_stock_pivot")
		var piv: Vector3 = ws.call("debug_pitch_pivot")
		var rh: Vector3 = sp["R_Hand_a"]
		var ua: Vector3 = sp["R_UpperArm_a"]
		d_piv.append(rh.distance_to(piv))
		hands.append(rh)
		piv_sh.append(piv.distance_to(ua))
		var g: Dictionary = ws.call("debug_left_grip")
		_ok(float(g.get("w", 1.0)) < 0.01, "pistol pitch %.1f keeps two-hand grip (no long-gun override)" % pitch)
		var he: Dictionary = ws.call("debug_hand_error")
		_ok(float(he.get("L", 9.0)) < 0.05 and float(he.get("R", 9.0)) < 0.05, "pistol pitch %.1f both hands on the gun (L %.1f cm R %.1f cm)" % [pitch, float(he.get("L", 9.0)) * 100.0, float(he.get("R", 9.0)) * 100.0])
	var spread := float(d_piv.max()) - float(d_piv.min())
	_ok(spread < 0.05, "pistol: hand-to-shoulder-pivot distance constant across pitch -> arms swing about the shoulder (%.1f cm)" % (spread * 100.0))
	_ok(float(piv_sh.max()) < 0.25, "pistol pivot sits at the shoulders (max %.2f m from R upper arm)" % float(piv_sh.max()))
	var arc := (hands[0] as Vector3).distance_to(hands[2])
	_ok(arc > 0.15, "pistol hands sweep an arc with pitch (%.0f cm)" % (arc * 100.0))
	ws.set("debug_aim_dist", 30.0)
	await _pose(false, 0.0)
	var b: Dictionary = ws.call("debug_bore_aim")
	ws.set("debug_aim_dist", -1.0)
	_ok(float(b.get("miss", 9.0)) < 0.36, "pistol level @30 m: bore through the aim point (miss %.2f m)" % float(b.get("miss", 9.0)))
	_ok(float(b.get("gun_pitch", -9.0)) > -0.5 and float(b.get("pitch_err", 99.0)) < 2.0, "pistol level: no droop (gun %.1f° view %.1f°)" % [float(b.get("gun_pitch", 0.0)), float(b.get("view_pitch", 0.0))])
	for pitch in [0.5, -0.6]:
		await _pose(false, pitch)
		var bp: Dictionary = ws.call("debug_bore_aim")
		var tol := 0.06 + 0.01 * float(bp.get("along", 1.0))
		_ok(float(bp.get("miss", 9.0)) < tol, "pistol pitch %.1f: bore passes the aim point (miss %.2f m)" % [pitch, float(bp.get("miss", 9.0))])
	await _pose(false, 0.0)


# ---- 7) 手/手指比例
func _check_hand_proportions() -> void:
	for mode in [1, 0]:
		player.call("set_play_mode", 1)
		_home()
		for id in ["rifle", "smg", "shotgun", "pistol"]:
			await _ready_gun(id)
			if mode == 0:
				player.call("set_play_mode", 0)
			for ads in [false, true]:
				await _pose(ads, 0.0)
				var st: Dictionary = ws.call("debug_arm_stretch")
				var tag := "%s %s %s" % ["FP" if mode == 1 else "TP", id, "ADS" if ads else "hip"]
				_ok(absf(float(st.get("L_fa_len", 9.0)) - 1.0) < 0.002 and absf(float(st.get("R_fa_len", 9.0)) - 1.0) < 0.002, "%s forearm->hand bone length unchanged (L %.3f R %.3f)" % [tag, float(st.get("L_fa_len", 9.0)), float(st.get("R_fa_len", 9.0))])
				_ok(absf(float(st.get("finger_len", 9.0)) - 1.0) < 0.002, "%s finger bones not stretched (%.3f)" % [tag, float(st.get("finger_len", 9.0))])
				if mode == 0 or id == "pistol":
					_ok(float(st.get("L", 9.0)) <= 1.051 and float(st.get("R", 9.0)) <= 1.051, "%s arm stretch subtle (L %.2f R %.2f)" % [tag, float(st.get("L", 9.0)), float(st.get("R", 9.0))])
				if id != "pistol":
					var g: Dictionary = ws.call("debug_left_grip")
					_ok(float(g.get("palm_to_attach", 9.0)) < 0.03, "%s left palm still on handguard (%.1f cm)" % [tag, float(g.get("palm_to_attach", 9.0)) * 100.0])
			if mode == 0:
				player.call("set_play_mode", 1)
	await _pose(false, 0.0)


# ---- 6) 霰弹泵动
func _check_pump() -> void:
	player.call("set_play_mode", 1)
	_home()
	for nr in [false, true]:
		if settings:
			settings.set("no_reload", nr)
		await _ready_gun("shotgun")
		await _pose(false, 0.0)
		var cam3: Camera3D = player.call("get_camera")
		var w = ws.call("cur_def")
		for shot in 2:
			ws.call("fire_along_ray", cam3.global_position, -cam3.global_transform.basis.z, false)
			var pump_max := 0.0
			var follow_worst := 0.0
			var finished := false
			var t0 := Time.get_ticks_msec()
			var d0: Dictionary = ws.call("debug_pump")
			while Time.get_ticks_msec() - t0 < 1500:
				await _late_frame()
				var d: Dictionary = ws.call("debug_pump")
				pump_max = maxf(pump_max, float(d["pump_m"]))
				follow_worst = maxf(follow_worst, float(d["palm_to_pump"]))
				if not bool(d["active"]):
					finished = true
					break
			var tag := "shotgun%s shot %d" % [" (no-reload)" if nr else "", shot + 1]
			_ok(bool(d0["active"]), "%s starts a pump rack" % tag)
			_ok(pump_max > 0.025, "%s pump slides back (%.1f cm)" % [tag, pump_max * 100.0])
			_ok(follow_worst < 0.03, "%s left palm rides the pump during the rack (worst %.1f cm)" % [tag, follow_worst * 100.0])
			_ok(finished and float(d0["dur"]) <= 60.0 / float(w.rpm) + 1e-3, "%s rack completes before the next shot (%.2f s <= %.2f s)" % [tag, float(d0["dur"]), 60.0 / float(w.rpm)])
			_ok(float(d0["back_u"]) > 0.3 and float(d0["back_u"]) < 0.8, "%s shell ejects at pump-back (u=%.2f)" % [tag, float(d0["back_u"])])
			await _phys(4)
	if settings:
		settings.set("no_reload", false)


# ---- 8) 走跑/跳跃：枪随身体，手与枪同一插值变换
func _check_body_follow() -> void:
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun("rifle")
	await _pose(false, 0.0)
	var sk: Skeleton3D = ws.get("skeleton")
	_ok(not sk.is_physics_interpolated_and_enabled(), "player body is placed per render frame with the camera's interpolation (no separate engine interpolation)")
	var worst_hand := 0.0
	var worst_grip := 0.0
	var follow_max := 0.0
	var xf_err := 0.0
	Input.action_press("move_forward")
	for i in 90:
		await _late_frame()
		if i == 30:
			Input.action_press("jump")
		if i == 33:
			Input.action_release("jump")
		if i < 10:
			continue
		var he: Dictionary = ws.call("debug_hand_error")
		if OS.has_environment("V41DBG"):
			print("  f%d L=%.3f R=%.3f onfloor=%s vy=%.2f st=%s" % [i, float(he.get("L", 0.0)), float(he.get("R", 0.0)), player.is_on_floor(), player.velocity.y, ws.call("debug_arm_stretch")])
		worst_hand = maxf(worst_hand, maxf(float(he.get("L", 0.0)), float(he.get("R", 0.0))))
		var g: Dictionary = ws.call("debug_left_grip")
		worst_grip = maxf(worst_grip, float(g.get("palm_to_attach", 0.0)))
		follow_max = maxf(follow_max, (ws.get("debug_body_follow") as Vector3).length())
		xf_err = maxf(xf_err, float(player.call("debug_body_interp_error")))
	Input.action_release("move_forward")
	_ok(worst_hand < 0.035, "walk+jump: hands stay on the gun every frame (worst %.1f cm)" % (worst_hand * 100.0))
	_ok(worst_grip < 0.035, "walk+jump: left palm stays on the handguard (worst %.1f cm)" % (worst_grip * 100.0))
	_ok(follow_max > 0.001, "walk+jump: gun follows the body/shoulder sway (max %.1f cm)" % (follow_max * 100.0))
	_ok(xf_err < 0.001, "rendered body uses the exact camera interpolation offset every frame (%.4f m)" % xf_err)
	await _phys(30)
	_home()


# ---- 4) 人体无黑点弹孔
func _check_no_body_decals() -> void:
	player.call("set_play_mode", 1)
	_home()
	if settings:
		settings.call("set_bullet_cam_chance", 0.0)
	var cam3: Camera3D = player.call("get_camera")
	var fwd := -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var c: Node = await _clone(fwd * 1.8)
	var bal: Node = ws.get("ballistics")
	bal.call("clear_decals")
	await _ready_gun("shotgun")
	for k in 3:
		var belly: Vector3 = ((c.call("get_organs") as Node).call("abdomen_frame") as Transform3D).origin
		_refill()
		ws.call("fire_along_ray", cam3.global_position, (belly - cam3.global_transform.origin).normalized(), true)
		await _phys(20)
	# 布娃娃：杀死后再打
	c.call("apply_damage", 9999.0, {"zone": "head"})
	await _phys(40)
	await _ready_gun("rifle")
	for k in 3:
		var tgt: Vector3 = (c as Node3D).global_position + Vector3(0, 0.3, 0)
		var org: Node = c.call("get_organs")
		if org:
			tgt = (org.call("abdomen_frame") as Transform3D).origin
		_refill()
		ws.call("fire_along_ray", cam3.global_position, (tgt - cam3.global_position).normalized(), true)
		await _phys(12)
	await _phys(30)
	var n_body := int(bal.call("body_decal_count", [c]))
	_ok(bool(c.call("is_dead")), "clone ragdolled for the corpse check")
	_ok(n_body == 0, "no black bullet-hole decals on the living body or ragdoll (%d)" % n_body)
	_ok(int(bal.call("decal_count")) > 0, "walls/static surfaces still get decals (%d)" % int(bal.call("decal_count")))
	_ok(int(bal.call("floating_decal_count")) == 0, "no floating marks")
	c.queue_free()
	await _frames(2)


# ---- 5) 子弹穿体后继续飞
func _check_bullet_through() -> void:
	player.call("set_play_mode", 1)
	_home()
	if settings:
		settings.call("set_bullet_cam_chance", 0.0)
	var cam3: Camera3D = player.call("get_camera")
	var fwd := -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var c: Node = await _clone(fwd * 1.8)
	await _ready_gun("rifle")
	var bal: Node = ws.get("ballistics")
	var belly: Vector3 = ((c.call("get_organs") as Node).call("abdomen_frame") as Transform3D).origin
	var origin := cam3.global_position
	var dir := (belly - origin).normalized()
	ws.call("fire_along_ray", origin, dir, true)
	var arr: Array = bal.call("live_projectiles")
	var rec: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
	var beyond := 0.0
	var hit_body := false
	for i in 30:
		await physics_frame
		if rec.is_empty():
			break
		hit_body = hit_body or bool(rec.get("hit_body", false))
		var p: Vector3 = rec.get("pos", origin)
		beyond = maxf(beyond, (p - belly).dot(dir))
		if not bool(rec.get("alive", true)):
			break
	_ok(hit_body, "rifle bullet hit the body")
	_ok(beyond > 0.6, "bullet keeps flying after passing through the body (%.2f m beyond the belly)" % beyond)
	# 特写：穿出后继续飞，再 4 秒停留
	var cam: Node = main.get_node_or_null("BulletCam")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	for id in ["rifle", "shotgun"]:
		await _ready_gun(id)
		belly = ((c.call("get_organs") as Node).call("abdomen_frame") as Transform3D).origin
		origin = cam3.global_position
		dir = (belly - origin).normalized()
		ws.call("fire_along_ray", origin, dir, true)
		arr = bal.call("live_projectiles")
		var lead: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
		var info := {"gut": true, "body": c, "organs": c.call("get_organs"), "entry": belly, "pos": belly, "exit": belly + dir * 0.22, "dir": dir, "origin": origin}
		cam.call("debug_reset")
		var did := bool(cam.call("consider", info, lead))
		_ok(did, "%s cinematic started" % id)
		var saw_through := false
		var max_beyond := 0.0
		var vis := 0
		var t := 0.0
		var hold_at := -1.0
		while bool(cam.get("playing")) and t < 20.0:
			cam.call("debug_advance", 0.05)
			t += 0.05
			var ph := str(cam.get("debug_phase"))
			if ph == "through":
				saw_through = true
				var d: Dictionary = cam.call("debug_through")
				max_beyond = maxf(max_beyond, float(d["max_beyond_exit"]))
				vis = maxi(vis, int(d["visible"]))
			if ph == "hold" and hold_at < 0.0:
				hold_at = t
		_ok(saw_through and max_beyond > 0.3 and vis >= 1, "%s cinematic: visible bullet flies on past the exit (%.2f m, %d visible)" % [id, max_beyond, vis])
		_ok(hold_at > 0.0 and t - hold_at > 3.8, "%s cinematic: then the 4 s hold (%.1f s)" % [id, t - hold_at])
		_ok(is_equal_approx(Engine.time_scale, 1.0), "%s cinematic restores time scale" % id)
		var ig := root.get_tree().get_nodes_in_group("ballistics_ignore")
		var visible_sphere := false
		for n in ig:
			for m in (n as Node).find_children("*", "MeshInstance3D", true, false):
				if (m as MeshInstance3D).visible:
					visible_sphere = true
		_ok(not visible_sphere, "%s impact spheres stay invisible" % id)
	cam.set("debug_roll", -1.0)
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	c.queue_free()
	await _frames(2)


# ---- 3) 多次散弹特写后回到基线
func _check_shotgun_cine_baseline() -> void:
	player.call("set_play_mode", 1)
	_home()
	var cam3: Camera3D = player.call("get_camera")
	var fwd := -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var c: Node = await _clone(fwd * 1.8)
	var cam: Node = main.get_node_or_null("BulletCam")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	await _ready_gun("shotgun")
	await _phys(30)
	var base_nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - 0
	var worst_frame := 0.0
	for k in 4:
		if k > 0:
			c.queue_free()
			await _frames(2)
			c = await _clone(fwd * 1.8)
			await _phys(10)
		var belly: Vector3 = ((c.call("get_organs") as Node).call("abdomen_frame") as Transform3D).origin
		cam.call("debug_reset")
		_refill()
		_ok(bool(ws.call("fire_along_ray", cam3.global_position, (belly - cam3.global_position).normalized(), true)), "shotgun shot %d fired" % (k + 1))
		var started := false
		for w in 60:
			await physics_frame
			if bool(cam.get("playing")):
				started = true
				break
		var last := Time.get_ticks_usec()
		var n := 0
		while bool(cam.get("playing")) and n < 2000:
			await process_frame
			var now := Time.get_ticks_usec()
			worst_frame = maxf(worst_frame, float(now - last) / 1000.0)
			last = now
			n += 1
		_ok(started, "shotgun cinematic %d played" % (k + 1))
		await _phys(20)
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("v041: shotgun cinematics x4: nodes %d -> %d, worst frame %.1f ms" % [base_nodes, nodes, worst_frame])
	_ok(is_equal_approx(Engine.time_scale, 1.0), "time scale back to 1 after 4 shotgun cinematics")
	_ok(nodes - base_nodes < 80, "node count stays bounded (+%d after 4 cinematics; decals capped, casings pooled)" % (nodes - base_nodes))
	_ok(worst_frame < 80.0, "no long hitch during/after shotgun cinematics (worst %.1f ms, was ~120 ms on first wound)" % worst_frame)
	cam.set("debug_roll", -1.0)
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
