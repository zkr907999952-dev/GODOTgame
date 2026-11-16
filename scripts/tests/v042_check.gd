extends SceneTree
## 0.2.14 自检 t28u：躯干皮肤保留暗红透明弹道孔（ball_wound 裁切 + 暗红腔色），人体仍不贴黑点弹孔贴花；
## 特写镜头：弹头穿出后继续飞，但镜头始终环绕受击区域（不跟弹头出去），单发与霰弹群、4 秒停留都一样。
##   godot --headless --path . -s res://scripts/tests/v042_check.gd

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
		print("v042: OK   ", msg)
	else:
		fails += 1
		push_error("v042: FAIL " + msg)


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
		print("v042_check: fails=", fails)
		quit(1)
		return
	spawn = player.global_position
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	_ok(presets.find("package/unique_name=\"com.zkr907999952.rouchang\"") >= 0, "applicationId unchanged")
	_ok(presets.find("keystore/release_password=\"\"") >= 0 and presets.find("keystore/release=\"\"") >= 0, "no keystore path/password committed")
	_check_shader_source()
	await _check_hole_and_decals()
	for mode in [1, 0]:
		await _check_cam_orbit(mode)
	print("v042_check: fails=", fails)
	quit(0 if fails == 0 else 1)


func _belly(c: Node) -> Vector3:
	return ((c.call("get_organs") as Node).call("abdomen_frame") as Transform3D).origin


func _fwd() -> Vector3:
	var cam3: Camera3D = player.call("get_camera")
	var f := -cam3.global_transform.basis.z
	f.y = 0.0
	return f.normalized()


# ---- 1) 暗红透明弹道孔：着色器里保留裁切 + 暗红腔色，且腔色是暗红不是纯黑
func _check_shader_source() -> void:
	var skin := FileAccess.get_file_as_string("res://shaders/skin_xray.gdshader")
	_ok(skin.find("ball_wound(v_ab)") >= 0, "torso skin shader evaluates the bullet channel (ball_wound)")
	_ok(skin.find("bw > 0.55") >= 0, "channel core is see-through (alpha-scissor cut, translucent hole)")
	_ok(skin.find("mix(ALBEDO, cavity_color") >= 0, "hole rim tinted with the cavity colour")
	_ok(skin.find("discard") < 0, "still no discard (mobile depth prepass safe)")
	var inc := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	var col := Color(0, 0, 0)
	var re := RegEx.create_from_string("uniform vec3 cavity_color[^=]*=\\s*vec3\\(([0-9.]+),\\s*([0-9.]+),\\s*([0-9.]+)\\)")
	var m := re.search(inc)
	if m:
		col = Color(float(m.get_string(1)), float(m.get_string(2)), float(m.get_string(3)))
	_ok(col.r > 0.15 and col.r > col.g * 2.0 and col.r > col.b * 2.0 and col.r < 0.6, "cavity colour is dark red, not black (%.2f, %.2f, %.2f)" % [col.r, col.g, col.b])


# ---- 1b) 命中后弹道通道被推给皮肤材质（孔会出现），人体不贴弹孔贴花，墙面照旧；无长帧
func _check_hole_and_decals() -> void:
	player.call("set_play_mode", 1)
	_home()
	if settings:
		settings.call("set_bullet_cam_chance", 0.0)
	var cam3: Camera3D = player.call("get_camera")
	var c: Node = await _clone(_fwd() * 1.8)
	var bal: Node = ws.get("ballistics")
	bal.call("clear_decals")
	# 不打自己（hit_owner=false）：从镜头射出时自带身体的 BodyHit 会先挡住子弹。
	var org: Node = c.call("get_organs")
	await _ready_gun("rifle")
	var worst := 0.0
	var last := Time.get_ticks_usec()
	for k in 3:
		_refill()
		ws.call("fire_along_ray", cam3.global_position, (_belly(c) - cam3.global_position).normalized(), false)
		for i in 15:
			await process_frame
			var now := Time.get_ticks_usec()
			worst = maxf(worst, float(now - last) / 1000.0)
			last = now
	var ch: Array = org.get("_ball_ch")
	_ok(ch.size() > 0, "bullet channel recorded on the body (%d)" % ch.size())
	var pushed := false
	var mats: Array = org.get("_all_mats")
	for m in mats:
		if m is ShaderMaterial and (m as ShaderMaterial).shader and (m as ShaderMaterial).shader.resource_path.ends_with("skin_xray.gdshader"):
			var bb = (m as ShaderMaterial).get_shader_parameter("ball_b")
			if bb is Array:
				for v in bb:
					if v is Vector4 and (v as Vector4).w > 0.0:
						pushed = true
	_ok(pushed, "channel pushed to the torso skin material -> dark-red hole is drawn")
	_ok(worst < 80.0, "no long hitch when the hole appears (worst frame %.1f ms)" % worst)
	_ok(int(bal.call("body_decal_count", [c])) == 0, "no black bullet-hole decals stuck on the body")
	await _ready_gun("shotgun")
	_refill()
	ws.call("fire_along_ray", cam3.global_position, (_belly(c) - cam3.global_position).normalized(), false)
	await _phys(30)
	_ok(int(bal.call("body_decal_count", [c])) == 0, "shotgun: still no body decals")
	_ok(int(bal.call("decal_count")) > 0, "walls keep their decals (%d)" % int(bal.call("decal_count")))
	c.queue_free()
	await _frames(2)


