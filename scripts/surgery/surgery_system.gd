extends Node
## 手术模式：检查床上进入 / 退出，腹腔、手绘切口、层状腹壁、可剥离皮瓣。
## 伤口来自真实网格切割，不用旧贴图 / Decal。
class_name SurgerySystem

const Geom := preload("res://scripts/surgery/surgery_geom.gd")
const SCALPEL_GLB := "res://assets/surgery/scalpel.glb"
const WALL_THICKNESS := 0.012
const SLIT_WIDTH := 0.0025
const OVAL_RX := 0.035
const OVAL_RY := 0.028
const WALL_MAX_SEGMENTS := Geom.WALL_MAX_SEGMENTS
const BULLET_SIDES := Geom.BULLET_SIDES
const EVERT_ROLL := 0.0085
const MAX_BULLET_HOLES := 6

signal mode_changed(active: bool)
signal tool_changed(tool: String)

var player: Node = null
var active: bool = false
var tool: String = ""  # "" | "scalpel" | "grab"  — 进入时无工具，可转视角
var thickness: float = WALL_THICKNESS
var cut_open: bool = false
var loop_ready: bool = false
var flap_peeled: bool = false
var lofted_tris: int = 0
var path_points: PackedVector3Array = PackedVector3Array()  # bind-space
var stroke_active: bool = false
var persist: bool = false
var flap_node: Node3D = null
var flap_kind: String = ""  # "softbody" | "verlet" | ""
var cavity_exposed: bool = false
var pose_locked: bool = false
var last_path_count: int = 0
const CATCH_LAYER := 8
const STROKE_MIN_SPACING := 0.0045

var _skel: Skeleton3D
var _skin: Skin
var _dress: MeshInstance3D
var _dress_mesh_orig: Mesh
var _organs: Node
var _navel_rest: Vector3 = Vector3(0.0, 1.060, 0.114)
var _outer: Geom.MeshData
var _inner: Geom.MeshData
var _rest: Geom.MeshData
var _surgical_mi: MeshInstance3D
var _cavity_mi: MeshInstance3D
var _wall_mi: MeshInstance3D
var _preview: MeshInstance3D
var _scalpel: MeshInstance3D
var _path_ids: PackedInt32Array = PackedInt32Array()
var _flap_loop: PackedInt32Array = PackedInt32Array()
var _body_loop: PackedInt32Array = PackedInt32Array()
var _loop_out: PackedInt32Array = PackedInt32Array()
var _loop_in: PackedInt32Array = PackedInt32Array()
var _wall_md: Geom.MeshData
var _posed_cache: PackedVector3Array = PackedVector3Array()
var _posed_dirty: bool = true
var _breath_amp_saved: float = -1.0
var _breath_enabled_saved: Variant = null
var _posed_frozen: PackedVector3Array = PackedVector3Array()
var _wrap: Geom.MeshData
var _flap_catch: StaticBody3D
var _guts_min: Vector3 = Vector3(-0.09, 0.956, 0.005)
var _guts_max: Vector3 = Vector3(0.078, 1.180, 0.102)
var _baked: bool = false
var _verified_dress: bool = false
var _dress_name: String = ""
var _skin_name: String = ""
var _trail_bind: PackedVector3Array = PackedVector3Array()
var _cavity_xraying: bool = false
var _wall_shader_mat: ShaderMaterial
var _cavity_shader_mat: ShaderMaterial
var _trail_mat: ShaderMaterial
var _evert: float = 0.0
var _evert_vel: float = 0.0
var _evert_anim: bool = false
var _lip_left: PackedInt32Array = PackedInt32Array()
var _lip_right: PackedInt32Array = PackedInt32Array()
var _lip_left_i: PackedInt32Array = PackedInt32Array()
var _lip_right_i: PackedInt32Array = PackedInt32Array()
var _lip_closed: bool = false
var _hole_loops: Array = []
var _outer_rest: Geom.MeshData
var _inner_rest: Geom.MeshData
var _wall_rest: Geom.MeshData
var _outer_evert: Geom.MeshData
var _inner_evert: Geom.MeshData
var _wall_evert: Geom.MeshData
var _xray_cached: int = -1
var _grab_kind: String = ""
var _grab_active: bool = false
var _grab_anchor: Node3D
var _grab_last: Vector3 = Vector3.ZERO
var _grab_vel: Vector3 = Vector3.ZERO
var _flap_throw_speed: float = 0.0
var _split_drag: float = 0.0
var _pull_p: Vector3 = Vector3.ZERO
var _pull_off: Vector3 = Vector3.ZERO
var _pull_r: float = 0.0
var _pinned_points: PackedInt32Array = PackedInt32Array()
var bullet_holes: int = 0
var bullet_wall_tris: int = 0
var bullet_plugs_removed: int = 0
var last_dense_loft_tris: int = 0


func setup(p: Node, skel: Skeleton3D, organs: Node) -> void:
	player = p
	_skel = skel
	_organs = organs
	if organs and organs.get("meta") and (organs.meta as Dictionary).has("navel"):
		var n: Array = organs.meta["navel"]
		_navel_rest = Vector3(n[0], n[1], n[2])
	if organs and organs.get("meta"):
		var meta: Dictionary = organs.meta
		if meta.has("guts") and meta["guts"] is Dictionary:
			var g: Dictionary = meta["guts"]
			if g.has("min") and g.has("max"):
				var mn: Array = g["min"]
				var mx: Array = g["max"]
				if mn.size() >= 3 and mx.size() >= 3:
					_guts_min = Vector3(mn[0], mn[1], mn[2])
					_guts_max = Vector3(mx[0], mx[1], mx[2])
	_find_meshes()
	_make_trail()
	_make_scalpel()


func is_active() -> bool:
	return active


func current_tool() -> String:
	return tool


func has_tool() -> bool:
	return tool == "scalpel" or tool == "grab"


func look_locked() -> bool:
	return active and has_tool()


func look_enabled() -> bool:
	return active and not has_tool()


func tool_interaction_enabled() -> bool:
	return active and has_tool()


func has_incision_trail() -> bool:
	return _preview != null and _preview.visible and _trail_bind.size() >= 2


func incision_trail_point_count() -> int:
	return _trail_bind.size()


func incision_trail_visible_without_xray() -> bool:
	# 涂鸦不依赖透视；只要轨迹在且材质不是透视专用隐藏。
	if _preview == null or _trail_bind.size() < 2:
		return false
	return _preview.visible and _preview.mesh != null


func can_use_grab() -> bool:
	if flap_node and is_instance_valid(flap_node):
		return true
	return cut_open or loop_ready or flap_peeled


func wall_is_skinned() -> bool:
	if _wall_mi == null or _wall_mi.mesh == null or _wall_md == null:
		return false
	if _wall_mi.skin == null or _wall_mi.skeleton == NodePath():
		return false
	return _wall_md.bones.size() >= _wall_md.vert_count() * 4


func wall_shares_belly_deform() -> bool:
	var mat := _wall_mi.material_override if _wall_mi else null
	if not (mat is ShaderMaterial):
		return false
	var sh: Shader = (mat as ShaderMaterial).shader
	if sh == null:
		return false
	var code := sh.code
	return code.find("drag_offset") >= 0 and code.find("organ_common.gdshaderinc") >= 0


func wall_tri_budget() -> int:
	return Geom.wall_tri_budget()


func last_dense_wall_tris() -> int:
	return last_dense_loft_tris


func evert_amount() -> float:
	return _evert


func cut_is_everted() -> bool:
	return cut_open and _evert >= 0.55 and _outer_evert != null


func lip_opening_width() -> float:
	return _measure_lip_width(_outer_evert if _outer_evert else _outer)


func flap_throw_speed() -> float:
	return _flap_throw_speed


func flap_is_held() -> bool:
	return _grab_active and _grab_kind == "flap"


func split_skin_drag_offset() -> float:
	return _split_drag


func has_bullet_hole() -> bool:
	return bullet_holes > 0 and bullet_wall_tris > 0


func bullet_plug_removed() -> bool:
	return bullet_plugs_removed > 0


func abdomen_world_centroid() -> Vector3:
	if _outer != null and _outer.vert_count() > 0 and _skel:
		return _mesh_centroid_world(_outer)
	return _navel_world()


func body_marker_world() -> Dictionary:
	## 稳定标记：肚脐、腹网质心、髋骨，用于确认手术/切开后躯体没有被抬到上方。
	var navel := _navel_world()
	var hip := navel
	var spine := navel
	if _skel:
		var hi := _skel.find_bone("C_Hip_a")
		if hi >= 0:
			hip = _skel.global_transform * _skel.get_bone_global_pose(hi).origin
		var si := _skel.find_bone("C_Spine_a")
		if si >= 0:
			spine = _skel.global_transform * _skel.get_bone_global_pose(si).origin
	var body_o := Vector3.ZERO
	if player and player.has_node("Body"):
		body_o = (player.get_node("Body") as Node3D).global_position
	elif player:
		body_o = player.global_position
	return {
		"navel": navel,
		"abdomen": abdomen_world_centroid(),
		"hip": hip,
		"spine": spine,
		"body": body_o,
	}


func cavity_xray_is_transparent() -> bool:
	if _cavity_mi == null:
		return false
	_update_cavity_visibility()
	if not _xray_on():
		return false
	var mat := _cavity_mi.material_override
	if mat is ShaderMaterial:
		var xm := mat as ShaderMaterial
		var xr := float(xm.get_shader_parameter("xray"))
		var col: Color = xm.get_shader_parameter("albedo_color")
		return xr > 0.0 and col.a < 0.85
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		return (
			sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			and sm.albedo_color.a < 0.85
			and sm.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
		)
	return _cavity_xraying


func cavity_xray_alpha() -> float:
	if _cavity_mi == null:
		return 1.0
	_update_cavity_visibility()
	var mat := _cavity_mi.material_override
	if mat is ShaderMaterial:
		var col: Color = (mat as ShaderMaterial).get_shader_parameter("albedo_color")
		return col.a
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color.a
	return 1.0


func is_on_exam_bed() -> bool:
	return player != null and str(player.get("occupancy")) == "exam_bed"


func can_enter() -> bool:
	return is_on_exam_bed() and not active


func has_cavity() -> bool:
	return _cavity_mi != null and _inner != null and _inner.vert_count() > 0


func cavity_hidden_until_cut() -> bool:
	return not cut_open


func cavity_visible_in_xray() -> bool:
	if not has_cavity():
		return false
	return _cavity_mi.visible and _xray_on()


func has_lofted_wall() -> bool:
	return lofted_tris > 0 and _wall_md != null and _wall_md.face_count() > 0


func can_grab_flap() -> bool:
	return loop_ready and not flap_peeled


