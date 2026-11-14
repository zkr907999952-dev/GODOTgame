extends Node
## 物理弹壳：按武器抛对应型号，Jolt 刚体落地弹跳，10 秒回收，上限内回收最旧的，对象池避免分配尖峰。

const SHELLS_SCENE := preload("res://assets/weapons/shared/shells.scn")
const LIFE_SEC := 10.0
const CAP := 40
const FADE_SEC := 0.45

## 抛壳手感：右向速度、上向、后向、角速度大约值（各武器不同）
const EJECT := {
	"pistol": {"speed": Vector3(0.4, 2.2, 3.2), "spin": 38.0, "mass": 0.012, "bounce": 0.42},
	"rifle": {"speed": Vector3(0.6, 2.8, 5.2), "spin": 48.0, "mass": 0.015, "bounce": 0.38},
	"smg": {"speed": Vector3(0.3, 2.6, 3.8), "spin": 42.0, "mass": 0.012, "bounce": 0.40},
	"shotgun": {"speed": Vector3(0.5, 1.6, 2.4), "spin": 18.0, "mass": 0.032, "bounce": 0.28},
}

var life_sec: float = LIFE_SEC
var cap: int = CAP
var _meshes: Dictionary = {}  # name -> Mesh
var _mats: Dictionary = {}    # 每颗壳自己的材质副本，用来淡出
var _pool: Array[RigidBody3D] = []
var _live: Array[RigidBody3D] = []
var _host: Node3D
var _phys_mat: PhysicsMaterial


func setup(host: Node3D = null) -> void:
	_host = host if host else self
	_phys_mat = PhysicsMaterial.new()
	_phys_mat.bounce = 0.38
	_phys_mat.friction = 0.55
	var root := SHELLS_SCENE.instantiate()
	for c in root.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh:
			_meshes[str(c.name)] = (c as MeshInstance3D).mesh
	root.free()
	set_physics_process(true)


func mesh_for(kind: String) -> Mesh:
	return _meshes.get(kind)


func live_count() -> int:
	return _live.size()


func live_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for b in _live:
		out.append(str(b.get_meta("kind", "")))
	return out


func oldest_age() -> float:
	var a := 0.0
	for b in _live:
		a = maxf(a, float(b.get_meta("age", 0.0)))
	return a


func clear_all() -> void:
	for b in _live:
		_park(b)
	_live.clear()


## xf = 抛壳口世界变换（X 前、Y 上、Z 右，与枪模型一致）；kind = shells.scn 子节点名
func eject(kind: String, xf: Transform3D, category: String = "rifle", body_vel: Vector3 = Vector3.ZERO) -> RigidBody3D:
	var mesh: Mesh = _meshes.get(kind)
	if mesh == null:
		return null
	while _live.size() >= cap:
		_despawn(_live[0])
	var b := _take(kind, mesh)
	var st: Dictionary = EJECT.get(category, EJECT["rifle"])
	b.mass = float(st["mass"])
	(_phys_mat as PhysicsMaterial).bounce = float(st["bounce"])
	b.physics_material_override = _phys_mat
	b.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
	var right := xf.basis.z.normalized()
	var up := xf.basis.y.normalized()
	var back := -xf.basis.x.normalized()
	var sp: Vector3 = st["speed"]
	var vel := right * randf_range(sp.z * 0.85, sp.z * 1.15) + up * randf_range(sp.y * 0.8, sp.y * 1.2) + back * randf_range(sp.x * 0.6, sp.x * 1.3)
	b.linear_velocity = vel + body_vel
	var spin := float(st["spin"])
	b.angular_velocity = xf.basis * Vector3(randf_range(-spin, spin), randf_range(spin * 0.4, spin), randf_range(-spin * 0.5, spin * 0.5))
	b.set_meta("kind", kind)
	b.set_meta("age", 0.0)
	b.set_meta("category", category)
	_live.append(b)
	return b


func _physics_process(dt: float) -> void:
	var i := 0
	while i < _live.size():
		var b := _live[i]
		var age := float(b.get_meta("age", 0.0)) + dt
		b.set_meta("age", age)
		var left := life_sec - age
		if left <= 0.0:
			_despawn(b)
			continue
		var mi: MeshInstance3D = b.get_node_or_null("Mesh")
		if mi:
			mi.transparency = 0.0 if left > FADE_SEC else clampf(1.0 - left / FADE_SEC, 0.0, 1.0)
		i += 1


func debug_age_all(sec: float) -> void:
	for b in _live:
		b.set_meta("age", sec)


func _take(kind: String, mesh: Mesh) -> RigidBody3D:
	var b: RigidBody3D = null
	for p in _pool:
		if not p.visible and str(p.get_meta("pool_kind", "")) == kind:
			b = p
			break
	if b == null:
		for p in _pool:
			if not p.visible:
				b = p
				_retarget(b, kind, mesh)
				break
	if b == null:
		b = _make(kind, mesh)
		_pool.append(b)
	b.visible = true
	b.freeze = false
	b.sleeping = false
	b.process_mode = Node.PROCESS_MODE_INHERIT
	b.collision_layer = 4
	b.collision_mask = 1 | 2
	var mi: MeshInstance3D = b.get_node_or_null("Mesh")
	if mi:
		mi.transparency = 0.0
	return b


func _retarget(b: RigidBody3D, kind: String, mesh: Mesh) -> void:
	var mi: MeshInstance3D = b.get_node("Mesh")
	mi.mesh = mesh
	b.set_meta("pool_kind", kind)
	_fit_shape(b, mesh)


func _make(kind: String, mesh: Mesh) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.name = "Casing"
	b.mass = 0.015
	b.continuous_cd = true
	b.can_sleep = true
	b.collision_layer = 4
	b.collision_mask = 1 | 2
	b.physics_material_override = _phys_mat
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.add_child(mi)
	var col := CollisionShape3D.new()
	col.name = "Col"
	b.add_child(col)
	_fit_shape(b, mesh)
	b.set_meta("pool_kind", kind)
	_host.add_child(b)
	return b


func _fit_shape(b: RigidBody3D, mesh: Mesh) -> void:
	var col: CollisionShape3D = b.get_node("Col")
	var aabb := mesh.get_aabb()
	var sh := BoxShape3D.new()
	var s := aabb.size
	sh.size = Vector3(maxf(s.x, 0.008), maxf(s.y, 0.006), maxf(s.z, 0.006))
	col.shape = sh
	col.position = aabb.position + aabb.size * 0.5


func _despawn(b: RigidBody3D) -> void:
	_live.erase(b)
	_park(b)


func _park(b: RigidBody3D) -> void:
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.freeze = true
	b.visible = false
	b.collision_layer = 0
	b.collision_mask = 0
	b.global_position = Vector3(0, -50, 0)
	b.process_mode = Node.PROCESS_MODE_DISABLED
