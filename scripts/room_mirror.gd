extends Node3D
## 房间空墙镜子：SubViewport + 镜像 Camera3D → QuadMesh ViewportTexture（对齐网页 WallMirror）。
## 世界坐标与网页一致：pos (0, 1.12, 0.948)，yaw=π，尺寸 2.42×2.18。
## 每帧从当前活动 Camera3D 反射位姿（展示 TP / 控制 FP 均正确）。

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
	_mirror_cam.current = true


func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	_viewport.size = Vector2i(resolution, resolution)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	_viewport.own_world_3d = false
	add_child(_viewport)
	# Share main World3D so the mirror sees the same scene (defer if root not ready).
	_sync_world()

	_mirror_cam = Camera3D.new()
	_mirror_cam.name = "MirrorCamera"
	_mirror_cam.current = true
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
	# ViewportTexture is mirrored via camera placement; flip U so text reads correctly.
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


func _sync_world() -> void:
	if _viewport == null:
		return
	var root_vp := get_viewport()
	if root_vp == null:
		return
	var w := root_vp.world_3d
	if w != null and _viewport.world_3d != w:
		_viewport.world_3d = w


func _process(_delta: float) -> void:
	if not visible or _mirror_cam == null:
		return
	_sync_world()
	var main_cam := get_viewport().get_camera_3d()
	if main_cam == null or main_cam == _mirror_cam:
		return
	# Always track the active camera (Display TP orbit and Control FP).
	_update_mirror_camera(main_cam)


func _update_mirror_camera(main_cam: Camera3D) -> void:
	# Reflect main camera across this node's local XY plane (local +Z = face normal).
	# room_mirror.tscn: yaw=π at (0, 1.12, 0.948) → face toward room center (-Z).
	var n := global_transform.basis.z.normalized()
	var origin := global_position
	var cam_xf := main_cam.global_transform
	var cam_pos := cam_xf.origin
	var dist := (cam_pos - origin).dot(n)
	# Skip if camera is behind / inside the glass.
	if dist < 0.05:
		return

	var mirrored_pos := cam_pos - 2.0 * dist * n

	# Reflect basis; reflection flips handedness → flip X to keep a valid view,
	# matching the material UV U-flip so the image reads as a mirror.
	var bx := cam_xf.basis.x
	var by := cam_xf.basis.y
	var bz := cam_xf.basis.z
	bx = bx - 2.0 * bx.dot(n) * n
	by = by - 2.0 * by.dot(n) * n
	bz = bz - 2.0 * bz.dot(n) * n
	bx = -bx
	var basis := Basis(bx, by, bz).orthonormalized()
	_mirror_cam.global_transform = Transform3D(basis, mirrored_pos)
	_mirror_cam.fov = main_cam.fov
	_mirror_cam.near = maxf(0.05, main_cam.near)
	_mirror_cam.far = main_cam.far
	if not _mirror_cam.current:
		_mirror_cam.current = true
