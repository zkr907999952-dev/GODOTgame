extends Node
## 手术模式：检查床上进入 / 退出，直线/环状预览切口、层状腹壁、可剥离皮瓣。
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
## 0.3.6：剖切红线比 0.3.5（半宽 0.0064、深红色）更窄更浅。
const TRAIL_HALF_WIDTH := 0.0036
const TRAIL_HALF_WIDTH_V035 := 0.0064
const TRAIL_COLOR_DEEP := Color(0.78, 0.32, 0.32, 1.0)
const TRAIL_COLOR_BRIGHT := Color(1.0, 0.58, 0.55, 1.0)
const TRAIL_ALPHA := 0.72
const TRAIL_FALLBACK_COLOR := Color(0.95, 0.52, 0.50, 0.70)

signal mode_changed(active: bool)
signal tool_changed(tool: String)
signal cut_mode_changed(mode: String)
signal preview_changed()

var player: Node = null
var active: bool = false
var tool: String = ""  # "" | "scalpel" | "grab"  — 进入时无工具，可转视角
var cut_mode: String = "straight"  # "straight" | "ring"
var thickness: float = WALL_THICKNESS
var cut_open: bool = false
var loop_ready: bool = false
var flap_peeled: bool = false
var lofted_tris: int = 0
var path_points: PackedVector3Array = PackedVector3Array()  # bind-space
var stroke_active: bool = false
var persist: bool = false
var flap_node: Node3D = null
var flap_kind: String = ""  # "rigid" | "softbody" | "verlet" | ""
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
var _scalpel: Node3D
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
var _cut_preview: bool = false
var _preview_a: Vector3 = Vector3.ZERO
var _preview_b: Vector3 = Vector3.ZERO
var _preview_center: Vector3 = Vector3.ZERO
var _preview_rx: float = 0.0
var _preview_ry: float = 0.0
var _preview_handle: String = ""
var _preview_drag_start: Vector3 = Vector3.ZERO
var _preview_center0: Vector3 = Vector3.ZERO
var _preview_rx0: float = 0.0
var _preview_ry0: float = 0.0
var _cut_anim: bool = false
var _cut_anim_t: float = 0.0
var _cut_anim_dur: float = 0.7
var _cut_anim_path: PackedVector3Array = PackedVector3Array()
var _cut_anim_closed: bool = false
var _dash: MeshInstance3D
var _handles: MeshInstance3D
var _lumbar_z: float = -1e9
var _pull_peak: float = 0.0
var _pull_rest: Vector3 = Vector3.ZERO
var last_cut_animated: bool = false
var last_commit_path: PackedVector3Array = PackedVector3Array()
var last_embedded_bind: PackedVector3Array = PackedVector3Array()
var _preview_compare_path: PackedVector3Array = PackedVector3Array()
var _flap_rest_size: Vector3 = Vector3.ZERO
var _split_dir: Vector3 = Vector3.ZERO
var _flap_outer_faces: int = 0
## 0.3.8 拿取：拖拽强度（指针位移 → 皮肤位移）和上限都比 0.3.7 低。
const GRAB_SKIN_GAIN := 0.5
const GRAB_SKIN_MAX := 0.06
const GRAB_FLAP_GAIN := 0.6
const GRAB_THROW_GAIN := 10.0
const GRAB_THROW_MAX := 3.5
## 拿取切口：0 = 旧的径向整体平移，1 = 直线切口（只拉被抓一侧、两端固定），2 = 环形洞缘。
var _pull_mode: int = 0
var _pull_a: Vector3 = Vector3.ZERO
var _pull_b: Vector3 = Vector3.ZERO
var _pull_axis: Vector3 = Vector3.ZERO
var _pull_raw: Vector3 = Vector3.ZERO
var _flap_goal: Vector3 = Vector3.ZERO
var _flap_goal_set: bool = false
var _flap_grab_off: Vector3 = Vector3.ZERO
const GRAB_FLAP_FOLLOW := 7.0


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
	_make_dash()
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


func current_cut_mode() -> String:
	return cut_mode


func set_cut_mode(m: String) -> void:
	var mode := "straight"
	if m == "ring" or m == "ellipse" or m == "loop":
		mode = "ring"
	elif m == "straight" or m == "line":
		mode = "straight"
	if _cut_anim:
		return
	if cut_mode == mode:
		return
	if stroke_active and tool == "scalpel":
		cancel_stroke()
	cut_mode = mode
	_clear_cut_preview()
	cut_mode_changed.emit(cut_mode)
	preview_changed.emit()


func has_cut_preview() -> bool:
	_sync_pending_drag()
	if not _cut_preview:
		return false
	if cut_mode == "ring":
		return _preview_rx >= 0.008 and _preview_ry >= 0.008
	return _preview_a.distance_to(_preview_b) >= 0.012


func preview_kind() -> String:
	if not _cut_preview:
		return ""
	return "ring" if cut_mode == "ring" else "straight"


func can_confirm_cut() -> bool:
	return active and tool == "scalpel" and has_cut_preview() and not _cut_anim


func is_cut_animating() -> bool:
	return _cut_anim


func straight_preview_ends() -> Array:
	_sync_pending_drag()
	return [_preview_a, _preview_b]


func ring_preview_params() -> Dictionary:
	_sync_pending_drag()
	return {"center": _preview_center, "rx": _preview_rx, "ry": _preview_ry}


func evert_profile() -> Dictionary:
	return _measure_evert_profile(_outer if _outer_evert == null else _mesh_evert_blend())


func evert_mid_width() -> float:
	return float(evert_profile().get("mid", 0.0))


func evert_end_width() -> float:
	return float(evert_profile().get("ends", 0.0))


func cavity_clears_lower_back(margin: float = 0.002) -> bool:
	if _wrap == null or _wrap.vert_count() < 1:
		return false
	var zmin := 1e9
	var lumbar_lo := _navel_rest.y - 0.16
	var lumbar_hi := _navel_rest.y - 0.02
	for p in _wrap.pos:
		zmin = minf(zmin, p.z)
		if p.y >= lumbar_lo and p.y <= lumbar_hi:
			if _lumbar_z > -1e8 and p.z < _lumbar_z + margin:
				return false
	if _lumbar_z > -1e8 and zmin < _lumbar_z + margin:
		return false
	# Documented bound: the bag stays in front of the sampled lumbar exterior.
	return true


func lumbar_safe_z() -> float:
	return _lumbar_z


func has_incision_trail() -> bool:
	return _preview != null and _preview.visible and _trail_bind.size() >= 2


func incision_trail_point_count() -> int:
	return _trail_bind.size()


func incision_trail_visible_without_xray() -> bool:
	# 涂鸦不依赖透视；只要轨迹在且材质不是透视专用隐藏。
	if _preview == null or _trail_bind.size() < 2:
		return false
	return _preview.visible and _preview.mesh != null


func preview_path_bind() -> PackedVector3Array:
	_sync_pending_drag()
	return _preview_path_bind()


func committed_path_bind() -> PackedVector3Array:
	if last_embedded_bind.size() >= 2:
		return last_embedded_bind
	return last_commit_path


func preview_matches_commit(tol: float = 0.004) -> bool:
	var a := last_commit_path
	if a.is_empty():
		a = last_embedded_bind
	var b := _preview_compare_path
	if b.is_empty():
		b = path_points
	if a.size() < 2 or b.size() < 2:
		return false
	return _path_max_deviation(a, b) <= tol


func preview_commit_deviation() -> float:
	var a := last_commit_path
	if a.is_empty():
		a = last_embedded_bind
	var b := _preview_compare_path
	if b.is_empty():
		b = path_points
	return _path_max_deviation(a, b)


func preview_geometry_ok(max_extent: float = 0.55) -> bool:
	var st: Dictionary = preview_geometry_stats()
	if not bool(st.get("ok", false)):
		return false
	for key in ["path", "dash", "handles", "trail"]:
		var item: Dictionary = st.get(key, {})
		if item.is_empty() or not bool(item.get("present", false)):
			continue
		if float(item.get("bind_extent", 0.0)) > max_extent:
			return false
		if float(item.get("world_extent", 0.0)) > max_extent:
			return false
	return true


func surgery_visuals_on_abdomen_scale(max_extent: float = 0.85) -> bool:
	## 预览虚线/手柄、涂鸦、腹网、截面、皮瓣的尺寸都应停在腹部量级，不能被拉到天上。
	return surgery_visuals_scale_report(max_extent).get("ok", false)


func surgery_visuals_scale_report(max_extent: float = 0.85) -> Dictionary:
	var out := {"ok": true, "reason": "", "parts": {}}
	if has_cut_preview() and not preview_geometry_ok(0.55):
		out["ok"] = false
		out["reason"] = "preview"
		out["parts"] = preview_geometry_stats()
		return out
	var names := ["abdomen", "cavity", "wall", "trail", "dash", "handles"]
	var meshes: Array = [_surgical_mi, _cavity_mi, _wall_mi, _preview, _dash, _handles]
	for i in names.size():
		var st: Dictionary = _visual_mesh_stats(meshes[i] as MeshInstance3D)
		out["parts"][names[i]] = st
		if st.is_empty() or not bool(st.get("present", false)):
			continue
		# 腹腔袋/腹网本身大约 0.5；天空级伸展是数米，不是稍超 0.8。
		if float(st.get("bind_extent", 0.0)) > max_extent or float(st.get("world_extent", 0.0)) > max_extent:
			out["ok"] = false
			out["reason"] = "%s bind=%.3f world=%.3f maxmag=%.3f" % [names[i], float(st.get("bind_extent", 0.0)), float(st.get("world_extent", 0.0)), float(st.get("maxmag", 0.0))]
			return out
	if flap_node and is_instance_valid(flap_node):
		var fa := _flap_aabb()
		out["parts"]["flap"] = {"present": true, "world_extent": fa.size.length()}
		if fa.size.length() > max_extent:
			out["ok"] = false
			out["reason"] = "flap extent=%.3f" % fa.size.length()
	return out


