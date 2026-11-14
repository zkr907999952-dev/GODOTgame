// 躯干皮肤（PurpleDress / Skin）：复刻导入的 StandardMaterial3D + 腹壁透视挖孔（网页 attachXray punch 材质）
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/skin_common.gdshaderinc"

void fragment() {
	// Mobile 深度预通道对 fragment 丢弃像素往往不打孔，透视窗口被不透明深度挡住、内脏全被挡住。
	// ALPHA_SCISSOR 走裁切管线，Forward+ / Mobile 都能正确写深度。fragment 里不能用 return。
	float hole = xray_hole(v_ab);
	float bw = ball_wound(v_ab);
	bool cut = fp_clipped(v_wp, CAMERA_VISIBLE_LAYERS) || hole > 0.07 || bw > 0.55;
	ALPHA = cut ? 0.0 : 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	if (!cut) {
		skin_surface(UV, FRONT_FACING, ALBEDO, METALLIC, ROUGHNESS, SPECULAR, AO, NORMAL_MAP, NORMAL_MAP_DEPTH);
		if (bw > 0.12) {
			ALBEDO = mix(ALBEDO, cavity_color, smoothstep(0.12, 0.55, bw));
		}
		AO_LIGHT_AFFECT = 0.0;
	}
}
