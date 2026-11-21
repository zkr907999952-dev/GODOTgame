extends Node
## 0.3.8「显示碰撞」：给场景里每个 CollisionShape3D 挂一个半透明覆盖网格（类似编辑器 Debug → Visible Collision Shapes）。
## 导出包里引擎自带的调试碰撞显示不可用，所以这里自己生成网格：
##  - 盒 / 球 / 胶囊 / 圆柱：半透明实体 + 线框；
##  - 凸包、三角网（地图）、高度图等：只画引擎生成的线框（get_debug_mesh），大地图不叠加半透明面，避免过度绘制。
## 颜色：角色胶囊 / 命中箱橙色，刚体（布娃娃 / 载具）绿色，Area 紫色，静态 / 其他青色。
## 关闭时全部释放；打开期间新加入场景的碰撞体（子弹壳、分身、地图）自动补上。

const OVERLAY_META := "collision_debug_overlay"
const TICK := 0.25
## 单个三角网线框超过这么多面就跳过（极端大地图仍保持可用帧率），并计入 skipped_shapes。
const MAX_TRIMESH_FACES := 400000

var enabled: bool = false
var skipped_shapes: int = 0
var _overlays: Dictionary = {}  # CollisionShape3D instance id -> {"cs": cs, "node": Node3D, "shape": Shape3D}
var _mats: Dictionary = {}
var _tick: float = 0.0
var _debug_mesh_cache: Dictionary = {}  # Shape3D instance id -> Mesh（共享的地图形状只生成一次线框）


func _ready() -> void:
	set_process(false)


func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	var tree := get_tree()
	if on:
		skipped_shapes = 0
		if tree and not tree.node_added.is_connected(_on_node_added):
			tree.node_added.connect(_on_node_added)
		if tree:
			for n in tree.root.find_children("*", "CollisionShape3D", true, false):
				_attach(n as CollisionShape3D)
		set_process(true)
	else:
		if tree and tree.node_added.is_connected(_on_node_added):
			tree.node_added.disconnect(_on_node_added)
		for id in _overlays.keys():
			var e: Dictionary = _overlays[id]
			var nd: Node = e["node"]
			if is_instance_valid(nd):
				nd.queue_free()
		_overlays.clear()
		_debug_mesh_cache.clear()
		set_process(false)


func overlay_count() -> int:
	var n := 0
	for id in _overlays.keys():
		if is_instance_valid((_overlays[id] as Dictionary)["node"]):
			n += 1
	return n


func has_overlay_for(cs: CollisionShape3D) -> bool:
	return cs != null and _overlays.has(cs.get_instance_id()) and is_instance_valid((_overlays[cs.get_instance_id()] as Dictionary)["node"])


func _on_node_added(n: Node) -> void:
	if n is CollisionShape3D:
		_attach.call_deferred(n)


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = TICK
	for id in _overlays.keys():
		var e: Dictionary = _overlays[id]
		var cs: CollisionShape3D = e["cs"] if is_instance_valid(e["cs"]) else null
		var nd: Node3D = e["node"] if is_instance_valid(e["node"]) else null
		if cs == null or nd == null:
			if nd:
				nd.queue_free()
			_overlays.erase(id)
			continue
		if cs.shape != e["shape"]:
			nd.queue_free()
			_overlays.erase(id)
			_attach(cs)
			continue
		var on := not cs.disabled
		var body := cs.get_parent() as CollisionObject3D
		if body and body.collision_layer == 0 and not (body is Area3D):
			on = false
		if nd.visible != on:
			nd.visible = on


func _attach(cs: CollisionShape3D) -> void:
	if not enabled or cs == null or not is_instance_valid(cs) or not cs.is_inside_tree():
		return
	if cs.shape == null or _overlays.has(cs.get_instance_id()):
		return
	var shape := cs.shape
	var col := _color_for(cs)
	var holder := Node3D.new()
	holder.name = "CollisionDebug"
	holder.set_meta(OVERLAY_META, true)
	var fill := _fill_mesh(shape)
	if fill:
		holder.add_child(_mi(fill, _mat(col, false)))
	var lines := _line_mesh(shape)
	if lines:
		holder.add_child(_mi(lines, _mat(col, true)))
	if holder.get_child_count() == 0:
		holder.free()
		return
	cs.add_child(holder, false, Node.INTERNAL_MODE_BACK)
	_overlays[cs.get_instance_id()] = {"cs": cs, "node": holder, "shape": shape}
	if shape.has_signal("changed") and not shape.changed.is_connected(_on_shape_changed.bind(cs)):
		shape.changed.connect(_on_shape_changed.bind(cs), CONNECT_ONE_SHOT)


func _on_shape_changed(cs: CollisionShape3D) -> void:
	if not enabled or not is_instance_valid(cs):
		return
	var id := cs.get_instance_id()
	if _overlays.has(id):
		var nd: Node = (_overlays[id] as Dictionary)["node"]
		if is_instance_valid(nd):
			nd.queue_free()
		_overlays.erase(id)
	_debug_mesh_cache.erase(cs.shape.get_instance_id() if cs.shape else 0)
	_attach.call_deferred(cs)


func _mi(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _fill_mesh(shape: Shape3D) -> Mesh:
	if shape is BoxShape3D:
		var b := BoxMesh.new()
		b.size = (shape as BoxShape3D).size
		return b
	if shape is SphereShape3D:
		var s := SphereMesh.new()
		s.radius = (shape as SphereShape3D).radius
		s.height = s.radius * 2.0
		s.radial_segments = 16
		s.rings = 8
		return s
	if shape is CapsuleShape3D:
		var c := CapsuleMesh.new()
		c.radius = (shape as CapsuleShape3D).radius
		c.height = (shape as CapsuleShape3D).height
		c.radial_segments = 16
		c.rings = 4
		return c
	if shape is CylinderShape3D:
		var y := CylinderMesh.new()
		y.top_radius = (shape as CylinderShape3D).radius
		y.bottom_radius = y.top_radius
		y.height = (shape as CylinderShape3D).height
		y.radial_segments = 16
		return y
	return null


func _line_mesh(shape: Shape3D) -> Mesh:
	if shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces().size() / 3
		if faces > MAX_TRIMESH_FACES:
			skipped_shapes += 1
			return null
	var sid := shape.get_instance_id()
	if _debug_mesh_cache.has(sid):
		return _debug_mesh_cache[sid]
	var m: Mesh = shape.get_debug_mesh()
	_debug_mesh_cache[sid] = m
	return m


func _color_for(cs: CollisionShape3D) -> Color:
	var body := cs.get_parent()
	if body is Area3D:
		return Color(0.75, 0.35, 1.0)
	if body and (body.is_in_group("character_hitbox") or body is CharacterBody3D or body.name == "BodyHit"):
		return Color(1.0, 0.55, 0.1)
	if body is RigidBody3D or body is PhysicalBone3D or body is VehicleBody3D:
		return Color(0.3, 1.0, 0.4)
	return Color(0.2, 0.8, 1.0)


func _mat(col: Color, lines: bool) -> StandardMaterial3D:
	var key := "%s|%s" % [col.to_html(), lines]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	m.albedo_color = Color(col.r, col.g, col.b, 0.85 if lines else 0.18)
	m.vertex_color_use_as_albedo = false
	m.render_priority = 1 if lines else 0
	_mats[key] = m
	return m
