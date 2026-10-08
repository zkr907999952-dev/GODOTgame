extends Node3D
## 房间空墙镜子（平面镜）：离轴视锥反射相机。
##
## 原理：把当前活动相机的眼睛位置按镜面平面做镜像，放一台“镜中相机”在镜后；
## 镜中相机始终正对镜面（前方 = 镜面法线方向，上方向 = 镜面上方向），
## 用 PROJECTION_FRUSTUM 让视锥的近裁面恰好落在镜面矩形上（离轴投影）。
## 渲染结果与镜面上的矩形区域 1:1 对应，按镜面本地坐标直接贴图（水平翻转一次即镜像），
## 无需屏幕空间 / 投影矩阵换算；近裁面 = 镜面，镜后物体自然被裁掉。
## 视差、透视、左右镜像都由几何关系天然正确，展示（第三人称）/ 控制（第一人称）通用。
##
## 清晰度：每帧只渲染镜面在主相机视野内可见的那块矩形，贴图分辨率按其屏幕像素密度
## 自适应（分档 + 迟滞，避免频繁重建），贴近镜子也不会糊。
##
## 节点约定：本节点原点 = 镜面中心，本地 +Z = 镜面法线（朝向房间内），本地 +Y = 上。

## 渲染层 20：镜面本身（镜中相机不渲染它，避免递归）。
const MIRROR_LAYER := 1 << 19
## 渲染层 19：第一人称时主相机隐藏的头/发/眼（镜中相机仍渲染，镜子里能看到脸）。
const FP_HEAD_LAYER := 1 << 18
const ALL_LAYERS := 0xFFFFF
const TEX_STEP := 128

@export var mirror_width: float = 4.06
@export var mirror_height: float = 2.44
## 镜面贴图像素密度 / 屏幕像素密度。1.0 = 与屏幕等清晰。
@export var resolution_scale: float = 1.0
@export var max_tex_size: int = 2048
@export var tint: Color = Color(0.94, 0.96, 0.97)

var _viewport: SubViewport
var _mirror_cam: Camera3D
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _active: bool = false

const _SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, specular_disabled, shadows_disabled;

uniform sampler2D mirror_tex : source_color, filter_linear, repeat_disable;
// 本帧渲染的镜面区域（镜面本地坐标，米）：x0, y0, 宽, 高
uniform vec4 tex_rect = vec4(-1.0, -1.0, 2.0, 2.0);
uniform vec3 tint = vec3(1.0);
varying vec2 local_xy;

void vertex() {
	local_xy = VERTEX.xy;
}

