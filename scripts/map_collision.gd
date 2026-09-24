extends Node3D
## 为子树中所有 MeshInstance3D 生成精细凹多边形（trimesh）静态碰撞。

@export var skip_foliage: bool = true
@export var min_size: float = 0.04
@export var build_on_ready: bool = true

var _built: bool = false


func _ready() -> void:
	if build_on_ready:
		ensure_collisions()


func ensure_collisions() -> void:
	if _built:
		return
	_built = true
	_build_collisions(self)
	print("map_collision: done under ", name)


func _is_foliage(node_name: String) -> bool:
	var n := node_name.to_lower()
	if n.contains("miami_ground") or n.contains("boulevard_ground") or n.contains("docks_ground") \
			or n.contains("island_ground") or n.contains("hotel_ground") or n.contains("sidewalk") \
			or n.contains("pavement") or n.contains("asphalt") or n.contains("road"):
		return false
	return n.contains("mat_trees") or n.contains("_trees_") or n.contains("palm") \
			or n.contains("foliage") or n.contains("leaves") or n.contains("leaf") \
			or n.contains("bush") or n.contains("hedge") or n.contains("plant") \
			or n.contains("flower") or n.contains("fern") or n.contains("weed")


func _build_collisions(root: Node) -> void:
	var count := 0
	var skipped := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if skip_foliage and _is_foliage(_collect_name(mi)):
			skipped += 1
			continue
		var aabb := mi.mesh.get_aabb()
		var sz := aabb.size
		if sz.x < min_size and sz.y < min_size and sz.z < min_size:
			skipped += 1
			continue
		var has_col := false
		for c in mi.get_children():
			if c is StaticBody3D:
				has_col = true
				break
		if has_col:
			continue
		mi.create_trimesh_collision()
		count += 1
	print("map_collision: trimesh=", count, " skipped=", skipped)


func _collect_name(node: Node) -> String:
	var parts: PackedStringArray = []
	var n: Node = node
	while n:
		if not n.name.is_empty():
			parts.append(str(n.name))
		n = n.get_parent()
	return " ".join(parts)
