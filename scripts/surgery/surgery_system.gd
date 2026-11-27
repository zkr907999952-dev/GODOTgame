extends Node
## 手术模式：检查床上进入 / 退出，直线/环状预览切口、层状腹壁、可剥离皮瓣。
## 伤口来自真实网格切割，不用旧贴图 / Decal。
class_name SurgerySystem

const Geom := preload("res://scripts/surgery/surgery_geom.gd")
const SpeculumTool := preload("res://scripts/surgery/speculum_tool.gd")
const SCALPEL_GLB := "res://assets/surgery/scalpel.glb"
const WALL_THICKNESS := 0.012
const SLIT_WIDTH := 0.0025
const WALL_MIN_SEG := 0.0012
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
signal speculum_changed()

var player: Node = null
var active: bool = false
var tool: String = ""  # "" | "scalpel" | "grab" | "retractor" | "forceps" | "speculum"  — 进入时无工具，可转视角
var speculum = null
var cut_mode: String = "straight"  # "straight" | "ring"
var thickness: float = WALL_THICKNESS
var cut_open: bool = false
var loop_ready: bool = false
## 0.4.04：直线切口围出的独立皮瓣（如三刀交成的三角形），可像环切皮瓣一样抓取取走。
var free_flap_ready: bool = false
var free_flap_faces: int = 0
var free_flaps_removed: int = 0
var flap_peeled: bool = false
var lofted_tris: int = 0
## 0.4.02：镜头碰撞忽略的分组（皮瓣、外露肠子、拉钩）。
const CAMERA_IGNORE_GROUP := "camera_ignore"
var path_points: PackedVector3Array = PackedVector3Array()  # bind-space
var stroke_active: bool = false
var persist: bool = false
## 0.4.06：仅触屏路径打开。放大拾取半径 / 射线容差，不影响鼠标。
var touch_pick: bool = false
var flap_node: Node3D = null
var flap_kind: String = ""  # "rigid" | "softbody" | "verlet" | ""
var cavity_exposed: bool = false
var pose_locked: bool = false
var navel_flattened: int = 0
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
## 0.3.9：截面分块（{md, ring}）；剥皮瓣时去掉该环的两侧截面，其余累积保留。
var _wall_parts: Array = []
var _ring_serial: int = 0
var _ring_open_id: int = -1
var _organ_z: float = -1e9
var _skin_mi: MeshInstance3D = null
var _wrap_torso_n: int = -1
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
## 0.4.03：直切口折线（腹局部两唇中点 + 弧长）与逐点张开方向，见 surgery_pull.gdshaderinc。
const PULL_MAXP := 24
var _pull_np: int = 0
var _pull_poly: PackedVector4Array = PackedVector4Array()
var _pull_pax: PackedVector4Array = PackedVector4Array()
var _pull_sp: float = 0.0
var _pull_lip: int = 0  # +1 = 左唇，-1 = 右唇（被抓的一侧）
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
	if speculum == null:
		speculum = SpeculumTool.new()
	speculum.setup(self, _organs, _skel)


func is_active() -> bool:
	return active


func current_tool() -> String:
	return tool


func has_tool() -> bool:
	return tool == "scalpel" or tool == "grab" or tool == "retractor" or tool == "forceps" or tool == "speculum"



func is_speculum_present() -> bool:
	return speculum != null and speculum.is_present()


func is_speculum_inserted() -> bool:
	return speculum != null and speculum.is_ready()


func speculum_angle() -> float:
	return float(speculum.opening_angle()) if speculum else 0.0


func set_speculum_angle(deg: float) -> void:
	if speculum:
		speculum.set_opening_angle(deg)


func speculum_max_angle() -> float:
	return float(speculum.max_angle()) if speculum else 24.0


func request_remove_speculum() -> bool:
	return speculum.request_remove() if speculum else false


func debug_insert_speculum() -> bool:
	return speculum.begin_insert() if speculum else false


func debug_finish_speculum_anim() -> void:
	if speculum:
		speculum.debug_finish_anim()


func speculum_node() -> Node3D:
	return speculum.node if speculum else null


func speculum_state() -> String:
	return str(speculum.state) if speculum else "idle"


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
			wp = _skel_xf() * _skin_array_vertex(verts[i], i, bones, weights, mi.skin)
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
			hip = _skel_xf() * _skel.get_bone_global_pose(hi).origin
		var si := _skel.find_bone("C_Spine_a")
		if si >= 0:
			spine = _skel_xf() * _skel.get_bone_global_pose(si).origin
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


## 立刻按当前透视开关刷新腹腔内壁 / 断面壁材质（不依赖手术模式是否激活）。
func sync_lining_xray() -> void:
	_xray_cached = -1
	_update_cavity_visibility()


func _sync_lining_xray_if_changed() -> void:
	if _cavity_mi == null and _wall_mi == null:
		return
	var xr := 1 if _xray_on() else 0
	if xr != _xray_cached:
		_xray_cached = xr
		_update_cavity_visibility()


## 只读当前材质，不先刷新。用于确认离开手术 / 进阴道或断面后内壁仍跟上透视。
func debug_lining_xray() -> Dictionary:
	var out := {
		"has_cavity": has_cavity(),
		"visible": false,
		"xray_on": _xray_on(),
		"mat_xray": -1.0,
		"alpha": 1.0,
		"transparent": false,
		"depth_disabled": false,
		"wall_visible": false,
		"wall_xray": -1.0,
		"wall_alpha": 1.0,
		"wall_transparent": false,
	}
	if _cavity_mi and is_instance_valid(_cavity_mi):
		out["visible"] = _cavity_mi.visible
		out.merge(_peek_shell_xray(_cavity_mi.material_override), true)
	if _wall_mi and is_instance_valid(_wall_mi):
		out["wall_visible"] = _wall_mi.visible
		var w: Dictionary = _peek_shell_xray(_wall_mi.material_override)
		out["wall_xray"] = float(w.get("mat_xray", -1.0))
		out["wall_alpha"] = float(w.get("alpha", 1.0))
		out["wall_transparent"] = bool(w.get("transparent", false))
	return out


func _peek_shell_xray(mat: Material) -> Dictionary:
	var out := {"mat_xray": -1.0, "alpha": 1.0, "transparent": false, "depth_disabled": false}
	if mat is ShaderMaterial:
		var xm := mat as ShaderMaterial
		var xr := float(xm.get_shader_parameter("xray"))
		var col: Color = xm.get_shader_parameter("albedo_color")
		out["mat_xray"] = xr
		out["alpha"] = col.a
		out["transparent"] = xr > 0.0 and col.a < 0.85
		out["depth_disabled"] = true
		return out
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		out["alpha"] = sm.albedo_color.a
		out["transparent"] = (
			sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			and sm.albedo_color.a < 0.85
			and sm.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
		)
		out["depth_disabled"] = sm.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
		out["mat_xray"] = 1.0 if out["transparent"] else 0.0
	return out


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


## T-15：从观察视角以当前站姿进入（不上检查床）。
var standing_session := false


func _standing_ok() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if str(player.get("occupancy")) != "":
		return false
	if player.has_method("is_dead") and bool(player.call("is_dead")):
		return false
	if player.has_method("is_display_mode") and not bool(player.call("is_display_mode")):
		return false
	return true


func body_mode_ok() -> bool:
	return is_on_exam_bed() or (standing_session and _standing_ok())


func enter_surgery_standing() -> bool:
	if active:
		return true
	if is_on_exam_bed():
		return enter_surgery()
	if not _standing_ok():
		return false
	standing_session = true
	if not enter_surgery():
		standing_session = false
		return false
	if player.has_method("set_body_mode_hold"):
		player.call("set_body_mode_hold", true)
	_frame_standing_camera(true)
	return true


## 站姿手术镜头：以当前姿态的腹部（肚脐 / 创口区）为中心，从腹部外法线方向看。
func _frame_standing_camera(snap: bool) -> void:
	if player == null or not player.has_method("apply_orbit_pose"):
		return
	var c := _navel_world()
	if c.length_squared() < 1e-10:
		return
	var outw := _cavity_outward().normalized()
	var from := outw
	from.y += 0.25
	player.call("apply_orbit_pose", c, from.normalized(), 0.72, snap)


func surgery_camera_target() -> Vector3:
	return _navel_world()


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
	return (loop_ready and not flap_peeled) or free_flap_ready


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


var _resume_play_mode := -1


func enter_surgery() -> bool:
	if active:
		return true
	if not body_mode_ok():
		return false
	if not _bake_if_needed():
		push_warning("surgery: bake failed")
		return false
	# 观察模式也可以进入：记下进入时的视角，退出时回到观察，不强迫切第一人称。
	# 与阴道互动互斥。
	if player and player.has_method("get_vagina_mode"):
		var vm = player.call("get_vagina_mode")
		if vm and vm.has_method("is_active") and bool(vm.call("is_active")):
			vm.call("exit")
	_resume_play_mode = -1
	if player and "play_mode" in player:
		_resume_play_mode = int(player.play_mode)
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
	if standing_session:
		standing_session = false
		if player and player.has_method("set_body_mode_hold"):
			player.call("set_body_mode_hold", false)
		# 站姿：退出后回到普通观察镜头。
		if player and player.has_method("clear_orbit_anchor"):
			player.call("clear_orbit_anchor")
		if player and player.has_method("tp_home") and str(player.get("occupancy")) == "":
			player.call("tp_home", false)
	if _resume_play_mode >= 0 and player and player.has_method("set_play_mode"):
		if int(player.get("play_mode")) != _resume_play_mode:
			player.call("set_play_mode", _resume_play_mode)
	_resume_play_mode = -1
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
	# 0.4.12：整身复原也复原子宫脱垂。
	var pcr := _prolapse_ctl()
	if pcr:
		pcr.call("reset")
	_clear_guts()
	_clear_retractors()
	if speculum:
		speculum.force_clear()
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
	_navel_patch = null
	_wall_md = null
	_wall_parts = []
	_ring_open_id = -1
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
	free_flap_ready = false
	free_flap_faces = 0
	flap_peeled = false
	_cuts.clear()
	_cuts_src = null
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
	return not cut_open and not flap_peeled and bullet_holes == 0 and flap_node == null and _trail_bind.is_empty() and not is_speculum_present() and (_dress == null or _dress_mesh_orig == null or _dress.mesh == _dress_mesh_orig or active)


func set_tool(t: String) -> void:
	# 再点已选工具则取消选择，恢复视角控制。
	# 扩张器已取出但工具仍选中：再点一次是重新插入，而不是取消选择。
	if t == tool:
		if t == "speculum" and speculum and not speculum.is_present():
			speculum.begin_insert()
			speculum_changed.emit()
			tool_changed.emit(tool)
			return
		if stroke_active:
			cancel_stroke()
		tool = ""
		_show_scalpel(false)
		_drop_preview_on_tool_leave()
		tool_changed.emit(tool)
		return
	# 拿取与手术刀一样随时可切换，不必先切开或先剥皮瓣。
	if t != "" and t != "scalpel" and t != "grab" and t != "retractor" and t != "forceps" and t != "speculum":
		t = ""
	if stroke_active:
		cancel_stroke()
	tool = t
	if tool != "scalpel":
		_show_scalpel(false)
		_drop_preview_on_tool_leave()
	if tool != "retractor":
		_hide_retractor_ghost()
		if _retr_selected >= 0:
			select_retractor(-1)
	if tool != "forceps":
		_clear_forceps_preview()
		if _fc_active:
			_end_forceps()
	if tool == "speculum" and speculum:
		speculum.begin_insert()
	tool_changed.emit(tool)


func ensure_tool(t: String) -> void:
	# 测试 / 程序切工具：已选中则保持，避免再点一次被取消。
	if tool != t:
		set_tool(t)


func _drop_preview_on_tool_leave() -> void:
	## 0.4.07：取消选择手术刀（切到其它工具或取消选择）时关闭并清空切口预览。
	if _cut_anim:
		return
	var had := _cut_preview or (_dash != null and _dash.visible)
	_clear_cut_preview()
	path_points = PackedVector3Array()
	if had:
		preview_changed.emit()


func begin_stroke(origin: Vector3, dir: Vector3) -> bool:
	if not active:
		return false
	if tool == "grab":
		return _begin_grab(origin, dir)
	if tool == "retractor":
		return _begin_retractor(origin, dir)
	if tool == "forceps":
		return _begin_forceps_pointer(origin, dir)
	if tool == "speculum":
		if speculum and speculum.is_ready() and speculum.hits_ray(origin, dir):
			return speculum.request_remove()
		return false
	if tool != "scalpel":
		return false
	if _cut_anim:
		return false
	_lock_pose_for_stroke(true)
	var hit: Variant = _mesh_hit(origin, dir)
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
	if tool == "forceps" and _fc_active:
		_drag_forceps(origin, dir)
		return
	if (tool == "grab" or tool == "retractor") and _grab_active:
		_drag_grab(origin, dir)
		return
	if tool == "retractor" and _retr_placing:
		hover_tool(origin, dir)
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
	if _fc_active:
		_end_forceps()
	_fc_pressing = false
	_fc_press_t = 0.0
	_retr_placing = false
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
	if _fc_pressing and not _fc_active:
		# 手机短点：只留下名称 / 标记，不夹、不扯出。
		_fc_pressing = false
		_fc_press_t = 0.0
		stroke_active = false
		return
	if _fc_active:
		_end_forceps()
		_fc_pressing = false
		_fc_press_t = 0.0
		return
	if _grab_active:
		_end_grab(true)
		stroke_active = false
		return
	if _retr_placing:
		_retr_placing = false
		stroke_active = false
		_place_retractor_at_ghost()
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
	_bake_pull()
	if free_flap_ready and not (loop_ready and not flap_peeled):
		return _peel_free_flap()
	if not can_grab_flap() or _outer == null or _inner == null:
		return false
	# 0.3.9：环形切口已真正切开，皮瓣是独立连通块；按连通性取出（不再按 2D 环重新分类，也不会内外拓扑不一致）。
	var loop := _flap_loop if _flap_loop.size() >= 3 else _path_ids
	if loop.size() < 3:
		return false
	_bake_evert()
	_ensure_twin()
	var seeds := PackedInt32Array()
	for id in loop:
		if id >= 0 and id < _outer.vert_count():
			seeds.append(id)
	var comp: Dictionary = Geom.component_faces(_outer, seeds)
	var ext_o: Dictionary
	if comp.size() > 0 and comp.size() < _outer.face_count() / 2:
		ext_o = Geom.extract_faces(_outer, comp, loop, _body_loop)
	else:
		ext_o = Geom.extract_inside(_outer, loop)
	if int(ext_o.get("inside_faces", 0)) < 1 or int(ext_o.get("outside_faces", 0)) < 1:
		push_warning("surgery: flap isolation failed (inside=%s outside=%s)" % [ext_o.get("inside_faces"), ext_o.get("outside_faces")])
		return false
	var body_o: Geom.MeshData = ext_o["outside"]
	var flap_o: Geom.MeshData = ext_o["inside"]
	if body_o.twin == null:
		body_o.twin = Geom.make_cavity(body_o, thickness, _organ_z, _navel_rest)
	if flap_o.twin == null:
		flap_o.twin = Geom.make_cavity(flap_o, thickness, _organ_z, _navel_rest)
	var body_i: Geom.MeshData = body_o.twin
	var flap_i: Geom.MeshData = flap_o.twin
	var loop_body_o: PackedInt32Array = ext_o["loop_out"]
	var loop_flap_o: PackedInt32Array = ext_o["loop_in"]
	if loop_body_o.size() < 3:
		loop_body_o = Geom.mesh_boundary_loop(body_o)
	# 身体：去掉这个环两侧的截面，换成洞缘一圈截面（外/内同索引）。
	var kept: Array = []
	for part in _wall_parts:
		if int((part as Dictionary).get("ring", -1)) != _ring_open_id or _ring_open_id < 0:
			kept.append(part)
	# 0.4.01：被环切覆盖的直切口，环内那段截面随皮瓣一起去掉（环外的保留）。
	var ring_poly := PackedVector2Array()
	for vi in loop_body_o:
		ring_poly.append(Vector2(body_o.pos[vi].x, body_o.pos[vi].y))
	for part2 in kept:
		var pmd: Geom.MeshData = (part2 as Dictionary).get("md")
		if pmd and ring_poly.size() >= 3:
			(part2 as Dictionary)["md"] = _drop_faces_inside(pmd, ring_poly)
	_wall_parts = kept
	var peel_wall := _make_loft_mesh(body_o, body_i, _closed_ids(loop_body_o), _closed_ids(loop_body_o), true, true)
	_wall_parts.append({"md": peel_wall, "ring": -1})
	_rebuild_wall_md()
	lofted_tris = _wall_md.face_count()
	_remap_wall_src(ext_o.get("map_out", null))
	_remap_cuts(ext_o.get("map_out", null), body_o)
	_outer = body_o
	_inner = body_i
	_lip_left = loop_body_o
	_lip_right = loop_body_o
	_lip_left_i = loop_body_o
	_lip_right_i = loop_body_o
	_lip_closed = true
	_ring_open_id = -1
	_hole_loops.append(loop_body_o)
	_start_eversion()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	# 皮瓣：外补丁 + 内补丁 + 周圈壁，转到世界空间后落地。
	var flap_md := flap_o.clone()
	var fo := flap_md.vert_count()
	_append_mesh(flap_md, flap_i)
	var lf := _closed_ids(loop_flap_o)
	var flap_inner_loop := PackedInt32Array()
	for id2 in lf:
		flap_inner_loop.append(id2 + fo)
	Geom.loft_wall(flap_md, lf, flap_inner_loop, false)
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


## ---- 0.4.04：直线切口围出的独立皮瓣 ----
const FREE_FLAP_MIN_FACES := 6
const FREE_FLAP_MAX_FRAC := 0.35


## 外皮里除了身体主块以外的最大连通块（三角集合）；没有则空。
func _free_flap_component() -> Dictionary:
	if _outer == null:
		return {}
	var comps: Array = Geom.all_components(_outer)
	if comps.size() < 2:
		return {}
	var total := _outer.face_count()
	for k in range(1, comps.size()):
		var c: Dictionary = comps[k]
		if c.size() >= FREE_FLAP_MIN_FACES and c.size() < int(total * FREE_FLAP_MAX_FRAC):
			return c
	return {}


func _ray_hits_free_flap(origin: Vector3, dir: Vector3) -> bool:
	var comp := _free_flap_component()
	if comp.is_empty():
		return false
	_refresh_posed()
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	return hit != null and comp.has(int((hit as Dictionary)["tri"]))


func _detect_free_flap() -> void:
	var c := _free_flap_component()
	free_flap_faces = c.size()
	free_flap_ready = c.size() > 0