func has_persistent_state() -> bool:
	return persist and (cut_open or flap_peeled) and _surgical_mi != null


func flap_kind_shipped() -> String:
	return flap_kind


func is_pose_locked() -> bool:
	return pose_locked


func cavity_wraps_organs() -> bool:
	if _inner == null or _wrap == null or _wrap.face_count() < 1:
		return false
	var mn := Vector3(1e9, 1e9, 1e9)
	var mx := Vector3(-1e9, -1e9, -1e9)
	for md in [_inner, _wrap]:
		for p in md.pos:
			mn.x = minf(mn.x, p.x)
			mn.y = minf(mn.y, p.y)
			mn.z = minf(mn.z, p.z)
			mx.x = maxf(mx.x, p.x)
			mx.y = maxf(mx.y, p.y)
			mx.z = maxf(mx.z, p.z)
	var pad := 0.008
	return (
		mn.x <= _guts_min.x + pad and mx.x >= _guts_max.x - pad
		and mn.y <= _guts_min.y + pad and mx.y >= _guts_max.y - pad
		and mn.z <= _guts_min.z + pad and mx.z >= _guts_max.z - pad
	)


func wrap_face_count() -> int:
	return _wrap.face_count() if _wrap else 0


func flap_clear_of_bed(margin: float = 0.04) -> bool:
	if flap_node == null or not is_instance_valid(flap_node):
		return false
	var top := _catch_top_y()
	var mn := _flap_aabb_min()
	if mn.y < -900.0:
		return false
	# 允许皮瓣还在下落，但不得穿过床面太多。
	return mn.y >= top - margin


func _flap_aabb_min() -> Vector3:
	if flap_node == null or not is_instance_valid(flap_node):
		return Vector3(0, -999, 0)
	if flap_node is SoftBody3D:
		var mi := flap_node as SoftBody3D
		if mi.mesh:
			var ab := mi.mesh.get_aabb()
			return mi.global_transform * ab.position
	if flap_node is MeshInstance3D and (flap_node as MeshInstance3D).mesh:
		var ab2 := (flap_node as MeshInstance3D).mesh.get_aabb()
		return flap_node.global_transform * ab2.position
	# Verlet holder
	for c in flap_node.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh:
			var ab3 := (c as MeshInstance3D).mesh.get_aabb()
			return (c as MeshInstance3D).global_transform * ab3.position
	if flap_node is Node3D:
		return (flap_node as Node3D).global_position
	return Vector3(0, -999, 0)


func verified_abdomen_on_dress() -> bool:
	return _verified_dress


func dress_mesh_name() -> String:
	return _dress_name


func toggle() -> void:
	if active:
		exit_surgery()
	else:
		enter_surgery()


func enter_surgery() -> bool:
	if active:
		return true
	if not is_on_exam_bed():
		return false
	if not _bake_if_needed():
		push_warning("surgery: bake failed")
		return false
	active = true
	tool = ""
	path_points = PackedVector3Array()
	stroke_active = false
	_dampen_breath(true)
	_update_cavity_visibility()
	_show_scalpel(false)
	mode_changed.emit(true)
	tool_changed.emit(tool)
	return true


func exit_surgery() -> void:
	if not active:
		return
	active = false
	stroke_active = false
	path_points = PackedVector3Array()
	_show_scalpel(false)
	if not cut_open:
		_clear_trail()
	elif _trail_bind.size() >= 2:
		_update_trail()
	_lock_pose_for_stroke(false)
	_dampen_breath(false)
	if cut_open or flap_peeled:
		persist = true
	_update_cavity_visibility()
	mode_changed.emit(false)


func set_tool(t: String) -> void:
	# 再点已选工具则取消选择，恢复视角控制。
	if t == tool:
		if stroke_active:
			cancel_stroke()
		tool = ""
		_show_scalpel(false)
		tool_changed.emit(tool)
		return
	# 拿取与手术刀一样随时可切换，不必先切开或先剥皮瓣。
	if t != "" and t != "scalpel" and t != "grab":
		t = ""
	if stroke_active:
		cancel_stroke()
	tool = t
	if tool != "scalpel":
		_show_scalpel(false)
	tool_changed.emit(tool)


func begin_stroke(origin: Vector3, dir: Vector3) -> bool:
	if not active:
		return false
	if tool == "grab":
		return _begin_grab(origin, dir)
	if tool != "scalpel":
		return false
	_lock_pose_for_stroke(true)
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	if hit == null:
		_lock_pose_for_stroke(false)
		return false
	stroke_active = true
	path_points = PackedVector3Array()
	path_points.append((hit as Dictionary)["bind"])
	_place_scalpel(hit["point"], dir)
	_show_scalpel(true)
	_update_preview()
	return true


func drag_stroke(origin: Vector3, dir: Vector3) -> void:
	if tool == "grab" and _grab_active:
		_drag_grab(origin, dir)
		return
	if not stroke_active or tool != "scalpel":
		return
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	if hit == null:
		return
	var p: Vector3 = (hit as Dictionary)["bind"]
	if path_points.is_empty() or path_points[path_points.size() - 1].distance_to(p) >= STROKE_MIN_SPACING:
		path_points.append(p)
	_place_scalpel(hit["point"], dir)
	_update_preview()


func cancel_stroke() -> void:
	if _grab_active:
		_end_grab(false)
	if not stroke_active:
		return
	stroke_active = false
	_show_scalpel(false)
	path_points = PackedVector3Array()
	if not cut_open:
		_clear_trail()
	_lock_pose_for_stroke(false)


func end_stroke() -> void:
	if _grab_active:
		_end_grab(true)
		stroke_active = false
		return
	if not stroke_active:
		return
	stroke_active = false
	_show_scalpel(false)
	var kept := false
	if path_points.size() >= 2:
		var simple := Geom.simplify_path(path_points, 0.003, 48)
		last_path_count = simple.size()
		if _commit_path(simple):
			_trail_bind = simple
			_update_trail()
			kept = true
	if not kept and not cut_open:
		_clear_trail()
	elif not kept and _trail_bind.size() >= 2:
		_update_trail()
	path_points = PackedVector3Array()
	_lock_pose_for_stroke(false)


func debug_scripted_incision(closed: bool = true, rx: float = OVAL_RX, ry: float = OVAL_RY) -> bool:
	if not _bake_if_needed():
		return false
	var center := _navel_rest + Vector3(0.0, -0.02, 0.0)
	var path := Geom.oval_path_on_mesh(_outer, center, rx, ry, 20)
	if path.size() < 6:
		return false
	if not closed and path.size() > 3:
		# 开放路径：丢掉最后四分之一，不闭合。
		var keep := int(path.size() * 0.72)
		var open := PackedVector3Array()
		for i in keep:
			open.append(path[i])
		path = open
	else:
		path = Geom.clean_closed_loop(path)
	path = Geom.simplify_path(path, 0.0024, 56)
	last_path_count = path.size()
	return _commit_path(path, closed)


func try_peel_at(origin: Vector3, dir: Vector3) -> bool:
	if not can_grab_flap():
		return false
	# 点到腹部即可剥离（测试与游玩都不必精确点中皮瓣中心）。
	_refresh_posed()
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	if hit == null:
		# 仍然允许在拿取工具下直接剥离（闭环已确认）。
		return peel_flap()
	return peel_flap()


func peel_flap() -> bool:
	if not can_grab_flap() or _outer == null or _inner == null:
		return false
	# 张开后：内唇=_flap_loop 是皮瓣边，外唇=_body_loop 是留在身上的洞缘。
	var loop := _flap_loop if _flap_loop.size() >= 3 else _path_ids
	if loop.size() < 3:
		return false
	var ext_o: Dictionary = Geom.extract_inside(_outer, loop)
	var ext_i: Dictionary = Geom.extract_inside(_inner, loop)
	if int(ext_o.get("inside_faces", 0)) < 1 or int(ext_o.get("outside_faces", 0)) < 1:
		push_warning("surgery: flap isolation failed (inside=%s outside=%s)" % [ext_o.get("inside_faces"), ext_o.get("outside_faces")])
		return false
	var body_o: Geom.MeshData = ext_o["outside"]
	var flap_o: Geom.MeshData = ext_o["inside"]
	var body_i: Geom.MeshData = ext_i["outside"]
	var flap_i: Geom.MeshData = ext_i["inside"]
	var loop_body_o: PackedInt32Array = ext_o["loop_out"]
	var loop_body_i: PackedInt32Array = ext_i["loop_out"]
	var loop_flap_o: PackedInt32Array = ext_o["loop_in"]
	var loop_flap_i: PackedInt32Array = ext_i["loop_in"]
	if _body_loop.size() >= 3:
		loop_body_o = _ensure_loop_in_mesh(ext_o["outside"], _outer, _body_loop)
		loop_body_i = _ensure_loop_in_mesh(ext_i["outside"], _inner, _body_loop)
	# 身体：外剩余 + 内剩余 + 洞缘层状壁。
	var body := _merge_meshes(body_o, body_i)
	var wall_body := Geom.MeshData.new()
	# loft 要在同一 MeshData 里引用两端顶点，先把内外合并进 body，再对映射后的环做 loft。
	# _merge_meshes 把 b 的顶点追加到 a：body 当前 = body_o + body_i（索引已偏移）。
	# 上面那行已经 merge 了，所以要重新映射 inner loop。
	# 重做一次更清晰：
	body = body_o.clone()
	var inner_off := body.vert_count()
	_append_mesh(body, body_i)
	var map_i_loop := PackedInt32Array()
	for id in loop_body_i:
		map_i_loop.append(id + inner_off)
	var peel_wall := _make_loft_mesh(body_o, body_i, loop_body_o, loop_body_i, true)
	lofted_tris = peel_wall.face_count()
	_outer = body_o
	_inner = body_i
	_wall_md = peel_wall
	_lip_left = loop_body_o
	_lip_right = loop_body_o
	_lip_left_i = loop_body_i
	_lip_right_i = loop_body_i
	_lip_closed = true
	_hole_loops.append(loop_body_o)
	_start_eversion()
	_rebuild_surgical_meshes(body_o, body_i, peel_wall)
	# 皮瓣：外补丁 + 内补丁 + 周圈壁，转到世界空间后落地。
	var flap_md := flap_o.clone()
	var fo := flap_md.vert_count()
	_append_mesh(flap_md, flap_i)
	var flap_inner_loop := PackedInt32Array()
	for id2 in loop_flap_i:
		flap_inner_loop.append(id2 + fo)
	Geom.loft_wall(flap_md, loop_flap_o, flap_inner_loop, true)
	if not _spawn_flap(flap_md, flap_o):
		return false
	flap_peeled = true
	loop_ready = false
	cut_open = true
	cavity_exposed = true
	persist = true
	_update_cavity_visibility()
	return true


