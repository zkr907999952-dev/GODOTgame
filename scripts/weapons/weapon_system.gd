extends Node
## 武器模块（第一人称 / 角色控制模式）。
## - 武器数据：assets/weapons/<id>/<id>.tres（WeaponDef），自动扫描，新增武器只加文件。
## - 枪模型 / 枪动画 / 剪影图标 / 枪口火焰：Kuptchi PSX-Weapons 免费包。
## - 手：素材里的手臂网格不导入；手臂动画烘焙成「相机空间的手腕 / 手掌朝向 / 手指弯曲」，
##   每帧用两骨 IK + 手指弯曲驱动**我们角色自己的**手臂 / 手指骨骼（arm_clips.gd）。
## - 射击 / 换弹 / 切枪 / 收枪 / 开镜 / 后坐力 / 枪口火焰 / 抛壳；弹道占位见 ballistics.gd。

signal weapon_changed(id: String)
signal ammo_changed(id: String, mag: int, reserve: int)
## 每发弹丸一次（霰弹 8 次）：起点、方向、武器 id —— 弹道系统 / 命中判定从这里接
signal shot_fired(origin: Vector3, dir: Vector3, weapon_id: String)
signal fired(weapon_id: String)
signal dry_fired(weapon_id: String)
signal reload_started(weapon_id: String, empty: bool)
signal reloaded(weapon_id: String)
## 声音钩子：event = fire / dry / reload / draw / holster（素材包没有音频）
signal sfx(event: String, weapon_id: String)

const WeaponDefScript = preload("res://scripts/weapons/weapon_def.gd")
const ArmClips = preload("res://scripts/weapons/arm_clips.gd")
const BallisticsScript = preload("res://scripts/weapons/ballistics.gd")
const CasingSystemScript = preload("res://scripts/weapons/casing_system.gd")
const WEAPON_DIR := "res://assets/weapons/"
const FLASH_TEX := preload("res://assets/weapons/shared/muzzle_flash.png")
const SHELLS_SCENE := preload("res://assets/weapons/shared/shells.scn")
const BLEND_T := 0.14
const IK_FADE := 7.0
## 手臂 IK：手肘朝下 + 向外（相机空间）
const POLE_R := Vector3(0.75, -1.0, 0.15)
const POLE_L := Vector3(-0.75, -1.0, 0.15)
const ARM_STRETCH_MAX := 1.18
var finger_gain := 1.0
const SHOULDER_MAX := 0.5

var player: Node
var camera: Camera3D
var skeleton: Skeleton3D
var ballistics: Node
var casings: Node
var _eject_q: Array = []

var defs: Array = []  # WeaponDef，按 order 排序
var ammo: Dictionary = {}  # id -> Vector2i(mag, reserve)
var current: String = ""
## 上一次持有的武器（G 重新取枪）
var last_id: String = ""
## holstered / drawing / ready / reloading / holstering
var state: String = "holstered"
var state_t: float = 0.0
var state_len: float = 0.0
var pending: String = ""
var trigger: bool = false
var _trigger_used: bool = false
var _cool: float = 0.0
var _flash_frame: int = 0
var spread_extra: float = 0.0
## 相机后坐力偏移（弧度，pitch / yaw），按 recoil_recover 指数回零
var recoil: Vector2 = Vector2.ZERO
var _kick: float = 0.0
var ads: bool = false
var _ads_k: float = 0.0
var shots_total: int = 0
var _reload_empty: bool = false
var _shell_phase: String = ""
var _fire_t: float = 99.0
var hidden_by_mode: bool = false

var view: Node3D
var gun: Node3D
var gun_ap: AnimationPlayer
var flash: MeshInstance3D
var flash_light: OmniLight3D
var _flash_t: float = 0.0
var _clips: ArmClips
var _clip: String = ""
var _clip_t: float = 0.0
var _clip_loop: bool = true
var _prev_pose: Dictionary = {}
var _blend: float = 1.0
var _last_pose: Dictionary = {}
var _ik_w: float = 0.0
var _shells: Array = []
var _shell_meshes: Dictionary = {}
var _audio: AudioStreamPlayer3D
var _sway: Vector2 = Vector2.ZERO
var _prev_cam_basis: Basis
var _fov_base: float = -1.0

## IK 骨骼缓存
var _arm: Dictionary = {}  # "R"/"L" -> {...}
var _loco_cache: Dictionary = {}  # bone idx -> Quaternion（物理帧里 loco 写的姿势）
var _ik_bones: PackedInt32Array = PackedInt32Array()
## 手指不在 loco 骨骼里：混合底 = 静止姿势
var _finger_bones: PackedInt32Array = PackedInt32Array()
var _ik_dirty: bool = false


