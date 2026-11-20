extends Node3D
## Fighter visual rig ported from rouchangmoniqi3 vehicles.tsx preparePlane
## and the per-frame surface / nozzle / gear update. Physics is owned by
## plane_controller.gd; this node only binds and poses the model.
class_name PlaneVisuals

const PlaneVaporScript := preload("res://scripts/vehicles/plane_vapor.gd")

const MODEL_PATH := "res://assets/vehicles/plane.glb"
const TARGET_LEN := 18.6
const ORIGIN_Y := 1.28

var surfaces: Array = []  # VehicleHinge
var gears: Array = []
var gear_doors: Array = []
var doors: Array = []
var wheels: Array = []  # {root, rest_pos, rest_quat, steer, axle, spin_sign, offset}
var nozzle_engines: Array = []  # {top, bot, aim, exit_z, throat_z}
var exhausts: Array = []
var steer_wheel: Dictionary = {}  # {obj, rest}
var flap_t: float = 0.0
var vapor: Node
var _surf_t: Dictionary = {}  # hinge id -> current (smoothed) deflection
var wrap: Node3D
var cockpit: Dictionary = {"x": 0.0, "y": 1.28, "z": -5.15}
var half_l: float = 8.6
var half_w: float = 2.1
var height: float = 2.8
var wheel_r: float = 0.42
var ready_ok: bool = false


func setup() -> bool:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		push_error("PlaneVisuals: missing %s" % MODEL_PATH)
		return false
	var root := packed.instantiate() as Node3D
	if root == null:
		return false
	wrap = Node3D.new()
	wrap.name = "PlaneVisual"
	add_child(wrap)
	wrap.add_child(root)
	# Must be in the tree before AABB / global_transform reads.
	VehicleCommon.normalize_facing(root, TARGET_LEN, "^elevator_l|^rudder_", "^gear_f$|bonnet|nose|wheel_lfchild")
	wrap.force_update_transform()
	wheels = _mount_wheels("^wheel_l[fr]")
	cockpit = _measure_cockpit()
	VehicleCommon.lift_origin(wrap, ORIGIN_Y)
	wrap.force_update_transform()
	_snapshot_wheel_offsets()
	_bind_gears()
	_refresh_wheel_rests()
	_bind_gear_doors()
	_bind_surfaces_and_nozzles()
	_bind_canopy()
	var steer := VehicleCommon.first_named(wrap, "steeringwheel")
	if steer is Node3D:
		steer_wheel = _mount_stick_pivot(steer as Node3D)
	VehicleCommon.make_glass(wrap, "window_lf|door_dside_f", 0.1)
	_attach_exhausts()
	vapor = PlaneVaporScript.new()
	add_child(vapor)
	vapor.setup(wrap)
	var box := VehicleCommon.world_aabb(wrap)
	var local_min := wrap.to_local(box.position)
	var local_max := wrap.to_local(box.position + box.size)
	half_l = maxf(absf(local_min.z), absf(local_max.z))
	half_w = maxf(absf(local_min.x), absf(local_max.x))
	height = maxf(local_max.y, 1.0) - minf(local_min.y, 0.0)
	ready_ok = true
	return true


func _mount_wheels(regex: String) -> Array:
	var out: Array = []
	for obj in VehicleCommon.find_named(wrap, regex):
		if not (obj is Node3D):
			continue
		var n := obj as Node3D
		if n.get_parent() and (str(n.get_parent().name).begins_with("WheelHub") \
				or str(n.get_parent().name).begins_with("WheelSteer") \
				or str(n.get_parent().name).begins_with("WheelSpin")):
			continue
		if n.name.ends_with("_hub") or n.name.contains("Hub"):
			continue
		var world_pos := n.global_position
		# Chassis → steer hinge (body-up kingpin) → spin child (axle roll).
		# Same composition as the sports car so a steered nose wheel does not
		# tumble its steer axis as it rolls.
		var spin_sign := 1.0
		var hinge := Node3D.new()
		hinge.name = "WheelSteer_%s" % n.name
		wrap.add_child(hinge)
		hinge.global_position = world_pos
		hinge.quaternion = Quaternion.IDENTITY
		hinge.scale = Vector3.ONE
		var spin := Node3D.new()
		spin.name = "WheelSpin_%s" % n.name
		hinge.add_child(spin)
		spin.position = Vector3.ZERO
		spin.quaternion = Quaternion.IDENTITY
		VehicleCommon.reparent_keep_global(n, spin)
		var off := hinge.position
		var steer := off.z < 0.0
		out.append({
			"root": hinge, "spin": spin, "rest_pos": off, "rest_quat": hinge.quaternion,
			"steer": steer, "axle": "x", "spin_sign": spin_sign, "offset": off,
		})
	out.sort_custom(func(a, b):
		var az: float = a["offset"].z
		var bz: float = b["offset"].z
		return az < bz or (is_equal_approx(az, bz) and a["offset"].x < b["offset"].x)
	)
	return out


