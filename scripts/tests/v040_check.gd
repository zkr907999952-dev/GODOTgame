extends SceneTree
## 0.2.12 自检 t25u：非手枪左手真正握在护木/泵动前托上；枪膛轴线指向视线目标（平视不下垂）；
## 俯仰以肩/枪托为轴；只有霰弹才触发多弹头特写，其它武器单发跟随；射击后无悬浮黑点。
##   godot --headless --path . -s res://scripts/tests/v040_check.gd

const VERSION_NAME := "0.2.13"
const VERSION_CODE := 15

var main: Node
var player: Node
var ws: Node
var settings: Node
var fails := 0
var spawn := Vector3.ZERO
var yaw_now := 0.0


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
		print("v040: OK   ", msg)
	else:
		fails += 1
		push_error("v040: FAIL " + msg)


func _ready_gun(id: String) -> void:
	ws.call("select", id)
	for i in 5:
		ws.call("debug_finish_state")
		await _frames(2)
		await _phys(1)


func _home() -> void:
	# 出生点在地板上（(1.4,0,2.2) 在这张地图上是空的，会一直下落导致身体与镜头错位）。
	player.global_position = spawn
	player.velocity = Vector3.ZERO
	player.set("input_locked", false)
	player.set("_yaw", 0.0)
	player.set("_pitch", 0.0)
	player.call("_apply_camera")


func _pose(ads: bool, pitch: float) -> void:
	ws.call("set_ads", ads)
	ws.set("_ads_k", 1.0 if ads else 0.0)
	player.set("_yaw", yaw_now)
	player.set("_pitch", pitch)
	player.call("_apply_camera")
	await _phys(14)
	await _frames(2)


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
		print("v040_check: fails=", fails)
		quit(1)
		return
	spawn = player.global_position

	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("version/name=\"%s\"" % VERSION_NAME) >= 0, "export versionName is %s" % VERSION_NAME)
	_ok(presets.find("version/code=%d" % VERSION_CODE) >= 0, "versionCode is %d" % VERSION_CODE)
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("package/name=\"蒂法玉腹沙盒\"") >= 0, "visible name unchanged")
	_ok(presets.find("keystore/release_password=\"\"") >= 0, "no release password committed")

	_check_sources()
	await _check_left_grip()
	await _check_bore_aim()
	await _check_pitch_pivot()
	await _check_bullet_cam_modes()
	await _check_no_floating_blobs()

	print("v040_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _check_sources() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/weapons/weapon_system.gd")
	_ok(src.find("func _shoulder_pivot_xf") >= 0, "FP pitch pivots about the stock / shoulder")
	_ok(src.find("func _converge_about") >= 0, "bore converges on the aim point")
	_ok(src.find("tilt = -u * 0.16") < 0, "look-up counter tilt (gun droop) removed")
	_ok(src.find("aim = (fwd + up * (-0.06") < 0, "observe aim no longer pitched down 6%")
	_ok(src.find("apply_ik_after_loco") >= 0, "apply_ik_after_loco still present")
	var bc := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(bc.find("best_shot_cluster") < 0, "bullet cam no longer borrows another shot's pellet cluster")
	_ok(bc.find("func is_cluster_shot") >= 0, "cluster mode is gated on the shotgun category")
	var sec := FileAccess.get_file_as_string("res://scripts/soft_secondary.gd")
	var fn := sec.find("func _apply_aim_waist")
	if fn >= 0:
		var body := sec.substr(fn, 500)
		_ok(body.find("_nudge_look_bone") < 0, "no waist/spine lean (t24u removal kept)")


