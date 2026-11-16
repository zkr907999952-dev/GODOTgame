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
const BLEND_T := 0.22
const IK_FADE := 7.0
## 手臂 IK：手肘朝下 + 向外（相机空间）
const POLE_R := Vector3(0.75, -1.0, 0.15)
const POLE_L := Vector3(-0.75, -1.0, 0.15)
## 左手在视模型空间的修正：动画手腕偏高，会穿出护木/机匣顶。略下移并靠近枪身。
const LEFT_HAND_ADJUST := Vector3(0.0, -0.012, 0.006)
## 右手略向握把靠拢、下移，掌心贴握把而不是悬空。
const RIGHT_HAND_ADJUST := Vector3(0.006, -0.012, 0.008)
## 把动画手腕往真实握持点拉近的混合量。
const GRIP_BLEND := 0.48
var grip_curl := 0.5
## 持枪姿势整体下移（视模型 / 手臂），开镜时少移一点以免机瞄对不齐。
const ARM_DOWN_HIP := 0.04
const ARM_DOWN_ADS := 0.015
const ARM_STRETCH_MAX := 1.28
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
## 弹道特写打断连射后，必须松开扳机（并等特写冷却）才能再开。
var _need_trigger_release: bool = false
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
## 换弹时是否已抛出弹匣（每轮一次）
var _mag_ejected: bool = false
## 本轮换弹应在 state_t 到达该秒数时抛匣（与动画抛匣帧对齐）
var _mag_eject_at: float = 0.0
var _mag_insert_at: float = 0.0
var _mag_visual_hidden: bool = false
## 手枪空仓挂机：弹匣打空后锁在后方，换弹结束必须关闭。不依赖 empty 动画（该片段 0 轨道）。
var _slide_locked: bool = false
## 机瞄光学点缓存（照门孔 / 准星尖，不是骨骼原点）
var _sight_cache_id: int = -1
var _sight_cache_wid: String = ""
var _sight_cache: PackedVector3Array = PackedVector3Array()
## 各枪在枪空间实测的瞄准轴线：机瞄孔/缺口中心 → 准星尖。不要用枪口高度兜底。
const SIGHT_AXIS := {
	# 步枪：照门是提把顶部横梁上的小孔，不是大方窗中心（0.224 会把整座机瞄留在准星上方）。
	"rifle": [Vector3(0.07267, 0.2423, 0.0), Vector3(0.493687, 0.2404, 0.0)],
	"smg": [Vector3(-0.087915, 0.22168, 0.0), Vector3(0.134899, 0.21632, 0.0)],
	"pistol": [Vector3(0.01108, 0.13718, 0.0), Vector3(0.181321, 0.13718, 0.0)],
	"shotgun": [Vector3(0.075169, 0.10401, 0.0), Vector3(0.634321, 0.103667, 0.0)],
}
const PISTOL_SLIDE_CLOSED := Vector3(0.003878, 0.119461, 0.0)
const PISTOL_SLIDE_OPEN := Vector3(-0.036122, 0.119461, 0.0)
var _mag_meshes: Dictionary = {}  # id -> Mesh
var _bob_t: float = 0.0
var _bob_pos: Vector3 = Vector3.ZERO
var _bob_ang: Vector3 = Vector3.ZERO

var view: Node3D
var gun: Node3D
var gun_ap: AnimationPlayer
var flash: MeshInstance3D
var flash_light: OmniLight3D
var _flash_t: float = 0.0
var _clips: ArmClips
var _clip: String = ""
var _clip_t: float = 0.0
## t27u 泵动上膛：每次开火后左手拉动泵动前托（Forearm 骨）；枪动画由本系统逐帧 seek，与左手 IK 同一帧。
var _pump_t: float = -1.0
var _pump_dur: float = 0.0
var _pump_bone_cache: Dictionary = {}
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


func _settings_node() -> Node:
	if player:
		var n := player.get_parent()
		if n:
			return n.get_node_or_null("GameSettings")
	return null


func infinite_reserve() -> bool:
	var s := _settings_node()
	return true if s == null else bool(s.get("infinite_reserve"))


func no_reload() -> bool:
	## 武器无需换弹：弹匣不会打空，开火不必换弹。与「无限备弹」独立。
	var s := _settings_node()
	return false if s == null else bool(s.get("no_reload"))


func has_reserve(id: String = "") -> bool:
	if infinite_reserve():
		return true
	var wid := id if id != "" else current
	return ammo_of(wid).y > 0


func ammo_text(id: String = "") -> String:
	var wid := id if id != "" else current
	var a := ammo_of(wid)
	if infinite_reserve():
		return "%d / ∞" % a.x
	return "%d / %d" % [a.x, a.y]


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
	if not on:
		_need_trigger_release = false
	if on and (_need_trigger_release or _cam_blocks_fire()):
		trigger = false
		return
	if on and not trigger:
		_trigger_used = false
		# 霰弹逐发装填中扣扳机 = 打断装填
		if state == "reloading" and _shell_phase == "step":
			_shell_phase = "end_req"
	trigger = on


func interrupt_for_bullet_cam() -> void:
	## 特写一开始就切断当前连发，不因扳机仍按着而继续出弹。
	trigger = false
	_need_trigger_release = true
	if _cool < 0.05:
		_cool = 0.05


func _bullet_cam_node() -> Node:
	if player == null:
		return null
	var root := player.get_parent()
	if root and root.get("bullet_cam") != null:
		return root.get("bullet_cam")
	return null


func _cam_blocks_fire() -> bool:
	if _need_trigger_release:
		return true
	var cam := _bullet_cam_node()
	if cam == null:
		return false
	if cam.has_method("is_playing") and bool(cam.call("is_playing")):
		return true
	if bool(cam.get("_burst_lock")):
		return true
	if float(cam.get("_cooldown")) > 0.0:
		return true
	return false


func set_ads(on: bool) -> void:
	ads = on


func reload() -> bool:
	if no_reload():
		return false
	if state != "ready":
		return false
	var w: WeaponDef = cur_def()
	if w == null:
		return false
	var a := ammo_of(current)
	var cap := _capacity(w, a.x)
	if a.x >= cap or not has_reserve(current):
		return false
	_reload_empty = a.x == 0
	state = "reloading"
	state_t = 0.0
	ads = false
	_mag_ejected = false
	_mag_insert_at = 0.0
	_restore_mag_visual()
	reload_started.emit(current, _reload_empty)
	sfx.emit("reload", current)
	if w.sfx_reload:
		_play(w.sfx_reload)
	if w.shell_reload:
		_shell_phase = "start"
		state_len = maxf(0.05, _clips.length("reload_start"))
		_play_clip("reload_start", false)
		_mag_eject_at = 999.0
	else:
		_shell_phase = ""
		var base: float = w.reload_time if w.reload_time > 0.0 else _clips.length("reload")
		state_len = (w.reload_empty_time if w.reload_empty_time > 0.0 else base * 1.3) if _reload_empty else base
		_play_clip("reload", false)
		_clip_speed = _clips.length("reload") / maxf(0.05, state_len)
		_gun_anim("reload", state_len)
		_mag_eject_at = _detect_mag_eject_time(w, state_len)
		_mag_insert_at = _detect_mag_insert_time(w, state_len, _mag_eject_at)
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
	_sight_cache_id = -1
	_sight_cache_wid = ""
	_sight_cache = PackedVector3Array()
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
	_slide_locked = (id == "pistol" and ammo_of(id).x == 0)
	if _slide_locked:
		_set_pistol_slide_open(true)
	var mag_n := gun.find_child("Magazine", true, false)
	if mag_n is MeshInstance3D and (mag_n as MeshInstance3D).mesh:
		_mag_meshes[id] = (mag_n as MeshInstance3D).mesh
	elif mag_n:
		for c in mag_n.find_children("*", "MeshInstance3D", true, false):
			if (c as MeshInstance3D).mesh:
				_mag_meshes[id] = (c as MeshInstance3D).mesh
				break


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
	if _cam_blocks_fire():
		trigger = false
		if _cool < 0.0:
			_cool = 0.0
		return
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
		if no_reload():
			var cap0 := _capacity(w, a.x)
			a.x = maxi(1, cap0)
			ammo[current] = a
		else:
			if not _trigger_used:
				_trigger_used = true
				dry_fired.emit(current)
				sfx.emit("dry", current)
				if w.sfx_dry:
					_play(w.sfx_dry)
				if has_reserve(current):
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
		if not auto or ammo_of(current).x <= 0 or _cam_blocks_fire() or not trigger:
			break
	if _cool < 0.0:
		_cool = 0.0


var _aim_override: Vector3 = Vector3.ZERO
var _has_aim_override: bool = false
var _origin_override: Vector3 = Vector3.ZERO
var _has_origin_override: bool = false


func fire_at_point(world_point: Vector3) -> bool:
	var origin := camera.global_position if camera else Vector3.ZERO
	var dir := world_point - origin
	if dir.length_squared() < 1e-8:
		return false
	return fire_along_ray(origin, dir.normalized())


func fire_along_ray(origin: Vector3, dir: Vector3, hit_owner: bool = false) -> bool:
	var w: WeaponDef = cur_def()
	if w == null or not is_armed():
		return false
	if ammo_of(current).x <= 0 and not no_reload():
		return false
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-8:
		return false
	# 把「可命中本体」记在即将生成的弹头上，不能只在本函数里改全局开关：
	# _fire_once 只负责生成弹头，真正的扫掠在之后的物理帧，那时全局开关早已被清掉。
	if hit_owner and ballistics:
		ballistics.set("next_hit_owner", true)
	_aim_override = dir.normalized()
	_has_aim_override = true
	_origin_override = origin
	_has_origin_override = true
	_fire_once(w)
	_has_aim_override = false
	_aim_override = Vector3.ZERO
	_has_origin_override = false
	_origin_override = Vector3.ZERO
	if ballistics:
		ballistics.set("next_hit_owner", false)
	return true


func _fire_once(w: WeaponDef) -> void:
	var a := ammo_of(current)
	if no_reload():
		var cap := _capacity(w, a.x)
		if a.x < cap:
			a.x = cap
			ammo[current] = a
	else:
		a.x -= 1
		ammo[current] = a
	shots_total += 1
	ammo_changed.emit(current, a.x, a.y)
	var origin := _origin_override if _has_origin_override else camera.global_position
	var fwd := _aim_override if _has_aim_override else -camera.global_transform.basis.z
	var spread := deg_to_rad((w.spread_deg * (0.35 if ads else 1.0)) + spread_extra)
	if _has_aim_override:
		# 观察点击：步枪等走精确射线；霰弹仍保留自身散布，才能看出多弹头特写与分叉拖尾。
		if str(w.category) == "shotgun":
			spread = deg_to_rad(w.spread_deg * 0.9)
		else:
			spread = 0.0
	if ballistics and ballistics.has_method("begin_shot"):
		ballistics.call("begin_shot")
	for i in maxi(1, w.pellets):
		var dir := _spread_dir(fwd, spread)
		shot_fired.emit(origin, dir, current)
		ballistics.fire_projectile(origin, dir, current, w)
	if ballistics and ballistics.has_method("end_shot"):
		ballistics.call("end_shot")
	fired.emit(current)
	sfx.emit("fire", current)
	if w.sfx_fire:
		_play(w.sfx_fire)
	spread_extra = minf(w.spread_max_deg, spread_extra + w.bloom_deg)
	var k := 0.6 if ads else 1.0
	recoil.x += deg_to_rad(w.recoil_pitch) * k
	recoil.y += deg_to_rad(randf_range(-w.recoil_yaw, w.recoil_yaw)) * k
	_kick = 1.0
	_flash_t = 0.08
	_flash_frame = Engine.get_process_frames()
	flash.visible = true
	flash_light.visible = true
	flash.rotation = Vector3(0.0, 0.0, randf() * TAU)
	var fs: float = w.flash_scale * randf_range(1.05, 1.45)
	flash.scale = Vector3(fs, fs, fs)
	if flash_light:
		flash_light.light_energy = 6.0 * maxf(0.6, w.flash_scale)
		flash_light.omni_range = 5.2
	_fire_t = 0.0
	if _clips.has("fire_aim" if ads else "fire"):
		_play_clip("fire_aim" if ads else "fire", false, true)
	if w.fire_mode == "pump" and gun_ap and gun_ap.has_animation("fire"):
		_start_pump(w)
	else:
		_gun_anim("fire", (60.0 / w.rpm) if w.fire_mode == "auto" else 0.0)
	if a.x == 0 and str(w.category) == "pistol":
		_slide_locked = true
		_set_pistol_slide_open(true)
	_eject_shell(w)
	_apply_character_shot_recoil(w)


func _body_recoil_scale(w: WeaponDef) -> float:
	# 霰弹/步枪更强，冲锋枪次之，手枪最轻（不直接用 recoil_pitch，手枪相机后坐大但身体应最轻）。
	if w == null:
		return 0.55
	match str(w.category):
		"shotgun":
			return 1.0
		"rifle":
			return 0.78
		"smg":
			return 0.45
		"pistol":
			return 0.28
		_:
			return 0.55


func _apply_character_shot_recoil(w: WeaponDef) -> void:
	# 角色身体后坐 + 乳摇冲量。与相机 recoil / 视模型 _kick 独立，开镜基线不受身体后坐影响。
	if player == null or w == null:
		return
	var scale := _body_recoil_scale(w) * (0.7 if ads else 1.0)
	var sec: Variant = player.call("get_secondary") if player.has_method("get_secondary") else null
	if sec and sec.has_method("apply_fire_recoil"):
		var pitch := deg_to_rad(8.0) * scale
		var yaw := deg_to_rad(randf_range(-2.2, 2.2)) * scale
		sec.call("apply_fire_recoil", pitch, yaw)
	var br: Variant = sec.get("breasts") if sec else null
	if br and br.has_method("apply_impulse"):
		var fwd := Vector3(0, 0, 1)
		if player.has_method("_body_forward"):
			fwd = player.call("_body_forward")
		if fwd.length_squared() < 1e-8:
			fwd = Vector3(0, 0, -1)
		fwd = fwd.normalized()
		var right := Vector3.UP.cross(fwd)
		if right.length_squared() < 1e-8:
			right = Vector3.RIGHT
		right = right.normalized()
		var st: float = float(br.get("strength")) if br.get("strength") != null else 0.5
		# 默认强度 0.5 → 增益 1.0；关闭乳摇时 apply_impulse 内部会直接返回。
		var gain := st / 0.5
		var vel: Vector3 = (-fwd * 0.85 + Vector3.UP * 0.55 + right * randf_range(-0.28, 0.28)) * (1.15 * scale * gain)
		br.call("apply_impulse", vel)


func debug_fire_once() -> bool:
	var w: WeaponDef = cur_def()
	if w == null:
		return false
	if ammo_of(current).x <= 0:
		return false
	_fire_once(w)
	return true


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
	q.size = Vector2(0.28, 0.28)
	var m := StandardMaterial3D.new()
	m.albedo_texture = FLASH_TEX
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.92, 0.65)
	m.no_depth_test = false
	q.material = m
	flash.mesh = q
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.visible = false
	view.add_child(flash)
	flash_light = OmniLight3D.new()
	flash_light.name = "MuzzleLight"
	flash_light.light_color = Color(1.0, 0.78, 0.42)
	flash_light.light_energy = 6.0
	flash_light.omni_range = 5.2
	flash_light.shadow_enabled = false
	flash_light.visible = false
	view.add_child(flash_light)