# ---- 2) 特写：弹头穿出继续飞，镜头仍环绕受击区域
func _check_cam_orbit(mode: int) -> void:
	player.call("set_play_mode", 1)
	_home()
	var cam3: Camera3D = player.call("get_camera")
	var c: Node = await _clone(_fwd() * 1.8)
	if mode == 0:
		player.call("set_play_mode", 0)
		await _phys(4)
	var cam: Node = main.get_node_or_null("BulletCam")
	var bal: Node = ws.get("ballistics")
	if settings:
		settings.call("set_bullet_cam_enabled", true)
		settings.call("set_bullet_cam_chance", 1.0)
	cam.set("debug_roll", 0.0)
	var mtag := "FP" if mode == 1 else "observe"
	for id in ["rifle", "shotgun"]:
		player.call("set_play_mode", 1)
		await _ready_gun(id)
		if mode == 0:
			player.call("set_play_mode", 0)
			await _phys(2)
		_refill()
		var b := _belly(c)
		var origin: Vector3 = cam3.global_position if mode == 1 else player.global_position + Vector3(0, 1.4, 0)
		var dir := (b - origin).normalized()
		ws.call("fire_along_ray", origin, dir, false)
		var arr: Array = bal.call("live_projectiles")
		var lead: Dictionary = arr[arr.size() - 1] if not arr.is_empty() else {}
		var info := {"gut": true, "body": c, "organs": c.call("get_organs"), "entry": b, "pos": b, "exit": b + dir * 0.22, "dir": dir, "origin": origin}
		cam.call("debug_reset")
		var did := bool(cam.call("consider", info, lead))
		var tag := "%s %s" % [mtag, id]
		_ok(did, "%s cinematic started" % tag)
		if not did:
			continue
		var t := 0.0
		var max_dist := 0.0
		var max_err := 0.0
		var max_jump := 0.0
		var bullet_far := 0.0
		var beyond := 0.0
		var hold_at := -1.0
		var post_n := 0
		var prev := Vector3.INF
		var pellets := int(cam.call("cinematic_pellet_count"))
		while bool(cam.get("playing")) and t < 20.0:
			cam.call("debug_advance", 0.05)
			t += 0.05
			var ph := str(cam.get("debug_phase"))
			var f: Dictionary = cam.call("debug_cam_focus")
			if not bool(f.get("ok", false)):
				continue
			if ph == "through" or ph == "hold":
				post_n += 1
				max_dist = maxf(max_dist, float(f["dist"]))
				max_err = maxf(max_err, float(f["look_err"]))
				bullet_far = maxf(bullet_far, float(f["bullet_dist"]))
				var d: Dictionary = cam.call("debug_through")
				beyond = maxf(beyond, float(d["max_beyond_exit"]))
				var eye: Vector3 = f["eye"]
				if prev != Vector3.INF:
					max_jump = maxf(max_jump, eye.distance_to(prev))
				prev = eye
			elif ph == "park":
				prev = f["eye"]
			if ph == "hold" and hold_at < 0.0:
				hold_at = t
		_ok(post_n > 10, "%s: ran the through + hold phases (%d samples)" % [tag, post_n])
		_ok(beyond > 0.3, "%s: bullet keeps flying past the exit (%.2f m)" % [tag, beyond])
		_ok(max_dist < 0.75, "%s: camera stays at the hit region while the bullet flies on (max %.2f m from impact)" % [tag, max_dist])
		_ok(max_err < 6.0, "%s: camera keeps looking at the impact point (max %.1f°)" % [tag, max_err])
		_ok(bullet_far > max_dist + 0.4, "%s: camera does not follow the bullet out (bullet %.2f m away vs impact %.2f m)" % [tag, bullet_far, max_dist])
		_ok(max_jump < 0.05, "%s: orbit is continuous through park -> through -> hold, no snap (max step %.3f m)" % [tag, max_jump])
		_ok(hold_at > 0.0 and t - hold_at > 3.8, "%s: 4 s hold orbiting the hit region (%.1f s)" % [tag, t - hold_at])
		if id == "shotgun":
			_ok(pellets > 1, "%s: cluster mode (%d pellets)" % [tag, pellets])
		else:
			_ok(pellets == 1, "%s: single-bullet mode" % tag)
		_ok(is_equal_approx(Engine.time_scale, 1.0), "%s: time scale restored" % tag)
		var visible_sphere := false
		for n in root.get_tree().get_nodes_in_group("ballistics_ignore"):
			for m in (n as Node).find_children("*", "MeshInstance3D", true, false):
				if (m as MeshInstance3D).visible:
					visible_sphere = true
		_ok(not visible_sphere, "%s: impact spheres hidden" % tag)
		cam.call("debug_reset")
		await _phys(10)
	cam.set("debug_roll", -1.0)
	if settings:
		settings.call("set_bullet_cam_chance", 0.20)
	player.call("set_play_mode", 1)
	c.queue_free()
	await _frames(2)