func _snapshot_wheel_offsets() -> void:
	for w in wheels:
		var hub: Node3D = w["root"]
		w["offset"] = hub.position
		w["rest_pos"] = hub.position
		w["rest_quat"] = hub.quaternion
		w["steer"] = hub.position.z < 0.0


func _refresh_wheel_rests() -> void:
	for w in wheels:
		var hub: Node3D = w["root"]
		w["rest_pos"] = hub.position
		w["rest_quat"] = hub.quaternion


func _match_gear_wheel(gear_node: Node3D) -> Array:
	var extras: Array = []
	var ga := VehicleCommon.aabb_in(wrap, gear_node)
	for w in wheels:
		var off: Vector3 = w["offset"]
		if absf(off.x - ga["cx"]) < 1.6 and absf(off.z - ga["cz"]) < 2.2:
			extras.append(w["root"])
	return extras


func _bind_gears() -> void:
	var nose := VehicleCommon.first_named(wrap, "^gear_f")
	if nose is Node3D:
		var a := VehicleCommon.aabb_in(wrap, nose as Node3D)
		gears.append(VehicleHinge.mount(wrap, nose as Node3D, Vector3(a["cx"], a["maxY"] - 0.02, a["cz"]), "x", 1.0, 1.42, "gear", _match_gear_wheel(nose as Node3D)))
	var left := VehicleCommon.first_named(wrap, "^gear_lm1")
	if left is Node3D:
		var a := VehicleCommon.aabb_in(wrap, left as Node3D)
		gears.append(VehicleHinge.mount(wrap, left as Node3D, Vector3(a["cx"] + 0.12, a["maxY"] - 0.02, a["cz"]), "z", -1.0, 1.48, "gear", _match_gear_wheel(left as Node3D)))
	var right := VehicleCommon.first_named(wrap, "^gear_rm1")
	if right is Node3D:
		var a := VehicleCommon.aabb_in(wrap, right as Node3D)
		gears.append(VehicleHinge.mount(wrap, right as Node3D, Vector3(a["cx"] - 0.12, a["maxY"] - 0.02, a["cz"]), "z", 1.0, 1.48, "gear", _match_gear_wheel(right as Node3D)))


func _bind_gear_doors() -> void:
	for obj in VehicleCommon.find_named(wrap, "^gear_door_f[lr]"):
		if not (obj is Node3D):
			continue
		var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
		var left: bool = a["cx"] < 0.0
		var in_x: float = maxf(a["minX"], a["cx"] + (a["maxX"] - a["minX"]) * 0.08) if left else minf(a["maxX"], a["cx"] - (a["maxX"] - a["minX"]) * 0.08)
		gear_doors.append(VehicleHinge.mount(wrap, obj as Node3D, Vector3(in_x, a["maxY"] + 0.01, a["cz"]), "z", 1.0 if left else -1.0, 1.56, "gearDoor"))
	for obj in VehicleCommon.find_named(wrap, "^gear_door_r[lr]"):
		if not (obj is Node3D):
			continue
		var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
		var left: bool = a["cx"] < 0.0
		var in_x: float = a["maxX"] if left else a["minX"]
		gear_doors.append(VehicleHinge.mount(wrap, obj as Node3D, Vector3(in_x, a["maxY"] + 0.01, a["cz"]), "z", 1.0 if left else -1.0, 1.56, "gearDoor"))


func _collect_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n as MeshInstance3D)
	for c in n.find_children("*", "MeshInstance3D", true, false):
		out.append(c as MeshInstance3D)
	return out


func _split_lr(meshes: Array, prefix: String) -> Dictionary:
	var out := {"L": [], "R": []}
	for mesh in meshes:
		if not (mesh is MeshInstance3D):
			continue
		var mi := mesh as MeshInstance3D
		for tag in PackedStringArray(["L", "R"]):
			var keep_left: bool = str(tag) == "L"
			var h := VehicleCommon.split_mesh_by_x(mi, wrap, keep_left, 0.02)
			if h == null:
				continue
			h.name = "%s%s" % [prefix, tag]
			wrap.add_child(h)
			h.global_transform = mi.global_transform
			out[tag].append(h)
		mi.visible = false
	return out


