extends Node3D
## 房间空墙镜子：对齐网页 three/examples Reflector（反射相机 lookAt + 投影纹理矩阵）。
## 世界坐标与网页一致：pos (0, 1.12, 0.948)，yaw=π，尺寸 2.42×2.18。
## 每帧从当前活动 Camera3D 更新（展示 TP / 控制 FP）。

@export var resolution: int = 768
@export var mirror_width: float = 2.42
@export var mirror_height: float = 2.18

var _viewport: SubViewport
var _mirror_cam: Camera3D
var _mesh: MeshInstance3D
var _frame: Node3D
var _mat: ShaderMaterial

const _SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, specular_disabled;

uniform sampler2D mirror_tex : source_color, filter_linear, repeat_disable;
uniform mat4 tex_matrix;
uniform vec3 tint_color = vec3(0.902, 0.925, 0.941);

varying vec4 mirror_uv;

void vertex() {
	// Reflector: vUv = textureMatrix * vec4(position, 1.0) with local position.
	mirror_uv = tex_matrix * vec4(VERTEX, 1.0);
}

void fragment() {
	if (mirror_uv.w <= 0.0001) {
		discard;
	}
	vec2 uv = mirror_uv.xy / mirror_uv.w;
	vec3 base = texture(mirror_tex, uv).rgb;
	ALBEDO = mix(base, tint_color, 0.06);
}
"""


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

	var sh := Shader.new()
	sh.code = _SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("mirror_tex", _viewport.get_texture())
	_mat.set_shader_parameter("tint_color", Vector3(0.902, 0.925, 0.941))
	_mesh.material_override = _mat
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
	_update_mirror_camera(main_cam)


func _reflect_point(p: Vector3, origin: Vector3, n: Vector3) -> Vector3:
	return p - 2.0 * (p - origin).dot(n) * n


func _reflect_dir(v: Vector3, n: Vector3) -> Vector3:
	return v - 2.0 * v.dot(n) * n


func _update_mirror_camera(main_cam: Camera3D) -> void:
	# Three.js Reflector: local plane normal = +Z, reflect eye + lookAt target + up.
	var n := global_transform.basis.z.normalized()
	var origin := global_position
	var cam_pos := main_cam.global_position
	var dist := (cam_pos - origin).dot(n)
	# Facing away / behind glass (Reflector: view.dot(normal) > 0 skip).
	if dist < 0.05:
		return

	var mirrored_pos := _reflect_point(cam_pos, origin, n)
	# Point main camera looks at (Godot / Three both look down -Z).
	var look_at_pos := cam_pos - main_cam.global_transform.basis.z
	var mirrored_look := _reflect_point(look_at_pos, origin, n)
	var mirrored_up := _reflect_dir(main_cam.global_transform.basis.y, n).normalized()
	if mirrored_up.length_squared() < 1e-8:
		mirrored_up = Vector3.UP

	_mirror_cam.global_position = mirrored_pos
	_mirror_cam.look_at(mirrored_look, mirrored_up)

	_mirror_cam.fov = main_cam.fov
	# Approximate clip at the glass (Godot 4.7 has no oblique projection override).
	_mirror_cam.near = clampf(dist - 0.02, 0.05, maxf(0.08, dist))
	_mirror_cam.far = main_cam.far
	_mirror_cam.keep_aspect = main_cam.keep_aspect

	# Match RT aspect to active camera viewport (Reflector copies projectionMatrix).
	var root_vp := get_viewport()
	if root_vp != null:
		var sz := root_vp.get_visible_rect().size
		if sz.y > 1.0 and sz.x > 1.0:
			var aspect := sz.x / sz.y
			var h := resolution
			var w := int(round(float(resolution) * aspect))
			w = clampi(w, 256, 2048)
			if _viewport.size.x != w or _viewport.size.y != h:
				_viewport.size = Vector2i(w, h)

	if not _mirror_cam.current:
		_mirror_cam.current = true

	_update_texture_matrix()


func _update_texture_matrix() -> void:
	if _mat == null or _mirror_cam == null:
		return
	# Reflector bias * projection * viewInverse * mirror.matrixWorld
	# Columns match Three.js Matrix4.set(0.5,0,0,0.5, 0,0.5,0,0.5, 0,0,0.5,0.5, 0,0,0,1)
	var bias := Projection()
	bias.x = Vector4(0.5, 0.0, 0.0, 0.0)
	bias.y = Vector4(0.0, 0.5, 0.0, 0.0)
	bias.z = Vector4(0.0, 0.0, 0.5, 0.0)
	bias.w = Vector4(0.5, 0.5, 0.5, 1.0)
	var proj := _mirror_cam.get_camera_projection()
	var view := Projection(_mirror_cam.global_transform.affine_inverse())
	var model := Projection(global_transform)
	var tex: Projection = bias * proj * view * model
	_mat.set_shader_parameter("tex_matrix", tex)


## Headless check: reflect an eye across the glass (same formula as Reflector).
func debug_reflect_eye(cam_pos: Vector3) -> Dictionary:
	var n := global_transform.basis.z.normalized()
	var origin := global_position
	var dist := (cam_pos - origin).dot(n)
	return {
		"normal": n,
		"origin": origin,
		"dist": dist,
		"mirrored": _reflect_point(cam_pos, origin, n),
	}