func _eject_shell(w: WeaponDef) -> void:
	var delay := w.eject_delay if w.eject_delay > 0.0 else (0.32 if w.fire_mode == "pump" else 0.0)
	if w.fire_mode == "pump" and _pump_t >= 0.0:
		var back_u := _pump_back_u()
		if back_u > 0.0:
			delay = back_u * _pump_dur
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


func _is_long_gun(w: WeaponDef) -> bool:
	return w != null and str(w.category) != "pistol"


func _hip_offset(w: WeaponDef) -> Vector3:
	# 相机看向 -Z：Z 更负 = 更远离镜头，Y 更负 = 更低。步枪再略降，避免枪口顶到脸前。
	var y := -0.10 if _is_long_gun(w) else -0.072
	var z := -0.11 if _is_long_gun(w) else -0.09
	if w and str(w.category) == "shotgun":
		# 腰射原先太靠后（贴身），再向前/向外伸出，并保持略低于步枪。
		# t25u：左手握到泵动护木后整枪本来就会被「够得着」逻辑拉回约 12cm；直接把基准放在够得着处，
		# 俯仰时枪托才稳定留在肩窝（否则抬头/低头拉回量不同，枪托会离开肩窝）。
		y = -0.155
		z = -0.13
	var extra: Vector3 = w.pose_hip if w else Vector3.ZERO
	return Vector3(w.view_offset.x + 0.02 + extra.x, w.view_offset.y + y + extra.y, w.view_offset.z + z + extra.z)


func _ads_offset(w: WeaponDef) -> Vector3:
	# 开镜基线略低于旧值，再由 _align_iron_sights 把准星对准屏幕中心（随更低的摄像机）。
	# Z 不能到 0（那会把机匣贴到眼睛上）。
	var y := -0.045 if _is_long_gun(w) else -0.022
	var z := -0.15 if _is_long_gun(w) else -0.11
	var extra: Vector3 = w.pose_ads if w else Vector3.ZERO
	return Vector3(w.view_offset.x + extra.x, w.view_offset.y + y + extra.y, w.view_offset.z + z + extra.z)


## t27u：走跑/跳跃时身体（肩膀）上下左右晃动，枪要跟着一起动，而不是钉在镜头前让手臂来回拉。
## 取两肩根部在「去掉俯仰的镜头坐标」里的位置，减去其慢速均值，只保留晃动/起跳落地的瞬时部分，
## 叠加到视模型上（与 IK 手同一变换、同一帧）。
const BODY_FOLLOW_K := 0.9
const BODY_FOLLOW_TAU := 0.7
const BODY_FOLLOW_MAX := 0.07
var _bf_ref := Vector3.ZERO
var _bf_has := false
var debug_body_follow := Vector3.ZERO


func _body_follow_offset(delta: float) -> Vector3:
	debug_body_follow = Vector3.ZERO
	if not (player and bool(player.get("first_person"))) or camera == null or skeleton == null or _arm.is_empty():
		_bf_has = false
		return Vector3.ZERO
	var inv := camera.global_transform.affine_inverse()
	var skx := _skel_xf()
	var acc := Vector3.ZERO
	var n := 0
	for sd in ["R", "L"]:
		var a: Dictionary = _arm.get(sd, {})
		if a.is_empty():
			continue
		acc += inv * (skx * skeleton.get_bone_global_pose(int(a["ua"])).origin)
		n += 1
	if n == 0:
		return Vector3.ZERO
	var u := _look_up_angle()
	var lvl: Vector3 = Basis(Vector3.RIGHT, u) * (acc / float(n))
	if not lvl.is_finite():
		return Vector3.ZERO
	if not _bf_has:
		_bf_ref = lvl
		_bf_has = true
	_bf_ref = _bf_ref.lerp(lvl, 1.0 - exp(-delta / BODY_FOLLOW_TAU))
	var d := (lvl - _bf_ref) * BODY_FOLLOW_K * (1.0 - 0.6 * _ads_k)
	if d.length() > BODY_FOLLOW_MAX:
		d = d.normalized() * BODY_FOLLOW_MAX
	var out: Vector3 = Basis(Vector3.RIGHT, -u) * d
	debug_body_follow = out
	return out


func _loco_bob_xf(delta: float) -> Transform3D:
	var sp := 0.0
	if player:
		sp = Vector2(player.velocity.x, player.velocity.z).length()
	var sprint := _sprinting()
	var moving := sp > 0.4
	if not moving or _ads_k > 0.65:
		_bob_t = 0.0
		var k := 1.0 - exp(-8.0 * delta)
		_bob_pos = _bob_pos.lerp(Vector3.ZERO, k)
		_bob_ang = _bob_ang.lerp(Vector3.ZERO, k)
	else:
		var freq := 10.0 if sprint else 7.0
		_bob_t += delta * freq
		var a := 0.022 if sprint else 0.011
		var want_p := Vector3(sin(_bob_t) * a, absf(cos(_bob_t)) * a * 0.6, 0.0)
		if sprint:
			want_p += Vector3(0.008, -0.04, 0.015) * (1.0 - _ads_k)
		var want_a := Vector3((0.14 if sprint else 0.045) * sin(_bob_t * 0.5), 0.0, sin(_bob_t) * (0.07 if sprint else 0.03))
		var k2 := 1.0 - exp(-10.0 * delta)
		_bob_pos = _bob_pos.lerp(want_p, k2)
		_bob_ang = _bob_ang.lerp(want_a, k2)
	var rot := Basis(Vector3.RIGHT, _bob_ang.x) * Basis(Vector3.FORWARD, _bob_ang.z)
	return Transform3D(rot, _bob_pos)


func _look_up_angle() -> float:
	# 相对水平面的仰角：抬头为正。不依赖 _pitch 的符号约定。
	if camera == null:
		return 0.0
	var fwd := -camera.global_transform.basis.z
	return asin(clampf(fwd.y, -1.0, 1.0))


func _armed_arm_down() -> Vector3:
	# 持枪手臂/枪位整体下移一些，开镜少移以免准星对不齐。
	var y := lerpf(ARM_DOWN_HIP, ARM_DOWN_ADS, _ads_k)
	return Vector3(0.0, -y, 0.0)


func _waist_world() -> Vector3:
	if skeleton == null:
		if camera:
			return camera.global_position + Vector3(0.0, -0.48, 0.0)
		return Vector3.ZERO
	var i := skeleton.find_bone("C_Spine_a")
	if i < 0:
		i = skeleton.find_bone("C_Hip_a")
	if i < 0:
		return camera.global_position + Vector3(0.0, -0.48, 0.0) if camera else Vector3.ZERO
	return _skel_xf() * skeleton.get_bone_global_pose(i).origin


func _pitch_hold_xf() -> Transform3D:
	# 只做平移（手臂略下沉 + 抬头时少量下移防穿下巴）。0.2.12 t25u：去掉抬头时的反向倾角
	# ——那会让枪口比视线低，正是「平视时武器反而向下」的来源之一。
	if not (player and bool(player.get("first_person"))):
		return Transform3D(Basis.IDENTITY, _armed_arm_down())
	var u := _look_up_angle()
	var hip := 1.0 - _ads_k
	var extra := _armed_arm_down()
	if u > 0.0:
		extra.y += -sin(u) * (0.05 * hip + 0.02 * _ads_k)
		extra.z += (1.0 - cos(u)) * (0.04 * hip + 0.02 * _ads_k)
	return Transform3D(Basis.IDENTITY, extra)


func _shoulder_pivot_xf(xf: Transform3D, gl: Transform3D, w: WeaponDef) -> Transform3D:
	# 俯仰旋转中心 = 抵在右腋窝/肩窝的枪托后端（≈ 上臂肩关节高度）。
	# 枪身方向跟随视线（相机空间里朝向不变），位置绕枪托点摆动：抬头/低头时整条手臂和
	# 双手绕肩画弧，枪托留在肩窝；不再以手为轴，也不再以腰为轴。
	# 推导：水平时枪托在相机空间为 s；俯仰 u 后世界里枪托不动 => 相机空间里在 Rx(-u)*s。
	if not (player and bool(player.get("first_person"))) or camera == null:
		return xf
	var u := _look_up_angle()
	if w and not _is_long_gun(w):
		# t27u 手枪：旋转中心 = 右肩（上臂肩关节），双臂伸直绕肩画弧。肩膀不随低头/抬头转，
		# 当前相机空间里的肩位 S_now 已是 Rx(-u)*S_level，所以平移量 = S_now - S_level。
		var sh := _pistol_shoulder_cam()
		if sh.is_finite() and sh != Vector3.ZERO:
			var level: Vector3 = Basis(Vector3.RIGHT, u) * sh
			return Transform3D(xf.basis, xf.origin + sh - level)
	var s: Vector3 = xf * (gl * _stock_local(w))
	if not s.is_finite():
		return xf
	var moved: Vector3 = Basis(Vector3.RIGHT, -u) * s
	return Transform3D(xf.basis, xf.origin + moved - s)


## 手枪俯仰枢轴：左右肩关节（上臂根部）中点偏右手侧，在相机局部坐标。没有骨架时返回 0。
func _pistol_shoulder_cam() -> Vector3:
	if skeleton == null or camera == null or _arm.is_empty():
		return Vector3.ZERO
	var skx := _skel_xf()
	var inv := camera.global_transform.affine_inverse()
	var pts: Array[Vector3] = []
	for sd in ["R", "L"]:
		var a: Dictionary = _arm.get(sd, {})
		if a.is_empty():
			continue
		# 用走跑底姿势里的上臂根部（IK 不转锁骨，肩点就是身体上的固定点）。
		pts.append(inv * (skx * skeleton.get_bone_global_pose(int(a["ua"])).origin))
	if pts.is_empty():
		return Vector3.ZERO
	if pts.size() == 1:
		return pts[0]
	# 双手握枪：两肩之间偏右（持枪手）0.65。
	return pts[1].lerp(pts[0], 0.65)


## 自检（t27u）：当前武器俯仰枢轴（世界坐标）。
func debug_pitch_pivot() -> Vector3:
	var w: WeaponDef = cur_def()
	if w and not _is_long_gun(w) and camera:
		var sh := _pistol_shoulder_cam()
		if sh != Vector3.ZERO:
			return camera.global_transform * sh
	if gun and w:
		return gun.to_global(_stock_local(w))
	return Vector3.ZERO


## 枪口应汇聚的瞄准点（世界）。第一人称：准心射线命中点（夹在 2–60m，未命中取 30m）。
const AIM_CONVERGE_DEFAULT := 30.0
var _aim_pt_frame := -1
## 测试：>0 时跳过准心射线，固定汇聚距离（米）。
var debug_aim_dist := -1.0
## 测试：本帧为了够到握把/护木把枪往肩方向拉了多少（米）。
var debug_last_pull := 0.0
var _aim_dist := AIM_CONVERGE_DEFAULT


func _center_aim_point() -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var fr := Engine.get_process_frames()
	if fr == _aim_pt_frame:
		return camera.global_position - camera.global_transform.basis.z.normalized() * _aim_dist
	var from := camera.global_position
	var fwd := -camera.global_transform.basis.z.normalized()
	var dist := AIM_CONVERGE_DEFAULT
	var w3 := camera.get_world_3d()
	if debug_aim_dist > 0.0:
		w3 = null
		dist = debug_aim_dist
	if w3:
		var q := PhysicsRayQueryParameters3D.create(from, from + fwd * 60.0, 1 | 2)
		var ex: Array[RID] = []
		if ballistics:
			for r in ballistics.exclude:
				if r is RID:
					ex.append(r)
			if ballistics.has_method("ignore_rids"):
				for r in ballistics.call("ignore_rids"):
					ex.append(r)
		if player is CollisionObject3D:
			ex.append((player as CollisionObject3D).get_rid())
		q.exclude = ex
		var hit := w3.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			dist = from.distance_to(hit["position"])
	dist = clampf(dist, 2.0, 60.0)
	_aim_dist = dist
	_aim_pt_frame = fr
	return from + fwd * dist


func _converge_about(xf: Transform3D, gl: Transform3D, w: WeaponDef, target: Vector3, pivot: Vector3, wt: float) -> Transform3D:
	## 让枪膛轴线（枪口 +X）穿过 target：绕 pivot（枪托后端）转动整个持枪变换。xf/target/pivot 同一坐标系。
	if w == null or wt <= 0.0:
		return xf
	for _i in 3:
		var M := xf * gl
		var muz: Vector3 = M * w.muzzle
		var bore: Vector3 = (M.basis * Vector3.RIGHT).normalized()
		var want := target - muz
		if want.length_squared() < 1e-6 or not bore.is_finite():
			return xf
		want = want.normalized()
		if bore.dot(want) > 0.999999:
			break
		var q := Quaternion(bore, want)
		if wt < 0.999:
			q = Quaternion.IDENTITY.slerp(q, wt)
		var R := Basis(q)
		xf = Transform3D(R * xf.basis, R * (xf.origin - pivot) + pivot)
	return xf


func _view_local(w: WeaponDef, pose: Dictionary = {}) -> Transform3D:
	var off: Vector3 = _hip_offset(w).lerp(_ads_offset(w), _ads_k) if w else Vector3.ZERO
	var sc: float = w.view_scale if w else 0.8
	var hold := _pitch_hold_xf()
	var xf := hold * Transform3D(Basis().scaled(Vector3.ONE * sc), off)
	var gl: Transform3D = pose["gun"] if pose.has("gun") else (gun.transform if gun else Transform3D())
	xf = _shoulder_pivot_xf(xf, gl, w)
	# 腰射：枪膛轴线汇聚到准心命中点（开镜由三点一线对准，不再叠加）。
	if camera and player and bool(player.get("first_person")) and w:
		var hip := 1.0 - clampf(_ads_k, 0.0, 1.0)
		if hip > 0.001:
			var tgt: Vector3 = camera.global_transform.affine_inverse() * _center_aim_point()
			var piv: Vector3 = xf * (gl * _stock_local(w))
			if not _is_long_gun(w):
				var shp := _pistol_shoulder_cam()
				if shp != Vector3.ZERO and shp.is_finite():
					piv = shp
			xf = _converge_about(xf, gl, w, tgt, piv, hip)
	return xf


func _tp_hold_adjust(w: WeaponDef) -> Transform3D:
	# 保留给调试；观察模式实际姿势在 _tp_view_xf。
	if not _is_long_gun(w):
		return Transform3D(Basis(Vector3.RIGHT, 0.04), Vector3(0.10, -0.10, 0.28))
	return Transform3D(Basis(Vector3.RIGHT, -0.06), Vector3(0.04, -0.08, 0.04))