func _bind_surfaces_and_nozzles() -> void:
	for obj in VehicleCommon.find_named(wrap, "^aileron_l"):
		if obj is Node3D:
			var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
			surfaces.append(VehicleHinge.mount(wrap, obj as Node3D, Vector3(a["cx"], a["cy"], a["minZ"] + 0.04), "x", 1.0, 0.42, "aileronL"))
	for obj in VehicleCommon.find_named(wrap, "^aileron_r"):
		if obj is Node3D:
			var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
			surfaces.append(VehicleHinge.mount(wrap, obj as Node3D, Vector3(a["cx"], a["cy"], a["minZ"] + 0.04), "x", 1.0, 0.42, "aileronR"))

	var elev_meshes: Array = []
	var upper_noz: Array = []
	var lower_noz: Array = []
	var el := VehicleCommon.first_named(wrap, "^elevator_l")
	if el:
		for m in _collect_meshes(el):
			var a := VehicleCommon.aabb_in(wrap, m)
			var x_span: float = a["maxX"] - a["minX"]
			var z_span: float = a["maxZ"] - a["minZ"]
			if z_span < 2.2 and x_span < 3.4:
				upper_noz.append(m)
			else:
				elev_meshes.append(m)
	var er := VehicleCommon.first_named(wrap, "^elevator_r")
	if er:
		for m in _collect_meshes(er):
			lower_noz.append(m)
	for mesh in elev_meshes:
		var a := VehicleCommon.aabb_in(wrap, mesh)
		if a["minX"] < -0.35 and a["maxX"] > 0.35:
			for tag in PackedStringArray(["L", "R"]):
				var h := VehicleCommon.split_mesh_by_x(mesh, wrap, tag == "L", 0.0)
				if h == null:
					continue
				h.name = "elev%s" % tag
				wrap.add_child(h)
				h.global_transform = mesh.global_transform
				var aa := VehicleCommon.aabb_in(wrap, h)
				surfaces.append(VehicleHinge.mount(wrap, h, Vector3(aa["cx"], aa["cy"], (aa["minZ"] + aa["maxZ"]) * 0.5), "x", 1.0, 0.38, "elevator"))
			mesh.visible = false
		else:
			surfaces.append(VehicleHinge.mount(wrap, mesh, Vector3(a["cx"], a["cy"], (a["minZ"] + a["maxZ"]) * 0.5), "x", 1.0, 0.38, "elevator"))

	var up: Dictionary = _split_lr(upper_noz, "NU")
	var lo: Dictionary = _split_lr(lower_noz, "NL")
	for tag in PackedStringArray(["L", "R"]):
		var tops: Array = up[tag]
		var bots: Array = lo[tag]
		if tops.is_empty() and bots.is_empty():
			continue
		var box := AABB()
		var any := false
		for m in tops + bots:
			var wa := VehicleCommon.world_aabb(m)
			var mn := wrap.to_local(wa.position)
			var mx := wrap.to_local(wa.position + wa.size)
			var a2 := AABB(Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z)), (mx - mn).abs())
			if not any:
				box = a2
				any = true
			else:
				box = box.merge(a2)
		var cx := box.position.x + box.size.x * 0.5
		var mid_y := box.position.y + box.size.y * 0.5
		var z0 := box.position.z
		var z1 := box.position.z + box.size.z
		var hinge_z := z0 + (z1 - z0) * 0.08
		var throat_z := z0 + (z1 - z0) * 0.28
		var exit_z := z1
		var top_bind: VehicleHinge = null
		var bot_bind: VehicleHinge = null
		if tops.size():
			var tb := AABB()
			var tany := false
			for m in tops:
				var wa := VehicleCommon.world_aabb(m)
				var mn := wrap.to_local(wa.position)
				var mx := wrap.to_local(wa.position + wa.size)
				var a2 := AABB(Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z)), (mx - mn).abs())
				if not tany:
					tb = a2
					tany = true
				else:
					tb = tb.merge(a2)
			var extras: Array = tops.slice(1)
			top_bind = VehicleHinge.mount(
				wrap, tops[0], Vector3(cx, tb.position.y + 0.02, hinge_z), "x", 1.0, 0.50,
				"nozzleLT" if tag == "L" else "nozzleRT", extras)
		if bots.size():
			var tb := AABB()
			var tany := false
			for m in bots:
				var wa := VehicleCommon.world_aabb(m)
				var mn := wrap.to_local(wa.position)
				var mx := wrap.to_local(wa.position + wa.size)
				var a2 := AABB(Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z)), (mx - mn).abs())
				if not tany:
					tb = a2
					tany = true
				else:
					tb = tb.merge(a2)
			var extras: Array = bots.slice(1)
			bot_bind = VehicleHinge.mount(
				wrap, bots[0], Vector3(cx, tb.position.y + tb.size.y - 0.02, hinge_z), "x", 1.0, 0.50,
				"nozzleLB" if tag == "L" else "nozzleRB", extras)
		var top: VehicleHinge = top_bind if top_bind else bot_bind
		var bot: VehicleHinge = bot_bind if bot_bind else top_bind
		var aim := Node3D.new()
		aim.name = "NozzleAim_%s" % tag
		wrap.add_child(aim)
		aim.position = Vector3(cx, mid_y, throat_z)
		if top_bind:
			surfaces.append(top_bind)
		if bot_bind and bot_bind != top_bind:
			surfaces.append(bot_bind)
		nozzle_engines.append({"top": top, "bot": bot, "aim": aim, "exit_z": exit_z, "throat_z": throat_z})
	if nozzle_engines.is_empty():
		var src = er if er else el
		if src is Node3D:
			var a := VehicleCommon.aabb_in(wrap, src as Node3D)
			surfaces.append(VehicleHinge.mount(wrap, src as Node3D, Vector3(a["cx"], a["cy"], a["minZ"] + 0.04), "x", 1.0, 0.40, "nozzle"))
	for obj in VehicleCommon.find_named(wrap, "^rudder"):
		if not (obj is Node3D):
			continue
		var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
		var left: bool = a["cx"] < 0.0
		var line := _fin_hinge_line(wrap, obj as Node3D, a)
		surfaces.append(VehicleHinge.mount_canted(wrap, obj as Node3D, line[0], line[1], 1.0, 0.48, "rudderL" if left else "rudderR"))
	for obj in VehicleCommon.find_named(wrap, "^wingflap_"):
		if obj is Node3D:
			var a := VehicleCommon.aabb_in(wrap, obj as Node3D)
			var line := _flap_hinge_line(wrap, obj as Node3D, a)
			var axis_dir: Vector3 = line[1] - line[0]
			if axis_dir.length_squared() < 1e-8:
				axis_dir = Vector3.RIGHT
			else:
				axis_dir = axis_dir.normalized()
			# Align hub +X with the wing-TE / flap leading-edge hinge so
			# rotation coincides with the wing instead of an AABB axis.
			var pre := Quaternion(Vector3.RIGHT, axis_dir)
			surfaces.append(VehicleHinge.mount(wrap, obj as Node3D, line[0], "x", 1.0, 0.36, "flap", [], wrap, pre))