func _ensure_loop_in_mesh(dest: Geom.MeshData, src: Geom.MeshData, loop: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id in loop:
		if id < 0 or id >= src.vert_count():
			continue
		# 按位置在 dest 里找已有顶点，否则拷入。
		var p: Vector3 = src.pos[id]
		var found := -1
		var best := 1e-8
		for i in dest.vert_count():
			var s := dest.pos[i].distance_squared_to(p)
			if s <= best:
				best = s
				found = i
		if found >= 0:
			out.append(found)
		else:
			out.append(dest.copy_vert(src, id))
	return out


func _make_loft_mesh(outer: Geom.MeshData, inner: Geom.MeshData, loop_o: PackedInt32Array, loop_i: PackedInt32Array, closed: bool) -> Geom.MeshData:
	var cap := WALL_MAX_SEGMENTS
	var src_o := Geom.resample_index_loop(outer, loop_o, cap)
	var src_i := Geom.resample_index_loop(inner, loop_i, cap)
	var n := mini(src_o.size(), src_i.size())
	if src_o.size() != src_i.size() and n >= 2:
		src_o = Geom.resample_index_loop(outer, src_o, n)
		src_i = Geom.resample_index_loop(inner, src_i, n)
	var wall := Geom.MeshData.new()
	var map_o: Dictionary = {}
	var map_i: Dictionary = {}
	var ids_o := PackedInt32Array()
	var ids_i := PackedInt32Array()
	for id in src_o:
		if not map_o.has(id):
			map_o[id] = wall.copy_vert(outer, id)
		ids_o.append(int(map_o[id]))
	for id2 in src_i:
		if not map_i.has(id2):
			map_i[id2] = wall.copy_vert(inner, id2)
		ids_i.append(int(map_i[id2]))
	Geom.loft_wall(wall, ids_o, ids_i, closed)
	return wall


func _merge_meshes(a: Geom.MeshData, b: Geom.MeshData) -> Geom.MeshData:
	var m := a.clone()
	_append_mesh(m, b)
	return m


func _append_mesh(dest: Geom.MeshData, src: Geom.MeshData) -> int:
	var off := dest.vert_count()
	for i in src.vert_count():
		dest.copy_vert(src, i)
	for f in src.face_count():
		dest.add_face(src.idx[f * 3] + off, src.idx[f * 3 + 1] + off, src.idx[f * 3 + 2] + off)
	return off


func _commit_path(path: PackedVector3Array, force_closed: bool = false) -> bool:
	if _outer == null or _inner == null or path.size() < 2:
		return false
	var work := path.duplicate()
	var closed := force_closed or Geom.is_path_closed(work)
	if closed:
		work = Geom.clean_closed_loop(work)
	else:
		work = Geom.simplify_path(work, 0.003, 48)
	last_path_count = work.size()
	if closed and work.size() >= 2 and work[0].distance_to(work[work.size() - 1]) <= Geom.PATH_CLOSE_DIST:
		work.remove_at(work.size() - 1)
	var ids := Geom.embed_path_paired(_outer, _inner, work)
	if ids.size() < 2:
		push_warning("surgery: path embed failed")
		return false
	if closed:
		ids = Geom.close_path_ids(_outer, ids)
		Geom.sync_inner(_outer, _inner)
		if ids.size() >= 3 and ids[0] != ids[ids.size() - 1]:
			ids.append(ids[0])
	_path_ids = ids
	var wall: Geom.MeshData
	if closed:
		loop_ready = true
		# 先沿环做内外壁之间的层状截面；皮瓣仍留在身上，等拿取工具剥离。
		# 再把环缝微微张开，切开的皮肤有真实裂口。
		var slit_o: Dictionary = Geom.open_loop_slit(_outer, ids, SLIT_WIDTH)
		var slit_i: Dictionary = Geom.open_loop_slit(_inner, ids, SLIT_WIDTH)
		var left: PackedInt32Array = slit_o.get("left", ids)
		var right: PackedInt32Array = slit_o.get("right", ids)
		var left_i: PackedInt32Array = slit_i.get("left", ids)
		var right_i: PackedInt32Array = slit_i.get("right", ids)
		# 剥离仍用嵌入后、张开前的环（ids）；左右唇只用于可见截面。
		last_dense_loft_tris = Geom.dense_loft_tris(left.size(), true, 2)
		wall = _make_loft_mesh(_outer, _inner, left, left_i, true)
		var wall2 := _make_loft_mesh(_outer, _inner, right, right_i, true)
		_append_mesh(wall, wall2)
		_flap_loop = left
		_body_loop = right
		_lip_left = left
		_lip_right = right
		_lip_left_i = left_i
		_lip_right_i = right_i
		_lip_closed = true
		lofted_tris = wall.face_count()
	else:
		loop_ready = false
		_flap_loop = PackedInt32Array()
		var slit_o2: Dictionary = Geom.open_slit(_outer, ids, SLIT_WIDTH)
		var slit_i2: Dictionary = Geom.open_slit(_inner, ids, SLIT_WIDTH)
		var lo: PackedInt32Array = slit_o2.get("left", ids)
		var ro: PackedInt32Array = slit_o2.get("right", ids)
		var li: PackedInt32Array = slit_i2.get("left", ids)
		var ri: PackedInt32Array = slit_i2.get("right", ids)
		last_dense_loft_tris = Geom.dense_loft_tris(lo.size(), false, 2)
		wall = _make_loft_mesh(_outer, _inner, lo, li, false)
		var w2 := _make_loft_mesh(_outer, _inner, ro, ri, false)
		_append_mesh(wall, w2)
		_lip_left = lo
		_lip_right = ro
		_lip_left_i = li
		_lip_right_i = ri
		_lip_closed = false
		lofted_tris = wall.face_count()
	cut_open = true
	cavity_exposed = true
	persist = true
	_wall_md = wall
	_start_eversion()
	_rebuild_surgical_meshes(_outer, _inner, wall)
	_posed_dirty = true
	if path.size() >= 2:
		_trail_bind = path.duplicate()
		_update_trail()
	_update_cavity_visibility()
	return lofted_tris > 0


func _resync_inner_after_outer_connect() -> void:
	Geom.sync_inner(_outer, _inner)


func _find_meshes() -> void:
	if _skel == null:
		return
	var dress: MeshInstance3D = null
	var skin_mi: MeshInstance3D = null
	var dress_ymax := -1e9
	var skin_ymax := -1e9
	for n in _skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var low := mi.name.to_lower()
		if "hair" in low or "_007_" in mi.name or "_eye" in low or "mouth" in low or "head" in low or "charm" in low:
			continue
		if "dress" in low:
			dress = mi
			_dress_name = mi.name
			dress_ymax = _mesh_ymax(mi)
		elif "skin" in low:
			skin_mi = mi
			_skin_name = mi.name
			skin_ymax = _mesh_ymax(mi)
	_dress = dress
	if _dress:
		_dress_mesh_orig = _dress.mesh
		_skin = _dress.skin
	# 腹部必须在 Dress（上半身）上：Skin 的最高点应低于肚脐。
	_verified_dress = dress != null and (skin_mi == null or skin_ymax < _navel_rest.y - 0.05) and dress_ymax > _navel_rest.y
	if not _verified_dress:
		push_warning("surgery: abdomen host check failed dress=%s ymax=%.3f skin_ymax=%.3f navel.y=%.3f" % [_dress_name, dress_ymax, skin_ymax, _navel_rest.y])


func _mesh_ymax(mi: MeshInstance3D) -> float:
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var m := -1e9
	for p in v:
		if p.y > m:
			m = p.y
	return m


func _bake_if_needed() -> bool:
	if _baked and _outer != null and _surgical_mi != null:
		return true
	if _dress == null:
		_find_meshes()
	if _dress == null or _dress.mesh == null:
		return false
	if not _verified_dress:
		# 仍然尝试用 Dress，但记录校验结果。
		pass
	var extracted := Geom.extract_abdomen(_dress, _navel_rest, true)
	if not bool(extracted.get("ok", false)):
		return false
	_outer = extracted["abdomen"]
	_rest = extracted["rest"]
	var organ_z := _organ_front_z()
	_inner = Geom.make_cavity(_outer, thickness, organ_z)
	var back_z := minf(_guts_min.z - 0.010, organ_z - 0.08)
	_wrap = Geom.make_cavity_wrap(_inner, back_z)
	# 用去掉腹部的 Dress 替换原网格，避免与手术网格重叠。
	if _rest.face_count() > 0:
		_dress.mesh = _rest.to_array_mesh()
		# 保留蒙皮与已有透视材质。
		if _skin:
			_dress.skin = _skin
		_dress.skeleton = _dress.skeleton
	_surgical_mi = _make_skinned_mi("SurgicalAbdomen", _outer.to_array_mesh(), true)
	_cavity_mi = _make_skinned_mi("SurgicalCavity", _cavity_display_mesh(), false)
	_cavity_mi.material_override = _cavity_material()
	_wall_mi = _make_skinned_mi("SurgicalWall", ArrayMesh.new(), false)
	_wall_mi.material_override = _wall_material()
	if _preview:
		_parent_trail(_preview)
	if _trail_mat:
		_register_deform_mat(_trail_mat)
	_baked = true
	_posed_dirty = true
	_update_cavity_visibility()
	return true


func _organ_front_z() -> float:
	if _organs and _organs.get("meta"):
		var meta: Dictionary = _organs.meta
		if meta.has("guts") and meta["guts"] is Dictionary and meta["guts"].has("max"):
			var mx: Array = meta["guts"]["max"]
			if mx.size() >= 3:
				return float(mx[2])
	return _navel_rest.z - thickness


func _make_skinned_mi(nm: String, mesh: Mesh, use_skin_mat: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	if _skin:
		mi.skin = _skin
	_skel.add_child(mi)
	# 与身体共用骨骼空间：作为 Skeleton 子节点，skeleton 路径指向父。
	mi.skeleton = NodePath("..")
	if use_skin_mat and _dress:
		var mat := _dress.get_active_material(0)
		if mat:
			mi.material_override = mat
	mi.visible = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _rebuild_surgical_meshes(outer: Geom.MeshData, inner: Geom.MeshData, wall: Geom.MeshData) -> void:
	if _surgical_mi:
		_surgical_mi.mesh = _mesh_with_evert(outer, _outer_rest, _outer_evert)
		if _skin:
			_surgical_mi.skin = _skin
		_apply_evert_weight()
	if _cavity_mi:
		_cavity_mi.mesh = _cavity_display_mesh()
		if _skin:
			_cavity_mi.skin = _skin
	if _wall_mi and wall:
		_wall_mi.mesh = _mesh_with_evert(wall, _wall_rest, _wall_evert)
		if _skin:
			_wall_mi.skin = _skin
		_wall_mi.visible = wall.face_count() > 0
		_apply_evert_weight()
	_posed_dirty = true


func _cavity_display_mesh() -> ArrayMesh:
	if _inner == null:
		return ArrayMesh.new()
	var d := _inner.clone()
	var ev: Geom.MeshData = null
	if _inner_evert and _inner_rest and _inner_evert.vert_count() == _inner.vert_count() and _inner_rest.vert_count() == _inner.vert_count():
		ev = _inner_evert.clone()
		if _wrap and _wrap.face_count() > 0:
			_append_mesh(ev, _wrap)
	if _wrap and _wrap.face_count() > 0:
		_append_mesh(d, _wrap)
	if ev and ev.vert_count() == d.vert_count():
		return d.to_array_mesh_with_blend("evert", ev)
	return d.to_array_mesh()


func _cavity_material() -> Material:
	if _cavity_shader_mat == null:
		_cavity_shader_mat = _make_shell_material(Color(0.55, 0.18, 0.16, 1.0))
		_register_deform_mat(_cavity_shader_mat)
	return _cavity_shader_mat


func _wall_material() -> Material:
	if _wall_shader_mat == null:
		_wall_shader_mat = _make_shell_material(Color(0.72, 0.28, 0.26, 1.0))
		_register_deform_mat(_wall_shader_mat)
	return _wall_shader_mat


func _make_shell_material(col: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh: Shader = load("res://shaders/surgery_wall.gdshader")
	if sh:
		m.shader = sh
	m.set_shader_parameter("albedo_color", col)
	m.set_shader_parameter("roughness", 0.55)
	m.set_shader_parameter("metallic", 0.0)
	m.set_shader_parameter("xray", 0.0)
	return m


func _register_deform_mat(mat: ShaderMaterial) -> void:
	if mat == null or _organs == null:
		return
	if _organs.has_method("register_deform_material"):
		_organs.call("register_deform_material", mat, false)


func _apply_xray_shell(mat: Material, base: Color, xray: bool) -> void:
	if mat is ShaderMaterial:
		var xm := mat as ShaderMaterial
		xm.set_shader_parameter("albedo_color", Color(base.r, base.g, base.b, 0.32 if xray else 1.0))
		xm.set_shader_parameter("xray", 1.0 if xray else 0.0)
		return
	if not (mat is StandardMaterial3D):
		return
	var sm := mat as StandardMaterial3D
	if xray:
		# 透视时腹腔袋改为半透明且不写深度，否则会把袋里的内脏完全挡住。
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color = Color(base.r, base.g, base.b, 0.32)
		sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		sm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		sm.albedo_color = Color(base.r, base.g, base.b, 1.0)
		sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED


func _update_cavity_visibility() -> void:
	if _cavity_mi == null:
		return
	# 网格一直留在场景里，好让透视挖孔和切开后的裂口都能看到内壁。
	# 未切开且透视关闭时，完好的腹壁会挡住它（测试用 cavity_hidden_until_cut / cavity_visible_in_xray）。
	_cavity_mi.visible = true
	if _wall_mi:
		_wall_mi.visible = cut_open and lofted_tris > 0
	var xray := _xray_on()
	_cavity_xraying = xray
	_apply_xray_shell(_cavity_mi.material_override, Color(0.55, 0.18, 0.16), xray)
	if _wall_mi:
		_apply_xray_shell(_wall_mi.material_override, Color(0.72, 0.28, 0.26), xray)


func _xray_on() -> bool:
	if _organs == null:
		return false
	if _organs.has_method("effective_xray"):
		return float(_organs.call("effective_xray")) > 0.0
	return bool(_organs.get("xray_enabled"))


func _refresh_posed() -> void:
	if pose_locked:
		return
	_posed_dirty = true


func _posed_world() -> PackedVector3Array:
	if _outer == null:
		return PackedVector3Array()
	if pose_locked and _posed_frozen.size() == _outer.vert_count():
		return _posed_frozen
	if _posed_dirty or _posed_cache.size() != _outer.vert_count():
		_posed_cache = Geom.world_positions(_outer, _skel, _skin)
		_posed_dirty = false
	return _posed_cache


func _dampen_breath(on: bool) -> void:
	if player == null or not player.has_method("get_secondary"):
		return
	var sec: RefCounted = player.call("get_secondary")
	if sec == null:
		return
	if on:
		if _breath_amp_saved < 0.0:
			_breath_amp_saved = float(sec.get("breath_amp"))
		sec.set("breath_amp", _breath_amp_saved * 0.45)
	elif _breath_amp_saved >= 0.0 and not pose_locked:
		sec.set("breath_amp", _breath_amp_saved)
		_breath_amp_saved = -1.0


func _lock_pose_for_stroke(on: bool) -> void:
	if player == null or not player.has_method("get_secondary"):
		pose_locked = on
		return
	var sec: RefCounted = player.call("get_secondary")
	if on:
		if not pose_locked:
			if sec:
				if _breath_enabled_saved == null:
					_breath_enabled_saved = bool(sec.get("breath_enabled"))
				if _breath_amp_saved < 0.0:
					_breath_amp_saved = float(sec.get("breath_amp"))
				sec.set("breath_enabled", false)
				sec.set("breath_amp", 0.0)
			_posed_dirty = true
			_posed_cache = Geom.world_positions(_outer, _skel, _skin) if _outer else PackedVector3Array()
			_posed_frozen = _posed_cache.duplicate()
			_posed_dirty = false
		pose_locked = true
	else:
		pose_locked = false
		_posed_frozen = PackedVector3Array()
		if sec:
			if _breath_enabled_saved != null:
				sec.set("breath_enabled", bool(_breath_enabled_saved))
				_breath_enabled_saved = null
			# 手术中仍保持减弱呼吸；退出时由 _dampen_breath(false) 完全恢复。
			if active and _breath_amp_saved >= 0.0:
				sec.set("breath_amp", _breath_amp_saved * 0.45)
			elif _breath_amp_saved >= 0.0:
				sec.set("breath_amp", _breath_amp_saved)
		_posed_dirty = true


func _make_trail() -> void:
	_preview = MeshInstance3D.new()
	_preview.name = "IncisionTrail"
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview.sorting_offset = 0.02
	var mat := ShaderMaterial.new()
	var sh: Shader = load("res://shaders/incision_trail.gdshader")
	if sh:
		mat.shader = sh
		mat.render_priority = 1
		_trail_mat = mat
		_register_deform_mat(mat)
	else:
		var fb := StandardMaterial3D.new()
		fb.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		fb.albedo_color = Color(0.86, 0.1, 0.1, 0.85)
		fb.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fb.cull_mode = BaseMaterial3D.CULL_DISABLED
		fb.render_priority = 1
		_preview.material_override = fb
		_parent_trail(_preview)
		_preview.visible = false
		return
	_preview.material_override = mat
	_parent_trail(_preview)
	_preview.visible = false


func _update_preview() -> void:
	_trail_bind = path_points.duplicate()
	_update_trail()


func _update_trail() -> void:
	if _preview == null:
		return
	if _trail_bind.size() < 2 or _skel == null:
		_preview.visible = false
		return
	var mesh := _build_trail_mesh(_trail_bind)
	if mesh == null or mesh.get_surface_count() == 0:
		_preview.visible = false
		return
	_preview.mesh = mesh
	if _preview.get_parent() == _skel:
		_preview.transform = Transform3D.IDENTITY
		if _skin:
			_preview.skin = _skin
		_preview.skeleton = NodePath("..")
	else:
		_preview.global_transform = Transform3D.IDENTITY
	# 非透视下也保持可见：不受 xray 开关控制。
	_preview.visible = true


func _build_trail_mesh(bind_pts: PackedVector3Array) -> ArrayMesh:
	# 绑定空间条带，随 SurgicalAbdomen 一起蒙皮，不再每帧按世界坐标重建。
	var n := bind_pts.size()
	if n < 2:
		return ArrayMesh.new()
	var worlds: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var bone_at: Array = []
	var weight_at: Array = []
	worlds.resize(n)
	norms.resize(n)
	bone_at.resize(n)
	weight_at.resize(n)
	for i in n:
		var bn: Array = _approx_bind_and_normal(bind_pts[i])
		worlds[i] = bn[0]
		norms[i] = bn[1]
		bone_at[i] = bn[2]
		weight_at[i] = bn[3]
	var lengths: PackedFloat32Array = PackedFloat32Array()
	lengths.resize(n)
	lengths[0] = 0.0
	var total := 0.0
	for i in range(1, n):
		total += worlds[i].distance_to(worlds[i - 1])
		lengths[i] = total
	if total < 1e-6:
		total = 1.0
	var half := 0.0064
	var lift := 0.0018
	var md := Geom.MeshData.new()
	for i in range(n - 1):
		var t0 := worlds[i + 1] - worlds[i]
		if t0.length_squared() < 1e-10:
			continue
		t0 = t0.normalized()
		var t1 := t0
		if i + 2 < n:
			var nxt := worlds[i + 2] - worlds[i + 1]
			if nxt.length_squared() > 1e-10:
				t1 = nxt.normalized()
		var n0: Vector3 = norms[i]
		var n1: Vector3 = norms[i + 1]
		var s0 := n0.cross(t0)
		if s0.length_squared() < 1e-10:
			s0 = t0.cross(Vector3.UP)
		if s0.length_squared() < 1e-10:
			s0 = t0.cross(Vector3.RIGHT)
		s0 = s0.normalized() * half
		var s1 := n1.cross(t1)
		if s1.length_squared() < 1e-10:
			s1 = s0
		else:
			s1 = s1.normalized() * half
		var a: Vector3 = worlds[i] + n0 * lift - s0
		var b: Vector3 = worlds[i] + n0 * lift + s0
		var c: Vector3 = worlds[i + 1] + n1 * lift - s1
		var d: Vector3 = worlds[i + 1] + n1 * lift + s1
		var u0 := lengths[i] / total
		var u1 := lengths[i + 1] / total
		var ia := md.add_vert(a, n0, Vector2(u0, 0.0), bone_at[i], weight_at[i])
		var ib := md.add_vert(b, n0, Vector2(u0, 1.0), bone_at[i], weight_at[i])
		var idv := md.add_vert(d, n1, Vector2(u1, 1.0), bone_at[i + 1], weight_at[i + 1])
		var ic := md.add_vert(c, n1, Vector2(u1, 0.0), bone_at[i + 1], weight_at[i + 1])
		md.add_face(ia, ib, idv)
		md.add_face(ia, idv, ic)
	return md.to_array_mesh()


func _trail_tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, nrm: Vector3) -> void:
	st.set_normal(nrm)
	st.set_uv(uv0)
	st.add_vertex(p0)
	st.set_normal(nrm)
	st.set_uv(uv1)
	st.add_vertex(p1)
	st.set_normal(nrm)
	st.set_uv(uv2)
	st.add_vertex(p2)


func _approx_world_bind(bind_p: Vector3) -> Vector3:
	if _outer == null or _skel == null:
		return bind_p
	var best := 0
	var best_s := 1e9
	for i in _outer.vert_count():
		var s := _outer.pos[i].distance_squared_to(bind_p)
		if s < best_s:
			best_s = s
			best = i
	if pose_locked and _posed_frozen.size() > best:
		return _posed_frozen[best]
	var posed := Geom.skin_vertex(bind_p, best, _outer, _skel, _skin)
	return _skel.global_transform * posed


func _approx_world_and_normal(bind_p: Vector3) -> Array:
	var w := _approx_world_bind(bind_p)
	var nrm := Vector3(0, 0, 1)
	if _outer == null:
		return [w, nrm]
	var posed := _posed_world()
	if posed.size() != _outer.vert_count():
		return [w, nrm]
	var best := 0
	var best_s := 1e9
	for i in _outer.vert_count():
		var s := _outer.pos[i].distance_squared_to(bind_p)
		if s < best_s:
			best_s = s
			best = i
	# 用含该顶点的一个三角估计外向法线。
	for f in _outer.face_count():
		var ia := _outer.idx[f * 3]
		var ib := _outer.idx[f * 3 + 1]
		var ic := _outer.idx[f * 3 + 2]
		if ia != best and ib != best and ic != best:
			continue
		if ia >= posed.size() or ib >= posed.size() or ic >= posed.size():
			continue
		var nn := (posed[ib] - posed[ia]).cross(posed[ic] - posed[ia])
		if nn.length_squared() > 1e-10:
			nrm = nn.normalized()
			# 朝外：绑定空间大致朝 +Z（腹前）。
			var bind_n := (_outer.pos[ib] - _outer.pos[ia]).cross(_outer.pos[ic] - _outer.pos[ia])
			if bind_n.z < 0.0:
				nrm = -nrm
			break
	return [w, nrm]


func _clear_preview() -> void:
	_clear_trail()


func _clear_trail() -> void:
	_trail_bind = PackedVector3Array()
	if _preview:
		_preview.visible = false
		_preview.mesh = null


func _make_scalpel() -> void:
	_scalpel = MeshInstance3D.new()
	_scalpel.name = "SurgeryScalpel"
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	if ResourceLoader.exists(SCALPEL_GLB):
		var packed := load(SCALPEL_GLB)
		if packed is PackedScene:
			var inst: Node = packed.instantiate()
			_scalpel.add_child(inst)
		elif packed is Mesh:
			_scalpel.mesh = packed
			_scalpel.material_override = mat
	if _scalpel.mesh == null and _scalpel.get_child_count() == 0:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.0025
		cyl.bottom_radius = 0.004
		cyl.height = 0.11
		cyl.radial_segments = 10
		_scalpel.mesh = cyl
		_scalpel.material_override = mat
	add_child(_scalpel)
	_scalpel.visible = false


func _show_scalpel(on: bool) -> void:
	if _scalpel:
		_scalpel.visible = on


func _place_scalpel(world_p: Vector3, dir: Vector3) -> void:
	if _scalpel == null:
		return
	# 圆柱默认沿 Y；把 Y 对齐切入方向。
	var d := dir.normalized()
	var up := Vector3.UP
	if absf(d.dot(up)) > 0.95:
		up = Vector3.RIGHT
	var basis := Basis().looking_at(d, up)
	# looking_at 让 -Z 朝向目标，再把圆柱 Y 转到 -Z。
	_scalpel.global_transform = Transform3D(basis * Basis.from_euler(Vector3(-PI * 0.5, 0, 0)), world_p - d * 0.05)


func _find_exam_bed() -> Node:
	if player == null:
		return null
	var g := player.get_parent()
	var vs: Node = g.get("vehicle_system") if g else null
	if vs == null:
		return null
	var occ = vs.get("occupied")
	if occ and str(vs.call("kind_of", occ)) == "exam_bed":
		return occ
	for v in vs.get("vehicles"):
		if str(vs.call("kind_of", v)) == "exam_bed":
			return v
	return null


func _ensure_flap_catch() -> StaticBody3D:
	if _flap_catch and is_instance_valid(_flap_catch):
		return _flap_catch
	var bed := _find_exam_bed()
	if bed == null:
		return null
	var body := StaticBody3D.new()
	body.name = "SurgeryFlapCatch"
	body.collision_layer = 1 << (CATCH_LAYER - 1)
	body.collision_mask = 0
	var seat := Vector3(0.0, 0.836, 0.35)
	var head := Vector3(0.0, 1.622, -0.777)
	if bed.has_method("seat_local"):
		seat = bed.call("seat_local")
	if bed.has_method("head_local"):
		head = bed.call("head_local")
	var mid := (seat + head) * 0.5
	# 盖住髋到上背的水平托板，只用第 8 层，不顶开角色。
	var z0 := minf(seat.z, mid.z) - 0.05
	var z1 := maxf(seat.z, mid.z) + 0.35
	var center := Vector3(0.0, seat.y - 0.02, (z0 + z1) * 0.5)
	var size := Vector3(0.95, 0.14, maxf(0.7, absf(z1 - z0)))
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = center
	body.add_child(cs)
	bed.add_child(body)
	_flap_catch = body
	return body


func _catch_top_y() -> float:
	var bed := _find_exam_bed()
	if bed and bed.has_method("seat_global"):
		return float((bed.call("seat_global") as Vector3).y)
	if _flap_catch and is_instance_valid(_flap_catch):
		return _flap_catch.global_position.y + 0.8
	if player:
		return player.global_position.y + 0.7
	return 0.8


func _spawn_flap(flap_md: Geom.MeshData, flap_outer: Geom.MeshData) -> bool:
	# 用当前姿态把皮瓣烘到世界空间，再做成柔体落地。
	if _skel == null:
		return false
	var world_pos := Geom.world_positions(flap_outer, _skel, _skin)
	var world_md := Geom.MeshData.new()
	for i in flap_md.vert_count():
		var wp: Vector3
		if i < world_pos.size():
			wp = world_pos[i]
		else:
			wp = _approx_world_bind(flap_md.pos[i])
		var empty_b := PackedInt32Array([0, 0, 0, 0])
		var empty_w := PackedFloat32Array([0, 0, 0, 0])
		world_md.add_vert(wp, flap_md.nrm[i], flap_md.uv[i], empty_b, empty_w)
	world_md.idx = flap_md.idx.duplicate()
	world_md.bones = PackedInt32Array()
	world_md.weights = PackedFloat32Array()
	_ensure_flap_catch()
	var top := _catch_top_y()
	# 略向外、向下推开，避免一开始嵌进腹壁；并抬到床面上方以防穿模。
	var nsum := Vector3.ZERO
	var c := Vector3.ZERO
	for i2 in world_md.vert_count():
		c += world_md.pos[i2]
		nsum += world_md.nrm[i2]
	if world_md.vert_count() > 0:
		c /= float(world_md.vert_count())
	if nsum.length_squared() > 1e-8:
		nsum = nsum.normalized()
	else:
		nsum = Vector3(0, -0.2, 0.8).normalized()
	var push := nsum * 0.05 + Vector3(0, -0.02, 0)
	var min_y := 1e9
	for i3 in world_md.vert_count():
		world_md.pos[i3] = world_md.pos[i3] + push
		if world_md.pos[i3].y < min_y:
			min_y = world_md.pos[i3].y
	if min_y < top + 0.02:
		var lift := (top + 0.03) - min_y
		for i4 in world_md.vert_count():
			world_md.pos[i4].y += lift
	var mesh := world_md.to_array_mesh()
	if mesh.get_surface_count() < 1:
		return false
	if flap_node and is_instance_valid(flap_node):
		flap_node.queue_free()
		flap_node = null
	var parent: Node = player.get_parent() if player else get_tree().current_scene
	if parent == null:
		parent = self
	var soft := SoftBody3D.new()
	soft.name = "SurgeryFlap"
	soft.mesh = mesh
	soft.collision_layer = 1
	soft.collision_mask = 1 | (1 << (CATCH_LAYER - 1))
	soft.linear_stiffness = 0.42
	soft.damping_coefficient = 0.22
	if "total_mass" in soft:
		soft.total_mass = 0.40
	soft.simulation_precision = 8
	if "parent_collision_ignore" in soft and player:
		soft.parent_collision_ignore = soft.get_path_to(player) if soft.is_inside_tree() else NodePath()
	soft.material_override = _wall_material()
	parent.add_child(soft)
	soft.global_transform = Transform3D.IDENTITY
	if player and "parent_collision_ignore" in soft:
		soft.parent_collision_ignore = soft.get_path_to(player)
	if is_instance_valid(soft) and soft.mesh and soft.mesh.get_surface_count() >= 1:
		flap_node = soft
		flap_kind = "softbody"
		return true
	soft.queue_free()
	return _spawn_flap_verlet(world_md, parent)


func _spawn_flap_verlet(world_md: Geom.MeshData, parent: Node) -> bool:
	var floor_y := _catch_top_y()
	var flap := load("res://scripts/surgery/surgery_flap_verlet.gd").new() as Node3D
	flap.name = "SurgeryFlap"
	parent.add_child(flap)
	var world: World3D = null
	if flap.get_world_3d():
		world = flap.get_world_3d()
	flap.call("setup_from_mesh", world_md, _wall_material(), world, floor_y)
	flap_node = flap
	flap_kind = "verlet"
	return true


func debug_begin_stroke_at_navel() -> bool:
	if not active:
		if not enter_surgery():
			return false
	var origin := _navel_world() + Vector3(0.0, 0.02, 0.28)
	var dir := (_navel_world() - origin)
	if dir.length_squared() < 1e-8:
		dir = Vector3(0, 0, -1)
	else:
		dir = dir.normalized()
	return begin_stroke(origin, dir)


func debug_freehand_cut_from_navel() -> bool:
	## 模拟一次真实手绘落刀：选手术刀、从肚脐附近拖出一段路径并提交。
	if not active:
		if not enter_surgery():
			return false
	if tool != "scalpel":
		set_tool("scalpel")
	if not debug_begin_stroke_at_navel():
		return false
	var n := _navel_world()
	for i in range(1, 10):
		var tgt := n + Vector3(0.0075 * float(i), 0.0035 * sin(float(i) * 0.9), 0.0)
		var origin := tgt + Vector3(0.0, 0.02, 0.28)
		var dir := (tgt - origin)
		if dir.length_squared() < 1e-8:
			dir = Vector3(0, 0, -1)
		else:
			dir = dir.normalized()
		drag_stroke(origin, dir)
	end_stroke()
	return cut_open


func _navel_world() -> Vector3:
	if _organs and _organs.has_method("abdomen_frame"):
		return (_organs.call("abdomen_frame") as Transform3D).origin
	if player:
		return player.global_position + Vector3(0, 1.06, 0.1)
	return _navel_rest


func _process(dt: float) -> void:
	if active and not is_on_exam_bed():
		exit_surgery()
		return
	if not active and not persist:
		return
	if (active or persist) and not pose_locked:
		_posed_dirty = true
	var xr := 1 if _xray_on() else 0
	if xr != _xray_cached:
		_xray_cached = xr
		_update_cavity_visibility()
	if _evert_anim:
		_step_eversion(dt)
	if not _grab_active and _pull_off.length_squared() > 1e-8:
		_step_pull_spring(dt)


func _parent_trail(mi: MeshInstance3D) -> void:
	if mi == null:
		return
	var want: Node = _skel if _skel else self
	if mi.get_parent() == want:
		return
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	want.add_child(mi)
	if want == _skel:
		mi.skeleton = NodePath("..")
		if _skin:
			mi.skin = _skin
		mi.transform = Transform3D.IDENTITY


func _approx_bind_and_normal(bind_p: Vector3) -> Array:
	var nrm := Vector3(0, 0, 1)
	var bones := PackedInt32Array([0, 0, 0, 0])
	var weights := PackedFloat32Array([1, 0, 0, 0])
	if _outer == null or _outer.vert_count() < 1:
		return [bind_p, nrm, bones, weights]
	var best := 0
	var best_s := 1e9
	for i in _outer.vert_count():
		var s := _outer.pos[i].distance_squared_to(bind_p)
		if s < best_s:
			best_s = s
			best = i
	if best < _outer.nrm.size():
		nrm = _outer.nrm[best]
		if nrm.length_squared() > 1e-10:
			nrm = nrm.normalized()
	if _outer.bones.size() >= (best + 1) * 4:
		for k in 4:
			bones[k] = _outer.bones[best * 4 + k]
			weights[k] = _outer.weights[best * 4 + k]
	return [bind_p, nrm, bones, weights]


func _mesh_with_evert(md: Geom.MeshData, rest: Geom.MeshData, ev: Geom.MeshData) -> ArrayMesh:
	if md == null:
		return ArrayMesh.new()
	if ev and rest and ev.vert_count() == md.vert_count() and rest.vert_count() == md.vert_count():
		return rest.to_array_mesh_with_blend("evert", ev)
	return md.to_array_mesh()


func _lips_valid(md: Geom.MeshData, lips: PackedInt32Array) -> bool:
	if md == null or lips.size() < 2:
		return false
	for id in lips:
		if id < 0 or id >= md.vert_count():
			return false
	return true


func _start_eversion() -> void:
	if _outer == null:
		return
	_outer_rest = _outer.clone()
	_inner_rest = _inner.clone() if _inner else null
	_wall_rest = _wall_md.clone() if _wall_md else null
	_outer_evert = _outer_rest.clone()
	_inner_evert = _inner_rest.clone() if _inner_rest else null
	_wall_evert = _wall_rest.clone() if _wall_rest else null
	if _lips_valid(_outer_evert, _lip_left) and _lips_valid(_outer_evert, _lip_right):
		if _lip_closed and _lip_left.size() >= 3:
			Geom.evert_loop_lips(_outer_evert, _lip_left, _lip_right, 1.0, EVERT_ROLL)
			if _inner_evert and _lips_valid(_inner_evert, _lip_left_i) and _lips_valid(_inner_evert, _lip_right_i):
				Geom.evert_loop_lips(_inner_evert, _lip_left_i, _lip_right_i, 1.0, EVERT_ROLL * 0.85)
		else:
			Geom.evert_open_lips(_outer_evert, _lip_left, _lip_right, 1.0, EVERT_ROLL)
			if _inner_evert and _lips_valid(_inner_evert, _lip_left_i) and _lips_valid(_inner_evert, _lip_right_i):
				Geom.evert_open_lips(_inner_evert, _lip_left_i, _lip_right_i, 1.0, EVERT_ROLL * 0.85)
	var valid_holes: Array = []
	for loop in _hole_loops:
		if loop is PackedInt32Array and _lips_valid(_outer_evert, loop as PackedInt32Array):
			Geom.evert_hole_rim(_outer_evert, loop, 1.0, EVERT_ROLL * 0.8)
			valid_holes.append(loop)
	_hole_loops = valid_holes
	_evert_wall_from_lips()
	_evert = 0.0
	_evert_vel = 0.0
	_evert_anim = true


func _evert_wall_from_lips() -> void:
	## 保持截面拓扑不变，按腹壁/内壁对应顶点的外翻位移去推截面，这样才跟得上肚子。
	if _wall_rest == null:
		return
	_wall_evert = _wall_rest.clone()
	_apply_corresponding_evert(_wall_evert, _wall_rest, _outer_rest, _outer_evert)
	_apply_corresponding_evert(_wall_evert, _wall_rest, _inner_rest, _inner_evert)


func _apply_corresponding_evert(dest: Geom.MeshData, dest_rest: Geom.MeshData, src_rest: Geom.MeshData, src_evert: Geom.MeshData) -> void:
	if dest == null or dest_rest == null or src_rest == null or src_evert == null:
		return
	if src_rest.vert_count() != src_evert.vert_count():
		return
	for i in dest.vert_count():
		var p: Vector3 = dest_rest.pos[i]
		var best := -1
		var best_s := 1e-8
		for j in src_rest.vert_count():
			var s := src_rest.pos[j].distance_squared_to(p)
			if s <= best_s:
				best_s = s
				best = j
		if best >= 0:
			var delta: Vector3 = src_evert.pos[best] - src_rest.pos[best]
			if delta.length_squared() > 1e-12:
				dest.pos[i] = dest.pos[i] + delta


func _step_eversion(dt: float) -> void:
	# 弹性外翻：有过冲的弹簧，看起来像切开皮肉自己翻开，而不是瞬间折角。
	var k := 42.0
	var c := 8.5
	var acc := (1.0 - _evert) * k - _evert_vel * c
	_evert_vel += acc * dt
	_evert += _evert_vel * dt
	if _evert > 1.12:
		_evert = 1.12
	if absf(_evert - 1.0) < 0.012 and absf(_evert_vel) < 0.08:
		_evert = 1.0
		_evert_vel = 0.0
		_evert_anim = false
	_apply_evert_weight()


func debug_settle_eversion() -> void:
	if _outer_evert == null:
		_start_eversion()
	_evert = 1.0
	_evert_vel = 0.0
	_evert_anim = false
	_apply_evert_weight()


func _apply_evert_weight() -> void:
	for mi in [_surgical_mi, _wall_mi, _cavity_mi]:
		if mi and mi.mesh and mi.mesh.get_blend_shape_count() > 0:
			mi.set_blend_shape_value(0, clampf(_evert, 0.0, 1.15))


func _measure_lip_width(md: Geom.MeshData) -> float:
	if md == null:
		return 0.0
	var n := mini(_lip_left.size(), _lip_right.size())
	if n < 2:
		return 0.0
	var acc := 0.0
	var cnt := 0
	var start := 1 if (not _lip_closed and n > 2) else 0
	var stop := n - 1 if (not _lip_closed and n > 2) else n
	for i in range(start, stop):
		var a: int = _lip_left[i]
		var b: int = _lip_right[i]
		if a == b or a < 0 or b < 0 or a >= md.vert_count() or b >= md.vert_count():
			continue
		acc += md.pos[a].distance_to(md.pos[b])
		cnt += 1
	return acc / float(cnt) if cnt > 0 else 0.0


func _resolve_bone(bind_i: int) -> int:
	var rec: Dictionary = Geom.resolve_skin_bind(_skin, _skel, bind_i)
	return int(rec.get("bone", -1))


func _dominant_bone(md: Geom.MeshData) -> int:
	if md == null or md.bones.is_empty():
		return -1
	var best_i := -1
	var best_w := 0.0
	var n := mini(md.vert_count(), int(md.bones.size() / 4))
	for i in n:
		for k in 4:
			var w: float = md.weights[i * 4 + k]
			if w <= best_w:
				continue
			var bi := _resolve_bone(md.bones[i * 4 + k])
			if bi >= 0:
				best_w = w
				best_i = bi
	return best_i


func debug_wall_follow_delta() -> Dictionary:
	## 轻推一根腹部相关骨骼，看断面与腹壁是否一起动，而不是留在原处。
	var out := {"ok": false, "wall": 0.0, "belly": 0.0, "ratio": 0.0}
	if _wall_md == null or _outer == null or _skel == null or _wall_md.vert_count() < 1:
		return out
	# 检查床上角色已不在绑定姿态：若断面跟着腹部蒙皮，其蒙皮质心应明显离开纯绑定位置。
	var w_bind := _mesh_centroid_bind(_wall_md)
	var b_bind := _mesh_centroid_bind(_outer)
	var w_pose := _mesh_centroid_world(_wall_md)
	var b_pose := _mesh_centroid_world(_outer)
	var wd := w_pose.distance_to(w_bind)
	var bd := b_pose.distance_to(b_bind)
	out["wall"] = wd
	out["belly"] = bd
	out["ratio"] = (wd / bd) if bd > 1e-6 else (1.0 if wd > 1e-5 else 0.0)
	out["ok"] = wd > 0.001 and (bd < 1e-6 or wd > bd * 0.25)
	return out


func _mesh_centroid_with_bone_shift(md: Geom.MeshData, bone_i: int, world_shift: Vector3) -> Vector3:
	if md == null or md.vert_count() < 1 or _skel == null:
		return Vector3.ZERO
	var local_shift: Vector3 = _skel.global_transform.basis.inverse() * world_shift
	var acc := Vector3.ZERO
	for i in md.vert_count():
		var p: Vector3 = Geom.skin_vertex(md.pos[i], i, md, _skel, _skin)
		var w := 0.0
		if _skin and md.bones.size() >= (i + 1) * 4:
			for k in 4:
				var bind_i: int = md.bones[i * 4 + k]
				if bind_i < 0 or bind_i >= _skin.get_bind_count():
					continue
				if _skin.get_bind_bone(bind_i) == bone_i:
					w += md.weights[i * 4 + k]
		acc += _skel.global_transform * (p + local_shift * w)
	return acc / float(md.vert_count())


func _mesh_centroid_world(md: Geom.MeshData) -> Vector3:
	if md == null or md.vert_count() < 1 or _skel == null:
		return Vector3.ZERO
	var pts := Geom.world_positions(md, _skel, _skin)
	if pts.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / float(pts.size())


func _mesh_centroid_bind(md: Geom.MeshData) -> Vector3:
	if md == null or md.vert_count() < 1:
		return Vector3.ZERO
	var xf := _skel.global_transform if _skel else Transform3D.IDENTITY
	var c := Vector3.ZERO
	for p in md.pos:
		c += xf * p
	return c / float(md.vert_count())


func _begin_grab(origin: Vector3, dir: Vector3) -> bool:
	if not can_use_grab():
		return false
	# 已剥离的皮瓣：点中则拿起、拖拽，松手时抛出。
	if flap_node and is_instance_valid(flap_node) and _ray_hits_flap(origin, dir):
		return _begin_flap_grab(origin, dir)
	# 未剥离的闭环：先撕下皮瓣再拿在手里。
	if can_grab_flap():
		if peel_flap() and flap_node and is_instance_valid(flap_node):
			return _begin_flap_grab(origin, dir)
		return false
	# 开放切口或洞缘：像拉扯皮肉一样拖动被分割的皮肤。
	if cut_open:
		return _begin_skin_grab(origin, dir)
	if flap_node and is_instance_valid(flap_node):
		return _begin_flap_grab(origin, dir)
	return false


func _ray_hits_flap(origin: Vector3, dir: Vector3) -> bool:
	if flap_node == null or not is_instance_valid(flap_node):
		return false
	var c := flap_centroid()
	var d := dir.normalized()
	var w := origin - c
	var proj := -w.dot(d)
	var closest: Vector3 = origin + d * maxf(proj, 0.0)
	return closest.distance_to(c) <= 0.18


func flap_centroid() -> Vector3:
	if flap_node == null or not is_instance_valid(flap_node):
		return Vector3.ZERO
	if flap_node.has_method("centroid"):
		return flap_node.call("centroid")
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		var c := Vector3.ZERO
		var cnt := 0
		var n := _soft_point_count(soft)
		for i in n:
			c += soft.get_point_transform(i)
			cnt += 1
		if cnt > 0:
			return c / float(cnt)
		if soft.mesh:
			var ab := soft.mesh.get_aabb()
			return soft.global_transform * ab.get_center()
		return soft.global_position
	if flap_node is Node3D:
		return (flap_node as Node3D).global_position
	return Vector3.ZERO


func _soft_point_count(soft: SoftBody3D) -> int:
	if soft.mesh == null or soft.mesh.get_surface_count() < 1:
		return 0
	var arr: Array = soft.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	return verts.size()


func _begin_flap_grab(origin: Vector3, dir: Vector3) -> bool:
	var hit := _grab_plane_hit(origin, dir, flap_centroid())
	_grab_kind = "flap"
	_grab_active = true
	stroke_active = true
	_grab_last = hit
	_grab_vel = Vector3.ZERO
	_flap_throw_speed = 0.0
	_ensure_grab_anchor(hit)
	_pin_flap_to_anchor()
	return true


func _begin_skin_grab(origin: Vector3, dir: Vector3) -> bool:
	_refresh_posed()
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	var world_p: Vector3
	var bind_p: Vector3
	if hit == null:
		# 没精确点中也允许拉最近的唇边，方便测试和粗操作。
		if _lip_left.size() < 1:
			return false
		bind_p = _outer.pos[_lip_left[_lip_left.size() / 2]] if _outer else Vector3.ZERO
		world_p = _approx_world_bind(bind_p)
	else:
		world_p = (hit as Dictionary)["point"]
		bind_p = (hit as Dictionary)["bind"]
	_grab_kind = "skin"
	_grab_active = true
	stroke_active = true
	_grab_last = world_p
	_grab_vel = Vector3.ZERO
	_split_drag = 0.0
	_pull_p = _to_ab_local(world_p)
	_pull_off = Vector3.ZERO
	_pull_r = 0.055
	_apply_pull_uniforms()
	return true


func _drag_grab(origin: Vector3, dir: Vector3) -> void:
	if not _grab_active:
		return
	if _grab_kind == "flap":
		var nxt := _grab_plane_hit(origin, dir, _grab_last)
		var delta: Vector3 = nxt - _grab_last
		_grab_vel = delta
		_grab_last = nxt
		_move_flap_by(delta)
		if _grab_anchor:
			_grab_anchor.global_position = nxt
		return
	if _grab_kind == "skin":
		var nxt2 := _grab_plane_hit(origin, dir, _grab_last)
		var off: Vector3 = nxt2 - _grab_last
		# 限制拉扯幅度，像有弹性的皮肉，而不是把网格拽坏。
		_pull_off += _to_ab_delta(off)
		if _pull_off.length() > 0.06:
			_pull_off = _pull_off.normalized() * 0.06
		_split_drag = _pull_off.length()
		_apply_pull_uniforms()


func _end_grab(do_throw: bool) -> void:
	if not _grab_active:
		return
	if _grab_kind == "flap":
		var vel := _grab_vel * (18.0 if do_throw else 0.0)
		if vel.length() > 6.0:
			vel = vel.normalized() * 6.0
		_unpin_flap()
		_apply_flap_throw(vel if do_throw else Vector3.ZERO)
		_flap_throw_speed = vel.length() if do_throw else 0.0
	elif _grab_kind == "skin":
		# 松手后弹簧收回，保留弹性手感。
		_split_drag = _pull_off.length()
	_grab_active = false
	_grab_kind = ""
	stroke_active = false


func debug_grab_move_flap(delta: Vector3) -> bool:
	if flap_node == null or not is_instance_valid(flap_node):
		if can_grab_flap():
			if not peel_flap():
				return false
		else:
			return false
	_grab_kind = "flap"
	_grab_active = true
	stroke_active = true
	_grab_last = flap_centroid()
	_grab_vel = delta
	_ensure_grab_anchor(_grab_last + delta)
	_pin_flap_to_anchor()
	_move_flap_by(delta)
	if _grab_anchor:
		_grab_anchor.global_position = _grab_last + delta
	_grab_last = _grab_last + delta
	return true


func debug_throw_flap(vel: Vector3) -> bool:
	if flap_node == null or not is_instance_valid(flap_node):
		return false
	if not _grab_active:
		_grab_kind = "flap"
		_grab_active = true
		_ensure_grab_anchor(flap_centroid())
		_pin_flap_to_anchor()
	_grab_vel = vel / 18.0
	_end_grab(true)
	return _flap_throw_speed > 0.0 or vel.length() <= 0.0


func debug_drag_split_skin(off: Vector3) -> bool:
	if not cut_open or _outer == null:
		return false
	_grab_kind = "skin"
	_grab_active = true
	stroke_active = true
	var mid := _navel_rest
	if _lip_left.size() > 0 and _lip_left[0] < _outer.vert_count():
		mid = _outer.pos[_lip_left[_lip_left.size() / 2]]
	_pull_p = mid
	_pull_off = off
	if _pull_off.length() > 0.06:
		_pull_off = _pull_off.normalized() * 0.06
	_pull_r = 0.055
	_split_drag = _pull_off.length()
	_apply_pull_uniforms()
	return _split_drag > 0.0


func debug_release_split_skin() -> void:
	_grab_active = false
	_grab_kind = ""
	stroke_active = false


func _grab_plane_hit(origin: Vector3, dir: Vector3, around: Vector3) -> Vector3:
	var d := dir.normalized()
	var n := d
	if n.length_squared() < 1e-8:
		n = Vector3(0, 0, 1)
	var denom := n.dot(d)
	if absf(denom) < 1e-8:
		return around
	var t := n.dot(around - origin) / denom
	return origin + d * t


func _ensure_grab_anchor(p: Vector3) -> void:
	if _grab_anchor and is_instance_valid(_grab_anchor):
		_grab_anchor.global_position = p
		return
	_grab_anchor = Node3D.new()
	_grab_anchor.name = "SurgeryFlapAnchor"
	var parent: Node = player.get_parent() if player else get_tree().current_scene
	if parent == null:
		parent = self
	parent.add_child(_grab_anchor)
	_grab_anchor.global_position = p


func _pin_flap_to_anchor() -> void:
	_pinned_points = PackedInt32Array()
	if flap_node == null or _grab_anchor == null:
		return
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		var mesh := soft.mesh
		if mesh == null or mesh.get_surface_count() < 1:
			return
		var arr: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var path := soft.get_path_to(_grab_anchor)
		# 钉住离锚点最近的一小簇顶点，整片皮瓣跟着走。
		var scored: Array = []
		var ap := _grab_anchor.global_position
		for i in verts.size():
			scored.append([verts[i].distance_squared_to(ap), i])
		scored.sort_custom(func(a, b): return a[0] < b[0])
		var n := mini(8, scored.size())
		for k in n:
			var idx: int = int(scored[k][1])
			soft.set_point_pinned(idx, true, path)
			_pinned_points.append(idx)
	elif flap_node.has_method("begin_hold"):
		flap_node.call("begin_hold", _grab_anchor.global_position)


func _move_flap_by(delta: Vector3) -> void:
	if flap_node == null or not is_instance_valid(flap_node) or delta.length_squared() < 1e-12:
		return
	if _grab_anchor:
		_grab_anchor.global_position += delta
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		var rid: RID = soft.get_physics_rid()
		var n := _soft_point_count(soft)
		for i in n:
			var p: Vector3 = soft.get_point_transform(i) + delta
			PhysicsServer3D.soft_body_move_point(rid, i, p)
	elif flap_node.has_method("drag_hold"):
		flap_node.call("drag_hold", flap_centroid() + delta)
	elif flap_node is Node3D:
		(flap_node as Node3D).global_position += delta


func _unpin_flap() -> void:
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		for i in _pinned_points:
			if soft.has_method("set_point_pinned"):
				soft.set_point_pinned(int(i), false)
	_pinned_points = PackedInt32Array()


func _apply_flap_throw(vel: Vector3) -> void:
	if flap_node == null or not is_instance_valid(flap_node):
		return
	if flap_node.has_method("end_hold"):
		flap_node.call("end_hold", vel)
		return
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		if vel.length_squared() > 1e-8:
			if soft.has_method("apply_central_impulse"):
				soft.apply_central_impulse(vel * 0.40)
			var rid: RID = soft.get_physics_rid()
			var n := _soft_point_count(soft)
			var imp := vel * 0.08
			for i in n:
				PhysicsServer3D.soft_body_apply_point_impulse(rid, i, imp)


func _to_ab_local(world_p: Vector3) -> Vector3:
	if _organs and _organs.has_method("abdomen_frame"):
		var fr: Transform3D = _organs.call("abdomen_frame")
		return fr.affine_inverse() * world_p
	return world_p


func _to_ab_delta(world_delta: Vector3) -> Vector3:
	if _organs and _organs.has_method("abdomen_frame"):
		var fr: Transform3D = _organs.call("abdomen_frame")
		return fr.basis.inverse() * world_delta
	return world_delta


func _apply_pull_uniforms() -> void:
	var mats: Array = []
	if _wall_shader_mat:
		mats.append(_wall_shader_mat)
	if _cavity_shader_mat:
		mats.append(_cavity_shader_mat)
	if _trail_mat:
		mats.append(_trail_mat)
	if _surgical_mi and _surgical_mi.material_override is ShaderMaterial:
		mats.append(_surgical_mi.material_override)
	for m in mats:
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("surgery_pull_p", _pull_p)
		sm.set_shader_parameter("surgery_pull_off", _pull_off)
		sm.set_shader_parameter("surgery_pull_r", _pull_r if _pull_off.length_squared() > 1e-8 else 0.0)


func _step_pull_spring(dt: float) -> void:
	var k := 28.0
	var c := 7.0
	# 用 _pull_off 当位移，简单弹簧回到 0。
	var acc: Vector3 = -_pull_off * k - _grab_vel * c
	_grab_vel += acc * dt
	_pull_off += _grab_vel * dt
	if _pull_off.length() < 0.0008 and _grab_vel.length() < 0.002:
		_pull_off = Vector3.ZERO
		_grab_vel = Vector3.ZERO
		_split_drag = 0.0
		_pull_r = 0.0
	else:
		_split_drag = _pull_off.length()
	_apply_pull_uniforms()


func apply_bullet_hit(info: Dictionary, par: Dictionary = {}) -> Dictionary:
	## 由 OrganRig.apply_ballistic_hit 调用：在手术腹网上打出柱状弹孔，并去掉圆心皮瓣。
	var out := {"entry": false, "exit": false, "tris": 0}
	if not bool(info.get("hit", false)):
		return out
	if not _bake_if_needed():
		return out
	var dir: Vector3 = info.get("dir", Vector3.ZERO)
	if dir is Vector3 and (dir as Vector3).length_squared() > 1e-8:
		dir = (dir as Vector3).normalized()
	else:
		var a: Variant = info.get("entry")
		var b: Variant = info.get("exit")
		if a is Vector3 and b is Vector3:
			dir = ((b as Vector3) - (a as Vector3))
			if dir.length_squared() > 1e-8:
				dir = dir.normalized()
			else:
				dir = Vector3(0, 0, -1)
		else:
			dir = Vector3(0, 0, -1)
	var energy := float(par.get("energy", 0.5))
	# 特写镜头离体表约 0.4m，通道要够大、够深才看得出柱状内壁。
	var radius := clampf(0.010 + energy * 0.008, 0.010, 0.020)
	if bullet_holes < MAX_BULLET_HOLES:
		var entry: Variant = info.get("entry")
		if entry is Vector3:
			out["entry"] = _punch_bullet_hole_world(entry, dir, radius)
	if bool(info.get("overpen", false)) and bullet_holes < MAX_BULLET_HOLES:
		var ex: Variant = info.get("exit")
		if ex is Vector3:
			out["exit"] = _punch_bullet_hole_world(ex, dir, radius * 1.12)
	out["tris"] = bullet_wall_tris
	if bool(out["entry"]) or bool(out["exit"]):
		persist = true
		cut_open = true
		cavity_exposed = true
		_update_cavity_visibility()
	return out


func debug_apply_bullet_hole(world_origin: Vector3, world_dir: Vector3, radius: float = 0.01) -> bool:
	if not _bake_if_needed():
		return false
	var d := world_dir
	if d.length_squared() < 1e-8:
		d = Vector3(0, 0, -1)
	else:
		d = d.normalized()
	return _punch_bullet_hole_world(world_origin, d, radius)


func _punch_bullet_hole_world(world_p: Vector3, world_dir: Vector3, radius: float) -> bool:
	if _outer == null:
		return false
	_posed_dirty = true
	var origin: Vector3 = world_p - world_dir * 0.25
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, world_dir)
	if hit == null:
		# 从另一侧再试（出口）。
		hit = Geom.ray_hit_mesh(_outer, _posed_world(), world_p + world_dir * 0.25, -world_dir)
	if hit == null:
		# 特写命中用的是腹部椭球，可能稍稍偏离腹网，改落在最近的腹点上。
		hit = _closest_mesh_hit_world(world_p)
	if hit == null:
		return false
	var bind_c: Vector3 = (hit as Dictionary)["bind"]
	var vi: int = int((hit as Dictionary).get("i0", 0))
	var bind_dir := Geom.world_dir_to_bind(world_dir, vi, _outer, _skel, _skin)
	return _punch_bullet_hole_bind(bind_c, bind_dir, radius)


func _closest_mesh_hit_world(world_p: Vector3) -> Variant:
	if _outer == null:
		return null
	var posed := _posed_world()
	if posed.size() != _outer.vert_count() or posed.is_empty():
		return null
	var best := -1
	var best_s := 1e9
	for i in posed.size():
		var s := posed[i].distance_squared_to(world_p)
		if s < best_s:
			best_s = s
			best = i
	# 超过约 10cm 就不是打在这片手术腹网上。
	if best < 0 or best_s > 0.10 * 0.10:
		return null
	return {"bind": _outer.pos[best], "point": posed[best], "i0": best}


func _punch_bullet_hole_bind(center: Vector3, axis: Vector3, radius: float) -> bool:
	if _outer == null or _inner == null:
		return false
	var path := Geom.circle_path_on_mesh(_outer, center, axis, radius, BULLET_SIDES)
	if path.size() < 5:
		return false
	var ids := Geom.embed_path_paired(_outer, _inner, path)
	if ids.size() < 3:
		return false
	ids = Geom.close_path_ids(_outer, ids)
	Geom.sync_inner(_outer, _inner)
	if ids.size() >= 3 and ids[0] != ids[ids.size() - 1]:
		ids.append(ids[0])
	var ext_o: Dictionary = Geom.extract_inside(_outer, ids)
	var ext_i: Dictionary = Geom.extract_inside(_inner, ids)
	if int(ext_o.get("inside_faces", 0)) < 1 or int(ext_o.get("outside_faces", 0)) < 1:
		return false
	var body_o: Geom.MeshData = ext_o["outside"]
	var body_i: Geom.MeshData = ext_i["outside"]
	var loop_o: PackedInt32Array = ext_o["loop_out"]
	var loop_i: PackedInt32Array = ext_i["loop_out"]
	# 柱状壁沿弹道：若内环可用就用内环，否则把外环沿弹轴平移到腹腔深度。
	var wall := _make_bullet_cylinder(body_o, body_i, loop_o, loop_i, axis)
	if wall.face_count() < 1:
		return false
	_outer = body_o
	_inner = body_i
	if _wall_md and _wall_md.face_count() > 0:
		_append_mesh(_wall_md, wall)
	else:
		_wall_md = wall
	lofted_tris = _wall_md.face_count()
	bullet_holes += 1
	bullet_plugs_removed += 1
	bullet_wall_tris += wall.face_count()
	# 冲压后旧切口唇的顶点索引可能已失效，只对外翻新弹孔缘。
	if not _lips_valid(body_o, _lip_left) or not _lips_valid(body_o, _lip_right):
		_lip_left = PackedInt32Array()
		_lip_right = PackedInt32Array()
		_lip_left_i = PackedInt32Array()
		_lip_right_i = PackedInt32Array()
	var holes: Array = []
	for loop2 in _hole_loops:
		if loop2 is PackedInt32Array and _lips_valid(body_o, loop2 as PackedInt32Array):
			holes.append(loop2)
	holes.append(loop_o)
	_hole_loops = holes
	cut_open = true
	cavity_exposed = true
	persist = true
	_start_eversion()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	_posed_dirty = true
	_update_cavity_visibility()
	return true


func _make_bullet_cylinder(outer: Geom.MeshData, inner: Geom.MeshData, loop_o: PackedInt32Array, loop_i: PackedInt32Array, axis: Vector3) -> Geom.MeshData:
	var cap := BULLET_SIDES
	var src_o := Geom.resample_index_loop(outer, loop_o, cap)
	var src_i := Geom.resample_index_loop(inner, loop_i, cap)
	var n := mini(src_o.size(), src_i.size())
	if n < 3:
		# 内环不够时，沿弹轴把外环推到腹腔厚度，做成真正的柱状断面。
		return _loft_translated_cylinder(outer, src_o if src_o.size() >= 3 else loop_o, axis)
	if src_o.size() != src_i.size():
		src_o = Geom.resample_index_loop(outer, src_o, n)
		src_i = Geom.resample_index_loop(inner, src_i, n)
	return _make_loft_mesh(outer, inner, src_o, src_i, true)


func _loft_translated_cylinder(outer: Geom.MeshData, loop_o: PackedInt32Array, axis: Vector3) -> Geom.MeshData:
	var ids := Geom.resample_index_loop(outer, loop_o, BULLET_SIDES)
	if ids.size() < 3:
		ids = loop_o
	var wall := Geom.MeshData.new()
	var front := PackedInt32Array()
	var back := PackedInt32Array()
	var ax := axis
	if ax.length_squared() < 1e-8:
		ax = Vector3(0, 0, -1)
	else:
		ax = ax.normalized()
	# 沿弹道走到腹腔内壁深度，形成短柱而不是一层薄片。
	var depth := thickness
	for id in ids:
		if id < 0 or id >= outer.vert_count():
			continue
		front.append(wall.copy_vert(outer, id))
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		for k in 4:
			b[k] = outer.bones[id * 4 + k]
			w[k] = outer.weights[id * 4 + k]
		var ip: Vector3 = outer.pos[id] + ax * depth
		# 若有法线，略向内收，避免柱体戳出腹壁。
		var nrm: Vector3 = outer.nrm[id] if id < outer.nrm.size() else ax
		if nrm.dot(ax) < 0.0:
			ip = outer.pos[id] + ax * depth
		back.append(wall.add_vert(ip, -nrm if nrm.length_squared() > 1e-8 else -ax, outer.uv[id] if id < outer.uv.size() else Vector2.ZERO, b, w))
	if front.size() >= 3 and front.size() == back.size():
		Geom.loft_wall(wall, front, back, true)
	return wall