func preview_geometry_stats() -> Dictionary:
	var out := {
		"ok": true,
		"path": _path_extent_stats(path_points if not path_points.is_empty() else _preview_path_bind()),
		"dash": _visual_mesh_stats(_dash),
		"handles": _visual_mesh_stats(_handles),
		"trail": _visual_mesh_stats(_preview),
	}
	for key in ["path", "dash", "handles", "trail"]:
		var item: Dictionary = out[key]
		if item.is_empty():
			continue
		if bool(item.get("present", false)) and (float(item.get("bind_extent", 0.0)) > 0.55 or float(item.get("world_extent", 0.0)) > 0.55):
			out["ok"] = false
	return out


func trail_half_width() -> float:
	return TRAIL_HALF_WIDTH


func trail_is_narrower_than_v035() -> bool:
	return TRAIL_HALF_WIDTH < TRAIL_HALF_WIDTH_V035 - 0.0005


func trail_is_lighter_than_v035() -> bool:
	# 0.3.5 深色约 (0.38, 0.02, 0.03) / 亮色 (0.95, 0.12, 0.10)。
	var deep_old := Color(0.38, 0.02, 0.03)
	var bright_old := Color(0.95, 0.12, 0.10)
	return TRAIL_COLOR_DEEP.r + TRAIL_COLOR_DEEP.g + TRAIL_COLOR_DEEP.b > deep_old.r + deep_old.g + deep_old.b + 0.3 \
		and TRAIL_COLOR_BRIGHT.g + TRAIL_COLOR_BRIGHT.b > bright_old.g + bright_old.b + 0.3


func flap_is_independent() -> bool:
	return flap_peeled and flap_node != null and is_instance_valid(flap_node) and (flap_kind == "rigid" or flap_node is RigidBody3D)


func flap_stretch_ratio() -> float:
	if flap_node == null or not is_instance_valid(flap_node):
		return 1.0
	var aabb := _flap_aabb()
	if aabb.size.length() < 1e-6 or _flap_rest_size.length() < 1e-6:
		return 1.0
	var sx := aabb.size.x / maxf(_flap_rest_size.x, 1e-5)
	var sy := aabb.size.y / maxf(_flap_rest_size.y, 1e-5)
	var sz := aabb.size.z / maxf(_flap_rest_size.z, 1e-5)
	return maxf(sx, maxf(sy, sz))


func _abdomen_bind_aabb() -> AABB:
	if _outer == null or _outer.vert_count() < 1:
		return AABB()
	var ab := AABB(_outer.pos[0], Vector3.ZERO)
	for i in range(1, _outer.vert_count()):
		ab = ab.expand(_outer.pos[i])
	return ab


func _path_extent_stats(pts: PackedVector3Array) -> Dictionary:
	if pts.size() < 1:
		return {"present": false, "bind_extent": 0.0, "world_extent": 0.0, "maxmag": 0.0}
	var ab := AABB(pts[0], Vector3.ZERO)
	var maxmag := 0.0
	for p in pts:
		ab = ab.expand(p)
		maxmag = maxf(maxmag, p.length())
	var wab := AABB()
	var have_w := false
	for p2 in pts:
		var wp: Vector3 = _approx_world_bind(p2)
		if not have_w:
			wab = AABB(wp, Vector3.ZERO)
			have_w = true
		else:
			wab = wab.expand(wp)
	return {
		"present": pts.size() >= 1,
		"bind_extent": ab.size.length(),
		"world_extent": wab.size.length() if have_w else 0.0,
		"maxmag": maxmag,
	}


func _visual_mesh_stats(mi: MeshInstance3D) -> Dictionary:
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() < 1:
		return {"present": false, "bind_extent": 0.0, "world_extent": 0.0, "maxmag": 0.0}
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return {"present": false, "bind_extent": 0.0, "world_extent": 0.0, "maxmag": 0.0}
	var ab := mi.mesh.get_aabb()
	var maxmag := 0.0
	for p in verts:
		maxmag = maxf(maxmag, p.length())
	var wab := AABB()
	var have_w := false
	var bones: PackedInt32Array = PackedInt32Array()
	var weights: PackedFloat32Array = PackedFloat32Array()
	if arr[Mesh.ARRAY_BONES] != null:
		bones = arr[Mesh.ARRAY_BONES]
	if arr[Mesh.ARRAY_WEIGHTS] != null:
		weights = arr[Mesh.ARRAY_WEIGHTS]
	var can_skin: bool = mi.skin != null and _skel != null and bones.size() >= verts.size() * 4 and weights.size() >= verts.size() * 4
	for i in verts.size():
		var wp: Vector3
		if can_skin:
			wp = _skel.global_transform * _skin_array_vertex(verts[i], i, bones, weights, mi.skin)
		elif mi.get_parent() == _skel:
			wp = _approx_world_bind(verts[i])
		else:
			wp = mi.global_transform * verts[i]
		if not have_w:
			wab = AABB(wp, Vector3.ZERO)
			have_w = true
		else:
			wab = wab.expand(wp)
	return {
		"present": true,
		"bind_extent": ab.size.length(),
		"world_extent": wab.size.length() if have_w else 0.0,
		"maxmag": maxmag,
	}


func _skin_array_vertex(p: Vector3, vi: int, bones: PackedInt32Array, weights: PackedFloat32Array, skin: Skin) -> Vector3:
	if _skel == null or skin == null:
		return p
	var acc := Vector3.ZERO
	var wsum := 0.0
	for k in 4:
		var w: float = float(weights[vi * 4 + k])
		if w <= 1e-8:
			continue
		var bind_i: int = int(bones[vi * 4 + k])
		var rec: Dictionary = Geom.resolve_skin_bind(skin, _skel, bind_i)
		var bone_i: int = int(rec["bone"])
		if bone_i < 0 or bone_i >= _skel.get_bone_count():
			continue
		var xform := _skel.get_bone_global_pose(bone_i) * (rec["pose"] as Transform3D)
		acc += w * (xform * p)
		wsum += w
	if wsum <= Geom.EPS:
		return p
	return acc / wsum


func _path_max_deviation(a: PackedVector3Array, b: PackedVector3Array) -> float:
	if a.is_empty() or b.is_empty():
		return 1e9
	var worst := 0.0
	for p in a:
		var best := 1e9
		for i in range(b.size() - 1):
			best = minf(best, _dist_point_segment(p, b[i], b[i + 1]))
		best = minf(best, _dist_point_segment(p, b[b.size() - 1], b[0]) if b.size() >= 3 and a[0].distance_to(a[a.size() - 1]) <= Geom.PATH_CLOSE_DIST * 3.0 else best)
		# also endpoints
		best = minf(best, p.distance_to(b[0]))
		best = minf(best, p.distance_to(b[b.size() - 1]))
		worst = maxf(worst, best)
	for p2 in b:
		var best2 := 1e9
		for j in range(a.size() - 1):
			best2 = minf(best2, _dist_point_segment(p2, a[j], a[j + 1]))
		best2 = minf(best2, p2.distance_to(a[0]))
		best2 = minf(best2, p2.distance_to(a[a.size() - 1]))
		worst = maxf(worst, best2)
	return worst


func _dist_point_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-12 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a.lerp(b, t))



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
	if player == null:
		return false
	if str(player.get("occupancy")) == "exam_bed":
		return true
	# 分身躺在检查床上时也可进入手术（操作者站在旁边）。
	if player.has_method("is_on_exam_bed"):
		return bool(player.call("is_on_exam_bed"))
	return player.get("on_exam_bed") != null and is_instance_valid(player.get("on_exam_bed"))


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


func _flap_aabb() -> AABB:
	if flap_node == null or not is_instance_valid(flap_node):
		return AABB()
	if flap_node is RigidBody3D:
		for c in flap_node.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh:
				var ab := (c as MeshInstance3D).mesh.get_aabb()
				return (c as MeshInstance3D).global_transform * ab
			if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
				var box := (c as CollisionShape3D).shape as BoxShape3D
				var xf := (c as CollisionShape3D).global_transform
				return xf * AABB(-box.size * 0.5, box.size)
		return AABB(flap_node.global_position, Vector3.ZERO)
	if flap_node is SoftBody3D:
		var mi := flap_node as SoftBody3D
		if mi.mesh:
			return mi.global_transform * mi.mesh.get_aabb()
	if flap_node is MeshInstance3D and (flap_node as MeshInstance3D).mesh:
		return flap_node.global_transform * (flap_node as MeshInstance3D).mesh.get_aabb()
	for c2 in flap_node.get_children():
		if c2 is MeshInstance3D and (c2 as MeshInstance3D).mesh:
			return (c2 as MeshInstance3D).global_transform * (c2 as MeshInstance3D).mesh.get_aabb()
	if flap_node is Node3D:
		return AABB((flap_node as Node3D).global_position, Vector3.ZERO)
	return AABB()


func _flap_aabb_min() -> Vector3:
	var ab := _flap_aabb()
	if ab.size.length_squared() < 1e-12:
		return Vector3(0, -999, 0)
	return ab.position



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
	_clear_cut_preview()
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
	_clear_cut_preview()
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