func _bind_canopy() -> void:
	var parts: Array = []
	for n in VehicleCommon.find_named(wrap, "^door_dside_f"):
		parts.append(n)
	for n in VehicleCommon.find_named(wrap, "^window_lf"):
		parts.append(n)
	if parts.is_empty():
		return
	var box := AABB()
	var any := false
	for p in parts:
		if not (p is Node3D):
			continue
		var wa := VehicleCommon.world_aabb(p as Node3D)
		var mn := wrap.to_local(wa.position)
		var mx := wrap.to_local(wa.position + wa.size)
		var a2 := AABB(Vector3(minf(mn.x, mx.x), minf(mn.y, mx.y), minf(mn.z, mx.z)), (mx - mn).abs())
		if not any:
			box = a2
			any = true
		else:
			box = box.merge(a2)
	var main: Node3D = parts[0] as Node3D
	var extras: Array = parts.slice(1)
	var hinge := Vector3(box.position.x + box.size.x * 0.5, box.position.y + box.size.y - 0.04, box.position.z + box.size.z - 0.08)
	doors.append(VehicleHinge.mount(wrap, main, hinge, "x", 1.0, 1.12, "canopy", extras))


func _attach_exhausts() -> void:
	for eng in nozzle_engines:
		var fx := _make_exhaust((eng["aim"] as Node3D), Vector3(0.0, 0.02, -0.28))
		exhausts.append(fx)
	if exhausts.is_empty():
		for s in surfaces:
			var h := s as VehicleHinge
			if h.kind == "nozzleL" or h.kind == "nozzleR" or h.kind == "nozzle":
				exhausts.append(_make_exhaust(h.obj, Vector3(0.0, 0.02, -0.28)))
				break


func _make_exhaust(hub: Node3D, pos: Vector3) -> JetExhaust:
	var fx := JetExhaust.new()
	hub.add_child(fx)
	fx.position = pos
	return fx


func _measure_hud_frame() -> Dictionary:
	## Find the thin centerline combiner / HUD box in front of the stick.
	## Called before lift_origin(); Y is still in pre-lift wrap space.
	var best: Dictionary = {}
	var best_score := -1.0e9
	for mi in VehicleCommon.mesh_instances(wrap):
		var a := VehicleCommon.aabb_in(wrap, mi)
		if a.get("empty", false):
			continue
		var s: Vector3 = a["max"] - a["min"]
		# Thin plate on the centerline, in front of the seat, above the dash.
		if absf(float(a["cx"])) > 0.20:
			continue
		if s.z > 0.08 or s.z < 0.004:
			continue
		if s.x < 0.08 or s.x > 0.50:
			continue
		if s.y < 0.05 or s.y > 0.35:
			continue
		if float(a["cz"]) > -4.6 or float(a["cz"]) < -7.2:
			continue
		if float(a["cy"]) < 2.6:  # pre-lift: combiner sits well above the floor
			continue
		var score := (0.20 - absf(float(a["cx"]))) * 4.0 + (0.08 - s.z) * 8.0 + s.x
		if score > best_score:
			best_score = score
			best = {"x": 0.0, "y": float(a["cy"]), "z": float(a["cz"]), "sx": s.x, "sy": s.y, "sz": s.z}
	return best