void fragment() {
	// 镜中相机的屏幕右方向 = 镜面 -X，故 u 从 x1 往 x0 走（即镜像）。
	vec2 uv = vec2(
		(tex_rect.x + tex_rect.z - local_xy.x) / tex_rect.z,
		(tex_rect.y + tex_rect.w - local_xy.y) / tex_rect.w
	);
	ALBEDO = texture(mirror_tex, uv).rgb * tint;
}
"""


func _ready() -> void:
	# 在主相机（玩家 _physics_process / 输入）更新之后再算镜中相机。
	process_priority = 1000
	_build()


func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	_viewport.own_world_3d = false  # 与主场景共用 World3D（同光照 / 环境）
	_viewport.transparent_bg = false
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_viewport.audio_listener_enable_3d = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.size = Vector2i(TEX_STEP * 4, TEX_STEP * 4)
	add_child(_viewport)

	_mirror_cam = Camera3D.new()
	_mirror_cam.name = "MirrorCamera"
	_mirror_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_mirror_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_mirror_cam.cull_mask = ALL_LAYERS & ~MIRROR_LAYER
	_viewport.add_child(_mirror_cam)
	_mirror_cam.current = true

	_mesh = MeshInstance3D.new()
	_mesh.name = "MirrorGlass"
	var quad := QuadMesh.new()  # 正面朝本地 +Z（房间内），背面剔除：从镜后看是透明的
	quad.size = Vector2(mirror_width, mirror_height)
	_mesh.mesh = quad
	_mesh.layers = MIRROR_LAYER
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sh := Shader.new()
	sh.code = _SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("mirror_tex", _viewport.get_texture())
	_mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	_mesh.material_override = _mat
	add_child(_mesh)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_visible_in_tree() else null
	var ok := cam != null and cam != _mirror_cam and _update_mirror_camera(cam)
	_set_active(ok)


func _set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	)


## 返回 false 表示本帧无需渲染镜子（相机在镜后 / 镜子不在视野内）。
func _update_mirror_camera(cam: Camera3D) -> bool:
	var mxf := global_transform.orthonormalized()
	var inv := mxf.affine_inverse()
	var eye := inv * cam.global_position  # 眼睛在镜面本地坐标
	var d := eye.z  # 眼睛到镜面的距离（>0 在房间这一侧）
	if d <= 0.001:
		return false

	# 1) 镜面在主相机视野内的可见部分（多边形裁剪到视锥）。
	var hw := mirror_width * 0.5
	var hh := mirror_height * 0.5
	var poly: Array[Vector3] = [
		mxf * Vector3(-hw, -hh, 0.0),
		mxf * Vector3(hw, -hh, 0.0),
		mxf * Vector3(hw, hh, 0.0),
		mxf * Vector3(-hw, hh, 0.0),
	]
	for plane in cam.get_frustum():
		poly = _clip_poly(poly, plane)
		if poly.size() < 3:
			return false

	# 2) 可见部分在镜面上的包围矩形 + 所需像素密度（屏幕像素 / 米）。
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var density := 0.0
	var prev_l := Vector2.ZERO
	var prev_s := Vector2.ZERO
	for i in poly.size() + 1:
		var p := poly[i % poly.size()]
		var l3 := inv * p
		var l := Vector2(l3.x, l3.y)
		var sp := cam.unproject_position(p)
		if i > 0:
			var phys := l.distance_to(prev_l)
			if phys > 1e-4:
				density = maxf(density, sp.distance_to(prev_s) / phys)
		prev_l = l
		prev_s = sp
		lo = lo.min(l)
		hi = hi.max(l)
	var pad := 0.01
	lo = (lo - Vector2(pad, pad)).max(Vector2(-hw, -hh))
	hi = (hi + Vector2(pad, pad)).min(Vector2(hw, hh))
	var rect_size := (hi - lo).max(Vector2(0.01, 0.01))

	# 3) 贴图尺寸（分档 + 迟滞），矩形按贴图宽高比外扩，保证 1:1 无拉伸。
	density *= resolution_scale
	_sync_texture_size(rect_size * density)
	var tex := Vector2(_viewport.size)
	var aspect := tex.x / tex.y
	var center := (lo + hi) * 0.5
	if rect_size.x / rect_size.y < aspect:
		rect_size.x = rect_size.y * aspect
	else:
		rect_size.y = rect_size.x / aspect
	lo = center - rect_size * 0.5
	_mat.set_shader_parameter("tex_rect", Vector4(lo.x, lo.y, rect_size.x, rect_size.y))

	# 4) 镜像眼睛：p' = p - 2·dot(p - c, n)·n  ⇔ 本地 (x, y, d) → (x, y, -d)
	var u := mxf.basis.x
	var v := mxf.basis.y
	var n := mxf.basis.z
	# 镜中相机正对镜面：前方(-Z) = n（从镜后望向房间），上 = 镜面上方，右 = -u。
	_mirror_cam.global_transform = Transform3D(Basis(-u, v, -n), mxf * Vector3(eye.x, eye.y, -d))

	# 5) 离轴视锥：近裁面 = 镜面平面，近裁面上的窗口 = 上面的镜面矩形。
	var near := maxf(d, 0.01)
	var s := near / d
	var far := maxf(cam.far + d, near + 1.0)
	# 相机 x 轴 = -u：矩形中心相对眼睛投影点在相机坐标中的偏移为 (ex - cx, cy - ey)。
	_mirror_cam.set_frustum(
		rect_size.y * s, Vector2((eye.x - center.x) * s, (center.y - eye.y) * s), near, far
	)
	if _mirror_cam.environment != cam.environment:
		_mirror_cam.environment = cam.environment
	if _mirror_cam.attributes != cam.attributes:
		_mirror_cam.attributes = cam.attributes
	return true


## Sutherland–Hodgman：保留平面内侧（非 over）部分。
func _clip_poly(poly: Array[Vector3], plane: Plane) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var count := poly.size()
	for i in count:
		var a := poly[i]
		var b := poly[(i + 1) % count]
		var da := plane.distance_to(a)
		var db := plane.distance_to(b)
		if da <= 0.0:
			out.append(a)
		if (da <= 0.0) != (db <= 0.0):
			out.append(a.lerp(b, da / (da - db)))
	return out


func _sync_texture_size(want: Vector2) -> void:
	var cap := float(max_tex_size)
	var k := minf(1.0, cap / maxf(want.x, want.y))
	want *= k
	var cur := _viewport.size
	var step := func(x: float, c: int) -> int:
		var q := clampi(int(ceil(x / TEX_STEP)) * TEX_STEP, TEX_STEP, max_tex_size)
		# 迟滞：变大立即跟上；变小到不足 70% 才缩，避免来回重建。
		if q < c and q > int(c * 0.7):
			return c
		return q
	var sz := Vector2i(step.call(want.x, cur.x), step.call(want.y, cur.y))
	if sz != cur:
		_viewport.size = sz
	var root_vp := get_viewport()
	if _viewport.msaa_3d != root_vp.msaa_3d:
		_viewport.msaa_3d = root_vp.msaa_3d


## 校验用：按镜面平面镜像一个点（与渲染使用同一公式）。
func debug_reflect_eye(cam_pos: Vector3) -> Dictionary:
	var n := global_transform.basis.z.normalized()
	var origin := global_position
	var dist := (cam_pos - origin).dot(n)
	return {
		"normal": n,
		"origin": origin,
		"dist": dist,
		"mirrored": cam_pos - 2.0 * dist * n,
	}


func is_rendering() -> bool:
	return _active


func get_texture_size() -> Vector2i:
	return _viewport.size