func _stock_local(w: WeaponDef) -> Vector3:
	# 枪托/握把在枪局部的位置（+X 朝枪口）。用枪空间 AABB 的最小 X 面中心，忽略闪光/阴影。
	if w and not _is_long_gun(w):
		return Vector3(0.0, 0.02, 0.0)
	if gun:
		var lo := 0.0
		var found := false
		var corners: Array[Vector3] = []
		for mi in gun.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null or not (mi as MeshInstance3D).visible:
				continue
			var n := String(mi.name).to_lower()
			if "shadow" in n or "flash" in n or "muzzle" in n:
				continue
			var a: AABB = mi.mesh.get_aabb()
			var xf: Transform3D = gun.global_transform.affine_inverse() * mi.global_transform
			for k in 8:
				var p: Vector3 = xf * a.get_endpoint(k)
				corners.append(p)
				if not found or p.x < lo:
					lo = p.x
					found = true
		if found:
			var ys := 0.0
			var zs := 0.0
			var c := 0
			for p in corners:
				if p.x <= lo + 0.03:
					ys += p.y
					zs += p.z
					c += 1
			var by := (ys / float(c)) if c > 0 else 0.04
			var bz := (zs / float(c)) if c > 0 else 0.0
			return Vector3(lo + 0.015, by, bz)
	return Vector3(-0.18, 0.04, 0.0)


func _tp_view_xf(w: WeaponDef, pose: Dictionary) -> Transform3D:
	# 不要把第一人称视模型偏移带到观察模式。
	# 长枪：枪托落在肩窝（上胸高度），不要抬到脸/额头；手枪：伸到胸前，不要缩进身体。
	var fwd: Vector3 = Vector3(0, 0, 1)
	if player and player.has_method("_body_forward"):
		fwd = player.call("_body_forward")
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(0, 0, -1)
	var up := Vector3.UP
	var right := up.cross(fwd)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT
	right = right.normalized()
	var pocket: Vector3
	if player and player.has_method("shoulder_aim_transform"):
		pocket = (player.call("shoulder_aim_transform") as Transform3D).origin
	elif player:
		pocket = player.global_position + Vector3(0, 1.28, 0) + right * 0.16
	else:
		pocket = Vector3.ZERO
	var aim: Vector3
	var ads_k := clampf(_ads_k, 0.0, 1.0)
	var extra: Vector3 = Vector3.ZERO
	if w:
		extra = (w.pose_observe as Vector3).lerp(w.pose_observe_ads as Vector3, ads_k)
	if _is_long_gun(w):
		# 枪托落在腋窝口袋，不要再向胸口推。开镜时略收紧抵肩。
		pocket += right * -0.005 + fwd * -0.02 + Vector3(0.0, -0.03, 0.0)
		pocket += extra
		aim = fwd
	else:
		# 手枪握把从肩窝向前伸出到胸前，略低于肩，避免缩进躯干
		pocket += right * 0.10 + fwd * 0.28 + Vector3(0.0, -0.10, 0.0)
		pocket += extra
		aim = fwd
	# 0.2.12 t25u：枪口指向视线目标，不再固定下压 3–6%（「平视时武器反而向下」）。
	var tgt := _tp_aim_point(fwd, pocket)
	var ad := tgt - pocket
	if ad.length_squared() > 1e-4:
		aim = ad.normalized()
	var gz := aim.cross(up)
	if gz.length_squared() < 1e-8:
		gz = Vector3.RIGHT
	gz = gz.normalized()
	var gy := gz.cross(aim).normalized()
	var want_gun := Transform3D(Basis(aim, gy, gz).orthonormalized(), Vector3.ZERO)
	want_gun.origin = pocket - want_gun.basis * _stock_local(w)
	var gun_local: Transform3D = pose["gun"] if pose and pose.has("gun") else Transform3D()
	var xf := want_gun * gun_local.affine_inverse()
	# 与第一人称同样的视模型缩放，绕枪托/握把点缩放，避免托口离开肩窝。
	var sc: float = w.view_scale if w else 1.0
	if sc > 0.05 and absf(sc - 1.0) > 0.001:
		xf.origin -= pocket
		xf = Transform3D(xf.basis * sc, xf.origin * sc)
		xf.origin += pocket
	# 枪托后端为轴，让枪膛轴线精确穿过视线目标点（模型枪管与 +X 有偏差、枪口高于枪托）。
	xf = _converge_about(xf, gun_local, w, tgt, pocket, 1.0)
	return xf


func _tp_aim_point(fwd: Vector3, pocket: Vector3) -> Vector3:
	## 观察/第三人称：角色视线目标。若镜头准心射线命中点在角色前方 ±55° 内且 ≥1.5m，就指向它；
	## 否则沿身体朝向、眼睛高度平视 20m（镜头在看角色本人时不应让枪乱指）。
	var eye := pocket + Vector3(0.0, 0.16, 0.0)
	if skeleton:
		var hi := skeleton.find_bone("C_Head_a")
		if hi >= 0:
			eye = _skel_xf() * skeleton.get_bone_global_pose(hi).origin
	var fallback := eye + fwd * 20.0
	if camera == null:
		return fallback
	var from := camera.global_position
	var cf := -camera.global_transform.basis.z.normalized()
	var w3 := camera.get_world_3d()
	if w3 == null:
		return fallback
	var q := PhysicsRayQueryParameters3D.create(from, from + cf * 80.0, 1)
	var ex: Array[RID] = []
	if ballistics:
		for r in ballistics.exclude:
			if r is RID:
				ex.append(r)
	if player is CollisionObject3D:
		ex.append((player as CollisionObject3D).get_rid())
	q.exclude = ex
	var hit := w3.direct_space_state.intersect_ray(q)
	var T: Vector3 = hit["position"] if not hit.is_empty() else from + cf * 40.0
	var d := T - pocket
	if d.length() < 1.5:
		return fallback
	var flat := Vector3(d.x, 0.0, d.z)
	if flat.length_squared() < 1e-6 or flat.normalized().dot(Vector3(fwd.x, 0.0, fwd.z).normalized()) < cos(deg_to_rad(55.0)):
		return fallback
	# 俯仰夹在 ±35°，手臂够得着
	var pitch := atan2(d.y, flat.length())
	if absf(pitch) > deg_to_rad(35.0):
		d.y = tan(deg_to_rad(35.0) * signf(pitch)) * flat.length()
		T = pocket + d
	return T


func _apply_view_xf(local_xf: Transform3D, pose: Dictionary = {}) -> void:
	var fp := bool(player.get("first_person")) if player else true
	var w: WeaponDef = cur_def()
	if fp:
		view.top_level = false
		if view.get_parent() != camera and camera:
			view.reparent(camera, false)
		view.transform = local_xf
	else:
		view.top_level = true
		view.global_transform = _tp_view_xf(w, pose)


func _try_eject_mag(w: WeaponDef) -> void:
	if _mag_ejected or w == null or w.shell_reload or casings == null:
		return
	var mesh: Mesh = _mag_meshes.get(w.id)
	var xf := gun.global_transform if gun else (view.global_transform if view else Transform3D())
	if gun:
		var mag_n := gun.find_child("Magazine", true, false)
		if mag_n is Node3D:
			xf = (mag_n as Node3D).global_transform
			if mesh == null and mag_n is MeshInstance3D:
				mesh = (mag_n as MeshInstance3D).mesh
	if mesh == null:
		return
	var kind := "mag_" + w.id
	casings.call("register_mesh", kind, mesh)
	var body_vel: Vector3 = player.get("velocity") if player else Vector3.ZERO
	casings.call("eject_mag", kind, xf, body_vel)
	_mag_ejected = true
	_hide_mag_visual()


func _hide_mag_visual() -> void:
	if gun == null:
		return
	var mag_n := gun.find_child("Magazine", true, false)
	if mag_n is Node3D:
		(mag_n as Node3D).visible = false
	_mag_visual_hidden = true


func _restore_mag_visual() -> void:
	if gun:
		var mag_n := gun.find_child("Magazine", true, false)
		if mag_n is Node3D:
			(mag_n as Node3D).visible = true
			# 动画可见性轨道可能把子网格关掉，插入时一并打开。
			for c in mag_n.find_children("*", "GeometryInstance3D", true, false):
				(c as GeometryInstance3D).visible = true
	_mag_visual_hidden = false


func _detect_mag_eject_time(w: WeaponDef, dur: float) -> float:
	# 返回本轮 state_t 到达多少秒时抛出空匣，与换弹动画抛匣帧对齐。
	if w == null or w.shell_reload:
		return 999.0
	dur = maxf(dur, 0.05)
	if w.mag_eject_frac > 0.0:
		return dur * clampf(w.mag_eject_frac, 0.08, 0.85)
	var anim_t := _scan_mag_throw_time()
	if anim_t >= 0.0:
		var an_len := 0.0
		if gun_ap and gun_ap.has_animation("reload"):
			an_len = gun_ap.get_animation("reload").length
		if an_len <= 0.0 and _clips:
			an_len = _clips.length("reload")
		if an_len > 0.05:
			return clampf(anim_t * (dur / an_len), 0.08, dur * 0.85)
		return clampf(anim_t, 0.08, dur * 0.85)
	return dur * 0.38


func _detect_mag_insert_time(w: WeaponDef, dur: float, eject_at: float) -> float:
	# 新弹匣开始插入：手把弹匣抬起 / 开始送入卡槽时就显示，不要等坐实之后。
	if w == null or w.shell_reload:
		return 999.0
	dur = maxf(dur, 0.05)
	var anim_t := _scan_mag_insert_time()
	if anim_t >= 0.0:
		var an_len := 0.0
		if gun_ap and gun_ap.has_animation("reload"):
			an_len = gun_ap.get_animation("reload").length
		if an_len <= 0.0 and _clips:
			an_len = _clips.length("reload")
		var t := anim_t
		if an_len > 0.05:
			t = anim_t * (dur / an_len)
		# 略提前一帧，让弹匣在抬手时就看见；仍必须晚于抛匣。
		return clampf(t - 0.05, eject_at + 0.05, dur * 0.70)
	# 检测失败：抛匣后很快显示，宁可早一点也不要拖到插入动画演完。
	return clampf(eject_at + 0.08, dur * 0.22, dur * 0.48)


func _scan_mag_insert_time() -> float:
	# 抛匣之后：找「手把新弹匣抬起 / 开始送回卡槽」的时刻，而不是坐实（回到 1.8cm 内）的时刻。
	if gun_ap == null or not gun_ap.has_animation("reload"):
		return -1.0
	var an: Animation = gun_ap.get_animation("reload")
	var eject_t := _scan_mag_throw_time()
	var best := -1.0
	for ti in an.get_track_count():
		var typ := an.track_get_type(ti)
		var path := String(an.track_get_path(ti))
		var low := path.to_lower()
		if "agazine" not in low and "/mag" not in low and not low.ends_with(":magazine"):
			continue
		if typ == Animation.TYPE_VALUE and "visible" in low:
			# 可见性重新打开往往偏晚（坐实才显示）。只作没有位移轨道时的备援，且再提前一点。
			var seen_hide := eject_t < 0.0
			for ki in an.track_get_key_count(ti):
				var kt := an.track_get_key_time(ti, ki)
				var v: Variant = an.track_get_key_value(ti, ki)
				if v is bool and not v and (eject_t < 0.0 or kt + 0.01 >= eject_t):
					seen_hide = true
				if seen_hide and v is bool and v and kt > (eject_t if eject_t >= 0.0 else 0.0) + 0.02:
					var early := maxf((eject_t if eject_t >= 0.0 else 0.0) + 0.06, kt - 0.18)
					if best < 0.0 or early < best:
						best = early
			continue
		if typ != Animation.TYPE_POSITION_3D and typ != Animation.TYPE_VALUE:
			continue
		if an.track_get_key_count(ti) < 3:
			continue
		var p0: Variant = an.track_get_key_value(ti, 0)
		if not (p0 is Vector3):
			continue
		var samples: Array = []
		for ki in range(0, an.track_get_key_count(ti)):
			var pv: Variant = an.track_get_key_value(ti, ki)
			if not (pv is Vector3):
				continue
			var kt2 := an.track_get_key_time(ti, ki)
			if eject_t >= 0.0 and kt2 < eject_t - 0.01:
				continue
			samples.append([kt2, (pv as Vector3).distance_to(p0)])
		if samples.size() < 2:
			continue
		# 抛匣后离卡槽最远的那一帧 = 新手持匣抬起；从此开始显示。
		var peak_t := -1.0
		var peak_d := -1.0
		for s in samples:
			if float(s[1]) > peak_d:
				peak_d = float(s[1])
				peak_t = float(s[0])
		if peak_t < 0.0 or peak_d < 0.02:
			continue
		# 再往前一点：最远点往往已是举起，提前到「开始抬起」——最远点之前距离开始明显增大的时刻。
		var start_t := peak_t
		for i in range(samples.size()):
			if float(samples[i][0]) >= peak_t:
				break
			if float(samples[i][1]) >= 0.02:
				start_t = float(samples[i][0])
				break
		if best < 0.0 or start_t < best:
			best = start_t
	return best


func _scan_mag_throw_time() -> float:
	# 在枪械 reload 动画里找弹匣被甩出的时间：方法轨道，或 Magazine 位姿首次明显下落。
	if gun_ap == null or not gun_ap.has_animation("reload"):
		return -1.0
	var an: Animation = gun_ap.get_animation("reload")
	var best := -1.0
	for ti in an.get_track_count():
		var typ := an.track_get_type(ti)
		if typ == Animation.TYPE_METHOD:
			for ki in an.track_get_key_count(ti):
				var nm := String(an.method_track_get_name(ti, ki)).to_lower()
				if "eject" in nm or "drop" in nm or "mag" in nm or "throw" in nm:
					var t := an.track_get_key_time(ti, ki)
					if best < 0.0 or t < best:
						best = t
			continue
		var path := String(an.track_get_path(ti))
		var low := path.to_lower()
		if "agazine" not in low and "/mag" not in low and not low.ends_with(":magazine"):
			continue
		if typ == Animation.TYPE_VALUE and "visible" in low:
			for ki in an.track_get_key_count(ti):
				var v: Variant = an.track_get_key_value(ti, ki)
				if v is bool and not v:
					var t2 := an.track_get_key_time(ti, ki)
					if best < 0.0 or t2 < best:
						best = t2
			continue
		if typ != Animation.TYPE_POSITION_3D and typ != Animation.TYPE_VALUE:
			continue
		if an.track_get_key_count(ti) < 2:
			continue
		var p0: Variant = an.track_get_key_value(ti, 0)
		if not (p0 is Vector3):
			continue
		var base_p: Vector3 = p0
		for ki in range(1, an.track_get_key_count(ti)):
			var pv: Variant = an.track_get_key_value(ti, ki)
			if not (pv is Vector3):
				continue
			var d: Vector3 = pv - base_p
			# 弹匣被抽出/抛出：离开卡槽超过约 2cm，通常向下或向外
			if d.length() >= 0.02 and (d.y < -0.012 or d.length() >= 0.04):
				var t3 := an.track_get_key_time(ti, ki)
				if best < 0.0 or t3 < best:
					best = t3
				break
	return best


func _start_pump(w: WeaponDef) -> void:
	var an := gun_ap.get_animation("fire")
	if an == null or an.length <= 0.05:
		return
	# 上膛必须在下一发之前完成：时长不超过射击间隔的 92%。
	var interval := 60.0 / maxf(w.rpm, 1.0)
	_pump_dur = minf(an.length, interval * 0.92)
	_pump_t = 0.0
	gun_ap.stop()
	gun_ap.play("fire")
	gun_ap.speed_scale = 0.0
	gun_ap.seek(0.0, true)