func _measure_cockpit() -> Dictionary:
	var x := 0.0
	var y := 2.58
	var z := -6.05
	var stick := VehicleCommon.first_named(wrap, "steeringwheel")
	var stick_z := z
	if stick is Node3D:
		var a := VehicleCommon.aabb_in(wrap, stick as Node3D)
		# Fallback height / station from the stick if the HUD frame is missing.
		y = a["cy"] + 0.20
		z = a["cz"] + 0.40
		stick_z = float(a["cz"])
	var hud := _measure_hud_frame()
	if not hud.is_empty():
		# 0.2.28 glued the eye to the thin combiner (Object_36) AABB origin,
		# which sits below the visible HUD box / pipper. Use the visual
		# center of the frame: a little above the combiner origin, still
		# well below the old too-high 1.983 seat, then sit slightly aft
		# so the look origin is in the middle of the box (boresight).
		var sy := float(hud.get("sy", 0.10))
		y = float(hud["y"]) + sy * 0.20 + 0.10
		z = float(hud["z"]) + 0.66
	var canopy := VehicleCommon.first_named(wrap, "^door_dside_f")
	if canopy == null:
		canopy = VehicleCommon.first_named(wrap, "^window_lf")
	if canopy is Node3D:
		var a := VehicleCommon.aabb_in(wrap, canopy as Node3D)
		y = clampf(y, a["minY"] + (a["maxY"] - a["minY"]) * 0.28, a["maxY"] - 0.16)
		z = clampf(z, a["minZ"] + 0.7, a["maxZ"] - 0.45)
	# Aircraft centerline (wrap X = 0). The stick is offset to the right;
	# leaving a fraction of that offset made the HUD sit off the view center.
	# Y is measured before lift_origin, so subtract ORIGIN_Y to get body space.
	return {"x": 0.0, "y": y - ORIGIN_Y, "z": z}


## Scales nozzle petal travel. 0.2.29 used 0.35; 0.2.30 raises this so idle
## is more closed and afterburner is more open, without changing the curve,
## pivots, or thrust-vectoring linkage.
const PETAL_GAP_SCALE := 0.62


static func petal_gap(thrust: float) -> float:
	## >0 opens the petal (accelerate / afterburner); <0 contracts (decelerate).
	## Applied angle is petal_gap(thrust) * PETAL_GAP_SCALE (see apply_pose).
	var u := clampf(thrust, 0.0, 1.0)
	if u >= 0.8:
		# Last segment of the thrust lever = afterburner, extra open.
		return 0.38 + (u - 0.8) / 0.2 * 0.28
	if u >= 0.4:
		return (u - 0.4) / 0.4 * 0.38
	# Idle / decelerate: petals close.
	return lerpf(-0.28, 0.0, u / 0.4)


func _mount_stick_pivot(stick: Node3D) -> Dictionary:
	## 操纵杆网格原点往往不在底座，直接改 quaternion 会把杆身甩出座舱。
	## 在杆的长轴底端建一个铰链，只做小幅度俯仰/滚转，不再平移。
	var box := AABB()
	var any := false
	var xform_to := stick.global_transform.affine_inverse()
	for n in stick.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.mesh.get_surface_count() < 1:
			continue
		var arr := mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var xf := xform_to * mi.global_transform
		var step := maxi(1, verts.size() / 280)
		var i := 0
		while i < verts.size():
			var p: Vector3 = xf * verts[i]
			if not any:
				box = AABB(p, Vector3.ZERO)
				any = true
			else:
				box = box.expand(p)
			i += step
	if not any:
		box = AABB(Vector3.ZERO, Vector3(0.02, 0.08, 0.02))
	var size := box.size
	var axis := "y"
	if size.x >= size.y and size.x >= size.z:
		axis = "x"
	elif size.z >= size.x and size.z >= size.y:
		axis = "z"
	# 底座取长轴更靠近机身下方 / 后方的一端（局部 y 更小，其次 z 更大/靠后）。
	var base_local := box.get_center()
	if axis == "y":
		base_local.y = box.position.y
	elif axis == "x":
		base_local.x = box.position.x if absf(box.position.x) < absf(box.position.x + box.size.x) else box.position.x + box.size.x
	else:
		base_local.z = box.position.z + box.size.z
	var pivot := Node3D.new()
	pivot.name = "StickPivot"
	var parent := stick.get_parent()
	var stick_xf := stick.global_transform
	if parent:
		parent.add_child(pivot)
	else:
		wrap.add_child(pivot)
	pivot.global_position = stick.to_global(base_local)
	pivot.global_basis = stick.global_basis
	VehicleCommon.reparent_keep_global(stick, pivot)
	stick.global_transform = stick_xf
	return {
		"obj": stick,
		"pivot": pivot,
		"rest": pivot.quaternion,
		"axis": axis,
		"base": base_local,
	}


