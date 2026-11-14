extends RefCounted
class_name CharacterLook
## 角色外观修正（运行时，对齐网页 figure.tsx polishHair）：
## - 头发：原导入为 Alpha 深度预通道混合（同一网格内发片无法排序 → 发片互相透、发灰、
##   透出头皮）。改为「双通道」：主通道 Alpha Scissor(0.38，网页 alphaTest) 不透明写深度 +
##   投射阴影，开 MSAA 时用 Alpha-to-Coverage 抗锯齿；次通道只画低 alpha 的发丝边缘
##   （半透明、不写深度），让发梢柔和。双面、无金属、粗糙 0.58。
## - 头皮：头部贴图在发片下面是肤色，透过发缝看起来像秃。用离线烘的 scalp_mask.png
##   （tools/fix_hair_skin.py）作为 detail mask，把被头发覆盖的头皮混成深发色。

const SCALP_MASK := preload("res://assets/characters/tifa/scalp_mask.png")
const HAIR_ALPHA_CUT := 0.38
const SCALP_COLOR := Color(0.12, 0.095, 0.085)


static func is_hair_mesh(mi: MeshInstance3D) -> bool:
	return "_007_" in mi.name or "hair" in mi.name.to_lower()


static func is_head_mesh(mi: MeshInstance3D) -> bool:
	return "_Head_" in mi.name


static func apply(body: Node) -> void:
	for n in body.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if is_hair_mesh(mi):
			_polish_hair(mi)
		elif is_head_mesh(mi):
			_tint_scalp(mi)
		elif is_eye_mesh(mi):
			_polish_eyes(mi)


static func is_eye_mesh(mi: MeshInstance3D) -> bool:
	return "_Eye_" in mi.name or mi.name.to_lower().ends_with("_eye_0")


## 眼睛：glTF 的 ORM 贴图 R 通道不是 AO（同躯干，见 skin_common），导入后被当 AO 用，
## 眼球 R 均值只有 0.27 → 环境光被压到 27%。室内有正面主光直射还看得过去；城市里太阳在头顶、
## 眼窝被眉骨/刘海挡住，几乎只剩天空环境光 → 眼白发黑。关掉 AO，并让眼球更湿润（低粗糙度高光）。
static func _polish_eyes(mi: MeshInstance3D) -> void:
	var src := mi.get_active_material(0) as BaseMaterial3D
	if src == null:
		return
	var m := src.duplicate() as BaseMaterial3D
	m.ao_enabled = false
	m.metallic = 0.0
	m.roughness = 0.42
	m.metallic_specular = 0.5
	mi.set_surface_override_material(0, m)


static func _polish_hair(mi: MeshInstance3D) -> void:
	var src := mi.get_active_material(0) as BaseMaterial3D
	if src == null:
		return
	var m := src.duplicate() as BaseMaterial3D
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = HAIR_ALPHA_CUT
	m.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	m.alpha_antialiasing_edge = 0.3
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	m.metallic = 0.0
	m.roughness = 0.58
	m.metallic_specular = 0.35
	m.normal_enabled = false
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	# 发丝边缘：只画 alpha < 阈值的部分，半透明叠加在不透明发片之上。
	var edge := StandardMaterial3D.new()
	edge.albedo_texture = m.albedo_texture
	edge.albedo_color = m.albedo_color
	edge.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge.cull_mode = BaseMaterial3D.CULL_DISABLED
	edge.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	edge.metallic = 0.0
	edge.roughness = 0.6
	edge.metallic_specular = 0.3
	edge.render_priority = 1
	edge.texture_filter = m.texture_filter
	m.next_pass = edge
	mi.set_surface_override_material(0, m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


static func _tint_scalp(mi: MeshInstance3D) -> void:
	var src := mi.get_active_material(0) as BaseMaterial3D
	if src == null:
		return
	var m := src.duplicate() as BaseMaterial3D
	# 面部贴图的金属度通道均值 ≈0.35（原游戏资源的打包方式），按 PBR 渲染时脸发暗发脏；皮肤不是金属。
	m.metallic = 0.0
	m.metallic_specular = 0.45
	# 同眼睛：ORM 的 R 不是 AO（这里 R≡G 粗糙度通道），当 AO 会让脸在纯环境光下发灰。
	m.ao_enabled = false
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(SCALP_COLOR)
	m.detail_enabled = true
	m.detail_mask = SCALP_MASK
	m.detail_albedo = ImageTexture.create_from_image(img)
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_1
	mi.set_surface_override_material(0, m)