func _step_pump(delta: float) -> void:
	if _pump_t < 0.0 or gun_ap == null or not gun_ap.has_animation("fire"):
		return
	var an := gun_ap.get_animation("fire")
	_pump_t += delta
	var u := clampf(_pump_t / maxf(_pump_dur, 0.05), 0.0, 1.0)
	if gun_ap.current_animation != "fire":
		gun_ap.play("fire")
	gun_ap.speed_scale = 0.0
	gun_ap.seek(u * an.length, true)
	if u >= 1.0:
		_pump_t = -1.0


func _pump_bone() -> Dictionary:
	## 泵动前托骨（霰弹 Forearm / Pump）：{sk, i}
	if gun == null:
		return {}
	var key := current
	if _pump_bone_cache.has(key):
		var c: Dictionary = _pump_bone_cache[key]
		if c.is_empty() or is_instance_valid(c.get("sk")):
			return c
	var out := {}
	for n in gun.find_children("*", "Skeleton3D", true, false):
		var sk := n as Skeleton3D
		for nm in ["Forearm", "Pump", "pump", "Forend", "ForeEnd"]:
			var bi := sk.find_bone(nm)
			if bi >= 0:
				out = {"sk": sk, "i": bi}
				break
		if not out.is_empty():
			break
	_pump_bone_cache[key] = out
	return out


func _pump_offset_gun() -> Vector3:
	## 泵动前托相对静止位的位移（枪局部坐标）。非泵动武器 / 无骨骼返回 0。
	var w: WeaponDef = cur_def()
	if w == null or w.fire_mode != "pump" or gun == null:
		return Vector3.ZERO
	var pb := _pump_bone()
	if pb.is_empty():
		return Vector3.ZERO
	var sk: Skeleton3D = pb["sk"]
	var bi: int = pb["i"]
	var to_gun := gun.global_transform.affine_inverse() * sk.global_transform
	var cur := to_gun * sk.get_bone_global_pose(bi).origin
	var rest := to_gun * sk.get_bone_global_rest(bi).origin
	var d := cur - rest
	return d if d.is_finite() else Vector3.ZERO


func _pump_back_u() -> float:
	## fire 动画里泵动前托离静止位最远的归一化时刻（抛壳时刻）。
	if gun_ap == null or not gun_ap.has_animation("fire"):
		return -1.0
	var pb := _pump_bone()
	if pb.is_empty():
		return -1.0
	var an := gun_ap.get_animation("fire")
	var sk: Skeleton3D = pb["sk"]
	var path := String(gun_ap.get_node(gun_ap.root_node).get_path_to(sk)) + ":" + sk.get_bone_name(int(pb["i"]))
	var ti := an.find_track(NodePath(path), Animation.TYPE_POSITION_3D)
	if ti < 0:
		return -1.0
	var p0: Vector3 = an.position_track_interpolate(ti, 0.0)
	var best_t := -1.0
	var best_d := 0.0
	var t := 0.0
	while t <= an.length:
		var d := an.position_track_interpolate(ti, t).distance_to(p0)
		if d > best_d:
			best_d = d
			best_t = t
		t += 1.0 / 60.0
	return best_t / an.length if best_t > 0.0 else -1.0


## 自检（t27u）：泵动状态、前托位移（米，世界尺度）、左手掌心到（随前托移动的）握持点距离。
func debug_pump() -> Dictionary:
	var out := {"active": _pump_t >= 0.0, "u": (_pump_t / _pump_dur) if (_pump_t >= 0.0 and _pump_dur > 0.0) else 0.0, "pump_m": 0.0, "palm_to_pump": 99.0, "back_u": _pump_back_u(), "dur": _pump_dur}
	if gun == null:
		return out
	var sc := gun.global_transform.basis.get_scale().x
	out["pump_m"] = _pump_offset_gun().length() * sc
	var info := _foregrip_info()
	if info.is_empty() or skeleton == null or _arm.is_empty():
		return out
	var want_g: Vector3 = (info["attach"] as Vector3) + _pump_offset_gun()
	var want_w: Vector3 = gun.global_transform * want_g
	var palm_w := _palm_world("L")
	out["palm_to_pump"] = palm_w.distance_to(want_w) - PALM_GAP
	return out


func _palm_world(s: String) -> Vector3:
	var a: Dictionary = _arm.get(s, {})
	if a.is_empty():
		return Vector3.ZERO
	var hi := int(a.get("ha", -1))
	if hi < 0:
		return Vector3.ZERO
	var hx := _skel_xf() * skeleton.get_bone_global_pose(hi)
	var mid := hx.origin
	# 掌心 ≈ 手骨与中指根之间
	var mi := skeleton.find_bone(s + "_Middle_a")
	if mi >= 0:
		mid = (hx.origin + (_skel_xf() * skeleton.get_bone_global_pose(mi)).origin) * 0.5
	return mid


func _sync_gun_reload_anim() -> void:
	# 用手部 clip 的归一化进度驱动枪械 AnimationPlayer，避免两套时钟漂移造成手和枪不同步。
	if gun_ap == null or _clips == null:
		return
	if not gun_ap.has_animation("reload"):
		return
	var an := gun_ap.get_animation("reload")
	if an == null or an.length <= 0.05:
		return
	var clip_len := _clips.length("reload")
	if clip_len <= 0.05:
		return
	var u := clampf(_clip_t / clip_len, 0.0, 1.0)
	if gun_ap.current_animation != "reload":
		gun_ap.play("reload")
	gun_ap.speed_scale = 0.0
	gun_ap.seek(u * an.length, true)


func debug_reload_sync() -> Dictionary:
	var clip_len := _clips.length("reload") if _clips else 0.0
	var gun_t := 0.0
	var gun_len := 0.0
	if gun_ap and gun_ap.has_animation("reload"):
		gun_len = gun_ap.get_animation("reload").length
		if gun_ap.current_animation == "reload" or state == "reloading":
			gun_t = gun_ap.current_animation_position
	var u_clip := _clip_t / clip_len if clip_len > 0.05 else 0.0
	var u_gun := gun_t / gun_len if gun_len > 0.05 else 0.0
	var left_to_mag := 99.0
	if gun and skeleton:
		var mag_n := gun.find_child("Magazine", true, false)
		var li := skeleton.find_bone("L_Hand_a")
		if li < 0:
			li = skeleton.find_bone("L_Hand")
		if mag_n is Node3D and li >= 0 and (mag_n as Node3D).visible:
			var hand := _skel_xf() * skeleton.get_bone_global_pose(li)
			left_to_mag = hand.origin.distance_to((mag_n as Node3D).global_position)
	return {
		"state": state,
		"clip_u": u_clip,
		"gun_u": u_gun,
		"sync_err": absf(u_clip - u_gun),
		"left_to_mag": left_to_mag,
		"state_u": (state_t / state_len) if state_len > 0.05 else 0.0,
		"mag_hidden": _mag_visual_hidden,
	}


func _finish_gun_reload_anim() -> void:
	# 换弹结束必须关闩。AnimationPlayer.stop() 默认回到第 0 帧，
	# 而手枪 reload 的第 0 帧正是空仓挂机（滑套后坐），会把刚上好的弹又锁在后面。
	if gun_ap:
		if gun_ap.is_playing() or gun_ap.current_animation != "":
			var an := gun_ap.get_animation(gun_ap.current_animation) if gun_ap.current_animation != "" else null
			if an:
				gun_ap.seek(an.length, true)
		gun_ap.pause()
		gun_ap.speed_scale = 1.0
	_slide_locked = false
	_set_pistol_slide_open(false)


func _pistol_skel() -> Skeleton3D:
	return gun.find_child("Skeleton3D", true, false) if gun else null


func _set_pistol_slide_open(open: bool) -> void:
	if current != "pistol" and (cur_def() == null or str(cur_def().category) != "pistol"):
		return
	var sk := _pistol_skel()
	if sk == null:
		return
	var i := sk.find_bone("Slide")
	if i < 0:
		return
	sk.set_bone_pose_position(i, PISTOL_SLIDE_OPEN if open else PISTOL_SLIDE_CLOSED)


func debug_slide_open() -> bool:
	var sk := _pistol_skel()
	if sk == null:
		return false
	var i := sk.find_bone("Slide")
	if i < 0:
		return false
	return sk.get_bone_pose_position(i).x < (PISTOL_SLIDE_CLOSED.x - 0.015)


func _bone_in_gun(sk: Skeleton3D, bone: String) -> Vector3:
	var i := sk.find_bone(bone)
	if i < 0:
		return Vector3.INF
	return gun.global_transform.affine_inverse() * (sk.global_transform * sk.get_bone_global_pose(i).origin)


func _mesh_verts_in_gun(mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() < 1:
		return out
	var arr := mi.mesh.surface_get_arrays(0)
	if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
		return out
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	# 用节点变换（含 Armature 的 -90°X）。瞄具网格不随骨骼摆动。
	for v in vs:
		out.append(gun.to_local(mi.to_global(v)) if mi.is_inside_tree() and gun.is_inside_tree() else mi.transform * v)
	return out


func _rear_aperture_from_verts(verts: PackedVector3Array, bone: Vector3) -> Vector3:
	# 提把顶部横梁上的照门孔（约低于顶面 7mm）。不用大方窗中心，也不用稀疏顶点灌水。
	if verts.is_empty():
		return Vector3.INF
	var x0 := bone.x
	var ymax := -1e9
	for p in verts:
		if absf(p.x - x0) <= 0.03 and absf(p.z) <= 0.016:
			ymax = maxf(ymax, p.y)
	if ymax < -1e8:
		return Vector3.INF
	return Vector3(x0, ymax - 0.007, 0.0)


func _front_post_from_verts(verts: PackedVector3Array, bone: Vector3) -> Vector3:
	# 准星尖：只用最高一簇顶点，避免把塔座侧面平均进来压低准星。
	var ymax := -1e9
	for p in verts:
		if absf(p.x - bone.x) <= 0.035 and absf(p.z) <= 0.008:
			ymax = maxf(ymax, p.y)
	if ymax < -1e8:
		return Vector3.INF
	var s := Vector3.ZERO
	var n := 0
	for p in verts:
		if absf(p.x - bone.x) <= 0.035 and absf(p.z) <= 0.008 and p.y >= ymax - 0.0015:
			s += p
			n += 1
	if n <= 0:
		return Vector3.INF
	var tip: Vector3 = s / float(n)
	tip.z = 0.0
	return tip


func _sight_locals(w: WeaponDef) -> PackedVector3Array:
	# 光学轴线 = 机瞄孔/缺口中心 → 准星尖。必须是真实瞄具点，不能用枪口或随便一个网格点，
	# 否则把 have 转到相机 -Z 会把整枪拧斜。
	var rear := Vector3.ZERO
	var front := Vector3.RIGHT
	var wid := str(w.id) if w else ""
	if w and SIGHT_AXIS.has(wid):
		var pair: Array = SIGHT_AXIS[wid]
		rear = pair[0]
		front = pair[1]
	elif w:
		rear = Vector3(w.muzzle.x * 0.15, w.muzzle.y, 0.0)
		front = w.muzzle
	if gun == null:
		return PackedVector3Array([rear, front])
	var gid := gun.get_instance_id()
	if gid == _sight_cache_id and _sight_cache_wid == wid and _sight_cache.size() == 2:
		return _sight_cache
	# 步枪仍可用提把网格精确到孔心（与表中数值一致，作校验/微调）
	if wid == "rifle":
		var sights: MeshInstance3D = gun.find_child("Sights_Mesh", true, false)
		var verts := _mesh_verts_in_gun(sights) if sights else PackedVector3Array()
		if verts.size() > 0:
			var hole := _rear_aperture_from_verts(verts, rear)
			var post := _front_post_from_verts(verts, front)
			if hole != Vector3.INF:
				rear = hole
			if post != Vector3.INF:
				front = post
	_sight_cache_id = gid
	_sight_cache_wid = wid
	_sight_cache = PackedVector3Array([rear, front])
	return _sight_cache


func _quat_map_dir_no_roll(from_dir: Vector3, to_dir: Vector3, up: Vector3) -> Quaternion:
	# 把 from 转到 to，只用偏航+俯仰（共同 up 参考），不引入横滚。
	var f := from_dir.normalized()
	var t := to_dir.normalized()
	var r1 := up.cross(f)
	if r1.length_squared() < 1e-10:
		r1 = Vector3.RIGHT.cross(f)
		if r1.length_squared() < 1e-10:
			r1 = Vector3.FORWARD.cross(f)
	r1 = r1.normalized()
	var u1 := f.cross(r1).normalized()
	var r2 := up.cross(t)
	if r2.length_squared() < 1e-10:
		r2 = Vector3.RIGHT.cross(t)
		if r2.length_squared() < 1e-10:
			r2 = Vector3.FORWARD.cross(t)
	r2 = r2.normalized()
	var u2 := t.cross(r2).normalized()
	var B1 := Basis(r1, u1, f)
	var B2 := Basis(r2, u2, t)
	return (B2 * B1.transposed()).get_rotation_quaternion()


func _align_iron_sights(w: WeaponDef) -> void:
	# 开镜：瞄准轴线与相机中心射线重合（三点一线），枪身摆正不横滚、不低头看枪顶。
	# 必须在写入 gun.transform 之后调用。旋转绕照门孔，只做偏航+俯仰，再绕瞄准轴去滚转。
	if w == null or gun == null or camera == null or _ads_k < 0.05:
		return
	if view.get_parent() != camera:
		return
	var pts := _sight_locals(w)
	var k := _ads_k
	var cam_inv := camera.global_transform.affine_inverse()
	var rear_c: Vector3 = cam_inv * gun.to_global(pts[0])
	var front_c: Vector3 = cam_inv * gun.to_global(pts[1])
	var have: Vector3 = front_c - rear_c
	if have.length_squared() < 1e-10:
		return
	var want := Vector3(0.0, 0.0, -1.0)
	var q_axis := _quat_map_dir_no_roll(have, want, Vector3.UP)
	var up_c: Vector3 = cam_inv.basis * gun.global_transform.basis.y
	var up2: Vector3 = Basis(q_axis) * up_c
	var q_roll := Quaternion.IDENTITY
	var xy := Vector2(up2.x, up2.y)
	if xy.length_squared() > 1e-10:
		q_roll = Quaternion(want, -atan2(xy.x, xy.y))
	var q: Quaternion = q_roll * q_axis
	if k < 0.999:
		q = Quaternion.IDENTITY.slerp(q, k)
	var R := Basis(q)
	var xf := view.transform
	view.transform = Transform3D(R * xf.basis, R * (xf.origin - rear_c) + rear_c)
	# 把孔放到相机中心射线上，并保持合理眼距（不要把机匣贴到镜头上）
	var r: Vector3 = camera.global_transform.affine_inverse() * gun.to_global(pts[0])
	view.position.x -= r.x * k
	view.position.y -= r.y * k
	# 长枪眼距收紧：原先可把机瞄推到 0.45m 外，枪托离开肩膀、手臂被拉直。手枪保持原眼距。
	var z_goal := r.z
	var z_near := -0.16 if _is_long_gun(w) else -0.18
	var z_far := -0.24 if _is_long_gun(w) else -0.45
	var z_def := -0.20 if _is_long_gun(w) else -0.26
	if r.z > z_near:
		z_goal = z_def
	elif r.z < z_far:
		z_goal = z_far
	view.position.z -= (r.z - z_goal) * k
	if _is_long_gun(w):
		_seat_stock_on_shoulder(w)


func _seat_stock_on_shoulder(w: WeaponDef) -> void:
	# 开镜后只沿相机前后轴把枪托拉回肩窝，不破坏已对准的瞄准轴和屏幕中心。
	if not _is_long_gun(w) or gun == null or camera == null or view == null:
		return
	if view.get_parent() != camera or _ads_k < 0.05:
		return
	var stock_c: Vector3 = camera.global_transform.affine_inverse() * gun.to_global(_stock_local(w))
	# 肩窝大约在镜头稍后、略低：相机空间 Z≈0（镜头平面附近）
	var want_z := 0.02
	var shift := want_z - stock_c.z
	var pts := _sight_locals(w)
	var rear_c: Vector3 = camera.global_transform.affine_inverse() * gun.to_global(pts[0])
	# 照门至少留 14cm 眼距，避免机匣贴到镜头上
	if rear_c.z + shift > -0.14:
		shift = -0.14 - rear_c.z
	# 只拉回，不要再往前推
	if shift > 0.0:
		view.position.z += shift * _ads_k


func _kick_xf(w: WeaponDef) -> Transform3D:
	if w == null:
		return Transform3D()
	return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(w.kick_rot) * _kick) * Basis(Vector3.UP, _sway.x) * Basis(Vector3.RIGHT, _sway.y), Vector3(0.0, 0.0, w.kick_back * _kick))


