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
@export var max_tex_size: int = 4096
## 距离 LOD：可见镜面最近点在此距离内始终全分辨率，更远才按距离反比降低。
const LOD_NEAR := 4.5
const LOD_MIN := 0.4
var last_lod: float = 1.0
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
	// tex_rect = 屏幕上的镜面包围矩形（0..1）；镜中相机画面左右翻转。
	vec2 uv = vec2(
		(tex_rect.x + tex_rect.z - SCREEN_UV.x) / tex_rect.z,
		(SCREEN_UV.y - tex_rect.y) / tex_rect.w
	);
	ALBEDO = texture(mirror_tex, uv).rgb * tint;
}
"""


func _ready() -> void:
	# 在主相机（玩家 _physics_process / 输入）更新之后再算镜中相机。
	process_priority = 1000
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # 镜中相机每帧 _process 摆放
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
	# Viewport 默认显式开启物理插值（不继承父节点），镜中相机必须关闭，否则镜像滞后一帧/重影。
	_viewport.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	# 镜像相机按主相机的“当前”变换计算；主相机若开物理插值会落后一帧，导致镜像错位。
	if cam != null and cam != _mirror_cam and cam.is_physics_interpolated():
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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

	# 0.4.04：屏幕空间平面反射。旧版按镜面平面均匀采样，斜看时近处一端像素不够、
	# 再被 max_tex_size 截断 → 模糊。现在镜中相机 = 主相机按镜面镜像，投影与主相机
	# 一致，只渲染镜子在屏幕上的包围矩形，贴图像素与屏幕像素 1:1（与视角无关）；
	# 只按距离降分辨率（LOD_NEAR 以内始终全分辨率）。
	var vp_size := get_viewport().get_visible_rect().size
	if vp_size.x < 1.0 or vp_size.y < 1.0 or cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return false
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var nearest := INF
	for p in poly:
		var sp := cam.unproject_position(p) / vp_size
		lo = lo.min(sp)
		hi = hi.max(sp)
		nearest = minf(nearest, cam.global_position.distance_to(p))
	var pad := Vector2(2.0, 2.0) / vp_size
	lo = (lo - pad).max(Vector2.ZERO)
	hi = (hi + pad).min(Vector2.ONE)
	var rect := (hi - lo).max(Vector2(4.0, 4.0) / vp_size)
	last_lod = 1.0 if nearest <= LOD_NEAR else clampf(LOD_NEAR / nearest, LOD_MIN, 1.0)
	_sync_texture_size(rect * vp_size * resolution_scale * last_lod)
	# 贴图宽高比经分档后与屏幕矩形不同：矩形按贴图宽高比外扩（保持 1:1 无拉伸）。
	var tex := Vector2(_viewport.size)
	var want_aspect := tex.x / tex.y
	var center := lo + rect * 0.5
	var rect_px := rect * vp_size
	if rect_px.x / rect_px.y < want_aspect:
		rect.x = rect_px.y * want_aspect / vp_size.x
	else:
		rect.y = rect_px.x / want_aspect / vp_size.y
	lo = center - rect * 0.5
	_mat.set_shader_parameter("tex_rect", Vector4(lo.x, lo.y, rect.x, rect.y))

	# 镜像相机：位置/朝向按镜面反射；反射后基是左手系，取 -x 恢复右手系（画面因此左右翻转，
	# 着色器里再翻回来 = 镜像）。
	var n := mxf.basis.z
	var o := mxf.origin
	var cb := cam.global_transform.basis.orthonormalized()
	var refl := func(v: Vector3) -> Vector3: return v - 2.0 * v.dot(n) * n
	var rx: Vector3 = refl.call(cb.x)
	var ry: Vector3 = refl.call(cb.y)
	var rz: Vector3 = refl.call(cb.z)
	var ceye := cam.global_position
	var reye := ceye - 2.0 * (ceye - o).dot(n) * n
	_mirror_cam.global_transform = Transform3D(Basis(-rx, ry, rz), reye)

	# 近裁面 = 镜子可见部分离镜中相机最近的深度：镜后（墙外）的东西基本都被裁掉。
	var near := INF
	for p in poly:
		near = minf(near, (p - reye).dot(-rz))
	near = maxf(near * 0.995, 0.01)
	var far := maxf(cam.far + d, near + 1.0)
	var asp := vp_size.x / vp_size.y
	var th := tan(deg_to_rad(cam.fov) * 0.5)
	var hgt := 2.0 * near * th
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		hgt = 2.0 * near * th / asp
	var wid := hgt * asp
	# 主屏幕 x 映射到镜中相机 1-x（左右翻转）。
	var cx := 1.0 - (lo.x + rect.x * 0.5)
	var cy := lo.y + rect.y * 0.5
	_mirror_cam.set_frustum(hgt * rect.y, Vector2((cx - 0.5) * wid, (0.5 - cy) * hgt), near, far)
	_sync_mirror_env(cam)
	if _mirror_cam.attributes != cam.attributes:
		_mirror_cam.attributes = cam.attributes
	return true


## 镜中画面贴回场景后，主视口还会再做一次色调映射（ACES）。镜中相机若也做一次就会
## 「双重 ACES」→ 镜子里偏暗、发灰。所以给镜中相机一份 LINEAR 色调映射的环境副本。
var _env_src: Environment
var _env_copy: Environment


func _sync_mirror_env(cam: Camera3D) -> void:
	var src: Environment = cam.environment if cam.environment else get_world_3d().environment
	if src != _env_src:
		_env_src = src
		_env_copy = null
		if src:
			_env_copy = src.duplicate() as Environment
			_env_copy.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			_env_copy.tonemap_exposure = 1.0
	if _mirror_cam.environment != _env_copy:
		_mirror_cam.environment = _env_copy


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