func _remap_ids(ids: PackedInt32Array, mp: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id in ids:
		var e := int(mp.get(id, -1))
		if e >= 0:
			out.append(e)
	return out


func _peel_free_flap() -> bool:
	_finish_retr_release()
	_bake_evert()
	_ensure_twin()
	var comp := _free_flap_component()
	if comp.is_empty():
		free_flap_ready = false
		return false
	# 只把身体那一侧的顶点映射过去（皮瓣独占的顶点不进身体网格）。
	var flap_v: Dictionary = {}
	for f in comp.keys():
		for k in 3:
			flap_v[_outer.idx[int(f) * 3 + k]] = true
	var keep_src := PackedInt32Array()
	for arr in [_lip_left, _lip_right, _flap_loop, _body_loop]:
		for id in arr:
			if not flap_v.has(id):
				keep_src.append(id)
	for r in _retractors:
		var rv := int((r as Dictionary)["vid"])
		if not flap_v.has(rv):
			keep_src.append(rv)
	var ext: Dictionary = Geom.extract_faces(_outer, comp, PackedInt32Array(), keep_src)
	if int(ext.get("inside_faces", 0)) < 1 or int(ext.get("outside_faces", 0)) < 1:
		return false
	var mp: Dictionary = ext["map_out"]
	var body_o: Geom.MeshData = ext["outside"]
	var flap_o: Geom.MeshData = ext["inside"]
	if body_o.twin == null:
		body_o.twin = Geom.make_cavity(body_o, thickness, _organ_z, _navel_rest)
	if flap_o.twin == null:
		flap_o.twin = Geom.make_cavity(flap_o, thickness, _organ_z, _navel_rest)
	var lf := _closed_ids(Geom.mesh_boundary_loop(flap_o))
	if lf.size() < 4:
		return false
	# 截面：皮瓣那一侧的直切截面随皮瓣带走（身体那一侧的截面保留，正好封住洞缘）。
	var poly := PackedVector2Array()
	for vi in lf:
		poly.append(Vector2(flap_o.pos[vi].x, flap_o.pos[vi].y))
	# 0.4.05：按截面顶点的来源顶点判断——来源顶点属于皮瓣的截面三角随皮瓣带走（不再按距离猜，
	# 外翻后截面离切线 2~5mm，按距离会漏掉皮瓣内侧的一整条截面）。
	var dropped := 0
	for part in _wall_parts:
		var pmd: Geom.MeshData = (part as Dictionary).get("md")
		if pmd == null:
			continue
		var before := pmd.face_count()
		var src: PackedInt32Array = (part as Dictionary).get("src", PackedInt32Array())
		if src.size() == pmd.vert_count():
			_drop_wall_faces_by_src(pmd, src, flap_v)
		else:
			(part as Dictionary)["md"] = _drop_faces_in_or_near(pmd, poly, SLIT_WIDTH * 0.4)
		dropped += before - ((part as Dictionary)["md"] as Geom.MeshData).face_count()
	_remap_wall_src(mp)
	_remap_cuts(mp, body_o)
	free_flap_wall_dropped = dropped
	_rebuild_wall_md()
	lofted_tris = _wall_md.face_count()
	# 身体网格换成去掉皮瓣后的那块；切口唇缘 / 拉钩顶点按新索引重映射。
	_outer = body_o
	_inner = body_o.twin
	free_flap_wall_dropped += _drop_bridging_wall_faces()
	_rebuild_wall_md()
	lofted_tris = _wall_md.face_count()
	_lip_left = _remap_ids(_lip_left, mp)
	_lip_right = _remap_ids(_lip_right, mp)
	_lip_left_i = _lip_left
	_lip_right_i = _lip_right
	_flap_loop = _remap_ids(_flap_loop, mp)
	_body_loop = _remap_ids(_body_loop, mp)
	for ri in range(_retractors.size() - 1, -1, -1):
		var rec: Dictionary = _retractors[ri]
		var nv := int(mp.get(int(rec["vid"]), -1))
		if nv < 0:
			var nd: Node = rec.get("node")
			if nd and is_instance_valid(nd):
				nd.queue_free()
			_retractors.remove_at(ri)
		else:
			rec["vid"] = nv
	_retr_selected = -1
	_start_eversion()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	_posed_dirty = true
	# 皮瓣：外补丁 + 内补丁 + 周圈壁（与环切皮瓣同一做法）。
	var flap_md := flap_o.clone()
	var fo := flap_md.vert_count()
	_append_mesh(flap_md, flap_o.twin)
	var fil := PackedInt32Array()
	for id2 in lf:
		fil.append(id2 + fo)
	Geom.loft_wall(flap_md, lf, fil, false)
	_flap_outer_faces = flap_o.face_count()
	if not _spawn_flap(flap_md, flap_o):
		return false
	free_flaps_removed += 1
	cut_open = true
	cavity_exposed = true
	persist = true
	_detect_free_flap()
	_update_cavity_visibility()
	return true


var free_flap_wall_dropped: int = 0
var bridging_faces_cleared: int = 0
var _loft_src: PackedInt32Array = PackedInt32Array()
## 0.4.05：所有切口的唇缘（外皮索引）：[{left, right, closed}]；_cuts_src = 这些索引所属的外皮网格。
var _cuts: Array = []
var _cuts_src: Object = null


func cut_count() -> int:
	return _cuts.size() if _cuts_src == _outer else 0


func cut_lips(i: int) -> Array:
	if i < 0 or i >= cut_count():
		return []
	return [(_cuts[i] as Dictionary)["left"], (_cuts[i] as Dictionary)["right"]]


func _drop_wall_faces_by_src(md: Geom.MeshData, src: PackedInt32Array, flap_v: Dictionary) -> void:
	var keep := PackedInt32Array()
	for f in md.face_count():
		var hit := 0
		for k in 3:
			if flap_v.has(src[md.idx[f * 3 + k]]):
				hit += 1
		if hit >= 2:
			continue
		for k2 in 3:
			keep.append(md.idx[f * 3 + k2])
	md.idx = keep


func _remap_wall_src(mp) -> void:
	for part in _wall_parts:
		var d := part as Dictionary
		var src: PackedInt32Array = d.get("src", PackedInt32Array())
		if src.is_empty():
			continue
		if not (mp is Dictionary):
			d["src"] = PackedInt32Array()
			continue
		var out := PackedInt32Array()
		out.resize(src.size())
		for i in src.size():
			out[i] = int((mp as Dictionary).get(src[i], -1))
		d["src"] = out


func _remap_cuts(mp, new_outer: Object) -> void:
	if _cuts_src != _outer or not (mp is Dictionary):
		_cuts.clear()
		_cuts_src = new_outer
		return
	var keep: Array = []
	for c in _cuts:
		var l := _remap_ids((c as Dictionary)["left"], mp)
		var r := _remap_ids((c as Dictionary)["right"], mp)
		if l.size() >= 2 and r.size() >= 2:
			keep.append({"left": l, "right": r, "closed": (c as Dictionary)["closed"]})
	_cuts = keep
	_cuts_src = new_outer


## 截面三角的来源顶点沿外皮边界链必须彼此靠近（≤ BRIDGE_HOPS 条边界边）：跨过另一条切口缝隙的截面三角
## （交叉处一侧唇连到另一侧唇）是无效截面，删掉。来源顶点已不在外皮边界上的（-1 / 被缝回）也删掉。
const BRIDGE_HOPS := 6


func _drop_bridging_wall_faces() -> int:
	if _outer == null:
		return 0
	var adj: Dictionary = {}
	for e in _boundary_edges(_outer):
		var ev := e as Vector2i
		if not adj.has(ev.x):
			adj[ev.x] = []
		if not adj.has(ev.y):
			adj[ev.y] = []
		(adj[ev.x] as Array).append(ev.y)
		(adj[ev.y] as Array).append(ev.x)
	var cache: Dictionary = {}
	var near := func(a: int, b: int) -> bool:
		if a == b:
			return true
		var key := Vector2i(mini(a, b), maxi(a, b))
		if cache.has(key):
			return cache[key]
		var frontier: Array = [a]
		var seen: Dictionary = {a: true}
		var found := false
		for _h in BRIDGE_HOPS:
			var nxt: Array = []
			for v in frontier:
				for w in adj.get(v, []):
					if w == b:
						found = true
						break
					if not seen.has(w):
						seen[w] = true
						nxt.append(w)
				if found:
					break
			if found or nxt.is_empty():
				break
			frontier = nxt
		cache[key] = found
		return found
	var total := 0
	for part in _wall_parts:
		var d := part as Dictionary
		var md: Geom.MeshData = d.get("md")
		var src: PackedInt32Array = d.get("src", PackedInt32Array())
		if md == null or src.size() != md.vert_count():
			continue
		var keep := PackedInt32Array()
		var dropped := 0
		for f in md.face_count():
			var s0 := src[md.idx[f * 3]]
			var s1 := src[md.idx[f * 3 + 1]]
			var s2 := src[md.idx[f * 3 + 2]]
			var ok := s0 >= 0 and s1 >= 0 and s2 >= 0 and adj.has(s0) and adj.has(s1) and adj.has(s2)
			ok = ok and bool(near.call(s0, s1)) and bool(near.call(s1, s2)) and bool(near.call(s0, s2))
			if not ok:
				dropped += 1
				continue
			keep.append(md.idx[f * 3])
			keep.append(md.idx[f * 3 + 1])
			keep.append(md.idx[f * 3 + 2])
		if dropped > 0:
			md.idx = keep
			total += dropped
	return total


## 0.4.05：把 vid 所在的那一刀设为当前切口（拿取 / 拉钩的单侧唇拉开按它算）。
func _activate_cut_for(vid: int) -> bool:
	if vid < 0 or cut_count() == 0:
		return false
	for c in _cuts:
		var d := c as Dictionary
		var l: PackedInt32Array = d["left"]
		var r: PackedInt32Array = d["right"]
		if l.has(vid) or r.has(vid):
			if l == _lip_left and r == _lip_right:
				return true
			_lip_left = l
			_lip_right = r
			_lip_left_i = l
			_lip_right_i = r
			_lip_closed = bool(d["closed"])
			return true
	return false


## 离绑定点最近的唇缘顶点所在的切口设为当前切口。
func _activate_cut_near(bind_p: Vector3) -> void:
	if cut_count() == 0:
		return
	var best := -1
	var bd := 1e9
	for c in _cuts:
		for arr in [(c as Dictionary)["left"], (c as Dictionary)["right"]]:
			for v in arr:
				if v >= 0 and v < _outer.vert_count():
					var dd := _outer.pos[v].distance_squared_to(bind_p)
					if dd < bd:
						bd = dd
						best = v
	if best >= 0 and bd < 0.02 * 0.02:
		_activate_cut_for(best)


func _drop_faces_in_or_near(md: Geom.MeshData, poly: PackedVector2Array, tol: float) -> Geom.MeshData:
	var keep := PackedInt32Array()
	var dropped := 0
	var n := poly.size()
	for f in md.face_count():
		var c3 := md.centroid(f)
		var c := Vector2(c3.x, c3.y)
		var hit := Geometry2D.is_point_in_polygon(c, poly)
		if not hit:
			for k in n:
				var q := Geometry2D.get_closest_point_to_segment(c, poly[k], poly[(k + 1) % n])
				if q.distance_to(c) < tol:
					hit = true
					break
		if hit:
			dropped += 1
			continue
		keep.append(md.idx[f * 3])
		keep.append(md.idx[f * 3 + 1])
		keep.append(md.idx[f * 3 + 2])
	if dropped > 0:
		md.idx = keep
	return md


## 0.3.9：闭环索引首尾相接（loft 用 closed=false 走一整圈，避免重复首点产生零面积三角）。
func _closed_ids(loop: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id in loop:
		if out.size() > 0 and out[out.size() - 1] == id:
			continue
		out.append(id)
	if out.size() >= 3 and out[0] != out[out.size() - 1]:
		out.append(out[0])
	return out


func _ensure_twin() -> void:
	if _outer == null:
		return
	if _inner == null or _inner.vert_count() != _outer.vert_count() or _inner.idx.size() != _outer.idx.size():
		_inner = Geom.make_cavity(_outer, thickness, _organ_z, _navel_rest)
	_outer.twin = _inner
	_outer.ensure_dsp()
	_inner.ensure_dsp()


func _bake_evert() -> void:
	## 上一刀的外翻并入 rest：之后的切割/剥离从已外翻的形状继续，旧切口不会合拢。
	if _outer == null:
		return
	var w := 1.0
	if _evert_anim:
		_evert_anim = false
	_outer.bake_dsp(w)
	if _inner:
		_inner.bake_dsp(w)
	for part in _wall_parts:
		var md: Geom.MeshData = (part as Dictionary).get("md")
		if md:
			md.bake_dsp(w)
	_evert = 1.0
	_evert_vel = 0.0


func _rebuild_wall_md() -> void:
	var w := Geom.MeshData.new()
	for part in _wall_parts:
		var md: Geom.MeshData = (part as Dictionary).get("md")
		if md and md.face_count() > 0:
			_append_mesh(w, md)
	_wall_md = w


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


func _make_loft_mesh(outer: Geom.MeshData, inner: Geom.MeshData, loop_o: PackedInt32Array, loop_i: PackedInt32Array, closed: bool, full: bool = false) -> Geom.MeshData:
	var cap := WALL_MAX_SEGMENTS
	var src_o := _thin_lip(outer, loop_o) if full else Geom.resample_index_loop(outer, loop_o, cap)
	var src_i := src_o if full and loop_o == loop_i else (_thin_lip(inner, loop_i) if full else Geom.resample_index_loop(inner, loop_i, cap))
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
	# 0.4.05：记下每个截面顶点来自外皮的哪个顶点（内壁 twin 同索引），用于按拓扑清理无效截面。
	_loft_src = PackedInt32Array()
	_loft_src.resize(wall.vert_count())
	for id3 in map_o.keys():
		_loft_src[int(map_o[id3])] = int(id3)
	for id4 in map_i.keys():
		_loft_src[int(map_i[id4])] = int(id4)
	return wall


## 0.3.9：截面沿唇缘全部顶点走，但相距不到 WALL_MIN_SEG 的相邻点合并（12mm 高的截面配 0.3mm 宽会成针状三角）。
func _thin_lip(md: Geom.MeshData, ids: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := ids.size()
	for i in n:
		var id: int = ids[i]
		if id < 0 or id >= md.vert_count():
			continue
		var last := i == n - 1
		if out.size() > 0 and not last and md.pos[id].distance_to(md.pos[out[out.size() - 1]]) < WALL_MIN_SEG:
			continue
		if last and out.size() > 1 and id != out[out.size() - 1] and md.pos[id].distance_to(md.pos[out[out.size() - 1]]) < WALL_MIN_SEG:
			out[out.size() - 1] = id
			continue
		if out.size() > 0 and out[out.size() - 1] == id:
			continue
		out.append(id)
	return out


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
	_finish_retr_release()
	_bake_pull()
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
	# 0.3.9：先把上一刀的外翻并入 rest，再在外皮上嵌入路径；内壁是 twin，所有拆分按同一插值同步（不再 IDW 近似）。
	_bake_evert()
	_ensure_twin()
	if _navel_flatten_if_near(work, closed):
		work = _project_path_to_flat_navel(work)
	var ids := Geom.embed_path(_outer, work)
	if ids.size() < 2:
		push_warning("surgery: path embed failed")
		return false
	if closed:
		ids = Geom.close_path_ids(_outer, ids)
		if ids.size() >= 3 and ids[0] != ids[ids.size() - 1]:
			ids.append(ids[0])
	Geom.sync_twin_faces(_outer)
	_path_ids = ids
	last_embedded_bind = PackedVector3Array()
	for id in ids:
		if id >= 0 and id < _outer.vert_count():
			last_embedded_bind.append(_outer.pos[id])
	# 真正切开：切线上的顶点复制成左右两份，三角只引用自己那一侧（内壁同索引同步）。
	var sp: Dictionary = Geom.split_path(_outer, ids, closed, SLIT_WIDTH)
	if not bool(sp.get("ok", false)):
		push_warning("surgery: split failed")
		return false
	var left: PackedInt32Array = sp["left"]
	var right: PackedInt32Array = sp["right"]
	var sdir: PackedVector3Array = sp["sdir"]
	# 0.4.01：唇缘 / 端点附近的细长三角做边翻转（毛刺、尖刺），内壁同步。
	Geom.flip_slivers(_outer, 0.08, 24)
	Geom.sync_twin_faces(_outer)
	_inner = _outer.twin
	# 外翻位移场（rest + dsp），截面顶点从唇缘拷贝时一起继承。
	Geom.evert_field(_outer, left, right, sdir, closed, 1.0, false, _navel_rest if _navel_rest != Vector3.ZERO else Vector3.INF)
	# 0.4.02：新切口穿过（X）或止于（T）旧切口时，旧截面在交叉处的那一段横在新开口上，
	# 会挡住角上的皮瓣、看起来粘连。把旧截面中离新切线 CROSS_CLEAR 以内的面去掉，交叉处由新截面封边。
	var cross_poly := PackedVector2Array()
	for id_c in ids:
		if id_c >= 0 and id_c < _outer.vert_count():
			cross_poly.append(Vector2(_outer.pos[id_c].x, _outer.pos[id_c].y))
	for part_c in _wall_parts:
		var pmd_c: Geom.MeshData = (part_c as Dictionary).get("md")
		if pmd_c:
			cross_faces_cleared += _drop_faces_near_path(pmd_c, cross_poly, CROSS_CLEAR)
	var wall := _make_loft_mesh(_outer, _inner, left, left, false, true)
	var wsrc := _loft_src.duplicate()
	var w2 := _make_loft_mesh(_outer, _inner, right, right, false, true)
	wsrc.append_array(_loft_src)
	_append_mesh(wall, w2)
	# 0.4.05：每一刀的左右唇都记下来，之后点哪一刀的唇就拉哪一刀（不只是最近一刀）。
	if _cuts_src != _outer:
		_cuts.clear()
	_cuts_src = _outer
	_cuts.append({"left": left.duplicate(), "right": right.duplicate(), "closed": closed})
	last_dense_loft_tris = Geom.dense_loft_tris(left.size(), closed, 2)
	_lip_left = left
	_lip_right = right
	_lip_left_i = left
	_lip_right_i = right
	_lip_closed = closed
	if closed:
		loop_ready = true
		# 闭环：法线×切向 指向左侧；按路径 XY 面积正负判断左侧是不是环内（皮瓣）。
		var poly := PackedVector3Array()
		for id3 in ids:
			poly.append(_outer.pos[id3])
		var sa := 0.0
		for k in poly.size():
			var pa := poly[k]
			var pb := poly[(k + 1) % poly.size()]
			sa += pa.x * pb.y - pb.x * pa.y
		var inside_left := sa >= 0.0
		_flap_loop = left if inside_left else right
		_body_loop = right if inside_left else left
		_ring_serial += 1
		_ring_open_id = _ring_serial
		_wall_parts.append({"md": wall, "ring": _ring_open_id, "src": wsrc})
	else:
		loop_ready = _ring_open_id >= 0 and not flap_peeled
		_wall_parts.append({"md": wall, "ring": -1, "src": wsrc})
	bridging_faces_cleared += _drop_bridging_wall_faces()
	_rebuild_wall_md()
	lofted_tris = wall.face_count()
	cut_open = true
	cavity_exposed = true
	persist = true
	_start_eversion()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	_posed_dirty = true
	if not closed:
		_detect_free_flap()
	# 0.4.0：切开后不再在皮肤上留粉红涂鸦线；改由切口边缘的红色渐变（_with_wound_color）表现。
	_clear_trail()
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
	_skin_mi = skin_mi
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


func set_touch_pick(on: bool) -> void:
	touch_pick = on


func is_touch_pick() -> bool:
	return touch_pick


func _touch_slop() -> float:
	return 0.045 if touch_pick else 0.0


func _lip_pick_dist() -> float:
	return 0.032 if touch_pick else RETR_PICK_DIST


func _handle_pick_r2() -> float:
	var r := 0.028 if touch_pick else 0.014
	return r * r


func _gut_pick_dist() -> float:
	return 0.030 if touch_pick else GUT_PICK_DIST


## 精确命中腹网；触屏时允许射线与网格最近点有几厘米容差。
func _mesh_hit(origin: Vector3, dir: Vector3) -> Variant:
	if _outer == null:
		return null
	var hit: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	if hit != null or not touch_pick:
		return hit
	return _nearest_mesh_on_ray(origin, dir, _touch_slop())


func _nearest_mesh_on_ray(origin: Vector3, dir: Vector3, slop: float) -> Variant:
	if _outer == null or slop <= 1e-6:
		return null
	var d := dir.normalized()
	var posed := _posed_world()
	var best_i := -1
	var best_perp := slop
	var best_t := 1e9
	for i in posed.size():
		var w: Vector3 = posed[i] - origin
		var t := w.dot(d)
		if t <= 0.02:
			continue
		var perp := (w - d * t).length()
		if perp < best_perp - 1e-6 or (absf(perp - best_perp) <= 1e-6 and t < best_t):
			best_perp = perp
			best_t = t
			best_i = i
	if best_i < 0:
		return null
	return {"bind": _outer.pos[best_i], "point": posed[best_i], "i0": best_i}


func apply_puncture_hole(world_p: Vector3, world_dir: Vector3, radius: float = 0.016) -> bool:
	## 0.4.06：肚脐捅穿 / 刺刀匕首最终刺穿 —— 小环切并去掉圆心皮瓣，可复原，手术钳可用。
	if not _bake_if_needed():
		return false
	var d := world_dir
	if d.length_squared() < 1e-8:
		d = Vector3(0, 0, -1)
	else:
		d = d.normalized()
	var r := clampf(radius, 0.008, 0.03)
	return _punch_bullet_hole_world(world_p, d, r)


## 0.4.07：肚脐凹陷延迟压平。entries: [凹陷位置, 压平位移, 压平法线]
var _navel_dimple: Array = []
var navel_flat_applied: bool = false
const NAVEL_FLAT_NEAR := 0.035


func navel_dimple_vert_count() -> int:
	return _navel_dimple.size()


func navel_dimple_depth() -> float:
	## 当前腹网上肚脐中心附近最低点相对压平面的深度（米，正 = 凹陷）。
	if _outer == null:
		return 0.0
	var best := 0.0
	for e in _navel_dimple:
		best = maxf(best, (e[1] as Vector3).z)
	return 0.0 if navel_flat_applied else best


func _capture_navel_dimple(pre_pos: PackedVector3Array, pre_nrm: PackedVector3Array, pre_idx: PackedInt32Array, pre_uv: PackedVector2Array = PackedVector2Array()) -> void:
	_navel_dimple = []
	if navel_flattened <= 0 or _outer == null:
		navel_flat_applied = true
		return
	var c := _navel_rest
	# 0.4.12（t65u）：XY 没被移动的顶点（过渡带 / 重三角化边界环）直接逐顶点还原原始位置和法线，
	# 而不是在重叠的坑壁三角里取最高 Z（会把坑口附近顶点放到错误的层上）。
	# flatten_navel 只松弛 r < r_in 的顶点 XY，压缩索引时保持原顺序（新点阵顶点追加在后）：
	# 按顺序双指针配对，同位置的重复顶点（硬边 / 接缝）也能一一对上。
	var exact_done: Dictionary = {}
	var pi := 0
	for vi in _outer.vert_count():
		var pv := _outer.pos[vi]
		var rv := Vector2(pv.x - c.x, pv.y - c.y).length()
		if rv < NAVEL_PATCH_R - 1e-6:
			continue
		var kx := _xy_key(pv)
		var bj := -1
		var pj := pi
		while pj < pre_pos.size():
			if _xy_key(pre_pos[pj]) == kx and (pj >= pre_uv.size() or vi >= _outer.uv.size() or pre_uv[pj].distance_squared_to(_outer.uv[vi]) < 1e-12):
				bj = pj
				break
			pj += 1
		if bj < 0:
			continue
		pi = bj + 1
		if rv > 0.026:
			continue
		exact_done[vi] = true
		var o := pre_pos[bj]
		if o.distance_squared_to(pv) > 1e-14:
			_navel_dimple.append([o, pv - o, _outer.nrm[vi]])
			_outer.pos[vi] = o
		# 压平时重算过 r < r_out + 4mm 的法线：未移动顶点也要还原原始法线。
		if pre_nrm.size() == pre_pos.size():
			_outer.nrm[vi] = pre_nrm[bj]
	var tris := PackedInt32Array()
	for f in pre_idx.size() / 3:
		for k in 3:
			var q := pre_pos[pre_idx[f * 3 + k]]
			if Vector2(q.x - c.x, q.y - c.y).length() < 0.034:
				tris.append(f)
				break
	for i in _outer.vert_count():
		if exact_done.has(i):
			continue
		var p := _outer.pos[i]
		var r := Vector2(p.x - c.x, p.y - c.y).length()
		if r > 0.026:
			continue
		var best_z := -1e9
		var best_n := Vector3.ZERO
		var xy := Vector2(p.x, p.y)
		for f in tris:
			var a := pre_pos[pre_idx[f * 3]]
			var b := pre_pos[pre_idx[f * 3 + 1]]
			var cc := pre_pos[pre_idx[f * 3 + 2]]
			var v0 := Vector2(b.x - a.x, b.y - a.y)
			var v1 := Vector2(cc.x - a.x, cc.y - a.y)
			var v2 := xy - Vector2(a.x, a.y)
			var den := v0.x * v1.y - v1.x * v0.y
			if absf(den) < 1e-14:
				continue
			var w1 := (v2.x * v1.y - v1.x * v2.y) / den
			var w2 := (v0.x * v2.y - v2.x * v0.y) / den
			var w0 := 1.0 - w1 - w2
			if w0 < -1e-5 or w1 < -1e-5 or w2 < -1e-5:
				continue
			var z := a.z * w0 + b.z * w1 + cc.z * w2
			if z > best_z:
				best_z = z
				var n0 := pre_nrm[pre_idx[f * 3]] if pre_nrm.size() == pre_pos.size() else Vector3.BACK
				var n1 := pre_nrm[pre_idx[f * 3 + 1]] if pre_nrm.size() == pre_pos.size() else Vector3.BACK
				var n2 := pre_nrm[pre_idx[f * 3 + 2]] if pre_nrm.size() == pre_pos.size() else Vector3.BACK
				best_n = (n0 * w0 + n1 * w1 + n2 * w2).normalized()
		if best_z < -1e8 or absf(best_z - p.z) < 1e-6:
			continue
		var dimpled := Vector3(p.x, p.y, best_z)
		_navel_dimple.append([dimpled, p - dimpled, _outer.nrm[i]])
		_outer.pos[i] = dimpled
		if best_n.length_squared() > 0.5:
			_outer.nrm[i] = best_n
	navel_flat_applied = _navel_dimple.is_empty()


## 0.4.12（t65u）：原始肚脐小片（flatten_navel 重三角化前 r < NAVEL_PATCH_R 的全部三角，原位置 / 法线 / UV / 骨骼）。
## 刀口碰到肚脐之前，手术腹网显示时把重三角化的压平圆盘换成这片原始网格，所以进手术、复原后肚脐与原模型完全一致。
const NAVEL_PATCH_R := 0.018
const NAVEL_PATCH_CHECK_R := 0.03
var _navel_patch: Geom.MeshData = null
var _navel_keep_xy: Dictionary = {}


static func _xy_key(p: Vector3) -> Vector2i:
	return Vector2i(roundi(p.x * 1e7), roundi(p.y * 1e7))


func _build_navel_patch(pre: Geom.MeshData) -> Geom.MeshData:
	if pre == null:
		return null
	var c := _navel_rest
	var patch := Geom.MeshData.new()
	var remap: Dictionary = {}
	# 压平只改 r < NAVEL_PATCH_R 的顶点 XY（Tutte 松弛 + 重三角化）；其余顶点 XY 不变。
	# 记下这些未动顶点的 XY，显示时凡是用到「XY 被改过」顶点的面都换成原始面。
	_navel_keep_xy = {}
	for vi0 in pre.vert_count():
		var q0 := pre.pos[vi0]
		var r0 := Vector2(q0.x - c.x, q0.y - c.y).length()
		if r0 >= NAVEL_PATCH_R and r0 < NAVEL_PATCH_CHECK_R + 0.004:
			_navel_keep_xy[_xy_key(q0)] = true
	for f in pre.face_count():
		var ok := false
		for k in 3:
			var q := pre.pos[pre.idx[f * 3 + k]]
			if Vector2(q.x - c.x, q.y - c.y).length() < NAVEL_PATCH_R:
				ok = true
				break
		if not ok:
			continue
		var ids := [0, 0, 0]
		for k2 in 3:
			var vi := pre.idx[f * 3 + k2]
			if not remap.has(vi):
				remap[vi] = patch.copy_vert(pre, vi)
			ids[k2] = int(remap[vi])
		patch.add_face(ids[0], ids[1], ids[2])
	return patch if patch.face_count() > 0 else null


func navel_patch_faces() -> int:
	return _navel_patch.face_count() if _navel_patch != null and not navel_flat_applied else 0


func _navel_patch_mesh(am: ArrayMesh) -> ArrayMesh:
	if am == null or navel_flat_applied or _navel_patch == null or am.get_surface_count() < 1:
		return am
	var arrays := am.surface_get_arrays(0)
	var V: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var I: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if V.is_empty() or I.is_empty():
		return am
	var c := _navel_rest
	var idx2 := PackedInt32Array()
	for f in I.size() / 3:
		var inside := false
		for k in 3:
			var q := V[I[f * 3 + k]]
			if Vector2(q.x - c.x, q.y - c.y).length() < NAVEL_PATCH_CHECK_R and not _navel_keep_xy.has(_xy_key(q)):
				inside = true
				break
		if not inside:
			idx2.append_array([I[f * 3], I[f * 3 + 1], I[f * 3 + 2]])
	var off := V.size()
	var P := _navel_patch
	var N: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var U: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	V.append_array(P.pos)
	if N != null and N.size() == off:
		N.append_array(P.nrm)
		arrays[Mesh.ARRAY_NORMAL] = N
	if U != null and U.size() == off:
		U.append_array(P.uv)
		arrays[Mesh.ARRAY_TEX_UV] = U
	var C = arrays[Mesh.ARRAY_COLOR]
	if C != null and (C as PackedColorArray).size() == off:
		var cc: PackedColorArray = C
		for _i in P.vert_count():
			cc.append(Color(1, 1, 1, 1))
		arrays[Mesh.ARRAY_COLOR] = cc
	var B = arrays[Mesh.ARRAY_BONES]
	var W = arrays[Mesh.ARRAY_WEIGHTS]
	if B != null and W != null and (B as PackedInt32Array).size() == off * 4:
		var bb: PackedInt32Array = B
		var ww: PackedFloat32Array = W
		bb.append_array(P.bones)
		ww.append_array(P.weights)
		arrays[Mesh.ARRAY_BONES] = bb
		arrays[Mesh.ARRAY_WEIGHTS] = ww
	arrays[Mesh.ARRAY_VERTEX] = V
	_navel_pad_tangents(arrays, off, P)
	for f2 in P.face_count():
		idx2.append_array([P.idx[f2 * 3] + off, P.idx[f2 * 3 + 1] + off, P.idx[f2 * 3 + 2] + off])
	arrays[Mesh.ARRAY_INDEX] = idx2
	var blends: Array = []
	for bi in am.get_blend_shape_count():
		var ba: Array = am.surface_get_blend_shape_arrays(0)[bi]
		var bv: PackedVector3Array = ba[Mesh.ARRAY_VERTEX]
		if bv != null and bv.size() == off:
			bv.append_array(P.pos)
			ba[Mesh.ARRAY_VERTEX] = bv
		var bn = ba[Mesh.ARRAY_NORMAL]
		if bn != null and (bn as PackedVector3Array).size() == off:
			var bnn: PackedVector3Array = bn
			bnn.append_array(P.nrm)
			ba[Mesh.ARRAY_NORMAL] = bnn
		_navel_pad_tangents(ba, off, P)
		blends.append(ba)
	var out := ArrayMesh.new()
	out.blend_shape_mode = am.blend_shape_mode
	for bi2 in am.get_blend_shape_count():
		out.add_blend_shape(am.get_blend_shape_name(bi2))
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blends)
	return out


func _navel_pad_tangents(arrays: Array, off: int, P: Geom.MeshData) -> void:
	var tg = arrays[Mesh.ARRAY_TANGENT]
	if tg == null or not (tg is PackedFloat32Array) or (tg as PackedFloat32Array).size() != off * 4:
		return
	var t: PackedFloat32Array = tg
	for i in P.vert_count():
		var n := P.nrm[i]
		var tt := n.cross(Vector3.UP)
		if tt.length_squared() < 1e-8:
			tt = n.cross(Vector3.RIGHT)
		tt = tt.normalized()
		t.append_array([tt.x, tt.y, tt.z, 1.0])
	arrays[Mesh.ARRAY_TANGENT] = t


func _navel_flatten_if_near(path: PackedVector3Array, closed: bool, extra: float = 0.0) -> bool:
	## 刀口（或弹孔环）进入肚脐附近时才把显示凹陷换回压平的切割面。
	if navel_flat_applied or _navel_dimple.is_empty() or _outer == null or path.is_empty():
		return false
	var c := Vector2(_navel_rest.x, _navel_rest.y)
	var dmin := 1e9
	var poly := PackedVector2Array()
	for i in path.size():
		var a := Vector2(path[i].x, path[i].y)
		poly.append(a)
		var j := i + 1
		if j >= path.size():
			if not closed:
				dmin = minf(dmin, c.distance_to(a))
				break
			j = 0
		var b := Vector2(path[j].x, path[j].y)
		dmin = minf(dmin, c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)))
	var near := dmin - extra < NAVEL_FLAT_NEAR
	if not near and closed and poly.size() >= 3 and Geometry2D.is_point_in_polygon(c, poly):
		near = true
	if not near:
		return false
	_apply_navel_flat()
	return true


func _project_path_to_flat_navel(path: PackedVector3Array) -> PackedVector3Array:
	## 预览是在凹陷显示面上画的；压平后把肚脐附近的路径点按 XY 投回压平的切割面（与 0.4.04 起的切割面一致）。
	var out := path.duplicate()
	var c := _navel_rest
	var tris := PackedInt32Array()
	for f in _outer.face_count():
		var q := _outer.pos[_outer.idx[f * 3]]
		if Vector2(q.x - c.x, q.y - c.y).length() < 0.034:
			tris.append(f)
	for i in out.size():
		var p := out[i]
		if Vector2(p.x - c.x, p.y - c.y).length() > 0.03:
			continue
		var xy := Vector2(p.x, p.y)
		var best := 1e9
		var bz := p.z
		for f in tris:
			var a := _outer.pos[_outer.idx[f * 3]]
			var b := _outer.pos[_outer.idx[f * 3 + 1]]
			var cc := _outer.pos[_outer.idx[f * 3 + 2]]
			var v0 := Vector2(b.x - a.x, b.y - a.y)
			var v1 := Vector2(cc.x - a.x, cc.y - a.y)
			var v2 := xy - Vector2(a.x, a.y)
			var den := v0.x * v1.y - v1.x * v0.y
			if absf(den) < 1e-14:
				continue
			var w1 := (v2.x * v1.y - v1.x * v2.y) / den
			var w2 := (v0.x * v2.y - v2.x * v0.y) / den
			var w0 := 1.0 - w1 - w2
			if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4:
				continue
			var z := a.z * w0 + b.z * w1 + cc.z * w2
			if absf(z - p.z) < best:
				best = absf(z - p.z)
				bz = z
		out[i] = Vector3(p.x, p.y, bz)
	return out


func _apply_navel_flat() -> void:
	if navel_flat_applied:
		return
	navel_flat_applied = true
	for md in [_outer, _outer_rest, _outer_evert]:
		if md == null:
			continue
		var m: Geom.MeshData = md
		for i in m.vert_count():
			var p := m.pos[i]
			if Vector2(p.x - _navel_rest.x, p.y - _navel_rest.y).length() > 0.027:
				continue
			var bi := -1
			var bd := 0.0015 * 0.0015
			for k in _navel_dimple.size():
				var d2 := p.distance_squared_to(_navel_dimple[k][0] as Vector3)
				if d2 < bd:
					bd = d2
					bi = k
			if bi < 0:
				continue
			m.pos[i] = p + (_navel_dimple[bi][1] as Vector3)
			if m.nrm.size() == m.vert_count():
				m.nrm[i] = _navel_dimple[bi][2]
	_posed_dirty = true
	_posed_cache = PackedVector3Array()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)


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
	# 0.4.04：切割用的腹网（以及由它生成的内壁）去掉肚脐凹陷，彻底避免肚脐处切线嵌入 / 拆分出错面、粘连。
	var pre_pos := _outer.pos.duplicate()
	var pre_nrm := _outer.nrm.duplicate()
	var pre_idx := _outer.idx.duplicate()
	var pre_md: Geom.MeshData = _outer.clone()
	navel_flattened = Geom.flatten_navel(_outer, _navel_rest, NAVEL_PATCH_R)
	navel_flat_applied = false
	_band_edge = _boundary_vert_keys(_outer)
	var organ_z := _organ_front_z()
	_organ_z = organ_z
	_inner = Geom.make_cavity(_outer, thickness, organ_z, _navel_rest)
	_outer.twin = _inner
	# 0.4.07：切割拓扑已压平（防粘连），但在刀口真正碰到肚脐前，显示位置仍还原原始凹陷。
	_capture_navel_dimple(pre_pos, pre_nrm, pre_idx, pre_md.uv)
	_navel_patch = _build_navel_patch(pre_md) if not navel_flat_applied else null
	_lumbar_z = Geom.lumbar_exterior_z(_rest, _navel_rest)
	var back_z := minf(_guts_min.z - 0.006, organ_z - 0.055)
	var wrap_skin := _wrap_skin_md()
	_wrap = Geom.make_cavity_wrap(_inner, back_z, _guts_min, _guts_max, _lumbar_z, wrap_skin, _wrap_torso_n, _navel_rest)
	# 用去掉腹部的 Dress 替换原网格，避免与手术网格重叠。
	if _rest.face_count() > 0:
		_dress.mesh = _rest.to_array_mesh()
		# 保留蒙皮与已有透视材质。
		if _skin:
			_dress.skin = _skin
		_dress.skeleton = _dress.skeleton
	_surgical_mi = _make_skinned_mi("SurgicalAbdomen", _outer.to_array_mesh(), true)
	# 0.4.0：手术腹网用独立的皮肤材质副本，开启切口边缘红色渐变（顶点色）；身体其余皮肤不受影响。
	if _surgical_mi.material_override is ShaderMaterial:
		var wm := (_surgical_mi.material_override as ShaderMaterial).duplicate() as ShaderMaterial
		wm.set_shader_parameter("wound_tint_on", 1.0)
		_surgical_mi.material_override = wm
		if _organs and _organs.has_method("register_deform_material"):
			_organs.call("register_deform_material", wm, true)
	_surgical_mi.mesh = _navel_patch_mesh(_with_wound_color(_surgical_mi.mesh as ArrayMesh, _outer))
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