func _apply_ads_kick(w: WeaponDef, kick_t: Transform3D) -> void:
	# 开镜对准之后再施加视模型后坐：绕枪托（长枪）或握把（手枪）抬起，准星会短暂离开准心，枪托不离开肩窝。
	if w == null or view == null or camera == null or gun == null:
		return
	if view.get_parent() != camera:
		return
	if _kick < 0.02 and kick_t.origin.length_squared() < 1e-8 and kick_t.basis.is_equal_approx(Basis()):
		return
	var pivot := Vector3.ZERO
	if _is_long_gun(w):
		pivot = camera.global_transform.affine_inverse() * gun.to_global(_stock_local(w))
	else:
		pivot = camera.global_transform.affine_inverse() * gun.to_global(Vector3(0.0, 0.02, 0.0))
	var xf := view.transform
	view.transform = Transform3D(kick_t.basis * xf.basis, kick_t.basis * (xf.origin - pivot) + pivot + kick_t.origin)


func debug_mag_ejected() -> bool:
	return _mag_ejected


func debug_mag_eject_at() -> float:
	return _mag_eject_at


func debug_mag_insert_at() -> float:
	return _mag_insert_at


func debug_mag_visible() -> bool:
	if gun == null:
		return false
	var mag_n := gun.find_child("Magazine", true, false)
	return mag_n is Node3D and (mag_n as Node3D).visible


func debug_muzzle_ahead() -> float:
	## 枪口在相机前方的距离（米）。相机看向 -Z。
	if gun == null or camera == null:
		return 0.0
	var w: WeaponDef = cur_def()
	if w == null:
		return 0.0
	var world: Vector3 = gun.global_transform * w.muzzle
	var local: Vector3 = camera.global_transform.affine_inverse() * world
	return -local.z - camera.near


func debug_center_hits_viewmodel() -> bool:
	## 髋射时屏幕中心射线是否打到视模型（不应挡住准星）。
	if gun == null or camera == null:
		return false
	var from := camera.global_position
	var to := from + (-camera.global_transform.basis.z) * 1.2
	var space := camera.get_world_3d().direct_space_state
	# 视模型通常没有碰撞体：用网格 AABB 与中心射线做近似检测。
	var meshes := gun.find_children("*", "MeshInstance3D", true, false)
	if gun is MeshInstance3D:
		meshes.append(gun)
	var n := 12
	for i in n:
		var t := 0.04 + 0.7 * float(i) / float(n)
		var p := from.lerp(to, t)
		for mi in meshes:
			var m := mi as MeshInstance3D
			if m.mesh == null or not m.visible:
				continue
			var aabb := m.mesh.get_aabb()
			var lp := m.global_transform.affine_inverse() * p
			if aabb.grow(0.005).has_point(lp):
				return true
	return false


func debug_hand_to_gun() -> Dictionary:
	## 手腕到枪网格 AABB 的距离（在枪上则为 0）。用于判断走跑时手是否离枪。
	var out := {"R": 99.0, "L": 99.0}
	if gun == null or skeleton == null or _arm.is_empty():
		return out
	var meshes: Array = gun.find_children("*", "MeshInstance3D", true, false)
	if gun is MeshInstance3D:
		meshes.append(gun)
	for s in ["R", "L"]:
		if not _arm.has(s):
			continue
		var hand: Vector3 = _skel_xf() * skeleton.get_bone_global_pose(int(_arm[s]["ha"])).origin
		var best := 99.0
		for mi in meshes:
			var m := mi as MeshInstance3D
			if m.mesh == null:
				continue
			var xf := m.global_transform
			var aabb := m.mesh.get_aabb().grow(0.03)
			var lp := xf.affine_inverse() * hand
			if aabb.has_point(lp):
				best = 0.0
				break
			# 到扩大盒的距离（局部轴对齐）
			var c := aabb.get_center()
			var h := aabb.size * 0.5
			var d := (lp - c).abs() - h
			var outside := Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0))
			best = minf(best, (xf.basis * outside).length())
		out[s] = best
	return out


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
	if state == "reloading":
		_pump_t = -1.0
		_sync_gun_reload_anim()
	else:
		_step_pump(delta)
	var pose := _clips.sample(_clip, _clip_t, _clip_loop)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / BLEND_T)
		pose = ArmClips.blend(_prev_pose, pose, smoothstep(0.0, 1.0, _blend))
	_last_pose = pose
	return pose


func _process(delta: float) -> void:
	if player == null or view == null:
		return
	if player.has_method("is_dead") and bool(player.call("is_dead")):
		trigger = false
		_ik_w = 0.0
		if is_armed() and has_method("holster"):
			holster()
		return
	# 射击 / 开镜 / 后坐只在第一人称。持枪切到观察模式时仍保持持枪姿势（不自动收枪）。
	# 观察模式：点角色身体仍走互动工具；开火键隐藏，扳机在此模式无效。
	var fp := bool(player.get("first_person")) and not bool(player.get("input_locked"))
	var show := is_armed()
	hidden_by_mode = not show
	# ---- 状态机（观察模式也走完换弹 / 拔枪，这样切回去姿势连续）
	state_t += delta
	match state:
		"drawing":
			if state_t >= state_len:
				state = "ready"
		"holstering":
			if state_t >= state_len:
				_finish_holster()
		"reloading":
			_step_reload_eject()
			_step_reload()
	if fp:
		_try_fire(delta)
	else:
		# 观察模式不开火，但保持开镜/瞄准姿势（不要一切视角就收回腰射）。
		trigger = false
	_fire_t += delta
	var w: WeaponDef = cur_def()
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
	if not show:
		if view.visible:
			view.visible = false
		_ik_w = maxf(0.0, _ik_w - delta * IK_FADE)
		if fp and camera:
			camera.rotation = Vector3(recoil.x, recoil.y, 0.0)
		elif camera and camera.rotation != Vector3.ZERO:
			camera.rotation = Vector3.ZERO
		_restore_fov()
		if _ik_w > 0.0 and not _last_pose.is_empty():
			_apply_ik(_last_pose, _ik_w)
		elif _ik_dirty:
			_restore_loco()
		return
	view.visible = true
	_ik_w = minf(1.0, _ik_w + delta * IK_FADE)
	if fp and camera:
		camera.rotation = Vector3(recoil.x, recoil.y, 0.0)
		if _fov_base < 0.0:
			_fov_base = camera.fov
		if w:
			camera.fov = lerpf(float(player.get("fp_fov")), w.ads_fov, _ads_k)
	else:
		if camera and camera.rotation != Vector3.ZERO:
			camera.rotation = Vector3.ZERO
		_restore_fov()
	# ---- 视模型：髋射下移推远 + 后坐 + 转视晃动 + 走跑摆动（同一变换驱动枪和 IK 手，避免不同步）
	if fp and camera:
		var cb := camera.global_transform.basis
		if _prev_cam_basis != Basis():
			var dq := (_prev_cam_basis.inverse() * cb).get_euler()
			_sway = _sway.lerp(Vector2(clampf(dq.y, -0.08, 0.08), clampf(dq.x, -0.08, 0.08)) * 0.8, 1.0 - exp(-10.0 * delta))
		_prev_cam_basis = cb
	_sway = _sway * exp(-6.0 * delta)
	var kick_t := _kick_xf(w)
	# 开镜对准会每帧把瞄准轴锁回准星，若把后坐写进基准姿势会被对消。髋射仍把后坐叠在视模型上。
	var pose := _update_clip(delta)
	if pose.is_empty():
		return
	_step_left_grip_weight(delta)
	var local_xf := Transform3D(Basis(), _body_follow_offset(delta)) * _view_local(w, pose) * (kick_t if _ads_k < 0.05 else Transform3D()) * _loco_bob_xf(delta)
	if gun:
		gun.transform = pose["gun"]
	_apply_view_xf(local_xf, pose)
	if fp:
		_align_iron_sights(w)
	# 空仓挂机：每帧写回滑套，避免射击动画结束把滑套带回关闭位
	if _slide_locked and state == "ready":
		_set_pistol_slide_open(true)
	_sync_skel_interp()
	_pull_gun_into_reach(pose)
	if fp and _ads_k >= 0.05:
		_apply_ads_kick(w, kick_t)
	_apply_ik(pose, _ik_w)


func _step_reload_eject() -> void:
	var w: WeaponDef = cur_def()
	if w == null or w.shell_reload:
		return
	if not _mag_ejected and state_t >= _mag_eject_at:
		_try_eject_mag(w)
	# 新弹匣开始插入时就显示模型（并每帧压过动画可见性轨道）。
	var insert_at := _mag_insert_at if _mag_insert_at > 0.0 else maxf(_mag_eject_at + 0.10, state_len * 0.32)
	if _mag_visual_hidden and state_t >= insert_at:
		_restore_mag_visual()
	elif (not _mag_visual_hidden) and _mag_ejected and state_t >= insert_at:
		_restore_mag_visual()


func _step_reload() -> void:
	var w: WeaponDef = cur_def()
	if w == null:
		state = "ready"
		return
	if not w.shell_reload:
		if state_t >= state_len:
			var a := ammo_of(current)
			var cap := _capacity(w, a.x)
			if infinite_reserve():
				a.x = cap
			else:
				var take := mini(cap - a.x, a.y)
				a.x += take
				a.y -= take
			ammo[current] = a
			state = "ready"
			_clip_speed = 1.0
			ammo_changed.emit(current, a.x, a.y)
			reloaded.emit(current)
			_restore_mag_visual()
			_finish_gun_reload_anim()
		return
	# 霰弹：开始 → 逐发 → 结束
	if state_t < state_len:
		return
	var a2 := ammo_of(current)
	match _shell_phase:
		"start", "step", "end_req":
			if _shell_phase == "step":
				a2.x += 1
				if not infinite_reserve():
					a2.y -= 1
				ammo[current] = a2
				ammo_changed.emit(current, a2.x, a2.y)
			if _shell_phase != "end_req" and a2.x < w.mag_size and has_reserve(current):
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


func left_arm_reach() -> float:
	# 上臂 + 前臂 + 手掌，约等于肩到指尖的手臂长。
	if _arm.has("L"):
		var a: Dictionary = _arm["L"]
		var reach := float(a.get("l1", 0.28)) + float(a.get("l2", 0.26))
		if skeleton:
			var ha := skeleton.find_bone("L_Hand_a")
			var mid := skeleton.find_bone("L_Middle_a")
			if ha >= 0 and mid >= 0:
				var ho := skeleton.get_bone_global_rest(ha).origin
				var mo := skeleton.get_bone_global_rest(mid).origin
				reach += ho.distance_to(mo)
			else:
				reach += 0.09
		else:
			reach += 0.09
		return reach
	return 0.70


func left_hand_world() -> Vector3:
	if skeleton == null:
		return Vector3.ZERO
	var i := skeleton.find_bone("L_Hand_a")
	if i < 0:
		return Vector3.ZERO
	return (_skel_xf() * skeleton.get_bone_global_pose(i)).origin


func grab_palm_sem(world_target: Vector3, shoulder_world: Vector3) -> Basis:
	## 左手抓取的 SEM 约定：X=指向，Z=掌心法线（指向抓取点），与持枪 sem 一致。
	## 不用 looking_at（它把 -Z 对准目标，手掌会翻/拧）。
	var palm := world_target - shoulder_world
	if palm.length_squared() < 1e-8:
		palm = Vector3.FORWARD
	palm = palm.normalized()
	var fingers := Vector3.UP
	if absf(fingers.dot(palm)) > 0.82:
		fingers = Vector3.RIGHT
	fingers = (fingers - palm * fingers.dot(palm)).normalized()
	if fingers.length_squared() < 1e-8:
		fingers = Vector3.RIGHT
		fingers = (fingers - palm * fingers.dot(palm)).normalized()
	# 稍微让指尖向内勾，掌心正对抓点。
	return Basis(fingers, palm.cross(fingers), palm).orthonormalized()


func apply_left_hand_grab(world_target: Vector3) -> void:
	## 左手伸向拖拽点。不转锁骨，只解上臂/前臂/手，与持枪 IK 同一套求解器。
	if skeleton == null or not _arm.has("L"):
		return
	if not world_target.is_finite():
		return
	var a: Dictionary = _arm["L"]
	for k in ["sh", "ua", "fa", "ha"]:
		var bi := int(a[k])
		if bi >= 0 and not _loco_cache.has(bi):
			_loco_cache[bi] = skeleton.get_bone_pose_rotation(bi)
	var sk_xf := _skel_xf()
	var to_sk := sk_xf.affine_inverse()
	var P: Vector3 = to_sk * world_target
	# 肘向外（角色左侧）并略向下，避免前臂翻拧。
	var pole := (to_sk.basis * Vector3(-0.75, -0.55, 0.15)).normalized()
	var ua_i := int(a["ua"])
	var sh_w: Vector3 = sk_xf * skeleton.get_bone_global_pose(ua_i).origin
	var sem_world := grab_palm_sem(world_target, sh_w)
	var hand_sk := (to_sk.basis * sem_world).orthonormalized()
	_grab_solving = true
	_solve_arm(a, P, pole, hand_sk, Vector3.ZERO, 1.0)
	_grab_solving = false


## 由 player_controller 在 SoftLoco.apply_pose 之后于同一物理帧调用。
## 先把当前（走跑/休息）肩臂旋转记进 _loco_cache，再解 IK；肩骨始终以这次缓存为底，不会累积。
func apply_ik_after_loco() -> void:
	if player and player.has_method("is_dead") and bool(player.call("is_dead")):
		_ik_w = 0.0
		return
	if skeleton == null:
		return
	if _ik_w <= 0.0 and not is_armed() and not _ik_dirty:
		_loco_cache.clear()
		return
	for bi in _ik_bones:
		_loco_cache[bi] = skeleton.get_bone_pose_rotation(bi)
	if _ik_w > 0.0 and not _last_pose.is_empty():
		_pull_gun_into_reach(_last_pose)
		# _pull_gun_into_reach 会再次对准准星，必须把开镜后坐补回去。
		if player and bool(player.get("first_person")) and _ads_k >= 0.05:
			_apply_ads_kick(cur_def(), _kick_xf(cur_def()))
		_apply_ik(_last_pose, _ik_w)


