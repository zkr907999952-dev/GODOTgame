extends Node3D
## 皮瓣回退：沿用头发那套 Verlet 积分 + 边长约束 + 地面碰撞。
## SoftBody3D 不可用时由 SurgerySystem 生成。
class_name SurgeryFlapVerlet

var points: PackedVector3Array = PackedVector3Array()
var prev: PackedVector3Array = PackedVector3Array()
var idx: PackedInt32Array = PackedInt32Array()
var rest: PackedFloat32Array = PackedFloat32Array()  # edge rest lengths, 3 per face? unique edges
var e0: PackedInt32Array = PackedInt32Array()
var e1: PackedInt32Array = PackedInt32Array()
var gravity: Vector3 = Vector3(0, -9.8, 0)
var damping: float = 0.08
var ground_y: float = 0.02
var iterations: int = 6
var _mi: MeshInstance3D
var _col_world: World3D


func setup_from_mesh(md, mat: Material, world: World3D, floor_y: float) -> void:
	points = md.pos.duplicate()
	prev = points.duplicate()
	idx = md.idx.duplicate()
	ground_y = floor_y
	_col_world = world
	var seen: Dictionary = {}
	for f in range(0, idx.size(), 3):
		_add_edge(idx[f], idx[f + 1], seen)
		_add_edge(idx[f + 1], idx[f + 2], seen)
		_add_edge(idx[f + 2], idx[f], seen)
	_mi = MeshInstance3D.new()
	_mi.name = "FlapMesh"
	_mi.material_override = mat
	add_child(_mi)
	_rebuild_mesh()


func _add_edge(a: int, b: int, seen: Dictionary) -> void:
	var key := "%d_%d" % [mini(a, b), maxi(a, b)]
	if seen.has(key):
		return
	seen[key] = true
	e0.append(a)
	e1.append(b)
	rest.append(points[a].distance_to(points[b]))


func _physics_process(dt: float) -> void:
	if points.is_empty():
		return
	var dt2 := dt * dt
	for i in points.size():
		var cur := points[i]
		var vel := (cur - prev[i]) * (1.0 - damping)
		prev[i] = cur
		var nxt := cur + vel + gravity * dt2
		# 与世界碰撞：先贴地，再朝下射线。
		if nxt.y < ground_y:
			nxt.y = ground_y
			prev[i] = nxt
		points[i] = nxt
	if _col_world:
		var space := _col_world.direct_space_state
		if space:
			for i2 in points.size():
				var from := points[i2] + Vector3(0, 0.05, 0)
				var to := points[i2] + Vector3(0, -0.08, 0)
				var q := PhysicsRayQueryParameters3D.create(from, to)
				q.collide_with_areas = false
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					var hp: Vector3 = hit["position"]
					if points[i2].y < hp.y + 0.004:
						points[i2].y = hp.y + 0.004
						prev[i2] = points[i2]
	for _k in iterations:
		for e in e0.size():
			var a := e0[e]
			var b := e1[e]
			var pa := points[a]
			var pb := points[b]
			var d := pb - pa
			var len := d.length()
			if len < 1e-8:
				continue
			var diff := (len - rest[e]) / len
			var corr := d * (0.5 * diff)
			points[a] = pa + corr
			points[b] = pb - corr
	_rebuild_mesh()


func _rebuild_mesh() -> void:
	if _mi == null:
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var nrm := PackedVector3Array()
	nrm.resize(points.size())
	for f in range(0, idx.size(), 3):
		var a := idx[f]
		var b := idx[f + 1]
		var c := idx[f + 2]
		var n := (points[b] - points[a]).cross(points[c] - points[a])
		if n.length_squared() > 1e-12:
			n = n.normalized()
			nrm[a] += n
			nrm[b] += n
			nrm[c] += n
	for i in nrm.size():
		if nrm[i].length_squared() > 1e-12:
			nrm[i] = nrm[i].normalized()
		else:
			nrm[i] = Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mi.mesh = am