func setup(p: Node, cam: Camera3D, sk: Skeleton3D) -> void:
	player = p
	camera = cam
	skeleton = sk
	process_priority = 10
	process_physics_priority = 10
	ballistics = BallisticsScript.new()
	ballistics.name = "Ballistics"
	add_child(ballistics)
	if p is CollisionObject3D:
		var ex: Array[RID] = [(p as CollisionObject3D).get_rid()]
		ballistics.exclude = ex
	var host: Node = p.get_parent() if p and p.get_parent() else self
	ballistics._host = host
	casings = CasingSystemScript.new()
	casings.name = "Casings"
	add_child(casings)
	casings.setup(host)
	view = Node3D.new()
	view.name = "WeaponView"
	cam.add_child(view)
	view.visible = false
	_audio = AudioStreamPlayer3D.new()
	view.add_child(_audio)
	_build_flash()
	var sh_root := SHELLS_SCENE.instantiate()
	for c in sh_root.get_children():
		if c is MeshInstance3D:
			_shell_meshes[str(c.name)] = (c as MeshInstance3D).mesh
	sh_root.free()
	load_defs()
	_setup_arms()


# ------------------------------------------------------------------ data
func load_defs() -> void:
	defs.clear()
	var dirs: PackedStringArray = ResourceLoader.list_directory(WEAPON_DIR)
	for d in dirs:
		if not d.ends_with("/") or d == "shared/":
			continue
		var id := d.trim_suffix("/")
		var path := WEAPON_DIR + d + id + ".tres"
		if not ResourceLoader.exists(path):
			continue
		var w: Resource = load(path)
		if w and w.get_script() == WeaponDefScript:
			defs.append(w)
	defs.sort_custom(func(a, b): return int(a.order) < int(b.order))
	for w in defs:
		if not ammo.has(w.id):
			ammo[w.id] = Vector2i(w.mag_size, w.reserve_start)


func weapon_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for w in defs:
		out.append(w.id)
	return out


func get_def(id: String) -> WeaponDef:
	for w in defs:
		if w.id == id:
			return w
	return null


func cur_def() -> WeaponDef:
	return get_def(current)


func ammo_of(id: String) -> Vector2i:
	return ammo.get(id, Vector2i.ZERO)


func categories() -> PackedStringArray:
	var out := PackedStringArray()
	for w in defs:
		if not out.has(w.category):
			out.append(w.category)
	return out


func is_armed() -> bool:
	return current != "" and state != "holstered"


func is_ready() -> bool:
	return state == "ready"


# ------------------------------------------------------------------ actions
## 选择武器（"" = 收枪）。正在用的武器再选一次 = 不变；切枪 = 先收后取。
func select(id: String) -> void:
	if id != "" and get_def(id) == null:
		return
	if id == current and state != "holstering":
		if state == "holstered" and id != "":
			_begin_draw(id)
		return
	if current == "" or state == "holstered":
		if id == "":
			return
		_begin_draw(id)
		return
	pending = id
	_begin_holster()


func holster() -> void:
	select("")


## 数字键：第 i 把（0 起）；当前武器再按 = 收枪
func select_slot(i: int) -> void:
	if i < 0 or i >= defs.size():
		return
	var id: String = defs[i].id
	if id == current and state != "holstered" and state != "holstering":
		holster()
	else:
		select(id)


func cycle(dir: int) -> void:
	if defs.is_empty():
		return
	var i := -1
	var target := pending if pending != "" else current
	for k in defs.size():
		if defs[k].id == target:
			i = k
	i = wrapi(i + dir, 0, defs.size()) if i >= 0 else (0 if dir > 0 else defs.size() - 1)
	select(defs[i].id)


func set_trigger(on: bool) -> void:
	if on and not trigger:
		_trigger_used = false
		# 霰弹逐发装填中扣扳机 = 打断装填
		if state == "reloading" and _shell_phase == "step":
			_shell_phase = "end_req"
	trigger = on


func set_ads(on: bool) -> void:
	ads = on


func reload() -> bool:
	if state != "ready":
		return false
	var w: WeaponDef = cur_def()
	if w == null:
		return false
	var a := ammo_of(current)
	var cap := _capacity(w, a.x)
	if a.x >= cap or a.y <= 0:
		return false
	_reload_empty = a.x == 0
	state = "reloading"
	state_t = 0.0
	ads = false
	reload_started.emit(current, _reload_empty)
	sfx.emit("reload", current)
	if w.sfx_reload:
		_play(w.sfx_reload)
	if w.shell_reload:
		_shell_phase = "start"
		state_len = maxf(0.05, _clips.length("reload_start"))
		_play_clip("reload_start", false)
	else:
		_shell_phase = ""
		var base: float = w.reload_time if w.reload_time > 0.0 else _clips.length("reload")
		state_len = (w.reload_empty_time if w.reload_empty_time > 0.0 else base * 1.3) if _reload_empty else base
		_play_clip("reload", false)
		_clip_speed = _clips.length("reload") / maxf(0.05, state_len)
		_gun_anim("reload", state_len)
	return true