## 0.3.8「复原身体」：撤掉所有手术切口 / 皮瓣 / 腹腔 / 弹孔冲压，Dress 换回原始网格；手术模式中则立即重新烘焙干净腹网。
func restore_body() -> void:
	var was_active := active
	if _grab_active:
		_end_grab(false)
	stroke_active = false
	_drag_pending = false
	_cut_anim = false
	_clear_cut_preview()
	_clear_trail()
	_show_scalpel(false)
	if flap_node and is_instance_valid(flap_node):
		flap_node.queue_free()
	flap_node = null
	flap_kind = ""
	for n in [_grab_anchor, _flap_catch, _surgical_mi, _cavity_mi, _wall_mi]:
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
	_grab_anchor = null
	_flap_catch = null
	_surgical_mi = null
	_cavity_mi = null
	_wall_mi = null
	if _dress and _dress_mesh_orig:
		_dress.mesh = _dress_mesh_orig
		if _skin:
			_dress.skin = _skin
	_outer = null
	_inner = null
	_rest = null
	_wall_md = null
	_wrap = null
	_outer_rest = null
	_inner_rest = null
	_wall_rest = null
	_outer_evert = null
	_inner_evert = null
	_wall_evert = null
	_baked = false
	cut_open = false
	loop_ready = false
	flap_peeled = false
	cavity_exposed = false
	persist = false
	lofted_tris = 0
	path_points = PackedVector3Array()
	_path_ids = PackedInt32Array()
	_flap_loop = PackedInt32Array()
	_body_loop = PackedInt32Array()
	_loop_out = PackedInt32Array()
	_loop_in = PackedInt32Array()
	_trail_bind = PackedVector3Array()
	_evert = 0.0
	_evert_vel = 0.0
	_evert_anim = false
	_lip_left = PackedInt32Array()
	_lip_right = PackedInt32Array()
	_lip_left_i = PackedInt32Array()
	_lip_right_i = PackedInt32Array()
	_lip_closed = false
	_hole_loops = []
	_split_dir = Vector3.ZERO
	_pull_off = Vector3.ZERO
	_pull_raw = Vector3.ZERO
	_pull_r = 0.0
	_pull_mode = 0
	_pull_peak = 0.0
	_pull_rest = Vector3.ZERO
	_split_drag = 0.0
	_flap_goal_set = false
	_apply_pull_uniforms()
	_pinned_points = PackedInt32Array()
	bullet_holes = 0
	bullet_wall_tris = 0
	bullet_plugs_removed = 0
	_posed_cache = PackedVector3Array()
	_posed_frozen = PackedVector3Array()
	_posed_dirty = true
	_invalidate_grid()
	_anim_world = PackedVector3Array()
	_anim_src = PackedVector3Array()
	_xray_cached = -1
	if pose_locked:
		_lock_pose_for_stroke(false)
	if was_active:
		_bake_if_needed()
		_update_cavity_visibility()
	preview_changed.emit()


func is_body_pristine() -> bool:
	return not cut_open and not flap_peeled and bullet_holes == 0 and flap_node == null and _trail_bind.is_empty() and (_dress == null or _dress_mesh_orig == null or _dress.mesh == _dress_mesh_orig or active)


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
	if _cut_anim:
		return false
	_lock_pose_for_stroke(true)
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	var bind_p := Vector3.ZERO
	var world_p := Vector3.ZERO
	if hit != null:
		bind_p = (hit as Dictionary)["bind"]
		world_p = (hit as Dictionary)["point"]
	# 已有预览：优先拖动起止点 / 椭圆控制点。未点中腹部时也允许靠近手柄。
	if has_cut_preview():
		var h := _pick_preview_handle(origin, dir, bind_p if hit != null else Vector3.INF)
		if h != "":
			_preview_handle = h
			stroke_active = true
			_preview_drag_start = bind_p if hit != null else _handle_bind(h)
			_preview_center0 = _preview_center
			_preview_rx0 = _preview_rx
			_preview_ry0 = _preview_ry
			if hit != null:
				_place_scalpel(world_p, dir)
			_show_scalpel(true)
			_update_cut_preview()
			return true
	if hit == null:
		_lock_pose_for_stroke(false)
		return false
	# 新预览：按下并拖出直线或椭圆，松手后仍只是预览，必须按「切割」才提交。
	stroke_active = true
	_preview_handle = "new"
	_cut_preview = true
	if cut_mode == "ring":
		_preview_center = bind_p
		_preview_rx = 0.01
		_preview_ry = 0.01
		_preview_drag_start = bind_p
	else:
		cut_mode = "straight"
		_preview_a = bind_p
		_preview_b = bind_p
		_preview_drag_start = bind_p
	_place_scalpel(world_p, dir)
	_show_scalpel(true)
	_update_cut_preview()
	preview_changed.emit()
	return true


func drag_stroke(origin: Vector3, dir: Vector3) -> void:
	if tool == "grab" and _grab_active:
		_drag_grab(origin, dir)
		return
	if not stroke_active or tool != "scalpel" or _cut_anim:
		return
	# 0.3.8：同一帧里的多次拖动事件只处理最后一次（鼠标 / 触屏一帧可能来好几次），其余在 _process / 松手时补上。
	var f := Engine.get_process_frames()
	if f == _drag_last_frame:
		_drag_pending = true
		_drag_pend_o = origin
		_drag_pend_d = dir
		return
	_drag_last_frame = f
	_drag_pending = false
	_do_drag_stroke(origin, dir)


var _drag_pending: bool = false
var _drag_pend_o: Vector3 = Vector3.ZERO
var _drag_pend_d: Vector3 = Vector3.FORWARD
var _drag_last_frame: int = -1
var preview_rebuilds: int = 0


## 查询预览状态前先补上本帧被合并的拖动事件，状态永远与最后一次输入一致。
func _sync_pending_drag() -> void:
	if _drag_pending:
		_flush_pending_drag()


func _flush_pending_drag() -> void:
	_drag_pending = false
	if stroke_active and tool == "scalpel" and not _cut_anim:
		_drag_last_frame = Engine.get_process_frames()
		_do_drag_stroke(_drag_pend_o, _drag_pend_d)


func _do_drag_stroke(origin: Vector3, dir: Vector3) -> void:
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	var bind_p: Vector3
	if hit != null:
		bind_p = (hit as Dictionary)["bind"]
		_place_scalpel((hit as Dictionary)["point"], dir)
	else:
		bind_p = _ray_to_preview_plane(origin, dir)
	_apply_preview_drag(bind_p)
	_update_cut_preview()


func cancel_stroke() -> void:
	_drag_pending = false
	if _grab_active:
		_end_grab(false)
	if not stroke_active:
		return
	stroke_active = false
	var was_new := _preview_handle == "new"
	_preview_handle = ""
	_show_scalpel(false)
	path_points = PackedVector3Array()
	if was_new and not has_cut_preview():
		_clear_cut_preview()
	_lock_pose_for_stroke(false)
	preview_changed.emit()


func end_stroke() -> void:
	if _drag_pending:
		_flush_pending_drag()
	if _grab_active:
		_end_grab(true)
		stroke_active = false
		return
	if not stroke_active:
		return
	stroke_active = false
	_preview_handle = ""
	_show_scalpel(false)
	# 不再在松手时提交切口：预览必须等「切割」按钮。
	if has_cut_preview():
		_update_cut_preview()
	else:
		_clear_cut_preview()
	_lock_pose_for_stroke(false)
	preview_changed.emit()


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


func debug_set_straight_preview(a: Vector3, b: Vector3) -> bool:
	if not active or not _bake_if_needed():
		return false
	if tool != "scalpel":
		set_tool("scalpel")
	cut_mode = "straight"
	_preview_a = a
	_preview_b = b
	_cut_preview = true
	_update_cut_preview()
	preview_changed.emit()
	return has_cut_preview()


func debug_set_ring_preview(center: Vector3, rx: float, ry: float) -> bool:
	if not active or not _bake_if_needed():
		return false
	if tool != "scalpel":
		set_tool("scalpel")
	cut_mode = "ring"
	_preview_center = center
	_preview_rx = maxf(rx, 0.008)
	_preview_ry = maxf(ry, 0.008)
	_cut_preview = true
	_update_cut_preview()
	preview_changed.emit()
	return has_cut_preview()


func debug_move_ring_preview(delta: Vector3) -> bool:
	if not has_cut_preview() or cut_mode != "ring":
		return false
	_preview_center += delta
	_update_cut_preview()
	preview_changed.emit()
	return true


func debug_reshape_ring_preview(rx: float, ry: float) -> bool:
	if not has_cut_preview() or cut_mode != "ring":
		return false
	_preview_rx = maxf(rx, 0.008)
	_preview_ry = maxf(ry, 0.008)
	_update_cut_preview()
	preview_changed.emit()
	return true


func debug_drag_preview_end(which: String, bind_p: Vector3) -> bool:
	if not has_cut_preview() or cut_mode != "straight":
		return false
	if which == "start" or which == "a":
		_preview_a = bind_p
	else:
		_preview_b = bind_p
	_update_cut_preview()
	preview_changed.emit()
	return has_cut_preview()


func confirm_cut(animate: bool = true) -> bool:
	## 按下「切割」后执行：手术刀沿预览轨迹走一圈/一段，再提交切口。
	if not can_confirm_cut():
		return false
	var path := _preview_path_bind()
	if path.size() < 2:
		return false
	_lock_pose_for_stroke(true)
	last_cut_animated = false
	if animate:
		_cut_anim = true
		_cut_anim_t = 0.0
		_cut_anim_dur = 1.0 if cut_mode == "ring" else 0.65
		_cut_anim_path = path
		_cut_anim_closed = cut_mode == "ring"
		last_cut_animated = true
		_show_scalpel(true)
		_place_scalpel_on_path(0.0)
		return true
	return _finish_confirmed_cut(path, cut_mode == "ring")


func debug_confirm_cut(animate: bool = false) -> bool:
	return confirm_cut(animate)


func debug_advance_cut_anim(sec: float) -> void:
	if not _cut_anim:
		return
	_cut_anim_t += maxf(sec, 0.0)
	var u := clampf(_cut_anim_t / maxf(_cut_anim_dur, 0.001), 0.0, 1.0)
	_place_scalpel_on_path(u)
	if u >= 1.0:
		_finish_confirmed_cut(_cut_anim_path, _cut_anim_closed)


