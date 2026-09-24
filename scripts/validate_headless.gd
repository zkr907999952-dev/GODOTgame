extends SceneTree
## 无头自检：导入主场景，打印角色 AABB / 骨骼数，然后退出。

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var err := OK
	print("validate: loading main...")
	var packed := load("res://scenes/main.tscn")
	if packed == null:
		push_error("validate: failed to load main.tscn")
		quit(1)
		return
	var main: Node = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var player := main.get_node_or_null("Player")
	if player == null:
		push_error("validate: no Player")
		quit(1)
		return

	var skel: Skeleton3D = null
	for n in player.find_children("*", "Skeleton3D", true, false):
		skel = n
		break
	if skel:
		print("validate: bones=", skel.get_bone_count())
		if skel.get_bone_count() > 0:
			var tip := skel.get_bone_global_pose(0).origin
			print("validate: bone0 tip=", tip)
	else:
		print("validate: WARNING no Skeleton3D")

	var mesh_count := 0
	var merged := AABB()
	var first := true
	for mi in player.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		mesh_count += 1
		var a := m.mesh.get_aabb()
		var xf := m.global_transform
		var corners: Array[Vector3] = []
		for i in 8:
			corners.append(xf * a.get_endpoint(i))
		var mn := corners[0]
		var mx := corners[0]
		for c in corners:
			mn = mn.min(c)
			mx = mx.max(c)
		var world := AABB(mn, mx - mn)
		if first:
			merged = world
			first = false
		else:
			merged = merged.merge(world)
	print("validate: meshes=", mesh_count, " AABB=", merged)
	print("validate: feet_y≈", merged.position.y, " height≈", merged.size.y)

	var room := main.get_node_or_null("Room")
	var city := main.get_node_or_null("City")
	print("validate: room=", room != null, " city=", city != null)
	quit(0)