func _capacity(w: WeaponDef, mag_now: int) -> int:
	return w.mag_size + (1 if (w.chamber_plus_one and mag_now > 0) else 0)


## 测试 / 调试
func debug_set_ammo(id: String, mag: int, reserve: int) -> void:
	ammo[id] = Vector2i(mag, reserve)
	ammo_changed.emit(id, mag, reserve)


func debug_finish_state() -> void:
	state_t = state_len + 0.001


# ------------------------------------------------------------------ state machine
var _clip_speed: float = 1.0


func _begin_draw(id: String) -> void:
	current = id
	last_id = id
	pending = ""
	_load_weapon(id)
	state = "drawing"
	state_t = 0.0
	var w: WeaponDef = cur_def()
	state_len = w.draw_time if w.draw_time > 0.0 else maxf(0.2, _clips.length("draw"))
	_play_clip("draw", false, true)
	_cool = 0.0
	weapon_changed.emit(id)
	sfx.emit("draw", id)
	var a := ammo_of(id)
	ammo_changed.emit(id, a.x, a.y)


func _begin_holster() -> void:
	state = "holstering"
	state_t = 0.0
	ads = false
	var w: WeaponDef = cur_def()
	state_len = (w.holster_time if w and w.holster_time > 0.0 else maxf(0.15, _clips.length("hide") if _clips else 0.3))
	if _clips:
		_play_clip("hide", false)
	sfx.emit("holster", current)


func _finish_holster() -> void:
	var nxt := pending
	_unload_weapon()
	current = ""
	state = "holstered"
	if nxt != "":
		_begin_draw(nxt)
	else:
		weapon_changed.emit("")


func _load_weapon(id: String) -> void:
	_unload_weapon()
	var w: WeaponDef = get_def(id)
	gun = w.scene.instantiate()
	view.add_child(gun)
	gun_ap = gun.find_child("AnimationPlayer", false, false)
	_clips = ArmClips.new(w.arms)
	# 枪口火焰挂到枪口
	flash.reparent(gun, false)
	flash.position = w.muzzle + Vector3(0.03 * w.flash_scale, 0.0, 0.0)
	flash_light.reparent(gun, false)
	flash_light.position = w.muzzle + Vector3(0.05, 0.0, 0.0)
	_audio.reparent(gun, false)
	_audio.position = w.muzzle
	if id == "pistol" and ammo_of(id).x == 0:
		_gun_anim("empty", 0.0, true)


func _unload_weapon() -> void:
	if flash and flash.get_parent() != view:
		flash.reparent(view, false)
		flash_light.reparent(view, false)
		_audio.reparent(view, false)
	flash.visible = false
	flash_light.visible = false
	if gun:
		gun.queue_free()
	gun = null
	gun_ap = null


func _gun_anim(name: String, dur: float = 0.0, hold_end: bool = false) -> void:
	if gun_ap == null or not gun_ap.has_animation(name):
		return
	var an := gun_ap.get_animation(name)
	gun_ap.stop()
	gun_ap.speed_scale = an.length / dur if dur > 0.0 else 1.0
	gun_ap.play(name)
	if hold_end:
		gun_ap.seek(an.length, true)
		gun_ap.pause()


# ------------------------------------------------------------------ firing
func _try_fire(delta: float) -> void:
	var w: WeaponDef = cur_def()
	if w == null:
		return
	_cool -= delta
	if trigger and OS.has_environment("WDBG"): print("dbg d=", delta, " cool=", _cool, " st=", state)
	if state != "ready" or not trigger:
		if _cool < 0.0:
			_cool = 0.0
		return
	if _sprinting():
		return
	var auto: bool = w.fire_mode == "auto"
	if not auto and _trigger_used:
		return
	if _cool > 0.0:
		return
	var a := ammo_of(current)
	if a.x <= 0:
		if not _trigger_used:
			_trigger_used = true
			dry_fired.emit(current)
			sfx.emit("dry", current)
			if w.sfx_dry:
				_play(w.sfx_dry)
			if a.y > 0:
				reload()
		return
	_trigger_used = true
	var interval := 60.0 / maxf(1.0, w.rpm)
	# 低帧率时一帧内补足应开的枪数（全自动射速与帧率无关）
	var guard := 0
	while _cool <= 0.0 and guard < 8:
		_fire_once(w)
		if OS.has_environment("WDBG"): print("dbg FIRE ", current, " cool_before=", _cool, " iv=", interval)
		_cool += interval
		guard += 1
		if not auto or ammo_of(current).x <= 0:
			break
	if _cool < 0.0:
		_cool = 0.0


