extends Node3D
## 房间空墙镜子：SubViewport + 镜像 Camera3D → QuadMesh ViewportTexture（对齐网页 WallMirror）。
## 世界坐标与网页一致：pos (0, 1.12, 0.948)，yaw=π，尺寸 2.42×2.18。

@export var resolution: int = 768
@export var mirror_width: float = 2.42
@export var mirror_height: float = 2.18

var _viewport: SubViewport
var _mirror_cam: Camera3D
var _mesh: MeshInstance3D
var _frame: Node3D


func _ready() -> void:
	_build()
	# Layer 2 = mirror surface; mirror cam excludes it to avoid recursion.
	_mesh.layers = 2
	_mirror_cam.cull_mask = 0xFFFFF - 2


func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	_viewport.size = Vector2i(resolution, resolution)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	_viewport.world_3d = get_viewport().world_3d
	add_child(_viewport)

	_mirror_cam = Camera3D.new()
	_mirror_cam.name = "MirrorCamera"
	_mirror_cam.current = false
	_mirror_cam.fov = 55.0
	_mirror_cam.near = 0.08
	_mirror_cam.far = 80.0
	_viewport.add_child(_mirror_cam)

	_mesh = MeshInstance3D.new()
	_mesh.name = "MirrorGlass"
	var quad := QuadMesh.new()
	quad.size = Vector2(mirror_width, mirror_height)
	_mesh.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	# ViewportTexture is already mirrored via camera placement; flip U so text reads correctly.
	mat.uv1_scale = Vector3(-1.0, 1.0, 1.0)
	mat.uv1_offset = Vector3(1.0, 0.0, 0.0)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = mat
	add_child(_mesh)

	_frame = Node3D.new()
	_frame.name = "Frame"
	add_child(_frame)
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.173, 0.149, 0.133)
	frame_mat.roughness = 0.48
	frame_mat.metallic = 0.32
	var t := 0.032
	var d := 0.022
	var hw := mirror_width * 0.5
	var hh := mirror_height * 0.5
	_add_bar(mirror_width + t * 2.0, t, d, 0.0, hh + t * 0.5, frame_mat)
	_add_bar(mirror_width + t * 2.0, t, d, 0.0, -hh - t * 0.5, frame_mat)
	_add_bar(t, mirror_height, d, -hw - t * 0.5, 0.0, frame_mat)
	_add_bar(t, mirror_height, d, hw + t * 0.5, 0.0, frame_mat)


func _add_bar(w: float, h: float, depth: float, x: float, y: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(w, h, depth)
	mi.mesh = box
	mi.material_override = mat
	mi.position = Vector3(x, y, -0.008)
	_frame.add_child(mi)


func _process(_delta: float) -> void:
	if not visible or _mirror_cam == null:
		return
	var main_cam := get_viewport().get_camera_3d()
	if main_cam == null:
		return
	# Only update when the player roughly faces the mirror (web: fwd.z > 0.08 after rot).
	var to_mirror := global_position - main_cam.global_position
	if to_mirror.dot(main_cam.global_transform.basis.z) > 0.15:
		# Camera looking away (Godot cam looks down -Z of its basis).
		pass
	_update_mirror_camera(main_cam)


func _update_mirror_camera(main_cam: Camera3D) -> void:
	# Reflect main camera across this node's XY plane (local +Z = face normal).
	var n := global_transform.basis.z.normalized()
	var origin := global_position
	var cam_pos := main_cam.global_position
	var dist := (cam_pos - origin).dot(n)
	# Skip if camera is behind the mirror glass.
	if dist < 0.02:
		return
	var mirrored_pos := cam_pos - 2.0 * dist * n

	# Reflect look target (a point in front of main cam) across the plane.
	var look_at_pt := cam_pos - main_cam.global_transform.basis.z  # Godot looks down -Z
	var look_dist := (look_at_pt - origin).dot(n)
	var mirrored_look := look_at_pt - 2.0 * look_dist * n

	# Reflect up vector.
	var up := main_cam.global_transform.basis.y
	var up_mir := up - 2.0 * up.dot(n) * n
	if up_mir.length_squared() < 1e-6:
		up_mir = Vector3.UP

	_mirror_cam.global_position = mirrored_pos
	# look_at needs a non-parallel up; fall back if reflected up collapses.
	if absf(up_mir.normalized().dot((mirrored_look - mirrored_pos).normalized())) > 0.98:
		up_mir = Vector3.UP
	_mirror_cam.look_at(mirrored_look, up_mir)
	_mirror_cam.fov = main_cam.fov
	_mirror_cam.near = maxf(0.05, main_cam.near)
	_mirror_cam.far = main_cam.far