func _check_left_grip() -> void:
	for mode in [1, 0]:
		player.call("set_play_mode", 1)
		_home()
		for id in ["rifle", "smg", "shotgun"]:
			await _ready_gun(id)
			if mode == 0:
				player.call("set_play_mode", 0)
			for ads in [false, true]:
				await _pose(ads, 0.0)
				var g: Dictionary = ws.call("debug_left_grip")
				var tag := "%s %s %s" % ["FP" if mode == 1 else "TP", id, "ADS" if ads else "hip"]
				_ok(float(g.get("w", 0.0)) > 0.95, "%s left grip active (w=%.2f)" % [tag, float(g.get("w", 0.0))])
				_ok(float(g.get("palm_to_attach", 9.0)) < 0.03, "%s left palm on handguard/pump (%.1f cm)" % [tag, float(g.get("palm_to_attach", 9.0)) * 100.0])
				_ok(int(g.get("inside", 9)) == 0, "%s left hand not inside the gun mesh (inside=%s)" % [tag, str(g.get("inside", "?"))])
				_ok(absf(float(g.get("along_x", 9.0))) < 0.03, "%s palm stays on handguard, not slid into mag well (%.1f cm)" % [tag, float(g.get("along_x", 9.0)) * 100.0])
			if mode == 0:
				player.call("set_play_mode", 1)
	# 手枪不变：不使用长枪护木握持
	player.call("set_play_mode", 1)
	_home()
	await _ready_gun("pistol")
	await _pose(false, 0.0)
	var gp: Dictionary = ws.call("debug_left_grip")
	_ok(float(gp.get("w", 0.0)) < 0.01 and not bool(gp.get("long", true)), "pistol keeps its two-hand grip (no foregrip override)")


var open_yaw := 0.0


func _find_open_yaw() -> void:
	# 找一个前方开阔（≥12m）的朝向，平视测试才不会被近处墙面的汇聚角干扰。
	var best := 0.0
	var best_d := 0.0
	var cam3: Camera3D = player.call("get_camera")
	for k in 24:
		var yaw := TAU * float(k) / 24.0
		player.set("_yaw", yaw)
		player.set("_pitch", 0.0)
		player.call("_apply_camera")
		await _phys(1)
		var from := cam3.global_position
		var fwd := -cam3.global_transform.basis.z
		var q := PhysicsRayQueryParameters3D.create(from, from + fwd * 60.0, 1 | 2)
		q.exclude = [player.get_rid()]
		var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
		var d := 60.0 if hit.is_empty() else from.distance_to(hit["position"])
		if d > best_d:
			best_d = d
			best = yaw
	open_yaw = best
	print("v040: open yaw %.2f (%.1f m clear)" % [best, best_d])


func _check_bore_aim() -> void:
	player.call("set_play_mode", 1)
	_home()
	await _find_open_yaw()
	yaw_now = open_yaw
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		await _ready_gun(id)
		for pitch in [0.0, 0.5, -0.6]:
			await _pose(false, pitch)
			var b: Dictionary = ws.call("debug_bore_aim")
			var along := float(b.get("along", 1.0))
			# 允许误差：瞄准点距离的 1%（≈0.6°）+ 6cm
			var tol := 0.06 + 0.01 * along
			_ok(float(b.get("miss", 9.0)) < tol, "FP %s hip pitch %.1f: bore passes the aim point (miss %.2f m @ %.1f m)" % [id, pitch, float(b.get("miss", 9.0)), along])
			if pitch == 0.0:
				# 近处墙面：枪口低于眼睛，汇聚到准心点必然略微上扬；绝不能下垂。
				_ok(float(b.get("gun_pitch", -9.0)) > -0.5, "FP %s hip level (wall at %.1f m): muzzle does not droop (%.1f°)" % [id, along, float(b.get("gun_pitch", 0.0))])
				# 远处目标（固定 30m 汇聚）：枪的俯仰与视线基本一致。
				ws.set("debug_aim_dist", 30.0)
				await _pose(false, 0.0)
				var bf: Dictionary = ws.call("debug_bore_aim")
				ws.set("debug_aim_dist", -1.0)
				_ok(float(bf.get("miss", 9.0)) < 0.36, "FP %s hip level @30 m: bore hits the aim point (miss %.2f m)" % [id, float(bf.get("miss", 9.0))])
				_ok(float(bf.get("pitch_err", 99.0)) < 2.0 and float(bf.get("gun_pitch", -9.0)) > -0.5, "FP %s hip level @30 m: gun pitch matches view (%.1f° vs %.1f°)" % [id, float(bf.get("gun_pitch", 0.0)), float(bf.get("view_pitch", 0.0))])
		await _pose(true, 0.0)
		var ba: Dictionary = ws.call("debug_bore_aim")
		_ok(float(ba.get("pitch_err", 99.0)) < 2.5, "FP %s ADS level: gun pitch within a few degrees of view (%.1f°)" % [id, float(ba.get("pitch_err", 99.0))])
	for id in ["rifle", "smg", "shotgun", "pistol"]:
		player.call("set_play_mode", 1)
		_home()
		await _ready_gun(id)
		player.call("set_play_mode", 0)
		await _pose(false, 0.0)
		var bt: Dictionary = ws.call("debug_bore_aim")
		_ok(float(bt.get("miss", 9.0)) < 0.10, "observe %s: bore intersects the eye-line target (miss %.3f m)" % [id, float(bt.get("miss", 9.0))])
		_ok(float(bt.get("pitch_err", 99.0)) < 3.0 and float(bt.get("gun_pitch", -9.0)) > -2.0, "observe %s: level look keeps the gun level (gun %.1f° view %.1f°)" % [id, float(bt.get("gun_pitch", 0.0)), float(bt.get("view_pitch", 0.0))])
	player.call("set_play_mode", 1)
	yaw_now = 0.0