func _fire_once(w: WeaponDef) -> void:
	var a := ammo_of(current)
	a.x -= 1
	ammo[current] = a
	shots_total += 1
	ammo_changed.emit(current, a.x, a.y)
	var origin := camera.global_position
	var fwd := -camera.global_transform.basis.z
	var spread := deg_to_rad((w.spread_deg * (0.35 if ads else 1.0)) + spread_extra)
	for i in maxi(1, w.pellets):
		var dir := _spread_dir(fwd, spread)
		shot_fired.emit(origin, dir, current)
		ballistics.fire_projectile(origin, dir, current, w)
	fired.emit(current)
	sfx.emit("fire", current)
	if w.sfx_fire:
		_play(w.sfx_fire)
	spread_extra = minf(w.spread_max_deg, spread_extra + w.bloom_deg)
	var k := 0.6 if ads else 1.0
	recoil.x += deg_to_rad(w.recoil_pitch) * k
	recoil.y += deg_to_rad(randf_range(-w.recoil_yaw, w.recoil_yaw)) * k
	_kick = 1.0
	_flash_t = 0.05
	_flash_frame = Engine.get_process_frames()
	flash.visible = true
	flash_light.visible = true
	flash.rotation = Vector3(0.0, 0.0, randf() * TAU)
	var fs: float = w.flash_scale * randf_range(0.8, 1.2)
	flash.scale = Vector3(fs, fs, fs)
	_fire_t = 0.0
	if _clips.has("fire_aim" if ads else "fire"):
		_play_clip("fire_aim" if ads else "fire", false, true)
	_gun_anim("fire", (60.0 / w.rpm) if w.fire_mode == "auto" else 0.0)
	if a.x == 0 and current == "pistol":
		_gun_anim("empty", 0.0, true)
	_eject_shell(w)


func _spread_dir(fwd: Vector3, ang: float) -> Vector3:
	if ang <= 1e-5:
		return fwd
	var side := fwd.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = Vector3.RIGHT
	side = side.normalized()
	var up := side.cross(fwd).normalized()
	var r := ang * sqrt(randf())
	var t := randf() * TAU
	return (fwd + (side * cos(t) + up * sin(t)) * tan(r)).normalized()


func _sprinting() -> bool:
	return player != null and Vector2(player.velocity.x, player.velocity.z).length() > 3.0


func _play(s: AudioStream) -> void:
	_audio.stream = s
	_audio.play()


# ------------------------------------------------------------------ fx
func _build_flash() -> void:
	flash = MeshInstance3D.new()
	flash.name = "MuzzleFlash"
	var q := QuadMesh.new()
	q.size = Vector2(0.16, 0.16)
	var m := StandardMaterial3D.new()
	m.albedo_texture = FLASH_TEX
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.85, 0.55)
	m.no_depth_test = false
	q.material = m
	flash.mesh = q
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.visible = false
	view.add_child(flash)
	flash_light = OmniLight3D.new()
	flash_light.name = "MuzzleLight"
	flash_light.light_color = Color(1.0, 0.72, 0.4)
	flash_light.light_energy = 2.5
	flash_light.omni_range = 3.5
	flash_light.shadow_enabled = false
	flash_light.visible = false
	view.add_child(flash_light)


func _eject_shell(w: WeaponDef) -> void:
	var delay := w.eject_delay if w.eject_delay > 0.0 else (0.32 if w.fire_mode == "pump" else 0.0)
	if delay > 0.0:
		_eject_q.append({"t": delay, "id": w.id})
	else:
		_do_eject(w)


func _do_eject(w: WeaponDef) -> void:
	if casings == null or w == null or gun == null:
		return
	var xf := Transform3D(gun.global_transform.basis.orthonormalized(), gun.global_transform * w.eject)
	var vel: Vector3 = player.velocity if player else Vector3.ZERO
	casings.call("eject", w.shell, xf, w.category, vel)


func _step_ejects(dt: float) -> void:
	if _eject_q.is_empty():
		return
	var keep: Array = []
	for e in _eject_q:
		e["t"] = float(e["t"]) - dt
		if float(e["t"]) <= 0.0:
			var w: WeaponDef = get_def(str(e.get("id", "")))
			if w:
				_do_eject(w)
		else:
			keep.append(e)
	_eject_q = keep


func _step_shells(_dt: float) -> void:
	# 旧的运动学抛壳已由 casing_system 物理模拟替代
	pass


func _play_clip(name: String, loop: bool, restart: bool = false) -> void:
	if _clips == null or not _clips.has(name):
		return
	if name == _clip and not restart:
		return
	_prev_pose = _last_pose
	_blend = 0.0 if not _prev_pose.is_empty() else 1.0
	_clip = name
	_clip_t = 0.0
	_clip_loop = loop
	_clip_speed = 1.0


func _idle_clip() -> String:
	if ads and _clips.has("aim"):
		return "aim"
	var sp := Vector2(player.velocity.x, player.velocity.z).length() if player else 0.0
	if sp > 3.0 and _clips.has("run"):
		return "run"
	if sp > 0.4 and _clips.has("walk"):
		return "walk"
	return "idle"


