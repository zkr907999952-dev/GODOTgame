extends RefCounted
## 拳交手臂 / 刺刀 / 长刺刀 网格与伤口贴图（网页 prepareArm / prepareBayonet / loadWoundAtlas 的移植）。
## 结果静态缓存：本体和所有分身共用同一份网格 / 材质 / 贴图。

const ARM_GLB := "res://assets/props/arm.glb"
const BAYONET_GLB := "res://assets/props/bayonet.glb"
const BAYONET_LONG_GLB := "res://assets/props/bayonet-long.glb"
const WOUND_TEX := "res://assets/props/wounds.webp"

static var _cache: Dictionary = {}


static func _first_mesh(path: String) -> Array:
	var ps := load(path) as PackedScene
	if ps == null:
		return []
	var root := ps.instantiate()
	var out: Array = []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# 累计到场景根的变换（实例不在场景树里）
		var xf := mi.transform
		var p := mi.get_parent()
		while p != null and p != root:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		out = [mi.mesh, xf]
		break
	root.free()
	return out


## 网页 prepareArm：拳头端（顶部 8%）放到原点，手臂残端朝 -Y，长 0.38m。
static func arm_mesh() -> Mesh:
	if _cache.has("arm"):
		return _cache["arm"]
	var src := _first_mesh(ARM_GLB)
	if src.is_empty():
		return null
	var mesh: Mesh = src[0]
	var xf: Transform3D = src[1]
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i] = xf * v[i]
	var ymin := INF
	var ymax := -INF
	for p in v:
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	var span := maxf(1e-4, ymax - ymin)
	var fist := Vector3.ZERO
	var fn := 0
	var stump := Vector3.ZERO
	var sn := 0
	for p in v:
		if p.y > ymax - span * 0.08:
			fist += p
			fn += 1
		if p.y < ymin + span * 0.08:
			stump += p
			sn += 1
	fist /= maxf(1.0, fn)
	stump /= maxf(1.0, sn)
	var axis := (stump - fist)
	if axis.length_squared() < 1e-8:
		axis = Vector3.DOWN
	var q := Quaternion(axis.normalized(), Vector3.DOWN)
	var scl := 0.38 / maxf(1e-4, (stump - fist).length())
	for i in v.size():
		v[i] = (q * (v[i] - fist)) * scl
	arr[Mesh.ARRAY_VERTEX] = v
	if arr[Mesh.ARRAY_NORMAL] != null:
		var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in nr.size():
			nr[i] = (q * (xf.basis * nr[i])).normalized()
		arr[Mesh.ARRAY_NORMAL] = nr
	arr[Mesh.ARRAY_TANGENT] = null
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#c9947a")
	mat.roughness = 0.52
	mat.metallic = 0.02
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	am.surface_set_material(0, mat)
	_cache["arm"] = am
	return am


## 网页 prepareBayonet：最长轴为刀身，刀尖（顶点较稀的一端）朝 +Y，刀柄端在原点，总长 total；
## 再绕 Y 把刃口转到 +Z（rollEdgeToZ），配合 blade_xform 让刃口朝下。
static func bayonet_mesh(long: bool) -> Mesh:
	var key := "bayonet_long" if long else "bayonet"
	if _cache.has(key):
		return _cache[key]
	var src := _first_mesh(BAYONET_LONG_GLB if long else BAYONET_GLB)
	if src.is_empty():
		return null
	var mesh: Mesh = src[0]
	var xf: Transform3D = src[1]
	var total := 0.42 if long else 0.248
	# 所有 surface 的顶点一起算包围盒 / 方向
	var surfs: Array = []
	var allv := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = xf * v[i]
		arr[Mesh.ARRAY_VERTEX] = v
		surfs.append(arr)
		allv.append_array(v)
	var bb := AABB(allv[0], Vector3.ZERO)
	for p in allv:
		bb = bb.expand(p)
	var axis := 1 if (bb.size.y >= bb.size.x and bb.size.y >= bb.size.z) else (2 if bb.size.z >= bb.size.x else 0)
	var min_a := bb.position[axis]
	var max_a := bb.end[axis]
	var span := maxf(1e-4, max_a - min_a)
	var n_lo := 0
	var n_hi := 0
	for p in allv:
		if p[axis] <= min_a + span * 0.18:
			n_lo += 1
		if p[axis] >= max_a - span * 0.18:
			n_hi += 1
	var tip_at_max := n_hi < n_lo
	var mid := func(t: float) -> Vector3:
		var c := Vector3.ZERO
		var n := 0
		for p in allv:
			if absf(p[axis] - t) <= span * 0.06:
				c += p
				n += 1
		if n == 0:
			c = bb.get_center()
			c[axis] = t
			return c
		return c / float(n)
	var tip: Vector3 = mid.call(max_a if tip_at_max else min_a)
	var hdl: Vector3 = mid.call(min_a if tip_at_max else max_a)
	var dirv := tip - hdl
	if dirv.length_squared() < 1e-10:
		dirv = Vector3.UP
	var q := Quaternion(dirv.normalized(), Vector3.UP)
	var scl := total / maxf(1e-4, dirv.length())
	var tv := PackedVector3Array()
	for arr in surfs:
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = (q * (v[i] - hdl)) * scl
		arr[Mesh.ARRAY_VERTEX] = v
		tv.append_array(v)
		if arr[Mesh.ARRAY_NORMAL] != null:
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			for i in nr.size():
				nr[i] = (q * (xf.basis * nr[i])).normalized()
			arr[Mesh.ARRAY_NORMAL] = nr
		arr[Mesh.ARRAY_TANGENT] = null
	# rollEdgeToZ：刀刃段（58%–92%）截面主轴转到 X，刃口（较宽的一侧）朝 +Z
	var mx := 0.0
	var mz := 0.0
	var cnt := 0
	for p in tv:
		if p.y >= total * 0.58 and p.y <= total * 0.92:
			mx += p.x
			mz += p.z
			cnt += 1
	var rot := 0.0
	if cnt >= 12:
		mx /= cnt
		mz /= cnt
		var cxx := 0.0
		var czz := 0.0
		var cxz := 0.0
		for p in tv:
			if p.y >= total * 0.58 and p.y <= total * 0.92:
				cxx += (p.x - mx) * (p.x - mx)
				czz += (p.z - mz) * (p.z - mz)
				cxz += (p.x - mx) * (p.z - mz)
		rot = PI * 0.5 - 0.5 * atan2(2.0 * cxz, cxx - czz)
	var am := ArrayMesh.new()
	var rb := Basis(Vector3.UP, -rot)
	for s in surfs.size():
		var arr: Array = surfs[s]
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] = rb * v[i]
		arr[Mesh.ARRAY_VERTEX] = v
		if arr[Mesh.ARRAY_NORMAL] != null:
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			for i in nr.size():
				nr[i] = rb * nr[i]
			arr[Mesh.ARRAY_NORMAL] = nr
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var m := mesh.surface_get_material(s)
		var bm := (m.duplicate() as BaseMaterial3D) if m is BaseMaterial3D else StandardMaterial3D.new()
		bm.metallic = maxf(bm.metallic, 0.35)
		bm.roughness = minf(bm.roughness, 0.45)
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		am.surface_set_material(s, bm)
	_cache[key] = am
	return am