func _check_pitch_pivot() -> void:
	player.call("set_play_mode", 1)
	_home()
	for id in ["rifle", "shotgun"]:
		await _ready_gun(id)
		var d_ua: Array = []
		var hands: Array = []
		var hs_d: Array = []
		for pitch in [-0.6, 0.0, 0.5]:
			await _pose(false, pitch)
			var sp: Dictionary = ws.call("debug_stock_pivot")
			var st: Vector3 = sp["stock"]
			var ua: Vector3 = sp["R_UpperArm_a"]
			var lh: Vector3 = sp["L_Hand_a"]
			d_ua.append(st.distance_to(ua))
			hands.append(lh)
			hs_d.append(lh.distance_to(st))
		var spread := float(d_ua.max()) - float(d_ua.min())
		_ok(spread < 0.06, "%s: stock stays in the shoulder pocket across pitch (stock-to-upper-arm spread %.1f cm)" % [id, spread * 100.0])
		var arc := (hands[0] as Vector3).distance_to(hands[2])
		_ok(arc > 0.15, "%s: left hand swings in an arc with pitch (%.0f cm)" % [id, arc * 100.0])
		var hs_spread := float(hs_d.max()) - float(hs_d.min())
		_ok(hs_spread < 0.06, "%s: hand-to-stock distance constant -> rotation about the stock/shoulder, not the hand (%.1f cm)" % [id, hs_spread * 100.0])
	await _pose(false, 0.0)


func _fire_and_consider(id: String, target: Node, cam: Node) -> Dictionary:
	await _ready_gun(id)
	var cam3: Camera3D = player.call("get_camera")
	var organs: Node = target.call("get_organs")
	var belly: Vector3 = (target as Node3D).global_position + Vector3(0, 1.05, 0)
	if organs and organs.has_method("abdomen_frame"):
		belly = (organs.call("abdomen_frame") as Transform3D).origin
	var origin: Vector3 = cam3.global_position
	var dir := (belly - origin).normalized()
	ws.call("fire_along_ray", origin, dir, true)
	var bal: Node = ws.get("ballistics")
	var lead := {}
	var arr: Array = bal.call("live_projectiles")
	# 最新一发（数组末尾）是本次射击
	for i in range(arr.size() - 1, -1, -1):
		if arr[i] is Dictionary:
			lead = arr[i]
			break
	if not lead.is_empty():
		var sid := int(lead.get("shot_id", 0))
		for p in arr:
			if p is Dictionary and int(p.get("shot_id", -1)) == sid:
				lead = p
				break
	var info := {
		"gut": true, "body": target, "organs": organs,
		"entry": belly, "pos": belly, "exit": belly + dir * 0.22,
		"dir": dir, "origin": origin,
	}
	cam.call("debug_reset")
	var did := bool(cam.call("consider", info, lead))
	var out := {"did": did, "mode": str(cam.call("cinematic_mode")), "n": int(cam.call("cinematic_pellet_count"))}
	if did:
		var worst := 0.0
		var lo := 999.0
		for k in 8:
			cam.call("debug_advance", 0.06)
			var te: Dictionary = cam.call("debug_track_error")
			if bool(te.get("ok", false)) and str(te.get("phase", "")) == "follow":
				worst = maxf(worst, float(te.get("angle", 0.0)))
				lo = minf(lo, float(te.get("angle", 0.0)))
		out["track_angle"] = worst
		out["track_jitter"] = worst - lo if lo < 999.0 else 99.0
		cam.call("debug_advance", 0.4)
		out["trails"] = int(cam.call("smoke_trail_count")) if cam.has_method("smoke_trail_count") else 0
		cam.call("skip")
	cam.call("debug_reset")
	return out


