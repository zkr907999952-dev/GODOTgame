// 躯干皮肤（PurpleDress / Skin）：复刻导入的 StandardMaterial3D + 腹壁透视挖孔（网页 attachXray punch 材质）
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/skin_common.gdshaderinc"

void fragment() {
	if (fp_clipped(v_wp, CAMERA_VISIBLE_LAYERS)) discard;
	float hole = xray_hole(v_ab);
	if (hole > 0.07) discard;
	float bw = ball_wound(v_ab);
	if (bw > 0.55) discard;
	skin_surface(UV, FRONT_FACING, ALBEDO, METALLIC, ROUGHNESS, SPECULAR, AO, NORMAL_MAP, NORMAL_MAP_DEPTH);
	if (bw > 0.12) {
		ALBEDO = mix(ALBEDO, cavity_color, smoothstep(0.12, 0.55, bw));
	}
	AO_LIGHT_AFFECT = 0.0;
}