func _update_clip(delta: float) -> Dictionary:
	if _clips == null:
		return {}
	match state:
		"ready":
			var one_shot := (_clip == "fire" or _clip == "fire_aim") and _clip_t < _clips.length(_clip)
			if not one_shot:
				_play_clip(_idle_clip(), true)
		_:
			pass
	_clip_t += delta * _clip_speed
	var pose := _clips.sample(_clip, _clip_t, _clip_loop)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / BLEND_T)
		pose = ArmClips.blend(_prev_pose, pose, smoothstep(0.0, 1.0, _blend))
	_last_pose = pose
	return pose


func _process(delta: float) -> void:
	if player == null or view == null:
		return
	var active := bool(player.get("first_person")) and not bool(player.get("input_locked"))
	hidden_by_mode = not active
	if not active:
		trigger = false
		ads = false
		if view.visible:
			view.visible = false
		_ik_w = maxf(0.0, _ik_w - delta * IK_FADE * 2.0)
		if camera.rotation != Vector3.ZERO:
			camera.rotation = Vector3.ZERO
		_restore_fov()
		_step_shells(delta)
		_step_ejects(delta)
		if _ik_dirty:
			if _ik_w > 0.0 and not _last_pose.is_empty():
				_apply_ik(_last_pose, _ik_w)
			else:
				_restore_loco()
		return
	# ---- 状态机
	state_t += delta
	match state:
		"drawing":
			if state_t >= state_len:
				state = "ready"
		"holstering":
			if state_t >= state_len:
				_finish_holster()
		"reloading":
			_step_reload()
	_try_fire(delta)
	_fire_t += delta
	var w: WeaponDef = cur_def()
	# ---- 后坐力 / 散布 / 开镜
	var rr: float = w.recoil_recover if w else 9.0
	recoil = recoil * exp(-rr * delta)
	if recoil.length() < 1e-5:
		recoil = Vector2.ZERO
	_kick *= exp(-18.0 * delta)
	spread_extra = maxf(0.0, spread_extra - (w.spread_recover if w else 8.0) * delta)
	var want_ads := ads and state == "ready" and not _sprinting()
	_ads_k = move_toward(_ads_k, 1.0 if want_ads else 0.0, delta * 6.0)
	_step_shells(delta)
	_step_ejects(delta)
	if _flash_t > 0.0:
		_flash_t -= delta
		# 至少显示一个渲染帧（低帧率时 0.05s 可能在同一帧内就过完）
		if _flash_t <= 0.0 and Engine.get_process_frames() <= _flash_frame:
			_flash_t = 0.0001
		elif _flash_t <= 0.0:
			flash.visible = false
			flash_light.visible = false
	if current == "" or state == "holstered":
		view.visible = false
		_ik_w = maxf(0.0, _ik_w - delta * IK_FADE)
		camera.rotation = Vector3(recoil.x, recoil.y, 0.0)
		_restore_fov()
		if _ik_w > 0.0:
			_apply_ik(_last_pose, _ik_w)
		elif _ik_dirty:
			_restore_loco()
		return
	view.visible = true
	_ik_w = minf(1.0, _ik_w + delta * IK_FADE)
	camera.rotation = Vector3(recoil.x, recoil.y, 0.0)
	if _fov_base < 0.0:
		_fov_base = camera.fov
	camera.fov = lerpf(float(player.get("fp_fov")), w.ads_fov, _ads_k)
	# ---- 视模型：偏移 + 后坐 + 晃动
	var cb := camera.global_transform.basis
	if _prev_cam_basis != Basis():
		var dq := (_prev_cam_basis.inverse() * cb).get_euler()
		_sway = _sway.lerp(Vector2(clampf(dq.y, -0.08, 0.08), clampf(dq.x, -0.08, 0.08)) * 0.8, 1.0 - exp(-10.0 * delta))
	_prev_cam_basis = cb
	_sway = _sway * exp(-6.0 * delta)
	var kick_t := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(w.kick_rot) * _kick) * Basis(Vector3.UP, _sway.x) * Basis(Vector3.RIGHT, _sway.y), Vector3(0.0, 0.0, w.kick_back * _kick))
	view.transform = Transform3D(Basis().scaled(Vector3.ONE * w.view_scale), w.view_offset) * kick_t
	var pose := _update_clip(delta)
	if pose.is_empty():
		return
	gun.transform = pose["gun"]
	_apply_ik(pose, _ik_w)