## 不再在此处解 IK：节点顺序可能早于或晚于 apply_pose，会把上一帧 IK 当底姿势把肩拧坏。
func _physics_process(_dt: float) -> void:
	return


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


## 渲染时骨架所在的世界变换（物理插值后的）。t27u：以前第一人称持枪时把骨架插值关掉，
## 结果身体按物理帧跳动、镜头和枪按插值平滑移动——走路/跳跃时两者每帧错开最多一个物理步，
## 手臂在「跳动的身体」和「平滑的枪」之间来回拉，看起来手晃、穿模、有虚影。
## 现在骨架保持插值，IK 目标换算也用同一个插值变换，手、身体、枪在同一帧同一变换下绘制。
func _skel_xf() -> Transform3D:
	if skeleton == null:
		return Transform3D()
	var live := skeleton.global_transform
	if Engine.is_in_physics_frame() or not skeleton.is_physics_interpolated_and_enabled():
		return live
	var itp := skeleton.get_global_transform_interpolated()
	# 真机偶发返回旧值/单位矩阵：离即时变换过远时退回即时变换（同 organ_rig._skel_world_xf）。
	if not itp.origin.is_finite() or itp.origin.distance_squared_to(live.origin) > 0.25:
		return live
	return itp


func _sync_skel_interp() -> void:
	# t27u：骨架始终继承物理插值（与镜头使用同一插值公式），不再在持枪第一人称时关闭。
	if skeleton == null:
		return
	var mode := Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	if skeleton.physics_interpolation_mode != mode:
		skeleton.physics_interpolation_mode = mode


func debug_spine_bow() -> Dictionary:
	## 腰/胸相对直立的前倾/后仰角（弧度）。俯仰镜头时应该接近 0，不能弓腰。
	var out := {"lean": 0.0, "spine_a": 0.0, "spine_b": 0.0, "spine_c": 0.0, "ok": false}
	if skeleton == null:
		return out
	var skx := _skel_xf()
	var ia := skeleton.find_bone("C_Spine_a")
	var ic := skeleton.find_bone("C_Spine_c")
	var ih := skeleton.find_bone("C_Hip_a")
	if ia < 0 or ic < 0:
		return out
	var pa: Vector3 = skx * skeleton.get_bone_global_pose(ia).origin
	var pc: Vector3 = skx * skeleton.get_bone_global_pose(ic).origin
	var hip: Vector3 = skx * skeleton.get_bone_global_pose(ih).origin if ih >= 0 else pa
	var up := (pc - hip)
	if up.length_squared() < 1e-8:
		return out
	up = up.normalized()
	# 相对世界竖直的前/后倾：0 = 直立。只看水平分量，忽略左右歪。
	var lean := atan2(Vector3(up.x, 0.0, up.z).length(), up.y)
	out["lean"] = lean
	for pair in [["spine_a", "C_Spine_a"], ["spine_b", "C_Spine_b"], ["spine_c", "C_Spine_c"]]:
		var bi := skeleton.find_bone(str(pair[1]))
		if bi < 0:
			continue
		var now: Quaternion = skeleton.get_bone_pose_rotation(bi)
		var rest: Quaternion = skeleton.get_bone_rest(bi).basis.get_rotation_quaternion()
		out[str(pair[0])] = now.angle_to(rest)
	# 站立时脊柱本身有一点生理弯曲；超过约 12° 视为明显弓腰
	out["ok"] = absf(lean) < deg_to_rad(14.0)
	return out


func _pull_gun_into_reach(pose: Dictionary) -> void:
	# 若护木/握把超出手臂长度，把视模型往肩方向拉回，避免俯仰时手离开枪。
	if not (player and bool(player.get("first_person"))) or skeleton == null or view == null or pose.is_empty() or _arm.is_empty():
		return
	if view.get_parent() != camera:
		return
	var skx := _skel_xf()
	var pulled := false
	debug_last_pull = 0.0
	for _pass in 2:
		var shift := Vector3.ZERO
		var worst := 0.0
		for s in ["R", "L"]:
			if not _arm.has(s) or not pose.has(s):
				continue
			var a: Dictionary = _arm[s]
			var h: Dictionary = pose[s]
			var wrist_cam: Vector3 = _wrist_cam(s, h, a)
			var want: Vector3 = view.global_transform * wrist_cam
			var sh: Vector3 = skx * skeleton.get_bone_global_pose(int(a["sh"])).origin
			var reach: float = (float(a["l1"]) + float(a["l2"])) * 0.96
			if s == "L" and _lgrip_w > 0.0 and _is_long_gun(cur_def()):
				# 左手允许略伸长（ARM_STRETCH_MAX）再拉枪，避免开镜时把枪往脸上拽。
				reach *= _stretch_max_for(true) * 0.98 / 0.96
			elif s == "R":
				reach *= _stretch_max_for(false) * 0.98 / 0.96
			var d := want.distance_to(sh)
			var extra := d - reach
			if extra > worst:
				worst = extra
				shift = (want - sh).normalized() * extra
		if worst <= 0.001:
			break
		if _ads_k > 0.5 and camera != null:
			# 开镜只沿相机前后轴拉近，避免把已对准的瞄准轴拉开。
			var cz := camera.global_transform.basis.z
			shift = cz * shift.dot(cz)
		view.global_position -= shift
		debug_last_pull += shift.length()
		pulled = true
	if pulled and _ads_k < 0.95 and camera and gun:
		# 拉近后枪口会偏离汇聚点：绕枪托再对一次（腰射权重）。
		var wd: WeaponDef = cur_def()
		if wd:
			var vt := view.transform
			var tgt: Vector3 = camera.global_transform.affine_inverse() * _center_aim_point()
			var piv: Vector3 = vt * (gun.transform * _stock_local(wd))
			view.transform = _converge_about(vt, gun.transform, wd, tgt, piv, 1.0 - _ads_k)
	if _ads_k > 0.05:
		_align_iron_sights(cur_def())
		_seat_stock_on_shoulder(cur_def())


func _left_hand_adjust() -> Vector3:
	var w: WeaponDef = cur_def()
	var base := LEFT_HAND_ADJUST
	if w and w.left_hand_adjust != Vector3.ZERO:
		base = w.left_hand_adjust
	# 开镜时动画手腕已经更贴护木，常数下调，避免走动时左手穿进机匣。
	var k := 1.0 - 0.45 * clampf(_ads_k, 0.0, 1.0)
	return base * k


var _gun_ext_cache: Dictionary = {}


func _gun_x_extent() -> Vector2:
	## 枪局部 X（+X 朝枪口）的最小 / 最大值，按武器缓存。忽略闪光/阴影。
	var id := current
	if _gun_ext_cache.has(id):
		return _gun_ext_cache[id]
	var lo := 1e9
	var hi := -1e9
	if gun:
		for mi in gun.find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).mesh == null:
				continue
			var n := String(mi.name).to_lower()
			if "shadow" in n or "flash" in n or "muzzle" in n:
				continue
			var a: AABB = (mi as MeshInstance3D).mesh.get_aabb()
			var xf: Transform3D = gun.global_transform.affine_inverse() * (mi as MeshInstance3D).global_transform
			for k in 8:
				var q: Vector3 = xf * a.get_endpoint(k)
				lo = minf(lo, q.x)
				hi = maxf(hi, q.x)
	var out := Vector2(lo, hi) if hi > lo else Vector2(-0.2, 0.6)
	if gun:
		_gun_ext_cache[id] = out
	return out


func _grip_target_x(s: String) -> float:
	## 手腕（手骨原点）沿枪身应在的位置：右手握把、左手护木/泵动前托。按枪长比例，适配不同模型。
	var w: WeaponDef = cur_def()
	var ext := _gun_x_extent()
	var L := ext.y - ext.x
	if w == null or not _is_long_gun(w):
		# 手枪：右手握把；左手包在右手前侧，不伸到套筒前面。
		return ext.x + L * (0.02 if s == "R" else 0.10)
	if str(w.category) == "shotgun":
		# 左手更靠前，落在泵动护木上，避开机匣/弹仓穿模。
		return ext.x + L * (0.20 if s == "R" else 0.58)
	# 步枪左手略前移到护木，不要停在弹匣井里。
	return ext.x + L * (0.17 if s == "R" else 0.52)


func _grip_anchor_gun(s: String) -> Vector3:
	# 兼容：返回枪局部的握持参考点（x 为握持位置，y/z 为枪轴附近）。
	return Vector3(_grip_target_x(s), 0.0, 0.0)


func _foregrip_gun() -> Vector3:
	# 左手应落在护木 / 泵动前托：沿枪 X 取该处网格包围盒，掌心托在管身下缘，不要穿进机匣中线。
	var x := _grip_target_x("L")
	var y_lo := 1e9
	var y_hi := -1e9
	var z_lo := 1e9
	var z_hi := -1e9
	var found := false
	if gun:
		for mi in gun.find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).mesh == null:
				continue
			var n := String(mi.name).to_lower()
			if "shadow" in n or "flash" in n or "muzzle" in n or "magazine" in n or n.ends_with("mag"):
				continue
			var a: AABB = (mi as MeshInstance3D).mesh.get_aabb()
			var xf: Transform3D = gun.global_transform.affine_inverse() * (mi as MeshInstance3D).global_transform
			for k in 8:
				var q: Vector3 = xf * a.get_endpoint(k)
				if q.x > x - 0.07 and q.x < x + 0.07:
					found = true
					y_lo = minf(y_lo, q.y)
					y_hi = maxf(y_hi, q.y)
					z_lo = minf(z_lo, q.z)
					z_hi = maxf(z_hi, q.z)
	if not found:
		return Vector3(x, 0.0, 0.0)
	# 托在护木下缘稍上方，Z 取截面中心。
	var y := lerpf(y_lo, y_hi, 0.28)
	var z := (z_lo + z_hi) * 0.5
	return Vector3(x, y, z)


# ---- 左手握护木（0.2.12 t25u）：按枪模型顶点截面求护木/泵动前托下缘，掌心包在下方 ----
## 掌心骨线到护木表面的距离（米，世界尺度）：手掌软组织厚度。
const PALM_GAP := 0.014
## 掌心法线在枪截面里的角度：0 = 正上方托住；正值偏向射手右侧（左手从左下方包住）。
const PALM_TILT_DEG := 38.0
var _sect_cache: Dictionary = {}
var _lgrip_w := 0.0


func _gun_sections() -> Dictionary:
	## 按 1cm X 分箱的顶点截面：每箱 [y_lo, y_hi, z_lo_low, z_hi_low]（low = 靠底部 3cm 内的顶点）。忽略弹匣/闪光。
	var id := current
	if _sect_cache.has(id):
		return _sect_cache[id]
	var out := {"x0": 0.0, "dx": 0.01, "bins": {}}
	if gun == null:
		return out
	var pts: Array[Vector3] = []
	var inv := gun.global_transform.affine_inverse()
	for mi in gun.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var n := String(m.name).to_lower()
		var pn := String(m.get_parent().name).to_lower() if m.get_parent() else ""
		if "shadow" in n or "flash" in n or "muzzle" in n or "magazine" in n or "magazine" in pn or n.ends_with("mag"):
			continue
		var xf: Transform3D = inv * m.global_transform
		for si in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(si)
			if arr.is_empty():
				continue
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for v in vs:
				pts.append(xf * v)
	var bins: Dictionary = {}
	for q in pts:
		var k := int(floor(q.x / 0.01))
		if not bins.has(k):
			bins[k] = [q.y, q.y, 1e9, -1e9]
		var b: Array = bins[k]
		b[0] = minf(b[0], q.y)
		b[1] = maxf(b[1], q.y)
	for q in pts:
		var k := int(floor(q.x / 0.01))
		var b: Array = bins[k]
		if q.y < float(b[0]) + 0.03:
			b[2] = minf(b[2], q.z)
			b[3] = maxf(b[3], q.z)
	out["bins"] = bins
	_sect_cache[id] = out
	return out


func _section_at(x: float) -> Array:
	## 返回 x 处 ±1cm 合并截面 [y_lo, y_hi, z_lo, z_hi]，无顶点返回空。
	var bins: Dictionary = _gun_sections()["bins"]
	var k0 := int(floor(x / 0.01))
	var r: Array = []
	for k in [k0 - 1, k0, k0 + 1]:
		if not bins.has(k):
			continue
		var b: Array = bins[k]
		if r.is_empty():
			r = b.duplicate()
		else:
			r[0] = minf(r[0], b[0])
			r[1] = maxf(r[1], b[1])
			r[2] = minf(r[2], b[2])
			r[3] = maxf(r[3], b[3])
	return r


func _foregrip_attach_x(w: WeaponDef) -> float:
	# 护木/泵动前托中段（从枪口往回量，和模型长度无关）：步枪 ≈ 护木中段，冲锋枪 ≈ 弹匣前方护木，霰弹 ≈ 泵动护木中心。
	var mz: float = w.muzzle.x if w else 0.6
	match str(w.category) if w else "":
		"shotgun":
			return mz - 0.39
		"smg":
			return mz - 0.245
	return mz - 0.27


func _foregrip_info() -> Dictionary:
	## 护木握持信息（枪局部）：attach = 掌心接触点，palm = 掌心骨线中心，n = 掌心法线，f = 手指方向，rear_x = 护木后端。
	var w: WeaponDef = cur_def()
	if w == null or not _is_long_gun(w) or gun == null:
		return {}
	var key := "fg_" + current
	if _sect_cache.has(key):
		return _sect_cache[key]
	var x := _foregrip_attach_x(w)
	var sec := _section_at(x)
	if sec.is_empty() or float(sec[2]) > float(sec[3]):
		return {}
	var y_lo: float = sec[0]
	var zl: float = sec[2]
	var zh: float = sec[3]
	var rz := maxf(0.008, (zh - zl) * 0.5)
	var c := Vector3(x, y_lo + rz, (zl + zh) * 0.5)
	var a := deg_to_rad(PALM_TILT_DEG)
	var n := Vector3(0.0, cos(a), sin(a))
	var attach := c - n * rz
	# 护木后端：往回扫，截面仍细（不是机匣/弹匣井）就继续
	var rear := x
	var xx := x - 0.01
	while xx > x - 0.25:
		var s2 := _section_at(xx)
		if s2.is_empty() or float(s2[0]) < y_lo - 0.02 or float(s2[1]) - float(s2[0]) > 0.11:
			break
		rear = xx
		xx -= 0.01
	var f := Vector3(0.45, -sin(a), cos(a)).normalized()
	f = (f - n * f.dot(n)).normalized()
	var info := {"attach": attach, "center": c, "rz": rz, "n": n, "f": f, "rear_x": rear, "x": x, "y_lo": y_lo, "y_hi": float(sec[1]), "z_lo": zl, "z_hi": zh}
	_sect_cache[key] = info
	return info


func _left_grip_allowed() -> bool:
	if gun == null or view == null or gun.get_parent() != view:
		return false
	if state == "reloading" or state == "drawing" or state == "holstering":
		return false
	return not _foregrip_info().is_empty()