func stick_in_cockpit(max_offset: float = 0.08) -> bool:
	if steer_wheel.is_empty():
		return false
	var sw: Node3D = steer_wheel.get("obj")
	var pivot: Node3D = steer_wheel.get("pivot")
	if sw == null or not is_instance_valid(sw):
		return false
	# 杆身仍应靠近铰链，不能飞出模型。
	var origin: Vector3 = pivot.global_position if pivot else sw.global_position
	var box := VehicleCommon.aabb_in(wrap, sw)
	var cx := Vector3(float(box["cx"]), float(box["cy"]), float(box["cz"]))
	var world_c := wrap.to_global(cx) if wrap else cx
	return origin.distance_to(world_c) <= max_offset + 0.25


func apply_pose(st: Dictionary, delta: float, time: float, altitude: float = 0.0) -> void:
	if not ready_ok:
		return
	var gear_down := float(st.get("gear", 1.0))
	var steer_angle := float(st.get("steer_angle", 0.0))
	var wheel_spin := float(st.get("wheel_spin", 0.0))
	var susp: Array = st.get("susp", [0.4, 0.4, 0.4, 0.4])
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var hinge: Node3D = w["root"]
		var spin_n: Node3D = w["spin"] if w.has("spin") else hinge
		var in_bay := gear_down < 0.18
		hinge.visible = not in_bay
		if in_bay:
			hinge.position = w["rest_pos"]
			hinge.quaternion = w["rest_quat"]
			if spin_n != hinge:
				spin_n.quaternion = Quaternion.IDENTITY
			continue
		var sag := ((float(susp[i]) if i < susp.size() else 0.4) - 0.4) if gear_down > 0.35 else 0.0
		hinge.position = w["rest_pos"] + Vector3(0.0, sag * 0.2, 0.0)
		hinge.quaternion = w["rest_quat"]
		if w["steer"] and gear_down > 0.4:
			hinge.rotate_object_local(Vector3.UP, steer_angle * 0.9)
		var spin_a: float = wheel_spin * float(w["spin_sign"])
		if spin_n != hinge:
			spin_n.quaternion = Quaternion(Vector3.RIGHT, spin_a)
		else:
			spin_n.rotate_object_local(Vector3.RIGHT, spin_a)
	var door_t := float(st.get("door", 0.0))
	for d in doors:
		(d as VehicleHinge).apply(door_t)
	var gear_up := 1.0 - gear_down
	for g in gears:
		(g as VehicleHinge).apply(gear_up)
	# The glb rest pose hangs the doors open (vertical). apply(1) rotates them
	# ~90° to lie flush with the belly. Close when the gear is up (and keep
	# them open while the legs travel, and when down and locked, so the struts
	# are clear of the covers).
	var door_closed := _smoothstep(0.55, 1.0, gear_up)
	for g in gear_doors:
		(g as VehicleHinge).apply(door_closed)
	var pitch_c := clampf(float(st.get("ctrl_pitch", 0.0)), -1.0, 1.0)
	var roll_c := clampf(float(st.get("ctrl_roll", 0.0)), -1.0, 1.0)
	var yaw_c := clampf(float(st.get("ctrl_yaw", steer_angle * 1.6)), -1.0, 1.0)
	var thrust := float(st.get("thrust", 0.0))
	# Petal gap opens with thrust (afterburner is the last segment); contracts when decelerating.
	var gap := petal_gap(thrust) * PETAL_GAP_SCALE
	# W/S pitch vectors both nozzles together; A/D adds differential vectoring.
	# pitch_c > 0 = nose up (S / stick back). Trailing edge up is negative X rotation.
	var vec_l := -pitch_c * 0.95 + roll_c * 0.92
	var vec_r := -pitch_c * 0.95 - roll_c * 0.92
	var brake := clampf(float(st.get("speed_brake", 0.0)), 0.0, 1.0)
	var decelerating := bool(st.get("decelerating", false)) or brake > 0.15 or thrust < 0.32
	for s in surfaces:
		var h := s as VehicleHinge
		var tv := 0.0
		match h.kind:
			"aileronL":
				# Roll left (A, roll_c < 0): left aileron trailing-edge up (tv < 0).
				tv = roll_c
			"aileronR":
				tv = -roll_c
			"elevator":
				# Nose up (S, pitch_c > 0): elevator trailing-edge up.
				tv = -pitch_c
			"nozzle":
				tv = -pitch_c * 0.95
			"nozzleL":
				tv = vec_l
			"nozzleR":
				tv = vec_r
			"nozzleLT":
				tv = vec_l - gap
			"nozzleLB":
				tv = vec_l + gap
			"nozzleRT":
				tv = vec_r - gap
			"nozzleRB":
				tv = vec_r + gap
			"rudder":
				tv = yaw_c
			"rudderL":
				tv = yaw_c + brake * 0.72
			"rudderR":
				tv = yaw_c - brake * 0.72
			"flap":
				# Deploy only at low speed or while decelerating; always
				# retract once above climb-out speed (even at idle thrust).
				var speed := float(st.get("speed", 0.0))
				var slowing := bool(st.get("decelerating", false)) or brake > 0.15
				var want := flap_want(speed, slowing)
				flap_t += (want - flap_t) * (1.0 - exp(-3.4 * delta))
				tv = flap_t
			_:
				tv = 0.0
		# Animate to the target instead of snapping in one frame.
		# Flaps already ease via flap_t; still run the same follow so a
		# one-frame apply cannot jump.
		var sid := "%s_%s" % [h.kind, h.obj.name if h.obj else str(h)]
		var cur := float(_surf_t.get(sid, 0.0))
		cur += (tv - cur) * (1.0 - exp(-9.0 * maxf(delta, 1e-5)))
		_surf_t[sid] = cur
		h.apply(cur)
	for eng in nozzle_engines:
		var top: VehicleHinge = eng["top"]
		var bot: VehicleHinge = eng["bot"]
		var aim: Node3D = eng["aim"]
		var tx := top.obj.position.x
		var ty := top.obj.position.y
		var bx := bot.obj.position.x
		var by := bot.obj.position.y
		aim.position = Vector3((tx + bx) * 0.5, (ty + by) * 0.5, float(eng["throat_z"]))
		aim.quaternion = top.obj.quaternion.slerp(bot.obj.quaternion, 0.5)
	if not steer_wheel.is_empty():
		# 小幅度角度跟随俯仰/滚转输入，只转铰链，不把杆平移出座舱。
		const STICK_PITCH := 0.18  # ≈10°
		const STICK_ROLL := 0.16
		var e := Vector3(-pitch_c * STICK_PITCH, yaw_c * 0.06, roll_c * STICK_ROLL)
		var target: Node3D = steer_wheel["pivot"] if steer_wheel.get("pivot") else steer_wheel["obj"]
		if target:
			target.quaternion = steer_wheel["rest"] * Quaternion.from_euler(e)
	for fx in exhausts:
		(fx as JetExhaust).apply(thrust, time, altitude, delta)
	if vapor:
		vapor.update(st, delta)


