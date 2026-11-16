// 躯干皮肤（PurpleDress / Skin）：复刻导入的 StandardMaterial3D + 腹壁透视挖孔（网页 attachXray punch 材质）
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/skin_common.gdshaderinc"

void fragment() {
	// Mobile 深度预通道对 fragment 丢弃像素往往不打孔，透视窗口被不透明深度挡住、内脏全被挡住。
	// ALPHA_SCISSOR 走裁切管线，Forward+ / Mobile 都能正确写深度。fragment 里不能用 return。
	// t27u：射击人体不再在皮肤上挖出弹道孔（以前 ball_wound>0.55 直接把皮肤裁掉、周围染成暗红腔色，
	// 手机上就是一个个黑点弹孔）。弹道通道只保留给内脏的撕裂/发红，体表只留创口贴花。
	float hole = xray_hole(v_ab);
	bool cut = fp_clipped(v_wp, CAMERA_VISIBLE_LAYERS) || hole > 0.07;
	ALPHA = cut ? 0.0 : 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	if (!cut) {
		skin_surface(UV, FRONT_FACING, ALBEDO, METALLIC, ROUGHNESS, SPECULAR, AO, NORMAL_MAP, NORMAL_MAP_DEPTH);
		AO_LIGHT_AFFECT = 0.0;
	}
}