## 网页 loadWoundAtlas：2×2 伤口图集，按亮度生成 alpha，边缘 + 径向渐隐。返回 4 张贴图。
## 预烘焙的 4 张伤口贴图（256×256，带 alpha 渐隐）。t27u：原来首次命中时用 GDScript 逐像素生成
## 4×256×256 像素（桌面约 115 ms，手机上近 1 秒卡顿，正好落在散弹枪特写入体那一帧），改为直接加载。
const WOUND_TILE_PATHS := [
	"res://assets/props/wound_tile_0.png",
	"res://assets/props/wound_tile_1.png",
	"res://assets/props/wound_tile_2.png",
	"res://assets/props/wound_tile_3.png",
]


static func wound_tiles() -> Array:
	if _cache.has("wounds"):
		return _cache["wounds"]
	var baked: Array = []
	for path in WOUND_TILE_PATHS:
		var t := load(path) as Texture2D if ResourceLoader.exists(path) else null
		if t == null:
			baked.clear()
			break
		baked.append(t)
	if baked.size() == WOUND_TILE_PATHS.size():
		_cache["wounds"] = baked
		return baked
	return _bake_wound_tiles()


## 回退/重新烘焙用：从 wounds.webp 切 4 块并做 alpha 渐隐。
static func _bake_wound_tiles() -> Array:
	var out: Array = []
	var tex := load(WOUND_TEX) as Texture2D
	var img: Image = tex.get_image() if tex else null
	if img == null:
		img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.55, 0.05, 0.04, 1.0))
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var tw0 := img.get_width() / 2
	var th0 := img.get_height() / 2
	var tw := 256
	var th := 256
	for ty in 2:
		for tx in 2:
			var t := img.get_region(Rect2i(tx * tw0, ty * th0, tw0, th0))
			t.resize(256, 256, Image.INTERPOLATE_BILINEAR)
			var pad_x := maxf(8.0, tw * 0.2)
			var pad_y := maxf(8.0, th * 0.2)
			for y in th:
				for x in tw:
					var c := t.get_pixel(x, y)
					var m := maxf(c.r, maxf(c.g, c.b)) * 255.0
					var a := 0.0 if m < 10.0 else (((m - 10.0) / 30.0) if m < 40.0 else 1.0)
					var fx := clampf(minf(x, tw - 1 - x) / pad_x, 0.0, 1.0)
					var fy := clampf(minf(y, th - 1 - y) / pad_y, 0.0, 1.0)
					var r := Vector2((x + 0.5) / tw - 0.5, (y + 0.5) / th - 0.5).length() * 2.05
					var rad := clampf(1.0 - (r - 0.32) / 0.46, 0.0, 1.0)
					a *= smoothstep(0.0, 1.0, fx) * smoothstep(0.0, 1.0, fy) * rad * rad * (3.0 - 2.0 * rad)
					c.a = a
					t.set_pixel(x, y, c)
			t.generate_mipmaps()
			out.append(ImageTexture.create_from_image(t))
	_cache["wounds"] = out
	return out
