extends Node3D
## Fighter visual rig ported from rouchangmoniqi3 vehicles.tsx preparePlane
## and the per-frame surface / nozzle / gear update. Physics is owned by
## plane_controller.gd; this node only binds and poses the model.
class_name PlaneVisuals

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
		steer_wheel = {"obj": steer, "rest": (steer as Node3D).quaternion, "axis": VehicleCommon.local_thin_axis(steer as Node3D)}
	VehicleCommon.make_glass(wrap, "window_lf|door_dside_f", 0.1)
	_attach_exhausts()
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
		if n.get_parent() and str(n.get_parent().name).begins_with("WheelHub"):
			continue
		if n.name.ends_with("_hub") or n.name.contains("Hub"):
			continue
		var world_pos := n.global_position
		var a := VehicleCommon.world_aabb(n)
		var axle := "x" if a.size.x <= a.size.z else "z"
		var sx := n.global_transform.basis.get_scale().x
		var spin_sign := signf(sx) if sx != 0.0 else 1.0
		var hub := Node3D.new()
		hub.name = "WheelHub_%s" % n.name
		wrap.add_child(hub)
		hub.global_position = world_pos
		hub.quaternion = Quaternion.IDENTITY
		hub.scale = Vector3.ONE
		VehicleCommon.reparent_keep_global(n, hub)
		var off := hub.position
		var steer := off.z < 0.0
		out.append({
			"root": hub, "rest_pos": off, "rest_quat": hub.quaternion,
			"steer": steer, "axle": axle, "spin_sign": spin_sign, "offset": off,
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
				surfaces.append(VehicleHinge.mount(wrap, h, Vector3(aa["cx"], aa["cy"], aa["minZ"] + 0.06), "x", 1.0, 0.38, "elevator"))
			mesh.visible = false
		else:
			surfaces.append(VehicleHinge.mount(wrap, mesh, Vector3(a["cx"], a["cy"], a["minZ"] + 0.06), "x", 1.0, 0.38, "elevator"))

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
			surfaces.append(VehicleHinge.mount(wrap, obj as Node3D, Vector3(a["cx"], a["cy"], a["minZ"] + 0.05), "x", 1.0, 0.36, "flap"))


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


func _measure_cockpit() -> Dictionary:
	var x := 0.0
	var y := 2.58
	var z := -6.05
	var stick := VehicleCommon.first_named(wrap, "steeringwheel")
	if stick is Node3D:
		var a := VehicleCommon.aabb_in(wrap, stick as Node3D)
		x = a["cx"] * 0.2
		y = a["cy"] + 0.42
		z = a["cz"] + 0.4
	var canopy := VehicleCommon.first_named(wrap, "^door_dside_f")
	if canopy == null:
		canopy = VehicleCommon.first_named(wrap, "^window_lf")
	if canopy is Node3D:
		var a := VehicleCommon.aabb_in(wrap, canopy as Node3D)
		y = clampf(y, a["minY"] + (a["maxY"] - a["minY"]) * 0.42, a["maxY"] - 0.16)
		z = clampf(z, a["minZ"] + 0.7, a["maxZ"] - 0.45)
	return {"x": x, "y": y - ORIGIN_Y + 0.16, "z": z}


static func petal_gap(thrust: float) -> float:
	## >0 opens the petal (accelerate / afterburner); <0 contracts (decelerate).
	var u := clampf(thrust, 0.0, 1.0)
	if u >= 0.8:
		# Last segment of the thrust lever = afterburner, extra open.
		return 0.38 + (u - 0.8) / 0.2 * 0.28
	if u >= 0.4:
		return (u - 0.4) / 0.4 * 0.38
	# Idle / decelerate: petals close.
	return lerpf(-0.28, 0.0, u / 0.4)


func apply_pose(st: Dictionary, delta: float, time: float, altitude: float = 0.0) -> void:
	if not ready_ok:
		return
	var gear_down := float(st.get("gear", 1.0))
	var steer_angle := float(st.get("steer_angle", 0.0))
	var wheel_spin := float(st.get("wheel_spin", 0.0))
	var susp: Array = st.get("susp", [0.4, 0.4, 0.4, 0.4])
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var hub: Node3D = w["root"]
		var in_bay := gear_down < 0.18
		hub.visible = not in_bay
		if in_bay:
			hub.position = w["rest_pos"]
			hub.quaternion = w["rest_quat"]
			continue
		var sag := ((float(susp[i]) if i < susp.size() else 0.4) - 0.4) if gear_down > 0.35 else 0.0
		hub.position = w["rest_pos"] + Vector3(0.0, sag * 0.2, 0.0)
		hub.quaternion = w["rest_quat"]
		if w["steer"] and gear_down > 0.4:
			hub.rotate_y(steer_angle * 0.9)
		var spin: float = wheel_spin * float(w["spin_sign"])
		if w["axle"] == "z":
			hub.rotate_z(spin)
		else:
			hub.rotate_x(spin)
	var door_t := float(st.get("door", 0.0))
	for d in doors:
		(d as VehicleHinge).apply(door_t)
	var gear_up := 1.0 - gear_down
	for g in gears:
		(g as VehicleHinge).apply(gear_up)
	# 1 - smoothstep(0.55, 1, gearUp)
	var door_close := 1.0 - _smoothstep(0.55, 1.0, gear_up)
	for g in gear_doors:
		(g as VehicleHinge).apply(door_close)
	var pitch_c := clampf(float(st.get("ctrl_pitch", 0.0)), -1.0, 1.0)
	var roll_c := clampf(float(st.get("ctrl_roll", 0.0)), -1.0, 1.0)
	var yaw_c := clampf(float(st.get("ctrl_yaw", steer_angle * 1.6)), -1.0, 1.0)
	var thrust := float(st.get("thrust", 0.0))
	# Petal gap opens with thrust (afterburner is the last segment); contracts when decelerating.
	var gap := petal_gap(thrust) * 0.35
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
				# Decelerate: flaps deploy. Accelerate / high thrust: retract.
				var want := 0.88 if decelerating else 0.0
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
		var sw: Node3D = steer_wheel["obj"]
		var e := Vector3(-pitch_c * 0.22, 0.0, roll_c * 0.2)
		sw.quaternion = steer_wheel["rest"] * Quaternion.from_euler(e)
	for fx in exhausts:
		(fx as JetExhaust).apply(thrust, time, altitude)


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


func wheel_layout() -> Array:
	var out: Array = []
	for w in wheels:
		var off: Vector3 = w["offset"]
		out.append({"x": off.x, "y": off.y, "z": off.z, "steer": w["steer"]})
	return out