## Auto-flap speeds (m/s). 72 ≈ 140 kt (fighter flap speed); 95 ≈ 185 kt
## modest climb-out, well below cruise. Always retract at/above retract speed.
const FLAP_EXTEND_SPEED := 72.0
const FLAP_RETRACT_SPEED := 95.0
const FLAP_DEPLOY := 0.88


static func flap_want(speed: float, decelerating: bool) -> float:
	## 1. High speed: always retract.
	## 2. Low speed: extend.
	## 3. Between: extend only while decelerating.
	if speed >= FLAP_RETRACT_SPEED:
		return 0.0
	if speed <= FLAP_EXTEND_SPEED or decelerating:
		return FLAP_DEPLOY
	return 0.0


func flap_hinge_info() -> Array:
	## For tests: wrap-space hinge origin, axis (hub +X), and the flap
	## leading-edge midline so we can check coincidence with the wing TE.
	var out: Array = []
	if wrap == null:
		return out
	for h in surfaces:
		if h == null or h.kind != "flap" or h.obj == null:
			continue
		var hub: Node3D = h.obj
		var origin := wrap.to_local(hub.global_position)
		var axis := (wrap.global_transform.basis.inverse() * hub.global_transform.basis.x).normalized()
		var pts: Array[Vector3] = _mesh_points_in(wrap, hub)
		var le := Vector3.ZERO
		var le_n := 0
		if pts.size() > 0:
			pts.sort_custom(func(p, q): return p.z < q.z)
			var take := maxi(1, mini(24, pts.size() / 8))
			for i in take:
				le += pts[i]
				le_n += 1
		if le_n > 0:
			le /= float(le_n)
		# Perpendicular distance from the leading-edge sample to the hinge axis.
		var rel := le - origin
		var axis_off := (rel - axis * rel.dot(axis)).length() if axis.length_squared() > 1e-8 else rel.length()
		out.append({
			"hub": hub,
			"origin": origin,
			"axis": axis,
			"leading": le,
			"axis_offset": axis_off,
			"t": flap_t,
		})
	return out


func _flap_hinge_line(wrap_n: Node3D, obj: Node3D, a: Dictionary) -> Array:
	## Hinge follows the flap leading edge (the wing trailing edge), including
	## sweep, instead of a constant-Z AABB pivot that left a gap / intersection.
	var pts: Array[Vector3] = _mesh_points_in(wrap_n, obj)
	var p0 := Vector3.ZERO
	var p1 := Vector3.ZERO
	if pts.size() >= 8:
		pts.sort_custom(func(p, q): return p.x < q.x)
		var lo_x: float = pts[0].x
		var hi_x: float = pts[pts.size() - 1].x
		var span := maxf(hi_x - lo_x, 0.05)
		var lo := _flap_leading_in_x_band(pts, lo_x, lo_x + span * 0.18)
		var hi := _flap_leading_in_x_band(pts, hi_x - span * 0.18, hi_x)
		var chord: float = float(a.get("maxZ", lo.z + 1.0)) - float(a.get("minZ", lo.z))
		# Small aft inset (+Z) from the sharp LE so the pivot sits on the
		# wing-TE attachment without opening a gap. Keep it tight (2–4 cm).
		var inset := Vector3(0.0, 0.0, clampf(chord * 0.03, 0.02, 0.04))
		p0 = lo + inset
		p1 = hi + inset
	else:
		var z := float(a["minZ"]) + 0.03
		p0 = Vector3(float(a["minX"]) + 0.04, float(a["cy"]), z)
		p1 = Vector3(float(a["maxX"]) - 0.04, float(a["cy"]), z)
	# Axis points toward +X so both wings keep sign 1.0 (trailing edge down).
	if p1.x < p0.x:
		var tmp := p0
		p0 = p1
		p1 = tmp
	return [p0, p1]