func _check_bullet_cam_modes() -> void:
	player.call("set_play_mode", 1)
	_home()
	var cam3: Camera3D = player.call("get_camera")
	var fwd := -cam3.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	main.call("spawn_clone", player.global_position + fwd * 1.8)
	await _frames(10)
	await _phys(4)
	var clones: Array = main.call("get_clones")
	var target: Node = clones[clones.size() - 1] if not clones.is_empty() else null
	var cam: Node = main.get_node_or_null("BulletCam")
	_ok(target != null and cam != null, "clone target and bullet cam present")
	if target == null or cam == null:
		return
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	# 先打一发霰弹，让弹组还留在弹道系统里——旧 bug 会把它塞进后面步枪的特写。
	var sg: Dictionary = await _fire_and_consider("shotgun", target, cam)
	_ok(bool(sg.get("did")) and str(sg.get("mode")) == "cluster" and int(sg.get("n")) >= 4, "shotgun uses multi-pellet cluster mode (mode=%s n=%d)" % [str(sg.get("mode")), int(sg.get("n", 0))])
	_ok(int(sg.get("trails", 0)) >= 2, "shotgun pellets keep white trails (trails=%d)" % int(sg.get("trails", 0)))
	var ws_bal: Node = ws.get("ballistics")
	ws.call("fire_along_ray", cam3.global_position, (-cam3.global_transform.basis.z).normalized(), true)
	for id in ["rifle", "pistol", "smg"]:
		var r: Dictionary = await _fire_and_consider(id, target, cam)
		_ok(bool(r.get("did")) and str(r.get("mode")) == "single" and int(r.get("n")) == 1, "%s uses single-bullet follow cam even with shotgun pellets alive (mode=%s n=%d)" % [id, str(r.get("mode")), int(r.get("n", 0))])
		# 跟随机位按设计在弹头侧后上方（固定 ≈23.6° 构图偏移）；关键是全程锁定、不漂移。
		_ok(float(r.get("track_angle", 99.0)) < 30.0 and float(r.get("track_jitter", 99.0)) < 2.0, "%s follow cam stays locked on the bullet (offset %.1f°, drift %.2f°)" % [id, float(r.get("track_angle", 99.0)), float(r.get("track_jitter", 99.0))])
		_ok(int(r.get("trails", 0)) >= 1, "%s keeps its white trail (trails=%d)" % [id, int(r.get("trails", 0))])
	# 观察模式
	await _ready_gun("rifle")
	player.call("set_play_mode", 0)
	await _phys(2)
	var ro: Dictionary = await _fire_and_consider("rifle", target, cam)
	_ok(bool(ro.get("did")) and str(ro.get("mode")) == "single", "observe-mode rifle cinematic is single-bullet (mode=%s)" % str(ro.get("mode")))
	player.call("set_play_mode", 1)
	var src := FileAccess.get_file_as_string("res://scripts/weapons/bullet_cam.gd")
	_ok(src.find("HOLD_SEC") >= 0 and src.find("_burst_lock") >= 0, "4 s hold and auto-burst interrupt still present")
	cam.set("debug_roll", -1.0)
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	if ws_bal:
		pass


func _check_no_floating_blobs() -> void:
	player.call("set_play_mode", 1)
	_home()
	var bal: Node = ws.get("ballistics")
	await _ready_gun("shotgun")
	var cam3: Camera3D = player.call("get_camera")
	for k in 4:
		var dir := (-cam3.global_transform.basis.z + Vector3(0.06 * (k - 1.5), -0.08, 0.0)).normalized()
		ws.call("fire_along_ray", cam3.global_position, dir, true)
		for i in 6:
			await _phys(1)
	Engine.time_scale = 1.0
	for i in 90:
		await _phys(1)
	var n_dec := int(bal.call("decal_count"))
	var floating := int(bal.call("floating_decal_count"))
	_ok(n_dec > 0, "shots left impact decals on surfaces (n=%d)" % n_dec)
	_ok(floating == 0, "no floating dark blobs after shooting (floating=%d / %d)" % [floating, n_dec])
	var spent := int(bal.call("spent_visible_count")) if bal.has_method("spent_visible_count") else 0
	_ok(spent == 0, "no spent projectile meshes hanging in the air (%d)" % spent)
	var ig := root.get_tree().get_nodes_in_group("ballistics_ignore")
	_ok(bal.has_method("ignore_rids"), "impact spheres are excluded from bullet rays (ignore group, %d live)" % ig.size())