func _step_reload() -> void:
	var w: WeaponDef = cur_def()
	if w == null:
		state = "ready"
		return
	if not w.shell_reload:
		if state_t >= state_len:
			var a := ammo_of(current)
			var cap := _capacity(w, a.x)
			var take := mini(cap - a.x, a.y)
			a.x += take
			a.y -= take
			ammo[current] = a
			state = "ready"
			_clip_speed = 1.0
			ammo_changed.emit(current, a.x, a.y)
			reloaded.emit(current)
			if gun_ap:
				gun_ap.stop()
				gun_ap.speed_scale = 1.0
		return
	# 霰弹：开始 → 逐发 → 结束
	if state_t < state_len:
		return
	var a2 := ammo_of(current)
	match _shell_phase:
		"start", "step", "end_req":
			if _shell_phase == "step":
				a2.x += 1
				a2.y -= 1
				ammo[current] = a2
				ammo_changed.emit(current, a2.x, a2.y)
			if _shell_phase != "end_req" and a2.x < w.mag_size and a2.y > 0:
				_shell_phase = "step"
				state_t = 0.0
				state_len = _clips.length("reload_step")
				_play_clip("reload_step", false, true)
				_gun_anim("reload_step")
			else:
				_shell_phase = "end"
				state_t = 0.0
				state_len = _clips.length("reload_end")
				_play_clip("reload_end", false, true)
				_gun_anim("reload_end")
		"end":
			_shell_phase = ""
			state = "ready"
			reloaded.emit(current)


func _restore_fov() -> void:
	if _fov_base >= 0.0:
		camera.fov = float(player.get("fp_fov"))
		_fov_base = -1.0


# ------------------------------------------------------------------ IK（自己的手臂 / 手指）
func _setup_arms() -> void:
	if skeleton == null:
		return
	for s in ["R", "L"]:
		var ids := {}
		for b in ["Shoulder_a", "UpperArm_a", "Forearm_a", "Hand_a", "Middle_a", "Index_a", "Pinky_a"]:
			ids[b] = skeleton.find_bone(s + "_" + b)
			if int(ids[b]) < 0:
				push_warning("weapon: missing bone " + s + "_" + b)
				return
		var rg := func(b: String) -> Transform3D:
			return skeleton.get_bone_global_rest(int(ids[b]))
		var hand_rest: Transform3D = rg.call("Hand_a")
		var f: Vector3 = (rg.call("Middle_a") as Transform3D).origin - hand_rest.origin
		var t: Vector3 = (rg.call("Index_a") as Transform3D).origin - (rg.call("Pinky_a") as Transform3D).origin
		var n := f.cross(t).normalized()
		var fh := f.normalized()
		var sem := Basis(fh, n.cross(fh), n)
		var palm := -n if s == "R" else n
		var fingers := []
		for fg in ArmClips.FINGERS:
			for j in ["a", "b", "c"]:
				var bi := skeleton.find_bone("%s_%s_%s" % [s, fg, j])
				if bi < 0:
					fingers.append({"i": -1})
					continue
				var ch := skeleton.get_bone_children(bi)
				var v: Vector3
				if ch.size() > 0:
					v = skeleton.get_bone_global_rest(ch[0]).origin - skeleton.get_bone_global_rest(bi).origin
				else:
					v = skeleton.get_bone_global_rest(bi).origin - skeleton.get_bone_global_rest(skeleton.get_bone_parent(bi)).origin
				var ax := v.normalized().cross(palm)
				if fg == "Thumb":
					ax = v.normalized().cross(palm.lerp(-fh, 0.0)).normalized()
				ax = (skeleton.get_bone_global_rest(bi).basis.orthonormalized().inverse() * ax.normalized()).normalized()
				fingers.append({"i": bi, "ax": ax, "rest": skeleton.get_bone_rest(bi).basis.get_rotation_quaternion(), "bend0": _rest_bend(s, fg, j, fh, palm)})
				_finger_bones.append(bi)
		_arm[s] = {
			"sh": ids["Shoulder_a"], "ua": ids["UpperArm_a"], "fa": ids["Forearm_a"], "ha": ids["Hand_a"],
			"l1": skeleton.get_bone_rest(int(ids["Forearm_a"])).origin.length(),
			"l2": skeleton.get_bone_rest(int(ids["Hand_a"])).origin.length(),
			"ua_dir": skeleton.get_bone_rest(int(ids["Forearm_a"])).origin.normalized(),
			"fa_dir": skeleton.get_bone_rest(int(ids["Hand_a"])).origin.normalized(),
			"sem_local": hand_rest.basis.orthonormalized().inverse() * sem,
			"flen": f.length(),
			"fingers": fingers,
		}
		for k in ["sh", "ua", "fa", "ha"]:
			_ik_bones.append(int(_arm[s][k]))


## 物理帧：loco 刚写完姿势 → 记下手臂 / 手指的 loco 姿势，作为 IK 混合的底
func _physics_process(_dt: float) -> void:
	if skeleton == null:
		return
	if _ik_w <= 0.0 and not is_armed() and not _ik_dirty:
		_loco_cache.clear()
		return
	for bi in _ik_bones:
		_loco_cache[bi] = skeleton.get_bone_pose_rotation(bi)


