extends Node3D
## 漂移烧胎印：按车轮接触点铺一条贴地的黑色轨迹带（成熟的 racing ribbon /
## decal-stamp 思路）。每个驱动轮一条环形缓冲，打滑时扩展，离开后淡出回收。
class_name CarSkidMarks

const POINTS := 48
const MIN_STEP := 0.28
const WIDTH := 0.22
const SLIP_ON := 3.8  # m/s of lateral slip to start marking
const FADE_TIME := 6.5

var _tex: Texture2D
var _trails: Array = []  # {mesh, hist, alphas, verts, cols, uvs, idx, emitting}


func setup() -> void:
	name = "SkidMarks"
	top_level = true
	global_transform = Transform3D.IDENTITY
	_tex = _make_tex()
	for i in 4:
		_trails.append(_make_trail("Skid_%d" % i))


func _make_tex() -> Texture2D:
	var img := Image.create(32, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 32:
			var u := (float(x) + 0.5) / 32.0
			var v := (float(y) + 0.5) / 8.0
			var across := 1.0 - pow(absf(u * 2.0 - 1.0), 1.6)
			var along := 0.75 + 0.25 * sin(v * TAU * 3.0)
			var a := clampf(across * along, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.05, 0.05, 0.05, a))
	return ImageTexture.create_from_image(img)


func _make_trail(nm: String) -> Dictionary:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_color = Color(0.04, 0.04, 0.045, 1.0)
	sm.albedo_texture = _tex
	sm.roughness = 1.0
	sm.metallic = 0.0
	sm.vertex_color_use_as_albedo = true
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	# Sit a little above the pavement; no z-fight with the road.
	sm.no_depth_test = false
	mi.material_override = sm
	mi.visible = false
	add_child(mi)
	var idx := PackedInt32Array()
	for i in POINTS - 1:
		var a := i * 2
		idx.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	return {
		"mesh": mi,
		"hist": [],
		"sides": [],
		"alphas": [],
		"idx": idx,
		"emitting": false,
	}


func update(wheels: Array, delta: float) -> void:
	## wheels: array of {pos: Vector3, normal: Vector3, slip: float, contact: bool}
	global_transform = Transform3D.IDENTITY
	for i in _trails.size():
		var tr: Dictionary = _trails[i]
		var w: Dictionary = wheels[i] if i < wheels.size() else {}
		var contact := bool(w.get("contact", false))
		var slip := float(w.get("slip", 0.0))
		var pos: Vector3 = w.get("pos", Vector3.ZERO)
		var nrm: Vector3 = w.get("normal", Vector3.UP)
		if nrm.length_squared() < 1e-6:
			nrm = Vector3.UP
		else:
			nrm = nrm.normalized()
		var emit := contact and slip >= SLIP_ON
		tr["emitting"] = emit
		if emit:
			pos += nrm * 0.018
			var hist: Array = tr["hist"]
			var sides: Array = tr["sides"]
			var alphas: Array = tr["alphas"]
			var side := nrm.cross(Vector3(0, 0, 1))
			if w.has("side"):
				side = w["side"]
			if side.length_squared() < 1e-6:
				side = nrm.cross(Vector3.FORWARD)
			if side.length_squared() < 1e-6:
				side = Vector3.RIGHT
			else:
				side = side.normalized()
			var strength := clampf((slip - SLIP_ON) / 8.0, 0.25, 1.0)
			if hist.is_empty() or hist[0].distance_to(pos) >= MIN_STEP:
				hist.insert(0, pos)
				sides.insert(0, side)
				alphas.insert(0, strength)
				if hist.size() > POINTS:
					hist.pop_back()
					sides.pop_back()
					alphas.pop_back()
			else:
				hist[0] = pos
				sides[0] = side
				alphas[0] = maxf(float(alphas[0]), strength)
		# Fade all stamps.
		var alphas2: Array = tr["alphas"]
		var hist2: Array = tr["hist"]
		var sides2: Array = tr["sides"]
		var di := 0
		while di < alphas2.size():
			alphas2[di] = float(alphas2[di]) - delta / FADE_TIME
			if float(alphas2[di]) <= 0.02:
				alphas2.remove_at(di)
				hist2.remove_at(di)
				sides2.remove_at(di)
			else:
				di += 1
		_rebuild(tr)


func _rebuild(tr: Dictionary) -> void:
	var hist: Array = tr["hist"]
	var sides: Array = tr["sides"]
	var alphas: Array = tr["alphas"]
	var mi: MeshInstance3D = tr["mesh"]
	var h := hist.size()
	mi.visible = h >= 2
	if h < 2:
		return
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(POINTS * 2)
	cols.resize(POINTS * 2)
	uvs.resize(POINTS * 2)
	for i in POINTS:
		var ii := mini(i, h - 1)
		var p: Vector3 = hist[ii]
		var side: Vector3 = sides[ii] if ii < sides.size() else Vector3.RIGHT
		var a: float = float(alphas[ii]) if ii < alphas.size() else 0.0
		if i >= h:
			a = 0.0
		var o := i * 2
		verts[o] = p - side * WIDTH
		verts[o + 1] = p + side * WIDTH
		var col := Color(1, 1, 1, clampf(a, 0.0, 1.0))
		cols[o] = col
		cols[o + 1] = col
		var v := float(i) / float(maxi(POINTS - 1, 1))
		uvs[o] = Vector2(0.0, v)
		uvs[o + 1] = Vector2(1.0, v)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = tr["idx"]
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mi.mesh = am


func active_count() -> int:
	var n := 0
	for tr in _trails:
		if (tr["mesh"] as MeshInstance3D).visible:
			n += 1
	return n