func _step_left_grip_weight(delta: float) -> void:
	# 换弹/拔枪时交给动画（手要去拿弹匣），结束后平滑回到护木，避免跳变。
	_lgrip_w = move_toward(_lgrip_w, 1.0 if _left_grip_allowed() else 0.0, delta * 9.0)


func _left_grip_pose(a: Dictionary) -> Dictionary:
	## 左手握护木的手骨原点（view 局部）与手语义朝向（view 局部）。
	var info := _foregrip_info()
	if info.is_empty() or gun == null:
		return {}
	var sc := gun.global_transform.basis.get_scale().x
	if sc < 1e-4:
		return {}
	var n: Vector3 = info["n"]
	var f: Vector3 = info["f"]
	var flen: float = float(a.get("flen", 0.09))
	# 泵动：掌心跟着前托一起前后滑（同一帧的枪骨姿势）。
	var palm: Vector3 = (info["attach"] as Vector3) + _pump_offset_gun() - n * (PALM_GAP / sc)
	var wrist_g: Vector3 = palm - f * (flen * 0.5 / sc)
	var gxf: Transform3D = gun.transform
	var sem_g := Basis(f, n.cross(f), n)
	return {
		"wrist": gxf * wrist_g,
		"q": (gxf.basis.orthonormalized() * sem_g).get_rotation_quaternion(),
		"palm_g": palm,
	}


func _wrist_cam(s: String, h: Dictionary, a: Dictionary) -> Vector3:
	var sem_cam := Basis(h["q"] as Quaternion)
	var wrist: Vector3 = (h["wrist"] as Vector3) + sem_cam.x * (float(h["flen"]) - float(a["flen"]))
	if s == "L":
		wrist += _left_hand_adjust()
	else:
		wrist += RIGHT_HAND_ADJUST
	# 长枪左手：握护木（权重 _lgrip_w 在换弹/拔枪时平滑退回动画）。
	if s == "L" and _is_long_gun(cur_def()):
		if _lgrip_w > 0.0:
			var lg := _left_grip_pose(a)
			if not lg.is_empty():
				return wrist.lerp(lg["wrist"], _lgrip_w)
		return wrist
	# 换弹时手要跟弹匣/拉机柄动画走，不要再把手腕硬拉回护木导致手脚不同步。
	var grip_ok := gun and view and GRIP_BLEND > 0.0 and gun.get_parent() == view
	if state == "reloading" or state == "drawing" or state == "holstering":
		grip_ok = false
	if grip_ok:
		var gxf: Transform3D = gun.transform  # view 局部
		var wg: Vector3 = gxf.affine_inverse() * wrist
		if wg.is_finite():
			var want := wg
			if s == "L":
				if not _is_long_gun(cur_def()):
					var attach := _foregrip_gun()
					var b := clampf(GRIP_BLEND * 1.55, 0.0, 0.88)
					return gxf * wg.lerp(attach, b)
				return wrist
			else:
				var tx := _grip_target_x(s)
				want.x = lerpf(wg.x, tx, clampf(GRIP_BLEND * 1.6, 0.0, 0.90))
				want.y -= 0.004
			wrist = gxf * want
	return wrist


func _apply_ik(pose: Dictionary, w: float) -> void:
	if pose.is_empty() or skeleton == null or _arm.is_empty() or w <= 0.0:
		return
	_ik_dirty = true
	# 视模型挂在插值关闭的相机上；必须用当前（非插值）骨架变换，
	# 否则俯仰时枪已经跟上镜头，手还留在上一物理帧的插值姿势上。
	var sk_xf := _skel_xf()
	var to_sk := sk_xf.affine_inverse()
	var vx := view.global_transform
	var barrel := (to_sk.basis * (vx.basis * (pose["gun"] as Transform3D).basis * Vector3.RIGHT)).normalized()
	for s in ["R", "L"]:
		var a: Dictionary = _arm[s]
		var h: Dictionary = pose[s]
		var sem_cam := Basis(h["q"] as Quaternion)
		var gw := 0.0
		_slide_max = 0.42
		if s == "L" and _lgrip_w > 0.0 and _is_long_gun(cur_def()):
			var lg := _left_grip_pose(a)
			if not lg.is_empty():
				gw = _lgrip_w
				sem_cam = Basis((h["q"] as Quaternion).slerp(lg["q"] as Quaternion, gw))
				# 够不着时只允许沿护木往后滑到护木后端，不再滑进弹匣井或悬空。
				var info := _foregrip_info()
				var scl := gun.global_transform.basis.get_scale().x
				_slide_max = lerpf(0.42, maxf(0.0, (float(info["x"]) - float(info["rear_x"])) * scl), gw)
		var sem_sk := (to_sk.basis * vx.basis * sem_cam).orthonormalized()
		# 手腕：让「指根」对齐素材手的指根（我们的手掌更短）；左手再略下调避免穿模。
		var wrist_cam: Vector3 = _wrist_cam(s, h, a)
		var P: Vector3 = to_sk * (vx * wrist_cam)
		var pole_cam: Vector3 = POLE_R if s == "R" else POLE_L
		# 用持枪空间（view）而不是环绕相机，否则观察模式下肘部会随观察角扭转。
		var pole_sk := (to_sk.basis * vx.basis * pole_cam).normalized()
		_solve_arm(a, P, pole_sk, sem_sk, barrel if s == "L" else Vector3.ZERO, w)
		# 手指
		var curls: PackedFloat32Array = h["curls"]
		var fl: Array = a["fingers"]
		for i in fl.size():
			var fd: Dictionary = fl[i]
			if int(fd["i"]) < 0:
				continue
			var ang := (curls[i] - float(fd["bend0"])) * finger_gain
			# 非拇指手指再弯曲，包住握把/护木（右手握把握得更紧，左手托护木稍松）。
			if i < 12:
				var gc := grip_curl * (1.0 if s == "R" else 0.75)
				ang += gc * (0.35 if (i % 3) == 0 else 1.0)
				# 左手握护木：四指合拢包住护木（绝对弯曲角，不随动画张开）。
				if gw > 0.0:
					ang = lerpf(ang, float(LGRIP_CURL[i % 3]), gw)
				elif s == "R" and _is_long_gun(cur_def()) and i >= 3:
					# 右手中/无名/小指扣紧握把
					ang = maxf(ang, float(RGRIP_CURL[i % 3]))
			var q: Quaternion = (fd["rest"] as Quaternion) * Quaternion(fd["ax"] as Vector3, ang)
			_set_rot(int(fd["i"]), q, w)
	_align_thumbs_to_slide(pose, w)


func _align_thumbs_to_slide(pose: Dictionary, ik_w: float) -> void:
	# 双手大拇指沿套筒/机匣方向（+X）：托手拇指贴高位，击发手拇指沿弱侧，不包住套筒后端。
	if skeleton == null or gun == null or ik_w <= 0.0:
		return
	var wdef: WeaponDef = cur_def()
	if wdef == null:
		return
	var slide := (gun.global_transform.basis * Vector3.RIGHT).normalized()
	var up := (gun.global_transform.basis * Vector3.UP).normalized()
	for s in ["R", "L"]:
		# 托手（左）略偏上贴套筒；击发手沿滑套外侧、略低于托手
		var want := (slide * 0.86 + up * 0.5).normalized() if s == "L" else (slide * 0.92 - up * 0.18).normalized()
		if s == "L" and _is_long_gun(wdef) and _lgrip_w > 0.0:
			# 长枪托护木：拇指贴着护木左侧向前，不要翘到导轨上方。
			want = (slide * 0.95 + up * lerpf(0.5, 0.05, _lgrip_w)).normalized()
		_aim_bone_chain_to(s + "_Thumb", want, ik_w)


func _aim_bone_chain_to(prefix: String, world_dir: Vector3, w: float) -> void:
	if world_dir.length_squared() < 1e-8:
		return
	world_dir = world_dir.normalized()
	var sk_xf := _skel_xf()
	for j in ["a", "b"]:
		var bi := skeleton.find_bone("%s_%s" % [prefix, j])
		if bi < 0:
			continue
		var ch := skeleton.get_bone_children(bi)
		if ch.is_empty():
			continue
		var g := skeleton.get_bone_global_pose(bi)
		var cg := skeleton.get_bone_global_pose(ch[0])
		var cur := (sk_xf.basis * (cg.origin - g.origin))
		if cur.length_squared() < 1e-10:
			continue
		cur = cur.normalized()
		var axis := cur.cross(world_dir)
		var si := axis.length()
		if si < 1e-5:
			continue
		axis = (g.basis.orthonormalized().inverse() * (sk_xf.basis.inverse() * (axis / si))).normalized()
		var ang := atan2(si, cur.dot(world_dir))
		var rest_q := _base_rot(bi)
		var q := rest_q * Quaternion(axis, ang)
		# 只叠加在当前姿势上：用已写好的手指弯曲再瞄一次
		var now := skeleton.get_bone_pose_rotation(bi)
		_set_rot(bi, now.slerp(now * Quaternion(axis, ang), 1.0), w)


func debug_ads_parts() -> Dictionary:
	var out := {"rear": 999.0, "front": 999.0, "rear_pt": Vector3.ZERO, "front_pt": Vector3.ZERO, "dy": 0.0, "dx": 0.0, "stack": 999.0, "axis_deg": 999.0, "roll_deg": 999.0}
	if gun == null or camera == null:
		return out
	var w: WeaponDef = cur_def()
	if w == null:
		return out
	var pts := _sight_locals(w)
	out["rear_pt"] = pts[0]
	out["front_pt"] = pts[1]
	var vp := camera.get_viewport()
	# 3D 反投影使用视口像素（vp.size），不要用 content_scale 的 visible_rect，否则手机上会偏。
	var c: Vector2 = Vector2(vp.size) * 0.5 if vp else Vector2.ZERO
	var wr: Vector3 = gun.to_global(pts[0])
	var wf: Vector3 = gun.to_global(pts[1])
	if camera.is_position_behind(wr) or camera.is_position_behind(wf):
		return out
	var pr: Vector2 = camera.unproject_position(wr)
	var pf: Vector2 = camera.unproject_position(wf)
	out["rear"] = pr.distance_to(c)
	out["front"] = pf.distance_to(c)
	out["dy"] = pr.y - c.y
	out["dx"] = pr.x - c.x
	out["stack"] = pr.distance_to(pf)
	var cam_inv := camera.global_transform.affine_inverse()
	var axis: Vector3 = (cam_inv * wf) - (cam_inv * wr)
	if axis.length_squared() > 1e-10:
		out["axis_deg"] = rad_to_deg(axis.normalized().angle_to(Vector3(0.0, 0.0, -1.0)))
	var up_c: Vector3 = cam_inv.basis * gun.global_transform.basis.y
	out["roll_deg"] = rad_to_deg(atan2(up_c.x, up_c.y))
	var stock_w: Vector3 = gun.to_global(_stock_local(w))
	var stock_c: Vector3 = cam_inv * stock_w
	out["stock_cam_z"] = stock_c.z
	out["rear_cam_z"] = (cam_inv * wr).z
	out["d_shoulder"] = 99.0
	if skeleton:
		var sh_i := skeleton.find_bone("R_Shoulder_a")
		if sh_i >= 0:
			var sh: Vector3 = _skel_xf() * skeleton.get_bone_global_pose(sh_i).origin
			out["d_shoulder"] = stock_w.distance_to(sh)
	return out


func debug_ads_error() -> float:
	## 三点一线：孔和准星尖都应投影在屏幕中心 + 上。
	var d := debug_ads_parts()
	return maxf(float(d.get("rear", 999.0)), float(d.get("front", 999.0)))


func debug_aim_follow() -> Dictionary:
	## 低头瞄准：枪口 +X 应与相机前向大致同向，视模型在画面中偏下。
	var out := {"dot": 0.0, "view_y": 0.0, "view_pos": Vector3.ZERO, "ok": false}
	if gun == null or camera == null or view == null:
		return out
	var wfwd := (gun.global_transform.basis * Vector3.RIGHT).normalized()
	var cfwd := (-camera.global_transform.basis.z).normalized()
	out["dot"] = wfwd.dot(cfwd)
	out["view_y"] = view.position.y
	out["view_pos"] = view.position
	out["ok"] = true
	return out


func debug_arm_down_offset() -> float:
	return _armed_arm_down().y


func debug_waist_hold_vector() -> Vector3:
	## 把「枪相对腰」的向量按当前仰角绕腰部右轴转回水平。若旋转中心是腰，
	## 不同俯仰下这个向量应大致不变；若绕眼睛转，低头后会明显偏离。
	if camera == null or view == null:
		return Vector3.ZERO
	var W := _waist_world()
	var g: Vector3 = view.global_position
	var u := _look_up_angle()
	var yaw_fwd := -camera.global_transform.basis.z
	yaw_fwd.y = 0.0
	if yaw_fwd.length_squared() < 1e-8:
		yaw_fwd = Vector3(0, 0, -1)
	yaw_fwd = yaw_fwd.normalized()
	# 右轴 = 水平前向 × 上，与相机 +X（朝右）一致。不要用 up.cross(fwd)，那是左轴。
	var yaw_r := yaw_fwd.cross(Vector3.UP)
	if yaw_r.length_squared() < 1e-8:
		yaw_r = Vector3.RIGHT
	yaw_r = yaw_r.normalized()
	return Basis(yaw_r, -u) * (g - W)


func debug_waist_pivot() -> Dictionary:
	## 俯仰应以腰部为旋转中心；胸椎不应再被弯折。
	var out := {
		"ok": false,
		"pivot": "waist",
		"arm_down": debug_arm_down_offset(),
		"look_up": 0.0,
		"waist": Vector3.ZERO,
		"gun": Vector3.ZERO,
		"hold_vec": Vector3.ZERO,
	}
	if camera == null or view == null:
		return out
	out["look_up"] = _look_up_angle()
	out["waist"] = _waist_world()
	out["gun"] = view.global_position
	out["hold_vec"] = debug_waist_hold_vector()
	# 若仍绕眼睛转，hold 向量相对水平会偏 |R(-u)(E-W) - (E-W)|，作为对照。
	var EW: Vector3 = camera.global_position - (out["waist"] as Vector3)
	var yf := -camera.global_transform.basis.z
	yf.y = 0.0
	if yf.length_squared() < 1e-8:
		yf = Vector3(0, 0, -1)
	var yr := yf.normalized().cross(Vector3.UP).normalized()
	out["eye_pivot_err"] = (Basis(yr, -float(out["look_up"])) * EW - EW).length()
	out["ok"] = true
	return out