## 我们手指在 rest 姿势下的几何弯曲角（与烘焙数据同一度量）
func _rest_bend(s: String, fg: String, j: String, fh: Vector3, palm: Vector3) -> float:
	var pt := func(jj: String) -> Vector3:
		var b := skeleton.find_bone("%s_%s_%s" % [s, fg, jj])
		return skeleton.get_bone_global_rest(b).origin if b >= 0 else Vector3.INF
	var pa: Vector3 = pt.call("a")
	var pb: Vector3 = pt.call("b")
	var pc: Vector3 = pt.call("c")
	if pa == Vector3.INF or pb == Vector3.INF or pc == Vector3.INF:
		return 0.0
	var cb := skeleton.find_bone("%s_%s_c" % [s, fg])
	var ch := skeleton.get_bone_children(cb)
	var tip := skeleton.get_bone_global_rest(ch[0]).origin if ch.size() > 0 else pc + (pc - pb) * 0.8
	var d0 := (pb - pa).normalized()
	var d1 := (pc - pb).normalized()
	var d2 := (tip - pc).normalized()
	match j:
		"a":
			return atan2(d0.dot(palm), d0.dot(fh))
		"b":
			return d0.angle_to(d1)
		_:
			return d1.angle_to(d2)


func _base_rot(bi: int) -> Quaternion:
	if _finger_bones.has(bi):
		return skeleton.get_bone_rest(bi).basis.get_rotation_quaternion()
	return _loco_cache.get(bi, skeleton.get_bone_pose_rotation(bi))


func _set_rot(bi: int, q: Quaternion, w: float) -> void:
	skeleton.set_bone_pose_rotation(bi, _base_rot(bi).slerp(q, w) if w < 0.999 else q)


func _apply_ik(pose: Dictionary, w: float) -> void:
	if pose.is_empty() or skeleton == null or _arm.is_empty() or w <= 0.0:
		return
	_ik_dirty = true
	var sk_xf := skeleton.get_global_transform_interpolated()
	var to_sk := sk_xf.affine_inverse()
	var vx := view.global_transform
	var barrel := (to_sk.basis * (vx.basis * (pose["gun"] as Transform3D).basis * Vector3.RIGHT)).normalized()
	for s in ["R", "L"]:
		var a: Dictionary = _arm[s]
		var h: Dictionary = pose[s]
		var sem_cam := Basis(h["q"] as Quaternion)
		var sem_sk := (to_sk.basis * vx.basis * sem_cam).orthonormalized()
		# 手腕：让「指根」对齐素材手的指根（我们的手掌更短）
		var wrist_cam: Vector3 = (h["wrist"] as Vector3) + sem_cam.x * (float(h["flen"]) - float(a["flen"]))
		var P: Vector3 = to_sk * (vx * wrist_cam)
		var pole_cam: Vector3 = POLE_R if s == "R" else POLE_L
		var pole_sk := (to_sk.basis * camera.global_transform.basis * pole_cam).normalized()
		_solve_arm(a, P, pole_sk, sem_sk, barrel if s == "L" else Vector3.ZERO, w)
		# 手指
		var curls: PackedFloat32Array = h["curls"]
		var fl: Array = a["fingers"]
		for i in fl.size():
			var fd: Dictionary = fl[i]
			if int(fd["i"]) < 0:
				continue
			var ang := (curls[i] - float(fd["bend0"])) * finger_gain
			var q: Quaternion = (fd["rest"] as Quaternion) * Quaternion(fd["ax"] as Vector3, ang)
			_set_rot(int(fd["i"]), q, w)


