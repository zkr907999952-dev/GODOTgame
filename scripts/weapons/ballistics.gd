extends Node
## 弹道 / 子弹系统占位（后续完善）。
## 现在：命中扫描（hitscan）射线 + 可选调试弹孔；不对角色造成伤害。
## 以后：弹速 / 下坠 / 穿透 / 伤害 / 命中特效都在这里扩展，武器系统只调用 fire_ray() 并发出 shot_fired 信号。

signal hit(position: Vector3, normal: Vector3, collider: Object, weapon_id: String)

## 调试弹孔（小黑点贴片），最多保留 MAX_DECALS 个
@export var debug_decals: bool = true
const MAX_DECALS := 48
var _decals: Array = []
var _decal_mesh: QuadMesh
var _decal_mat: StandardMaterial3D
var exclude: Array[RID] = []
var last_hit: Dictionary = {}


func fire_ray(origin: Vector3, dir: Vector3, range_m: float, weapon_id: String) -> Dictionary:
	var w := get_viewport().world_3d if get_viewport() else null
	if w == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m)
	q.exclude = exclude
	q.collide_with_areas = false
	var r := w.direct_space_state.intersect_ray(q)
	last_hit = r
	if r.is_empty():
		return r
	hit.emit(r["position"], r["normal"], r["collider"], weapon_id)
	if debug_decals:
		_spawn_decal(r["position"], r["normal"])
	return r


func _spawn_decal(p: Vector3, n: Vector3) -> void:
	if _decal_mesh == null:
		_decal_mesh = QuadMesh.new()
		_decal_mesh.size = Vector2(0.025, 0.025)
		_decal_mat = StandardMaterial3D.new()
		_decal_mat.albedo_color = Color(0.05, 0.04, 0.035)
		_decal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_decal_mesh.material = _decal_mat
	var mi := MeshInstance3D.new()
	mi.mesh = _decal_mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var host: Node = get_tree().current_scene if get_tree().current_scene else self
	host.add_child(mi)
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	mi.global_transform = Transform3D(Basis.looking_at(-n, up), p + n * 0.002)
	_decals.append(mi)
	while _decals.size() > MAX_DECALS:
		var o: Node = _decals.pop_front()
		if is_instance_valid(o):
			o.queue_free()


func clear_decals() -> void:
	for d in _decals:
		if is_instance_valid(d):
			d.queue_free()
	_decals.clear()