func debug_finish_cut_anim() -> bool:
	if not _cut_anim:
		return cut_open
	return _finish_confirmed_cut(_cut_anim_path, _cut_anim_closed)


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
	# 0.3.8：前 flap_o.face_count() 个三角是皮瓣外表面（正常皮肤），其余（内面 + 周圈断面）才是红色截面。
	_flap_outer_faces = flap_o.face_count()
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
	elif work.size() > 24:
		# 预览直线/环状路径已经很稀疏，不再简化，以免切口偏离虚线。
		work = Geom.simplify_path(work, 0.003, 48)
	_preview_compare_path = path.duplicate()
	last_commit_path = work.duplicate()
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
	last_embedded_bind = PackedVector3Array()
	for id in ids:
		if id >= 0 and id < _outer.vert_count():
			last_embedded_bind.append(_outer.pos[id])
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
	if work.size() >= 2:
		# 涂鸦跟提交路径一致，不再用未经同一套嵌入的原始副本。
		_trail_bind = work.duplicate()
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
	_lumbar_z = Geom.lumbar_exterior_z(_rest, _navel_rest)
	var back_z := minf(_guts_min.z - 0.006, organ_z - 0.055)
	_wrap = Geom.make_cavity_wrap(_inner, back_z, _guts_min, _guts_max, _lumbar_z)
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
	_invalidate_grid()
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
		mat.set_shader_parameter("trail_color_deep", Vector3(TRAIL_COLOR_DEEP.r, TRAIL_COLOR_DEEP.g, TRAIL_COLOR_DEEP.b))
		mat.set_shader_parameter("trail_color_bright", Vector3(TRAIL_COLOR_BRIGHT.r, TRAIL_COLOR_BRIGHT.g, TRAIL_COLOR_BRIGHT.b))
		mat.set_shader_parameter("trail_alpha", TRAIL_ALPHA)
		_trail_mat = mat
		_register_deform_mat(mat)
	else:
		var fb := StandardMaterial3D.new()
		fb.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		fb.albedo_color = TRAIL_FALLBACK_COLOR
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
	var half := TRAIL_HALF_WIDTH
	var lift := 0.0016
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
	if _outer == null or _skel == null or _outer.vert_count() < 1:
		return bind_p
	var best := _nearest_outer(bind_p)
	if pose_locked and _posed_frozen.size() > best:
		return _posed_frozen[best]
	var posed := Geom.skin_vertex(bind_p, best, _outer, _skel, _skin)
	return _skel.global_transform * posed


var _grid: Dictionary = {}
var _grid_src: Object = null
var grid_builds: int = 0


## 0.3.8：腹网 XY 网格索引（预览投影 / 最近顶点加速）；腹网拓扑一变就重建。
func _outer_grid() -> Dictionary:
	if _outer == null:
		return {}
	if _grid_src != _outer or not Geom.grid_valid(_outer, _grid):
		_grid = Geom.build_xy_grid(_outer)
		_grid_src = _outer
		grid_builds += 1
	return _grid


func _invalidate_grid() -> void:
	_grid = {}
	_grid_src = null


func _nearest_outer(bind_p: Vector3) -> int:
	return maxi(0, Geom.nearest_vertex_grid(_outer, _outer_grid(), bind_p))


func _approx_world_and_normal(bind_p: Vector3) -> Array:
	var w := _approx_world_bind(bind_p)
	var nrm := Vector3(0, 0, 1)
	if _outer == null:
		return [w, nrm]
	var posed := _posed_world()
	if posed.size() != _outer.vert_count():
		return [w, nrm]
	var best := _nearest_outer(bind_p)
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


## 0.3.8：正式手术刀模型（assets/surgery/scalpel.glb）。模型长轴沿 X，刀尖在 -X 端，刀身平面为 XZ。
## 运行时量出刀尖顶点和总长，把刀尖放到 _scalpel 原点、整把缩放到 SCALPEL_LEN；
## 摆放时刀尖贴在切点，刀柄沿行进方向后仰约 45°、刃口朝皮肤。模型缺失时回退到白色圆柱（CylinderMesh）。
const SCALPEL_LEN := 0.145
const SCALPEL_TILT := 0.75  # 刀柄离开皮肤的仰角（弧度，约 43°）
var scalpel_model_loaded: bool = false
var scalpel_tip_local: Vector3 = Vector3.ZERO
var _scalpel_last_p: Vector3 = Vector3.INF
var _scalpel_tan: Vector3 = Vector3.ZERO


func _collect_mesh_points(n: Node, xf: Transform3D, out: PackedVector3Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var m: Mesh = (n as MeshInstance3D).mesh
		for si in m.get_surface_count():
			var pts: PackedVector3Array = m.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			for pt in pts:
				out.append(t * pt)
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_collect_mesh_points(c, t, out)


func _make_scalpel() -> void:
	_scalpel = Node3D.new()
	_scalpel.name = "SurgeryScalpel"
	scalpel_model_loaded = false
	if ResourceLoader.exists(SCALPEL_GLB):
		var packed := load(SCALPEL_GLB)
		if packed is PackedScene:
			var inst: Node = (packed as PackedScene).instantiate()
			if inst is Node3D:
				var pts := PackedVector3Array()
				_collect_mesh_points(inst, Transform3D.IDENTITY, pts)
				if pts.size() > 3:
					var tip := pts[0]
					var mx := pts[0].x
					for pt in pts:
						if pt.x < tip.x:
							tip = pt
						mx = maxf(mx, pt.x)
					var sc := SCALPEL_LEN / maxf(mx - tip.x, 1e-4)
					var holder := Node3D.new()
					holder.name = "ScalpelModel"
					holder.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sc), -tip * sc)
					holder.add_child(inst)
					_scalpel.add_child(holder)
					scalpel_tip_local = Vector3.ZERO
					scalpel_model_loaded = true
				else:
					inst.free()
			else:
				inst.free()
	if not scalpel_model_loaded:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1, 1, 1)
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.0025
		cyl.bottom_radius = 0.004
		cyl.height = 0.11
		cyl.radial_segments = 10
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = mat
		# 圆柱沿 Y；转到 -X 方向为刀尖、底端在原点，与正式模型同一套朝向。
		mi.transform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0.055, 0, 0))
		_scalpel.add_child(mi)
	add_child(_scalpel)
	_scalpel.visible = false


func _show_scalpel(on: bool) -> void:
	if _scalpel:
		_scalpel.visible = on
		if not on:
			_scalpel_last_p = Vector3.INF


## dir/nrm：给了 nrm 时 dir 是切割行进方向（动画沿路径）；否则 dir 是视线，用相邻两次落点估计行进方向。
func _place_scalpel(world_p: Vector3, dir: Vector3, nrm: Vector3 = Vector3.ZERO) -> void:
	if _scalpel == null:
		return
	var n := nrm
	var tan := dir
	if n.length_squared() < 1e-8:
		n = -dir.normalized()
		if _scalpel_last_p != Vector3.INF and world_p.distance_to(_scalpel_last_p) > 0.002:
			_scalpel_tan = (world_p - _scalpel_last_p).normalized()
		if _scalpel_last_p == Vector3.INF or world_p.distance_to(_scalpel_last_p) > 0.002:
			_scalpel_last_p = world_p
		tan = _scalpel_tan
	n = n.normalized()
	tan = tan - n * tan.dot(n)
	if tan.length_squared() < 1e-6:
		# 没有行进方向：刀柄朝屏幕上方 / 身体头部方向。
		tan = Vector3.UP - n * Vector3.UP.dot(n)
		if tan.length_squared() < 1e-6:
			tan = Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
		tan = -tan
	tan = tan.normalized()
	var ca := cos(SCALPEL_TILT)
	var sa := sin(SCALPEL_TILT)
	var tip_dir := (tan * ca - n * sa).normalized()    # 刀柄 → 刀尖
	var edge := (-n * ca - tan * sa).normalized()      # 刃口朝皮肤
	var xw := -tip_dir
	var zw := edge
	var yw := zw.cross(xw).normalized()
	_scalpel.global_transform = Transform3D(Basis(xw, yw, zw), world_p)


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
	# 把皮瓣烘到世界空间，做成像空弹匣一样的独立刚体，不再用会异常拉伸的柔体。
	if _skel == null:
		return false
	var world_md := Geom.MeshData.new()
	var empty_b := PackedInt32Array([0, 0, 0, 0])
	var empty_w := PackedFloat32Array([0, 0, 0, 0])
	for i in flap_md.vert_count():
		var wp: Vector3
		if flap_md.bones.size() >= (i + 1) * 4 and _skin:
			wp = Geom.skin_vertex(flap_md.pos[i], i, flap_md, _skel, _skin)
			if _skel:
				wp = _skel.global_transform * wp
		elif i < flap_outer.vert_count():
			var posed := Geom.world_positions(flap_outer, _skel, _skin)
			wp = posed[i] if i < posed.size() else _approx_world_bind(flap_md.pos[i])
		else:
			wp = _approx_world_bind(flap_md.pos[i])
		world_md.add_vert(wp, flap_md.nrm[i], flap_md.uv[i], empty_b, empty_w)
	world_md.idx = flap_md.idx.duplicate()
	world_md.bones = PackedInt32Array()
	world_md.weights = PackedFloat32Array()
	_ensure_flap_catch()
	var top := _catch_top_y()
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
	# 重新计算质心，顶点改成本地坐标，刚体原点放在质心，避免巨型未居中网格把物理撑坏。
	c = Vector3.ZERO
	for i5 in world_md.vert_count():
		c += world_md.pos[i5]
	if world_md.vert_count() > 0:
		c /= float(world_md.vert_count())
	for i6 in world_md.vert_count():
		world_md.pos[i6] -= c
	var mesh := _flap_two_surface_mesh(world_md, _flap_outer_faces)
	if mesh.get_surface_count() < 1:
		return false
	if flap_node and is_instance_valid(flap_node):
		flap_node.queue_free()
		flap_node = null
	var parent: Node = player.get_parent() if player else get_tree().current_scene
	if parent == null:
		parent = self
	if _spawn_flap_rigid(mesh, c, parent):
		return true
	# 刚体创建失败时才退回 Verlet，仍保持独立实体、不粘在骨架上。
	for i7 in world_md.vert_count():
		world_md.pos[i7] += c
	return _spawn_flap_verlet(world_md, parent)