## 0.3.9：腹腔袋贴合用的皮肤点云（上半身 Dress 余下部分 + 下半身 Skin 的腰臀段，绑定空间）。
func _wrap_skin_md() -> Geom.MeshData:
	var md := Geom.MeshData.new()
	var srcs: Array = []
	if _rest:
		srcs.append(_rest)
	if _skin_mi and _skin_mi.mesh and _skin_mi.mesh.get_surface_count() > 0:
		var arr: Array = _skin_mi.mesh.surface_get_arrays(0)
		var lm := Geom.MeshData.new()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var bo: PackedInt32Array = arr[Mesh.ARRAY_BONES] if arr[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var we: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS] if arr[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		var stride := 4
		if bo.size() >= v.size() * 8:
			stride = 8
		# 两块网格的 Skin 绑定槽位可能不同：按骨骼名映射到 Dress 的槽位。
		var remap: Dictionary = {}
		var sk2: Skin = _skin_mi.skin
		if sk2 and _skin and sk2 != _skin:
			var by_name: Dictionary = {}
			for j in _skin.get_bind_count():
				by_name[String(_skin.get_bind_name(j))] = j
			for j2 in sk2.get_bind_count():
				var nm := String(sk2.get_bind_name(j2))
				remap[j2] = int(by_name.get(nm, -1))
		if bo.size() >= v.size() * 4 and nr.size() == v.size():
			for i in v.size():
				var p := v[i]
				if absf(p.y - _navel_rest.y) > 0.3:
					continue
				var b := PackedInt32Array()
				var w := PackedFloat32Array()
				b.resize(4)
				w.resize(4)
				var bad := false
				for k in 4:
					b[k] = bo[i * stride + k]
					w[k] = we[i * stride + k]
					if w[k] <= 0.0:
						b[k] = 0
					elif not remap.is_empty():
						b[k] = int(remap.get(b[k], -1))
						if b[k] < 0:
							bad = true
				if bad:
					continue
				lm.add_vert(p, nr[i], Vector2.ZERO, b, w)
			srcs.append(lm)
	_wrap_torso_n = -1
	for si in srcs.size():
		var m: Geom.MeshData = srcs[si]
		for i2 in m.vert_count():
			if absf(m.pos[i2].y - _navel_rest.y) > 0.3:
				continue
			md.copy_vert(m, i2)
		if si == 0 and _rest:
			_wrap_torso_n = md.vert_count()
	return md


## 0.3.9 自检：腹腔袋（后盖/侧壁）与内壁在当前姿势下离皮肤的最小间隙。
## 返回 {wrap_max, inner_max, wrap_bad, inner_bad, worst}，*_max 为「最靠外」的有符号距离（负 = 在皮肤内侧）。
func debug_cavity_clearance(margin: float = 0.002) -> Dictionary:
	var out := {"wrap_max": -1.0, "inner_max": -1.0, "wrap_bad": 0, "inner_bad": 0, "worst": Vector3.ZERO, "wrap_n": 0}
	if _skel == null or _inner == null:
		return out
	var cloud := _wrap_skin_md()
	if _outer:
		for i in _outer.vert_count():
			cloud.copy_vert(_outer, i)
	var cw := Geom.world_positions(cloud, _skel, _skin)
	var cn := PackedVector3Array()
	cn.resize(cloud.vert_count())
	var gb := _skel_xf().basis
	for i2 in cloud.vert_count():
		cn[i2] = (gb * (Geom.skin_basis(i2, cloud, _skel, _skin) * cloud.nrm[i2])).normalized()
	var cell := 0.03
	var grid: Dictionary = {}
	for i3 in cw.size():
		var key := Vector3i(floori(cw[i3].x / cell), floori(cw[i3].y / cell), floori(cw[i3].z / cell))
		var lst: PackedInt32Array = grid.get(key, PackedInt32Array())
		lst.append(i3)
		grid[key] = lst
	if _wrap:
		var ww := Geom.world_positions(_wrap, _skel, _skin)
		out["wrap_n"] = ww.size()
		for p2 in ww:
			var h: float = _clearance_at(p2, grid, cw, cn, cell)
			if h > float(out["wrap_max"]):
				out["wrap_max"] = h
				out["worst"] = p2
			if h > -margin:
				out["wrap_bad"] = int(out["wrap_bad"]) + 1
	var iw := Geom.world_positions(_inner, _skel, _skin)
	var bad_rel: Array = []
	for vi in iw.size():
		var p3: Vector3 = iw[vi]
		var h2: float = _clearance_at(p3, grid, cw, cn, cell)
		if h2 > float(out["inner_max"]):
			out["inner_worst_rel"] = _inner.pos[vi] - _navel_rest
		out["inner_max"] = maxf(float(out["inner_max"]), h2)
		if h2 > -margin and bad_rel.size() < 400:
			bad_rel.append(_inner.pos[vi] - _navel_rest)
		if h2 > -margin:
			out["inner_bad"] = int(out["inner_bad"]) + 1
	out["inner_bad_rel"] = bad_rel
	return out


## 0.3.9 自检：腹腔袋顶点与三角重心在当前姿势下是否在皮肤里面（沿朝背方向射线与身体三角求交，奇数 = 在内）。
func debug_wrap_outside(which: String = "wrap") -> Dictionary:
	var out := {"tested": 0, "outside": 0, "pts": []}
	if _skel == null or _wrap == null or _rest == null:
		return out
	var tgt: Geom.MeshData = _wrap
	if which == "inner":
		tgt = _inner
	elif which == "outer_in":
		tgt = _outer.clone()
		for i0 in tgt.vert_count():
			tgt.pos[i0] -= tgt.nrm[i0].normalized() * 0.0008
	var body := _rest.clone()
	var cloud := _wrap_skin_md_full()
	_append_mesh(body, cloud)
	if _outer and which == "wrap":
		_append_mesh(body, _outer)
	var bw := Geom.world_positions(body, _skel, _skin)
	var ww := Geom.world_positions(tgt, _skel, _skin)
	var fr: Transform3D = _ab_frame() if _organs and _organs.has_method("abdomen_frame") else Transform3D.IDENTITY
	var dir := -fr.basis.z.normalized()
	var pts := PackedVector3Array()
	for p in ww:
		pts.append(p)
	var face_of: Dictionary = {}
	if which == "wrap":
		for f in _wrap.face_count():
			var A := ww[_wrap.idx[f * 3]]
			var B := ww[_wrap.idx[f * 3 + 1]]
			var C := ww[_wrap.idx[f * 3 + 2]]
			for bc in [Vector3(1, 1, 1) / 3.0, Vector3(0.6, 0.2, 0.2), Vector3(0.2, 0.6, 0.2), Vector3(0.2, 0.2, 0.6), Vector3(0.5, 0.5, 0.0), Vector3(0.0, 0.5, 0.5), Vector3(0.5, 0.0, 0.5)]:
				face_of[pts.size()] = f
				pts.append(A * bc.x + B * bc.y + C * bc.z)
	# 只保留射线附近的身体三角，加速。
	var lo := pts[0]
	var hi := pts[0]
	for q in pts:
		lo = lo.min(q)
		hi = hi.max(q)
	var tris := PackedInt32Array()
	for f2 in body.face_count():
		var a := bw[body.idx[f2 * 3]]
		var b := bw[body.idx[f2 * 3 + 1]]
		var c := bw[body.idx[f2 * 3 + 2]]
		var tlo := a.min(b).min(c)
		var thi := a.max(b).max(c)
		# 沿 dir 方向无限延伸：只在垂直于 dir 的两个轴上裁剪。
		var ok := true
		for ax in 3:
			if thi[ax] < lo[ax] - 0.25 or tlo[ax] > hi[ax] + 0.25:
				ok = false
		if ok:
			tris.append(f2)
	var gb := _skel_xf().basis
	var dirs := [dir, (dir + fr.basis.x.normalized()).normalized(), (dir - fr.basis.x.normalized()).normalized()]
	var qi := -1
	for q2 in pts:
		qi += 1
		var outside_votes := 0
		for d in dirs:
			var best_t := 1e9
			var best_f := -1
			for f3 in tris:
				var r: Variant = Geometry3D.ray_intersects_triangle(q2, d, bw[body.idx[f3 * 3]], bw[body.idx[f3 * 3 + 1]], bw[body.idx[f3 * 3 + 2]])
				if r != null:
					var t := ((r as Vector3) - q2).length()
					if t < best_t:
						best_t = t
						best_f = f3
			if best_f < 0:
				outside_votes += 1
				continue
			var nsum := Vector3.ZERO
			for k in 3:
				var vi: int = body.idx[best_f * 3 + k]
				nsum += gb * (Geom.skin_basis(vi, body, _skel, _skin) * body.nrm[vi])
			# 最近交点处皮肤法线与射线同向 = 从里往外穿出 = 点在体内。
			if nsum.dot(d) <= 0.0:
				outside_votes += 1
		out["tested"] = int(out["tested"]) + 1
		if outside_votes >= 2:
			out["outside"] = int(out["outside"]) + 1
			if (out["pts"] as Array).size() < 40:
				if which == "inner":
					(out["pts"] as Array).append(fr.affine_inverse() * q2)
					continue
				var tag: Variant = qi if qi < tgt.vert_count() else [int(face_of.get(qi, -1)), _wrap.idx[int(face_of.get(qi, 0)) * 3], _wrap.idx[int(face_of.get(qi, 0)) * 3 + 1], _wrap.idx[int(face_of.get(qi, 0)) * 3 + 2]]
				(out["pts"] as Array).append(tag)
	return out


func _wrap_skin_md_full() -> Geom.MeshData:
	## Skin（下半身）带三角的网格，骨骼槽位映射到 Dress。
	var lm := Geom.MeshData.new()
	if _skin_mi == null or _skin_mi.mesh == null or _skin_mi.mesh.get_surface_count() < 1:
		return lm
	var arr: Array = _skin_mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var bo: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var we: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var ind: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var stride := 8 if bo.size() >= v.size() * 8 else 4
	var remap: Dictionary = {}
	var sk2: Skin = _skin_mi.skin
	if sk2 and _skin and sk2 != _skin:
		var by_name: Dictionary = {}
		for j in _skin.get_bind_count():
			by_name[String(_skin.get_bind_name(j))] = j
		for j2 in sk2.get_bind_count():
			remap[j2] = int(by_name.get(String(sk2.get_bind_name(j2)), 0))
	for i in v.size():
		var b := PackedInt32Array()
		var w := PackedFloat32Array()
		b.resize(4)
		w.resize(4)
		for k in 4:
			w[k] = we[i * stride + k]
			b[k] = int(remap.get(bo[i * stride + k], bo[i * stride + k])) if w[k] > 0.0 else 0
		lm.add_vert(v[i], nr[i], Vector2.ZERO, b, w)
	for f in ind.size() / 3:
		lm.add_face(ind[f * 3], ind[f * 3 + 1], ind[f * 3 + 2])
	return lm


func _clearance_at(p: Vector3, grid: Dictionary, cw: PackedVector3Array, cn: PackedVector3Array, cell: float) -> float:
	var k0 := Vector3i(floori(p.x / cell), floori(p.y / cell), floori(p.z / cell))
	var bd := PackedFloat32Array([1e9, 1e9, 1e9])
	var bi := PackedInt32Array([-1, -1, -1])
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var key := k0 + Vector3i(dx, dy, dz)
				if not grid.has(key):
					continue
				var lst: PackedInt32Array = grid[key]
				for j in lst:
					var d := cw[j].distance_squared_to(p)
					if d < bd[2]:
						if d < bd[0]:
							bd[2] = bd[1]; bi[2] = bi[1]; bd[1] = bd[0]; bi[1] = bi[0]; bd[0] = d; bi[0] = j
						elif d < bd[1]:
							bd[2] = bd[1]; bi[2] = bi[1]; bd[1] = d; bi[1] = j
						else:
							bd[2] = d; bi[2] = j
	if bi[0] < 0:
		return -1.0
	var sp := Vector3.ZERO
	var sn := Vector3.ZERO
	var c := 0
	for k in 3:
		if bi[k] >= 0:
			sp += cw[bi[k]]
			sn += cn[bi[k]]
			c += 1
	sp /= float(c)
	return (p - sp).dot(sn.normalized())


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
		_surgical_mi.mesh = _navel_patch_mesh(_with_wound_color(_mesh_with_evert(outer, _outer_rest, _outer_evert), outer))
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
	_update_cavity_visibility()


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
		_cavity_shader_mat.set_shader_parameter("clip_low", 1.0)
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
	return _skel_xf() * posed


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
	# T-15：站姿手术不用任何检查床（不要拿场景里别的空床当托板 / 地面高度）。
	if not is_on_exam_bed():
		return null
	# t99u：分身宿主躺的是它自己的那张床（分身挂在 Clones 下，父节点没有 vehicle_system）。
	if "on_exam_bed" in player:
		var own = player.get("on_exam_bed")
		if own is Node and is_instance_valid(own):
			return own
	var g := player.get_parent()
	var vs: Node = g.get("vehicle_system") if g else null
	if vs == null:
		return null
	var occ = vs.get("occupied")
	if occ and str(vs.call("kind_of", occ)) == "exam_bed":
		return occ
	if player.is_in_group("clone_dolls"):
		return null
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
	if _flap_catch and is_instance_valid(_flap_catch) and is_on_exam_bed():
		return _flap_catch.global_position.y + 0.8
	if player:
		# 站姿：接住面 = 脚下地面。
		return player.global_position.y
	return 0.0


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
				wp = _skel_xf() * wp
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
	# 0.4.02：皮瓣不参与镜头碰撞避让（不会挡住 / 推近观察与手术镜头）。
	body.add_to_group(CAMERA_IGNORE_GROUP)
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
	flap.add_to_group(CAMERA_IGNORE_GROUP)
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


## 0.4.15 t99：渲染一致的骨架世界变换。
## 身体节点关闭物理插值时（玩家，每个渲染帧由 _body_interp_apply 手动摆放），即时变换就是画面上的位置；
## 真机上 get_global_transform_interpolated() 对这类节点偶发返回旧位置 → 扯出的子宫（世界坐标柔体，
## 按帧变换差值搬运）会前后跳 = 走动时闪烁 / 重影。开启插值的身体（分身等）用插值变换（过远退回即时值）。
func _skel_xf() -> Transform3D:
	if _skel == null:
		return Transform3D.IDENTITY
	var live := _skel.global_transform
	if not _skel.is_physics_interpolated_and_enabled() or Engine.is_in_physics_frame():
		return live
	var itp := _skel.get_global_transform_interpolated()
	if itp.origin.distance_squared_to(live.origin) > 0.25:
		return live
	return itp


## 腹部坐标系，换算到与 _skel_xf() 一致的骨架变换下（organ_rig 内部总用插值变换，见 _skel_world_xf）。
func _ab_frame() -> Transform3D:
	if _organs == null or not _organs.has_method("abdomen_frame"):
		return Transform3D.IDENTITY
	var fr: Transform3D = _organs.call("abdomen_frame")
	return _ab_fix() * fr


## organ_rig 帧 → 渲染一致帧的修正量（世界坐标左乘）。布娃娃时 organ_rig 用物理骨，不修正。
func _ab_fix() -> Transform3D:
	var osk = _organs.get("_skel") if _organs else null
	if not (osk is Skeleton3D) or not is_instance_valid(osk):
		return Transform3D.IDENTITY
	var sk: Skeleton3D = osk
	var live := sk.global_transform
	var itp := sk.get_global_transform_interpolated()
	var interp := sk.is_physics_interpolated_and_enabled() and not Engine.is_in_physics_frame()
	var fix := ab_fix_for(live, itp, interp)
	if fix.is_equal_approx(Transform3D.IDENTITY):
		return Transform3D.IDENTITY
	if _organs.has_method("_spine_world_from_ragdoll") and _organs.call("_spine_world_from_ragdoll") is Transform3D:
		return Transform3D.IDENTITY
	return fix


## 纯函数（便于测试）：organ_rig._skel_world_xf 用的是 itp（相差 > 0.5 m 时退回 live）；
## 画面上的骨架：开插值 = 同一个值，关插值 = live。返回 want * used⁻¹。
static func ab_fix_for(live: Transform3D, itp: Transform3D, interpolated: bool) -> Transform3D:
	var used := live if itp.origin.distance_squared_to(live.origin) > 0.25 else itp
	var want := used if interpolated else live
	if want.is_equal_approx(used):
		return Transform3D.IDENTITY
	return want * used.affine_inverse()


## 世界点 → 传给 organ_rig（其内部按自己的帧换到腹部坐标）时先抵消 _ab_fix，腹部坐标保持一致。
func _to_organ_world(p: Vector3) -> Vector3:
	return _ab_fix().affine_inverse() * p


func _navel_world() -> Vector3:
	if _organs and _organs.has_method("abdomen_frame"):
		return (_ab_frame() as Transform3D).origin
	if player:
		return player.global_position + Vector3(0, 1.06, 0.1)
	return _navel_rest


func _process(dt: float) -> void:
	if active and not body_mode_ok():
		exit_surgery()
	# 未进手术 / 无残留切口时也要跟着透视开关，否则腹腔内壁会保持不透明、挡住内脏。
	_sync_lining_xray_if_changed()
	if speculum:
		var st0 := str(speculum.state)
		speculum.step(dt)
		if str(speculum.state) != st0:
			speculum_changed.emit()
	if not active and not persist:
		return
	if (active or persist) and not pose_locked:
		_posed_dirty = true
	_step_retr_release(dt)
	# t99：先按本帧（身体已在 -10 优先级摆好）刷新腹部坐标系，再步进悬挂脏器；
	# 不依赖 organ_rig 与本节点在树里的先后（附身换父节点后顺序会变）。
	if _organs and _organs.has_method("_update_frame") and (not _soft_organs.is_empty() or not _gut_pulls.is_empty()):
		_organs.call("_update_frame")
	var _tg0 := Time.get_ticks_usec()
	_update_guts(dt)
	gut_update_usec = Time.get_ticks_usec() - _tg0
	_update_retractors()
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
	## 0.3.9：外翻目标 = rest + dsp（切割时算好的平滑位移场）；外皮、内壁、截面同一套位移，截面不会和唇缘脱开。
	if _outer == null:
		return
	_outer.ensure_dsp()
	_outer_rest = _outer.clone()
	_outer_evert = _outer.with_dsp()
	if _inner:
		_inner.ensure_dsp()
		_inner_rest = _inner.clone()
		_inner_evert = _inner.with_dsp()
	else:
		_inner_rest = null
		_inner_evert = null
	if _wall_md:
		_wall_md.ensure_dsp()
		_wall_rest = _wall_md.clone()
		_wall_evert = _wall_md.with_dsp()
	else:
		_wall_rest = null
		_wall_evert = null
	var valid_holes: Array = []
	for loop in _hole_loops:
		if loop is PackedInt32Array and _lips_valid(_outer, loop as PackedInt32Array):
			valid_holes.append(loop)
	_hole_loops = valid_holes
	_evert = 0.0
	_evert_vel = 0.0
	_evert_anim = true


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
	var local_shift: Vector3 = _skel_xf().basis.inverse() * world_shift
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
		acc += _skel_xf() * (p + local_shift * w)
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
	var xf := _skel_xf() if _skel else Transform3D.IDENTITY
	var c := Vector3.ZERO
	for p in md.pos:
		c += xf * p
	return c / float(md.vert_count())


func _begin_grab(origin: Vector3, dir: Vector3) -> bool:
	# t104u：点中已放好的拉钩 → 拿起拉钩（沿创缘挪位 / 往外拉开），松手留在新位置。
	if cut_open and _outer != null and not _retractors.is_empty():
		var ri0 := _ray_hits_retractor(origin, dir)
		if ri0 >= 0 and _begin_retractor_grab(ri0):
			return true
	# T-11：先看是否点中已悬垂在体外的物理内脏（肠袢 / 柔体器官 / 输卵管悬链 / 脱垂子宫）。
	if _begin_organ_grab(origin, dir):
		return true
	if not can_use_grab():
		return false
	# 已剥离的皮瓣：点中则拿起、拖拽，松手时抛出。
	if flap_node and is_instance_valid(flap_node) and _ray_hits_flap(origin, dir):
		return _begin_flap_grab(origin, dir)
	# 0.4.04：直线切口围出的独立皮瓣——点中它才撕下（点别处仍是拉扯切口皮肉）。
	if free_flap_ready and not (loop_ready and not flap_peeled):
		if _ray_hits_free_flap(origin, dir):
			if peel_flap() and flap_node and is_instance_valid(flap_node):
				return _begin_flap_grab(origin, dir)
			return false
		if cut_open:
			return _begin_skin_grab(origin, dir)
		return false
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
	# 0.4.03：优先按射线最近的唇缘顶点选侧（点到截面 / 腹腔而没点中外皮时，原来一律退回左唇，另一侧选不中）。
	var want_lip := 0
	var pv := _pick_lip_vertex(origin, dir)
	if pv >= 0:
		_activate_cut_for(pv)
	elif hit != null:
		_activate_cut_near((hit as Dictionary)["bind"])
	if pv >= 0:
		want_lip = 1 if _lip_left.has(pv) else (-1 if _lip_right.has(pv) else 0)
	if pv >= 0 and (hit == null or want_lip != 0):
		bind_p = _outer.pos[pv]
		world_p = _vert_world(pv) if hit == null else (hit as Dictionary)["point"]
	elif hit == null:
		# 没精确点中也允许拉最近的唇边，方便测试和粗操作。
		if _lip_left.size() < 1:
			return false
		bind_p = _outer.pos[_lip_left[_lip_left.size() / 2]] if _outer else Vector3.ZERO
		world_p = _approx_world_bind(bind_p)
	else:
		world_p = (hit as Dictionary)["point"]
		bind_p = (hit as Dictionary)["bind"]
	_bake_pull()
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
	_setup_pull_geometry(bind_p, world_p, Vector3.ZERO, want_lip)
	_apply_pull_uniforms()
	return true


## 0.4.0：拿取拉开的位移永久保留。开始新的拿取 / 下一刀 / 剥皮瓣之前，把当前 shader 拉扯位移
## （与 surgery_pull.gdshaderinc 同一公式）换算回绑定空间写进网格，再清零 shader 拉扯。
## 这样拉开 A 侧后再拉 B 侧（或另一条切口），A 侧保持张开；只有「复原身体」会清掉。
func _bake_pull() -> bool:
	if not _retr_release.is_empty():
		_finish_retr_release()
	if _pull_r < 1e-5 or _pull_off.length_squared() < 1e-10 or _outer == null or _skel == null:
		return false
	if _organs == null or not _organs.has_method("abdomen_frame"):
		return false
	_bake_evert()
	var fr: Transform3D = _ab_frame()
	var mds: Array = [_outer]
	if _inner:
		mds.append(_inner)
	for part in _wall_parts:
		var wmd: Geom.MeshData = (part as Dictionary).get("md")
		if wmd:
			mds.append(wmd)
	if _wrap and _wrap.bones.size() >= _wrap.vert_count() * 4:
		mds.append(_wrap)
	var moved := 0
	for md in mds:
		moved += _bake_pull_md(md, fr)
	pulls_baked += 1
	_pull_off = Vector3.ZERO
	_pull_raw = Vector3.ZERO
	_pull_r = 0.0
	_pull_mode = 0
	_pull_peak = 0.0
	_pull_rest = Vector3.ZERO
	_grab_vel = Vector3.ZERO
	_apply_pull_uniforms()
	_rebuild_wall_md()
	_start_eversion()
	_evert = 1.0
	_evert_vel = 0.0
	_evert_anim = false
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	_apply_evert_weight()
	_posed_dirty = true
	return moved > 0


var pulls_baked: int = 0


func _bake_pull_md(md: Geom.MeshData, fr: Transform3D) -> int:
	var n := md.vert_count()
	if n == 0 or md.bones.size() < n * 4:
		return 0
	var w0 := Geom.world_positions(md, _skel, _skin)
	var off_w := PackedVector3Array()
	off_w.resize(n)
	var any := false
	for i in n:
		var o := _pull_offset_cpu(fr.affine_inverse() * w0[i])
		if o.length_squared() > 1e-12:
			off_w[i] = fr.basis * o
			any = true
	if not any:
		return 0
	var h := 0.001
	var cols: Array = []
	for ax in [Vector3(h, 0, 0), Vector3(0, h, 0), Vector3(0, 0, h)]:
		var m := md.clone()
		for i in n:
			m.pos[i] += ax
		cols.append(Geom.world_positions(m, _skel, _skin))
	var moved := 0
	for i in n:
		if off_w[i].length_squared() < 1e-12:
			continue
		var jb := Basis(((cols[0] as PackedVector3Array)[i] - w0[i]) / h, ((cols[1] as PackedVector3Array)[i] - w0[i]) / h, ((cols[2] as PackedVector3Array)[i] - w0[i]) / h)
		if absf(jb.determinant()) < 1e-6:
			continue
		md.pos[i] += jb.inverse() * off_w[i]
		moved += 1
	return moved


## 测试：把当前拉扯并入网格（与开始下一次拿取时相同）。
func debug_bake_pull() -> bool:
	return _bake_pull()


const CROSS_CLEAR := 0.0042
var cross_faces_cleared: int = 0


func _drop_faces_near_path(md: Geom.MeshData, poly: PackedVector2Array, r: float) -> int:
	if poly.size() < 2 or md.face_count() == 0:
		return 0
	var keep := PackedInt32Array()
	var dropped := 0
	for f in md.face_count():
		var c := md.centroid(f)
		var c2 := Vector2(c.x, c.y)
		var near := false
		for i in poly.size() - 1:
			if Geom._dist_point_seg_2d(c2, poly[i], poly[i + 1]) < r:
				near = true
				break
		if near:
			dropped += 1
			continue
		keep.append(md.idx[f * 3])
		keep.append(md.idx[f * 3 + 1])
		keep.append(md.idx[f * 3 + 2])
	if dropped > 0:
		md.idx = keep
	return dropped


func _drop_faces_inside(md: Geom.MeshData, poly: PackedVector2Array) -> Geom.MeshData:
	var keep := PackedInt32Array()
	var dropped := 0
	for f in md.face_count():
		var c := md.centroid(f)
		if Geometry2D.is_point_in_polygon(Vector2(c.x, c.y), poly):
			dropped += 1
			continue
		keep.append(md.idx[f * 3])
		keep.append(md.idx[f * 3 + 1])
		keep.append(md.idx[f * 3 + 2])
	if dropped == 0:
		return md
	md.idx = keep
	return md


## ---- 0.4.01 外露肠子（链条软体） ----
const GutRope := preload("res://scripts/surgery/gut_rope.gd")
const SoftOrgan := preload("res://scripts/surgery/soft_organ.gd")
const GUT_LEN_PER_M := 2.6     # 每米创口尺寸可掉出的肠子长度
const GUT_MAX_LEN := 0.7
const GUT_MIN_OPENING := 0.03  # 创口尺寸低于 3cm 不掉出
var gut_rope: MeshInstance3D = null
var _gut_src: Object = null
var _gut_ids: Array = []       # [a_l, a_r, b_l, b_r] 外皮顶点（两端锚点各取左右唇中点）
var _gut_opening: float = 0.0
var _gut_sig: Array = []


## 创口尺寸（米）：已剥皮瓣的洞取周长，开放的直切口取长度；环切未剥皮瓣 / 弹孔不算。
func wound_opening_size() -> float:
	return _gut_opening


func gut_spill_max() -> float:
	return clampf(_gut_opening * GUT_LEN_PER_M, 0.0, GUT_MAX_LEN) if _gut_opening >= GUT_MIN_OPENING else 0.0


func _gut_rebuild_ids() -> void:
	_gut_src = _outer
	_gut_ids = []
	_gut_opening = 0.0
	if _outer == null or not cut_open:
		return
	var n := _outer.vert_count()
	if flap_peeled and not _hole_loops.is_empty():
		var loop: PackedInt32Array = _hole_loops[_hole_loops.size() - 1]
		var m := loop.size()
		if m < 6:
			return
		var per := 0.0
		for i in m:
			per += _outer.pos[loop[i]].distance_to(_outer.pos[loop[(i + 1) % m]])
		_gut_opening = per
		# 洞缘下半圈相隔约 1/6 周的两点作为肠袢两端（肠子从洞口下缘掉出）
		var lo := 0
		for i2 in m:
			if _outer.pos[loop[i2]].y < _outer.pos[loop[lo]].y:
				lo = i2
		var k := maxi(1, m / 12)
		_gut_ids = [loop[(lo - k + m) % m], loop[(lo - k + m) % m], loop[(lo + k) % m], loop[(lo + k) % m]]
		return
	if _lip_closed:
		return
	var nl := mini(_lip_left.size(), _lip_right.size())
	if nl < 4:
		return
	for id in _lip_left:
		if id < 0 or id >= n:
			return
	var length := 0.0
	for i3 in nl - 1:
		length += _outer.pos[_lip_left[i3]].distance_to(_outer.pos[_lip_left[i3 + 1]])
	_gut_opening = length
	var ia := nl / 3
	var ib := (2 * nl) / 3
	_gut_ids = [_lip_left[ia], _lip_right[ia], _lip_left[ib], _lip_right[ib]]


func _gut_world(i: int, j: int) -> Vector3:
	if pose_locked and _posed_frozen.size() > maxi(i, j):
		return (_posed_frozen[i] + _posed_frozen[j]) * 0.5
	return _skel_xf() * ((Geom.skin_vertex(_outer.pos[i], i, _outer, _skel, _skin) + Geom.skin_vertex(_outer.pos[j], j, _outer, _skel, _skin)) * 0.5)


## 0.4.03：默认不再自动外露 / 悬挂肠子；只有手术钳从腹腔里扯出来的肠袢（_gut_pulls）。
func _update_guts(dt: float) -> void:
	_update_forceps_anim(dt)
	if _outer == null or _skel == null or not cut_open:
		if not _gut_pulls.is_empty() or not _soft_organs.is_empty():
			_clear_guts()
		return
	var sig := [_outer.get_instance_id(), _outer.vert_count(), _outer.idx.size(), flap_peeled, _hole_loops.size()]
	if _gut_src != _outer or sig != _gut_sig:
		_gut_sig = sig
		_gut_rebuild_ids()
		_gut_skin_ids = PackedInt32Array()
		for gp in _gut_pulls:
			_gut_rebind_pull(gp as Dictionary)
	if _gut_pulls.is_empty():
		_sync_gut_hide()
		_update_soft_organs(dt)
		return
	var fr: Transform3D = _ab_frame() if _organs and _organs.has_method("abdomen_frame") else Transform3D.IDENTITY
	var rim := _gut_rim_world()
	var hole_c := Vector3.ZERO
	for q in rim:
		hole_c += q
	if rim.size() > 0:
		hole_c /= float(rim.size())
	var sk := _gut_skin_samples(hole_c)
	var caps := _gut_capsules()
	var fy := -1e9
	var host := get_parent() as Node3D
	if host:
		fy = host.global_position.y
	if is_on_exam_bed():
		fy = maxf(fy, _catch_top_y())
	_carry_ropes(host)
	# 0.4.04：系膜锚点 = 创缘一圈往创口中心收 20%、再往腹腔内 1cm（肠袢挂在创口周围）。
	var na0 := Vector3.ZERO
	for gp0 in _gut_pulls:
		na0 += fr.basis * ((gp0 as Dictionary)["in_ab"] as Vector3)
	na0 = na0.normalized() if na0.length_squared() > 1e-9 else Vector3.ZERO
	var mes_anc := PackedVector3Array()
	for q2 in rim:
		mes_anc.append(q2.lerp(hole_c, 0.2) + na0 * 0.01)
	var all_ropes: Array = []
	for gp3 in _gut_pulls:
		var r3: Node = (gp3 as Dictionary)["rope"]
		if r3 != null and is_instance_valid(r3):
			all_ropes.append(r3)
	for gp2 in _gut_pulls:
		var g: Dictionary = gp2
		var rope: Node = g["rope"]
		if rope == null or not is_instance_valid(rope):
			continue
		var oth: Array = []
		for r4 in all_ropes:
			if r4 != rope and int(r4.call("point_count")) > 0:
				oth.append([(r4.call("points") as PackedVector3Array).duplicate(), (r4.call("radii") as PackedFloat32Array).duplicate()])
		rope.set("others", oth)
		rope.set("mes_anchors", mes_anc)
		var c := _gut_pull_anchor(g, fr)
		var spread: Vector3 = fr.basis * (g["spread_ab"] as Vector3)
		var na: Vector3 = fr.basis * (g["in_ab"] as Vector3)
		var a := c - spread * GUT_ANCHOR_SPREAD
		var b := c + spread * GUT_ANCHOR_SPREAD
		rope.set("anchor_a", a)
		rope.set("anchor_b", b)
		rope.set("exit_a", _gut_exit(a, rim, hole_c, na))
		rope.set("exit_b", _gut_exit(b, rim, hole_c, na))
		rope.set("mes_root", c + na * 0.045)
		rope.set("skin_p", sk[0])
		rope.set("skin_n", sk[1])
		rope.set("capsules", caps)
		rope.set("floor_y", fy)
		rope.call("step", dt)
	# 0.4.05：放回完成的肠袢删掉
	for i in range(_gut_pulls.size() - 1, -1, -1):
		var rr: Node = (_gut_pulls[i] as Dictionary)["rope"]
		if rr != null and is_instance_valid(rr) and bool(rr.call("retract_done")):
			_remove_gut_pull(i)
			gut_putbacks_done += 1
	_sync_gut_hide()
	_update_soft_organs(dt)


## 0.4.08：坐在载具里时外露肠管在载具局部坐标系里模拟（每帧随载体刚体搬运 + 重力随载体转），
## 加速 / 转弯 / 高速都不会甩、拖尾或拉爆；不在载具里时（步行、检查床）完全不变。
var _carrier_prev: Transform3D = Transform3D.IDENTITY
var _carrier_b0: Basis = Basis.IDENTITY
var _carrier_has: bool = false
var carrier_carries: int = 0
# 互动拖拽：腹部软位移的上一帧世界偏移，用来整颗搬运柔体子宫 / 悬链。
var _tissue_drag_prev: Vector3 = Vector3.ZERO
var _tissue_drag_has: bool = false


func _carry_ropes(host: Node) -> void:
	var cx: Variant = host.call("vehicle_carrier") if host and host.has_method("vehicle_carrier") else null
	var grav := Vector3(0.0, -9.8, 0.0)
	if cx is Transform3D:
		var c: Transform3D = cx
		c.basis = c.basis.orthonormalized()
		if not _carrier_has:
			_carrier_has = true
			_carrier_prev = c
			_carrier_b0 = c.basis
		var d := c * _carrier_prev.affine_inverse()
		_carrier_prev = c
		grav = (c.basis * _carrier_b0.inverse()) * grav
		for gp in _gut_pulls:
			var rope: Node = (gp as Dictionary)["rope"]
			if rope and is_instance_valid(rope):
				rope.call("carry", d)
		for sk in _soft_organs.keys():
			var so: Node = _soft_organs[sk]
			if so and is_instance_valid(so) and so.has_method("carry"):
				so.call("carry", d)
		carrier_carries += 1
	else:
		_carrier_has = false
	for gp2 in _gut_pulls:
		var r2: Node = (gp2 as Dictionary)["rope"]
		if r2 and is_instance_valid(r2):
			r2.set("gravity", grav)
	for sk2 in _soft_organs.keys():
		var so2: Node = _soft_organs[sk2]
		if so2 and is_instance_valid(so2):
			so2.set("gravity", grav)


func _gut_inner_world(i: int, j: int, fr: Transform3D) -> Vector3:
	var md: Geom.MeshData = _inner if _inner and _inner.vert_count() == _outer.vert_count() else _outer
	var p: Vector3
	if pose_locked and _posed_frozen.size() > maxi(i, j):
		p = _gut_world(i, j) - fr.basis.z.normalized() * 0.012
	elif _skel == null:
		p = (md.pos[i] + md.pos[j]) * 0.5
	else:
		p = _skel_xf() * ((Geom.skin_vertex(md.pos[i], i, md, _skel, _skin) + Geom.skin_vertex(md.pos[j], j, md, _skel, _skin)) * 0.5)
	if _pull_r > 1e-5:
		p += fr.basis * _pull_offset_cpu(fr.affine_inverse() * p)
	return p


const GUT_TILE_ALBEDO := "res://assets/organs/small_tile_albedo.png"
const GUT_TILE_NORMAL := "res://assets/organs/small_tile_normal.png"


## 体内小肠的材质副本（同贴图 / 同蠕动），加入器官材质列表以接收蠕动时钟；不做腹壁约束。
func _gut_organ_material() -> ShaderMaterial:
	if _organs == null:
		return null
	var mats = _organs.get("_organ_mats")
	if not (mats is Array):
		return null
	var src: ShaderMaterial = null
	for m in mats:
		var sm := m as ShaderMaterial
		if sm == null or not bool(sm.get_shader_parameter("is_gut")):
			continue
		var tex = sm.get_shader_parameter("albedo_tex")
		if tex is Texture2D and str((tex as Texture2D).resource_path).find("small") >= 0:
			src = sm
			break
	if src == null:
		return null
	var dup := src.duplicate() as ShaderMaterial
	dup.set_shader_parameter("strike_k", 0.3)
	# 0.4.03：小肠贴图是 UV 图集（岛 + 底色），平铺到管子上会露出底色和接缝；换成从同一贴图截取的无缝平铺块。
	if ResourceLoader.exists(GUT_TILE_ALBEDO):
		dup.set_shader_parameter("albedo_tex", load(GUT_TILE_ALBEDO))
	if ResourceLoader.exists(GUT_TILE_NORMAL):
		dup.set_shader_parameter("normal_tex", load(GUT_TILE_NORMAL))
	dup.set_meta("exposed_gut", true)
	(mats as Array).append(dup)
	if _organs.has_method("register_deform_material"):
		_organs.call("register_deform_material", dup, false)
	return dup


## 四肢精细命中箱胶囊（世界坐标 [a, b, r]）：手臂 / 手 / 腿 / 脚。躯干、头不算（锚点本来就在腹腔里）。
func _gut_capsules() -> Array:
	var out: Array = []
	var host := get_parent()
	if host == null or not host.has_method("get_hitboxes"):
		return out
	var hb: Node = host.call("get_hitboxes")
	if hb == null:
		return out
	for body in hb.get_children():
		if not (body is Node3D):
			continue
		var bone := str((body as Node).get_meta("hitbox_bone", ""))
		if bone.begins_with("C_"):
			continue
		for cs in (body as Node).get_children():
			if cs is CollisionShape3D and (cs as CollisionShape3D).shape is CapsuleShape3D:
				var cap := (cs as CollisionShape3D).shape as CapsuleShape3D
				var xf := (cs as CollisionShape3D).global_transform
				var ax := xf.basis.y.normalized()
				var hh := maxf(cap.height * 0.5 - cap.radius, 0.0)
				out.append([xf.origin - ax * hh, xf.origin + ax * hh, cap.radius])
	return out


var _gut_hide_sig: Array = []
var gut_hide_usec: int = 0
# 小肠累积隐藏区间：多点扯出只增不减，放回才收缩。
var _gut_hide_acc: Dictionary = {"colon": [], "small_intestine": []}


func _sync_gut_hide() -> void:
	if _organs == null or not _organs.has_method("set_gut_eaten"):
		return
	var t0 := Time.get_ticks_usec()
	if _gut_pulls.is_empty():
		if not _gut_hide_sig.is_empty():
			if _organs.has_method("clear_gut_eaten"):
				_organs.call("clear_gut_eaten")
			_gut_hide_sig = []
			_gut_hide_acc = {"colon": [], "small_intestine": []}
		gut_hide_usec = Time.get_ticks_usec() - t0
		return
	var by := {"colon": [], "small_intestine": []}
	var sig: Array = []
	for gp in _gut_pulls:
		var g: Dictionary = gp
		var k := "colon" if str(g.get("kind", "")) == "colon" else "small_intestine"
		var rope: Node = g.get("rope")
		if rope == null or not is_instance_valid(rope):
			continue
		var retracting := bool(rope.get("retracting"))
		var fed := float(rope.get("fed_len"))
		var plen := float(_organs.call("gut_path_length", k)) if _organs.has_method("gut_path_length") else 0.6
		if not g.has("along") or not (g["along"] is float):
			var hit: Vector3 = g.get("hit", Vector3.INF)
			if hit == Vector3.INF:
				hit = _gut_pull_anchor(g, _ab_frame() if _organs.has_method("abdomen_frame") else Transform3D.IDENTITY)
			g["along"] = float(_organs.call("gut_along_near", k, hit)) if _organs.has_method("gut_along_near") else 0.5
		var along := float(g["along"])
		var rate := SI_HIDE_RATE if k == "small_intestine" else 1.0
		var win: Vector4 = _organs.call("gut_hide_window", along, fed, plen, rate) if _organs.has_method("gut_hide_window") else Vector4(along, clampf(fed * rate / maxf(plen, 0.08) * 0.5, 0.0, 0.5), 1.0, 0.0)
		var cur_iv: Vector2 = _organs.call("gut_hide_interval", win) if _organs.has_method("gut_hide_interval") else Vector2(clampf(win.x - win.y, 0.0, 1.0), clampf(win.x + win.y, 0.0, 1.0))
		var prev_iv: Vector2 = g["hide_iv"] if g.get("hide_iv") is Vector2 else Vector2(1.0, 0.0)
		# 小肠多点扯出：在已有隐藏上累加，未放回时绝不把已藏的肠段重新显示。
		if retracting or k != "small_intestine":
			g["hide_iv"] = cur_iv
		elif _organs.has_method("grow_hide_interval"):
			g["hide_iv"] = _organs.call("grow_hide_interval", prev_iv, cur_iv)
		else:
			if prev_iv.y > prev_iv.x and cur_iv.y > cur_iv.x:
				g["hide_iv"] = Vector2(minf(prev_iv.x, cur_iv.x), maxf(prev_iv.y, cur_iv.y))
			elif cur_iv.y > cur_iv.x:
				g["hide_iv"] = cur_iv
			else:
				g["hide_iv"] = prev_iv
		sig.append([k, snapped(fed, 0.002), snapped(along, 0.01), snapped((g["hide_iv"] as Vector2).x, 0.01), snapped((g["hide_iv"] as Vector2).y, 0.01), retracting])
	for kind2 in ["colon", "small_intestine"]:
		var ivs: Array = []
		var any_live := false
		var any_retract := false
		for gp2 in _gut_pulls:
			var g2: Dictionary = gp2
			var k2 := "colon" if str(g2.get("kind", "")) == "colon" else "small_intestine"
			if k2 != kind2:
				continue
			var rope2: Node = g2.get("rope")
			if rope2 == null or not is_instance_valid(rope2):
				continue
			any_live = true
			if bool(rope2.get("retracting")):
				any_retract = true
			if g2.get("hide_iv") is Vector2:
				ivs.append(g2["hide_iv"])
		var acc: Array = _gut_hide_acc.get(kind2, [])
		var merged: Array = _organs.call("merge_hide_intervals", ivs) if _organs.has_method("merge_hide_intervals") else ivs
		if not any_live:
			merged = []
		elif kind2 == "small_intestine" and not any_retract:
			var both: Array = []
			both.append_array(acc)
			both.append_array(merged)
			merged = _organs.call("merge_hide_intervals", both) if _organs.has_method("merge_hide_intervals") else merged
		_gut_hide_acc[kind2] = merged
		if _organs.has_method("intervals_to_eat_windows"):
			by[kind2] = _organs.call("intervals_to_eat_windows", merged)
		else:
			by[kind2] = merged
	if sig == _gut_hide_sig:
		gut_hide_usec = Time.get_ticks_usec() - t0
		return
	_gut_hide_sig = sig
	_organs.call("set_gut_eaten", "colon", by["colon"])
	_organs.call("set_gut_eaten", "small_intestine", by["small_intestine"])
	gut_hide_usec = Time.get_ticks_usec() - t0


func _clear_guts() -> void:
	for gp in _gut_pulls:
		var rope: Node = (gp as Dictionary).get("rope")
		if rope and is_instance_valid(rope):
			var gm := (rope as GeometryInstance3D).material_override as ShaderMaterial
			if gm and gm.has_meta("exposed_gut") and _organs:
				for key in ["_organ_mats", "_all_mats"]:
					var arr = _organs.get(key)
					if arr is Array:
						(arr as Array).erase(gm)
			rope.queue_free()
	_gut_pulls.clear()
	gut_rope = null
	_gut_src = null
	_gut_ids = []
	_gut_opening = 0.0
	_gut_sig = []
	_gut_skin_ids = PackedInt32Array()
	_gut_skin_p = PackedVector3Array()
	_gut_skin_n = PackedVector3Array()
	_fc_active = false
	_fc_pull = -1
	_fc_kind = "gut"
	_fc_soft_kind = ""
	_fc_tube_side = -1
	_clear_soft_organs()
	_tissue_drag_has = false
	_tissue_drag_prev = Vector3.ZERO
	if _organs and _organs.has_method("clear_gut_eaten"):
		_organs.call("clear_gut_eaten")
	_gut_hide_acc = {"colon": [], "small_intestine": []}
	_gut_hide_sig = []
	_set_selected_organ("")
	_set_hovered_organ("")
	if _forceps_node and is_instance_valid(_forceps_node):
		_forceps_node.visible = false


func has_exposed_guts() -> bool:
	for gp in _gut_pulls:
		var rope: Node = (gp as Dictionary).get("rope")
		if rope and is_instance_valid(rope) and not rope.is_queued_for_deletion():
			return true
	return false


## ---- 0.4.03 手术钳（Overholt 弯头钳，工具包 8 / 9 号之间那把）：夹住腹腔内的肠子往外扯 ----
const FORCEPS_SCENE := "res://assets/surgery/forceps.glb"
const FORCEPS_OPEN_DEG := 11.0
const FORCEPS_JAW_Z := 0.042      # 模型里钳尖到铰链的距离（+Z）
const GUT_ANCHOR_SPREAD := 0.011  # 肠袢两端锚点相距 2.2cm
const GUT_PULL_MAX := 1.2         # 一次最多扯出 1.2m
const SI_HIDE_RATE := 0.48        # 小肠体内隐藏长度 / 已扯出长度（略快于 0.35，仍远慢于 1.0）
const GUT_PICK_DIST := 0.014
const GUT_MAX_PULLS := 4
## 0.4.05：手术钳子选项「扯出」/「放回」。放回：把肠袢拖到它的创口锚点附近松手，约 1 秒内一节节缩回体内。
const PUTBACK_RADIUS := 0.045
const PUTBACK_TIME := 1.0
## 0.4.11：大肠（单点、更粗更短、更大阻尼）与子宫 / 膀胱五档柔体脱出。
const COLON_PULL_MAX := 0.58
const COLON_RADIUS := 0.0148
const COLON_SEG := 0.028
const COLON_DAMP := 0.88
const COLON_MIN_PTS := 7
const COLON_MAX_PTS := 28
const COLON_MES_EVERY := 5
const COLON_TILE_ALBEDO := "res://assets/organs/colon_tile_albedo.png"
const COLON_TILE_NORMAL := "res://assets/organs/colon_tile_normal.png"
const ORGAN_CHARGE_RATE := 0.32
const ORGAN_PUTBACK_RATE := 0.85
const TUBE_CHAIN_LEVEL := 4
const UTERUS_SPECULUM_HINT := "请先取出阴道扩张器，再扯出子宫。"
signal forceps_mode_changed(mode: String)
signal surgery_hint(text: String)
var forceps_mode: String = "pull"
var gut_putbacks: int = 0
var gut_putbacks_done: int = 0


func set_forceps_mode(m: String) -> void:
	m = "putback" if m == "putback" else "pull"
	if m == forceps_mode:
		return
	forceps_mode = m
	forceps_mode_changed.emit(m)


func get_forceps_mode() -> String:
	return forceps_mode


## 肠袢的创口锚点（两个出口的中点）。
func gut_wound_anchor(rope: Node) -> Vector3:
	return ((rope.get("exit_a") as Vector3) + (rope.get("exit_b") as Vector3)) * 0.5


func _remove_gut_pull(i: int) -> void:
	var rope: Node = (_gut_pulls[i] as Dictionary).get("rope")
	if rope and is_instance_valid(rope):
		var gm := (rope as GeometryInstance3D).material_override as ShaderMaterial
		if gm and _organs:
			for key in ["_organ_mats", "_all_mats"]:
				var arr = _organs.get(key)
				if arr is Array:
					(arr as Array).erase(gm)
		rope.queue_free()
	_gut_pulls.remove_at(i)
	if _fc_pull == i:
		_fc_active = false
		_fc_pull = -1
	elif _fc_pull > i:
		_fc_pull -= 1
	gut_rope = (_gut_pulls[_gut_pulls.size() - 1] as Dictionary)["rope"] if not _gut_pulls.is_empty() else null
var _gut_pulls: Array = []        # {rope, vid, off_ab, spread_ab, in_ab}
var _gut_skin_ids: PackedInt32Array = PackedInt32Array()
var _gut_skin_p: PackedVector3Array = PackedVector3Array()
var _gut_skin_n: PackedVector3Array = PackedVector3Array()
var _gut_skin_frame: int = 0
var _forceps_node: Node3D = null
var _fc_active := false
var _fc_pull := -1
var _fc_last := Vector3.ZERO
var _fc_anim := 1.0       # 0 = 张开，1 = 夹紧
var _fc_target := 1.0
var _fc_hide_t := 0.0
var _fc_preview_valid := false
var _fc_preview_pt := Vector3.ZERO
var forceps_hover_usec: int = 0
var _fc_pressing := false
var _fc_press_t := 0.0
var _fc_press_origin := Vector3.ZERO
var _fc_press_dir := Vector3.DOWN
var _fc_marker: MeshInstance3D = null
const FORCEPS_LONGPRESS := 1.0
var forceps_clamps: int = 0
var gut_update_usec: int = 0
var _soft_organs: Dictionary = {}   # "uterus" / "bladder" -> SoftOrgan
var _fc_kind: String = "gut"        # gut | soft | tube | prolapse | prolapse_out
var _fc_soft_kind: String = ""
var _fc_tube_side: int = -1
var extraction_hint: String = ""
var organ_putbacks: int = 0
var hovered_organ: String = ""
var selected_organ: String = ""
signal organ_target_changed(label: String)


func organ_display_name(kind: String) -> String:
	match kind:
		"uterus", "uterus_cavity":
			return "子宫"
		"tube":
			return "输卵管"
		"ovary":
			return "卵巢"
		"small_intestine", "small":
			return "小肠"
		"colon":
			return "大肠"
		"bladder":
			return "膀胱"
		_:
			return ""


func get_organ_target_label() -> String:
	# 实时：悬停目标优先，没有悬停时再显示已夹住/已选中的目标。
	var k := hovered_organ if hovered_organ != "" else selected_organ
	return organ_display_name(k)


func _set_hovered_organ(kind: String) -> void:
	if hovered_organ == kind:
		return
	hovered_organ = kind
	organ_target_changed.emit(get_organ_target_label())


func _set_selected_organ(kind: String) -> void:
	if selected_organ != kind:
		selected_organ = kind
		var cn := organ_display_name(kind)
		if cn != "":
			extraction_hint = "当前选择：%s" % cn
			surgery_hint.emit(extraction_hint)
		organ_target_changed.emit(get_organ_target_label())


func _hover_forceps(origin: Vector3, dir: Vector3) -> void:
	if not cut_open:
		_set_hovered_organ(selected_organ)
		return
	var rec := _pick_forceps_aim(origin, dir)
	var kind := str(rec.get("kind", ""))
	_set_hovered_organ(kind)


func gut_pull_count() -> int:
	return _gut_pulls.size()


func gut_ropes() -> Array:
	var out: Array = []
	for gp in _gut_pulls:
		out.append((gp as Dictionary)["rope"])
	return out


func forceps_node() -> Node3D:
	return _forceps_node


func forceps_jaw_angle() -> float:
	return FORCEPS_OPEN_DEG * (1.0 - _fc_anim)


## 肠袢锚点 / 创缘 / 皮肤采样一律按当前骨骼实时蒙皮（不用下刀时冻结的姿势），始终跟着身体走。
func _inner_world(vid: int) -> Vector3:
	var md: Geom.MeshData = _inner if _inner and _inner.vert_count() == _outer.vert_count() else _outer
	return _skel_xf() * Geom.skin_vertex(md.pos[vid], vid, md, _skel, _skin)


func _outer_live(vid: int) -> Vector3:
	return _skel_xf() * Geom.skin_vertex(_outer.pos[vid], vid, _outer, _skel, _skin)


func _gut_pull_anchor(g: Dictionary, fr: Transform3D) -> Vector3:
	var vid: int = g["vid"]
	if vid < 0 or vid >= _outer.vert_count():
		return (g["rope"] as Node3D).get("anchor_a") if g.get("rope") else Vector3.ZERO
	var p := _inner_world(vid)
	if _pull_r > 1e-5:
		p += fr.basis * _pull_offset_cpu(fr.affine_inverse() * p)
	return p + fr.basis * (g["off_ab"] as Vector3)


## 拓扑变化（又切了一刀）后按绑定坐标重新找参考顶点。
func _gut_rebind_pull(g: Dictionary) -> void:
	var bp: Vector3 = g.get("bind", Vector3.INF)
	if bp == Vector3.INF or _outer == null:
		return
	var best := -1
	var bd := 1e9
	for v in _outer.vert_count():
		var d := _outer.pos[v].distance_squared_to(bp)
		if d < bd:
			bd = d
			best = v
	g["vid"] = best


## 当前创口边缘（世界坐标）：最近一刀的两唇 / 洞缘。
func _gut_rim_world() -> PackedVector3Array:
	var out := PackedVector3Array()
	var ids := PackedInt32Array()
	if flap_peeled and not _hole_loops.is_empty():
		ids = _hole_loops[_hole_loops.size() - 1]
	else:
		ids.append_array(_lip_left)
		ids.append_array(_lip_right)
	# 0.4.06：弹孔 / 肚脐捅穿 / 刺刀切口只有 _hole_loops，没有左右唇
	if ids.is_empty() and not _hole_loops.is_empty():
		for loop2 in _hole_loops:
			if loop2 is PackedInt32Array:
				ids.append_array(loop2 as PackedInt32Array)
	var nv := _outer.vert_count()
	var step := maxi(1, ids.size() / 48)
	for i in range(0, ids.size(), step):
		if ids[i] >= 0 and ids[i] < nv:
			out.append(_outer_live(ids[i]))
	return out


## 出口：离锚点最近的创缘点往创口中心收 35%、再抬出皮面 4mm——肠子从这里搭出创缘。
func _gut_exit(anchor: Vector3, rim: PackedVector3Array, hole_c: Vector3, in_w: Vector3) -> Vector3:
	if rim.is_empty():
		return anchor - in_w * 0.03
	var best := rim[0]
	var bd := 1e9
	for q in rim:
		var d := q.distance_squared_to(anchor)
		if d < bd:
			bd = d
			best = q
	return best.lerp(hole_c, 0.35) - in_w.normalized() * 0.004


## 创口周围外皮采样（世界坐标位置 + 法线），供体外肠子做皮肤碰撞（搭在创缘上，不穿腹壁）。
func _gut_skin_samples(hole_c_w: Vector3) -> Array:
	if _gut_skin_ids.is_empty():
		var cb := Vector3.ZERO
		var rim_ids: PackedInt32Array = _hole_or_lip_ids()
		var cnt := 0
		for id in rim_ids:
			if id >= 0 and id < _outer.vert_count():
				cb += _outer.pos[id]
				cnt += 1
		cb = cb / float(maxi(cnt, 1)) if cnt > 0 else _navel_rest
		var cand := PackedInt32Array()
		for v in _outer.vert_count():
			if Vector2(_outer.pos[v].x - cb.x, _outer.pos[v].y - cb.y).length() < 0.16:
				cand.append(v)
		var stp := maxi(1, cand.size() / 200)
		for i in range(0, cand.size(), stp):
			_gut_skin_ids.append(cand[i])
		for id2 in rim_ids:
			if id2 >= 0 and id2 < _outer.vert_count():
				_gut_skin_ids.append(id2)
	# 位置每 2 帧、法线每 8 帧更新一次（法线只用于判断皮肤外侧方向，变化慢）。
	_gut_skin_frame += 1
	var n := _gut_skin_ids.size()
	var need_n := _gut_skin_n.size() != n or _gut_skin_frame % 8 == 0
	if _gut_skin_p.size() == n and not need_n and _gut_skin_frame % 2 == 1:
		return [_gut_skin_p, _gut_skin_n]
	_gut_skin_p.resize(n)
	if need_n:
		_gut_skin_n.resize(n)
	var gx := _skel_xf()
	for k in n:
		var v2: int = _gut_skin_ids[k]
		var p0 := gx * Geom.skin_vertex(_outer.pos[v2], v2, _outer, _skel, _skin)
		_gut_skin_p[k] = p0
		if need_n:
			var p1 := gx * Geom.skin_vertex(_outer.pos[v2] + _outer.nrm[v2].normalized() * 0.01, v2, _outer, _skel, _skin)
			_gut_skin_n[k] = (p1 - p0).normalized()
	return [_gut_skin_p, _gut_skin_n]


func _ensure_forceps_node() -> void:
	if _forceps_node and is_instance_valid(_forceps_node):
		return
	var ps: PackedScene = load(FORCEPS_SCENE) if ResourceLoader.exists(FORCEPS_SCENE) else null
	if ps:
		_forceps_node = ps.instantiate() as Node3D
	else:
		_forceps_node = Node3D.new()
	_forceps_node.name = "Forceps"
	_forceps_node.top_level = true
	_forceps_node.add_to_group(CAMERA_IGNORE_GROUP)
	_forceps_node.visible = false
	add_child(_forceps_node)


func _set_forceps_jaw(angle_deg: float) -> void:
	if _forceps_node == null:
		return
	var a := _forceps_node.find_child("JawPosX", true, false) as Node3D
	var b := _forceps_node.find_child("JawNegX", true, false) as Node3D
	if a:
		a.rotation = Vector3(0, deg_to_rad(angle_deg), 0)
	if b:
		b.rotation = Vector3(0, -deg_to_rad(angle_deg), 0)


## T-11：钳子绕钳口倾斜（钳柄偏向画面右下），不再正对镜头只看到一个点。
const FORCEPS_TILT_DEG := 32.0


func forceps_tilted_axis(dir: Vector3) -> Vector3:
	var z0 := dir.normalized()
	if z0.length_squared() < 1e-8:
		z0 = Vector3.FORWARD
	var up0 := Vector3.UP if absf(z0.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x0 := up0.cross(z0).normalized()   # 画面左
	var y0 := z0.cross(x0).normalized()    # 画面上
	# 钳柄端（-z）往画面右下偏：z 朝左上转 FORCEPS_TILT_DEG。
	var side := (x0 * 0.55 + y0 * 0.84).normalized()
	var t := deg_to_rad(FORCEPS_TILT_DEG)
	return (z0 * cos(t) + side * sin(t)).normalized()


func _place_forceps(tip: Vector3, dir: Vector3) -> void:
	_ensure_forceps_node()
	var z := forceps_tilted_axis(dir)
	var up := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	var bs := Basis(x, y, z)
	_forceps_node.global_transform = Transform3D(bs, tip - z * FORCEPS_JAW_Z)
	_forceps_node.visible = true


func _update_forceps_anim(dt: float) -> void:
	# 手机长按计时不依赖钳子模型是否已创建。
	if _fc_pressing and not _fc_active and touch_pick:
		_fc_press_t += dt
		if _fc_press_t + 1e-4 >= FORCEPS_LONGPRESS:
			_begin_forceps(_fc_press_origin, _fc_press_dir)
	if not _fc_active and _fc_preview_valid and tool == "forceps":
		_fc_target = 0.0
		_fc_hide_t = 0.3
		_place_forceps(_fc_preview_pt, _preview_forceps_dir())
	if _forceps_node == null or not is_instance_valid(_forceps_node):
		return
	_fc_anim = move_toward(_fc_anim, _fc_target, dt / 0.14)
	_set_forceps_jaw(forceps_jaw_angle())
	if not _fc_active and _forceps_node.visible and not (_fc_preview_valid and tool == "forceps"):
		_fc_hide_t -= dt
		if _fc_hide_t <= 0.0:
			_forceps_node.visible = false
			_hide_forceps_marker()
	if _fc_active and _fc_kind == "gut" and _fc_pull >= 0 and _fc_pull < _gut_pulls.size():
		var rope: Node3D = (_gut_pulls[_fc_pull] as Dictionary)["rope"]
		if rope and is_instance_valid(rope):
			var cam := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
			var d: Vector3 = (rope.get("hold_pos") - cam.global_position) if cam else Vector3.FORWARD
			_place_forceps(rope.get("hold_pos"), d)
	elif _fc_active and _fc_kind == "prolapse_out":
		var pca := _prolapse_ctl()
		if pca and int(pca.call("drive_node")) >= 0:
			var np: Vector3 = (pca.call("node_positions") as PackedVector3Array)[int(pca.call("drive_node"))]
			var cam4 := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
			_place_forceps(np, (np - cam4.global_position) if cam4 else Vector3.FORWARD)
	elif _fc_active and _fc_kind == "soft":
		var so_f := _soft_node(_fc_soft_kind)
		if so_f:
			var hp: Vector3 = so_f.get("hold_pos")
			_fc_last = hp
			var cam2 := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
			var d2: Vector3 = (hp - cam2.global_position) if cam2 else Vector3.FORWARD
			_place_forceps(hp, d2)
	elif _fc_active and _fc_kind == "tube":
		var so_t := _soft_node(_fc_soft_kind)
		if so_t:
			for r in so_t.call("chain_ropes"):
				if r and int(r.get("hold_index")) >= 0:
					var hpt: Vector3 = r.get("hold_pos")
					_fc_last = hpt
					var cam3 := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
					var d3: Vector3 = (hpt - cam3.global_position) if cam3 else Vector3.FORWARD
					_place_forceps(hpt, d3)
					break


## 射线与腹腔（器官椭球）的交点，且必须穿过开放创口（前面没有完整皮肤挡着）。
func _ray_cavity_hit_cheap(origin: Vector3, dir: Vector3) -> Variant:
	# 悬停跟随用：只打腹腔椭球 + 创缘距离，不遍历整张腹皮。
	if _outer == null or not cut_open or _organs == null:
		return null
	var ec = _organs.get("_ellipsoid_c")
	var er = _organs.get("_ellipsoid_r")
	if not (ec is Vector3 and er is Vector3):
		return null
	var fr: Transform3D = _ab_frame()
	var inv := fr.affine_inverse()
	var r3: Vector3 = (er as Vector3) * 0.92
	var lo := ((inv * origin) - (ec as Vector3)) / r3
	var ld := (inv.basis * dir.normalized()) / r3
	var A := ld.dot(ld)
	var B := 2.0 * lo.dot(ld)
	var C := lo.dot(lo) - 1.0
	var disc := B * B - 4.0 * A * C
	if disc < 0.0 or A < 1e-12:
		return null
	var t := (-B - sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		t = (-B + sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		return null
	var hit := origin + dir.normalized() * t
	var rim := _gut_rim_world()
	var near := 1e9
	for q in rim:
		near = minf(near, q.distance_to(hit))
	if near > (0.09 if touch_pick else 0.06):
		return null
	return hit


func _ray_cavity_hit(origin: Vector3, dir: Vector3) -> Variant:
	if _outer == null or not cut_open or _organs == null:
		return null
	var ec = _organs.get("_ellipsoid_c")
	var er = _organs.get("_ellipsoid_r")
	if not (ec is Vector3 and er is Vector3):
		return null
	var fr: Transform3D = _ab_frame()
	var inv := fr.affine_inverse()
	var r3: Vector3 = (er as Vector3) * 0.92
	var lo := ((inv * origin) - (ec as Vector3)) / r3
	var ld := (inv.basis * dir.normalized()) / r3
	var A := ld.dot(ld)
	var B := 2.0 * lo.dot(ld)
	var C := lo.dot(lo) - 1.0
	var disc := B * B - 4.0 * A * C
	if disc < 0.0 or A < 1e-12:
		return null
	var t := (-B - sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		t = (-B + sqrt(disc)) / (2.0 * A)
	if t < 0.0:
		return null
	var hit := origin + dir.normalized() * t
	var rim := _gut_rim_world()
	var near := 1e9
	for q in rim:
		near = minf(near, q.distance_to(hit))
	if near > (0.09 if touch_pick else 0.06):
		return null
	var sh: Variant = Geom.ray_hit_mesh(_outer, _posed_world(), origin, dir)
	if sh != null:
		var sp: Vector3 = (sh as Dictionary)["point"]
		if sp.distance_to(origin) < t - 0.004:
			# 皮肤挡在前面：只有点在创缘附近（狭窄切口）才算伸进了创口
			var near2 := 1e9
			for q2 in rim:
				near2 = minf(near2, q2.distance_to(sp))
			# 直切口缝很窄（6mm）；弹孔 / 捅穿孔径约 1.5cm，唇缘外翻后略放宽，触屏再稍加容差。
			var lip_tol := 0.022 if (bullet_holes > 0 or (flap_peeled and not _hole_loops.is_empty())) else 0.006
			if touch_pick:
				lip_tol = maxf(lip_tol, 0.018)
			if near2 > lip_tol:
				return null
	return hit


func _begin_forceps_pointer(origin: Vector3, dir: Vector3) -> bool:
	_hover_forceps(origin, dir)
	_preview_forceps(origin, dir)
	if touch_pick:
		# 手机：点一下只显示名称和标记，满 1 秒长按才夹住拖拽。
		if not _fc_preview_valid and hovered_organ == "":
			return false
		_fc_pressing = true
		_fc_press_t = 0.0
		_fc_press_origin = origin
		_fc_press_dir = dir
		_show_forceps_marker(_fc_preview_pt if _fc_preview_valid else _fc_last)
		stroke_active = true
		return true
	# 电脑：按住左键立即夹住并拖拽。
	return _begin_forceps(origin, dir)


func _preview_forceps_dir() -> Vector3:
	if is_inside_tree() and get_viewport():
		var cam := get_viewport().get_camera_3d()
		if cam:
			var d: Vector3 = _fc_preview_pt - cam.global_position
			if d.length_squared() > 1e-8:
				return d.normalized()
	return Vector3.FORWARD


func _pick_forceps_aim(origin: Vector3, dir: Vector3) -> Dictionary:
	# 一次遍历：悬停名称 + 钳尖位置。已扯出的肠袢不得挡住仍可见的体内肠管。
	var d := dir.normalized()
	var best := _gut_pick_dist()
	var kind := ""
	var best_p := Vector3.INF
	var rope_t := 1e9
	var rope_perp := 1e9
	var rope_rad := 0.008
	if cut_open:
		for i in _gut_pulls.size():
			var rope: Node = (_gut_pulls[i] as Dictionary).get("rope")
			if rope == null or not is_instance_valid(rope) or bool(rope.get("retracting")):
				continue
			var pk: Array = rope.call("ray_pick", origin, d)
			if int(pk[0]) >= 0 and float(pk[1]) < best:
				best = float(pk[1])
				rope_perp = float(pk[1])
				kind = "colon" if str((_gut_pulls[i] as Dictionary).get("kind", "")) == "colon" else "small_intestine"
				var pts: PackedVector3Array = rope.call("points")
				var hi := int(pk[0])
				best_p = pts[hi] if hi >= 0 and hi < pts.size() else origin + d * 0.2
				rope_t = origin.distance_to(best_p)
				rope_rad = float(rope.get("radius")) if "radius" in rope else rope_rad
		var soft_kind := ""
		for k in _soft_organs.keys():
			var so: Node = _soft_organs[k]
			if so == null or not is_instance_valid(so) or not bool(so.call("is_extracted")):
				continue
			if so.has_method("ray_pick_adnexa"):
				var ts: int = int(so.call("ray_pick_adnexa", origin, d))
				if ts >= 0:
					soft_kind = "tube"
					best_p = so.call("horn_world", ts) if so.has_method("horn_world") else so.call("fundus_world")
					best = 0.0
			var pk2: Array = so.call("ray_pick", origin, d)
			if int(pk2[0]) >= 0 and float(pk2[1]) < best:
				best = float(pk2[1])
				soft_kind = str(k)
				var cage: PackedVector3Array = so.get("_p")
				var idx := int(pk2[0])
				best_p = cage[idx] if idx >= 0 and idx < cage.size() else so.call("fundus_world")
		if soft_kind != "":
			kind = soft_kind
		if _organs:
			var pick: Dictionary = {}
			if _organs.has_method("ray_pick_viscera_fast"):
				pick = _organs.call("ray_pick_viscera_fast", origin, d)
			if pick.is_empty() and _organs.has_method("ray_pick_viscera"):
				pick = _organs.call("ray_pick_viscera", origin, d)
			if not pick.is_empty() and pick.has("point"):
				var vk := str(pick.get("kind", ""))
				var vp: Vector3 = pick["point"]
				var vt := origin.distance_to(vp)
				var visible_gut := vk == "small_intestine" or vk == "colon"
				# 射线点到仍可见的体内肠管时，优先它，而不是被体外肠袢的宽松距离挡住。
				var rope_blocks := rope_perp < (rope_rad + 0.0035) and rope_t + 0.010 < vt
				if visible_gut and not rope_blocks:
					kind = vk
					best_p = vp
				elif kind == "" or (best_p == Vector3.INF) or (not visible_gut and vt < origin.distance_to(best_p) + 0.01 and soft_kind == ""):
					if kind == "":
						kind = vk
					if best_p == Vector3.INF or vt < origin.distance_to(best_p) + 0.01:
						best_p = vp
						if kind == "":
							kind = vk
	if best_p == Vector3.INF:
		var cav = _ray_cavity_hit_cheap(origin, d)
		if cav != null:
			best_p = cav
	return {"kind": kind, "point": best_p, "valid": best_p != Vector3.INF, "rope_t": rope_t, "rope_perp": rope_perp}


func _forceps_aim_point(origin: Vector3, dir: Vector3) -> Variant:
	var rec := _pick_forceps_aim(origin, dir)
	if not bool(rec.get("valid", false)):
		return null
	return rec["point"]


func _preview_forceps(origin: Vector3, dir: Vector3) -> void:
	var pt = _forceps_aim_point(origin, dir)
	if pt == null:
		return
	_fc_preview_valid = true
	_fc_preview_pt = pt
	_fc_target = 0.0
	_place_forceps(pt, dir)
	if touch_pick:
		_show_forceps_marker(pt)


func _show_forceps_marker(pt: Vector3) -> void:
	if _fc_marker == null or not is_instance_valid(_fc_marker):
		_fc_marker = MeshInstance3D.new()
		_fc_marker.name = "ForcepsGrabMarker"
		_fc_marker.top_level = true
		_fc_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fc_marker.add_to_group(CAMERA_IGNORE_GROUP)
		var sm := SphereMesh.new()
		sm.radius = 0.0055
		sm.height = 0.011
		sm.radial_segments = 10
		sm.rings = 6
		_fc_marker.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.92, 0.35)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.2)
		mat.emission_energy_multiplier = 1.4
		_fc_marker.material_override = mat
		add_child(_fc_marker)
	_fc_marker.global_position = pt
	_fc_marker.visible = true


func _hide_forceps_marker() -> void:
	if _fc_marker and is_instance_valid(_fc_marker):
		_fc_marker.visible = false


func _clear_forceps_preview() -> void:
	_fc_preview_valid = false
	_fc_pressing = false
	_fc_press_t = 0.0
	_hide_forceps_marker()
	if not _fc_active and _forceps_node and is_instance_valid(_forceps_node):
		_fc_hide_t = 0.0
		_forceps_node.visible = false


func forceps_longpress_seconds() -> float:
	return FORCEPS_LONGPRESS


func is_forceps_clamped() -> bool:
	return _fc_active


func has_forceps_preview() -> bool:
	return _fc_preview_valid


func forceps_preview_point() -> Vector3:
	return _fc_preview_pt


func forceps_press_time() -> float:
	return _fc_press_t


func debug_forceps_preview(origin: Vector3, dir: Vector3) -> String:
	set_touch_pick(false)
	ensure_tool("forceps")
	hover_tool(origin, dir)
	return str(call("get_organ_target_label"))


func debug_forceps_hover_profile(origin: Vector3, dir: Vector3, n: int = 16, uncached: bool = false) -> Dictionary:
	n = maxi(n, 1)
	var t0 := Time.get_ticks_usec()
	for i in n:
		if uncached:
			# 旧路径：每次 surface_get_arrays + 全三角形 + 腹皮网格。
			if _organs and _organs.has_method("ray_pick_viscera_uncached"):
				_organs.call("ray_pick_viscera_uncached", origin, dir)
			_ray_cavity_hit(origin, dir)
		else:
			hover_tool(origin, dir)
	var us := float(Time.get_ticks_usec() - t0) / float(n)
	return {"us": us, "label": get_organ_target_label(), "uncached": uncached}


func debug_forceps_touch_begin(origin: Vector3, dir: Vector3) -> bool:
	set_touch_pick(true)
	return _begin_forceps_pointer(origin, dir)


func debug_forceps_tick(dt: float) -> void:
	_update_forceps_anim(dt)
	if _fc_active:
		_update_guts(dt)


func fundus_out_distance(kind: String = "uterus") -> float:
	var so := _soft_node(kind)
	if so and so.has_method("fundus_out_distance"):
		return float(so.call("fundus_out_distance"))
	return 0.0


func ovary_contained(side: int) -> bool:
	var so := _soft_node("uterus")
	if so and so.has_method("ovary_contained"):
		return bool(so.call("ovary_contained", side))
	return true


func physical_fraction(kind: String = "uterus") -> float:
	var so := _soft_node(kind)
	if so and so.has_method("physical_fraction"):
		return float(so.call("physical_fraction"))
	return 0.0


func soft_size_ratio(kind: String = "uterus") -> float:
	var so := _soft_node(kind)
	if so and so.has_method("physical_size_ratio"):
		return float(so.call("physical_size_ratio"))
	return 1.0


func max_edge_ratio(kind: String = "uterus") -> float:
	var so := _soft_node(kind)
	return float(so.call("max_edge_ratio")) if so and so.has_method("max_edge_ratio") else 1.0


func rest_fundus_world(kind: String = "uterus") -> Vector3:
	var so := _soft_node(kind)
	return so.call("rest_fundus_world") if so and so.has_method("rest_fundus_world") else Vector3.ZERO


func rest_cervix_world(kind: String = "uterus") -> Vector3:
	var so := _soft_node(kind)
	return so.call("rest_cervix_world") if so and so.has_method("rest_cervix_world") else Vector3.ZERO


func organ_centroid_world(kind: String = "uterus") -> Vector3:
	var so := _soft_node(kind)
	return so.call("centroid_world") if so and so.has_method("centroid_world") else Vector3.ZERO


func soft_mesh_quality(kind: String = "uterus") -> Dictionary:
	var so := _soft_node(kind)
	if so and so.has_method("debug_mesh_quality"):
		return so.call("debug_mesh_quality")
	return {}


func _begin_forceps(origin: Vector3, dir: Vector3, kinds: PackedStringArray = PackedStringArray()) -> bool:
	_fc_active = false
	_fc_pull = -1
	_fc_kind = "gut"
	_fc_soft_kind = ""
	_fc_tube_side = -1
	# 1a. 已扯出的肠袢 / 大肠：直接夹住重新拖动。
	# 若射线同时点到仍可见的体内小肠 / 大肠，优先开新的扯出点，避免体外肠袢挡住选中。
	var best_d := _gut_pick_dist()
	var bi := -1
	var bp := -1
	var rope_depth := 1e9
	var rope_perp := 1e9
	var rope_rad := 0.008
	for i in _gut_pulls.size():
		var rope: Node = (_gut_pulls[i] as Dictionary)["rope"]
		if rope == null or not is_instance_valid(rope):
			continue
		if bool(rope.get("retracting")):
			continue
		var pk: Array = rope.call("ray_pick", origin, dir)
		if int(pk[0]) >= 0 and float(pk[1]) < best_d:
			best_d = float(pk[1])
			bi = i
			bp = int(pk[0])
			rope_perp = float(pk[1])
			var pts0: PackedVector3Array = rope.call("points")
			if bp >= 0 and bp < pts0.size():
				rope_depth = origin.distance_to(pts0[bp])
			rope_rad = float(rope.get("radius")) if "radius" in rope else rope_rad
	var viscera_pick := {}
	if _organs and _organs.has_method("ray_pick_viscera"):
		viscera_pick = _organs.call("ray_pick_viscera", origin, dir)
	var vkind := str(viscera_pick.get("kind", "")) if not viscera_pick.is_empty() else ""
	var visible_inbody := vkind == "small_intestine" or vkind == "colon"
	if visible_inbody and viscera_pick.has("point"):
		var vt: float = origin.distance_to(viscera_pick["point"])
		var rope_blocks := bi >= 0 and rope_perp < (rope_rad + 0.0035) and rope_depth + 0.010 < vt
		if not rope_blocks:
			bi = -1
			bp = -1
	# 1b. 已脱出的柔体器官 / 悬链输卵管
	# 宫体笼子半径常大于肠绳点半径，允许稍宽的夹取容差。
	var soft_best := maxf(best_d, 0.022)
	var soft_kind := ""
	var soft_idx := -1
	var tube_side := -1
	for k in _soft_organs.keys():
		var so: Node = _soft_organs[k]
		if so == null or not is_instance_valid(so) or not bool(so.call("is_extracted")):
			continue
		if bool(so.get("retracting")):
			continue
		var pk2: Array = so.call("ray_pick", origin, dir)
		if int(pk2[0]) >= 0 and float(pk2[1]) < soft_best:
			soft_best = float(pk2[1])
			soft_kind = str(k)
			soft_idx = int(pk2[0])
			tube_side = -1
		var ts: int = int(so.call("ray_pick_adnexa", origin, dir))
		if ts >= 0:
			# 输卵管 / 卵巢命中：优先于更远的宫体命中
			soft_kind = str(k)
			soft_idx = -1
			tube_side = ts
			soft_best = minf(soft_best, best_d)
	if tube_side >= 0 and soft_kind != "":
		var so2: Node = _soft_organs[soft_kind]
		# 未到 4 档时提前夹住 → 该侧立即进入悬链
		so2.call("detach_adnexa", tube_side)
		if bool(so2.call("chain_hold", tube_side, origin, dir)):
			_fc_kind = "tube"
			_fc_soft_kind = soft_kind
			_fc_tube_side = tube_side
			var rope_t: Node = null
			for r in so2.call("chain_ropes"):
				if int(r.get("hold_index")) >= 0:
					rope_t = r
					break
			_fc_last = rope_t.get("hold_pos") if rope_t else _fc_last
			_start_forceps_grip(-1, dir)
			return true
	if soft_kind != "" and soft_idx >= 0 and (bi < 0 or soft_best <= best_d):
		var so3: Node = _soft_organs[soft_kind]
		var cage: PackedVector3Array = so3.get("_p")
		var hp: Vector3 = cage[soft_idx] if soft_idx < cage.size() else so3.call("fundus_world")
		so3.call("hold_particle", soft_idx, hp)
		_fc_last = hp
		_fc_kind = "soft"
		_fc_soft_kind = soft_kind
		_start_forceps_grip(-1, dir)
		return true
	# 1c. t68u：已脱垂在阴道口外的子宫 → 夹住拖动 / 甩动（可往回推复位，也可再往外拉加重）。
	if (kinds.is_empty() or kinds.has("uterus")) and _try_begin_prolapse_drag(origin, dir, rope_depth if bi >= 0 else 1e9):
		return true
	if bi >= 0:
		var r2: Node = (_gut_pulls[bi] as Dictionary)["rope"]
		var pts: PackedVector3Array = r2.call("points")
		r2.set("hold_index", bp)
		r2.set("hold_pos", pts[bp])
		_fc_last = pts[bp]
		_fc_kind = "gut"
		_start_forceps_grip(bi, dir)
		return true
	# 2. 从创口点选对应器官，扯出新的一段 / 开始五档脱出（「放回」模式下不新扯）
	if forceps_mode == "putback":
		return false
	# 0.4.12：子宫脱垂中从创口夹子宫 → 先按拉出量把脱垂复位，复位完再进入正常的创口扯出。
	if (kinds.is_empty() or kinds.has("uterus")) and _try_begin_prolapse_reduce(origin, dir):
		return true
	var hv: Variant = _ray_cavity_hit(origin, dir)
	var pick := viscera_pick if kinds.is_empty() else {}
	if _organs and _organs.has_method("ray_pick_viscera") and (pick.is_empty() or not kinds.is_empty()):
		pick = _organs.call("ray_pick_viscera", origin, dir, kinds)
	var kind := str(pick.get("kind", "")) if not pick.is_empty() else ""
	# 点到可见体内肠管即可开新扯出；创口射线只作后备。
	if hv == null and kind not in ["small_intestine", "colon", "uterus", "uterus_cavity", "tube", "ovary", "bladder"]:
		return false
	var hit: Vector3 = pick["point"] if (not pick.is_empty() and pick.has("point")) else (hv if hv != null else Vector3.INF)
	if hit == Vector3.INF:
		return false
	if kind in ["uterus", "uterus_cavity", "tube", "ovary"]:
		var side := int(pick.get("side", -1))
		if not _start_soft_extract("uterus", origin, dir, side if kind in ["tube", "ovary"] else -1):
			return false
		_set_selected_organ("tube" if kind == "tube" else ("ovary" if kind == "ovary" else "uterus"))
		return true
	if kind == "bladder":
		if _start_soft_extract("bladder", origin, dir, -1):
			_set_selected_organ("bladder")
			return true
		return false
	if kind == "colon":
		if _start_colon_pull(hit, dir):
			_set_selected_organ("colon")
			return true
		return false
	# 只有真正点到小肠网格才扯小肠，空创口 / 点到其它器官不再回退成小肠。
	if kind == "small_intestine":
		if _small_gut_count() >= GUT_MAX_PULLS:
			return false
		var g := _new_gut_pull(hit)
		if g.is_empty():
			return false
		_gut_pulls.append(g)
		gut_rope = g["rope"]
		var rope3: Node = g["rope"]
		_update_guts(0.0)
		rope3.call("step", 1.0 / 60.0)
		var n := int(rope3.call("point_count"))
		var orr := rope3.call("outside_range") as Vector2i
		rope3.set("hold_index", clampi(n / 2, orr.x, maxi(orr.x, orr.y)))
		rope3.set("hold_pos", (rope3.call("points") as PackedVector3Array)[int(rope3.get("hold_index"))])
		_fc_last = rope3.get("hold_pos")
		_fc_kind = "gut"
		_start_forceps_grip(_gut_pulls.size() - 1, dir)
		_set_selected_organ("small_intestine")
		return true
	return false


## T-11：夹住体内器官后往外拉——拖动距离先把夹点沿直线带到创口，过了创口再按手势侧向
## 往腹腔外走（而不是在体内那一层深度横拖、穿过腹壁）。夹点本来就在体外时只保证不被拖回壁内。
const FORCEPS_OUT_MIN := 0.004
var _fc_start_rel := Vector3.ZERO
var _fc_ray_ref := Vector3.ZERO
var _fc_start_inside := false


func _forceps_outward_tip(origin: Vector3, dir: Vector3, plane_tip: Vector3) -> Vector3:
	var wc := _wound_center_world()
	var ow := _cavity_outward().normalized()
	if not _fc_start_inside:
		var dd := (plane_tip - wc).dot(ow)
		if dd < FORCEPS_OUT_MIN:
			plane_tip += ow * (FORCEPS_OUT_MIN - dd)
		return plane_tip
	var start := wc + _fc_start_rel
	var ref := _grab_plane_hit(origin, dir, _fc_ray_ref)
	var disp := ref - _fc_ray_ref
	if _fc_kind == "soft" and _fc_soft_kind == "uterus":
		# t91u：子宫不再先被拖到创口中心（肚脐一侧）再出来，而是从原位直接朝离它最近的创口处（下缘）拉出。
		return forceps_pull_path(start, uterus_exit_center(start, wc, ow), ow, disp)
	return forceps_pull_path(start, wc, ow, disp)


## t91u：子宫出口 = 夹点在创口平面上的投影，限制在创口中心 HANG_MAX 以内（子宫在创口下方时就是创口下缘，
## 与 bd0187e 的悬挂点一致）。
const UTERUS_EXIT_MAX := 0.017


func uterus_exit_center(start: Vector3, wc: Vector3, ow: Vector3) -> Vector3:
	var rel := start - wc
	rel -= ow * rel.dot(ow)
	var lim := minf(HANG_MAX, UTERUS_EXIT_MAX)
	if rel.length() > lim:
		rel = rel.normalized() * lim
	return wc + rel


## 纯函数：起点 start（体内），创口中心 wc，外向 ow，手势位移 disp → 钳尖目标。
func forceps_pull_path(start: Vector3, wc: Vector3, ow: Vector3, disp: Vector3) -> Vector3:
	var s := disp.length()
	var hole := wc + ow * FORCEPS_OUT_MIN
	var lh := start.distance_to(hole)
	if s <= lh or lh < 1e-5:
		return start.lerp(hole, clampf(s / maxf(lh, 1e-5), 0.0, 1.0))
	var e := s - lh
	var lat := disp - ow * disp.dot(ow)
	var side := lat / maxf(s, 1e-6)
	var dirv := (ow + side).normalized()
	return hole + dirv * e


func _start_forceps_grip(pi: int, dir: Vector3) -> void:
	var wc0 := _wound_center_world()
	_fc_start_rel = _fc_last - wc0
	_fc_ray_ref = _fc_last
	_fc_start_inside = (_fc_last - wc0).dot(_cavity_outward().normalized()) < 0.0
	_fc_active = true
	_fc_pull = pi
	stroke_active = true
	_fc_anim = 0.0     # 先张开，再夹紧（夹住动画）
	_fc_target = 1.0
	forceps_clamps += 1
	_place_forceps(_fc_last, dir)


func _hole_or_lip_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	if flap_peeled and not _hole_loops.is_empty():
		ids = _hole_loops[_hole_loops.size() - 1]
	else:
		ids.append_array(_lip_left)
		ids.append_array(_lip_right)
	if ids.is_empty() and not _hole_loops.is_empty():
		for loop2 in _hole_loops:
			if loop2 is PackedInt32Array:
				ids.append_array(loop2 as PackedInt32Array)
	return ids


func _new_gut_pull(hit: Vector3) -> Dictionary:
	var fr: Transform3D = _ab_frame()
	# 参考顶点：最近的创缘内壁顶点（twin 同索引），锚点 = 它 + 腹局部偏移，跟着蒙皮 / 软体 / 拿取位移走。
	var ids := _hole_or_lip_ids()
	var best := -1
	var bd := 1e9
	for id in ids:
		if id < 0 or id >= _outer.vert_count():
			continue
		var d := _inner_world(id).distance_squared_to(hit)
		if d < bd:
			bd = d
			best = id
	if best < 0:
		return {}
	var iw := _inner_world(best)
	# 腹腔内方向（向背）：皮肤外法线取反
	var nw := (_skel_xf() * Geom.skin_vertex(_outer.pos[best] + _outer.nrm[best].normalized() * 0.01, best, _outer, _skel, _skin)) - _outer_live(best)
	var in_w := -nw.normalized()
	# 锚点至少在内壁以下 1.5cm
	var anc := hit
	var depth := (anc - iw).dot(in_w)
	if depth < 0.015:
		anc += in_w * (0.015 - depth)
	var inv_b := fr.basis.inverse()
	# 两端锚点沿创缘切向分开
	var tg := Vector3.ZERO
	var k := ids.find(best)
	if k >= 0:
		var k2 := clampi(k + 2, 0, ids.size() - 1)
		var k1 := clampi(k - 2, 0, ids.size() - 1)
		tg = _outer_live(ids[k2]) - _outer_live(ids[k1])
	tg -= in_w * tg.dot(in_w)
	if tg.length_squared() < 1e-8:
		tg = in_w.cross(Vector3.UP)
	var rope := GutRope.new()
	rope.name = "PulledGut%d" % _gut_pulls.size()
	rope.add_to_group(CAMERA_IGNORE_GROUP)
	add_child(rope)
	var gm := _gut_organ_material()
	if gm:
		rope.call("use_organ_material", gm)
	rope.set("max_len", GUT_PULL_MAX)
	rope.set("fed_len", 0.05)
	return {"rope": rope, "vid": best, "kind": "small", "hit": hit, "bind": _outer.pos[best], "off_ab": inv_b * (anc - iw), "spread_ab": (inv_b * tg).normalized(), "in_ab": (inv_b * in_w).normalized()}


func _drag_forceps(origin: Vector3, dir: Vector3) -> void:
	if not _fc_active:
		return
	var tip := _grab_plane_hit(origin, dir, _fc_last)
	if _fc_kind == "prolapse":
		_prolapse_forceps_to(tip, origin, dir)
		return
	if _fc_kind == "prolapse_out":
		_fc_last = tip
		var pco := _prolapse_ctl()
		if pco:
			pco.call("drive_to", tip)
		return
	if forceps_mode != "putback":
		tip = _forceps_outward_tip(origin, dir, tip)
	_fc_last = tip
	if _fc_kind == "soft":
		var so := _soft_node(_fc_soft_kind)
		if so:
			so.call("hold_particle", int(so.get("hold_index")), tip)
		return
	if _fc_kind == "tube":
		var so2 := _soft_node(_fc_soft_kind)
		if so2:
			so2.call("chain_drag", _fc_tube_side, tip)
		return
	if _fc_pull < 0 or _fc_pull >= _gut_pulls.size():
		return
	var rope: Node = (_gut_pulls[_fc_pull] as Dictionary)["rope"]
	if rope == null or not is_instance_valid(rope):
		return
	_forceps_hold(rope, tip)


## 把钳尖移到 tip：被扯得更远就从创口里再拉出几节（fed_len 增加），超过上限则钳尖被肠管拽住。
func _forceps_hold(rope: Node, tip: Vector3, no_feed: bool = false, reach_min: float = 0.0) -> void:
	var n := int(rope.call("point_count"))
	var hi := int(rope.get("hold_index"))
	if n < 3 or hi <= 0 or hi >= n - 1:
		return
	var ea: Vector3 = rope.get("exit_a")
	var eb: Vector3 = rope.get("exit_b")
	var aa: Vector3 = rope.get("anchor_a")
	var ab: Vector3 = rope.get("anchor_b")
	var fa := float(hi) / float(n - 1)
	var fb := 1.0 - fa
	var need := maxf((aa.distance_to(ea) * 1.0 + ea.distance_to(tip)) / maxf(fa, 0.05), (ab.distance_to(eb) + eb.distance_to(tip)) / maxf(fb, 0.05)) * 1.03
	var cap := float(rope.get("max_len"))
	if cap <= 1e-6:
		cap = GUT_PULL_MAX
	var fed := float(rope.get("fed_len"))
	if no_feed:
		# T-11 拿取工具：只拖动已扯出的这段，不再从创口里多拉（上限 = 当前扯出长度）。
		cap = fed
	elif need > fed:
		fed = minf(need, cap)
		rope.set("fed_len", fed)
	if need > cap:
		var em := (ea + eb) * 0.5
		var reach := maxf(minf(cap * fa - aa.distance_to(ea), cap * fb - ab.distance_to(eb)) / 1.03, maxf(0.01, reach_min))
		if tip.distance_to(em) > reach:
			tip = em + (tip - em).normalized() * reach
	rope.set("hold_pos", tip)


func _end_forceps() -> void:
	if _fc_kind == "prolapse_out":
		var pco := _prolapse_ctl()
		if pco and str(pco.get("drive_source")) == "forceps":
			pco.call("end_drive")
	if _fc_kind == "prolapse":
		var pc := _prolapse_ctl()
		if pc:
			pc.call("end_surgery_reduce")
		_prol_pending = 0.0
	if _fc_kind == "soft":
		var so := _soft_node(_fc_soft_kind)
		if so:
			so.call("release_hold")
			if forceps_mode == "putback":
				so.call("start_putback")
				organ_putbacks += 1
	elif _fc_kind == "tube":
		var so2 := _soft_node(_fc_soft_kind)
		if so2:
			so2.call("chain_release", _fc_tube_side)
			if forceps_mode == "putback":
				so2.call("start_putback")
				organ_putbacks += 1
	elif _fc_pull >= 0 and _fc_pull < _gut_pulls.size():
		var rope: Node = (_gut_pulls[_fc_pull] as Dictionary)["rope"]
		if rope and is_instance_valid(rope):
			var hp2: Vector3 = rope.get("hold_pos")
			rope.set("hold_index", -1)
			if forceps_mode == "putback" and hp2.distance_to(gut_wound_anchor(rope)) <= PUTBACK_RADIUS:
				rope.call("start_retract", PUTBACK_TIME)
				gut_putbacks += 1
	_fc_active = false
	_fc_pull = -1
	_fc_kind = "gut"
	_fc_soft_kind = ""
	_fc_tube_side = -1
	stroke_active = false
	_fc_target = 0.0   # 松开：钳口张开后收起
	_fc_hide_t = 0.3


## 测试：按世界坐标模拟手术钳点击 / 拖动 / 松开。
func debug_forceps_begin(origin: Vector3, dir: Vector3) -> bool:
	set_touch_pick(false)
	return _begin_forceps(origin, dir)


func debug_forceps_begin_kind(origin: Vector3, dir: Vector3, kinds: PackedStringArray) -> bool:
	set_touch_pick(false)
	return _begin_forceps(origin, dir, kinds)


func debug_forceps_drag_to(tip: Vector3) -> void:
	if not _fc_active:
		return
	if _fc_kind == "prolapse":
		var cam := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
		var o := cam.global_position if cam else tip + _cavity_outward() * 0.3
		_prolapse_forceps_to(tip, o, (tip - o).normalized())
		return
	if _fc_kind == "prolapse_out":
		_fc_last = tip
		var pco := _prolapse_ctl()
		if pco:
			pco.call("drive_to", tip)
		return
	_fc_last = tip
	if _fc_kind == "soft":
		var so := _soft_node(_fc_soft_kind)
		if so:
			so.call("hold_particle", int(so.get("hold_index")), tip)
		return
	if _fc_kind == "tube":
		var so2 := _soft_node(_fc_soft_kind)
		if so2:
			so2.call("chain_drag", _fc_tube_side, tip)
		return
	if _fc_pull >= 0 and _fc_pull < _gut_pulls.size():
		_forceps_hold((_gut_pulls[_fc_pull] as Dictionary)["rope"], tip)


func debug_forceps_end() -> void:
	_end_forceps()



## ---- 0.4.11 大肠 / 子宫 / 膀胱脱出 ---------------------------------------

func _small_gut_count() -> int:
	var n := 0
	for gp in _gut_pulls:
		if str((gp as Dictionary).get("kind", "small")) != "colon":
			n += 1
	return n


func colon_pull_count() -> int:
	var n := 0
	for gp in _gut_pulls:
		if str((gp as Dictionary).get("kind", "")) == "colon":
			n += 1
	return n


func colon_ropes() -> Array:
	var out: Array = []
	for gp in _gut_pulls:
		if str((gp as Dictionary).get("kind", "")) == "colon":
			out.append((gp as Dictionary)["rope"])
	return out


func _colon_organ_material() -> ShaderMaterial:
	if _organs == null:
		return null
	var mats = _organs.get("_organ_mats")
	if not (mats is Array):
		return null
	var src: ShaderMaterial = null
	for m in mats:
		var sm := m as ShaderMaterial
		if sm == null or not bool(sm.get_shader_parameter("is_gut")):
			continue
		var tex = sm.get_shader_parameter("albedo_tex")
		if tex is Texture2D and str((tex as Texture2D).resource_path).find("colon") >= 0:
			src = sm
			break
	if src == null:
		# 回退：复制小肠材质再换贴图
		for m2 in mats:
			var sm2 := m2 as ShaderMaterial
			if sm2 and bool(sm2.get_shader_parameter("is_gut")):
				src = sm2
				break
	if src == null:
		return null
	var dup := src.duplicate() as ShaderMaterial
	dup.set_shader_parameter("strike_k", 0.3)
	if ResourceLoader.exists(COLON_TILE_ALBEDO):
		dup.set_shader_parameter("albedo_tex", load(COLON_TILE_ALBEDO))
	if ResourceLoader.exists(COLON_TILE_NORMAL):
		dup.set_shader_parameter("normal_tex", load(COLON_TILE_NORMAL))
	dup.set_meta("exposed_gut", true)
	dup.set_meta("colon_rope", true)
	(mats as Array).append(dup)
	if _organs.has_method("register_deform_material"):
		_organs.call("register_deform_material", dup, false)
	return dup


func _start_colon_pull(hit: Vector3, dir: Vector3) -> bool:
	# 只能有一个大肠扯出点：已有则夹住已有的，不新建。
	if colon_pull_count() > 0:
		for i in _gut_pulls.size():
			if str((_gut_pulls[i] as Dictionary).get("kind", "")) != "colon":
				continue
			var rope0: Node = (_gut_pulls[i] as Dictionary)["rope"]
			if rope0 == null or not is_instance_valid(rope0) or bool(rope0.get("retracting")):
				continue
			var pts0: PackedVector3Array = rope0.call("points")
			var hi := int(pts0.size() / 2)
			if pts0.size() > 0:
				rope0.set("hold_index", hi)
				rope0.set("hold_pos", pts0[hi])
				_fc_last = pts0[hi]
			_fc_kind = "gut"
			_start_forceps_grip(i, dir)
			return true
		return false
	var g := _new_gut_pull(hit)
	if g.is_empty():
		return false
	var rope: Node = g["rope"]
	rope.name = "PulledColon"
	rope.call("apply_profile", {
		"profile": "colon",
		"radius": COLON_RADIUS,
		"seg": COLON_SEG,
		"damp": COLON_DAMP,
		"min_pts": COLON_MIN_PTS,
		"max_pts": COLON_MAX_PTS,
		"mes_every": COLON_MES_EVERY,
	})
	rope.set("max_len", COLON_PULL_MAX)
	rope.set("fed_len", 0.06)
	var cm := _colon_organ_material()
	if cm:
		rope.call("use_organ_material", cm)
	g["kind"] = "colon"
	_gut_pulls.append(g)
	gut_rope = rope
	_update_guts(0.0)
	rope.call("step", 1.0 / 60.0)
	var n := int(rope.call("point_count"))
	var orr := rope.call("outside_range") as Vector2i
	rope.set("hold_index", clampi(n / 2, orr.x, maxi(orr.x, orr.y)))
	rope.set("hold_pos", (rope.call("points") as PackedVector3Array)[int(rope.get("hold_index"))])
	_fc_last = rope.get("hold_pos")
	_fc_kind = "gut"
	_start_forceps_grip(_gut_pulls.size() - 1, dir)
	return true


func _soft_node(kind: String) -> Node:
	if not _soft_organs.has(kind):
		return null
	var n: Node = _soft_organs[kind]
	if n == null or not is_instance_valid(n):
		return null
	return n


func _wound_center_world() -> Vector3:
	var rim := _gut_rim_world()
	if rim.is_empty():
		return _navel_rest
	var c := Vector3.ZERO
	for q in rim:
		c += q
	return c / float(rim.size())


## t82u：柔体子宫每帧用的创口中心 / 悬挂点缓存（腹部局部坐标）。创缘蒙皮采样一次约 0.2 ms，
## 创口形状没变时每 WC_REFRESH 帧才重算一次，其余帧只随腹部坐标系搬运；拉扯 / 拉钩回弹期间每帧重算。
const WC_REFRESH := 12
var _wc_fr := Transform3D()
## 悬挂点：创口中心沿身体向下（耻骨方向）移到创缘下缘附近，最多 HANG_MAX（留在洞口 HOLE_R 内）。
const HANG_FRAC := 0.8
const HANG_MAX := 0.017
var _wc_ab: Vector3 = Vector3.ZERO
var _hang_ab: Vector3 = Vector3.ZERO
var _wc_sig: Array = []
var _wc_age: int = 999


func _wound_and_hang(fr: Transform3D) -> Array:
	var sig := [_outer.get_instance_id() if _outer else 0, _outer.vert_count() if _outer else 0, _outer.idx.size() if _outer else 0, flap_peeled, _hole_loops.size(), _lip_left.size(), _lip_right.size(), _retractors.size()]
	var busy := _grab_active or not _retr_release.is_empty() or stroke_active
	# t99u：人物走动 / 动画时皮肤创缘相对腹部坐标系在动；只每 12 帧重算会让悬挂点一跳一跳（子宫闪烁）。
	# 腹部坐标系本帧有位移 / 转动就每帧重算。
	var moving := fr.origin.distance_squared_to(_wc_fr.origin) > 1e-10 or not fr.basis.is_equal_approx(_wc_fr.basis)
	_wc_fr = fr
	if sig != _wc_sig or busy or moving or _wc_age >= WC_REFRESH:
		_wc_sig = sig
		_wc_age = 0
		var rim := _gut_rim_world()
		var wc := _navel_rest
		if not rim.is_empty():
			wc = Vector3.ZERO
			for q in rim:
				wc += q
			wc /= float(rim.size())
		var hang := wc
		var outv := _cavity_outward()
		var y := fr.basis.y.normalized()
		var yt := y - outv * y.dot(outv)
		if yt.length_squared() > 1e-8 and not rim.is_empty():
			yt = yt.normalized()
			var low := 0.0
			for q2 in rim:
				low = minf(low, (q2 - wc).dot(yt))
			hang = wc - yt * minf(-low * HANG_FRAC, HANG_MAX)
		var inv := fr.affine_inverse()
		_wc_ab = inv * wc
		_hang_ab = inv * hang
	else:
		_wc_age += 1
	return [fr * _wc_ab, fr * _hang_ab]


## 子宫悬挂点（世界坐标；测试 / 调试用）。
func uterus_hang_world() -> Vector3:
	var fr: Transform3D = _ab_frame() if _organs else Transform3D.IDENTITY
	_wc_age = 999
	return _wound_and_hang(fr)[1]


func _cavity_outward() -> Vector3:
	if _organs:
		var fr: Transform3D = _ab_frame()
		# 腹前方向（创口朝外）
		var fwd: Vector3 = fr.basis.z.normalized()
		if fwd.length_squared() > 1e-8:
			return fwd
	return Vector3(0, 0, 1)


func _clear_soft_organs() -> void:
	for k in _soft_organs.keys():
		var so: Node = _soft_organs[k]
		if so and is_instance_valid(so):
			so.call("force_reset")
			so.queue_free()
	_soft_organs.clear()
	if _organs and _organs.has_method("clear_canal_stretch"):
		_organs.call("clear_canal_stretch")
	if _organs and _organs.has_method("clear_uterus_phys_cut"):
		_organs.call("clear_uterus_phys_cut")
	if _organs and _organs.has_method("set_kind_visible"):
		for k2 in ["uterus", "uterus_cavity", "bladder", "tube", "ovary"]:
			_organs.call("set_kind_visible", k2, true)
	if _organs:
		_organs.set_meta("uterus_extracted", false)
	# 脱垂还在：原子宫继续隐藏（显示的是脱垂柔体）。
	var pcv := _prolapse_ctl()
	if pcv:
		pcv.call("rehide_sources")
	extraction_hint = ""


## 一键收回所有已扯出的体外内脏（肠、子宫、膀胱、输卵管/卵巢），不关闭创口、不整身复原。
func si_hide_rate() -> float:
	return SI_HIDE_RATE


func restore_extracted_organs() -> bool:
	var any := not _gut_pulls.is_empty() or not _soft_organs.is_empty()
	# 0.4.12：「放回内脏」同时复原子宫脱垂。
	var pc0 := _prolapse_ctl()
	if pc0:
		any = true
		pc0.call("reset")
	if _fc_active:
		debug_forceps_end()
	_clear_forceps_preview()
	# 只清已扯出的绳，保留创口状态。
	for gp in _gut_pulls:
		var rope: Node = (gp as Dictionary).get("rope")
		if rope and is_instance_valid(rope):
			var gm := (rope as GeometryInstance3D).material_override as ShaderMaterial
			if gm and _organs:
				for key in ["_organ_mats", "_all_mats"]:
					var arr = _organs.get(key)
					if arr is Array:
						(arr as Array).erase(gm)
			rope.queue_free()
	_gut_pulls.clear()
	gut_rope = null
	_clear_soft_organs()
	if _organs and _organs.has_method("clear_gut_eaten"):
		_organs.call("clear_gut_eaten")
	_gut_hide_acc = {"colon": [], "small_intestine": []}
	_gut_hide_sig = []
	if _organs and _organs.has_method("clear_canal_stretch"):
		_organs.call("clear_canal_stretch")
	_set_selected_organ("")
	_set_hovered_organ("")
	if _forceps_node and is_instance_valid(_forceps_node):
		_forceps_node.visible = false
	return any


func _ensure_soft(kind: String) -> Node:
	var existing := _soft_node(kind)
	if existing:
		return existing
	if _organs == null:
		return null
	var so: Node = SoftOrgan.new()
	so.name = "Soft" + kind.capitalize()
	so.add_to_group(CAMERA_IGNORE_GROUP)
	add_child(so)
	var fr: Transform3D = _ab_frame()
	var navel: Vector3 = _organs.get("_navel_rest")
	var main_meshes: Array = []
	var hide_meshes: Array = []
	var adnex: Array = []
	if kind == "uterus":
		main_meshes = _organs.call("viscera_meshes", "uterus")
		hide_meshes = main_meshes.duplicate()
		for m in _organs.call("viscera_meshes", "uterus_cavity"):
			hide_meshes.append(m)
		for k3 in ["tube", "ovary"]:
			for m2 in _organs.call("viscera_meshes", k3):
				adnex.append(m2)
	else:
		main_meshes = _organs.call("viscera_meshes", "bladder")
		hide_meshes = main_meshes.duplicate()
	var cervix_rest := navel
	var fundus_rest := navel
	var horns: Array = [navel, navel]
	if kind == "uterus":
		var canal: Dictionary = _organs.call("vagina_canal")
		if not canal.is_empty():
			cervix_rest = (canal["cervix_ab"] as Vector3) + navel
		var meta: Dictionary = _organs.get("meta")
		if meta.has("uterus"):
			var mn: Array = meta["uterus"]["min"]
			var mx: Array = meta["uterus"]["max"]
			var a := Vector3(float(mn[0]), float(mn[1]), float(mn[2]))
			var b := Vector3(float(mx[0]), float(mx[1]), float(mx[2]))
			# 宫底：沿宫颈→上/前方向最远的角
			fundus_rest = Vector3((a.x + b.x) * 0.5, b.y, b.z)
		if meta.has("tubes") and meta["tubes"] is Array:
			var tb: Array = meta["tubes"]
			for i in mini(2, tb.size()):
				var h: Array = (tb[i] as Dictionary).get("horn", [])
				if h.size() >= 3:
					horns[i] = Vector3(float(h[0]), float(h[1]), float(h[2]))
	else:
		# 膀胱：锚在较低 / 靠后的一端，底在对侧
		var box_mn := Vector3(INF, INF, INF)
		var box_mx := Vector3(-INF, -INF, -INF)
		for mi in main_meshes:
			if mi == null or (mi as MeshInstance3D).mesh == null:
				continue
			var P: PackedVector3Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for p3 in P:
				box_mn = box_mn.min(p3)
				box_mx = box_mx.max(p3)
		if box_mn.x < INF:
			cervix_rest = Vector3((box_mn.x + box_mx.x) * 0.5, box_mn.y, box_mn.z)
			fundus_rest = Vector3((box_mn.x + box_mx.x) * 0.5, box_mx.y, box_mx.z)
	so.call("setup", kind, fr, navel, main_meshes, adnex, cervix_rest, fundus_rest, horns)
	# t72u：子宫取出后的过渡段用阴道的肉粉底色。
	if kind == "uterus" and so.has_method("set_transition_color"):
		var vgm: Array = _organs.call("viscera_meshes", "vagina") if _organs and _organs.has_method("viscera_meshes") else []
		for vmi in vgm:
			var vm_mat = (vmi as MeshInstance3D).material_override if vmi is MeshInstance3D else null
			if vm_mat is ShaderMaterial and (vm_mat as ShaderMaterial).get_shader_parameter("base_color") is Color:
				so.call("set_transition_color", (vm_mat as ShaderMaterial).get_shader_parameter("base_color"))
				break
	# 子宫还要把内膜腔体一起隐藏。
	if kind == "uterus":
		var extra: Array = []
		for cm in _organs.call("viscera_meshes", "uterus_cavity"):
			extra.append(cm)
		if not extra.is_empty() and so.has_method("add_hide_meshes"):
			so.call("add_hide_meshes", extra)
	_soft_organs[kind] = so
	return so


func _start_soft_extract(kind: String, origin: Vector3, dir: Vector3, early_side: int) -> bool:
	extraction_hint = ""
	if kind == "uterus" and speculum and speculum.has_method("is_present") and bool(speculum.call("is_present")):
		extraction_hint = UTERUS_SPECULUM_HINT
		surgery_hint.emit(extraction_hint)
		return false
	if kind == "uterus" and _prolapse_ctl() != null:
		# 仍在脱垂：不能直接扯（先复位）。
		return false
	var so := _ensure_soft(kind)
	if so == null:
		return false
	var fr: Transform3D = _ab_frame() if _organs else Transform3D.IDENTITY
	if kind == "uterus":
		_wc_age = 999
		var wh0 := _wound_and_hang(fr)
		so.set("hang_offset", (wh0[1] as Vector3) - (wh0[0] as Vector3))
	so.call("begin_extract", fr, _wound_center_world(), _cavity_outward())
	if kind == "uterus" and _organs:
		_organs.set_meta("uterus_extracted", true)
	if _organs and _organs.has_method("set_kind_visible"):
		if kind == "uterus":
			_organs.call("set_kind_visible", "uterus", false)
			_organs.call("set_kind_visible", "uterus_cavity", false)
			_organs.call("set_kind_visible", "tube", false)
			_organs.call("set_kind_visible", "ovary", false)
			if _organs.has_method("clear_uterus_phys_cut"):
				_organs.call("clear_uterus_phys_cut")
		else:
			_organs.call("set_kind_visible", kind, false)
	if early_side >= 0 and kind == "uterus":
		so.call("detach_adnexa", early_side)
		if bool(so.call("chain_hold", early_side, origin, dir)):
			_fc_kind = "tube"
			_fc_soft_kind = kind
			_fc_tube_side = early_side
			_fc_last = _fc_last
			_start_forceps_grip(-1, dir)
			return true
	# 夹住露出的柔体
	var pk: Array = so.call("ray_pick", origin, dir)
	var idx := int(pk[0])
	var cage: PackedVector3Array = so.get("_p")
	if idx < 0 and not cage.is_empty():
		idx = cage.size() - 1
	var hp: Vector3 = cage[idx] if idx >= 0 and idx < cage.size() else so.call("fundus_world")
	so.call("hold_particle", idx, hp)
	_fc_last = hp
	_fc_kind = "soft"
	_fc_soft_kind = kind
	_start_forceps_grip(-1, dir)
	return true


func _apply_uterus_phys_cut(so: Node) -> void:
	if so == null or _organs == null or not _organs.has_method("set_uterus_phys_cut"):
		return
	if not bool(so.call("is_extracted")):
		_organs.call("clear_uterus_phys_cut")
		return
	var cut := float(so.call("physical_cut"))
	var origin: Vector3 = so.get("_cervix_ab")
	var axis: Vector3 = so.get("_axis_ab")
	var cut_m := cut * maxf(float(so.get("_rest_len")), 0.03)
	_organs.call("set_uterus_phys_cut", cut_m, origin, axis, true, 0.007)


func _tissue_drag_world_at(world_p: Vector3) -> Vector3:
	if _organs == null or not _organs.has_method("soft_offset_ab") or not _organs.has_method("abdomen_frame"):
		return Vector3.ZERO
	var fr: Transform3D = _ab_frame()
	var off_ab: Vector3 = _organs.call("soft_offset_ab", fr.affine_inverse() * world_p)
	return fr.basis * off_ab


func _carry_soft_with_tissue_drag(wound: Vector3) -> Vector3:
	# 与体内肠管着色器同一套腹部软位移：柔体质点 / 输卵管链整颗跟着走，避免 PIN_OUT 过低而留在原地。
	var cur := _tissue_drag_world_at(wound)
	if not _tissue_drag_has:
		_tissue_drag_prev = Vector3.ZERO
		_tissue_drag_has = true
	var d := cur - _tissue_drag_prev
	_tissue_drag_prev = cur
	if d.length_squared() > 1e-14:
		var xf := Transform3D(Basis.IDENTITY, d)
		for sk in _soft_organs.keys():
			var so: Node = _soft_organs[sk]
			if so and is_instance_valid(so) and so.has_method("carry"):
				so.call("carry", xf)
	return cur


func _update_soft_organs(dt: float) -> void:
	_update_prolapse_forceps(dt)
	if _soft_organs.is_empty():
		_tissue_drag_has = false
		_tissue_drag_prev = Vector3.ZERO
		return
	var fr: Transform3D = _ab_frame() if _organs else Transform3D.IDENTITY
	var wh := _wound_and_hang(fr)
	var wound: Vector3 = wh[0]
	var drag := _carry_soft_with_tissue_drag(wound)
	wound += drag
	var hang_off: Vector3 = (wh[1] as Vector3) - (wh[0] as Vector3)
	var out := _cavity_outward()
	var fy := -1e9
	var host := get_parent() as Node3D
	if host:
		fy = host.global_position.y
	if has_method("is_on_exam_bed") and is_on_exam_bed() and has_method("_catch_top_y"):
		fy = maxf(fy, _catch_top_y())
	var caps := _gut_capsules()
	var sk: Array = [_gut_skin_p, _gut_skin_n]
	for k in _soft_organs.keys():
		var so: Node = _soft_organs[k]
		if so == null or not is_instance_valid(so):
			continue
		so.set("floor_y", fy)
		if str(k) == "uterus":
			so.set("hang_offset", hang_off)
		so.set("capsules", caps)
		so.set("skin_p", sk[0])
		so.set("skin_n", sk[1])
		# 夹住时由钳尖直接拖动段链，不再用时间加档。放回模式夹住即开始收回。
		if _fc_active and _fc_kind == "soft" and _fc_soft_kind == str(k) and dt > 0.0 and forceps_mode == "putback":
			if so.has_method("start_putback"):
				so.call("start_putback")
		var was_out := bool(so.call("is_extracted"))
		so.call("step", dt, fr, wound, out)
		var now_out := bool(so.call("is_extracted"))
		if str(k) == "uterus" and now_out:
			# 整颗子宫已是柔体，原网格保持隐藏；阴道始终接到当前宫颈。
			# 0.4.12：阴道顶端只跟系带根部走一小段，伸长部分由系带管子表现（不再把阴道拉成一根怪管跟着子宫走）。
			if _organs and _organs.has_method("set_canal_stretch"):
				var cx: Vector3 = so.call("canal_os_world") if so.has_method("canal_os_world") else so.call("cervix_world")
				_organs.call("set_canal_stretch", _to_organ_world(cx), 1.0)
				var c_os = _organs.get("_canal_os_rest")
				var c_op = _organs.get("_canal_open_rest")
				if c_os is Vector3 and c_op is Vector3:
					so.set("vagina_axis_ab", (c_os - c_op).normalized() if (c_os - c_op).length_squared() > 1e-10 else Vector3.ZERO)
		elif str(k) == "uterus" and _organs:
			if _organs.has_method("clear_canal_stretch") and not now_out:
				_organs.call("clear_canal_stretch")
			if _organs.has_method("clear_uterus_phys_cut") and not now_out:
				_organs.call("clear_uterus_phys_cut")
		if _fc_active and _fc_kind == "soft" and _fc_soft_kind == str(k):
			var hp2: Vector3 = so.get("hold_pos")
			_fc_last = hp2
			var cam := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
			var d2: Vector3 = (hp2 - cam.global_position) if cam else out
			_place_forceps(hp2, d2)
		elif _fc_active and _fc_kind == "tube" and _fc_soft_kind == str(k):
			var rps: Array = so.call("chain_ropes") if so.has_method("chain_ropes") else []
			for r in rps:
				if r and int(r.get("hold_index")) >= 0:
					var hpt: Vector3 = r.get("hold_pos")
					_fc_last = hpt
					var cam2 := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() else null
					var d3: Vector3 = (hpt - cam2.global_position) if cam2 else out
					_place_forceps(hpt, d3)
					break
		if was_out and not now_out and _organs and _organs.has_method("set_kind_visible"):
			if str(k) == "uterus":
				_organs.call("set_kind_visible", "uterus", true)
				_organs.call("set_kind_visible", "uterus_cavity", true)
				_organs.call("set_kind_visible", "tube", true)
				_organs.call("set_kind_visible", "ovary", true)
			else:
				_organs.call("set_kind_visible", str(k), true)


func has_extracted_organs() -> bool:
	if colon_pull_count() > 0:
		return true
	for k in _soft_organs.keys():
		var so: Node = _soft_organs[k]
		if so and is_instance_valid(so) and bool(so.call("is_extracted")):
			return true
	return false


func soft_organ(kind: String) -> Node:
	return _soft_node(kind)


func extract_level(kind: String) -> int:
	var so := _soft_node(kind)
	return int(so.call("level")) if so else 0


func extract_charge(kind: String) -> float:
	var so := _soft_node(kind)
	return float(so.get("extract_charge")) if so else 0.0


func ovary_at_chain_end(side: int) -> bool:
	var so := _soft_node("uterus")
	return bool(so.call("ovary_at_chain_end", side)) if so and so.has_method("ovary_at_chain_end") else false


func chain_is_straight(side: int) -> bool:
	var so := _soft_node("uterus")
	return bool(so.call("chain_is_straight", side)) if so and so.has_method("chain_is_straight") else false


func organ_source_hidden(kind: String) -> bool:

	if _organs == null:
		var so0 := _soft_node(kind)
		return bool(so0.call("original_hidden")) if so0 else false
	var any := false
	for mi in _organs.get("organ_meshes"):
		var m := mi as MeshInstance3D
		if m == null:
			continue
		var k := str(m.get_meta("organ_kind", ""))
		var is_src := k == kind
		if kind == "uterus":
			is_src = k == "uterus" or k == "uterus_cavity" or bool(m.get_meta("is_cavity", false))
		if not is_src:
			continue
		any = true
		if m.visible:
			return false
	if any:
		return true
	var so := _soft_node(kind)
	return bool(so.call("original_hidden")) if so else false


func tube_chain_active(side: int) -> bool:
	var so := _soft_node("uterus")
	return bool(so.call("tube_chain_active", side)) if so else false


func get_extraction_hint() -> String:
	return extraction_hint


func cervix_world() -> Vector3:
	var so := _soft_node("uterus")
	return so.call("cervix_world") if so else Vector3.ZERO


func debug_pick_viscera(origin: Vector3, dir: Vector3) -> String:
	if _organs == null or not _organs.has_method("ray_pick_viscera"):
		return ""
	var hit: Dictionary = _organs.call("ray_pick_viscera", origin, dir)
	return str(hit.get("kind", "")) if not hit.is_empty() else ""


func debug_begin_si_along(along: float, fed: float = 0.2) -> bool:
	if not cut_open:
		return false
	if _small_gut_count() >= GUT_MAX_PULLS:
		return false
	var g := _new_gut_pull(_wound_center_world())
	if g.is_empty():
		return false
	g["along"] = clampf(along, 0.0, 1.0)
	g["kind"] = "small"
	var rope: Node = g["rope"]
	if rope:
		rope.set("fed_len", maxf(fed, 0.04))
	_gut_pulls.append(g)
	gut_rope = g["rope"]
	_sync_gut_hide()
	return true


func debug_gut_hide_mask(kind: String, steps: int = 48) -> PackedFloat32Array:
	_sync_gut_hide()
	if _organs and _organs.has_method("gut_hide_mask"):
		return _organs.call("gut_hide_mask", kind, steps)
	return PackedFloat32Array()


func debug_gut_hide_amount(kind: String, steps: int = 48) -> float:
	_sync_gut_hide()
	if _organs and _organs.has_method("gut_hide_amount"):
		return float(_organs.call("gut_hide_amount", kind, steps))
	return 0.0


func debug_begin_extract(kind: String) -> bool:
	if not cut_open:
		return false
	kind = kind.strip_edges()
	var dir := -_cavity_outward()
	var origin := _wound_center_world() - dir * 0.08
	var ok := false
	var sel := kind
	if kind == "colon":
		ok = _start_colon_pull(_wound_center_world(), dir)
		sel = "colon"
	elif kind == "uterus" and _prolapse_ctl() != null:
		# 脱垂中：瞄准子宫静止时的宫底，先进入「复位」。
		var pc := _prolapse_ctl()
		var aim: Vector3 = pc.call("rest_fundus_world")
		ok = _try_begin_prolapse_reduce(aim - dir * 0.12, dir)
		sel = kind
	elif kind == "uterus" or kind == "bladder":
		ok = _start_soft_extract(kind, origin, dir, -1)
		sel = kind
	elif kind == "tube" or kind == "ovary":
		ok = _start_soft_extract("uterus", origin, dir, 0)
		sel = kind
	elif kind == "small" or kind == "small_intestine":
		if _small_gut_count() >= GUT_MAX_PULLS:
			return false
		var g := _new_gut_pull(_wound_center_world())
		if g.is_empty():
			return false
		_gut_pulls.append(g)
		gut_rope = g["rope"]
		_fc_kind = "gut"
		_start_forceps_grip(_gut_pulls.size() - 1, dir)
		ok = true
		sel = "small_intestine"
	if ok:
		_set_selected_organ(sel)
	return ok


func debug_add_extract_charge(kind: String, strength: float, dt: float) -> void:
	var so := _soft_node(kind)
	if so:
		if so.has_method("release_hold"):
			so.call("release_hold")
		so.call("add_charge", strength, dt)
		# 立即步进一次让位置跟上档位
		if _organs:
			so.call("step", minf(dt, 1.0 / 30.0), _ab_frame(), _wound_center_world(), _cavity_outward())
			if kind == "uterus" and _organs.has_method("set_canal_stretch") and bool(so.call("is_extracted")):
				_organs.call("set_canal_stretch", _to_organ_world(so.call("canal_os_world")), 1.0)


func debug_putback_organ(kind: String) -> bool:
	if kind == "colon":
		for gp in _gut_pulls:
			if str((gp as Dictionary).get("kind", "")) != "colon":
				continue
			var rope: Node = (gp as Dictionary)["rope"]
			if rope and is_instance_valid(rope):
				rope.call("start_retract", PUTBACK_TIME)
				gut_putbacks += 1
				return true
		return false
	var so := _soft_node(kind)
	if so and bool(so.call("is_extracted")):
		so.call("start_putback")
		organ_putbacks += 1
		return true
	return false


func debug_grab_adnexa(side: int) -> bool:
	var so := _soft_node("uterus")
	if so == null or not bool(so.call("is_extracted")):
		# 若子宫尚未脱出，视为从创口夹到了输卵管：先开始脱出再拆悬链
		if not cut_open:
			return false
		if not _start_soft_extract("uterus", _wound_center_world() + Vector3(0, 0.08, 0), Vector3(0, -1, 0), side):
			return false
		so = _soft_node("uterus")
	if so == null:
		return false
	return bool(so.call("detach_adnexa", side))


## ---- 0.4.02 拉钩（Roux 双头拉钩，手术工具包 5 号） ----
const RETRACTOR_SCENE := "res://assets/surgery/retractor.glb"
const RETR_PICK_DIST := 0.014      # 射线离唇缘顶点多近算点中切口边缘（米）
const RETR_OPEN := 0.006           # 放下时把唇缘往外拉开的量
const RETR_CLOSE_MAX := 0.006
## 模型局部：刀身在 y≈-0.0148，长轴 z，+z 端（窄头、浅钩）钩进切口，钩子朝 +y 弯。
const RETR_HOOK_Z := 0.066
const RETR_UNDER_Y := -0.0148
var _retractors: Array = []        # {node, vid, bind, out_bind}
var _retr_ghost: Node3D = null
var _retr_ghost_vid: int = -1
var _retr_ghost_out: Vector3 = Vector3.ZERO
var _retr_placing: bool = false
var _retr_drag: int = -1
var _retr_sig: Array = []


func retractor_count() -> int:
	return _retractors.size()


func retractor_nodes() -> Array:
	var out: Array = []
	for r in _retractors:
		out.append((r as Dictionary)["node"])
	return out


func retractor_ghost_visible() -> bool:
	return _retr_ghost != null and is_instance_valid(_retr_ghost) and _retr_ghost.visible


func _make_retractor_node(ghost: bool) -> Node3D:
	var n: Node3D = null
	if ResourceLoader.exists(RETRACTOR_SCENE):
		var ps: PackedScene = load(RETRACTOR_SCENE)
		if ps:
			n = ps.instantiate() as Node3D
	if n == null:
		n = Node3D.new()
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.03, 0.002, 0.148)
		mi.mesh = bm
		mi.position = Vector3(0, RETR_UNDER_Y, 0)
		n.add_child(mi)
	n.name = "RetractorGhost" if ghost else "Retractor"
	n.top_level = true
	n.add_to_group(CAMERA_IGNORE_GROUP)
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi2 := c as MeshInstance3D
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if ghost:
			var gm := StandardMaterial3D.new()
			gm.albedo_color = Color(0.55, 0.85, 1.0, 0.38)
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gm.cull_mode = BaseMaterial3D.CULL_DISABLED
			gm.no_depth_test = true
			mi2.material_override = gm
	add_child(n)
	return n


## 切口边缘候选：网格开放边界上、不在原腹带外缘的顶点（直切口两唇、环切 / 剥离洞缘）。
func _lip_candidates() -> PackedInt32Array:
	var out := PackedInt32Array()
	if _outer == null:
		return out
	var seen: Dictionary = {}
	for e in _boundary_edges(_outer):
		for v in [(e as Vector2i).x, (e as Vector2i).y]:
			if not seen.has(v) and not _band_edge.has(_qkey(_outer.pos[v])):
				seen[v] = true
				out.append(v)
	return out


func _pick_lip_vertex(origin: Vector3, dir: Vector3) -> int:
	if _outer == null or not cut_open:
		return -1
	var d := dir.normalized()
	var best := -1
	var best_d := _lip_pick_dist()
	for v in _lip_candidates():
		var w := _vert_world(v) - origin
		var t := w.dot(d)
		if t <= 0.0:
			continue
		var dist := (w - d * t).length()
		if dist < best_d:
			best_d = dist
			best = v
	return best


## t82u：唇缘顶点的「向外」方向（绑定空间，贴皮肤切平面）：从切口中心线指向这一侧唇缘所在的皮肤。
## 拉钩只拉开、不推：方向只由切口几何决定——这一刀（或剥离洞缘）的唇缘链在该点附近 ±RETR_WIN 个顶点的
## 平滑切线 × 平均法线，符号由这一段唇缘相邻面片整体落在哪一侧决定（面片只长在本侧皮肤上），
## 与镜头 / 光标无关；同一侧相邻顶点方向连续，不会因单个三角形的朝向翻面。切口两端（左右唇共用的顶点）沿切口轴向朝外。
const RETR_WIN := 4
var _retr_out_cache: Dictionary = {}
var _retr_out_sig: Array = []
var _retr_face_map: Dictionary = {}


func _lip_out_bind(vid: int) -> Vector3:
	if _outer == null or vid < 0 or vid >= _outer.vert_count():
		return Vector3.UP
	var sig := _retractor_sig()
	sig.append(_cuts.size())
	sig.append(_hole_loops.size())
	sig.append(_cuts_src.get_instance_id() if _cuts_src else 0)
	if sig != _retr_out_sig:
		_retr_out_sig = sig
		_retr_out_cache.clear()
		_retr_face_map.clear()
	if _retr_out_cache.has(vid):
		return _retr_out_cache[vid]
	var o := _lip_out_geom(vid)
	if o.length_squared() < 0.5:
		o = _lip_out_local(vid)
	_retr_out_cache[vid] = o
	return o


## vid 所在的唇缘链：[链, 另一侧唇, 是否闭合]；不在任何切口 / 洞缘上时链为空。
func _lip_chain_of(vid: int) -> Array:
	if cut_count() > 0:
		for c in _cuts:
			var d := c as Dictionary
			var l: PackedInt32Array = d["left"]
			var r: PackedInt32Array = d["right"]
			var in_l := l.has(vid)
			var in_r := r.has(vid)
			if in_l and in_r:
				return [l, r, bool(d["closed"]), true]
			if in_l:
				return [l, r, bool(d["closed"]), false]
			if in_r:
				return [r, l, bool(d["closed"]), false]
	for loop in _hole_loops:
		if loop is PackedInt32Array and (loop as PackedInt32Array).has(vid):
			return [loop, PackedInt32Array(), true, false]
	return [PackedInt32Array(), PackedInt32Array(), false, false]


func _retr_faces_of(v: int) -> PackedInt32Array:
	if _retr_face_map.is_empty():
		var want: Dictionary = {}
		for c in _cuts:
			for key in ["left", "right"]:
				for w in ((c as Dictionary)[key] as PackedInt32Array):
					want[w] = true
		for loop in _hole_loops:
			if loop is PackedInt32Array:
				for w2 in (loop as PackedInt32Array):
					want[w2] = true
		for w3 in _lip_candidates():
			want[w3] = true
		for f in _outer.face_count():
			for k in 3:
				var vi := _outer.idx[f * 3 + k]
				if want.has(vi):
					if _retr_face_map.has(vi):
						(_retr_face_map[vi] as PackedInt32Array).append(f)
					else:
						_retr_face_map[vi] = PackedInt32Array([f])
		_retr_face_map[-1] = PackedInt32Array()
	return _retr_face_map.get(v, PackedInt32Array())


func _lip_out_geom(vid: int) -> Vector3:
	var info := _lip_chain_of(vid)
	var chain: PackedInt32Array = info[0]
	var closed: bool = info[2]
	var tip: bool = info[3]
	var n := chain.size()
	if n < 3:
		return Vector3.ZERO
	var i := chain.find(vid)
	if i < 0:
		return Vector3.ZERO
	var p := _outer.pos[vid]
	var nv := _outer.vert_count()
	var win: Array = []
	for k in range(-RETR_WIN, RETR_WIN + 1):
		var j := i + k
		if closed:
			j = posmod(j, n)
		elif j < 0 or j >= n:
			continue
		if chain[j] >= 0 and chain[j] < nv:
			win.append(chain[j])
	if win.size() < 2:
		return Vector3.ZERO
	var nrm := Vector3.ZERO
	for w in win:
		nrm += _outer.nrm[w]
	if nrm.length_squared() < 1e-12:
		nrm = _outer.nrm[vid]
	nrm = nrm.normalized()
	if tip and not closed:
		# 切口端点：沿切口轴向朝外（远离切口中段）。
		var cen := Vector3.ZERO
		for w0 in chain:
			cen += _outer.pos[w0]
		cen /= float(n)
		var ax := p - cen
		ax -= nrm * ax.dot(nrm)
		return ax.normalized() if ax.length_squared() > 1e-12 else Vector3.ZERO
	var t: Vector3 = _outer.pos[win[win.size() - 1]] - _outer.pos[win[0]]
	t -= nrm * t.dot(nrm)
	if t.length_squared() < 1e-12:
		return Vector3.ZERO
	var o := nrm.cross(t.normalized())
	if o.length_squared() < 1e-10:
		return Vector3.ZERO
	o = o.normalized()
	# 符号由整条唇缘决定（不看单个三角形）：
	# - 闭合（环切 / 剥离洞缘）：两侧唇按平均半径分内外，外侧唇朝外、内侧（皮瓣）唇朝洞心；只有一圈洞缘时一律朝外。
	# - 直切口：远离对侧唇上最近的点；两唇还贴在一起时，用整条唇缘相邻面片落在哪一侧。
	var other: PackedInt32Array = info[1]
	var ref := Vector3.ZERO
	if closed:
		var cen2 := Vector3.ZERO
		var cnt := 0
		for w4 in chain:
			cen2 += _outer.pos[w4]
			cnt += 1
		for w5 in other:
			cen2 += _outer.pos[w5]
			cnt += 1
		cen2 /= float(maxi(cnt, 1))
		var sgn := 1.0
		if not other.is_empty():
			var r_self := _mean_radius(chain, cen2)
			var r_other := _mean_radius(other, cen2)
			if absf(r_self - r_other) > 0.0003:
				sgn = 1.0 if r_self > r_other else -1.0
			else:
				sgn = 1.0 if _chain_face_side(chain, nrm) >= 0.0 else -1.0
		ref = (p - cen2) * sgn
	else:
		var bd := 1e9
		var near := Vector3.ZERO
		for w3 in other:
			var dd := _outer.pos[w3].distance_squared_to(p)
			if dd < bd:
				bd = dd
				near = _outer.pos[w3]
		if bd < 1e8 and bd > 0.0005 * 0.0005:
			ref = p - near
		else:
			var ax2: Vector3 = _outer.pos[chain[n - 1]] - _outer.pos[chain[0]]
			var og := nrm.cross(ax2.normalized()).normalized()
			ref = og * _chain_face_side(chain, nrm)
	if o.dot(ref) < 0.0:
		o = -o
	return o


func _mean_radius(chain: PackedInt32Array, c: Vector3) -> float:
	var acc := 0.0
	for w in chain:
		acc += _outer.pos[w].distance_to(c)
	return acc / float(maxi(chain.size(), 1))


## 整条唇缘相邻面片质心相对切口轴法向（nrm × 轴）的总偏向；正 = 皮肤在 nrm × 轴 那一侧。
func _chain_face_side(chain: PackedInt32Array, nrm: Vector3) -> float:
	var n := chain.size()
	if n < 2:
		return 0.0
	var ax: Vector3 = _outer.pos[chain[n - 1]] - _outer.pos[chain[0]]
	if ax.length_squared() < 1e-12:
		return 0.0
	var og := nrm.cross(ax.normalized())
	var side := 0.0
	for w in chain:
		var pw := _outer.pos[w]
		for f in _retr_faces_of(w):
			side += (_outer.centroid(f) - pw).dot(og)
	return side


## 旧算法（单顶点）：只在找不到唇缘链时用。
func _lip_out_local(vid: int) -> Vector3:
	var p := _outer.pos[vid]
	var nrm := _outer.nrm[vid].normalized()
	# 同一边界环上的前后邻点给出切线
	var nb: Array = []
	for e in _boundary_edges(_outer):
		var ev := e as Vector2i
		if ev.x == vid:
			nb.append(ev.y)
		elif ev.y == vid:
			nb.append(ev.x)
	var t := Vector3.RIGHT
	if nb.size() >= 2:
		t = (_outer.pos[nb[0]] - _outer.pos[nb[1]]).normalized()
	elif nb.size() == 1:
		t = (_outer.pos[nb[0]] - p).normalized()
	var o := nrm.cross(t)
	if o.length_squared() < 1e-10:
		o = Vector3.UP
	o = o.normalized()
	# 指向远离开口：开口一侧没有面。看这个顶点所属的面质心在哪边。
	var side := 0.0
	for f in _outer.face_count():
		for k in 3:
			if _outer.idx[f * 3 + k] == vid:
				side += (_outer.centroid(f) - p).dot(o)
	if side < 0.0:
		o = -o
	return o


func _vert_world(vid: int) -> Vector3:
	if pose_locked and _posed_frozen.size() > vid:
		return _posed_frozen[vid]
	if _skel == null:
		return _outer.pos[vid]
	return _skel_xf() * Geom.skin_vertex(_outer.pos[vid], vid, _outer, _skel, _skin)


func _retractor_xf(vid: int, out_bind: Vector3, extra_off: Vector3 = Vector3.ZERO) -> Transform3D:
	var p: Vector3 = _vert_world(vid) + extra_off
	var sb := _skel_xf().basis if _skel else Basis.IDENTITY
	var bone_b := Basis.IDENTITY
	if _skel and _skin and _outer.bones.size() >= (vid + 1) * 4:
		# 主骨骼的姿势旋转（跟随蒙皮）
		var bi := _outer.bones[vid * 4]
		var bw := _outer.weights[vid * 4]
		if bw > 0.0 and bi < _skin.get_bind_count():
			var bn := _skin.get_bind_bone(bi)
			if bn < 0:
				bn = _skel.find_bone(_skin.get_bind_name(bi))
			if bn >= 0:
				bone_b = (_skel.get_bone_global_pose(bn) * _skin.get_bind_pose(bi)).basis
	var n := (sb * bone_b * _outer.nrm[vid]).normalized()
	var o := (sb * bone_b * out_bind).normalized()
	o = (o - n * o.dot(n)).normalized()
	if o.length_squared() < 0.5:
		o = n.cross(Vector3.UP).normalized()
	var z := -o                      # +z 指向切口（钩头那端）
	var y := -n                      # 钩子朝 +y 弯进体内
	var x := y.cross(z).normalized()
	# 0.4.04：整把拉钩绕钩头往外翘 RETR_TILT_DEG：外端（手柄）离开皮肤，不再穿进身体。
	var ta := deg_to_rad(RETR_TILT_DEG)
	z = (z * cos(ta) - n * sin(ta)).normalized()
	y = z.cross(x).normalized()
	var b := Basis(x, y, z).orthonormalized()
	# 0.4.05：钩头接触点再沿皮表法线往外挪几毫米，避免钩身穿进皮肤；钩子仍扣在切面唇缘。
	var origin := p + n * RETR_HOOK_OUT - z * RETR_HOOK_Z - y * (RETR_UNDER_Y - 0.0015)
	return Transform3D(b, origin)


func hover_tool(origin: Vector3, dir: Vector3) -> void:
	if not active:
		_hide_retractor_ghost()
		_set_hovered_organ("")
		return
	if tool == "forceps":
		_hide_retractor_ghost()
		var t0 := Time.get_ticks_usec()
		if not cut_open:
			_set_hovered_organ(selected_organ)
		elif not _fc_active:
			var rec := _pick_forceps_aim(origin, dir)
			_set_hovered_organ(str(rec.get("kind", "")))
			if bool(rec.get("valid", false)):
				_fc_preview_valid = true
				_fc_preview_pt = rec["point"]
				_fc_target = 0.0
				_place_forceps(rec["point"], dir)
				if touch_pick:
					_show_forceps_marker(rec["point"])
		else:
			_hover_forceps(origin, dir)
		forceps_hover_usec = Time.get_ticks_usec() - t0
		return
	if tool != "retractor":
		_hide_retractor_ghost()
		_set_hovered_organ("")
		return
	var vid := _pick_lip_vertex(origin, dir)
	if vid < 0:
		_hide_retractor_ghost()
		return
	if _retr_ghost == null or not is_instance_valid(_retr_ghost):
		_retr_ghost = _make_retractor_node(true)
	if vid != _retr_ghost_vid:
		_retr_ghost_out = _lip_out_bind(vid)
	_retr_ghost_vid = vid
	_retr_ghost.global_transform = _retractor_xf(vid, _retr_ghost_out)
	_retr_ghost.visible = true


func _hide_retractor_ghost() -> void:
	if _retr_ghost and is_instance_valid(_retr_ghost):
		_retr_ghost.visible = false
	_retr_ghost_vid = -1


func _ray_hits_retractor(origin: Vector3, dir: Vector3) -> int:
	var best := -1
	var best_t := 1e9
	var box := AABB(Vector3(-0.017, -0.02, -0.078), Vector3(0.034, 0.04, 0.156))
	for i in _retractors.size():
		var n: Node3D = (_retractors[i] as Dictionary)["node"]
		if n == null or not is_instance_valid(n):
			continue
		var inv := n.global_transform.affine_inverse()
		var lo := inv * origin
		var ld := (inv.basis * dir).normalized()
		var hit = box.intersects_ray(lo, ld)
		if hit != null:
			var t := ((hit as Vector3) - lo).length()
			if t < best_t:
				best_t = t
				best = i
	return best


func _begin_retractor(origin: Vector3, dir: Vector3) -> bool:
	if not cut_open or _outer == null:
		return false
	# 点中已放好的拉钩柄：拿起并拖动（拖动 = 拉动它钩住的唇缘）。
	var ri := _ray_hits_retractor(origin, dir)
	if ri >= 0:
		select_retractor(ri)
		return _begin_retractor_drag(ri)
	select_retractor(-1)
	hover_tool(origin, dir)
	if _retr_ghost_vid < 0:
		return false
	_retr_placing = true
	stroke_active = true
	return true


func _place_retractor_at_ghost() -> bool:
	var vid := _retr_ghost_vid
	var out_b := _retr_ghost_out
	_hide_retractor_ghost()
	return place_retractor(vid, out_b)


## 在唇缘顶点 vid 放一把拉钩：钩头盖住截面、钩住唇缘，并把唇缘往外拉开一点（写进网格，不回弹）。
func place_retractor(vid: int, out_b: Vector3 = Vector3.ZERO) -> bool:
	if _outer == null or vid < 0 or vid >= _outer.vert_count():
		return false
	if out_b.length_squared() < 1e-10:
		out_b = _lip_out_bind(vid)
	_bake_pull()
	var node := _make_retractor_node(false)
	if not is_in_group(HangGrab.GROUP):
		add_to_group(HangGrab.GROUP)   # t104u：普通互动工具（HangGrab）也能抓拉钩
	var rec := {"node": node, "vid": vid, "bind": _outer.pos[vid], "out_bind": out_b}
	_retractors.append(rec)
	_retr_sig = _retractor_sig()
	# 初始拉开
	if _start_retractor_pull(_retractors.size() - 1):
		_pull_off = _pull_axis * RETR_OPEN if _pull_axis.length_squared() > 1e-8 else _pull_off
		_apply_pull_uniforms()
		_bake_pull_tracked(_retractors.size() - 1)
	_grab_active = false
	_grab_kind = ""
	_update_retractors()
	return true


func _start_retractor_pull(ri: int) -> bool:
	var r: Dictionary = _retractors[ri]
	var vid: int = r["vid"]
	if vid < 0 or vid >= _outer.vert_count():
		return false
	var bind_p := _outer.pos[vid]
	var world_p := _approx_world_bind(bind_p)
	var out_w := _approx_world_bind(bind_p + (r["out_bind"] as Vector3) * 0.01) - world_p
	var out_ab := _to_ab_delta(out_w)
	_split_dir = _skin_split_dir(bind_p)
	_activate_cut_for(vid)
	var wl := 1 if _lip_left.has(vid) else (-1 if _lip_right.has(vid) else 0)
	_setup_pull_geometry(bind_p, world_p, out_ab, wl)
	if _pull_mode == 1 and not (_lip_left.has(vid) or _lip_right.has(vid)):
		# 拉钩不在最近一刀的直切口上：退回径向小范围拉动
		_pull_mode = 0
	if _pull_mode == 0:
		_pull_axis = out_ab.normalized()
		_pull_p = _to_ab_local(world_p)
	_pull_r = PULL_RADIUS if _pull_mode != 0 else RETR_PICK_DIST * 1.6
	_pull_raw = Vector3.ZERO
	_pull_off = Vector3.ZERO
	_pull_peak = 0.0
	_pull_rest = Vector3.ZERO
	return true


func _begin_retractor_drag(ri: int) -> bool:
	_bake_pull()
	_retr_drag = ri
	if not _start_retractor_pull(ri):
		_retr_drag = -1
		return false
	var n: Node3D = (_retractors[ri] as Dictionary)["node"]
	_grab_kind = "retractor"
	_grab_active = true
	stroke_active = true
	_grab_last = n.global_transform * Vector3(0, 0, RETR_HOOK_Z)
	_grab_vel = Vector3.ZERO
	_apply_pull_uniforms()
	return true


## 测试：拿起第 ri 把拉钩，沿腹局部方向拖 off_ab（米）后松手。
func debug_drag_retractor(ri: int, off_ab: Vector3) -> bool:
	if ri < 0 or ri >= _retractors.size():
		return false
	if not _begin_retractor_drag(ri):
		return false
	_pull_raw = off_ab
	_pull_off = _shape_pull(off_ab, true)
	_apply_pull_uniforms()
	_end_grab(false)
	stroke_active = false
	return true


## ---- t104u：拿取工具 / 普通互动工具（HangGrab）拿起已放好的拉钩 ----
## 指针相对按下点的位移分两部分：沿创缘（拉钩自身 x 轴 = 唇缘切线）的分量让钩头挪到同一条唇缘链上
## 最近的顶点（这把拉钩原来写进网格的拉开量撤回，在新位置按原拉开量重新拉开）；其余分量照拉钩工具的
## 规则（_shape_pull：方向由切口几何决定，只沿拉开轴，最多往回收 RETR_CLOSE_MAX）改变拉开程度。松手写进网格。
const RETR_SLIDE_HYST := 0.0015
var _retr_slide := false
var _retr_ref := Vector3.ZERO       # 指针位移的参考点（钩头，挪位后跟着新顶点走）
var _retr_ref_off := Vector3.ZERO   # 钩头 − 唇缘顶点（按下时）
var retractor_moved: int = 0


func _retr_hook_world(ri: int) -> Vector3:
	var n: Node3D = (_retractors[ri] as Dictionary)["node"]
	return n.global_transform * Vector3(0, 0, RETR_HOOK_Z) if n and is_instance_valid(n) else _vert_world(int((_retractors[ri] as Dictionary)["vid"]))


func _begin_retractor_grab(ri: int) -> bool:
	if ri < 0 or ri >= _retractors.size() or _grab_active:
		return false
	_update_retractors()
	select_retractor(ri)
	if not _begin_retractor_drag(ri):
		return false
	_retr_slide = true
	_retr_ref = _grab_last
	_retr_ref_off = _retr_ref - _vert_world(int((_retractors[ri] as Dictionary)["vid"]))
	return true


func _retr_slide_drag(target: Vector3) -> void:
	if _retr_drag < 0 or _retr_drag >= _retractors.size() or not target.is_finite():
		return
	var rec: Dictionary = _retractors[_retr_drag]
	var vid: int = rec["vid"]
	var n: Node3D = rec["node"]
	if vid >= 0 and vid < _outer.vert_count() and n and is_instance_valid(n):
		var tx := n.global_transform.basis.x.normalized()
		var cur_w := _vert_world(vid)
		var want := cur_w + tx * (target - _retr_ref).dot(tx)
		var chain: PackedInt32Array = _lip_chain_of(vid)[0]
		if chain.is_empty():
			chain = _lip_candidates()
		var best := vid
		var bd := cur_w.distance_to(want) - RETR_SLIDE_HYST
		for v in chain:
			if v == vid or v < 0 or v >= _outer.vert_count() or _band_edge.has(_qkey(_outer.pos[v])):
				continue
			var dv := _vert_world(v).distance_to(want)
			if dv < bd:
				bd = dv
				best = v
		if best != vid:
			_relocate_retractor(_retr_drag, best)
			_retr_ref = _vert_world(best) + _retr_ref_off
	_pull_raw = _to_ab_delta(target - _retr_ref) * GRAB_SKIN_GAIN
	_pull_off = _shape_pull(_pull_raw, true)
	_grab_vel = Vector3.ZERO
	_split_drag = _pull_off.length()
	_apply_pull_uniforms()
	_update_retractors()


## 这把拉钩在它钩住的唇缘顶点上写进网格的拉开量（米）。
func _retr_hold_amount(rec: Dictionary) -> float:
	var vid: int = rec["vid"]
	var acc := Vector3.ZERO
	for e in rec.get("deltas", []):
		if e[0] != _outer:
			continue
		var ids: PackedInt32Array = e[1]
		var i := ids.find(vid)
		if i >= 0:
			acc += (e[2] as PackedVector3Array)[i]
	return acc.length()


## 把第 ri 把拉钩挪到唇缘顶点 new_vid：撤回它原来写进网格的位移，在新位置按原拉开量重新拉开并记账；
## 之后继续以新位置为基准拖动。
func _relocate_retractor(ri: int, new_vid: int) -> void:
	var rec: Dictionary = _retractors[ri]
	var hold := maxf(_retr_hold_amount(rec), RETR_OPEN)
	_pull_off = Vector3.ZERO
	_pull_raw = Vector3.ZERO
	_pull_r = 0.0
	_apply_pull_uniforms()
	_finish_retr_release()
	var dl: Array = rec.get("deltas", [])
	if not dl.is_empty():
		_apply_retr_deltas(dl, -1.0)
	rec["deltas"] = []
	rec["vid"] = new_vid
	rec["bind"] = _outer.pos[new_vid]
	rec["out_bind"] = _lip_out_bind(new_vid)
	_after_retr_delta()
	if _start_retractor_pull(ri):
		_pull_off = _pull_axis * hold if _pull_axis.length_squared() > 1e-8 else Vector3.ZERO
		_apply_pull_uniforms()
		_bake_pull_tracked(ri)
		_start_retractor_pull(ri)
		_apply_pull_uniforms()
	retractor_moved += 1


## HangGrab 接口（普通互动工具 / 手术里没拿工具时的手）：只抓已放好的拉钩。
func hang_pick(origin: Vector3, dir: Vector3) -> Dictionary:
	if not (active or persist) or not cut_open or _outer == null or _retractors.is_empty() or _grab_active:
		return {}
	var ri := _ray_hits_retractor(origin, dir)
	if ri < 0:
		return {}
	var d := dir.normalized()
	var hook := _retr_hook_world(ri)
	var t := (hook - origin).dot(d)
	if t <= 0.0:
		return {}
	return {"t": t, "point": origin + d * t, "anchor": hook, "part": "retractor", "ri": ri}


func hang_grab(hit: Dictionary, _origin: Vector3, _dir: Vector3) -> bool:
	return _begin_retractor_grab(int(hit.get("ri", -1)))


func hang_drag(anchor_target: Vector3) -> void:
	if _grab_active and _grab_kind == "retractor" and _retr_slide:
		_retr_slide_drag(anchor_target)


func hang_release() -> void:
	if _grab_active and _grab_kind == "retractor":
		_end_grab(false)


func hang_grab_part() -> String:
	return "retractor" if _grab_active and _grab_kind == "retractor" else ""


## 测试：用拿取工具的路径拿起第 ri 把拉钩，把钩头拖到 world_off（世界位移，分 steps 步），松手。
func debug_grab_tool_drag_retractor(ri: int, world_off: Vector3, steps: int = 12) -> bool:
	if not _begin_retractor_grab(ri):
		return false
	var p0 := _retr_ref
	for i in steps:
		var acc := world_off * (float(i + 1) / float(steps))
		_retr_slide_drag(p0 + acc)
	_end_grab(false)
	return true


func _retractor_sig() -> Array:
	return [_outer.get_instance_id() if _outer else 0, _outer.vert_count() if _outer else 0, _outer.idx.size() if _outer else 0]


func _update_retractors() -> void:
	if _retractors.is_empty() or _outer == null:
		return
	var sig := _retractor_sig()
	if sig != _retr_sig:
		# 拓扑变了（新切口 / 剥皮瓣）：按记下的绑定位置重新找最近的唇缘顶点。
		_retr_sig = sig
		var cands := _lip_candidates()
		for r in _retractors:
			var bp: Vector3 = (r as Dictionary)["bind"]
			var best := -1
			var bd := 1e9
			for v in cands:
				var dd := _outer.pos[v].distance_squared_to(bp)
				if dd < bd:
					bd = dd
					best = v
			(r as Dictionary)["vid"] = best
	var fr_ok := _organs and _organs.has_method("abdomen_frame")
	var fr: Transform3D = _ab_frame() if fr_ok else Transform3D.IDENTITY
	for i in _retractors.size():
		var r2: Dictionary = _retractors[i]
		var n: Node3D = r2["node"]
		var vid: int = r2["vid"]
		if n == null or not is_instance_valid(n) or vid < 0 or vid >= _outer.vert_count():
			if n and is_instance_valid(n):
				n.visible = false
			continue
		r2["bind"] = _outer.pos[vid]
		var extra := Vector3.ZERO
		if _pull_r > 1e-5 and fr_ok:
			extra = fr.basis * _pull_offset_cpu(fr.affine_inverse() * _vert_world(vid))
		n.global_transform = _retractor_xf(vid, r2["out_bind"], extra)
		n.visible = true


## ---- 0.4.04 拉钩选中 / 移除 ----
const RETR_TILT_DEG := 14.0
const RETR_HOOK_OUT := 0.005   # 0.4.05：钩头沿法线外移，消除穿皮
const RETR_RELEASE_T := 0.6
var _retr_selected: int = -1
var _retr_release: Array = []   # [{deltas: Array[[md, ids, d]], t}]
var retractor_removed: int = 0
signal retractor_selection_changed


func selected_retractor() -> int:
	return _retr_selected


func select_retractor(ri: int) -> void:
	if ri >= _retractors.size():
		ri = -1
	_retr_selected = ri
	for i in _retractors.size():
		var n: Node3D = (_retractors[i] as Dictionary)["node"]
		if n and is_instance_valid(n):
			_set_retractor_highlight(n, i == ri)
	retractor_selection_changed.emit()


func _set_retractor_highlight(n: Node3D, on: bool) -> void:
	var ov: StandardMaterial3D = null
	if on:
		ov = StandardMaterial3D.new()
		ov.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ov.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ov.albedo_color = Color(0.35, 0.85, 1.0, 0.35)
		ov.no_depth_test = true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_overlay = ov
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_overlay = ov


## 把当前拉扯写进网格，并把这次写入的位移记到第 ri 把拉钩名下。
func _bake_pull_tracked(ri: int) -> bool:
	_finish_retr_release()
	_bake_evert()
	var mds: Array = [_outer]
	if _inner:
		mds.append(_inner)
	for part in _wall_parts:
		var wmd: Geom.MeshData = (part as Dictionary).get("md")
		if wmd:
			mds.append(wmd)
	if _wrap:
		mds.append(_wrap)
	var before: Array = []
	for md in mds:
		before.append((md as Geom.MeshData).pos.duplicate())
	var ok := _bake_pull()
	if ri < 0 or ri >= _retractors.size():
		return ok
	var rec: Dictionary = _retractors[ri]
	var dl: Array = rec.get("deltas", [])
	for k in mds.size():
		var md2: Geom.MeshData = mds[k]
		var b0: PackedVector3Array = before[k]
		var ids := PackedInt32Array()
		var dd := PackedVector3Array()
		for v in mini(b0.size(), md2.vert_count()):
			var d := md2.pos[v] - b0[v]
			if d.length_squared() > 1e-14:
				ids.append(v)
				dd.append(d)
		if not ids.is_empty():
			dl.append([md2, ids, dd])
	rec["deltas"] = dl
	return ok


## 移除第 ri 把拉钩：拉钩消失，它写进网格的拉开位移按弹簧曲线撤回（皮瓣像松手一样回弹）。
func remove_retractor(ri: int) -> bool:
	if ri < 0 or ri >= _retractors.size():
		return false
	if _grab_active and _grab_kind == "retractor":
		_end_grab(false)
	_finish_retr_release()
	var rec: Dictionary = _retractors[ri]
	var n: Node = rec.get("node")
	if n and is_instance_valid(n):
		n.queue_free()
	_retractors.remove_at(ri)
	_retr_selected = -1
	_retr_drag = -1
	var dl: Array = rec.get("deltas", [])
	if not dl.is_empty():
		_retr_release.append({"deltas": dl, "t": 0.0, "w": 0.0})
	retractor_removed += 1
	select_retractor(-1)
	return true


func remove_selected_retractor() -> bool:
	return remove_retractor(_retr_selected)


## 撤回曲线：欠阻尼弹簧，0 → 1，略过冲后停在 1。
func _retr_release_w(t: float) -> float:
	if t >= RETR_RELEASE_T:
		return 1.0
	return 1.0 - exp(-t * 9.0) * cos(t * 13.0)


func _step_retr_release(dt: float) -> void:
	if _retr_release.is_empty():
		return
	var any := false
	for rel in _retr_release:
		var r: Dictionary = rel
		r["t"] = float(r["t"]) + dt
		var w1 := _retr_release_w(float(r["t"]))
		var dw := w1 - float(r["w"])
		r["w"] = w1
		if absf(dw) > 1e-6:
			_apply_retr_deltas(r["deltas"], -dw)
			any = true
	var keep: Array = []
	for rel2 in _retr_release:
		if float((rel2 as Dictionary)["t"]) < RETR_RELEASE_T:
			keep.append(rel2)
	_retr_release = keep
	if any:
		_after_retr_delta()


func _apply_retr_deltas(dl: Array, k: float) -> void:
	for e in dl:
		var md: Geom.MeshData = e[0]
		var ids: PackedInt32Array = e[1]
		var dd: PackedVector3Array = e[2]
		for i in ids.size():
			if ids[i] < md.vert_count():
				md.pos[ids[i]] += dd[i] * k


func _after_retr_delta() -> void:
	_rebuild_wall_md()
	_rebuild_surgical_meshes(_outer, _inner, _wall_md)
	_posed_dirty = true
	_update_retractors()


## 有新的拉扯 / 切割要写网格前，把还没撤完的位移一次撤完。
func _finish_retr_release() -> void:
	if _retr_release.is_empty():
		return
	for rel in _retr_release:
		var r: Dictionary = rel
		var dw := 1.0 - float(r["w"])
		if absf(dw) > 1e-6:
			_apply_retr_deltas(r["deltas"], -dw)
	_retr_release.clear()
	_after_retr_delta()


func retractor_releasing() -> bool:
	return not _retr_release.is_empty()


func _unhandled_input(event: InputEvent) -> void:
	if not active or _retractors.is_empty():
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var kc := (event as InputEventKey).keycode
		if (kc == KEY_DELETE or kc == KEY_BACKSPACE) and _retr_selected >= 0:
			remove_selected_retractor()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		var mp := (event as InputEventMouseButton).position
		var ri := _ray_hits_retractor(cam.project_ray_origin(mp), cam.project_ray_normal(mp))
		if ri >= 0:
			remove_retractor(ri)
			get_viewport().set_input_as_handled()


func _clear_retractors() -> void:
	for r in _retractors:
		var n: Node = (r as Dictionary)["node"]
		if n and is_instance_valid(n):
			n.queue_free()
	_retractors = []
	_retr_drag = -1
	_retr_placing = false
	_retr_selected = -1
	_retr_release.clear()
	if _retr_ghost and is_instance_valid(_retr_ghost):
		_retr_ghost.queue_free()
	_retr_ghost = null
	_retr_ghost_vid = -1


## ---- 0.4.0 切口边缘红色渐变 ----
const WOUND_TINT_R := 0.0045
var _band_edge: Dictionary = {}
var wound_tint_verts: int = 0


static func _qkey(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))


var _bnd_cache_key: Array = []
var _bnd_cache: Dictionary = {}


func _boundary_edges(md: Geom.MeshData) -> Dictionary:
	# 同一网格、拓扑未变时复用（拉钩悬停每次鼠标移动都要查唇缘）。
	var key := [md.get_instance_id(), md.vert_count(), md.idx.size(), hash(md.idx)]
	if key == _bnd_cache_key:
		return _bnd_cache
	var res := _boundary_edges_raw(md)
	_bnd_cache_key = key
	_bnd_cache = res
	return res


func _boundary_edges_raw(md: Geom.MeshData) -> Dictionary:
	var cnt: Dictionary = {}
	for f in md.face_count():
		for k in 3:
			var a := md.idx[f * 3 + k]
			var b := md.idx[f * 3 + (k + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			cnt[key] = int(cnt.get(key, 0)) + 1
	var out: Dictionary = {}
	for key in cnt:
		if int(cnt[key]) == 1:
			out[key] = true
	return out


func _boundary_vert_keys(md: Geom.MeshData) -> Dictionary:
	var out: Dictionary = {}
	if md == null:
		return out
	for e in _boundary_edges(md):
		out[_qkey(md.pos[(e as Vector2i).x])] = true
		out[_qkey(md.pos[(e as Vector2i).y])] = true
	return out


## 每个顶点的伤缘权重（1 = 唇缘 / 洞缘 / 弹孔边，WOUND_TINT_R 内平滑降到 0）。原腹带外缘不算。
func wound_weights(md: Geom.MeshData) -> PackedFloat32Array:
	var n := md.vert_count()
	var w := PackedFloat32Array()
	w.resize(n)
	var lips: Dictionary = {}
	for e in _boundary_edges(md):
		for v in [(e as Vector2i).x, (e as Vector2i).y]:
			if not _band_edge.has(_qkey(md.pos[v])):
				lips[v] = true
	if lips.is_empty():
		return w
	var cell := WOUND_TINT_R
	var grid: Dictionary = {}
	for v in lips:
		var c := Vector3i((md.pos[v] / cell).floor())
		if not grid.has(c):
			grid[c] = []
		(grid[c] as Array).append(v)
	for i in n:
		var p := md.pos[i]
		var c0 := Vector3i((p / cell).floor())
		var best := cell * cell
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var arr = grid.get(c0 + Vector3i(dx, dy, dz))
					if arr == null:
						continue
					for v2 in arr:
						best = minf(best, p.distance_squared_to(md.pos[v2]))
		if best < cell * cell:
			var t := sqrt(best) / WOUND_TINT_R
			w[i] = 1.0 - t * t * (3.0 - 2.0 * t)
	return w


func _with_wound_color(am: ArrayMesh, md: Geom.MeshData) -> ArrayMesh:
	if am == null or md == null or am.get_surface_count() < 1:
		return am
	var arrays := am.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.size() != md.vert_count():
		return am
	var w := wound_weights(md)
	var cols := PackedColorArray()
	cols.resize(verts.size())
	var tinted := 0
	for i in verts.size():
		cols[i] = Color(1.0, 1.0 - w[i], 1.0 - w[i], 1.0)
		if w[i] > 0.5:
			tinted += 1
	wound_tint_verts = tinted
	arrays[Mesh.ARRAY_COLOR] = cols
	var blends: Array = []
	for bi in am.get_blend_shape_count():
		blends.append(am.surface_get_blend_shape_arrays(0)[bi])
	var out := ArrayMesh.new()
	out.blend_shape_mode = am.blend_shape_mode
	for bi2 in am.get_blend_shape_count():
		out.add_blend_shape(am.get_blend_shape_name(bi2))
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blends)
	return out


## 0.3.8：拿取切口的几何约束。直线切口：只拉被抓的那一侧唇缘，沿切口两端权重为 0（切口端点钉在身上），
## 离切线越远越弱；环形洞缘：只拉被抓的那一段洞缘。避免像 0.3.7 那样把整段切口连同两侧一起拖走错位。
const PULL_RADIUS := 0.055


func _setup_pull_geometry(bind_p: Vector3, world_p: Vector3, want_side: Vector3 = Vector3.ZERO, want_lip: int = 0) -> void:
	_pull_p = _to_ab_local(world_p)
	_pull_mode = 0
	_pull_axis = Vector3.ZERO
	_pull_np = 0
	_pull_lip = 0
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
		# 0.3.9：张开方向必须贴着皮肤切平面。原来带有很大的法向分量，而切口在弯曲的腹部上鼓出端点连线，
		# 两侧唇缘相对连线的「侧向距离」几乎为 0，拿取拉不开任何一侧（看起来黏在一起）。
		var mid_n: Vector3 = Vector3.ZERO
		for li2 in [l0, r0, l1, r1, _lip_left[n / 2], _lip_right[n / 2]]:
			mid_n += _outer.nrm[li2]
		if mid_n.length_squared() > 1e-10:
			var bmid := (_outer.pos[_lip_left[n / 2]] + _outer.pos[_lip_right[n / 2]]) * 0.5
			var n_ab := _to_ab_local(_approx_world_bind(bmid + mid_n.normalized() * 0.01)) - _to_ab_local(_approx_world_bind(bmid))
			if n_ab.length_squared() > 1e-12:
				n_ab = n_ab.normalized()
				sd -= n_ab * sd.dot(n_ab)
		if sd.length_squared() < 1e-10:
			return
		sd = sd.normalized()
		var sign := 1.0
		# 0.4.03：先确定抓的是哪一侧唇（拓扑上的左 / 右），再由该侧唇缘实际位置定方向；
		# 不再用端点连线判断，经过肚脐等切线弯折处另一侧也能正确选中。
		var lip := want_lip
		if lip == 0 and want_side.length_squared() < 1e-10:
			var dl0 := 1e9
			var dr0 := 1e9
			for i0 in n:
				if _lip_left[i0] < nv:
					dl0 = minf(dl0, _outer.pos[_lip_left[i0]].distance_squared_to(bind_p))
				if _lip_right[i0] < nv:
					dr0 = minf(dr0, _outer.pos[_lip_right[i0]].distance_squared_to(bind_p))
			lip = 1 if dl0 <= dr0 else -1
		if lip == 0:
			var lm := _to_ab_local(_approx_world_bind(_outer.pos[_lip_left[n / 2]]))
			var rm := _to_ab_local(_approx_world_bind(_outer.pos[_lip_right[n / 2]]))
			lip = 1 if want_side.dot(lm - rm) >= 0.0 else -1
		if _build_pull_poly(lip, n, sd):
			var pm: Vector4 = _pull_pax[_pull_np / 2]
			sign = 1.0 if Vector3(pm.x, pm.y, pm.z).dot(sd) >= 0.0 else -1.0
			_pull_axis = sd * sign
			_pull_mode = 1
			_pull_lip = lip
			return
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


func _build_pull_poly(lip: int, n: int, sd: Vector3) -> bool:
	var nv := _outer.vert_count()
	var g: PackedInt32Array = _lip_left if lip > 0 else _lip_right
	var o: PackedInt32Array = _lip_right if lip > 0 else _lip_left
	var cnt := mini(PULL_MAXP, n)
	if cnt < 2:
		return false
	var mids: Array[Vector3] = []
	var gs: Array[Vector3] = []
	for k in cnt:
		var i := int(round(float(k) * float(n - 1) / float(cnt - 1)))
		if g[i] >= nv or o[i] >= nv:
			return false
		var pg := _to_ab_local(_approx_world_bind(_outer.pos[g[i]]))
		var po := _to_ab_local(_approx_world_bind(_outer.pos[o[i]]))
		mids.append((pg + po) * 0.5)
		gs.append(pg)
	_pull_poly = PackedVector4Array()
	_pull_pax = PackedVector4Array()
	var acc := 0.0
	var nrm_ab := Vector3.ZERO
	var fb := sd
	# 退化（两端两唇重合）时的后备方向：中间一段的方向
	var mi := cnt / 2
	if (gs[mi] - mids[mi]).dot(sd) < 0.0:
		fb = -sd
	for k in cnt:
		if k > 0:
			acc += mids[k].distance_to(mids[k - 1])
		_pull_poly.append(Vector4(mids[k].x, mids[k].y, mids[k].z, acc))
		var tg := mids[mini(k + 1, cnt - 1)] - mids[maxi(k - 1, 0)]
		var ax := gs[k] - mids[k]
		if tg.length_squared() > 1e-12:
			tg = tg.normalized()
			ax -= tg * ax.dot(tg)
		if ax.length() < 0.0004:
			ax = fb - tg * fb.dot(tg)
		ax = ax.normalized()
		# 去掉法向分量（贴着皮肤切平面张开），法向由 sd 与切向近似
		var nn := tg.cross(fb)
		if nn.length_squared() > 1e-10:
			nn = nn.normalized()
			ax -= nn * ax.dot(nn)
			if ax.length_squared() > 1e-10:
				ax = ax.normalized()
		_pull_pax.append(Vector4(ax.x, ax.y, ax.z, 0.0))
	_pull_np = cnt
	_pull_sp = _poly_arclen_at(_pull_p)
	return true


func _poly_arclen_at(l: Vector3) -> float:
	var bd := 1e9
	var bs := 0.0
	for k in _pull_np - 1:
		var a: Vector4 = _pull_poly[k]
		var b: Vector4 = _pull_poly[k + 1]
		var pa := Vector3(a.x, a.y, a.z)
		var e := Vector3(b.x, b.y, b.z) - pa
		var t := clampf((l - pa).dot(e) / maxf(e.length_squared(), 1e-10), 0.0, 1.0)
		var d := l.distance_squared_to(pa + e * t)
		if d < bd:
			bd = d
			bs = lerpf(a.w, b.w, t)
	return bs


## 把累计的拖拽量变成实际皮肤位移：沿张开方向（只张开，不能把唇缘推过切线）+ 少量切向，软饱和到 GRAB_SKIN_MAX。
func _shape_pull(raw: Vector3, allow_close: bool = false) -> Vector3:
	var v := raw
	if _pull_mode == 0 or _pull_axis.length_squared() < 1e-8:
		if _split_dir.length_squared() > 1e-6:
			var along0 := _split_dir * raw.dot(_split_dir)
			v = along0 * 0.85 + raw * 0.15
	else:
		var along := raw.dot(_pull_axis)
		var tang := raw - _pull_axis * along
		# 拉钩可以往回推一点（收小开口），但不超过 RETR_CLOSE_MAX，避免把唇缘推过切线。
		var lo := -RETR_CLOSE_MAX if allow_close else 0.0
		v = _pull_axis * maxf(along, lo) + tang * 0.15
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
	if _pull_mode == 1 and _pull_np >= 2:
		var bd := 1e9
		var br := Vector3.ZERO
		var bax := Vector3.ZERO
		var bs := 0.0
		for k in _pull_np - 1:
			var a4: Vector4 = _pull_poly[k]
			var b4: Vector4 = _pull_poly[k + 1]
			var pa := Vector3(a4.x, a4.y, a4.z)
			var e := Vector3(b4.x, b4.y, b4.z) - pa
			var tt := clampf((l - pa).dot(e) / maxf(e.length_squared(), 1e-10), 0.0, 1.0)
			var rr := l - (pa + e * tt)
			var d := rr.length_squared()
			if d < bd:
				bd = d
				br = rr
				var x0: Vector4 = _pull_pax[k]
				var x1: Vector4 = _pull_pax[k + 1]
				bax = Vector3(x0.x, x0.y, x0.z).lerp(Vector3(x1.x, x1.y, x1.z), tt)
				bs = lerpf(a4.w, b4.w, tt)
		var total := maxf((_pull_poly[_pull_np - 1] as Vector4).w, 1e-5)
		var T := clampf(bs / total, 0.0, 1.0)
		var sidep := br.dot((bax + Vector3(1e-9, 1e-9, 1e-9)).normalized())
		var endsp := sqrt(maxf(sin(PI * T), 0.0))
		var wsidep := smoothstep(0.0, 0.0015, sidep)
		var wfallp := 1.0 - smoothstep(0.0, _pull_r, br.length())
		var wgrabp := 1.0 - smoothstep(0.0, 0.07, absf(bs - _pull_sp))
		w = endsp * wsidep * wfallp * (0.35 + 0.65 * wgrabp)
	elif _pull_mode == 1:
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


## ---- T-11：拿取工具拖动已悬垂在体外的物理内脏 ----------------------------------
## 只移动 / 甩动：不放回、也不会再多扯出——肠袢 fed_len、柔体系带长度与扯出档位、
## 脱垂量在拖动期间都保持不变（钳子才负责扯出 / 放回）。
const ORGAN_GRAB_PICK := 0.022
var organ_grab_kind: String = ""     # gut | soft | tube | prolapse
var _og_pull := -1
var _og_soft := ""
var _og_side := -1
var _og_reach := 0.0
var organ_grabs := 0


func is_organ_grab_active() -> bool:
	return _grab_active and _grab_kind == "organ"


func _begin_organ_grab(origin: Vector3, dir: Vector3) -> bool:
	if not active:
		return false
	var d := dir.normalized()
	var best := ORGAN_GRAB_PICK
	var best_t := 1e9
	var pick := {}
	# 肠袢：ray_pick 只返回体外段的点。
	for i in _gut_pulls.size():
		var rope: Node = (_gut_pulls[i] as Dictionary)["rope"]
		if rope == null or not is_instance_valid(rope) or bool(rope.get("retracting")):
			continue
		var pk: Array = rope.call("ray_pick", origin, d)
		var idx := int(pk[0])
		if idx < 0:
			continue
		var pts: PackedVector3Array = rope.call("points")
		var rr := float(rope.get("radius")) if "radius" in rope else 0.008
		var t := (pts[idx] - origin).dot(d)
		if float(pk[1]) <= maxf(rr + 0.006, 0.012) and (float(pk[1]) < best or t < best_t - 0.01):
			best = float(pk[1])
			best_t = t
			pick = {"kind": "gut", "i": i, "idx": idx, "p": pts[idx]}
	# 柔体器官：只能抓体外节点；输卵管悬链：只抓已经是悬链的一侧（不拆新的）。
	for k in _soft_organs.keys():
		var so: Node = _soft_organs[k]
		if so == null or not is_instance_valid(so) or not bool(so.call("is_extracted")) or bool(so.get("retracting")):
			continue
		var cage: PackedVector3Array = so.get("_p")
		for bi in cage.size():
			if not bool(so.call("node_outside", bi)):
				continue
			var w := cage[bi] - origin
			var t2 := w.dot(d)
			if t2 <= 0.0:
				continue
			var perp := (w - d * t2).length()
			if perp < maxf(best, 0.024) and t2 < best_t + 0.004:
				best = perp
				best_t = t2
				pick = {"kind": "soft", "k": str(k), "idx": bi, "p": cage[bi]}
		if str(k) == "uterus":
			for side in [0, 1]:
				if not bool(so.call("tube_chain_active", side)):
					continue
				var rope2: Node = so.call("_chain_node", side)
				if rope2 == null:
					continue
				var pk2: Array = rope2.call("ray_pick", origin, d)
				if int(pk2[0]) < 0 or float(pk2[1]) > 0.010:
					continue
				var pts2: PackedVector3Array = rope2.call("points")
				var t3 := (pts2[int(pk2[0])] - origin).dot(d)
				if t3 < best_t - 0.004 or pick.is_empty():
					best = float(pk2[1])
					best_t = t3
					pick = {"kind": "tube", "k": str(k), "side": side, "p": pts2[int(pk2[0])]}
	# 脱垂子宫（阴道口外的部分）。
	var pc := _prolapse_ctl()
	if pc and bool(pc.call("is_active")):
		var pp: Dictionary = pc.call("ray_pick", origin, d)
		if not pp.is_empty():
			var t4 := (Vector3(pp["point"]) - origin).dot(d)
			if pick.is_empty() or t4 < best_t:
				pick = {"kind": "prolapse", "idx": int(pp["node"]), "p": pp["point"]}
	if pick.is_empty():
		return false
	return _start_organ_grab(pick, origin, d)


func _start_organ_grab(pick: Dictionary, origin: Vector3, dir: Vector3) -> bool:
	var kind := str(pick["kind"])
	var p0: Vector3 = pick["p"]
	match kind:
		"gut":
			var rope: Node = (_gut_pulls[int(pick["i"])] as Dictionary)["rope"]
			rope.set("hold_index", int(pick["idx"]))
			rope.set("hold_pos", p0)
			var ea: Vector3 = rope.get("exit_a")
			var eb: Vector3 = rope.get("exit_b")
			_og_reach = p0.distance_to((ea + eb) * 0.5)
			_og_pull = int(pick["i"])
		"soft":
			var so: Node = _soft_organs[str(pick["k"])]
			if not bool(so.call("hold_particle_swing", int(pick["idx"]), p0)):
				return false
			_og_soft = str(pick["k"])
		"tube":
			var so2: Node = _soft_organs[str(pick["k"])]
			if not bool(so2.call("chain_hold", int(pick["side"]), origin, dir)):
				return false
			_og_soft = str(pick["k"])
			_og_side = int(pick["side"])
		"prolapse":
			var pc := _prolapse_ctl()
			if pc == null:
				return false
			pc.call("begin_drive", "grab", int(pick["idx"]), p0, false, false)
		_:
			return false
	organ_grab_kind = kind
	organ_grabs += 1
	_grab_kind = "organ"
	_grab_active = true
	_grab_last = p0
	_grab_vel = Vector3.ZERO
	stroke_active = true
	return true


func _organ_grab_to(tip: Vector3) -> void:
	if not tip.is_finite():
		return
	_grab_vel = tip - _grab_last
	_grab_last = tip
	match organ_grab_kind:
		"gut":
			if _og_pull >= 0 and _og_pull < _gut_pulls.size():
				var rope: Node = (_gut_pulls[_og_pull] as Dictionary)["rope"]
				if rope and is_instance_valid(rope):
					_forceps_hold(rope, tip, true, _og_reach)
		"soft":
			var so := _soft_node(_og_soft)
			if so:
				so.call("hold_particle", int(so.get("hold_index")), tip)
				so.set("hold_no_feed", true)
		"tube":
			var so2 := _soft_node(_og_soft)
			if so2:
				so2.call("chain_drag", _og_side, tip)
		"prolapse":
			var pc := _prolapse_ctl()
			if pc:
				pc.call("drive_to", tip)


func _end_organ_grab() -> void:
	# 松手只是放开（随惯性摆动），从不触发放回。
	match organ_grab_kind:
		"gut":
			if _og_pull >= 0 and _og_pull < _gut_pulls.size():
				var rope: Node = (_gut_pulls[_og_pull] as Dictionary)["rope"]
				if rope and is_instance_valid(rope):
					rope.set("hold_index", -1)
		"soft":
			var so := _soft_node(_og_soft)
			if so:
				so.call("release_hold")
		"tube":
			var so2 := _soft_node(_og_soft)
			if so2:
				so2.call("chain_release", _og_side)
		"prolapse":
			var pc := _prolapse_ctl()
			if pc:
				pc.call("end_drive")
	organ_grab_kind = ""
	_og_pull = -1
	_og_soft = ""
	_og_side = -1


## 测试：用射线开始拿取（与鼠标同一路径），再把抓点移到世界坐标 tip。
func debug_organ_grab_begin(origin: Vector3, dir: Vector3) -> bool:
	if tool != "grab":
		set_tool("grab")
	return begin_stroke(origin, dir) and is_organ_grab_active()


func debug_organ_grab_to(tip: Vector3) -> void:
	if is_organ_grab_active():
		_organ_grab_to(tip)


func debug_organ_grab_end() -> void:
	if _grab_active:
		_end_grab(true)


func _drag_grab(origin: Vector3, dir: Vector3) -> void:
	if not _grab_active:
		return
	if _grab_kind == "organ":
		_organ_grab_to(_grab_plane_hit(origin, dir, _grab_last))
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
	if _grab_kind == "retractor" and _retr_slide:
		_retr_slide_drag(_grab_plane_hit(origin, dir, _retr_ref))
		return
	if _grab_kind == "retractor":
		var nxt3 := _grab_plane_hit(origin, dir, _grab_last)
		_pull_raw = _to_ab_delta(nxt3 - _grab_last) * GRAB_SKIN_GAIN
		_pull_off = _shape_pull(_pull_raw, true)
		_grab_vel = Vector3.ZERO
		_split_drag = _pull_off.length()
		_apply_pull_uniforms()
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
			_pull_rest = _pull_off * GRAB_REST_FRAC
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
	elif _grab_kind == "organ":
		_end_organ_grab()
	elif _grab_kind == "retractor":
		# 拉钩固定：松手立即把位移写进网格，不回弹（记下这把拉钩造成的位移，移除时可撤销）。
		_bake_pull_tracked(_retr_drag)
		_retr_drag = -1
		_retr_slide = false
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
	_bake_pull()
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
	_pull_rest = _pull_off * GRAB_REST_FRAC
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
		var fr: Transform3D = _ab_frame()
		return fr.affine_inverse() * world_p
	return world_p


func _to_ab_delta(world_delta: Vector3) -> Vector3:
	if _organs and _organs.has_method("abdomen_frame"):
		var fr: Transform3D = _ab_frame()
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
		var np := _pull_np if _pull_mode == 1 else 0
		sm.set_shader_parameter("surgery_pull_np", np)
		if np >= 2:
			var pp := _pull_poly.duplicate()
			var px := _pull_pax.duplicate()
			pp.resize(PULL_MAXP)
			px.resize(PULL_MAXP)
			sm.set_shader_parameter("surgery_pull_poly", pp)
			sm.set_shader_parameter("surgery_pull_pax", px)
			sm.set_shader_parameter("surgery_pull_sp", _pull_sp)


## 0.4.02：拿取松手后回弹更强：只留峰值的 12%（原 42%），弹簧更硬、略欠阻尼，能看到明显回弹。
## 只有拉钩固定的唇缘不回弹。
const GRAB_REST_FRAC := 0.12
const GRAB_SPRING_K := 70.0
const GRAB_SPRING_C := 11.0


func _step_pull_spring(dt: float) -> void:
	var k := GRAB_SPRING_K
	var c := GRAB_SPRING_C
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


func bullet_hole_radius(energy: float) -> float:
	## 0.4.07：特写弹孔贯穿的柱状孔更小（原 1.0–2.0 cm → 0.6–1.2 cm）。
	return clampf(0.006 + energy * 0.005, 0.006, 0.012)


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
	var radius := bullet_hole_radius(energy)
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
	_navel_flatten_if_near(PackedVector3Array([center]), false, radius)
	var path := Geom.circle_path_on_mesh(_outer, center, axis, radius, BULLET_SIDES)
	if path.size() < 5:
		return false
	_bake_evert()
	_ensure_twin()
	var ids := Geom.embed_path(_outer, path)
	if ids.size() < 3:
		return false
	ids = Geom.close_path_ids(_outer, ids)
	if ids.size() >= 3 and ids[0] != ids[ids.size() - 1]:
		ids.append(ids[0])
	Geom.sync_twin_faces(_outer)
	var ext_o: Dictionary = Geom.extract_inside(_outer, ids)
	if int(ext_o.get("inside_faces", 0)) < 1 or int(ext_o.get("outside_faces", 0)) < 1:
		return false
	var body_o: Geom.MeshData = ext_o["outside"]
	if body_o.twin == null:
		body_o.twin = Geom.make_cavity(body_o, thickness, _organ_z, _navel_rest)
	var body_i: Geom.MeshData = body_o.twin
	var loop_o: PackedInt32Array = ext_o["loop_out"]
	# 弹孔缘轻微外翻（位移场，内壁同步），再做柱状壁，壁顶点继承同一位移。
	var lc := _closed_ids(loop_o)
	var sd := PackedVector3Array()
	sd.resize(lc.size())
	Geom.evert_field(body_o, lc, lc, sd, true, 0.45, true)
	var wall := _make_bullet_cylinder(body_o, body_i, loop_o, loop_o, axis)
	if wall.face_count() < 1:
		return false
	_outer = body_o
	_inner = body_i
	_wall_parts.append({"md": wall, "ring": -1})
	_rebuild_wall_md()
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
	var best_s := _handle_pick_r2()
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
		n = (_ab_frame() as Transform3D).basis.z.normalized()
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


# ------------------------------------------------------------------ 0.4.12 子宫脱垂：手术复位后再扯出
var _prol_pending := 0.0          # 已向外拉、还没换算成复位的距离
var _prol_ray_o := Vector3.ZERO
var _prol_ray_d := Vector3.FORWARD
var prolapse_reduce_handoffs := 0  # 复位完成后转入创口扯出的次数（自检用）


func _prolapse_ctl() -> Node:
	if _organs == null or not _organs.has_method("has_prolapse") or not bool(_organs.call("has_prolapse")):
		return null
	return _organs.call("prolapse")


## 射线经创口指向体内的子宫部分（脱垂柔体在体内的节点附近）→ 夹住开始复位。
func _try_begin_prolapse_reduce(origin: Vector3, dir: Vector3) -> bool:
	var pc := _prolapse_ctl()
	if pc == null or not active:
		return false
	var d := dir.normalized()
	var nodes: PackedVector3Array = pc.call("node_positions")
	var best := 1e9
	var best_p := Vector3.ZERO
	# 体内部分：在体内的节点 + 宫底静止位置（复位后会回去的地方）。
	var cand := PackedVector3Array()
	for i in nodes.size():
		if not bool(pc.call("node_outside", i)):
			cand.append(nodes[i])
	cand.append(pc.call("rest_fundus_world"))
	for p in cand:
		var t := (p - origin).dot(d)
		if t <= 0.0:
			continue
		var q := origin + d * t
		var dist := q.distance_to(p)
		if dist < best:
			best = dist
			best_p = p
	if best > 0.035:
		return false
	_fc_kind = "prolapse"
	_fc_soft_kind = "uterus"
	_fc_last = best_p
	_prol_pending = 0.0
	_prol_ray_o = origin
	_prol_ray_d = d
	pc.call("begin_surgery_reduce")
	_start_forceps_grip(-1, dir)
	_set_selected_organ("uterus")
	return true


## t68u：射线点到阴道口外悬垂的脱垂子宫 → 手术钳夹住拖动（与阴道互动的手拖同一驱动接口）。
func _try_begin_prolapse_drag(origin: Vector3, dir: Vector3, max_t: float = 1e9) -> bool:
	var pc := _prolapse_ctl()
	if pc == null or not active:
		return false
	var pk: Dictionary = pc.call("ray_pick", origin, dir)
	if pk.is_empty():
		return false
	var p: Vector3 = pk["point"]
	if origin.distance_to(p) > max_t + 0.02 and max_t < 1e8:
		return false
	_fc_kind = "prolapse_out"
	_fc_soft_kind = "uterus"
	_fc_last = p
	pc.call("begin_drive", "forceps", int(pk["node"]), p, true, true)
	_start_forceps_grip(-1, dir)
	_set_selected_organ("uterus")
	return true


func _prolapse_forceps_to(tip: Vector3, origin: Vector3, dir: Vector3) -> void:
	var outw := _cavity_outward()
	var pull := (tip - _fc_last).dot(outw)
	if pull > 0.0:
		_prol_pending += pull
	# 钳尖只沿创口外向跟手（脱垂在复位时子宫被往上提），侧向随手。
	_fc_last = tip
	_prol_ray_o = origin
	_prol_ray_d = dir.normalized()


func _update_prolapse_forceps(dt: float) -> void:
	if not (_fc_active and _fc_kind == "prolapse"):
		return
	var pc := _prolapse_ctl()
	if pc == null:
		_prolapse_handoff()
		return
	var before := float(pc.get("descent"))
	var after := float(pc.call("surgery_reduce", _prol_pending, dt))
	var gain := maxf(float((pc.get("params") as Resource).get("surgery_reduce_gain")), 1e-3)
	_prol_pending = maxf(_prol_pending - (before - after) / gain, 0.0)
	if after <= 1e-5:
		pc.call("reset")
		_prolapse_handoff()
	_place_forceps(_fc_last, _prol_ray_d)


## 复位完成：继续拉 = 进入正常的经创口扯出子宫（五档 / 柔体）。
func _prolapse_handoff() -> void:
	prolapse_reduce_handoffs += 1
	_fc_active = false
	var ok := _start_soft_extract("uterus", _prol_ray_o, _prol_ray_d, -1)
	if not ok:
		_fc_kind = "gut"
		_fc_soft_kind = ""
		stroke_active = false
		return
	_prol_pending = 0.0
