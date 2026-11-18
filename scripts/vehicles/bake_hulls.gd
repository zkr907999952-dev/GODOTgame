extends SceneTree
## One-shot baker: instantiate the car / plane, let _ready build and trim
## convex hulls, then save them as BakedHulls resources.
##   godot --headless --path . -s res://scripts/vehicles/bake_hulls.gd

const BakedHullsScript = preload("res://scripts/vehicles/baked_hulls.gd")

const OUT := {
	"res://scenes/vehicles/car.tscn": "res://assets/vehicles/collision/car_hulls.tres",
	"res://scenes/vehicles/plane.tscn": "res://assets/vehicles/collision/plane_hulls.tres",
}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for src in OUT.keys():
		var t0 := Time.get_ticks_msec()
		var v: Node = load(src).instantiate()
		root.add_child(v)
		# Trim uses queue_free — wait a frame so dropped hulls are gone.
		await process_frame
		await process_frame
		var baked := BakedHullsScript.new()
		for c in v.get_children():
			if not (c is CollisionShape3D):
				continue
			var cs := c as CollisionShape3D
			if cs.shape == null or not (cs.shape is ConvexPolygonShape3D):
				continue
			var poly := cs.shape as ConvexPolygonShape3D
			baked.hull_names.append(cs.name)
			baked.hull_transforms.append(cs.transform)
			baked.hull_points.append(poly.points)
		var path: String = OUT[src]
		var err := ResourceSaver.save(baked, path)
		print("bake_hulls: ", src, " -> ", path, " hulls=", baked.hull_count(), " err=", err, " ms=", Time.get_ticks_msec() - t0)
		v.queue_free()
		await process_frame
	quit(0)