func _spawn_flap_rigid(mesh: ArrayMesh, origin: Vector3, parent: Node) -> bool:
	var body := RigidBody3D.new()
	body.name = "SurgeryFlap"
	body.mass = 0.28
	body.gravity_scale = 1.0
	body.continuous_cd = true
	body.linear_damp = 0.35
	body.angular_damp = 0.55
	body.collision_layer = 1
	body.collision_mask = 1 | (1 << (CATCH_LAYER - 1))
	var mi := MeshInstance3D.new()
	mi.name = "FlapMesh"
	mi.mesh = mesh
	# 0.3.8：外表面用正常皮肤材质，只有截面（内面 + 周圈壁）是红色。
	# 两种材质都不注册腹部形变：皮瓣已是独立刚体，不能再被腹部拖拽 / 拿取的 shader 位移扭曲。
	if mesh.get_surface_count() >= 2:
		mi.set_surface_override_material(0, _flap_skin_material())
		mi.set_surface_override_material(1, _flap_cut_material())
	else:
		mi.material_override = _flap_cut_material()
	body.add_child(mi)
	var col := CollisionShape3D.new()
	col.name = "FlapShape"
	var aabb := mesh.get_aabb()
	var box := BoxShape3D.new()
	# 薄皮瓣用略加厚的盒子，保证能被抓取和碰撞，又不会像柔体那样被拉长。
	box.size = Vector3(maxf(aabb.size.x, 0.012), maxf(aabb.size.y, 0.008), maxf(aabb.size.z, 0.012))
	col.shape = box
	col.position = aabb.get_center()
	body.add_child(col)
	parent.add_child(body)
	body.global_transform = Transform3D(Basis.IDENTITY, origin)
	if "max_contacts_reported" in body:
		body.max_contacts_reported = 4
	flap_node = body
	flap_kind = "rigid"
	_flap_rest_size = box.size
	return true



## 皮瓣网格分两个 surface：0 = 外表面（皮肤），1 = 内面 + 周圈断面（红色）。
func _flap_two_surface_mesh(md: Geom.MeshData, outer_faces: int) -> ArrayMesh:
	var nf := md.face_count()
	var split := clampi(outer_faces, 0, nf)
	if split <= 0 or split >= nf:
		return md.to_array_mesh()
	var am := ArrayMesh.new()
	for part in 2:
		var f0 := 0 if part == 0 else split
		var f1 := split if part == 0 else nf
		var sub := Geom.MeshData.new()
		var remap: Dictionary = {}
		var empty_b := PackedInt32Array([0, 0, 0, 0])
		var empty_w := PackedFloat32Array([0, 0, 0, 0])
		for f in range(f0, f1):
			var ids := PackedInt32Array()
			for k in 3:
				var vi: int = md.idx[f * 3 + k]
				if not remap.has(vi):
					remap[vi] = sub.add_vert(md.pos[vi], md.nrm[vi], md.uv[vi], empty_b, empty_w)
				ids.append(int(remap[vi]))
			sub.add_face(ids[0], ids[1], ids[2])
		sub.bones = PackedInt32Array()
		sub.weights = PackedFloat32Array()
		if sub.face_count() < 1:
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = sub.pos
		arrays[Mesh.ARRAY_NORMAL] = sub.nrm
		arrays[Mesh.ARRAY_TEX_UV] = sub.uv
		arrays[Mesh.ARRAY_INDEX] = sub.idx
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


var _flap_skin_mat: Material = null
var _flap_cut_mat: ShaderMaterial = null


## 皮瓣外表面：沿用身体皮肤的贴图（albedo / 法线），但用普通 StandardMaterial3D，不跟腹部形变 / 透视挖孔。
func _flap_skin_material() -> Material:
	if _flap_skin_mat:
		return _flap_skin_mat
	var src: Material = _dress.get_active_material(0) if _dress else null
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.62
	m.metallic = 0.0
	m.metallic_specular = 0.32
	m.albedo_color = Color(0.93, 0.80, 0.74)
	if src is ShaderMaterial:
		var sm := src as ShaderMaterial
		var tex = sm.get_shader_parameter("albedo_tex")
		if tex is Texture2D:
			m.albedo_texture = tex
			m.albedo_color = Color(1, 1, 1)
			var ac = sm.get_shader_parameter("albedo_color")
			if ac is Color:
				m.albedo_color = Color(ac.r, ac.g, ac.b, 1.0)
		var nt = sm.get_shader_parameter("normal_tex")
		var has_n = sm.get_shader_parameter("has_normal")
		if nt is Texture2D and (has_n == null or bool(has_n)):
			m.normal_enabled = true
			m.normal_texture = nt
	elif src is StandardMaterial3D:
		var dup := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
		dup.cull_mode = BaseMaterial3D.CULL_DISABLED
		_flap_skin_mat = dup
		return dup
	_flap_skin_mat = m
	return m


## 皮瓣截面：与切口断面同色，但不注册腹部形变（独立刚体不该被腹部 shader 拉扯）。
func _flap_cut_material() -> ShaderMaterial:
	if _flap_cut_mat == null:
		_flap_cut_mat = _make_shell_material(Color(0.72, 0.28, 0.26, 1.0))
	return _flap_cut_mat