func _flap_leading_in_x_band(pts: Array[Vector3], x0: float, x1: float) -> Vector3:
	var band: Array[Vector3] = []
	for p in pts:
		if p.x >= x0 and p.x <= x1:
			band.append(p)
	if band.is_empty():
		return pts[0]
	band.sort_custom(func(p, q): return p.z < q.z)
	var n := mini(10, band.size())
	var acc := Vector3.ZERO
	for i in n:
		acc += band[i]
	return acc / float(n)


func _fin_hinge_line(wrap_n: Node3D, obj: Node3D, a: Dictionary) -> Array:
	## Hinge line follows the fin leading edge (cant + sweep), not world +Y.
	var pts: Array[Vector3] = _mesh_points_in(wrap_n, obj)
	if pts.size() >= 8:
		pts.sort_custom(func(p, q): return p.y < q.y)
		var lo_y: float = pts[0].y
		var hi_y: float = pts[pts.size() - 1].y
		var span := maxf(hi_y - lo_y, 0.05)
		var lo := _leading_in_band(pts, lo_y, lo_y + span * 0.18)
		var hi := _leading_in_band(pts, hi_y - span * 0.18, hi_y)
		# Inset a little from the sharp leading edge into the panel.
		var chord: float = float(a.get("maxZ", lo.z + 1.0)) - float(a.get("minZ", lo.z))
		var inset := Vector3(0.0, 0.0, maxf(chord * 0.08, 0.04))
		return [lo + inset, hi + inset]
	# AABB fallback: use inboard-root and outboard-tip at each end's front.
	var left: bool = float(a["cx"]) < 0.0
	var in_x: float = float(a["maxX"]) - 0.04 if left else float(a["minX"]) + 0.04
	var out_x: float = float(a["minX"]) + 0.04 if left else float(a["maxX"]) - 0.04
	var root_z: float = float(a["minZ"]) + (float(a["maxZ"]) - float(a["minZ"])) * 0.55
	var tip_z: float = float(a["minZ"]) + (float(a["maxZ"]) - float(a["minZ"])) * 0.08
	return [Vector3(in_x, float(a["minY"]) + 0.14, root_z), Vector3(out_x, float(a["maxY"]) - 0.05, tip_z)]


func _leading_in_band(pts: Array[Vector3], y0: float, y1: float) -> Vector3:
	var band: Array[Vector3] = []
	for p in pts:
		if p.y >= y0 and p.y <= y1:
			band.append(p)
	if band.is_empty():
		return pts[0]
	band.sort_custom(func(p, q): return p.z < q.z)
	var n := mini(10, band.size())
	var acc := Vector3.ZERO
	for i in n:
		acc += band[i]
	return acc / float(n)


func _mesh_points_in(wrap_n: Node3D, n: Node3D) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var nodes: Array = n.find_children("*", "MeshInstance3D", true, false)
	if n is MeshInstance3D:
		nodes.append(n)
	var seen := {}
	for x in nodes:
		if not (x is MeshInstance3D):
			continue
		var mi := x as MeshInstance3D
		if mi.mesh == null or seen.has(mi.get_instance_id()):
			continue
		seen[mi.get_instance_id()] = true
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var xf := wrap_n.global_transform.affine_inverse() * mi.global_transform
			var step := maxi(1, verts.size() / 400)
			var i := 0
			while i < verts.size():
				out.append(xf * verts[i])
				i += step
	return out


func _smoothstep(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / maxf(e1 - e0, 1e-5), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func wheel_rig_info() -> Array:
	var out: Array = []
	for w in wheels:
		var hinge: Node3D = w["root"]
		var spin: Node3D = w["spin"] if w.has("spin") else hinge
		out.append({
			"steer": hinge,
			"spin": spin,
			"parent_ok": spin.get_parent() == hinge,
			"kingpin": hinge.global_transform.basis.y.normalized(),
			"axle": spin.global_transform.basis.x.normalized(),
			"is_steer": bool(w["steer"]),
		})
	return out


func wheel_layout() -> Array:
	var out: Array = []
	for w in wheels:
		var off: Vector3 = w["offset"]
		out.append({"x": off.x, "y": off.y, "z": off.z, "steer": w["steer"]})
	return out