func _solve_arm(a: Dictionary, P: Vector3, pole: Vector3, hand_basis: Basis, slide_axis: Vector3, w: float) -> void:
	var sh := int(a["sh"])
	var ua := int(a["ua"])
	var fa := int(a["fa"])
	var ha := int(a["ha"])
	var l1: float = a["l1"]
	var l2: float = a["l2"]
	var reach := (l1 + l2) * 0.999
	var ua_local := Transform3D(Basis(_base_rot(ua)), skeleton.get_bone_pose_position(ua))
	# 肩胛前伸：目标太远时转动锁骨（最多 SHOULDER_MAX 弧度），让肩头向目标靠
	var sh_par := skeleton.get_bone_parent(sh)
	var par_g := skeleton.get_bone_global_pose(sh_par) if sh_par >= 0 else Transform3D()
	var sh_base := Basis(_base_rot(sh))
	var sh_g := par_g * Transform3D(sh_base, skeleton.get_bone_pose_position(sh))
	var A0 := (sh_g * ua_local).origin
	if A0.distance_to(P) > reach * 0.85:
		var v0 := A0 - sh_g.origin
		var v1 := (P - sh_g.origin).normalized() * v0.length()
		var ang := minf(v0.angle_to(v1), SHOULDER_MAX)
		var axis := v0.cross(v1)
		if axis.length_squared() > 1e-10 and ang > 1e-4:
			var rot_g := Basis(axis.normalized(), ang)
			var new_b := rot_g * sh_g.basis
			var q := (par_g.basis.orthonormalized().inverse() * new_b.orthonormalized()).get_rotation_quaternion()
			_set_rot(sh, q, w)
			sh_g = skeleton.get_bone_global_pose(sh)
	else:
		_set_rot(sh, sh_base.get_rotation_quaternion(), w)
	var ua_g := sh_g * ua_local
	var A := ua_g.origin
	var d := P - A
	# 左手够不着护木：沿枪管往回滑（握护木更靠后），仍不够再允许手臂略伸长
	if slide_axis != Vector3.ZERO and d.length() > reach:
		var b := slide_axis
		var bd := d.dot(b)
		var disc := bd * bd - (d.length_squared() - reach * reach)
		var sl := bd - sqrt(disc) if disc >= 0.0 else bd
		sl = clampf(sl, 0.0, 0.3)
		P -= b * sl
		d = P - A
	var stretch := clampf(d.length() / reach, 1.0, ARM_STRETCH_MAX)
	l1 *= stretch
	l2 *= stretch
	var dist := clampf(d.length(), 0.02, (l1 + l2) * 0.999)
	var dir := d.normalized()
	var ca := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var hh := sqrt(maxf(0.0, l1 * l1 - ca * ca))
	var pd := pole - dir * pole.dot(dir)
	if pd.length_squared() < 1e-8:
		pd = Vector3.DOWN - dir * Vector3.DOWN.dot(dir)
	pd = pd.normalized()
	var elbow := A + dir * ca + pd * hh
	var target := A + dir * dist
	# 上臂
	var ua_b := ua_g.basis.orthonormalized()
	var cur := (ua_b * (a["ua_dir"] as Vector3)).normalized()
	var ua_new := Basis(Quaternion(cur, (elbow - A).normalized())) * ua_b
	_set_rot(ua, (sh_g.basis.orthonormalized().inverse() * ua_new).get_rotation_quaternion(), w)
	# 前臂
	var fa_b := (ua_new * Basis(_base_rot(fa))).orthonormalized()
	var cur2 := (fa_b * (a["fa_dir"] as Vector3)).normalized()
	var fa_new := Basis(Quaternion(cur2, (target - elbow).normalized())) * fa_b
	# 手：目标朝向；把一部分绕前臂轴的扭转分给前臂（避免手腕扭成麻花）
	var hand_g := hand_basis * (a["sem_local"] as Basis).inverse()
	var hand_local := (fa_new.inverse() * hand_g).get_rotation_quaternion()
	var ax: Vector3 = a["fa_dir"]
	var proj := Vector3(hand_local.x, hand_local.y, hand_local.z).project(ax)
	var twist := Quaternion(proj.x, proj.y, proj.z, hand_local.w).normalized()
	var share := Quaternion.IDENTITY.slerp(twist, 0.55)
	fa_new = fa_new * Basis(share)
	_set_rot(fa, (ua_new.inverse() * fa_new).get_rotation_quaternion(), w)
	if stretch > 1.0001:
		skeleton.set_bone_pose_position(fa, skeleton.get_bone_rest(fa).origin * stretch)
		skeleton.set_bone_pose_position(ha, skeleton.get_bone_rest(ha).origin * stretch)
	else:
		skeleton.set_bone_pose_position(fa, skeleton.get_bone_rest(fa).origin)
		skeleton.set_bone_pose_position(ha, skeleton.get_bone_rest(ha).origin)
	_set_rot(ha, (share.inverse() * hand_local).normalized(), w)


func _restore_loco() -> void:
	_ik_dirty = false
	for bi in _loco_cache.keys():
		skeleton.set_bone_pose_rotation(bi, _loco_cache[bi])
	for bi in _finger_bones:
		skeleton.set_bone_pose_rotation(bi, skeleton.get_bone_rest(bi).basis.get_rotation_quaternion())
	for s in _arm.keys():
		var a: Dictionary = _arm[s]
		skeleton.set_bone_pose_position(int(a["fa"]), skeleton.get_bone_rest(int(a["fa"])).origin)
		skeleton.set_bone_pose_position(int(a["ha"]), skeleton.get_bone_rest(int(a["ha"])).origin)
	_loco_cache.clear()


## 测试：手腕到素材目标的误差（米）
func debug_hand_error() -> Dictionary:
	var out := {}
	if _last_pose.is_empty() or _arm.is_empty():
		return out
	var vx := view.global_transform
	for s in ["R", "L"]:
		var a: Dictionary = _arm[s]
		var h: Dictionary = _last_pose[s]
		var sem_cam := Basis(h["q"] as Quaternion)
		var wrist_cam: Vector3 = (h["wrist"] as Vector3) + sem_cam.x * (float(h["flen"]) - float(a["flen"]))
		var want := vx * wrist_cam
		var got := skeleton.global_transform * skeleton.get_bone_global_pose(int(a["ha"])).origin
		out[s] = want.distance_to(got)
	return out