func flap_surface_materials() -> Array:
	## 自检：[外表面材质, 截面材质]（皮瓣不存在时为空）。
	if flap_node == null or not is_instance_valid(flap_node):
		return []
	var mi := flap_node.get_node_or_null("FlapMesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return []
	var out: Array = []
	for i in mi.mesh.get_surface_count():
		out.append(mi.get_surface_override_material(i) if mi.get_surface_override_material(i) else mi.material_override)
	return out


func _spawn_flap_verlet(world_md: Geom.MeshData, parent: Node) -> bool:
	var floor_y := _catch_top_y()
	var flap := load("res://scripts/surgery/surgery_flap_verlet.gd").new() as Node3D
	flap.name = "SurgeryFlap"
	parent.add_child(flap)
	var world: World3D = null
	if flap.get_world_3d():
		world = flap.get_world_3d()
	flap.call("setup_from_mesh", world_md, _flap_cut_material(), world, floor_y)
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
	## 兼容旧测试名：现在只拉出直线预览，松手不提交。真正切开请用 confirm_cut。
	if not active:
		if not enter_surgery():
			return false
	if tool != "scalpel":
		set_tool("scalpel")
	set_cut_mode("straight")
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
	return has_cut_preview() and not cut_open


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
	if _cut_anim:
		debug_advance_cut_anim(dt)
	if _evert_anim:
		_step_eversion(dt)
	if not _grab_active and _pull_off.length_squared() > 1e-8:
		_step_pull_spring(dt)
	if _grab_active and _grab_kind == "flap" and _flap_goal_set and flap_node and is_instance_valid(flap_node):
		var cur := flap_centroid()
		var step := (_flap_goal - cur) * (1.0 - exp(-GRAB_FLAP_FOLLOW * dt))
		if step.length_squared() > 1e-10:
			_move_flap_by(step)
	if _drag_pending:
		_flush_pending_drag()


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
	var best := _nearest_outer(bind_p)
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
	if flap_node is RigidBody3D:
		return (flap_node as RigidBody3D).global_position
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
	_flap_grab_off = flap_centroid() - hit
	_flap_goal = flap_centroid()
	_flap_goal_set = false
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
	_pull_off = Vector3.ZERO
	_pull_raw = Vector3.ZERO
	_pull_r = PULL_RADIUS
	_pull_peak = 0.0
	_pull_rest = Vector3.ZERO
	_split_dir = _skin_split_dir(bind_p)
	_setup_pull_geometry(bind_p, world_p)
	_apply_pull_uniforms()
	return true


## 0.3.8：拿取切口的几何约束。直线切口：只拉被抓的那一侧唇缘，沿切口两端权重为 0（切口端点钉在身上），
## 离切线越远越弱；环形洞缘：只拉被抓的那一段洞缘。避免像 0.3.7 那样把整段切口连同两侧一起拖走错位。
const PULL_RADIUS := 0.055


func _setup_pull_geometry(bind_p: Vector3, world_p: Vector3, want_side: Vector3 = Vector3.ZERO) -> void:
	_pull_p = _to_ab_local(world_p)
	_pull_mode = 0
	_pull_axis = Vector3.ZERO
	if _outer == null:
		return
	var nv := _outer.vert_count()
	var straight := (not _lip_closed) and _lip_left.size() >= 2 and _lip_right.size() >= 2 and _lip_left != _lip_right
	if straight:
		var n := mini(_lip_left.size(), _lip_right.size())
		var l0: int = _lip_left[0]
		var r0: int = _lip_right[0]
		var l1: int = _lip_left[n - 1]
		var r1: int = _lip_right[n - 1]
		if l0 >= nv or r0 >= nv or l1 >= nv or r1 >= nv:
			return
		_pull_a = _to_ab_local(_approx_world_bind((_outer.pos[l0] + _outer.pos[r0]) * 0.5))
		_pull_b = _to_ab_local(_approx_world_bind((_outer.pos[l1] + _outer.pos[r1]) * 0.5))
		var sd_bind := _split_dir if _split_dir.length_squared() > 1e-8 else _skin_split_dir(bind_p)
		if sd_bind.length_squared() < 1e-8:
			return
		# 分开方向是绑定空间的，换算到腹局部空间（与 _pull_a/_pull_b、shader 一致；躺在检查床上两者朝向不同）。
		var mid_bind := (_outer.pos[l0] + _outer.pos[r0] + _outer.pos[l1] + _outer.pos[r1]) * 0.25
		var sd := _to_ab_local(_approx_world_bind(mid_bind + sd_bind.normalized() * 0.01)) - _to_ab_local(_approx_world_bind(mid_bind))
		var ab_dir := (_pull_b - _pull_a).normalized() if (_pull_b - _pull_a).length_squared() > 1e-10 else Vector3.ZERO
		sd -= ab_dir * sd.dot(ab_dir)
		if sd.length_squared() < 1e-10:
			return
		sd = sd.normalized()
		var sign := 1.0
		if want_side.length_squared() > 1e-10:
			sign = 1.0 if want_side.dot(sd) >= 0.0 else -1.0
		else:
			var ab := _pull_b - _pull_a
			var t := clampf((_pull_p - _pull_a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
			var q := _pull_a + ab * t
			var side := (_pull_p - q).dot(sd)
			if absf(side) < 0.0008:
				# 点在切线上：看离哪一侧唇缘顶点更近。
				var dl := 1e9
				var dr := 1e9
				for i in n:
					if _lip_left[i] < nv:
						dl = minf(dl, _outer.pos[_lip_left[i]].distance_squared_to(bind_p))
					if _lip_right[i] < nv:
						dr = minf(dr, _outer.pos[_lip_right[i]].distance_squared_to(bind_p))
				sign = 1.0 if dr < dl else -1.0
			else:
				sign = 1.0 if side >= 0.0 else -1.0
		_pull_axis = sd * sign
		_pull_mode = 1
		return
	var loop: PackedInt32Array = _hole_loops[_hole_loops.size() - 1] if not _hole_loops.is_empty() else _lip_left
	if loop.size() < 3:
		return
	var pts: Array[Vector3] = []
	var c := Vector3.ZERO
	for id in loop:
		if id < 0 or id >= nv:
			continue
		var pa := _to_ab_local(_approx_world_bind(_outer.pos[id]))
		pts.append(pa)
		c += pa
	if pts.size() < 3:
		return
	c /= float(pts.size())
	var hr := 1e9
	for pa2 in pts:
		hr = minf(hr, pa2.distance_to(c))
	var ax := (want_side if want_side.length_squared() > 1e-10 else _pull_p - c)
	if ax.length_squared() < 1e-10:
		return
	_pull_a = c
	_pull_b = Vector3(hr, 0.0, 0.0)
	_pull_axis = ax.normalized()
	_pull_mode = 2


## 把累计的拖拽量变成实际皮肤位移：沿张开方向（只张开，不能把唇缘推过切线）+ 少量切向，软饱和到 GRAB_SKIN_MAX。
func _shape_pull(raw: Vector3) -> Vector3:
	var v := raw
	if _pull_mode == 0 or _pull_axis.length_squared() < 1e-8:
		if _split_dir.length_squared() > 1e-6:
			var along0 := _split_dir * raw.dot(_split_dir)
			v = along0 * 0.85 + raw * 0.15
	else:
		var along := raw.dot(_pull_axis)
		var tang := raw - _pull_axis * along
		v = _pull_axis * maxf(along, 0.0) + tang * 0.15
	var L := v.length()
	if L > 1e-7:
		v = v / L * (GRAB_SKIN_MAX * tanh(L / GRAB_SKIN_MAX))
	return v


func pull_mode() -> int:
	return _pull_mode


## 自检：当前拿取位移下，某个绑定空间点（腹局部坐标）的位移量（与 shader 同一公式）。
func debug_pull_offset_at_ab(l: Vector3) -> Vector3:
	return _pull_offset_cpu(l)


func debug_pull_endpoints_ab() -> Array:
	return [_pull_a, _pull_b, _pull_axis]


func _pull_offset_cpu(l: Vector3) -> Vector3:
	if _pull_r < 1e-5:
		return Vector3.ZERO
	var w := 0.0
	if _pull_mode == 1:
		var ab := _pull_b - _pull_a
		var L2 := maxf(ab.dot(ab), 1e-8)
		var t := clampf((l - _pull_a).dot(ab) / L2, 0.0, 1.0)
		var q := _pull_a + ab * t
		var r := l - q
		var side := r.dot(_pull_axis)
		var ends := sqrt(maxf(sin(PI * t), 0.0))
		var wside := smoothstep(0.0, 0.0015, side)
		var wfall := 1.0 - smoothstep(0.0, _pull_r, r.length())
		var tp := clampf((_pull_p - _pull_a).dot(ab) / L2, 0.0, 1.0)
		var wgrab := 1.0 - smoothstep(0.0, 0.07, absf(t - tp) * sqrt(L2))
		w = ends * wside * wfall * (0.35 + 0.65 * wgrab)
	elif _pull_mode == 2:
		var r2 := l - _pull_a
		var dist := r2.length()
		var rim := absf(dist - _pull_b.x)
		var cosang := r2.dot(_pull_axis) / maxf(dist, 1e-5)
		w = smoothstep(0.15, 0.85, cosang) * (1.0 - smoothstep(0.0, _pull_r, rim))
	else:
		var t0 := clampf(1.0 - l.distance_to(_pull_p) / maxf(_pull_r, 1e-4), 0.0, 1.0)
		w = t0 * t0 * (3.0 - 2.0 * t0)
	return _pull_off * w


func _drag_grab(origin: Vector3, dir: Vector3) -> void:
	if not _grab_active:
		return
	if _grab_kind == "flap":
		var nxt := _grab_plane_hit(origin, dir, _grab_last)
		var delta: Vector3 = nxt - _grab_last
		_grab_vel = delta * GRAB_FLAP_GAIN
		_grab_last = nxt
		# 0.3.8：皮瓣不再瞬移到指针，而是在 _process 里以较低的跟随强度追上目标（拖拽更轻、更稳）。
		_flap_goal = nxt + _flap_grab_off
		_flap_goal_set = true
		if _grab_anchor:
			_grab_anchor.global_position = nxt
		return
	if _grab_kind == "skin":
		var nxt2 := _grab_plane_hit(origin, dir, _grab_last)
		# 0.3.7 的 bug：_grab_last 不更新却每次累加「总位移」，拖得越久偏移越大、把切口整体拽走。
		# 现在用相对按下点的总位移 × 增益，再按切口约束成只张开被抓的一侧。
		_pull_raw = _to_ab_delta(nxt2 - _grab_last) * GRAB_SKIN_GAIN
		_pull_off = _shape_pull(_pull_raw)
		_grab_vel = Vector3.ZERO
		_split_drag = _pull_off.length()
		if _split_drag > _pull_peak:
			_pull_peak = _split_drag
			_pull_rest = _pull_off * 0.42
		_apply_pull_uniforms()


func _end_grab(do_throw: bool) -> void:
	if not _grab_active:
		return
	if _grab_kind == "flap":
		var vel := _grab_vel * (GRAB_THROW_GAIN if do_throw else 0.0)
		if vel.length() > GRAB_THROW_MAX:
			vel = vel.normalized() * GRAB_THROW_MAX
		_flap_goal_set = false
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
	_grab_vel = vel / GRAB_THROW_GAIN
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
	_split_dir = _skin_split_dir(mid)
	_setup_pull_geometry(mid, _approx_world_bind(mid), off)
	_pull_raw = off
	_pull_off = _shape_pull(off)
	_pull_r = PULL_RADIUS
	_split_drag = _pull_off.length()
	_pull_peak = _split_drag
	_pull_rest = _pull_off * 0.42
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
	if flap_node is RigidBody3D:
		var rb := flap_node as RigidBody3D
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
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
	if flap_node is RigidBody3D:
		var rb := flap_node as RigidBody3D
		rb.freeze = true
		rb.global_position += delta
		return
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
	if flap_node is RigidBody3D:
		(flap_node as RigidBody3D).freeze = false
	if flap_node is SoftBody3D:
		var soft := flap_node as SoftBody3D
		for i in _pinned_points:
			if soft.has_method("set_point_pinned"):
				soft.set_point_pinned(int(i), false)
	_pinned_points = PackedInt32Array()


func _apply_flap_throw(vel: Vector3) -> void:
	if flap_node == null or not is_instance_valid(flap_node):
		return
	if flap_node is RigidBody3D:
		var rb := flap_node as RigidBody3D
		rb.freeze = false
		rb.linear_velocity = vel
		rb.angular_velocity = vel.cross(Vector3.UP) * 0.6
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


func _skin_split_dir(bind_hint: Vector3) -> Vector3:
	## 切口左右唇的张开方向（绑定/腹局部空间）。
	if _outer == null or _lip_left.size() < 2 or _lip_right.size() < 2:
		return Vector3.ZERO
	var n := mini(_lip_left.size(), _lip_right.size())
	var best_i := int(n / 2)
	var best_s := 1e9
	for i in n:
		var a: int = _lip_left[i]
		var b: int = _lip_right[i]
		if a < 0 or b < 0 or a >= _outer.vert_count() or b >= _outer.vert_count():
			continue
		var mid: Vector3 = (_outer.pos[a] + _outer.pos[b]) * 0.5
		var s := mid.distance_squared_to(bind_hint)
		if s < best_s:
			best_s = s
			best_i = i
	var la: int = _lip_left[best_i]
	var ra: int = _lip_right[best_i]
	if la < 0 or ra < 0 or la >= _outer.vert_count() or ra >= _outer.vert_count():
		return Vector3.ZERO
	var side := _outer.pos[ra] - _outer.pos[la]
	if side.length_squared() < 1e-10:
		return Vector3.ZERO
	# 转到腹局部，便于 pull uniform 使用。
	var w0 := _approx_world_bind(_outer.pos[la])
	var w1 := _approx_world_bind(_outer.pos[ra])
	var d := _to_ab_delta(w1 - w0)
	if d.length_squared() < 1e-10:
		d = side
	return d.normalized()


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
		sm.set_shader_parameter("surgery_pull_a", _pull_a)
		sm.set_shader_parameter("surgery_pull_b", _pull_b)
		sm.set_shader_parameter("surgery_pull_axis", _pull_axis)
		sm.set_shader_parameter("surgery_pull_mode", float(_pull_mode))


func _step_pull_spring(dt: float) -> void:
	var k := 28.0
	var c := 7.0
	# 松手回弹，但停在一次拉扯峰值的一小部分，切口可以保持张开看到腹腔。
	var target: Vector3 = _pull_rest
	var acc: Vector3 = (target - _pull_off) * k - _grab_vel * c
	_grab_vel += acc * dt
	_pull_off += _grab_vel * dt
	if (_pull_off - target).length() < 0.0008 and _grab_vel.length() < 0.002:
		_pull_off = target
		_grab_vel = Vector3.ZERO
		_split_drag = _pull_off.length()
		if _pull_off.length_squared() < 1e-8:
			_pull_r = 0.0
	else:
		_split_drag = _pull_off.length()
	_apply_pull_uniforms()


func apply_bullet_hit(info: Dictionary, par: Dictionary = {}) -> Dictionary:
	## 由 OrganRig.apply_ballistic_hit 调用：在手术腹网上打出柱状弹孔，并去掉圆心皮瓣。
	var out := {"entry": false, "exit": false, "tris": 0}
	if not bool(info.get("hit", false)):
		return out
	# 仅当设置开启，且这一发确实触发了弹道特写时才冲压网格通道。
	if not _bullet_holes_allowed(par, info):
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


func _game_settings() -> Node:
	var n: Node = player
	while n:
		var s := n.get_node_or_null("GameSettings")
		if s:
			return s
		n = n.get_parent()
	var tree := get_tree()
	if tree:
		return tree.root.find_child("GameSettings", true, false)
	return null


func _bullet_holes_allowed(par: Dictionary, info: Dictionary) -> bool:
	var s := _game_settings()
	if s == null or not bool(s.get("bullet_hole_penetrate")):
		return false
	if bool(par.get("cinematic", false)) or bool(par.get("bullet_cam", false)):
		return true
	if bool(info.get("cinematic", false)) or bool(info.get("bullet_cam", false)):
		return true
	return false


func _preview_path_bind() -> PackedVector3Array:
	if not _cut_preview or _outer == null:
		return PackedVector3Array()
	if cut_mode == "ring":
		var path := Geom.oval_path_on_mesh(_outer, _preview_center, _preview_rx, _preview_ry, 24, _outer_grid())
		if path.size() >= 3:
			if path[0].distance_to(path[path.size() - 1]) > Geom.PATH_CLOSE_DIST:
				path.append(path[0])
		return path
	return Geom.line_path_on_mesh(_outer, _preview_a, _preview_b, 12, _outer_grid())


func _clear_cut_preview() -> void:
	_cut_preview = false
	_preview_handle = ""
	_preview_rx = 0.0
	_preview_ry = 0.0
	_dash_path_cache = PackedVector3Array()
	_handles_cache = ""
	if _dash:
		_dash.visible = false
		_dash.mesh = null
	if _handles:
		_handles.visible = false
		_handles.mesh = null


func _cancel_cut_anim() -> void:
	_cut_anim = false
	_cut_anim_path = PackedVector3Array()
	_show_scalpel(false)
	_lock_pose_for_stroke(false)


func _finish_confirmed_cut(path: PackedVector3Array, closed: bool) -> bool:
	_cut_anim = false
	_show_scalpel(false)
	var ok := _commit_path(path, closed)
	_clear_cut_preview()
	_lock_pose_for_stroke(false)
	preview_changed.emit()
	return ok


var _anim_world: PackedVector3Array = PackedVector3Array()
var _anim_nrm: PackedVector3Array = PackedVector3Array()
var _anim_acc: PackedFloat32Array = PackedFloat32Array()
var _anim_src: PackedVector3Array = PackedVector3Array()


## 0.3.8：切割动画路径的世界坐标 / 法线 / 弧长只在动画开始时算一次（动画期间姿态锁定）。
func _cache_anim_path() -> void:
	_anim_src = _cut_anim_path.duplicate()
	_anim_world = PackedVector3Array()
	_anim_nrm = PackedVector3Array()
	_anim_acc = PackedFloat32Array()
	var total := 0.0
	for i in _cut_anim_path.size():
		var wn: Array = _approx_world_and_normal(_cut_anim_path[i])
		_anim_world.append(wn[0])
		_anim_nrm.append(wn[1])
		if i > 0:
			total += _anim_world[i].distance_to(_anim_world[i - 1])
		_anim_acc.append(total)


func _place_scalpel_on_path(u: float) -> void:
	if _cut_anim_path.size() < 2:
		return
	if _anim_src != _cut_anim_path or _anim_world.size() != _cut_anim_path.size():
		_cache_anim_path()
	var t := clampf(u, 0.0, 1.0)
	if _cut_anim_closed and t >= 0.999:
		t = 1.0
	var total := _anim_acc[_anim_acc.size() - 1]
	if total < 1e-6:
		total = 1.0
	var want := t * total
	var world := _anim_world[0]
	var nrm := _anim_nrm[0]
	var tan := Vector3(0, 0, -1)
	for i in range(1, _anim_world.size()):
		if _anim_acc[i] >= want or i == _anim_world.size() - 1:
			var span := maxf(_anim_acc[i] - _anim_acc[i - 1], 1e-6)
			var f := clampf((want - _anim_acc[i - 1]) / span, 0.0, 1.0)
			world = _anim_world[i - 1].lerp(_anim_world[i], f)
			nrm = _anim_nrm[i - 1].lerp(_anim_nrm[i], f)
			tan = _anim_world[i] - _anim_world[i - 1]
			break
	if tan.length_squared() < 1e-8:
		tan = Vector3(0, 0, -1)
	if nrm.length_squared() < 1e-8:
		nrm = Vector3(0, 0, 1)
	_place_scalpel(world, tan.normalized(), nrm.normalized())
	_show_scalpel(true)


func _handle_bind(h: String) -> Vector3:
	match h:
		"start":
			return _preview_a
		"end":
			return _preview_b
		"center", "move":
			return _preview_center
		"rx":
			return _preview_center + Vector3(_preview_rx, 0, 0)
		"ry":
			return _preview_center + Vector3(0, _preview_ry, 0)
		"rxn":
			return _preview_center + Vector3(-_preview_rx, 0, 0)
		"ryn":
			return _preview_center + Vector3(0, -_preview_ry, 0)
	return _preview_center


func _pick_preview_handle(origin: Vector3, dir: Vector3, bind_hint: Vector3) -> String:
	var names: PackedStringArray = PackedStringArray()
	if cut_mode == "ring":
		names = PackedStringArray(["center", "rx", "ry", "rxn", "ryn"])
	else:
		names = PackedStringArray(["start", "end"])
	var best := ""
	var best_s := 0.014 * 0.014
	for h in names:
		var hb: Vector3 = _handle_bind(h)
		var hw: Vector3 = _approx_world_bind(hb)
		# 射线到点的距离。
		var d := dir.normalized()
		var w := origin - hw
		var closest: Vector3 = origin + d * maxf(-w.dot(d), 0.0)
		var s := closest.distance_squared_to(hw)
		if bind_hint.x < 1e8:
			s = minf(s, bind_hint.distance_squared_to(hb))
		if s < best_s:
			best_s = s
			best = "move" if h == "center" else h
	# 点在椭圆内部则移动整个预览。
	if best == "" and cut_mode == "ring" and bind_hint.x < 1e8:
		var q: Vector3 = bind_hint - _preview_center
		var nx := q.x / maxf(_preview_rx, 0.004)
		var ny := q.y / maxf(_preview_ry, 0.004)
		if nx * nx + ny * ny <= 1.0:
			best = "move"
	return best


func _ray_to_preview_plane(origin: Vector3, dir: Vector3) -> Vector3:
	var d := dir.normalized()
	var c: Vector3 = _navel_world()
	var n := Vector3(0, 0, 1)
	if _organs and _organs.has_method("abdomen_frame"):
		n = (_organs.call("abdomen_frame") as Transform3D).basis.z.normalized()
	var denom := n.dot(d)
	var world: Vector3
	if absf(denom) < 1e-6:
		world = c
	else:
		var t := n.dot(c - origin) / denom
		world = origin + d * t
	# 反投到绑定空间：用最近点。
	if _outer == null:
		return _navel_rest
	# 0.3.8：拖动中姿态已锁定（_posed_frozen），不要每个事件都重新蒙皮整张腹网。
	if not pose_locked:
		_posed_dirty = true
	var posed := _posed_world()
	var best := 0
	var best_s := 1e9
	for i in posed.size():
		var s := posed[i].distance_squared_to(world)
		if s < best_s:
			best_s = s
			best = i
	return _outer.pos[best] if best < _outer.vert_count() else _navel_rest


func _apply_preview_drag(bind_p: Vector3) -> void:
	if _preview_handle == "new":
		if cut_mode == "ring":
			var d: Vector3 = bind_p - _preview_drag_start
			_preview_center = (_preview_drag_start + bind_p) * 0.5
			_preview_rx = maxf(absf(d.x) * 0.5, 0.008)
			_preview_ry = maxf(absf(d.y) * 0.5, 0.008)
		else:
			_preview_b = bind_p
		_cut_preview = true
		return
	if cut_mode == "ring":
		if _preview_handle == "move" or _preview_handle == "center":
			_preview_center = _preview_center0 + (bind_p - _preview_drag_start)
		elif _preview_handle == "rx" or _preview_handle == "rxn":
			_preview_rx = maxf(absf(bind_p.x - _preview_center.x), 0.008)
		elif _preview_handle == "ry" or _preview_handle == "ryn":
			_preview_ry = maxf(absf(bind_p.y - _preview_center.y), 0.008)
	else:
		if _preview_handle == "start":
			_preview_a = bind_p
		else:
			_preview_b = bind_p


func _update_cut_preview() -> void:
	if _dash == null:
		_make_dash()
	var path := _preview_path_bind()
	path_points = path
	if path.size() < 2:
		if _dash:
			_dash.visible = false
		if _handles:
			_handles.visible = false
		return
	if pose_locked and _dash and _dash.visible and _dash.mesh != null and path == _dash_path_cache and _handles_key() == _handles_cache:
		return  # 0.3.8：路径没变就不重建虚线网格
	_dash_path_cache = path.duplicate()
	preview_rebuilds += 1
	var mesh := _build_dashed_trail(path)
	if _dash:
		_dash.mesh = mesh
		_parent_trail(_dash)
		if _dash.get_parent() == _skel:
			_dash.transform = Transform3D.IDENTITY
			if _skin:
				_dash.skin = _skin
			_dash.skeleton = NodePath("..")
		_dash.visible = mesh != null and mesh.get_surface_count() > 0
	_update_preview_handles()
	preview_changed.emit()


var _dash_path_cache: PackedVector3Array = PackedVector3Array()
var _handles_cache: String = ""


func _handles_key() -> String:
	return "%s|%s|%s|%s|%s|%s|%s" % [cut_mode, _preview_a, _preview_b, _preview_center, _preview_rx, _preview_ry, has_cut_preview()]


func _make_dash() -> void:
	if _dash:
		return
	_dash = MeshInstance3D.new()
	_dash.name = "IncisionPreviewDash"
	_dash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dash.sorting_offset = 0.025
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.95, 0.15, 0.12, 0.92)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mat.render_priority = 2
	_dash.material_override = mat
	_parent_trail(_dash)
	_dash.visible = false
	_handles = MeshInstance3D.new()
	_handles.name = "IncisionPreviewHandles"
	_handles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_handles.sorting_offset = 0.03
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.albedo_color = Color(1.0, 0.92, 0.2, 0.95)
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.cull_mode = BaseMaterial3D.CULL_DISABLED
	hm.render_priority = 3
	_handles.material_override = hm
	_parent_trail(_handles)
	_handles.visible = false


func _build_dashed_trail(bind_pts: PackedVector3Array) -> ArrayMesh:
	# 把路径拆成短段虚线，避免被当成已经切开的红色涂鸦。
	if bind_pts.size() < 2:
		return ArrayMesh.new()
	var worlds: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var bones: Array = []
	var weights: Array = []
	worlds.resize(bind_pts.size())
	norms.resize(bind_pts.size())
	bones.resize(bind_pts.size())
	weights.resize(bind_pts.size())
	for i in bind_pts.size():
		var bn: Array = _approx_bind_and_normal(bind_pts[i])
		worlds[i] = bn[0]
		norms[i] = bn[1]
		bones[i] = bn[2]
		weights[i] = bn[3]
	var samples: Array = []  # [world, nrm, bone, weight, arclen]
	var total := 0.0
	samples.append([worlds[0], norms[0], bones[0], weights[0], 0.0])
	for i in range(1, worlds.size()):
		var a: Vector3 = worlds[i - 1]
		var b: Vector3 = worlds[i]
		var seg := a.distance_to(b)
		if seg < 1e-6:
			continue
		total += seg
		samples.append([b, norms[i], bones[i], weights[i], total])
	if samples.size() < 2 or total < 1e-5:
		return ArrayMesh.new()
	var dash := 0.0075
	var gap := 0.0045
	var period := dash + gap
	var md := Geom.MeshData.new()
	var half := 0.0048
	var lift := 0.0020
	var on := true
	var walked := 0.0
	while walked < total - 0.0005:
		var span := dash if on else gap
		var a_s := walked
		var b_s := minf(walked + span, total)
		if on and b_s - a_s > 0.001:
			var pa: Array = _sample_poly(samples, a_s)
			var pb: Array = _sample_poly(samples, b_s)
			var ta: Vector3 = pb[0] - pa[0]
			if ta.length_squared() < 1e-10:
				walked = b_s
				on = not on
				continue
			ta = ta.normalized()
			var n0: Vector3 = pa[1]
			var n1: Vector3 = pb[1]
			var s0 := n0.cross(ta)
			if s0.length_squared() < 1e-10:
				s0 = ta.cross(Vector3.UP)
			if s0.length_squared() < 1e-10:
				s0 = ta.cross(Vector3.RIGHT)
			s0 = s0.normalized() * half
			var s1 := n1.cross(ta)
			if s1.length_squared() < 1e-10:
				s1 = s0
			else:
				s1 = s1.normalized() * half
			var va: Vector3 = pa[0] + n0 * lift - s0
			var vb: Vector3 = pa[0] + n0 * lift + s0
			var vc: Vector3 = pb[0] + n1 * lift - s1
			var vd: Vector3 = pb[0] + n1 * lift + s1
			var ia := md.add_vert(va, n0, Vector2(0, 0), pa[2], pa[3])
			var ib := md.add_vert(vb, n0, Vector2(0, 1), pa[2], pa[3])
			var idv := md.add_vert(vd, n1, Vector2(1, 1), pb[2], pb[3])
			var ic := md.add_vert(vc, n1, Vector2(1, 0), pb[2], pb[3])
			md.add_face(ia, ib, idv)
			md.add_face(ia, idv, ic)
		walked = b_s
		on = not on
	return md.to_array_mesh()


func _sample_poly(samples: Array, arclen: float) -> Array:
	for i in range(1, samples.size()):
		if float(samples[i][4]) >= arclen or i == samples.size() - 1:
			var a: Array = samples[i - 1]
			var b: Array = samples[i]
			var span := maxf(float(b[4]) - float(a[4]), 1e-6)
			var f := clampf((arclen - float(a[4])) / span, 0.0, 1.0)
			var n0: Vector3 = a[1]
			var n1: Vector3 = b[1]
			var n := (n0 * (1.0 - f) + n1 * f)
			if n.length_squared() < 1e-8:
				n = n0
			else:
				n = n.normalized()
			return [a[0].lerp(b[0], f), n, a[2], a[3]]
	return samples[0]


func _update_preview_handles() -> void:
	if _handles == null:
		return
	var pts: Array = []
	if cut_mode == "ring" and has_cut_preview():
		pts = ["center", "rx", "ry", "rxn", "ryn"]
	elif cut_mode != "ring" and has_cut_preview():
		pts = ["start", "end"]
	if pts.is_empty():
		_handles.visible = false
		return
	# 手柄与虚线一样用绑定空间 + 蒙皮，避免世界坐标再挂到骨骼上产生偏移。
	var md := Geom.MeshData.new()
	var r := 0.0045
	for h in pts:
		var bind_p: Vector3 = _handle_bind(str(h))
		var bn: Array = _approx_bind_and_normal(bind_p)
		var w: Vector3 = bn[0]
		var bones = bn[2]
		var weights = bn[3]
		var px := w + Vector3(r, 0, 0)
		var nx := w + Vector3(-r, 0, 0)
		var py := w + Vector3(0, r, 0)
		var ny := w + Vector3(0, -r, 0)
		var pz := w + Vector3(0, 0, r)
		var nz := w + Vector3(0, 0, -r)
		for tri in [[px, py, pz], [py, nx, pz], [nx, ny, pz], [ny, px, pz], [py, px, nz], [nx, py, nz], [ny, nx, nz], [px, ny, nz]]:
			var n: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
			if n.length_squared() < 1e-10:
				n = Vector3.UP
			else:
				n = n.normalized()
			var ia := md.add_vert(tri[0], n, Vector2.ZERO, bones, weights)
			var ib := md.add_vert(tri[1], n, Vector2.ZERO, bones, weights)
			var ic := md.add_vert(tri[2], n, Vector2.ZERO, bones, weights)
			md.add_face(ia, ib, ic)
	_handles.mesh = md.to_array_mesh()
	_handles_cache = _handles_key()
	_parent_trail(_handles)
	if _handles.get_parent() == _skel:
		_handles.transform = Transform3D.IDENTITY
		if _skin:
			_handles.skin = _skin
		_handles.skeleton = NodePath("..")
	_handles.visible = true



func _measure_evert_profile(md = null) -> Dictionary:
	var use: Geom.MeshData = md
	if use == null:
		use = _outer_evert if _outer_evert else _outer
	if use == null:
		return {"mid": 0.0, "ends": 0.0}
	var n := mini(_lip_left.size(), _lip_right.size())
	if n < 3:
		return {"mid": 0.0, "ends": 0.0}
	var mid_i := int(n / 2)
	var mid_w := 0.0
	var mid_c := 0
	var end_w := 0.0
	var end_c := 0
	for i in n:
		var a: int = _lip_left[i]
		var b: int = _lip_right[i]
		if a < 0 or b < 0 or a >= use.vert_count() or b >= use.vert_count():
			continue
		var d := use.pos[a].distance_to(use.pos[b])
		var u := float(i) / float(maxi(n - 1, 1))
		if absf(u - 0.5) <= 0.18:
			mid_w += d
			mid_c += 1
		elif u <= 0.18 or u >= 0.82:
			end_w += d
			end_c += 1
	return {
		"mid": mid_w / float(mid_c) if mid_c > 0 else 0.0,
		"ends": end_w / float(end_c) if end_c > 0 else 0.0,
	}


func _mesh_evert_blend() -> Geom.MeshData:
	return _outer_evert if _outer_evert else _outer