func debug_stock_vs_head() -> Dictionary:
	## 第三人称：枪托应更靠近肩窝而不是头/脸。
	var out := {"stock": Vector3.ZERO, "shoulder": Vector3.ZERO, "head": Vector3.ZERO, "d_sh": 99.0, "d_head": 99.0, "ok": false}
	if gun == null or skeleton == null:
		return out
	var w: WeaponDef = cur_def()
	out["stock"] = gun.to_global(_stock_local(w))
	var sh_i := skeleton.find_bone("R_Shoulder_a")
	var hd_i := skeleton.find_bone("C_Head_a")
	var skx := _skel_xf()
	if sh_i >= 0:
		out["shoulder"] = skx * skeleton.get_bone_global_pose(sh_i).origin
	if hd_i >= 0:
		out["head"] = skx * skeleton.get_bone_global_pose(hd_i).origin
	out["d_sh"] = out["stock"].distance_to(out["shoulder"])
	out["d_head"] = out["stock"].distance_to(out["head"])
	out["ok"] = out["d_sh"] + 0.02 < out["d_head"]
	var fwd := Vector3(0, 0, 1)
	if player and player.has_method("_body_forward"):
		fwd = player.call("_body_forward")
	if fwd.length_squared() < 1e-8:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 1e-8:
		right = Vector3.RIGHT
	right = right.normalized()
	var delta: Vector3 = out["stock"] - out["shoulder"]
	out["along_fwd"] = delta.dot(fwd)
	out["along_right"] = delta.dot(right)
	out["along_up"] = delta.y
	var chest_i := skeleton.find_bone("C_Spine_c")
	var ua_i := skeleton.find_bone("R_UpperArm_a")
	if chest_i >= 0:
		out["chest"] = skx * skeleton.get_bone_global_pose(chest_i).origin
		out["d_chest"] = out["stock"].distance_to(out["chest"])
	if ua_i >= 0 and sh_i >= 0:
		var axilla: Vector3 = (out["shoulder"] as Vector3).lerp(skx * skeleton.get_bone_global_pose(ua_i).origin, 0.42)
		axilla += Vector3(0.0, -0.025, 0.0)
		out["armpit"] = axilla
		out["d_armpit"] = out["stock"].distance_to(axilla)
	return out


func debug_flash() -> Dictionary:
	var qsz := Vector2.ZERO
	if flash and flash.mesh is QuadMesh:
		qsz = (flash.mesh as QuadMesh).size
	return {
		"quad": qsz,
		"energy": flash_light.light_energy if flash_light else 0.0,
		"range": flash_light.omni_range if flash_light else 0.0,
		"duration": 0.08,
		"visible": flash.visible if flash else false,
	}


func debug_thumb_slide() -> Dictionary:
	## 拇指骨指向与套筒 +X 的点积（越大越贴合）。
	var out := {"L": -1.0, "R": -1.0, "ok": false}
	if gun == null or skeleton == null:
		return out
	var slide := (gun.global_transform.basis * Vector3.RIGHT).normalized()
	var skx := _skel_xf()
	for s in ["R", "L"]:
		var a := skeleton.find_bone("%s_Thumb_a" % s)
		var b := skeleton.find_bone("%s_Thumb_b" % s)
		if a < 0 or b < 0:
			continue
		var pa: Vector3 = skx * skeleton.get_bone_global_pose(a).origin
		var pb: Vector3 = skx * skeleton.get_bone_global_pose(b).origin
		var d := (pb - pa)
		if d.length_squared() < 1e-10:
			continue
		out[s] = d.normalized().dot(slide)
	out["ok"] = float(out["L"]) > 0.35 and float(out["R"]) > 0.25
	return out


## 左手握护木四指弯曲（弧度，近/中/远节）。
const LGRIP_CURL := [0.80, 1.00, 0.70]
const RGRIP_CURL := [0.85, 1.05, 0.75]
var _slide_max := 0.42
var _grab_solving := false
## 第一人称长枪：肩膀在镜头后下方约 0.3–0.6m（为不露出自己身体），开镜时手臂需要更长才能握到护木。
## t27u：t25u 的伸长把「前臂→手」骨的位置也按倍数放大，手骨被推离前臂末端近 20cm，
## 手腕/手掌皮肤被拉长，看起来像左手手指被拉长。现在：
##  - 前臂、手、手指骨长度永远保持原样（只旋转，不缩放不位移）；
##  - 第一人称长枪（肩膀在镜头后下方、画面外）需要的额外长度只加在上臂上（画面外），
##    总长倍数沿用 t25u 的腰射 1.42 / 开镜 1.80 上限，再不够才沿护木后滑；
##  - 观察模式 / 手枪 / 其它持枪：总长最多 1.05（轻微），其余由 _pull_gun_into_reach 把枪挪近。
const ARM_STRETCH_FP_HIP := 1.42
const ARM_STRETCH_FP_ADS := 1.80
const ARM_STRETCH_ARMED := 1.05


func _stretch_max_for(left_grip: bool) -> float:
	# 空手抓取/拖拽保持原手臂上限。
	if _grab_solving or not is_armed():
		return ARM_STRETCH_MAX
	var fp := bool(player.get("first_person")) if player else false
	if not fp or not _is_long_gun(cur_def()):
		return ARM_STRETCH_ARMED
	var k := clampf(_ads_k, 0.0, 1.0)
	var m := lerpf(ARM_STRETCH_FP_HIP, ARM_STRETCH_FP_ADS, k)
	if not left_grip:
		m = lerpf(ARM_STRETCH_ARMED, m, 0.6)
	return m


## 自检（t27u）：上一帧左右手臂的伸长倍数（1 = 原长）。
func debug_arm_stretch() -> Dictionary:
	var out := {}
	for s in ["L", "R"]:
		var a: Dictionary = _arm.get(s, {})
		out[s] = float(a.get("last_stretch", 1.0))
		out[s + "_ua"] = float(a.get("last_ua_k", 1.0))
		# 前臂/手骨的实际长度比（应恒为 1）
		if not a.is_empty() and skeleton:
			var ha := int(a["ha"])
			out[s + "_fa_len"] = skeleton.get_bone_pose_position(ha).length() / maxf(skeleton.get_bone_rest(ha).origin.length(), 1e-5)
	# 手指骨位移比（应恒为 1）
	var worst := 1.0
	for bi in _finger_bones:
		var r := skeleton.get_bone_rest(bi).origin.length()
		if r > 1e-5:
			var k := skeleton.get_bone_pose_position(bi).length() / r
			if absf(k - 1.0) > absf(worst - 1.0):
				worst = k
	out["finger_len"] = worst
	return out


func _solve_arm(a: Dictionary, P: Vector3, pole: Vector3, hand_basis: Basis, slide_axis: Vector3, w: float) -> void:
	var sh := int(a["sh"])
	var ua := int(a["ua"])
	var fa := int(a["fa"])
	var ha := int(a["ha"])
	var l1: float = a["l1"]
	var l2: float = a["l2"]
	var reach := (l1 + l2) * 0.999
	var ua_local := Transform3D(Basis(_base_rot(ua)), skeleton.get_bone_pose_position(ua))
	# 锁骨 / 肩膀保持走跑或休息底姿势，不再为够枪而转动。
	# 枪械动画只叠加上臂随动 + 小臂及以下；拧锁骨会把胸肩网格拉成麻花。
	var sh_par := skeleton.get_bone_parent(sh)
	var par_g := skeleton.get_bone_global_pose(sh_par) if sh_par >= 0 else Transform3D()
	var sh_base := Basis(_base_rot(sh))
	_set_rot(sh, sh_base.get_rotation_quaternion(), w)
	var sh_g := par_g * Transform3D(sh_base, skeleton.get_bone_pose_position(sh))
	var ua_g := sh_g * ua_local
	var A := ua_g.origin
	var d := P - A
	# 左手够不着护木：先允许手臂伸长（第一人称肩膀在镜头后下方，开镜时距离天然更远），
	# 仍不够再沿护木往回滑（最多到护木后端），绝不让手悬空或滑进弹匣井。
	var smax := _stretch_max_for(slide_axis != Vector3.ZERO)
	if slide_axis != Vector3.ZERO and d.length() > reach * smax:
		reach *= smax
		var b := slide_axis
		var bd := d.dot(b)
		var disc := bd * bd - (d.length_squared() - reach * reach)
		var sl := bd - sqrt(disc) if disc >= 0.0 else bd
		sl = clampf(sl, 0.0, _slide_max)
		P -= b * sl
		d = P - A
		reach /= smax
	var stretch := clampf(d.length() / reach, 1.0, smax)
	a["last_stretch"] = stretch
	# 额外长度全部给上臂：l1' = stretch·(l1+l2) − l2；前臂 l2 不变。
	var ua_k := maxf(1.0, (stretch * (l1 + l2) - l2) / maxf(l1, 1e-4))
	a["last_ua_k"] = ua_k
	l1 *= ua_k
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
	# 只移动前臂骨的起点（= 上臂变长）；手骨位置保持 rest，手/手指比例不变。
	if ua_k > 1.0001:
		skeleton.set_bone_pose_position(fa, skeleton.get_bone_rest(fa).origin * ua_k)
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


## 测试：锁骨/上臂相对 rest 的扭转，以及左右肩高度差（持枪时肩不应拧坏）。
func debug_shoulder_metrics() -> Dictionary:
	var out := {
		"L_sh": 0.0, "R_sh": 0.0, "L_ua": 0.0, "R_ua": 0.0,
		"height_delta": 0.0, "ok": false,
	}
	if skeleton == null:
		return out
	var skx := _skel_xf()
	var heights: Dictionary = {}
	for s in ["L", "R"]:
		for pair in [["sh", "Shoulder_a"], ["ua", "UpperArm_a"]]:
			var bi := skeleton.find_bone("%s_%s" % [s, pair[1]])
			if bi < 0:
				continue
			var now: Quaternion = skeleton.get_bone_pose_rotation(bi)
			var rest: Quaternion = skeleton.get_bone_rest(bi).basis.get_rotation_quaternion()
			out["%s_%s" % [s, pair[0]]] = now.angle_to(rest)
		var shi := skeleton.find_bone("%s_Shoulder_a" % s)
		if shi >= 0:
			heights[s] = (skx * skeleton.get_bone_global_pose(shi).origin).y
	if heights.has("L") and heights.has("R"):
		out["height_delta"] = absf(float(heights["L"]) - float(heights["R"]))
	# 走跑底姿势锁骨也会有几度生理活动；超过约 22° 或左右肩高低差过大视为拧坏。
	out["ok"] = (
		float(out["L_sh"]) < deg_to_rad(22.0)
		and float(out["R_sh"]) < deg_to_rad(22.0)
		and float(out["height_delta"]) < 0.055
	)
	return out


## 测试（t25u）：左手是否真的握在护木/泵动前托上。距离均为世界米。
func debug_left_grip() -> Dictionary:
	var out := {"ok": false, "long": false, "w": _lgrip_w}
	var w: WeaponDef = cur_def()
	if w == null or gun == null or skeleton == null or not _arm.has("L"):
		return out
	out["long"] = _is_long_gun(w)
	var info := _foregrip_info()
	if info.is_empty():
		return out
	var skx := _skel_xf()
	var hi := skeleton.find_bone("L_Hand_a")
	var mi := skeleton.find_bone("L_Middle_a")
	if hi < 0 or mi < 0:
		return out
	var hand: Vector3 = skx * skeleton.get_bone_global_pose(hi).origin
	var mid: Vector3 = skx * skeleton.get_bone_global_pose(mi).origin
	var palm := (hand + mid) * 0.5
	var sc := gun.global_transform.basis.get_scale().x
	var lg := _left_grip_pose(_arm["L"])
	var target_palm: Vector3 = gun.to_global(lg["palm_g"]) if not lg.is_empty() else palm
	var attach: Vector3 = gun.to_global(info["attach"])
	var inv := gun.global_transform.affine_inverse()
	var c: Vector3 = info["center"]
	var pl: Vector3 = inv * palm
	var radial := Vector2(pl.y - c.y, pl.z - c.z).length()
	out["palm"] = palm
	out["attach"] = attach
	out["palm_err"] = palm.distance_to(target_palm)
	out["palm_to_attach"] = palm.distance_to(attach)
	out["gap"] = (radial - float(info["rz"])) * sc
	out["along_x"] = (pl.x - float(info["x"])) * sc
	var inside := 0
	var tips := 0
	for nm in ["L_Hand_a", "L_Middle_a", "L_Index_c", "L_Middle_c", "L_Ring_c", "L_Pinky_c", "L_Index_b", "L_Middle_b", "L_Ring_b", "L_Pinky_b"]:
		var bi := skeleton.find_bone(nm)
		if bi < 0:
			continue
		var q: Vector3 = inv * (skx * skeleton.get_bone_global_pose(bi).origin)
		var sec := _section_at(q.x)
		if sec.is_empty():
			continue
		var m := 0.003 / maxf(sc, 1e-4)
		if q.y > float(sec[0]) + m and q.y < float(sec[1]) - m and q.z > float(sec[2]) + m and q.z < float(sec[3]) - m:
			inside += 1
		if nm.ends_with("_c"):
			tips += 1
	out["inside"] = inside
	out["ok"] = float(out["palm_to_attach"]) < 0.03 and inside == 0
	return out


## 测试（t25u）：枪膛轴线到瞄准点的最近距离（米）与枪/视线俯仰差（度）。
func debug_bore_aim() -> Dictionary:
	var out := {"ok": false}
	var w: WeaponDef = cur_def()
	if w == null or gun == null or camera == null:
		return out
	var fp := bool(player.get("first_person")) if player else true
	var M := gun.global_transform
	var muz: Vector3 = M * w.muzzle
	var bore: Vector3 = (M.basis * Vector3.RIGHT).normalized()
	var T: Vector3
	var view_dir: Vector3
	if fp:
		T = _center_aim_point()
		view_dir = -camera.global_transform.basis.z.normalized()
	else:
		var fwd: Vector3 = player.call("_body_forward") if player and player.has_method("_body_forward") else Vector3(0, 0, -1)
		var pocket: Vector3 = M * _stock_local(w)
		T = _tp_aim_point(fwd.normalized(), pocket)
		view_dir = (T - pocket).normalized()
	var to_t := T - muz
	var along := to_t.dot(bore)
	var closest := muz + bore * along
	out["target"] = T
	out["muzzle"] = muz
	out["miss"] = closest.distance_to(T)
	out["along"] = along
	out["gun_pitch"] = rad_to_deg(asin(clampf(bore.y, -1.0, 1.0)))
	out["view_pitch"] = rad_to_deg(asin(clampf(view_dir.y, -1.0, 1.0)))
	out["pitch_err"] = absf(float(out["gun_pitch"]) - float(out["view_pitch"]))
	out["ok"] = along > 0.0
	return out


## 测试（t25u）：枪托后端与右肩/上臂的世界位置（俯仰时枪托应留在肩窝、手绕肩画弧）。
func debug_stock_pivot() -> Dictionary:
	var out := {"ok": false}
	var w: WeaponDef = cur_def()
	if w == null or gun == null or skeleton == null:
		return out
	var skx := _skel_xf()
	out["stock"] = gun.to_global(_stock_local(w))
	for nm in ["R_Shoulder_a", "R_UpperArm_a", "L_Hand_a", "R_Hand_a"]:
		var bi := skeleton.find_bone(nm)
		if bi >= 0:
			out[nm] = skx * skeleton.get_bone_global_pose(bi).origin
	if camera:
		out["eye"] = camera.global_position
	out["look_up"] = _look_up_angle()
	out["ok"] = out.has("R_UpperArm_a")
	return out


## 测试：手腕到素材目标的误差（米）
func debug_hand_error() -> Dictionary:
	var out := {}
	if _last_pose.is_empty() or _arm.is_empty():
		return out
	var vx := view.global_transform
	for s in ["R", "L"]:
		var a: Dictionary = _arm[s]
		var h: Dictionary = _last_pose[s]
		var wrist_cam: Vector3 = _wrist_cam(s, h, a)
		var want := vx * wrist_cam
		var got := _skel_xf() * skeleton.get_bone_global_pose(int(a["ha"])).origin
		out[s] = want.distance_to(got)
	return out
